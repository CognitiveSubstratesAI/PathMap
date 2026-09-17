"""
TrieNode — port of `pathmap/src/trie_node.rs`.

This file contains:
  - `MAX_NODE_KEY_BYTES`, `NODE_ITER_INVALID`, `NODE_ITER_FINISHED` constants
  - `AbstractTrieNode{V,A}` — abstract supertype (= Rust's `dyn TrieNode<V,A>`)
  - Abstract interface declarations (= Rust's `trait TrieNode`)
  - `TrieNodeODRc{V,A}` — GC-managed reference-counted node pointer
    (= Rust's `TrieNodeODRc<V,A>` on the non-slim, non-nightly path:
    `Arc<dyn TrieNode<V,A>>`. Julia's GC replaces `Arc`; COW is explicit.)
  - `PayloadRef{V,A}` — None / Val / Child (= Rust's `PayloadRef<'a,V,A>`)
  - `ValOrChild{V,A}` — Val / Child owned (= Rust's `ValOrChild<V,A>`)
  - `AbstractNodeRef{V,A}` — None/BorrowedDyn/BorrowedRc/BorrowedTiny/OwnedRc
  - Node tag constants
  - Lattice / DistributiveLattice / Quantale impls on `TrieNodeODRc`

**Deferred** (require concrete node types — see `nodes/` sub-files):
  - `TaggedNodeRef` variant definitions (DenseByteNode, LineListNode, …)
  - `TaggedNodeRefMut` / `TaggedNodePtr` definitions
  - `pmeet_generic` / `pmeet_generic_internal` (`node_count_branches_recursive` is ported below `as_tagged`)

1:1 port of upstream non-slim, non-nightly path. `slim_ptrs` is an upstream
`#[cfg(feature)]`-gated optimisation — not Tier-1 substrate parity.
"""

# =====================================================================
# Constants
# =====================================================================
#
# Rust: MAX_NODE_KEY_BYTES = 48 — compile-time assertions enforce it is
#   (a) >= KEY_BYTES_CNT in line_list_node.rs  (b) < 253

"""
    MAX_NODE_KEY_BYTES :: Int

Maximum key length any single node may require to address any value or
sub-path it contains. Matches upstream `MAX_NODE_KEY_BYTES = 48`.
"""
const MAX_NODE_KEY_BYTES = 48

# ── Iteration tokens (upstream trie_node.rs:408-479, 0.4.0 contract) ─────────────────────────────────────
"Node-specific encoding representing a position within the node (upstream `IterToken = u64`)."
const IterToken = UInt64

"""
Reserved high bit marking a token with a special, non-node-specific meaning. When set, the complete token
value is one of `TOKEN_LAST`, `TOKEN_AFTER_LAST`, `NODE_ITER_INVALID`, `NODE_ITER_FINISHED`; node-specific
encodings leave it clear.
"""
const NODE_TOKEN_SPECIAL_BIT = one(IterToken) << 63

"""
Reserved flag returned by `iter_token_for_path` for a nonexistent path: clear = the token names a path that
exists in the node; set = a path *below or after* the one named by the token with the bit cleared. Set on
`TOKEN_LAST` it gives `TOKEN_AFTER_LAST`. No singular meaning in the control sentinels.
"""
const NODE_TOKEN_NONEXISTENT_BIT = one(IterToken) << 62

"Canonical token for the last valid path in a node that supports it; `next_items` on it reports exhaustion."
const TOKEN_LAST = typemax(IterToken) & ~NODE_TOKEN_NONEXISTENT_BIT

"The nonexistent-path companion to `TOKEN_LAST`: a focus after the node's last valid path."
const TOKEN_AFTER_LAST = TOKEN_LAST | NODE_TOKEN_NONEXISTENT_BIT

"Special sentinel token: an unknown or invalid location."
const NODE_ITER_INVALID = NODE_TOKEN_SPECIAL_BIT

"Special sentinel token: iteration of a node has concluded. Returned, never passed in."
const NODE_ITER_FINISHED = typemax(IterToken) - 1

# upstream `debug_assert_iter_token_layout` (trie_node.rs:449-469), checked once at load
@assert TOKEN_LAST & NODE_TOKEN_SPECIAL_BIT == NODE_TOKEN_SPECIAL_BIT
@assert TOKEN_LAST & NODE_TOKEN_NONEXISTENT_BIT == 0
@assert TOKEN_LAST & ~(NODE_TOKEN_SPECIAL_BIT | NODE_TOKEN_NONEXISTENT_BIT) == NODE_TOKEN_NONEXISTENT_BIT - 1
@assert TOKEN_AFTER_LAST == typemax(IterToken)
@assert NODE_ITER_INVALID < TOKEN_LAST < NODE_ITER_FINISHED < TOKEN_AFTER_LAST

"""
    node_iter_token_is_nonexistent(token) -> Bool

Whether `token` names a nonexistent path within the node (trie_node.rs:475). Not for the sentinels.
"""
@inline node_iter_token_is_nonexistent(token::IterToken) = (token & NODE_TOKEN_NONEXISTENT_BIT) != 0

# =====================================================================
# Node-type tag constants
# =====================================================================
#
# Upstream uses these as stable tag indices for concrete node types.
# They are used by TrieNodeODRc and TaggedNodeRef dispatch.

const EMPTY_NODE_TAG = 0
const DENSE_BYTE_NODE_TAG = 1
const LINE_LIST_NODE_TAG = 2
const CELL_BYTE_NODE_TAG = 3
const TINY_REF_NODE_TAG = 4

