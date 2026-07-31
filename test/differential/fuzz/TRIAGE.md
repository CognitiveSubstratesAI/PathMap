# Fuzz divergences — triage (33 of 3000 cases)

Regenerate with `test/differential/shrink.jl` (needs the rustup toolchain): it reduces each failing
case to a 1–2 op reproducer and re-pins it against the upstream binary.

**SHRINK FIRST, THEN ATTRIBUTE.** Case 00020's duplicate path was reported as our structural
corruption; shrinking showed BOTH engines produce it.

## Closed (34 → 5)

| root cause | cases | commit |
|---|---|---|
| null-sentinel contract only one method wide (all 7 crashes) | 7 | `18647bb` |
| `set_val_at!(m,"",v)` materialised a spurious root node | 6 | `18647bb` |
| `wz_take_focus!` was read-then-clear, not upstream's two-branch `take_node_at_key` | 3 | this commit |
| `join_map_into` early return tested emptiness; upstream tests only `is_none()` | 4 | this commit |
| **`set_payload_abstract!` child arm forwarded `created_subnode` instead of hardcoding `true`** | **10** | this commit |

That last one is the lesson of the batch: a ONE-WORD asymmetry inside a single function closed ten
divergences. Our value arm hardcoded `true` (matching upstream), the child arm forwarded the
recursive call's flag. We reach that code only via `split_0`, which by definition just created a
subnode at THIS level — so under-reporting made `_wz_graft_internal!` skip its
`mend_root!`/`descend_to_internal!`, leaving the zipper pointing at the parent while the split had
moved the value into the new child.

## ✅ CLOSED 2026-07-31 — `00174` and the whole constructor-descend family: **75 → 33** (42 cases)

**The fix is one line**: `write_zipper_at_path` now calls `_wz_mend_root!` where it used to call
`_wz_descend_to_internal!`. Measured before/after on the same 3000-case corpus with the same
harness — 75 divergences → 33, **42 closed, 0 newly broken**, 0 errors. The full PathMap suite
passes, including the 6 tests the earlier attempt broke.

**Why the earlier attempt failed and this one does not.** Deleting the descend was right about the
cause and wrong about the remedy: the origin path still has to be absorbed somewhere. Upstream
absorbs it into `root_key_start` (advancing it and RE-POINTING the stack root), not into a descent.
So the correct change is a SUBSTITUTION, not a deletion — which is why over-removal
(`[ab,bb:] vc=2`) disappears.

That also explains the size of the win. The old note projected ~11 cases (the 9 RESET-family plus
`00174`/`00177`); the actual figure is 42, because the disabled `mend_root` affected every zipper
built at a path, not only the ones whose scripts contained a `RESET`.

The analysis below is retained — it is correct, and it is what located the cause.

## THE REMAINING 33, RE-CLASSIFIED 2026-07-31 (the old grouping is stale)

The 42 closures changed which shapes dominate, so the op-shape table further down no longer
describes the corpus. Re-run after the fix:

| class | n | meaning |
|---|---|---|
| **MORE** | **27** | we retain atoms upstream removes — OVER-RETENTION |
| STATUS-ONLY | 3 | identical dumps, different `AlgebraicStatus` |
| SAME-COUNT-DIFF | 3 | same `vc`, different paths |
| ~~FEWER~~ | **0** | **the data-loss class is EMPTY** |

**That is the headline: there are no data-loss divergences left.** Every remaining case has us
keeping too much or reporting the wrong status, never dropping an atom. The constructor-descend fix
closed the entire "fewer atoms" class.

Op shapes are now almost all singletons (only `JOINMAP SUB` ×3 repeats; just 5 of 33 involve
`RESET`, against 9 of 15 before). Grouping by op shape is no longer informative — group by class.
Among the 27 MORE cases, `GRAFTMAP` appears in 14, `SETVAL` in 12, `JOINMAP` in 10.

