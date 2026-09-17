"""
ZipperTraits — the upstream 0.4.0 zipper trait surface (`~/dev-zone/PathMap` src/zipper.rs:32-1245 @ f477a91).

One Julia generic function per upstream trait method, named as upstream plus `!` when it moves or mutates
(docs/ZIPPER_API_0.4.0_PORT_PLAN.md). A Rust trait is a set of generic functions here; a Rust default body is a
method on `AbstractZipper`; a zipper type implements a trait by adding methods for its own type.

| upstream trait            | functions |
|---------------------------|-----------|
| `Zipper`                  | `path_exists`, `is_val`, `child_count`, `child_mask` |
| `ZipperValues`            | `val` |
| `ZipperValuesAt`          | `val_at` |
| `ZipperMoving`            | `depth`, `at_root`, `focus_byte`, `reset!`, `val_count`, `descend_to!`, `descend_to_check!`, `descend_to_existing!`, `descend_to_val!`, `descend_to_byte!`, `descend_to_existing_byte!`, `descend_indexed_byte!`, `descend_first_byte!`, `descend_last_byte!`, `descend_until!`, `descend_until_observed!`, `descend_until_max_bytes!`, `descend_until_max_bytes_observed!`, `ascend!`, `ascend_byte!`, `ascend_until!`, `ascend_until_branch!`, `to_next_sibling_byte!`, `to_prev_sibling_byte!`, `to_next_step!`, `to_next_step_observed!` |
| `ZipperPath`              | `path`, `move_to_path!` |
| `ZipperIteration`         | `to_next_val!`, `to_next_val_observed!`, `descend_last_path!`, `descend_last_path_observed!`, `descend_first_k_path!`, `descend_first_k_path_observed!`, `to_next_k_path!`, `to_next_k_path_observed!` |
| `ZipperAbsolutePath`      | `origin_path`, `root_prefix_path` |
| `ZipperForking`           | `fork_read_zipper` |
| `ZipperConcrete`          | `shared_node_id`, `is_shared` |
| `ZipperReadOnlyValues`    | `get_val`, `get_val_at` |
| `ZipperReadOnlyIteration` | `to_next_get_val!`, `to_next_get_val_observed!` |
| `PathObserver`            | `descend_to!(obs, path)`, `descend_to_byte!(obs, byte)`, `ascend!(obs, steps)` |

Return shapes are upstream's: `Option<u8>` is `Union{Nothing, UInt8}`, `usize` counts are `Int`.
"""

"Supertype of every zipper; upstream default trait bodies are its methods."
abstract type AbstractZipper end

# ── Zipper (zipper.rs:33-55) ──────────────────────────────────────────────────────────────────────────────────
"`path_exists(z)` — is the focus on a path within the trie?"
function path_exists end
# `is_val` already exists (node payloads, nodes/TrieNode.jl); zipper methods join it: is there a value at the focus?
"`child_count(z)` — the number of child branches from the focus (0 at a leaf)."
function child_count end
"`child_mask(z)` — 256-bit mask of the children at the focus (empty at a leaf or a non-existent path)."
function child_mask end

# ── ZipperValues / ZipperValuesAt (zipper.rs:58-105) ─────────────────────────────────────────────────────────
"`val(z)` — the value at the focus, or `nothing`. (`val(m::PathMap)` is the root value, trie_map.rs:608.)"
function val end
"`val_at(z, path)` — the value at `path` relative to the focus, without moving it."
function val_at end

# ── ZipperMoving (zipper.rs:166-508) ─────────────────────────────────────────────────────────────────────────
"`depth(z)` — bytes between the zipper's root and its focus (= `length(path(z))` for `ZipperPath` zippers)."
function depth end

"`at_root(z)` — is the focus at the root, unable to ascend further?"
at_root(z::AbstractZipper) = depth(z) == 0

"""
`focus_byte(z)` — the byte last descended to reach the focus, or `nothing`. At the root the result is
unspecified (a zipper that knows the trie above its root may return the byte leading to it); use `at_root`.
"""
function focus_byte end

"`reset!(z)` — move the focus back to the root."
function reset!(z::AbstractZipper)
    while !at_root(z)
        ascend_byte!(z)
    end
    nothing
end

# `val_count` already exists (`val_count(m::PathMap)`); zipper methods join it: values at and below the focus.

"`descend_to!(z, k)` — move the focus deeper by `k`, relative to the focus (may leave the trie)."
function descend_to! end

"`descend_to_check!(z, k)` — `descend_to!` then `path_exists`."
function descend_to_check!(z::AbstractZipper, k)
    descend_to!(z, k)
    path_exists(z)