# =====================================================================
# AbstractTrieNode — trait equivalent
# =====================================================================
#
# Rust: `pub(crate) trait TrieNode<V, A> : TrieNodeDowncast<V,A> + DynClone + ...`
#
# In Julia there is no lifetime parameter, and dynamic dispatch replaces
# the trait object pattern.  Any concrete node (DenseByteNode, LineListNode,
# CellByteNode, EmptyNode, TinyRefNode) extends this abstract type.
#
# The abstract function declarations below mirror the trait method surface.
# Each concrete node file implements them via method dispatch.

"""
    AbstractTrieNode{V,A<:Allocator}

Abstract supertype for all trie node implementations.
Corresponds to `dyn TrieNode<V, A>` in upstream.
"""
abstract type AbstractTrieNode{V, A <: Allocator} end

# ------------------------------------------------------------------
# Abstract interface — mirrors TrieNode<V,A> trait methods
# ------------------------------------------------------------------
# Every concrete node must implement these. Signatures follow upstream
# exactly except lifetimes are dropped and `&mut self` → normal methods.

"""
    node_key_overlap(node, key::Vector{UInt8}) -> Int

Number of bytes in `key` that overlap a key contained within the node.
"""
function node_key_overlap end

"""
    node_contains_partial_key(node, key::Vector{UInt8}) -> Bool

Returns true if the node contains a key that begins with `key`.
Default implementation: `node_key_overlap(node, key) == length(key)`.
"""
node_contains_partial_key(node::AbstractTrieNode, key) =
    node_key_overlap(node, key) == length(key)

"""
    node_get_child(node, key::Vector{UInt8}) -> Union{Nothing, Tuple{Int, TrieNodeODRc}}

Returns `(matched_bytes, child_node)` or `nothing` if not found.
"""
function node_get_child end

"""
    node_get_child_mut(node, key::Vector{UInt8}) -> Union{Nothing, Tuple{Int, TrieNodeODRc}}

Mutable version of `node_get_child`.
"""
function node_get_child_mut end

"""
    node_replace_child!(node, key::Vector{UInt8}, new_node::TrieNodeODRc)

Replace the child at `key` with `new_node`. Key must already exist.
"""
function node_replace_child! end

"""
    node_get_payloads(node, keys, results) -> Bool

Retrieve multiple values or child links. Returns `true` if keys
exhaust all elements in the node.
"""
function node_get_payloads end

"""
    node_contains_val(node, key::Vector{UInt8}) -> Bool
"""
function node_contains_val end

"""
    node_get_val(node, key::Vector{UInt8}) -> Union{Nothing, V}
"""
function node_get_val end

"""
    node_get_val_mut(node, key::Vector{UInt8}) -> Union{Nothing, Ref}

Mutable reference to the value at `key`.
"""
function node_get_val_mut end

"""
    node_set_val!(node, key::Vector{UInt8}, val) -> Union{Ok, Err(TrieNodeODRc)}

Sets value at `key`. Returns `(old_val::Union{Nothing,V}, sub_node_created::Bool)`
on success; returns `Err(new_node)` if node was upgraded.
"""
function node_set_val! end

"""
    node_remove_val!(node, key::Vector{UInt8}, prune::Bool) -> Union{Nothing, V}
"""
function node_remove_val! end

"""
    node_create_dangling!(node, key::Vector{UInt8}) -> Union{Ok, Err(TrieNodeODRc)}
"""
function node_create_dangling! end

"""
    node_remove_dangling!(node, key::Vector{UInt8}) -> Int
"""
function node_remove_dangling! end

"""
    node_set_branch!(node, key::Vector{UInt8}, new_node::TrieNodeODRc) -> Union{Ok, Err(TrieNodeODRc)}
"""
function node_set_branch! end

"""
    node_remove_all_branches!(node, key::Vector{UInt8}, prune::Bool) -> Bool
"""
function node_remove_all_branches! end

"""
    node_remove_unmasked_branches!(node, key::Vector{UInt8}, mask::ByteMask, prune::Bool)
"""
function node_remove_unmasked_branches! end

"""
    node_is_empty(node) -> Bool
"""
function node_is_empty end

"""
    new_iter_token(node) -> IterToken

A new token, to iterate the children and values of this node. The token is a node-local cursor that must
represent any position within the node; every representable existing path has ONE canonical token
(trie_node.rs:196-210).
"""
function new_iter_token end

"""
    iter_token_for_path(node, key) -> IterToken

The token representing `key` within this node. `NODE_TOKEN_NONEXISTENT_BIT` clear = an exact existing
in-node path; set = a nonexistent path below or after the token with the bit cleared (likewise
`TOKEN_LAST` / `TOKEN_AFTER_LAST`). Never returns `NODE_ITER_INVALID` or `NODE_ITER_FINISHED`
(trie_node.rs:212-222).
"""
function iter_token_for_path end

"""
    ascend_iter_token(node, token, byte_count) -> IterToken

The token for the focus reached by ascending `byte_count` bytes within this node. `token` must be valid
with the nonexistent bit clear; `byte_count` a non-zero in-node ascent not passing the node root
(trie_node.rs:224-229).
"""
function ascend_iter_token end

