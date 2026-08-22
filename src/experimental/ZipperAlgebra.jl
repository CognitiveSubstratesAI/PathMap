"""
    ZipperAlgebra — experimental N-ary zipper merge operations.

Ports `src/experimental/zipper_algebra.rs` from upstream PathMap,
PR #35 (commits ca42077…3e4a2ba, "zipper_join_n").

## Public API

    wz_join_n!(out, zs)      — N-way join   (∨, least-upper-bound, union-like)
    wz_meet_n!(out, zs)      — N-way meet   (∧, greatest-lower-bound, intersection)
    wz_subtract_n!(out, zs)  — N-way subtract (left-associative, lhs \\ rhs1 \\ rhs2 …)

All three accept:
  out :: WriteZipperCore{V,A}   — output zipper (written during traversal)
  zs  :: AbstractVector{WriteZipperCore{V,A}}  — input zippers (read-only navigation)

Input zippers are navigated (descend / ascend) in place and restored to root
before the function returns.

## Algorithm

Implements a stackless iterative DFS (`_zm_merge_n!`) that simultaneously
traverses all N tries in lexicographic order using a 64-bit bitmask (`active`)
to track which input zippers are still "live".  At each node:

- Finds the minimum child byte and the *frontier* (subset of inputs that have
  that byte as a child).
- Dispatches:
  - **Full match** (`frontier == active`): descend all, combine values.
  - **Singleton** (`|frontier| = 1`): call `_zm_on_single!` (policy-dependent
    graft or skip).
  - **Partial overlap** (`1 < |frontier| < N`): maybe descend the subset
    (policy-dependent); falls back to a recursive call on the subset.
- After processing all children at a depth level, ascends and moves on.

Shared-node short-circuit (upstream commit ade1e1b): when all active inputs
land on the same trie node after descent, calls `_zm_on_id!` without further
traversal.

## Policy types

    JoinP()     — least-upper-bound; on_single = graft; combine = pjoin
    MeetP()     — greatest-lower-bound; on_single = drop; combine = pmeet
    SubtractP() — asymmetric difference; on_single(left-only) = graft; combine = psubtract

## Julia vs Rust differences

| Rust                         | Julia                                    |
|------------------------------|------------------------------------------|
| `[Z; N]` const-generic array | `AbstractVector{WriteZipperCore{V,A}}`   |
| Input/output separate traits | Both input and output are WriteZipperCore|
| `ZipperConcrete::shared_node_id()` | `_wm_shared_node_id(wz)`            |
| `ByteMask::from_range(a..b)` | `from_range(Int(a):Int(b)-1)` (excl→incl)|
| `ByteMask::from_range(a..)`  | `from_range(Int(a):255)`                 |
"""

# =====================================================================
# Policy types
# =====================================================================

"""
Abstract base for N-ary merge policies (Join / Meet / Subtract).
"""
abstract type ZipperMergePolicy end

"""
Join (∨, least-upper-bound, union-like). Preserves both sides.
"""
struct JoinP <: ZipperMergePolicy end

"""
Meet (∧, greatest-lower-bound, intersection). Keeps only shared keys.
"""
struct MeetP <: ZipperMergePolicy end

"""
Subtract (asymmetric difference).  Left-associative: `z0 \\ z1 \\ z2 …`.
Only `z0`'s structure contributes; subsequent zippers remove matching regions.
"""
struct SubtractP <: ZipperMergePolicy end

# =====================================================================
# Shared-node identity for WriteZipperCore
# =====================================================================

"""
    _wm_shared_node_id(z) -> Union{Nothing, UInt64}

Return the stable GC identity of the trie node at `z`'s current focus,
or `nothing` if no stable identity is available.

Mirrors `ZipperConcrete::shared_node_id()` from upstream PathMap.
Used by the shared-node short-circuit in `_zm_merge_n!`.
"""
function _wm_shared_node_id(z::WriteZipperCore{V, A}) where {V, A}
    anr_shared_id(_wz_get_focus_anr(z))
end

