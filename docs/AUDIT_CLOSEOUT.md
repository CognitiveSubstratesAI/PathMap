# PathMap audit close-out

Working tracker for the close-out of the 2026-06-02 deep audit (Rust→Julia
porting faithfulness, idiomatic Julia, Julia 1.12.6). Fix-and-harden in place; no
repo migration until every package is audited + fixed. Each step lands against a
verification gate.

## Status

| Step | What | State |
|------|------|-------|
| — | JuliaFormatter pass (whitespace/reflow only) | ✅ `89fa57f` |
| 0 | Test net: COW refcount-primitive **rewrite guard** | ✅ `8205292` (suite 113/113) |
| 1 | 3 operator-precedence fixes (`A \|\| B && return` misparse) + regressions | ✅ `084fd0c` |
| 3a | **COW discipline — `make_unique!` before `drop_head_dyn!` in `wz_join_k_path_into!`** (decoupled live-bug fix) + Gate A regression | ✅ `fac3d84` (suite 118/118) |
| 2 | **Shallow `clone_self`** (LineListNode slots, DenseByteNode/CellByteNode via `_cf_copy`, BridgeNode child via `copy()`) — structural sharing restored | ✅ Option B (suite 124/124, Gate B) |
| 3b | **COW discipline** — `make_unique!` before each `drop_head_dyn!` RECURSION (LineListNode) + before the in-place merge in `wz_join_into_take!` | ✅ Option B (Gate A + MORK 1715/1715) |
| 2-A | **Node-keyed `@atomic refcnt`** rewrite (thread-safety + Rust `slim_ptrs` fidelity) — Option A hardening | ✅ (suite 128/128 incl. atomic concurrency test, MORK 1715/1715) |
| 4 | Arena allocator (Bumper.jl) in-or-out decision | ✅ OUT (decision recorded below) |
| 5 | Doc-comment the integer/bool lattices as a deliberate divergence | ✅ `Ring.jl` header comment |

## Step 4 decision — Bumper.jl arena: OUT (keep the seam)

