# test_upstream_zipper_iter_state.jl — upstream's read-zipper iteration-state regression tests
# (~/dev-zone/PathMap src/zipper.rs:5857-6607 @ f477a91; commits f365d00, d19a7c8, 4601b5a, 48658cd, 9d8499d,
# 990c61a/ed203dc/46761a0, 85f4daa (kept by e4bd089), 15d27e8, ab2fe2f, 4470349).
#
# WRITTEN AGAINST THE 0.4.0 API (docs/ZIPPER_API_0.4.0_PORT_PLAN.md): upstream method names plus `!`, byte-returning
# descends and sibling moves, count-returning ascends. Until phase 3 lands, `Shim040` below maps those names onto
# the 0.3-shaped API; phase 3 deletes the shim and these tests then exercise the real functions unchanged.
# Test names, keys and assertions are upstream's, one testset per `#[test]`.
module UpstreamZipperIterStateTests

using Test, PathMaps
const PM = PathMaps.PathMap

# ── Shim040: 0.4.0 names over the 0.3-shaped API (DELETE in phase 3) ─────────────────────────────────────────
path(z) = collect(UInt8, zipper_path(z))
depth(z) = length(zipper_path(z))
val(z) = zipper_val(z)
is_val(z) = zipper_is_val(z)
at_root(z) = zipper_at_root(z)
path_exists(z) = zipper_path_exists(z)
reset!(z) = (zipper_reset!(z); nothing)
descend_to!(z, k) = zipper_descend_to!(z, collect(UInt8, k))
descend_to_byte!(z, b) = zipper_descend_to_byte!(z, UInt8(b))
descend_to_existing_byte!(z, b) = zipper_descend_to_existing_byte!(z, UInt8(b))
move_to_path!(z, k) = zipper_move_to_path!(z, collect(UInt8, k))
descend_until!(z) = zipper_descend_until!(z)
_moved_byte(z, moved::Bool) = moved ? last(zipper_path(z)) : nothing
descend_first_byte!(z) = _moved_byte(z, zipper_descend_first_byte!(z))
descend_last_byte!(z) = _moved_byte(z, zipper_descend_last_byte!(z))
descend_indexed_byte!(z, i) = _moved_byte(z, zipper_descend_indexed_byte!(z, i))
to_next_sibling_byte!(z) = _moved_byte(z, zipper_to_next_sibling_byte!(z))
to_prev_sibling_byte!(z) = _moved_byte(z, zipper_to_prev_sibling_byte!(z))
_ascended(z, f) = (d = depth(z); f(); d - depth(z))
ascend!(z, n) = _ascended(z, () -> zipper_ascend!(z, n))
ascend_until!(z) = _ascended(z, () -> zipper_ascend_until!(z))
ascend_until_branch!(z) = _ascended(z, () -> zipper_ascend_until_branch!(z))
ascend_byte!(z) = zipper_ascend_byte!(z)
to_next_val!(z) = zipper_to_next_val!(z)
to_next_step!(z) = zipper_to_next_step!(z)
descend_first_k_path!(z, k) = zipper_descend_first_k_path!(z, k)
to_next_k_path!(z, k) = zipper_to_next_k_path!(z, k)
fork_read_zipper(z) = zipper_fork!(z)
# ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

b(s::String) = Vector{UInt8}(s)
unit_map(keys) = (m = PM{UnitVal}(); for k in keys; set_val_at!(m, collect(UInt8, k), UNIT_VAL); end; m)
u64_map(pairs) = (m = PM{UInt64}(); for (k, v) in pairs; set_val_at!(m, collect(UInt8, k), UInt64(v)); end; m)
rz_at(m, p) = read_zipper_at_path(m, collect(UInt8, p))
create_path!(m, p) = wz_create_path!(write_zipper_at_path(m, collect(UInt8, p)))

function value_iteration_history_test_map()
    m = PM{UInt64}()
    wz_set_val!(write_zipper(m), UInt64(0))
    set_val_at!(m, UInt8[0, 0], UInt64(7))
    set_val_at!(m, UInt8[1], UInt64(9))
    m
end
function multi_node_value_iteration_history_test_map()
    prefix = fill(UInt8(3), PathMaps.KEY_BYTES_CNT)
    (u64_map([vcat(prefix, 0x00) => 24, vcat(prefix, 0x01) => 25]), prefix)