### ✅ `00610` SOLVED 2026-07-31 — it is an UPSTREAM defect, and we are on the right side

**`graft_map`'s trailing `set_val` destroys the subtrie `graft_internal` just planted**, whenever the
source map carries a root value. Full write-up, with the controlled experiment, in
`../UPSTREAM_BUGS.md`. Three scripts through the release binary, differing only where marked:

    A ::b / S bb:: / ORIGIN ::   SROOTVAL 1  ->  [::,::b]        S's content GONE
    (same)                       SROOTVAL 0  ->  [::b,::bb::]    S's content PRESENT
    A :b  / S bb:: / ORIGIN :    SROOTVAL 1  ->  [:,:b]          gone again

Row 2 isolates the cause. Row 3 **retires the multi-byte-node-key hypothesis** that this section had
been built on — it happens at a single-byte origin too.

⚠️ **THE `make_mut` COW CANDIDATE IS REFUTED.** The note below proposed that our `into_child` recursion
lacks upstream's `child_in_slot_mut::<0>().make_mut()`. Measured, not argued: instrumenting that exact
site across the whole 3000-case corpus gives **1074 visits, 0 shared, max refcount 1**. The
post-`split_0` child is never shared, so `make_mut` is a no-op there and cannot be the cause. Do not
rebuild this hypothesis.

13 of the 27 over-retention cases carry a source with BOTH a root value and content plus a
source-consuming op, consistent with this cause; only `00610` has been individually reduced. The
other **12 have no source root value at all** and remain unexplained — that is the next question.

### `00175` and the OTHER 12 — reduced to SUB, semantic not structural, minimal case NOT yet found

The 12 over-retention cases with NO source root value are not explained by the `graft_map` defect
above. `00175` (`JOINMAP | SUB 0`) is the simplest and was reduced with 8 discriminating runs against
the release binary (`gen_fuzz --exec`). What is ESTABLISHED:

1. **Both ops agree in ISOLATION.** `JOINMAP` alone: ours == upstream, `vc=8`, identical dumps.
   `SUB` alone: ours == upstream, `vc=5`, `Identity`. Only the SEQUENCE diverges (upstream 4, ours 5).
2. **It is NOT structural.** Rebuilding the post-join content from LITERAL keys and running the same
   SUB diverges identically (`vc=4` both ways). So the join does not leave a different trie shape —
   the difference is in SUB's semantics on that content.
3. **Bisect isolates one source key.** Removing `ba` from `S = {a:b, ab, ba}` makes `bb` AND `bba`
   survive (`vc=4`). Removing any single A key does not. So subtracting the path `ba` is what also
   removes the value at `b` — its proper PREFIX.

That is the same defect class as our own `_bn_psubtract_abstract` bug (closed earlier in this file):
*a value must be removed only when the source has a VALUE AT THE SAME PATH, never merely structure
below it.* Ours is fixed; upstream's answer here looks like that bug unfixed.

⚠️ **BUT THE MINIMAL CASE DOES NOT REPRODUCE, so this is NOT yet a filed defect.** Every reduced
shape behaves CORRECTLY upstream:

    A bb          / S ba   ORIGIN b   ->  Identity [bb]              value + strict extension: OK
    A bb bc       / S ba              ->  Identity [bb,bc]           width 2: OK
    A bb bc bd    / S ba              ->  Identity [bb,bc,bd]        width 3: OK
    A bb bc bd be bf / S ba           ->  Identity [bb,…]            width 5: OK  (node width is NOT it)
    A bb bba      / S ba              ->  Element  [bb]              value + child BELOW it: OK
    A bba         / S ba              ->  None     []                child only: OK
    A bb bca      / S ba              ->  Identity [bb,bca]          child elsewhere: OK

So the trigger needs sibling content the reduced cases lack — in `00175` the subtrie also carries
`ab`, `a:b` and `:a`. Five hypotheses are dead: join-produced structure, general over-removal after a
join, bare value-vs-extension, value-with-child-below, and node width.

