# PathMap.jl

[![CI](https://github.com/CognitiveSubstratesAI/PathMap/actions/workflows/CI.yml/badge.svg)](https://github.com/CognitiveSubstratesAI/PathMap/actions/workflows/CI.yml)
[![Docs (stable)](https://img.shields.io/badge/docs-stable-blue.svg)](https://cognitivesubstratesai.github.io/PathMap/stable/)
[![Docs (dev)](https://img.shields.io/badge/docs-dev-blue.svg)](https://cognitivesubstratesai.github.io/PathMap/dev/)
[![Code Style: Blue](https://img.shields.io/badge/code%20style-blue-4495d1.svg)](https://github.com/invenia/BlueStyle)
[![Aqua QA](https://raw.githubusercontent.com/JuliaTesting/Aqua.jl/master/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)
[![Julia 1.12+](https://img.shields.io/badge/Julia-1.12%2B-blue)](https://julialang.org)

A high-performance, structurally-shared, byte-keyed trie map for Julia —
the substrate for [MORK.jl](../MORK) and the broader
[Hyperon](https://wiki.opencog.org/w/Hyperon) ecosystem.

Inspired by the Rust [`pathmap`](https://github.com/trueagi-io/PathMap) crate.
This is an independent Julia implementation with several capabilities
that go beyond the current upstream Rust release.

---

## Overview

`PathMap{V}` is a key-value store where keys are arbitrary **byte slices**
and values are of type `V`.  Its defining properties are:

| Property | Description |
|----------|-------------|
| **Prefix compression** | Common prefixes are stored once (PATRICIA trie) |
| **Structural sharing** | Subtries can be shared across multiple maps without copying |
| **Lazy copy-on-write** | Shared structure is cloned only at the moment of mutation |
| **Path algebra** | First-class join, meet, subtract, restrict, drop-head operations |
| **Cursor navigation** | Zippers provide zero-copy positional read/write access |
| **Morphisms** | Catamorphism (fold) and anamorphism (unfold) with optional caching |

---

## Installation

```julia
using Pkg
Pkg.develop(path = "path/to/PathMap")
```

Requires Julia ≥ 1.10.  No external runtime dependencies beyond `Zlib_jll`.

> **Note**: PathMap.jl is not yet registered in the Julia General Registry.
> Clone the repo and use `Pkg.develop` as shown above.

## Benchmarks

Run the included benchmark suite:

```bash
julia --project=. benchmarks/benchmarks.jl
```

Covers construction (dense/sparse keys), word-index workload, algebraic
operations (union/subtract/policy-sum), morphisms (cata_cached, map_hash),
and serialization (.paths round-trip).  Pass `--tune` for longer calibration.

---

## Quick Start

```julia
using PathMap

# Create a map and insert values
m = PathMap{Int}()
set_val_at!(m, b"books:fiction:dune",         1965)
set_val_at!(m, b"books:fiction:neuromancer",  1984)
set_val_at!(m, b"books:non-fiction:cosmos",   1980)
set_val_at!(m, b"movies:blade_runner",        1982)

# Point lookup
get_val_at(m, b"books:fiction:dune")          # => 1965
get_val_at(m, b"books:missing")               # => nothing

# Structural join (union) — returns a new map
other = PathMap{Int}()
set_val_at!(other, b"books:fiction:foundation", 1951)
result = pjoin(m, other)                      # all paths from both

# Navigate with a zipper
rz = read_zipper_at_path(m, b"books:fiction:")
while zipper_to_next_val!(rz)
    println(String(zipper_path(rz)), " => ", zipper_val(rz))
end
```

---

## Core Concepts

### PathMap

`PathMap{V}` is the top-level container.  It owns the trie root and
provides high-level read/write methods.

```julia
m = PathMap{String}()
set_val_at!(m, b"key", "value")
val = get_val_at(m, b"key")           # "value"
remove_val_at!(m, b"key")
val_count(m)                           # number of stored values
```

### Zippers — Cursors into the Trie

A **zipper** is a lightweight cursor that navigates the trie without
copying.  There are two flavours:

| Type | Purpose |
|------|---------|
| `ReadZipperCore` | Read-only navigation and queries |
| `WriteZipperCore` | Mutable operations (set, remove, graft, algebraic ops) |

```julia
# Read zipper
rz = read_zipper(m)                        # start at root
zipper_descend_to!(rz, b"books:")
zipper_child_mask(rz)                      # which byte-branches exist
zipper_val(rz)                             # value at cursor (or nothing)

# Write zipper
wz = write_zipper(m)
wz_descend_to!(wz, b"books:sci-fi:")
wz_set_val!(wz, 2024)                      # create or overwrite
wz_remove_val!(wz)                         # remove
wz_insert_prefix!(wz, b"new:")             # prepend to all paths below
wz_remove_prefix!(wz, 8)                   # strip 8 bytes from all paths
```

### Algebraic Operations — Path Algebra

All operations work structurally on the trie.  Values at coinciding
paths are merged according to the value type's `Lattice` implementation
(or a user-supplied [policy](#policy-api)).

| Operation | Symbol | Description |
|-----------|--------|-------------|
| Join (union) | `pjoin` | Path present in **any** operand |
| Meet (intersection) | `pmeet` | Path present in **all** operands |
| Subtract | `psubtract` | Paths in left but **not** right |
| Restrict | `prestrict` | Paths in left whose **prefix** is in right |
| Drop-head | `join_k_path_into!` | Collapse first `n` bytes, joining sub-tries |

```julia
a = PathMap{Nothing}()
set_val_at!(a, b"x", nothing); set_val_at!(a, b"y", nothing)

b = PathMap{Nothing}()
set_val_at!(b, b"y", nothing); set_val_at!(b, b"z", nothing)

pjoin(a, b)      # {x, y, z}
pmeet(a, b)      # {y}
psubtract(a, b)  # {x}
```

---

## Zipper Reference

### Read Zipper

| Function | Description |
|----------|-------------|
| `read_zipper(m)` | Zipper at the root of `m` |
| `read_zipper_at_path(m, path)` | Zipper pre-positioned at `path` |
| `zipper_descend_to!(z, k)` | Descend to sub-path `k` |
| `zipper_ascend!(z, n)` | Ascend `n` bytes |
| `zipper_reset!(z)` | Return to origin |
| `zipper_val(z)` | Value at cursor (or `nothing`) |
| `zipper_is_val(z)` | True if a value exists at cursor |
| `zipper_path_exists(z)` | True if any path exists below cursor |
| `zipper_path(z)` | Current path bytes from origin |
| `zipper_child_mask(z)` | `ByteMask` of existing child bytes |
| `zipper_child_count(z)` | Number of child branches |
| `zipper_to_next_val!(z)` | Advance to next value (DFS order) |
| `zipper_to_next_step!(z)` | Advance one step (every node) |
| `tr_fork_read_zipper(z)` | Clone the zipper at current position |

### Write Zipper

| Function | Description |
|----------|-------------|
| `write_zipper(m)` | Mutable zipper at the root of `m` |
| `write_zipper_at_path(m, path)` | Pre-positioned at `path` |
| `wz_set_val!(z, v)` | Set value at cursor |
| `wz_remove_val!(z)` | Remove value at cursor |
| `wz_get_or_set_val!(z, default)` | Upsert — return existing or set default |
| `wz_create_path!(z)` | Create a dangling (valueless) path |
| `wz_prune_path!(z)` | Remove dangling empty paths |
| `wz_graft!(z, src)` | Replace subtrie at cursor with `src` |
| `wz_graft_map!(z, m)` | Replace subtrie at cursor with map `m` |
| `wz_take_map!(z)` | Remove and return subtrie as a new `PathMap` |
| `wz_insert_prefix!(z, prefix)` | Prepend `prefix` bytes to all paths below |
| `wz_remove_prefix!(z, n)` | Strip `n` bytes of prefix from all paths |
| `wz_join_into!(z, src)` | Join `src` into subtrie at cursor |
| `wz_meet_into!(z, src)` | Meet `src` into subtrie at cursor |
| `wz_subtract_into!(z, src)` | Subtract `src` from subtrie at cursor |
| `wz_restrict!(z, src)` | Restrict subtrie to paths in `src` |
| `wz_remove_branches!(z)` | Remove all branches at cursor |
| `wz_child_mask(z)` | `ByteMask` of child bytes at cursor |

### Abstract Zippers

Combinators that compose read-zippers without materialising copies:

| Type | Description |
|------|-------------|
| `PrefixZipper` | Prepend a fixed byte prefix to all paths |
| `OverlayZipper` | Fuse two zippers (reads from both) |
| `ProductZipper` | Cartesian product of multiple zippers |
| `ProductZipperG` | Generic N-factor product zipper |
| `DependentZipper` | Navigation guided by a factor zipper |
| `EmptyZipper` | Virtual infinite empty trie (useful for composition) |

### ZipperHead — Multi-Zipper Coordination

`ZipperHead` manages multiple zippers into the same `PathMap` with
exclusive-access guarantees, enabling safe concurrent navigation:

```julia
zh = ZipperHead(m)
rz = zh_read_zipper_at_path(zh, b"left:")
wz = zh_write_zipper_at_exclusive_path(zh, b"right:")  # exclusive
# rz and wz can coexist because their paths are non-overlapping
```

---

## Morphisms

### Catamorphism (Fold)

Folds the trie from leaves to root, calling `alg_f` at each fork.

```julia
# Count all values
cata_cached(m, (mask, children, val) ->
    (val !== nothing ? 1 : 0) + reduce(+, children, init=0))

# Collect all paths with values
cata_side_effect(m, (mask, children, val, path) -> begin
    val !== nothing && println(String(path), " => ", val)
    nothing
end)
```

| Function | Caches | Path visible | Jumping |
|----------|--------|-------------|---------|
| `cata_side_effect` | ✗ | ✓ | ✗ |
| `cata_jumping_side_effect` | ✗ | ✓ | ✓ |
| `cata_cached` | ✓ | ✗ | ✗ |
| `cata_jumping_cached` | ✓ | ✗ | ✓ |
| `cata_hybrid_cached` | ✓ | ✓ | ✗ |
| `cata_jumping_hybrid_cached` | ✓ | ✓ | ✓ |

The **hybrid cached** variants are a PathMap.jl extension — see
[Hybrid Cached Catamorphism](docs/advanced/hybrid_cata.md).

### Anamorphism (Unfold)

```julia
# Build a trie from a generating function
ana_jumping!(PathMap{Int}(), state -> ...) 
```

---

## Policy API

The **Policy API** decouples value-merge behaviour from the type system,
allowing different merge strategies for the same value type:

```julia
# Built-in policies
pjoin_policy(a, b, SumPolicy())   # v_a + v_b at coinciding paths
pjoin_policy(a, b, MaxPolicy())   # max(v_a, v_b)
pjoin_policy(a, b, MinPolicy())   # min(v_a, v_b)
pjoin_policy(a, b, ProdPolicy())  # v_a * v_b
pjoin_policy(a, b, TakeFirst())   # keep v_a
pjoin_policy(a, b, TakeLast())    # overwrite with v_b
pjoin_policy(a, b, MergeWith(f))  # custom: f(v_a, v_b)

# In-place zipper variant
wz_join_policy!(wz, src_map, SumPolicy())
```

See [Policy API Guide](docs/advanced/policy_api.md).

---

## Serialization

```julia
# .paths format (zlib-compressed byte sequences)
buf = serialize_paths(m)
m2  = deserialize_paths(UInt8, buf)

# With auxiliary data per path
buf = serialize_paths_with_auxdata(m, (path, val) -> encode(val))
m3  = deserialize_paths_with_auxdata(buf, decode)

# ArenaCompact (ACT) — read-only memory-mapped format
write_act(m, "data.act")
act = act_open("data.act")
az  = ACTZipper(act)          # navigate without loading into RAM
```

---

## Performance Notes

- **Structural sharing** is preserved across `pjoin`, `graft`, and copy.
  Clone-on-write is deferred until the first write through that path
  (lazy COW — see [WriteZipper COW](docs/advanced/lazy_cow.md)).
- **`cata_cached`** exploits sharing: a subtrie seen at `n` locations is
  folded once and the result reused.
- **`jumping`** variants skip monotone path segments between forks,
  dramatically reducing call overhead for sparse tries.
- **`ZipperHead`** enables safe parallel read/write across disjoint
  subtries without locking.

---

## Documentation

| Document | Description |
|----------|-------------|
**Guides**

| Document | Description |
|----------|-------------|
| [Getting Started](docs/guide/getting_started.md) | Installation, first map, iteration |
| [Zipper Guide](docs/guide/zippers.md) | Read/write zippers, abstract combinators, ZipperHead |
| [Algebraic Operations](docs/guide/algebra.md) | Join, meet, subtract, restrict with examples |
| [Morphisms](docs/guide/morphisms.md) | Cata/ana fold patterns, complexity guide |
| [Serialization](docs/guide/serialization.md) | .paths and ACT formats |

**Advanced**

| Document | Description |
|----------|-------------|
| [Policy API](docs/advanced/policy_api.md) | Pluggable value-merge policies |
| [Lazy COW](docs/advanced/lazy_cow.md) | Copy-on-write internals, two-phase design |
| [Hybrid Cata](docs/advanced/hybrid_cata.md) | A.0005: caching + full path visibility |

**Reference**

| Document | Description |
|----------|-------------|
| [API Reference](docs/api/README.md) | Full exported symbol index (100+ entries) |

---

## Relationship to Upstream

PathMap.jl is inspired by the Rust
[`pathmap`](https://github.com/trueagi-io/PathMap) crate.
The core algorithms and data structures follow the upstream design.

> **Deferred upstream delta (as of 2026-06-24):** upstream `27d9b09` (PR #38) adds a
> `val_at`/`graft_src_at`/`graft_masked_branches` read-API family + perf. It is **not yet ported** —
> no current consumer (MORK) uses it. See [docs/UPSTREAM_DELTA_2026-06-24.md](docs/UPSTREAM_DELTA_2026-06-24.md)
> for the exact commit range + port trigger.

The following capabilities are implemented in PathMap.jl but are not
yet present in the current Rust release:

| Feature | Description |
|---------|-------------|
| **Lazy COW WriteZipper** | Clone-on-write deferred to first write (A.0004) |
| **Policy API** | Pluggable value-merge at call time (A.0003) |
| **Hybrid Cached Cata** | Caching + full path visibility (A.0005) |
| **`insert_prefix!` / `remove_prefix!`** | Bulk path-prefix manipulation |

---

## License

Apache 2.0 — see [LICENSE](LICENSE).
