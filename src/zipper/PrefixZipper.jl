"""
PrefixZipper — port of `pathmap/src/prefix_zipper.rs`.

Wraps a source zipper and prepends an arbitrary byte-string prefix to its
path space.  Navigation through the prefix portion is virtual (just advancing
an index); navigation beyond the prefix delegates to the source zipper.

Julia translation notes:
  - Rust lifetime `'prefix` → Julia owns the prefix bytes (no borrow needed).
  - `Cow<'prefix, [u8]>` → `Vector{UInt8}` (always owned in Julia).
  - `prepare_buffers` ensures `path` starts with `prefix[1:origin_depth]`.
"""

# =====================================================================
# PrefixPos — cursor position relative to the prefix
# =====================================================================

"""
    PrefixPos

Tracks whether the cursor is inside the prefix, off the prefix (invalid
path), or in the source zipper.  Mirrors `PrefixPos` in prefix_zipper.rs.
"""
@enum PrefixPosTag begin
    PREFIX_POS_PREFIX = 1   # valid bytes into prefix
    PREFIX_POS_OFF = 2   # descended off prefix (invalid path)
    PREFIX_POS_SOURCE = 3   # prefix fully traversed; cursor in source
end

struct PrefixPos
    tag::PrefixPosTag
    valid::Int   # bytes matched in prefix (Prefix / PrefixOff)
    invalid::Int   # bytes beyond valid prefix (PrefixOff only)
end

PrefixPos_prefix(valid::Int) = PrefixPos(PREFIX_POS_PREFIX, valid, 0)
PrefixPos_off(v::Int, i::Int) = PrefixPos(PREFIX_POS_OFF, v, i)
PrefixPos_source() = PrefixPos(PREFIX_POS_SOURCE, 0, 0)

_pos_is_invalid(p::PrefixPos) = p.tag == PREFIX_POS_OFF
_pos_is_source(p::PrefixPos) = p.tag == PREFIX_POS_SOURCE

function _pos_prefixed_depth(p::PrefixPos)
    p.tag == PREFIX_POS_PREFIX && return p.valid
    p.tag == PREFIX_POS_OFF && return p.valid + p.invalid
    nothing   # Source
end

# =====================================================================
# PrefixZipper struct
# =====================================================================

"""
    PrefixZipper{Z}

Wraps source zipper `Z` and prepends `prefix` bytes to its path space.
Mirrors `PrefixZipper<'prefix, Z>`.
"""
mutable struct PrefixZipper{Z}
    path::Vector{UInt8}   # full absolute path (origin_depth prefix + relative)
    source::Z
    prefix::Vector{UInt8}   # the full prefix bytes
    origin_depth::Int             # bytes of prefix that belong to the root prefix path
    position::PrefixPos
end

"""
    PrefixZipper(prefix, source) → PrefixZipper

Create a `PrefixZipper` wrapping `source` with the given `prefix`.
Mirrors `PrefixZipper::new`.
"""
function PrefixZipper(prefix, source::Z) where {Z}
    pv = collect(UInt8, prefix)
    zipper_reset!(source)
    pos = isempty(pv) ? PrefixPos_source() : PrefixPos_prefix(0)
    PrefixZipper{Z}(UInt8[], source, pv, 0, pos)
end

# =====================================================================
# Internal helpers
# =====================================================================

"""
Ensure path buffer starts with prefix[1:origin_depth].
"""
function _pz_prepare_buffers!(pz::PrefixZipper)
    if length(pz.path) < pz.origin_depth
        resize!(pz.path, pz.origin_depth)
        copyto!(pz.path, 1, pz.prefix, 1, pz.origin_depth)
    end
end

"""
Set position to Prefix{valid} or Source if valid == prefix_len - origin_depth.
"""
function _pz_set_valid!(pz::PrefixZipper, valid::Int)
    @assert valid <= length(pz.prefix) - pz.origin_depth
    if valid == length(pz.prefix) - pz.origin_depth
        pz.position = PrefixPos_source()
    else
        pz.position = PrefixPos_prefix(valid)
    end
