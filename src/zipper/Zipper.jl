"""
ReadZipperCore — port of `pathmap/src/zipper.rs` (read zipper + PathMap).

Ports:
  - `node_along_path` utility
  - `val_count_below_root` utility
  - `ReadZipperCore{V,A}` (= Rust's `ReadZipperUntracked` — lifetime
    distinctions vanish in Julia's GC-managed world)
  - All `ZipperMoving`, `ZipperIteration`, `ZipperReadOnlyValues` methods
  - `PathMap{V,A}` container with read API

Write zipper (`write_zipper.rs`), zipper head, and exotic zippers
(ProductZipper, OverlayZipper, etc.) are deferred to Phase 1c.

Design note — inner-node storage (TaggedNodeRef analogue):
  Upstream stores `TaggedNodeRef<'a, V, A>` (typed raw ptr) in focus_node and ancestors.
  Julia equivalent: `Union{Nothing, AbstractTrieNode{V,A}}` where `nothing` = EmptyNode sentinel.
  The root_node TrieNodeODRc is kept as an anchor to ensure the root sub-trie stays reachable.
"""

# =====================================================================
# Module-level constants
# =====================================================================

const EXPECTED_DEPTH = 16
const EXPECTED_PATH_LEN = 64

# The closed node union and the narrowing accessors (`TrieNodeVariant`, `_fnode`, `as_tagged`) live in
# nodes/NodeVariant.jl, which is included after the last node type. See that file's header.

# Extract the inner node from a TrieNodeODRc (returns nothing for empty)
@inline _rc_inner(rc::TrieNodeODRc) = rc.node

# =====================================================================
# node_along_path
# =====================================================================
#
# Rust: `pub(crate) fn node_along_path<...>` in zipper.rs.
# Descends as far as possible along `path` from `root_rc`.
# Returns (final_rc, remaining_key_view, val).

function node_along_path(
    root_rc::TrieNodeODRc{V, A}, path, root_val::Union{Nothing, V}, stop_short::Bool=false
) where {V, A}
    node = root_rc
    key = path
    val = root_val
    inner = _fnode(_rc_inner(node), V, A)

    if !isempty(key)
        while true
            result = node_get_child(inner, key)
            result === nothing && break
            consumed, next_rc = result
            if consumed < length(key)
                node = next_rc
                key = view(key, (consumed + 1):length(key))
                inner = _fnode(_rc_inner(node), V, A)
            else
                if !stop_short
                    val = node_get_val(inner, key)
                    node = next_rc
                    key = view(key, 1:0)   # empty subarray
                else
                    val = nothing
                end
                break
            end
        end
    end

    (node, key, val)
end

"""
    _cow_in_place!(rc, inner) -> narrowed inner (possibly a fresh clone)

Copy-on-write one node: if `inner` is shared, clone it and re-point `rc` at the clone.

Equivalent to `make_unique!(rc)` but takes the ALREADY-NARROWED `inner` from `_fnode`, which is the
whole point. `make_unique!` reads `rc.node`, an abstract
`Union{Nothing,AbstractTrieNode}`, and its `_has_refcnt`/`_node_refcount` helpers are
`@nospecialize` — so every call is a dynamic dispatch. Measured on the naive version of this fix:
`remove_val_at!` x20_000 over an UNSHARED map went 42 ms -> 76 ms with BYTE-IDENTICAL allocations,
i.e. nothing was cloned and the entire 1.8x was dispatch. Passing the narrowed union lets
`hasfield` constant-fold per concrete type and keeps the unshared path free.
"""
@inline function _cow_in_place!(rc::TrieNodeODRc{V, A}, inner) where {V, A}
    if hasfield(typeof(inner), :refcnt) && Int(getfield(inner, :refcnt, :acquire)) > 1
        _node_dec_refcnt!(inner)                        # one fewer referrer to the shared node
        rc.node = (clone_self(inner)::TrieNodeODRc{V, A}).node
        return _fnode(_rc_inner(rc), V, A)              # re-narrow: the clone is a different object
    end
    inner
end

# =====================================================================
# node_along_path_mut!
# =====================================================================
#
# 1:1 with upstream `node_along_path_mut` (trie_node.rs:2461). The ONLY difference from
# `node_along_path` above is that this one COPY-ON-WRITES every node it steps through, exactly as
# upstream's `node.make_mut().node_into_child_mut(key)` (trie_node.rs:2468) does.
#
# 🔴 WHY IT EXISTS. Upstream calls the MUTATING walker from both `mend_root` (write_zipper.rs:2452)
# and `new_with_node_and_path_in` (:1141); we called the read-only twin at both sites, and the
# mutating twin was never ported. That is not a theoretical gap — it silently corrupted any map
# sharing nodes with another:
#
#     s = {"x:1","x:2","x:3"};  graft s into t at "g:";  then write to t through
#     write_zipper_at_path(t, "g:x:1")  ->  S LOSES THE VALUE TOO
#
# 17 op shapes corrupt this way (set_val, remove_val, take_map/take_focus, remove_branches,
# insert_prefix, graft, graft_map, join_into, join_map_into, join_into_take, meet_into, restrict,
# restricting, join_k_path_into, meet_k_path_into, …), plus the ZipperHead tracked API.
#
# ⚠️ IT IS A REGRESSION, NOT AN ANCIENT GAP — bisected to `6d3fd84` ("MEND the root at
# construction, do not DESCEND — 75 -> 33 divergences"). Before it `write_zipper_at_path` used
# `_wz_descend_to_internal!`, which built the FULL ancestor stack, so `_wz_ensure_write_unique!`'s
# `for k in 2:n` loop happened to cover the chain. Mending records the origin in `root_key_start`
# instead, leaving nothing above `focus_stack[1]` to walk — the 42 fuzz divergences that fix closed
# and the corruption it opened are the same trade. Reverting to descend is not the answer; adding
# the make_mut upstream always had is.
#
# ORDER MATTERS: COW the node FIRST, then re-read its children. `clone_self` gives the clone its OWN
# child wrappers, so a child fetched before the clone belongs to the pre-clone parent and writing
# through it would leak straight back into whoever still shares that parent.
function node_along_path_mut!(
    root_rc::TrieNodeODRc{V, A}, path, root_val::Union{Nothing, V}, stop_short::Bool=false
) where {V, A}
    node = root_rc
    key = path
    val = root_val
    inner = _cow_in_place!(node, _fnode(_rc_inner(node), V, A))

    if !isempty(key)
        while true
            result = node_get_child(inner, key)
            result === nothing && break
            consumed, next_rc = result
            if consumed < length(key)
                node = next_rc
                key = view(key, (consumed + 1):length(key))
                inner = _cow_in_place!(node, _fnode(_rc_inner(node), V, A))
            else
                if !stop_short
                    val = node_get_val(inner, key)
                    node = next_rc
                    key = view(key, 1:0)
                else
                    val = nothing
                end
                break
            end
        end
    end

    (node, key, val)
