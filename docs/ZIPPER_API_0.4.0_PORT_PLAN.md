# Port plan — upstream PathMap 0.4.0 zipper API (blind zippers) + MORK `ac172d5`

Upstream `~/dev-zone/PathMap` @ `f477a91` (0.4.0); MORK upstream `ac172d5`. Inventories (2026-09-17) were read from the
code bodies on both sides; line numbers below are upstream `src/*.rs` unless prefixed with a Julia path.

## Where we are

- **Our API is prefix-per-type with no shared abstraction**: `zipper_*` (ReadZipperCore, partly forwarded to
  ProductZipperG / DependentZipper / ACTZipper), `wz_*`, `tr_*`, `pz_*` (shared by ProductZipper AND PrefixZipper),
  `pzg_*`, `dpz_*`, `oz_*`, `ez_*` (MORK reuses `ez_` for ExprZipper), `act_*`, `rzt_*`/`wzt_*`, plus `rz_*` aliases.
- Every movement returns the **0.3 shapes**: `ascend*` → Bool; `descend_first/last/indexed_byte` and the sibling
  moves → Bool. No `depth`, `focus_byte`, `ZipperPath`, `PathObserver`, `PathTracker`, `_observed`, `ZipperValuesAt`.
- **Node iteration tokens are not 0.3 either**: the byte node still uses the pre-`44a31ab` UInt128 layout; LineList
  and Empty match 0.3; `ascend_iter_token`, `after_focus`, `TOKEN_LAST`/`TOKEN_AFTER_LAST`, bit 62 are absent. The
  zipper imitates 0.4 with INVALID resets (items 9/10/12c) and a `resume_from` filter in the k-path walk.