**NEXT STEP: a real delta-debugging minimizer**, not more hand-built cases. The predicate is cheap now
that arbitrary scripts can be run on both engines (`gen_fuzz --exec` for upstream, `fuzz_run_text` for
ours), so shrinking A and S jointly until a one-element change flips the answer is mechanical. Build
that before writing another candidate by hand.

### (superseded) `00610` — a SINGLE `GRAFTMAP` diverges, and BOTH engines look wrong

The cleanest reproducer in the corpus: one op, no RESET.

    A ::b        AROOTVAL 0
    S bb::       SROOTVAL 1
    ORIGIN ::
    OP GRAFTMAP

    ours      [::,::b,::bb::] vc=3
    upstream  [::,::b]        vc=2

The harnesses are NOT asymmetric — `_fmk` (run_fuzz.jl:52) and `mk` (gen_fuzz.rs:124) are
line-for-line the same construction, checked.

`graft_map` (write_zipper.rs:1464) is `into_root()`, then `graft_internal(src_root_node)`, then —
under the DEFAULT `graft_root_vals` feature — `set_val` if the source had a root value. `into_root`
(trie_map.rs:205) returns `Some(node)` whenever the root node is non-empty, and S's is, so upstream
should graft S's content.

**It does not.** `::b` is a DESCENDANT of the graft point `::`, so a graft at `::` should replace it;
upstream KEEPS `::b` and contains none of S's `bb::`. We add S's content but also fail to clear
`::b`. So upstream appears not to graft at all at a MULTI-BYTE node key, and we graft without
clearing.

#### What the 00610 dig RULED OUT (2026-07-31) — recorded so it is not repeated

Correlation over the whole corpus, then a targeted code read. Neither located the cause; both
narrowed it, and the negative results are the point.

*Correlation.* "origin is a proper prefix of an A key" holds for 13 of the 14 diverging `GRAFTMAP`
cases — but **214 cases with that same property PASS**, so it is not the condition. Adding "exactly
one A key strictly extends the origin" (true for 13/13) and "the origin is not itself a key" gives a
predicate matching 593 cases corpus-wide of which only 20 diverge: ~3% precision. **Correlation has
been taken as far as it usefully goes here** — the answer needs code, not statistics.

*Code read of the slot-0 overlap branch* (`set_payload_abstract`, line_list_node.rs:963-980 vs our
LineListNode.jl:692-711), which is the path `node_set_branch` takes for a prefix key:

* The branch is FAITHFUL — same `find_prefix_overlap`, same `IS_CHILD && is_child_ptr && overlap ==
  key.len()` total-replacement arm, same `overlap -= 1` adjustment, same `split_0` + recurse.
* Our `set_recursive(child_rc, sub_key)` looks like it drops upstream's third argument. It does not:
  it is a local closure capturing `payload` and `is_child`. Not a bug.
* `child_mut = as_tagged(child_rc)` (LineListNode.jl:708) is DEAD — `set_recursive` recomputes it.
  Harmless, but delete it when next in the file.

*The one candidate this surfaced.* Upstream recurses into
`self.child_in_slot_mut::<0>().make_mut()` — `make_mut()` is the COW ensure-unique. Ours recurses
into `into_child(n.slot0)` with no visible equivalent. If the child can be SHARED at that point, the
two engines differ in whether the mutation is isolated. ⚠️ Verify with an actual REFCOUNT check
before believing it — a COW-isolation claim from reading alone has been wrong here before.