"""
    next_items(node, token, after_focus::Bool) -> (IterToken, bytes, Union{Nothing,TrieNodeODRc}, Union{Nothing,V})

Step to the next existing path within the node, depth-first (trie_node.rs:231-256). `token` must not be a
control sentinel; a nonexistent-flagged token is a lower-bound cursor, treated as the unflagged token.
`TOKEN_LAST` / `TOKEN_AFTER_LAST` always give `(NODE_ITER_FINISHED, [], nothing, nothing)`. With
`after_focus`, steps to the first item strictly after (and not below) the focus. On success the returned
token is the canonical token of the returned path and the continuation token; when nothing is left the
result is `(NODE_ITER_FINISHED, [], nothing, nothing)` with no item.
"""
function next_items end

"""
    node_val_count(node, cache::Dict) -> Int
"""
# ⚠️ Every method is annotated `::Int`. `node_val_count` and `val_count_below_node` are MUTUALLY
# RECURSIVE across all six node types, and inference gives up on that cycle and returns `Any` — which
# then propagated out through `val_count(::ReadZipperCore)` to every caller (perf audit 2026-09-17,
# docs/PERF_AUDIT_2026-09-17.md Finding 2). The annotation breaks the cycle; it is not a conversion.
function node_val_count end

"""
    node_goat_val_count(node) -> Int
"""
function node_goat_val_count end

"""
    node_child_iter_start(node) -> (UInt64, Union{Nothing, TrieNodeODRc})
"""
function node_child_iter_start end

"""
    node_child_iter_next(node, token::UInt64) -> (UInt64, Union{Nothing, TrieNodeODRc})
"""
function node_child_iter_next end

"""
    node_first_val_depth_along_key(node, key::Vector{UInt8}) -> Union{Nothing, Int}
"""
function node_first_val_depth_along_key end

"""
    nth_child_from_key(node, key::Vector{UInt8}, n::Int) -> (Union{Nothing, UInt8}, Union{Nothing, AbstractTrieNode})
"""
function nth_child_from_key end

"""
    first_child_from_key(node, key::Vector{UInt8}) -> (Union{Nothing, Vector{UInt8}}, Union{Nothing, AbstractTrieNode})
"""
function first_child_from_key end

"""
    count_branches(node, key::Vector{UInt8}) -> Int
"""
function count_branches end

"""
    node_branches_mask(node, key::Vector{UInt8}) -> ByteMask
"""
function node_branches_mask end

"""
    prior_branch_key(node, key::Vector{UInt8}) -> Vector{UInt8}
"""
function prior_branch_key end

"""
    get_sibling_of_child(node, key::Vector{UInt8}, next::Bool) -> (Union{Nothing, UInt8}, Union{Nothing, AbstractTrieNode})
"""
function get_sibling_of_child end

"""
    get_node_at_key(node, key::Vector{UInt8}) -> AbstractNodeRef
"""
function get_node_at_key end

"""
    take_node_at_key!(node, key::Vector{UInt8}, prune::Bool) -> Union{Nothing, TrieNodeODRc}
"""
function take_node_at_key! end

"""
    pjoin_dyn(node, other::AbstractTrieNode) -> AlgebraicResult{TrieNodeODRc}
"""
function pjoin_dyn end

"""
    join_into_dyn!(node, other::TrieNodeODRc) -> Tuple{AlgebraicStatus, Union{Ok, Err(TrieNodeODRc)}}
"""
function join_into_dyn! end

"""
    drop_head_dyn!(node, byte_cnt::Int) -> Union{Nothing, TrieNodeODRc}
"""
function drop_head_dyn! end

"""
    pmeet_dyn(node, other::AbstractTrieNode) -> AlgebraicResult{TrieNodeODRc}
"""
function pmeet_dyn end

"""
    psubtract_dyn(node, other::AbstractTrieNode) -> AlgebraicResult{TrieNodeODRc}
"""
function psubtract_dyn end

"""
    prestrict_dyn(node, other::AbstractTrieNode) -> AlgebraicResult{TrieNodeODRc}
"""
function prestrict_dyn end

"""
    clone_self(node) -> TrieNodeODRc
"""
function clone_self end

# Downcast helpers (from TrieNodeDowncast trait)
"""
    node_tag(node) -> Int

Returns the stable tag constant for this node type.
"""
function node_tag end

"""
    convert_to_cell_node!(node) -> TrieNodeODRc

Migrates node contents into a new CellByteNode and returns it,
leaving `node` empty.
"""
function convert_to_cell_node! end

# =====================================================================
# TrieNodeODRc — GC-managed reference-counted node pointer
# =====================================================================
#
# Rust (non-slim, non-nightly):
#   pub struct TrieNodeODRc<V, A: Allocator>(Arc<dyn TrieNode<V, A>>);
#
# Julia: The GC plays the role of Arc. We wrap the AbstractTrieNode in a
# mutable struct so it can be re-pointed (for COW replacement). The `alloc`
# field is carried for API fidelity — on the default GlobalAlloc path it
# is a no-op phantom, just as on Rust's stable (non-nightly) path.
#
# COW semantics (make_mut / make_unique): Rust's Arc::make_mut clones the
# inner object when more than one Arc points to it.  Julia does not expose
# GC refcounts.  A safe, faithful equivalent: track sharing explicitly with
# a `Base.RefValue{Int}` refcount that the MORK layer manages. For Phase 1
# (abstract interface) we carry the field but defer actual COW enforcement
# to Phase 1c when WriteZipper methods exercise it.

