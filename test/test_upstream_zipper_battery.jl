# test_upstream_zipper_battery.jl — upstream's OWN zipper conformance battery, ported.
#
# WHY. Upstream PathMap authors and ships a type-generic zipper conformance battery
# (`zipper_moving_tests` / `zipper_iteration_tests`, src/zipper.rs:3037+), applied there to
# ProductZipper, ProductZipperG, ArenaCompactZipper, OverlayZipper and more. WE HAVE NEVER RUN IT.
#
# That matters more than it sounds, because on 2026-08-03 the zipper-composition layer was measured
# to have ZERO differential coverage: `test/differential/rust_probe/src/` contains no reference to
# any zipper composition, and the 3000-case corpus exercises the trie ALGEBRA (join/meet/subtract/
# graft) only. So this file covers a surface where we currently have no oracle at all — and it is
# the same surface carrying the open CmpSource risk in test/differential/ADAPTATIONS.md entry 2.
#
# The precedent for why an unmeasured surface is dangerous is in this repo: the 2026-08-01 COW class
# put five corrupting sites behind 3000 GREEN cases, because the harness could not observe the
# defect. Finding nothing here is still a result — it converts "unmeasured" into "measured clean".
#
# FIDELITY. Test bodies are ported operation-for-operation from the upstream functions, keeping
# upstream's own key sets and comments so a divergence is attributable to OUR zipper rather than to
# a re-imagined test. Upstream line numbers are cited per test.
using Test, PathMap
const PM = PathMap.PathMap   # module and type share the name (same alias runtests.jl uses)

# upstream src/zipper.rs:3228
const ZIPPER_MOVING_BASIC_TEST_KEYS =
    ["romane", "romanus", "romulus", "rubens", "ruber", "rubicon", "rubicundus", "rom'i"]

"Build a PathMap over `keys` and return a read zipper at its root."
function battery_zipper(keys::Vector{String})
    m = PM{UnitVal}()
    for k in keys
        set_val_at!(m, Vector{UInt8}(k), UNIT_VAL)
    end
    (m, read_zipper(m))
end

mask_bytes(z) = sort!(collect(zipper_child_mask(z)))
pathstr(z) = String(copy(collect(zipper_path(z))))

@testset "upstream zipper conformance battery (ported)" begin

    @testset "zipper_moving_basic_test (upstream zipper.rs:3230)" begin
        _, z = battery_zipper(ZIPPER_MOVING_BASIC_TEST_KEYS)

        zipper_descend_to!(z, b"r"); zipper_descend_to!(z, b"o"); zipper_descend_to!(z, b"m")
        zipper_descend_to!(z, b"'")
        @test zipper_path_exists(z)                       # focus = rom'  (' is the lowest byte)

        # upstream: "we can't actually guarantee whether we land on 'a' or 'u'"
        @test zipper_to_next_sibling_byte!(z)
        @test pathstr(z) in ("roma", "romu")
        @test mask_bytes(z) == [UInt8('n')]               # romane/romanus both continue with n

        @test zipper_to_next_sibling_byte!(z)
        @test pathstr(z) in ("roma", "romu")
        @test mask_bytes(z) == [UInt8('l')]               # romulus continues with l

        @test !zipper_to_next_sibling_byte!(z)            # only 3 children: ' a u
        @test zipper_to_prev_sibling_byte!(z)
        @test pathstr(z) in ("roma", "romu")
        @test zipper_to_prev_sibling_byte!(z)
        @test pathstr(z) == "rom'"                        # back where we began
        @test mask_bytes(z) == [UInt8('i')]

        @test zipper_ascend!(z, 1)                        # focus = rom
        @test mask_bytes(z) == [UInt8('\''), UInt8('a'), UInt8('u')]

        # ' < a < u  (39 < 97 < 117) — indexed descent must follow byte order
        @test zipper_descend_indexed_byte!(z, 0)
        @test mask_bytes(z) == [UInt8('i')]
        @test zipper_ascend!(z, 1)
        @test zipper_descend_indexed_byte!(z, 1)
        @test mask_bytes(z) == [UInt8('n')]
        @test zipper_ascend!(z, 1)
        @test zipper_descend_indexed_byte!(z, 2)
        @test mask_bytes(z) == [UInt8('l')]
        @test zipper_ascend!(z, 1)
    end

end
