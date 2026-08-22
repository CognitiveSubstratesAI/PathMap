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

# Mirrors `WriteZipperCore::at_root` (write_zipper.rs:1002):
#     self.key.prefix_buf.len() <= self.key.origin_path.len()
#
# ⚠️ This USED to read `isempty(_wz_node_key(z))`, which is a DIFFERENT predicate: it asks
# "is the cursor at a node boundary", not "is the cursor back at the zipper's origin". The two
# agree whenever `origin_path_len == 0` (a zipper from `write_zipper(m)`), which is why every
# MORK call site was unaffected and the bug stayed invisible — but for a zipper built by
# `write_zipper_at_path(m, path)` the origin bytes sit in `prefix_buf` with `root_key_start = 0`,
# so `_wz_node_key` is NON-empty at the origin and `wz_ascend!` would truncate straight THROUGH
# the zipper's own root into the absolute path. That made `wz_remove_prefix!(wz, 1)` at a focus of
# `"foo:"` rewrite `foo:bar` to `foobar`, where upstream leaves the map untouched and returns
# false. Pinned by `prefix/remove_prefix_ret_at_origin` (upstream `false`) with
# `prefix/remove_prefix_below_origin*` as the control proving ascend must still move when the
# focus is BELOW its origin. `_wz_prune_path_internal!` had already worked around this by
# hand-guarding with the correct predicate instead of fixing it.
@inline _wz_at_root(z::WriteZipperCore) = length(z.prefix_buf) <= z.origin_path_len

# Mirrors `KeyFields::excess_key_len` (write_zipper.rs:2666-2667):
#     self.prefix_buf.len() - self.prefix_idx.last().unwrap_or(self.origin_path.len())
# Upstream's own doc: "the number of chars that can be LEGALLY ascended within the node, taking
# into account the root_key".
#
# ⚠️ This is NOT `length(_wz_node_key(z))`, and the difference is the whole point: `node_key_start`
# (:2650) falls back to `root_key_start`, this falls back to `origin_path_len`. `ascend` caps each
# jump with THIS one (:1048), so capping with the node key lets a SINGLE jump truncate straight
# past the zipper's origin even when the `_wz_at_root` guard is correct — the guard is only tested
# BETWEEN jumps. Pinned by `ascend/over_ascend_*`.
@inline function _wz_excess_key_len(z::WriteZipperCore)
    length(z.prefix_buf) - (isempty(z.prefix_idx) ? z.origin_path_len : z.prefix_idx[end])
