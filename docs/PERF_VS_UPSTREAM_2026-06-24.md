# PathMap.jl vs upstream Rust pathmap — performance comparison & optimization plan (2026-06-24)

Apples-to-apples micro-benchmark of the Julia port against upstream Rust `pathmap` (`27d9b09`,
edition 2024), same keys (200k `cat<NNN>:<8 random>` byte keys) and same operations, plus a
profile of the Julia hot path. Goal: a fair Julia-vs-Rust delta and a concrete optimization list.

## Configs (fair = upstream's *recommended* build)

- **Rust**: `rustc 1.98-nightly`, `--features nightly,jemalloc`, `RUSTFLAGS=-C target-cpu=native`.
  This is upstream's intended config: on nightly `GlobalAlloc = std::alloc::Global` → routes node
  `Box`es through `#[global_allocator] = jemalloc` (pathmap declares it under the `jemalloc` feature);
  `nightly` enables `allocator_api` + better SIMD. **No custom arena** — every upstream bench uses
  `PathMap::new()`, and the `Allocator` bound requires `Send + Sync` (so `bumpalo::Bump`, being
  `!Sync`, won't even compile). **jemalloc *is* pathmap's arena strategy** (per-thread arenas +
  size-class pooling) — which is exactly why upstream recommends it instead of a bespoke bump arena.
- **Julia**: `julia 1.12`, `PathMap{Int32}`, min-of-trials, `const` data.

## Results

| Operation | **Julia PathMap** | Julia `Dict` | **Rust PathMap** | Rust `HashMap` | **Julia ÷ Rust** |
|---|---|---|---|---|---|
| point-get (varied) | 4903 ns | 153 ns | **205 ns** | 87 ns | **24×** |
| insert (build 200k) | ~9800 ns/ins | 171 ns | **404 ns/ins** | 172 ns | **24×** |
| prefix-scan (count under prefix) | 159 µs | 23,246 µs | **7.4 µs** | 3,950 µs | **21×** |
| **PathMap ÷ its language's hash baseline** | **32×** | — | **2.35×** | — | — |

### Reading the table
- **Upstream Rust PathMap is ~2.35× a `HashMap` on point-get** — i.e. competitive as a near-KV store
  (confirms the community "MORK ≈ dict" finding *at the source*, with its real build).
- **Our Julia port is ~21-24× behind upstream Rust PathMap** on every op. This is the honest gap.
- **No semantic deviation** — prefix counts agree exactly (port is faithful); the gap is purely
  constant-factor.
- **The structural advantage holds in both** — Rust prefix-scan beats a HashMap O(N) scan by **536×**,
  Julia by **147×**; the trie's reason to exist is real regardless of language.
- nightly+jemalloc only bought ~11% over stable+system-alloc, single-threaded — jemalloc's real win
  is multi-threaded scaling (not measured here).

## Profile of the Julia hot path (`get_val_at`)

Measured on the Julia port (`@allocated`, `@code_warntype`, JET `@report_opt`):

| signal | value |
|---|---|
| **allocation / lookup (miss)** | **352 bytes** |
| **allocation / lookup (hit)** | **464 bytes** |
| dynamic dispatch (JET `@report_opt`) | **none** ("No errors detected") |
| return type | `Union{Nothing, Int32}` |

**The killer is allocation, NOT dispatch.** Rust `get_val_at` is zero-allocation pointer traversal;
the Julia port heap-allocates **352–464 bytes on every lookup**, paying GC overhead per descend.
(Earlier hypothesis of "dynamic dispatch / boxing" was wrong — JET shows the small `Union`s are
union-split with no dispatch; the cost is allocation.)

### Allocation sources (file:line), from `lib/.../PathMap.jl:82-95` + `@code_warntype`
1. **`node_along_path(...)` — `PathMap.jl:87`** returns
   `Tuple{Union{Nothing,TrieNodeODRc}, Union{SubArray,Vector{UInt8}}, Union{Nothing,V}}`. The
   `remaining` is a `SubArray` **view** and the tuple has `Union` fields → heap-allocated per call.
   *(This is the base ~352 bytes — hit on every lookup, miss or hit.)*
2. **`collect(UInt8, remaining)` — `PathMap.jl:94`** copies the remaining path into a fresh `Vector`
   on the value-slot (Phase-2) path → a second allocation.
3. **`Union{Nothing, V}` return** — boxes the value on a hit (~the +112 bytes hit-vs-miss delta).

## Optimization plan (ranked, read path)

1. **Make `node_along_path` allocation-free + type-stable** *(biggest win — kills the ~352 B base)*.
   Return an **integer index** into the original `path` instead of a `SubArray` view, and avoid the
   `Union`-field tuple (return concrete fields / use a small mutable scratch or multiple returns).
   Mirrors Rust's index-based descend.
2. **Drop the `collect(UInt8, remaining)` copy — `PathMap.jl:94`**. Pass `remaining` as a
   `@view`/range into `path_v`; `node_get_val` should accept a view, not own a copy.
3. **De-box the return** where the caller can use a sentinel — minor (~112 B), but compounds.
4. **Write path (`set_val_at`) — separate profile needed**: expect the same view/tuple allocations
   *plus* per-node `mutable struct` GC allocation (Rust arena-allocates nodes via the `Allocator` API;
   Julia mutable-struct nodes are individual GC objects). The Julia-idiomatic fix is an **index-based /
   struct-of-arrays node pool** — which the `.act` arena format already proves out: in this same
   bench, querying the mmap'd `.act` arena ran at **423 ns vs 1703 ns for the in-RAM trie (4× faster)**,
   because the flat arena is cache-friendly instead of pointer-chasing GC objects.

## Bottom line

The 24× gap is **language-structural, not a porting bug** (faithful behavior; jemalloc already covers
the allocator axis upstream uses). It is **addressable**: the read path is dominated by ~352-464 B of
per-lookup allocation from a `SubArray`-view + `Union`-tuple in `node_along_path` and a `collect` copy —
none of which Rust pays. Eliminating per-lookup allocation (index-based descend, view-not-copy) is the
highest-leverage work, and an index/SoA node pool (the `.act` arena layout, already 4× faster for reads)
is the write-path follow-on.

## Optimization #1 — IMPLEMENTED (index-based, allocation-free descend)

Branch `perf/index-based-descend`. Added `node_along_path_off` (Zipper.jl) — returns the byte
**offset** consumed instead of a `SubArray` view of the remaining key — and switched `get_val_at`
to it + a `view` instead of `collect(UInt8, remaining)`.

| metric | before | after |
|---|---|---|
| allocation / lookup (hit) | 464 B | **224 B** (−52%) |
| allocation / lookup (miss) | 352 B | **160 B** (−55%) |
| **point-get (200k varied keys)** | **4903 ns** | **3998 ns** (−18%) |
| Julia ÷ Rust PathMap | 24× | **19.5×** |
| `@code_warntype` instability lines | 3 | 2 (the `Union{SubArray,Vector}` is gone) |

Full PathMap test suite green. The `Union{SubArray,Vector}` remaining-key instability + the escaping
view + the `collect` copy are eliminated.

### Road to zero-alloc (AllocCheck.jl)
`check_allocs(get_val_at, …)` reports the residual sites precisely:
- **`_ensure_root!` (PathMap.jl:31)** — lazy root init; *not* hit on a populated map (static-only).
- **`indexed_iterate` at the `last_rc, off, val = …` destructure (PathMap.jl:87)** — `val::Union{Nothing,V}`
  tuple field → `jl_get_nth_field_checked` boxes. Fix: return node+offset and look up the value
  separately, or annotate field access.
- **`node_get_child` returning `(consumed, next_rc)` tuples** (DenseByteNode.jl:1083, LineListNode, …)
  + the internal `view(path, off+1:n)` per descend step. Fix: pass `(path, offset)` into the node
  accessors instead of a view, and return via out-params / a small isbits struct — a deeper,
  cross-node refactor. This is what stands between −52% and zero.

### Data-driven ranking of the remaining work (`benchmarks/profile_get_val.jl`)
`BenchmarkTools` + `Profile` (statistical self-time) + `@code_typed` rank the residual cost, so the
deep refactor is driven by measurement. Current state: **10 allocs / 320 B** per lookup. Top
self-time frames over 3e6 lookups:

| rank | hot spot (self-time samples) | cause | fix |
|---|---|---|---|
| **1** | `node_get_child` tuple return — DenseByteNode:1083 (893) + LineListNode:776 (357) | `(consumed,next_rc)` boxes in the `Union{Nothing,Tuple{Int,TrieNodeODRc}}` return (`TrieNodeODRc` mutable ⇒ non-isbits ⇒ the `Tuple` heap-boxes in the `Union`) | union-free sentinel return (26 sites × 4 node types) |
| **2** | `indexed_iterate` (579) + `node_along_path_off` return Zipper:135 (272) | the `Union{Nothing,V}` val field of the descend return tuple | return node+offset; look up val separately |
| **3** | `SubArray`/`Array` `similar`/`getindex` (≈150-180) | per-iteration `view(path, off+1:n)` feeding `node_get_child` | pass `(path, offset)` into the node accessors |

`node_get_child`'s union-tuple return (#1) is both the largest allocation *and* the largest self-time
sink — the highest-leverage target for the deep refactor. Reproduce with `benchmarks/profile_get_val.jl`.

## Optimization #2 — IMPLEMENTED (non-boxing `node_get_child_nb`)

Attacked the data-ranked #1+#2+#3 targets in the read hot path with `node_get_child_nb` (Zipper.jl,
one method per node type + a fallback): takes `(path, off)` (no per-iteration `view`), compares the
prefix in place (no `key[1:klen]` slice copy), and returns `Tuple{Int, Union{Nothing,TrieNodeODRc}}`
— a nullable-pointer 2nd field, so the tuple is isbits-representable and stays in registers (no box).
`node_along_path_off` uses it; the Phase-2 remaining slice is materialized as a `view` once. The 25
other `node_get_child` callers are untouched.

