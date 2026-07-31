`LineListNode::convert_to_dense` silently drops a subtrie when the two slot keys share their
first byte — `set_val` at a just-grafted focus is the easy way to hit it

*(against 52fd9df, default features, release build)*

---

## Summary

`graft` / `graft_map` / `graft_src_at` / `insert_prefix` / `remove_prefix` / `join_map_into` all
install the new subtrie through `graft_internal`, which for a non-root focus calls
`node_set_branch(node_key, src)`. On a `LineListNode` whose *other* slot holds a longer key with the
same first byte, that leaves the node holding **slot_0 = child at `K`, slot_1 = payload at `K…`** —
a shape `validate_node` itself rejects as an *"ambiguous path violation"*
(`line_list_node.rs:2784-2788`). Nothing detects it, and the trie still enumerates correctly, so the
damage is latent. It detonates on the next operation that cannot fit a third payload into the node —
in practice `set_val` at that same focus. The overflow path calls
`LineListNode::convert_to_dense` (`line_list_node.rs:1086`), which transplants both slots into a
`DenseByteNode` with plain `ByteNode::set_child` (`line_list_node.rs:1101` and `:1121`). Both slots
map to the **same byte**, and `set_child` on an occupied byte is `cf.swap_rec(node)`
(`dense_byte_node.rs:129-134`, `:1674`) — it *replaces* the child and drops the old one on the floor.
The subtrie installed by the graft is destroyed. `graft_map` with a source that has a root value
destroys itself this way in a **single call**, with no user `set_val` involved, because
`graft_map` = `graft_internal` + `set_val(src_root_val)` (`write_zipper.rs:1464-1474`).

The correct merging transplant already exists next door — `ByteNode::join_child_into`
(`dense_byte_node.rs:145`) and `ByteNode::merge_from_list_node` (`dense_byte_node.rs:526`), which
`line_list_node.rs:2477/2490/2518/2529` use for exactly this LineList→Dense upgrade on the algebra
paths. `convert_to_dense` cannot call them as written: it sits in
`impl<V: Clone + Send + Sync, A: Allocator> LineListNode<V, A>` (`line_list_node.rs:576`) and the
joining helpers need `V: Lattice`.

## Reproducer — two ops, public API

```rust
use pathmap::PathMap;
use pathmap::zipper::*;

let src: PathMap<()> = PathMap::from_iter([("ab::", ())]);
let mut map: PathMap<()> = PathMap::from_iter([("::aa", ())]);
{
    let mut wz = map.write_zipper_at_path(b":");
    wz.graft_map(src);   // focus ":" now carries the source subtrie
    wz.set_val(());      // <-- destroys it
}
// after graft_map, before set_val : ["::aa", ":ab::"]
// after set_val                   : [":", "::aa"]        <-- ":ab::" is gone
```

Whatever one takes `graft`'s treatment of `"::aa"` to be (see the footnote), `set_val` at `":"` may
not delete `":ab::"`. Values are `()` because that is what we measured; the lost thing is a child
pointer, so the value type is irrelevant.

### Silent one-op form (no user `set_val` at all)

`graft_map` supplies its own `set_val` when the source has a root value
(`write_zipper.rs:1470-1474`, feature `graft_root_vals`, on by default):

```rust
let src: PathMap<()> = PathMap::from_iter([("", ()), ("bb::", ())]);   // note the ROOT value
let mut map: PathMap<()> = PathMap::from_iter([("::b", ())]);
map.write_zipper_at_path(b"::").graft_map(src);
// expected: the source's "bb::" under "::"
// actual:   ["::", "::b"]   — none of the source's content is present
```

### It is not "the previous op gets undone"

Two controls, same measurement run:

| variant | result |
|---|---|
| `graft_map` → `remove_val(false)` (a no-op here) → `set_val` | **still lost** — the graft is two ops back |
| `graft_map` → `set_val`, focus's parent node already a `DenseByteNode` (`map = {"::aa","b"}`) | **not lost** |
| `graft_map` → `set_val`, slot_1 free so no upgrade happens (`map = {":"}`) | **not lost** |

The trigger is the LineList→Dense upgrade with a first-byte collision, not adjacency to the graft.

## Mechanism, step by step

Reproducer state, `map = {"::aa"}`, write zipper at `":"` (`node_key = ":"`, focus node = root
`LineListNode`, slot_0 = `"::aa"` → val).

1. `graft_map` → `graft_internal` (`write_zipper.rs:2246`), `node_key.len() > 0` → `node_set_branch(":", src)`
   (`write_zipper.rs:2252-2256`).