- The write zipper lacks most read-side movement (`descend_until`, `ascend_until*`, `to_next_val`, `move_to_path`,
  …: the Lean harness's `skip:wz-gap`); `ReadZipperTracked` has no movement at all.

## Target (upstream 0.4.0 surface, upstream names)

Traits (zipper.rs): `Zipper` :33, `ZipperValues` :58 (`val`), **`ZipperValuesAt`** :78 (`val_at`, moved), `ZipperForking`
:108, `ZipperSubtries` :122, **`ZipperMoving`** :166 (required: **`depth`**, **`focus_byte`**, `val_count`,
`descend_to`, `ascend`, `ascend_until`, `ascend_until_branch`), **`ZipperPath`** :1147 (`path`, `move_to_path`),
`ZipperIteration` :924 (not bounded by ZipperPath), `ZipperAbsolutePath` :1175 (now `: ZipperPath`),
`ZipperConcrete` :1197, `ZipperPathBuffer` :1230, read-only value/iteration traits :747-843, `ZipperInfallibleSubtries`
:874 (now `: ZipperValuesAt`), `ZipperWriting` (write_zipper.rs:16, unchanged), `ZipperCreation`, `ZipperProduct`.

Return-type changes: `descend_indexed_byte` / `descend_first_byte` / `descend_last_byte` / `to_next_sibling_byte` /
`to_prev_sibling_byte` → `Option<u8>` (Julia `Union{Nothing,UInt8}`); `ascend(steps)` / `ascend_until` /
`ascend_until_branch` → bytes ascended; `ascend_byte` stays Bool; `descend_indexed_branch` (deprecated) stays Bool.
`to_next_k_path` with `k > depth` resets to the root.

Observer: `PathObserver` :515 (`descend_to(path)`, `descend_to_byte(b)`, `ascend(steps)`), implementors `Vec<u8>`,
`usize`, `()`, `ArrayVec`, `&mut`, tuples, `MirrorPathObserver` :620, private `TruncatingObserver` :645,
`HashObserver` :713. Every observer-taking method is `<name>_observed(…, obs)`; `<name>(…)` passes `()`:
`descend_until`, `descend_until_max_bytes`, `to_next_step`, `to_next_val`, `descend_last_path`,
`descend_first_k_path`, `to_next_k_path`, `to_next_get_val`, `to_next_get_val_with_witness`.
`PathTracker<Z>` (path_tracker.rs) wraps any `ZipperMoving` and supplies `ZipperPath`. `PathMap` implements
`ZipperValues`/`ZipperValuesAt` (trie_map.rs:608/615); `PathMap::get_val_at` deprecated. `TrieRef*::is_shared` real.

Node token contract (trie_node.rs:195-256, constants :408-478): `IterToken = u64`; `NODE_ITER_INVALID = 1<<63`,
`NODE_ITER_FINISHED = MAX-1`, `TOKEN_LAST`, `TOKEN_AFTER_LAST`, `NODE_TOKEN_NONEXISTENT_BIT = 1<<62`;
`new_iter_token`, `iter_token_for_path` (never a sentinel; canonical), **`ascend_iter_token(tok, n)`**,
**`next_items(tok, after_focus)`**. Byte node `values_idx<<9 | next_byte`; LineList = offset into `key0++key1`.

## Julia shape (naming DECIDED by the user 2026-09-17)

- **Names: upstream method name, plus `!` when it mutates the zipper** (`descend_first_byte!(z)`, `ascend!(z, n)`,
  `to_next_val_observed!(z, obs)`, `depth(z)`, `focus_byte(z)`, `path(z)`, `val(z)`).
- **Old prefixed names are REMOVED** once PathMap/test, MORK/src, MORK/test and every other package using them
  are migrated — no deprecated aliases.
- One generic function per upstream method, methods per zipper type (Julia's version of a trait
  method). An `abstract type AbstractZipper` hierarchy + trait predicates (`is_zipper_path(::Type)`) stand in for
  trait bounds; default methods live on the abstract type exactly where upstream has default bodies.
- `PathObserver`: an abstract type, plus methods on `Vector{UInt8}`, `Int` (as `Ref{Int}`), `Nothing` (= `()`),
  `Tuple`; `MirrorPathObserver`, `HashObserver`, `TruncatingObserver` as structs. `nothing` observer compiles away.
- Option<u8> → `Union{Nothing,UInt8}` (small union, no allocation).

## Phases (each: port upstream tests first, warm PathMap suite, Lean harness seeds 1–3, fuzz, warm MORK suite + JET ratchet, commit)

0. **Baseline, no contract change** — DONE 2026-09-17: 4470349 ported; the 32 zipper regression tests
   (zipper.rs:5926-6607) ported as `test/test_upstream_zipper_iter_state.jl`, written in the 0.4.0 names with a
   `Shim040` block (delete in phase 3). They found a **segfault**: the k-path walk popped an ancestor pushed by
   `descend_to` (token INVALID) and handed the sentinel to dense `next_items`, whose `@inbounds` read went wild
   (`read_zipper_k_path_edge_cases`, long path, k = 70; crashed the MettaJam server). Fixed as upstream
   `ac241e2` does (loop back to the re-sync); dense `next_items` is bounds-checked again. The Lean harness never
   calls `to_next_k_path` after `descend_to`, so it could not see this — widen its op sequencing in phase 2.
   321/321.
1. **Token contract** — DONE 2026-09-17: `IterToken = UInt64` and the 0.4.0 constants (load-time layout
   asserts), `ascend_iter_token`, `next_items(node, tok, after_focus)`; byte node `values_idx<<9 | next_byte`
   with the bit-62 rule (supersedes our 12c workaround); LineList offset tokens + `TOKEN_LAST` + `after_focus`
   (e0f32c0, 662e593); Empty `TOKEN_AFTER_LAST`; sentinel inputs raise instead of reading garbage. The zipper
   passes `after_focus = false` (behaviour-preserving, traced per LineList case); MORK's node tests updated.
   Upstream node tests: `test/test_upstream_iter_token.jl` 121/121. Originally planned scope: `TrieNode.jl` constants/declarations (UInt64), EmptyNode, TinyRef, Bridge, ByteNode
   (dense_byte_node.rs:315-381, 1010-1053), LineList (line_list_node.rs:1950-2133), Viz callers; node tests
   (`byte_node_iter_token_crosses_mask_word_boundaries`, `test_line_list_ascend_iter_token`,
   `…after_focus_skips_partial_item`, `…skips_descendant_item`, `…uses_canonical_tokens`).
2. **Zipper token consumers** — DONE 2026-09-17, all as upstream bodies: `_reascend_iter_token!` in ascend,
   ascend_byte, ascend_within_node and the k-path exits (replaces our INVALID writes); `descend_first_byte`
   reuses the token (nonexistent early-out, `ascend_iter_token` for a partial item); token-based
   `to_next_sibling_byte`; `to_prev_sibling_byte` = `to_sibling(false)` with e659a96 (dense via
   `next_bit`/`prev_bit`, `bit_sibling` removed; LineList prev rule); `to_next_get_val` `< TOKEN_LAST`;
   `k_path_internal` = zipper.rs:3131-3223 with `continue_from_focus` (our `resume_from` filter and re-sync
   loop removed; the mutant with `false` fails 7 + 80); native `descend_until_max_bytes`;
   `descend_to_existing_byte` invalidates in the partial-key arm. Internal `_zc_*` functions already
   return the 0.4.0 shapes (byte / count); the public `zipper_*` still return Bool until phase 3. An
   AllocCheck site from a `UInt8[]` fallback in LineList `ascend_iter_token` was removed (pin 3 held).
   Lean seeds 1–6: the same 7 FINDINGS-#8 programs. Originally planned: `reascend_iter_token` in ascend / ascend_within_node; `descend_first_byte`
   (2179-2233); token `to_next_sibling_byte` (2359-2424); `to_next_get_val` `< TOKEN_LAST`; `k_path_internal`
   3132-3222 verbatim (drops our `resume_from` and resync loop).
3. **Generic API + return shapes** — DONE 2026-09-17. `src/zipper/ZipperTraits.jl` is the trait surface:
   `abstract type AbstractZipper` (every zipper subtypes it), one generic function per upstream trait method
   with upstream's name + `!` when it moves, upstream's default bodies as `AbstractZipper` methods, and the
   `PathObserver` protocol (`nothing` = the no-op `()`, `Vector{UInt8}`, `Base.RefValue{Int}`, tuples,
   `MirrorPathObserver`, `HashObserver`, `TruncatingObserver`). Every zipper type converted: Read, Write,
   tracked, ZipperHead, TrieRef, Product, ProductG, Dependent, Prefix, Overlay, Empty, ACT — old prefixed
   names (`zipper_*`, `wz_*`, `tr_*`, `pz_*`, `pzg_*`, `dpz_*`, `oz_*`, `ez_*`, `act_*` zipper, `rz_*`,
   `rzt_*`, `wzt_*`, `zh_*`, `zho_*`) REMOVED, per-type duplicates of a default deleted, and
   ProductZipperG's private `_zpg_*` dispatch table deleted in favour of the generics. The write zipper
   inherits the movement it lacked (closes the harness's `skip:wz-gap`); `PathMap` gained `val` / `val_at` /
   `is_shared` (trie_map.rs:593-623); the spec harness's Bool→byte/count adapters are identities now.
   Callers migrated across PathMap, MORK, Core, MorkServer, MorkSupercompiler, MORKTensorNetworks and
   WorldModel. A parser-based scanner (`~/csai-work/gates/probes/shadow_scan.jl`) found every place a local
   named `path`/`val`/`depth`/`child_mask` would shadow the new generic — 8 in PathMap, 6 elsewhere.
   Behaviour changes to know: `descend_to_check!` never restores on failure (upstream zipper.rs:210-213;
   MORK's coref helpers normalise), `remove_prefix!` returns Bool from a now-counting `ascend!`, and
   `ez_reset!` is MORK's own ExprZipper function again. Originally planned:  abstract types, upstream-named generics, `depth`, `focus_byte`, Option/count
   returns, `ZipperPath`, `ZipperValuesAt`, for every zipper type (Read, Write, Tracked, TrieRef, Product,
   ProductG, Dependent, Prefix, Overlay, Empty, ACT). Fill the write-zipper movement gaps. Lean harness: the
   `sp_ascend!`/`sp_moved_byte` adapters become identities; drop `skip:wz-gap` where filled.
4. **Observers** — `PathObserver` + implementors, `_observed` variants, `PathTracker`, `HashObserver`,
   `MirrorPathObserver` (ProductZipperG / Dependent `descend_until_observed`), Overlay chunked descend.
5. **MORK** — `ac172d5`: Leapfrog.jl (depth for `length(zipper_path)`, returned byte for `path[end]` after moves,
   `focus_byte` for the pre-move last byte, count equalities on ascend); Space.jl coref helpers
   (`_coref_path_length` → `depth`); Sinks.jl has no 1:1 site (structure differs; see inventory). Remove direct
   struct-field reads where `depth`/`path` now suffice.
6. **Old names** — remove the prefixed names once PathMap/test, MORK/src, MORK/test are migrated (or keep as
   deprecated aliases for one release — user decision). Update `workflows/PORT_NAME_MAP.tsv`, CODEMAP.

## Size

Return-type-changing calls: PathMap/test 124, MORK/test 18, MORK/src 24. Renames: ~1000 call sites across
PathMap/src+test and MORK/src+test (plus function-as-value references in the battery and MORK runtests).

## Upstream oddities to check with the Rust probe before copying

- Default `k_path_default_internal` (zipper.rs:1112-1139) appears not to terminate for `k == 0` with no sibling;
  ACT (arena_compact.rs:3216) and PrefixZipper (:570) return `true` for `k == 0` where the doc says false.
- `PrefixZipper::to_next_k_path_observed` returns false without resetting when `depth < k` (:588).
- `ReadZipperCore::to_next_k_path_observed` uses an absolute `base_idx` (:2680).
- `ProductZipperG`/`DependentProductZipperG::val_count` `unimplemented!`, `OverlayZipper::val_count` `todo!`.

## Latent defects of ours found by the inventory

- `pzg_val` with a PrefixZipper factor → MethodError (`ProductZipperG.jl:34`, no `pz_val(::PrefixZipper)`).
- `zipper_ascend!(::ACTZipper, n)` = `(act_ascend!(z, n); n > 0)` ignores failure (`ArenaCompact.jl:1014`);
  `_zpg_ascend!(ACT)` always true (:1043).
- `zipper_descend_to_check!` does not restore on failure while `pz_`/`pzg_` do (MORK compensates, Space.jl:1311-1330).
- `_to_next_get_val!` misses 4470349 (token not invalidated at the root-escape exit, Zipper.jl:874-879).
