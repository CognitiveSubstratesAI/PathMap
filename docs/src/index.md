# PathMap.jl

A high-performance, structurally-shared, byte-keyed **trie map** for Julia — the
storage substrate for [MORK.jl](https://github.com/CognitiveSubstratesAI/MORK) and
the broader [Hyperon](https://wiki.opencog.org/w/Hyperon) ecosystem.

PathMap is an independent Julia port of the Rust
[`pathmap`](https://github.com/trueagi-io/PathMap) crate, hardened by a deep
Rust→Julia porting audit. It provides:

- **Copy-on-write structural sharing** — `copy` is O(1) and shares nodes; a write
  uniquifies only the touched path (node-keyed `@atomic` refcount, thread-safe).
- **Zippers** — read/write cursors (`read_zipper_at_path`, `write_zipper`) with
  grafting, lattice algebra (join / meet / subtract / restrict), and morphisms.
- **Compact on-disk form** — `ArenaCompact` mmap round-trip for persistence.

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/CognitiveSubstratesAI/PathMap")
```

## Quickstart

```julia
using PathMaps

m = PathMap.PathMap{Int}()
set_val_at!(m, b"alpha", 1)
set_val_at!(m, b"beta", 2)
get_val_at(m, b"alpha")          # => 1

# O(1) copy-on-write: `c` shares m's nodes until one is written
c = copy(m.root)
```

## Contents

```@contents
Pages = [
    "guide/getting_started.md",
    "guide/zippers.md",
    "guide/algebra.md",
    "guide/morphisms.md",
    "guide/serialization.md",
    "advanced/lazy_cow.md",
    "advanced/policy_api.md",
    "advanced/hybrid_cata.md",
]
Depth = 1
```