end

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
        # At the STACK root — which is the MAP's root only while `root_key_start == 0`.
        #
        # ⚠️ `_wz_mend_root!` re-points `focus_stack[1]` at an INNER node (advancing
        # `root_key_start`) whenever a subnode gets created above the origin. Assigning
        # `pathmap.root` unconditionally after that RE-ROOTS the whole map at that inner node,
        # discarding the origin prefix and every sibling outside it.
        # Upstream never has this problem because it writes through the stack's root SLOT —
        # `*focus_stack.root_mut() = replacement_node` (write_zipper.rs:2532) — which after a mend
        # is the inner node's slot inside its parent, not the map's root pointer.
        #
        # Symptom: `join_map_into` at origin `":a"` with a source that HAS a root value produced
        # `[a,aa:bb,ab,aba]` where upstream gives `[:a,:aa:bb,:ab,:aba,bb:]` — the entire map lost
        # its `:` prefix and the unrelated key `bb:`. Only reachable when the val write fires
        # first (it is what creates the subnode and triggers the mend), which is why the
        # no-root-value case agreed exactly. PathMap fuzz 00174.
        if z.root_key_start == 0
            z.pathmap.root = new_rc
            z.focus_stack[1] = new_rc
        else
            # Write THROUGH the shared wrapper so the parent's child pointer sees it.
            z.focus_stack[1].node = new_rc.node
        end
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
    # k=1 (root): uniquify in place if shared.
    root_rc = z.focus_stack[1]
    root_rc.node === nothing && return nothing
    refcount(root_rc) > 1 && make_unique!(root_rc)
    # k=2..n: RE-FETCH each child from the (now-unique) parent's ACTUAL slot and
    # uniquify it there. Do NOT reuse the descent's stale focus_stack wrapper: that
    # wrapper belongs to the PRE-clone parent's child slot, which is still owned by
    # whatever shares that parent (a `clone()`/graft SNAPSHOT). Forking the stale
    # wrapper + re-linking makes the snapshot and this map point through the SAME
    # forked child, so a same-subtrie write LEAKS into the snapshot (the transitive-COW
    # bug: root forks, child stays shared). `clone_self` gives each cloned node its OWN
    # child wrappers (`_shallow_clone_slot` = `copy(child)`, refcount-bumped), so the
    # cloned parent's real child (from `node_get_child`) is the one to uniquify. Mirrors
    # upstream write_zipper.rs `make_mut`, which walks top-down re-fetching each child
    # from the just-made_mut'd parent. (Stale "deepcopy" premise in the old comment was
    # wrong: clone_self shallow-SHARES children with a refcount bump, not a deepcopy.)
    for k in 2:n
        parent = z.focus_stack[k - 1].node
        parent === nothing && break
        pk = _wz_parent_key_for_level(z, k)   # view: node_get_child only READS the key
        gc = node_get_child(parent, pk)::Union{Nothing, Tuple{Int, TrieNodeODRc{V, A}}}
        gc === nothing && break
        child_rc = gc[2]
        # `child_rc` IS the (now-unique) parent's OWN slot wrapper (node_get_child returns
        # the stored `cf.rec` / `voc._child` object). Forking it in place via make_unique!
        # updates that slot directly — no node_replace_child! needed. The descent's stale
        # wrapper (still held by any snapshot of the PRE-clone parent) is left untouched, so
        # the snapshot keeps the original shared child. make_unique!'s own refcount dec keeps
        # the counts exact.
        refcount(child_rc) > 1 && make_unique!(child_rc)
        z.focus_stack[k] = child_rc
    end
    return nothing
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
    if focus_node === nothing
        # The null sentinel IS the empty node (EmptyNode.jl:83). Reads and removals answer it
        # directly, but a WRITE cannot no-op — it has to materialise real storage first. This is
        # the same move as the upgrade path below, just triggered by absence rather than by a
        # node outgrowing its representation. Upstream never needs it: its stack holds a
        # `&mut dyn TrieNode`, so there is no null to materialise, and hence no code to port.
        fresh = TrieNodeODRc(LineListNode{V, A}(z.alloc), z.alloc)
        _wz_replace_top_node!(z, fresh)
        focus_node = z.focus_stack[end].node
    end
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
        # A NULL node has no children, so there is nothing to descend into — stop.
        #
        # ⚠️ Upstream cannot hit this: `descend_to_internal` drives `focus_stack.advance(|node| …)`
        # (write_zipper.rs:2481) and the Rust `MutNodeStack` hands the closure a `&mut dyn TrieNode`
        # that is non-null BY CONSTRUCTION. Our `TrieNodeODRc.node` is
        # `Union{Nothing, AbstractTrieNode}` and CAN be nothing — a port-introduced state, already
        # guarded elsewhere (`_wz_ensure_write_unique!`, `_wz_prune_path_internal!`) but not here.
        # Without this line, any DESCEND after an op that empties the trie (remove_val / subtract /
        # graft of an empty source / take_map) died with
        # `MethodError: no method matching node_get_child(::Nothing, …)` where upstream simply
        # continues. Seven of the differential fuzzer's 34 divergences were this ONE line.
        # Minimal repro: set_val_at!(m,"b:") · write_zipper_at_path(m,"b:") · wz_remove_val! ·
        # wz_descend_to!(wz,":a").
        focus_node === nothing && break
        # `focus_node` is abstract (`TrieNodeODRc.node::Union{Nothing,AbstractTrieNode}`), so this
        # dispatch is dynamic and infers `Any` — the assertion pins the concrete return (all 4
        # node_get_child methods return exactly this), stabilizing `consumed`/`child_rc` and killing
        # the downstream `length`/`>=`/`+`/`view` dynamic-dispatch cascade. Semantic no-op.
        result =
            node_get_child(focus_node, key)::Union{Nothing, Tuple{Int, TrieNodeODRc{V, A}}}
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
    # Traverse root_slice to find the deepest reachable node, COPY-ON-WRITING every node on the way.
    #
    # 🔴 THE `_mut!` IS LOad-BEARING. This used to call the read-only `node_along_path`, matching
    # neither of upstream's two mend/construct sites — both use `node_along_path_mut` precisely so
    # the origin chain is made unique BEFORE the zipper exists (write_zipper.rs:2452 and :1141).
    # Mending records the origin in `root_key_start`, so afterwards there is NOTHING above
    # `focus_stack[1]` for `_wz_ensure_write_unique!` to walk — its `for k in 2:n` loop goes
    # downward only. A shared ancestor absorbed by the mend was therefore never uniquified, and any
    # write through the zipper wrote into a node another map still reached. See the header on
    # `node_along_path_mut!` for the 17 corrupting op shapes and the bisect.
    (final_rc, remaining, _) = node_along_path_mut!(root_rc, root_slice, nothing, true)
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
        z,
        (node, key) -> node_set_val!(
            node, key, val
        )::Union{Tuple{Union{Nothing, V}, Bool}, TrieNodeODRc{V, A}},
        (_node, _key) -> (nothing, true)
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
    # ⚠️ `_wz_prune_path_internal!`, NOT `wz_prune_path!` — and note this is the OPPOSITE choice from
    # `wz_join_k_path_into!`, which must use the public one. Upstream really does differ per site:
    #
    #     remove_val        `if prune { self.prune_path_internal(false); }`   write_zipper.rs:1415
    #     join_k_path_into  `if prune && !result { self.prune_path(); }`      write_zipper.rs:1773
    #
    # `prune_path` runs `node_remove_dangling(node_key)` first and walks the ancestors ONLY if that
    # returned > 0. Here it always returns 0: `node_remove_val!(focus_node, nk, prune)` on the line
    # above has already taken the payload whole, so there is no dangling remnant left for it to trim.
    # Routing through the public helper therefore meant the gate NEVER OPENED and we never pruned
    # ancestors at all — a `parent -> empty-child` link that upstream deletes stayed in our trie.
    #
    # Observable two ways, both measured against the binary:
    #   TAKEMAP at that parent   ours `[] vc=0` (an empty map)  vs upstream `None` (nothing there)
    #   SUB status at that path  ours `Element`                 vs upstream `None`
    # `wz_take_map!` calls `wz_remove_val!(z, prune)`, so `TAKEMAP 1` inherited this too.
    prune && old_val !== nothing && _wz_prune_path_internal!(z)
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
        cur_jump = min(steps, _wz_excess_key_len(z))
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
    # 🔴 MEND, DO NOT DESCEND. This one line closed 42 of the 75 fuzz divergences (measured
    # before/after on the same 3000-case corpus; 0 newly broken).
    #
    # Upstream's constructor (`new_with_node_and_path_internal_in`, write_zipper.rs:1147) builds ONLY
    # KeyFields + a stack root — it never descends. The origin path is absorbed LAZILY by
    # `mend_root`, which advances `root_key_start` and RE-POINTS the stack root at the reached node,
    # leaving the zipper at depth 1 with an empty `prefix_idx`.
    #
    # We used to call `_wz_descend_to_internal!` here instead. That records the origin in
    # `prefix_idx`/`focus_stack` rather than in `root_key_start` — and since `_wz_mend_root!` guards
    # on `isempty(prefix_idx)` (:309, byte-identical to upstream's guard at write_zipper.rs:2444),
    # a descended zipper DISABLED MENDING FOR ITS ENTIRE LIFETIME. `wz_reset!` then returned to the
    # original root, where upstream returns to the node mend_root had substituted. Case 00174:
    # `node_remove_val` was handed the two-byte key ":a" against the Dense root, which NEITHER
    # engine can serve (upstream's DenseByteNode is `if key.len() == 1 { … } else { None }`,
    # dense_byte_node.rs:847), so the value survived here and was removed upstream.
    #
    # ⚠️ DELETING the descend outright was tried before and REVERTED — it over-removed
    # (`[ab,bb:] vc=2` against upstream's `[:ab,ab,bb:] vc=3`) and broke 6 tests. The difference is
    # that the origin still has to be absorbed; upstream just absorbs it into `root_key_start`
    # instead of into a descent. Replacing the descend with the mend does that, and the 6 tests pass.
    _wz_mend_root!(z)
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
    if isempty(path)
        # The ROOT VALUE lives in `m.root_val`, not in any node, so setting it needs no node at
        # all. Going through `write_zipper(m)` would call `_ensure_root!` and MATERIALISE an empty
        # root node as a side effect — upstream does not, and the difference is OBSERVABLE:
        # `join_map_into`/`graft_map` branch on whether the source map HAS a root node
        # (write_zipper.rs:1694-1700), so a spurious empty root sends us down the node path where
        # upstream takes its early return, and we answer Element where upstream answers
        # None/Identity. Confirmed against the binary by fuzz case 00074.
        # ⚠️ NOT the same as "treat an empty root node as absent" — upstream CAN legitimately hold
        # `Some(empty root)` (its `take_map` returns exactly that, fuzz case 00056), so the fix has
        # to be to stop CREATING one, not to ignore one.
        old = m.root_val
        m.root_val = val
        return old
    end
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
        # The null sentinel IS the empty node (EmptyNode.jl:83 and the contract below it), and an
        # empty node has no subtrie at any key. Guarded HERE rather than as a `::Nothing` method
        # because the empty answer is `ANRNone{V,A}()` — it needs the type params, which only the
        # zipper knows. Same contract hole as the node_* accessors; found by the fuzzer.
        fnode = z.focus_stack[end].node
        fnode === nothing ? ANRNone{V, A}() : get_node_at_key(fnode, nk)
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