end

# ─────────────────────────────────────────────────────────────────────────────
# Allocation-free read hot path (docs/PERF_VS_UPSTREAM_2026-06-24.md, optimization #1).
#
# `node_get_child` returns `Union{Nothing, Tuple{Int, TrieNodeODRc}}` — and `TrieNodeODRc` is a
# mutable struct (non-isbits), so the `Tuple` heap-BOXES inside the `Union` (the #1 self-time +
# alloc site in the profile). It also slices `key[1:klen]` (a copy). The `_nb` ("no-box") variants
# below fix both: they take `(path, off)` (no per-iteration `view`), compare the prefix in place
# (no slice copy), and return `Tuple{Int, Union{Nothing, TrieNodeODRc}}` — whose 2nd field is a
# nullable pointer, so the tuple is isbits-representable and stays in registers (no box).
# Used ONLY by `node_along_path_off` — the 25 other `node_get_child` callers are untouched.

@inline function _prefix_eq_off(
    path::AbstractVector{UInt8}, off::Int, klen::Int, nkey
)::Bool
    (length(path) - off) >= klen || return false
    @inbounds for i in 1:klen
        path[off + i] == nkey[i] || return false
    end
    true
end

@inline function node_get_child_nb(
    n::AbstractByteNode{V, A}, path::AbstractVector{UInt8}, off::Int
)::Tuple{Int, Union{Nothing, TrieNodeODRc{V, A}}} where {V, A}
    @inbounds cf = _bn_get(n, path[off + 1])
    (cf === nothing || cf.rec === nothing) && return (0, nothing)
    (1, cf.rec)
end
@inline function node_get_child_nb(
    n::LineListNode{V, A}, path::AbstractVector{UInt8}, off::Int
)::Tuple{Int, Union{Nothing, TrieNodeODRc{V, A}}} where {V, A}
    if is_child_0(n)
        klen = key_len_0(n)
        _prefix_eq_off(path, off, klen, n.key0) && return (klen, into_child(n.slot0))
    end
    if is_child_1(n)
        klen = key_len_1(n)
        _prefix_eq_off(path, off, klen, n.key1) && return (klen, into_child(n.slot1))
    end
    (0, nothing)
end
@inline function node_get_child_nb(
    n::BridgeNode{V, A}, path::AbstractVector{UInt8}, off::Int
)::Tuple{Int, Union{Nothing, TrieNodeODRc{V, A}}} where {V, A}
    (n.is_child && !node_is_empty(n)) || return (0, nothing)
    klen = length(n.key)
    _prefix_eq_off(path, off, klen, n.key) || return (0, nothing)
    child_rc = into_child(_bn_pl(n))
    is_empty_node(child_rc) && return (0, nothing)
    (klen, child_rc)
end
@inline function node_get_child_nb(
    t::TinyRefNode{V, A}, path::AbstractVector{UInt8}, off::Int
)::Tuple{Int, Union{Nothing, TrieNodeODRc{V, A}}} where {V, A}
    if t.is_child && !node_is_empty(t)
        klen = length(t.key)
        if _prefix_eq_off(path, off, klen, t.key)
            child_rc = into_child(t.payload)
            is_empty_node(child_rc) || return (klen, child_rc)
        end
    end
    (0, nothing)
end
# Fallback for any other AbstractTrieNode — delegates to node_get_child (correct, not optimized).
@inline function node_get_child_nb(
    n::AbstractTrieNode{V, A}, path::AbstractVector{UInt8}, off::Int
)::Tuple{Int, Union{Nothing, TrieNodeODRc{V, A}}} where {V, A}
    r = node_get_child(n, view(path, (off + 1):length(path)))
    r === nothing ? (0, nothing) : r
end

# Returns the descent's stop node + the byte OFFSET consumed from `path` + `full` (true iff the
# remaining matched a child edge in full ⇒ all path bytes were traversed). Returning a `Bool`
# instead of the looked-up value keeps the return tuple `(TrieNodeODRc, Int, Bool)` isbits-
# representable — no `Union{Nothing,V}` field ⇒ no heap box (the Cluster-2 alloc at this return +
# the `indexed_iterate` destructure box are eliminated). Callers do the value lookup uniformly as
# `node_get_val(inner(node), view(path, off+1:end))`; `full` is `path_exists_at`'s dangling-safe
# "structurally exists" signal. In both the terminal-match and the stall case `node` is the node to
# look the value up in (NOT advanced past the final edge), and `off` is the start of the remaining.
function node_along_path_off(
    root_rc::TrieNodeODRc{V, A}, path::AbstractVector{UInt8}
) where {V, A}
    node = root_rc
    inner = _fnode(_rc_inner(node), V, A)
    n = length(path)
    off = 0
    full = n == 0
    while off < n
        consumed, next_rc = node_get_child_nb(inner, path, off)
        next_rc === nothing && break
        if consumed < n - off
            node = next_rc
            off += consumed
            inner = _fnode(_rc_inner(node), V, A)
        else                                  # remaining matched a child edge in full → fully traversed
            full = true
            break
        end
    end
    (node, off, full)
end

# =====================================================================
# val_count_below_root
# =====================================================================

function val_count_below_root(inner_node)::Int
    inner_node === nothing && return 0
    cache = Dict{UInt64, Int}()
    node_val_count(inner_node, cache)
end

# =====================================================================
# ReadZipperCore struct
# =====================================================================
#
# Rust: `pub struct ReadZipperCore<'a, 'path, V, A>` in a pub(crate) mod.
#
# Julia differences:
#  - OwnedOrBorrowed<'a, TrieNodeODRc>  → root_node::TrieNodeODRc (GC owns all)
#  - TaggedNodeRef<'a, V, A>            → Any (inner AbstractTrieNode or nothing)
#  - SliceOrLen<'path>                  → origin_path_len::Int
#  - MiriWrapper<T>                     → plain T (no Miri concerns)
#  - Lifetime params 'a, 'path          → dropped

"""
    ReadZipperCore{V, A<:Allocator}

Read-only cursor into a `PathMap`-like trie.  Corresponds to both
`ReadZipperCore` and `ReadZipperUntracked` in upstream.

focus_node and ancestors store `Union{Nothing,AbstractTrieNode{V,A}}` —
the Julia equivalent of upstream's `TaggedNodeRef<'a,V,A>` typed ref.
`nothing` is the EmptyNode sentinel. NOT `TrieNodeODRc` wrappers.
"""
mutable struct ReadZipperCore{V, A <: Allocator} <: AbstractZipper
    root_key_start::Int               # 0-indexed: prefix_buf[root_key_start+1:] = root key
    root_val::Union{Nothing, V} # value at the zipper root (if any)
    root_node::TrieNodeODRc{V, A} # anchor Rc — keeps root sub-trie alive
    focus_node::Union{Nothing, AbstractTrieNode{V, A}}  # nothing = EmptyNode sentinel (TaggedNodeRef<V,A>)
    focus_iter_token::IterToken           # iteration token (NODE_ITER_INVALID = unstarted)
    prefix_buf::Vector{UInt8}     # full path buffer: origin_path ++ relative_path
    origin_path_len::Int               # length of initial path prefix embedded in prefix_buf
    ancestors::Vector{Tuple{Union{Nothing, AbstractTrieNode{V, A}}, IterToken, Int}} # (TaggedNodeRef, iter_tok, key_offset_0)
    alloc::A
