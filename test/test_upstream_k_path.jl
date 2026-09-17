# test_upstream_k_path.jl — upstream's k-path iteration tests (`zipper_iteration_tests::k_path_test1..a`,
# ~/dev-zone/PathMap src/zipper.rs:4720-5125 @ f477a91), ported for the read zipper.
#
# WHY. None of them had been ported, and our `descend_first_k_path!` was the trait default loop,
# which hangs on a childless focus (docs/UPSTREAM_DELTA_2026-09-16.md P0 #1). The fix ports upstream's
# `ReadZipperCore::k_path_internal`; these are upstream's own checks of it.
#
# FIDELITY. Keys, roots and path assertions are upstream's, test by test. Upstream also threads a
# `PathObserver` through every call and checks it equals `path()`; our port has no observer API, so
# those assertions are dropped (every `path()` assertion is kept). `descend_indexed_byte` returns
# Bool here (upstream `Option<u8>`), and `ascend(n)` returns Bool (upstream: bytes ascended).
using Test, PathMaps
const PMK = PathMaps.PathMap

kp_map(keys) = begin
    m = PMK{UnitVal}()
    for k in keys
        set_val_at!(m, collect(UInt8, k), UNIT_VAL)
    end
    m
end
kp_zipper(keys, root) = (m = kp_map(keys); isempty(root) ? read_zipper(m) : read_zipper_at_path(m, collect(UInt8, root)))
kp_path(z) = collect(UInt8, path(z))
kpb(s::String) = Vector{UInt8}(s)

