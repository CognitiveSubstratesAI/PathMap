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