end
k_path_history_test_map() = u64_map([UInt8[0, 0] => 1, UInt8[0, 1] => 1, UInt8[1, 0] => 1, UInt8[1, 1] => 1])
nested_k_path_history_test_map() =
    u64_map([UInt8[0, 0, 0] => 1, UInt8[0, 1, 0] => 1, UInt8[1, 0, 0] => 1, UInt8[1, 1, 0] => 1])

# Mirrors the default `ZipperIteration::to_next_val_observed` (zipper.rs:5896-5920).
function to_next_val_default(z)
    while true
        if descend_first_byte!(z) !== nothing
            is_val(z) && return true
            descend_until!(z) && is_val(z) && return true
        else
            while true
                if to_next_sibling_byte!(z) !== nothing
                    is_val(z) && return true
                    break
                end
                ascend_byte!(z)
                at_root(z) && return false
            end
        end
    end
end

@testset "upstream read-zipper iteration state (zipper.rs:5926-6607)" begin

@testset "read_zipper_to_next_val_after_descend_first_byte_matches_descend_to" begin
    m = value_iteration_history_test_map()
    a = read_zipper(m); @test descend_first_byte!(a) == 0x00
    d = read_zipper(m); descend_to!(d, [0x00])
    @test path(a) == path(d); @test to_next_val!(d)
    @test to_next_val!(a); @test path(a) == path(d); @test val(a) == val(d)
    em = u64_map([UInt8[0] => 10, UInt8[1] => 11])
    a = read_zipper(em); @test descend_first_byte!(a) == 0x00
    d = read_zipper(em); descend_to!(d, [0x00])
    @test path(a) == path(d); @test to_next_val!(d)
    @test to_next_val!(a); @test path(a) == path(d); @test val(a) == val(d)
end

@testset "read_zipper_to_next_val_after_each_ascent_matches_direct_position_in_multi_node_map" begin
    m, prefix = multi_node_value_iteration_history_test_map()
    ascents = [("ascend", z -> @test(ascend!(z, 1) == 1)), ("ascend_byte", z -> @test(ascend_byte!(z))),
        ("ascend_until", z -> @test(ascend_until!(z) == 1)),
        ("ascend_until_branch", z -> @test(ascend_until_branch!(z) == 1))]
    for (label, up) in ascents
        z = read_zipper(m)
        @test to_next_val!(z); @test to_next_val!(z)
        up(z)
        @test path(z) == prefix
        d = read_zipper(m); descend_to!(d, prefix)
        @test to_next_val!(d)
        @test to_next_val!(z)
        @test path(z) == path(d)
        @test val(z) == val(d)
    end
end

@testset "read_zipper_to_next_sibling_from_partial_focus_matches_direct_focus" begin
    m = u64_map([b("abc") => 10, b("wxyz") => 11])
    z = read_zipper(m); descend_to!(z, b("a"))
    @test to_next_sibling_byte!(z) == UInt8('w'); @test path(z) == b("w")
    @test to_next_sibling_byte!(z) === nothing; @test path(z) == b("w")
    d = read_zipper(m); descend_to!(d, b("w")); @test to_next_val!(d)
    @test to_next_val!(z); @test path(z) == path(d); @test val(z) == val(d)
end

@testset "read_zipper_to_next_k_path_after_descend_first_k_path_matches_descend_to" begin
    m = k_path_history_test_map()
    a = read_zipper(m); @test descend_first_k_path!(a, 2)
    d = read_zipper(m); descend_to!(d, path(a))
    @test path(a) == path(d); @test to_next_k_path!(d, 2)
    @test to_next_k_path!(a, 2); @test path(a) == path(d)
end

@testset "read_zipper_to_next_k_path_after_k_path_descent_and_ascent_matches_unmoved_focus" begin
    m = nested_k_path_history_test_map()
    a = read_zipper(m); @test descend_first_k_path!(a, 2)
    @test descend_first_byte!(a) == 0x00; @test ascend_byte!(a)
    u = read_zipper(m); @test descend_first_k_path!(u, 2)
    @test path(a) == path(u); @test to_next_k_path!(u, 2)
    @test to_next_k_path!(a, 2); @test path(a) == path(u)
