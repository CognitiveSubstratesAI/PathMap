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

### Likely cause / where to look
`wz_prune_path!` (`src/zipper/WriteZipper.jl:301`) node-collapse vs. the read zipper's path
reconstruction (`origin_path` / prefix-buffer bookkeeping). Pruning a single-child or value-only node
appears to leave a read zipper's cached path length inconsistent with the collapsed structure. Add a
direct PathMap unit test: build a 2+ atom trie, `remove_val_at!(…, true)` one, then iterate the
remaining values via a fresh read zipper and assert each reconstructed path round-trips.

### Why it's not urgent
No shipped call site passes `prune=true`; the default path is sound. Fixing this would let MORK adopt
prune-on-remove for exact upstream parity and drop the query-layer value gate, but the gate is correct
and cheap in the meantime.
