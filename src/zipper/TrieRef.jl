"""
    TrieRef

Lightweight read-only reference to a location in a trie.

Ports pathmap/src/trie_ref.rs.

Julia collapses `TrieRefBorrowed` / `TrieRefOwned` / `TrieRef` into one struct
(`TrieRefBorrowed`) because GC handles object lifetimes; no unsafe union needed.

State invariants:
  - Invalid  : focus_node === nothing
  - Has key  : focus_node !== nothing && !isempty(node_key)  (cursor inside node)
  - Boundary : focus_node !== nothing && isempty(node_key)   (val stored in .val)
"""

# =====================================================================
# TrieRefBorrowed struct
# =====================================================================

mutable struct TrieRefBorrowed{V, A <: Allocator}
    focus_node::Union{Nothing, TrieNodeODRc{V, A}}
    node_key::Vector{UInt8}        # empty = at node boundary
    val::Union{Nothing, V}    # set only at boundary (node_key empty)
    alloc::A
end

# Type aliases — Owned is the same as Borrowed in Julia (GC owns everything)
const TrieRefOwned{V, A} = TrieRefBorrowed{V, A}
const TrieRef{V, A} = TrieRefBorrowed{V, A}

# =====================================================================
# Constructors
# =====================================================================

"""
Invalid (bad) sentinel.
"""
_tr_new_invalid(::Type{V}, alloc::A) where {V, A <: Allocator} =
    TrieRefBorrowed{V, A}(nothing, UInt8[], nothing, alloc)

_tr_new_invalid(::Type{V}) where {V} = _tr_new_invalid(V, GlobalAlloc())

"""
    _tr_new(node_rc, root_val, path, alloc) → TrieRefBorrowed

Internal constructor.  Descends `path` from `node_rc` via `node_along_path`,
then builds the appropriate state (invalid / has-key / boundary).
Ports `TrieRefBorrowed::new_with_node_and_path_in` and `TrieRefOwned::new_with_node_and_path_in`.
"""
function _tr_new(
    node_rc::TrieNodeODRc{V, A}, root_val::Union{Nothing, V}, path, alloc::A
) where {V, A <: Allocator}
    (final_rc, key, val) = node_along_path(node_rc, path, root_val, false)
    key_len = length(key)
    if key_len > MAX_NODE_KEY_BYTES
        # Key too long to store → invalid (mirrors Rust BAD_SENTINEL path)
        return TrieRefBorrowed{V, A}(nothing, UInt8[], nothing, alloc)
    elseif key_len > 0
        # Cursor is inside a node at a partial key
        return TrieRefBorrowed{V, A}(final_rc, Vector{UInt8}(key), nothing, alloc)
    else
        # At a node boundary — store the val (may be nothing if no val here)
        return TrieRefBorrowed{V, A}(final_rc, UInt8[], val, alloc)
    end
end

"""
    _tr_new_from_key(node_rc, root_val, node_key, path, alloc) → TrieRefBorrowed

Internal constructor for `trie_ref_at_path` when the caller is already inside a
node (has a `node_key`).  Tries to combine `node_key ++ path` to step down one
node level, then falls through to `_tr_new` for the remainder.
Ports `new_with_key_and_path_in`.
"""
function _tr_new_from_key(
    node_rc::TrieNodeODRc{V, A},
    root_val::Union{Nothing, V},
    node_key::Vector{UInt8},
    path::AbstractVector{UInt8},
    alloc::A
) where {V, A <: Allocator}
    node_key_len = length(node_key)
    path_len = length(path)

    cur_node = node_rc
    cur_path = path   # will be narrowed as we step

    if node_key_len > 0 && path_len > 0
        # Build a combined key = node_key ++ first chunk of path (capped at MAX_NODE_KEY_BYTES)
        remaining_cap = MAX_NODE_KEY_BYTES - node_key_len
        chunk_len = min(remaining_cap, path_len)
        combined = vcat(node_key, path[1:chunk_len])

        result = node_get_child(as_tagged(node_rc), combined)
        if result !== nothing
            consumed, next_rc = result
            # consumed ≥ node_key_len (we consumed at least the existing key)
            cur_node = next_rc
            step = consumed - node_key_len   # bytes consumed from path
            cur_path = view(path, (step + 1):path_len)
        else
            # Couldn't step down — treat combined as the new path from current node
            cur_path = combined
        end
    elseif path_len == 0
        # No more path — treat node_key as the remaining key to resolve
        cur_path = node_key
    end
    # (if node_key_len == 0: cur_path = path unchanged)

    _tr_new(cur_node, root_val, cur_path, alloc)
