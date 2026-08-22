# path_exists_at vs upstream — regression guard.
#
# Upstream (PathMap/src/trie_map.rs:328-332) is simply
#     let zipper = self.read_zipper_at_borrowed_path(path); zipper.path_exists()
# Ours had a bespoke two-phase traversal that disagreed with our OWN zipper on MID-EDGE prefixes:
# for {abc, abcdefghij} it reported "a", "abcd", "abcdefghi" as NOT existing, and for a single
# 16-byte key the prefixes 1..16 came back FFFFFFFFFFFFFTFT instead of all-true. Expected values
# below are upstream's, measured from the Rust.
using PathMap, Test

const PM = PathMap.PathMap

@testset "path_exists_at — mid-edge prefixes (upstream trie_map.rs:328)" begin
    m = PM{PathMap.UnitVal}()
    PathMap.set_val_at!(m, b"abc", PathMap.UnitVal())
    PathMap.set_val_at!(m, b"abcdefghij", PathMap.UnitVal())

    # every proper prefix of a stored key exists, INCLUDING ones that fall mid-edge
    for k in ["a", "ab", "abc", "abcd", "abcdefghi", "abcdefghij"]
        @test PathMap.path_exists_at(m, Vector{UInt8}(codeunits(k)))
    end
    @test !PathMap.path_exists_at(m, Vector{UInt8}(codeunits("abz")))   # genuinely absent
    @test !PathMap.path_exists_at(m, Vector{UInt8}(codeunits("abcx")))

    # must agree with the zipper it now delegates to — the self-inconsistency that exposed the bug
    for k in ["a", "ab", "abc", "abcd", "abcdefghi", "abcdefghij", "abz", "abcx"]
        p = Vector{UInt8}(codeunits(k))
        @test PathMap.path_exists_at(m, p) ==
            PathMap.zipper_path_exists(PathMap.read_zipper_at_path(m, p))
    end

    # single long key: EVERY prefix length exists (upstream: TTTTTTTTTTTTTTTT)
    m2 = PM{PathMap.UnitVal}()
    key = repeat(b"z", 16)
    PathMap.set_val_at!(m2, key, PathMap.UnitVal())
    @test all(PathMap.path_exists_at(m2, key[1:n]) for n in 1:16)
    @test !PathMap.path_exists_at(m2, vcat(key, UInt8('q')))
end
