# PathMap — known issues / hardening backlog

## KI-1 — `remove_val_at!(…, prune=true)` crashes a subsequent multi-factor query

**Status:** open · **Filed:** 2026-06-11 · **Severity:** medium (the `prune=true` path is opt-in and
currently unused in shipped call sites; default `prune=false` is unaffected).

### Summary
`remove_val_at!(m, path, prune::Bool=false)` (`src/zipper/WriteZipper.jl:483` → `wz_remove_val!` →
`wz_prune_path!`) defaults pruning **off**, so a removed value leaves a **dangling path-node** behind.
That dangling path is correctly skipped by value-gated reads (`get_val_at`, `val_count`, dump, and the
read-zipper's `to_next_val`) but was matched by MORK's multi-factor conjunction query — see the MORK
finding `experiments/mm2_programs/findings/control_08_phantom_conjunction.md`.

MORK fixed its symptom at the query layer (gate matches on value-presence, MORK `16981af`). The
**port-faithful** alternative — prune on remove so no dangling path ever exists (matching upstream
pathmap, whose query gates on `path_exists()`) — is blocked by a latent crash in the prune path.

### Repro (in MORK, which depends on this PathMap)
Enabling `prune=true` at MORK's `RemoveSink.sink_finalize!` (`Sinks.jl:201`) + forwarding `prune`
through the `PrefixBtm` wrapper, then running `Control_08_Halts_on_fail.mm2`, the prune succeeds but
the **next-step query crashes**:

```
BoundsError: attempt to access 15-element Vector{UInt8} at index [16]
  in ExprAlg.jl:50  (expr span/byte access)
  ← ProductZipper enumeration  (MORK Space.jl:751 ← 373/402 ← 1279/1283)
```

i.e. after `wz_prune_path!` collapses the now-empty branch, a read zipper iterating the same trie
reconstructs an `origin_path` that is one byte short, so downstream expr decode indexes out of bounds.

### Sharper diagnosis (2026-06-11)
The crash needs **COW sharing**, not just prune. Isolated single-trie prune works fine — a plain
`remove_val_at!(…, true)` then read-zipper iteration round-trips correctly (verified across flat
siblings, pruned subtries, and counter-like shapes). It only breaks when the pruned node is
**COW-shared** (refcount > 1), exactly MORK's metta-calculus case: `read_btm = pjoin(s.btm,
singleton).value` is kept alive across the step, so the `-`-sink's prune must fork before collapsing.

Decisive MORK experiment (re-enable `prune=true` at `RemoveSink`, **disable** MORK's query value-gate):
the next-step **`ProductZipper`** yields a position where `pz_is_val(pz)` is **true** but `pz_path(pz)`
is **one byte short** — a structurally truncated expr. `pz_to_next_val!` gates on `pz_is_val`
(ProductZipper.jl:404/407/413), so the value-flag and the reconstructed path have gone **inconsistent**
after the prune-on-COW-shared node. MORK's value gate masks it (a truncated path has no value via
`get_val_at`), which is why MORK is sound with the gate + prune off — but the underlying
prune↔COW↔ProductZipper bookkeeping is still wrong.

### Where to look
`wz_prune_path!` / `_wz_prune_path_internal!` node-collapse (`WriteZipper.jl:1139,1153`) **after a COW
fork** vs. `ProductZipper` path/`factor_paths` reconstruction (`src/zipper/ProductZipper.jl`,
`pz_path`/`pz_is_val`). Hypothesis: collapsing a single-child node shortens trie depth by a byte, but
a COW-shared sibling's cached key/path length isn't updated, so the product traversal reports a value
at a path that's a byte short. Repro to build at the PathMap level: pjoin-share a trie, `remove_val_at!
(…, true)` a key on the shared spine, then drive a **`ProductZipper`** (not a single read zipper) over
it and assert every `pz_is_val` position has a full-length, round-tripping `pz_path`.

### Why it's not urgent / not needed
No shipped call site passes `prune=true`; the default (`prune=false`) path is sound. MORK's bug is
**fully fixed** by the query value-gate (`16981af`) with prune **off** — prune is *not* required for
correctness, only for upstream parity + avoiding long-run dangling-node accumulation (a memory, not
correctness, concern). Enabling prune is therefore gated on fixing this COW+ProductZipper bug first;
until then keep `prune=false` at all call sites.
