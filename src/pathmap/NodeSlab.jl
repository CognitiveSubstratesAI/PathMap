# ADR-001 (docs/ADR-001-node-storage-memory-slab.md) — increment 1, step 1: slab scaffold.
#
# ADDITIVE and NOT wired into the live trie. It exists to (a) PROVE the redesign's central thesis
# and (b) provide the storage primitive the node migration (increments 2-4) builds on.
#
# Thesis: replacing the mutable-struct + heap-ref node model with an IMMUTABLE isbits handle
# (index + tag) into a contiguous `Memory{UInt8}` slab makes `Tuple{Int, handle}` isbits ⇒ it
# stack-allocates, eliminating the residual Cluster-3 box that a mutable `TrieNodeODRc`
# structurally cannot avoid. Mirrors the existing read-only ACT (`ArenaCompact.jl`): an `ACT_NodeId`
# handle + slab-threaded reads — ADR-001 promotes that layout to the primary, writable form.

@enum NodeTag::UInt8 TAG_NIL = 0 TAG_LINELIST = 1 TAG_DENSEBYTE = 2 TAG_BRIDGE = 3 TAG_TINYREF = 4

"""
    SlabHandle

Immutable, **isbits** handle into a [`NodeSlab`](@ref): 1-based byte `idx` (0 = nil) + node-type
`tag`. The isbits-ness is the whole point — `Tuple{Int, SlabHandle}` stack-allocates (no heap box),
unlike `Tuple{Int, TrieNodeODRc}` today.
"""
struct SlabHandle
    idx::UInt32
    tag::NodeTag
end
const SLAB_NIL = SlabHandle(UInt32(0), TAG_NIL)
@inline slab_is_nil(h::SlabHandle) = h.idx == UInt32(0)

"""
    NodeSlab

Contiguous `Memory{UInt8}` arena for node records, owned by a `PathMap` (the allocator role moves
here under ADR-001). Append-only for now; free-list reuse arrives with the COW migration.
"""
mutable struct NodeSlab
    bytes::Memory{UInt8}
    len::UInt32
end
NodeSlab(cap::Integer = 256) = NodeSlab(Memory{UInt8}(undef, Int(cap)), UInt32(0))

"Reserve `nbytes` contiguous bytes (doubling-grow if needed); return the 1-based start index."
@inline function slab_reserve!(s::NodeSlab, nbytes::Integer)::UInt32
    start = s.len + UInt32(1)
    need = Int(s.len) + Int(nbytes)
    if need > length(s.bytes)
        newcap = max(2 * length(s.bytes), need)
        nb = Memory{UInt8}(undef, newcap)
        @inbounds for i in 1:Int(s.len)
            nb[i] = s.bytes[i]
        end
        s.bytes = nb
    end
    s.len = UInt32(need)
    return start
end

"Store an isbits `x::T` at 1-based byte offset `off` (x86 allows the unaligned access)."
@inline function slab_store!(s::NodeSlab, off::UInt32, x::T) where {T}
    GC.@preserve s unsafe_store!(Ptr{T}(pointer(s.bytes) + (Int(off) - 1)), x)
    return nothing
end

"Load an isbits `T` from 1-based byte offset `off`."
@inline function slab_load(s::NodeSlab, off::UInt32, ::Type{T}) where {T}
    GC.@preserve s unsafe_load(Ptr{T}(pointer(s.bytes) + (Int(off) - 1)))
end

# ── increment 1, step 2: DenseByteNode in-slab record (round-trip; NOT wired into the live trie) ──
# A `DenseByteNode` is a `ByteMask` (which bytes are present) + one `CoFreeEntry` (child + value) per
# present byte. Packed layout, fixed-stride for O(1) entry indexing (requires isbits `V`):
#   [mask: ByteMask (32 B)] [nentries: UInt16] [entries...]
#   entry = [child: SlabHandle (8 B)] [val: V (sizeof(V))] [has_val: UInt8]   (child==SLAB_NIL ⇒ none)

"One packed dense-byte entry: the child handle, the value, and whether the value is present."
struct DBNEntry{V}
    child::SlabHandle
    val::V
    has_val::Bool
end

@inline _dbn_estride(::Type{V}) where {V} = sizeof(SlabHandle) + sizeof(V) + 1

