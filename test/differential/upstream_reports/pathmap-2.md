`graft_map` destroys the subtrie it just grafted, when the source has a root value

---
`graft_map` plants the source's root node and then writes the source's root value. The second step
lands in the slot the first step just wrote and replaces it, so the grafted subtrie is lost.

## Reproducer — one op

```
target = {"::b"}
source = {"bb::"} with a ROOT VALUE set
zipper at "::"
wz.graft_map(source)
```

| | result |
|---|---|
| observed | `["::", "::b"]` — none of the source's content is present |
| expected | the source's `bb::` to appear under the graft point |

## Isolating it

```
source has a root value   ->  [::, ::b]        source content GONE
source has NO root value  ->  [::b, ::bb::]    source content present
single-byte graft point   ->  [:, :b]          gone again (not about multi-byte keys)
```

Row 2 is the control: with the root value removed and nothing else changed, the graft survives.

## Where it comes from

`WriteZipperCore::graft_map` (write_zipper.rs:1464):

```rust
let (src_root_node, src_root_val) = map.into_root();
self.graft_internal(src_root_node);
#[cfg(feature = "graft_root_vals")]                 // DEFAULT feature
let _ = match src_root_val {
    Some(src_val) => self.set_val(src_val),
    None          => self.remove_val(false)
};
```

`into_root` returns `Some(node)` whenever the root node is non-empty, so `graft_internal` does run —
the subsequent `set_val` is what removes its effect. Only reachable when the source carries a root
value, since otherwise `remove_val` runs instead.

Found by differential-fuzzing a Julia port of PathMap against the Rust build.