end

@testset "read_zipper_to_next_k_path_after_prior_k_path_step_matches_unmoved_focus" begin
    m = k_path_history_test_map()
    a = read_zipper(m); @test descend_first_k_path!(a, 2); @test to_next_k_path!(a, 2)
    @test to_prev_sibling_byte!(a) == 0x00
    u = read_zipper(m); @test descend_first_k_path!(u, 2)
    @test path(a) == path(u); @test to_next_k_path!(u, 2)
    @test to_next_k_path!(a, 2); @test path(a) == path(u)
end

@testset "read_zipper_to_next_k_path_after_nested_k_path_step_matches_unmoved_focus" begin
    m = nested_k_path_history_test_map()
    a = read_zipper(m); @test descend_first_k_path!(a, 2); @test descend_first_k_path!(a, 1)
    @test !to_next_k_path!(a, 1)
    u = read_zipper(m); @test descend_first_k_path!(u, 2)
    @test path(a) == path(u); @test to_next_k_path!(u, 2)
    @test to_next_k_path!(a, 2); @test path(a) == path(u)
end

@testset "read_zipper_descend_first_byte_after_failed_descend_first_k_path" begin
    z = read_zipper(unit_map([b("ab")]))
    @test !descend_first_k_path!(z, 3); @test path(z) == UInt8[]
    @test descend_first_byte!(z) == UInt8('a')
end

@testset "read_zipper_to_next_step_after_exhausted_to_next_k_path" begin
    z = read_zipper(unit_map([UInt8[0, 0, 0, 1, 0, 2, 2, 2, 1, 2, 1, 0, 3]]))
    @test to_next_val!(z)
    @test !to_next_k_path!(z, 5); @test path(z) == UInt8[0, 0, 0, 1, 0, 2, 2, 2]
    @test to_next_step!(z); @test path(z) == UInt8[0, 0, 0, 1, 0, 2, 2, 2, 1]
end

@testset "read_zipper_descend_first_byte_after_exhausted_k_path_and_ascent" begin
    z = read_zipper(unit_map([b("ab"), b("wxyz")]))
    descend_to!(z, b("w"))
    @test descend_first_k_path!(z, 1); @test path(z) == b("wx")
    @test !to_next_k_path!(z, 1); @test path(z) == b("w")
    @test ascend_byte!(z); @test path(z) == UInt8[]
    @test descend_first_byte!(z) == UInt8('a')
end

@testset "read_zipper_reset_at_root_clears_iteration_token" begin
    z = read_zipper(unit_map([UInt8[24]]))
    @test to_next_step!(z); reset!(z)
    @test descend_first_byte!(z) == 0x18; reset!(z)
    @test to_next_step!(z)
end

@testset "read_zipper_to_next_k_path_after_path_movement" begin
    cases = [
        ("descend_to across a node boundary", :descend_to,
            [UInt8[0, 0, 1, 1], UInt8[0, 1, 0, 1, 0, 0], UInt8[0, 1, 1, 0, 0, 0, 1, 0]], 2, UInt8[0]),
        ("move_to_path", :move_to_path, [UInt8[3, 2, 2], UInt8[3, 2, 3, 1, 2, 3, 0], UInt8[3, 2, 3, 3]], 4, UInt8[]),
        ("descend_to followed by descend_until", :descend_to_then_until,
            [UInt8[0, 0, 0, 0, 1, 0, 1], UInt8[0, 1, 1, 1]], 4, UInt8[]),
    ]
    for (name, movement, paths, k, expected) in cases
        z = read_zipper(unit_map(paths))
        if movement === :descend_to
            descend_to!(z, UInt8[0, 1, 1])
        elseif movement === :move_to_path
            move_to_path!(z, UInt8[3, 2, 3, 3])
        else
            descend_to!(z, UInt8[0, 1])
            @test descend_until!(z)
            @test path(z) == UInt8[0, 1, 1, 1]
        end
        @test !to_next_k_path!(z, k)
        @test path(z) == expected
    end
end

@testset "read_zipper_to_next_k_path_does_not_repeat_prefix_value" begin
    z = read_zipper(unit_map([b("a"), b("abcd")]))
    @test descend_first_k_path!(z, 1); @test path(z) == b("a")
    @test !to_next_k_path!(z, 1)