"""
    _wm_all_share(zs, active) -> Bool

Return `true` iff **all** active input zippers (≥ 2) point to the same trie
node.  Returns `false` when fewer than 2 zippers are active, since a single
zipper trivially "shares with itself" — firing `on_id!` in that case would
produce incorrect results for `SubtractP` (it would drop the base set instead
of copying it).

Mirrors `all_active_share` in upstream `zipper_merge_n_mono`.
"""
function _wm_all_share(zs::AbstractVector{<:WriteZipperCore}, active::UInt64)
    count_ones(active) < 2 && return false   # need ≥ 2 to meaningfully share
    first_id = nothing
    for i in 0:(length(zs) - 1)
        (active >> i) & 1 == 0 && continue
        id = _wm_shared_node_id(zs[i + 1])
        id === nothing && return false
        if first_id === nothing
            first_id = id
        elseif id != first_id
            return false
        end
    end
    first_id !== nothing
end

# =====================================================================
# Graft helpers
# =====================================================================

"""
    _zm_graft_children_masked!(out, src, range)

Graft all children of `src` whose byte key falls within `range` into `out`.
Both zippers are returned to their entry position after the call.

Handles three cases for each child byte `b`:

 1. **Value-only leaf** (`wz_is_val` = true, `_wz_get_focus_anr` = ANRNone):
    the value is stored in the parent slot; copy it with `wz_set_val!`.
 2. **Subtrie-only node** (`wz_is_val` = false, ANR ≠ None):
    graft the child subtrie with `_wz_graft_internal!`.
 3. **Both value and subtrie** (both true):
    set the value AND graft the subtrie (they are stored independently
    in the parent slot's `val` vs `child` fields).

Note: `_wz_get_focus_anr` returns `ANRNone` for pure-value leaf positions
because there is no child `TrieNodeODRc` at that key — only a `ValOrChild`
with `kind=0x00`.  The value must be copied separately.

Mirrors `ZipperWriting::graft_children(z, range)` from upstream PathMap.
Called by `_zm_on_single!` and `_zm_on_id!`.
"""
function _zm_graft_children_masked!(
    out::WriteZipperCore{V, A}, src::WriteZipperCore{V, A}, range::ByteMask
) where {V, A}
    active_mask = range & wz_child_mask(src)
    b = indexed_bit(active_mask, 0, true)
    while b !== nothing
        wz_descend_to_byte!(src, b)
        wz_descend_to_byte!(out, b)

        # Copy value (covers value-only leaves and nodes that have both)
        if wz_is_val(src)
            wz_set_val!(out, wz_get_val(src))
        end
        # Copy child subtrie (covers branch nodes and nodes that have both)
        focus_anr = _wz_get_focus_anr(src)
        if !is_none(focus_anr)
            _wz_graft_internal!(out, into_option(focus_anr))
        end

        wz_ascend_byte!(out)
        wz_ascend_byte!(src)
        b = next_bit(active_mask, b)
    end
end

# =====================================================================
# Policy dispatch — on_id!
# =====================================================================
# on_id!: called when all active zippers share the same trie node.
# The output should be set to the identity result for the policy.
# `first_z` is the first active zipper (used for the graft source).

"""
    _zm_on_id!(policy, first_z, out)

Called when all active inputs share the same trie node.
Writes the identity result for `policy` into `out`.

  - Join / Meet : graft all children (A ∨ A = A, A ∧ A = A).
  - Subtract    : do nothing (A \\ A = ∅).

Mirrors `MergePolicy::on_id` in upstream zipper_algebra.rs.
"""
function _zm_on_id!(::JoinP, first_z::WriteZipperCore, out::WriteZipperCore)
    _zm_graft_children_masked!(out, first_z, bytemask_full())
end
function _zm_on_id!(::MeetP, first_z::WriteZipperCore, out::WriteZipperCore)
    _zm_graft_children_masked!(out, first_z, bytemask_full())
end
_zm_on_id!(::SubtractP, first_z, out) = nothing

# =====================================================================
# Policy dispatch — on_single!
# =====================================================================
# on_single!: called when only a subset (singleton or partial frontier)
# of the active zippers have children in a byte range.
# `mask_bit` is the frontier bitmask (which inputs are active here).

"""
    _zm_on_single!(policy, z, mask_bit, range, out)

Handle a byte range `range` where only the zipper(s) identified by
`mask_bit` have children.

  - Join     : graft (any side contributes to union).
  - Meet     : drop (only shared keys survive intersection).
  - Subtract : graft iff `z` is the left-most (index 0) operand.

Mirrors `MergePolicy::on_single` in upstream zipper_algebra.rs.
"""
function _zm_on_single!(
    ::JoinP, z::WriteZipperCore, ::UInt64, range::ByteMask, out::WriteZipperCore
)
    _zm_graft_children_masked!(out, z, range)
