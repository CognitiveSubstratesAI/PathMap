"""
WriteZipperCore — port of `pathmap/src/write_zipper.rs` (Phase 1c).

Ports:
  - `WriteZipperCore{V,A}` struct + KeyFields-equivalent fields
  - `in_zipper_mut_static_result` / `replace_top_node` COW upgrade helpers
  - `descend_to_internal` / `mend_root` / `ascend` navigation
  - `set_val` / `remove_val` mutation primitives
  - `write_zipper` / `write_zipper_at_path` PathMap constructors
  - `set_val_at!` / `remove_val_at!` high-level PathMap API (replaces stubs)

Design notes vs Rust:
  - `MutNodeStack` (raw-ptr cursor) → `Vector{TrieNodeODRc{V,A}}` (GC refs).
    The Julia GC prevents dangling; we mutate `TrieNodeODRc.node` in-place or
    call `node_replace_child!` on the parent when an upgrade occurs.
  - `KeyFields` is inlined into the struct (no lifetime split needed).
  - `root_val: *mut Option<V>` → `pathmap.root_val` accessed via the PathMap ref.
  - Focus semantics: `focus_stack[end]` = the node CONTAINING the cursor position;
    `_wz_node_key(z)` = remaining path WITHIN that node to reach the cursor.
    (Same as Rust's `focus_stack.top()` + `key.node_key()`.)
"""

# =====================================================================
# WriteZipperCore struct
# =====================================================================

"""
    WriteZipperCore{V, A<:Allocator}

Mutable write cursor into a `PathMap`.  Corresponds to `WriteZipperCore` /
`WriteZipperUntracked` in upstream (lifetimes dropped in Julia).

Fields mirror `WriteZipperCore + KeyFields` in write_zipper.rs:

  - `pathmap`         — owning PathMap (for root replacement + root_val access)
  - `root_key_start`  — 0-indexed offset of root node's key in `prefix_buf`
  - `prefix_buf`      — full path bytes (origin prefix + traversal extension)
  - `origin_path_len` — length of the initial origin-path prefix in `prefix_buf`
  - `prefix_idx`      — 0-indexed key_start offsets, one per ancestor level
  - `focus_stack`     — TrieNodeODRc references from root down to current focus
  - `alloc`           — allocator (carried for node creation)
"""
mutable struct WriteZipperCore{V, A <: Allocator}
    pathmap::PathMap{V, A}
    root_key_start::Int                        # 0-indexed (mirrors KeyFields.root_key_start)
    prefix_buf::Vector{UInt8}              # mirrors KeyFields.prefix_buf
    origin_path_len::Int                        # mirrors origin_path.len()
    prefix_idx::Vector{Int}                # 0-indexed per level (mirrors KeyFields.prefix_idx)
    focus_stack::Vector{TrieNodeODRc{V, A}}  # mirrors MutNodeStack
    alloc::A
end

const WriteZipperUntracked{V, A} = WriteZipperCore{V, A}

# =====================================================================
# Key helpers
# =====================================================================
#
# Mirror KeyFields methods: node_key_start, node_key, parent_key, excess_key_len

@inline function _wz_node_key_start(z::WriteZipperCore)
    isempty(z.prefix_idx) ? z.root_key_start : z.prefix_idx[end]
end

@inline function _wz_node_key(z::WriteZipperCore)
    ks = _wz_node_key_start(z)
    view(z.prefix_buf, (ks + 1):length(z.prefix_buf))
end

@inline _wz_at_root(z::WriteZipperCore) = isempty(_wz_node_key(z))

# Key from the grandparent to the current focus (used by _wz_replace_top_node!)
# Mirrors KeyFields.parent_key()
@inline function _wz_parent_key(z::WriteZipperCore)
    ks = length(z.prefix_idx) > 1 ? z.prefix_idx[end - 1] : z.root_key_start
    ke = _wz_node_key_start(z)   # 0-indexed end (exclusive in Rust → inclusive at ke in Julia)
    view(z.prefix_buf, (ks + 1):ke)
end

# =====================================================================
# _wz_replace_top_node! — COW upgrade when a node needs replacement
# =====================================================================
#
# Mirrors `replace_top_node` in write_zipper.rs (lines 2373-2388).
# When `node_set_val!` / `node_set_branch!` returns a `TrieNodeODRc`
# replacement (LineListNode → DenseByteNode upgrade), we:
#   depth > 1 : pop, tell parent to replace its child slot, re-push new_rc
#   depth == 1: update pathmap.root directly

function _wz_replace_top_node!(
    z::WriteZipperCore{V, A}, new_rc::TrieNodeODRc{V, A}
) where {V, A}
    if length(z.focus_stack) > 1
        pop!(z.focus_stack)
        parent_node = z.focus_stack[end].node
        pk = collect(_wz_parent_key(z))          # parent_key as owned Vector
        node_replace_child!(parent_node, pk, new_rc)
        push!(z.focus_stack, new_rc)
    else
        # At root: update PathMap.root and the stack root entry
        z.pathmap.root = new_rc
        z.focus_stack[1] = new_rc
    end
end

# =====================================================================
# _wz_parent_key_for_level — key bytes navigating from level k-1 to k
# =====================================================================

@inline function _wz_parent_key_for_level(z::WriteZipperCore, k::Int)
    # k is 1-indexed, k >= 2. Returns the byte slice that the parent node
    # at focus_stack[k-1] uses to reach focus_stack[k].
    key_start = k == 2 ? z.root_key_start : z.prefix_idx[k - 2]
    key_end = z.prefix_idx[k - 1]
    view(z.prefix_buf, (key_start + 1):key_end)
end

# =====================================================================
# _wz_ensure_write_unique! — lazy COW path uniquification
# =====================================================================
#
# Implements A.0004 "Scouting WriteZipper" lazy-COW semantics.
# Descent (in _wz_descend_to_internal!) is read-only — no cloning happens.
# This function is called at every mutation entry point to ensure the
# entire path from root to focus is uniquely owned before any write.
#
# Algorithm:
#   Walk focus_stack from root (k=1) to focus (k=end).
#   If node k has refcount > 1: call make_unique! (clones inner node in-place).
#   If parent (k-1) was just cloned: its clone_self used deepcopy, so its
#     child slot points to a fresh copy, not our focus_stack[k]. Re-link.