2. `LineListNode::node_set_branch` → `set_payload_abstract::<true>` (`line_list_node.rs:1864`, `:942`).
   `overlap = 1 = key.len()`, so the "totally replace the existing downstream branch" shortcut at
   `line_list_node.rs:977-981` does **not** fire — it is guarded on `self.is_child_ptr::<0>()`, and
   slot_0 holds a *value*. `overlap -= 1` → `0` (`:983-985`), no split, so the child lands in the
   free slot_1 (`:994-1000`).
   Node is now `slot_0 = ":" → child`, `slot_1 = "::aa" → val` — the shape
   `validate_node` panics on at `line_list_node.rs:2784-2788` ("ambiguous path violation").
   `set_payload_abstract` has no `debug_assert!(validate_node(self))`, so nothing notices. *(Derived
   from source: a debug build should therefore panic at the next `validate_node` call site reached
   with this node, e.g. `node_remove_val`'s `line_list_node.rs:1813`. We measured release only.)*
3. `set_val` (`write_zipper.rs:1388`) → `node_set_val(":")` → `set_payload_abstract::<false>`.
   `get_payload_exact_key_mut::<false>` (`line_list_node.rs:516-530`) correctly refuses the `":"`
   slot because it is a child, both slots are occupied, neither overlap branch can split, so control
   reaches the upgrade at `line_list_node.rs:1025`.
4. `convert_to_dense` (`line_list_node.rs:1086`):
   - slot_0, `key = ":"`, is a child of length 1 → `replacement_node.set_child(b':', graft)` (`:1105`)
   - slot_1, `key = "::aa"`, length > 1 → wrapped in an intermediate node →
     `replacement_node.set_child(b':', intermediate)` (`:1121`) — **same byte**
   - `ByteNode::set_child` (`dense_byte_node.rs:129`): bit already set → `cf.swap_rec(node)`
     (`:133`, `:1674`) returns the previous child and `convert_to_dense` discards the return value.
     The grafted subtrie is dropped here.
   - then the new value is added at `line_list_node.rs:1046`.

Result: `':'` → `CoFree { rec: {":aa"}, val: () }` → `[":", "::aa"]`. Confirmed by measurement
(4 scripts, all four outcomes predicted from the source before running, all four matched).

## Why the test suite does not see it

The only place the suite puts a value at a just-grafted focus is
`write_zipper_remove_val_beside_child_test` (`write_zipper.rs:2840-2869`) —
`wz.graft(...)` at `"a"` then `map.set_val_at(b"a", 9)`. That is the *legal* shared-key shape
(both slot keys equal `"a"`, slot_1 free), so no upgrade happens and nothing is lost. The collision
needs **three** payloads competing for one byte: a child at `K`, another key `K…` in the other slot,
and then a value at `K`. `write_zipper_insert_prefix_test` (`:4168`) never writes at the focus
afterwards, and `write_zipper_graft_into_grafted_subtrie_test` (`:2874`) grafts at a node boundary,
where `line_list_node.rs:977-981` does fire and clears the slot.

Also note the state is unreachable through `set_val_at` alone — a zipper descends into an existing
child before writing, so the ambiguous node only ever comes from an op that sets a *branch* at a
focus sitting mid-line. That is `graft_internal` and its callers.

## Blast radius

- `graft` / `graft_src_at` / `graft_map` (`write_zipper.rs:1444`, `:1454`, `:1464`): with
  `graft_root_vals` (default) and a source carrying a root value, these destroy the subtrie they
  just installed **within the same call**, no user code required. Internal users inherit it:
  `graft_child_maps` (`write_zipper.rs:118`), `meet_k_path_into` (`:1799`),
  `paths_serialization.rs:195`.
- `insert_prefix` (`:1841`), `remove_prefix` (`:1853`), `join_map_into` (`:1680`), `meet_into`
  (`:1863`): leave the ambiguous node behind; the next `set_val` at that focus detonates it.
- The loss is silent — no panic in release, no `AlgebraicStatus` signal, and the trie enumerates
  consistently before and after.

## Suggested fix

Two independent sites; either one stops the data loss, and we would suggest both:

1. **Do not create the node.** `set_payload_abstract` (`line_list_node.rs:977-981`) already removes
   the colliding slot when it holds a *child*; extend the same shortcut to a slot whose key strictly
   extends `key`, i.e. `IS_CHILD && overlap == key.len() && (self.is_child_ptr::<0>() || node_key_0.len() > key.len())`
   (and the slot_1 twin at `:1006-1011`). A payload at exactly `key` must still be kept — that is the
   legal value-beside-child shape. This also makes `graft` match its own doc comment
   (`write_zipper.rs:76-80`, "replaces the trie below the zipper's focus"), which today it does not
   when the focus lands mid-line: after `wz.graft_map(...)` at `":"` above, `"::aa"` is still there.
2. **Make the upgrade non-destructive.** `convert_to_dense` should not call `set_child` twice for the
   same byte. `merge_from_list_node` / `join_child_into` already do the right thing but need
   `V: Lattice`; failing that, `debug_assert!(key_0.get(0) != key_1.get(0) || …)` would at least turn
   silent loss into a debug-build failure.

---

*Found by differential-fuzzing a Julia port of PathMap against the Rust build; **25 of the 30
remaining divergences** in a 3000-case corpus reduce to this one defect.*

*Footnote — a second, separate observation from the same reproducer: after `wz.graft_map(src)` at
`":"`, the pre-existing path `"::aa"`, which is below the focus, is still present. Fix (1) above
removes it as a side effect.*