"""
    TrieNodeODRc{V,A<:Allocator}

GC-managed reference-counted pointer to an `AbstractTrieNode{V,A}`.

Mirrors upstream `TrieNodeODRc<V,A>` (non-slim, non-nightly path).
"""
mutable struct TrieNodeODRc{V, A <: Allocator}
    # The polymorphic node.  `nothing` represents the EmptyNode sentinel
    # (corresponds to upstream's EMPTY_NODE_TAG sentinel pointer 0xBAADF00D).
    node::Union{Nothing, AbstractTrieNode{V, A}}
    # Allocator — phantom on GlobalAlloc path, matches Rust stable API shape.
    alloc::A
end
# NOTE (close-out 2-A): the refcount is now NODE-KEYED — each mutable node carries
# an `@atomic refcnt::UInt32` (mirrors Rust `slim_ptrs refcnt: AtomicU32` as the
# node's first field), so all wrappers of the same node share ONE atomic counter.
# This is thread-safe (vs the previous racy per-wrapper `Ref{Int} += 1`) and makes
# divergence between wrappers structurally impossible. Immutable nodes (TinyRefNode,
# EmptyNode) carry no field: they upgrade-on-write, so make_unique! is a no-op and
# they report a sentinel count of 1.

# ── node-keyed refcount protocol ─────────────────────────────────────
# `hasfield(typeof(n), :refcnt)` is a compile-time constant per type, so the branch
# folds away. getfield/modifyfield! with a memory order is the generic API for an
# `@atomic` struct field.
@inline _has_refcnt(@nospecialize n) = hasfield(typeof(n), :refcnt)
@inline _node_refcount(@nospecialize n) =
    _has_refcnt(n) ? Int(getfield(n, :refcnt, :acquire)) : 1
@inline function _node_inc_refcnt!(@nospecialize n)
    _has_refcnt(n) && modifyfield!(n, :refcnt, +, UInt32(1), :acquire_release)
    nothing
end
@inline function _node_dec_refcnt!(@nospecialize n)
    _has_refcnt(n) && modifyfield!(n, :refcnt, -, UInt32(1), :acquire_release)
    nothing
end

# Constructors

"""
    TrieNodeODRc(node::AbstractTrieNode{V,A}, alloc::A) -> TrieNodeODRc{V,A}

Create a new node pointer. The node carries its own refcount (node-keyed).
Mirrors `TrieNodeODRc::new_in`.
"""
TrieNodeODRc(node::AbstractTrieNode{V, A}, alloc::A) where {V, A <: Allocator} =
    TrieNodeODRc{V, A}(node, alloc)

"""
    TrieNodeODRc{V,A}() -> TrieNodeODRc{V,A}

Create an empty-sentinel node pointer. Mirrors `TrieNodeODRc::new_empty`.
"""
TrieNodeODRc{V, A}() where {V, A <: Allocator} = TrieNodeODRc{V, A}(nothing, GlobalAlloc())

# Shallow clone — bumps the NODE's atomic refcount (mirrors Arc::clone)
function Base.copy(rc::TrieNodeODRc{V, A}) where {V, A <: Allocator}
    rc.node !== nothing && _node_inc_refcnt!(rc.node)
    TrieNodeODRc{V, A}(rc.node, rc.alloc)
end

"""
    refcount(rc::TrieNodeODRc) -> Int

Returns current strong reference count (read through the node). Mirrors
`Arc::strong_count`. The empty sentinel and immutable nodes report 1.
"""
refcount(rc::TrieNodeODRc) = rc.node === nothing ? 1 : _node_refcount(as_tagged(rc))

"""
    ptr_eq(a::TrieNodeODRc, b::TrieNodeODRc) -> Bool

Returns true iff both pointers reference the same underlying node object.
Mirrors `Arc::ptr_eq`.
"""
ptr_eq(a::TrieNodeODRc, b::TrieNodeODRc) = a.node === b.node

"""
    is_empty_node(rc::TrieNodeODRc) -> Bool

Returns true iff this points at the EmptyNode sentinel.
Mirrors `TrieNodeODRc::is_empty`.
"""
is_empty_node(rc::TrieNodeODRc) = rc.node === nothing

"""
    as_tagged(rc::TrieNodeODRc) -> AbstractTrieNode

Returns the inner node (= `TaggedNodeRef`). Mirrors `TrieNodeODRc::as_tagged`, which yields
`TaggedNodeRef::EmptyNode` for the empty sentinel (trie_node.rs `TaggedNodePtr`:
`EMPTY_NODE_TAG => Self::EmptyNode`) — so here the `EmptyNode` singleton, never `nothing`.
Returning `nothing` made every node query and `*_dyn` operation on an empty child a MethodError
(`count_branches(::Nothing, …)`, `pmeet_dyn(::Nothing, …)`, …), patched one `::Nothing` method at a
time (EmptyNode.jl); the Lean-model harness found nine more such sites
(docs/UPSTREAM_DELTA_2026-09-16.md #18). `rc.node` itself still holds `nothing` for the sentinel.
"""
# The narrowing definition lives in nodes/NodeVariant.jl — it needs the closed union of every node type,
# which can only be written after the last node file. See that file's header (perf audit 2026-09-17).
function as_tagged end

"""
    node_count_branches_recursive(node, key) -> Int

Child count at `key` below `node`, stepping into the child when `key` covers a whole child edge.
1:1 with upstream `node_count_branches_recursive` (trie_node.rs:682-697), which
`WriteZipperCore::child_count` uses (write_zipper.rs:974-981): a write zipper's node key can span a
full child edge, where one-node `count_branches` answers 0 (docs/UPSTREAM_DELTA_2026-09-16.md #16).
"""
function node_count_branches_recursive(node, key::AbstractVector{UInt8})
    isempty(key) && return count_branches(node, UInt8[])
    result = node_get_child(node, key)
    result === nothing && return count_branches(node, key)
    consumed, child_rc = result
    length(key) >= consumed ? count_branches(as_tagged(child_rc), view(key, (consumed + 1):length(key))) : 0