"""
    wz_graft_masked_branches!(z, src_anr, child_mask, remove_unset)

Ports `WriteZipperCore::graft_masked_branches` (write_zipper.rs:1503-1560) — for every byte SET in
`child_mask`, replace the destination's child at that byte with the source's; when `remove_unset`,
also drop the destination's children OUTSIDE the mask.

The contract, taken from upstream's own tests (write_zipper.rs:5340-5429) rather than inferred:

  * a masked byte present in `src`  -> destination's child is REPLACED wholesale (subtree and all)
  * a masked byte ABSENT from `src` -> destination's child is REMOVED
  * an unmasked byte               -> destination keeps its own, and src's is NOT copied across
  * the destination's FOCUS VALUE is untouched in every case
  * a masked byte absent from BOTH sides must not leave a dangling branch (their Case 3)

⚠️ IMPLEMENTATION DEVIATION, deliberate. Upstream reaches this through
`merge_branches_into_focus` -> `merge_branches_into_byte_node` (dense_byte_node.rs:1504): bulk
range-iteration over the two masks, rebuilding a `ValuesVec` in one pass, monomorphized over the
CoFree type and a `const REMOVE_UNSET`. That is a PERFORMANCE implementation of the contract above,
and it reaches into `ByteNode`'s internal layout; it also forces a `split_at_focus` and node-type
conversions (LineList/TinyRef -> Dense) purely so the bulk path applies.

We implement the contract with the zipper's own descend/graft/ascend, which needs none of that
machinery and keeps the COW path intact. Same observable result — verified against all four of
upstream's own cases, including the dangling-branch one. If this ever shows up in a profile, the
bulk path is the optimisation to port, not a correctness fix.
"""
function wz_graft_masked_branches!(
    z::WriteZipperCore{V, A}, src_anr::AbstractNodeRef{V, A},
    child_mask::ByteMask, remove_unset::Bool
) where {V, A}
    # upstream: `src.get_focus().try_as_tagged()` yielding None makes the whole call a no-op
    is_none(src_anr) && return nothing
    src_node = as_tagged(src_anr)

    if remove_unset
        # Drop the destination's children outside the mask. Collected FIRST — removing while
        # iterating the live mask would read a structure being mutated underneath.
        doomed = UInt8[b for b in iter(wz_child_mask(z)) if !test_bit(child_mask, b)]
        for b in doomed
            wz_descend_to!(z, UInt8[b])
            _wz_remove_branches!(z, false)
            wz_ascend!(z, 1)
        end
    end

    for b in iter(child_mask)
        child = node_get_child(src_node, UInt8[b])
        wz_descend_to!(z, UInt8[b])
        if child === nothing
            # absent in the source => remove. Upstream's Case 3 pins that this must NOT leave a
            # dangling branch when the destination lacked the byte too.
            _wz_remove_branches!(z, false)
        else
            (_klen, child_rc) = child
            _wz_graft_internal!(z, child_rc)
        end
        wz_ascend!(z, 1)
    end
    nothing
end

"""
    _pm_into_root(m) -> (Union{Nothing,TrieNodeODRc}, Union{Nothing,V})

Ports `PathMap::into_root` (trie_map.rs:205-216) — the map's root node and root value, with an
EMPTY root node reported as `nothing`. That emptiness check is load-bearing: `graft_map` and
`wz_graft_child_maps!` both branch on whether the source has a node at all.
"""
function _pm_into_root(m::PathMap{V, A}) where {V, A}
    r = m.root
    node = (r === nothing || node_is_empty(as_tagged(r))) ? nothing : r
    (node, m.root_val)
end

