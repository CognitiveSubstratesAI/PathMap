# test_cow_join_map.jl — `wz_join_map_into!` must not let later writes corrupt the SOURCE map.
#
# WHY THIS FILE EXISTS. On 2026-08-01 a profiling-driven change made `clone_slot{0,1}_payload`
# shallow (sharing a child subtrie by refcount instead of `deepcopy`-ing it). It was a large,
# correctly-measured win — join dropped from 574,106 allocations to 42 — and it was WRONG:
# joining B into a map and then removing a key from the RESULT deleted the key from B as well.
#
#     B val_count before  20000
#     B val_count after   19999      <- source corrupted through a shared node
#
# 🔴 EVERY GATE WE HAD PASSED IT. The full PathMap suite, the 3000-case differential (30 known
# divergences, 0 errors), and MORK's 2959 tests were all green with the corruption in place. The
# suite already had two COW tests — `lazy COW — graft does not corrupt source` and `COW property:
# join_k_path on shared subtrie preserves source` — and neither covers this path: one grafts, the
# other drops a head. Neither does `join_map_into` FOLLOWED BY A WRITE, which is what shares nodes
# and then mutates them.
#
# WHY UPSTREAM DOES NOT HAVE THIS PROBLEM, which is the part that misleads: upstream's
# `join_map_into(&mut self, map: PathMap<V, A>)` takes the map BY VALUE. In Rust the source is MOVED
# and the caller cannot observe it afterwards, so sharing its nodes is free and safe. Julia has no
# move, so our caller keeps a live handle to `B` — the safety upstream gets from the type system has
# to be paid for here, either by copying or by a copy-on-write that actually covers this path.
#
# So "match upstream" was the wrong instinct: the Rust is sound BECAUSE of a guarantee our port
# cannot express. Recorded rather than retried.
using PathMap, Test

_b(s) = Vector{UInt8}(codeunits(s))

function _build(n::Int, salt::String)
    m = PathMap.PathMap{PathMap.UnitVal}()
    for i in 1:n
        PathMap.set_val_at!(m, _b("rel:$(salt):$(i % 97):$(i)"), PathMap.UnitVal())
    end
    m
end

@testset "join_map_into does not expose the source to later writes" begin

    @testset "removing from the RESULT leaves the source intact" begin
        # Disjoint sources, which is the shape that makes sharing tempting: the join can attach B's
        # whole subtrie at the divergence point with a single refcount bump. That is exactly the
        # case the shallow clone got fast and wrong.
        a = _build(2_000, "a")
        b = _build(2_000, "b")
        z = PathMap.write_zipper(deepcopy(a))
        PathMap.wz_join_map_into!(z, b)
        result = z.pathmap
        @test PathMap.val_count(result) == 4_000

        PathMap.remove_val_at!(result, _b("rel:b:1:1"), false)
        @test PathMap.get_val_at(result, _b("rel:b:1:1")) === nothing   # removed from the result
        @test PathMap.get_val_at(b, _b("rel:b:1:1")) !== nothing        # ← and NOT from the source
        @test PathMap.val_count(b) == 2_000
    end

    @testset "writing INTO the result leaves the source intact" begin
        # The mirror direction: a set_val landing inside the shared subtrie must copy first.
        a = _build(500, "a")
        b = _build(500, "b")
        z = PathMap.write_zipper(deepcopy(a))
        PathMap.wz_join_map_into!(z, b)
        PathMap.set_val_at!(z.pathmap, _b("rel:b:1:1:extra"), PathMap.UnitVal())
        @test PathMap.get_val_at(z.pathmap, _b("rel:b:1:1:extra")) !== nothing
        @test PathMap.get_val_at(b, _b("rel:b:1:1:extra")) === nothing
        @test PathMap.val_count(b) == 500
    end

    @testset "the source can be joined again afterwards" begin
        # If the first join left `b` structurally damaged, a second join would produce the wrong
        # count even without any explicit mutation — an independent way to catch the same defect.
        a = _build(500, "a")
        b = _build(500, "b")
        z1 = PathMap.write_zipper(deepcopy(a))
        PathMap.wz_join_map_into!(z1, b)
        PathMap.remove_val_at!(z1.pathmap, _b("rel:b:1:1"), false)

        z2 = PathMap.write_zipper(deepcopy(a))
        PathMap.wz_join_map_into!(z2, b)
        @test PathMap.val_count(z2.pathmap) == 1_000
    end
end