end

@testset "read_zipper_to_next_val_after_exhausted_k_path" begin
    z = read_zipper(unit_map([b("ab"), b("wxyz")]))
    @test descend_first_k_path!(z, 1); @test to_next_k_path!(z, 1); @test !to_next_k_path!(z, 1)
    @test at_root(z); @test to_next_val!(z); @test path(z) == b("ab")
    z = read_zipper(unit_map([UInt8[1, 2, 1, 0, 0, 0, 2, 1, 1, 1, 2, 3, 1, 2], UInt8[2, 2, 1, 2, 3, 2, 3],
        UInt8[3, 3, 3, 2, 3, 0, 0, 3]]))
    @test descend_indexed_byte!(z, 1) == 0x02
    @test descend_to_existing_byte!(z, 2)
    @test !to_next_k_path!(z, 1); @test path(z) == UInt8[2]
    @test to_next_val!(z); @test path(z) == UInt8[2, 2, 1, 2, 3, 2, 3]
end

@testset "read_zipper_k_path_edge_cases" begin
    m = unit_map([b("b"), b("bb"), b("bc"), b("bc" * "c"^58), b("cb")])
    for (missing, expected, d) in [(b("bd"), b("b"), 1), (UInt8[], UInt8[], 100), (b("bbb"), b("bb"), 1),
        (b("aa"), b("a"), 1), (b("bbbbb"), b("bbbb"), 1), (b("d"), UInt8[], 1), (b("cbb"), UInt8[], 3),
        (b("ba"), UInt8[], 3), (b("b" * "c"^57), UInt8[], 70)]
        z = read_zipper(m)
        descend_to!(z, missing)
        @test !descend_first_k_path!(z, d)
        @test path(z) == missing
        @test !to_next_k_path!(z, d)
        @test path(z) == expected
    end
end

@testset "read_zipper_descend_first_byte_then_ascend_from_missing_path" begin
    for (name, paths, missing, expected) in [("before the first key", [b("b"), b("c")], b("a"), UInt8('b')),
        ("after the last key", [b("ab"), b("wxyz")], b("z"), UInt8('a'))]
        z = read_zipper(unit_map(paths))
        descend_to!(z, missing)
        @test !path_exists(z)
        @test descend_first_byte!(z) === nothing
        @test ascend_byte!(z)
        @test descend_first_byte!(z) == expected
    end
end

@testset "read_zipper_ascend_until_branch_from_missing_path_below_zipper_root" begin
    m = unit_map([UInt8[1, 12, 4, 5, 4], UInt8[13, 9, 5, 15, 5, 0, 11, 14, 13, 3, 12, 0, 4], UInt8[15, 3, 14, 15, 0, 8, 7]])
    z = rz_at(m, UInt8[1, 12, 4, 5, 4])
    descend_to!(z, UInt8[12, 12]); descend_to!(z, UInt8[173, 37, 23])
    @test descend_first_byte!(z) === nothing
    @test ascend_until_branch!(z) == 5
    @test at_root(z)
end

@testset "read_zipper_to_next_step_after_missing_path" begin
    z = rz_at(unit_map([UInt8[0], UInt8[7], UInt8[14, 5]]), UInt8[14, 5])
    descend_to_byte!(z, 11); descend_to_byte!(z, 13)
    @test descend_first_byte!(z) === nothing
    @test ascend_byte!(z)
    @test !to_next_step!(z)
end

@testset "read_zipper_to_next_val_does_not_escape_zipper_root_after_missing_path" begin
    z = rz_at(unit_map([UInt8[7, 167, 36, 166, 110]]), UInt8[7, 167, 36, 166, 110])
    descend_to!(z, UInt8[45, 47, 220])
    @test descend_first_byte!(z) === nothing
    @test ascend!(z, 1) == 1
    @test !to_next_val!(z)
end

@testset "read_zipper_to_next_sibling_after_missing_path_below_leaf" begin
    z = read_zipper(unit_map([UInt8[10], UInt8[20], UInt8[30]]))
    descend_to!(z, UInt8[10, 99])
    @test descend_first_byte!(z) === nothing
    @test ascend_byte!(z); @test path(z) == UInt8[10]
    @test to_next_sibling_byte!(z) == 0x14
