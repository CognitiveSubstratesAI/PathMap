"""
PrefixZipper — port of `pathmap/src/prefix_zipper.rs` (upstream 0.4.0 @ f477a91).

Wraps a source zipper and prepends an arbitrary byte-string prefix to its
path space.  Navigation through the prefix portion is virtual (just advancing
an index); navigation beyond the prefix delegates to the source zipper.

Julia translation notes:
  - Rust lifetime `'prefix` → Julia owns the prefix bytes (no borrow needed).
  - `Cow<'prefix, [u8]>` → `Vector{UInt8}` (always owned in Julia).
  - `prepare_buffers` ensures `path` starts with `prefix[1:origin_depth]`.
  - The trait methods are methods of the generic functions in ZipperTraits.jl; the source zipper is
    driven through those same generics, so any `AbstractZipper` can be wrapped.
  - 0.4.0 threads a `PathObserver` through the moving/iteration methods (99d4f87): the prefix bytes
    this zipper contributes are reported to the caller's observer, and the source's movement is fanned
    out to `pz.path` (which is itself an observer) and the caller's observer via a 2-tuple.
"""

# =====================================================================
# PrefixPos — cursor position relative to the prefix
# =====================================================================

"""
    PrefixPos

Tracks whether the cursor is inside the prefix, off the prefix (invalid
path), or in the source zipper.  Mirrors `PrefixPos` (prefix_zipper.rs:10-37).
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
Mirrors `PrefixZipper<'prefix, Z>` (prefix_zipper.rs:56-62).
"""
mutable struct PrefixZipper{Z} <: AbstractZipper
    path::Vector{UInt8}   # full absolute path (origin_depth prefix + relative)
    source::Z
    prefix::Vector{UInt8}   # the full prefix bytes
    origin_depth::Int             # bytes of prefix that belong to the root prefix path
    position::PrefixPos
end

"""
    PrefixZipper(prefix, source) → PrefixZipper

Create a `PrefixZipper` wrapping `source` with the given `prefix`.
Mirrors `PrefixZipper::new` (prefix_zipper.rs:70-87).
"""
function PrefixZipper(prefix, source::Z) where {Z}
    pv = collect(UInt8, prefix)
    reset!(source)
    pos = isempty(pv) ? PrefixPos_source() : PrefixPos_prefix(0)
    PrefixZipper{Z}(UInt8[], source, pv, 0, pos)
end

"""
    set_root_prefix_path!(pz, root_prefix_path)

Set the portion of the zipper's `prefix` to treat as the
[`root_prefix_path`](@ref); the rest of the prefix stays part of [`path`](@ref).
Resets the zipper.  Mirrors `PrefixZipper::set_root_prefix_path`
(prefix_zipper.rs:102-109); the Rust `Result` becomes a thrown `ArgumentError`.
"""
function set_root_prefix_path!(pz::PrefixZipper, root_prefix_path)
    rpp = root_prefix_path isa AbstractVector{UInt8} ? root_prefix_path :
        collect(UInt8, root_prefix_path)
    slice_starts_with(pz.prefix, rpp) ||
        throw(ArgumentError("zipper's prefix must begin with root_prefix_path"))
    pz.origin_depth = length(rpp)
    reset!(pz)
    nothing
end

# =====================================================================
# Internal helpers
# =====================================================================

"""
Ensure path buffer starts with prefix[1:origin_depth] (`prepare_buffers`, prefix_zipper.rs:309-314).
"""
function _pz_prepare_buffers!(pz::PrefixZipper)
    if length(pz.path) < pz.origin_depth
        resize!(pz.path, pz.origin_depth)
        copyto!(pz.path, 1, pz.prefix, 1, pz.origin_depth)
    end
end

