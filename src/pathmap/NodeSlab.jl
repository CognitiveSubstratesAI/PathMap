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