end

const ReadZipperUntracked{V, A} = ReadZipperCore{V, A}

# =====================================================================
# Constructors
# =====================================================================

# Internal constructor: root_rc already positioned; path = full prefix_buf content.
# root_key_start_0 is the 0-indexed offset of the root node's key in path.
function ReadZipperCore(
    root_rc::TrieNodeODRc{V, A},
    path::AbstractVector{UInt8},
    root_key_start_0::Int,
    root_val::Union{Nothing, V},
    alloc::A
) where {V, A <: Allocator}
    # Fix 2: pre-allocate prefix_buf and ancestors to avoid _growend!/memmove
    # in the hot descent loop.  sizehint! returns the vector in Julia 1.1+.
    _pbuf = Vector{UInt8}(path)
    length(_pbuf) < EXPECTED_PATH_LEN && sizehint!(_pbuf, EXPECTED_PATH_LEN)
    _anc_type = Tuple{Union{Nothing, AbstractTrieNode{V, A}}, IterToken, Int}
    _anc = sizehint!(Vector{_anc_type}(), EXPECTED_DEPTH)
    ReadZipperCore{V, A}(
        root_key_start_0,
        root_val,
        root_rc,
        _rc_inner(root_rc),                         # focus_node = inner node
        NODE_ITER_INVALID,
        _pbuf,
        length(path),                               # origin_path_len
        _anc,
        alloc
    )
end

# Full constructor with path traversal (mirrors new_with_node_and_path_in).
# Traverses path[root_key_start_0+1:] within root_rc, then positions the
# zipper root at the deepest reachable node.
function ReadZipperCore_at_path(
    root_rc::TrieNodeODRc{V, A},
    path::AbstractVector{UInt8},
    root_prefix_len::Int,
    root_key_start_0::Int,
    root_val::Union{Nothing, V},
    alloc::A
) where {V, A <: Allocator}
    sub_path = view(path, (root_key_start_0 + 1):length(path))
    final_rc, remaining_key, val = node_along_path(root_rc, sub_path, root_val, false)
    new_root_key_start = root_prefix_len - length(remaining_key)  # 0-indexed
    ReadZipperCore(final_rc, path, new_root_key_start, val, alloc)
end

# =====================================================================
# Internal helpers
# =====================================================================

# Type-parameterized EmptyNode fallback for focus dispatch
@inline _zfnode(z::ReadZipperCore{V, A}) where {V, A} = _fnode(z.focus_node, V, A)

# 0-indexed byte offset in prefix_buf where the focus node's key starts
@inline function _znode_key_start(z::ReadZipperCore)
    isempty(z.ancestors) ? z.root_key_start : z.ancestors[end][3]
end

# The key bytes within the focus node (view into prefix_buf, 0-indexed offset)
@inline function _znode_key(z::ReadZipperCore)
    ks = _znode_key_start(z)
    view(z.prefix_buf, (ks + 1):length(z.prefix_buf))
end

# How many bytes can be ascended within the current node (without popping ancestor)
@inline function _excess_key_len(z::ReadZipperCore)
    lb = isempty(z.ancestors) ? z.origin_path_len : z.ancestors[end][3]
    length(z.prefix_buf) - lb
end

# 0-indexed start of the parent's key in prefix_buf
@inline function _parent_key_start(z::ReadZipperCore)
    length(z.ancestors) >= 2 ? z.ancestors[end - 1][3] : z.root_key_start
end

# Key leading to focus_node within its parent
@inline function _parent_key(z::ReadZipperCore)
    ks = _parent_key_start(z)
    view(z.prefix_buf, (ks + 1):_znode_key_start(z))
end

# prepare_buffers!: no-op in Julia (buffers always allocated)
@inline _prepare_buffers!(::ReadZipperCore) = nothing

# is_val_internal: does the current focus position hold a value?
function _is_val_internal(z::ReadZipperCore{V, A}) where {V, A}
    key = _znode_key(z)
    if !isempty(key)
        node_contains_val(_zfnode(z), key)
    elseif !isempty(z.ancestors)
        parent = z.ancestors[end][1]
        node_contains_val(_fnode(parent, V, A), _parent_key(z))
    else
        !isnothing(z.root_val)
    end
end

# get_val: value at current focus
function _get_val(z::ReadZipperCore{V, A}) where {V, A}
    key = _znode_key(z)
    if !isempty(key)
        node_get_val(_zfnode(z), key)
    elseif !isempty(z.ancestors)
        parent = z.ancestors[end][1]
        node_get_val(_fnode(parent, V, A), _parent_key(z))
    else
        z.root_val
    end
end

# regularize!: descend into child if node_get_child(focus, node_key) succeeds
function _regularize!(z::ReadZipperCore{V, A}) where {V, A}
    nk = _znode_key(z)
    result = node_get_child(_zfnode(z), nk)
    result === nothing && return nothing
    _, next_rc = result
    push!(z.ancestors, (z.focus_node, z.focus_iter_token, length(z.prefix_buf)))
    z.focus_node = _rc_inner(next_rc)
    z.focus_iter_token = NODE_ITER_INVALID
end

# ascend across nodes: pop one ancestor without changing prefix_buf length
function _ascend_across_nodes!(z::ReadZipperCore)
    if !isempty(z.ancestors)
        focus_node, iter_tok, _ = pop!(z.ancestors)
        z.focus_node = focus_node
        z.focus_iter_token = iter_tok
    else
        z.focus_iter_token = NODE_ITER_INVALID
    end
end

# =====================================================================
# Internal ReadZipperCore helpers used by ProductZipper
# =====================================================================

"""
    _zc_regularize!(z)

If focus has a child at node_key, push current focus into ancestors
and set focus_node to the child. No-op if already regularized.
Mirrors `ReadZipperCore::regularize` (zipper.rs:2254).
"""
function _zc_regularize!(z::ReadZipperCore{V, A}) where {V, A}
    key = collect(_znode_key(z))
    isempty(key) && return nothing
    result = node_get_child(_zfnode(z), key)
    result === nothing && return nothing
    consumed, next_rc = result
    push!(z.ancestors, (z.focus_node, z.focus_iter_token, length(z.prefix_buf)))
    z.focus_node = _rc_inner(next_rc)
    z.focus_iter_token = NODE_ITER_INVALID