"""
Set position to Prefix{valid} or Source if valid == prefix_len - origin_depth (`set_valid`,
prefix_zipper.rs:111-118).
"""
function _pz_set_valid!(pz::PrefixZipper, valid::Int)
    @assert valid <= length(pz.prefix) "valid prefix can't be outside prefix"
    if valid == length(pz.prefix) - pz.origin_depth
        pz.position = PrefixPos_source()
    else
        pz.position = PrefixPos_prefix(valid)
    end
end

"""
Descend over whatever remains of the `prefix`, leaving the focus at the source's root; returns
whether the focus moved.  The bytes are appended to our own path buffer AND reported to `obs`.
Mirrors `consume_prefix` (prefix_zipper.rs:124-135).
"""
function _pz_consume_prefix!(pz::PrefixZipper, obs)::Bool
    prefixed_depth = _pos_prefixed_depth(pz.position)
    prefixed_depth === nothing && return false      # already within the source
    prefix_rest = view(pz.prefix, (pz.origin_depth + prefixed_depth + 1):length(pz.prefix))
    append!(pz.path, prefix_rest)
    descend_to!(obs, prefix_rest)
    pz.position = PrefixPos_source()
    true
end

"""
Ascend `steps` bytes.  Returns number of bytes NOT ascended (0 = fully ascended).
Mirrors `ascend_n` (prefix_zipper.rs:137-171); upstream 0.4.0 takes the source's own
byte count instead of measuring its path before and after.
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
        _pz_set_valid!(pz, max(0, valid - steps))
        remaining = steps - valid
        return remaining > 0 ? remaining : 0
    end

    # Case: Source → try to ascend in source, then fall back to Prefix
    if _pos_is_source(pz.position)
        ascended = ascend!(pz.source, steps)
        ascended == steps && return 0
        steps -= ascended
        # Intermediate state: the position points one off, fixed up by the Prefix arm below
        pz.position = PrefixPos_prefix(length(pz.prefix) - pz.origin_depth)
    end

    # Case: Prefix → ascend within prefix
    if pz.position.tag == PREFIX_POS_PREFIX
        valid = pz.position.valid
        _pz_set_valid!(pz, max(0, valid - steps))
        remaining = steps - valid
        return remaining > 0 ? remaining : 0
    end

    steps
end

"""
Internal ascend_until.  `val=true` → stop at val; `val=false` → stop at branch.
Returns number of bytes ascended, or `nothing` if already at root.
Mirrors `ascend_until_n` (prefix_zipper.rs:172-197).
"""
function _pz_ascend_until_n!(pz::PrefixZipper, val::Bool)::Union{Nothing, Int}
    at_root(pz) && return nothing
    ascended = 0

    if _pos_is_source(pz.position)
        moved = val ? ascend_until!(pz.source) : ascend_until_branch!(pz.source)
        if moved > 0 && ((val && is_val(pz.source)) || child_count(pz.source) > 1)
            return moved
        end
        # Falling through here means the source ascended all the way to its own root, so the
        # distance it reports is the whole of the path it had descended
        ascended += moved
        pz.position = PrefixPos_prefix(length(pz.prefix) - pz.origin_depth)
    end

    d = _pos_prefixed_depth(pz.position)
    d === nothing && return nothing   # unreachable: we no longer point at the source
    ascended += d
    _pz_set_valid!(pz, 0)
    ascended
end

# ── adjust_lookup_path — upstream prefix_zipper.rs:203-215, VERBATIM shape.
#     Source            => Some(path)                       (cursor already inside the source)
#     Prefix { valid }  => path must START WITH the unconsumed tail of the prefix; strip it
#     PrefixOff { .. }  => None                             (focus is off the prefix; nothing below)
function _pz_adjust_lookup_path(pz::PrefixZipper, p::AbstractVector{UInt8})
    pos = pz.position
    _pos_is_source(pos) && return p
    if pos.tag == PREFIX_POS_PREFIX
        rest = view(pz.prefix, (pz.origin_depth + pos.valid + 1):length(pz.prefix))
        slice_starts_with(p, rest) || return nothing          # upstream: !starts_with -> None
        return view(p, (length(rest) + 1):length(p))
    end
    nothing                                                    # PREFIX_POS_OFF
end

"""
    prefix_path_below_focus(pz) → Union{Nothing, AbstractVector{UInt8}}

