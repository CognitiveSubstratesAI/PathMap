# PathMapsSpec — an executable Lean 4 specification of our Julia `PathMaps`

The oracle for our Julia PathMap port: a total, executable definition of what each trie and zipper operation
*means*, used to check `PathMaps` by differential fuzzing.

## Provenance

Adapted from Adam Vandervorst/PathMap `lean/` at commit `f477a91` (MIT; see `LICENSE-UPSTREAM`). The namespace is
renamed `PathMapModel` → `PathMapsSpec` and every file carries an attribution header. Upstream's README explains
the design; the part we keep unchanged is its core decision — **the model is not a trie**. A map is a canonical,
sorted, prefix-closed list of `(path, value?)` entries (a location can exist without a value), and a zipper is that
list plus a root and a relative path. Iteration is specified by path order, never by walking nodes, so node-handling
bugs cannot be present in both the model and an implementation.

## What this model specifies

**The intended behaviour of our port** (decided 2026-09-16), not its current behaviour. Known defects therefore
appear as divergences until they are fixed (the port list is `../docs/UPSTREAM_DELTA_2026-09-16.md`). Where our
port deliberately differs from upstream (`../test/differential/ADAPTATIONS.md`, `UPSTREAM_BUGS.md`), the model is
changed to our intended semantics and the change is noted at its site.

## Status

- **Phase A (5eff3ff):** the model builds; its `#guard` law checks and regression fixtures pass.
  `PathMapsSpec/Fuzz.lean` and `Main.lean` are still upstream's operation table and trace format (the Rust
  harness's contract) — kept as a working baseline and to be replaced.
- **Phase B (done 2026-09-16):** `../test/differential/spec/` — one op table (`ops.toml`, 25 read-zipper
  operations) generating both `PathMapsSpec/SpecOps.lean` and `ops_generated.jl` via `../tools/gen_spec_ops.jl`;
  `SpecHarness.jl` runs PathMaps in-process against a resident `pathmaps-oracle --server --spec`
  (2000 programs in ~9 s warm). First results are recorded in `../docs/UPSTREAM_DELTA_2026-09-16.md`.
- **Phase C:** write-zipper and algebra operations, then a ratchet in the PathMap suite. Originally planned as:
  a Julia-native harness (not a port of the Rust crate or the Python drivers): one operation
  table as data from which both the Lean and the Julia sides are generated, an in-process driver in the warm
  Revise session talking to a resident `pathmaps-oracle`, Julia threads for parallelism, shrinking with
  `../test/differential/shrink.jl`, and a known-divergence ratchet in the PathMap suite.

## Build

```bash
cd PathMap/lean && lake build        # toolchain pinned in lean-toolchain (v4.33.1); no dependencies
```

A build failure in `PathMapsSpec/Check.lean` means a law or a regression fixture broke.
