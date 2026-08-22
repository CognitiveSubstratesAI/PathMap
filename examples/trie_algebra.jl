#!/usr/bin/env julia
# examples/trie_algebra.jl — Demonstrate path algebra on a knowledge base
#
# Demonstrates:
#   - Set operations (union, subtract, intersection) via write zippers
#   - pjoin_policy for vote-tallying with SumPolicy
#   - insert_prefix! for namespace remapping
#   - Serialization round-trip (.paths format)
#
# Run:
#   julia --project=. examples/trie_algebra.jl

using PathMap

# PathMap-level pjoin/pmeet/psubtract return AlgebraicResult (faithful to Rust).
# These helpers materialise the result as a concrete PathMap for convenience.
function map_union(a::PathMap.PathMap{V, A}, b::PathMap.PathMap{V, A}) where {V, A}
    result = deepcopy(a)
    b.root === nothing && return result
    wz = write_zipper(result)
    wz_join_map_into!(wz, b)
    result
end

function map_subtract(a::PathMap.PathMap{V, A}, b::PathMap.PathMap{V, A}) where {V, A}
    b.root === nothing && return deepcopy(a)
    a.root === nothing && return PathMap.PathMap{V, A}(a.alloc)
    result = deepcopy(a)
    wz = write_zipper(result)
    wz_subtract_into!(wz, ANRBorrowedRc(b.root))
    result
end

# a ∩ b  =  a − (a − b)
map_intersect(a, b) = map_subtract(a, map_subtract(a, b))

# ── Knowledge bases ───────────────────────────────────────────────────
function make_set(paths)
    m = PathMap.PathMap{Bool}()
    for p in paths

        set_val_at!(m, p, true)
    end
    m
end

animals = make_set([
    b"mammal:dog", b"mammal:cat", b"mammal:whale", b"reptile:snake", b"reptile:turtle",
    b"bird:eagle", b"bird:penguin"
])

swimmers = make_set([b"mammal:whale", b"reptile:turtle", b"bird:penguin", b"fish:salmon"])

println("=== Path Algebra on Knowledge Bases ===")
println("Animals:  ", val_count(animals))
println("Swimmers: ", val_count(swimmers))

# ── Union ─────────────────────────────────────────────────────────────
all_known = map_union(animals, swimmers)
println("\nUnion (all known): ", val_count(all_known), " entries")

# ── Difference ────────────────────────────────────────────────────────
land_or_air = map_subtract(animals, swimmers)
println("Non-swimmers (animals − swimmers): ", val_count(land_or_air))
rz = read_zipper(land_or_air)
while zipper_to_next_val!(rz)
    println("  ", String(copy(zipper_path(rz))))
end

# ── Intersection ──────────────────────────────────────────────────────
swimming_animals = map_intersect(animals, swimmers)
println("\nIntersection (swimming animals): ", val_count(swimming_animals))
rz2 = read_zipper(swimming_animals)
while zipper_to_next_val!(rz2)
    println("  ", String(copy(zipper_path(rz2))))
end

# ── Prefix filter ─────────────────────────────────────────────────────
println("\nMammals only (prefix navigation):")
rz3 = read_zipper_at_path(animals, b"mammal:")
while zipper_to_next_val!(rz3)
    println("  mammal:", String(copy(zipper_path(rz3))))
end

# ── Namespace remapping with insert_prefix! ───────────────────────────
println("\n=== Namespace Remapping ===")
catalog = make_set([b"eagle", b"penguin"])
wz = write_zipper(catalog)
wz_insert_prefix!(wz, b"bird:")
println("After insert_prefix 'bird:': ", val_count(catalog), " entries")
rz4 = read_zipper(catalog)
while zipper_to_next_val!(rz4)
    println("  ", String(copy(zipper_path(rz4))))
end

# ── Policy API — SumPolicy for vote tallying ──────────────────────────
println("\n=== Policy Join (SumPolicy) ===")
votes_a = PathMap.PathMap{Int}()
set_val_at!(votes_a, b"option:A", 3)
set_val_at!(votes_a, b"option:B", 1)
votes_b = PathMap.PathMap{Int}()
set_val_at!(votes_b, b"option:A", 2)
set_val_at!(votes_b, b"option:C", 5)

tallied = pjoin_policy(votes_a, votes_b, SumPolicy())
println("option:A => ", get_val_at(tallied, b"option:A"))  # 3+2 = 5
println("option:B => ", get_val_at(tallied, b"option:B"))  # 1
println("option:C => ", get_val_at(tallied, b"option:C"))  # 5

# ── Serialization round-trip ──────────────────────────────────────────
println("\n=== Serialization Round-Trip ===")
io = IOBuffer()
serialize_paths(swimming_animals, io)
println("Serialized $(val_count(swimming_animals)) paths → $(position(io)) bytes")
seekstart(io)
restored = PathMap.PathMap{Bool}()
deserialize_paths(restored, io, true)
println(
    "Restored: ",
    val_count(restored),
    " paths — matches: ",
    val_count(restored) == val_count(swimming_animals)
)