end

@testset "read_zipper_ascend_multiple_bytes_from_missing_path" begin
    z = read_zipper(unit_map([UInt8[24], UInt8[49, 69], UInt8[54], UInt8[73, 209, 145, 207], UInt8[124]]))
    move_to_path!(z, UInt8[133, 52, 64, 90])
    @test to_next_sibling_byte!(z) === nothing
    @test ascend!(z, 2) == 2
    @test path(z) == UInt8[133, 52]
end

@testset "read_zipper_missing_dense_path_uses_lower_bound_for_iteration" begin
    m = unit_map([b("a"), b("b"), b("z")])
    s = read_zipper(m); move_to_path!(s, b("m"))
    @test !path_exists(s)
    @test to_next_sibling_byte!(s) == UInt8('z'); @test path(s) == b("z")
    v = read_zipper(m); move_to_path!(v, b("mm"))
    @test !path_exists(v)
    @test to_next_sibling_byte!(v) === nothing
    @test to_next_val!(v); @test path(v) == b("z")
end

@testset "read_zipper_sibling_moves_do_not_escape_zipper_root" begin
    z = rz_at(unit_map([UInt8[4], UInt8[5]]), UInt8[4])
    @test to_next_sibling_byte!(z) === nothing
    z = rz_at(unit_map([UInt8[14], UInt8[15]]), UInt8[15])
    @test to_prev_sibling_byte!(z) === nothing
end

@testset "read_zipper_to_prev_sibling_at_first_dense_child" begin
    z = read_zipper(unit_map([UInt8[0, 0, 2], UInt8[0, 1], UInt8[1], UInt8[1, 2], UInt8[2], UInt8[2, 0, 1],
        UInt8[2, 2, 1], UInt8[2, 2, 2]]))
    @test descend_first_k_path!(z, 1)
    @test to_prev_sibling_byte!(z) === nothing
end

@testset "read_zipper_native_and_default_value_iteration_can_be_interleaved" begin
    m = u64_map([UInt8[0, 0] => 10, UInt8[0, 1] => 11, UInt8[1] => 12, UInt8[2, 0] => 13, UInt8[2, 1] => 14])
    walk(step) = (z = read_zipper(m); out = Tuple{Vector{UInt8}, UInt64}[];
        i = 0; while step(z, i); push!(out, (path(z), val(z))); i += 1; end; out)
    native = walk((z, i) -> to_next_val!(z))
    default = walk((z, i) -> to_next_val_default(z))
    mixed = walk((z, i) -> iseven(i) ? to_next_val!(z) : to_next_val_default(z))
    @test length(native) == 5
    @test default == native
    @test mixed == native
end

@testset "read_zipper_to_next_val_after_every_movement" begin
    m = value_iteration_history_test_map()
    ways = [
        ("descend_to([0])", z -> descend_to!(z, UInt8[0])),
        ("descend_to_byte(0)", z -> descend_to_byte!(z, 0)),
        ("descend_indexed_byte(0)", z -> descend_indexed_byte!(z, 0)),
        ("descend_to_existing_byte(0)", z -> descend_to_existing_byte!(z, 0)),
        ("move_to_path([0])", z -> move_to_path!(z, UInt8[0])),
        ("descend_first_byte()", z -> descend_first_byte!(z)),
        ("to_next_step()", z -> to_next_step!(z)),
        ("descend_first_k_path(1)", z -> descend_first_k_path!(z, 1)),
        ("descend_last_byte(), to_prev_sibling_byte()", z -> (descend_last_byte!(z); to_prev_sibling_byte!(z))),
    ]
    for (label, f) in ways
        @testset "$label" begin
            z = read_zipper(m)
            f(z)
            @test path(z) == UInt8[0]
            @test to_next_val!(z); @test path(z) == UInt8[0, 0]; @test val(z) == 7
            @test to_next_val!(z); @test path(z) == UInt8[1]
            @test !to_next_val!(z)
        end
    end
    z = read_zipper(u64_map([UInt8[1, 1, 1] => 72]))
    @test to_next_val!(z); @test !to_next_val!(z)
    reset!(z)
    @test to_next_val!(z); @test val(z) == 72
    two = u64_map([UInt8[3] => 24, UInt8[3, 3] => 25])
    ups = [("ascend", z -> ascend!(z, 7)), ("ascend_byte", z -> (ascend_byte!(z); ascend_byte!(z))),
        ("ascend_until", z -> (ascend_until!(z); ascend_until!(z))), ("ascend_until_branch", z -> ascend_until_branch!(z))]
    for (label, up) in ups
        @testset "$label" begin
            z = read_zipper(two)
            @test to_next_val!(z); @test to_next_val!(z); @test path(z) == UInt8[3, 3]
            up(z)
            @test at_root(z)
            @test to_next_val!(z); @test val(z) == 24
        end
    end
    z = read_zipper(k_path_history_test_map())
    @test descend_first_k_path!(z, 2)
    seen = [path(z)]
    while to_next_k_path!(z, 2); push!(seen, path(z)); length(seen) > 8 && break; end
    @test seen == [UInt8[0, 0], UInt8[0, 1], UInt8[1, 0], UInt8[1, 1]]