"Pack a dense byte node (mask + entries) into the slab; return its `SlabHandle`."
function dbn_pack!(s::NodeSlab, mask::ByteMask, entries::AbstractVector{DBNEntry{V}}) where {V}
    es = _dbn_estride(V)
    start = slab_reserve!(s, sizeof(ByteMask) + 2 + length(entries) * es)
    off = start
    slab_store!(s, off, mask);                    off += UInt32(sizeof(ByteMask))
    slab_store!(s, off, UInt16(length(entries))); off += UInt32(2)
    for e in entries
        slab_store!(s, off, e.child);             off += UInt32(sizeof(SlabHandle))
        slab_store!(s, off, e.val);               off += UInt32(sizeof(V))
        slab_store!(s, off, e.has_val ? 0x01 : 0x00); off += UInt32(1)
    end
    return SlabHandle(start, TAG_DENSEBYTE)
end

@inline dbn_mask(s::NodeSlab, h::SlabHandle) = slab_load(s, h.idx, ByteMask)
@inline dbn_nentries(s::NodeSlab, h::SlabHandle) = Int(slab_load(s, h.idx + UInt32(sizeof(ByteMask)), UInt16))

"Read the `i`-th (1-based) entry of the slab dense byte node at `h`."
function dbn_entry(s::NodeSlab, h::SlabHandle, i::Integer, ::Type{V}) where {V}
    base = h.idx + UInt32(sizeof(ByteMask) + 2 + (Int(i) - 1) * _dbn_estride(V))
    child = slab_load(s, base, SlabHandle)
    val = slab_load(s, base + UInt32(sizeof(SlabHandle)), V)
    hv = slab_load(s, base + UInt32(sizeof(SlabHandle) + sizeof(V)), UInt8)
    return DBNEntry{V}(child, val, hv != 0x00)
end

# Read lookup (step 3 prerequisite): the byte-keyed entry index a slab `DenseByteNode` resolves a
# byte to — exactly the `test_bit` + `index_of` mask lookup `node_get_child`/`node_get_val` use on
# the mutable byte node. Returns the 1-based entry index, or 0 if the byte is absent. With this, a
# slab byte node can serve reads; wiring it into the live descent (dual-path dispatch) is the next
# (riskier) sub-step.
@inline function dbn_slab_index(s::NodeSlab, h::SlabHandle, byte::UInt8)::Int
    mask = dbn_mask(s, h)
    test_bit(mask, byte) || return 0
    return Int(index_of(mask, byte)) + 1
end

# ── increment 2: sparse LIST node (TAG_LINELIST) — no 32-byte mask, linear scan ──
# Layout: [count: UInt16] [entries: count × (byte: UInt8, child: SlabHandle 8, val: V, has_val: UInt8)].
# Halves per-node memory vs the dense node for the (many) sparse nodes; lookup is an O(count) scan.
@inline _lln_estride(::Type{V}) where {V} = 1 + sizeof(SlabHandle) + sizeof(V) + 1
@inline lln_count(s::NodeSlab, h::SlabHandle) = Int(slab_load(s, h.idx, UInt16))
@inline _lln_ebase(h::SlabHandle, i::Int, ::Type{V}) where {V} = h.idx + UInt32(2 + (i - 1) * _lln_estride(V))
@inline lln_byte(s::NodeSlab, h::SlabHandle, i::Int, ::Type{V}) where {V} = slab_load(s, _lln_ebase(h, i, V), UInt8)
@inline lln_child(s::NodeSlab, h::SlabHandle, i::Int, ::Type{V}) where {V} = slab_load(s, _lln_ebase(h, i, V) + UInt32(1), SlabHandle)
@inline lln_val(s::NodeSlab, h::SlabHandle, i::Int, ::Type{V}) where {V} = slab_load(s, _lln_ebase(h, i, V) + UInt32(9), V)
@inline lln_hasval(s::NodeSlab, h::SlabHandle, i::Int, ::Type{V}) where {V} = slab_load(s, _lln_ebase(h, i, V) + UInt32(9 + sizeof(V)), UInt8) != 0x00
@inline lln_child_off(h::SlabHandle, i::Int, ::Type{V}) where {V} = _lln_ebase(h, i, V) + UInt32(1)

@inline function lln_find(s::NodeSlab, h::SlabHandle, byte::UInt8, ::Type{V})::Int where {V}
    cnt = lln_count(s, h)
    @inbounds for i in 1:cnt
        slab_load(s, _lln_ebase(h, i, V), UInt8) == byte && return i
    end
    return 0
