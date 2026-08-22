"""
ProductZipper — port of `pathmap/src/product_zipper.rs`.

Creates a virtual Cartesian-product trie from N source tries.  Paths in the
product trie are formed by concatenating one path from each factor in order.

Example with 2 factors A={a,b} and B={x,y}:
  Product paths = {ax, ay, bx, by}

The implementation reuses `ReadZipperCore` as the primary cursor, pushing
secondary factor roots onto its ancestor stack at factor boundaries.

Julia translation notes:
  - Rust `take_core()` + `push_node()` + `regularize()` → implemented as
    `_zc_push_node!` + `_zc_regularize!` + `_zc_deregularize!` on ReadZipperCore.
  - `TrieRefOwned` (secondary roots) → TrieRefBorrowed in Julia (GC-managed).
  - `source_zippers` ownership (to keep TrieRef alive) → Julia GC handles this.
"""

# =====================================================================
# ProductZipper struct
# =====================================================================

"""
    ProductZipper{V, A}

Cartesian-product zipper over N factors.
Mirrors `ProductZipper<'factor_z, 'trie, V, A>`.
"""
mutable struct ProductZipper{V, A <: Allocator}
    z::ReadZipperCore{V, A}      # primary cursor (owns the ancestor stack)
    secondaries::Vector{TrieRefBorrowed{V, A}}  # secondary factor roots
    factor_paths::Vector{Int}             # path lengths at each factor boundary
end

"""
    ProductZipper(primary_z, other_zippers) → ProductZipper

Create a ProductZipper from a primary ReadZipperCore and an iterable of
additional factor zippers (each must be a ReadZipperCore).
Mirrors `ProductZipper::new`.
"""
function ProductZipper(primary_z::ReadZipperCore{V, A}, other_zippers) where {V, A}
    zipper_reset!(primary_z)
    secondaries = TrieRefBorrowed{V, A}[]
    for oz in other_zippers
        # Fork a TrieRef at the root of each secondary zipper
        t = trie_ref_at_path(PathMap{V, A}(oz.root_node, oz.root_val, oz.alloc), UInt8[])
        push!(secondaries, t)
    end
    # Upstream: factor_paths pre-allocated with Vec::with_capacity(secondaries.len())
    fp = Int[]
    sizehint!(fp, length(secondaries))
    ProductZipper{V, A}(primary_z, secondaries, fp)
end

"""
    ProductZipper(primary_z) → ProductZipper

Create a ProductZipper with only the primary factor.
Mirrors `ProductZipper::new_with_primary`.
"""
function ProductZipper(primary_z::ReadZipperCore{V, A}) where {V, A}
    zipper_reset!(primary_z)
    ProductZipper{V, A}(primary_z, TrieRefBorrowed{V, A}[], Int[])
end