⚠️ Multi-byte node keys are exactly where the `00174` analysis already found asymmetry ("`node_remove_val`
cannot serve a multi-byte key on EITHER side"), and after the mend fix a path-rooted zipper sits at
depth 1 with a multi-byte `node_key` far more often. So this is likely the shared root of much of the
MORE class — but do NOT assume it: `00020` was once reported as our corruption and turned out to be
produced by both engines. Read `graft_internal`'s multi-byte-key path on both sides before changing
anything.

## 00174 — the divergence is in TRIE SHAPE after `set_val`, not in `reset` (FIXED, see above)

⚠️ **A PREVIOUS HYPOTHESIS HERE WAS REFUTED — recorded so nobody rebuilds it.** I claimed
`wz_reset!` fails to unwind `_wz_mend_root!`'s `root_key_start` advance, and that fixing it needed
a struct change to retain the origin root. **Wrong on both counts, settled by reading upstream:**

* `MutNodeStack::to_root()` is literally `self.stack.clear()` and `replace_root()` merely
  re-points `self.root` (write_zipper.rs:2773-2780). Upstream restores NOTHING, and its `reset`
  does not touch `root_key_start` either — so ours is faithful here.
* In this case `mend_root` never even fires: it no-ops while `prefix_idx` is non-empty, and
  measurement shows `root_key_start == 0` throughout.

**The verified facts.** Reproducer: `A={":ab","ab","bb:"}`, source = ROOT VALUE ONLY, origin
`":a"`, then `JOINMAP` · `RESET` · `REMOVEVAL 1`.

    start / after JOINMAP   prefix_buf=":a" rks=0 idx=[1] depth=2 node_key="a"
    after RESET             prefix_buf=":a" rks=0 idx=[]  depth=1 node_key=":a"
    ours      remove_val -> false, `:a` survives   [:a,:ab,ab,bb:] vc=4
    upstream  remove_val -> true,  `:a` removed    [:ab,ab,bb:]    vc=3

The join's value write happens at depth 2 (`node_key="a"`, i.e. inside the child node reached past
`:`). After `RESET` the focus is the ROOT with `node_key=":a"` — a TWO-byte key.

**And `node_remove_val` cannot serve a multi-byte key on EITHER side:** upstream's
`DenseByteNode::node_remove_val` is `if key.len() == 1 { … } else { None }`
(dense_byte_node.rs:847), and `LineListNode`'s matches its slot key EXACTLY. So upstream succeeds
only because its root holds a slot keyed `":a"` where ours does not — i.e. **the two engines'
trie SHAPES differ after the val write**, and `reset`/`remove_val` are innocent.

### ROOT CAUSE LOCATED (2026-07-28) — and the OBVIOUS FIX IS WRONG, measured

Our structure after `JOINMAP` (from our ported `viz_maps`):

    root = Dense
      [58 ':'] -> Pair   [97 'a']     -> UnitVal     <- the value at ":a" lives in the CHILD
                         [97,98 'ab'] -> UnitVal
      [97 'a'] -> Pair   [98 'b']     -> UnitVal
      [98 'b'] -> Pair   [98,58 'b:'] -> UnitVal

**The difference is at CONSTRUCTION.** `descend_to_internal` is called upstream only from
`descend_to` / `set_val` / `graft_internal` and friends (write_zipper.rs:1033, 1231, 1401, 1626,
1638, 2173, 2259) — **never from a constructor** (`new_with_node_and_path_internal_in`, :1147,
only builds KeyFields and the stack root). Our `write_zipper_at_path` DOES descend.

Consequence chain, all verified:
* Descending leaves `prefix_idx` NON-EMPTY, and `_wz_mend_root!` no-ops while that holds — so the
  origin is never absorbed into `root_key_start` (measured: `rks=0` for the whole sequence).
* Upstream starts at depth 1, so its first `set_val` DOES trigger `mend_root`, advancing
  `root_key_start` to 1 and re-pointing the stack root at the child.
* After `RESET`, upstream is on the child with a ONE-byte `node_key` (`"a"`), which
  `node_remove_val` can serve. We are on the Dense root with a TWO-byte `node_key` (`":a"`), which
  NEITHER engine's `node_remove_val` can serve (upstream's DenseByteNode is
  `if key.len() == 1 { .. } else { None }`, dense_byte_node.rs:847).