| metric | `main` | after #1 | **after #2** |
|---|---|---|---|
| **point-get (200k keys)** | 4903 ns | 3998 ns | **2560 ns** (−48% from main) |
| **Julia ÷ Rust PathMap** | 24× | 19.5× | **12.5×** |
| alloc / lookup (BenchmarkTools, 40k map) | — | 320 B / 10 | **256 B / 8** |
| median (40k map) | — | 1187 ns | **764 ns** (−36%) |

Full PathMap suite green. **Two contained, tested changes roughly halved the gap to upstream Rust.**

## Optimization #3 — IMPLEMENTED (Cluster 2: de-box the descend return)

`node_along_path_off` returned `(node, off, val::Union{Nothing,V})` — the `Union` field made the
tuple non-isbits, so it heap-boxed (AllocCheck Zipper:189) and the `indexed_iterate` destructure
boxed too. Fix: return `(node, off, full::Bool)` — `(ptr, Int, Bool)` is isbits-representable, no box.
`full` (did the descent match the remaining as a child edge → all bytes traversed) carries the
dangling-path signal `path_exists_at` needs; both callers do the value lookup uniformly via
`node_get_val(inner, view(path, off+1:end))`. **AllocCheck 21 → 8 sites; dynamic 256→224 B / 8→7
allocs; suite green** (incl. dangling-path semantics). Time barely moved (40k 764→728 ns; 200k
2560→2588 ns) — confirming the cache-sweep finding that **we are now cache-bound**, so further
allocation cuts have diminishing returns.

