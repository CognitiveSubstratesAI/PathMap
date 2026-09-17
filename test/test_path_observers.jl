# test_path_observers.jl — the 0.4.0 PathObserver mechanism (upstream zipper.rs:510-741, path_tracker.rs).
#
# WHY. The `_observed` methods are what make "blind" zippers possible: a zipper moves without keeping a path,
# and whoever needs the path supplies an observer. Nothing else in the suite asserts that the bytes an
# observer receives equal the path the zipper is actually on — the conformance battery checks `path(z)`, which
# for every zipper we have is the zipper's OWN buffer. These tests compare the two.
#
# FIDELITY. The observer contracts are upstream's: `Vector{UInt8}` accumulates (zipper.rs:530), a depth counter
# is upstream's `usize` (:543), `nothing` is upstream's `()` (:555), a tuple fans out (:598),
# `MirrorPathObserver` replays onto another zipper (:620), `TruncatingObserver` forwards at most `limit` and
# never reports the overshoot (:645-698), `HashObserver` is chunking-invariant and zeroes on ascend (:700-741).
module PathObserverTests

using Test, PathMaps
const PM = PathMaps.PathMap

b(s::String) = Vector{UInt8}(s)
unit_map(keys) = (m = PM{UnitVal}(); for k in keys; set_val_at!(m, collect(UInt8, k), UNIT_VAL); end; m)
path_of(z) = collect(UInt8, path(z))

@testset "PathObserver (0.4.0)" begin

@testset "an observer sees exactly the path the zipper walks" begin
    m = unit_map(["ab", "abc", "abd", "wxyz"])
    for (name, walk) in [
        ("to_next_val_observed!", (z, obs) -> to_next_val_observed!(z, obs)),
        ("to_next_step_observed!", (z, obs) -> to_next_step_observed!(z, obs)),
    ]
        @testset "$name" begin
            z = read_zipper(m)
            obs = UInt8[]
            steps = 0
            while walk(z, obs)
                steps += 1
                @test obs == path_of(z)      # the observer's bytes ARE the zipper's path
                steps > 64 && break
            end
            @test steps > 0
            @test obs == path_of(z)          # …including after the walk returns false
        end
    end
end

@testset "descend_until_observed! / descend_first_k_path_observed! / to_next_k_path_observed!" begin
    m = unit_map(["abcdef", "abcdeg"])
    z = read_zipper(m)
    obs = UInt8[]
    @test descend_until_observed!(z, obs)
    @test obs == path_of(z) == b("abcde")

    m2 = unit_map(["aa", "ab", "ba", "bb"])
    z2 = read_zipper(m2)
    obs2 = UInt8[]
    @test descend_first_k_path_observed!(z2, 2, obs2)
    @test obs2 == path_of(z2) == b("aa")
    seen = [copy(obs2)]
    while to_next_k_path_observed!(z2, 2, obs2)
        @test obs2 == path_of(z2)
        push!(seen, copy(obs2))
        length(seen) > 8 && break
    end
    @test seen == [b("aa"), b("ab"), b("ba"), b("bb")]
    @test obs2 == path_of(z2)                # on the false exit both have ascended to the common root
end

@testset "a depth observer tracks depth; `nothing` discards" begin
    m = unit_map(["abc", "abd"])
    z = read_zipper(m)
    d = Ref(0)
    while to_next_val_observed!(z, d)
        @test d[] == depth(z)
    end
    @test d[] == depth(z)
    z2 = read_zipper(m)
    while to_next_val_observed!(z2, nothing)      # upstream's `()` — must not throw or move differently
    end
    @test at_root(z2)
end

@testset "a tuple fans out to both observers" begin
    m = unit_map(["xy", "xz"])
    z = read_zipper(m)
    a = UInt8[]
    d = Ref(0)
    while to_next_val_observed!(z, (a, d))
        @test a == path_of(z)
        @test d[] == depth(z)
    end
end

