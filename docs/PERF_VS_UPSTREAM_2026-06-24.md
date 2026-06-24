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

*Methodology files (ephemeral, this session): `bench_dict*.jl`, `pmcmp/` (Rust), `profile_get.jl`.*