end

"""
    shared_node_id(rc::TrieNodeODRc) -> UInt64

Returns a stable identity for the pointed-to node (using `objectid`).
Returns `UInt64(0)` for the empty sentinel.
Mirrors `Arc::as_ptr as u64`.
"""
shared_node_id(rc::TrieNodeODRc) =
    rc.node === nothing ? UInt64(0) : UInt64(objectid(rc.node))

"""
    make_unique!(rc::TrieNodeODRc)

Ensures `rc` holds the sole reference to its node. If refcount > 1,
clones the inner node (copy-on-write). Mirrors `TrieNodeODRc::make_unique`.
"""
function make_unique!(rc::TrieNodeODRc{V, A}) where {V, A <: Allocator}
    @assert !is_empty_node(rc) "make_unique! on empty sentinel"
    # NARROWED, not `rc.node`: the field is `Union{Nothing, AbstractTrieNode}`, so the raw read makes
    # `_has_refcnt` / `_node_refcount` / `clone_self` dynamic (perf audit 2026-09-17 Finding 4).
    n = as_tagged(rc)
    # Immutable nodes (TinyRefNode/EmptyNode) carry no refcount: they upgrade on
    # write (the caller replaces the wrapper), so there is nothing to uniquify.
    _has_refcnt(n) || return rc
    if _node_refcount(n) > 1
        _node_dec_refcnt!(n)               # one fewer referrer to the shared node
        # `n` is abstract (rc.node::Union{Nothing,AbstractTrieNode}); assert the concrete return
        # upstream's `fn clone_self(&self) -> TrieNodeODRc<V,A>` guarantees (semantic no-op).
        new_inner = clone_self(n)::TrieNodeODRc{V, A}  # shallow clone; the fresh node has refcnt = 1
        rc.node = new_inner.node
    end
    return rc
end

# Delegating overload for join_into_dyn!: unwraps the first TrieNodeODRc.
# DenseByteNode calls join_into_dyn!(cf.rec, node) where cf.rec::TrieNodeODRc.
# Mirrors upstream `TrieNodeODRc::join_into` (trie_node.rs:3094-3103): `self.make_mut()`
# BEFORE delegating to the mutating trait method — make_mut is the COW-fork (clone iff
# shared) that makes the subsequent in-place mutation safe. The prior version skipped
# this and mutated `rc.node` directly regardless of sharing, corrupting any OTHER live
# reference to the same node (e.g. a shallow-cloned parent's shared child during pjoin's
# deepcopy_bn+merge_from_list_node! path — found 2026-07-24 investigating a DTL
# non-termination bug: a read-only isolated snapshot built via `pjoin` was silently
# leaking writes back into the live space through exactly this aliasing gap).
function join_into_dyn!(rc::TrieNodeODRc{V, A}, other::TrieNodeODRc{V, A}) where {V, A}
    rc.node === nothing && return (ALG_STATUS_IDENTITY, nothing)
    make_unique!(rc)
    join_into_dyn!(rc.node, other)
end

# =====================================================================
# PayloadRef — borrowed reference to a value or child within a node
# =====================================================================
#
# Rust: `pub(crate) enum PayloadRef<'a, V, A> { None, Val(&'a V), Child(&'a ODRc) }`
# Julia: lifetime dropped; immutable struct holding a reference.

"""
    PayloadRef{V,A<:Allocator}

A reference to a payload (value or child node) within a trie node.
Corresponds to `PayloadRef<'a, V, A>` in upstream.
"""
struct PayloadRef{V, A <: Allocator}
    _kind::UInt8   # 0=None, 1=Val, 2=Child
    _val::Union{Nothing, Ref{V}}
    _child::Union{Nothing, TrieNodeODRc{V, A}}
end

# Constructors matching upstream's variant pattern
PayloadRef{V, A}() where {V, A <: Allocator} = PayloadRef{V, A}(0x0, nothing, nothing)

function PayloadRef(val::V) where {V}
    PayloadRef{V, GlobalAlloc}(0x1, Ref(val), nothing)
end

function PayloadRef(child::TrieNodeODRc{V, A}) where {V, A <: Allocator}
    PayloadRef{V, A}(0x2, nothing, child)
end

is_none(p::PayloadRef) = p._kind == 0x0
is_val(p::PayloadRef) = p._kind == 0x1
is_child(p::PayloadRef) = p._kind == 0x2

function get_val(p::PayloadRef{V}) where {V}
    @assert is_val(p)
    p._val[]
end

function get_child(p::PayloadRef{V, A}) where {V, A}
    @assert is_child(p)
    p._child
end

# =====================================================================
# ValOrChild — owned value or child
# =====================================================================
#
# Rust: `pub(crate) enum ValOrChild<V,A> { Val(V), Child(TrieNodeODRc<V,A>) }`
# Julia: tagged union.  `ValOrChildUnion` (unsafe Rust union) → not needed.

"""
    ValOrChild{V,A<:Allocator}

Owned payload: either a value `V` or a child node pointer.
Corresponds to `ValOrChild<V, A>` in upstream.
"""
struct ValOrChild{V, A <: Allocator}
    _kind::UInt8   # 0=Val, 1=Child
    _val::Union{Nothing, V}
    _child::Union{Nothing, TrieNodeODRc{V, A}}
