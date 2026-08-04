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

# ── RUN THE BATTERY AGAINST MORE THAN ONE ZIPPER TYPE, as upstream does ──────────────────────────
# Upstream's macro is invoked once per zipper type (product_zipper.rs:1791-1828 applies it to
# ProductZipper AND ProductZipperG; arena_compact.rs:2856 and overlay_zipper.rs:362 to two more),
# with a `$make_z` closure that builds the zipper from a map + root path. `BATTERY_MAKE_Z` is that
# closure, swapped by the loop at the bottom of this file, so every test below runs unchanged
# against each type — no test is written twice.
# NB the empty-path case must use `read_zipper`, not `read_zipper_at_path(m, [])` — they return
# DIFFERENT types (ReadZipperCore vs ReadZipperUntracked) and only the former carries the full
# zipper_* method set. Measured: routing everything through read_zipper_at_path errors with
# `no method matching zipper_reset!(::ReadZipperUntracked)`.
const BATTERY_MAKE_Z = Ref{Function}(
    (m, path) -> isempty(path) ? read_zipper(m) : read_zipper_at_path(m, path))

battery_map(keys::Vector{String}) = begin
    m = PM{UnitVal}()
    for k in keys
        set_val_at!(m, Vector{UInt8}(k), UNIT_VAL)
    end
    m
end

"Build a PathMap over `keys` and return a zipper at its root (type per BATTERY_MAKE_Z)."
function battery_zipper(keys::Vector{String})
    m = battery_map(keys)
    (m, BATTERY_MAKE_Z[](m, UInt8[]))
end

"Zipper rooted at `path` — upstream's `run_test` third argument."
battery_zipper_at(m, path) = BATTERY_MAKE_Z[](m, path)

# ── forwarding lives in the PACKAGE, not here ────────────────────────────────────────────────────
# `zipper_*` methods for ProductZipperG are defined in src/zipper/ProductZipperG.jl. Defining them
# HERE (at Main scope, extending PathMap's generics) invalidated the package's precompiled code and
# made the base battery run go 1.6s -> 49.3s, with the whole suite past 20 minutes. Measured, then
# moved. ProductZipperG implementing the zipper interface is a package concern regardless.

mask_bytes(z) = sort!(collect(zipper_child_mask(z)))
pathstr(z) = String(copy(collect(zipper_path(z))))