end
_zm_on_single!(::MeetP, z, mask_bit, range, out) = nothing
function _zm_on_single!(
    ::SubtractP, z::WriteZipperCore, mask_bit::UInt64, range::ByteMask, out::WriteZipperCore
)
    # graft only if bit 0 is set (left-most zipper = the base set)
    mask_bit & UInt64(1) != 0 && _zm_graft_children_masked!(out, z, range)
end

# =====================================================================
# Policy dispatch — descend_on_equal
# =====================================================================

"""
    _zm_descend_on_equal(policy, frontier) -> Bool

Return `true` if the merge should descend into a partial-overlap subset
(Case C in the DFS).

  - Join     : always descend.
  - Meet     : never (partial overlap = not all present → annihilate).
  - Subtract : only when the left-most zipper (bit 0) is in the frontier.

Mirrors `MergePolicy::descend_on_some_equal` in upstream zipper_algebra.rs.
"""
_zm_descend_on_equal(::JoinP, ::UInt64) = true
_zm_descend_on_equal(::MeetP, ::UInt64) = false
_zm_descend_on_equal(::SubtractP, frontier::UInt64) = frontier & UInt64(1) != 0

# =====================================================================
# Policy dispatch — combine_n
# =====================================================================

"""
    _zm_combine_n(policy, vals) -> Union{Nothing, V}

Combine an iterable of `Union{Nothing,V}` values using the policy's
lattice operation.  Returns `nothing` if the combination yields no value.

  - Join     : fold with `pjoin`; missing values are skipped (identity = ∅).
  - Meet     : fold with `pmeet`; any `nothing` short-circuits to `nothing`.
  - Subtract : left-associative fold with `psubtract`.

Mirrors `ValuePolicy::combine_n` in upstream zipper_algebra.rs.
"""
function _zm_combine_n(::JoinP, vals)
    result = nothing
    for v in vals
        v === nothing && continue
        if result === nothing
            result = v
        else
            ar = pjoin(result, v)
            if ar isa AlgResElement
                result = ar.value
            elseif ar isa AlgResIdentity
                result = ar.mask & SELF_IDENT != 0 ? result : v
            else
                result = nothing
            end
        end
    end
    result
end

function _zm_combine_n(::MeetP, vals)
    result = nothing
    started = false
    for v in vals
        v === nothing && return nothing
        if !started
            result = v
            started = true
        else
            ar = pmeet(result, v)
            if ar isa AlgResElement
                result = ar.value
            elseif ar isa AlgResIdentity
                result = ar.mask & SELF_IDENT != 0 ? result : v
            else
                return nothing
            end
        end
    end
    result
end

function _zm_combine_n(::SubtractP, vals)
    result = nothing
    started = false
    for v in vals
        if !started
            result = v
            started = true
        elseif result !== nothing && v !== nothing
            ar = psubtract(result, v)
            if ar isa AlgResElement
                result = ar.value
            elseif ar isa AlgResIdentity
                # subtract identity means left is unchanged
                result = ar.mask & SELF_IDENT != 0 ? result : nothing
            else
                return nothing
            end
        elseif result === nothing
            return nothing
        end
        # v === nothing → result unchanged (subtracting nothing changes nothing)
    end
    result
end

# =====================================================================
# Core N-ary DFS engine
# =====================================================================

