"""
OverlayZipper — port of `pathmap/src/overlay_zipper.rs` (upstream 0.4.0 @ f477a91).

A virtual zipper that fuses two underlying zippers (A and B) into one
virtual trie whose paths are the union of A and B.  A `mapping` function
combines values from A and B at each position.

Julia translation notes:
  - Rust generic `Mapping: for<'a> Fn(Option<&'a AV>, Option<&'a BV>) -> Option<&'a OutV>`
    becomes a Julia `Function` field (no HRTB needed; GC handles lifetimes).
  - `a` and `b` may be any `AbstractZipper`; they are driven through the generic trait functions
    (`descend_to!`, `ascend!`, `path`, …) from `ZipperTraits.jl`.
  - Upstream implements `Zipper`, `ZipperValues`, `ZipperValuesAt`, `ZipperMoving`, `ZipperPath` and an
    empty `ZipperIteration` (overlay_zipper.rs:388-394), so all iteration methods — and every
    `ZipperMoving` method not listed below — use the `AbstractZipper` defaults.
  - `val_count()` is unimplemented upstream (`todo!()`, overlay_zipper.rs:172); see below.
"""

# =====================================================================
# OverlayZipper struct
# =====================================================================

"""
    OverlayZipper{VA, VB, VOut, ZA, ZB}

Virtual zipper over the union of two source tries.
Mirrors `OverlayZipper<AV, BV, OutV, AZipper, BZipper, Mapping>`.
"""
mutable struct OverlayZipper{VA, VB, VOut, ZA, ZB} <: AbstractZipper
    a::ZA                   # zipper over trie A
    b::ZB                   # zipper over trie B
    mapping::Function             # (Union{Nothing,VA}, Union{Nothing,VB}) → Union{Nothing,VOut}
end

"""
    OverlayZipper(a, b) → OverlayZipper

Default mapping: A-value takes priority over B-value.
Mirrors `OverlayZipper::new` (overlay_zipper.rs:46).
"""
function OverlayZipper(a::ZA, b::ZB) where {ZA, ZB}
    reset!(a)
    reset!(b)
    VA = _overlay_val_type(ZA)
    VB = _overlay_val_type(ZB)
    OverlayZipper{VA, VB, VA, ZA, ZB}(a, b, (av, bv) -> av !== nothing ? av : bv)
end

"""
    OverlayZipper(a, b, mapping) → OverlayZipper

Custom mapping function.  Mirrors `OverlayZipper::with_mapping` (overlay_zipper.rs:59).
"""
function OverlayZipper(a::ZA, b::ZB, mapping::Function) where {ZA, ZB}
    reset!(a)
    reset!(b)
    VA = _overlay_val_type(ZA)
    VB = _overlay_val_type(ZB)
    VOut = VA   # best-effort; Julia can't infer return type from Function
    OverlayZipper{VA, VB, VOut, ZA, ZB}(a, b, mapping)
end

# Helper to extract value type parameter from ReadZipperCore{V,A}
_overlay_val_type(::Type{ReadZipperCore{V, A}}) where {V, A} = V
_overlay_val_type(::Type{T}) where {T} = Any

# =====================================================================
# ZipperValues / ZipperValuesAt (overlay_zipper.rs:95-117)
# =====================================================================

"""
Value at the overlay cursor — the mapping function decides.
"""
val(oz::OverlayZipper) = oz.mapping(val(oz.a), val(oz.b))

val_at(oz::OverlayZipper, p) = oz.mapping(val_at(oz.a, p), val_at(oz.b, p))

# =====================================================================
# Zipper (overlay_zipper.rs:119-140)
# =====================================================================

path_exists(oz::OverlayZipper) = path_exists(oz.a) || path_exists(oz.b)

# NOTE (overlay_zipper.rs:130): the mapping function can nullify a value, so this is `val() !== nothing`
# and NOT `is_val(a) || is_val(b)`.
is_val(oz::OverlayZipper) = val(oz) !== nothing

"""
Union of both child masks.
"""
child_mask(oz::OverlayZipper) = child_mask(oz.a) | child_mask(oz.b)

child_count(oz::OverlayZipper) = count_bits(child_mask(oz))

# =====================================================================
# ZipperMoving (overlay_zipper.rs:142-374)
# =====================================================================

# Both sources are kept in lock-step, so A's depth/focus byte is the overlay's (upstream debug-asserts
# that B agrees; overlay_zipper.rs:149-165).
depth(oz::OverlayZipper) = depth(oz.a)
focus_byte(oz::OverlayZipper) = focus_byte(oz.a)

