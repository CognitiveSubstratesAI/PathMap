# Adaptations — where upstream is RIGHT and we deliberately built it differently

Companion to `UPSTREAM_BUGS.md`, which records where **upstream is wrong** and we decline to
reproduce it. This file is the other category: upstream is correct, we understood it, and we chose a
different mechanism — or upstream changed and we deliberately did not follow.

See `MORK/test/conformance/ADAPTATIONS.md` for why this category needed a home: every entry was
already written down inside the file it affects, which is not findable, and one of them was
rediscovered the hard way three times in a single session.

---

## 1. `debug_assert!` is NOT ported as a runtime `@assert`

**Upstream** uses `debug_assert!` in several places — e.g. `debug_assert!(!status.is_none())` in
`line_list_node.rs`, and `debug_assert_eq!(factor_paths.len(), secondary.len())` added in
`dependent_zipper.rs` by PR #56 (2026-08-02).

**Ours** does not throw. The reasoning is recorded at `src/nodes/LineListNode.jl:1837`: a debug
assertion is compiled out in release, so **upstream PROCEEDS on violation**. Throwing where upstream
proceeds would be a NEW divergence — we would abort a run upstream completes.

**What we do instead:** pin the invariant as a TEST. `test/runtests.jl` has
*"DependentZipper — factor_paths and secondary stay IN STEP (upstream 143ecd1)"*, verified by a
positive control (inverting it fails at the named line, 3 pass / 1 fail).

**Cost.** A violation is caught by the suite, not at the point of failure in production. That is the
correct trade for port fidelity, but it means the invariant is only as good as the test's coverage.

---

## 2. `dpz_factor_count` is RETAINED where upstream DELETED it

**Upstream** deleted the inherent `factor_count()` from `DependentProductZipperG` in PR #56
(`143ecd1`). This is a real removal, not a relocation — **there is no `impl ZipperProduct for
DependentProductZipperG` anywhere** (the trait impls at `product_zipper.rs:826/848/873` are for
`ProductZipper`, `ProductZipperG` and `OneFactor`). The capability is gone for that type.

**Why upstream removed it.** The same PR made `secondary` a stack popped in step with
`factor_paths`. Once it is a live stack, `secondary.len() + 1` is a MOVING DEPTH, and the documented
contract — *"the number of factors composing the ProductZipper; the minimum returned value will be 1
because the primary factor is counted"* — cannot hold.

**Ours** keeps `dpz_factor_count(dpz) = length(dpz.secondary) + 1` and exports it, because it has a
live consumer: `src/zipper/ProductZipperG.jl:227` computes `dpz_factor_count(src) - 1` inside
`pzg_factor_count`.

✅ **MEASURED 2026-08-03 — the mechanism is REAL, the guard is NOT WRONG.**
`test/test_pzg_factor_count_guard.jl` builds CmpSource's exact shape and enrolls a secondary
mid-walk. `pzg_factor_count` genuinely MOVES — it takes {2, 1} within a single walk — so the
concern below was correctly identified. But `focus_factor` is derived from the SAME live state,
so the two move together and `focus_factor < factor_count` holds at every step; the
`focus_factor != factor_count - 1` guard keeps selecting the last factor correctly. Upstream PR
#56's invariant (`secondary` in step with `factor_paths`) also held throughout.

⚠️ Two things that reproduction taught, both easy to get wrong:
* The **PrefixZipper layer is load-bearing**. `_pzg_inner_factor_count` has a method for
  PrefixZipper ONLY (ProductZipperG.jl:225), so a bare DependentZipper primary falls through to
  the generic `= 0` and factor_count cannot move at all. A probe without the wrapper reports a
  false all-clear — measured.
* **Upstream's conformance battery cannot reach this.** It asserts exact paths, and an enrolling
  callback changes them; run non-enrolling, `secondary` stays empty and factor_count is pinned
  at 1. Three green battery invocations say nothing about this question.

SCOPE: one shape — a single enrolled secondary, empty prefix. This refutes the specific
"focus index vs moving total" concern for CmpSource. It does not prove the guard correct for
multiple simultaneous secondaries or a non-empty prefix.

The original analysis, kept because it is why the test exists: The composition is reachable and the mixed
quantities are real:

* `ProductZipperG`'s own `secondary` is STATIC — never popped.
* the inner `DependentZipper`'s IS a live stack, under the invariant above.
* `pzg_factor_count` SUMS them, so it moves during a walk.
* MORK guards on `pzg_focus_factor(prz) != pzg_factor_count(prz) - 1` (`MORK/src/kernel/Space.jl:836`)
  — a focus index compared against a total that changes. Upstream's analogous assertion is
  `assert!(self.focus_factor() == self.factor_count() - 1)` (`product_zipper.rs:177`), but on a type
  whose secondaries are static.
* the path is LIVE: `MORK/src/kernel/Sources.jl:244` builds a `DependentZipper` inside a
  `PrefixZipper` for `CmpSource` — the `==`/`!=` source.

**Not changed, because it needs a behavioural test rather than an API edit.** The `==` conformance
probes (`space/s2_isrc_eq_debruijn`, `space/s2_isrc_eq_ground`) currently PASS, so if the guard
misfires it is on a shape they do not reach. The next step is a probe that walks a `CmpSource` while
the dependent stack changes depth and checks whether the last-factor guard still selects correctly —
NOT deleting the accessor and seeing what breaks.

⚠️ **AND THIS SURFACE HAS NO DIFFERENTIAL COVERAGE AT ALL — verified 2026-08-03.** `rust_probe`
(`test/differential/rust_probe/src/`) contains **zero** references to `DependentProductZipper`,
`ProductZipper` or `dependent_zipper`. The 3000-case corpus exercises trie ops — join/meet/subtract/
graft — and never the zipper-composition layer.

Two consequences, and they compound:

1. It is why the risk above is INVISIBLE. There is no oracle that could see a wrong last-factor
   selection, so "the differential is green" says nothing about it. Same shape as the 2026-08-01 COW
   class: 3000 green cases and not one could observe source corruption because the harness only
   dumped the destination.
2. It is why moving the vendored checkout `52fd9df` → `143ecd1` (2026-08-03) did NOT invalidate the
   30 known divergences — upstream's changes were confined to `dependent_zipper.rs` and
   `product_zipper.rs`, neither of which the corpus touches. Checked BEFORE relying on it, rather
   than assuming the green run meant anything.

**So the honest statement is not "the differential covers PathMap"** — it covers the trie algebra.
The zipper-composition layer, which is where `CmpSource` and the `==`/`!=` source live, is
unmeasured. Upstream ships a 39-function type-generic zipper conformance battery
(`zipper_moving_tests` + `zipper_iteration_tests`) that we have never run; that is the ready-made
oracle for exactly this gap.

---

## Not in this file

Cases where upstream is wrong live in `UPSTREAM_BUGS.md` — `subtract_into` dropping a value at a
prefix on DENSE nodes, `graft_map` destroying the subtrie it just grafted, and the `1e300` symbol
truncation where upstream writes a corrupted symbol and we decline the write.
