"""
ZipperHead — port of `pathmap/src/zipper_head.rs`.

Coordinates multiple simultaneous zippers into the same PathMap using
`SharedTrackerPaths` to enforce exclusive write access and shared read access.

Julia translation notes:
  - No `CellByteNode` / split-borrow / `prepare_exclusive_write_path` needed.
    Julia GC handles object lifetimes; TrieNodeODRc is already a shared ref.
    WriteZipperCore at a sub-path naturally propagates changes to the PathMap.
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
mutable struct ReadZipperTracked{V, A <: Allocator}
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
function rzt_release!(t::ReadZipperTracked)
    _rzt_finalize!(t)
end

"""
    with_read_zipper_tracked(f, t::ReadZipperTracked)

Run `f(t)` and DETERMINISTICALLY release the read zipper's path lock at scope exit
(`rzt_release!` in a `finally`) rather than at GC time. See `with_zipper_tracker` (ZT-1).
"""
function with_read_zipper_tracked(f, t::ReadZipperTracked)
    try
        f(t)
    finally
        rzt_release!(t)
    end
end

# Delegate all read operations to the inner zipper
@inline rzt_path_exists(t::ReadZipperTracked) = rz_path_exists(t.z)
@inline rzt_is_val(t::ReadZipperTracked) = rz_is_val(t.z)
@inline rzt_get_val(t::ReadZipperTracked{V}) where {V} = rz_get_val(t.z)
@inline rzt_path(t::ReadZipperTracked) = rz_path(t.z)
@inline rzt_child_count(t::ReadZipperTracked) = rz_child_count(t.z)
@inline rzt_child_mask(t::ReadZipperTracked) = rz_child_mask(t.z)
@inline rzt_val_count(t::ReadZipperTracked) = rz_val_count(t.z)

# =====================================================================
# WriteZipperTracked
# =====================================================================

"""
    WriteZipperTracked{V, A}

A write zipper that carries an optional `ZipperTracker{TrackingWrite}` to
hold its path lock until the zipper is released.
Mirrors `WriteZipperTracked` in write_zipper.rs.
"""
mutable struct WriteZipperTracked{V, A <: Allocator}
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
function wzt_release!(t::WriteZipperTracked)
    _wzt_finalize!(t)
end

"""
    with_write_zipper_tracked(f, t::WriteZipperTracked)

Run `f(t)` and DETERMINISTICALLY release the write zipper's path lock at scope exit
(`wzt_release!` in a `finally`) rather than at GC time. See `with_zipper_tracker` (ZT-1).
"""
function with_write_zipper_tracked(f, t::WriteZipperTracked)
    try
        f(t)
    finally
        wzt_release!(t)
    end
end

# Delegate write operations to the inner WriteZipperCore
@inline wzt_set_val!(t::WriteZipperTracked{V}, v::V) where {V} = wz_set_val!(t.z, v)
@inline wzt_remove_val!(t::WriteZipperTracked, prune::Bool=false) =
    wz_remove_val!(t.z, prune)
@inline wzt_descend_to!(t::WriteZipperTracked, k) = wz_descend_to!(t.z, k)
@inline wzt_ascend!(t::WriteZipperTracked, n::Int=1) = wz_ascend!(t.z, n)
@inline wzt_reset!(t::WriteZipperTracked) = wz_reset!(t.z)
@inline wzt_path(t::WriteZipperTracked) = wz_path(t.z)
@inline wzt_path_exists(t::WriteZipperTracked) = wz_path_exists(t.z)
@inline wzt_is_val(t::WriteZipperTracked) = wz_is_val(t.z)
@inline wzt_get_val(t::WriteZipperTracked{V}) where {V} = wz_get_val(t.z)
@inline wzt_child_count(t::WriteZipperTracked) = wz_child_count(t.z)
@inline wzt_child_mask(t::WriteZipperTracked) = wz_child_mask(t.z)
@inline wzt_val_count(t::WriteZipperTracked) = wz_val_count(t.z)
@inline wzt_descend_first_byte!(t::WriteZipperTracked) = wz_descend_first_byte!(t.z)
@inline wzt_ascend_byte!(t::WriteZipperTracked) = wz_ascend_byte!(t.z)
@inline wzt_to_next_sibling_byte!(t::WriteZipperTracked) = wz_to_next_sibling_byte!(t.z)

# =====================================================================
# ZipperHead
# =====================================================================

"""
    ZipperHead{V, A}

Coordinates multiple simultaneous read and write zippers over a PathMap.
Use `zh_write_zipper_at_exclusive_path` and `zh_read_zipper_at_path` to
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
    zh_write_zipper_at_exclusive_path(zh, path) → WriteZipperTracked