at_root(oz::OverlayZipper) = at_root(oz.a) || at_root(oz.b)

function reset!(oz::OverlayZipper)
    reset!(oz.a)
    reset!(oz.b)
    nothing
end

"""
    val_count(oz) → Int

Count vals reachable from the cursor in the **union** of the two underlying
subtries (A wins at overlapping keys). Upstream's `OverlayZipper::val_count`
is `todo!()` (overlay_zipper.rs:172); PRIMUS substrate ledger lists this as
deferred. There are no in-tree callers today.

A previous implementation silently returned 0 — a silent-zero footgun for
any future caller using val_count to size or check emptiness. This warns
once-per-process so misuse is loud rather than hidden.
"""
function val_count(::OverlayZipper)
    @warn "val_count(::OverlayZipper) is a substrate-deferred stub returning 0 (upstream is todo!()); see MORK_PATHMAP_SUBSTRATE_LEDGER.md. If you actually need the union-cardinality, file an issue." maxlog=1
    0
end

function descend_to!(oz::OverlayZipper, p)
    descend_to!(oz.a, p)
    descend_to!(oz.b, p)
    nothing
end

function descend_to_byte!(oz::OverlayZipper, k::UInt8)
    descend_to_byte!(oz.a, k)
    descend_to_byte!(oz.b, k)
    nothing
end

# overlay_zipper.rs:182-195 — whichever source got further sets the shared position
function descend_to_existing!(oz::OverlayZipper, p)
    pv = p isa AbstractVector{UInt8} ? p : collect(UInt8, p)
    depth_a = descend_to_existing!(oz.a, pv)
    depth_b = descend_to_existing!(oz.b, pv)
    if depth_a > depth_b
        descend_to!(oz.b, view(pv, (depth_b + 1):depth_a))
        depth_a
    elseif depth_b > depth_a
        descend_to!(oz.a, view(pv, (depth_a + 1):depth_b))
        depth_b
    else
        depth_a
    end
end

# overlay_zipper.rs:197-220 — the shallower source wins only when it actually stopped ON a value
function descend_to_val!(oz::OverlayZipper, p)
    pv = p isa AbstractVector{UInt8} ? p : collect(UInt8, p)
    depth_a = descend_to_val!(oz.a, pv)
    depth_b = descend_to_val!(oz.b, pv)
    if depth_a < depth_b
        if is_val(oz.a)
            ascend!(oz.b, depth_b - depth_a)
            depth_a
        else
            descend_to!(oz.a, view(pv, (depth_a + 1):depth_b))
            depth_b
        end
    elseif depth_b < depth_a
        if is_val(oz.b)
            ascend!(oz.a, depth_a - depth_b)
            depth_b
        else
            # 🔴 UPSTREAM SAYS `self.a.descend_to(..)` HERE (overlay_zipper.rs:214) — a copy-paste of
            # the mirrored branch. `a` is ALREADY at `depth_a` in this branch, so descending it again
            # would push it past the key and leave `b` behind at `depth_b`, desynchronising the pair
            # (every later method assumes `path(a) == path(b)`). It is `b` that has to catch up.
            descend_to!(oz.b, view(pv, (depth_b + 1):depth_a))
            depth_a
        end
    else
        depth_a
    end
end

"""
The chunk size used by `descend_until_observed!` (overlay_zipper.rs:243).
"""
const OVERLAY_DESCEND_CHUNK = 48