end

"`descend_to_existing!(z, k)` — descend along `k` while the path exists; returns the bytes descended."
function descend_to_existing!(z::AbstractZipper, k)
    i = 0
    for b in k
        descend_to_byte!(z, UInt8(b))
        if !path_exists(z)
            ascend_byte!(z)
            return i
        end
        i += 1
    end
    i
end

"""
`descend_to_val!(z, k)` — descend along `k`, stopping at a value or where the path ends; returns the bytes
descended. From a value it moves to the *next* value along the path.
"""
function descend_to_val!(z::AbstractZipper, k)
    i = 0
    for b in k
        descend_to_byte!(z, UInt8(b))
        if !path_exists(z)
            ascend_byte!(z)
            return i
        end
        i += 1
        is_val(z) && return i
    end
    i
end

"`descend_to_byte!(z, b)` — descend one byte (= `descend_to!` with a one-byte key)."
descend_to_byte!(z::AbstractZipper, b::UInt8) = descend_to!(z, UInt8[b])

# Julia convenience: upstream's byte arguments are `u8`; accept any Integer and convert once, so call
# sites can write `descend_to_byte!(z, 11)`. `UInt8(...)` still throws on an out-of-range value.
descend_to_byte!(z::AbstractZipper, b::Integer) = descend_to_byte!(z, UInt8(b))
descend_to_existing_byte!(z::AbstractZipper, b::Integer) = descend_to_existing_byte!(z, UInt8(b))

"`descend_to_existing_byte!(z, b)` — descend one byte only if it is in `child_mask`; returns whether it moved."
function descend_to_existing_byte!(z::AbstractZipper, b::UInt8)
    descend_to_byte!(z, b)
    path_exists(z) && return true
    ascend_byte!(z)
    false
end

"""
`descend_indexed_byte!(z, idx)` — descend into the `idx`-th child (0-based); returns the byte, or `nothing`
without moving when `idx` is out of range.
"""
function descend_indexed_byte!(z::AbstractZipper, idx::Int)::Union{Nothing, UInt8}
    child_byte = indexed_bit(child_mask(z), idx, true)
    child_byte === nothing && return nothing
    descend_to_byte!(z, child_byte)
    child_byte
end

"`descend_first_byte!(z)` — `descend_indexed_byte!(z, 0)`; returns the byte or `nothing`."
descend_first_byte!(z::AbstractZipper) = descend_indexed_byte!(z, 0)

"`descend_last_byte!(z)` — descend into the last child; returns the byte or `nothing`."
function descend_last_byte!(z::AbstractZipper)::Union{Nothing, UInt8}
    cc = child_count(z)
    cc == 0 ? nothing : descend_indexed_byte!(z, cc - 1)
end

"`descend_until!(z)` — `descend_until_observed!(z, nothing)`."
descend_until!(z::AbstractZipper) = descend_until_observed!(z, nothing)

"""
`descend_until_observed!(z, obs)` — descend until a branch or a value, reporting bytes to `obs`; returns
whether the focus moved. From a value it moves on to the next value or branch; on a branch it does not move.
"""
function descend_until_observed!(z::AbstractZipper, obs)
    descended = false
    while child_count(z) == 1
        descended = true
        byte = descend_first_byte!(z)
        byte === nothing || descend_to_byte!(obs, byte)
        is_val(z) && break
    end
    descended
end

"`descend_until_max_bytes!(z, max_bytes)` — `descend_until_max_bytes_observed!(z, max_bytes, nothing)`."
descend_until_max_bytes!(z::AbstractZipper, max_bytes::Int) = descend_until_max_bytes_observed!(z, max_bytes, nothing)

"""
`descend_until_max_bytes_observed!(z, max_bytes, obs)` — as `descend_until_observed!`, but never more than
`max_bytes`; `false` for `max_bytes == 0`. Bytes past the limit are never reported to `obs`.
"""
function descend_until_max_bytes_observed!(z::AbstractZipper, max_bytes::Int, obs)
    max_bytes == 0 && return false
    truncating = TruncatingObserver(obs, max_bytes, 0)
    descended = descend_until_observed!(z, truncating)
    overshoot = _overshoot(truncating)
    overshoot > 0 && ascend!(z, overshoot)
    descended
end

"`ascend!(z, steps)` — ascend `steps` bytes, stopping at the root; returns the bytes ascended."
function ascend! end

"`ascend_byte!(z)` — ascend one byte; returns whether it moved."
ascend_byte!(z::AbstractZipper) = ascend!(z, 1) == 1

