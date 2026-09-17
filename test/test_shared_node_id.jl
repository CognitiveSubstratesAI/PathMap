# test_shared_node_id.jl — `shared_node_id` / `is_shared` and the cached catamorphism.
#
# Upstream `read_zipper_shared_node_id` (zipper.rs:2638-2653) returns an id only when the focus is
# SHARED, at a node boundary, and carries NO value: focus values live outside the node, so one node
# reached by two paths can carry two different values and a cache keyed on the node would reuse the
# wrong result. Ours returned an id at every node boundary, so `cata_cached` (and `map_hash`, which
# folds with it) was wrong on such tries (docs/UPSTREAM_DELTA_2026-09-16.md P0 #2).
using Test, PathMaps
const PMS = PathMaps.PathMap
cus(s) = collect(codeunits(s))

"Count of values via the uncached and the cached fold (upstream `cata_test_cached` compares the two)."
count_side(m) = cata_side_effect(m, (mask, ch, val, path) -> sum(ch; init = 0) + (val === nothing ? 0 : 1))
count_cached(m) = cata_cached(m, (mask, ch, val) -> sum(ch; init = 0) + (val === nothing ? 0 : 1))

"The whole fold as a value tree, so a reused cache entry shows up as a wrong subtree."
tree_side(m) = cata_side_effect(m, (mask, ch, val, path) -> (val, Tuple(ch)))
tree_cached(m) = cata_cached(m, (mask, ch, val) -> (val, Tuple(ch)))

@testset "shared_node_id guard (upstream zipper.rs:2638-2653)" begin
    @testset "a shared subtrie with different focus values at its two paths" begin
        s = PMS{UInt64}(); set_val_at!(s, cus("x"), UInt64(1)); set_val_at!(s, cus("y"), UInt64(2))
        for valued in ("a", "b")                      # the value on the first- or the later-visited path
            t = PMS{UInt64}()
            for p in ("a", "b")
                graft_map!(write_zipper_at_path(t, cus(p)), s)
            end
            set_val_at!(t, cus(valued), UInt64(9))
            @test count_side(t) == 5
            @test count_cached(t) == 5
            @test tree_cached(t) == tree_side(t)
            z = read_zipper(t); descend_to!(z, cus(valued))
            @test val(z) == 9
            @test shared_node_id(z) === nothing  # valued focus: never an id
        end
    end

    @testset "unshared and dangling foci have no id" begin
        m = PMS{UInt64}()
        for k in ("aa", "ab", "ba", "bb", "b"); set_val_at!(m, cus(k), UInt64(1)); end
        remove_val_at!(m, cus("ba"), false); remove_val_at!(m, cus("bb"), false)
        z = read_zipper(m); descend_to!(z, cus("ba"))
        @test path_exists(z)
        @test !is_shared(z)
        @test shared_node_id(z) === nothing
        z = read_zipper(m); descend_to!(z, cus("a"))
        @test !is_shared(z)                     # refcount 1
        @test shared_node_id(z) === nothing
    end

    @testset "a shared, value-free node has the same id on both paths" begin
        s = PMS{UInt64}(); set_val_at!(s, cus("x"), UInt64(1)); set_val_at!(s, cus("y"), UInt64(2))
        t = PMS{UInt64}()
        for p in ("a", "b")
            graft_map!(write_zipper_at_path(t, cus(p)), s)
        end
        za = read_zipper(t); descend_to!(za, cus("a"))
        zb = read_zipper(t); descend_to!(zb, cus("b"))
        @test is_shared(za) && is_shared(zb)
        @test shared_node_id(za) !== nothing
        @test shared_node_id(za) == shared_node_id(zb)
        @test count_cached(t) == count_side(t) == 4
    end

    # upstream cata_test_cached (morphisms.rs:1922-1990): three levels, each grafting the previous map
    # under bytes 0, 1 and 2 — heavy sharing — and the cached fold must equal the uncached one.
    @testset "cata_test_cached (upstream morphisms.rs:1922)" begin
        m = PMS{UInt8}(); set_val_at!(m, UInt8[0], UInt8(0))
        for _level in 1:3
            next = PMS{UInt8}()
            for ii in 0:2
                graft_map!(write_zipper_at_path(next, UInt8[ii]), m)
            end
            m = next
        end
        @test tree_cached(m) == tree_side(m)
        @test count_cached(m) == count_side(m) == 27
    end
end