function run_battery(kind::String)
@testset "upstream zipper conformance battery — $kind" begin

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


    # ─────────────────────────────────────────────────────────────────────────────────────────────
    # upstream src/zipper.rs:3273-3274
    #   ZIPPER_WITH_ROOT_PATH_KEYS = romane romanus romulus rubens ruber rubicon rubicundus rom'i
    #   ZIPPER_WITH_ROOT_PATH_PATH = b"ro"
    # The macro (zipper.rs:3055-3058) passes ZIPPER_WITH_ROOT_PATH_PATH as `z_path` to `run_test`,
    # i.e. this zipper's ROOT is "ro" — every `path()` below is RELATIVE to it, and `at_root()`
    # means "at ro", not "at the map root".
    # ─────────────────────────────────────────────────────────────────────────────────────────────
    @testset "zipper_with_root_path (upstream zipper.rs:3277)" begin
        ks = ["romane", "romanus", "romulus", "rubens", "ruber", "rubicon", "rubicundus", "rom'i"]
        m, _ = battery_zipper(ks)
        z = battery_zipper_at(m, b"ro")     # ZIPPER_WITH_ROOT_PATH_PATH

        # Test `descend_to` and `ascend_until`
        @test pathstr(z) == ""
        @test zipper_child_count(z) == 1
        zipper_descend_to!(z, b"m")
        @test pathstr(z) == "m"
        @test zipper_child_count(z) == 3
        zipper_descend_to!(z, b"an")
        @test pathstr(z) == "man"
        @test zipper_child_count(z) == 2
        zipper_descend_to!(z, b"e")
        @test pathstr(z) == "mane"
        @test zipper_child_count(z) == 0
        @test zipper_ascend_until!(z)
        zipper_descend_to!(z, b"us")
        @test pathstr(z) == "manus"
        @test zipper_child_count(z) == 0
        @test zipper_ascend_until!(z)
        @test pathstr(z) == "man"
        @test zipper_child_count(z) == 2
        @test zipper_ascend_until!(z)
        @test pathstr(z) == "m"
        @test zipper_child_count(z) == 3
        @test zipper_ascend_until!(z)
        @test pathstr(z) == ""
        @test zipper_at_root(z)
        @test !zipper_ascend_until!(z)

        # Test `ascend`
        zipper_descend_to!(z, b"manus")
        @test pathstr(z) == "manus"
        @test zipper_ascend!(z, 1)
        @test pathstr(z) == "manu"
        @test !zipper_ascend!(z, 5)           # 5 > 4 remaining bytes: fails, but still lands at root
        @test pathstr(z) == ""
        @test zipper_at_root(z)
        zipper_descend_to!(z, b"mane")
        @test pathstr(z) == "mane"
        @test zipper_ascend!(z, 3)
        @test pathstr(z) == "m"
        @test zipper_child_count(z) == 3
    end

    # ─────────────────────────────────────────────────────────────────────────────────────────────
    # upstream src/zipper.rs:3322-3323 — "A wide shallow trie"
    #   ZIPPER_DANGLING_DESCEND_TEST_KEYS = ["b", "bqqq"]      (root path: &[], i.e. the map root)
    # ─────────────────────────────────────────────────────────────────────────────────────────────
    # `descend_first_byte` must agree with `descend_indexed_byte(0)`, including when the focus
    # sits on a non-existent (dangling) path, where there are no children to descend into
    @testset "zipper_dangling_descend_test (upstream zipper.rs:3327)" begin
        _, z = battery_zipper(["b", "bqqq"])

        # Descend to a path that doesn't exist in the trie.  `b"bq"` exists as a prefix of
        # `b"bqqq"`, but `b"bb"` does not.
        zipper_descend_to!(z, b"bb")
        @test zipper_path_exists(z) == false
        @test zipper_child_count(z) == 0

        # With no children, `descend_indexed_byte(0)` is out of range and must not move
        @test zipper_descend_indexed_byte!(z, 0) == false
        @test pathstr(z) == "bb"

        # `descend_first_byte` is documented to behave identically to `descend_indexed_byte(0)`
        @test zipper_descend_first_byte!(z) == false
        @test pathstr(z) == "bb"
    end

    # ─────────────────────────────────────────────────────────────────────────────────────────────
    # upstream src/zipper.rs:3742
    #   ZIPPER_DESCEND_TO_EXISTING_TEST1_KEYS = arrow bow cannon roman romane romanus romulus
    #                                           rubens ruber rubicon rubicundus rom'i
    # (root path: &[], the map root — zipper.rs:3145-3148)
    # ─────────────────────────────────────────────────────────────────────────────────────────────
    @testset "descend_to_existing_test1 (upstream zipper.rs:3744)" begin
        _, z = battery_zipper(["arrow", "bow", "cannon", "roman", "romane", "romanus", "romulus",
                               "rubens", "ruber", "rubicon", "rubicundus", "rom'i"])

        @test zipper_descend_to_existing!(z, b"bowling") == 3
        @test pathstr(z) == "bow"
        zipper_reset!(z)

        @test zipper_descend_to_existing!(z, b"can") == 3
        @test pathstr(z) == "can"
        zipper_reset!(z)

        @test zipper_descend_to_existing!(z, UInt8[]) == 0
        @test pathstr(z) == ""
        zipper_reset!(z)
    end

    # ─────────────────────────────────────────────────────────────────────────────────────────────
    # upstream src/zipper.rs:3759 — ZIPPER_DESCEND_TO_EXISTING_TEST2_KEYS = ["arrow"]
    # ─────────────────────────────────────────────────────────────────────────────────────────────
    # Tests a really long path that doesn't exist, to exercise the chunk-descending code
    # (upstream writes the two literals out in full: "arrow" / "arr" each followed by 160 '0's)
    @testset "descend_to_existing_test2 (upstream zipper.rs:3762)" begin
        _, z = battery_zipper(["arrow"])
        zeros160 = repeat("0", 160)

        @test zipper_descend_to_existing!(z, Vector{UInt8}("arrow" * zeros160)) == 5
        @test pathstr(z) == "arrow"
        zipper_reset!(z)

        @test zipper_descend_to_existing!(z, Vector{UInt8}("arr" * zeros160)) == 3
        @test pathstr(z) == "arr"
    end

    # ─────────────────────────────────────────────────────────────────────────────────────────────
    # upstream src/zipper.rs:3772 — ZIPPER_DESCEND_TO_EXISTING_TEST3_KEYS = ["arrow"]
    # ─────────────────────────────────────────────────────────────────────────────────────────────
    # Tests calling the method when the focus is already on a non-existent path
    @testset "descend_to_existing_test3 (upstream zipper.rs:3775)" begin
        _, z = battery_zipper(["arrow"])

        zipper_descend_to!(z, b"arrow00000")
        @test zipper_path_exists(z) == false
        @test pathstr(z) == "arrow00000"

        @test zipper_descend_to_existing!(z, b"0000") == 0
        @test pathstr(z) == "arrow00000"
    end


    @testset "zipper_indexed_bytes_test1 (upstream zipper.rs:3345)" begin
        # upstream src/zipper.rs:3343 — ZIPPER_INDEXED_BYTE_TEST1_KEYS
        keys1 = ["0", "1", "2", "3", "4", "5", "6"]
        _, z = battery_zipper(keys1)

        zipper_descend_to!(z, b"2")
        @test zipper_is_val(z) == true
        @test zipper_child_count(z) == 0
        @test !zipper_descend_indexed_byte!(z, 1)
        @test pathstr(z) == "2"

        zipper_reset!(z)
        @test zipper_descend_indexed_byte!(z, 2)
        @test zipper_is_val(z) == true
        @test zipper_child_count(z) == 0
        @test pathstr(z) == "2"
        @test !zipper_descend_indexed_byte!(z, 1)
        @test pathstr(z) == "2"

        zipper_reset!(z)
        @test !zipper_descend_indexed_byte!(z, 7)
        @test zipper_is_val(z) == false
        @test zipper_child_count(z) == 7
        @test pathstr(z) == ""

        # Try with a narrow deeper trie
        # (upstream builds this second map inside the test body, then takes a plain read_zipper)
        keys2 = ["000", "1Z", "00AAA", "00AA000", "00AA00AAA"]
        _, z = battery_zipper(keys2)

        zipper_descend_to!(z, b"000")
        @test zipper_val(z) === UNIT_VAL              # upstream: Some(&())
        @test pathstr(z) == "000"
        @test zipper_child_count(z) == 0
        @test !zipper_descend_indexed_byte!(z, 1)
        @test pathstr(z) == "000"

        zipper_reset!(z)
        @test !zipper_descend_indexed_byte!(z, 2)
        @test zipper_child_count(z) == 2
        @test zipper_descend_indexed_byte!(z, 1)
        @test pathstr(z) == "1"
        @test zipper_val(z) === nothing               # upstream: None
        @test zipper_child_count(z) == 1
        @test !zipper_descend_indexed_byte!(z, 1)
        @test zipper_val(z) === nothing
        @test pathstr(z) == "1"

        zipper_reset!(z)
        @test zipper_descend_indexed_byte!(z, 0)
        @test pathstr(z) == "0"
        @test zipper_val(z) === nothing
        @test zipper_child_count(z) == 1
        @test !zipper_descend_indexed_byte!(z, 1)
        @test zipper_val(z) === nothing
        @test pathstr(z) == "0"
    end

    @testset "zipper_indexed_bytes_test2 (upstream zipper.rs:3402)" begin
        # upstream src/zipper.rs:3399 — "A narrow deeper trie" (ZIPPER_INDEXED_BYTE_TEST2_KEYS)
        keys = ["000", "1Z", "00AAA", "00AA000", "00AA00AAA"]
        _, z = battery_zipper(keys)

        zipper_descend_to!(z, b"000")
        @test zipper_is_val(z) == true
        @test pathstr(z) == "000"
        @test zipper_child_count(z) == 0
        @test !zipper_descend_indexed_byte!(z, 1)
        @test pathstr(z) == "000"

        zipper_reset!(z)
        @test !zipper_descend_indexed_byte!(z, 2)
        @test zipper_child_count(z) == 2
        @test zipper_descend_indexed_byte!(z, 1)
        @test pathstr(z) == "1"
        @test zipper_is_val(z) == false
        @test zipper_child_count(z) == 1
        @test !zipper_descend_indexed_byte!(z, 1)
        @test zipper_is_val(z) == false
        @test pathstr(z) == "1"

        zipper_reset!(z)
        @test zipper_descend_indexed_byte!(z, 0)
        @test pathstr(z) == "0"
        @test zipper_is_val(z) == false
        @test zipper_child_count(z) == 1
        @test !zipper_descend_indexed_byte!(z, 1)
        @test zipper_is_val(z) == false
        @test pathstr(z) == "0"
    end

    @testset "indexed_zipper_movement1 (upstream zipper.rs:3635)" begin
        # upstream src/zipper.rs:3633 — ZIPPER_INDEXED_MOVEMENT_TEST1_KEYS
        keys = ["arrow", "bow", "cannon", "romane", "romanus", "romulus",
                "rubens", "ruber", "rubicon", "rubicundus", "rom'i"]
        _, z = battery_zipper(keys)

        # upstream's own in-test helper: descends a single specific byte using
        # `descend_indexed_byte`. Just for testing. A real user would use `descend_towards`.
        function descend_byte(zz, byte::UInt8)
            for i in 0:(zipper_child_count(zz) - 1)   # upstream i is 0-based; ours takes the same index
                @test zipper_descend_indexed_byte!(zz, i) == true
                if last(zipper_path(zz)) == byte
                    break
                else
                    @test zipper_ascend!(zz, 1) == true
                end
            end
        end

        @test pathstr(z) == ""
        @test zipper_child_count(z) == 4
        descend_byte(z, UInt8('r'))
        @test pathstr(z) == "r"
        @test zipper_child_count(z) == 2
        @test zipper_descend_until!(z) == false
        descend_byte(z, UInt8('o'))
        @test pathstr(z) == "ro"
        @test zipper_child_count(z) == 1
        @test zipper_descend_until!(z) == true
        @test pathstr(z) == "rom"
        @test zipper_child_count(z) == 3

        zipper_reset!(z)
        @test zipper_descend_until!(z) == false
        descend_byte(z, UInt8('a'))
        @test pathstr(z) == "a"
        @test zipper_child_count(z) == 1
        @test zipper_descend_until!(z) == true
        @test pathstr(z) == "arrow"
        @test zipper_child_count(z) == 0

        @test zipper_ascend!(z, 3) == true
        @test pathstr(z) == "ar"
        @test zipper_child_count(z) == 1
    end

    @testset "zipper_child_mask_test1 (upstream zipper.rs:3700)" begin
        # upstream src/zipper.rs:3698 — ZIPPER_CHILD_MASK_TEST1_KEYS = [[8,194,1,45,194,1], [34,193]]
        # Non-UTF8 byte keys: Julia `String(::Vector{UInt8})` is byte-transparent, and
        # `battery_zipper` feeds them back through `Vector{UInt8}`, so the trie sees these bytes.
        keys = [String(UInt8[8, 194, 1, 45, 194, 1]), String(UInt8[34, 193])]
        _, z = battery_zipper(keys)

        zipper_descend_to!(z, UInt8[8, 194, 1])
        @test zipper_path_exists(z) == true
        @test zipper_child_count(z) == 1
        # upstream asserts the raw mask words: [0x200000000000, 0, 0, 0]
        # word 0 covers bytes 0..63, bit 45 (0x2000_0000_0000 == 1<<45) => byte 45
        @test mask_bytes(z) == [UInt8(45)]

        zipper_reset!(z)
        zipper_descend_to!(z, UInt8[8, 194, 1, 45])
        @test zipper_path_exists(z) == true
        @test zipper_child_count(z) == 1
        # upstream asserts the raw mask words: [0, 0, 0, 0x4]
        # word 3 covers bytes 192..255, bit 2 => byte 194
        @test mask_bytes(z) == [UInt8(194)]
    end

    @testset "zipper_child_mask_test2 (upstream zipper.rs:3716)" begin
        # upstream src/zipper.rs:3714 — ZIPPER_CHILD_MASK_TEST2_KEYS
        keys = ["arrow", "bow", "cannon", "roman", "romane", "romanus", "romulus",
                "rubens", "ruber", "rubicon", "rubicundus", "rom'i"]
        _, z = battery_zipper(keys)

        #'a' + 'b' + 'c' + 'r'
        # upstream: [0, 1<<(b'a'-64) | 1<<(b'b'-64) | 1<<(b'c'-64) | 1<<(b'r'-64), 0, 0]
        # word 1 covers bytes 64..127, so those four bits are exactly the bytes a b c r
        @test mask_bytes(z) == [UInt8('a'), UInt8('b'), UInt8('c'), UInt8('r')]

        i = 0
        while zipper_to_next_step!(z)
            if i == 0
                #'r' descending from 'a' in "arrow"
                @test mask_bytes(z) == [UInt8('r')]
            elseif i == 1
                #'r' descending from "ar" in "arrow"
                @test mask_bytes(z) == [UInt8('r')]
            elseif i == 2
                #'o' descending from "arr" in "arrow"
                @test mask_bytes(z) == [UInt8('o')]
            elseif i == 3
                #'w' descending from "arro" in "arrow"
                @test mask_bytes(z) == [UInt8('w')]
            elseif i == 4
                #leaf node, "arrow"
                @test mask_bytes(z) == UInt8[]
            elseif i == 14
                #'o' + 'u' descending from 'r' in "roman", "rubens", etc.
                @test mask_bytes(z) == [UInt8('o'), UInt8('u')]
            end
            i += 1
        end
    end

    @testset "zipper_descend_until_test1 (upstream zipper.rs:3434)" begin
        # Tests how descend_until treats values along paths
        # upstream ZIPPER_DESCEND_UNTIL_TEST1_KEYS (zipper.rs:3432); root path = &[]
        descend_until_keys = ["a", "ab", "abCDEf", "abCDEfGHi"]
        _, z = battery_zipper(descend_until_keys)

        for key in descend_until_keys
            @test zipper_descend_until!(z)
            @test pathstr(z) == key
        end
    end

    @testset "zipper_descend_until_max_bytes_test1 (upstream zipper.rs:3444)" begin
        # Tests how descend_until_max_bytes enforces a max descent length
        # upstream ZIPPER_DESCEND_UNTIL_MAX_BYTES_TEST1_KEYS (zipper.rs:3442); root path = &[]
        _, z = battery_zipper(["a0abcdef", "a0abcxy", "a1mnopqr"])

        zipper_descend_to!(z, b"a0")
        @test pathstr(z) == "a0"
        @test zipper_descend_until_max_bytes!(z, 2)
        @test pathstr(z) == "a0ab"

        zipper_reset!(z)
        zipper_descend_to!(z, b"a1")
        @test pathstr(z) == "a1"
        @test zipper_descend_until_max_bytes!(z, 3)
        @test pathstr(z) == "a1mno"

        zipper_reset!(z)
        zipper_descend_to!(z, b"a0")
        @test pathstr(z) == "a0"
        @test zipper_descend_until_max_bytes!(z, 10)
        @test pathstr(z) == "a0abc"

        zipper_reset!(z)
        zipper_descend_to!(z, b"a0")
        @test pathstr(z) == "a0"
        @test !zipper_descend_until_max_bytes!(z, 0)
        @test pathstr(z) == "a0"
    end

    @testset "zipper_ascend_until_test1 (upstream zipper.rs:3472)" begin
        # Test a 3-way branch, so we definitely don't have a pair node
        # upstream ZIPPER_ASCEND_UNTIL_TEST1_KEYS (zipper.rs:3470); root path = &[]
        _, z = battery_zipper(["AAa", "AAb", "AAc"])

        zipper_descend_to!(z, b"AAaDDd")
        @test !zipper_path_exists(z)
        @test pathstr(z) == "AAaDDd"
        @test zipper_ascend_until!(z)
        @test pathstr(z) == "AAa"
        @test zipper_ascend_until!(z)
        @test pathstr(z) == "AA"
        @test zipper_ascend_until!(z)
        @test pathstr(z) == ""
        @test !zipper_ascend_until!(z)
    end

    @testset "zipper_ascend_until_test2 (upstream zipper.rs:3488)" begin
        # Test what's likely to be represented as a pair node
        # upstream ZIPPER_ASCEND_UNTIL_TEST2_KEYS (zipper.rs:3486); root path = &[]
        _, z = battery_zipper(["AAa", "AAb"])

        zipper_descend_to!(z, b"AAaDDd")
        @test !zipper_path_exists(z)
        @test pathstr(z) == "AAaDDd"
        @test zipper_ascend_until!(z)
        @test pathstr(z) == "AAa"
        @test zipper_ascend_until!(z)
        @test pathstr(z) == "AA"
        @test zipper_ascend_until!(z)
        @test pathstr(z) == ""
        @test !zipper_ascend_until!(z)
    end

    @testset "zipper_ascend_until_test3 (upstream zipper.rs:3504)" begin
        # Test a straight-line trie
        # upstream ZIPPER_ASCEND_UNTIL_TEST3_KEYS (zipper.rs:3502); root path = &[]
        _, z = battery_zipper(["1", "12", "123", "1234", "12345"])

        # First test that ascend_until stops when transitioning from non-existent path
        zipper_descend_to!(z, b"123456")
        @test zipper_path_exists(z) == false
        @test zipper_ascend_until!(z)
        @test pathstr(z) == "12345"

        # Test that ascend_until stops at each value
        @test zipper_ascend_until!(z)
        @test pathstr(z) == "1234"
        @test zipper_ascend_until!(z)
        @test pathstr(z) == "123"
        @test zipper_ascend_until!(z)
        @test pathstr(z) == "12"
        @test zipper_ascend_until!(z)
        @test pathstr(z) == "1"
        @test zipper_ascend_until!(z)
        @test pathstr(z) == ""
        @test !zipper_ascend_until!(z)
        @test zipper_at_root(z)

        # Test that ascend_until_branch skips over all the values
        zipper_descend_to!(z, b"12345")
        @test zipper_path_exists(z)
        @test pathstr(z) == "12345"
        @test zipper_ascend_until_branch!(z)
        @test pathstr(z) == ""
        @test zipper_at_root(z)

        # Try with some actual branches in the trie.
        # Some paths encountered will be values only, some will be branches only, and some will be both
        # (upstream builds a second PathMap inline here — zipper.rs:3536)
        _, z2 = battery_zipper(["1", "123", "12345", "1abc", "1234abc"])

        zipper_descend_to!(z2, b"12345")
        @test zipper_path_exists(z2)
        @test pathstr(z2) == "12345"
        @test zipper_ascend_until!(z2)
        @test pathstr(z2) == "1234"          # "1234" is a branch only
        @test zipper_is_val(z2) == false
        @test zipper_child_count(z2) == 2
        @test zipper_ascend_until!(z2)
        @test pathstr(z2) == "123"           # "123" is a value only
        @test zipper_child_count(z2) == 1
        @test zipper_is_val(z2) == true
        @test zipper_ascend_until!(z2)       # Jump over "12" because it's neither a branch nor a value
        @test pathstr(z2) == "1"             # "1" is both a branch and a value
        @test zipper_is_val(z2) == true
        @test zipper_child_count(z2) == 2
        @test zipper_ascend_until!(z2)
        @test pathstr(z2) == ""
        @test zipper_child_count(z2) == 1
        @test !zipper_ascend_until!(z2)
        @test zipper_at_root(z2)

        # Test that ascend_until_branch skips over all the values
        zipper_descend_to!(z2, b"12345")
        @test zipper_path_exists(z2)
        @test zipper_ascend_until_branch!(z2)
        @test pathstr(z2) == "1234"
        @test zipper_ascend_until_branch!(z2)
        @test pathstr(z2) == "1"
        @test zipper_ascend_until_branch!(z2)
        @test pathstr(z2) == ""
        @test !zipper_ascend_until_branch!(z2)
        @test zipper_at_root(z2)
    end

    @testset "zipper_ascend_until_test4 (upstream zipper.rs:3578)" begin
        # Test a trie with some actual branches
        # Some paths encountered will be values only, some will be branches only, and some will be both
        # upstream ZIPPER_ASCEND_UNTIL_TEST4_KEYS (zipper.rs:3576); root path = &[]
        _, z = battery_zipper(["1", "123", "12345", "1abc", "1234abc"])

        zipper_descend_to!(z, b"12345")
        @test zipper_path_exists(z)
        @test pathstr(z) == "12345"
        @test zipper_ascend_until!(z)
        @test pathstr(z) == "1234"           # "1234" is a branch only
        @test zipper_is_val(z) == false
        @test zipper_child_count(z) == 2
        @test zipper_ascend_until!(z)
        @test pathstr(z) == "123"            # "123" is a value only
        @test zipper_child_count(z) == 1
        @test zipper_is_val(z) == true
        @test zipper_ascend_until!(z)        # Jump over "12" because it's neither a branch nor a value
        @test pathstr(z) == "1"              # "1" is both a branch and a value
        @test zipper_is_val(z) == true
        @test zipper_child_count(z) == 2
        @test zipper_ascend_until!(z)
        @test pathstr(z) == ""
        @test zipper_child_count(z) == 1
        @test !zipper_ascend_until!(z)
        @test zipper_at_root(z)

        # Test that ascend_until_branch skips over all the values
        zipper_descend_to!(z, b"12345")
        @test zipper_path_exists(z)
        @test zipper_ascend_until_branch!(z)
        @test pathstr(z) == "1234"
        @test zipper_ascend_until_branch!(z)
        @test pathstr(z) == "1"
        @test zipper_ascend_until_branch!(z)
        @test pathstr(z) == ""
        @test !zipper_ascend_until_branch!(z)
        @test zipper_at_root(z)
    end

    @testset "zipper_ascend_until_test5 (upstream zipper.rs:3617)" begin
        # Test ascending over a long key that spans multiple nodes
        # upstream ZIPPER_ASCEND_UNTIL_TEST5_KEYS (zipper.rs:3615) is the literal &[b"A", b"AAA...A"];
        # the second literal is exactly 127 'A' bytes (counted from the upstream source line).
        long_a = "A"^127
        _, z = battery_zipper(["A", long_a])

        # Test that ascend_until stops when transitioning from non-existent path
        # (upstream descends 127 'A' bytes followed by one 'B' — zipper.rs:3620)
        zipper_descend_to!(z, Vector{UInt8}(long_a * "B"))
        @test zipper_path_exists(z) == false
        @test zipper_ascend_until!(z)
        @test pathstr(z) == long_a

        # Test that jump all the way back to where we want to be
        @test zipper_ascend_until!(z)
        @test pathstr(z) == "A"
        @test zipper_ascend_until!(z)
        @test pathstr(z) == ""
        @test zipper_ascend_until!(z) == false
    end

    @testset "to_next_step_test1 (upstream zipper.rs:3787)" begin
        # upstream ZIPPER_TO_NEXT_STEP_TEST1_KEYS (zipper.rs:3785); root path = &[]
        _, z = battery_zipper(["arrow", "bow", "cannon", "roman", "romane", "romanus",
                               "romulus", "rubens", "ruber", "rubicon", "rubicundus", "rom'i"])

        # PORT NOTE: upstream's `while zipper.to_next_step()` loop is unbounded. A zipper that fails
        # to terminate would HANG the suite rather than fail it, so the port caps the walk; the cap
        # is 20x the 43 steps upstream's own indices imply, and tripping it is itself a failure.
        step_cap = 1000
        i = 0
        while zipper_to_next_step!(z)
            if i == 0
                @test pathstr(z) == "a"
            elseif i == 4
                @test pathstr(z) == "arrow"
            elseif i == 5
                @test pathstr(z) == "b"
            elseif i == 7
                @test pathstr(z) == "bow"
            elseif i == 8
                @test pathstr(z) == "c"
            elseif i == 13
                @test pathstr(z) == "cannon"
            elseif i == 14
                @test pathstr(z) == "r"
            elseif i == 18
                @test pathstr(z) == "rom'i"
            elseif i == 20
                @test pathstr(z) == "roman"
            elseif i == 21
                @test pathstr(z) == "romane"
            elseif i == 23
                @test pathstr(z) == "romanus"
            elseif i == 24
                @test pathstr(z) == "romu"
            elseif i == 25
                @test pathstr(z) == "romul"
            elseif i == 26
                @test pathstr(z) == "romulu"
            elseif i == 27
                @test pathstr(z) == "romulus"
            elseif i == 28
                @test pathstr(z) == "ru"
            elseif i == 32
                @test pathstr(z) == "rubens"
            elseif i == 33
                @test pathstr(z) == "ruber"
            elseif i == 37
                @test pathstr(z) == "rubicon"
            elseif i == 42
                @test pathstr(z) == "rubicundus"
            end
            i += 1
            if i > step_cap
                @test i <= step_cap   # to_next_step! walk did not terminate
                break
            end
        end
    end


    # ── zipper_val_at_test (upstream zipper.rs:3904) NOT PORTED — the op does not exist here ──────
    # Upstream's test is nothing but 27 `zipper.val_at(<relative path>)` calls. `val_at` is a
    # `ZipperValues` method (zipper.rs:66) that reads the value at a path RELATIVE TO THE FOCUS
    # WITHOUT MOVING the zipper. Our Zipper.jl has `zipper_val` (focus only) and PathMap has
    # `get_val_at` (map-root-absolute) — neither is `val_at`, and emulating it with
    # fork/descend/val would exercise a different code path than the one upstream is testing,
    # so the test would be green while the op is still absent. Reported as a missing op instead.

    @testset "zipper_value_locations (upstream zipper.rs:3677)" begin
        # ZIPPER_VALUE_LOCATIONS_TEST1_KEYS — upstream zipper.rs:3675
        _, z = battery_zipper(["arrow", "bow", "cannon", "roman", "romane", "romanus",
                               "romulus", "rubens", "ruber", "rubicon", "rubicundus", "rom'i"])

        zipper_descend_to!(z, b"ro")
        @test zipper_path_exists(z)
        @test zipper_is_val(z) == false
        zipper_descend_to!(z, b"mulus")
        @test zipper_is_val(z) == true

        zipper_reset!(z)
        zipper_descend_to!(z, b"roman")
        @test zipper_path_exists(z)
        @test zipper_is_val(z) == true          # "roman" is a value AND an interior branch
        zipper_descend_to!(z, b"e")
        @test zipper_is_val(z) == true
        @test zipper_ascend!(z, 1) == true
        zipper_descend_to!(z, b"u")
        @test zipper_is_val(z) == false         # "romanu" is a dangling prefix of "romanus"
        zipper_descend_until!(z)
        @test zipper_is_val(z) == true
    end

    @testset "zipper_byte_iter_test1 (upstream zipper.rs:3819)" begin
        # ZIPPER_BYTES_ITER_TEST1_KEYS — upstream zipper.rs:3817
        _, z = battery_zipper(["ABCDEFGHIJKLMNOPQRSTUVWXYZ", "ab"])

        zipper_descend_to_byte!(z, UInt8('A'))
        @test zipper_path_exists(z) == true
        @test zipper_descend_first_byte!(z) == true
        @test pathstr(z) == "AB"
        @test zipper_to_next_sibling_byte!(z) == false
        @test pathstr(z) == "AB"
    end

    @testset "zipper_byte_iter_test2 (upstream zipper.rs:3832)" begin
        # ZIPPER_BYTES_ITER_TEST2_KEYS / _PATH — upstream zipper.rs:3829-3830.
        # Byte keys (not UTF-8) and a non-root zipper origin, so this builds the map directly
        # rather than through `battery_zipper` (which takes Strings and roots at the map root).
        m = PM{UnitVal}()
        for k in (UInt8[2, 194, 1, 1, 193, 5],
                  UInt8[3, 194, 1, 0, 193, 6, 193, 5],
                  UInt8[3, 193, 4, 193])
            set_val_at!(m, k, UNIT_VAL)
        end
        z = battery_zipper_at(m, UInt8[2, 194])

        @test zipper_descend_first_byte!(z) == true
        @test collect(UInt8, zipper_path(z)) == UInt8[1]
        @test zipper_to_next_sibling_byte!(z) == false
        @test collect(UInt8, zipper_path(z)) == UInt8[1]
    end

    @testset "zipper_byte_iter_test3 (upstream zipper.rs:3842)" begin
        # ZIPPER_BYTES_ITER_TEST3_KEYS / _PATH — upstream zipper.rs:3839-3840
        m = PM{UnitVal}()
        for k in (UInt8[3, 193, 4, 193, 5, 2, 193, 6, 193, 7],
                  UInt8[3, 193, 4, 193, 5, 2, 193, 6, 255])
            set_val_at!(m, k, UNIT_VAL)
        end
        z = battery_zipper_at(m, UInt8[3, 193, 4, 193, 5, 2, 193])

        @test collect(UInt8, zipper_path(z)) == UInt8[]
        @test zipper_descend_first_byte!(z) == true
        @test collect(UInt8, zipper_path(z)) == UInt8[6]
        @test zipper_descend_first_byte!(z) == true
        @test collect(UInt8, zipper_path(z)) == UInt8[6, 193]
        @test zipper_descend_first_byte!(z) == true
        @test collect(UInt8, zipper_path(z)) == UInt8[6, 193, 7]
    end

    @testset "zipper_byte_iter_test4 (upstream zipper.rs:3854)" begin
        # ZIPPER_BYTES_ITER_TEST4_KEYS — upstream zipper.rs:3852
        _, z = battery_zipper(["ABC", "ABCDEF", "ABCdef"])

        # Check that we end up at the first leaf by depth-first search
        # (bounded at 64 steps purely so a cycle FAILS the assertion below instead of hanging the
        #  suite — the deepest key here is 6 bytes)
        for _ in 1:64
            zipper_descend_first_byte!(z) || break
        end
        @test pathstr(z) == "ABCDEF"

        # Try taking a different branch
        zipper_reset!(z)
        zipper_descend_to!(z, b"ABC")
        @test zipper_path_exists(z)
        @test pathstr(z) == "ABC"
        @test zipper_descend_indexed_byte!(z, 1)     # 'D' is index 0, 'd' is index 1
        @test pathstr(z) == "ABCd"
        @test zipper_descend_first_byte!(z)
        @test pathstr(z) == "ABCde"
        @test zipper_descend_first_byte!(z)
        @test pathstr(z) == "ABCdef"
        @test !zipper_descend_first_byte!(z)
    end

    @testset "zipper_byte_iter_test5 (upstream zipper.rs:3880)" begin
        # ZIPPER_BYTES_ITER_TEST5_KEYS — upstream zipper.rs:3874
        keys = [
            UInt8[2, 197, 97, 120, 105, 111, 109, 3, 193, 61, 4, 193, 97, 192, 192, 3, 193, 75, 192, 3, 193, 84, 192, 3, 193, 75, 128, 131, 193, 49],
            UInt8[2, 197, 97, 120, 105, 111, 109, 3, 193, 61, 4, 193, 97, 192, 192, 3, 193, 84, 3, 193, 75, 192, 192, 3, 193, 75, 128, 131, 193, 49],
            UInt8[2, 197, 97, 120, 255, 111, 109, 3, 193, 61, 4, 193, 97, 192, 192, 3, 193, 84, 3, 193, 75, 192, 192, 3, 193, 75, 128, 131, 193, 49],
        ]
        m = PM{UnitVal}()
        for k in keys
            set_val_at!(m, k, UNIT_VAL)
        end
        z = battery_zipper_at(m, UInt8[])

        # `i` is kept 0-based, exactly as upstream, so the two exempt depths read identically
        for i in 0:(length(keys[1]) - 1)
            zipper_reset!(z)
            zipper_descend_to!(z, keys[1][1:i])
            if i != 18 && i != 5
                @test zipper_to_next_sibling_byte!(z) == false
            end
        end

        zipper_reset!(z)
        zipper_descend_to!(z, UInt8[2, 197, 97, 120, 105, 111, 109, 3, 193, 61, 4, 193, 97, 192, 192, 3, 193, 75])
        @test zipper_to_next_sibling_byte!(z) == true
        zipper_reset!(z)
        zipper_descend_to!(z, UInt8[2, 197, 97, 120, 105])
        @test zipper_to_next_sibling_byte!(z) == true
    end

    # Simply calls `to_next_val` over the whole trie, ensuring all paths are visited exactly once
    @testset "zipper_iter_test1 (upstream zipper.rs:4063)" begin
        # ZIPPER_ITER_TEST1_KEYS — upstream zipper.rs:4060.  Order is load-bearing: it is the
        # expected iteration order ('\'' = 0x27 sorts before 'a', so rom'i precedes roman).
        keys = ["arrow", "bow", "cannon", "rom'i", "roman", "romane", "romanus", "romulus",
                "rubens", "ruber", "rubicon", "rubicundus"]
        _, z = battery_zipper(keys)

        # Test iteration of the whole tree
        idx = 0
        @test zipper_is_val(z) == false
        while zipper_to_next_val!(z)
            idx += 1
            idx > length(keys) && break     # guard: over-yield must FAIL below, not hang the suite
            @test pathstr(z) == keys[idx]
        end
        @test idx == length(keys)
    end

    @testset "zipper_iter_test2 (upstream zipper.rs:4084)" begin
        # zipper_iter_test2_paths / ZIPPER_ITER_TEST2_COUNT — upstream zipper.rs:4077-4082.
        # Paths are b"in" ++ i.to_be_bytes(); usize is 64-bit on this target, so 8 big-endian bytes.
        ZIPPER_ITER_TEST2_COUNT = 32
        be8(i) = UInt8[(UInt64(i) >> (8 * (7 - j))) & 0xff for j in 0:7]

        m = PM{UnitVal}()
        for i in 0:(ZIPPER_ITER_TEST2_COUNT - 1)
            set_val_at!(m, vcat(Vector{UInt8}("in"), be8(i)), UNIT_VAL)
        end
        # Test iterating using a zipper that has a root that is not the map root
        z = battery_zipper_at(m, Vector{UInt8}("in"))

        count = 0
        while zipper_to_next_val!(z)
            @test zipper_is_val(z) == true
            @test collect(UInt8, zipper_path(z)) == be8(count)
            count += 1
            count > ZIPPER_ITER_TEST2_COUNT && break   # guard: over-yield FAILS below, not hangs
        end
        @test count == ZIPPER_ITER_TEST2_COUNT
    end