function _wz_ensure_write_unique!(z::WriteZipperCore{V, A}) where {V, A}
    n = length(z.focus_stack)
    n == 0 && return nothing
    parent_was_cloned = false
    for k in 1:n
        rc = z.focus_stack[k]
        rc.node === nothing && break
        was_cloned = false
        if refcount(rc) > 1
            # Explicitly shared via copy(): safe to modify rc's fields in-place.
            # make_unique! decrements the shared refcount and replaces rc.node.
            make_unique!(rc)
            was_cloned = true
        elseif parent_was_cloned
            # Transitively shared: refcount==1 but an ancestor was just cloned,
            # so the original ancestor's subtrie STILL references this TrieNodeODRc
            # via the original (pre-clone) inner node's child slot.
            # We CANNOT modify rc.node in-place — that would alias m1's subtrie.
            # Create a completely new TrieNodeODRc so we leave rc (and m1) untouched.
            new_rc = clone_self(rc.node)   # new TrieNodeODRc, refcount=1, fresh inner node
            z.focus_stack[k] = new_rc
            rc = new_rc
            was_cloned = true
        end
        # Parent was cloned (its inner node is a fresh deepcopy) — the deepcopy's
        # child slot holds a stale copy, not our focus_stack[k]. Re-link the parent
        # to point to the real (now unique) rc.
        if parent_was_cloned && k > 1
            pk = collect(_wz_parent_key_for_level(z, k))
            node_replace_child!(z.focus_stack[k - 1].node, pk, rc)
        end
        parent_was_cloned = was_cloned
    end
end

# =====================================================================
# _wz_in_mut_static_result! — try mutation, handle upgrade
# =====================================================================
#
# Mirrors `in_zipper_mut_static_result` (write_zipper.rs line 2134).
# Calls `node_f(focus_node, key)`.  If the result is a TrieNodeODRc
# (upgrade), replaces the top node and calls `retry_f`.

function _wz_in_mut_static_result!(
    z::WriteZipperCore{V, A}, node_f::Function, retry_f::Function
) where {V, A}
    _wz_ensure_write_unique!(z)
    key = collect(_wz_node_key(z))
    focus_node = z.focus_stack[end].node
    result = node_f(focus_node, key)
    if result isa TrieNodeODRc
        _wz_replace_top_node!(z, result)
        new_focus = z.focus_stack[end].node
        retry_f(new_focus, key)
    else
        result
    end
end

# =====================================================================
# _wz_descend_to_internal! — follow prefix_buf, pushing nodes
# =====================================================================
#
# Mirrors `descend_to_internal` (write_zipper.rs line 2317).
# WriteZipper stops descending when < 2 bytes remain (node_key >= 1 byte
# must remain for the focus-holds-parent invariant).

function _wz_descend_to_internal!(z::WriteZipperCore{V, A}) where {V, A}
    key_start = _wz_node_key_start(z)
    key = view(z.prefix_buf, (key_start + 1):length(z.prefix_buf))
    length(key) < 2 && return nothing

    while true
        focus_node = z.focus_stack[end].node
        # `focus_node` is abstract (`TrieNodeODRc.node::Union{Nothing,AbstractTrieNode}`), so this
        # dispatch is dynamic and infers `Any` — the assertion pins the concrete return (all 4
        # node_get_child methods return exactly this), stabilizing `consumed`/`child_rc` and killing
        # the downstream `length`/`>=`/`+`/`view` dynamic-dispatch cascade. Semantic no-op.
        result = node_get_child(focus_node, key)::Union{Nothing, Tuple{Int, TrieNodeODRc{V, A}}}
        result === nothing && break
        consumed, child_rc = result
        # Only descend if there are bytes remaining AFTER consuming this child's key
        consumed >= length(key) && break
        key_start += consumed
        push!(z.prefix_idx, key_start)
        push!(z.focus_stack, child_rc)
        key = view(z.prefix_buf, (key_start + 1):length(z.prefix_buf))
        length(key) < 2 && break   # must keep >= 1 byte as node_key
    end
end

# =====================================================================
# _wz_mend_root! — regularize after subnode creation above origin root
# =====================================================================
#
# Mirrors `mend_root` (write_zipper.rs line 2298).
# Only active when origin_path_len > 1 and focus is at the root level.
# For write_zipper(m) / write_zipper_at_path with origin_path_len = 0,
# this is always a no-op.

function _wz_mend_root!(z::WriteZipperCore{V, A}) where {V, A}
    (isempty(z.prefix_idx) && z.origin_path_len > 1) || return nothing
    length(z.focus_stack) == 1 || return nothing
    root_prefix = view(z.prefix_buf, 1:z.origin_path_len)
    nks = z.root_key_start
    nks >= length(root_prefix) && return nothing
    root_slice = view(root_prefix, (nks + 1):length(root_prefix))
    root_rc = z.focus_stack[1]
    # Traverse root_slice to find the deepest reachable node
    (final_rc, remaining, _) = node_along_path(root_rc, root_slice, nothing, true)
    if length(remaining) < length(root_slice)
        z.root_key_start += length(root_slice) - length(remaining)
    end
    z.focus_stack[1] = final_rc
end

# =====================================================================
# wz_set_val! — set a value at the cursor position
# =====================================================================
#
# Mirrors WriteZipperCore::set_val (write_zipper.rs line 1345).

"""
    wz_set_val!(z::WriteZipperCore, val) -> Union{Nothing, V}

Set the value at the zipper's current cursor position.  Returns the
previously stored value (or `nothing`).  Handles COW node upgrades
transparently.  Mirrors upstream `WriteZipperCore::set_val`.
"""
function wz_set_val!(z::WriteZipperCore{V, A}, val::V) where {V, A}
    nk = _wz_node_key(z)
    if isempty(nk)
        # At root: write directly to PathMap.root_val
        old_val = z.pathmap.root_val
        z.pathmap.root_val = val
        return old_val
    end

    (old_val, created_subnode) = _wz_in_mut_static_result!(
        z, (node, key) -> node_set_val!(node, key, val), (_node, _key) -> (nothing, true)
    )  # retry after upgrade always creates subnode

    if created_subnode
        _wz_mend_root!(z)
        _wz_descend_to_internal!(z)
    end
    old_val
end

# =====================================================================
# wz_remove_val! — remove the value at the cursor position
# =====================================================================
#
# Mirrors WriteZipperCore::remove_val (write_zipper.rs line 1362).
# No COW upgrade is needed for removal.

"""
    wz_remove_val!(z::WriteZipperCore, prune::Bool=false) -> Union{Nothing, V}

Remove the value at the zipper's current cursor position.  If `prune`
is true, empty dangling paths are pruned.  Mirrors `remove_val`.
"""
function wz_remove_val!(z::WriteZipperCore{V, A}, prune::Bool=false) where {V, A}
    nk = collect(_wz_node_key(z))
    if isempty(nk)
        old_val = z.pathmap.root_val
        z.pathmap.root_val = nothing
        return old_val
    end
    _wz_ensure_write_unique!(z)
    focus_node = z.focus_stack[end].node
    old_val = node_remove_val!(focus_node, nk, prune)
    prune && old_val !== nothing && wz_prune_path!(z)
    old_val
end

# =====================================================================
# wz_descend_to! — navigate the write zipper to a sub-path
# =====================================================================
#
# Mirrors ZipperMoving::descend_to (write_zipper.rs line 1005).

"""
    wz_descend_to!(z::WriteZipperCore, k) -> nothing

Extend the cursor's path by `k` bytes and descend as far as possible
through existing trie nodes.  Mirrors `descend_to`.
"""
function wz_descend_to!(z::WriteZipperCore, k)
    isempty(k) && return nothing
    append!(z.prefix_buf, k)
    _wz_descend_to_internal!(z)
    nothing
