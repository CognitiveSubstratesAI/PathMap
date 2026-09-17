# Type-stability / allocation audit — 2026-09-17 (after the 0.4.0 zipper API port)

Tools: `JET.@report_opt` (runtime dispatch), the repo's `tools/jet_report.jl` (`@report_call`, type errors),
`Aqua.test_all`, `Profile.Allocs`, and timed workloads (3 runs, median). Probes and logs:
`~/csai-work/gates/audit/{opt_report,alloc_report,static_report,jet_report,aqua,bench_before}.{jl,log}`.

Baseline workload: 5 000 keys `k0001:payload … k5000:payload`, `PathMap{UnitVal}`.

| op | median | bytes |
|---|---|---|
| build (`set_val_at!` ×5000) | 25.2 ms | 10.6 MB |
| walk (`to_next_val!` ×5000) | 9.4 ms | 2.16 MB |
| lookups (`get_val_at` ×5000) | 6.5 ms | 0.82 MB |
| removes (`remove_val_at!` ×5000) | 37.1 ms | 9.18 MB |
| `join_map_into!` | 45.7 ms | 8.44 MB |
| `map_hash` | 56.9 ms | 8.33 MB |

GC time was 0 ms in every run: nothing here is GC-bound at this size. The cost is allocation VOLUME
(pressure that shows up at scale) and dynamic dispatch, not collection pauses.

## Finding 1 — the write path dispatches dynamically; the read path does not

`@report_opt`, counting only frames in `PathMap/src`:

| probe | runtime-dispatch sites |
|---|---|
| read: `to_next_val!` / `to_next_step!` / `descend_to!` / k-path walk | **0** |
| write: `set_val_at!` | 9 |
| write: `remove_val_at!` | 15 |
| `join_map_into!` | 32 |
| `meet_into!` | 35 |
| `map_hash` | 5 |

**Root cause.** The read zipper narrows every node handle through `_fnode` (Zipper.jl:57) to the CLOSED
union `TrieNodeVariant`, so node calls compile to a union-split if-else chain. That helper exists and is
documented ("Fix 1"). The write zipper has no equivalent: `z.focus_stack[k].node` is
`Union{Nothing, AbstractTrieNode{V,A}}` and `as_tagged(rc)` returns an abstract `AbstractTrieNode`, so every
`node_get_child` / `node_contains_val` / `node_remove_all_branches!` on the write side is a vtable lookup.
The same holds for anything reached through `AbstractNodeRef` (`_wz_get_focus_anr`, `get_node_at_key`).

## Finding 2 — six public entry points infer `Any`

`Base.return_types` over the API (`static_report.jl` §4). Every read-zipper method is concrete
(`to_next_val!::Bool`, `descend_first_byte!::Union{Nothing,UInt8}`, `ascend!::Int64`, `path::SubArray`, …).
These are not:

    val_count(::ReadZipperCore)      → Any     REAL, fixed
    val(::WriteZipperCore)           → Any     REAL, fixed
    child_count(::WriteZipperCore)   → Any     REAL, fixed
    remove_val!(::WriteZipperCore)   → Any     REAL, fixed
    get_val_at(::PathMap, key)       → Any     ❌ MY PROBE'S ERROR — see below
    set_val_at!(::PathMap, key, val) → Any     ❌ MY PROBE'S ERROR — see below

🔴 CORRECTION. The last two were an artifact of how I asked. `PathMap{UnitVal}` is a UnionAll — the
ALLOCATOR parameter is still free — so `Base.return_types(get_val_at, (PathMap{UnitVal}, Vector{UInt8}))`
asks about an abstract type and `Any` is the correct answer. On the concrete `PathMap{UnitVal, GlobalAlloc}`
both infer `Union{Nothing, UnitVal}`. They were never unstable. The lesson generalises: when probing
inference, pass `typeof(x)`, never a hand-written type application.

**Root cause of the four real ones.** `val(::WriteZipperCore)`, `child_count(::WriteZipperCore)` and
`remove_val!` end in a node call whose receiver is `Union{Nothing, AbstractTrieNode}` — Finding 1's abstract
handle — so inference gives up at the call and `Any` propagates to the caller. `val_count` is different and
worth separating: it is `Any` because `node_val_count` and `val_count_below_node` are MUTUALLY RECURSIVE
across all six node types and inference abandons the cycle, not because of an abstract receiver.

