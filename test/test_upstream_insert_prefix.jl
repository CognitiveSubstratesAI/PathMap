# test_upstream_insert_prefix.jl — upstream f0cd6b7's tests ("Fixes for a number of issues adjacent to
# https://github.com/Adam-Vandervorst/PathMap/issues/79"), ported: write_zipper.rs
# `write_zipper_insert_prefix_{mid_key_replaces_old_downstream_path,keeps_focus_value,empty_is_identity,
# randomized}`, `write_zipper_graft_over_single_line`, and line_list_node.rs
# `test_line_list_set_branch_replaces_compressed_value_descendant`.
#
# WHY. A graft (and `insert_prefix`, which grafts) at a focus inside a compressed key run kept the OLD
# run beside the new one — duplicate values (delta P1 #5; Lean-harness program #686).
#
# FIDELITY. Keys, foci and expectations are upstream's. `assert_valid_nodes` walks every node with our
# child iterator and checks `validate_list_node`. The randomized test keeps upstream's generator SHAPE
# and case count with Julia's RNG (upstream's StdRng stream is not reproducible here), so it asserts
# the same property on a different sample.
using Test, PathMaps, Random
const PMI = PathMaps.PathMap

ip_keys(m) = sort([collect(UInt8, k) for (k, _) in m])
ipb(s::String) = Vector{UInt8}(s)

function ip_assert_valid_nodes(m)
    function walk(rc)
        (rc === nothing || PathMaps.is_empty_node(rc)) && return true
        n = rc.node
        ok = n isa PathMaps.LineListNode ? PathMaps.validate_list_node(n) : true
        tok, child = PathMaps.node_child_iter_start(n)
        while child !== nothing
            ok &= walk(child)
            tok, child = PathMaps.node_child_iter_next(n, tok)
        end
        ok
    end
    walk(m.root)
end

function ip_rewrite_ok(keys, focus, prefix)
    keys = unique(sort(keys))
    m = PMI{UnitVal}()
    for k in keys
        set_val_at!(m, k, UNIT_VAL)
    end
    expected = sort([(length(k) > length(focus) && k[1:length(focus)] == focus) ?
                     vcat(focus, prefix, k[(length(focus) + 1):end]) : k for k in keys])
    wz = write_zipper(m)
    descend_to!(wz, focus)
    insert_prefix!(wz, prefix)
    ip_keys(m) == expected && ip_assert_valid_nodes(m)
end

@testset "upstream f0cd6b7 — graft / insert_prefix replace the old key run" begin
    @testset "write_zipper_insert_prefix_mid_key_replaces_old_downstream_path" begin
        m = PMI{UnitVal}()
        set_val_at!(m, ipb("aaa"), UNIT_VAL)
        wz = write_zipper(m)
        descend_to!(wz, ipb("a"))
        @test insert_prefix!(wz, ipb("b"))
        @test ip_keys(m) == [ipb("abaa")]
        @test get_val_at(m, ipb("aaa")) === nothing
        rz = read_zipper(m); descend_to!(rz, ipb("aa"))
        @test !path_exists(rz)                     # stale key run must be gone
        @test ip_assert_valid_nodes(m)

        m = PMI{UnitVal}()
        set_val_at!(m, ipb("abcd"), UNIT_VAL)
        set_val_at!(m, ipb("abce"), UNIT_VAL)
        wz = write_zipper(m)
        descend_to!(wz, ipb("ab"))
        @test insert_prefix!(wz, ipb("X"))
        @test ip_keys(m) == [ipb("abXcd"), ipb("abXce")]
        @test ip_assert_valid_nodes(m)
    end

    @testset "write_zipper_insert_prefix_keeps_focus_value" begin
        m = PMI{UnitVal}()
        for k in ("a", "ab", "ac"); set_val_at!(m, ipb(k), UNIT_VAL); end
        wz = write_zipper(m)
        descend_to!(wz, ipb("a"))
        @test insert_prefix!(wz, ipb("Z"))
        @test ip_keys(m) == [ipb("a"), ipb("aZb"), ipb("aZc")]
        @test ip_assert_valid_nodes(m)
    end

    @testset "write_zipper_insert_prefix_empty_is_identity" begin
        m = PMI{UInt64}()
        set_val_at!(m, ipb("ab"), UInt64(1))
        set_val_at!(m, ipb("ac"), UInt64(2))
        @test insert_prefix!(write_zipper(m), UInt8[])
        @test ip_keys(m) == [ipb("ab"), ipb("ac")]
        wz = write_zipper(m)
        descend_to!(wz, ipb("a"))
        @test insert_prefix!(wz, UInt8[])
        @test get_val_at(m, ipb("ab")) == 1
        @test get_val_at(m, ipb("ac")) == 2
        @test ip_assert_valid_nodes(m)
    end

    @testset "write_zipper_graft_over_single_line" begin
        for src_key in (UInt8[0, 3], UInt8[0, 0])
            dst = PMI{UInt64}()
            set_val_at!(dst, UInt8[0, 0], UInt64(1))
            src = PMI{UInt64}()
            set_val_at!(src, src_key, UInt64(8))
            wz = write_zipper_at_path(dst, UInt8[0])
            t = trie_ref_at_path(src, UInt8[0])            # the source read zipper's focus
            graft!(wz, get_focus(t), get_val(t))
            @test ip_keys(dst) == [UInt8[0, src_key[2]]]
            @test get_val_at(dst, UInt8[0, src_key[2]]) == 8
            @test ip_assert_valid_nodes(dst)
        end
    end

    @testset "write_zipper_insert_prefix_randomized (2000 cases)" begin
        rng = Xoshiro(42)
        bad = 0
        for _ in 1:2000
            alphabet = rand(rng, 2:3)
            keys = [UInt8[UInt8('a') + rand(rng, 0:(alphabet - 1)) for _ in 1:rand(rng, 0:5)] for _ in 1:rand(rng, 1:6)]
            keys = unique(sort(keys))
            key = keys[rand(rng, eachindex(keys))]
            focus = key[1:rand(rng, 0:length(key))]
            prefix = UInt8[UInt8('a') + rand(rng, 0:(alphabet - 1)) for _ in 1:rand(rng, 1:3)]
            ip_rewrite_ok(keys, focus, prefix) || (bad += 1)
        end
        @test bad == 0
    end

    @testset "test_line_list_set_branch_replaces_compressed_value_descendant" begin
        node = PathMaps.LineListNode{Int, PathMaps.GlobalAlloc}(PathMaps.global_alloc())
        PathMaps.node_set_val!(node, ipb("aaa"), 1)
        repl = PathMaps.LineListNode{Int, PathMaps.GlobalAlloc}(PathMaps.global_alloc())
        PathMaps.node_set_val!(repl, ipb("b"), 2)
        repl_rc = PathMaps.TrieNodeODRc(repl, PathMaps.global_alloc())
        r = PathMaps.node_set_branch!(node, ipb("a"), repl_rc)
        @test !(r isa PathMaps.TrieNodeODRc)               # no upgrade needed
        @test PathMaps.node_get_val(node, ipb("aaa")) === nothing   # the replaced subtree must not leak its old value
        used, child = PathMaps.node_get_child(node, ipb("a"))
        @test used == 1
        @test PathMaps.node_get_val(PathMaps.as_tagged(child), ipb("b")) == 2
        @test PathMaps.validate_list_node(node)
    end
end
