"""
ZipperHead — port of `pathmap/src/zipper_head.rs`.

Coordinates multiple simultaneous zippers into the same PathMap using
`SharedTrackerPaths` to enforce exclusive write access and shared read access.

Julia translation notes:
  - No `CellByteNode` / split-borrow / `prepare_exclusive_write_path` needed.
    Julia GC handles object lifetimes; TrieNodeODRc is already a shared ref.
    WriteZipperCore at a sub-path naturally propagates changes to the PathMaps.
  - `ZipperHead` wraps a PathMap directly (vs Rust wrapping a WriteZipperCore).
  - `ZipperHeadOwned` is the same thing with a ReentrantLock for thread safety.
  - `ReadZipperTracked`/`WriteZipperTracked` = inner zipper + optional tracker.
"""

# =====================================================================
# ReadZipperTracked
# =====================================================================

"""
    ReadZipperTracked{V, A}

A read zipper that carries an optional `ZipperTracker{TrackingRead}` to
hold its path lock until the zipper is released.
Mirrors `ReadZipperTracked` in zipper.rs.
"""
mutable struct ReadZipperTracked{V, A <: Allocator} <: AbstractZipper
    z::ReadZipperCore{V, A}
    tracker::Union{Nothing, ZipperTracker{TrackingRead, A}}
end

function ReadZipperTracked(
    rz::ReadZipperCore{V, A}, tracker::Union{Nothing, ZipperTracker{TrackingRead, A}}
) where {V, A}
    t = ReadZipperTracked{V, A}(rz, tracker)
    finalizer(_rzt_finalize!, t)
    t
end

function _rzt_finalize!(t::ReadZipperTracked)
    t.tracker !== nothing && zt_release!(t.tracker)
    t.tracker = nothing
end

"""
Release the read zipper's path lock explicitly.
"""
function release!(t::ReadZipperTracked)
    _rzt_finalize!(t)
end

"""
    with_read_zipper_tracked(f, t::ReadZipperTracked)

Run `f(t)` and DETERMINISTICALLY release the read zipper's path lock at scope exit
(`release!` in a `finally`) rather than at GC time. See `with_zipper_tracker` (ZT-1).
"""
function with_read_zipper_tracked(f, t::ReadZipperTracked)
    try
        f(t)
    finally
        release!(t)
    end
end

# Delegate all read operations to the inner zipper
# ZipperReadOnly* / Zipper / ZipperValues / ZipperMoving, delegated to the inner zipper (zipper.rs:1466-1507)
@inline path_exists(t::ReadZipperTracked) = path_exists(t.z)
@inline is_val(t::ReadZipperTracked) = is_val(t.z)
@inline val(t::ReadZipperTracked) = val(t.z)
@inline get_val(t::ReadZipperTracked) = get_val(t.z)
@inline val_at(t::ReadZipperTracked, p::AbstractVector{UInt8}) = val_at(t.z, p)
@inline path(t::ReadZipperTracked) = path(t.z)
@inline origin_path(t::ReadZipperTracked) = origin_path(t.z)
@inline root_prefix_path(t::ReadZipperTracked) = root_prefix_path(t.z)
@inline child_count(t::ReadZipperTracked) = child_count(t.z)
@inline child_mask(t::ReadZipperTracked) = child_mask(t.z)
@inline val_count(t::ReadZipperTracked) = val_count(t.z)
@inline depth(t::ReadZipperTracked) = depth(t.z)
@inline at_root(t::ReadZipperTracked) = at_root(t.z)
@inline focus_byte(t::ReadZipperTracked) = focus_byte(t.z)
@inline reset!(t::ReadZipperTracked) = reset!(t.z)
@inline descend_to!(t::ReadZipperTracked, k) = descend_to!(t.z, k)
@inline descend_to_byte!(t::ReadZipperTracked, b::UInt8) = descend_to_byte!(t.z, b)
@inline descend_indexed_byte!(t::ReadZipperTracked, i::Int) = descend_indexed_byte!(t.z, i)
@inline descend_first_byte!(t::ReadZipperTracked) = descend_first_byte!(t.z)
@inline descend_until_observed!(t::ReadZipperTracked, obs) = descend_until_observed!(t.z, obs)
@inline ascend!(t::ReadZipperTracked, n::Int) = ascend!(t.z, n)
@inline ascend_byte!(t::ReadZipperTracked) = ascend_byte!(t.z)
@inline ascend_until!(t::ReadZipperTracked) = ascend_until!(t.z)
@inline ascend_until_branch!(t::ReadZipperTracked) = ascend_until_branch!(t.z)
@inline to_next_sibling_byte!(t::ReadZipperTracked) = to_next_sibling_byte!(t.z)
@inline to_prev_sibling_byte!(t::ReadZipperTracked) = to_prev_sibling_byte!(t.z)
@inline to_next_val_observed!(t::ReadZipperTracked, obs) = to_next_val_observed!(t.z, obs)
@inline to_next_get_val_observed!(t::ReadZipperTracked, obs) = to_next_get_val_observed!(t.z, obs)
@inline descend_first_k_path_observed!(t::ReadZipperTracked, k::Int, obs) = descend_first_k_path_observed!(t.z, k, obs)
@inline to_next_k_path_observed!(t::ReadZipperTracked, k::Int, obs) = to_next_k_path_observed!(t.z, k, obs)
@inline fork_read_zipper(t::ReadZipperTracked) = fork_read_zipper(t.z)