## Finding 3 — the read walk allocates ~336 B per value although it is type-stable

`Profile.Allocs` over `to_next_val!` ×5000: 83 906 allocation events, 1.68 MB. Attribution:

| site | what |
|---|---|
| `DenseByteNode.jl:1384` `next_items` | a fresh `Vector{UInt8}` (+ its `Memory`) **per item** |
| `LineListNode.jl:1235` `next_items` | `copy(key0)` / `copy(key1)` **per item** |
| `Zipper.jl:888/897/922` `to_next_get_val_observed!` | the returned 4-tuple and the `UInt64` token, BOXED |

**Root cause, two halves.** (a) `next_items` returns a freshly allocated key vector; upstream returns a
borrowed slice — for a byte node, `&ALL_BYTES[k..=k]` into a static 256-byte table (dense_byte_node.rs:1052),
and for a line node the node's own key bytes. Our `UInt8[k]` / `copy(key0)` allocates on every step of every
walk. (b) the four branches of `next_items` return tuples of DIFFERENT concrete types
(`Tuple{UInt64,Vector{UInt8},TrieNodeODRc,Nothing}` vs `…,Nothing,UnitVal}` vs the empty case), so the call
site sees a union of tuple types and boxes both the tuple and the token inside it.

## Finding 4 — `@nospecialize` on the refcount helpers costs a dispatch per COW check

`_has_refcnt` / `_node_refcount` / `_node_inc_refcnt!` / `_node_dec_refcnt!` (TrieNode.jl:431-440) are
`@nospecialize`, so `getfield(n, :refcnt, :acquire)` infers `Any` and both the `Int(...)` conversion and the
`> 1` comparison become runtime dispatches — visible in the audit inside `make_unique!` (TrieNode.jl:543,547)
and `_wz_ensure_write_unique!` (WriteZipper.jl:187,204,213), i.e. on EVERY write.

This is already documented from the other side: `_cow_in_place!` (Zipper.jl:113) exists precisely because
"`@nospecialize` helpers force a real dynamic dispatch", measured there as 42 → 76 ms on `remove_val_at!`
×20 000. The read path got the narrowed-argument treatment; the write path never did.

## Finding 5 — `Any`-typed caches in the catamorphism (the `map_hash` path)

`Morphisms.jl:268` `cache = Dict{UInt64, Any}()`, `:642` `Dict{UInt64, Tuple{Any, Vector{UInt8}}}`,
`:870` `child_ws::Vector{Any}`. The fold result type `W` is fixed per call but is not a type parameter of
the frame/cache, so every cached value is boxed and every read from the cache is `Any`. `map_hash` is the
heaviest op measured (56.9 ms / 8.33 MB for 5 000 keys). CLAUDE.md's own rule bans `Vector{Any}` in hot
paths; `DependentZipper.jl:38` records the same fix being applied there earlier.

## Finding 6 — 140 JET type-error reports, all one known structural class

`tools/jet_report.jl` over 10 algebra entry points: restrict! 19, meet_into! 21, subtract_into! 21,
join_map_into! 20, graft_map! 20, join_k_path_into! 21, prestrict_dyn 12, remove_val! 2, take_map! 2,
`_wz_prune_path_internal!` 2. Every one is `no matching method f(::Nothing)` from a `Union{Nothing,T}` field
whose validity is carried by a separate tag bit (`slot0`/`slot1` + `is_child_0`, `TrieNodeODRc.node`), which
JET cannot correlate. The file's header already documents the class and the honest fix (a typed slot
representation, not scattering `f(::Nothing)` methods that would mask invariant violations).

⚠️ The count has grown 74 → 140 since the header was written (2026-08-01), partly because it now probes 10
entry points rather than 8. Treat 140 as the new baseline; a NEW shape here is still worth investigating.

## Aqua — clean

`Aqua.test_all(PathMaps)` passes: no method ambiguities, no type piracy, no undefined exports, no stale deps.

## Not a finding: GC

No measured GC pause in any workload (0 ms in every run at 5 000 keys). Allocation reduction is worth doing
for throughput and for scaling, not because collection is currently hurting.

