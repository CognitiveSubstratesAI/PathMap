# ADR-001 increment 1, step 3b — a minimal WRITABLE slab-backed trie.
#
# Self-contained and NOT a replacement for PathMap. It proves the redesign's core end-to-end:
# inserts BUILD dense-byte nodes in the slab (via immutable isbits SlabHandles), gets read them back.
# Validated for key→value equivalence against a Dict. Scope of THIS minimal version:
#   • dense-byte nodes only (no LineListNode compaction yet),
#   • relocate-on-grow + in-place parent-handle update (handles are indices ⇒ stable across regrow),
#   • append-only (no free-list reuse; relocated records are leaked — reclaimed in a later increment),
#   • no COW / structural sharing.
# Those remaining pieces (+ then replacing PathMap) are the later increments in ADR-001-IMPL-PLAN.md.
# Requires isbits `V` with `zero(V)` (the placeholder for a child-only entry).

mutable struct SlabTrie{V}
    slab::NodeSlab
    root::SlabHandle
end
SlabTrie{V}() where {V} = SlabTrie{V}(NodeSlab(), SLAB_NIL)

@inline _dbn_ebase(h::SlabHandle, ei::Int, ::Type{V}) where {V} =
    h.idx + UInt32(sizeof(ByteMask) + 2 + (ei - 1) * _dbn_estride(V))

# In-place set of entry `ei`'s value (the record size is unchanged ⇒ no relocation).
@inline function _dbn_set_val!(s::NodeSlab, h::SlabHandle, ei::Int, val::V) where {V}
    base = _dbn_ebase(h, ei, V)
    slab_store!(s, base + UInt32(sizeof(SlabHandle)), val)
    slab_store!(s, base + UInt32(sizeof(SlabHandle) + sizeof(V)), 0x01)   # has_val = true
    return nothing
end

@inline dbn_new!(s::NodeSlab, ::Type{V}) where {V} = dbn_pack!(s, ByteMask(), DBNEntry{V}[])

# Add byte `b` (empty entry) to dense byte node `h` (which must not already contain it). Relocates
# the node and returns (new_handle, 1-based entry index of b). Children/values are preserved.
function dbn_add_byte!(s::NodeSlab, h::SlabHandle, b::UInt8, ::Type{V}) where {V}
    mask = dbn_mask(s, h)
    ne = dbn_nentries(s, h)
    entries = Vector{DBNEntry{V}}(undef, ne)
    @inbounds for i in 1:ne
        entries[i] = dbn_entry(s, h, i, V)
    end
    newmask = set(mask, b)
    pos = Int(index_of(newmask, b)) + 1                       # byte-sorted insertion point
    insert!(entries, pos, DBNEntry{V}(SLAB_NIL, zero(V), false))
    return (dbn_pack!(s, newmask, entries), pos)
end

"Insert/overwrite `key => val`."
function slabtrie_set!(t::SlabTrie{V}, key, val::V) where {V}
    s = t.slab
    slab_is_nil(t.root) && (t.root = dbn_new!(s, V))
    n = length(key)
    h = t.root
    parent_coff = UInt32(0)                                   # 0 ⇒ h is the root
    i = 0
    while i < n
        b = UInt8(key[i + 1])
        ei = dbn_slab_index(s, h, b)
        if ei == 0                                            # byte absent → grow this node
            h, ei = dbn_add_byte!(s, h, b, V)                 # h relocated
            parent_coff == UInt32(0) ? (t.root = h) : slab_store!(s, parent_coff, h)
        end
        i += 1
        ecoff = _dbn_ebase(h, ei, V)                          # entry's child-handle offset
        if i == n
            _dbn_set_val!(s, h, ei, val)                      # value lives at the last byte's entry
            return t
        else
            child = dbn_entry(s, h, ei, V).child
            if slab_is_nil(child)
                child = dbn_new!(s, V)
                slab_store!(s, ecoff, child)                  # link the new child in place
            end
            parent_coff = ecoff
            h = child
        end
    end
    return t
end

"Look up `key`; returns the value or `nothing`."
function slabtrie_get(t::SlabTrie{V}, key) where {V}
    s = t.slab
    h = t.root
    slab_is_nil(h) && return nothing
    n = length(key)
    i = 0
    while i < n
        b = UInt8(key[i + 1])
        ei = dbn_slab_index(s, h, b)
        ei == 0 && return nothing
        e = dbn_entry(s, h, ei, V)
        i += 1
        i == n && return e.has_val ? e.val : nothing
        slab_is_nil(e.child) && return nothing
        h = e.child
    end
    return nothing
end

# Copy the subtrie rooted at `old_h` from `old`→`new` in DFS PRE-order: the node is written first,
# then its children are placed immediately after (recursively), and the node's child handles are
# backpatched to the new locations. Result: every root→leaf path is laid out near-contiguously
# (forward) — the cache-friendly layout the read-only ACT gets from its sorted build.
function _compact_node!(old::NodeSlab, new::NodeSlab, old_h::SlabHandle, ::Type{V}) where {V}
    mask = dbn_mask(old, old_h)
    ne = dbn_nentries(old, old_h)
    entries = Vector{DBNEntry{V}}(undef, ne)
    @inbounds for i in 1:ne
        entries[i] = dbn_entry(old, old_h, i, V)
    end
    new_h = dbn_pack!(new, mask, entries)            # write parent first (placeholder child handles)
    @inbounds for i in 1:ne
        ch = entries[i].child
        if !slab_is_nil(ch)
            nc = _compact_node!(old, new, ch, V)     # place child after, recursively
            slab_store!(new, _dbn_ebase(new_h, i, V), nc)   # backpatch parent's child handle
        end
    end
    return new_h
end

"""
    slabtrie_compact!(t) -> t

Rebuild the slab in DFS pre-order (cache-friendly path layout) AND drop the append-only leaked
records — only reachable nodes are copied, so the slab also shrinks. (Recursive on trie depth;
no structural sharing in this minimal version, so each node is visited once.)
"""
function slabtrie_compact!(t::SlabTrie{V}) where {V}
    slab_is_nil(t.root) && return t
    new = NodeSlab(max(64, Int(t.slab.len)))         # old len is a safe upper bound (compaction shrinks)
    t.root = _compact_node!(t.slab, new, t.root, V)
    t.slab = new
    return t
end
