# Upstream PathMap delta — DEFERRED (2026-06-24)

Status: **DEFERRED, not ported.** No current consumer needs it; the substrate is done/tested.
Decision recorded so this is a known, ready-to-pick-up gap — not a silent drift.

## Baseline vs upstream

| | Rust `pathmap` commit | date |
| --- | --- | --- |
| Our Julia port tracks (~baseline) | `0ca5aaa` (`~/JuliaAGI/dev-zone/PathMap-upstream`) | 2026-05-07 |
| Fresh upstream downloaded | `27d9b09` — PR #38 `rz_path_api_and_fast_multi_branch_graft` (`~/JuliaAGI/dev-zone/PathMap`) | 2026-06-23 |

Crate version unchanged (0.3.0) across the range. Delta = ~30 commits, **+1616 / −67 across 19 files**
(`git -C ~/JuliaAGI/dev-zone/PathMap log --oneline 0ca5aaa..27d9b09`).

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
that point port from `~/JuliaAGI/dev-zone/PathMap` (the fresh `27d9b09` source) 1:1 — read the Rust
first (`src/write_zipper.rs`, `src/zipper.rs`, `src/trie_ref.rs`, `src/prefix_zipper.rs`), skip the
benchmarks + micro-perf opts, and add warm-REPL coverage per new method.
