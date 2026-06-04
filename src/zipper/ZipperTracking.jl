"""
ZipperTracking — port of `pathmap/src/zipper_tracking.rs`.

Concurrency safety layer that tracks outstanding read and write zipper paths.
Used by ZipperHead to prevent overlapping path access.

Julia translation notes:
  - TrackingMode sealed trait → abstract type + two concrete marker singletons
  - Arc<RwLock<TrackerPaths>> → SharedTrackerPaths wraps a ReentrantLock
  - NonZeroU32 read counts → plain UInt32 (invariant: >0 means at least 1 reader)
  - ManuallyDrop dismantle pattern → field nulling (GC handles memory)
  - Feature-gated items (path_status, PathStatus) → always compiled in Julia
"""

# =====================================================================
# TrackingMode — marker types
# =====================================================================

abstract type AbstractTrackingMode end

"""
Marker: tracker guards a read zipper.
"""
struct TrackingRead <: AbstractTrackingMode end

"""
Marker: tracker guards a write zipper.
"""
struct TrackingWrite <: AbstractTrackingMode end

_tracking_mode_str(::TrackingRead) = "read"
_tracking_mode_str(::TrackingWrite) = "write"
_tracks_writes(::TrackingRead) = false
_tracks_writes(::TrackingWrite) = true

# =====================================================================
# IsTracking — discriminates conflict source
# =====================================================================

@enum IsTracking begin
    IS_TRACKING_WRITE = 1
    IS_TRACKING_READ = 2
end

# =====================================================================
# Conflict — error type for overlapping paths
# =====================================================================

"""
    Conflict

Raised when a zipper cannot be created because an existing zipper holds
a conflicting path lock.  Mirrors `Conflict` in zipper_tracking.rs.
"""
struct Conflict <: Exception
    with::IsTracking
    count::UInt32     # >0 for IS_TRACKING_READ: number of current readers
    at::Vector{UInt8}
end

function Base.showerror(io::IO, c::Conflict)
    print(io, "ZipperConflict: conflicts with existing ")
    if c.with == IS_TRACKING_WRITE
        print(io, "write zipper")
    else
        print(io, "read zipper (arity: $(c.count))")
    end
    println(io, " @ $(c.at)")
end

_write_conflict(path::AbstractVector{UInt8}) =
    Conflict(IS_TRACKING_WRITE, 0, Vector{UInt8}(path))

_read_conflict(cnt::UInt32, path::AbstractVector{UInt8}) =
    Conflict(IS_TRACKING_READ, cnt, Vector{UInt8}(path))

conflict_path(c::Conflict) = c.at

# =====================================================================
# TrackerPaths (internal) + SharedTrackerPaths
# =====================================================================

mutable struct TrackerPaths{A <: Allocator}
    read_paths::PathMap{UInt32, A}   # val = reader count (>0)
    written_paths::PathMap{Bool, A}     # val = true = write lock present
end

TrackerPaths(alloc::A) where {A <: Allocator} =
    TrackerPaths{A}(PathMap{UInt32, A}(alloc), PathMap{Bool, A}(alloc))

TrackerPaths() = TrackerPaths(GlobalAlloc())

"""
    SharedTrackerPaths

Thread-safe shared registry of outstanding zipper path locks.
Wraps a `ReentrantLock`-guarded `TrackerPaths`.
Mirrors `SharedTrackerPaths` in zipper_tracking.rs.
"""
struct SharedTrackerPaths{A <: Allocator}
    _lock::ReentrantLock
    _paths::TrackerPaths{A}
end

SharedTrackerPaths(alloc::A) where {A <: Allocator} =
    SharedTrackerPaths{A}(ReentrantLock(), TrackerPaths(alloc))

SharedTrackerPaths() = SharedTrackerPaths(GlobalAlloc())

function _with_paths(f, stp::SharedTrackerPaths)
    lock(stp._lock) do
        f(stp._paths)
    end
end

# =====================================================================
# Conflict helpers (check_for_lock_along_path etc.)
# =====================================================================

"""
Check whether `path` conflicts with any existing write locks.
A conflict exists if any prefix of `path` has a lock, OR if any lock
exists at `path` or any descendant.  Returns `nothing` on success.
Mirrors `check_for_write_conflict`.
"""
function _check_for_write_conflict(
    path::AbstractVector{UInt8}, written_paths::PathMap{Bool}
)::Union{Nothing, Conflict}
    isempty(written_paths) && return nothing
    # Check ancestor locks: any prefix of path has a stored Bool=true lock
    for i in 0:length(path)
        prefix = view(path, 1:i)
        z = read_zipper_at_path(written_paths, prefix)
        zipper_is_val(z) && return _write_conflict(collect(prefix))
    end
    # Check descendant locks: any val in subtrie at/below path
    z = write_zipper(written_paths)
    wz_descend_to!(z, path)
    wz_val_count(z) > 0 && return _write_conflict(path)
    nothing