"""
    _zm_merge_n!(policy, zs, active, out)

Internal: N-ary stackless DFS merge.  Simultaneously traverses all
zippers in `zs` whose bit is set in `active` (UInt64 bitmask, bit i = zs[i+1]).

Implements the algorithm from upstream `zipper_merge_n_mono`:

  - iterative 'ascend / 'merge_level loop with explicit depth counter `k`
  - shared-node short-circuit at root and after each descent
  - Case A (full match): descend all, refresh masks
  - Case B (singleton ): call `_zm_on_single!`
  - Case C (partial    ): maybe descend subset recursively

Both input zippers and the output zipper are navigated in place.
All input zippers are returned to their entry position when this function
returns.
"""
function _zm_merge_n!(
    policy::ZipperMergePolicy, zs::AbstractVector{<:WriteZipperCore{V, A}}, active::UInt64,
    out::WriteZipperCore{V, A}
) where {V, A}
    N = length(zs)
    @assert N >= 1 && N <= 64
    @assert active >> N == 0

    # ── helpers ──────────────────────────────────────────────────────────
    @inline active_bits() = (i for i in 0:(N - 1) if (active >> i) & 1 != 0)

    @inline function first_active_idx()
        for i in 0:(N - 1)
            (active >> i) & 1 != 0 && return i
        end
        error("active is zero")
    end

    @inline function for_each_active(f)
        for i in 0:(N - 1)
            (active >> i) & 1 != 0 && f(i)
        end
    end

    @inline function for_each_frontier(f)
        bits = frontier
        while bits != 0
            i = trailing_zeros(bits)
            f(i)
            bits &= bits - 1
        end
    end

    # ── shared-node check at entry ────────────────────────────────────
    if _wm_all_share(zs, active)
        _zm_on_id!(policy, zs[first_active_idx() + 1], out)
        return nothing
    end

    # ── combine root values ───────────────────────────────────────────
    let vals = (
            wz_is_val(zs[i + 1]) ? wz_get_val(zs[i + 1]) : nothing for i in active_bits()
        )
        combined = _zm_combine_n(policy, vals)
        combined !== nothing && wz_set_val!(out, combined)
    end

    # ── per-zipper state: current child mask + next byte ──────────────
    masks = Vector{ByteMask}(undef, N)
    bytes = Vector{Union{Nothing, UInt8}}(undef, N)
    for i in active_bits()
        masks[i + 1] = wz_child_mask(zs[i + 1])
        bytes[i + 1] = indexed_bit(masks[i + 1], 0, true)
    end

    k = 0          # descent depth counter (for the ascend phase)
    frontier = UInt64(0) # re-used in closure below; declare at scope level

    # ── main iterative DFS ────────────────────────────────────────────
    while true  # 'ascend: loop

        # ---------- merge_level loop ----------------------------------
        break_merge = false
        while !break_merge

            # find minimum byte (min_byte) and frontier bitmask
            min_byte = nothing
            frontier = UInt64(0)
            next_byte = nothing

            for i in active_bits()
                b = bytes[i + 1]
                b === nothing && continue
                if min_byte === nothing
                    min_byte = b
                    frontier = UInt64(1) << i
                elseif b < min_byte
                    # old min becomes next candidate
                    if next_byte === nothing || min_byte < next_byte
                        next_byte = min_byte
                    end
                    min_byte = b
                    frontier = UInt64(1) << i
                elseif b == min_byte
                    frontier |= UInt64(1) << i
                else  # b > min_byte
                    if next_byte === nothing || b < next_byte
                        next_byte = b
                    end
                end
            end

            # no more children at this level
            min_byte === nothing && break

            a = min_byte
            cnt = count_ones(frontier)

            if frontier == active
                # ── Case A: full match — descend all ──────────────────
                wz_descend_to_byte!(out, a)
                for_each_active(i -> wz_descend_to_byte!(zs[i + 1], a))

                # shared-node check after descent
                if _wm_all_share(zs, active)
                    _zm_on_id!(policy, zs[first_active_idx() + 1], out)
                    for_each_active(i -> begin
                        wz_ascend_byte!(zs[i + 1])
                        bytes[i + 1] = next_bit(masks[i + 1], a)
                    end)
                    wz_ascend_byte!(out)
                    continue  # continue 'merge_level
                end

                # combine values
                let vals = (
                        wz_is_val(zs[i + 1]) ? wz_get_val(zs[i + 1]) : nothing for
                        i in active_bits()
                    )
                    combined = _zm_combine_n(policy, vals)
                    combined !== nothing && wz_set_val!(out, combined)
                end

                # refresh masks
                for_each_active(i -> begin
                    masks[i + 1] = wz_child_mask(zs[i + 1])
                    bytes[i + 1] = indexed_bit(masks[i + 1], 0, true)
                end)
                k += 1
                # continue 'merge_level

            elseif cnt == 1
                # ── Case B: singleton — graft or skip ─────────────────
                i = trailing_zeros(frontier)
                if next_byte === nothing
                    _zm_on_single!(policy, zs[i + 1], frontier, from_range(Int(a):255), out)
                    break_merge = true
                else
                    _zm_on_single!(
                        policy,
                        zs[i + 1],
                        frontier,
                        from_range(Int(a):(Int(next_byte) - 1)),
                        out
                    )
                    # advance this zipper past the handled range
                    adv = masks[i + 1] & from_range(Int(next_byte):255)
                    bytes[i + 1] = indexed_bit(adv, 0, true)
                end

            else
                # ── Case C: partial overlap — maybe descend subset ────
                if _zm_descend_on_equal(policy, frontier)
                    wz_descend_to_byte!(out, a)
                    for_each_frontier(i -> wz_descend_to_byte!(zs[i + 1], a))

                    # Recurse on the subset (same array, smaller mask)
                    _zm_merge_n!(policy, zs, frontier, out)

                    for_each_frontier(i -> wz_ascend_byte!(zs[i + 1]))
                    wz_ascend_byte!(out)
                end
                # advance all frontier bits
                for_each_frontier(i -> begin
                    bytes[i + 1] = next_bit(masks[i + 1], a)
                end)
            end
        end  # merge_level

        # ── ascend phase ──────────────────────────────────────────────
        k == 0 && break

        # get byte we descended on from the first active zipper's path
        fst_path = wz_path(zs[first_active_idx() + 1])
        byte_from = fst_path[end]

        for_each_active(i -> begin
            wz_ascend_byte!(zs[i + 1])
            masks[i + 1] = wz_child_mask(zs[i + 1])
            bytes[i + 1] = next_bit(masks[i + 1], byte_from)
        end)
        wz_ascend_byte!(out)
        k -= 1
    end  # 'ascend