"""
Descend until branch or val in both zippers, keeping them synchronized.
Mirrors `OverlayZipper::descend_until_observed` (overlay_zipper.rs:238-315).

Descending happens in buffer-sized chunks, so neither source can outrun what we're able to capture.
As long as both sources fill a whole chunk and agree on every byte of it, the chunk is committed and
we go around again.  Any other outcome ends the descent and is settled by the case analysis below.
"""
function descend_until_observed!(oz::OverlayZipper, obs)
    path_a = UInt8[]
    path_b = UInt8[]
    sizehint!(path_a, OVERLAY_DESCEND_CHUNK)
    sizehint!(path_b, OVERLAY_DESCEND_CHUNK)

    # Total bytes committed to `obs` across all completed chunks
    committed = 0

    while true
        empty!(path_a)
        empty!(path_b)
        desc_a = descend_until_max_bytes_observed!(oz.a, OVERLAY_DESCEND_CHUNK, path_a)
        desc_b = descend_until_max_bytes_observed!(oz.b, OVERLAY_DESCEND_CHUNK, path_b)

        if !desc_a && !desc_b
            break
        end
        if !desc_a && desc_b
            if child_count(oz.a) == 0
                descend_to!(oz.a, path_b)
                descend_to!(obs, path_b)
                committed += length(path_b)
            else
                ascend!(oz.b, length(path_b))
            end
            break
        end
        if desc_a && !desc_b
            if child_count(oz.b) == 0
                descend_to!(oz.b, path_a)
                descend_to!(obs, path_a)
                committed += length(path_a)
            else
                ascend!(oz.a, length(path_a))
            end
            break
        end

        # Both moved.  Keep the portion they agree on and rewind the rest
        overlap = find_prefix_overlap(path_a, path_b)
        if length(path_a) > overlap
            ascend!(oz.a, length(path_a) - overlap)
        end
        if length(path_b) > overlap
            ascend!(oz.b, length(path_b) - overlap)
        end
        # Both sources now sit at the same position: the agreed-upon prefix
        if overlap > 0
            descend_to!(obs, view(path_a, 1:overlap))
            committed += overlap
        end

        # Only a full chunk that both sources agreed on end-to-end can be continued.  Anything
        # shorter means at least one source stopped on its own, so the descent is complete.
        if overlap < OVERLAY_DESCEND_CHUNK ||
           length(path_a) != OVERLAY_DESCEND_CHUNK ||
           length(path_b) != OVERLAY_DESCEND_CHUNK
            break
        end
    end

    committed > 0
end

# overlay_zipper.rs:317-323 — both sources move together, so they must report the same distance
function ascend!(oz::OverlayZipper, steps::Int)::Int
    a = ascend!(oz.a, steps)
    b = ascend!(oz.b, steps)
    max(a, b)
end

# overlay_zipper.rs:329-348
function ascend_until!(oz::OverlayZipper)::Int
    start_depth = length(path(oz.a))
    asc_a = ascend_until!(oz.a)
    depth_a = length(path(oz.a))
    asc_b = ascend_until!(oz.b)
    path_b = path(oz.b)
    depth_b = length(path_b)
    if asc_a == 0 && asc_b == 0
        return 0
    end
    # Whichever source ascended further sets the shared position; the other descends to match
    if depth_b > depth_a
        descend_to!(oz.a, view(path_b, (depth_a + 1):depth_b))
    elseif depth_a > depth_b
        descend_to!(oz.b, view(path(oz.a), (depth_b + 1):depth_a))
    end
    start_depth - length(path(oz.a))
end

# overlay_zipper.rs:350-365
function ascend_until_branch!(oz::OverlayZipper)::Int
    start_depth = length(path(oz.a))
    ascend_until_branch!(oz.a)
    depth_a = length(path(oz.a))
    ascend_until_branch!(oz.b)
    path_b = path(oz.b)
    depth_b = length(path_b)
    # Whichever source ascended further sets the shared position; the other descends to match
    if depth_b > depth_a
        descend_to!(oz.a, view(path_b, (depth_a + 1):depth_b))
    elseif depth_a > depth_b
        descend_to!(oz.b, view(path(oz.a), (depth_b + 1):depth_a))
    end
    start_depth - length(path(oz.a))
end

# overlay_zipper.rs:77-92 — note the focus is put back on `last` when there is no sibling
function _oz_to_sibling!(oz::OverlayZipper, next::Bool)::Union{Nothing, UInt8}
    last = focus_byte(oz)
    last === nothing && return nothing
    ascend!(oz, 1)
    mask = child_mask(oz)
    maybe_child = next ? next_bit(mask, last) : prev_bit(mask, last)
    if maybe_child === nothing
        descend_to_byte!(oz, last)
        return nothing
    end
    descend_to_byte!(oz, maybe_child)
    maybe_child
end

to_next_sibling_byte!(oz::OverlayZipper)::Union{Nothing, UInt8} = _oz_to_sibling!(oz, true)
to_prev_sibling_byte!(oz::OverlayZipper)::Union{Nothing, UInt8} = _oz_to_sibling!(oz, false)

# =====================================================================
# ZipperPath (overlay_zipper.rs:376-386)
# =====================================================================

"""
Path — both zippers are kept in sync so A's path is canonical.
"""
path(oz::OverlayZipper) = path(oz.a)

# =====================================================================
# Exports
# =====================================================================

export OverlayZipper, OVERLAY_DESCEND_CHUNK