@testset "upstream k_path iteration tests (zipper.rs:4720-5125)" begin

    @testset "k_path_test1" begin
        keys = [":5:above:3:the:4:fray:", ":5:err:", ":5:erronious:6:potato:", ":5:error:2:is:2:my:4:name:",
            ":5:hello:5:world:", ":5:mucky:4:muck:", ":5:roger:6:rabbit:", ":5:zebra:", ":9:muckymuck:5:raker:"]
        z = kp_zipper(keys, ":")
        @test descend_indexed_byte!(z, 0) !== nothing
        sym_len = parse(Int, Char(kp_path(z)[1]))
        @test sym_len == 5
        @test descend_indexed_byte!(z, 0) !== nothing   # step over ':'
        @test child_count(z) == 6
        @test descend_first_k_path!(z, sym_len + 1) == true
        @test kp_path(z) == kpb("5:above:")
        # blows past "err" (shorter than k) and stops in the middle of "erronious"
        @test to_next_k_path!(z, sym_len + 1) == true
        @test kp_path(z) == kpb("5:erroni")
        @test last(kp_path(z)) != UInt8(':')
        for expected in ["5:error:", "5:hello:", "5:mucky:", "5:roger:", "5:zebra:"]
            @test to_next_k_path!(z, sym_len + 1) == true
            @test kp_path(z) == kpb(expected)
        end
        @test to_next_k_path!(z, sym_len + 1) == false
        @test kp_path(z) == kpb("5:")
        @test child_count(z) == 6
    end

    @testset "k_path_test2" begin
        K_PATH_TEST2_COUNT = 50
        paths = [UInt8[((j + i) % 255) for j in 0:((i % 15) + 4)] for i in 0:(K_PATH_TEST2_COUNT - 1)]
        z = kp_zipper(paths, UInt8[])
        descend_first_k_path!(z, 5)
        count = 1
        while to_next_k_path!(z, 5)
            count += 1
            count > K_PATH_TEST2_COUNT && break   # over-yield fails below instead of spinning
        end
        @test count == K_PATH_TEST2_COUNT
    end

    @testset "k_path_test3" begin
        keys = [":1a1A", ":1a1B", ":1a1C", ":1b1A", ":1b1B", ":1b1C", ":1c1A"]
        z = kp_zipper(keys, ":")
        # first symbols (lower case)
        descend_to!(z, kpb("1"))
        @test path_exists(z)
        @test descend_first_k_path!(z, 1) == true
        @test kp_path(z) == kpb("1a")
        @test to_next_k_path!(z, 1) == true
        @test kp_path(z) == kpb("1b")
        @test to_next_k_path!(z, 1) == true
        @test kp_path(z) == kpb("1c")
        @test to_next_k_path!(z, 1) == false
        @test kp_path(z) == kpb("1")
        # nested second symbols (upper case)
        reset!(z)
        descend_to!(z, kpb("1a1"))
        @test path_exists(z)
        @test descend_first_k_path!(z, 1) == true
        @test kp_path(z) == kpb("1a1A")
        @test to_next_k_path!(z, 1) == true
        @test kp_path(z) == kpb("1a1B")
        @test to_next_k_path!(z, 1) == true
        @test kp_path(z) == kpb("1a1C")
        @test to_next_k_path!(z, 1) == false
        @test kp_path(z) == kpb("1a1")
        # recursive scan
        reset!(z)
        descend_to!(z, kpb("1"))
        @test path_exists(z)
        @test descend_first_k_path!(z, 1) == true
        @test kp_path(z) == kpb("1a")
        @test descend_first_k_path!(z, 2) == true
        @test kp_path(z) == kpb("1a1A")
        @test to_next_k_path!(z, 2) == true
        @test kp_path(z) == kpb("1a1B")
        @test to_next_k_path!(z, 2) == true
        @test kp_path(z) == kpb("1a1C")
        @test to_next_k_path!(z, 2) == false
        @test kp_path(z) == kpb("1a")
        @test to_next_k_path!(z, 1) == true
        @test kp_path(z) == kpb("1b")
        @test to_next_k_path!(z, 1) == true
        @test kp_path(z) == kpb("1c")
        @test to_next_k_path!(z, 1) == false
        @test kp_path(z) == kpb("1")
        # inter-operating with descend_indexed_byte
        reset!(z)
        descend_to!(z, kpb("1"))
        @test path_exists(z)
        @test descend_first_k_path!(z, 1) == true
        @test kp_path(z) == kpb("1a")
        @test descend_indexed_byte!(z, 0) !== nothing
        @test kp_path(z) == kpb("1a1")
        @test descend_first_k_path!(z, 1) == true
        @test kp_path(z) == kpb("1a1A")
        @test to_next_k_path!(z, 1) == true
        @test kp_path(z) == kpb("1a1B")
        @test to_next_k_path!(z, 1) == true
        @test kp_path(z) == kpb("1a1C")
        @test to_next_k_path!(z, 1) == false
        @test kp_path(z) == kpb("1a1")
        @test ascend!(z, 1) == 1
        @test kp_path(z) == kpb("1a")
        @test to_next_k_path!(z, 1) == true
        @test kp_path(z) == kpb("1b")
        @test to_next_k_path!(z, 1) == true
        @test kp_path(z) == kpb("1c")
        @test to_next_k_path!(z, 1) == false
        @test kp_path(z) == kpb("1")
    end

    @testset "k_path_test4" begin
        K_PATH_TEST4_KEYS = Vector{UInt8}[
            [100, 74, 37, 218, 90, 211, 23, 84, 226, 59, 193, 236],
            [199, 102, 166, 28, 234, 168, 198, 13],
            [101, 241, 88, 163, 2, 9, 37, 110, 53, 201, 251, 164, 23, 162, 216],
            [237, 8, 108, 15, 63, 3, 249, 78, 200, 154, 103, 191],
            [106, 30, 34, 182, 157, 102, 126, 90, 200, 5, 93, 0, 163, 245, 112],
            [188, 177, 13, 5, 50, 66, 169, 113, 157, 202, 72, 11, 79, 73],
            [250, 96, 103, 31, 32, 104],
            [100, 152, 199, 46, 48, 252, 139, 150, 158, 8, 57, 50, 123],
            [65, 16, 128, 207, 27, 252, 145, 123, 105, 238, 230],
            [244, 34, 40, 224, 11, 125, 102],
            [116, 63, 105, 214, 137, 86, 202],
            [63, 70, 201, 21, 131, 60],
            [139, 209, 149, 73, 172, 12, 139, 80, 184, 105],
            [253, 235, 49, 156, 40, 50, 60, 73, 145, 249],
            [228, 81, 220, 29, 208, 234, 27],
            [116, 109, 134, 122, 15, 78, 126, 240, 158, 42, 221, 229, 93, 200, 194],
            [180, 216, 189, 14, 82, 14, 170, 195, 196, 42, 177, 144, 153, 156, 140, 109, 93, 78, 157],
            [190, 6, 59, 69, 208, 253, 2, 33, 86],
            [245, 168, 144, 122, 243, 111],
            [123, 150, 249, 114, 32, 140, 186, 204, 199, 8, 205, 150, 34, 104, 186, 236],
            [8, 29, 191, 189, 72, 101, 39, 24, 105, 44, 13, 87, 75, 187],
            [14, 201, 29, 151, 113, 10, 175],
            [83, 130, 247, 5, 250, 101, 141, 5, 42, 132, 205, 3, 118, 152, 33, 219, 1, 91, 204],
            [207, 215, 38, 17, 244, 96],
            [34, 132, 138, 222, 250, 162, 231, 68, 142, 162, 152, 172, 244, 102, 179, 111, 161, 95],
            [124, 120, 11, 4, 219, 210, 172, 50, 182, 160, 86, 88, 136, 122, 97, 98],
            [86, 74, 181, 17, 3, 173, 12],
            [18, 234, 66, 134, 20],
            [20, 24, 83, 219, 209, 20, 236, 128, 155, 15, 110, 54, 237, 105, 186, 62],
            [67, 11, 50, 124, 120, 33, 218],
            [89, 248, 169, 97, 245, 98, 230, 53, 114, 198, 227, 148, 22, 127, 198, 153, 238, 59, 223],
            [100, 128, 38, 54, 171, 186, 9, 133, 191, 82, 113, 86, 10, 72, 236, 124, 201, 65],
            [152, 115, 99, 124, 81, 254, 0, 179, 24, 87, 24, 77, 60],
            [107, 117, 222, 38, 162, 193, 48, 44, 140, 162, 104, 139, 90],
            [63, 29, 217, 85, 63, 130, 110, 121, 227, 43, 215, 223, 249, 1, 72, 134, 92, 188],
            [117, 3, 144, 15, 103, 113, 130, 253, 0, 102, 47, 24, 234, 0, 159],
            [38, 60, 197, 120, 53, 94, 202, 137, 116, 27, 12, 181],
            [248, 41, 252, 254, 98, 173, 42, 92, 30, 65, 72],
            [240, 147, 89, 110, 224, 8],
            [199, 86, 108, 195, 62, 169, 61],
            [93, 225, 21, 185, 91, 23, 19, 7, 108, 176, 191, 91],
            [70, 10, 122, 77, 171],
            [32, 161, 24, 162, 112, 152, 21, 226, 149, 253, 212, 246, 175, 182],
            [99, 7, 213, 87, 192, 2, 110, 242, 222, 89, 20, 83, 138, 112],
            [92, 64, 61, 35, 111, 41, 151, 121, 24, 157],
            [115, 201, 114, 124, 135, 246, 93, 230, 210, 164, 213, 254, 108, 181, 77, 19, 103, 166],
            [26, 231, 59, 238, 246],
            [52, 74, 93, 202, 140, 11, 56, 46, 211, 194, 137, 65, 36, 90, 209],
            [56, 245, 179, 40, 190, 168, 116, 115],
            [192, 215, 69, 171, 218, 187, 202, 120, 92, 33, 14, 77, 34, 46, 40, 93, 135, 117, 152],
        ]
        z = kp_zipper(K_PATH_TEST4_KEYS, UInt8[])
        descend_first_k_path!(z, 5)
        count = 1
        while to_next_k_path!(z, 5)
            count += 1
            count > length(K_PATH_TEST4_KEYS) && break
        end
        @test count == length(K_PATH_TEST4_KEYS)
    end

    @testset "k_path_test5 (straddles a node boundary)" begin
        keys = Vector{UInt8}[[3, 193, 4, 194, 1, 43, 3, 193, 8, 194, 1, 45, 194, 1, 46],
                             [3, 193, 4, 194, 1, 43, 3, 193, 34, 193]]
        z = kp_zipper(keys, UInt8[])
        descend_to!(z, UInt8[3, 193, 4, 194, 1, 43, 3, 193, 8, 194, 1, 45, 194])
        @test path_exists(z)
        @test descend_first_k_path!(z, 2) == true
        @test kp_path(z) == UInt8[3, 193, 4, 194, 1, 43, 3, 193, 8, 194, 1, 45, 194, 1, 46]
        @test to_next_k_path!(z, 2) == false
        @test kp_path(z) == UInt8[3, 193, 4, 194, 1, 43, 3, 193, 8, 194, 1, 45, 194]
    end

    K6 = Vector{UInt8}[
        [2, 197, 97, 120, 105, 111, 109, 3, 193, 61, 4, 193, 97, 192, 192, 3, 193, 75, 192, 3, 193, 84, 192, 3, 193, 75, 128, 131, 193, 49],
        [2, 197, 97, 120, 105, 111, 109, 3, 193, 61, 4, 193, 97, 192, 192, 3, 193, 84, 3, 193, 75, 192, 192, 3, 193, 75, 128, 131, 193, 49],
    ]

    @testset "k_path_test6 (recursive k_path with token invalidation)" begin
        function test_loop(z, descend_f, ascend_f)
            reset!(z)
            P0 = UInt8[2, 197, 97, 120, 105, 111, 109, 3, 193, 61, 4, 193, 97, 192, 192, 3, 193]
            descend_f(z, P0)                                    # L0 descent
            @test descend_first_k_path!(z, 1)
            @test kp_path(z) == vcat(P0, 75)
            P1 = UInt8[192, 3, 193, 84, 192, 3, 193]
            descend_f(z, P1)                                    # L1 descent
            @test descend_first_k_path!(z, 1)
            @test kp_path(z) == vcat(P0, 75, P1, 75)
            P2 = UInt8[128, 131, 193]
            descend_f(z, P2)                                    # L2 descent
            @test descend_first_k_path!(z, 1)
            @test kp_path(z) == K6[1]
            @test !to_next_k_path!(z, 1)                 # L2 next and ascent
            @test kp_path(z) == vcat(P0, 75, P1, 75, P2)
            ascend_f(z, 3)
            @test !to_next_k_path!(z, 1)                 # L1 next and ascent
            @test kp_path(z) == vcat(P0, 75, P1)
            ascend_f(z, 7)
            @test to_next_k_path!(z, 1)                  # L0 next
            @test kp_path(z) == vcat(P0, 84)
            ascend_f(z, 17)
        end
        z = kp_zipper(K6, UInt8[])
        # descend_to & ascend
        test_loop(z, (z, p) -> (descend_to!(z, p); @test path_exists(z)),
            (z, n) -> @test ascend!(z, n) == n)
        # descend_to_byte & ascend_byte
        test_loop(z, (z, p) -> for x in p; descend_to_byte!(z, x); @test path_exists(z); end,
            (z, n) -> for _ in 1:n; @test ascend_byte!(z); end)
        # descend_first_byte & ascend_byte
        test_loop(z, (z, p) -> for _ in p; @test descend_first_byte!(z) !== nothing; end,
            (z, n) -> for _ in 1:n; @test ascend_byte!(z); end)
    end

    @testset "k_path_test7 (descend and re-ascend one step at a time)" begin
        z = kp_zipper(K6, UInt8[])
        key = K6[1]
        for i in 0:(length(key) - 1)
            @test kp_path(z) == key[1:i]
            @test descend_first_k_path!(z, 1)
        end
        for i in (length(key) - 1):-1:0
            @test kp_path(z) == key[1:(i + 1)]
            if i != 17
                @test !to_next_k_path!(z, 1)
            else
                @test to_next_k_path!(z, 1)
                @test !to_next_k_path!(z, 1)
            end
        end
    end

    @testset "k_path_test8 (after descend_to_byte)" begin
        z = kp_zipper(["ABCDEFGHIJKLMNOPQRSTUVWXYZ", "ab"], UInt8[])
        reset!(z)
        descend_to_byte!(z, UInt8('A'))
        @test path_exists(z) == true
        @test descend_first_k_path!(z, 1) == true
        @test kp_path(z) == kpb("AB")
        @test to_next_k_path!(z, 1) == false
        @test kp_path(z) == kpb("A")
    end

    @testset "k_path_test9 (subtrie without further branches; outer trie branches)" begin
        keys = Vector{UInt8}[[2, 194, 1, 1, 193, 5], [3, 194, 1, 0, 193, 6, 193, 5], [3, 193, 4, 193]]
        z = kp_zipper(keys, UInt8[2, 194])
        reset!(z)
        @test descend_first_k_path!(z, 1) == true
        @test kp_path(z) == UInt8[1]
        @test to_next_k_path!(z, 1) == false
        @test kp_path(z) == UInt8[]
    end

    @testset "k_path_testa (a k longer than one node key)" begin
        long0 = vcat(zeros(UInt8, 127), UInt8[1])   # 128 bytes, as upstream
        long1 = vcat(zeros(UInt8, 127), UInt8[2])
        z = kp_zipper([long0, long1], UInt8[])
        reset!(z)
        k = length(long0)
        @test descend_first_k_path!(z, k) == true
        @test kp_path(z) == long0
        @test to_next_k_path!(z, k) == true
        @test kp_path(z) == long1
        @test to_next_k_path!(z, k) == false
        @test kp_path(z) == UInt8[]
    end

    # ── the P0 #1 reproducer (not upstream's): a childless focus must return false and stay put ──
    @testset "descend_first_k_path from a childless focus returns (P0 #1)" begin
        z = kp_zipper(["a", "b"], UInt8[])
        descend_to!(z, kpb("a"))
        @test descend_first_k_path!(z, 1) == false
        @test kp_path(z) == kpb("a")
        z = kp_zipper(["a"], UInt8[])
        descend_to!(z, kpb("a"))
        @test descend_first_k_path!(z, 2) == false
        @test kp_path(z) == kpb("a")
    end

    # Lean-harness program #526: keys `02` and `020000` in one node must yield the k-path `02` ONCE
    @testset "to_next_k_path never repeats the k-path it resumes from (#526)" begin
        z = kp_zipper([UInt8[0, 2, 1, 0, 3], UInt8[1], UInt8[3, 2], UInt8[3, 2, 0, 0]], UInt8[])
        walk = Vector{UInt8}[]
        descend_first_k_path!(z, 2) && push!(walk, kp_path(z))
        while to_next_k_path!(z, 2) && length(walk) < 8
            push!(walk, kp_path(z))
        end
        @test walk == [UInt8[0, 2], UInt8[3, 2]]
        @test kp_path(z) == UInt8[]
    end

    # Lean-harness program #357 (upstream bdbdfdc): a finished walk must not leave a "node finished"
    # token behind — the next to_next_val from the base still sees the values below it
    @testset "to_next_val after a finished k-path walk (bdbdfdc)" begin
        z = kp_zipper(["ab", "ac", "b"], UInt8[])
        @test descend_first_k_path!(z, 2)
        while to_next_k_path!(z, 2) end
        @test kp_path(z) == UInt8[]
        @test to_next_val!(z)
        @test kp_path(z) == kpb("ab")
    end

    # upstream 8082317: k deeper than the focus resets the zipper and returns false
    @testset "to_next_k_path with k > depth resets (upstream 8082317)" begin
        z = kp_zipper(["abc", "abd"], UInt8[])
        descend_to!(z, kpb("ab"))
        @test to_next_k_path!(z, 3) == false
        @test kp_path(z) == UInt8[]
    end
end