# =====================================================================
# WriteZipperTracked
# =====================================================================

"""
    WriteZipperTracked{V, A}

A write zipper that carries an optional `ZipperTracker{TrackingWrite}` to
hold its path lock until the zipper is released.
Mirrors `WriteZipperTracked` in write_zipper.rs.
"""
mutable struct WriteZipperTracked{V, A <: Allocator} <: AbstractZipper
    z::WriteZipperCore{V, A}
    tracker::Union{Nothing, ZipperTracker{TrackingWrite, A}}
end

function WriteZipperTracked(
    wz::WriteZipperCore{V, A}, tracker::Union{Nothing, ZipperTracker{TrackingWrite, A}}
) where {V, A}
    t = WriteZipperTracked{V, A}(wz, tracker)
    finalizer(_wzt_finalize!, t)
    t
end

function _wzt_finalize!(t::WriteZipperTracked)
    t.tracker !== nothing && zt_release!(t.tracker)
    t.tracker = nothing
end

"""
Release the write zipper's path lock explicitly.
"""
function release!(t::WriteZipperTracked)
    _wzt_finalize!(t)
end

"""
    with_write_zipper_tracked(f, t::WriteZipperTracked)

Run `f(t)` and DETERMINISTICALLY release the write zipper's path lock at scope exit
(`release!` in a `finally`) rather than at GC time. See `with_zipper_tracker` (ZT-1).
"""
function with_write_zipper_tracked(f, t::WriteZipperTracked)
    try
        f(t)
    finally
        release!(t)
    end
end

# Delegate write operations to the inner WriteZipperCore
# ZipperWriting / Zipper / ZipperValues / ZipperMoving, delegated to the inner zipper (write_zipper.rs:402-550)
@inline set_val!(t::WriteZipperTracked{V}, v::V) where {V} = set_val!(t.z, v)
@inline remove_val!(t::WriteZipperTracked, prune::Bool=false) = remove_val!(t.z, prune)
@inline descend_to!(t::WriteZipperTracked, k) = descend_to!(t.z, k)
@inline descend_to_byte!(t::WriteZipperTracked, b::UInt8) = descend_to_byte!(t.z, b)
@inline ascend!(t::WriteZipperTracked, n::Int) = ascend!(t.z, n)
@inline ascend_byte!(t::WriteZipperTracked) = ascend_byte!(t.z)
@inline ascend_until!(t::WriteZipperTracked) = ascend_until!(t.z)
@inline ascend_until_branch!(t::WriteZipperTracked) = ascend_until_branch!(t.z)
@inline reset!(t::WriteZipperTracked) = reset!(t.z)
@inline path(t::WriteZipperTracked) = path(t.z)
@inline origin_path(t::WriteZipperTracked) = origin_path(t.z)
@inline root_prefix_path(t::WriteZipperTracked) = root_prefix_path(t.z)
@inline path_exists(t::WriteZipperTracked) = path_exists(t.z)
@inline is_val(t::WriteZipperTracked) = is_val(t.z)
@inline val(t::WriteZipperTracked) = val(t.z)
@inline child_count(t::WriteZipperTracked) = child_count(t.z)
@inline child_mask(t::WriteZipperTracked) = child_mask(t.z)
@inline val_count(t::WriteZipperTracked) = val_count(t.z)
@inline depth(t::WriteZipperTracked) = depth(t.z)
@inline at_root(t::WriteZipperTracked) = at_root(t.z)
@inline focus_byte(t::WriteZipperTracked) = focus_byte(t.z)
@inline descend_first_byte!(t::WriteZipperTracked) = descend_first_byte!(t.z)
@inline descend_indexed_byte!(t::WriteZipperTracked, i::Int) = descend_indexed_byte!(t.z, i)
@inline to_next_sibling_byte!(t::WriteZipperTracked) = to_next_sibling_byte!(t.z)
@inline to_prev_sibling_byte!(t::WriteZipperTracked) = to_prev_sibling_byte!(t.z)

