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

- `401881e` dense `iter_token_for_path` for 2+-byte missing keys (code is pre-fix; reproducer not run)
- `8082317` `to_next_k_path` with k > depth should reset to root (code differs; not run)
- `4470349` `to_next_val` root-escape exit should invalidate the token (not run)
- `e659a96` LineList `get_sibling_of_child` prev direction wrong for missing keys — no callers in `src`
- `45f78dc` TrieRef unchecked `consumed - node_key_len` (`zipper/TrieRef.jl:100-101`) — unreachable today
- `val_count` at a focus counts from the zipper root (ACT and read zipper, `{aa,ab,b}` at `aa` → 3); `FINDINGS` A1 says 1 — **verify against the upstream binary before calling it a bug**

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
