# Deliberate deviations from upstream — where "match the binary" is the WRONG goal

Every other divergence in this directory is a bug of OURS to close. The ones recorded here are
different: **upstream is wrong, and we deliberately do not reproduce it.** Each entry carries the
probe that demonstrates it, so the claim is settled by execution rather than by argument.

This mirrors `MORK/test/conformance/upstream_panics/`, which vendors the programs where `mork run`
ABORTS — on those shapes "match upstream" has no meaning either.

**Rule of thumb, and the default is the other way.** The project's standing principle is *if
upstream has it, we implement it* — we do not get to judge whether it matters. This file is the
narrow exception: reproducing **silent data loss or corruption** is worse than deviating. Precedent:
the `1e300` symbol truncation (upstream's `SymbolSize(len as _)` truncates 302 → 46 and writes a
CORRUPTED symbol; we decline the write) and `mm1_forward`'s vacuous `dump_sexpr` queries ("porting
them faithfully would port a bug"). An entry here needs a demonstrated wrong ANSWER, not a
disagreement of taste.

To re-check any of these after an upstream rebuild:

```bash
export PATH="$HOME/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/bin:$PATH"
cd test/differential/rust_probe && cargo run --release --quiet --bin gen_fuzz -- --exec <dir-of-scripts>
```

---

## 1. `set_val` after `insert_prefix` at a MID-EDGE focus silently DESTROYS the inserted subtrie

**Status:** deviation approved 2026-07-28. Fuzz case `00041`.

**What upstream does.** `insert_prefix` succeeds and returns `true`. A dump confirms the inserted
subtrie is in the map. Then a `set_val` **at that same focus** makes it vanish — and the write
touched a different slot (the focus VALUE), not the subtrie.

```
map {ab}, write_zipper_at_path("a"), insert_prefix("x")        -> [ab, axb]     ret true
   ... then set_val(())                                        -> [a, ab]       ← axb GONE
```

**Why we call it a bug rather than a contract.** Two reads of the same map disagree depending on an
intervening, unrelated write. `insert_prefix` reported success and its effect was observable, then
was silently discarded. There is no return value or error signalling the loss.

**It is specifically `set_val`, and specifically a mid-edge focus** — established by probing every
other operation in that position, all of which PRESERVE the insert on both engines:

| after `insert_prefix` at a mid-edge focus | upstream | ours |
|---|---|---|
| `remove_val` / `descend_to` / `reset` / `ascend` / a second `insert_prefix` | preserved | preserved (agree) |
| **`set_val`** | **subtrie destroyed** | preserved ← **our deviation** |
| `set_val` at a BRANCHING focus (not mid-edge) | preserved | preserved (agree) |

**Our behaviour.** The inserted subtrie survives. We keep the data.

**What would change this.** A consumer that depends on the destructive behaviour (none found — the
only MORK caller of these APIs is HeadSink, which does not use `insert_prefix`), or upstream
declaring it intentional.

---

## 2. Duplicate paths enumerated from a single map — OBSERVED, not yet characterised

**Status:** ⚠️ NOT yet a deviation — recorded so it is not mistaken for one of ours. Fuzz cases
`00020`, `00177`.

Upstream can enumerate the SAME path twice from one map, e.g. `[:::a,:::a,a:,ba] vc=4` where we
produce `[:::a,a:,ba] vc=3`. In case `00020` **both engines** produce the duplicate
(`[:ba,:ba] vc=2`), so it is upstream behaviour that we sometimes reproduce and sometimes do not.

**I have NOT established which of us is right here**, and the honest position is that it is
uncharacterised. It is listed because I briefly reported case 00020's duplicate as OUR structural
corruption before shrinking it — the shrinker showed both engines produce it. Do not repeat that
mistake: **shrink first, then attribute.**

Next step if picked up: determine whether the duplicate is a mid-edge enumeration artifact in
upstream's read zipper (in which case ours is more correct and this becomes a deviation) or a
genuine multi-value state we fail to represent (in which case it is our defect).