end

# =====================================================================
# wz_ascend! — move cursor up N bytes
# =====================================================================
#
# Mirrors ZipperMoving::ascend (write_zipper.rs line 1012).

"""
    wz_ascend!(z::WriteZipperCore, steps::Int=1) -> Bool

Ascend `steps` bytes toward the zipper root.  Returns `true` on success,
`false` if the zipper is already at the root.  Mirrors `ascend`.
"""
function wz_ascend!(z::WriteZipperCore, steps::Int=1)
    while true
        if isempty(_wz_node_key(z))
            # ascend_across_nodes: pop ancestor level if possible (no-op at root)
            if !isempty(z.prefix_idx)
                pop!(z.focus_stack)
                pop!(z.prefix_idx)
            end
        end
        steps == 0 && return true
        _wz_at_root(z) && return false
        cur_jump = min(steps, length(_wz_node_key(z)))
        resize!(z.prefix_buf, length(z.prefix_buf) - cur_jump)
        steps -= cur_jump
    end
end

# =====================================================================
# Read-like queries on WriteZipperCore
# =====================================================================

"""
    wz_path_exists(z::WriteZipperCore) -> Bool

True iff the trie contains any path starting at the cursor.
Mirrors `path_exists`.
"""
function wz_path_exists(z::WriteZipperCore{V, A}) where {V, A}
    nk = _wz_node_key(z)
    isempty(nk) && return true
    focus_node = z.focus_stack[end].node
    node_contains_partial_key(focus_node, nk)
end

"""
    wz_is_val(z::WriteZipperCore) -> Bool

True iff there is a value at the cursor position.  Mirrors `is_val`.
"""
function wz_is_val(z::WriteZipperCore{V, A}) where {V, A}
    nk = _wz_node_key(z)
    if isempty(nk)
        return !isnothing(z.pathmap.root_val)
    end
    focus_node = z.focus_stack[end].node
    node_contains_val(focus_node, nk)
end

"""
    wz_get_val(z::WriteZipperCore) -> Union{Nothing, V}

Return the value at the cursor position (or `nothing`).  Mirrors `val`.
"""
function wz_get_val(z::WriteZipperCore{V, A}) where {V, A}
    nk = collect(_wz_node_key(z))
    if isempty(nk)
        return z.pathmap.root_val
    end
    focus_node = z.focus_stack[end].node
    node_get_val(focus_node, nk)
end

# path relative to the zipper's origin
wz_path(z::WriteZipperCore) =
    view(z.prefix_buf, (z.origin_path_len + 1):length(z.prefix_buf))

# =====================================================================
# PathMap write zipper constructors
# =====================================================================
#
# Mirrors PathMap::write_zipper / write_zipper_at_path (trie_map.rs).

"""
    write_zipper(m::PathMap) -> WriteZipperCore

Create a write zipper at the root of `m`.  Mirrors `PathMap::write_zipper`.
"""
function write_zipper(m::PathMap{V, A}) where {V, A}
    _ensure_root!(m)
    root_rc = m.root::TrieNodeODRc{V, A}
    # Fix 2: pre-allocate prefix_buf and prefix_idx to eliminate _growend!/memmove
    # in wz_descend_to! hot path.  EXPECTED_PATH_LEN / EXPECTED_DEPTH from Zipper.jl.
    WriteZipperCore{V, A}(
        m,
        0,                                                     # root_key_start (0-indexed)
        sizehint!(UInt8[], EXPECTED_PATH_LEN),                 # prefix_buf pre-allocated
        0,                                                     # origin_path_len
        sizehint!(Int[], EXPECTED_DEPTH),                      # prefix_idx pre-allocated
        TrieNodeODRc{V, A}[root_rc],                           # focus_stack: [root]
        m.alloc
    )
end

"""
    write_zipper_at_path(m::PathMap, path) -> WriteZipperCore

Create a write zipper pre-positioned at `path`.
Mirrors `PathMap::write_zipper_at_path`.
"""
function write_zipper_at_path(m::PathMap{V, A}, path) where {V, A}
    _ensure_root!(m)
    path_v = collect(UInt8, path)
    if isempty(path_v)
        return write_zipper(m)
    end
    root_rc = m.root::TrieNodeODRc{V, A}
    # Build zipper with full path as prefix_buf, then descend
    # root_key_start = 0 (origin is at the absolute map root)
    # Fix 2: pre-allocate prefix_idx; path_v already has capacity from collect.
    length(path_v) < EXPECTED_PATH_LEN && sizehint!(path_v, EXPECTED_PATH_LEN)
    z = WriteZipperCore{V, A}(
        m,
        0,
        path_v,                                     # prefix_buf = path (pre-allocated)
        length(path_v),                             # origin_path_len = path.len()
        sizehint!(Int[], EXPECTED_DEPTH),           # prefix_idx pre-allocated
        TrieNodeODRc{V, A}[root_rc],
        m.alloc
    )
    _wz_descend_to_internal!(z)
    z
end

# =====================================================================
# PathMap high-level write API  (replaces stubs in Zipper.jl)
# =====================================================================

"""
    set_val_at!(m::PathMap, path, val) -> Union{Nothing, V}

Set the value at `path` in `m`.  Returns the previously stored value.
`path` may be a `Vector{UInt8}`, `AbstractVector{UInt8}`, `AbstractString`,
or any other byte-iterable; no intermediate copy is made.
"""
function set_val_at!(m::PathMap{V, A}, path::AbstractVector{UInt8}, val::V) where {V, A}
    z = write_zipper(m)
    wz_descend_to!(z, path)
    wz_set_val!(z, val)
end
function set_val_at!(m::PathMap{V, A}, path::AbstractString, val::V) where {V, A}
    set_val_at!(m, codeunits(path), val)
end
function set_val_at!(m::PathMap{V, A}, path, val::V) where {V, A}
    set_val_at!(m, collect(UInt8, path), val)
end

"""
    remove_val_at!(m::PathMap, path, prune::Bool=false) -> Union{Nothing, V}

Remove the value at `path` in `m`.  Returns the removed value.
"""
function remove_val_at!(
    m::PathMap{V, A}, path::AbstractVector{UInt8}, prune::Bool=false
) where {V, A}
    m.root === nothing && return nothing
    z = write_zipper_at_path(m, path)
    wz_remove_val!(z, prune)
end
function remove_val_at!(
    m::PathMap{V, A}, path::AbstractString, prune::Bool=false
) where {V, A}
    remove_val_at!(m, codeunits(path), prune)
end
function remove_val_at!(m::PathMap{V, A}, path, prune::Bool=false) where {V, A}
    remove_val_at!(m, collect(UInt8, path), prune)
end

# =====================================================================
# _wz_get_focus_anr — get AbstractNodeRef at cursor position
# =====================================================================
#
# Mirrors WriteZipperCore::get_focus (write_zipper.rs:1231).
# Non-root: delegate to get_node_at_key on the focus node.
# At root: wrap the root TrieNodeODRc as ANRBorrowedRc.