end

ValOrChild(val::V) where {V} = ValOrChild{V, GlobalAlloc}(0x0, val, nothing)
ValOrChild(child::TrieNodeODRc{V, A}) where {V, A <: Allocator} =
    ValOrChild{V, A}(0x1, nothing, child)

is_val(voc::ValOrChild) = voc._kind == 0x0
is_child(voc::ValOrChild) = voc._kind == 0x1

function into_val(voc::ValOrChild{V}) where {V}
    @assert is_val(voc)
    voc._val
end

function into_child(voc::ValOrChild{V, A}) where {V, A}
    @assert is_child(voc)
    voc._child
end

# =====================================================================
# FatAlgebraicResult helpers — used by pmeet_generic
# =====================================================================
#
# FatAlgebraicResult{V} and fat_none/fat_element/to_algebraic_result are
# defined in Ring.jl.  Only the pmeet-specific helpers are added here.

"""
    fat_from_binary_op_result(result, a::T, b::T) → FatAlgebraicResult{T}

Convert a binary-op `AlgebraicResult` into a `FatAlgebraicResult{T}`, materialising
`a` or `b` as the element when the result is Identity.
Ports `FatAlgebraicResult::from_binary_op_result`.
"""
function fat_from_binary_op_result(result, a::T, b::T) where {T}
    if result isa AlgResNone
        return FatAlgebraicResult{T}(UInt64(0), nothing)
    elseif result isa AlgResElement
        return FatAlgebraicResult{T}(UInt64(0), result.value)
    else  # AlgResIdentity
        mask = result.mask
        elem = (mask & SELF_IDENT != 0) ? a : b
        return FatAlgebraicResult{T}(mask, elem)
    end
end

"""
    fat_map(fat::FatAlgebraicResult{W}, f, ::Type{R}) → FatAlgebraicResult{R}

Apply `f` to `fat.element` (if non-nothing), producing a `FatAlgebraicResult{R}`.
`R` must be provided explicitly so the result type is always concrete and stable.
Ports `FatAlgebraicResult::map`.
"""
function fat_map(fat::FatAlgebraicResult{W}, f::F, ::Type{R}) where {W, F, R}
    elem2::Union{Nothing, R} = fat.element === nothing ? nothing : f(fat.element)::R
    FatAlgebraicResult{R}(fat.identity_mask, elem2)
end

# =====================================================================
# AbstractNodeRef — abstracted reference to the zipper's focus node
# =====================================================================
#
# Only the ABSTRACT type lives here, because files included before the last node type
# (`DenseByteNode.jl`'s `try_as_tagged(r::AbstractNodeRef)`) need it in a signature. The five
# concrete variants are in `nodes/NodeRef.jl`, included after `NodeVariant.jl`: upstream's
# `BorrowedDyn(TaggedNodeRef)` and `BorrowedTiny(TinyRefNode)` carry CONCRETE payloads, and the Julia
# equivalents (`TrieNodeVariant`, `TinyRefNode`) do not exist yet at this point in the load order.

abstract type AbstractNodeRef{V, A <: Allocator} end

# =====================================================================
# Lattice / DistributiveLattice / Quantale on TrieNodeODRc
# =====================================================================
#
# Ports the impl blocks at lines 3075-3225 of trie_node.rs.
# These dispatch to pjoin_dyn / pmeet_dyn / psubtract_dyn / prestrict_dyn
# on the inner node.

function pjoin(a::TrieNodeODRc{V, A}, b::TrieNodeODRc{V, A}) where {V, A}
    ptr_eq(a, b) && return AlgResIdentity(SELF_IDENT | COUNTER_IDENT)
    pjoin_dyn(as_tagged(a), as_tagged(b))
end

function pmeet(a::TrieNodeODRc{V, A}, b::TrieNodeODRc{V, A}) where {V, A}
    ptr_eq(a, b) && return AlgResIdentity(SELF_IDENT | COUNTER_IDENT)
    pmeet_dyn(as_tagged(a), as_tagged(b))
end

function psubtract(a::TrieNodeODRc{V, A}, b::TrieNodeODRc{V, A}) where {V, A}
    ptr_eq(a, b) && return AlgResNone()
    psubtract_dyn(as_tagged(a), as_tagged(b))
end

function prestrict(a::TrieNodeODRc{V, A}, b::TrieNodeODRc{V, A}) where {V, A}
    prestrict_dyn(as_tagged(a), as_tagged(b))
end

# Lattice on Union{Nothing, TrieNodeODRc} — ports lines 3131-3168
function pjoin(
    a::Union{Nothing, TrieNodeODRc{V, A}}, b::Union{Nothing, TrieNodeODRc{V, A}}
) where {V, A}
    if a === nothing
        b === nothing ? AlgResNone() : AlgResIdentity(COUNTER_IDENT)
    else
        b === nothing ? AlgResIdentity(SELF_IDENT) : Base.map(x -> x, pjoin(a, b))
    end
end

function pmeet(
    a::Union{Nothing, TrieNodeODRc{V, A}}, b::Union{Nothing, TrieNodeODRc{V, A}}
) where {V, A}
    a === nothing && return AlgResNone()
    b === nothing && return AlgResNone()
    pmeet(a, b)
end