"""
    wz_graft_child_maps!(z, child_mask, maps, remove_unset)

Ports `WriteZipperCore::graft_child_maps` (write_zipper.rs:1573-1616) — plant one map per set bit of
`child_mask`, each one byte below the focus.

Two strategies, and the threshold is upstream's:

  * `count_bits(child_mask) > 2 && remove_unset` — build a fresh `DenseByteNode` sized to the mask,
    fill it directly, and graft it whole. Replacing every child anyway, and enough of them to be
    worth a byte node.
  * otherwise — clear first if `remove_unset`, then set each child individually. Upstream leaves a
    `GOAT` note that `count > 2 && !remove_unset` could take the fast path too but does not, "since
    it requires logic to upgrade the focus_node to ByteNode". Ported as written, slow path and all.

`maps` is consumed in mask order and must yield at least `count_bits(child_mask)` entries; upstream
panics on a short iterator ("maps iterator returned fewer items than the number of set bits").
"""
function wz_graft_child_maps!(
    z::WriteZipperCore{V, A}, child_mask::ByteMask, maps, remove_unset::Bool
) where {V, A}
    map_count = count_bits(child_mask)
    it = iterate(maps)
    next_map!() = begin
        it === nothing && error(
            "maps iterator returned fewer items than the number of set bits in child_mask"
        )
        (m, st) = it
        it = iterate(maps, st)
        m
    end

    if map_count > 2 && remove_unset
        new_node = DenseByteNode{V, A}(z.alloc, map_count)
        for child_byte in iter(child_mask)
            m = next_map!()
            (src_node, src_val) = _pm_into_root(m)
            src_node === nothing || node_set_branch!(new_node, UInt8[child_byte], src_node)
            src_val === nothing || node_set_val!(new_node, UInt8[child_byte], src_val)
        end
        _wz_graft_internal!(z, TrieNodeODRc(new_node, z.alloc))
    else
        remove_unset && _wz_remove_branches!(z, false)
        for child_byte in iter(child_mask)
            m = next_map!()
            (src_node, src_val) = _pm_into_root(m)
            src_node === nothing ||
                _wz_set_node_at_child_path!(z, UInt8[child_byte], src_node)
            src_val === nothing || _wz_set_val_at_child_path!(z, UInt8[child_byte], src_val)
        end
    end
    nothing
end

"""
    _wz_split_at_focus!(z)

Ports `WriteZipperCore::split_at_focus` (write_zipper.rs:1210-1232) — force the focus onto its own
node, splitting the parent's key if the focus currently lives inside a multi-byte slot key.

Takes the subtrie at the focus out of the parent (`take_node_at_key!`), or makes a fresh empty node
if there was nothing there, and sets it back as a branch at the focus key. The round trip is the
point: `node_set_branch!` re-inserts through `set_payload_abstract!`, which splits a multi-byte slot
key at the overlap, so afterwards the focus has a node of its own.

Upstream calls this from `splitting_borrow_focus` (ZipperHead root isolation) and
`graft_masked_branches`; both are the same need — an isolated node to hand out or merge into.
"""
function _wz_split_at_focus!(z::WriteZipperCore{V, A}) where {V, A}
    alloc = z.alloc
    sub_branch_added = _wz_in_mut_static_result!(
        z,
        function (node, key)
            taken = take_node_at_key!(node, key, false)
            new_node =
                taken === nothing ?
                TrieNodeODRc(LineListNode{V, A}(alloc), alloc) : taken
            node_set_branch!(node, key, new_node)
        end,
        (_, _) -> true
    )
    if sub_branch_added
        _wz_mend_root!(z)
        _wz_descend_to_internal!(z)
    end
    nothing
end

"""
    _wz_set_node_at_child_path!(z, path, src)
    _wz_set_val_at_child_path!(z, path, val) -> Union{Nothing, V}

Port `set_node_at_child_path` / `set_val_at_child_path` (write_zipper.rs:1618/1632) — plant a branch
or a value at `path` BELOW the focus, leaving the focus where it was. Both exist only to serve
`wz_graft_child_maps!`, and upstream calls them with a single byte.

⚠️ DELIBERATE STRUCTURAL DEVIATION, and the reason is a Rust/Julia one. Upstream reaches the target
through `with_node_at_path`, which walks to the node with `node_along_path_mut` and, on an upgrade,
writes the replacement back through a `&mut` INTO THE TRIE (`*node = replacement_node`). Julia has no
such through-reference: `node_along_path` hands back a value, and assigning to it would update
nothing. Reproducing that would mean re-implementing the parent-pointer surgery that our zipper
already performs correctly.

So we descend, act, and ascend. The observable effect is the same, and it is arguably safer: the
zipper's own `wz_set_val!` / `_wz_graft_internal!` already run `_wz_mend_root!` +
`_wz_descend_to_internal!` — the exact epilogue upstream's helpers run by hand — and the COW
`_wz_ensure_write_unique!` path stays intact. Upstream avoids descending for speed, not semantics;
its own comment concedes the helper "isn't suitable for general-purpose path-based ops yet" because
it stack-copies the key into a fixed buffer.
"""
function _wz_set_node_at_child_path!(
    z::WriteZipperCore{V, A}, path::AbstractVector{UInt8}, src::TrieNodeODRc{V, A}
) where {V, A}
    wz_descend_to!(z, path)
    _wz_graft_internal!(z, src)
    wz_ascend!(z, length(path))
    nothing
end

function _wz_set_val_at_child_path!(
    z::WriteZipperCore{V, A}, path::AbstractVector{UInt8}, val::V
) where {V, A}
    wz_descend_to!(z, path)
    old = wz_set_val!(z, val)
    wz_ascend!(z, length(path))
    old
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
# Mirrors WriteZipperCore::graft / graft_map (write_zipper.rs:1444/1464).
#
# `graft_root_vals` IS a DEFAULT upstream feature (Cargo.toml:39), so the
# `#[cfg(feature = "graft_root_vals")]` arm is the LIVE one and the behaviour below is the
# DEFAULT, not an opt-in. The rule, uniform across the family: the value at the write zipper's
# FOCUS is the counterpart of the SOURCE's ROOT value, combined under the same operation.

"""
    _wz_root_val_op!(z, op, src_root_val, prune) -> (AlgebraicStatus, val_was_none::Bool)

Shared `graft_root_vals` focus-value handling for the algebraic ops — upstream applies the same
shape in `join_map_into` (write_zipper.rs:1682), `meet_into` (:1865) and `subtract_into` (:1976),
and its own comment at :146-148 says the implementation "could likely be factored out and shared
among all the ops". Done once here rather than three times.

`op` is the `Union{Nothing,V}` lattice op (`pjoin`/`pmeet`/`psubtract`), whose blanket impls in
Ring.jl:436-495 already port Rust's `impl Lattice for Option<V>` — which is exactly the
(focus value, source root value) algebra, so the four-way match upstream writes out per op falls
out of dispatch instead of being retyped three times.
"""
function _wz_root_val_op!(
    z::WriteZipperCore{V, A}, op::F, src_root_val::Union{Nothing, V}, prune::Bool
) where {V, A, F}
    self_val = wz_get_val(z)
    val_was_none = self_val === nothing
    r = op(self_val, src_root_val)
    status = if r isa AlgResElement
        nv = r.value
        if nv === nothing
            wz_remove_val!(z, prune)
            ALG_STATUS_NONE
        else
            wz_set_val!(z, nv)
            ALG_STATUS_ELEMENT
        end
    elseif r isa AlgResIdentity
        if (r.mask & SELF_IDENT) > 0
            # self is the answer — leave the focus value exactly as it is
            val_was_none ? ALG_STATUS_NONE : ALG_STATUS_IDENTITY
        elseif src_root_val === nothing
            wz_remove_val!(z, prune)
            ALG_STATUS_NONE
        else
            wz_set_val!(z, src_root_val)
            ALG_STATUS_ELEMENT
        end
    else
        wz_remove_val!(z, prune)
        ALG_STATUS_NONE
    end
    (status, val_was_none)