function _wz_get_focus_anr(z::WriteZipperCore{V, A}) where {V, A}
    nk = collect(_wz_node_key(z))
    if isempty(nk)
        ANRBorrowedRc{V, A}(z.focus_stack[1])
    else
        get_node_at_key(z.focus_stack[end].node, nk)
    end
end

# =====================================================================
# _wz_remove_branches! — remove all branches at cursor
# =====================================================================
#
# Mirrors WriteZipperCore::remove_branches (write_zipper.rs:1948).
function _wz_remove_branches!(z::WriteZipperCore{V, A}, prune::Bool) where {V, A}
    _wz_ensure_write_unique!(z)
    nk = collect(_wz_node_key(z))
    if !isempty(nk)
        focus_node = z.focus_stack[end].node
        removed = node_remove_all_branches!(focus_node, nk, prune)
        removed && prune && _wz_prune_path_internal!(z)
        removed
    else
        @assert length(z.focus_stack) == 1
        if node_is_empty(z.focus_stack[1].node)
            return false
        end
        empty_rc = TrieNodeODRc(LineListNode{V, A}(z.alloc), z.alloc)
        z.pathmap.root = empty_rc
        z.focus_stack[1] = empty_rc
        true
    end
end

# =====================================================================
# _wz_graft_internal! — plant src at cursor (core of all lattice ops)
# =====================================================================
#
# Mirrors WriteZipperCore::graft_internal (write_zipper.rs:2101).
# src === nothing → _wz_remove_branches!
# at root (node_key empty) → direct stack/pathmap root replacement
# otherwise → node_set_branch! via _wz_in_mut_static_result!

function _wz_graft_internal!(
    z::WriteZipperCore{V, A}, src::Union{Nothing, TrieNodeODRc{V, A}}
) where {V, A}
    if src !== nothing
        nk = collect(_wz_node_key(z))
        if !isempty(nk)
            sub_branch_added = _wz_in_mut_static_result!(
                z, (node, key) -> node_set_branch!(node, key, src), (_, _) -> true
            )
            if sub_branch_added
                _wz_mend_root!(z)
                _wz_descend_to_internal!(z)
            end
        else
            z.pathmap.root = src
            z.focus_stack[1] = src
        end
    else
        _wz_remove_branches!(z, false)
    end
end

# =====================================================================
# wz_graft! / wz_graft_map! — unconditional subtrie replacement
# =====================================================================
#
# Mirrors WriteZipperCore::graft / graft_map (write_zipper.rs:1401/1411).
# graft_root_vals feature not enabled — root val handling omitted.

"""
    wz_graft!(z, src_anr)

Replace the subtrie at the cursor with `src_anr`'s subtrie.
"""
function wz_graft!(z::WriteZipperCore{V, A}, src_anr::AbstractNodeRef{V, A}) where {V, A}
    _wz_graft_internal!(z, into_option(src_anr))
end

"""
    wz_graft_map!(z, map)

Replace the subtrie at the cursor with `map`'s root node.
"""
function wz_graft_map!(z::WriteZipperCore{V, A}, map::PathMap{V, A}) where {V, A}
    # copy() bumps the refcount so both map and the graft site track sharing;
    # make_unique! at write time will then COW-clone before any mutation.
    src = map.root !== nothing ? copy(map.root) : nothing
    _wz_graft_internal!(z, src)
end

# =====================================================================
# wz_join_into! — pjoin self with src, result stored in self
# =====================================================================
#
# Mirrors WriteZipperCore::join_into (write_zipper.rs:1499).
# Returns AlgebraicStatus.

"""
    wz_join_into!(z, src_anr) -> AlgebraicStatus

Join (lattice-sup) self's subtrie with `src_anr`. Result written to self.
"""
function wz_join_into!(
    z::WriteZipperCore{V, A}, src_anr::AbstractNodeRef{V, A}
) where {V, A}
    if is_none(src_anr) || node_is_empty(as_tagged(src_anr))
        focus_anr = _wz_get_focus_anr(z)
        return if (is_none(focus_anr) || node_is_empty(as_tagged(focus_anr)))
            ALG_STATUS_NONE
        else
            ALG_STATUS_IDENTITY
        end
    end
    focus_anr = _wz_get_focus_anr(z)
    if is_none(focus_anr)
        _wz_graft_internal!(z, into_option(src_anr))
        return ALG_STATUS_ELEMENT
    end
    self_node = as_tagged(focus_anr)
    if node_is_empty(self_node)
        _wz_graft_internal!(z, into_option(src_anr))
        return ALG_STATUS_ELEMENT
    end
    result = pjoin_dyn(self_node, as_tagged(src_anr))
    if result isa AlgResElement
        _wz_graft_internal!(z, result.value)
        ALG_STATUS_ELEMENT
    elseif result isa AlgResIdentity
        if result.mask & SELF_IDENT > 0
            ALG_STATUS_IDENTITY
        else
            (_wz_graft_internal!(z, into_option(src_anr)); ALG_STATUS_ELEMENT)
        end
    else
        _wz_graft_internal!(z, nothing)
        ALG_STATUS_NONE
    end
end

# =====================================================================
# wz_join_map_into! — pjoin self with PathMap, result stored in self
# =====================================================================
#
# Mirrors WriteZipperCore::join_map_into (write_zipper.rs:1535).

"""
    wz_join_map_into!(z, map) -> AlgebraicStatus

Join self's subtrie with `map`. Result written to self.
"""
function wz_join_map_into!(z::WriteZipperCore{V, A}, map::PathMap{V, A}) where {V, A}
    src_rc = map.root
    if src_rc === nothing
        focus_anr = _wz_get_focus_anr(z)
        return if (is_none(focus_anr) || node_is_empty(as_tagged(focus_anr)))
            ALG_STATUS_NONE
        else
            ALG_STATUS_IDENTITY
        end
    end
    focus_anr = _wz_get_focus_anr(z)
    if is_none(focus_anr)
        _wz_graft_internal!(z, copy(src_rc))
        return ALG_STATUS_ELEMENT
    end
    self_node = as_tagged(focus_anr)
    if node_is_empty(self_node)
        _wz_graft_internal!(z, copy(src_rc))
        return ALG_STATUS_ELEMENT
    end
    result = pjoin_dyn(self_node, src_rc.node)
    if result isa AlgResElement
        _wz_graft_internal!(z, result.value)
        ALG_STATUS_ELEMENT
    elseif result isa AlgResIdentity
        # src_rc is from map.root — copy() so both map and graft site track sharing
        if result.mask & SELF_IDENT > 0
            ALG_STATUS_IDENTITY
        else
            (_wz_graft_internal!(z, copy(src_rc)); ALG_STATUS_ELEMENT)
        end
    else
        _wz_graft_internal!(z, nothing)
        ALG_STATUS_NONE
    end
end

# =====================================================================
# wz_meet_into! — pmeet self with src, result stored in self
# =====================================================================
#
# Mirrors WriteZipperCore::meet_into (write_zipper.rs:1718).

