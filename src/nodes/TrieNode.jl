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
  - `pmeet_generic` / `pmeet_generic_internal` / `node_count_branches_recursive`

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

"""
    NODE_ITER_INVALID :: UInt128

Sentinel token: iteration has NOT been initialized.
Matches upstream `NODE_ITER_INVALID = 0xFFFFFFFF…`.
"""
const NODE_ITER_INVALID = typemax(UInt128)

"""
    NODE_ITER_FINISHED :: UInt128

Sentinel token: iteration has concluded.
Matches upstream `NODE_ITER_FINISHED = NODE_ITER_INVALID - 1`.
"""
const NODE_ITER_FINISHED = typemax(UInt128) - UInt128(1)

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
    new_iter_token(node) -> UInt128
"""
function new_iter_token end

"""
    iter_token_for_path(node, key::Vector{UInt8}) -> UInt128
"""
function iter_token_for_path end

"""
    next_items(node, token::UInt128) -> (UInt128, Vector{UInt8}, Union{Nothing, TrieNodeODRc}, Union{Nothing, V})
"""
function next_items end

"""
    node_val_count(node, cache::Dict) -> Int
"""
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
refcount(rc::TrieNodeODRc) = rc.node === nothing ? 1 : _node_refcount(rc.node)

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

Returns the inner node (= `TaggedNodeRef`). Mirrors `as_tagged`.
"""
@inline as_tagged(rc::TrieNodeODRc) = rc.node

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
    n = rc.node
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
# Mirrors Rust's implicit Deref through Arc<dyn TrieNode>.
function join_into_dyn!(rc::TrieNodeODRc{V, A}, other::TrieNodeODRc{V, A}) where {V, A}
    rc.node === nothing && return (ALG_STATUS_IDENTITY, nothing)
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
# Rust:
#   pub enum AbstractNodeRef<'a, V, A> {
#     None,
#     BorrowedDyn(TaggedNodeRef<'a, V, A>),
#     BorrowedRc(&'a TrieNodeODRc<V, A>),
#     BorrowedTiny(TinyRefNode<'a, V, A>),
#     OwnedRc(TrieNodeODRc<V, A>),
#   }
#
# Julia: lifetime dropped; BorrowedTiny uses the abstract node type until
# TinyRefNode is defined in its own file.

"""
    AbstractNodeRef{V,A<:Allocator}

Abstracted reference to a node at a zipper's focus position.
Corresponds to `AbstractNodeRef<'a, V, A>` in upstream.

Variants:

  - `ANRNone` — focus is on a non-existent path
  - `ANRBorrowedDyn` — borrowed dynamic node reference (no ODRc available)
  - `ANRBorrowedRc` — borrowed ODRc reference (cheapest/fastest path)
  - `ANRBorrowedTiny` — pointer into a sub-position within a node
  - `ANROwnedRc` — newly allocated node (worst-case: allocation happened)
"""
abstract type AbstractNodeRef{V, A <: Allocator} end

struct ANRNone{V, A <: Allocator} <: AbstractNodeRef{V, A} end

struct ANRBorrowedDyn{V, A <: Allocator} <: AbstractNodeRef{V, A}
    node::AbstractTrieNode{V, A}
end

struct ANRBorrowedRc{V, A <: Allocator} <: AbstractNodeRef{V, A}
    rc::TrieNodeODRc{V, A}
end

struct ANRBorrowedTiny{V, A <: Allocator} <: AbstractNodeRef{V, A}
    # Placeholder until TinyRefNode is ported in Phase 1b.
    # Carries the abstract node; TinyRefNode.jl will narrow this.
    node::AbstractTrieNode{V, A}
end

struct ANROwnedRc{V, A <: Allocator} <: AbstractNodeRef{V, A}
    rc::TrieNodeODRc{V, A}
end

