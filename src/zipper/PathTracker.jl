"""
PathTracker — port of `~/dev-zone/PathMap/src/path_tracker.rs` @ f477a91 (upstream 452f876, 99d4f87).

Wrapper that gives `ZipperPath` (a contiguous `path`) to any zipper that only implements `ZipperMoving`.

The "blind" zipper pattern lets nested virtual zippers compose without each layer copying paths; a
`PathTracker` reinstates a path buffer at whichever layer actually needs one. Movements that report to an
observer are handed `(tracker.path, obs)` — the tuple observer — so the wrapped zipper keeps its own native
implementation and fans its movement out to this buffer AND to the caller's observer.

    m = PathMap{UnitVal}(); set_val_at!(m, b"hello", UNIT_VAL)
    t = PathTracker(read_zipper(m))
    descend_to_existing!(t, b"hello")   # 5
    path(t)                            # b"hello"
"""
mutable struct PathTracker{Z <: AbstractZipper} <: AbstractZipper
    zipper::Z
    path::Vector{UInt8}
    origin_len::Int
end

"`PathTracker(z)` — track the path from `z`'s root (path_tracker.rs:33)."
function PathTracker(zipper::Z) where {Z <: AbstractZipper}
    reset!(zipper)
    PathTracker{Z}(zipper, UInt8[], 0)
end

"`PathTracker(z, origin)` — as above, with `origin` as the zipper's `root_prefix_path` (path_tracker.rs:43)."
function PathTracker(zipper::Z, origin::AbstractVector{UInt8}) where {Z <: AbstractZipper}
    reset!(zipper)
    PathTracker{Z}(zipper, collect(UInt8, origin), length(origin))
end

# ── Zipper (path_tracker.rs:53-58) ───────────────────────────────────────────────────────────────────────
@inline path_exists(t::PathTracker) = path_exists(t.zipper)
@inline is_val(t::PathTracker) = is_val(t.zipper)
@inline child_count(t::PathTracker) = child_count(t.zipper)
@inline child_mask(t::PathTracker) = child_mask(t.zipper)

# ── ZipperMoving (path_tracker.rs:60-155) ────────────────────────────────────────────────────────────────
@inline depth(t::PathTracker) = length(t.path) - t.origin_len
@inline at_root(t::PathTracker) = at_root(t.zipper)
@inline focus_byte(t::PathTracker) =
    length(t.path) > t.origin_len ? @inbounds(t.path[end]) : nothing
val_count(t::PathTracker) = val_count(t.zipper)

function reset!(t::PathTracker)
    reset!(t.zipper)
    resize!(t.path, t.origin_len)
    nothing
end

function descend_to!(t::PathTracker, k)
    append!(t.path, k)
    descend_to!(t.zipper, k)
    nothing
end

function descend_to_existing!(t::PathTracker, k)
    kv = k isa AbstractVector{UInt8} ? k : collect(UInt8, k)
    descended = descend_to_existing!(t.zipper, kv)
    append!(t.path, view(kv, 1:descended))
    descended
end

function descend_to_existing_byte!(t::PathTracker, b::UInt8)
    descend_to_existing_byte!(t.zipper, b) || return false
    push!(t.path, b)
    true
end

function descend_to_val!(t::PathTracker, k)
    kv = k isa AbstractVector{UInt8} ? k : collect(UInt8, k)
    descended = descend_to_val!(t.zipper, kv)
    append!(t.path, view(kv, 1:descended))
    descended
end

function descend_to_byte!(t::PathTracker, b::UInt8)
    push!(t.path, b)
    descend_to_byte!(t.zipper, b)
    nothing
end

function descend_indexed_byte!(t::PathTracker, child_idx::Int)::Union{Nothing, UInt8}
    byte = descend_indexed_byte!(t.zipper, child_idx)
    byte === nothing && return nothing
    push!(t.path, byte)
    byte
end

function descend_first_byte!(t::PathTracker)::Union{Nothing, UInt8}
    byte = descend_first_byte!(t.zipper)
    byte === nothing && return nothing
    push!(t.path, byte)
    byte
end

# Fan the descended bytes out to our own buffer as well as the caller's observer
descend_until_observed!(t::PathTracker, obs) = descend_until_observed!(t.zipper, (t.path, obs))

function ascend!(t::PathTracker, steps::Int)
    ascended = ascend!(t.zipper, steps)
    resize!(t.path, length(t.path) - ascended)
    ascended
end

function ascend_byte!(t::PathTracker)
    ascend_byte!(t.zipper) || return false
    pop!(t.path)
    true
end

function ascend_until!(t::PathTracker)
    ascended = ascend_until!(t.zipper)
    resize!(t.path, length(t.path) - ascended)
    ascended
end

function ascend_until_branch!(t::PathTracker)
    ascended = ascend_until_branch!(t.zipper)
    resize!(t.path, length(t.path) - ascended)
    ascended
end

to_next_step_observed!(t::PathTracker, obs) = to_next_step_observed!(t.zipper, (t.path, obs))

function to_next_sibling_byte!(t::PathTracker)::Union{Nothing, UInt8}
    byte = to_next_sibling_byte!(t.zipper)
    byte === nothing && return nothing
    isempty(t.path) && error("PathTracker: a sibling move with an empty path")
    t.path[end] = byte
    byte
end

function to_prev_sibling_byte!(t::PathTracker)::Union{Nothing, UInt8}
    byte = to_prev_sibling_byte!(t.zipper)
    byte === nothing && return nothing
    isempty(t.path) && error("PathTracker: a sibling move with an empty path")
    t.path[end] = byte
    byte
end

# ── ZipperIteration (path_tracker.rs:158-173): delegate, so the wrapped zipper keeps its native walk ─────
to_next_val_observed!(t::PathTracker, obs) = to_next_val_observed!(t.zipper, (t.path, obs))
descend_last_path_observed!(t::PathTracker, obs) = descend_last_path_observed!(t.zipper, (t.path, obs))
descend_first_k_path_observed!(t::PathTracker, k::Int, obs) =
    descend_first_k_path_observed!(t.zipper, k, (t.path, obs))
to_next_k_path_observed!(t::PathTracker, k::Int, obs) =
    to_next_k_path_observed!(t.zipper, k, (t.path, obs))

# ── ZipperPath / ZipperAbsolutePath / values (path_tracker.rs:175-197) ──────────────────────────────────
path(t::PathTracker) = view(t.path, (t.origin_len + 1):length(t.path))
origin_path(t::PathTracker) = t.path
root_prefix_path(t::PathTracker) = view(t.path, 1:t.origin_len)

val(t::PathTracker) = val(t.zipper)
val_at(t::PathTracker, p) = val_at(t.zipper, p)
get_val(t::PathTracker) = get_val(t.zipper)
get_val_at(t::PathTracker, p) = get_val_at(t.zipper, p)

export PathTracker