end

"""
    _zc_deregularize!(z)

If at a node boundary (empty node_key), pop one ancestor.
Mirrors `ReadZipperCore::deregularize` (zipper.rs:2269).
"""
function _zc_deregularize!(z::ReadZipperCore)
    if length(z.prefix_buf) == _znode_key_start(z)
        _ascend_across_nodes!(z)
    end
end

"""
    _zc_push_node!(z, node_inner)

Push a raw inner node onto the ancestor stack, making it the new focus.
Mirrors `ReadZipperCore::push_node` (zipper.rs:2752).
"""
function _zc_push_node!(
    z::ReadZipperCore{V, A}, node_inner::Union{Nothing, AbstractTrieNode{V, A}}
) where {V, A}
    push!(z.ancestors, (z.focus_node, z.focus_iter_token, length(z.prefix_buf)))
    z.focus_node = node_inner
    z.focus_iter_token = NODE_ITER_INVALID
end

"""
    _zc_node_key(z) → view

Return the current node_key slice. Mirrors `ReadZipperCore::node_key`.
"""
@inline _zc_node_key(z::ReadZipperCore) = _znode_key(z)

# upstream `ascend_within_node` (zipper.rs:3355-3365): trim prefix_buf to just past the prior branch key;
# returns the bytes ascended
function _ascend_within_node!(z::ReadZipperCore{V, A}) where {V, A}
    branch_key = prior_branch_key(_zfnode(z), _znode_key(z))
    new_len = max(z.origin_path_len, _znode_key_start(z) + length(branch_key))
    old_len = length(z.prefix_buf)
    resize!(z.prefix_buf, new_len)
    ascended = old_len - new_len
    ascended > 0 && _reascend_iter_token!(z, ascended)
    ascended
end

# upstream `reascend_iter_token` (zipper.rs:3369-3380): after removing bytes within the focus node, an
# invalid cursor stays invalid, a nonexistent-path cursor becomes invalid, otherwise the node re-encodes it.
@inline function _reascend_iter_token!(z::ReadZipperCore, byte_count::Int)
    tok = z.focus_iter_token
    tok == NODE_ITER_INVALID && return nothing
    if node_iter_token_is_nonexistent(tok)
        z.focus_iter_token = NODE_ITER_INVALID
        return nothing
    end
    z.focus_iter_token = ascend_iter_token(_zfnode(z), tok, byte_count)
    nothing
end

# descend_to_internal!: extend prefix_buf with k, descend via node_get_child
function _descend_to_internal!(z::ReadZipperCore{V, A}, k) where {V, A}
    z.focus_iter_token = NODE_ITER_INVALID
    append!(z.prefix_buf, k)
    key_start = _znode_key_start(z)
    key = view(z.prefix_buf, (key_start + 1):length(z.prefix_buf))

    while true
        result = node_get_child(_zfnode(z), key)
        result === nothing && break
        consumed, next_rc = result
        key_start += consumed
        push!(z.ancestors, (z.focus_node, NODE_ITER_INVALID, key_start))
        z.focus_node = _rc_inner(next_rc)
        if consumed < length(key)
            key = view(z.prefix_buf, (key_start + 1):length(z.prefix_buf))
        else
            return view(z.prefix_buf, 1:0)  # empty
        end
    end
    key
end

# descend to the first child (for descend_until, descend_first_byte)
function _descend_first!(z::ReadZipperCore{V, A}, obs = nothing) where {V, A}
    _prepare_buffers!(z)
    prefix_opt, child_opt = first_child_from_key(_zfnode(z), _znode_key(z))
    prefix_opt === nothing && return nothing   # unreachable per upstream
    append!(z.prefix_buf, prefix_opt)
    descend_to!(obs, prefix_opt)
    # upstream `descend_first` (zipper.rs:3242-3270): a non-empty step invalidates the token BEFORE the
    # ancestor push, in both arms
    isempty(prefix_opt) || (z.focus_iter_token = NODE_ITER_INVALID)
    if child_opt !== nothing
        push!(z.ancestors, (z.focus_node, z.focus_iter_token, length(z.prefix_buf)))
        z.focus_node = child_opt   # already AbstractTrieNode (from first_child_from_key)
        z.focus_iter_token = NODE_ITER_INVALID
        if isempty(prefix_opt)
            _descend_first!(z, obs)   # recurse if zero-byte prefix (node boundary)
        end
    end
end

# =====================================================================
# Zipper interface methods
# =====================================================================

function path_exists(z::ReadZipperCore{V, A}) where {V, A}
    key = _znode_key(z)
    isempty(key) ? true : node_contains_partial_key(_zfnode(z), key)
end

is_val(z::ReadZipperCore) = _is_val_internal(z)
val(z::ReadZipperCore) = _get_val(z)
get_val(z::ReadZipperCore) = _get_val(z)   # ZipperReadOnlyValues

"""
    val_at(z, path) -> Union{Nothing, V}

Value at `path`, RELATIVE TO THE FOCUS, without moving the zipper — upstream
`ZipperValues::val_at` (zipper.rs:66).

Upstream resolves it with a borrowed trie-ref built from `focus_parent()` + `node_key()` + `path`
(zipper.rs:2338-2352). We cannot reuse `_get_val`'s node-local lookup: `node_get_val` is
SINGLE-NODE (DenseByteNode requires `length(key) == 1`), so a relative path crossing a node
boundary needs a walk. This resolves the ABSOLUTE target from the zipper's own root anchor via
`node_along_path`, which every zipper constructor already uses.

The original zipper is untouched — this reads through the anchor rather than descending and
ascending back, so it cannot strand the focus on a dangling path when `path` does not exist.

Added 2026-08-03. Its ABSENCE blocked upstream's own conformance battery: `zipper_val_at_test`
(zipper.rs:3904) and `zipper_val_at_long_path_test` (:3944) are 27 `val_at` calls and nothing else,
so neither could be ported.
"""
function val_at(z::ReadZipperCore{V, A}, path::AbstractVector{UInt8}) where {V, A}
    _prepare_buffers!(z)
    isempty(path) && return _get_val(z)
    # 1:1 with upstream `get_val_at` (zipper.rs:2891-2911): a trie ref built from the FOCUS node and
    # `node_key() ++ path`. Ours used to walk the whole `prefix_buf ++ path` from `z.root_node` — but
    # for `read_zipper_at_path` that is the node the ROOT path already reached, so the root bytes were
    # walked twice and values were missed (docs/UPSTREAM_DELTA_2026-09-16.md #12b).
    # Two phases, as before: follow child edges, then `node_get_val` over the remaining bytes (a value
    # slot is never returned by `node_get_child`).
    key = vcat(collect(_znode_key(z)), path)
    inner = _zfnode(z)
    off = 0
    while off < length(key)
        r = node_get_child(inner, view(key, (off + 1):length(key)))
        r === nothing && break
        consumed, next_rc = r
        consumed < length(key) - off || break      # a full edge: the value sits in `inner`
        off += consumed
        inner = _fnode(_rc_inner(next_rc), V, A)
    end
    node_get_val(inner, view(key, (off + 1):length(key)))