"""
    wz_meet_into!(z, src_anr, prune=false) -> AlgebraicStatus

Meet (lattice-inf) self's subtrie with `src_anr`. Result written to self.
`prune=true` removes empty dangling ancestor paths after the operation.

**Shared-node short-circuit**: when both sides point to the same trie node
(identical `objectid`), A ∩ A = A — returns `ALG_STATUS_IDENTITY` immediately
without any DFS traversal. Mirrors upstream PathMap commit `ade1e1b`
("short-circuit on shared subtries") in `experimental/zipper_algebra.rs`.

Mirrors `WriteZipperCore::meet_into` (write_zipper.rs:1718).
"""
function wz_meet_into!(
    z::WriteZipperCore{V, A}, src_anr::AbstractNodeRef{V, A}, prune::Bool=false
) where {V, A}
    focus_anr = _wz_get_focus_anr(z)
    if is_none(focus_anr) || node_is_empty(as_tagged(focus_anr))
        return ALG_STATUS_NONE
    end
    if is_none(src_anr)
        _wz_graft_internal!(z, nothing)
        prune && wz_prune_path!(z)
        return ALG_STATUS_NONE
    end
    # Shared-node short-circuit: A ∩ A = A (identity — self unchanged).
    _check_anr_sharing(focus_anr, src_anr) && return ALG_STATUS_IDENTITY
    self_node = as_tagged(focus_anr)
    result = pmeet_dyn(self_node, as_tagged(src_anr))
    if result isa AlgResElement
        _wz_graft_internal!(z, result.value)
        ALG_STATUS_ELEMENT
    elseif result isa AlgResIdentity
        if result.mask & SELF_IDENT > 0
            ALG_STATUS_IDENTITY
        else
            (_wz_graft_internal!(z, into_option(src_anr)); ALG_STATUS_ELEMENT)
        end
    else
        _wz_graft_internal!(z, nothing)
        prune && wz_prune_path!(z)
        ALG_STATUS_NONE
    end
end

# =====================================================================
# wz_subtract_into! — psubtract src from self, result stored in self
# =====================================================================
#
# Mirrors WriteZipperCore::subtract_into (write_zipper.rs:1829).

"""
    wz_subtract_into!(z, src_anr, prune=false) -> AlgebraicStatus

Subtract `src_anr` from self's subtrie. Result written to self.
`prune=true` removes empty dangling paths after the operation.

**Shared-node short-circuit**: when both sides point to the same trie node
(identical `objectid`), A − A = ∅ — grafts nothing and returns `ALG_STATUS_NONE`
immediately without any DFS traversal. Mirrors upstream PathMap commit `ade1e1b`
("short-circuit on shared subtries") in `experimental/zipper_algebra.rs`.

Mirrors `WriteZipperCore::subtract_into` (write_zipper.rs:1829).
"""
function wz_subtract_into!(
    z::WriteZipperCore{V, A}, src_anr::AbstractNodeRef{V, A}, prune::Bool=false
) where {V, A}
    focus_anr = _wz_get_focus_anr(z)
    self_empty = is_none(focus_anr) || node_is_empty(as_tagged(focus_anr))
    if is_none(src_anr)
        return self_empty ? ALG_STATUS_NONE : ALG_STATUS_IDENTITY
    end
    if self_empty
        return ALG_STATUS_NONE
    end
    # Shared-node short-circuit: A − A = ∅ (subtract set from itself = empty).
    if _check_anr_sharing(focus_anr, src_anr)
        _wz_graft_internal!(z, nothing)
        prune && wz_prune_path!(z)
        return ALG_STATUS_NONE
    end
    self_node = as_tagged(focus_anr)
    result = psubtract_dyn(self_node, as_tagged(src_anr))
    if result isa AlgResElement
        _wz_graft_internal!(z, result.value)
        ALG_STATUS_ELEMENT
    elseif result isa AlgResIdentity
        ALG_STATUS_IDENTITY   # subtract is non-commutative → only SELF_IDENT possible
    else
        _wz_graft_internal!(z, nothing)
        prune && wz_prune_path!(z)
        ALG_STATUS_NONE
    end
end

# =====================================================================
# wz_restrict! — prestrict self to src's domain
# =====================================================================
#
# Mirrors WriteZipperCore::restrict (write_zipper.rs:1900).

"""
    wz_restrict!(z, src_anr) -> AlgebraicStatus

Restrict self's subtrie to paths present in `src_anr`.
"""
function wz_restrict!(z::WriteZipperCore{V, A}, src_anr::AbstractNodeRef{V, A}) where {V, A}
    if is_none(src_anr)
        _wz_graft_internal!(z, nothing)
        return ALG_STATUS_NONE
    end
    focus_anr = _wz_get_focus_anr(z)
    if is_none(focus_anr)
        return ALG_STATUS_NONE
    end
    self_node = as_tagged(focus_anr)
    result = prestrict_dyn(self_node, as_tagged(src_anr))
    if result isa AlgResElement
        _wz_graft_internal!(z, result.value)
        ALG_STATUS_ELEMENT
    elseif result isa AlgResIdentity
        ALG_STATUS_IDENTITY   # restrict is non-commutative → only SELF_IDENT possible
    else
        _wz_graft_internal!(z, nothing)
        ALG_STATUS_NONE
    end
end

# =====================================================================
# wz_join_k_path_into! — drop-head / composition
# =====================================================================
#
# Mirrors WriteZipperCore::join_k_path_into (write_zipper.rs:1617).
#
# Removes the first `byte_cnt` bytes of every path below the cursor,
# collapsing (joining) any paths that collide as a result.
# This is the PathMap "composition" operation — used in MorkL's OP_DROP_HEAD
# and whenever an intermediate binding prefix needs to be erased.
#
# Returns true if any paths survive after dropping; false if the subtrie
# is empty.  When prune=true and result is false, prunes the empty path.

"""
    wz_join_k_path_into!(z, byte_cnt, prune=true) -> Bool

Remove the first `byte_cnt` bytes from every path below the cursor,
joining any paths that collide.  Returns true if the subtrie is non-empty.
Mirrors `WriteZipperCore::join_k_path_into` (write_zipper.rs:1617).
"""
function wz_join_k_path_into!(
    z::WriteZipperCore{V, A}, byte_cnt::Int, prune::Bool=true
) where {V, A}
    focus_anr = _wz_get_focus_anr(z)
    if is_none(focus_anr)
        prune && _wz_prune_path_internal!(z)
        return false
    end
    # COW: drop_head_dyn! mutates the focus subtrie IN PLACE. The focus node is
    # reached via get_node_at_key and is NOT on focus_stack, so the stack-only
    # _wz_ensure_write_unique! does not cover it. If that borrowed node is SHARED
    # (e.g. grafted in via copy(), refcount>1), make it unique first — mirroring
    # Rust `self_node.make_mut().drop_head_dyn(...)` (write_zipper.rs:1620).
    # Without this, dropping the head of a shared subtrie corrupts the SOURCE map
    # (live bug, reachable via MorkL OP_DROP_HEAD on a shared space).
    focus_rc = borrow(focus_anr)
    focus_rc !== nothing && make_unique!(focus_rc)
    self_node = as_tagged(focus_anr)
    new_node = drop_head_dyn!(self_node, byte_cnt)
    _wz_graft_internal!(z, new_node)
    result = new_node !== nothing
    prune && !result && _wz_prune_path_internal!(z)
    result