Remaining prefix bytes from the current cursor (empty once inside the source), or `nothing` if
off-prefix.  Mirrors `prefix_path_below_focus` (prefix_zipper.rs:220-226).
"""
function prefix_path_below_focus(pz::PrefixZipper)
    pz.position.tag == PREFIX_POS_PREFIX &&
        return view(pz.prefix, (pz.origin_depth + pz.position.valid + 1):length(pz.prefix))
    _pos_is_source(pz.position) && return UInt8[]
    nothing
end

# =====================================================================
# Zipper (prefix_zipper.rs:328-362)
# =====================================================================

function path_exists(pz::PrefixZipper)
    pz.position.tag == PREFIX_POS_PREFIX && return true
    _pos_is_invalid(pz.position) && return false
    path_exists(pz.source)
end

function is_val(pz::PrefixZipper)
    _pos_is_source(pz.position) || return false
    is_val(pz.source)
end

function child_count(pz::PrefixZipper)
    pz.position.tag == PREFIX_POS_PREFIX && return 1
    _pos_is_invalid(pz.position) && return 0
    child_count(pz.source)
end

function child_mask(pz::PrefixZipper)
    if pz.position.tag == PREFIX_POS_PREFIX
        byte = pz.prefix[pz.origin_depth + pz.position.valid + 1]
        return ByteMask(byte)
    end
    _pos_is_invalid(pz.position) && return ByteMask()
    child_mask(pz.source)
end

# ── ZipperConcrete (prefix_zipper.rs:229-245)
shared_node_id(pz::PrefixZipper) =
    _pos_is_source(pz.position) ? shared_node_id(pz.source) : nothing
is_shared(pz::PrefixZipper) = _pos_is_source(pz.position) ? is_shared(pz.source) : false

# ── ZipperValues / ZipperValuesAt / ZipperReadOnlyValues (prefix_zipper.rs:247-285)
val(pz::PrefixZipper) = _pos_is_source(pz.position) ? val(pz.source) : nothing
get_val(pz::PrefixZipper) = _pos_is_source(pz.position) ? get_val(pz.source) : nothing

function val_at(pz::PrefixZipper, p::AbstractVector{UInt8})
    a = _pz_adjust_lookup_path(pz, p)
    a === nothing ? nothing : val_at(pz.source, a)
end

function get_val_at(pz::PrefixZipper, p::AbstractVector{UInt8})
    a = _pz_adjust_lookup_path(pz, p)
    a === nothing ? nothing : get_val_at(pz.source, a)
end

# =====================================================================
# ZipperMoving (prefix_zipper.rs:364-515)
# =====================================================================

depth(pz::PrefixZipper) = length(pz.path) - pz.origin_depth

function at_root(pz::PrefixZipper)
    pz.position.tag == PREFIX_POS_PREFIX && return pz.position.valid == 0
    _pos_is_invalid(pz.position) && return false
    length(pz.prefix) <= pz.origin_depth && at_root(pz.source)
end

focus_byte(pz::PrefixZipper) = isempty(pz.path) ? nothing : @inbounds(pz.path[end])

function reset!(pz::PrefixZipper)
    _pz_prepare_buffers!(pz)
    resize!(pz.path, pz.origin_depth)
    reset!(pz.source)
    _pz_set_valid!(pz, 0)
    nothing
end

val_count(pz::PrefixZipper) = val_count(pz.source)

function descend_to_existing!(pz::PrefixZipper, k)
    _pos_is_invalid(pz.position) && return 0
    kv = k isa AbstractVector{UInt8} ? k : collect(UInt8, k)
    rest = view(kv, 1:length(kv))
    descended = 0

    if pz.position.tag == PREFIX_POS_PREFIX
        valid = pz.position.valid
        rest_prefix = view(pz.prefix, (pz.origin_depth + valid + 1):length(pz.prefix))
        overlap = find_prefix_overlap(rest_prefix, rest)
        rest = view(rest, (overlap + 1):length(rest))
        _pz_set_valid!(pz, valid + overlap)
        descended += overlap
    end

    if _pos_is_source(pz.position)
        descended += descend_to_existing!(pz.source, rest)
    end

    append!(pz.path, view(kv, 1:descended))
    descended
end

function descend_to!(pz::PrefixZipper, k)
    kv = k isa AbstractVector{UInt8} ? k : collect(UInt8, k)
    existing = descend_to_existing!(pz, kv)
    rem = view(kv, (existing + 1):length(kv))
    isempty(rem) && return nothing

    append!(pz.path, rem)
    if pz.position.tag == PREFIX_POS_PREFIX
        pz.position = PrefixPos_off(pz.position.valid, length(rem))
    elseif _pos_is_invalid(pz.position)
        pz.position = PrefixPos_off(pz.position.valid, pz.position.invalid + length(rem))
    else
        descend_to!(pz.source, rem)
    end
    nothing
end

# `descend_to_byte!`, `descend_indexed_byte!`, `descend_first_byte!`, `descend_last_byte!`,
# `descend_to_check!`, `descend_to_existing_byte!`, `ascend_byte!` and `to_next_step!` are upstream's
# trait defaults for this type (prefix_zipper.rs:439-455, 495-498) — see ZipperTraits.jl.

function descend_until_observed!(pz::PrefixZipper, obs)
    _pos_is_invalid(pz.position) && return false
    # Consuming the remainder of the prefix is itself a movement, so it must be reflected in the
    # return value even when the source zipper can't descend any further — otherwise a caller that
    # loops `while descend_until!(…)` stops one step early and never sees the prefixed position.
    # Upstream prefix_zipper.rs:457-466.
    descended_prefix = _pz_consume_prefix!(pz, obs)
    # Fan the descended bytes out to our own path buffer as well as the caller's observer
    src_moved = descend_until_observed!(pz.source, (pz.path, obs))
    descended_prefix | src_moved
end

function to_next_sibling_byte!(pz::PrefixZipper)::Union{Nothing, UInt8}
    _pos_is_source(pz.position) || return nothing
    byte = to_next_sibling_byte!(pz.source)
    byte === nothing && return nothing
    pz.path[end] = byte
    byte
end

function to_prev_sibling_byte!(pz::PrefixZipper)::Union{Nothing, UInt8}
    _pos_is_source(pz.position) || return nothing
    byte = to_prev_sibling_byte!(pz.source)
    byte === nothing && return nothing
    pz.path[end] = byte
    byte
end

function ascend!(pz::PrefixZipper, steps::Int)::Int
    remaining = _pz_ascend_n!(pz, steps)
    ascended = steps - remaining
    resize!(pz.path, length(pz.path) - ascended)
    ascended
end

function ascend_until!(pz::PrefixZipper)::Int
    n = _pz_ascend_until_n!(pz, true)
    n === nothing && return 0
    resize!(pz.path, length(pz.path) - n)
    n
end

function ascend_until_branch!(pz::PrefixZipper)::Int
    n = _pz_ascend_until_n!(pz, false)
    n === nothing && return 0
    resize!(pz.path, length(pz.path) - n)
    n
end

# =====================================================================
# ZipperPath / ZipperAbsolutePath (prefix_zipper.rs:517-536)
# =====================================================================

path(pz::PrefixZipper) = view(pz.path, (pz.origin_depth + 1):length(pz.path))
origin_path(pz::PrefixZipper) = pz.path
root_prefix_path(pz::PrefixZipper) = view(pz.path, 1:pz.origin_depth)

# =====================================================================
# ZipperIteration (prefix_zipper.rs:538-612)
# =====================================================================

function to_next_val_observed!(pz::PrefixZipper, obs)
    _pos_is_invalid(pz.position) && return false
    # Values only exist within the source, and the source's own root may hold one, so the prefix
    # is consumed without descending any further before handing off
    _pz_consume_prefix!(pz, obs)
    to_next_val_observed!(pz.source, (pz.path, obs))
end

function descend_last_path_observed!(pz::PrefixZipper, obs)
    _pos_is_invalid(pz.position) && return false
    # As in `descend_until!`, consuming the prefix is movement in its own right
    descended_prefix = _pz_consume_prefix!(pz, obs)
    src_moved = descend_last_path_observed!(pz.source, (pz.path, obs))
    descended_prefix | src_moved
end

function descend_first_k_path_observed!(pz::PrefixZipper, k::Int, obs)
    _pos_is_invalid(pz.position) && return false
    # The prefix is a single forced path, so the bytes it contributes always exist and never
    # branch.  Descend as much of `k` as the prefix covers, then ask the source for the rest.
    prefixed_depth = _pos_prefixed_depth(pz.position)
    prefix_rest = prefixed_depth === nothing ? 0 :
        length(pz.prefix) - pz.origin_depth - prefixed_depth
    if k <= prefix_rest
        taken = view(pz.prefix, (length(pz.path) + 1):(length(pz.path) + k))
        append!(pz.path, taken)
        descend_to!(obs, taken)
        _pz_set_valid!(pz, length(pz.path) - pz.origin_depth)
        return true
    end
    _pz_consume_prefix!(pz, obs)
    if descend_first_k_path_observed!(pz.source, k - prefix_rest, (pz.path, obs))
        true
    else
        ascend!(pz, prefix_rest)
        ascend!(obs, prefix_rest)
        false
    end
end

function to_next_k_path_observed!(pz::PrefixZipper, k::Int, obs)
    (_pos_is_invalid(pz.position) || depth(pz) < k) && return false
    # Only the portion of `k` inside the source can have alternatives to step to, so `k` is
    # clamped to the source's depth.  Iterating at the clamped depth visits exactly the same
    # positions, because the prefix above it is a single forced path.
    source_depth = depth(pz.source)
    source_depth == 0 && return false   # entirely within the prefix, which offers no alternatives
    clamped = min(k, source_depth)
    if to_next_k_path_observed!(pz.source, clamped, (pz.path, obs))
        true
    else
        # The source rewound to its root; ascend the rest of `k` back up through the prefix
        remaining = k - clamped
        if remaining > 0
            ascend!(pz, remaining)
            ascend!(obs, remaining)
        end
        false
    end
end

# `to_next_get_val_observed!` is the trait default built on `to_next_val_observed!`, which is
# implemented natively above, so it picks that up (prefix_zipper.rs:614-616).

# =====================================================================
# ZipperForking (prefix_zipper.rs:620-634)
# =====================================================================

"""
    fork_read_zipper(pz) → PrefixZipper

A new `PrefixZipper` over a fork of the source, rooted at the whole prefix again.
Mirrors `ZipperForking::fork_read_zipper`.  DEVIATION: upstream hardcodes `Prefix { valid: 0 }`,
which would index past the end of an EMPTY prefix in `child_mask`; we use the same rule as the
constructor (an empty prefix starts in the source).
"""
function fork_read_zipper(pz::PrefixZipper)
    src = fork_read_zipper(pz.source)
    pos = isempty(pz.prefix) ? PrefixPos_source() : PrefixPos_prefix(0)
    PrefixZipper{typeof(src)}(UInt8[], src, copy(pz.prefix), 0, pos)
end

# =====================================================================
# Exports
# =====================================================================

export PrefixZipper, PrefixPosTag, PrefixPos
export prefix_path_below_focus, set_root_prefix_path!