end

"""
Check whether `path` conflicts with any existing read locks.
Returns `nothing` on success, `Conflict` otherwise.
Mirrors `check_for_read_conflict`.
"""
function _check_for_read_conflict(
    path::AbstractVector{UInt8}, read_paths::PathMap{UInt32}
)::Union{Nothing, Conflict}
    isempty(read_paths) && return nothing
    # Check ancestor locks: any prefix of path has a stored UInt32 count
    for i in 0:length(path)
        prefix = view(path, 1:i)
        z = read_zipper_at_path(read_paths, prefix)
        if zipper_is_val(z)
            v = zipper_val(z)
            v !== nothing && return _read_conflict(v, collect(prefix))
        end
    end
    # Check descendant locks
    z = write_zipper(read_paths)
    wz_descend_to!(z, path)
    if wz_val_count(z) > 0
        v = wz_get_val(z)
        cnt = v !== nothing ? v : UInt32(1)
        return _read_conflict(cnt, path)
    end
    nothing
end

# =====================================================================
# SharedTrackerPaths — add/remove operations
# =====================================================================

"""
Attempt to register a write lock at `path`.
Returns `nothing` on success, `Conflict` on failure.
Mirrors `try_add_writer`.
"""
function stp_try_add_writer!(
    stp::SharedTrackerPaths, path::AbstractVector{UInt8}
)::Union{Nothing, Conflict}
    _with_paths(stp) do paths
        c = _check_for_write_conflict(path, paths.written_paths)
        c !== nothing && return c
        c = _check_for_read_conflict(path, paths.read_paths)
        c !== nothing && return c
        set_val_at!(paths.written_paths, path, true)
        nothing
    end
end

"""
Attempt to register a read lock at `path`.
Returns `nothing` on success, `Conflict` on failure.
Mirrors `try_add_reader`.
"""
function stp_try_add_reader!(
    stp::SharedTrackerPaths, path::AbstractVector{UInt8}
)::Union{Nothing, Conflict}
    _with_paths(stp) do paths
        c = _check_for_write_conflict(path, paths.written_paths)
        c !== nothing && return c
        old = get_val_at(paths.read_paths, path)
        if old !== nothing
            set_val_at!(paths.read_paths, path, old + UInt32(1))
        else
            set_val_at!(paths.read_paths, path, UInt32(1))
        end
        nothing
    end
end

"""
Add a reader lock without conflict-checking (used when cloning a read tracker).
Mirrors `add_reader_unchecked`.
"""
function stp_add_reader_unchecked!(stp::SharedTrackerPaths, path::AbstractVector{UInt8})
    _with_paths(stp) do paths
        old = get_val_at(paths.read_paths, path)
        if old !== nothing
            set_val_at!(paths.read_paths, path, old + UInt32(1))
        else
            set_val_at!(paths.read_paths, path, UInt32(1))
        end
    end
end

"""
Remove a write lock at `path`.
Mirrors `remove_lock` for `TrackingWrite`.
"""
function stp_remove_writer!(stp::SharedTrackerPaths, path::AbstractVector{UInt8})
    _with_paths(stp) do paths
        # PathMap{Bool}: get_val_at returns the Bool or nothing (not found)
        get_val_at(paths.written_paths, path) === nothing &&
            error("Write lock missing at path $(path)")
        remove_val_at!(paths.written_paths, path, true)
    end
end

"""
Remove a read lock at `path` (decrement counter, prune if last reader).
Mirrors `remove_lock` for `TrackingRead`.
"""
function stp_remove_reader!(stp::SharedTrackerPaths, path::AbstractVector{UInt8})
    _with_paths(stp) do paths
        old = get_val_at(paths.read_paths, path)
        old === nothing && error("Read lock missing at path $(path)")
        if old == UInt32(1)
            remove_val_at!(paths.read_paths, path, true)
        else
            set_val_at!(paths.read_paths, path, old - UInt32(1))
        end
    end
end

# =====================================================================
# ZipperTracker{M}
# =====================================================================

"""
    ZipperTracker{M<:AbstractTrackingMode}

Accompanies a zipper and holds a path lock in a `SharedTrackerPaths` registry.
Automatically releases the lock when garbage-collected (via `finalizer`).
Mirrors `ZipperTracker<M>` in zipper_tracking.rs.
"""
mutable struct ZipperTracker{M <: AbstractTrackingMode, A <: Allocator}
    all_paths::SharedTrackerPaths{A}
    this_path::Vector{UInt8}
    _alive::Bool   # false after dismantle; prevents double-release in finalizer
end

function ZipperTracker{TrackingRead}(
    stp::SharedTrackerPaths{A}, path::AbstractVector{UInt8}
) where {A}
    c = stp_try_add_reader!(stp, path)
    c !== nothing && throw(c)
    t = ZipperTracker{TrackingRead, A}(stp, Vector{UInt8}(path), true)
    finalizer(_zt_finalize!, t)
    t