**The remaining 8 AllocCheck sites (named, bounded, tracked to ADR-001):**
- `_ensure_root!` (PathMap.jl:31) — lazy root init; never fires on a read of a populated map.
- **`node_get_child_nb` tuple construction — Zipper.jl:127 `(1, cf.rec)` and :132
  `(klen, into_child(n.slot0))`** — the `Tuple{Int, Union{Nothing,TrieNodeODRc}}` return. Opt #2
  made it a nullable-pointer (no *outer* box) but the tuple itself still constructs for the non-byte
  node path (`consumed>1`). **These are Cluster-3 remnants that CANNOT be eliminated while
  `TrieNodeODRc` is mutable (non-isbits) — they go to zero only under ADR-001's isbits redesign.**

### `(c-write)` — SUPERSEDED by ADR-001 (not deferred)
The 3 write-path callers of `node_along_path` live in the **mutable-struct node ownership model that
ADR-001 replaces entirely** — the write path is redesigned as part of the slab migration. Migrating
those callers now would target an interface that disappears in the ADR branch. **`(c-write)` is
closed as superseded**, *unless* a write-path benchmark surfaces a real problem before ADR-001 lands.

### The real lever is now the node memory layout (see ADR-NODE-STORAGE)
The cache sweep (constant depth, growing trie) measured get-latency **864 ns @1k → 8742 ns @1M** —
a 10× swing purely from cache pressure on scattered GC mutable-struct nodes. At cache-resident scale
Julia is **~4× Rust** (the compute floor); the rest of the gap *is* cache misses. The
`Memory{T}` flat-index / isbits-`TrieNodeODRc` redesign (ADR) is what addresses it — and as a bonus
makes the node tuples fully isbits (zero-alloc). Allocation micro-opts have taken us as far as they
usefully can.