"""
    ProductZipper(m::PathMap, prefix, n_factors) → ProductZipper

Anchored constructor: build an `n_factors`-way Cartesian-product zipper whose
factors all traverse the **subtrie rooted at `prefix`** in `m`, rather than
the whole trie.

Why this exists (vs. `ProductZipper(read_zipper_at_path(m, prefix), …)`):
`read_zipper_at_path` records the prefix only as a *cursor position*; its
`root_node` stays the trie root.  The base `ProductZipper` constructor then
re-roots each secondary from `root_node` and resets the primary to its
origin — both of which discard the prefix anchor.  The result traverses the
whole trie and `pz_path` carries the raw prefix bytes (which then crash
expression decoders that expect tag bytes).

This constructor instead resolves the prefix to its actual subtrie-root node
via `trie_ref_at_path` + `into_option(tr_get_focus_anr(...))`, wraps that node
as a fresh `PathMap` root, and builds every factor with `read_zipper` over it.
Each factor zipper therefore has `origin = 0` relative to the prefix node, so
`pz_path` is anchor-relative (no prefix bytes) and traversal is O(subtrie) —
a true prefix-scoped view, no copy.

`tr_get_focus_anr` (not `tr_get_focus_rc`) is used deliberately: when `prefix`
lands *inside* a compressed edge — e.g. a single atom `b/foo` path-compresses
`b/foo` into one edge with no node boundary at `b/` — `tr_get_focus_rc`
returns `nothing` (no child exactly at the prefix), which would wrongly look
like an empty region.  `get_node_at_key` (reached via `tr_get_focus_anr`)
instead peels the consumed prefix off the compressed key and returns a node
for the remaining subtrie (`ANRBorrowedTiny`); `into_option` materializes it
as a clean root rc via a shallow node clone (children stay shared — still a
view, not an O(subtrie) copy).  Resolving to a clean root up front also keeps
the ProductZipper's own factor-enrollment (which uses `tr_get_focus_rc`)
correct, since it then operates on a node-boundary root, never mid-edge.

An empty / absent prefix region yields a ProductZipper over an empty trie
(iteration produces nothing), matching the "no matches under this prefix"
semantics callers expect.
"""
function ProductZipper(
    m::PathMap{V, A}, prefix::AbstractVector{UInt8}, n_factors::Int
) where {V, A}
    n_factors >= 1 || throw(ArgumentError("n_factors must be >= 1"))
    _ensure_root!(m)
    tr = trie_ref_at_path(m, prefix)
    rc = _tr_is_valid(tr) ? into_option(tr_get_focus_anr(tr)) : nothing
    sub = if rc === nothing
        e = PathMap{V, A}(m.alloc)
        _ensure_root!(e)
        e        # empty region
    else
        PathMap{V, A}(rc, nothing, m.alloc)                    # root AT prefix node
    end
    primary = read_zipper(sub)
    n_factors == 1 && return ProductZipper(primary)
    secondaries = ReadZipperCore{V, A}[read_zipper(sub) for _ in 2:n_factors]
    ProductZipper(primary, secondaries)
end

# =====================================================================
# Internal helpers
# =====================================================================

"""
Number of total factors (primary + secondaries).
"""
pz_factor_count(pz::ProductZipper) = 1 + length(pz.secondaries)

"""
Index (0-based) of the factor that currently contains the cursor.
"""
function pz_focus_factor(pz::ProductZipper)::Int
    path_len = length(zipper_path(pz.z))
    for (i, fp) in enumerate(pz.factor_paths)
        path_len < fp && return i - 1
    end
    length(pz.factor_paths)
end

"""
True if there is a next secondary factor not yet enrolled.
"""
_pz_has_next_factor(pz::ProductZipper) = length(pz.factor_paths) < length(pz.secondaries)

"""
Push the next secondary factor's root onto the primary zipper's ancestor stack.
Mirrors `ProductZipper::enroll_next_factor`.
"""
function _pz_enroll_next_factor!(pz::ProductZipper{V, A}) where {V, A}
    idx = length(pz.factor_paths) + 1   # 1-based secondary index
    t = pz.secondaries[idx]
    _tr_is_valid(t) || return nothing
    # Get the root node of the secondary factor
    rc = tr_get_focus_rc(t)
    rc === nothing && return nothing
    secondary_root = _rc_inner(rc)
    _zc_deregularize!(pz.z)
    _zc_push_node!(pz.z, secondary_root)
    push!(pz.factor_paths, length(zipper_path(pz.z)))
end

"""
If at a factor boundary (leaf of current factor), enroll the next factor.
Mirrors `ProductZipper::ensure_descend_next_factor`.
"""
function _pz_ensure_descend_next_factor!(pz::ProductZipper)
    _pz_has_next_factor(pz) || return nothing
    zipper_child_count(pz.z) == 0 || return nothing
    last_fp = isempty(pz.factor_paths) ? 0 : pz.factor_paths[end]
    last_fp < length(zipper_path(pz.z)) || return nothing
    _pz_enroll_next_factor!(pz)
end

"""
After any ascend, pop factor_paths entries that are now above the cursor.
Mirrors `ProductZipper::fix_after_ascend`.
"""
function _pz_fix_after_ascend!(pz::ProductZipper)
    path_len = length(zipper_path(pz.z))
    while !isempty(pz.factor_paths) && path_len < pz.factor_paths[end]
        pop!(pz.factor_paths)
    end
end

# =====================================================================
# Zipper interface
# =====================================================================