end

function ZipperTracker{TrackingWrite}(
    stp::SharedTrackerPaths{A}, path::AbstractVector{UInt8}
) where {A}
    c = stp_try_add_writer!(stp, path)
    c !== nothing && throw(c)
    t = ZipperTracker{TrackingWrite, A}(stp, Vector{UInt8}(path), true)
    finalizer(_zt_finalize!, t)
    t
end

function _zt_finalize!(t::ZipperTracker{M}) where {M}
    t._alive || return nothing
    t._alive = false
    if _tracks_writes(M())
        stp_remove_writer!(t.all_paths, t.this_path)
    else
        stp_remove_reader!(t.all_paths, t.this_path)
    end
end

"""
Explicitly release the zipper lock (mirrors Drop).
"""
function zt_release!(t::ZipperTracker)
    _zt_finalize!(t)
end

"""
    with_zipper_tracker(f, tracker::ZipperTracker)

Run `f(tracker)` and DETERMINISTICALLY release the path lock at scope exit (via
`zt_release!` in a `finally`), instead of waiting for GC to run the finalizer.

ZT-1 (audit 2026-06-04): Julia `finalizer`s run at GC time (non-deterministic), NOT at
scope exit like Rust `Drop`. A lock can therefore linger after the zipper is logically
done until GC collects the tracker, so a later `stp_try_add_writer!`/`reader!` may see a
spurious `Conflict`. The `finalizer` remains as a backstop, but prefer this scoped wrapper
(the deterministic-Drop equivalent) wherever a tracker's lifetime is lexically bounded.
"""
function with_zipper_tracker(f, tracker::ZipperTracker)
    try
        f(tracker)
    finally
        zt_release!(tracker)
    end
end

"""
Path being tracked.
"""
zt_path(t::ZipperTracker) = t.this_path

"""
Clone a read tracker (adds another reader entry).
"""
function Base.copy(t::ZipperTracker{TrackingRead, A}) where {A}
    stp_add_reader_unchecked!(t.all_paths, t.this_path)
    nt = ZipperTracker{TrackingRead, A}(t.all_paths, copy(t.this_path), true)
    finalizer(_zt_finalize!, nt)
    nt
end

"""
Convert a write tracker to a read tracker (atomically).  Mirrors `into_reader`.
"""
function zt_into_reader(t::ZipperTracker{TrackingWrite, A}) where {A}
    # Add reader BEFORE removing writer to avoid race
    stp_add_reader_unchecked!(t.all_paths, t.this_path)
    all_paths = t.all_paths
    this_path = copy(t.this_path)
    t._alive = false  # prevent finalizer from double-removing
    stp_remove_writer!(all_paths, this_path)
    nt = ZipperTracker{TrackingRead, A}(all_paths, this_path, true)
    finalizer(_zt_finalize!, nt)
    nt
end

function Base.show(io::IO, t::ZipperTracker{M}) where {M}
    print(io, "ZipperTracker{$(M)} @ $(t.this_path)")
end

# =====================================================================
# PathStatus (always compiled, cf feature = "zipper_tracking" in Rust)
# =====================================================================

"""
    PathStatus

Returned by `stp_path_status`: whether a path is available for
reading + writing, reading only, or completely unavailable.
"""
@enum PathStatus begin
    PATH_STATUS_AVAILABLE = 1
    PATH_STATUS_AVAILABLE_FOR_READ = 2
    PATH_STATUS_UNAVAILABLE = 3
end

"""
    stp_path_status(stp, path) → PathStatus

Returns the current lock status of `path` in the registry.
Mirrors `SharedTrackerPaths::path_status`.
"""
function stp_path_status(stp::SharedTrackerPaths, path::AbstractVector{UInt8})::PathStatus
    _with_paths(stp) do paths
        c = _check_for_write_conflict(path, paths.written_paths)
        c !== nothing && return PATH_STATUS_UNAVAILABLE
        c = _check_for_read_conflict(path, paths.read_paths)
        c !== nothing && return PATH_STATUS_AVAILABLE_FOR_READ
        PATH_STATUS_AVAILABLE
    end
end

# =====================================================================
# Exports
# =====================================================================

export TrackingRead, TrackingWrite
export Conflict, conflict_path
export SharedTrackerPaths
export stp_try_add_writer!, stp_try_add_reader!, stp_add_reader_unchecked!
export stp_remove_writer!, stp_remove_reader!, stp_path_status
export ZipperTracker, zt_path, zt_release!, zt_into_reader, with_zipper_tracker
export PathStatus,
    PATH_STATUS_AVAILABLE, PATH_STATUS_AVAILABLE_FOR_READ, PATH_STATUS_UNAVAILABLE
