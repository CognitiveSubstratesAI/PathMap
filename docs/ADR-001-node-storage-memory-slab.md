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
- **AOT / StaticCompiler eligibility.** With `isbits` node handles, the inner descent loop becomes a
  flat indexed loop over a `Memory{T}` slab with **no GC interaction** — exactly the profile
  StaticCompiler.jl can lower to native code with zero Julia runtime. The path
  current → `Memory{T}` → StaticCompiler is validated at each step by *existing* measurements (the
  ACT slab already runs this layout), not theory.

**Lower-risk than it looks:** this is **not** a green-field design. The contiguous-slab layout
already exists and is measured — `src/pathmap/ArenaCompact.jl` (the read-only ACT, 4× faster reads).
ADR-001 is "promote the existing working layout to the primary representation," not "invent a new
one." That materially de-risks the redesign.

**Costs / risks**
- A full redesign of the **node ownership model** — every node type's storage, the COW/refcount
  machinery, the zipper layer's node references, and serialization all change.
- Slab growth/compaction + free-list management (the allocator role moves into PathMap).
- Careful migration: the existing extensive test suite must stay green throughout; do it node-type by
  node-type behind the slab abstraction.

## Validation (increment 1, 2026-06-24) — the premise is confirmed in code

A minimal **writable** slab trie (`src/pathmap/SlabTrie.jl`, dense-byte-only, no compaction / no
free-list / no COW yet) was built and proven `≡ Dict` over 3000 random inserts, then benchmarked
against the mature mutable `PathMap` on identical keys:

| N (constant 15B keys) | `PathMap.get_val_at` | `SlabTrie.get` | speedup |
|---|---|---|---|
| 1k | 779 ns | **229 ns** | 3.4× |
| 30k | 2409 ns | **598 ns** | 4.0× |
| 200k | 3803 ns | **983 ns** | 3.9× |
| allocations / lookup | 4 / 140 B | **0 / 15 B** | zero-alloc |

**Even unoptimized, the slab trie is 3.4-4× faster and zero-allocation** — at 200k it matches the
mutable trie's *cache-resident* (1k) latency. Then **DFS-pre-order locality compaction**
(`slabtrie_compact!`) was added and measured:

| N | `PathMap` | SlabTrie raw | **SlabTrie compacted** | slab mem (→) |
|---|---|---|---|---|
| 1k | 667 ns | 206 ns | **183 ns** | 0.9→0.4 MB |
| 30k | 2303 ns | 833 ns | **433 ns** | 20.4→10.2 MB |
| 200k | 3401 ns | 949 ns | **589 ns** | 129.7→62 MB |

Compaction is 1.6-1.9× faster than raw at scale, **flattens the cache-swing 4.6×→3.2×**, and
**halves memory** (drops the append-only leaks). Net: the compacted dense-byte slab trie is 5.8×
faster than the mutable `PathMap` at 200k and **~2.9× Rust** (589 vs 205 ns), from the mutable trie's
~12-18×.

**Increment 2 — sparse LIST nodes (no 32-byte mask; O(count) scan)** replace the dense node on the
same writable trie:

| N | `PathMap` | SlabTrie (list, compacted) | slab mem | `PathMap` RAM |
|---|---|---|---|---|
| 1k | 663 ns | **100 ns** | 0.2 MB | 0.2 MB |
| 30k | 2485 ns | **346 ns** | 3.8 MB | 5.8 MB |
| 200k | 3781 ns | **449 ns** | 23 MB | 38 MB |

On real (sparse) tries the linear scan is over 1-2 entries — *cheaper* than a 32-byte mask load — so
list nodes beat dense (449 vs 589 ns at 200k) **and halve memory**. Net at 200k: **8.4× faster than
the mutable `PathMap`, ~2.2× Rust, and 40% less RAM (23 vs 38 MB)** — **the redesign now beats the
mutable trie on BOTH speed and memory.** **The ADR thesis is decisively confirmed: contiguous
isbits-handle node storage + locality layout + a compact sparse node closes most of the Julia-vs-Rust
gap on both axes.**

The node-type story is then completed by a **HYBRID dispatch**: nodes start as compact LIST nodes and
a node that exceeds `SLAB_MAXLIST` (16) children converts to a DENSE (mask, O(1)) node — so
high-fan-out nodes don't degrade to a long scan, while the common sparse nodes keep the list win. The
tag branch is predictable (most nodes are list) ⇒ **no hot-path regression** (200k still ~2.2× Rust,
23 MB), now robust across any fan-out distribution.

## Critique / corrections — what this PoC does and does NOT establish (2026-06-24)

Expert review after increment 2. The thesis, the additive `≡ Dict`-gated isolation, the hybrid
list/dense design, and the DFS-compaction insight are all endorsed and carry forward unchanged. **Two
corrections must be applied before any integration:**

1. **`Memory{UInt8}` is a PoC shortcut, NOT the production primitive.** What landed is a raw byte
   arena with manual `slab_store!`/`slab_load` + per-field byte-offset arithmetic — it bypasses the
   type system in the hot path (loses SROA + compiler field reasoning) and is error-prone exactly at
   the `parent_coff` relocation backpatch (one wrong `sizeof` silently corrupts the trie). It is the
   **read-only ACT (`ArenaCompact.jl`) serialization format mirrored into a *writable* structure** —
   right for immutable mmap, wrong for mutation+backpatch. Integration must instead use **typed
   `Memory{T}` per node type**, or (preferred) a **two-level layout**: `Memory{NodeHeader}` (typed,
   O(1) field access) + a `Memory{EntryRecord}` pool with a bump allocator (byte arithmetic confined
   to one place). Decide this **before** integration, not after.

2. **Integration has NOT started — the "remaining work" below is the MAJORITY of the work, not a
   tail.** SlabTrie is a *simplified* node model: **single-byte edges only.** It does **not** have
   PathMap's `LineListNode` (variable-length keys / path compression, `klen>1` — packing a varlen key
   field into the slab is an *unsolved* design problem), nor `BridgeNode`/`TinyRefNode`, nor **COW**,
   nor **structural sharing**. The 8.4× is on a **tree** with none of that machinery. Structural
   sharing changes compaction *categorically* (a DAG needs shared-node dedup, not the PoC's tree DFS
   relayout). **Validated:** storage substrate + node-layout principles + speed ceiling. **NOT
   validated:** zippers, COW, structural sharing.
   *(Naming caveat: the PoC's `TAG_LINELIST` is a sparse single-byte-branch node, NOT PathMap's
   path-compressing `LineListNode` — a borrowed name to rename in integration.)*

**Remaining = the integration endgame, GATED on a new ADR.** COW + structural sharing in a slab model
is the genuinely hard design problem; it gets **ADR-002 (COW + structural sharing in the slab)** before
a line of integration code. Then: typed/two-level storage, the full node set (LineList path
compression, Bridge, TinyRef), zipper mutation model, and the swap-vs-parallel-map decision
(replace `PathMap` internals, or ship `SlabTrie`/`SlabPathMap` as a standalone high-perf map first).

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