pz_at_root(pz::ProductZipper)::Bool = isempty(zipper_path(pz.z))
pz_path(pz::ProductZipper) = zipper_path(pz.z)
pz_is_val(pz::ProductZipper)::Bool = zipper_is_val(pz.z)
pz_val(pz::ProductZipper{V}) where {V} = zipper_val(pz.z)
pz_path_exists(pz::ProductZipper) = zipper_path_exists(pz.z)
pz_child_mask(pz::ProductZipper) = zipper_child_mask(pz.z)
pz_child_count(pz::ProductZipper) = zipper_child_count(pz.z)

function pz_val_count(pz::ProductZipper)
    @assert pz_focus_factor(pz) == pz_factor_count(pz) - 1
    zipper_val_count(pz.z)
end

# =====================================================================
# ZipperMoving
# =====================================================================

function pz_reset!(pz::ProductZipper)
    empty!(pz.factor_paths)
    zipper_reset!(pz.z)
end

function pz_descend_to_existing!(pz::ProductZipper, k)
    kv = collect(UInt8, k)
    descended = 0
    while descended < length(kv)
        this_step = zipper_descend_to_existing!(pz.z, kv[(descended + 1):end])
        this_step == 0 && break
        descended += this_step
        if _pz_has_next_factor(pz)
            if zipper_child_count(pz.z) == 0 &&
                (isempty(pz.factor_paths) ? 0 : pz.factor_paths[end]) <
               length(zipper_path(pz.z))
                _pz_enroll_next_factor!(pz)
            end
        else
            break
        end
    end
    descended
end

function pz_descend_to!(pz::ProductZipper, k)
    kv = collect(UInt8, k)
    descended = pz_descend_to_existing!(pz, kv)
    if descended != length(kv)
        zipper_descend_to!(pz.z, kv[(descended + 1):end])
    end
end

function pz_descend_to_byte!(pz::ProductZipper, k::UInt8)
    zipper_descend_to_byte!(pz.z, k)
    if zipper_child_count(pz.z) == 0
        if _pz_has_next_factor(pz) && zipper_path_exists(pz.z)
            @assert (isempty(pz.factor_paths) ? 0 : pz.factor_paths[end]) <
                length(zipper_path(pz.z))
            _pz_enroll_next_factor!(pz)
            nk = collect(_zc_node_key(pz.z))
            isempty(nk) || _zc_regularize!(pz.z)
        end
    end
end

function pz_descend_indexed_byte!(pz::ProductZipper, idx::Int)
    result = zipper_descend_indexed_byte!(pz.z, idx)
    _pz_ensure_descend_next_factor!(pz)
    result
end

function pz_descend_first_byte!(pz::ProductZipper)
    result = zipper_descend_first_byte!(pz.z)
    _pz_ensure_descend_next_factor!(pz)
    result
end

function pz_descend_until!(pz::ProductZipper)
    moved = false
    while zipper_child_count(pz.z) == 1
        moved |= zipper_descend_until!(pz.z)
        _pz_ensure_descend_next_factor!(pz)
        zipper_is_val(pz.z) && break
    end
    moved
end

function pz_to_next_sibling_byte!(pz::ProductZipper)
    if !isempty(pz.factor_paths) && pz.factor_paths[end] == length(zipper_path(pz.z))
        pop!(pz.factor_paths)
    end
    moved = zipper_to_next_sibling_byte!(pz.z)
    _pz_ensure_descend_next_factor!(pz)
    moved
end

function pz_to_prev_sibling_byte!(pz::ProductZipper)
    if !isempty(pz.factor_paths) && pz.factor_paths[end] == length(zipper_path(pz.z))
        pop!(pz.factor_paths)
    end
    moved = zipper_to_prev_sibling_byte!(pz.z)
    _pz_ensure_descend_next_factor!(pz)
    moved
end

function pz_ascend!(pz::ProductZipper, steps::Int=1)
    result = zipper_ascend!(pz.z, steps)
    _pz_fix_after_ascend!(pz)
    result
end

pz_ascend_byte!(pz::ProductZipper) = pz_ascend!(pz, 1)

function pz_ascend_until!(pz::ProductZipper)
    result = zipper_ascend_until!(pz.z)
    _pz_fix_after_ascend!(pz)
    result
end

function pz_ascend_until_branch!(pz::ProductZipper)
    result = zipper_ascend_until_branch!(pz.z)
    _pz_fix_after_ascend!(pz)
    result
end

# =====================================================================
# Additional navigation methods needed by coreferential DFS
# =====================================================================

