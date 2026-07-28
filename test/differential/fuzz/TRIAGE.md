# Fuzz divergences — triage (5 remaining of an original 34)

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

## 00174 — the divergence is in TRIE SHAPE after `set_val`, not in `reset` (NEXT ITEM)

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

**Next step:** dump both engines' node structure after the `JOINMAP` step (before `RESET`) and
diff the shapes. Do NOT start from `reset`.

`00177` (RESET + REMPREFIX) is listed with this pair only because it also follows a `RESET`; its
divergence is upstream emitting a DUPLICATE path, which is a different question. Treat separately.

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