## What was fixed, and what it measured

(details below the table)

## Fix order (by measured cost, cheapest first)

1. Narrow the write-zipper node handles (Findings 1, 2) — one accessor, mirroring `_fnode`.
2. Give the refcount helpers a specialised path (Finding 4) — the `_cow_in_place!` treatment.
3. Make `next_items` return borrowed slices and one concrete tuple type (Finding 3).
4. Parameterise the catamorphism caches on `W` (Finding 5).
5. Re-baseline `tools/jet_report.jl`'s header count, and repair `benchmarks/benchmarks.jl`, which is stale:
   it still says `using PathMap` (pre-rename) and `PathMap{Nothing}` (pre-UnitVal), so it cannot run.


---

# Results (same day)

## Fixed

**`as_tagged` now narrows (Findings 1 and 2).** `src/nodes/NodeVariant.jl` is new: it holds the closed node
union `TrieNodeVariant`, `_fnode`, and BOTH `as_tagged` methods, moved out of `TrieNode.jl` because the union
can only be written after the last node type exists. `as_tagged` asserts into the closed union, so everything
reached through it union-splits instead of dispatching. Seven `z.focus_stack[end].node` reads in the write
zipper now go through it as well.

**The recursive value count is annotated `::Int`.** `node_val_count` (all node types), `val_count_below_node`
and `val_count_below_root` are mutually recursive across six types; inference gave up on the cycle and
returned `Any`, which propagated out through `val_count`.

| metric | before | after `as_tagged` | after refcount (Finding 4) |
|---|---|---|---|
| runtime-dispatch sites over 9 entry points | 96 | 62 | **41** |
| `set_val_at!` | 9 | 9 | **4** |
| `remove_val_at!` | 15 | 6 | **2** |
| `join_map_into!` | 32 | 20 | 17 |
| `meet_into!` | 35 | 22 | 19 |
| public API inferring `Any` (real cases) | 4 | **0** | 0 |

**`next_items` returns a borrowed slice (Finding 3, partly).** Every method now returns `NodeKeySlice`
(a view) instead of a freshly allocated `Vector` — a byte node slices the static `ALL_BYTES` table as upstream
does. The 5 000-value walk went **83 901 → 72 898 allocations**, and AllocCheck's static site count for
`to_next_val!` 42 → 37.

**The refcount helpers get a specialised path (Finding 4).** `_has_refcnt` / `_node_refcount` /
`_node_inc_refcnt!` / `_node_dec_refcnt!` now have methods taking `::TrieNodeVariant` (NodeVariant.jl), so
Julia union-splits, `hasfield(typeof(n), :refcnt)` folds per concrete type, and the atomic read is a plain
field load. The `@nospecialize` methods stay in TrieNode.jl as the fallback for genuinely abstract call
sites. `make_unique!` and `refcount` were changed to go through `as_tagged(rc)` so they reach the specialised
methods. This is what took the write path from 62 to 41 dispatch sites — `set_val_at!` 9 → 4 and
`remove_val_at!` 15 → 2 are almost entirely this fix, because the COW check runs on every write.

**The catamorphism caches are parameterised on the fold type (Finding 5).** `_cata_cached!` gained a trailing
`::Type{W} = Any` parameter; `children = W[]` and `cache = Dict{UInt64, W}()` replace the `Any` containers, and
a new public `cata_cached(m, alg_f, ::Type{W})` lets a caller state the fold type. `map_hash` passes
`UInt128`. Measured over 5 000 keys: **234 703 → 229 146 allocations**. The default stays `Any`, so existing
callers keep working unchanged and pay what they paid before.

`_cata_ascend_to_fork!`'s own allocations (`opath = copy(origin_path(z))` 45 559, `z_children = [w]` 40 003)
were left alone DELIBERATELY: both objects are handed to the user-supplied fold function, so reusing a buffer
would alias whatever that function retains.

**`benchmarks/benchmarks.jl` runs again (fix-order item 5).** It was dead code: `using PathMap` (pre-rename),
`PathMap{Nothing}` (pre-UnitVal), `deserialize_paths(m, io, true)`. It now takes `PathMaps.PathMap{UnitVal}`,
reports `minimum` time plus allocation and byte counts, and exposes `run_benchmarks(; tune=false)` so it can be
included into a warm daemon instead of only running as a script. Baseline
(`~/csai-work/gates/audit/bench_repaired.log`):