end

"""
Ascend `steps` bytes.  Returns number of bytes NOT ascended (0 = fully ascended).
Mirrors `ascend_n`.
"""
function _pz_ascend_n!(pz::PrefixZipper, steps::Int)::Int
    # Case: PrefixOff → reduce invalid, then valid
    if _pos_is_invalid(pz.position)
        valid = pz.position.valid
        invalid = pz.position.invalid
        if invalid > steps
            pz.position = PrefixPos_off(valid, invalid - steps)
            return 0
        end
        steps -= invalid
        v = max(0, valid - steps)
        _pz_set_valid!(pz, v)
        remaining = steps - valid
        return remaining > 0 ? remaining : 0
    end

    # Case: Source → try to ascend in source, then fall back to Prefix
    if _pos_is_source(pz.position)
        len_before = length(zipper_path(pz.source))
        if zipper_ascend!(pz.source, steps)
            return 0
        end
        len_after = length(zipper_path(pz.source))
        steps -= (len_before - len_after)
        pz.position = PrefixPos_prefix(length(pz.prefix) - pz.origin_depth)
    end

    # Case: Prefix → ascend within prefix
    if pz.position.tag == PREFIX_POS_PREFIX
        valid = pz.position.valid
        v = max(0, valid - steps)
        _pz_set_valid!(pz, v)
        remaining = steps - valid
        return remaining > 0 ? remaining : 0
    end

    return steps
end

"""
Internal ascend_until.  `VAL=true` → stop at val; `VAL=false` → stop at branch.
Returns number of bytes ascended, or `nothing` if already at root.
Mirrors `ascend_until_n`.
"""
function _pz_ascend_until_n!(pz::PrefixZipper, val::Bool)::Union{Nothing, Int}
    pz_at_root(pz) && return nothing
    ascended = 0

    if _pos_is_source(pz.position)
        len_before = length(zipper_path(pz.source))
        good =
            val ? zipper_ascend_until!(pz.source) : zipper_ascend_until_branch!(pz.source)
        if good && ((val && zipper_is_val(pz.source)) || zipper_child_count(pz.source) > 1)
            len_after = length(zipper_path(pz.source))
            return len_before - len_after
        end
        ascended += len_before
        pz.position = PrefixPos_prefix(length(pz.prefix) - pz.origin_depth)
    end

    depth = _pos_prefixed_depth(pz.position)
    if depth === nothing

        return nothing
    end
    ascended += depth
    _pz_set_valid!(pz, 0)
    ascended
end

# =====================================================================
# Zipper interface
# =====================================================================

function pz_path_exists(pz::PrefixZipper)
    pz.position.tag == PREFIX_POS_PREFIX && return true
    _pos_is_invalid(pz.position) && return false
    zipper_path_exists(pz.source)
end

function pz_is_val(pz::PrefixZipper)
    _pos_is_source(pz.position) || return false
    zipper_is_val(pz.source)
end

function pz_child_mask(pz::PrefixZipper)
    if pz.position.tag == PREFIX_POS_PREFIX
        byte = pz.prefix[pz.origin_depth + pz.position.valid + 1]
        return ByteMask(byte)
    end
    _pos_is_invalid(pz.position) && return ByteMask()
    zipper_child_mask(pz.source)
end

function pz_child_count(pz::PrefixZipper)
    pz.position.tag == PREFIX_POS_PREFIX && return 1
    _pos_is_invalid(pz.position) && return 0
    zipper_child_count(pz.source)
end

pz_path(pz::PrefixZipper) = view(pz.path, (pz.origin_depth + 1):length(pz.path))

pz_val_count(pz::PrefixZipper) = zipper_val_count(pz.source)