"`ascend_until!(z)` — ascend to the nearest branch or value; returns the bytes ascended (0 at the root)."
function ascend_until! end

"`ascend_until_branch!(z)` — ascend to the nearest branch, skipping values; returns the bytes ascended."
function ascend_until_branch! end

"`to_next_sibling_byte!(z)` — move to the next sibling; returns its byte, or `nothing` without moving."
function to_next_sibling_byte!(z::AbstractZipper)::Union{Nothing, UInt8}
    cur_byte = focus_byte(z)
    cur_byte === nothing && return nothing
    ascend_byte!(z) || return nothing
    byte = next_bit(child_mask(z), cur_byte)
    descend_to_byte!(z, byte === nothing ? cur_byte : byte)
    byte
end

"`to_prev_sibling_byte!(z)` — move to the previous sibling; returns its byte, or `nothing` without moving."
function to_prev_sibling_byte!(z::AbstractZipper)::Union{Nothing, UInt8}
    cur_byte = focus_byte(z)
    cur_byte === nothing && return nothing
    ascend_byte!(z) || return nothing
    byte = prev_bit(child_mask(z), cur_byte)
    descend_to_byte!(z, byte === nothing ? cur_byte : byte)
    byte
end

"`to_next_step!(z)` — `to_next_step_observed!(z, nothing)`."
to_next_step!(z::AbstractZipper) = to_next_step_observed!(z, nothing)

"""
`to_next_step_observed!(z, obs)` — one depth-first step over every existing path, reporting to `obs`;
`false` once back at the root.
"""
function to_next_step_observed!(z::AbstractZipper, obs)
    if child_count(z) == 0
        while true
            byte = to_next_sibling_byte!(z)
            if byte !== nothing
                # a sibling step replaces the last byte: the observer sees it retracted, then the new one
                ascend!(obs, 1)
                descend_to_byte!(obs, byte)
                break
            end
            ascend_byte!(z) || return false
            ascend!(obs, 1)
        end
        return true
    end
    byte = descend_first_byte!(z)
    byte === nothing && return false
    descend_to_byte!(obs, byte)
    true
end

# ── ZipperPath (zipper.rs:1147-1172) ─────────────────────────────────────────────────────────────────────────
"`path(z)` — the path from the root to the focus (empty exactly when `at_root`)."
function path end

"`move_to_path!(z, p)` — move to `p` relative to the root; returns the bytes shared by the old and new focus."
function move_to_path!(z::AbstractZipper, p)
    pv = p isa AbstractVector{UInt8} ? p : collect(UInt8, p)
    cur = path(z)
    overlap = find_prefix_overlap(pv, cur)
    to_ascend = length(cur) - overlap
    if overlap == 0
        reset!(z)
        descend_to!(z, pv)
    else
        ascend!(z, to_ascend)
        descend_to!(z, view(pv, (overlap + 1):length(pv)))
    end
    overlap
end

# ── ZipperIteration (zipper.rs:924-1140) ─────────────────────────────────────────────────────────────────────
"`to_next_val!(z)` — `to_next_val_observed!(z, nothing)`."
to_next_val!(z::AbstractZipper) = to_next_val_observed!(z, nothing)

"`to_next_val_observed!(z, obs)` — depth-first move to the next value; `false` once back at the root."
function to_next_val_observed!(z::AbstractZipper, obs)
    while true
        byte = descend_first_byte!(z)
        if byte !== nothing
            descend_to_byte!(obs, byte)
            is_val(z) && return true
            descend_until_observed!(z, obs) && is_val(z) && return true
        else
            while true
                sib = to_next_sibling_byte!(z)
                if sib !== nothing
                    ascend!(obs, 1)
                    descend_to_byte!(obs, sib)
                    is_val(z) && return true
                    break
                end
                ascend_byte!(z) && ascend!(obs, 1)
                at_root(z) && return false
            end
        end
    end
end

"`descend_last_path!(z)` — `descend_last_path_observed!(z, nothing)`."
descend_last_path!(z::AbstractZipper) = descend_last_path_observed!(z, nothing)

"""
`descend_last_path_observed!(z, obs)` — descend to the end of the last path below the focus; `false` (and no
move) if already at a path end.
"""
function descend_last_path_observed!(z::AbstractZipper, obs)
    any = false
    while true
        byte = descend_last_byte!(z)
        byte === nothing && break
        any = true
        descend_to_byte!(obs, byte)
        descend_until_observed!(z, obs)
    end
    any
end

"`descend_first_k_path!(z, k)` — `descend_first_k_path_observed!(z, k, nothing)`."
descend_first_k_path!(z::AbstractZipper, k::Int) = descend_first_k_path_observed!(z, k, nothing)