Obtain a tracked write zipper at `path`.  Returns a `Conflict` exception
if an overlapping zipper exists.  Mirrors `write_zipper_at_exclusive_path`.
"""
function zh_write_zipper_at_exclusive_path(zh::ZipperHead{V, A}, path) where {V, A}
    p = collect(UInt8, path)
    tracker = ZipperTracker{TrackingWrite}(zh.tracker_paths, p)
    wz = write_zipper_at_path(zh.pathmap, p)
    WriteZipperTracked(wz, tracker)
end

"""
    zh_write_zipper_at_exclusive_path_unchecked(zh, path) → WriteZipperTracked

Unchecked version — skip conflict check.  Caller guarantees no conflicts.
"""
function zh_write_zipper_at_exclusive_path_unchecked(
    zh::ZipperHead{V, A}, path
) where {V, A}
    p = collect(UInt8, path)
    wz = write_zipper_at_path(zh.pathmap, p)
    WriteZipperTracked{V, A}(wz, nothing)
end

"""
    zh_read_zipper_at_path(zh, path) → ReadZipperTracked

Obtain a tracked read zipper at `path`.  Returns a `Conflict` if a write
zipper holds an overlapping path.  Mirrors `read_zipper_at_path`.
"""
function zh_read_zipper_at_path(zh::ZipperHead{V, A}, path) where {V, A}
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
    zh_read_zipper_at_path_unchecked(zh, path) → ReadZipperTracked

Unchecked version — skip conflict check.  Caller guarantees no conflicts.
"""
function zh_read_zipper_at_path_unchecked(zh::ZipperHead{V, A}, path) where {V, A}
    p = collect(UInt8, path)
    _ensure_root!(zh.pathmap)
    rz = ReadZipperCore_at_path(
        zh.pathmap.root::TrieNodeODRc{V, A}, p, length(p), 0, zh.pathmap.root_val,
        zh.pathmap.alloc
    )
    ReadZipperTracked{V, A}(rz, nothing)
end

"""
    zh_cleanup_write_zipper!(zh, z)

After dropping a write zipper, prune any empty dangling path it created.
Mirrors `cleanup_write_zipper` (zipper_head.rs:302).
"""
function zh_cleanup_write_zipper!(
    zh::ZipperHead{V, A}, z::WriteZipperTracked{V, A}
) where {V, A}
    # The *absolute* path the zipper was rooted at lives in prefix_buf[1:origin_path_len].
    # wz_path returns the RELATIVE path inside the rooted zipper, which is empty
    # for an at-root cursor — using it here previously pruned the wrong subtree.
    origin = copy(view(z.z.prefix_buf, 1:z.z.origin_path_len))
    wzt_release!(z)               # release tracker + finalize
    isempty(origin) && return nothing
    hz = write_zipper(zh.pathmap)
    wz_descend_to!(hz, origin)
    wz_prune_path!(hz)            # walks up from origin, removing any empty spine
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
function zho_into_map(zho::ZipperHeadOwned{V, A}) where {V, A}
    lock(zho._lock) do
        copy(zho.pathmap)
    end
end

function zho_write_zipper_at_exclusive_path(zho::ZipperHeadOwned{V, A}, path) where {V, A}
    p = collect(UInt8, path)
    tracker = ZipperTracker{TrackingWrite}(zho.tracker_paths, p)
    lock(zho._lock) do
        wz = write_zipper_at_path(zho.pathmap, p)
        WriteZipperTracked(wz, tracker)
    end
end

function zho_read_zipper_at_path(zho::ZipperHeadOwned{V, A}, path) where {V, A}
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
export rzt_release!, rzt_path_exists, rzt_is_val, rzt_get_val, rzt_path
export rzt_child_count, rzt_child_mask, rzt_val_count
export wzt_release!, wzt_set_val!, wzt_remove_val!, wzt_descend_to!, wzt_ascend!
export wzt_reset!, wzt_path, wzt_path_exists, wzt_is_val, wzt_get_val
export wzt_child_count, wzt_child_mask, wzt_val_count
export wzt_descend_first_byte!, wzt_ascend_byte!, wzt_to_next_sibling_byte!
export ZipperHead, ZipperHeadOwned
export zh_write_zipper_at_exclusive_path, zh_write_zipper_at_exclusive_path_unchecked
export zh_read_zipper_at_path, zh_read_zipper_at_path_unchecked
export zh_cleanup_write_zipper!, zipper_head
export zho_into_map, zho_write_zipper_at_exclusive_path, zho_read_zipper_at_path