end

get_val_at(z::ReadZipperCore, p::AbstractVector{UInt8}) = val_at(z, p)   # ZipperReadOnlyValues

function child_count(z::ReadZipperCore{V, A}) where {V, A}
    count_branches(_zfnode(z), _znode_key(z))
end

function child_mask(z::ReadZipperCore{V, A}) where {V, A}
    node_branches_mask(_zfnode(z), _znode_key(z))
end

# =====================================================================
# ZipperMoving methods
# =====================================================================

at_root(z::ReadZipperCore) = length(z.prefix_buf) <= z.origin_path_len

# zipper.rs:2049-2060 (`depth` = path length below the root; `focus_byte` = the last buffer byte, which at the
# root may be the last byte of the root prefix)
depth(z::ReadZipperCore) = max(length(z.prefix_buf) - z.origin_path_len, 0)
focus_byte(z::ReadZipperCore) = isempty(z.prefix_buf) ? nothing : @inbounds(z.prefix_buf[end])
root_prefix_path(z::ReadZipperCore) = view(z.prefix_buf, 1:z.origin_path_len)

function reset!(z::ReadZipperCore)
    while !isempty(z.ancestors)
        focus_node, _iter_tok, _ = pop!(z.ancestors)
        z.focus_node = focus_node
    end
    # 🔴 DISCARD THE STORED ITERATION TOKEN — upstream `zipper.rs:1565` writes
    # `self.focus_iter_token = NODE_ITER_INVALID` and binds the ancestor's token as `_tok`, the
    # underscore saying the saved value is deliberately thrown away. Ours RESTORED it, so a reset
    # after a PARTIAL walk resumed mid-iteration instead of restarting.
    # MEASURED before the fix — iterate n values, reset, then walk to exhaustion:
    #     flat   ["a","b","c","d"]  stop@2 -> ["c","d"]            (2 values never seen again)
    #     nested 5 keys             stop@2 -> ["ba","bb","c"]
    #     deep   4 keys             stop@1 -> ["b"]                 (silently skips 2)
    #     wide   30 keys            stop@3 -> []                    (returns NOTHING)
    # ⚠️ A walk taken to EXHAUSTION first clears the token as a side effect, so the obvious test
    # (iterate all, reset, iterate all) PASSES over the bug. It only shows up after a partial walk.
    z.focus_iter_token = NODE_ITER_INVALID
    resize!(z.prefix_buf, z.origin_path_len)
    nothing
end

# path relative to zipper root
@inline path(z::ReadZipperCore) =
    view(z.prefix_buf, (z.origin_path_len + 1):length(z.prefix_buf))

function val_count(z::ReadZipperCore{V, A}) where {V, A}
    root_val_cnt = _is_val_internal(z) ? 1 : 0
    nk = _znode_key(z)
    if isempty(nk)
        val_count_below_root(_zfnode(z)) + root_val_cnt
    else
        # 1:1 with upstream `val_count` (zipper.rs:2075-2088): the focus node is `get_focus()` —
        # `get_node_at_key`, which also synthesises the node when `nk` ends inside a key — and a
        # missing focus counts only the focus value. The old fallback counted `to_next_val` steps,
        # which do not stop at the focus subtree (docs/UPSTREAM_DELTA_2026-09-16.md #12a).
        focus = get_node_at_key(_zfnode(z), nk)
        is_none(focus) ? root_val_cnt : val_count_below_root(as_tagged(focus)) + root_val_cnt
    end
end

function descend_to!(z::ReadZipperCore, k)
    isempty(k) && return nothing
    _prepare_buffers!(z)
    _descend_to_internal!(z, k)
    nothing
end

function descend_to_check!(z::ReadZipperCore{V, A}, k) where {V, A}
    isempty(k) && return path_exists(z)
    _prepare_buffers!(z)
    remaining = _descend_to_internal!(z, k)
    isempty(remaining) ? true : node_contains_partial_key(_zfnode(z), remaining)
end

function descend_to_byte!(z::ReadZipperCore{V, A}, k::UInt8) where {V, A}
    _prepare_buffers!(z)
    push!(z.prefix_buf, k)
    z.focus_iter_token = NODE_ITER_INVALID
    nk = _znode_key(z)
    result = node_get_child(_zfnode(z), nk)
    if result !== nothing
        _, next_rc = result
        push!(z.ancestors, (z.focus_node, z.focus_iter_token, length(z.prefix_buf)))
        z.focus_node = _rc_inner(next_rc)
    end
    nothing
end

function descend_to_existing_byte!(z::ReadZipperCore{V, A}, k::UInt8) where {V, A}
    _prepare_buffers!(z)
    push!(z.prefix_buf, k)
    nk = _znode_key(z)
    result = node_get_child(_zfnode(z), nk)
    if result !== nothing
        z.focus_iter_token = NODE_ITER_INVALID
        _, next_rc = result
        push!(z.ancestors, (z.focus_node, z.focus_iter_token, length(z.prefix_buf)))
        z.focus_node = _rc_inner(next_rc)
        return true
    end
    if node_contains_partial_key(_zfnode(z), nk)
        z.focus_iter_token = NODE_ITER_INVALID   # zipper.rs:2149-2151
        return true
    end
    pop!(z.prefix_buf)
    false
end

# zipper.rs:2158-2177
function descend_indexed_byte!(z::ReadZipperCore{V, A}, child_idx::Int)::Union{Nothing, UInt8} where {V, A}
    _prepare_buffers!(z)
    prefix_opt, child_opt = nth_child_from_key(_zfnode(z), _znode_key(z), child_idx)
    prefix_opt === nothing && return nothing
    push!(z.prefix_buf, prefix_opt)
    # upstream zipper.rs:2162-2176: the focus moved, so the token is invalidated in BOTH arms, and
    # BEFORE the ancestor push (ours pushed the stale token, and kept it when no child node exists)
    z.focus_iter_token = NODE_ITER_INVALID
    if child_opt !== nothing
        push!(z.ancestors, (z.focus_node, z.focus_iter_token, length(z.prefix_buf)))
        z.focus_node = child_opt   # AbstractTrieNode from nth_child_from_key
    end
    prefix_opt
end