"""
`descend_first_k_path_observed!(z, k, obs)` — depth-first search for the first path exactly `k` bytes below
the focus. `false` (focus unchanged) if none exists or `k == 0`.
"""
descend_first_k_path_observed!(z::AbstractZipper, k::Int, obs) = _k_path_default_internal!(z, k, depth(z), obs)

"`to_next_k_path!(z, k)` — `to_next_k_path_observed!(z, k, nothing)`."
to_next_k_path!(z::AbstractZipper, k::Int) = to_next_k_path_observed!(z, k, nothing)

"""
`to_next_k_path_observed!(z, k, obs)` — the next location at the same depth under the common root `k` bytes
above the focus. On `false` the focus has ascended `k` bytes; with `k > depth` it returns `false` and resets.
"""
function to_next_k_path_observed!(z::AbstractZipper, k::Int, obs)
    d = depth(z)
    d < k && return _k_path_depth_exceeded!(z, d, obs)
    _k_path_default_internal!(z, k, d - k, obs)
end

# zipper.rs:1101-1105
function _k_path_depth_exceeded!(z, d::Int, obs)
    reset!(z)
    ascend!(obs, d)
    false
end

# zipper.rs:1112-1140 — the default k-path walk (`base_idx` is the depth of the common root).
function _k_path_default_internal!(z, k::Int, base_idx::Int, obs)
    while true
        if depth(z) < base_idx + k
            while true
                byte = descend_first_byte!(z)
                byte === nothing && break
                descend_to_byte!(obs, byte)
                depth(z) == base_idx + k && return true
            end
        end
        sib = to_next_sibling_byte!(z)
        if sib !== nothing
            ascend!(obs, 1)
            descend_to_byte!(obs, sib)
            depth(z) == base_idx + k && return true
            continue
        end
        while depth(z) > base_idx
            ascend_byte!(z) && ascend!(obs, 1)
            depth(z) == base_idx && return false
            sib = to_next_sibling_byte!(z)
            if sib !== nothing
                ascend!(obs, 1)
                descend_to_byte!(obs, sib)
                break
            end
        end
    end
end

# ── ZipperAbsolutePath / ZipperForking / ZipperConcrete (zipper.rs:108-119, 1175-1227) ───────────────────────
"`origin_path(z)` — the path from the origin to the focus (= `root_prefix_path(z) ++ path(z)`)."
function origin_path end
"`root_prefix_path(z)` — the path from the origin to the root; constant for the zipper's life."
function root_prefix_path end
"`fork_read_zipper(z)` — a new read zipper rooted at the focus."
function fork_read_zipper end
# `shared_node_id` already exists (`shared_node_id(rc::TrieNodeODRc)`); zipper methods join it.
"`is_shared(z)` — may the focus be reached by two or more distinct paths? (optimisation only)"
function is_shared end

# ── ZipperReadOnlyValues / ZipperReadOnlyIteration (zipper.rs:747-829) ──────────────────────────────────────
# `get_val` already exists (node payloads); zipper methods join it: the value at the focus.
"`to_next_get_val!(z)` — `to_next_get_val_observed!(z, nothing)`."
to_next_get_val!(z::AbstractZipper) = to_next_get_val_observed!(z, nothing)

"`to_next_get_val_observed!(z, obs)` — `to_next_val_observed!`, returning the value (or `nothing` at the root)."
to_next_get_val_observed!(z::AbstractZipper, obs) = to_next_val_observed!(z, obs) ? get_val(z) : nothing

# ── PathObserver (zipper.rs:510-741) ─────────────────────────────────────────────────────────────────────────
"""
Supertype of the observer structs. As upstream, plain values also observe: `nothing` (= `()`, discards),
`Vector{UInt8}` (the full path), `Base.RefValue{Int}` (= `usize`, the depth), and a 2-`Tuple` (fans out).
Protocol: `descend_to!(obs, path)`, `descend_to_byte!(obs, byte)`, `ascend!(obs, steps)`.
"""
abstract type PathObserver end

descend_to!(::Nothing, ::Any) = nothing
descend_to_byte!(::Nothing, ::UInt8) = nothing
ascend!(::Nothing, ::Int) = nothing

descend_to!(obs::Vector{UInt8}, p) = (append!(obs, p); nothing)
descend_to_byte!(obs::Vector{UInt8}, b::UInt8) = (push!(obs, b); nothing)
ascend!(obs::Vector{UInt8}, steps::Int) = (resize!(obs, length(obs) - steps); nothing)