end

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
    src_root_val = map.root_val
    _wz_graft_internal!(z, src)
    # graft_root_vals (DEFAULT): the focus value becomes the source's root value —
    # UNCONDITIONALLY, so a source with no root value CLEARS it (write_zipper.rs:1468-1473,
    # `None => self.remove_val(false)`; note prune is false there).
    src_root_val === nothing ? wz_remove_val!(z, false) : wz_set_val!(z, src_root_val)
    nothing
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

`map` is READ-ONLY: it survives the call unchanged, and so does any other map sharing its nodes.
Pinned in `test/test_join_preserves_source.jl`, in both handover modes.

🔄 **This docstring used to say the opposite** — "`map` IS CONSUMED, DO NOT USE IT AFTERWARDS",
justified by upstream taking the map BY VALUE (`pub fn join_map_into(&mut self, map: PathMap<V, A>)`,
write_zipper.rs:1680) and therefore being free to mutate it. By-value means upstream MAY; it does
not mean upstream DOES, and it does not — its node-level joins clone the operand
(`line_list_node.rs:2515-2532`) or `make_mut()` before touching it (`dense_byte_node.rs:1306-1334`),
and it emits no source change on any of the 3000 fuzz cases. Ours mutated the source because
`LineListNode::join_into_dyn!` merged into its RIGHT-HAND operand; fixing that one write removed the
behaviour for shared AND unshared sources alike. See the test header and fuzz case `00324`.
"""
function wz_join_map_into!(z::WriteZipperCore{V, A}, map::PathMap{V, A}) where {V, A}
    # graft_root_vals (DEFAULT): the map's ROOT value joins into the FOCUS value, and upstream
    # does it BEFORE any node work (write_zipper.rs:1682-1691). Order is load-bearing — the
    # `src_root_node === nothing` early return below returns without merging, and does NOT undo
    # this write. That is exactly why `graft/join_map_into_rootval_at_p` yields `[p,px,q]`.
    #
    # ⚠️ `join_into` (the read-zipper form, :1652) has NO such block upstream. The two are
    # deliberately asymmetric, so a caller wanting `join_into` semantics must NOT route here.
    (val_status, _) = _wz_root_val_op!(z, pjoin, map.root_val, false)

    src_rc = map.root
    if src_rc === nothing
        # ⚠️ Upstream tests ONLY `self_focus.is_none()` here (write_zipper.rs:1696-1700) — NOT
        # emptiness. An EMPTY-but-present focus is `Some`, so upstream answers Identity where an
        # added `|| node_is_empty(...)` makes us answer None. Joining nothing into an existing
        # (even empty) focus IS the identity; there is no focus to have been annihilated.
        # Fuzz 00134: two empty maps, join at the root — upstream Identity, ours was None.
        focus_anr = _wz_get_focus_anr(z)
        return is_none(focus_anr) ? ALG_STATUS_NONE : ALG_STATUS_IDENTITY
    end
    focus_anr = _wz_get_focus_anr(z)
    node_status = if is_none(focus_anr) || node_is_empty(as_tagged(focus_anr))
        _wz_graft_internal!(z, copy(src_rc))
        ALG_STATUS_ELEMENT
    else
        result = pjoin_dyn(as_tagged(focus_anr), src_rc.node)
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
    # join cannot turn a non-None operand into None, so both `*_was_none` flags are true
    # (write_zipper.rs:1730, `node_status.merge(val_status, true, true)`).
    merge_status(node_status, val_status, true, true)
end

"""
    wz_descend_first_k_path!(z, k) -> Bool
    wz_to_next_k_path!(z, k) -> Bool

Port `ZipperIteration::descend_first_k_path` / `to_next_k_path` (zipper.rs:660/675) for the WRITE
zipper. Upstream gets these free as TRAIT DEFAULTS over `ZipperMoving`; Julia has no trait defaults,
so our port hand-writes them per type — this is the WriteZipperCore set, alongside the existing
ProductZipper/ProductZipperG/EmptyZipper ones. The body is `k_path_default_internal` (zipper.rs:686).

`to_next_k_path` returns false outright when the path is shorter than `k` — there is no common root
`k` steps up to return to. On a false result the zipper is left back at that common root.
"""
wz_descend_first_k_path!(z::WriteZipperCore, k::Int)::Bool =
    _wz_k_path_internal!(z, k, length(wz_path(z)))

function wz_to_next_k_path!(z::WriteZipperCore, k::Int)::Bool
    n = length(wz_path(z))
    n >= k || return false
    _wz_k_path_internal!(z, k, n - k)
end

function _wz_k_path_internal!(z::WriteZipperCore, k::Int, base_idx::Int)::Bool
    while true
        if length(wz_path(z)) < base_idx + k
            while wz_descend_first_byte!(z)
                length(wz_path(z)) == base_idx + k && return true
            end
        end
        if wz_to_next_sibling_byte!(z)
            length(wz_path(z)) == base_idx + k && return true
            continue
        end
        while length(wz_path(z)) > base_idx
            wz_ascend_byte!(z)
            length(wz_path(z)) == base_idx && return false
            wz_to_next_sibling_byte!(z) && break
        end
    end
end

"""
    wz_meet_k_path_into!(z, byte_cnt, prune=false) -> Bool