end

# =====================================================================
# wz_restricting! — stem-population (inverse restrict)
# =====================================================================
#
# Mirrors WriteZipperCore::restricting (write_zipper.rs:1927).
#
# Where wz_restrict!(z, src) keeps paths of z that have a prefix in src,
# wz_restricting!(z, src) fills z's existing structure with src content —
# arguments to prestrict_dyn are reversed (src.prestrict_dyn(self)).
# Upstream names this "GOAT" (needs better name) — it is non-commutative.

"""
    wz_restricting!(z, src_anr) -> Bool

Fill z's subtrie structure using src as the domain provider —
the inverse direction of `wz_restrict!`.
Returns true if src was non-empty and z had content.
Mirrors `WriteZipperCore::restricting` (write_zipper.rs:1927).
"""
function wz_restricting!(
    z::WriteZipperCore{V, A}, src_anr::AbstractNodeRef{V, A}
) where {V, A}
    is_none(src_anr) && return false
    focus_anr = _wz_get_focus_anr(z)
    is_none(focus_anr) && return false

    self_node = as_tagged(focus_anr)
    # Key difference from wz_restrict!: arguments to prestrict_dyn are reversed
    # Rust: src.prestrict_dyn(self_node)  vs  restrict: self_node.prestrict_dyn(src)
    result = prestrict_dyn(as_tagged(src_anr), self_node)

    if result isa AlgResElement
        _wz_graft_internal!(z, result.value)
    elseif result isa AlgResIdentity
        # src unchanged (identity from src's perspective)
        _wz_graft_internal!(z, into_option(src_anr))
    else
        _wz_graft_internal!(z, nothing)
    end
    true
end

# =====================================================================
# Exports
# =====================================================================

# =====================================================================
# ZipperMoving — navigation trait methods
# =====================================================================
#
# Ports WriteZipperCore ZipperMoving impl (write_zipper.rs:976-1075)
# and the ZipperMoving default methods in zipper.rs:232-420.
# All rely on _wz_node_key, wz_descend_to!, wz_ascend!, wz_child_mask.

"""
    wz_at_root(z) → Bool

True iff the zipper is at its origin root (path length == origin_path_len).
Mirrors `ZipperMoving::at_root`.
"""
@inline wz_at_root(z::WriteZipperCore) = length(z.prefix_buf) <= z.origin_path_len

"""
    wz_reset!(z) → nothing

Reset the zipper to its origin root.
Mirrors `WriteZipperCore::reset` (write_zipper.rs:982).
"""
function wz_reset!(z::WriteZipperCore{V, A}) where {V, A}
    # Pop back to root frame
    while length(z.focus_stack) > 1
        pop!(z.focus_stack)
    end
    resize!(z.prefix_buf, z.origin_path_len)
    empty!(z.prefix_idx)
    nothing
end

"""
    wz_child_mask(z) → ByteMask

Returns a `ByteMask` of which byte-branches exist at the cursor position.
Mirrors `WriteZipperCore::child_mask` (write_zipper.rs:922).
"""
function wz_child_mask(z::WriteZipperCore{V, A}) where {V, A}
    isempty(z.focus_stack) && return ByteMask()
    focus_node = z.focus_stack[end].node
    nk = collect(_wz_node_key(z))
    if isempty(nk)
        return node_branches_mask(focus_node, UInt8[])
    end
    result = node_get_child(focus_node, nk)
    if result !== nothing
        consumed, child_rc = result
        child_node = as_tagged(child_rc)
        if length(nk) >= consumed
            return node_branches_mask(child_node, nk[(consumed + 1):end])
        else
            return ByteMask()
        end
    end
    node_branches_mask(focus_node, nk)
end

"""
    wz_child_count(z) → Int

Returns the number of byte-branches at the cursor position.
Mirrors `WriteZipperCore::child_count` (write_zipper.rs:914).
"""
function wz_child_count(z::WriteZipperCore{V, A}) where {V, A}
    isempty(z.focus_stack) && return 0
    focus_node = z.focus_stack[end].node
    nk = collect(_wz_node_key(z))
    count_branches(focus_node, nk)
end

"""
    wz_val_count(z) → Int

Returns the number of values in the subtrie rooted at the cursor.
Mirrors `WriteZipperCore::val_count` (write_zipper.rs:997).
"""
function wz_val_count(z::WriteZipperCore{V, A}) where {V, A}
    root_val = wz_is_val(z) ? 1 : 0
    focus_anr = _wz_get_focus_anr(z)
    is_none(focus_anr) && return root_val
    val_count_below_root(as_tagged(focus_anr)) + root_val
end

"""
    wz_descend_to_byte!(z, k::UInt8) → nothing

Descend the cursor one byte into child `k`.
Default impl: descend_to([k]).  Mirrors ZipperMoving::descend_to_byte.
"""
@inline function wz_descend_to_byte!(z::WriteZipperCore, k::UInt8)
    wz_descend_to!(z, UInt8[k])
end

"""
    wz_descend_indexed_byte!(z, idx::Int) → Bool

Descend to the `idx`-th child (0-based) in byte order.
Returns `false` if `idx >= child_count`.
Mirrors ZipperMoving::descend_indexed_byte (zipper.rs:256).
"""
function wz_descend_indexed_byte!(z::WriteZipperCore, idx::Int)
    mask = wz_child_mask(z)
    child_byte = indexed_bit(mask, idx, true)
    child_byte === nothing && return false
    wz_descend_to_byte!(z, child_byte)
    true
end

"""
    wz_descend_first_byte!(z) → Bool

Descend to the first (lexicographically smallest) child.
Mirrors ZipperMoving::descend_first_byte (zipper.rs:279).
"""
@inline wz_descend_first_byte!(z::WriteZipperCore) = wz_descend_indexed_byte!(z, 0)

"""
    wz_ascend_byte!(z) → Bool

Ascend exactly one byte.  Returns `false` if already at root.
Mirrors ZipperMoving::ascend_byte (zipper.rs:340).
"""
@inline wz_ascend_byte!(z::WriteZipperCore) = wz_ascend!(z, 1)

"""
    wz_to_next_sibling_byte!(z) → Bool

Move to the next sibling byte at the same depth.
Returns `false` if already the last sibling.
Mirrors ZipperMoving::to_next_sibling_byte (zipper.rs:364).
"""
function wz_to_next_sibling_byte!(z::WriteZipperCore)
    cur_path = wz_path(z)
    isempty(cur_path) && return false
    cur_byte = last(cur_path)
    !wz_ascend_byte!(z) && return false
    mask = wz_child_mask(z)
    next = next_bit(mask, cur_byte)
    if next !== nothing
        wz_descend_to_byte!(z, next)
        return true
    else
        wz_descend_to_byte!(z, cur_byte)
        return false
    end