# ── adjust_lookup_path — upstream prefix_zipper.rs:191-203, VERBATIM shape.
#     Source            => Some(path)                       (cursor already inside the source)
#     Prefix { valid }  => path must START WITH the unconsumed tail of the prefix; strip it
#     PrefixOff { .. }  => None                             (focus is off the prefix; nothing below)
function _pz_adjust_lookup_path(pz::PrefixZipper, path::AbstractVector{UInt8})
    pos = pz.position
    _pos_is_source(pos) && return path
    if pos.tag == PREFIX_POS_PREFIX
        rest = view(pz.prefix, (pz.origin_depth + pos.valid + 1):length(pz.prefix))
        length(path) >= length(rest) || return nothing        # upstream: !starts_with -> None
        for i in eachindex(rest)
            path[i] == rest[i] || return nothing
        end
        return view(path, (length(rest) + 1):length(path))
    end
    nothing                                                    # PREFIX_POS_OFF
end

# ── val_at — upstream prefix_zipper.rs:245-248
pz_val_at(pz::PrefixZipper, path::AbstractVector{UInt8}) =
    (
        a=_pz_adjust_lookup_path(pz, path);
        a === nothing ? nothing : zipper_val_at(pz.source, a)
    )

function pz_at_root(pz::PrefixZipper)
    if pz.position.tag == PREFIX_POS_PREFIX
        return pz.position.valid == 0
    end
    _pos_is_invalid(pz.position) && return false
    length(pz.prefix) <= pz.origin_depth && zipper_at_root(pz.source)
end

# =====================================================================
# ZipperMoving
# =====================================================================

function pz_reset!(pz::PrefixZipper)
    _pz_prepare_buffers!(pz)
    resize!(pz.path, pz.origin_depth)
    zipper_reset!(pz.source)
    _pz_set_valid!(pz, 0)
end

function pz_descend_to_existing!(pz::PrefixZipper, path)
    _pos_is_invalid(pz.position) && return 0
    bytes_in = collect(UInt8, path)
    pv = bytes_in
    descended = 0

    if pz.position.tag == PREFIX_POS_PREFIX
        valid = pz.position.valid
        rest_prefix = view(pz.prefix, (pz.origin_depth + valid + 1):length(pz.prefix))
        overlap = find_prefix_overlap(rest_prefix, pv)
        pv = pv[(overlap + 1):end]
        _pz_set_valid!(pz, valid + overlap)
        descended += overlap
    end

    if _pos_is_source(pz.position)
        n = zipper_descend_to_existing!(pz.source, pv)
        descended += n
    end

    append!(pz.path, bytes_in[1:descended])
    descended
end

function pz_descend_to!(pz::PrefixZipper, path)
    pv = collect(UInt8, path)
    existing = pz_descend_to_existing!(pz, pv)
    rem = pv[(existing + 1):end]
    isempty(rem) && return nothing

    append!(pz.path, rem)
    if pz.position.tag == PREFIX_POS_PREFIX
        pz.position = PrefixPos_off(pz.position.valid, length(rem))
    elseif _pos_is_invalid(pz.position)
        pz.position = PrefixPos_off(pz.position.valid, pz.position.invalid + length(rem))
    else
        zipper_descend_to!(pz.source, rem)
    end
end

pz_descend_to_byte!(pz::PrefixZipper, k::UInt8) = pz_descend_to!(pz, UInt8[k])

function pz_descend_indexed_byte!(pz::PrefixZipper, idx::Int)
    mask = pz_child_mask(pz)
    byte = indexed_bit(mask, idx, true)
    byte === nothing && return false
    pz_descend_to_byte!(pz, byte)
    true
end

pz_descend_first_byte!(pz::PrefixZipper) = pz_descend_indexed_byte!(pz, 0)

function pz_descend_until!(pz::PrefixZipper)
    _pos_is_invalid(pz.position) && return false
    # Jump through remaining prefix bytes.
    # CONSUMING THE PREFIX REMAINDER IS ITSELF A MOVEMENT, so it must be reflected in the return
    # value even when the source zipper cannot descend any further — otherwise a caller that loops
    # `while descend_until()` stops one step early and never sees the prefixed position.
    # Upstream `c3fc955`, prefix_zipper.rs:437.
    descended_prefix = false
    if !_pos_is_source(pz.position)
        depth = _pos_prefixed_depth(pz.position)::Int
        rem = view(pz.prefix, (pz.origin_depth + depth + 1):length(pz.prefix))
        append!(pz.path, rem)
        pz.position = PrefixPos_source()
        descended_prefix = true
    end
    len_before = length(zipper_path(pz.source))
    zipper_descend_until!(pz.source) || return descended_prefix
    sp = zipper_path(pz.source)
    append!(pz.path, sp[(len_before + 1):end])
    true
