`subtract_into` removes a value at a PREFIX of a subtracted path (dense nodes only)

---
Subtracting a path also removes a value stored at a **proper prefix** of that path, when the node
holding the value is dense. A value should be removed only when the source has a value at the *same*
path, never merely structure below it.

## Reproducer — one op, three keys

```
target  = {"a", "b", "bbba"}
source  = {"bbba"}
zipper at the root
wz.subtract_into(&source_rz, true)
```

| | result |
|---|---|
| observed | `["a"]` — `"b"` is gone |
| expected | `["a", "b"]` |

`"b"` is a proper prefix of the subtracted `"bbba"`, and the source has no value at `"b"`.

## Three conditions, each shown necessary

```
{b, bbba}        - {bbba}  ->  [b]      OK    2 distinct first bytes: node is a Pair
{a, b, bbba}     - {bbba}  ->  [a]      BUG   3 -> node is dense
{a, c, b, bbba}  - {bbba}  ->  [a,c]    BUG   4, still dense
{a, c, bbba}     - {bbba}  ->  [a,c]    OK    no value at a prefix of the subtracted path
{a, b, bbba}     - {bbba}  ->  [a]      BUG   prune=false behaves identically
```

So it needs (1) the node holding the value to be **dense** — three or more *distinct first bytes*,
not a `LineListNode`/Pair — and (2) a value at a proper prefix of a subtracted path. `prune` makes no
difference.

## Note for anyone reducing this further

Several simpler shapes are **correct**, which makes the bug easy to miss: value + strict extension at
any width, value with a child below it, and the same content rebuilt by ordinary inserts. A width
test using keys `bb bc bd be bf` also passes — those share a first byte, so they widen a *subtree*
while leaving the root a Pair. Widening the node that *holds the value* is what matters.

Found by differential-fuzzing a Julia port of PathMap against the Rust build (3000 random programs,
delta-debugged). Happy to supply the harness if useful.