# upstream `ReadZipperCore::descend_first_byte` (zipper.rs:2179-2228), returning the byte (0.4.0 shape)
function _zc_descend_first_byte!(z::ReadZipperCore{V, A})::Union{Nothing, UInt8} where {V, A}
    _prepare_buffers!(z)
    if z.focus_iter_token == NODE_ITER_INVALID
        z.focus_iter_token = iter_token_for_path(_zfnode(z), _znode_key(z))
    end
    node_iter_token_is_nonexistent(z.focus_iter_token) && return nothing
    new_tok, key_bytes, child_rc, _value = next_items(_zfnode(z), z.focus_iter_token, false)
    new_tok == NODE_ITER_FINISHED && return nothing
    node_key = _znode_key(z)
    byte_idx = length(node_key)
    # `iter_token_for_path` positions a lower-bound cursor, so on a non-existent focus the item may belong
    # to a sibling; only descend when it continues the path we're on (5f7fa2a).
    (byte_idx >= length(key_bytes) || !slice_starts_with(key_bytes, node_key)) && return nothing
    descended_byte = key_bytes[byte_idx + 1]
    push!(z.prefix_buf, descended_byte)
    if length(key_bytes) == byte_idx + 1
        z.focus_iter_token = new_tok
        if child_rc !== nothing
            push!(z.ancestors, (z.focus_node, new_tok, length(z.prefix_buf)))
            z.focus_node = _rc_inner(child_rc)
            z.focus_iter_token = new_iter_token(_zfnode(z))
        end
    else
        z.focus_iter_token = ascend_iter_token(_zfnode(z), new_tok, length(key_bytes) - (byte_idx + 1))
    end
    descended_byte
end

descend_first_byte!(z::ReadZipperCore) = _zc_descend_first_byte!(z)

# zipper.rs:2230-2242
function descend_until_observed!(z::ReadZipperCore, obs)
    moved = false
    while child_count(z) == 1
        moved = true
        _descend_first!(z, obs)
        _is_val_internal(z) && break
    end
    moved
end

# upstream `ReadZipperCore::ascend` (zipper.rs:2431-2460): returns the bytes ascended
function _zc_ascend!(z::ReadZipperCore, steps::Int)::Int
    at_root(z) && return 0
    remaining = steps
    while remaining > 0
        if _excess_key_len(z) == 0
            isempty(z.ancestors) && return steps - remaining
            focus_node, iter_tok, _ = pop!(z.ancestors)
            z.focus_node = focus_node
            z.focus_iter_token = iter_tok
        end
        cur_jump = min(remaining, _excess_key_len(z))
        if cur_jump > 0
            resize!(z.prefix_buf, length(z.prefix_buf) - cur_jump)
            _reascend_iter_token!(z, cur_jump)
            remaining -= cur_jump
        end
    end
    steps
end

ascend!(z::ReadZipperCore, steps::Int) = _zc_ascend!(z, steps)

# upstream `ReadZipperCore::ascend_byte` (zipper.rs:2462-2484)
function ascend_byte!(z::ReadZipperCore)
    at_root(z) && return false
    if _excess_key_len(z) == 0
        isempty(z.ancestors) && return false
        focus_node, iter_tok, _ = pop!(z.ancestors)
        z.focus_node = focus_node
        z.focus_iter_token = iter_tok
    end
    pop!(z.prefix_buf)
    _reascend_iter_token!(z, 1)
    true
end

# upstream `ReadZipperCore::ascend_until` (zipper.rs:2486-2503): returns the bytes ascended
function _zc_ascend_until!(z::ReadZipperCore)::Int
    at_root(z) && return 0
    ascended = 0
    while true
        isempty(_znode_key(z)) && _ascend_across_nodes!(z)
        ascended += _ascend_within_node!(z)
        (child_count(z) > 1 || _is_val_internal(z) || at_root(z)) && return ascended
    end
end

# upstream `ReadZipperCore::ascend_until_branch` (zipper.rs:2505-2522): returns the bytes ascended
function _zc_ascend_until_branch!(z::ReadZipperCore)::Int
    at_root(z) && return 0
    ascended = 0
    while true
        isempty(_znode_key(z)) && _ascend_across_nodes!(z)
        ascended += _ascend_within_node!(z)
        (child_count(z) > 1 || at_root(z)) && return ascended
    end
end

ascend_until!(z::ReadZipperCore) = _zc_ascend_until!(z)
ascend_until_branch!(z::ReadZipperCore) = _zc_ascend_until_branch!(z)

# =====================================================================
# ZipperIteration — to_next_val!
# =====================================================================

# upstream `ReadZipperCore::to_next_get_val_observed` (zipper.rs:2924-3003)
function to_next_get_val_observed!(z::ReadZipperCore{V, A}, obs) where {V, A}
    _prepare_buffers!(z)
    while true
        if z.focus_iter_token == NODE_ITER_INVALID
            z.focus_iter_token = iter_token_for_path(_zfnode(z), _znode_key(z))
        end
        new_tok, key_bytes, child_rc, value = if z.focus_iter_token < TOKEN_LAST   # 9485052
            next_items(_zfnode(z), z.focus_iter_token, false)
        else
            (NODE_ITER_FINISHED, UInt8[], nothing, nothing)
        end
        if new_tok != NODE_ITER_FINISHED
            z.focus_iter_token = new_tok
            key_start = _znode_key_start(z)
            # Make sure we don't move to a branch that forks above the zipper root
            origin_len = z.origin_path_len
            if key_start < origin_len
                unmod_len = origin_len - key_start
                if unmod_len > length(key_bytes) ||
                   view(z.prefix_buf, (key_start + 1):origin_len) != view(key_bytes, 1:unmod_len)
                    ascend!(obs, length(z.prefix_buf) - origin_len)
                    resize!(z.prefix_buf, origin_len)
                    z.focus_iter_token = NODE_ITER_INVALID   # 4470349
                    return nothing
                end
            end
            # The rewind may pass below the root, but those bytes are re-supplied identically by
            # `key_bytes` (checked above); the observer tracks the path from the root.
            obs_skip = max(origin_len - key_start, 0)
            ascend!(obs, length(z.prefix_buf) - key_start - obs_skip)
            resize!(z.prefix_buf, key_start)
            append!(z.prefix_buf, key_bytes)
            obs_skip <= length(key_bytes) && descend_to!(obs, view(key_bytes, (obs_skip + 1):length(key_bytes)))
            if child_rc !== nothing
                push!(z.ancestors, (z.focus_node, new_tok, length(z.prefix_buf)))
                z.focus_node = _rc_inner(child_rc)
                z.focus_iter_token = new_iter_token(_zfnode(z))
            end
            value !== nothing && return value
        else
            if !isempty(z.ancestors)
                focus_node, iter_tok, prefix_offset = pop!(z.ancestors)
                z.focus_node = focus_node
                z.focus_iter_token = iter_tok
                ascend!(obs, length(z.prefix_buf) - prefix_offset)
                resize!(z.prefix_buf, prefix_offset)
            else
                z.focus_iter_token = NODE_ITER_INVALID
                ascend!(obs, length(z.prefix_buf) - z.origin_path_len)
                resize!(z.prefix_buf, z.origin_path_len)
                return nothing
            end
        end
    end