Ports `WriteZipperCore::meet_k_path_into` (write_zipper.rs:1778-1802) — intersect every subtrie
reachable at depth `byte_cnt` below the focus, and replace the focus with that intersection. Returns
whether anything survived.

Upstream flags its own implementation: *"this is a provisional implementation with the wrong
performance characteristics, but should have the right behavior"*. It takes each k-deep subtrie out
with `take_map` and folds them with `meet`. Ported as written, including the early exit the moment
the accumulator goes empty (an intersection cannot come back).

`temp_map.meet(&other)` becomes `wz_meet_into!` on a zipper over the accumulator: upstream returns a
new map, but the accumulator is a local we own, so meeting in place is the same value with one less
allocation. The source's root value is threaded explicitly, as everywhere else our node-ref-based
algebra meets upstream's zipper-based signatures.
"""
function wz_meet_k_path_into!(
    z::WriteZipperCore{V, A}, byte_cnt::Int, prune::Bool=false
) where {V, A}
    _anr_of(m::PathMap{V, A}) =
        m.root === nothing ? ANRNone{V, A}() : ANRBorrowedRc{V, A}(m.root)

    temp_map = if wz_descend_first_k_path!(z, byte_cnt)
        acc = something(wz_take_map!(z, false), PathMap{V, A}(nothing, nothing, z.alloc))
        while wz_to_next_k_path!(z, byte_cnt)
            if isempty(acc)
                # an empty intersection stays empty — upstream ascends out and stops
                wz_ascend!(z, byte_cnt)
                break
            end
            other = something(
                wz_take_map!(z, false), PathMap{V, A}(nothing, nothing, z.alloc)
            )
            wz_meet_into!(write_zipper(acc), _anr_of(other), false, other.root_val)
        end
        acc
    else
        PathMap{V, A}(nothing, nothing, z.alloc)
    end

    if isempty(temp_map)
        _wz_remove_branches!(z, prune)
        false
    else
        wz_graft_map!(z, temp_map)
        true
    end
end

"""
    wz_meet_2!(z, a_anr, b_anr) -> AlgebraicStatus

Meet TWO sources and store the result at the focus, ignoring whatever the focus currently holds.
Ports `WriteZipperCore::meet_2` (write_zipper.rs:1935-1972).

⚠️ NOT `wz_meet_into!` with an extra argument. `meet_into` meets the source INTO the destination, so
it can report `Identity` when the destination already equals the result; this one overwrites the
destination and never reads it. Upstream says so against its own `Identity` arm: *"document that
meet_2 will not return identity because it doesn't actually check what's in the destination"* — the
arm still grafts `a` or `b` (whichever the mask names) and reports `Element`.

It also does NO root-value handling, unlike `wz_meet_into!`'s `_wz_root_val_op!` — faithful; upstream's
`meet_2` touches only nodes.

