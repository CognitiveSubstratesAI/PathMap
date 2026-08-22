# path_exists_at vs upstream — regression guard.
#
# Upstream (PathMap/src/trie_map.rs:328-332) is simply
#     let zipper = self.read_zipper_at_borrowed_path(path); zipper.path_exists()
# Ours had a bespoke two-phase traversal that disagreed with our OWN zipper on MID-EDGE prefixes:
# for {abc, abcdefghij} it reported "a", "abcd", "abcdefghi" as NOT existing, and for a single
# 16-byte key the prefixes 1..16 came back FFFFFFFFFFFFFTFT instead of all-true. Expected values
# below are upstream's, measured from the Rust.
using PathMaps, Test

const PM = PathMaps.PathMap

@testset "path_exists_at — mid-edge prefixes (upstream trie_map.rs:328)" begin
    m = PM{PathMaps.UnitVal}()
    PathMaps.set_val_at!(m, b"abc", PathMaps.UnitVal())
    PathMaps.set_val_at!(m, b"abcdefghij", PathMaps.UnitVal())

    # every proper prefix of a stored key exists, INCLUDING ones that fall mid-edge
    for k in ["a", "ab", "abc", "abcd", "abcdefghi", "abcdefghij"]
        @test PathMaps.path_exists_at(m, Vector{UInt8}(codeunits(k)))
    end
    @test !PathMaps.path_exists_at(m, Vector{UInt8}(codeunits("abz")))   # genuinely absent
    @test !PathMaps.path_exists_at(m, Vector{UInt8}(codeunits("abcx")))

    # must agree with the zipper it now delegates to — the self-inconsistency that exposed the bug
    for k in ["a", "ab", "abc", "abcd", "abcdefghi", "abcdefghij", "abz", "abcx"]
        p = Vector{UInt8}(codeunits(k))
        @test PathMaps.path_exists_at(m, p) ==
            PathMaps.zipper_path_exists(PathMaps.read_zipper_at_path(m, p))
    end

    # single long key: EVERY prefix length exists (upstream: TTTTTTTTTTTTTTTT)
    m2 = PM{PathMaps.UnitVal}()
    key = repeat(b"z", 16)
    PathMaps.set_val_at!(m2, key, PathMaps.UnitVal())
    @test all(PathMaps.path_exists_at(m2, key[1:n]) for n in 1:16)
    @test !PathMaps.path_exists_at(m2, vcat(key, UInt8('q')))
end