end

# zipper.rs:2661-2664 (the value type is never `nothing`: `PathMap{UnitVal}` stores `UNIT_VAL`)
to_next_val_observed!(z::ReadZipperCore, obs) = to_next_get_val_observed!(z, obs) !== nothing

# =====================================================================
# ZipperMoving remaining defaults (zipper.rs trait defaults)
# =====================================================================

# upstream `ReadZipperCore::to_next_sibling_byte` (zipper.rs:2359-2424), token based (4601b5a, 458602a,
# 679a9b7, e0f32c0): the next item strictly after the focus, accepted only if it differs from the focus in
# its last byte alone.
function _zc_to_next_sibling_byte!(z::ReadZipperCore{V, A})::Union{Nothing, UInt8} where {V, A}
    at_root(z) && return nothing
    _prepare_buffers!(z)
    isempty(z.prefix_buf) && return nothing
    _zc_deregularize!(z)
    if z.focus_iter_token == NODE_ITER_INVALID
        z.focus_iter_token = iter_token_for_path(_zfnode(z), _znode_key(z))
    end
    new_tok, key_bytes, child_rc, _value = next_items(_zfnode(z), z.focus_iter_token, true)
    if new_tok == NODE_ITER_FINISHED
        _regularize!(z)
        return nothing
    end
    node_key = _znode_key(z)
    node_key_len = length(node_key)
    node_key_len == 0 && return nothing     # the root has no siblings
    fixed_len = node_key_len - 1
    if fixed_len >= length(key_bytes) ||
       view(key_bytes, 1:fixed_len) != view(node_key, 1:fixed_len) ||
       key_bytes[fixed_len + 1] <= node_key[fixed_len + 1]
        _regularize!(z)
        return nothing
    end
    byte = key_bytes[fixed_len + 1]
    focus_iter_token = length(key_bytes) == node_key_len ? new_tok :
        ascend_iter_token(_zfnode(z), new_tok, length(key_bytes) - node_key_len)
    z.prefix_buf[end] = byte
    z.focus_iter_token = focus_iter_token
    if length(key_bytes) == node_key_len && child_rc !== nothing
        push!(z.ancestors, (z.focus_node, new_tok, length(z.prefix_buf)))
        z.focus_node = _rc_inner(child_rc)
        z.focus_iter_token = NODE_ITER_INVALID
    end
    byte
end

# upstream `ReadZipperCore::to_sibling` (zipper.rs:3072-3129), used for `to_prev_sibling_byte`
function _zc_to_sibling!(z::ReadZipperCore{V, A}, next::Bool)::Union{Nothing, UInt8} where {V, A}
    at_root(z) && return nothing
    _prepare_buffers!(z)
    nk = _znode_key(z)
    if !isempty(nk)
        prefix, child = get_sibling_of_child(_zfnode(z), nk, next)
        prefix === nothing && return nothing
        z.prefix_buf[end] = prefix
        z.focus_iter_token = NODE_ITER_INVALID
        if child !== nothing
            push!(z.ancestors, (z.focus_node, z.focus_iter_token, length(z.prefix_buf)))
            z.focus_node = child
        end
        return prefix
    end
    isempty(z.ancestors) && return nothing
    parent, _, parent_offset = z.ancestors[end]
    prefix, child = get_sibling_of_child(_fnode(parent, V, A), _parent_key(z), next)
    prefix === nothing && return nothing
    z.prefix_buf[end] = prefix
    should_pop = child === nothing
    if !should_pop
        z.focus_node = child
        z.focus_iter_token = NODE_ITER_INVALID
    end
    z.ancestors[end] = (parent, NODE_ITER_INVALID, parent_offset)
    if should_pop
        focus_node, iter_tok, _ = pop!(z.ancestors)
        z.focus_node = focus_node
        z.focus_iter_token = iter_tok
    end
    prefix
end

to_next_sibling_byte!(z::ReadZipperCore) = _zc_to_next_sibling_byte!(z)   # zipper.rs:2359
to_prev_sibling_byte!(z::ReadZipperCore) = _zc_to_sibling!(z, false)       # zipper.rs:2426

# `to_next_step`, `descend_last_byte`, `descend_to_val`, `descend_to_existing`, `descend_last_path` and
# `move_to_path` are upstream's trait defaults for the read zipper (ZipperTraits.jl).

# upstream `ReadZipperCore::descend_until_max_bytes_observed` (zipper.rs:2244-2291)
function descend_until_max_bytes_observed!(z::ReadZipperCore{V, A}, max_bytes::Int, obs) where {V, A}
    max_bytes == 0 && return false
    remaining = max_bytes
    moved = false
    while child_count(z) == 1 && remaining > 0
        _prepare_buffers!(z)
        prefix, child = first_child_from_key(_zfnode(z), _znode_key(z))
        prefix === nothing && error("descend_until_max_bytes: unreachable (child_count == 1 without a child)")
        if isempty(prefix)
            child === nothing && break
            moved = true
            push!(z.ancestors, (z.focus_node, z.focus_iter_token, length(z.prefix_buf)))
            z.focus_node = child
            z.focus_iter_token = NODE_ITER_INVALID
            continue
        end
        take = min(remaining, length(prefix))
        moved = true
        append!(z.prefix_buf, view(prefix, 1:take))
        descend_to!(obs, view(prefix, 1:take))
        remaining -= take
        z.focus_iter_token = NODE_ITER_INVALID
        take < length(prefix) && break
        if child !== nothing
            push!(z.ancestors, (z.focus_node, z.focus_iter_token, length(z.prefix_buf)))
            z.focus_node = child
            z.focus_iter_token = NODE_ITER_INVALID
        end
        _is_val_internal(z) && break
    end
    moved
end

# =====================================================================
# ZipperIteration — k-path traversal
# =====================================================================

# 🔴 PORT OF `ReadZipperCore::k_path_internal` (zipper.rs:3131-3223 @ f477a91), not of the trait default: the
# default hangs on a childless focus (upstream lean/FINDINGS.md #6; our P0 #1). Final 0.4.0 form: 46761a0 (never
# store FINISHED; exhaustion handled inline), ac241e2 (an INVALID token is re-synced with `continue_from_focus`),
# bdbdfdc (a `false` exit re-ascends the token), fad58f4 (an overshoot keeps an ascended token), 8082317. The
# `continue_from_focus` flag is `next_items(…, after_focus)`: resume strictly AFTER the focus, never below it,
# which replaced our `resume_from` filter and re-sync skip loop (Lean-harness #526).
const MIN_EXCESS_TO_AVOID_COPY = 12   # zipper.rs:3135 (below it, copying the whole key and truncating is cheaper)