end

# =====================================================================
# PathMap-level entry point
# =====================================================================

"""
    trie_ref_at_path(m::PathMap, path) → TrieRefBorrowed

Returns a lightweight read-only cursor at `path` inside `m`.
Ports the `trie_ref_at_path` method on PathMap (via ZipperReadOnlySubtries).
"""
function trie_ref_at_path(m::PathMap{V, A}, path) where {V, A}
    _ensure_root!(m)
    _tr_new(m.root, m.root_val, path, m.alloc)
end

# =====================================================================
# State accessors (internal)
# =====================================================================

@inline _tr_is_valid(t::TrieRefBorrowed) = t.focus_node !== nothing
@inline _tr_node_key(t::TrieRefBorrowed) = t.node_key
@inline _tr_at_boundary(t::TrieRefBorrowed) = _tr_is_valid(t) && isempty(t.node_key)

# =====================================================================
# Zipper-like read API (mirrors the Zipper / ZipperValues traits)
# =====================================================================

"""
    tr_path_exists(t) → Bool

Returns `true` if the path the TrieRef points to exists in the trie.
Ports `Zipper::path_exists`.
"""
function tr_path_exists(t::TrieRefBorrowed{V, A}) where {V, A}
    _tr_is_valid(t) || return false
    key = _tr_node_key(t)
    if !isempty(key)
        node_contains_partial_key(as_tagged(t.focus_node), key)
    else
        true
    end
end

"""
    tr_get_val(t) → Union{Nothing, V}

Returns the value at the TrieRef's position, or `nothing`.
Ports `ZipperReadOnlyValues::get_val`.
"""
function tr_get_val(t::TrieRefBorrowed{V, A}) where {V, A}
    _tr_is_valid(t) || return nothing
    key = _tr_node_key(t)
    if !isempty(key)
        node_get_val(as_tagged(t.focus_node), key)
    else
        t.val
    end
end

"""
    tr_is_val(t) → Bool

Returns `true` if the TrieRef position holds a value.
Ports `Zipper::is_val`.
"""
tr_is_val(t::TrieRefBorrowed) = tr_get_val(t) !== nothing

"""
    tr_child_count(t) → Int

Returns the number of distinct byte-branches at the TrieRef's position.
Ports `Zipper::child_count`.
"""
function tr_child_count(t::TrieRefBorrowed{V, A}) where {V, A}
    _tr_is_valid(t) || return 0
    count_branches(as_tagged(t.focus_node), _tr_node_key(t))
end

"""
    tr_child_mask(t) → ByteMask

Returns a ByteMask of which byte-branches exist at the TrieRef's position.
Ports `Zipper::child_mask`.
"""
function tr_child_mask(t::TrieRefBorrowed{V, A}) where {V, A}
    _tr_is_valid(t) || return ByteMask(UInt256(0))
    node_branches_mask(as_tagged(t.focus_node), _tr_node_key(t))
end

# =====================================================================
# Subtrie operations
# =====================================================================

"""
    tr_trie_ref_at_path(t, path) → TrieRefBorrowed

Returns a new TrieRef at `path` relative to `t`.
Ports `ZipperReadOnlySubtries::trie_ref_at_path`.
"""
function tr_trie_ref_at_path(t::TrieRefBorrowed{V, A}, path) where {V, A}
    _tr_is_valid(t) || return _tr_new_invalid(V, t.alloc)
    key = _tr_node_key(t)
    if !isempty(key)
        _tr_new_from_key(t.focus_node, nothing, key, collect(UInt8, path), t.alloc)
    else
        _tr_new_from_key(
            t.focus_node, tr_get_val(t), UInt8[], collect(UInt8, path), t.alloc
        )
    end