⚠️ **Simply deleting the constructor's descend was TRIED AND REVERTED.** It fixes the return value
but over-removes — `[ab,bb:] vc=2` where upstream gives `[:ab,ab,bb:] vc=3` — and breaks 6 tests.
Other parts of our port evidently rely on the zipper being pre-descended, so this is a coordinated
change (constructor + whatever compensates for it), not a deletion. Do not retry the deletion
alone.

`00177` (RESET + REMPREFIX) is listed with this pair only because it also follows a `RESET`; its
divergence is upstream emitting a DUPLICATE path, which is a different question. Treat separately.

## SCALED TO 3000 CASES (2026-07-28) — 81 divergences, 0 crashes

⚠️ **This is NOT a regression from "5 remaining".** That 5 was out of **300** cases. The corpus
now runs **3000**, and case numbering is STABLE across counts (verified: the first 300 lines of the
3000-case ground truth are byte-identical to the old corpus), so the original 5 are still present
and the other 76 come from the 2700 NEWLY GENERATED programs.

    300 cases   ->  5 divergences  (1.7%)
    3000 cases  -> 81 divergences  (2.7%)   0 errors

The rate went UP slightly, which is the informative part: the extra programs reach shapes the first
300 never generated. "5 remaining" was never a population estimate — only what 300 random programs
happened to expose. **Zero crashes at 10x scale** is the other result worth noting.

### CLOSED from the "fewer" group: `_bn_psubtract_abstract` dropped a value (81 -> 75)

Shrinking the first 10 "fewer atoms" cases collapsed 5 of them onto ONE missing `else`.
`_bn_psubtract_abstract` looked up `node_get_val(other, key)` and, when the source had structure at
that byte but NO VALUE, did nothing — leaving `new_cf.val` unset, so OUR value vanished. A value
must be removed only when the source has a VALUE AT THE SAME PATH, never merely structure below it.

    {a}    - {ab}    upstream Identity [a]     ours was None []
    {a,ab} - {ab}    upstream Element  [a]     ours was None []
    {:b:}  - {:b:b}  upstream Identity [:b:]   ours was None []

FAMILY SWEEP DONE: only two `_abstract` algebra paths exist — `_bn_psubtract_abstract` (fixed) and
`_bn_prestrict_abstract`, which already has the `else`. No `pjoin`/`pmeet` equivalents.

### THE CONSTRUCTOR-DESCEND CAUSE IS WORTH ~9 OF THE 15 REMAINING DATA-LOSS CASES

After the subtract fix, shrinking ALL 15 remaining "fewer atoms" cases collapses them to 7 op
shapes, and one cause dominates:

    x4  RESET SETVAL              00642 01137 01991 02767
    x4  RESET JOINMAP             01100 01963 01978 02974
    x1  RESET REMPREFIX           00177
    x3  DESCEND REMPREFIX         00498 00800 01536
    x1  DESCEND ASCEND            00724
    x2  (singletons)              01687 02038

