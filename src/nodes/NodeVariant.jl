"""
NodeVariant — the CLOSED union of concrete node types, and the two accessors that narrow to it.

Upstream's `TaggedNodeRef` is an enum: matching on it gives the compiler the complete list of node types, so
a node call becomes a jump table rather than a vtable lookup. Julia's equivalent is a `Union` of the concrete
types plus a type assertion at the accessor — but the union can only be written once EVERY node type exists,
which is why this file is included after the last of them (`BridgeNode.jl`) rather than in `TrieNode.jl`
beside the struct it accesses.

🔴 WHY THE ASSERTION IS THE WHOLE POINT. `TrieNodeODRc.node` is declared
`Union{Nothing, AbstractTrieNode{V,A}}` — it has to be, because a node holds children of any type. Without
`::TrieNodeVariant{V,A}` here, every `node_get_child` / `node_contains_val` / `node_remove_all_branches!`
reached through `as_tagged` is a DYNAMIC DISPATCH, and inference gives `Any` back to the caller.
MEASURED 2026-09-17 (docs/PERF_AUDIT_2026-09-17.md): the read zipper, which already narrowed through
`_fnode`, showed ZERO runtime-dispatch sites; the write zipper, which did not, showed 96 across its entry
points, and six public functions (`val`/`child_count` on the write zipper, `remove_val!`, `get_val_at`,
`set_val_at!`, `val_count`) inferred `Any`.

The assertion is a semantic no-op: `TrieNodeVariant` enumerates every subtype of `AbstractTrieNode` in the
package, so anything reaching it already satisfies it. If a new node type is added it MUST be listed here —
otherwise the assertion throws, loudly, at the first call rather than silently degrading.
"""

const TrieNodeVariant{V, A} = Union{
    EmptyNode{V, A}, LineListNode{V, A}, DenseByteNode{V, A}, CellByteNode{V, A},
    TinyRefNode{V, A}, BridgeNode{V, A}
}

"""
    _fnode(inner, V, A) -> TrieNodeVariant{V,A}

The EmptyNode-safe, NARROWED inner-node accessor: `nothing` (the empty sentinel) becomes the `EmptyNode`
singleton, anything else is asserted into the closed union. Upstream's `TaggedNodeRef`.
"""
@inline function _fnode(inner, ::Type{V}, ::Type{A}) where {V, A <: Allocator}
    inner === nothing ? EmptyNode{V, A}() : inner::TrieNodeVariant{V, A}
end

"""
    as_tagged(rc::TrieNodeODRc) -> TrieNodeVariant

Returns the inner node (= `TaggedNodeRef`). Mirrors `TrieNodeODRc::as_tagged`, which yields
`TaggedNodeRef::EmptyNode` for the empty sentinel (trie_node.rs `TaggedNodePtr`:
`EMPTY_NODE_TAG => Self::EmptyNode`) — so here the `EmptyNode` singleton, never `nothing`.
"""
@inline as_tagged(rc::TrieNodeODRc{V, A}) where {V, A} = _fnode(rc.node, V, A)

"""
    as_tagged(r::AbstractNodeRef) -> TrieNodeVariant

The `AbstractNodeRef` (upstream `AbstractNodeRef`) form, narrowed the same way. `ANRNone` has no node and
throws, as before.
"""
function as_tagged(r::AbstractNodeRef{V, A}) where {V, A}
    if r isa ANRBorrowedDyn
        return r.node::TrieNodeVariant{V, A}
    elseif r isa ANRBorrowedRc
        return as_tagged(r.rc)
    elseif r isa ANRBorrowedTiny
        return r.node::TrieNodeVariant{V, A}
    elseif r isa ANROwnedRc
        return as_tagged(r.rc)
    else
        error("as_tagged on ANRNone")
    end
end

# ── the key slice `next_items` hands back ────────────────────────────────────────────────────────────────
"""
    NodeKeySlice

The type every `next_items` method returns as its `path` element: a BORROWED view, never a fresh vector.

Upstream returns `&[u8]` — for a byte node a slice of the static `ALL_BYTES` table (dense_byte_node.rs:1052),
for a line node the node's own key bytes. Ours used to `copy` on every step, which cost one `Vector` (plus its
`Memory`) PER ITERATION STEP: measured 2026-09-17 at 83 906 allocations / 1.68 MB for a 5 000-value walk
(docs/PERF_AUDIT_2026-09-17.md Finding 3).

Every method returning the SAME concrete type also matters: with four methods returning four different tuple
types the call site saw a union and boxed the tuple and the token inside it.

⚠️ BORROWED means borrowed: the slice is only valid until the node is next mutated, exactly as upstream's
`&[u8]` is. Callers that keep the bytes must copy (the zipper `append!`s them into its own path buffer).
"""
const NodeKeySlice = SubArray{UInt8, 1, Vector{UInt8}, Tuple{UnitRange{Int}}, true}

"The 256 single bytes, so a byte node can hand back a slice instead of allocating (upstream `ALL_BYTES`)."
const ALL_BYTES = collect(UInt8, 0x00:0xff)

"An empty key slice, for the `FINISHED` result."
const NO_KEY_BYTES = UInt8[]
@inline no_key()::NodeKeySlice = view(NO_KEY_BYTES, 1:0)
@inline one_byte(k::UInt8)::NodeKeySlice = view(ALL_BYTES, (Int(k) + 1):(Int(k) + 1))
@inline whole_key(v::Vector{UInt8})::NodeKeySlice = view(v, 1:length(v))

export TrieNodeVariant, NodeKeySlice
