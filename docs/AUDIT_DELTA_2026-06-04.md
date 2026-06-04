# PathMap — Delta Audit Closeout (2026-06-04)

Reconciliation of an external delta audit (`PATHMAP_DELTA_AUDIT_3.md`) against the migrated
PathMap. Every finding verified against the code by reading (the external audit noted it had
no grep tool; the precedence sweep below is the verification it couldn't run).

## Verified FIXED (spot-checked vs code)
- **#1 deepcopy clone_self → shallow structural sharing** — confirmed at BOTH sites:
  `LineListNode._shallow_clone_slot`, `DenseByteNode.deepcopy_bn`.
- **#7 per-wrapper refcount → node-keyed `@atomic refcnt::UInt32`** — confirmed on all four
  mutable node types: TrieNode, LineListNode, DenseByteNode/CellByteNode, BridgeNode.
- **BN-1 BridgeNode undercount** — `_clone_val_or_child` now bumps the child refcount
  (`BridgeNode.jl:354`). Confirmed fixed.
- **Lazy-COW WriteZipper** — `_wz_ensure_write_unique!`, transitive-sharing handling,
  node-level + zipper-level COW guards — all present.

## Precedence finding — RESOLVED by grep (the audit's open question)
`grep -rnE "\|\|.*&&.*return" src/` → every hit is properly PARENTHESIZED `(A || B) && return`
(correct precedence). The dangerous unparenthesized `A || B && return` (parses as
`A || (B && return)`) appears NOWHERE in LineListNode / Ring / ArenaCompact / Morphisms /
Zipper / OverlayZipper. The precedence-bug class is gone. **Confirmed clean.**

## FIXED this pass
- **ZT-1 (Medium, concurrency) — finalizer-vs-Drop.** `ZipperTracker`/`ReadZipperTracked`/
  `WriteZipperTracked` release their path locks via `finalizer` = GC time, not scope exit
  like Rust `Drop`, so a lingering lock can cause a spurious `Conflict`. Added deterministic
  scoped wrappers `with_zipper_tracker` / `with_read_zipper_tracked` /
  `with_write_zipper_tracked` (release in `finally`), exported, with a regression test that
  asserts the lock is free immediately after the `with_` block WITHOUT any `GC.gc()` call
  (`test/runtests.jl` "ZT-1"). The `finalizer` remains as a backstop. 137/138 (1 broken =
  threads-only test).
- **IN-DOC1 (Low, stale comment).** `Ints.jl` deferred-section note said the range
  generators "will be ported once trie_map.rs + write_zipper.rs land" — those HAVE landed.
  Updated: they remain unported only for lack of a consumer; the dependency is no longer the
  blocker.

## DOCUMENTED (verified, NOT defects — defensible-by-design / latent / deferred)
- **MM-PERF1 (Med, perf)** — catamorphism `Vector{Any}`/`Dict{,Any}` (Morphisms.jl). Generic
  over the fold-result `W`, which the engine isn't parameterized on (Rust monomorphizes via a
  `W` type param). Real boxing on hot folds; a design tradeoff. Fix = parameterize on `W`.
- **DPZ-PERF1 / PZG-PERF1 (Low, perf)** — `secondary::Vector{Any}` etc. in
  DependentZipper/ProductZipperG: genuinely heterogeneous factor-zipper types, resolved via
  runtime dispatch. Same class + justification as MM-PERF1.
- **ZT-2 (Low, perf)** — `_check_for_write_conflict` builds an O(path-len) zipper per prefix.
  Acceptable for short paths; revisit if conflict-checking becomes hot.
- **BN-2 (latent, upstream-faithful)** — BridgeNode `pmeet/psubtract/prestrict/drop_head`
  `error("unimplemented")` (matches Rust — BridgeNode is the DenseByteNode suffix-holder).
  Throws rather than computes if a future path routes those ops through a BridgeNode focus.
- **Iteration-cap pattern** (Overlay/Dependent/Product/ProductG `*_to_next_val!`) — hard
  100k–200k cap that `@warn`s + returns `false`. Converts a hang into a bounded, loud failure;
  a known safety net, not a correctness guarantee. Acceptable.

## Verdict
All located findings FIXED or fixed-and-confirmed; the one genuine actionable (ZT-1) is now
fixed + tested; the stale comment (IN-DOC1) corrected; remaining items are documented perf
tradeoffs / latent / deferred. No new correctness defects. PathMap's structural-sharing core
is sound. The execution-level arbiter remains the COW property + integration tests.
