# ADR-001: Flat-index node storage (`Memory{T}` slab) for isbits `TrieNodeODRc`

**Status:** Proposed (successor to the `perf/index-based-descend` allocation work)
**Date:** 2026-06-24
**Context branch:** `perf/index-based-descend` · **Scope:** separate branch + review cycle

## Context

The `perf/index-based-descend` arc eliminated the *cheap* read-path overhead (escaping views, slice
copies, `Union`-tuple boxing) and ~halved the Julia-vs-upstream-Rust gap (get-latency 4903 → 2560 ns,
24× → 12.5×; see `PERF_VS_UPSTREAM_2026-06-24.md`). But a controlled cache sweep — **constant key
depth, only the trie size growing** — shows the dominant remaining cost is *not* per-op code:

| trie size (constant depth) | get-latency |
|---|---|
| 1k (cache-resident) | **864 ns** (≈ 4× Rust — the compute floor) |
| 30k | 2342 ns |
| 200k | 3357 ns |
| 1M | **8742 ns** (≈ 43× Rust) |

A **10× swing from cache pressure alone**. The cause: PathMap nodes (`LineListNode`, `DenseByteNode`,
`BridgeNode`, `TinyRefNode`) are **mutable structs** — each is an individually GC-allocated heap
object, scattered across the heap. Every descend step chases a pointer to an object that is likely a
cache miss. Rust's `pathmap` gets contiguity + value-type enums "for free" from `Allocator` + node
enums; we pay GC-object + pointer-chase costs it doesn't.

A second consequence of the same root cause: because `TrieNodeODRc` is a **mutable struct**, it is
**not `isbits`**, so any `Tuple{Int, TrieNodeODRc}` is not `isbits` and **heap-boxes on return**
(the Cluster-3 cost; worked around tactically with nullable-pointer returns, but not eliminated).

`bounds-check` analysis (`--check-bounds=no`) showed bounds checks are *not* a material factor at
realistic sizes — confirming the gap is memory layout, not codegen.

## Decision

Replace the mutable-struct + heap-reference node model with an **immutable index handle into a
per-`PathMap` `Memory{T}` node slab** (Julia ≥ 1.11):

- `TrieNodeODRc{V,A}` becomes an **immutable** struct wrapping a `UInt32`/`UInt64` index (+ a tag)
  into a contiguous `Memory{PathNode}` (or per-type slabs) owned by the `PathMap`.
- Nodes are stored **contiguously** in the slab; traversal indexes the slab instead of chasing GC
  pointers → cache-friendly, prefetchable.
- With `TrieNodeODRc` `isbits`, `Tuple{Int, TrieNodeODRc}` is `isbits` → the descend/`node_get_child`
  tuples live on the stack → **fully zero-alloc** reads (closes Cluster 3 + the residual).

## Consequences

**Benefits**
- Addresses the *dominant* measured cost (cache locality) — the only lever that moves the 12.5×→~?
  gap at scale, not just the ~4× compute floor.
- Fully zero-alloc reads (isbits node handles).
- Unlocks, on the same representation: **`arena_compact`** (the slab *is* the ACT layout — mmap to
  disk for out-of-core tries; already measured 4× faster than the in-RAM trie for reads),
  **structural sharing** via shared index ranges, and **lock-free snapshot reads**.

**Costs / risks**
- A full redesign of the **node ownership model** — every node type's storage, the COW/refcount
  machinery, the zipper layer's node references, and serialization all change.
- Slab growth/compaction + free-list management (the allocator role moves into PathMap).
- Careful migration: the existing extensive test suite must stay green throughout; do it node-type by
  node-type behind the slab abstraction.

## Scope boundaries

- **In a dedicated branch + review cycle.** NOT part of `perf/index-based-descend`.
- Do **not** land stubs, type aliases, or placeholder `Memory{T}` types in the current PR branch.
- The "flat array store" framing is the **target** state — PathMap nodes are *currently* scattered
  heap objects, not a contiguous array. This ADR is the plan to get there.

## Alternatives considered

- **More allocation micro-opts** (continue Cluster 2/3 polishing): rejected as the primary path —
  the cache sweep shows the read path is now cache-bound; further alloc cuts barely move latency
  (Cluster 2 moved 200k get 2560→2588 ns, within noise).
- **jemalloc-style allocator tuning**: Julia's GC *is* the allocator; no per-collection arena hook
  like Rust's `Allocator`. The slab redesign is the Julia-idiomatic equivalent.

## References

- `docs/PERF_VS_UPSTREAM_2026-06-24.md` — the full benchmark + profile + the cache sweep.
- `benchmarks/profile_get_val.jl` — reproducible BenchmarkTools/Profile/@code_typed harness.
- `src/pathmap/ArenaCompact.jl` — the existing read-only ACT slab (4× faster reads) — the prototype
  of the target layout.