end

@inline function lln_new!(s::NodeSlab, ::Type{V}) where {V}
    start = slab_reserve!(s, 2)
    slab_store!(s, start, UInt16(0))
    return SlabHandle(start, TAG_LINELIST)
end

"Pack a list node from `(byte, child, val, has_val)` items."
function lln_pack!(s::NodeSlab, items::AbstractVector{Tuple{UInt8, SlabHandle, V, Bool}}) where {V}
    n = length(items)
    start = slab_reserve!(s, 2 + n * _lln_estride(V))
    slab_store!(s, start, UInt16(n))
    off = start + UInt32(2)
    for (b, c, v, hv) in items
        slab_store!(s, off, b)
        slab_store!(s, off + UInt32(1), c)
        slab_store!(s, off + UInt32(9), v)
        slab_store!(s, off + UInt32(9 + sizeof(V)), hv ? 0x01 : 0x00)
        off += UInt32(_lln_estride(V))
    end
    return SlabHandle(start, TAG_LINELIST)
end

# Append byte `b` (empty entry) to list node `h` (relocate); return (new_handle, new entry index).
function lln_add_byte!(s::NodeSlab, h::SlabHandle, b::UInt8, ::Type{V}) where {V}
    cnt = lln_count(s, h)
    items = Vector{Tuple{UInt8, SlabHandle, V, Bool}}(undef, cnt + 1)
    @inbounds for i in 1:cnt
        items[i] = (lln_byte(s, h, i, V), lln_child(s, h, i, V), lln_val(s, h, i, V), lln_hasval(s, h, i, V))
    end
    items[cnt + 1] = (b, SLAB_NIL, zero(V), false)
    return (lln_pack!(s, items), cnt + 1)
end

@inline function lln_set_val!(s::NodeSlab, h::SlabHandle, i::Int, val::V) where {V}
    base = _lln_ebase(h, i, V)
    slab_store!(s, base + UInt32(9), val)
    slab_store!(s, base + UInt32(9 + sizeof(V)), 0x01)
    return nothing
end
@inline lln_set_child!(s::NodeSlab, h::SlabHandle, i::Int, child::SlabHandle, ::Type{V}) where {V} =
    slab_store!(s, _lln_ebase(h, i, V) + UInt32(1), child)

# ── increment 2 hybrid: dense-byte WRITE helpers + list→dense conversion + tag dispatch ──
# Sparse nodes stay LIST (compact, fast scan); a node that exceeds SLAB_MAXLIST children converts to
# DENSE (32-byte mask, O(1) lookup) so high-fan-out nodes don't degrade to a long linear scan.
const SLAB_MAXLIST = 16

@inline _dbn_ebase(h::SlabHandle, i::Int, ::Type{V}) where {V} = h.idx + UInt32(sizeof(ByteMask) + 2 + (i - 1) * _dbn_estride(V))
@inline dbn_child(s::NodeSlab, h::SlabHandle, i::Int, ::Type{V}) where {V} = slab_load(s, _dbn_ebase(h, i, V), SlabHandle)
@inline dbn_val(s::NodeSlab, h::SlabHandle, i::Int, ::Type{V}) where {V} = slab_load(s, _dbn_ebase(h, i, V) + UInt32(sizeof(SlabHandle)), V)
@inline dbn_hasval(s::NodeSlab, h::SlabHandle, i::Int, ::Type{V}) where {V} = slab_load(s, _dbn_ebase(h, i, V) + UInt32(sizeof(SlabHandle) + sizeof(V)), UInt8) != 0x00
@inline dbn_child_off(h::SlabHandle, i::Int, ::Type{V}) where {V} = _dbn_ebase(h, i, V)
@inline function dbn_set_val!(s::NodeSlab, h::SlabHandle, i::Int, val::V) where {V}
    base = _dbn_ebase(h, i, V)
    slab_store!(s, base + UInt32(sizeof(SlabHandle)), val)
    slab_store!(s, base + UInt32(sizeof(SlabHandle) + sizeof(V)), 0x01)
    return nothing
end
@inline dbn_set_child!(s::NodeSlab, h::SlabHandle, i::Int, child::SlabHandle, ::Type{V}) where {V} =
    slab_store!(s, _dbn_ebase(h, i, V), child)