**NINE of fifteen involve RESET** — the same root cause already documented above for `00174`: our
`write_zipper_at_path` DESCENDS at construction (upstream's constructors do not), which leaves
`prefix_idx` non-empty, which makes `_wz_mend_root!` a no-op, which leaves `reset` landing at a
depth upstream never occupies. The `RESET JOINMAP` group is status-only (`None` vs `Identity` with
identical dumps), which is consistent: after a mis-positioned reset our `_wz_get_focus_anr` reports
none where upstream's reports Some.

**So this is now the single highest-value item in the corpus** — roughly 9 here plus `00174` and
`00177`, and plausibly some of the "same count" group too.

⚠️ Still NOT a deletion. Removing the constructor descend was tried and reverted (see above): it
over-removes and breaks 6 tests, because with no descend our node-level ops receive a MULTI-BYTE
`node_key` and something in our port does not handle that the way upstream's `node_set_val` /
`node_set_branch` do (they split and recurse internally). The coordinated change is:
constructor stops descending **and** the node ops handle full-length keys. Budget it as a session,
not a patch.

### ⚠️ COVERAGE GAP — the fuzzer never exercises `restrict`

The generator's op set is DESCEND · ASCEND · SETVAL · REMOVEVAL · GRAFTMAP · JOINMAP · MEET · SUB ·
TAKEMAP · INSPREFIX · REMPREFIX · RESET. There is **no RESTRICT**, so `wz_restrict!` and
`_bn_prestrict_abstract` are covered by nothing here — and `prestrict` is precisely a sibling of
the function that just turned out to be silently dropping values.

⚠️ Adding an op is a RE-BASELINE event, not a free change: the generator picks ops with
`r.below(13)`, so widening it changes RNG consumption and reshuffles every case. Do it
deliberately, regenerate ground truth, and re-derive KNOWN_DIVERGENT.txt in the same commit.

### Cheap shape split of the 81 (by `vc=` count, before any shrinking)

| shape | count | reading |
|---|---|---|
| ours has MORE atoms | 33 | we PRESERVE where upstream destroys — the approved deviation class |
| ours has FEWER atoms | 24 | we LOSE data — **likely OURS** |
| same count, different content | 24 | either; needs shrinking |

So roughly a third are not defects at all. **Start with the 24 "fewer atoms" cases** — that is
where we are losing data — and shrink before attributing, as always.

## CLASSIFIED 2026-07-28 — `00111` and `00119` are UPSTREAM, not ours

Settled by execution, not by resemblance: both are the mid-edge write-loss bug already approved for
deviation (`../UPSTREAM_BUGS.md` §1b, which carries the full probe table). `00119` is an explicit
`SETVAL` after a join; `00111` is `graft_map` whose `graft_root_vals` arm calls `set_val` ITSELF
when the source has a root value. Controls confirm the boundaries — at a root origin, at a
full-key origin, or with `REMOVEVAL` instead of `SETVAL`, both engines agree exactly.

**So 2 of the remaining 5 are not defects to fix.** They stay in `KNOWN_DIVERGENT.txt` because the
gate compares against upstream's actual bytes and we deliberately differ; do not "fix" them.

## Open — the last 5, NOT yet firmly attributed

⚠️ **Attribution below is a hypothesis, not a finding.** Each needs the ours-vs-upstream probe
treatment that settled `00041` (see `../UPSTREAM_BUGS.md`) before being called ours or theirs.

| case | shape | ours | upstream | hypothesis |
|---|---|---|---|---|
| `00119` | JOINMAP + SETVAL | keeps the joined subtrie | discards it | **likely the APPROVED upstream deviation** — same shape as `00041` (structural op at a MID-EDGE focus, then SETVAL, upstream loses the structural change) |
| `00111` | GRAFTMAP | `[:,:a,:abb:]` | `[:,:a]` | upstream drops part of the GRAFTED content — suspicious, probably the same class |
| `00174` | JOINMAP | `[a,aa:bb,ab,aba]` | `[:a,:aa:bb,:ab,:aba,bb:]` | **ours** — every path lost its leading byte AND an unrelated key (`bb:`) vanished. Looks like a write at the wrong depth relative to the origin |
| `00166` | GRAFTMAP+TAKEMAP+SUB | `[] vc=1` | `[b:b:] vc=2` | **ours** — we lose `b:b:` |
| `00020` | REMPREFIX + SUB | status `None` | status `Identity` | status-only; dumps agree |

**Next step:** probe `00174` first — it is the clearest "ours", and a whole-path byte shift usually
means one origin-relative offset, which has been the theme of this entire arc
(`_wz_at_root`, `excess_key_len`, spurious root).

## What this corpus does NOT cover

Value PAYLOAD algebra. Values are unit by design — our integer lattices carry a documented
intentional divergence (`src/core/Ring.jl`, audit 2026-06-02), so fuzzing `u64` would report a
by-design difference on nearly every merge. Closing that needs a decision on the deviation first.
