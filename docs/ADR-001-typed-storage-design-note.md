# ADR-001 design note: typed slab storage (replacing the `Memory{UInt8}` PoC shortcut)

**Status:** Design note (no code) — the "first hour" gate before integration code
**Date:** 2026-06-24
**Decides:** the storage primitive the read-path integration (Day 1) builds on.

## The question

The PoC packs typed node records into one raw `Memory{UInt8}` arena with manual `slab_store!`/
`slab_load` + per-field byte-offset arithmetic. That is unsafe for a *writable* + COW structure
(loses SROA, no type-system backstop, error-prone `parent_coff` backpatch). Two typed replacements:

- **Option A — per-type fixed-stride slabs.** `Memory{DenseNodeRecord}` + `Memory{ListNodeRecord}`,
  each a fixed *max-capacity* entry array (256 dense / 16 list). Typed, SROA-eligible, no offset math.
  Cost: wasted space on underfilled nodes.
- **Option B — two-level header + entry pool.** `Memory{NodeHeader}` (count/mask/entry-start, indexed
  by handle) + a tightly-packed typed `Memory{EntryRecord}` pool (bump allocator). Typed throughout —
  the entry pool is index arithmetic into a *typed* array, NOT byte arithmetic.

## The measurement (200k constant-15B keys, the realistic sparse workload)

| | value |
|---|---|
| nodes | **1,264,332** (≈ 6.3 nodes / key) |
| list / dense | **99.8% list**, mean **1.16 children/node**, **95% exactly 1 child**, max 36 |
| current packed `Memory{UInt8}` | 23.0 MB |
| **Option A** (fixed-stride) | **341.5 MB — 14.8× (catastrophic)** |
| **Option B** (header + pool) | 74.0 MB — 3.2× |

## Decision

**Reject Option A.** At mean 1.16 children/node, a fixed 16-entry list record is ~14× waste — worse
than the mutable `PathMap` (38 MB) it replaces. The plan's "default A" is overridden exactly on its
stated condition ("unless wasted-space is measured significant" — it is, 14.8×).

**Adopt Option B (typed two-level header + entry pool)** for integration. Reasons: typed field access
(SROA-eligible, no offset-arithmetic corruption risk in the writable/COW path), and it does *not*
fixed-stride-waste the 99.8% sparse nodes. Keep the `NodeHeader` **lean** (the 40 B estimate above is
pessimistic — a single-child node needs only count + entry-start + the dense mask only when dense).

**Why we move off `Memory{UInt8}` at all — note it is for SAFETY, not memory.** The byte blob is in
fact the *most* memory-efficient (23 MB) because it adds zero per-node typed overhead. We accept
Option B's overhead in exchange for type safety in the mutating/COW path. That overhead is the price
of correctness, not a performance win.

## The finding that reframes the memory picture: path compression is load-bearing

**6.3 nodes/key is the signature of MISSING path compression.** Each 8-char unique key suffix becomes
~8 single-child nodes instead of one. The 1.26M node count — not the storage primitive — is what
drives memory; any per-node typed overhead (A *or* B) is multiplied by 1.26M.

`LineListNode` path compression (Day 2) collapses single-child chains into one node with a multi-byte
key. Estimated effect: ~5–6× fewer nodes (toward ~220k), which (a) makes Option B comfortably
memory-competitive with — likely better than — the byte blob, and (b) is the real memory lever
regardless of A/B. **Implication for sequencing:** the typed-storage memory cost is only a concern
*pre*-path-compression; land `LineListNode` early so Option B and path compression realize their wins
together. Choose B now for safety; its memory overhead is recovered by the Day-2 path-compression work.

## Carries into integration
- Read-path dispatch (Day 1) reads `DenseNodeRecord`/`ListNodeRecord` (or header+pool) via typed
  access — no `slab_store!`/`slab_load` byte math.
- `LineListNode` varlen keys (Day 2): pack key bytes inline at a fixed max-klen stride **after**
  measuring the real key-length distribution.
- COW + structural sharing remain gated on **ADR-002** (design note, Day 2; no implementation).