# =====================================================================
# anr_shared_id / _check_anr_sharing — shared-node identity for AbstractNodeRef
# =====================================================================
#
# Upstream context: PathMap experimental/zipper_algebra.rs, commit ade1e1b
# ("zipper_algebra: short-circuit on shared subtries").
#
# `ZipperConcrete::shared_node_id()` returns `Option<u64>` in Rust —
# `Some(ptr)` when the zipper's focus has a stable pointer identity, `None`
# otherwise.  In Julia, `ANRBorrowedRc` / `ANROwnedRc` carry a `TrieNodeODRc`
# whose `objectid` is the stable identity.  Dynamic and tiny refs don't expose
# one.

"""
    anr_shared_id(r::AbstractNodeRef) -> Union{Nothing, UInt64}

Return a stable pointer identity for the trie node referenced by `r`, or
`nothing` if `r` does not carry a GC-stable node pointer.

  - `ANRBorrowedRc` / `ANROwnedRc` → `objectid(rc.node)` (non-zero when non-empty)
  - `ANRNone` / `ANRBorrowedDyn` / `ANRBorrowedTiny` → `nothing`

Mirrors `ZipperConcrete::shared_node_id()` (upstream PathMap, commit ade1e1b).
Used by `_check_anr_sharing` to enable the shared-node short-circuit in
`wz_meet_into!` and `wz_subtract_into!`.
"""
anr_shared_id(::ANRNone) = nothing
anr_shared_id(::ANRBorrowedDyn) = nothing
anr_shared_id(::ANRBorrowedTiny) = nothing
function anr_shared_id(r::ANRBorrowedRc{V, A}) where {V, A}
    id = shared_node_id(r.rc)
    id == UInt64(0) ? nothing : id
end
function anr_shared_id(r::ANROwnedRc{V, A}) where {V, A}
    id = shared_node_id(r.rc)
    id == UInt64(0) ? nothing : id
end

"""
    _check_anr_sharing(a, b) -> Bool

Return `true` iff both `AbstractNodeRef` values point to the **same** underlying
trie node (identical `objectid`).

This is the guard for the shared-node short-circuit:

  - `wz_meet_into!`    : A ∩ A = A  → returns `ALG_STATUS_IDENTITY` immediately
  - `wz_subtract_into!`: A − A = ∅  → grafts nothing, returns `ALG_STATUS_NONE`

Mirrors `check_sharing` in upstream PathMap `experimental/zipper_algebra.rs`
(commit ade1e1b: "short-circuit on shared subtries (entry + post-descend)").
"""
@inline function _check_anr_sharing(
    a::AbstractNodeRef{V, A}, b::AbstractNodeRef{V, A}
) where {V, A}
    aid = anr_shared_id(a)
    aid === nothing && return false
    bid = anr_shared_id(b)
    bid !== nothing && aid == bid
end

# Mirror upstream's is_none / borrow / into_option / as_tagged

is_none(r::ANRNone) = true
is_none(r::AbstractNodeRef) = false

function borrow(r::AbstractNodeRef{V, A}) where {V, A}
    if r isa ANRBorrowedRc
        return r.rc
    elseif r isa ANROwnedRc
        return r.rc
    else
        return nothing
    end
end

function into_option(r::AbstractNodeRef{V, A}) where {V, A}
    if r isa ANRNone
        return nothing
    elseif r isa ANRBorrowedDyn
        return clone_self(r.node)
    elseif r isa ANRBorrowedRc
        if !is_empty_node(r.rc) && !node_is_empty(as_tagged(r.rc))
            return copy(r.rc)
        else
            return nothing
        end
    elseif r isa ANRBorrowedTiny
        # TinyRefNode support deferred — treat as BorrowedDyn for now
        return clone_self(r.node)
    elseif r isa ANROwnedRc
        return r.rc
    end
end

function as_tagged(r::AbstractNodeRef{V, A}) where {V, A}
    if r isa ANRBorrowedDyn
        return r.node
    elseif r isa ANRBorrowedRc
        return as_tagged(r.rc)
    elseif r isa ANRBorrowedTiny
        return r.node
    elseif r isa ANROwnedRc
        return as_tagged(r.rc)
    else
        error("as_tagged on ANRNone")
    end
end

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
export new_iter_token, iter_token_for_path, next_items
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
