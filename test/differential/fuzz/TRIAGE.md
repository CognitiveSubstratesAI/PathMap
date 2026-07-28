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

## The `root_key_start` bookkeeping is not unwound by `wz_reset!` — NEXT ITEM

Diagnosed 2026-07-28 while closing 00174's first cause. `_wz_mend_root!` advances
`root_key_start` and OVERWRITES `focus_stack[1]` with an inner node, and **nothing restores
either**. `wz_reset!` pops the stack and truncates `prefix_buf` but leaves `root_key_start`
advanced and the original map root already lost.

Upstream can restore because its `MutNodeStack` keeps the original root SEPARATELY
(`take_root`/`replace_root`, and `reset` calls `focus_stack.to_root()`); our `focus_stack[1]` is
simply overwritten, so the information is gone. **This needs a struct change** — keep the origin
root (and its `root_key_start`) alongside the working one — not a one-liner.

Two of the remaining five are this:

| case | shape | ours | upstream |
|---|---|---|---|
| `00174` | RESET + REMOVEVAL | `false;[:a,:ab,ab,bb:] vc=4` | `true;[:ab,ab,bb:] vc=3` |
| `00177` | RESET + REMPREFIX | `[:::a,a:,ba] vc=3` | `[:::a,:::a,a:,ba] vc=4` |

⚠️ `00177` is ALSO a case where upstream emits a DUPLICATE path, so closing the reset gap may not
make it match — check that separately rather than assuming one fix covers both.

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