end

function pz_ascend!(pz::PrefixZipper, steps::Int=1)
    remaining = _pz_ascend_n!(pz, steps)
    ascended = steps - remaining
    resize!(pz.path, length(pz.path) - ascended)
    remaining == 0
end

pz_ascend_byte!(pz::PrefixZipper) = pz_ascend!(pz, 1)

function pz_ascend_until!(pz::PrefixZipper)
    n = _pz_ascend_until_n!(pz, true)
    n === nothing && return false
    resize!(pz.path, length(pz.path) - n)
    true
end

function pz_ascend_until_branch!(pz::PrefixZipper)
    n = _pz_ascend_until_n!(pz, false)
    n === nothing && return false
    resize!(pz.path, length(pz.path) - n)
    true
end

function pz_to_next_sibling_byte!(pz::PrefixZipper)
    _pos_is_source(pz.position) || return false
    zipper_to_next_sibling_byte!(pz.source) || return false
    byte = last(zipper_path(pz.source))
    pz.path[end] = byte
    true
end

function pz_to_prev_sibling_byte!(pz::PrefixZipper)
    _pos_is_source(pz.position) || return false
    zipper_to_prev_sibling_byte!(pz.source) || return false
    byte = last(zipper_path(pz.source))
    pz.path[end] = byte
    true
end

# ZipperIteration default impl — mirrors the Rust default in zipper.rs
function pz_to_next_val!(pz::PrefixZipper)
    iters = 0
    while true
        iters += 1
        if iters > 200_000
            @warn "pz_to_next_val! hit iteration cap (200k); returning false. This indicates a likely infinite loop in PrefixZipper DFS." maxlog=1
            return false
        end
        if pz_descend_first_byte!(pz)
            pz_is_val(pz) && return true
            pz_descend_until!(pz) && pz_is_val(pz) && return true
        else
            ascending = true
            while ascending
                if pz_to_next_sibling_byte!(pz)
                    pz_is_val(pz) && return true
                    ascending = false
                else
                    pz_ascend_byte!(pz) || return false
                    pz_at_root(pz) && return false
                end
            end
        end
    end
end

# =====================================================================
# ZipperAbsolutePath
# =====================================================================

pz_origin_path(pz::PrefixZipper) = pz.path
pz_root_prefix_path(pz::PrefixZipper) = view(pz.path, 1:pz.origin_depth)

"""
    pz_prefix_path_below_focus(pz) → Union{Nothing, Vector{UInt8}}

Remaining prefix bytes from the current cursor, or `nothing` if off-prefix.
Mirrors `prefix_path_below_focus`.
"""
function pz_prefix_path_below_focus(pz::PrefixZipper)
    pz.position.tag == PREFIX_POS_PREFIX &&
        return view(pz.prefix, (pz.origin_depth + pz.position.valid + 1):length(pz.prefix))
    _pos_is_source(pz.position) && return UInt8[]
    nothing
end

# =====================================================================
# Exports
# =====================================================================

export PrefixZipper, PrefixPosTag, PrefixPos
export pz_path_exists, pz_is_val, pz_child_mask, pz_child_count
export pz_path, pz_val_count, pz_val_at, pz_at_root
export pz_reset!, pz_descend_to!, pz_descend_to_byte!, pz_descend_indexed_byte!
export pz_descend_first_byte!, pz_descend_until!, pz_descend_to_existing!
export pz_ascend!, pz_ascend_byte!, pz_ascend_until!, pz_ascend_until_branch!
export pz_to_next_sibling_byte!, pz_to_prev_sibling_byte!, pz_to_next_val!
export pz_origin_path, pz_root_prefix_path, pz_prefix_path_below_focus