Takes `AbstractNodeRef`s where upstream takes read zippers, the same substitution `wz_meet_into!`
makes; a bare node ref carries no root value, which is exactly what this operation wants.
"""
function wz_meet_2!(
    z::WriteZipperCore{V, A}, a_anr::AbstractNodeRef{V, A}, b_anr::AbstractNodeRef{V, A}
) where {V, A}
    # upstream: `try_as_tagged()` yielding None on either side grafts None and returns None
    if is_none(a_anr) || is_none(b_anr)
        _wz_graft_internal!(z, nothing)
        return ALG_STATUS_NONE
    end
    result = pmeet_dyn(as_tagged(a_anr), as_tagged(b_anr))
    if result isa AlgResElement
        _wz_graft_internal!(z, result.value)
        ALG_STATUS_ELEMENT
    elseif result isa AlgResIdentity
        # SELF_IDENT names `a` here (self is the FIRST source, not the destination); anything else
        # must be COUNTER_IDENT, i.e. `b` — upstream debug_asserts exactly that.
        _wz_graft_internal!(z, into_option((result.mask & SELF_IDENT) > 0 ? a_anr : b_anr))
        ALG_STATUS_ELEMENT
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
    z::WriteZipperCore{V, A}, src_anr::AbstractNodeRef{V, A}, prune::Bool=false,
    src_root_val::Union{Nothing, V}=nothing
) where {V, A}
    # graft_root_vals (DEFAULT): meet the SOURCE's root value into the FOCUS value, before any
    # node work (write_zipper.rs:1865-1878). `(Some, None)` CLEARS the focus value — that is the
    # branch behind `graft/meet_into_at_p`.
    #
    # `src_root_val` exists because upstream's `meet_into` takes a READ ZIPPER, which carries a
    # root value, where ours takes an `AbstractNodeRef`, which cannot. Defaulting it to `nothing`
    # is the faithful reading of a bare node ref (a source with no root value), not a shortcut.
    (val_status, val_was_none) = _wz_root_val_op!(z, pmeet, src_root_val, prune)

    node_was_none = false
    focus_anr = _wz_get_focus_anr(z)
    node_status = if is_none(focus_anr) || node_is_empty(as_tagged(focus_anr))
        node_was_none = true
        ALG_STATUS_NONE
    elseif is_none(src_anr)
        _wz_graft_internal!(z, nothing)
        prune && wz_prune_path!(z)
        ALG_STATUS_NONE
    elseif _check_anr_sharing(focus_anr, src_anr)
        # Shared-node short-circuit: A ∩ A = A (identity — self unchanged).
        ALG_STATUS_IDENTITY
    else
        result = pmeet_dyn(as_tagged(focus_anr), as_tagged(src_anr))
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
    merge_status(node_status, val_status, node_was_none, val_was_none)
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
    z::WriteZipperCore{V, A}, src_anr::AbstractNodeRef{V, A}, prune::Bool=false,
    src_root_val::Union{Nothing, V}=nothing
) where {V, A}
    # graft_root_vals (DEFAULT): subtract the SOURCE's root value from the FOCUS value first
    # (write_zipper.rs:1976-1990). Note the asymmetry with meet — here `(Some, None)` KEEPS the
    # focus value (Identity); it is `(Some, Some)` that clears it, which is the branch behind
    # `graft/subtract_into_rootval_at_p`. See `wz_meet_into!` on why `src_root_val` is a parameter.
    (val_status, val_was_none) = _wz_root_val_op!(z, psubtract, src_root_val, prune)

    node_was_none = false
    focus_anr = _wz_get_focus_anr(z)
    self_empty = is_none(focus_anr) || node_is_empty(as_tagged(focus_anr))
    node_status = if is_none(src_anr)
        if self_empty
            node_was_none = true
            ALG_STATUS_NONE
        else
            ALG_STATUS_IDENTITY
        end
    elseif self_empty
        node_was_none = true
        ALG_STATUS_NONE
    elseif _check_anr_sharing(focus_anr, src_anr)
        # Shared-node short-circuit: A − A = ∅ (subtract set from itself = empty).
        _wz_graft_internal!(z, nothing)
        prune && wz_prune_path!(z)
        ALG_STATUS_NONE
    else
        result = psubtract_dyn(as_tagged(focus_anr), as_tagged(src_anr))
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
    merge_status(node_status, val_status, node_was_none, val_was_none)
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
    # ⚠️ PRUNE VIA `wz_prune_path!`, NOT `_wz_prune_path_internal!`. Upstream's body is
    #
    #     let result = match self.get_focus().into_option() { Some(..) => {..}, None => false };
    #     if prune && !result { self.prune_path(); }
    #
    # (write_zipper.rs:1762-1775) — the PUBLIC `prune_path`, reached from ONE common tail. We used to
    # call the INTERNAL helper from two places, which is wrong twice over: `prune_path` first does
    # `node_remove_dangling(node_key)` and only walks the ancestors when that removed something
    # (:2179-2190), so we were skipping the node-level dangling removal outright AND running the
    # ancestor walk unconditionally. Nothing caught it because `join_k_path_into` is not one of the
    # 12 ops the differential fuzzer generates.
    # 🔴 TWO DIFFERENT COW STEPS ARE NEEDED HERE, AND NEITHER SUBSTITUTES FOR THE OTHER.
    #
    # (1) THE ANCESTOR CHAIN, on `focus_stack` — this call. Every other mutating op does it
    #     (:230 set_val, :386 remove_val, :671, :1707 take_focus, :1874, :1909); this one did not,
    #     and that omission let a write reach a map SHARING our ancestors:
    #
    #         a  = {":b"=>101, ":a"=>102};  ac = share(a)      # copy(root) -> refcount 2
    #         z = write_zipper(a); descend ":"; join_k_path_into!(z, 1, prune)
    #           a  -> []   intended
    #           ac -> []   *** THE SHARED CLONE WAS EMPTIED ***
    #
    #     Independent of `prune` and of `byte_cnt`. AT THE ROOT it does not reproduce — with no
    #     descent the shared root IS `focus_stack[1]`, and step (2)'s `make_unique!` happens to
    #     cover it. That is exactly why the existing COW test (runtests.jl:639, which shares a
    #     subtrie BELOW the focus) stayed green: it never descends past the shared node.
    #
    #     Same signature as the `write_zipper_at_path` hole fixed in `38dcfbd` — the node being
    #     written has refcount 1, the sharing is ONE LEVEL UP, so no amount of uniquifying the
    #     focus can find anything to fork. Upstream is safe because it reaches the focus through
    #     `&mut self` (write_zipper.rs:1762), whose `make_mut` walk covers the whole chain.
    #
    #     ORDER MATTERS: this must run BEFORE `_wz_get_focus_anr`, because it may CLONE stack
    #     nodes; a focus reference taken first would point into the pre-clone parent.
    #
    # (2) THE FOCUS NODE ITSELF — the `make_unique!(focus_rc)` below. `drop_head_dyn!` mutates the
    #     focus subtrie IN PLACE, and that node is reached via `get_node_at_key` and is NOT on
    #     `focus_stack`, so (1) cannot see it. Mirrors `self_node.make_mut().drop_head_dyn(...)`
    #     (write_zipper.rs:1620). Without it, dropping the head of a shared subtrie corrupts the
    #     SOURCE map — reachable via MorkL OP_DROP_HEAD on a shared space.
    _wz_ensure_write_unique!(z)
    focus_anr = _wz_get_focus_anr(z)
    if is_none(focus_anr)
        prune && wz_prune_path!(z)
        return false
    end
    focus_rc = borrow(focus_anr)
    focus_rc !== nothing && make_unique!(focus_rc)
    self_node = as_tagged(focus_anr)
    new_node = drop_head_dyn!(self_node, byte_cnt)
    _wz_graft_internal!(z, new_node)
    result = new_node !== nothing
    prune && !result && wz_prune_path!(z)   # see the note above — public prune_path, not the helper
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

Delegates to `_wz_at_root` so there is exactly ONE body for this predicate. Keeping two
independent bodies is what let `wz_ascend!` call a wrong one for months while this correct
one sat unused beside it — see the note at `_wz_at_root`.
"""
@inline wz_at_root(z::WriteZipperCore) = _wz_at_root(z)

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
    # 1:1 with upstream `take_focus` (write_zipper.rs:2202-2227), which has TWO branches keyed on
    # `node_key().len() == 0`.
    #
    # ⚠️ This used to be a read-then-clear — `get_focus()` for the node, then
    # `graft_internal(nothing)` to remove it. That is NOT the same operation. `get_focus` reports
    # only a node that EXISTS, whereas upstream's `take_node_at_key` also yields the empty node
    # sitting on a DANGLING path (take_focus's own doc says it "may leave behind a dangling path",
    # so the next call meets one). We answered `nothing` where upstream answers `Some(empty)`,
    # which `take_map` then turns into `nothing` instead of an empty PathMap. Fuzz cases
    # 00056 / 00277 / 00287: a SECOND `take_map` at the same focus gives us None, upstream `[] vc=0`.
    _wz_ensure_write_unique!(z)
    nk = collect(_wz_node_key(z))
    if isempty(nk)
        # AT ROOT: upstream swaps a FRESH empty node into the stack root and returns the old one
        # only if it was non-empty (:2208-2215) — so taking an already-empty root yields None,
        # while taking a populated one hands the whole trie over and leaves an empty map behind.
        old_rc = z.focus_stack[1]
        replacement = TrieNodeODRc(LineListNode{V, A}(z.alloc), z.alloc)
        z.pathmap.root = replacement
        z.focus_stack[1] = replacement
        return node_is_empty(old_rc.node) ? nothing : old_rc
    else
        focus_node = z.focus_stack[end].node
        new_node = take_node_at_key!(focus_node, nk, prune)
        new_node === nothing && return nothing
        prune && _wz_prune_path_internal!(z)
        return new_node
    end