*Methodology files (ephemeral, this session): `bench_dict*.jl`, `pmcmp/` (Rust), `profile_get.jl`,
`alloccheck_get.jl`; committed: `benchmarks/profile_get_val.jl`.*

## Fresh cross-check 2026-07-06 — LIVE Rust bench + small-N read parity (confirms the above)

Re-ran a live head-to-head after the coref work (which touched MORK, not PathMap — so no read/write-path
change here). **Rust**: `cargo bench --bench binary_keys` on upstream `~/JuliaAGI/dev-zone/PathMap`
(rustup nightly, `--no-default-features --features nightly,graft_root_vals,slim_ptrs` to skip the
libz/cmake serialization dep), divan. **Julia**: fresh `BenchmarkTools`, deterministic 12-byte keys.

| op | Rust pathmap | Julia PathMap | gap |
|---|---|---|---|
| insert (N=200→1600) | 363–482 ns/key | 3.9–5.7 µs/key | **~10–14×** |
| **point-get, cache-resident (N≤4000)** | ~205 ns | **198–352 ns** | **~parity** |
| point-get @ 200k (table above) | 205 ns | 2560 ns | 12.5× |

**The new finding: read is at NEAR-PARITY with Rust when cache-resident** (198–352 ns vs ~205 ns for
N≤4000) — the 12.5× is a pure **scale/cache-scatter** effect (Julia's non-moving GC never compacts the
scattered mutable-struct nodes; the sweep above: 864 ns @1k → 8742 ns @1M). At the compute floor we are
already ~Rust. **The insert ~10–14× gap holds even at small N** — it is node **allocation + dynamic
dispatch** (AllocCheck: `set_val_at!` = 85 allocs + 30 dyn-dispatch/call; Rust arena-allocates + value-type
enums), locked by `test/test_alloc_regression.jl`. Both gaps → the same **ADR-001 isbits `Memory{T}` node
slab** (contiguous storage fixes read-at-scale AND write alloc/dispatch in one), still deferred on
measured-need (PathMap is not the MeTTa-eval bottleneck; the coref join's GC is only 4.5% — see
`~/.claude/.../memory/reference_julia_gc_memory_model.md`). No regression vs 2026-06-24.

## Insert-dispatch win 2026-07-06 (`b38b990`) — type-stability alone buys ~40%, no slab

Testing "does type-stability help the insert gap without the slab?" — YES. AllocCheck attributed
`set_val_at!` = 85 allocs + **30 dynamic dispatches**; the dispatches were on **basic ops** (`length`,
`>=`, `+`, `view`) in the insert hot loop `_wz_descend_to_internal!`, because `TrieNodeODRc.node` is
abstract (`Union{Nothing,AbstractTrieNode}`) → `node_get_child(focus_node, key)` dispatches dynamically
and infers `Any`, cascading. All 4 `node_get_child` methods return exactly
`Union{Nothing,Tuple{Int,TrieNodeODRc}}`, so a **call-site type assertion** (semantic no-op) pins it:

| metric | orig | after descend (`b38b990`) | after sweep (`93b359a`) |
|---|---|---|---|
| set_val_at! dynamic dispatch | 30 | 20 | **17** |
| insert @N=1600 | 5662 ns/key | ~3400 | **~2650** (2878/2657/2628) |
| Julia ÷ Rust insert | ~12× | ~7× | **~6×** |

Two rounds of call-site type assertions (each a semantic no-op re-stating a return type Julia lost when
`TrieNodeODRc.node` was stored abstract): (1) `node_get_child` in the descend loop; (2) `clone_self`
×2 (upstream trait is literally `fn clone_self -> TrieNodeODRc<V,A>`, trie_node.rs:353) + the
`node_set_val!` closure. **−53% insert, no slab, byte-identical** (147 pass / 1 broken pre-existing / 0
fail); floor locked at `test_alloc_regression.jl` (`set_dyn <= 17`). The remaining 17 dispatches +
node-creation allocs are node mutations / the abstract `.node` field → need the isbits node slab
(ADR-001), still deferred. **This confirms the slab's dispatch benefit is real (type-stability alone
halved insert), and shows how far the cheap Julia-idiom fixes reach before the slab is required.**