# =====================================================================
# ZipperHead
# =====================================================================

"""
    ZipperHead{V, A}

Coordinates multiple simultaneous read and write zippers over a PathMaps.
Use `write_zipper_at_exclusive_path` and `read_zipper_at_path` to
obtain tracked zippers that are safe to use concurrently (within the
exclusivity constraints of the tracker).

Mirrors `ZipperHead` in zipper_head.rs.

Julia note: ZipperHead holds a direct reference to the PathMap rather than
wrapping a WriteZipperCore, since Julia's GC eliminates split-borrow needs.
"""
mutable struct ZipperHead{V, A <: Allocator}
    pathmap::PathMap{V, A}
    tracker_paths::SharedTrackerPaths{A}
end

"""
    ZipperHead(m::PathMap) → ZipperHead

Create a ZipperHead for `m`.  Mirrors `PathMap::zipper_head`.
"""
function ZipperHead(m::PathMap{V, A}) where {V, A}
    ZipperHead{V, A}(m, SharedTrackerPaths(m.alloc))
end

"""
    write_zipper_at_exclusive_path(zh, path) → WriteZipperTracked

Obtain a tracked write zipper at `path`.  Returns a `Conflict` exception
if an overlapping zipper exists.  Mirrors `write_zipper_at_exclusive_path`.
"""
function write_zipper_at_exclusive_path(zh::ZipperHead{V, A}, path) where {V, A}
    p = collect(UInt8, path)
    tracker = ZipperTracker{TrackingWrite}(zh.tracker_paths, p)
    wz = write_zipper_at_path(zh.pathmap, p)
    WriteZipperTracked(wz, tracker)
end

"""
    write_zipper_at_exclusive_path_unchecked(zh, path) → WriteZipperTracked

Unchecked version — skip conflict check.  Caller guarantees no conflicts.
"""
function write_zipper_at_exclusive_path_unchecked(
    zh::ZipperHead{V, A}, path
) where {V, A}
    p = collect(UInt8, path)
    wz = write_zipper_at_path(zh.pathmap, p)
    WriteZipperTracked{V, A}(wz, nothing)
end

"""
    read_zipper_at_path(zh, path) → ReadZipperTracked

Obtain a tracked read zipper at `path`.  Returns a `Conflict` if a write
zipper holds an overlapping path.  Mirrors `read_zipper_at_path`.
"""
function read_zipper_at_path(zh::ZipperHead{V, A}, path) where {V, A}
    p = collect(UInt8, path)
    tracker = ZipperTracker{TrackingRead}(zh.tracker_paths, p)
    _ensure_root!(zh.pathmap)
    rz = ReadZipperCore_at_path(
        zh.pathmap.root::TrieNodeODRc{V, A}, p, length(p), 0, zh.pathmap.root_val,
        zh.pathmap.alloc
    )
    ReadZipperTracked(rz, tracker)
end

