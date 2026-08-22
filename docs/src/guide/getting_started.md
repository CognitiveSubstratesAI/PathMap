# Getting Started

## Installation

PathMap.jl requires Julia ≥ 1.10.

```julia
using Pkg
Pkg.develop(path = "/path/to/PathMap")
# or from the PRIMUS monorepo:
Pkg.develop(path = "packages/PathMap")
```

## Your First Map

```julia
using PathMaps

# Create a typed map — V can be any Julia type
m = PathMap{Int}()

# Insert values at byte-slice keys
set_val_at!(m, b"users:alice:score", 95)
set_val_at!(m, b"users:bob:score",   87)
set_val_at!(m, b"users:alice:rank",  1)

# Read
get_val_at(m, b"users:alice:score")  # 95
get_val_at(m, b"users:carol:score")  # nothing

# Mutate
set_val_at!(m, b"users:alice:score", 98)
remove_val_at!(m, b"users:bob:score")

# Inspect
val_count(m)  # 2
```

## Iterating Values

The idiomatic way to iterate is through a read zipper:

```julia
rz = read_zipper_at_path(m, b"users:")

# Visit every value in the subtrie (DFS order)
while zipper_to_next_val!(rz)
    path = String(zipper_path(rz))     # relative to origin
    val  = zipper_val(rz)
    println("$path => $val")
end
```

Output:
```
alice:rank => 1
alice:score => 98
```

## String vs Binary Keys

Keys are `Vector{UInt8}` or anything that converts to it.  The `b"..."` 
literal is the most convenient form for ASCII keys:

```julia
set_val_at!(m, b"ascii:key", 1)
set_val_at!(m, collect(UInt8, "also works"), 2)
set_val_at!(m, [0x00, 0xFF, 0x42], 3)   # arbitrary bytes
```

## Value Types

`PathMap{V}` is parametric.  Common choices:

```julia
PathMap{Nothing}()     # set — keys only, no values
PathMap{Int}()         # integer counters
PathMap{Float64}()     # float values (works with Policy API min/max/sum)
PathMap{Vector{UInt8}}() # byte-string values
PathMap{Any}()         # heterogeneous (slower)
```

## Next Steps

- [Zipper Guide](zippers.md) — efficient navigation and bulk operations
- [Algebraic Operations](algebra.md) — joins, meets, set operations
- [Morphisms](morphisms.md) — fold patterns
- [Policy API](../advanced/policy_api.md) — custom merge strategies
