# WILLIAM × PathMap N-ary operations
# Tests N-way join/meet for multi-space pattern aggregation
using PathMap, Test

println("=== WILLIAM × PathMap N-ary ===\n")

# `const`, not a plain assignment: BOTH callers already bind this name as a constant —
# tools/repl.jl:25 (used by tools/run_tests.sh) and test/runtests.jl:13 — so a bare
# `PM = …` throws "invalid assignment to constant Main.PM" and this file could not be
# included from anywhere. Re-binding a const to the IDENTICAL value is permitted.
const PM = PathMap.PathMap

@testset "WILLIAM pattern union/intersection via N-ary PathMap" begin
    @testset "3-way join = pattern union across 3 spaces" begin
        m1 = PM{UnitVal}()
        m2 = PM{UnitVal}()
        m3 = PM{UnitVal}()
        for k in ["bird-robin", "bird-sparrow", "bird-eagle"]
            set_val_at!(m1, Vector{UInt8}(k), UNIT_VAL)
        end
        for k in ["bird-sparrow", "mammal-dog", "mammal-cat"]
            set_val_at!(m2, Vector{UInt8}(k), UNIT_VAL)
        end
        for k in ["bird-eagle", "mammal-cat", "fish-salmon"]
            set_val_at!(m3, Vector{UInt8}(k), UNIT_VAL)
        end
        out = PM{UnitVal}()
        wz_join_n!(
            write_zipper(out), [write_zipper(m1), write_zipper(m2), write_zipper(m3)]
        )
        rz = read_zipper(out);
        keys = Set{String}()
        while zipper_to_next_val!(rz)
            ;
            push!(keys, String(copy(zipper_path(rz))));
        end
        @test "bird-robin" in keys
        @test "mammal-dog" in keys
        @test "fish-salmon" in keys
        @test length(keys) == 6
        println("  join: $(length(keys)) unique patterns across 3 spaces ✓")
    end

    @testset "3-way meet = common patterns (WILLIAM.LGG candidates)" begin
        m1 = PM{UnitVal}()
        m2 = PM{UnitVal}()
        m3 = PM{UnitVal}()
        for k in ["common-a", "common-b", "only-in-1"]
            set_val_at!(m1, Vector{UInt8}(k), UNIT_VAL)
        end
        for k in ["common-a", "common-b", "only-in-2"]
            set_val_at!(m2, Vector{UInt8}(k), UNIT_VAL)
        end
        for k in ["common-a", "common-b", "only-in-3"]
            set_val_at!(m3, Vector{UInt8}(k), UNIT_VAL)
        end
        out = PM{UnitVal}()
        wz_meet_n!(
            write_zipper(out), [write_zipper(m1), write_zipper(m2), write_zipper(m3)]
        )
        rz = read_zipper(out);
        keys = Set{String}()
        while zipper_to_next_val!(rz)
            ;
            push!(keys, String(copy(zipper_path(rz))));
        end
        @test keys == Set(["common-a", "common-b"])
        println("  meet: $(keys) — only universal patterns ✓")
    end

    @testset "3-way subtract = patterns unique to base" begin
        base = PM{UnitVal}()
        noise1 = PM{UnitVal}()
        noise2 = PM{UnitVal}()
        for k in ["keep-a", "keep-b", "remove-c", "remove-d"]
            set_val_at!(base, Vector{UInt8}(k), UNIT_VAL)
        end
        for k in ["remove-c", "other"]
            set_val_at!(noise1, Vector{UInt8}(k), UNIT_VAL)
        end
        for k in ["remove-d", "more"]
            set_val_at!(noise2, Vector{UInt8}(k), UNIT_VAL)
        end
        out = PM{UnitVal}()
        wz_subtract_n!(
            write_zipper(out),
            [write_zipper(base), write_zipper(noise1), write_zipper(noise2)]
        )
        rz = read_zipper(out);
        keys = Set{String}()
        while zipper_to_next_val!(rz)
            ;
            push!(keys, String(copy(zipper_path(rz))));
        end
        @test keys == Set(["keep-a", "keep-b"])
        println("  subtract: $(keys) — noise removed ✓")
    end

    @testset "5-way join scales to many spaces" begin
        maps = [PM{UnitVal}() for _ in 1:5]
        for (i, m) in enumerate(maps)
            set_val_at!(m, Vector{UInt8}("shared"), UNIT_VAL)
            set_val_at!(m, Vector{UInt8}("space-$i"), UNIT_VAL)
        end
        out = PM{UnitVal}()
        wz_join_n!(write_zipper(out), [write_zipper(m) for m in maps])
        rz = read_zipper(out);
        keys = Set{String}()
        while zipper_to_next_val!(rz)
            ;
            push!(keys, String(copy(zipper_path(rz))));
        end
        @test "shared" in keys
        @test length(keys) == 6  # 1 shared + 5 unique
        println("  5-way join: $(length(keys)) patterns ✓")
    end
end

println("\n✓ WILLIAM × PathMap N-ary tests complete")