end

"""
    wz_to_prev_sibling_byte!(z) → Bool

Move to the previous sibling byte at the same depth.
Returns `false` if already the first sibling.
Mirrors ZipperMoving::to_prev_sibling_byte (zipper.rs:395).
"""
function wz_to_prev_sibling_byte!(z::WriteZipperCore)
    cur_path = wz_path(z)
    isempty(cur_path) && return false
    cur_byte = last(cur_path)
    !wz_ascend_byte!(z) && return false
    mask = wz_child_mask(z)
    prev = prev_bit(mask, cur_byte)
    if prev !== nothing
        wz_descend_to_byte!(z, prev)
        return true
    else
        wz_descend_to_byte!(z, cur_byte)
        return false
    end
end

"""
    wz_take_focus!(z, prune=false) → Union{Nothing, TrieNodeODRc}

Remove and return the subtrie at the cursor.
If `prune`, empty ancestor paths are pruned.
Mirrors `WriteZipperCore::take_focus` (write_zipper.rs:2057).
"""
function wz_take_focus!(z::WriteZipperCore{V, A}, prune::Bool=false) where {V, A}
    focus_anr = _wz_get_focus_anr(z)
    is_none(focus_anr) && return nothing
    rc = into_option(focus_anr)
    rc === nothing && return nothing
    _wz_graft_internal!(z, nothing)
    prune && wz_prune_path!(z)
    rc
end

"""
    wz_take_map!(z, prune=false) → Union{Nothing, PathMap}

Remove and return a PathMap snapshot at the cursor.
Mirrors `WriteZipperCore::take_map` (write_zipper.rs:1973).
"""
function wz_take_map!(z::WriteZipperCore{V, A}, prune::Bool=false) where {V, A}
    root_node = wz_take_focus!(z, prune)
    root_node === nothing ? nothing : PathMap{V, A}(z.alloc, root_node, nothing)
end

# =====================================================================
# wz_prune_path! — remove dangling empty paths
# =====================================================================
#
# Mirrors WriteZipperCore::prune_path (write_zipper.rs:2048) +
# prune_path_internal (write_zipper.rs:2192).

"""
    wz_prune_path!(z) → Int

Remove dangling path at the cursor.  Returns bytes pruned.
Mirrors `WriteZipperCore::prune_path`.
"""
function wz_prune_path!(z::WriteZipperCore{V, A}) where {V, A}
    nk = collect(_wz_node_key(z))
    isempty(nk) && return 0
    focus_node = z.focus_stack[end].node
    node_pruned = node_remove_dangling!(focus_node, nk)
    trie_pruned = node_pruned > 0 ? _wz_prune_path_internal!(z) : 0
    max(node_pruned, trie_pruned)
end

"""
    _wz_prune_path_internal!(z) → Int

Ascend and remove empty ancestor nodes.  Internal; mirrors `prune_path_internal`.
"""
function _wz_prune_path_internal!(z::WriteZipperCore{V, A}) where {V, A}
    pruned = 0
    while true
        inner = z.focus_stack[end].node
        # node is empty if it's nothing OR its inner node says so
        is_empty = (inner === nothing) || node_is_empty(inner)
        is_empty || break
        wz_at_root(z) && break
        old_len = length(z.prefix_buf)
        wz_ascend!(z, 1) || break
        nk = collect(_wz_node_key(z))
        parent_inner = z.focus_stack[end].node
        if !isempty(nk) && parent_inner !== nothing
            node_remove_all_branches!(parent_inner, nk, true)
        end
        pruned += old_len - length(z.prefix_buf)
        parent_empty = (parent_inner === nothing) || node_is_empty(parent_inner)
        (parent_empty && !wz_is_val(z)) || break
    end
    pruned
end

# =====================================================================
# wz_remove_branches! — remove all branches at cursor
# =====================================================================
#
# Mirrors WriteZipperCore::remove_branches (write_zipper.rs:1948).

"""
    wz_remove_branches!(z, prune=false) → Bool

Remove all branches at the cursor position.
Returns `true` if any branches were removed.
Mirrors `WriteZipperCore::remove_branches`.
"""
function wz_remove_branches!(z::WriteZipperCore{V, A}, prune::Bool=false) where {V, A}
    _wz_ensure_write_unique!(z)
    nk = collect(_wz_node_key(z))
    focus_node = z.focus_stack[end].node
    if !isempty(nk)
        removed = node_remove_all_branches!(focus_node, nk, prune)
        if removed && prune
            _wz_prune_path_internal!(z)
        end
        removed
    else
        # At root: replace with empty node
        wz_at_root(z) || return false
        node_is_empty(focus_node) && return false
        empty_rc = TrieNodeODRc(LineListNode{V, A}(z.alloc), z.alloc)
        z.pathmap.root = empty_rc
        z.focus_stack[1] = empty_rc
        true
    end
end

# =====================================================================
# wz_remove_unmasked_branches! — keep only masked branches
# =====================================================================
#
# Mirrors WriteZipperCore::remove_unmasked_branches (write_zipper.rs:1975).

"""
    wz_remove_unmasked_branches!(z, mask::ByteMask, prune=false)

Remove all branches whose first byte is NOT set in `mask`.
Mirrors `WriteZipperCore::remove_unmasked_branches`.
"""
function wz_remove_unmasked_branches!(
    z::WriteZipperCore{V, A}, mask::ByteMask, prune::Bool=false
) where {V, A}
    _wz_ensure_write_unique!(z)
    nk = collect(_wz_node_key(z))
    focus_node = z.focus_stack[end].node
    node_remove_unmasked_branches!(focus_node, nk, mask, prune)
    if prune
        _wz_prune_path_internal!(z)
    end
end

# =====================================================================
# wz_create_path! — create a dangling path
# =====================================================================
#
# Mirrors WriteZipperCore::create_path (write_zipper.rs:2010).

"""
    wz_create_path!(z) → Bool

Create a dangling (no value) path at the cursor.
Returns `true` if the path was newly created.
Mirrors `WriteZipperCore::create_path`.
"""
function wz_create_path!(z::WriteZipperCore{V, A}) where {V, A}
    nk = collect(_wz_node_key(z))
    isempty(nk) && return false   # at root — can't create dangling
    (created_path, created_subnode) = _wz_in_mut_static_result!(
        z, (node, key) -> node_create_dangling!(node, key), (_, _) -> (true, true)
    )
    if created_subnode
        _wz_mend_root!(z)
        _wz_descend_to_internal!(z)
    end
    created_path
end

# =====================================================================
# _wz_make_parent_node! — wrap a child in a new node with a prefix key
# =====================================================================
#
# Mirrors `make_parents_in` (write_zipper.rs:2415).
# Creates a fresh LineListNode with `prefix` as the edge to `child_rc`.