end

"""
    tr_make_map(t) → PathMap

Creates a PathMap snapshot rooted at the TrieRef's position.
Ports `ZipperInfallibleSubtries::make_map`.
"""
function tr_make_map(t::TrieRefBorrowed{V, A}) where {V, A}
    focus_rc = tr_get_focus_rc(t)
    m = PathMap{V, A}(t.alloc)
    # 🔴 THE `copy` IS LOAD-BEARING — it bumps the node's refcount (Base.copy(::TrieNodeODRc) ->
    # _node_inc_refcnt!, "mirrors Arc::clone"). Assigning `focus_rc` RAW aliases the node while
    # leaving refcnt at 1, so `_cow_in_place!` — which forks only ABOVE 1 — mutates it IN PLACE and
    # the write lands in BOTH maps. MEASURED 2026-08-05, before the fix:
    #     src = {"ab"=>1,"ac"=>2,"ad"=>3};  m = tr_make_map(trie_ref_at_path(src, []))
    #     refcount(m.root.node) == 1                      # two maps, one node, refcnt says one
    #     set_val_at!(m, b"az", 99)
    #     get_val_at(src, b"az") == 99                    # (!!) the SOURCE was mutated
    # Upstream cannot have this bug: `make_map` (trie_ref.rs:290-298) builds from
    # `self.get_focus().into_option()` on a `&self`, so producing an OWNED node ref requires an Rc
    # clone and the refcount rises. Julia has no such implicit clone — the bump must be written.
    #
    # This is `pathmap_rs_reference.md` §1.2 invariant 2 ("a write zipper descending past a share
    # point must uniquify the nodes along its path"): uniquification is DRIVEN BY the refcount, so a
    # share that never raises it is invisible to the mechanism meant to protect it.
    focus_rc === nothing || (m.root = copy(focus_rc))
    m
end

"""
    tr_get_focus_rc(t) → Union{Nothing, TrieNodeODRc}

Returns the `TrieNodeODRc` at the cursor's actual focus position (one level
below `focus_node` when `node_key` is non-empty).
Ports the `get_focus` → `into_option` logic.
"""
function tr_get_focus_rc(t::TrieRefBorrowed{V, A}) where {V, A}
    _tr_is_valid(t) || return nothing
    key = _tr_node_key(t)
    if isempty(key)
        t.focus_node
    else
        result = node_get_child(as_tagged(t.focus_node), key)
        result === nothing ? nothing : result[2]
    end
end

"""
    tr_fork_read_zipper(t) → ReadZipperCore

Forks a `ReadZipperCore` from the TrieRef's position.
Ports `ZipperForking::fork_read_zipper`.
"""
function tr_fork_read_zipper(t::TrieRefBorrowed{V, A}) where {V, A}
    @assert _tr_is_valid(t) "tr_fork_read_zipper called on invalid TrieRef"
    ReadZipperCore(t.focus_node, _tr_node_key(t), 0, tr_get_val(t), t.alloc)
end

# =====================================================================
# Exports
# =====================================================================

export TrieRefBorrowed, TrieRefOwned, TrieRef
export trie_ref_at_path, tr_trie_ref_at_path, tr_make_map
"""
    tr_get_focus_anr(t::TrieRefBorrowed) → AbstractNodeRef

Returns the `AbstractNodeRef` at the TrieRef's cursor position.
Mirrors `ZipperInfallibleSubtries::get_focus` for TrieRef.
"""
function tr_get_focus_anr(t::TrieRefBorrowed{V, A}) where {V, A}
    _tr_is_valid(t) || return ANRNone{V, A}()
    key = _tr_node_key(t)
    if !isempty(key)
        get_node_at_key(as_tagged(t.focus_node), key)
    else
        ANRBorrowedRc{V, A}(t.focus_node)
    end
end

export tr_path_exists, tr_is_val, tr_get_val, tr_child_count, tr_child_mask
export tr_fork_read_zipper, tr_get_focus_rc, tr_get_focus_anr
export _tr_is_valid, _tr_node_key, _tr_at_boundary, _tr_new_invalid
