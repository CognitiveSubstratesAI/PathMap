# ADR-002 design note: COW + structural sharing in the slab model

**Status:** Design note (no code) — the gate before ANY slab write-path / integration code
**Date:** 2026-06-24
**Depends on:** ADR-001 (slab read path, characterized) · `ADR-001-typed-storage-design-note.md` (Option B)

This is the genuinely-hard part of the slab redesign. The read path is characterized (typed compressed
slab ≈ 3–5× Rust, decode-bound win over heap's ~18×). The write/concurrency model is undesigned, and
getting it wrong is **silent data corruption under concurrent load**, not a failed benchmark. Four
questions, each grounded in the *existing* code, with a decision and its consequence on the
integration sequence.

## Grounding: how COW + concurrency work TODAY (heap model)

- **Path-copying lazy COW.** Descent is read-only. At each mutation, `_wz_ensure_write_unique!`
  (`WriteZipper.jl:133`) walks `focus_stack` root→focus; for each node with `refcount > 1` it calls
  `make_unique!` (`TrieNode.jl:461`) → `clone_self` produces a **fresh heap node** (shallow: children
  stay shared, their refcounts bump), and re-links the parent via `node_replace_child!`.
- **Sharing = refcount.** Node-keyed `@atomic refcnt` (one per inner node); two `TrieNodeODRc` over the
  same node ⇒ `refcount == 2`. The DAG is real (structural sharing is what makes MORK space-algebra
  joins/meets cheap).
- **Concurrency = path-level locks.** `SharedTrackerPaths` (`ZipperTracking.jl:100`) = a `ReentrantLock`
  + `written_paths`/`read_paths`. `stp_try_add_writer!`/`reader!` permit **concurrent writers on
  DISJOINT paths** + readers off written paths. Allocation today is the **GC** (thread-safe by default).

The slab replaces GC-allocation with a manual arena — which is exactly where each of these four breaks.

## Q1 — Copy direction on COW: into the slab, or materialise to heap?

**Decision: COW *into the slab*** (append a new slab record, return a new handle) — NOT heap-materialise.
Heap-materialise would degrade the slab's locality win precisely on hot (frequently-written) regions and
permanently bifurcate the representation; the trie would never converge to all-slab. COW-into-slab keeps
one uniform representation, mirroring `_wz_ensure_write_unique!` but allocating the clone in the slab.
**Consequence (sequence):** the write path now produces slab garbage (the old shared record stays live
for other owners) ⇒ it **cannot land before refcounted records + compaction exist (Q2)**. Write path is
strictly after Q2.

## Q2 — Compaction under structural sharing (the DAG)

**Decision: refcount each slab record** (mirror the node-keyed `@atomic refcnt`, a counter per record),
and make compaction a **DAG copy with a `seen::Dict{old_handle,new_handle}`** — each shared record copied
**once**, all referrers repointed to the single new handle. The PoC's `slabtrie_compact!` is a **tree
DFS** and is **WRONG under sharing**: it would duplicate every shared subtrie (breaking node identity that
space-algebra relies on, and exploding size). **Consequence (sequence):** this is the single most
invasive change vs the PoC, and it must exist **before** any sharing write path — the moment two writers
(or a join) share a slab node, tree-DFS compaction corrupts. Build refcount+DAG-compaction first.

## Q3 — Zipper consistency across relocation

**Decision: handles are stable indices + the slab is append-only** (existing records never move). This is
already true in the PoC (indices survive regrow). The `focus_stack` stores **handles, not raw pointers**,
so growing/regrowing the slab does NOT invalidate live zippers, and COW-replace re-links the parent's
child *handle* exactly as `node_replace_child!` does today. **No epoch/lock is needed for ordinary
allocation.** The one hazard is **compaction (Q2), which MOVES records** — it must run only at a quiesce
point (no live zipper), or use copy-on-compact (build a new slab; live zippers drain on the old).
**Consequence (sequence):** Q3 is essentially *free* if Q1/Q4 keep the slab append-only — it falls out of
stable-index handles, and only compaction needs a quiesce barrier.

## Q4 — Concurrency / thread-safety (the gating question — PRIMUS-specific)

`SharedTrackerPaths` permits **concurrent writers on disjoint paths within one space**; they share that
space's slab, so the slab's allocator is hit concurrently. The PoC's slab is a **single `Memory{UInt8}`
with realloc-on-regrow** — `slab_reserve!` reallocates the whole array on growth, which under concurrency
is catastrophic (reallocating while another thread reads the old array = data race + use-after-free).

**Decision: per-Space slab + a SEGMENTED append-only slab** — fixed-size `Memory` chunks that are **never
reallocated**; growth appends a *new* chunk; the global length is bumped by **CAS** for lock-free
concurrent append. A handle decodes to (chunk, offset). This (a) keeps existing records pinned (Q3 stays
free), (b) gives lock-free disjoint-writer allocation, (c) confines the only stop-the-world op to
compaction (Q2). **Consequence (sequence): this GATES MORK integration and must be the slab design from
the start.** The PoC's single reallocatable `Memory{UInt8}` is NOT concurrency-viable; retrofitting
concurrency onto it later is a rewrite, not a patch.

## ✅ UPSTREAM CROSS-CHECK — DONE (2026-06-24, `~/JuliaAGI/dev-zone/PathMap-upstream` + `MORK`)

Read `alloc.rs`, `trie_node.rs` (`make_mut`), and MORK's space construction. Result: **the slab has NO
direct Rust analog — it is a Julia-specific adaptation, so there is nothing upstream to "deviate" from
on the slab mechanism. Q1 is confirmed aligned; Q4's concurrency assumption needs one specific revision.**

- **No arena in Rust. Per-node heap allocation via the GLOBAL allocator.** `alloc.rs`: on stable
  `Allocator` is an **empty trait** and `GlobalAlloc = ()` (a no-op); nodes are `TrieNodeODRc(Arc<dyn
  TrieNode>)` — individually heap-allocated, refcounted `Arc`. Rust's locality comes from compact
  value-type nodes + jemalloc size-classes, **NOT a contiguous trie arena.** ⇒ The Julia slab is the
  idiomatic way to get that locality *despite GC scatter* — a Julia-specific solution to a Julia-specific
  problem (GC doesn't cluster like jemalloc). **Confirmed: no deviation — there's no Rust arena to match.**
- **Q1 COW — CONFIRMED ALIGNED.** `make_mut` = `Arc::make_mut`: if refcount>1, **clone the shared node
  into a NEW heap allocation**; else mutate in place. ADR-002's "COW into a new slab record" is the exact
  Julia-slab equivalent of "new heap allocation." The slim_ptrs variant's inline `AtomicU32` is what the
  port's node-keyed `@atomic refcnt` mirrors. Q1/Q2 refcount semantics match upstream.
- **Q4 — SPECIFIC REVISION (the slab's concurrency cost is largely self-inflicted).** Rust gets
  concurrent-safe allocation **for free** from the global allocator; the segmented-CAS-append scheme
  solves a problem the arena *introduces*, that Rust doesn't have. And **MORK's parallelism is
  `par_iter().reduce(PathMap::new(), merge)` — independent per-worker PathMaps MERGED, not concurrent
  writes to one shared trie.** ⇒ **Before committing to segmented CAS-append, verify whether MORK's
  RUNTIME (not just construction) ever does concurrent zipper-head writes to a SINGLE trie.** If it does
  not (construction is par-reduce; runtime may be single-writer-per-space), **Q4 simplifies dramatically**:
  one slab per PathMap, single-threaded writes per slab, parallelism via independent slabs + merge — **no
  CAS, no segmentation-for-thread-safety needed.** (Segmentation may still be worth it to avoid
  realloc-invalidating-live-zippers per Q3, but that's a Q3 concern, not a concurrency one.)

**Net:** the slab direction and Q1/Q2/Q3 are confirmed; **Q4 is the one component to re-scope** — pin
MORK's actual single-trie concurrency before building the segmented allocator. Do that verification as
the first thing after the segmented-handle format (step 0), before the Q4 allocator (step 1).

## Implied build order (what the next coding session starts from)

0. **Segmented `SlabHandle` format FIRST (~half-day, not an hour).** The PoC handle is a flat
   `(idx::UInt32, tag::UInt8)` into one contiguous `Memory`. A segmented slab needs
   `(segment::UInt16, offset::UInt32, tag::UInt8)` (or equivalent). Scope is **"rewrite the existing slab
   PoC to use segmented handles, suite green"** — a breaking change to EVERY handle-using function in
   `NodeSlab.jl` (`lln_find`, `dbn_mask`, `node_find`, `_compact_node!`, all read helpers) AND all 38
   tests in `test_node_slab.jl`. Foundation, not a late refactor. **Do NOT build the segment-array
   *allocator* yet** — just the handle format + the existing PoC using it correctly, all 38 slab tests +
   full suite green before committing.
1. **Segmented, CAS-append, per-Space slab** (Q4) — the concurrency-safe foundation; nothing else is
   sound without it.
2. **Refcounted records + DAG compaction with a seen-map** (Q2) — before any sharing write path.
3. **COW-into-slab write path** (Q1) — clones append to the slab, parent handles re-linked.
4. **Zipper on stable handles** (Q3) — mostly free; add a compaction quiesce barrier.
5. Read path (already characterized) can land independently/first as the additive, no-risk slice.

## Cross-space structural sharing — DECISION (resolved 2026-06-24 by reading the cross-space paths)

The concern: MORK space algebra could rely on **global** structural sharing — two Spaces holding handles
to the SAME physical node, refcount spanning both — which per-Space slabs (Q4) break. Resolved by reading
the actual cross-space code:

- **Cross-space joins/products do NOT share nodes.** `ProductZipper` (`secondaries::Vector{TrieRefBorrowed}`
  + primary `ReadZipperCore`) and `ProductZipperG` (`primary` + `secondary::Vector` of per-factor zippers)
  traverse each factor (Space) via its OWN independent read-zipper and form the product by **concatenating
  one path per factor** — there is no cross-space node-level sharing to lose.
- **Graft is the only cross-space sharing path.** `wz_graft!` → `_wz_graft_internal!(z, copy(src_rc))`:
  `copy()` shares the source node by reference (refcount bump). A cross-Space graft thus shares a physical
  node across two PathMaps today.

**Decision: Option (a) — cross-Space operations COPY at the slab level** (handles are relative to the
owning Space's segment array; never shared across Space boundaries). Consequences:
- **No regression for joins/products** — `ProductZipper`/`ProductZipperG` already read each Space
  independently; per-Space slabs change nothing there.
- **Within-Space sharing fully preserved** (the common case: COW path-copying, internal graft, joins).
- **Cross-Space graft loses its O(1) by-reference share** → O(subtrie) copy into the destination Space's
  slab. Acceptable: cross-Space access is dominated by `ProductZipper` reads, not by-reference graft.
- **Escape hatch if measured hot:** option (c) (space-id in handle) re-enables cross-Space sharing without
  a global slab — revisit ONLY if a workload shows cross-Space graft-copy as a bottleneck.

This unblocks Q1 — cross-Space grafts materialise into the destination slab; no global slab needed.

## Other open items (deferred to implementation)

Free-list vs compaction-only reclamation; chunk size; compaction trigger policy; and the LineList
varlen-key pool layout (from the typed-storage note).