end

"""
    wz_take_map!(z, prune=false) → Union{Nothing, PathMap}

Remove and return a PathMap snapshot at the cursor.
Mirrors `WriteZipperCore::take_map` (write_zipper.rs:1973).
"""
function wz_take_map!(z::WriteZipperCore{V, A}, prune::Bool=false) where {V, A}
    # graft_root_vals (DEFAULT): the focus VALUE is taken out too, becoming the returned map's
    # root value (write_zipper.rs:2119-2122). Removal happens BEFORE take_focus, as upstream.
    root_val = wz_remove_val!(z, prune)
    root_node = wz_take_focus!(z, prune)
    # Upstream returns Some when EITHER is present (:2126) — a focus holding only a value still
    # yields a map, one whose root_val is set and whose root node is empty.
    (root_node === nothing && root_val === nothing) && return nothing
    # ⚠️ This previously read `PathMap{V, A}(z.alloc, root_node, nothing)`, but the field order is
    # (root, root_val, alloc) and no (alloc, root, val) constructor exists — so it threw a
    # MethodError ("Cannot convert GlobalAlloc to TrieNodeODRc") on EVERY call where the focus had
    # a subtrie, i.e. its primary use. Invisible because nothing called it that way.
    PathMap{V, A}(root_node, root_val, z.alloc)
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
    _wz_prune_path_internal!(z, should_ascend=false) → Int

Remove empty ancestor nodes.  Internal; mirrors `prune_path_internal` (write_zipper.rs:2337).

🔴 **PRUNING MUST NOT MOVE THE CURSOR** unless `should_ascend` — and NO caller passes true, here or
upstream. This is not a stylistic detail; it was a real defect, fixed 2026-07-31.

Upstream says so in the function's own docstring (write_zipper.rs:2333): *"If `should_ascend` is
`false`, then this method does not move the zipper"*. It walks the dangling spine over a **local
copy** of the path (`temp_path`, :2350, annotated "leaving the path buffer alone") and truncates the
live `key.prefix_buf` ONLY inside `if should_ascend` (:2434). All FIVE of its call sites pass `false`
(:1415, :2099, :2158, :2185, :2219), so upstream's cursor is *never* shortened by a prune. The one
cursor-moving variant, `prune_ascend` (:2193), does it EXPLICITLY —
`let bytes = self.prune_path(); self.ascend(bytes);` — which is the proof that the implicit move was
never intended.

Ours implemented the same walk with a real `wz_ascend!(z, 1)`, which `resize!`s `prefix_buf` (:427).
The cursor was therefore left at the pruned-back position, and the NEXT write went to the wrong path:

    ORIGIN "::" / DESCEND "::a" / JOINMAP / TAKEMAP 1 / SETVAL
      ours before   |[::,     :a,:ab,ba]     <- the value landed at the ORIGIN
      upstream      |[::::a,  :a,:ab,ba]     <- and belongs at the focus

It hid because the prune has to actually *fire* to do damage: `wz_take_focus!` returns early when
the path does not exist (:1681), so the same script without the preceding JOINMAP — which is what
materialises "::::a" — agrees with upstream. Three fuzz cases: 01359, 02038, 02979.

`focus_stack`/`prefix_idx` stay popped, which IS upstream's end state (it pops the node stack at
:2380-2381 while the path buffer stays long). Only `prefix_buf` is restored.

Do NOT "fix" `wz_ascend!` instead — it is a faithful port of write_zipper.rs:1036 and the
`ascend/*` and `prefix/*` tests pin it.

⚠️ OPEN, UNVERIFIED: we call this from SEVEN sites against upstream's five. Mapped by hand:

    ours                              upstream write_zipper.rs
    :651  _wz_remove_branches!        (internal helper — layer above also prunes)
    :1400 wz_join_k_path_into!        NONE   <- suspect
    :1416 wz_join_k_path_into!        NONE   <- suspect (two calls in ONE function)
    :1674 wz_take_focus!              :2219  take_focus
    :1718 wz_prune_path!              :2185
    :1820 wz_remove_branches!         :2099  remove_branches
    :1854 wz_remove_unmasked_branches! :2158 remove_unmasked_branches
    (we route via wz_prune_path!)     :1415  remove_val

`wz_join_k_path_into!` is the one to look at: upstream appears not to prune there at all, and we have
just fixed one defect caused by pruning at the wrong moment. NOT yet settled by execution — recorded
so it is not silently assumed equivalent.
"""
function _wz_prune_path_internal!(z::WriteZipperCore{V, A},
    should_ascend::Bool=false) where {V, A}
    # The loop only ever SHORTENS prefix_buf, so snapshotting it is enough to undo the movement.
    # Snapshot LAZILY — taken only just before the first cursor move. Most calls prune nothing and
    # break out of the loop immediately, and upstream allocates nothing at all here (it re-slices),
    # so an eager `copy` would put an allocation on a hot path that previously had none.
    saved = UInt8[]
    snapped = false
    pruned = 0
    while true
        inner = z.focus_stack[end].node
        # node is empty if it's nothing OR its inner node says so
        is_empty = (inner === nothing) || node_is_empty(inner)
        is_empty || break
        wz_at_root(z) && break
        if !should_ascend && !snapped
            saved = copy(z.prefix_buf)   # first cursor move only — see the note above
            snapped = true
        end
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
    # Put the cursor back. `pruned` was accumulated inside the loop from the in-loop truncation
    # delta, so it still reports the same byte count upstream does (`path_buf.len() - temp_path.len()`,
    # write_zipper.rs:2431) and callers such as a future `prune_ascend` port keep working.
    if snapped && length(z.prefix_buf) < length(saved)
        resize!(z.prefix_buf, length(saved))
        copyto!(z.prefix_buf, saved)
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
export wz_meet_2!, wz_graft_child_maps!, wz_graft_masked_branches!
export wz_meet_k_path_into!, wz_descend_first_k_path!, wz_to_next_k_path!
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