# psubtract on Union{Nothing, TrieNodeODRc}
function psubtract(
    a::Union{Nothing, TrieNodeODRc{V, A}}, b::Union{Nothing, TrieNodeODRc{V, A}}
) where {V, A}
    a === nothing && return AlgResNone()
    b === nothing && return AlgResIdentity(SELF_IDENT)
    psubtract(a, b)
end

# =====================================================================
# pmeet_generic family — ports trie_node.rs lines 541–715
# =====================================================================
#
# Rust: pub(crate) fn pmeet_generic<const MAX_PAYLOAD_CNT, V, A, MergeF>(...)
# Julia: runtime-sized; const-generic becomes ordinary parameter (unused).
# `merge_f` takes Vector{Any} of Union{Nothing, ValOrChild} and returns TrieNodeODRc.

"""
    pmeet_generic_recursive_reset!(cur_group, is_ex_ref, idx, self_payloads, keys, req_results, results)

Flush the current key-group by recursing into its child node, then reset the group.
Ports `pmeet_generic_recursive_reset` (trie_node.rs, inlined into pmeet_generic_internal!).
`cur_group` is NOT mutated (caller reassigns after return).
"""
function pmeet_generic_recursive_reset!(
    cur_group, is_ex_ref::Ref{Bool}, idx::Int, self_payloads, keys, req_results, results
)
    cur_group === nothing && return nothing
    (group_start, next_node_rc) = cur_group
    if group_start >= idx
        return nothing
    end
    group_range = group_start:(idx - 1)
    sub_self = view(self_payloads, group_range)
    sub_keys = view(keys, group_range)
    sub_res = view(results, group_range)
    if !pmeet_generic_internal!(
        sub_self, sub_keys, req_results, sub_res, as_tagged(next_node_rc)
    )
        is_ex_ref[] = false
    end
end

"""
    pmeet_generic_internal!(self_payloads, keys, req_results, results, other_node) → Bool

Core recursive worker for `pmeet_generic`.  Fills `results` with
`FatAlgebraicResult` for each self_payload entry.  Returns `is_exhaustive`.
Ports `pmeet_generic_internal` (trie_node.rs lines 596–715).
"""
function pmeet_generic_internal!(
    self_payloads,
    keys,
    req_results,
    results::AbstractVector{FatAlgebraicResult{ValOrChild{V, A}}},
    other_node::AbstractTrieNode{V, A}
) where {V, A}
    is_ex_ref = Ref(true)

    if !node_get_payloads(other_node, keys, req_results)
        is_ex_ref[] = false
    end

    cur_group = nothing   # Union{Nothing, Tuple{Int, TrieNodeODRc{V,A}}}

    for idx in 1:length(keys)
        (consumed_bytes, payload) = req_results[idx]
        req_results[idx] = (0, PayloadRef{V, A}())   # take (reset)

        if !is_none(payload)
            key_len = length(keys[idx][1])
            if consumed_bytes < key_len
                # Partial match — advance key and group by child node
                old_key = keys[idx][1]
                keys[idx] = (old_key[(consumed_bytes + 1):end], keys[idx][2])
                child = get_child(payload)

                if cur_group !== nothing
                    (group_start, group_child) = cur_group
                    if !(child === group_child)
                        pmeet_generic_recursive_reset!(
                            cur_group, is_ex_ref, idx, self_payloads, keys, req_results,
                            results
                        )
                        cur_group = (idx, child)
                    end
                    # else: same child, extend group silently
                else
                    cur_group = (idx, child)
                end
            else
                # Exact match
                pmeet_generic_recursive_reset!(
                    cur_group, is_ex_ref, idx, self_payloads, keys, req_results, results
                )
                cur_group = nothing

                self_pr = self_payloads[idx][2]
                fat_res = if is_child(self_pr)
                    self_link = get_child(self_pr)
                    other_link = get_child(payload)
                    r = pmeet(self_link, other_link)
                    fat_map(
                        fat_from_binary_op_result(r, self_link, other_link),
                        c -> ValOrChild(c),
                        ValOrChild{V, A}
                    )
                else
                    self_val = get_val(self_pr)
                    other_val = get_val(payload)
                    r = pmeet(self_val, other_val)
                    fat_map(
                        fat_from_binary_op_result(r, self_val, other_val),
                        v -> ValOrChild(v),
                        ValOrChild{V, A}
                    )
                end
                results[idx] = fat_res
            end
        else
            # No match in other_node — try get_node_at_key for deeper subtrie
            pmeet_generic_recursive_reset!(
                cur_group, is_ex_ref, idx, self_payloads, keys, req_results, results
            )
            cur_group = nothing

            self_pr = self_payloads[idx][2]
            fat_res = if is_child(self_pr)
                self_link = get_child(self_pr)
                node_ref = get_node_at_key(other_node, keys[idx][1])
                other_opt = into_option(node_ref)
                if other_opt !== nothing
                    r = pmeet_dyn(as_tagged(self_link), as_tagged(other_opt))
                    fat_map(
                        fat_from_binary_op_result(r, self_link, other_opt),
                        c -> ValOrChild(c),
                        ValOrChild{V, A}
                    )
                else
                    if is_empty_node(self_link) &&
                        node_get_val(other_node, keys[idx][1]) !== nothing
                        FatAlgebraicResult{ValOrChild{V, A}}(
                            SELF_IDENT, ValOrChild(TrieNodeODRc{V, A}())
                        )
                    else
                        FatAlgebraicResult{ValOrChild{V, A}}(COUNTER_IDENT, nothing)
                    end
                end
            else
                FatAlgebraicResult{ValOrChild{V, A}}(COUNTER_IDENT, nothing)
            end
            results[idx] = fat_res
        end
    end

    # Flush any remaining group
    pmeet_generic_recursive_reset!(
        cur_group, is_ex_ref, length(keys)+1, self_payloads, keys, req_results, results
    )

    is_ex_ref[]