end

@testset "read_zipper_fork_root_to_next_step_terminates" begin
    m = u64_map([UInt8[0, 0, 2, 3, 0] => 1]); create_path!(m, UInt8[0, 3])
    rz = rz_at(m, UInt8[0, 3])
    f = fork_read_zipper(rz); @test !ascend_byte!(f)
    f = fork_read_zipper(rz); @test !to_next_step!(f)
end

@testset "read_zipper_empty_node_below_dangling_path_ascend" begin
    m = u64_map([UInt8[0, 0, 2] => 1]); create_path!(m, UInt8[0, 3])
    z = rz_at(m, UInt8[0, 3])
    descend_to!(z, UInt8[1])
    @test descend_first_byte!(z) === nothing
    @test ascend_byte!(z)
    @test at_root(z)
end

@testset "read_zipper_missing_focus_between_key0_and_descendant_key1" begin
    m = unit_map([b("a"), b("abcd")])
    z = read_zipper(m); descend_to!(z, b("aa"))
    @test to_next_sibling_byte!(z) == UInt8('b'); @test path(z) == b("ab")
    z = read_zipper(m); descend_to!(z, b("aaa"))
    @test to_next_sibling_byte!(z) === nothing; @test path(z) == b("aaa")
    z = read_zipper(m); descend_to!(z, b("aa"))
    @test to_next_k_path!(z, 1); @test path(z) == b("ab")
    z = read_zipper(m); descend_to!(z, b("aaa"))
    @test !to_next_k_path!(z, 1); @test path(z) == b("aa")
end

@testset "read_zipper_k_path_base_mismatch_exit" begin
    m = unit_map([UInt8[0, 0, 0, 0, 0, 0, 1], UInt8[2]])
    z = read_zipper(m)
    @test to_next_val!(z); @test !to_next_k_path!(z, 2); @test path(z) == UInt8[0, 0, 0, 0, 0]
    @test descend_first_byte!(z) == 0x00
    z = read_zipper(m)
    @test to_next_val!(z); @test !to_next_k_path!(z, 2)
    @test to_next_val!(z); @test path(z) == UInt8[0, 0, 0, 0, 0, 0, 1]
end

@testset "read_zipper_rooted_to_next_val_exhaustion" begin
    m = unit_map([UInt8[1, 2, 3], UInt8[1, 5]])
    z = rz_at(m, UInt8[1, 2])
    @test to_next_val!(z); @test !to_next_val!(z); @test at_root(z)
    @test descend_first_byte!(z) == 0x03
    z = rz_at(m, UInt8[1, 2])
    @test to_next_val!(z); @test !to_next_val!(z)
    @test to_next_step!(z); @test path(z) == UInt8[3]
end

@testset "read_zipper_prev_sibling_cases" begin
    m = unit_map([UInt8[10], UInt8[20], UInt8[70]])
    z = read_zipper(m); descend_to!(z, UInt8[70]); @test to_prev_sibling_byte!(z) == 0x14
    z = read_zipper(m); descend_to!(z, UInt8[60]); @test to_prev_sibling_byte!(z) == 0x14
    z = read_zipper(unit_map([UInt8[10, 1], UInt8[200, 1]])); descend_to!(z, UInt8[100])
    @test to_prev_sibling_byte!(z) == 0x0a
end

end # testset

end # module
