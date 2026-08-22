# ADR-001 increment 1 (3b/3c) + increment 2 — a minimal WRITABLE slab-backed trie.
#
# Self-contained and NOT a replacement for PathMaps. Proves the redesign's core: inserts BUILD nodes
# in the slab via immutable isbits SlabHandles; gets read them back; validated `≡ Dict`. Nodes are
# HYBRID: sparse nodes are compact LIST nodes (no 32-byte mask — fast scan, half the memory); a node
# that exceeds SLAB_MAXLIST children converts to a DENSE node (mask, O(1) lookup) so high-fan-out
# nodes don't degrade. Both via the tag-dispatched node interface in NodeSlab.jl. Scope: relocate-on-
# grow, append-only (no free-list; `slabtrie_compact!` reclaims), no COW. Requires isbits `V`, `zero(V)`.

mutable struct SlabTrie{V}
    slab::NodeSlab
    root::SlabHandle
end
SlabTrie{V}() where {V} = SlabTrie{V}(NodeSlab(), SLAB_NIL)

"Insert/overwrite `key => val`."
function slabtrie_set!(t::SlabTrie{V}, key, val::V) where {V}
    s = t.slab
    slab_is_nil(t.root) && (t.root = node_new!(s, V))
    n = length(key)
    h = t.root
    parent_coff = UInt32(0)                                   # 0 ⇒ h is the root
    i = 0
    while i < n
        b = UInt8(key[i + 1])
        ei = node_find(s, h, b, V)
        if ei == 0                                            # byte absent → grow (may convert to dense)
            h, ei = node_add_byte!(s, h, b, V)                # h relocated
            parent_coff == UInt32(0) ? (t.root = h) : slab_store!(s, parent_coff, h)
        end
        i += 1
        ecoff = node_child_off(h, ei, V)
        if i == n
            node_set_val!(s, h, ei, val)                      # value lives at the last byte's entry
            return t
        else
            child = node_child(s, h, ei, V)
            if slab_is_nil(child)
                child = node_new!(s, V)
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
        ei = node_find(s, h, b, V)
        ei == 0 && return nothing
        i += 1
        i == n && return node_hasval(s, h, ei, V) ? node_val(s, h, ei, V) : nothing
        c = node_child(s, h, ei, V)
        slab_is_nil(c) && return nothing
        h = c
    end
    return nothing
end

# DFS pre-order copy old→new: write the node first (same type), place children immediately after
# (recursively), backpatch child handles. Lays each root→leaf path near-contiguously (cache-friendly)
# and drops the append-only leaks (only reachable nodes copied). Recursive; no sharing ⇒ visit once.
function _compact_node!(
    old::NodeSlab, new::NodeSlab, old_h::SlabHandle, ::Type{V}
) where {V}
    if old_h.tag == TAG_DENSEBYTE
        mask = dbn_mask(old, old_h)
        ne = dbn_nentries(old, old_h)
        entries = Vector{DBNEntry{V}}(undef, ne)
        @inbounds for i in 1:ne
            entries[i] = dbn_entry(old, old_h, i, V)
        end
        new_h = dbn_pack!(new, mask, entries)
        @inbounds for i in 1:ne
            ch = entries[i].child
            if !slab_is_nil(ch)
                dbn_set_child!(new, new_h, i, _compact_node!(old, new, ch, V), V)
            end
        end
        return new_h
    else
        cnt = lln_count(old, old_h)
        items = Vector{Tuple{UInt8, SlabHandle, V, Bool}}(undef, cnt)
        @inbounds for i in 1:cnt
            items[i] = (
                lln_byte(old, old_h, i, V),
                lln_child(old, old_h, i, V),
                lln_val(old, old_h, i, V),
                lln_hasval(old, old_h, i, V)
            )
        end
        new_h = lln_pack!(new, items)
        @inbounds for i in 1:cnt
            ch = items[i][2]
            if !slab_is_nil(ch)
                lln_set_child!(new, new_h, i, _compact_node!(old, new, ch, V), V)
            end
        end
        return new_h
    end
end

"""
    slabtrie_compact!(t) -> t

Rebuild the slab in DFS pre-order (cache-friendly path layout) AND drop the append-only leaked
records — only reachable nodes are copied, so the slab also shrinks. Node types are preserved.
"""
function slabtrie_compact!(t::SlabTrie{V}) where {V}
    slab_is_nil(t.root) && return t
    new = NodeSlab(max(64, Int(t.slab.len)))
    t.root = _compact_node!(t.slab, new, t.root, V)
    t.slab = new
    return t
end