**Decision (2026-06-02): do NOT take a Bumper.jl dependency now; keep the `alloc`
seam.** Rationale:
- The `alloc` field / `A <: Allocator` parameter is the faithful image of Rust's
  allocator threading (`new_in` / `Box::new_in`). It is inert on the `GlobalAlloc`
  path (a phantom, exactly as on Rust's stable non-nightly path) but is the correct
  seam where a bump allocator would plug in — so the architecture is already
  arena-ready without the dependency.
- Write-path perf (~4 ms / 1k inserts) is acceptable for the current bootstrap
  workloads; no measured bottleneck justifies the dependency yet.
- Project policy: no new runtime dependency unless justified vs a Julia-native
  approach. Bumper.jl is not justified at present.
- Revisit IF a profiled hot path shows node-allocation churn dominating. At that
  point the change is local (plug an allocator type into the existing seam), not a
  rewrite. Until then PathMap is "done" after this close-out.

## Option A / B split (decided 2026-06-02, "B now, A later")

The per-wrapper `Ref` refcount turned out to be **already coherent** for shallow
clone: every secondary node reference arises through `copy()` (e.g.
`wz_graft_map!` does `copy(map.root)`), and `copy` shares the *same* `Ref` box, so
the count tracks node sharing today. So node-keyed refcount is **not required to
enable** shallow clone (the audit's premise was slightly off) — it buys
thread-safety (atomic field vs racy `Ref{Int} += 1`) and faithful mirroring of
Rust `slim_ptrs refcnt: AtomicU32`.

- **Option B (landed):** keep the coherent per-wrapper `Ref`; flip `clone_self`
  shallow + add the `make_unique!` discipline at the `drop_head` recursion and
  `wz_join_into_take!`. Captures the real payoff (structural sharing) at small
  blast radius. Single-thread-correct. `drop_head_dyn!` for DenseByteNode was
  ALREADY discipline-correct (copy + `make_unique!` + fresh node); only
  LineListNode's two recursions and `wz_join_into_take!` needed the guard.
- **Option A (LANDED, "2-A"):** added `@atomic refcnt::UInt32` to the four mutable
  node structs (LineListNode, DenseByteNode, CellByteNode, BridgeNode) with a
  defaulting inner ctor each; stripped `_refcount` from `TrieNodeODRc`; rewrote
  `copy`/`make_unique!`/`refcount` node-keyed via a generic protocol
  (`_has_refcnt`/`_node_refcount`/`_node_inc_refcnt!`/`_node_dec_refcnt!` using
  `getfield`/`modifyfield!` with memory order — the `hasfield` branch folds at
  compile time). Immutable nodes (TinyRefNode, EmptyNode) carry no field — they
  upgrade-on-write, so `make_unique!` is a no-op and they report count 1. The
  step-0 rewrite guard stayed green (contract preserved); a new atomic-concurrency
  test asserts 500 concurrent `copy`s give an EXACT count (no lost updates).

## ⚠️ CORRECTION: the COW bug was LIVE, not latent — and discipline DECOUPLES

An empirical probe (graft-share `m1` into `m2`, then `wz_join_k_path_into!` on `m2`)
showed `m1`'s values **silently corrupted** — a **LIVE** bug, reachable today via
MorkL's `OP_DROP_HEAD`. The audit's "masked by deepcopy" assessment was **wrong for
this path**: `wz_join_k_path_into!` bypasses `make_unique!` *and* `clone_self`
entirely (it calls `drop_head_dyn!` directly), so the deepcopy never runs → no
masking → live corruption.

Key consequence for the coupling: the implication is **one-directional**.
*Shallow-clone-without-discipline* is more broken (the principle below holds). But
*discipline-without-shallow-clone* is **safe AND fixes a live bug** — `make_unique!`
uses the current refcount + deepcopy clone (private copy → mutate copy → source
intact). So the `wz_join_k_path_into!` guard landed NOW (`fac3d84`), decoupled from
the deferred core. Subtlety that made the obvious fix wrong: the focus node is reached
via `get_node_at_key` and is **off** `focus_stack`, so the stack-only
`_wz_ensure_write_unique!` misses it — the fix `make_unique!`s the **borrowed focus
rc** (`borrow(focus_anr)`), the actual Rust `make_mut()` target.

`wz_join_into_take!` — PROBED (graft-share + join_into_take): source stays intact,
**NOT a current bug** (join_into_dyn! on a LineListNode builds a new node rather than
mutating self in place — the audit's "largely masked" guess confirmed). Adding
`make_unique!` there is a robustness item for the shallow-clone world, NOT a live fix.

STILL TODO in the coupled change: node-keyed refcount + shallow `clone_self` + the
`drop_head_dyn!` swap-into-fresh Rust-mirror + the `wz_join_into_take!` robustness
guard. The live corruption (`wz_join_k_path_into!`) is already fixed (`fac3d84`).

## The coupling principle (read before touching step 2)

`clone_self`'s `deepcopy` (`LineListNode.jl`, `DenseByteNode.jl`) is **load-bearing
as a safety mechanism**, not just a perf wart. It deep-copies whole subtrees, so
almost nothing is structurally shared — which *masks* the COW discipline gaps
(missing `make_unique!`). The intermediate state "shallow clone + missing
`make_unique!`" is **strictly more broken** than today: it replaces *correct-but-slow*
with *fast-and-corrupting*. **There is no valid commit boundary between flipping the
clone and landing the discipline fixes.** Steps 2 and 3 are one atomic correctness
unit. Do not split them.

(The refcount mechanics themselves are NOT a live corruption bug today — the current
per-wrapper `Ref` scheme errs toward overcount → over-clone → safe-but-slow. The
node-keyed refcount is the *enabler* of the shallow clone, which is the real payoff.)

## Step 2+3 — the coupled change (5 parts)

1. **Node-keyed refcount.** Move `refcnt` onto each node type (`@atomic refcnt::UInt32`,
   mirroring Rust `slim_ptrs` `refcnt: AtomicU32` as the node's first field). Strip
   `_refcount::Base.RefValue{Int}` from `TrieNodeODRc` (`TrieNode.jl:367`). Rewrite
   `copy` / `make_unique!` / `refcount` to read **through the node**. Every
   `clone_self`/constructor inits `refcnt = 1`. GC means no Drop-side decrement and
   no Rust `MAX_REFCOUNT` saturation needed.
2. **Shallow `clone_self`.** Share children via `copy` (Arc-bump), NOT `deepcopy`
   (`LineListNode.jl:1850`, `DenseByteNode.jl:1537/1540`, `deepcopy_bn:1440`). This
   restores structural sharing — PathMap's reason for existing.
3. **COW discipline (two distinct sub-fixes).**
   a. Add `make_unique!` on the focus rc BEFORE the in-place mutation in
      `wz_join_k_path_into!` (`WriteZipper.jl:834`) and `wz_join_into_take!` (`:1332`)
      — Rust calls `make_mut()` at exactly those sites.
   b. Fix `drop_head_dyn!` (`LineListNode.jl:1702/1736`) to **swap contents into a
      fresh node** before wrapping, mirroring Rust `drop_head_dyn`
      (`line_list_node.rs:2525-2563`, `core::mem::swap` then `new_in`) — NOT a
      Julia-local approach. `drop_head` is subtle; DIFF against the Rust mechanism
      before accepting. Same for the DenseByteNode `drop_head_dyn!` path.
4. **COW property test** (write FIRST, adversarially — see Gate A).
5. **Run MORK** against the changed PathMap (Gate C, blocking).

## Acceptance gates (definition-of-done — write the tests BEFORE the implementation)

These, not "hot context", are what make this change safe. Each must be written
deliberately.

- **Gate A — COW property test (containment proof).** Build a map; graft/`copy` a
  non-trivial subtrie into a second map so they genuinely SHARE nodes; take a write
  zipper on one and run the discipline-gap ops (`drop_head` via the public path,
  `wz_join_k_path_into!`, `wz_join_into_take!`); assert the OTHER map is byte-identical
  to a pre-op snapshot. **Must FAIL against parts 1+2 alone (shallow clone, no
  discipline) and PASS only after part 3.** That fail-then-pass is the literal proof
  the un-masking is contained. If it passes against 1+2, the test is too weak — fix
  the test first.
  **ORDERING (do not let fresh momentum skip this):** write Gate A and *watch it
  fail* on the 1+2-only intermediate (shallow clone landed, discipline NOT yet)
  BEFORE implementing part 3. A test written after the fix tends to be a test that
  passes, not one that proves. The fail-first observation IS the proof the gate is
  real — same logic as the step-0 rewrite guard.
- **Gate B — structural-sharing assertion (proves #1 FIXED, not just not-broken).**
  After a shallow `clone_self` of a node with children, assert a child node is
  `ptr_eq` / `shared_node_id`-identical between original and clone. The integration
  tests CANNOT give you this — they don't measure sharing. This is the gate that
  proves `deepcopy` is actually gone and sharing is real.
- **Gate C — MORK integration run (BLOCKING, not post-hoc).** Run MORK's full suite
  against the modified PathMap built **in the integrated workspace** (MORK resolving
  the in-tree, changed PathMap via the workspace dev-dep) — NOT MORK against a
  published/registered PathMap, which would measure nothing. The harness already
  exists (the earlier MORK-impact check used it). PathMap is the substrate MORK rides
  on; a subtle COW bug surfaces three layers up in `.metta` and is ruinously
  expensive to diagnose from there. Green MORK is part of done.

- **Guard (step 0):** the existing "COW refcount semantics (rewrite guard)" testset
  (`test/runtests.jl`) must stay green through the refcount rewrite.

## References

- Deep-audit findings + the corrected bug-#7 analysis: session memory
  `project_pathmap_cow_audit_2026-06-02` and `project_packages_migration_to_cognitivesubstrates`.
- Upstream Rust: `~/dev-zone/PathMap/src/` (`trie_node.rs`, `line_list_node.rs`,
  `dense_byte_node.rs`, `write_zipper.rs`, `ring.rs`).
- MORK-impact on the integer/bool lattice divergence: DONE — MORK uses `PathMap{UnitVal}`
  exclusively for algebraic ops; `UnitVal` lattice is bit-exact to Rust `Lattice for ()`.
  Int/bool divergence is off-path (latent); step 5 = document it, not a blocker.
