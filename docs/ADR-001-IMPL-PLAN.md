# ADR-001 implementation plan — increment 1: slab abstraction + `DenseByteNode` migration

Branch `feat/node-slab-adr-001`. Implements ADR-001 (Memory{T} flat-index node storage) one node
type at a time, suite green at each step. This doc is the executable design for **increment 1**.

## The pattern (already prototyped by the ACT)

`src/pathmap/ArenaCompact.jl` is the working reference: `struct ACT_NodeId` is an immutable index
handle, and `act_read_node(data, node_id)` threads the slab (`data`) + handle to read a node.
ADR-001 generalizes this from the read-only ACT to the **primary, writable** representation.

The core shift: `TrieNodeODRc` stops being a mutable heap reference and becomes an **immutable
isbits handle** (index + tag) into a per-`PathMap` slab; node operations **thread the slab**.

```julia
# Target (mirrors ACT_NodeId + act_read_node):
struct TrieNodeODRc{V,A}            # immutable ⇒ isbits ⇒ Tuple{Int,TrieNodeODRc} stack-allocates
    idx::UInt32                     # index into the slab
    tag::UInt8                      # node-type tag (LineList / DenseByte / Bridge / TinyRef)
end
mutable struct NodeSlab{V,A}        # owned by the PathMap (the "allocator" role moves here)
    bytes::Memory{UInt8}            # or a typed Memory per node kind; contiguous, cache-friendly
    len::UInt32
    free::Vector{UInt32}            # free-list for reuse (COW/remove)
end
```

The node API changes from `node_get_child(node, key)` → `node_get_child(slab, handle, key)` — the
slab is threaded exactly as the ACT threads `data`.

## Key design decision: how the handle stays isbits

An isbits handle **cannot** hold a heap reference to its slab. Two viable options:
1. **Thread the slab** through every node op (chosen — this is what the ACT already does;
   `PathMap` owns the slab and passes it down the descent). Zero unsafety, clean.
2. Raw `Ptr` to the slab data inside the handle — isbits but unsafe; rejected unless threading proves
   too invasive for the zipper layer.

Decision: **thread the slab** (option 1). It matches the prototype and keeps everything safe.

## Increment 1 steps (each ends with the FULL suite green)

1. **Slab scaffold.** Add `NodeSlab{V,A}` + an immutable `TrieNodeODRc` handle alongside the
   current types (do NOT remove the mutable ones yet). New tag enum. No behavior change.
2. **`DenseByteNode` in-slab repr.** Define the byte-node's fields as a packed record in the slab;
   `dbn_alloc!(slab, ...) → handle`, `dbn_read(slab, handle)`. Unit-test the round-trip.
3. **Dual-path dispatch.** Make `_fnode`/`_rc_inner` + `node_get_child`/`node_get_val` accept the
   slab and dispatch on the handle tag → slab-backed `DenseByteNode` OR (still) the mutable types.
   Thread the slab through `node_along_path_off` + `node_get_child_nb`.
4. **Build DenseByteNode tries on the slab.** `set_val_at!`/grafts that create byte nodes allocate
   in the slab. Keep LineList/Bridge/TinyRef on the old path for now (mixed tries must work).
5. **Gate.** Full suite green + AllocCheck on `get_val_at` over a byte-node-only trie shows the
   `Tuple{Int,TrieNodeODRc}` site is **gone** (isbits handle) + `benchmarks/profile_get_val.jl`
   shows the cache sweep flattened for byte-heavy tries. Record the delta.

## Then iterate (increments 2-4)
`LineListNode` → `BridgeNode` → `TinyRefNode`, same recipe; finally retire the mutable structs +
the dual-path dispatch. COW/refcount + the zipper layer's node refs migrate with each type.

## Risk controls
- **One node type per increment, suite green each time** — never batch.
- Keep the mutable path alive until ALL types are migrated (mixed tries must pass throughout).
- The COW/refcount machinery is the sharp edge — migrate it explicitly per type, with the existing
  COW tests as the gate (`test/` already covers structural sharing).
- If slab-threading proves too invasive for the zipper layer, reassess option 2 (Ptr handle) before
  proceeding — do not force it.

## Success criteria (increment 1)
- Full suite green.
- AllocCheck: `node_get_child` `Tuple{Int,TrieNodeODRc}` box **gone** on byte-node tries.
- Cache sweep (`benchmarks/profile_get_val.jl`, byte-heavy): the 864→8742 ns size-swing **flattens**.
- No regression for LineList/Bridge/TinyRef tries (still on the mutable path).