| group | op | min | allocs |
|---|---|---|---|
| word_index | build / lookup_hit / iterate_all | 1.185 ms / 237 ns / 35.98 µs | 17543 / 1 / 481 |
| construction | sparse_1k / dense_1k | 1.508 ms / 1.952 ms | 33518 / 33143 |
| serialization | serialize_500 / deserialize_500 | 658.4 µs / 923.8 µs | 6430 / 15065 |
| algebra | union / policy_sum / subtract | 42.56 / 35.49 / 38.40 µs | 214 / 454 / 495 |
| morphisms | cata_count / cata_paths / map_hash | 405.6 / 324.4 / 342.7 µs | 3802 / 2031 / 2674 |

**Coverage reaches Codecov (fix-order item 5).** All seven repos' `.github/workflows/CI.yml` gained
`julia-actions/julia-processcoverage@v1` + `codecov/codecov-action@v5` (`files: lcov.info`,
`token: secrets.CODECOV_TOKEN`, `fail_ci_if_error: false`) after the `julia-runtest` step.

## 🔴 A REGRESSION THIS AUDIT CAUSED, AND HOW IT WAS CAUGHT

Narrowing the read at `remove_val!` cost **18 fuzz cases** (2995 → 2977). `node_remove_val!(::Nothing, …)`
returns `nothing` ("there was no value") but `node_remove_val!(::EmptyNode, …)` ERRORS as unreachable
(EmptyNode.jl:56) — the sentinel and `EmptyNode` are NOT interchangeable for that callee. I had checked that
an `::EmptyNode` method *existed* by grepping, without reading its body. The site is reverted with a comment;
the other six narrow safely because both of their methods agree. Lesson: for this refactor, method EXISTENCE
is not equivalence — read the body.

## Measured but NOT adopted

- **Guarding the observer slices** (`obs === nothing || descend_to!(obs, view(...))`, to avoid building an
  argument that a no-op observer discards): allocations went **72 898 → 83 901**. Reverted.
- **`no_key()` in `to_next_get_val_observed!`'s exhausted branch** (for tuple-type uniformity): same
  regression, 72 898 → 83 901. Reverted; that branch keeps `UInt8[]`.

Both were measured twice on a freshly restarted daemon. Allocation counts are deterministic per code version,
which is why they, not timings, decided these.

## ⚠️ Timings on this box are currently unusable

Identical workloads varied 3-4× run to run (`build` 24 / 68 / 35 ms; `map_hash` 39 / 89 / 98 ms) with other
jobs on the machine. `BenchmarkTools.minimum` is steadier but still moved ±40% across daemon restarts. Every
claim above therefore rests on ALLOCATION COUNTS and STATIC DISPATCH SITES, both deterministic. Re-run
`~/csai-work/gates/audit/bt_bench.jl` on a quiet box before quoting any speed number.

## Still open

1. The remaining ~73 k allocations in a 5 000-value walk are structural: `next_items` returns a 4-tuple whose
   fields are pointers (the slice, `Union{Nothing,TrieNodeODRc}`, `Union{Nothing,V}`), so the tuple itself is
   heap-allocated, and the zipper's `ancestors` stack pushes a tuple with a `Union` field per descent. Removing
   them means changing the node interface (write the item into caller-owned buffers) or splitting `ancestors`
   into parallel arrays — both bigger than this pass.
2. The 41 remaining dispatch sites are concentrated in `join_map_into!` (17) and `meet_into!` (19), where the
   node pairs come out of `AbstractNodeRef` slots whose validity is a separate tag bit — the same
   representation problem as Finding 6. Fixing it means a typed slot, not another assertion.
3. `_cata_ascend_to_fork!`'s per-fork `copy(origin_path(z))` + `[w]` (85 k allocations over 5 000 keys) —
   left deliberately, see above. Removing them needs a fold interface that states whether the callee may
   retain its arguments.
4. Finding 6's 140 JET type-error reports: baseline re-recorded, class unchanged.
5. Codecov is wired but has not yet reported — the first run lands on the next push to each repo.