function _wz_make_parent_node(
    prefix::Vector{UInt8}, child_rc::TrieNodeODRc{V, A}, alloc::A
) where {V, A}
    new_node = LineListNode{V, A}(alloc)
    result = node_set_branch!(new_node, prefix, child_rc)
    # node_set_branch! on a fresh empty node won't upgrade, but handle it anyway
    result isa TrieNodeODRc ? result : TrieNodeODRc(new_node, alloc)
end

# =====================================================================
# wz_insert_prefix! — prepend bytes to every path below the cursor
# =====================================================================
#
# Mirrors WriteZipperCore::insert_prefix (write_zipper.rs:1696).
# Wraps the focus subtrie in a new parent node keyed by `prefix`,
# then grafts the result back at the cursor position.
# Returns true if the focus was non-empty (operation performed).

"""
    wz_insert_prefix!(z, prefix) → Bool

Prepend `prefix` bytes to every path in the subtrie at the cursor.
E.g. cursor at `"123:"`, `insert_prefix("pet:")` → all paths become
`"123:pet:…"`.  Returns `false` if the focus is empty.
Mirrors `WriteZipperCore::insert_prefix`.
"""
function wz_insert_prefix!(z::WriteZipperCore{V, A}, prefix) where {V, A}
    prefix_v = collect(UInt8, prefix)
    focus_anr = _wz_get_focus_anr(z)
    is_none(focus_anr) && return false
    focus_rc = into_option(focus_anr)
    focus_rc === nothing && return false
    new_parent = _wz_make_parent_node(prefix_v, focus_rc, z.alloc)
    _wz_graft_internal!(z, new_parent)
    true
end

# =====================================================================
# wz_remove_prefix! — strip n bytes of prefix from paths below cursor
# =====================================================================
#
# Mirrors WriteZipperCore::remove_prefix (write_zipper.rs:1708).
# Captures the focus subtrie, ascends n bytes, then grafts the subtrie
# at the higher position — effectively removing n bytes of path prefix
# from every path below the original cursor position.
# Returns true if the zipper ascended the full n bytes.

"""
    wz_remove_prefix!(z, n::Int) → Bool

Strip `n` bytes of path prefix from every path in the subtrie at the
cursor.  E.g. cursor at `":Pam"`, `remove_prefix(4)` lifts the subtrie
up by 4 bytes.  Returns `false` if the zipper couldn't ascend `n` bytes.
Mirrors `WriteZipperCore::remove_prefix`.
"""
function wz_remove_prefix!(z::WriteZipperCore{V, A}, n::Int) where {V, A}
    downstream = into_option(_wz_get_focus_anr(z))
    fully_ascended = wz_ascend!(z, n)
    _wz_graft_internal!(z, downstream)
    fully_ascended
end

# =====================================================================
# wz_get_val_mut / wz_get_or_set_val! — val access (Julia adaptation)
# =====================================================================
#
# In Rust, get_val_mut returns &mut V.  In Julia we use a get+set pattern.
# `wz_get_val_mut` returns the current value (same as wz_get_val).
# Use wz_set_val! to write back a modified value.

"""
    wz_get_val_mut(z) → Union{Nothing, V}

Return the value at the cursor (Julia mutable equivalent: get then set_val!).
Mirrors `WriteZipperCore::get_val_mut`.
"""
wz_get_val_mut(z::WriteZipperCore) = wz_get_val(z)

"""
    wz_get_or_set_val!(z, default::V) → V

Return the value at the cursor, setting `default` if none exists.
Mirrors `WriteZipperCore::get_val_or_set_mut`.
"""
function wz_get_or_set_val!(z::WriteZipperCore{V, A}, default::V) where {V, A}
    wz_is_val(z) || wz_set_val!(z, default)
    wz_get_val(z)::V
end

# =====================================================================
# wz_join_into_take! — join and consume src subtrie
# =====================================================================
#
# Mirrors WriteZipperCore::join_into_take (write_zipper.rs:1589).

"""
    wz_join_into_take!(z, src_anr, prune=false) → AlgebraicStatus

Join `src_anr` subtrie into `z`, consuming the src.
Returns the algebraic status of the operation.
Mirrors `WriteZipperCore::join_into_take`.
"""
function wz_join_into_take!(
    z::WriteZipperCore{V, A}, src_anr::AbstractNodeRef{V, A}, prune::Bool=false
) where {V, A}
    if is_none(src_anr)
        focus_anr = _wz_get_focus_anr(z)
        return if (is_none(focus_anr) || node_is_empty(as_tagged(focus_anr)))
            ALG_STATUS_NONE
        else
            ALG_STATUS_IDENTITY
        end
    end
    src_rc = into_option(src_anr)
    src_rc === nothing && return ALG_STATUS_NONE

    self_rc = wz_take_focus!(z, false)
    if self_rc !== nothing
        # COW: join_into_dyn! mutates self in place on the byte-node path
        # (_bn_join_into!). If self was grafted/shared (refcount>1, now reachable via
        # shallow clone), make it unique first so the source is not corrupted —
        # mirrors Rust make_mut() before the in-place merge.
        make_unique!(self_rc)
        result = join_into_dyn!(self_rc.node, src_rc)
        if result isa Tuple
            status, ok_or_replacement = result
            if ok_or_replacement isa TrieNodeODRc
                _wz_graft_internal!(z, ok_or_replacement)
            else
                _wz_graft_internal!(z, self_rc)
            end
            return status
        end
        _wz_graft_internal!(z, self_rc)
        ALG_STATUS_ELEMENT
    else
        _wz_graft_internal!(z, src_rc)
        ALG_STATUS_ELEMENT
    end
end

# =====================================================================
# Exports
# =====================================================================

export WriteZipperCore, WriteZipperUntracked
export _wz_at_root, _wz_node_key, _wz_node_key_start
export _wz_parent_key_for_level, _wz_ensure_write_unique!
export wz_set_val!, wz_remove_val!
export wz_descend_to!, wz_ascend!
export wz_path_exists, wz_is_val, wz_get_val, wz_path
export write_zipper, write_zipper_at_path
export set_val_at!, remove_val_at!
export _wz_get_focus_anr, _wz_graft_internal!, _wz_remove_branches!
export wz_graft!, wz_graft_map!
export wz_join_into!, wz_join_map_into!
export wz_meet_into!, wz_subtract_into!, wz_restrict!
export wz_join_k_path_into!, wz_restricting!
export wz_at_root, wz_reset!
export wz_child_mask, wz_child_count, wz_val_count
export wz_descend_to_byte!, wz_descend_indexed_byte!
export wz_descend_first_byte!, wz_ascend_byte!
export wz_to_next_sibling_byte!, wz_to_prev_sibling_byte!
export wz_take_focus!, wz_take_map!
export wz_prune_path!, _wz_prune_path_internal!
export wz_remove_branches!, wz_remove_unmasked_branches!
export wz_create_path!
export wz_get_val_mut, wz_get_or_set_val!
export wz_insert_prefix!, wz_remove_prefix!
export wz_join_into_take!
export tr_get_focus_anr