descend_to!(obs::Base.RefValue{Int}, p) = (obs[] += length(p); nothing)
descend_to_byte!(obs::Base.RefValue{Int}, ::UInt8) = (obs[] += 1; nothing)
ascend!(obs::Base.RefValue{Int}, steps::Int) = (obs[] -= steps; nothing)

descend_to!(obs::Tuple{Any, Any}, p) = (descend_to!(obs[1], p); descend_to!(obs[2], p); nothing)
descend_to_byte!(obs::Tuple{Any, Any}, b::UInt8) = (descend_to_byte!(obs[1], b); descend_to_byte!(obs[2], b); nothing)
ascend!(obs::Tuple{Any, Any}, steps::Int) = (ascend!(obs[1], steps); ascend!(obs[2], steps); nothing)

"`MirrorPathObserver(z)` — replays observed movement onto another zipper (even off the end of its trie)."
struct MirrorPathObserver{Z <: AbstractZipper} <: PathObserver
    z::Z
end
descend_to!(obs::MirrorPathObserver, p) = (descend_to!(obs.z, p); nothing)
descend_to_byte!(obs::MirrorPathObserver, b::UInt8) = (descend_to_byte!(obs.z, b); nothing)
ascend!(obs::MirrorPathObserver, steps::Int) = (ascend!(obs.z, steps); nothing)

# zipper.rs:645-698: forwards at most `limit` bytes, counting everything (private upstream)
mutable struct TruncatingObserver{O} <: PathObserver
    obs::O
    limit::Int
    descended::Int
end
@inline _forwarded(t::TruncatingObserver) = min(t.descended, t.limit)
@inline _overshoot(t::TruncatingObserver) = max(t.descended - t.limit, 0)
function descend_to!(t::TruncatingObserver, p)
    take = min(max(t.limit - t.descended, 0), length(p))
    take > 0 && descend_to!(t.obs, view(p, 1:take))
    t.descended += length(p)
    nothing
end
function descend_to_byte!(t::TruncatingObserver, b::UInt8)
    t.descended < t.limit && descend_to_byte!(t.obs, b)
    t.descended += 1
    nothing
end
function ascend!(t::TruncatingObserver, steps::Int)
    before = _forwarded(t)
    t.descended = max(t.descended - steps, 0)
    after = _forwarded(t)
    before > after && ascend!(t.obs, before - after)
    nothing
end

"""
`HashObserver()` — reduces the observed path to a 64-bit digest that does not depend on how movement was
chunked. Ascending zeroes the digest (zipper.rs:700-741).
"""
mutable struct HashObserver <: PathObserver
    hash::UInt64
    depth::Int
end
HashObserver() = HashObserver(zero(UInt64), 0)
function descend_to!(h::HashObserver, p)
    for b in p
        descend_to_byte!(h, UInt8(b))
    end
    nothing
end
function descend_to_byte!(h::HashObserver, b::UInt8)
    # SplitMix64's finalizer: a bijection, so distinct (depth, byte) pairs contribute distinct values
    x = ((UInt64(h.depth) << 8) | UInt64(b)) * 0x9E3779B97F4A7C15
    x = (x ⊻ (x >> 30)) * 0xBF58476D1CE4E5B9
    h.hash ⊻= x ⊻ (x >> 27)
    h.depth += 1
    nothing
end
function ascend!(h::HashObserver, steps::Int)
    h.hash = zero(UInt64)
    h.depth = max(h.depth - steps, 0)
    nothing
end

export AbstractZipper, PathObserver, MirrorPathObserver, HashObserver
export path_exists, is_val, child_count, child_mask, val, val_at
export depth, at_root, focus_byte, reset!, val_count, descend_to!, descend_to_check!, descend_to_existing!,
    descend_to_val!, descend_to_byte!, descend_to_existing_byte!, descend_indexed_byte!, descend_first_byte!,
    descend_last_byte!, descend_until!, descend_until_observed!, descend_until_max_bytes!,
    descend_until_max_bytes_observed!, ascend!, ascend_byte!, ascend_until!, ascend_until_branch!,
    to_next_sibling_byte!, to_prev_sibling_byte!, to_next_step!, to_next_step_observed!
export path, move_to_path!
export to_next_val!, to_next_val_observed!, descend_last_path!, descend_last_path_observed!,
    descend_first_k_path!, descend_first_k_path_observed!, to_next_k_path!, to_next_k_path_observed!
export origin_path, root_prefix_path, fork_read_zipper, shared_node_id, is_shared
export get_val, to_next_get_val!, to_next_get_val_observed!