@inline dbn_new!(s::NodeSlab, ::Type{V}) where {V} = dbn_pack!(s, ByteMask(), DBNEntry{V}[])

# Add byte `b` (empty entry) to dense node `h` (relocate, byte-sorted); return (new_handle, index).
function dbn_add_byte!(s::NodeSlab, h::SlabHandle, b::UInt8, ::Type{V}) where {V}
    mask = dbn_mask(s, h)
    ne = dbn_nentries(s, h)
    entries = Vector{DBNEntry{V}}(undef, ne)
    @inbounds for i in 1:ne
        entries[i] = dbn_entry(s, h, i, V)
    end
    newmask = set(mask, b)
    pos = Int(index_of(newmask, b)) + 1
    insert!(entries, pos, DBNEntry{V}(SLAB_NIL, zero(V), false))
    return (dbn_pack!(s, newmask, entries), pos)
end

# Convert list node `h` (+ a new byte) into a dense node; return (dense_handle, index of new byte).
function lln_to_dense!(s::NodeSlab, h::SlabHandle, newbyte::UInt8, ::Type{V}) where {V}
    cnt = lln_count(s, h)
    items = Vector{Tuple{UInt8, SlabHandle, V, Bool}}(undef, cnt + 1)
    @inbounds for i in 1:cnt
        items[i] = (lln_byte(s, h, i, V), lln_child(s, h, i, V), lln_val(s, h, i, V), lln_hasval(s, h, i, V))
    end
    items[cnt + 1] = (newbyte, SLAB_NIL, zero(V), false)
    sort!(items; by = it -> it[1])                       # dense entries are mask (byte) ordered
    mask = ByteMask()
    for it in items
        mask = set(mask, it[1])
    end
    entries = DBNEntry{V}[DBNEntry{V}(it[2], it[3], it[4]) for it in items]
    return (dbn_pack!(s, mask, entries), Int(index_of(mask, newbyte)) + 1)
end

# Tag-dispatched node interface used by SlabTrie (LIST sparse | DENSE high-fan-out).
@inline node_count(s::NodeSlab, h::SlabHandle, ::Type{V}) where {V} = h.tag == TAG_DENSEBYTE ? dbn_nentries(s, h) : lln_count(s, h)
@inline node_find(s::NodeSlab, h::SlabHandle, byte::UInt8, ::Type{V}) where {V} = h.tag == TAG_DENSEBYTE ? dbn_slab_index(s, h, byte) : lln_find(s, h, byte, V)
@inline node_child(s::NodeSlab, h::SlabHandle, i::Int, ::Type{V}) where {V} = h.tag == TAG_DENSEBYTE ? dbn_child(s, h, i, V) : lln_child(s, h, i, V)
@inline node_val(s::NodeSlab, h::SlabHandle, i::Int, ::Type{V}) where {V} = h.tag == TAG_DENSEBYTE ? dbn_val(s, h, i, V) : lln_val(s, h, i, V)
@inline node_hasval(s::NodeSlab, h::SlabHandle, i::Int, ::Type{V}) where {V} = h.tag == TAG_DENSEBYTE ? dbn_hasval(s, h, i, V) : lln_hasval(s, h, i, V)
@inline node_child_off(h::SlabHandle, i::Int, ::Type{V}) where {V} = h.tag == TAG_DENSEBYTE ? dbn_child_off(h, i, V) : lln_child_off(h, i, V)
@inline node_set_val!(s::NodeSlab, h::SlabHandle, i::Int, val::V) where {V} = h.tag == TAG_DENSEBYTE ? dbn_set_val!(s, h, i, val) : lln_set_val!(s, h, i, val)
@inline node_set_child!(s::NodeSlab, h::SlabHandle, i::Int, child::SlabHandle, ::Type{V}) where {V} = h.tag == TAG_DENSEBYTE ? dbn_set_child!(s, h, i, child, V) : lln_set_child!(s, h, i, child, V)
@inline node_new!(s::NodeSlab, ::Type{V}) where {V} = lln_new!(s, V)        # always start sparse
@inline function node_add_byte!(s::NodeSlab, h::SlabHandle, b::UInt8, ::Type{V}) where {V}
    h.tag == TAG_DENSEBYTE && return dbn_add_byte!(s, h, b, V)
    lln_count(s, h) < SLAB_MAXLIST ? lln_add_byte!(s, h, b, V) : lln_to_dense!(s, h, b, V)
end
