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



## `subtract_into` removes a value at a PREFIX of a subtracted path, on DENSE nodes

Found 2026-07-31 by shrinking fuzz cases `00175` and `01357`. **Silent over-removal.**

### Minimal reproducer — one op, no join, at the root

```
A a b bbba
AROOTVAL 0
S bbba
SROOTVAL 0
ORIGIN -
OP SUB 1
```

    upstream   Element;|[a]    vc=1     <- `b` is GONE
    ours       Element;|[a,b]  vc=2     <- correct

Subtracting `{bbba}` must remove exactly `bbba`. `b` is a proper PREFIX of it, and the rule upstream
honours everywhere else is that a value is removed only when the source has a VALUE AT THE SAME PATH,
never merely structure below it.

### Three conditions, each shown NECESSARY

    A b bbba       / S bbba   ->  [b]        agree      2 distinct first bytes: node is a Pair, OK
    A a b bbba     / S bbba   ->  [a]        DIVERGE    3 -> the node is DENSE
    A a c b bbba   / S bbba   ->  [a,c]      DIVERGE    4, still dense
    A a c bbba     / S bbba   ->  [a,c]      agree      no value at a prefix of the subtracted path
    A a b bbba     / SUB 0    ->  [a]        DIVERGE    prune is IRRELEVANT

So it needs (1) the node holding the value to be DENSE — three or more distinct first bytes, not a
Pair/LineList — and (2) a value at a proper prefix of a subtracted path. `prune` makes no difference.

⚠️ **Why this took so long to isolate, worth reading before hand-building probes for this file.** Six
earlier hypotheses were "refuted" on shapes that could not reach the dense path: value+strict
extension, value-with-child-below, literal rebuild, join-produced structure, `set_val`-wipes-subtrie,
and a width test that added keys `bb bc bd be bf` — those share the first byte `b`, so they widened a
SUBTREE while leaving the ROOT a Pair. Widening the node that holds the value is the thing that
matters, and it takes distinct first bytes.

### What we do

We keep the value, which is what the operation specifies. Our own equivalent bug
(`_bn_psubtract_abstract`, closed earlier in this corpus — the same rule, stated the same way) was
found and fixed; upstream's is not. This is why the corpus scores these as "we have MORE atoms".

⚠️ Some cases in this family also show a `[bb,bb]` duplicate in BOTH columns. That is a SEPARATE,
shared upstream behaviour — after a join at a focus inside a multi-byte slot key one value is
reachable through two slot encodings — verified identical on both engines. It is not part of this
defect and not ours.

## An ambiguous `LineListNode` is built silently, then clobbered when it overflows to dense

Found 2026-07-31 running down fuzz `00610`; **root cause corrected 2026-07-31** after every remaining
divergence was shrunk. **Silent data loss in a core operation — 25 of our 30 remaining divergences.**

Full write-up, with the step-by-step mechanism and a two-op Rust reproducer against the public API,
in `upstream_reports/pathmap-2.md`. In short, two upstream defects cooperate:

* **CREATION** — `graft_internal` at a non-root focus calls `node_set_branch`. When the focus node is
  a `LineListNode` whose *other* slot holds a longer key with the same first byte,
  `set_payload_abstract`'s slot-clearing shortcut (line_list_node.rs:977) does not fire — it is
  guarded on `is_child_ptr::<0>()` and that slot holds a VALUE. The graft is parked in the free slot
  and the node becomes `slot0 = child at K`, `slot1 = payload at K…`, which upstream's own
  `validate_node` calls an *"ambiguous path violation"* and panics on (:2784). Nothing on this path
  calls `validate_node`, so it is created silently and still enumerates correctly.
* **DETONATION** — the next op needing a third payload overflows the node through `convert_to_dense`
  (:1086), which transplants both slots with `set_child` keyed on the FIRST BYTE only (:1101, :1121).
  Both keys share that byte and `set_child` on an occupied byte is `swap_rec` — a clobber whose
  returned old child is discarded.

### ⚠️ THIS FILE PREVIOUSLY RECORDED TWO ENTRIES HERE, BOTH WITH THE WRONG MECHANISM

They are replaced by the one above. Kept visible rather than quietly deleted, because the way they
were wrong is the reusable part:

* *"`graft_map`'s trailing `set_val` lands in the slot `graft_internal` just wrote and replaces it"* —
  no. `set_val` cannot overwrite a child slot: `get_payload_exact_key_mut::<IS_CHILD>`
  (line_list_node.rs:516-530) type-checks the slot first.
* *"`set_val` after `insert_prefix` at a mid-edge focus destroys the inserted subtrie"* — the same
  defect seen through a different caller, not a second bug.
* A later generalisation, *"`set_val` at the focus discards the immediately preceding op"*, fit all
  26 cases AND a controlled experiment (disable every `set_val` and the engines agree 26/26) — and
  was still wrong.

All three were arrived at by generalising from which ops appeared next to each other. What settled it
was **predicting outcomes from the Rust source and then running them**, including cases predicted to
AGREE:

| probe | ours | upstream | |
|---|---|---|---|
| graft + `set_val` | `[:,::aa,:ab::]` | `[:,::aa]` | loss |
| graft + `remove_val` + `set_val` | `[:,::aa,:ab::]` | `[:,::aa]` | **still loses** — kills "the preceding op" |
| graft + `set_val`, parent already dense | `[:,:ab::,b,c]` | *identical* | **no loss** |
| graft + `set_val`, slot_1 free | `[:,:ab::]` | *identical* | **no loss** |

Four predicted, four matched. The two that AGREE carry the information: a hypothesis that only ever
predicts disagreement cannot be falsified by a corpus of disagreements.

### What we do — and it is NOT luck

We keep the grafted subtrie, so the corpus reports these as "we have MORE atoms than upstream".

The reason we survive is structural: our `_convert_to_dense!` (LineListNode.jl) routes through
`merge_from_list_node!` → `_bn_join_child_into!`, the **joining** transplant. Upstream's
`convert_to_dense` cannot call its own `join_child_into`/`merge_from_list_node` — they require
`V: Lattice` and the impl block at line_list_node.rs:576 does not carry the bound.

🔴 That makes it an **UNDOCUMENTED DEVIATION of ours that happens to be correct**. Recorded here so
that nobody "restores parity" by making our transplant clobber too. If upstream fixes this by adding
the bound, our version already matches.

### Separately, SHARED, and therefore invisible to the fuzzer

After `graft_map` at a focus landing mid-node-key, the pre-existing path below the focus SURVIVES on
**both** engines — `::aa` survives a graft at `:` — contradicting `graft`'s own doc comment
(write_zipper.rs:76-80, "replaces the trie below the zipper's focus"). We ported it faithfully, so it
never shows up as a divergence. Suggested fix (1) in the report removes it as a side effect.

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