"""
    pz_descend_to_existing_byte!(pz, b) → Bool

Single-byte variant of pz_descend_to_existing!.
Returns true if the byte path exists and was descended.
"""
function pz_descend_to_existing_byte!(pz::ProductZipper, b::UInt8)::Bool
    pz_descend_to_existing!(pz, UInt8[b]) == 1
end

"""
    pz_descend_to_check!(pz, bytes) → Bool

Descend into `bytes` if the exact path exists; return true on success.
On failure, ascend back to restore prior position.
Mirrors behaviour of `zipper_descend_to_check!` for ProductZipper.
"""
function pz_descend_to_check!(pz::ProductZipper, bytes)::Bool
    bv = bytes isa AbstractVector{UInt8} ? bytes : collect(UInt8, bytes)
    isempty(bv) && return true
    n = pz_descend_to_existing!(pz, bv)
    if n == length(bv)
        return true
    end
    # Failed — ascend back the bytes we did descend
    n > 0 && pz_ascend!(pz, n)
    false
end

"""
    pz_descend_first_k_path!(pz, k) → Bool

Descend to the first path exactly `k` bytes below the current focus.
Delegates to the primary zipper (factor transitions handled by existing pz logic).
Mirrors `zipper_descend_first_k_path!` for ProductZipper.
"""
function pz_descend_first_k_path!(pz::ProductZipper, k::Int)::Bool
    base_idx = length(pz_path(pz))
    _pz_k_path_internal!(pz, k, base_idx)
end

"""
    pz_to_next_k_path!(pz, k) → Bool

Move to the next path at the same depth (k steps from the common root).
Mirrors `zipper_to_next_k_path!` for ProductZipper.
"""
function pz_to_next_k_path!(pz::ProductZipper, k::Int)::Bool
    base_idx = length(pz_path(pz)) - k
    _pz_k_path_internal!(pz, k, base_idx)
end

function _pz_k_path_internal!(pz::ProductZipper, k::Int, base_idx::Int)::Bool
    # Direct port of _zipper_k_path_internal! (Zipper.jl) using pz_* methods.
    while true
        if length(pz_path(pz)) < base_idx + k
            while pz_descend_first_byte!(pz)
                length(pz_path(pz)) == base_idx + k && return true
            end
        end
        if pz_to_next_sibling_byte!(pz)
            length(pz_path(pz)) == base_idx + k && return true
            continue
        end
        while length(pz_path(pz)) > base_idx
            pz_ascend_byte!(pz)
            length(pz_path(pz)) == base_idx && return false
            pz_to_next_sibling_byte!(pz) && break
        end
    end
end

# ZipperIteration — use default DFS impl (same as OverlayZipper)
function pz_to_next_val!(pz::ProductZipper)
    loop_count = 0
    while true
        loop_count += 1
        if loop_count > 100_000
            @warn "ProductZipper pz_to_next_val! hit iteration cap (100k); returning false. This indicates a likely infinite loop in product DFS." maxlog=1
            return false
        end
        if pz_descend_first_byte!(pz)
            pz_is_val(pz) && return true
            if pz_descend_until!(pz)

                pz_is_val(pz) && return true
            end
        else
            ascending = true
            while ascending
                if pz_to_next_sibling_byte!(pz)
                    pz_is_val(pz) && return true
                    ascending = false
                else
                    pz_ascend_byte!(pz)
                    pz_at_root(pz) && return false
                end
            end
        end
    end
end

# =====================================================================
# Exports
# =====================================================================

export ProductZipper
export pz_factor_count, pz_focus_factor
export pz_at_root, pz_path, pz_is_val, pz_val, pz_path_exists
export pz_child_mask, pz_child_count, pz_val_count
export pz_reset!, pz_descend_to!, pz_descend_to_byte!, pz_descend_indexed_byte!
export pz_descend_first_byte!, pz_descend_until!, pz_descend_to_existing!
export pz_ascend!, pz_ascend_byte!, pz_ascend_until!, pz_ascend_until_branch!
export pz_to_next_sibling_byte!, pz_to_prev_sibling_byte!, pz_to_next_val!
export pz_descend_to_existing_byte!, pz_descend_to_check!
export pz_descend_first_k_path!, pz_to_next_k_path!