function _zipper_k_path_internal!(z::ReadZipperCore, k::Int, base_idx::Int, continue_from_focus::Bool, obs)
    obs_floor = z.origin_path_len
    target_idx = base_idx + k
    while true
        if z.focus_iter_token == NODE_ITER_INVALID
            z.focus_iter_token = iter_token_for_path(_zfnode(z), _znode_key(z))
            continue_from_focus = true
        end
        key_start = _znode_key_start(z)
        new_tok, key_bytes, child_rc, _ = next_items(_zfnode(z), z.focus_iter_token, continue_from_focus)
        continue_from_focus = false
        if new_tok != NODE_ITER_FINISHED
            if key_start < base_idx
                base_key_len = base_idx - key_start   # bytes we must not modify
                if base_key_len > length(key_bytes) ||
                   view(key_bytes, 1:base_key_len) != view(z.prefix_buf, (key_start + 1):base_idx)
                    excess = length(z.prefix_buf) - base_idx
                    resize!(z.prefix_buf, base_idx)
                    if excess > 0
                        ascend!(obs, excess)
                        _reascend_iter_token!(z, excess)
                    end
                    return false
                end
            end
            z.focus_iter_token = new_tok
            obs_skip = max(obs_floor - key_start, 0)
            ascend!(obs, max(length(z.prefix_buf) - max(key_start, obs_floor), 0))
            resize!(z.prefix_buf, key_start)
            remaining = target_idx - key_start
            if length(key_bytes) > remaining
                excess = length(key_bytes) - remaining
                if excess >= MIN_EXCESS_TO_AVOID_COPY
                    append!(z.prefix_buf, view(key_bytes, 1:remaining))
                    obs_skip <= remaining && descend_to!(obs, view(key_bytes, (obs_skip + 1):remaining))
                else
                    append!(z.prefix_buf, key_bytes)
                    obs_skip <= length(key_bytes) &&
                        descend_to!(obs, view(key_bytes, (obs_skip + 1):length(key_bytes)))
                    ascend!(obs, excess)
                    resize!(z.prefix_buf, target_idx)
                end
                z.focus_iter_token = ascend_iter_token(_zfnode(z), new_tok, excess)
                return true
            end
            append!(z.prefix_buf, key_bytes)
            obs_skip <= length(key_bytes) && descend_to!(obs, view(key_bytes, (obs_skip + 1):length(key_bytes)))
            if child_rc !== nothing
                push!(z.ancestors, (z.focus_node, new_tok, length(z.prefix_buf)))
                z.focus_node = _rc_inner(child_rc)
                z.focus_iter_token = new_iter_token(_zfnode(z))
            end
            length(z.prefix_buf) == target_idx && return true
        else
            if key_start <= base_idx
                excess = length(z.prefix_buf) - base_idx
                ascend!(obs, excess)
                resize!(z.prefix_buf, base_idx)
                excess > 0 && _reascend_iter_token!(z, excess)
                return false
            end
            if !isempty(z.ancestors)
                focus_node, iter_tok, prefix_offset = pop!(z.ancestors)
                z.focus_node = focus_node
                z.focus_iter_token = iter_tok
                ascend!(obs, max(length(z.prefix_buf) - max(prefix_offset, obs_floor), 0))
                resize!(z.prefix_buf, prefix_offset)
            else
                z.focus_iter_token = NODE_ITER_INVALID
                ascend!(obs, max(length(z.prefix_buf) - z.origin_path_len, 0))
                resize!(z.prefix_buf, z.origin_path_len)
                return false
            end
        end
    end
end

# zipper.rs:2665-2673
function descend_first_k_path_observed!(z::ReadZipperCore, k::Int, obs)
    _prepare_buffers!(z)
    z.focus_iter_token = iter_token_for_path(_zfnode(z), _znode_key(z))
    _zipper_k_path_internal!(z, k, length(z.prefix_buf), false, obs)
end

# zipper.rs:2674-2686 (`k` deeper than the focus: `k_path_depth_exceeded`, zipper.rs:1101-1105)
function to_next_k_path_observed!(z::ReadZipperCore, k::Int, obs)
    d = depth(z)
    d < k && return _k_path_depth_exceeded!(z, d, obs)
    base_idx = length(z.prefix_buf) - k
    _zc_deregularize!(z)
    _zipper_k_path_internal!(z, k, base_idx, true, obs)
end

# =====================================================================
# ZipperForking — fork a read sub-zipper at the current focus
# =====================================================================

"""
    fork_read_zipper(z) → ReadZipperCore

New read zipper rooted at the current focus position.
Mirrors `fork_read_zipper` / `new_with_node_and_path_internal_in`:
creates a new zipper using root_node + current absolute path so that
the fork's `path()` is empty but its subtrie equals the current subtrie.
"""
function fork_read_zipper(z::ReadZipperCore{V, A}) where {V, A}
    _prepare_buffers!(z)
    abs_path = copy(z.prefix_buf)
    path_len = length(abs_path)
    fork_val = _is_val_internal(z) ? _get_val(z) : nothing
    # 🔴 RESUME FROM `z.root_key_start`, DO NOT RESTART AT 0. `z.root_node` is NOT the trie root for
    # any zipper built by `ReadZipperCore_at_path` — that constructor stores the node it DESCENDED
    # TO as `root_node`, while `prefix_buf` keeps the FULL path. Passing 0 therefore re-walked the
    # whole path a second time from an already-descended node, which finds nothing.
    # MEASURED before the fix — fork vs a directly-constructed zipper at the same path:
    #     at ""    direct ["p","q"]    forked ["p","q"]   (root: root_key_start == 0, so 0 was right)
    #     at "a"   direct ["b","c"]    forked []          <- EMPTY
    #     at "aa"  direct ["aa","b"]   forked []          <- EMPTY
    #     at "xa"  direct ["xa","xb"]  forked []          <- EMPTY
    # i.e. fork was silently empty for EVERY non-root focus, and correct only at the root — which is
    # why a smoke test that forks a fresh whole-map zipper passes over it.
    # `root_key_start` is exactly "how much of prefix_buf root_node has already consumed", so the
    # remaining walk is `prefix_buf[root_key_start+1:end]` — the parameter this call was zeroing.
    # Upstream reaches the same focus differently, borrowing `focus_parent()` with
    # `new_root_key_start = path.len() - node_key().len()` (zipper.rs:1478) — O(1) where ours re-walks
    # the tail; the RESULT must match, and that is what the test asserts.
    ReadZipperCore_at_path(z.root_node, abs_path, path_len, z.root_key_start, fork_val, z.alloc)
end

# =====================================================================
# PathMap is now in src/pathmap/PathMap.jl (mirrors upstream trie_map.rs)

# =====================================================================
# Exports
# =====================================================================

export ReadZipperCore, ReadZipperCore_at_path, ReadZipperUntracked
export node_along_path, val_count_below_root
export _zc_regularize!, _zc_deregularize!, _zc_push_node!, _zc_node_key