@testset "MirrorPathObserver replays the movement onto another zipper" begin
    m = unit_map(["abc", "abd", "q"])
    z = read_zipper(m)
    mirror_z = read_zipper(m)
    obs = PathMaps.MirrorPathObserver(mirror_z)
    while to_next_val_observed!(z, obs)
        @test path_of(mirror_z) == path_of(z)     # the mirror follows byte for byte
    end
    @test path_of(mirror_z) == path_of(z)
end

@testset "descend_until_max_bytes_observed! never reports past the limit" begin
    m = unit_map(["abcdefgh"])
    for max_bytes in 0:8
        z = read_zipper(m)
        obs = UInt8[]
        moved = descend_until_max_bytes_observed!(z, max_bytes, obs)
        @test length(obs) <= max_bytes
        @test obs == path_of(z)                   # the overshoot is ascended away, not reported
        @test moved == (max_bytes > 0)
    end
end

@testset "HashObserver is chunking-invariant and zeroes on ascend" begin
    one_chunk = PathMaps.HashObserver()
    descend_to!(one_chunk, b("1234"))
    two_chunks = PathMaps.HashObserver()
    descend_to!(two_chunks, b("12")); descend_to!(two_chunks, b("34"))
    by_byte = PathMaps.HashObserver()
    for c in b("1234"); descend_to_byte!(by_byte, c); end
    @test one_chunk.hash == two_chunks.hash == by_byte.hash
    @test one_chunk.depth == two_chunks.depth == by_byte.depth == 4

    reordered = PathMaps.HashObserver()
    descend_to!(reordered, b("4321"))
    @test reordered.hash != one_chunk.hash        # invariant over chunking, NOT over byte order

    ascended = PathMaps.HashObserver()
    descend_to!(ascended, b("1234"))
    ascend!(ascended, 2)
    @test ascended.hash == 0                      # zipper.rs:737 — ascending cannot un-mix the digest
    @test ascended.depth == 2

    # two observers over the same movement agree, whatever the chunking
    m = unit_map(["abc", "abd"])
    z1 = read_zipper(m); h1 = PathMaps.HashObserver()
    z2 = read_zipper(m); h2 = PathMaps.HashObserver()
    while to_next_val_observed!(z1, h1); end
    while to_next_val_observed!(z2, h2); end
    @test h1.hash == h2.hash && h1.depth == h2.depth
end

@testset "PathTracker gives a path to a wrapped zipper (path_tracker.rs)" begin
    m = unit_map(["hello", "help", "world"])
    t = PathTracker(read_zipper(m))
    @test descend_to_existing!(t, b("hello")) == 5
    @test collect(UInt8, path(t)) == b("hello")
    @test depth(t) == 5
    @test is_val(t)
    @test ascend!(t, 2) == 2
    @test collect(UInt8, path(t)) == b("hel")
    @test focus_byte(t) == UInt8('l')

    # the tracker's buffer must agree with the wrapped zipper's own path at every step
    t2 = PathTracker(read_zipper(m))
    while to_next_val!(t2)
        @test collect(UInt8, path(t2)) == collect(UInt8, path(t2.zipper))
    end
    reset!(t2)
    @test at_root(t2) && isempty(path(t2))

    # with an origin: `path` is relative to the root, `origin_path` absolute (path_tracker.rs:43, :179-182)
    t3 = PathTracker(read_zipper_at_path(m, b("hel")), b("hel"))
    @test collect(UInt8, root_prefix_path(t3)) == b("hel")
    @test isempty(path(t3))
    @test to_next_val!(t3)
    @test collect(UInt8, path(t3)) == b("lo")
    @test collect(UInt8, origin_path(t3)) == b("hello")

    # and it still fans movement out to the caller's observer
    t4 = PathTracker(read_zipper(m))
    obs = UInt8[]
    while to_next_val_observed!(t4, obs)
        @test obs == collect(UInt8, path(t4))
    end
end

end # testset

end # module
