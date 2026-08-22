# test_graft_child_maps.jl — WriteZipperCore::graft_child_maps + meet_2 + split_at_focus
# (ported 2026-07-31).
#
# The graft_child_maps expectations are upstream's OWN test, `write_zipper_graft_child_maps_test1`
# (write_zipper.rs:5110-5206), transcribed scenario for scenario including its four code paths:
# map_count >2 / <=2 crossed with remove_unset true / false. Values are Int here as they are i32
# there — the documented UnitVal restriction applies to lattice ALGEBRA (Ring.jl), and
# graft_child_maps performs none.
using PathMap, Test

const P = PathMap

_m(pairs...) = (
    m=P.PathMap{Int}();
    for (k, v) in pairs
        P.set_val_at!(m, Vector{UInt8}(k), v)
    end;
    m
)
_mask(bytes...) = foldl((a, b) -> P.ByteMask(a.bits .| P.ByteMask(UInt8(b)).bits), bytes;
    init=P.ByteMask())

@testset "graft_child_maps / meet_2 / split_at_focus" begin
    @testset "upstream test1 — remove_unset=true replaces 'a','c' and removes 'b','d'" begin
        m = _m("root:a:x" => 1, "root:a:y" => 2, "root:b:x" => 3, "root:b:y" => 4,
            "root:c:x" => 5, "root:c:y" => 6, "root:d:x" => 7)
        wz = P.write_zipper_at_path(m, Vector{UInt8}("root:"))
        P.wz_graft_child_maps!(
            wz, _mask('a', 'c'), [_m(":new_a" => 10), _m(":new_c" => 30)], true
        )

        @test P.get_val_at(m, Vector{UInt8}("root:a:new_a")) == 10
        @test P.get_val_at(m, Vector{UInt8}("root:c:new_c")) == 30
        for gone in ("root:a:x", "root:a:y", "root:b:x", "root:b:y", "root:d:x")
            @test P.get_val_at(m, Vector{UInt8}(gone)) === nothing
        end
    end

    @testset "upstream test2 — remove_unset=false keeps 'a','c' and replaces only 'b'" begin
        m = _m("root:a:old" => 100, "root:b:old" => 200, "root:c:old" => 300)
        wz = P.write_zipper_at_path(m, Vector{UInt8}("root:"))
        P.wz_graft_child_maps!(wz, _mask('b'), [_m(":new_b" => 222)], false)

        @test P.get_val_at(m, Vector{UInt8}("root:a:old")) == 100
        @test P.get_val_at(m, Vector{UInt8}("root:b:old")) === nothing
        @test P.get_val_at(m, Vector{UInt8}("root:b:new_b")) == 222
        @test P.get_val_at(m, Vector{UInt8}("root:c:old")) == 300
    end

    @testset "upstream test3 — three maps at the root takes the DenseByteNode fast path" begin
        m = P.PathMap{Int}()
        wz = P.write_zipper(m)
        P.wz_graft_child_maps!(wz, _mask('x', 'y', 'z'),
            [_m(":data" => 111), _m(":info" => 222), _m(":stuff" => 333)], true)

        @test P.get_val_at(m, Vector{UInt8}("x:data")) == 111
        @test P.get_val_at(m, Vector{UInt8}("y:info")) == 222
        @test P.get_val_at(m, Vector{UInt8}("z:stuff")) == 333
        @test P.val_count(m) == 3
    end

    @testset "upstream test4 — an EMPTY mask with remove_unset=true clears everything" begin
        m = _m("root:a" => 1, "root:b" => 2)
        wz = P.write_zipper_at_path(m, Vector{UInt8}("root:"))
        P.wz_graft_child_maps!(wz, P.ByteMask(), P.PathMap{Int}[], true)

        @test P.get_val_at(m, Vector{UInt8}("root:a")) === nothing
        @test P.get_val_at(m, Vector{UInt8}("root:b")) === nothing
    end

    _anr(m) =
        if m.root === nothing
            P.ANRNone{Int, P.GlobalAlloc}()
        else
            P.ANRBorrowedRc{Int, P.GlobalAlloc}(m.root)
        end
    _paths(m) = (z=P.read_zipper(m); v=String[];
        while P.zipper_to_next_val!(z)
            push!(v, String(copy(P.zipper_path(z))))
        end; sort!(v))

    @testset "meet_2 — meets TWO sources into the focus, ignoring what is there" begin
        a = _m("x" => 1, "y" => 1)
        b = _m("y" => 1, "z" => 1)

        # the destination's existing content is OVERWRITTEN, never consulted — that is the whole
        # difference from wz_meet_into!, and why upstream notes meet_2 cannot return Identity
        dst = _m("zzz" => 9)
        st = P.wz_meet_2!(P.write_zipper(dst), _anr(a), _anr(b))
        @test _paths(dst) == ["y"]
        @test st === P.ALG_STATUS_ELEMENT

        # a disjoint meet empties the destination
        dst2 = _m("zzz" => 9)
        @test P.wz_meet_2!(P.write_zipper(dst2), _anr(_m("p" => 1)), _anr(_m("q" => 1))) ===
            P.ALG_STATUS_NONE
        @test isempty(_paths(dst2))

        # either source absent -> None, destination cleared
        dst3 = _m("zzz" => 9)
        @test P.wz_meet_2!(P.write_zipper(dst3), _anr(P.PathMap{Int}()), _anr(a)) ===
            P.ALG_STATUS_NONE
        @test isempty(_paths(dst3))

        # identical sources: A ∩ A = A, reported as Element (NOT Identity — see above)
        dst4 = P.PathMap{Int}()
        @test P.wz_meet_2!(P.write_zipper(dst4), _anr(a), _anr(a)) === P.ALG_STATUS_ELEMENT
        @test _paths(dst4) == ["x", "y"]
    end

    @testset "split_at_focus — gives the focus a node of its own" begin
        # a single key makes a LineListNode whose slot key is the WHOLE path, so a focus partway
        # along it has no node; splitting must create one without changing any value
        m = _m("abcd" => 1)
        wz = P.write_zipper_at_path(m, Vector{UInt8}("ab"))
        P._wz_split_at_focus!(wz)
        @test _paths(m) == ["abcd"]           # content untouched
        @test P.get_val_at(m, Vector{UInt8}("abcd")) == 1

        # splitting where there is genuinely nothing leaves an empty node, not a value
        m2 = _m("abcd" => 1)
        wz2 = P.write_zipper_at_path(m2, Vector{UInt8}("zz"))
        P._wz_split_at_focus!(wz2)
        @test _paths(m2) == ["abcd"]
    end

    @testset "set_val_at_child_path / set_node_at_child_path — one byte below the focus" begin
        m = _m("root:a" => 1)
        wz = P.write_zipper_at_path(m, Vector{UInt8}("root:"))
        old = P._wz_set_val_at_child_path!(wz, UInt8[UInt8('b')], 5)
        @test old === nothing
        @test P.get_val_at(m, Vector{UInt8}("root:b")) == 5
        @test P.get_val_at(m, Vector{UInt8}("root:a")) == 1      # focus restored, sibling intact
        # setting again returns the previous value
        @test P._wz_set_val_at_child_path!(wz, UInt8[UInt8('b')], 6) == 5

        src = _m(":deep" => 42)
        P._wz_set_node_at_child_path!(wz, UInt8[UInt8('c')], src.root)
        @test P.get_val_at(m, Vector{UInt8}("root:c:deep")) == 42
        @test P.get_val_at(m, Vector{UInt8}("root:a")) == 1
    end

    @testset "graft_masked_branches — upstream's own three cases" begin
        # write_zipper.rs:5340-5429, transcribed. src has masked `a` and `c` but NO `b`, plus an
        # unmasked `e`.
        function _src()
            _m("root:" => 700, "root:a:new_a" => 10, "root:a:nested:deep" => 11,
                "root:c:new_c" => 30, "root:e:unmasked" => 50)
        end
        mask = _mask('a', 'b', 'c')
        # the source's focus as an AbstractNodeRef — the zipper's own accessor, since a hand-rolled
        # node_along_path walk returns ANRNone whenever the path ends inside a multi-byte slot key
        _at(m, path) = P._wz_get_focus_anr(P.write_zipper_at_path(m, Vector{UInt8}(path)))

        # Case 1: remove_unset=false — replaces masked, removes masked-but-missing `b`,
        # PRESERVES unmasked siblings d/z, and does NOT copy src's unmasked `e`.
        dst1 = _m("root:" => 900, "root:a:old_a" => 1, "root:b:old_b" => 2,
            "root:c:old_c" => 3,
            "root:d:old_d" => 4, "root:z:old_z" => 26)
        wz1 = P.write_zipper_at_path(dst1, Vector{UInt8}("root:"))
        P.wz_graft_masked_branches!(wz1, _at(_src(), "root:"), mask, false)
        @test P.wz_get_val(wz1) == 900                       # focus value untouched
        g(m, k) = P.get_val_at(m, Vector{UInt8}(k))
        @test g(dst1, "root:") == 900
        @test g(dst1, "root:a:old_a") === nothing
        @test g(dst1, "root:a:new_a") == 10
        @test g(dst1, "root:a:nested:deep") == 11
        @test g(dst1, "root:b:old_b") === nothing            # masked, missing in src -> removed
        @test g(dst1, "root:c:old_c") === nothing
        @test g(dst1, "root:c:new_c") == 30
        @test g(dst1, "root:d:old_d") == 4                   # unmasked sibling preserved
        @test g(dst1, "root:z:old_z") == 26
        @test g(dst1, "root:e:unmasked") === nothing         # src's unmasked NOT copied

        # Case 2: remove_unset=true — same, plus unmasked destination siblings removed
        dst2 = _m("root:" => 901, "root:a:old_a" => 101, "root:b:old_b" => 102,
            "root:c:old_c" => 103, "root:d:old_d" => 104, "root:z:old_z" => 126)
        wz2 = P.write_zipper_at_path(dst2, Vector{UInt8}("root:"))
        P.wz_graft_masked_branches!(wz2, _at(_src(), "root:"), mask, true)
        @test P.wz_get_val(wz2) == 901
        @test g(dst2, "root:") == 901
        @test g(dst2, "root:a:new_a") == 10
        @test g(dst2, "root:a:nested:deep") == 11
        @test g(dst2, "root:c:new_c") == 30
        for gone in
            ("root:a:old_a", "root:b:old_b", "root:c:old_c", "root:d:old_d", "root:z:old_z")
            @test g(dst2, gone) === nothing
        end
        @test P.val_count(dst2) == 4

        # Case 3: a masked byte missing from BOTH sides must not leave a dangling branch
        dst3 = _m("root:" => 902)
        wz3 = P.write_zipper_at_path(dst3, Vector{UInt8}("root:"))
        P.wz_graft_masked_branches!(wz3, _at(_src(), "root:"), mask, false)
        @test P.wz_get_val(wz3) == 902
        @test sort(collect(P.iter(P.wz_child_mask(wz3)))) == UInt8[UInt8('a'), UInt8('c')]
        @test g(dst3, "root:") == 902
        @test g(dst3, "root:a:new_a") == 10
        @test g(dst3, "root:a:nested:deep") == 11
        @test g(dst3, "root:b") === nothing
        @test g(dst3, "root:c:new_c") == 30
        @test P.val_count(dst3) == 4
    end

    @testset "meet_k_path_into — upstream's own test1" begin
        # write_zipper.rs:4040-4059 verbatim. k=4 selects the "abc:"/"def:" subtries below "123:";
        # their intersection is {Bob, Sue}.
        m = P.PathMap{Int}()
        for k in ("123:abc:Bob", "123:abc:Jim", "123:abc:Pam", "123:abc:Sue",
            "123:def:Nan", "123:def:Mel", "123:def:Bob", "123:def:Sue")
            P.set_val_at!(m, Vector{UInt8}(k), 1)
        end
        wz = P.write_zipper_at_path(m, Vector{UInt8}("123:"))
        @test P.wz_meet_k_path_into!(wz, 4, true)
        @test P.val_count(m) == 2
        @test P.get_val_at(m, Vector{UInt8}("123:Bob")) == 1
        @test P.get_val_at(m, Vector{UInt8}("123:Sue")) == 1

        # a disjoint intersection empties the focus and reports false
        m2 = P.PathMap{Int}()
        for k in ("123:abc:Bob", "123:def:Nan")
            P.set_val_at!(m2, Vector{UInt8}(k), 1)
        end
        wz2 = P.write_zipper_at_path(m2, Vector{UInt8}("123:"))
        @test !P.wz_meet_k_path_into!(wz2, 4, true)
        @test P.val_count(m2) == 0
    end

    @testset "descend_first_k_path / to_next_k_path on the write zipper" begin
        m = P.PathMap{Int}()
        for k in ("ab", "ac", "bd")
            P.set_val_at!(m, Vector{UInt8}(k), 1)
        end
        z = P.write_zipper(m)
        seen = String[]
        if P.wz_descend_first_k_path!(z, 2)
            push!(seen, String(copy(P.wz_path(z))))
            while P.wz_to_next_k_path!(z, 2)
                push!(seen, String(copy(P.wz_path(z))))
            end
        end
        @test sort(seen) == ["ab", "ac", "bd"]
        # exhausted -> back at the common root
        @test isempty(P.wz_path(z))
        # a path shorter than k has no common root k steps up
        @test !P.wz_to_next_k_path!(P.write_zipper(m), 5)
    end
end
