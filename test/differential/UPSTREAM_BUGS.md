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



## `subtract_into` removes a value at a PREFIX of a subtracted path

Found 2026-07-31 by shrinking fuzz case `00175`. **Silent over-removal.**

### Minimal reproducer

```
A bb
AROOTVAL 0
S ab ba
SROOTVAL 0
ORIGIN b
OP JOINMAP
OP SUB 0
```

    upstream   Element;None;|[]       vc=0
    ours       Element;Element;|[bb,bb] vc=2

At origin `b` the target's subtrie holds a VALUE at path `b` (from key `bb`). Joining `S = {ab, ba}`
adds paths `ab` and `ba`. Subtracting the same `S` must remove exactly those two and leave the value
at `b` — `b` is a proper PREFIX of `ba`, and the rule (which upstream honours everywhere else) is that
a value is removed only when the source has a VALUE AT THE SAME PATH, never merely structure below it.
Upstream removes it.

### Why it took a shrink to find, and what does NOT reproduce it

Every simpler shape behaves CORRECTLY upstream, which is why hand-built probes kept missing it:

    A bb / S ba        / SUB only                 Identity [bb]        value + strict extension: OK
    A bb bc bd be bf / S ba / SUB only            Identity [bb,…]      node width alone: OK
    A bb bba / S ba    / SUB only                 Element  [bb]        value + child below: OK
    A bb bba / S ba    / literal, then SUB        Element  [bb]        OK
    A bb / S ba        / JOINMAP + SUB            Element  [bb,bb]     ONE source key: OK
    A bb / S a:b ab    / JOINMAP + SUB            Element  [bb,bb]     two keys, none is `ba`: OK
    A bb / S ab ba     / JOINMAP + SUB            None     []          ← FAILS

So it needs BOTH the `ba` key — the one sharing a first byte with the existing value-path — AND a
second source key, which is what grows the post-join node past its small representation. Neither
alone is enough, and the plain `SUB` path is correct at every width tried.

### What we do

We keep the value, which is what the operation specifies. Our own equivalent bug
(`_bn_psubtract_abstract`, closed earlier in this corpus — "a value must be removed only when the
source has a VALUE AT THE SAME PATH, never merely structure below it") was the same rule; ours is
fixed and upstream's is not.

⚠️ The `[bb,bb]` duplicate in both columns is a SEPARATE, SHARED upstream behaviour: after a join at a
focus inside a multi-byte slot key, one value is reachable through two slot encodings. Both engines
produce it identically — verified on three shapes — so it is not part of this defect and not ours.

## `graft_map` DESTROYS the subtrie it just grafted, when the source has a root value

Found 2026-07-31 while running down fuzz case `00610`. **Silent data loss in a core operation.**

`graft_map` (write_zipper.rs:1464) is three steps:

```rust
let (src_root_node, src_root_val) = map.into_root();
self.graft_internal(src_root_node);
#[cfg(feature = "graft_root_vals")]                       // DEFAULT feature
let _ = match src_root_val {
    Some(src_val) => self.set_val(src_val),
    None          => self.remove_val(false)
};
```

The trailing `set_val` lands in the same slot the `graft_internal` branch was just written to and
replaces it, so **the entire grafted subtrie disappears**. Only when the source map carries a root
value — otherwise `remove_val` runs instead and the graft survives.

### Settled by a controlled experiment against the release binary

Three scripts through `gen_fuzz --exec`, differing only where marked:

| script | source root value | upstream result |
|---|---|---|
| `A ::b / S bb:: / ORIGIN ::` | **yes** | `[::,::b]` — S's `bb::` is **GONE** |
| same, `SROOTVAL 0` | **no** | `[::b,::bb::]` — S's content **present** |
| `A :b / S bb:: / ORIGIN :` | **yes** | `[:,:b]` — gone again |

Row 2 is the control that isolates it: with the root value removed and nothing else changed, the
graft survives. Row 3 rules out the obvious alternative — it is NOT about multi-byte node keys, which
was the standing hypothesis for this family and is hereby retired.

### What we do

We keep both the grafted subtrie and the root value, which is what the operation says it does. That
puts this file's rule in play — *reproducing silent data loss is worse than deviating* — and this is
a clear instance: a caller asked for a subtrie to be planted and upstream drops it on the floor.

Our fuzz corpus therefore reports these as "we have MORE atoms than upstream", and that is the
correct side to be on. **13 of the 27 remaining over-retention cases** have a source carrying both a
root value and content together with a source-consuming op (`00111 00607 00610 01137 01449 02234
02280 02307 02338 02596 02665 02703 02877`) — consistent with this cause, though only `00610` has
been reduced and confirmed individually. The other 12 have no source root value at all and need a
separate explanation.

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

### 1b. The same bug reached through `join_map_into` and `graft_map` — fuzz `00119`, `00111`

**Status:** classified 2026-07-28 by execution. Same deviation, same reasoning; recorded here so
they are not re-investigated as separate defects.

`insert_prefix` is not special — ANY structural write at a mid-edge focus followed by `set_val`
loses the structural change. A one-factor-at-a-time probe series, every value pinned against the
binary:

| probe | upstream | ours | reading |
|---|---|---|---|
| join only, mid-edge origin `:` | `[::,::,::aa,:ab,:ba] vc=5` | identical | fine |
| **join + `SETVAL`** (`00119`) | `[:,::] vc=2` — joined content GONE | `…vc=5`, preserved | **the bug** |
| join + `SETVAL`, origin at the ROOT | `[::,:aa,ab,ba] vc=5` | identical | not mid-edge ⇒ safe |
| join + `SETVAL`, origin at a FULL KEY | `[::,:::aa,::ab,::ba] vc=4` | identical | node boundary ⇒ safe |
| join + **`REMOVEVAL`** | content preserved | identical | it is `set_val` specifically |
| **`graft_map`, source HAS a root value** (`00111`) | `:abb:` dropped | preserved | **the bug** |
| `graft_map`, source has NO root value | `[:a,:a,:abb:] vc=4` | identical | no internal `set_val` fires |

The graft rows are the informative ones: `graft_map` takes no `set_val` op from the caller, but
under `graft_root_vals` it calls `self.set_val(src_val)` ITSELF when the source has a root value
(write_zipper.rs:1471). So the destructive path is entered from inside the graft — which is why
`00111` looked like "upstream drops grafted content" until the source-root-value factor was
isolated.

**Net:** we agree with upstream on every probe in that table EXCEPT the two where upstream destroys
data. We keep the data in all of them.

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
