# Upstream delta 2026-09-16 — PathMap `143ecd1..f477a91` against our Julia port

Upstream: `~/dev-zone/PathMap` @ `f477a91` (0.4.0 line). MORK upstream `~/dev-zone/MORK` @ `ed57c67`: one commit
past our port point (`ac172d5`, adapts to the PathMap 0.4.0 blind-zipper API — port only together with that API).

152 non-merge PathMap commits: ~54 fixes, ~27 blind-zipper API (0.4.0, breaking), 7 perf, ~11 upstream test
infrastructure (Lean model, differential fuzzer, `lean/FINDINGS.md`), ~33 CI/docs.

**Method.** Four read-only audits, one per area. Every verdict rests on the upstream diff plus the BODY of our
Julia function (file:line), never on a name search. "WE HAVE THE BUG" = a reproducer executed on our port against
the upstream-fixed expectation (upstream tests translated, or the upstream HEAD binary built from a copy of
`test/differential/rust_probe`). Probes: session scratchpad `audit_{algebra,iter,move,trie}/`.

## P0 — hangs and wrong hashes (not upstream commits)

**Both FIXED (phase D).** #1: `zipper_descend_first_k_path!` / `zipper_to_next_k_path!` now port upstream's
`ReadZipperCore` token walk (143ecd1 `k_path_internal`, which upstream had before our port point) with
86180a2 and 8082317, plus two fixes expressed in our 0.3 token contract: bdbdfdc (a finished walk leaves
NODE_ITER_INVALID, not FINISHED — harness program #357) and never re-yielding the k-path being resumed from
(upstream's `ascend_iter_token` effect — harness program #526, `0002,0302,0302`). Upstream's k-path tests
1–9, a are ported (`test/test_upstream_k_path.jl`); mutants without the base guard / the 8082317 reset / the
resume skip / the INVALID token each fail them. The harness's `skip:known-hang` is gone (op table v3).
#2: `zipper_shared_node_id` ports upstream's guard, with `zipper_is_shared` (zipper.rs:2618-2653);
`test/test_shared_node_id.jl` (incl. upstream `cata_test_cached`) fails 7 assertions on the old body.


| # | defect | where | evidence |
|---|---|---|---|
| 1 | `descend_first_k_path` never returns from a focus with no children and no later sibling (trait-default loop; upstream `FINDINGS.md` #6). Upstream's `ReadZipperCore` overrides it with a token k-path. | `src/zipper/Zipper.jl:1082-1098` | hung the warm server for 12 min |
| 2 | `zipper_shared_node_id` lacks upstream's guard (`!is_shared \|\| key non-empty \|\| value present → None`): returns ids for unshared nodes and ignores the focus value, so `cata_cached` reuses results across paths with different focus values — **`map_hash` is affected** | `src/pathmap/Morphisms.jl:133-137` (upstream `zipper.rs:2639-2652`) | `cata_cached` counts 6 / 4 where `cata_side_effect` counts 5 |

## P1 — silent wrong results / data loss

| # | upstream | defect | where |
|---|---|---|---|
| 3 | `b2a0c09` | `restrict` drops a value on a branching path (`{ab,abc,abd}` → loses `ab`) | `nodes/LineListNode.jl:2095-2112` |
| 4 | `e0f47f7` | `join_k_path_into(0)` rewrites dense nodes / asserts elsewhere; must be identity | `zipper/WriteZipper.jl:1443-1500`, `DenseByteNode.jl:1583-1609` |
| 5 | `f0cd6b7` | graft / `insert_prefix` / `join_map` at a mid-key focus keep stale subtries (duplicate values; 486/3000 random cases); `insert_prefix("")` asserts. Resolves the "SHARED" note in `test/differential/UPSTREAM_BUGS.md` | `WriteZipper.jl:907-929` |
| 6 | `8679140` + `e7879a6` | `join_k_path_into` double-counts coinciding keys and loses keys (4/600 random); `factor_prefix` legal-overlap rule too loose | `LineListNode.jl:1885-2003`, `DenseByteNode.jl:1567-1609` |
| 7 | `1438d2b` + `e7879a6` | after `drop_head`, `get_node_at_key("a")` on `("ab","ac")` exposes only `b` | `LineListNode.jl:1889-1892` |
| 8 | `b6eac3a` / `8a9eb75` | `graft_masked_branches` ignores source branches stored below the masked byte and keeps masked-byte values (5 cases differ from upstream HEAD) | `WriteZipper.jl:722-760` (docstring's "same observable result" is false) |
| 9 | `d19a7c8` | every ascend (`ascend`, `ascend_byte`, `ascend_until`, `ascend_until_branch`, ascending `move_to_path!`) keeps a stale iteration token → `to_next_val!` returns false with values ahead; wrapper zippers delegate here | `Zipper.jl:784-829` |
| 10 | `f365d00` (+`86180a2` test) | `descend_first_byte` stores the advanced token unconditionally → `to_next_val!` skips values after `descend_first_byte` / `to_next_step` / `descend_first_k_path` | `Zipper.jl:742-772` (NB `lean/FINDINGS.md` #2 predates this fix) |
| 11 | `cab3ed7` | ACT `reset` of a zipper rooted off-trie restores `invalid = 0` → returns the ancestor's value/existence | `pathmap/ArenaCompact.jl:611-619, 707-716` (needs `origin_invalid`, also in `copy`) |
| 12 | — (found via `cbbf219`'s test) | `act_zipper_with_root_here!` reads `origin_ndepth` before the stack swap → wrong bytes after `reset` at a mid-line root | `ArenaCompact.jl:613` |

### Confirmed later the same day by the Lean-model harness (`test/differential/spec/`)

Each case was attributed by replaying the program to the diverging step and testing the mechanism on that
state, not by the name of the op where the traces first differ (probes: session scratchpad `spec_attr*.juliasrc`).

| # | defect | where | evidence |
|---|---|---|---|
| 12a | **`zipper_val_count` is wrong whenever the focus is inside a node key** (not a node boundary and not an existing child edge). Upstream's read zipper answers `get_focus()`: 0 for a missing focus, otherwise the count below the synthesised focus (`zipper.rs:2075-2088`). Our fallback instead copies the zipper and counts `to_next_val` steps, which do not stop at the focus subtree, so it counts every value **after** the focus inside the zipper root, even when the focus does not exist. (Upstream `FINDINGS` A1 is the separate ACT variant.) | `zipper/Zipper.jl:658-680` | 49 of 200 programs (seed 1) first differ on `n`; all 49 take the fallback branch; the model's `n` equals an independent child-mask count in all 49. 48 equal "focus value + values after the focus" (17 of them only once the copied stale token is discarded, i.e. items 9–10 compound it); 1 (#173) is 12c |
| 12b | **`zipper_val_at` misses values when the zipper root lies below the root node**: `read_zipper_at_path` makes `root_node` the node reached along the root path (`Zipper.jl:375-385`), but `zipper_val_at` walks the FULL `prefix_buf` from that node instead of the part after `root_key_start` | `zipper/Zipper.jl:607-618` | #1823 (seed 2): root `0201`, `root_key_start = 1`, `root_node` ≠ map root; `val_at` → `-`, model → `68` |
| 12c | `401881e` (was P3, now executed): dense `iter_token_for_path` returns a fresh token (iterate from the start of the node) for a missing key of 2+ bytes; upstream returns `NODE_ITER_INVALID`. `to_next_val` from such a focus jumps **backwards** | `nodes/DenseByteNode.jl:1337` | 6 programs (seed 2 #511, #653, #955, #1200, #1422, #1871): focus missing, `DenseByteNode`, node key ≥ 2 bytes; a fresh zipper at the same path still differs |

With `n` masked, 2000 programs (seed 2) differ in 30: 23 `to_next_val` from stale tokens (items 9–10: discarding
the focus token, or a fresh zipper at the same path, reproduces the model), 6 `to_next_val` from 12c, 1 `val_at`
(12b). Only each program's FIRST divergence is reported, so fixing these can uncover more.

Not exercised by phase B: `to_next_k_path` with k > depth (P3 `8082317`) — the walk calls it only after
`descend_first_k_path` succeeded, so depth ≥ k; and the childless-focus k-path case is skipped (#1).

### Found by the harness's write / algebra ops (phase C, `ops.toml` version 2)

**Phase D progress (2026-09-16).** Harness population (1000 programs, seed 1): 624 → 618 (P0 fixes) → **266**.
- **#18 FIXED** — `as_tagged(::TrieNodeODRc)` returns the `EmptyNode` singleton for the empty sentinel, as upstream's
  `TaggedNodeRef::EmptyNode`; every `*_dyn` / node query now handles an empty operand. Knock-on ports from the same
  change: `wz_meet_2!`'s Identity arm reports None for an empty source (write_zipper.rs:2096-2105).
- **#16 FIXED** — `node_count_branches_recursive` ported (trie_node.rs:682-697) and used by `wz_child_count`;
  `wz_child_mask` reads `as_tagged(focus_stack[end])`.
- **graft_map / join_map_into** now take the source through `_pm_into_root` (upstream `map.into_root()`,
  write_zipper.rs:1518/1794): an empty root counts as no root (harness #240/#697/#923 created the focus path).
- **remove_unmasked_branches** ported 1:1 (write_zipper.rs:2271-2297): a node key reaching a child removes inside
  the child (harness #766).
- **P1 #8 (graft_masked_branches)** — the 0/1/2-bit arms are upstream's (`graft_src_at` per byte, via
  `get_node_at_key` + the `graft_root_vals` value step; harness #607); 3+ bits use the same per-byte graft.
- **P2 #15 FIXED** — `0375ee5` ported with its upstream test.
- **#17 FIXED** — `tr_make_map` ports trie_ref.rs:327-335 (focus value as root value; an empty focus node is no
  root); `wz_graft!(z, src_anr, src_val)` is upstream `graft` with the `graft_root_vals` step (the 2-argument
  form stays node-only = `graft_internal`). Population 266 → **161**. The one newly exposed class
  (`to_next_val ret`, #938) is item 9: `ascend 2` left the read zipper's token from its old focus (a token reset
  or a fresh zipper finds the value the model expects).
- **2026-09-17 batch — 161 → 2.** 12a (`zipper_val_count` = upstream zipper.rs:2075-2088 via
  `get_node_at_key`), 12b (`zipper_val_at` walks `node_key ++ path` from the focus node, zipper.rs:2891-2911),
  item 9 (`d19a7c8`: every in-node ascend invalidates the token), item 10 (`f365d00`: `descend_first_byte`
  keeps the advanced token only when the item ends at the focus), P1 #4 (`join_k_path_into` = upstream's
  current body: `into_option` drops an empty focus, `k = 0` is the identity — the harness no longer skips it,
  op table v4). Model change (`ofValRes` follows upstream `AlgebraicResult::status()`: an identity without
  SELF_IDENT is Element) closed the 5 `meet_into ret` programs. 12c produced no remaining first divergence.
  Verified WARM: related test files, PathMap suite 172/172 and MORK 8168/8168 in `MORK/tools/warm_suite.sh`.
- **The 2 left, attributed:** #686 is **P1 #5** (`f0cd6b7`): `insert_prefix` at a one-byte write-zipper root kept
  the old key run beside the prefixed copy (`graft_internal` lacks `node_remove_all_branches`), surfacing later at
  `set_val`. #747 is an **upstream defect we ported 1:1**: dense `prestrict_abstract` (dense_byte_node.rs:489-545)
  drops a value-only entry (or an entry's value) when `other` has no value at that byte without clearing
  `is_identity`, so `restrict` reports Identity and the branch survives.

1000 programs (seed 1): 624 diverge on their first step that differs (`test/differential/spec/KNOWN_DIVERGENT.tsv`,
ratcheted by `test/lean_spec_gate.jl`). The classes below were attributed by replaying the program to the
diverging step and applying the candidate fix to that state (probe `spec_c3.juliasrc`). Upstream names are used
throughout so a search from either side finds the row.

| # | defect | where | evidence |
|---|---|---|---|
| 16 | **`child_count` on the write zipper ignores a node key that spans a child edge.** Upstream's `WriteZipperCore::child_count` calls `node_count_branches_recursive(focus, node_key)` (`trie_node.rs:682-697`), which steps into the child when the key covers its edge; our port never ported that helper (it is only named in a comment, `nodes/TrieNode.jl:20`) and calls one-node `count_branches`. Upstream's `LineListNode::count_branches` documents that a full child key answers 0 because "the node would have advanced", which a write zipper at a mended or un-mended root does not guarantee (`mend_root` skips origins of length ≤ 1 on both sides). | `zipper/WriteZipper.jl:1616-1621` `wz_child_count` | 156 programs first differ on `W.c`; a restatement of `node_count_branches_recursive` reproduces the model in 146. Of the other 10: 3 reach an empty-sentinel child (item 18), **7 are unattributed** (6 `graft_masked_branches`, 1 `set_val`) |
| 17 | **`graft_root_vals` is not applied on two paths.** (a) `make_map` from a TrieRef keeps the focus node but drops the focus value: upstream `trie_ref.rs:327-335` passes `self.val().cloned()` as the root value; our `tr_make_map` never sets `root_val`. (b) `graft` from a source zipper: upstream `write_zipper.rs:1497-1505` sets or removes the focus value from `read_zipper.val()` after `graft_internal`; our `wz_graft!` takes an `AbstractNodeRef`, which carries no value, so the step cannot happen (the signature needs the source value, as `wz_meet_into!`'s `src_root_val` already does) | `zipper/TrieRef.jl:232-252` `tr_make_map`; `zipper/WriteZipper.jl:991-993` `wz_graft!` | (b) `graft W.v` 34/34: the model's value is the source's focus value. (a) 34 of 52 `graft_map` / `join_map_into` / `make_map_val_count` cases match once `make_map` carries the value; the other 18 differ for another reason (not yet attributed) |
| 18 | **The empty sentinel reaches `*_dyn` / node methods as `nothing`** (the P2 common root cause) on many more paths than P2 lists: `tr_get_focus_anr` / `tr_get_focus_rc` call `get_node_at_key(as_tagged(focus_node), key)` with `as_tagged` → `nothing`; `wz_child_count` calls `count_branches(nothing, key)` on an empty focus; `wz_restrict!`, `wz_subtract_into!`, `wz_meet_into!`, `wz_join_map_into!`, `wz_meet_2!` call `prestrict_dyn` / `psubtract_dyn` / `pmeet_dyn` / `pjoin_dyn` with a `nothing` operand; `join_k_path_into` reaches `make_unique!` on the sentinel (`nodes/TrieNode.jl` assertion) | throw sites, by function: `TrieRef.jl:tr_get_focus_anr`, `TrieRef.jl:tr_get_focus_rc`, `WriteZipper.jl:wz_child_count`, `wz_restrict!`, `wz_subtract_into!`, `wz_meet_into!`, `wz_join_map_into!`, `wz_meet_2!`, `TrieNode.jl:make_unique!` | the THROW classes in KNOWN_DIVERGENT.tsv; `remove_unmasked_branches` @`DenseByteNode.jl` is P2 #15 |

Not yet attributed: `restrict` / `meet_into` / `join_k_path_into` / `take_map_restore` / `remove_branches` /
`restricting` `ret` classes, `join_map_into W.e`, `graft W.e`, `graft_masked_branches W.n` (each 1–5 programs),
and the 7 + 18 residues above. Each needs its own replay before it is called a defect.

Write-side ops of upstream's model that the harness does NOT run, and why, are listed in `ops.toml` (`gaps`):
`prune_ascend`, `graft_src_at`, `get_val_or_set_mut_with`, `descend_until_observed` and `to_next_get_val` have no
counterpart in our port; the read-only movement ops without a write-zipper method run on `rz` only
(`skip:wz-gap`).

## P2 — throws where upstream returns a result

| # | upstream | defect | where |
|---|---|---|---|
| 13 | `94e0ac2` | `meet_2` with a dangling/empty source → `MethodError pmeet_dyn(::Nothing, …)` | `WriteZipper.jl:1239-1261` |
| 14 | `3a016ef` | `join_into_take` asserts on a dangling destination; wrong status for a dangling source | `WriteZipper.jl:2087-2121` |
| 15 | `0375ee5` | dense `remove_unmasked_branches` at a non-existent path asserts | `DenseByteNode.jl:1425-1428`, `WriteZipper.jl:1940-1950` |

Common root cause of 13, 14 and the throws in 4 and 6: `as_tagged(rc)` returns `nothing` for the empty sentinel
and most `*_dyn` methods have no `Nothing` method. Mapping the sentinel to `EmptyNode` (as `_as_tagged_or_empty`,
`LineListNode.jl:2079`, already does locally) or guarding at the zipper ops closes most of them.

## P3 — latent or not yet executed

- ~~`401881e`~~ → confirmed, now item 12c
- `8082317` `to_next_k_path` with k > depth should reset to root (code differs; not run)
- `4470349` `to_next_val` root-escape exit should invalidate the token (not run)
- `e659a96` LineList `get_sibling_of_child` prev direction wrong for missing keys — no callers in `src`
- `45f78dc` TrieRef unchecked `consumed - node_key_len` (`zipper/TrieRef.jl:100-101`) — unreachable today
- ~~`val_count` at a focus~~ → confirmed, now item 12a (the ACT zipper's `act_val_count` has the same shape; unverified)

## Already correct (evidence executed)

`16e05af`, `f3fd56d`, `5361e2a`, `c6bb6af`, `a1c53e2` (read only), `e276ccd`, `466f396`, `ab2fe2f`, `330c85e`,
`c86b9f5`, `56c7b2c`, `b381767`, `bd2059f`, `3d0103c`, `bf2b498` (dangling case), `471b972` (observable).

## Not applicable

Upstream-only structures: `46761a0`, `fad58f4`, `bdbdfdc`, `ac241e2`, `888217e`, `e0f32c0`, `662e593`, `7c632f9`,
`556c4ed`, `e55e427` (feature), `e4bd089`/`85f4daa` (reverted), `d479d33` (reverted by `e7879a6`).

## 0.4.0 contract changes (only if we adopt the blind-zipper API)

`951d987`, `48658cd`, `9485052`, `fb4f9c9`, `4917097` (iteration-token contract) plus the ~27 blind-zipper API
commits (`PathObserver`, `_observed` renames, `ZipperValue`/`ZipperValueAt`, …) and MORK `ac172d5`.
Under 0.3 semantics the equivalent rule is: invalidate the token on every in-node focus change.

## Differential oracle

- `test/differential/rust_probe` builds against `~/dev-zone/PathMap` by path; a copy built against HEAD with
  `RUSTFLAGS="-C target-cpu=native"`.
- Re-running our vendored 3000-case fuzz corpus against HEAD: **100 cases diverge, 76 of them new** (our output
  equals the OLD vendored upstream answer), mostly GRAFTMAP / INSPREFIX / REMPREFIX / JOINMAP → expected from #5.
  Some (e.g. 00020) are unattributed.
- `expected/*.tsv` and `UPSTREAM_BUGS.md` must be regenerated / re-checked after the fixes.
