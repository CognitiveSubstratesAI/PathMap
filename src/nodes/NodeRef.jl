"""
NodeRef — the five concrete `AbstractNodeRef` variants (upstream's `AbstractNodeRef` enum).

Split out of `TrieNode.jl` (where the abstract supertype still lives, because earlier files need it in a
signature) for the same reason `NodeVariant.jl` was: upstream's payloads are CONCRETE —

    BorrowedDyn(TaggedNodeRef<'a, V, A>)   -> Julia: the closed union `TrieNodeVariant{V,A}`
    BorrowedTiny(TinyRefNode<'a, V, A>)    -> Julia: `TinyRefNode{V,A}`

— and neither type exists until every node type has been included. Ours declared both fields
`AbstractTrieNode{V,A}`, an abstract field, with a comment saying `TinyRefNode.jl will narrow this`; it never
did. MEASURED 2026-09-17 (docs/PERF_AUDIT_2026-09-17.md, round 3): that one abstract field is what made
`get_node_at_key` and `node_get_child` dispatch dynamically inside `_wz_get_focus_anr`, which then inferred
`Any` for the whole `AbstractNodeRef` and made `is_none`, `as_tagged`, `_check_anr_sharing`,
`_wz_graft_internal!`, `pjoin_dyn` and `pmeet_dyn` dispatch dynamically in turn — 34 of the 40 remaining
runtime-dispatch sites, all in `join_map_into!` / `meet_into!`.
"""

# The variants of `AbstractNodeRef{V,A}` (declared in TrieNode.jl):
#
#   - `ANRNone`         — focus is on a non-existent path
#   - `ANRBorrowedDyn`  — borrowed dynamic node reference (no ODRc available)
#   - `ANRBorrowedRc`   — borrowed ODRc reference (cheapest/fastest path)
#   - `ANRBorrowedTiny` — pointer into a sub-position within a node
#   - `ANROwnedRc`      — newly allocated node (worst-case: allocation happened)

struct ANRNone{V, A <: Allocator} <: AbstractNodeRef{V, A} end

struct ANRBorrowedDyn{V, A <: Allocator} <: AbstractNodeRef{V, A}
    node::TrieNodeVariant{V, A}   # upstream: TaggedNodeRef<'a, V, A>
end

struct ANRBorrowedRc{V, A <: Allocator} <: AbstractNodeRef{V, A}
    rc::TrieNodeODRc{V, A}
end

struct ANRBorrowedTiny{V, A <: Allocator} <: AbstractNodeRef{V, A}
    node::TinyRefNode{V, A}       # upstream: TinyRefNode<'a, V, A>
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
`meet_into!` and `subtract_into!`.
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

  - `meet_into!`    : A ∩ A = A  → returns `ALG_STATUS_IDENTITY` immediately
  - `subtract_into!`: A − A = ∅  → grafts nothing, returns `ALG_STATUS_NONE`

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
        # Upstream: `tiny.into_full().map(|list| TrieNodeODRc::new_in(list, tiny.alloc))`.
        # `clone_self(::TinyRefNode)` IS that expression (TinyRefNode.jl:272) — the only difference is the
        # empty case, which upstream maps to `None` and `into_full` asserts against here; `get_node_at_key`
        # never builds an empty `ANRBorrowedTiny`, which is why the assert has never fired.
        return clone_self(r.node)
    elseif r isa ANROwnedRc
        return r.rc
    end
end

# `as_tagged(::AbstractNodeRef)` lives in nodes/NodeVariant.jl, beside the union it narrows to.