"""
    read_zipper_at_path_unchecked(zh, path) → ReadZipperTracked

Unchecked version — skip conflict check.  Caller guarantees no conflicts.
"""
function read_zipper_at_path_unchecked(zh::ZipperHead{V, A}, path) where {V, A}
    p = collect(UInt8, path)
    _ensure_root!(zh.pathmap)
    rz = ReadZipperCore_at_path(
        zh.pathmap.root::TrieNodeODRc{V, A}, p, length(p), 0, zh.pathmap.root_val,
        zh.pathmap.alloc
    )
    ReadZipperTracked{V, A}(rz, nothing)
end

"""
    cleanup_write_zipper!(zh, z)

After dropping a write zipper, prune any empty dangling path it created.
Mirrors `cleanup_write_zipper` (zipper_head.rs:302).
"""
function cleanup_write_zipper!(
    zh::ZipperHead{V, A}, z::WriteZipperTracked{V, A}
) where {V, A}
    # The *absolute* path the zipper was rooted at lives in prefix_buf[1:origin_path_len].
    # `path` returns the RELATIVE path inside the rooted zipper, which is empty
    # for an at-root cursor — using it here previously pruned the wrong subtree.
    origin = copy(view(z.z.prefix_buf, 1:z.z.origin_path_len))
    release!(z)               # release tracker + finalize
    isempty(origin) && return nothing
    hz = write_zipper(zh.pathmap)
    descend_to!(hz, origin)
    prune_path!(hz)               # walks up from origin, removing any empty spine
end

"""
    zipper_head(m::PathMap) → ZipperHead

Convenience constructor.  Mirrors `PathMap::zipper_head` in trie_map.rs.
"""
zipper_head(m::PathMap) = ZipperHead(m)

# =====================================================================
# ZipperHeadOwned
# =====================================================================

"""
    ZipperHeadOwned{V, A}

Thread-safe version of `ZipperHead` that owns its PathMap behind a
`ReentrantLock`.  Mirrors `ZipperHeadOwned` in zipper_head.rs.
"""
mutable struct ZipperHeadOwned{V, A <: Allocator}
    _lock::ReentrantLock
    pathmap::PathMap{V, A}
    tracker_paths::SharedTrackerPaths{A}
end

function ZipperHeadOwned(m::PathMap{V, A}) where {V, A}
    ZipperHeadOwned{V, A}(ReentrantLock(), m, SharedTrackerPaths(m.alloc))
end

"""
Extract the PathMap from a ZipperHeadOwned.  Mirrors `into_map`.
"""
function into_map(zho::ZipperHeadOwned{V, A}) where {V, A}
    lock(zho._lock) do
        copy(zho.pathmap)
    end
end

function write_zipper_at_exclusive_path(zho::ZipperHeadOwned{V, A}, path) where {V, A}
    p = collect(UInt8, path)
    tracker = ZipperTracker{TrackingWrite}(zho.tracker_paths, p)
    lock(zho._lock) do
        wz = write_zipper_at_path(zho.pathmap, p)
        WriteZipperTracked(wz, tracker)
    end
end

function read_zipper_at_path(zho::ZipperHeadOwned{V, A}, path) where {V, A}
    p = collect(UInt8, path)
    tracker = ZipperTracker{TrackingRead}(zho.tracker_paths, p)
    lock(zho._lock) do
        _ensure_root!(zho.pathmap)
        rz = ReadZipperCore_at_path(
            zho.pathmap.root::TrieNodeODRc{V, A}, p, length(p), 0, zho.pathmap.root_val,
            zho.pathmap.alloc
        )
        ReadZipperTracked(rz, tracker)
    end
end

# =====================================================================
# Exports
# =====================================================================

export ReadZipperTracked, WriteZipperTracked
export with_read_zipper_tracked, with_write_zipper_tracked
export release!            # tracked-zipper lifecycle (upstream: Drop / ZipperHead::cleanup_write_zipper)
export ZipperHead, ZipperHeadOwned, zipper_head
# ZipperCreation (zipper_head.rs:11-84); `read_zipper_at_path` is also PathMap's
export write_zipper_at_exclusive_path, write_zipper_at_exclusive_path_unchecked
export read_zipper_at_path_unchecked, cleanup_write_zipper!, into_map
