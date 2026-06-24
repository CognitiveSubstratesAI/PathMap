# ADR-001 increment 1, step 3b/3c + increment 2 — a minimal WRITABLE slab-backed trie.
#
# Self-contained and NOT a replacement for PathMap. Proves the redesign's core: inserts BUILD nodes
# in the slab via immutable isbits SlabHandles; gets read them back; validated `≡ Dict`. This version
# uses SPARSE LIST nodes (no 32-byte mask — increment 2), halving per-node memory vs the dense node
# for the many sparse nodes (lookup is an O(count) linear scan). Scope: list nodes only (a dense
# fallback for high-fan-out nodes is a later increment), relocate-on-grow, append-only (no free-list;
# `slabtrie_compact!` reclaims), no COW. Requires isbits `V` with `zero(V)`.

mutable struct SlabTrie{V}
    slab::NodeSlab
    root::SlabHandle
end
SlabTrie{V}() where {V} = SlabTrie{V}(NodeSlab(), SLAB_NIL)

"Insert/overwrite `key => val`."
function slabtrie_set!(t::SlabTrie{V}, key, val::V) where {V}
    s = t.slab
    slab_is_nil(t.root) && (t.root = lln_new!(s, V))
    n = length(key)
    h = t.root
    parent_coff = UInt32(0)                                   # 0 ⇒ h is the root
    i = 0
    while i < n
        b = UInt8(key[i + 1])
        ei = lln_find(s, h, b, V)
        if ei == 0                                            # byte absent → grow this node
            h, ei = lln_add_byte!(s, h, b, V)                 # h relocated
            parent_coff == UInt32(0) ? (t.root = h) : slab_store!(s, parent_coff, h)
        end
        i += 1
        ecoff = lln_child_off(h, ei, V)
        if i == n
            lln_set_val!(s, h, ei, val)                       # value lives at the last byte's entry
            return t
        else
            child = lln_child(s, h, ei, V)
            if slab_is_nil(child)
                child = lln_new!(s, V)
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
        ei = lln_find(s, h, b, V)
        ei == 0 && return nothing
        i += 1
        i == n && return lln_hasval(s, h, ei, V) ? lln_val(s, h, ei, V) : nothing
        c = lln_child(s, h, ei, V)
        slab_is_nil(c) && return nothing
        h = c
    end
    return nothing
end

# DFS pre-order copy old→new: write the node first, place children immediately after (recursively),
# backpatch child handles. Lays each root→leaf path near-contiguously (cache-friendly) and drops the
# append-only leaks (only reachable nodes are copied). Recursive on depth; no sharing ⇒ visit once.
function _compact_node!(old::NodeSlab, new::NodeSlab, old_h::SlabHandle, ::Type{V}) where {V}
    cnt = lln_count(old, old_h)
    items = Vector{Tuple{UInt8, SlabHandle, V, Bool}}(undef, cnt)
    @inbounds for i in 1:cnt
        items[i] = (lln_byte(old, old_h, i, V), lln_child(old, old_h, i, V), lln_val(old, old_h, i, V), lln_hasval(old, old_h, i, V))
    end
    new_h = lln_pack!(new, items)
    @inbounds for i in 1:cnt
        ch = items[i][2]
        if !slab_is_nil(ch)
            nc = _compact_node!(old, new, ch, V)
            lln_set_child!(new, new_h, i, nc, V)
        end
    end
    return new_h
end

"""
    slabtrie_compact!(t) -> t

Rebuild the slab in DFS pre-order (cache-friendly path layout) AND drop the append-only leaked
records — only reachable nodes are copied, so the slab also shrinks.
"""
function slabtrie_compact!(t::SlabTrie{V}) where {V}
    slab_is_nil(t.root) && return t
    new = NodeSlab(max(64, Int(t.slab.len)))
    t.root = _compact_node!(t.slab, new, t.root, V)
    t.slab = new
    return t
end
