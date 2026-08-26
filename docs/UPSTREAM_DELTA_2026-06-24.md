# Upstream PathMap delta — DEFERRED (2026-06-24)

Status: **DEFERRED, not ported.** No current consumer needs it; the substrate is done/tested.
Decision recorded so this is a known, ready-to-pick-up gap — not a silent drift.

## Baseline vs upstream

| | Rust `pathmap` commit | date |
| --- | --- | --- |
| Our Julia port tracks (~baseline) | `0ca5aaa` (`~/dev-zone/PathMap-upstream`) | 2026-05-07 |
| Fresh upstream downloaded | `27d9b09` — PR #38 `rz_path_api_and_fast_multi_branch_graft` (`~/dev-zone/PathMap`) | 2026-06-23 |

Crate version unchanged (0.3.0) across the range. Delta = ~30 commits, **+1616 / −67 across 19 files**
(`git -C ~/dev-zone/PathMap log --oneline 0ca5aaa..27d9b09`).

## What the delta actually is (all NEW functionality + perf — none used by our MORK)

1. **Read-without-moving `_at` API family** (the substantive new surface):
   - `val_at` / `get_val_at` — read a src val without moving the zipper (on `WriteZipperCore`,
     `PrefixZipper`, `ACTZipper`, `TrieRef`; `Zipper::get_val_at` via `TrieRef`).
   - `graft_src_at` — read-access to a src subtrie without moving the src zipper.
   - `get_focus_at` — internal entry point supporting `graft_src_at`.
   - `_at` traversal refactor (`24ee8e3`) to enable future `child_count_at`, etc.
2. **Optimized `graft_masked_branches`** (PR #38 headline) — specialized WriteZipper dispatch,
   range-based `merge_branches_into_byte_node`, CellNode-source support; `merge_branches_into_focus`
   switched from in-place to always-allocate-new-node (`47c5428`).
3. **`utils/mod.rs` (+206)** — `ByteMaskRangeIter`, a `ByteMask` distribution formatter, convenience
   conversions.
4. **`write_zipper`: removed a deprecated API** (`f6dcfe3`) — removal, not an add; optional cleanup.
5. **Pure perf + Rust benchmarks** (`benches/graft_masked_branches.rs` +366, "removing dumb slowness"
   commits) — not portable / not needed in the Julia port.

The only `fix` commits — `4d220cb` (val_at for PrefixZipper), `98042c9` (graft_masked_branches test2 +
get_focus_at temp-buffer) — fix the **new** code above, **not** anything we already ported. Verified
2026-06-24: no correctness fix lands on existing ported functionality.

## Why deferred

- `grep` of the **MORK port** (`~/code/CognitiveSubstratesAI/MORK/src`) for `graft_masked_branches`,
  `val_at`, `graft_src_at`, `get_focus_at`, `child_count_at`, `ByteMaskRangeIter`,
  `merge_branches_into` → **0 references.** Yesterday's MORK upstream sync (sinks/kernel/connectome)
  introduced no dependency on these.
- Substrate is DONE + extensively tested; adding ~1000 lines of unused API is churn-for-zero-runtime-benefit.

## Port trigger (when to pick this up)

Port the relevant slice **the moment a consumer calls it** — i.e. if a future MORK/Core sync starts
using `graft_masked_branches` (fast multi-branch graft) or the `val_at`/`graft_src_at` read API. At
that point port from `~/dev-zone/PathMap` (the fresh `27d9b09` source) 1:1 — read the Rust
first (`src/write_zipper.rs`, `src/zipper.rs`, `src/trie_ref.rs`, `src/prefix_zipper.rs`), skip the
benchmarks + micro-perf opts, and add warm-REPL coverage per new method.

---

## Re-verification 2026-07-06 — extended to current upstream HEAD `233fbba`; STILL DEFERRED

Re-checked after the coref-join became the MORK default (921c05c) — the change that most plausibly
could have made a PathMap op hot. Three layers checked; **conclusion unchanged: nothing to port.**

### (a) The genuinely-new upstream delta `27d9b09..233fbba` is 100% experimental, 0 consumers
`git -C ~/dev-zone/PathMap diff --stat 27d9b09..233fbba` = **one file,
`src/experimental/zipper_algebra.rs` (+2165/−443)** — all 17 commits (DNF clause-merge engine,
XOR→`sym_diff`, majority-of-three, the `ValuePolicy` Cow rewrite, and the `active_bits` iteration
opt saga 9da58e3→revert 9724ca1→8447ab8). It is the **experimental DNF zipper-merge module**. Our
mirror is `src/experimental/ZipperAlgebra.jl` (PR #35 port). `grep` of **MORK/src and Core/src** for
`ZipperAlgebra|zipper_merge|_dnf|DNF` → **0 references.** The `active_bits` opt is internal to that
DNF engine — NOT the core `zipper_child_mask` the coref join uses (that was untouched in this range).
→ Porting it is churn for a module no consumer imports.

### (b) The coref-join default did NOT create a consumer for the PR #38 API
`grep` MORK/src for `graft_masked_branches|val_at|graft_src_at|get_focus_at` → still **0**. Coref
(`Space.jl:_coreferential_transition!`) drives the trie with `zipper_child_mask` / `descend_to_byte` /
`ascend` — none of the read-without-moving `_at` surface. The 2026-06-24 defer holds verbatim.

### (c) Profiled the now-default coref join — PathMap is 6.6% of self-time, NOT the bottleneck
`counter_machine_5.mm2` (5-factor higher-order join, coref default), 12 runs, self-time buckets:

| bucket | self-time | what it is |
|---|---|---|
| libc + GC (malloc/free/memcpy, `gc_page_data`, `jl_gc_alloc_`, `gc_sweep_page`, `box_int64`) | **~52%+37%** | **allocation churn** |
| **PathMap** (`zipper_descend_to_byte!`, `zipper_child_mask`) | **6.6%** | trie traversal |
| MORK (`_coreferential_transition!` DFS driver) | 3.8% | coref inner loop |

Even zeroing **all** PathMap self-time is a ~6% win. The dominant cost is heap-allocation/GC — the
same **node-cache-layout** issue `PERF_VS_UPSTREAM_2026-06-24.md` already root-caused (mutable-struct
nodes ⇒ pointer-chasing GC objects), whose fix is the **ADR-001 `Memory{T}` isbits node slab**,
deliberately deferred ("PathMap not the bottleneck", `57b6bc4`). This fresh coref-join profile
**independently re-confirms that deferral** — the bottleneck is allocation, not any PathMap op
upstream optimized, and definitely not anything in the `233fbba` experimental delta.

### The real perf frontier is now the MORK coref *driver*, not PathMap (separate, measured-need item)
The profile's non-PathMap allocation lives in `Space.jl:_coreferential_transition!`'s DFS inner loop —
concrete, nameable per-call allocs: `length(_coref_path(loc))` builds a `SubArray` only for its length
(951); a fresh `Vector{UInt8}`+`Expr`+`ExprEnv` per bound back-ref (1003-1005); a static-NewVar
`Expr([byte])`+`ExprEnv` rebuilt every unbound back-ref (1007-1008, a constant — hoistable); a
byte-slice per `ExprSymbol` (1034). These are **MORK** optimizations, not a PathMap upstream port, and
each needs its own before/after allocation measurement (3 stable runs) + a correctness check that
`Expr`/`ExprEnv` buffers aren't mutated after being shared/pushed. Tracked, NOT done here — out of
scope for "PathMap perf sync," and not to be changed speculatively.