end

# =====================================================================
# Public API
# =====================================================================

"""
    wz_join_n!(out, zs)

N-way join (∨, least-upper-bound, union-like) of all tries in `zs`.
Result is written to `out`.  All input zippers are navigated in place and
restored to root on return.

Mirrors `zipper_n_join` in upstream PathMap `src/experimental/zipper_algebra.rs`.
"""
function wz_join_n!(
    out::WriteZipperCore{V, A}, zs::AbstractVector{<:WriteZipperCore{V, A}}
) where {V, A}
    isempty(zs) && return nothing
    length(zs) <= 64 || error("wz_join_n!: at most 64 inputs supported")
    active = (UInt64(1) << length(zs)) - UInt64(1)
    _zm_merge_n!(JoinP(), zs, active, out)
end

"""
    wz_meet_n!(out, zs)

N-way meet (∧, greatest-lower-bound, intersection) of all tries in `zs`.
Only paths present in ALL inputs appear in `out`.  All input zippers are
navigated in place and restored to root on return.

Mirrors `zipper_n_meet` in upstream PathMap `src/experimental/zipper_algebra.rs`.
"""
function wz_meet_n!(
    out::WriteZipperCore{V, A}, zs::AbstractVector{<:WriteZipperCore{V, A}}
) where {V, A}
    isempty(zs) && return nothing
    length(zs) <= 64 || error("wz_meet_n!: at most 64 inputs supported")
    active = (UInt64(1) << length(zs)) - UInt64(1)
    _zm_merge_n!(MeetP(), zs, active, out)
end

"""
    wz_subtract_n!(out, zs)

Left-associative N-way subtract: `zs[1] \\ zs[2] \\ … \\ zs[N]`.
`zs[1]` is the base set; subsequent inputs remove matching structure.
Result is written to `out`.  All input zippers are navigated in place and
restored to root on return.

Mirrors `zipper_n_subtract` in upstream PathMap `src/experimental/zipper_algebra.rs`.
"""
function wz_subtract_n!(
    out::WriteZipperCore{V, A}, zs::AbstractVector{<:WriteZipperCore{V, A}}
) where {V, A}
    isempty(zs) && return nothing
    length(zs) <= 64 || error("wz_subtract_n!: at most 64 inputs supported")
    active = (UInt64(1) << length(zs)) - UInt64(1)
    _zm_merge_n!(SubtractP(), zs, active, out)
end

# =====================================================================
# Exports
# =====================================================================

export ZipperMergePolicy, JoinP, MeetP, SubtractP
export wz_join_n!, wz_meet_n!, wz_subtract_n!
export _wm_shared_node_id, _zm_graft_children_masked!