end

"""
    pmeet_generic(self_payloads, other, merge_f) → AlgebraicResult{TrieNodeODRc}

Generic lattice-meet over a node's payloads vs another node.
Ports `pmeet_generic` (trie_node.rs lines 541–591).

`self_payloads` must be sorted by key (ascending).
`merge_f(payloads::Vector{Union{Nothing,ValOrChild{V,A}}})` receives the per-slot
results and must return a `TrieNodeODRc{V,A}`.
"""
function pmeet_generic(
    self_payloads::AbstractVector, other::AbstractTrieNode{V, A}, merge_f::Function
) where {V, A <: Allocator}
    n = length(self_payloads)
    n == 0 && return AlgResNone()

    request_keys = [(copy(p[1]), is_val(p[2])) for p in self_payloads]
    element_results = FatAlgebraicResult{ValOrChild{V, A}}[
        fat_none(ValOrChild{V, A}) for _ in 1:n
    ]
    req_results = [(0, PayloadRef{V, A}()) for _ in 1:n]

    is_exhaustive = pmeet_generic_internal!(
        self_payloads, request_keys, req_results, element_results, other
    )

    is_none_all = true
    combined_mask = SELF_IDENT | COUNTER_IDENT
    result_payloads = Vector{Union{Nothing, ValOrChild{V, A}}}(undef, n)

    for i in 1:n
        res = element_results[i]
        combined_mask = combined_mask & res.identity_mask
        is_none_all = is_none_all && res.element === nothing
        result_payloads[i] = res.element
    end

    is_none_all && return AlgResNone()

    if !is_exhaustive
        combined_mask = combined_mask & ~COUNTER_IDENT
    end

    combined_mask > 0 && return AlgResIdentity(combined_mask)

    AlgResElement(merge_f(result_payloads))
end

# =====================================================================
# TaggedNodeRef — DEFERRED
# =====================================================================
#
# Upstream:
#   pub enum TaggedNodeRef<'a, V, A> {
#     DenseByteNode(&'a DenseByteNode<V, A>),
#     LineListNode(&'a LineListNode<V, A>),
#     CellByteNode(&'a CellByteNode<V, A>),
#     TinyRefNode(&'a TinyRefNode<'a, V, A>),
#     EmptyNode,
#   }
# + ~30 forwarding methods delegating to TrieNode trait methods.
#
# In Julia, dynamic dispatch on AbstractTrieNode already provides the
# forwarding behaviour. TaggedNodeRef variants are therefore defined as
# concrete node types themselves (DenseByteNode <: AbstractTrieNode, etc.)
# in their respective source files.  The "TaggedNodeRef" type alias for
# AbstractTrieNode is NOT created here to avoid naming confusion; callers
# use AbstractTrieNode directly.
#
# TaggedNodeRefMut<'a, V, A> → mutability in Julia is per-binding, not
# per-type. No separate type is needed.
#
# See `nodes/DenseByteNode.jl`, `nodes/LineListNode.jl`, etc. (Phase 1b).

# =====================================================================
# Exports
# =====================================================================

export MAX_NODE_KEY_BYTES, NODE_ITER_INVALID, NODE_ITER_FINISHED
export IterToken, NODE_TOKEN_SPECIAL_BIT, NODE_TOKEN_NONEXISTENT_BIT, TOKEN_LAST, TOKEN_AFTER_LAST
export node_iter_token_is_nonexistent
export EMPTY_NODE_TAG, DENSE_BYTE_NODE_TAG, LINE_LIST_NODE_TAG
export CELL_BYTE_NODE_TAG, TINY_REF_NODE_TAG, BRIDGE_NODE_TAG

export AbstractTrieNode
export node_key_overlap, node_contains_partial_key
export node_get_child, node_get_child_mut, node_replace_child!
export node_get_payloads
export node_contains_val, node_get_val, node_get_val_mut
export node_set_val!, node_remove_val!
export node_create_dangling!, node_remove_dangling!
export node_set_branch!, node_remove_all_branches!, node_remove_unmasked_branches!
export node_is_empty
export new_iter_token, iter_token_for_path, ascend_iter_token, next_items
export node_val_count, node_goat_val_count
export node_child_iter_start, node_child_iter_next
export node_first_val_depth_along_key
export nth_child_from_key, first_child_from_key
export count_branches, node_branches_mask, prior_branch_key
export get_sibling_of_child, get_node_at_key, take_node_at_key!
export pjoin_dyn, join_into_dyn!, drop_head_dyn!, pmeet_dyn, psubtract_dyn, prestrict_dyn
export clone_self, node_tag, convert_to_cell_node!

export TrieNodeODRc
export refcount, ptr_eq, is_empty_node, as_tagged, shared_node_id, make_unique!
export anr_shared_id, _check_anr_sharing

export PayloadRef, is_none, is_val, is_child, get_val, get_child
export ValOrChild, into_val, into_child

export AbstractNodeRef, ANRNone, ANRBorrowedDyn, ANRBorrowedRc, ANRBorrowedTiny, ANROwnedRc
export borrow, into_option

export fat_from_binary_op_result, fat_map
export pmeet_generic, pmeet_generic_internal!, pmeet_generic_recursive_reset!