end  # @testset
end  # function run_battery

# ── the two invocations. Base read zipper, then the COMPOSITION — which is the point: upstream
# applies this battery to ProductZipperG too, and until 2026-08-03 ours could not run it at all
# (five ops absent). A ProductZipperG with ZERO secondaries is exactly upstream's own harness
# (product_zipper.rs:1817-1828), and it still routes every operation through the composition
# wrapper's delegation and factor bookkeeping.
run_battery("base read zipper")

BATTERY_MAKE_Z[] = (m, path) -> PathMap.ProductZipperG(
    isempty(path) ? read_zipper(m) : read_zipper_at_path(m, path),
    PathMap.ReadZipperCore{UnitVal, PathMap.GlobalAlloc}[])
run_battery("ProductZipperG (0 secondaries)")

# ── THIRD INVOCATION: a DEPENDENT ZIPPER in the composition. ─────────────────────────────────────
# This is the shape MORK's CmpSource actually builds (MORK Sources.jl:243-246):
#     PrefixZipper(prefix, DependentZipper(read_zipper_at_path(btm, []), policy))
# and it is the layer carrying the open pzg_factor_count / last-factor-guard risk recorded in
# test/differential/ADAPTATIONS.md entry 2 — `secondary` is a LIVE STACK under upstream PR #56's
# invariant, so pzg_factor_count sums a static count with a moving depth.
#
# The enroll callback NEVER enrolls (always returns `nothing`), which keeps every path identical to
# the primary's so upstream's exact path assertions still hold. That is deliberate: it isolates the
# DELEGATION and factor bookkeeping from path rewriting. A callback that enrolled would change the
# paths and the battery would be measuring a different trie, not our zipper.
BATTERY_MAKE_Z[] = (m, path) -> begin
    inner = isempty(path) ? read_zipper(m) : read_zipper_at_path(m, path)
    dpz = PathMap.DependentZipper(inner, nothing, (payload, p, idx) -> (payload, nothing))
    PathMap.ProductZipperG(dpz, PathMap.ReadZipperCore{UnitVal, PathMap.GlobalAlloc}[])
end
run_battery("ProductZipperG over DependentZipper (CmpSource shape)")
