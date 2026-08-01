# test_join_consumes_source.jl — `wz_join_map_into!` CONSUMES its source map.
#
# This pins BEHAVIOUR THAT LOOKS LIKE A BUG, on purpose, so nobody "fixes" it into a different
# operation. Upstream's signature is `pub fn join_map_into(&mut self, map: PathMap<V, A>)`
# (write_zipper.rs:1680) — BY VALUE. The source is MOVED, so Rust callers cannot observe what the
# join does to it, and upstream is free to mutate it. Julia has no move, so the same mutation is
# visible; the guarantee Rust gets from its type system has to be a documented contract here.
#
# Same asymmetry as `clone_payload` and `graft_map`: the Rust is sound BECAUSE of something the port
# cannot express. Porting the mechanism without the guarantee ports a hazard.
#
# ⚠️ IT IS NOT A COPY-ON-WRITE GAP. An unshared, freshly built source is mutated exactly the same
# way, so cloning the argument does not make it "safe" — it makes it a different operation with an
# extra copy. If a caller needs the source afterwards, it must hand over a copy and treat the one it
# passed as gone.
#
# FOUND while prototyping a source-preservation check for the differential fuzzer: of 163 new
# mismatches, 162 were an unrelated status class and exactly ONE — corpus case `00324` — was real.
# The corpus cannot see this today, because every op there builds its own throwaway source.
using PathMap, Test

_b(s) = Vector{UInt8}(codeunits(s))

function _mk(keys::Vector{String})
    m = PathMap.PathMap{PathMap.UnitVal}()
    for k in keys
        PathMap.set_val_at!(m, _b(k), PathMap.UnitVal())
    end
    m
end

_paths(m) = begin
    z = PathMap.read_zipper(m)
    v = String[]
    while PathMap.zipper_to_next_val!(z)
        push!(v, String(copy(PathMap.zipper_path(z))))
    end
    sort(v)
end

@testset "wz_join_map_into! consumes its source (documented, not a defect)" begin

    @testset "the target is correct — that is what the op promises" begin
        a = _mk(["ab:", "b", "b:a"])
        s = _mk(["a:a", "aa", "ab"])
        PathMap.wz_join_map_into!(PathMap.write_zipper(a), s)
        @test _paths(a) == ["a:a", "aa", "ab", "ab:", "b", "b:a"]
        @test PathMap.val_count(a) == 6
    end

    @testset "the SOURCE is mutated — minimal reproducer, reduced from fuzz case 00324" begin
        a = _mk(["ab:", "b", "b:a"])
        s = _mk(["a:a", "aa", "ab"])
        @test _paths(s) == ["a:a", "aa", "ab"]
        PathMap.wz_join_map_into!(PathMap.write_zipper(a), s)
        # `s` gains "ab:" FROM `a`. Asserted exactly, so a change in this behaviour is visible
        # rather than silently absorbed.
        @test _paths(s) == ["a:a", "aa", "ab", "ab:"]
        @test PathMap.val_count(s) == 4
    end

    @testset "it does NOT need sharing — an unshared source is mutated identically" begin
        # The discriminator. If this were a copy-on-write gap, a freshly built source with
        # refcount 1 would be safe. It is not, which is what makes "consumed" the right framing.
        a = _mk(["ab:", "b", "b:a"])
        fresh = _mk(["a:a", "aa", "ab"])          # never shared with anything
        PathMap.wz_join_map_into!(PathMap.write_zipper(a), fresh)
        @test _paths(fresh) == ["a:a", "aa", "ab", "ab:"]
    end

    @testset "hand over a copy when the source is still needed" begin
        # The supported way to keep a source: give the join a copy. Documented here because the
        # contract is otherwise only discoverable by being bitten by it.
        a = _mk(["ab:", "b", "b:a"])
        s = _mk(["a:a", "aa", "ab"])
        before = _paths(s)
        PathMap.wz_join_map_into!(PathMap.write_zipper(a), deepcopy(s))
        @test _paths(s) == before                  # untouched
        @test PathMap.val_count(a) == 6            # and the join still did its job
    end
end
