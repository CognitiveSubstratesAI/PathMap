# test_upstream_iter_token.jl — upstream's node iteration-token contract tests, 0.4.0
# (~/dev-zone/PathMap @ f477a91: dense_byte_node.rs:2419 `byte_node_iter_token_crosses_mask_word_boundaries`;
# line_list_node.rs:3107-3329 `test_line_list_node_key_and_value_collision`, `test_line_list_ascend_iter_token`,
# `test_line_list_next_items_after_focus_skips_partial_item`, `…_skips_descendant_item`,
# `test_line_list_next_items_uses_canonical_tokens`). docs/ZIPPER_API_0.4.0_PORT_PLAN.md phase 1.
#
# FIDELITY. Values and assertions are upstream's. Upstream builds the duplicate-key node (value and child at
# the same one-byte path) with `unsafe set_child_1`; ours sets `key1`/`slot1` directly. Upstream's
# `validate_node` has no Julia port and is not asserted. Upstream's debug-build panics are `error`s here.
module UpstreamIterTokenTests

using Test, PathMaps
using PathMaps: LineListNode, DenseByteNode, TrieNodeODRc, ValOrChild, GlobalAlloc, node_set_val!,
    node_get_val, node_get_child, new_iter_token, iter_token_for_path, ascend_iter_token, next_items,
    node_iter_token_is_nonexistent, NODE_TOKEN_NONEXISTENT_BIT, TOKEN_LAST, TOKEN_AFTER_LAST,
    NODE_ITER_INVALID, NODE_ITER_FINISHED, _rc_inner

const GA = GlobalAlloc()
b(s::String) = Vector{UInt8}(s)
ll() = LineListNode{UInt64, GlobalAlloc}(GA)
function ll_with(pairs...)
    n = ll()
    for (k, v) in pairs
        node_set_val!(n, b(k), UInt64(v))
    end
    n
end
# value at "a" in slot 0 and a child at "a" in slot 1 (upstream: `unsafe set_child_1`)
function duplicate_node(child; v = 0)
    n = ll_with("a" => v)
    n.key1 = b("a")
    n.slot1 = ValOrChild(TrieNodeODRc(child, GA))
    n
end
function walk(node, token)
    seen = UInt8[]
    while token != NODE_ITER_FINISHED
        token, path, _, value = next_items(node, token, false)
        if token != NODE_ITER_FINISHED
            @test length(path) == 1
            @test value == UInt64(path[1])
            push!(seen, path[1])
        end
    end
    seen
end

@testset "upstream iteration-token contract (0.4.0)" begin

@testset "byte_node_iter_token_crosses_mask_word_boundaries" begin
    node = DenseByteNode{UInt64, GlobalAlloc}(GA)
    for byte in UInt8[0, 63, 64, 127, 128, 191, 192, 255]
        node_set_val!(node, UInt8[byte], UInt64(byte))
    end
    @test walk(node, new_iter_token(node)) == UInt8[0, 63, 64, 127, 128, 191, 192, 255]
    @test iter_token_for_path(node, UInt8[]) == new_iter_token(node)
    @test !node_iter_token_is_nonexistent(iter_token_for_path(node, UInt8[127]))
    @test iter_token_for_path(node, UInt8[127, 0]) == iter_token_for_path(node, UInt8[127]) | NODE_TOKEN_NONEXISTENT_BIT
    @test walk(node, iter_token_for_path(node, UInt8[127])) == UInt8[128, 191, 192, 255]
    t65 = iter_token_for_path(node, UInt8[65])
    @test node_iter_token_is_nonexistent(t65)
    @test walk(node, t65) == UInt8[127, 128, 191, 192, 255]
    for exhausted in (TOKEN_LAST, TOKEN_AFTER_LAST), after_focus in (false, true)
        token, path, child, value = next_items(node, exhausted, after_focus)
        @test token == NODE_ITER_FINISHED
        @test isempty(path) && child === nothing && value === nothing
    end
end

@testset "test_line_list_node_key_and_value_collision" begin
    child = ll_with("hello" => 24)
    n = duplicate_node(child; v = 42)
    @test node_get_val(n, b("a")) == 42
    used, crc = node_get_child(n, b("a"))
    @test used == 1
    @test node_get_val(_rc_inner(crc), b("hello")) == 24
end

@testset "test_line_list_ascend_iter_token" begin
    node = ll_with("abc" => 0, "wxyz" => 1)
    p0 = iter_token_for_path(node, b("ab")); c0 = iter_token_for_path(node, b("abc"))
    @test p0 == 2 && c0 == 3
    @test ascend_iter_token(node, p0, 1) == 1
    @test ascend_iter_token(node, c0, 1) == p0
    @test ascend_iter_token(node, c0, 3) == 0
    p1 = iter_token_for_path(node, b("wxy")); c1 = iter_token_for_path(node, b("wxyz"))
    @test p1 == 6 && c1 == TOKEN_LAST
    @test ascend_iter_token(node, p1, 1) == 5
    @test ascend_iter_token(node, c1, 1) == p1
    @test ascend_iter_token(node, c1, 4) == 0
    @test next_items(node, c1, false)[1] == NODE_ITER_FINISHED
    @test iter_token_for_path(node, b("`")) == NODE_TOKEN_NONEXISTENT_BIT
    @test iter_token_for_path(node, b("abcd")) == 3 | NODE_TOKEN_NONEXISTENT_BIT
    @test iter_token_for_path(node, b("m")) == 3 | NODE_TOKEN_NONEXISTENT_BIT
    @test iter_token_for_path(node, b("zz")) == TOKEN_AFTER_LAST
    @test !node_iter_token_is_nonexistent(TOKEN_LAST)
    @test node_iter_token_is_nonexistent(TOKEN_AFTER_LAST)
    @test_throws ErrorException ascend_iter_token(node, UInt64(0), 0)
    @test_throws ErrorException ascend_iter_token(node, UInt64(0), 1)
    @test_throws ErrorException ascend_iter_token(node, p0, 3)
    @test_throws ErrorException ascend_iter_token(node, NODE_ITER_INVALID, 1)
    @test_throws ErrorException ascend_iter_token(node, NODE_ITER_FINISHED, 1)

    dup = duplicate_node(ll())
    dc = iter_token_for_path(dup, b("a"))
    @test dc == TOKEN_LAST
    @test ascend_iter_token(dup, dc, 1) == 0
    @test next_items(dup, dc, false)[1] == NODE_ITER_FINISHED

    single = ll_with("abc" => 0)
    sc = iter_token_for_path(single, b("abc"))
    @test sc == TOKEN_LAST
    @test iter_token_for_path(single, b("abcd")) == TOKEN_AFTER_LAST
    @test ascend_iter_token(single, sc, 1) == 2
    snext, skey, _, sval = next_items(single, UInt64(0), false)
    @test snext == TOKEN_LAST && skey == b("abc") && sval == 0
    @test next_items(single, sc, false)[1] == NODE_ITER_FINISHED

    anc = ll_with("a" => 0, "ab" => 1)
    @test ascend_iter_token(anc, iter_token_for_path(anc, b("ab")), 1) == iter_token_for_path(anc, b("a"))
end

@testset "test_line_list_next_items_after_focus_skips_partial_item" begin
    node = ll_with("abc" => 0, "wxyz" => 1)
    p0 = iter_token_for_path(node, b("ab"))
    next_token, key, _, value = next_items(node, p0, false)
    @test key == b("abc") && value == 0
    naf, key, _, value = next_items(node, p0, true)
    @test key == b("wxyz") && value == 1 && naf == TOKEN_LAST
    @test next_items(node, next_token, true) == next_items(node, next_token, false)
    for (missing, expected) in [(b("`"), (b("abc"), 0)), (b("abcd"), (b("wxyz"), 1)), (b("m"), (b("wxyz"), 1)),
        (b("zz"), nothing)]
        token = iter_token_for_path(node, missing)
        @test node_iter_token_is_nonexistent(token)
        for after_focus in (false, true)
            nxt, key, child, value = next_items(node, token, after_focus)
            @test child === nothing
            if expected !== nothing
                @test key == expected[1] && value == expected[2]
                @test nxt == iter_token_for_path(node, expected[1])
            else
                @test nxt == NODE_ITER_FINISHED && isempty(key) && value === nothing
            end
        end
    end
end

@testset "test_line_list_next_items_after_focus_skips_descendant_item" begin
    node = ll_with("a" => 0, "abcd" => 1)
    focus = iter_token_for_path(node, b("a"))
    nxt, key, child, value = next_items(node, focus, true)
    @test nxt == NODE_ITER_FINISHED && isempty(key) && child === nothing && value === nothing
    _, key, child, value = next_items(node, focus, false)
    @test key == b("abcd") && child === nothing && value == 1
end

@testset "test_line_list_next_items_uses_canonical_tokens" begin
    node = ll_with("a" => 0, "z" => 1)
    token, key, child, value = next_items(node, new_iter_token(node), false)
    @test token == 1 && key == b("a") && child === nothing && value == 0
    token, key, child, value = next_items(node, token, false)
    @test token == TOKEN_LAST && key == b("z") && child === nothing && value == 1
    token, key, child, value = next_items(node, token, false)
    @test token == NODE_ITER_FINISHED && isempty(key) && child === nothing && value === nothing

    dup = duplicate_node(ll())
    token, key, child, value = next_items(dup, new_iter_token(dup), false)
    @test token == TOKEN_LAST && key == b("a") && child !== nothing && value == 0
    @test iter_token_for_path(dup, key) == token
    for exhausted in (TOKEN_LAST, TOKEN_AFTER_LAST), after_focus in (false, true)
        token, key, child, value = next_items(node, exhausted, after_focus)
        @test token == NODE_ITER_FINISHED && isempty(key) && child === nothing && value === nothing
    end
end

@testset "bit_siblings_test (utils/mod.rs, e659a96)" begin
    x = UInt64(0b0000000000000000000000000000000000000100001001100000000000000010)
    i = UInt64(1) << 18
    p = UInt64(1) << 21
    nn = UInt64(1) << 17
    f = UInt64(1) << 26
    l = UInt64(1) << 1
    mask = PathMaps.ByteMask((x, UInt64(0), UInt64(0), UInt64(0)))
    bit_i = UInt8(trailing_zeros(i))
    @test i & x != 0
    @test PathMaps.prev_bit(mask, bit_i) == UInt8(trailing_zeros(nn))
    @test PathMaps.next_bit(mask, bit_i) == UInt8(trailing_zeros(p))
    @test PathMaps.prev_bit(mask, UInt8(trailing_zeros(l))) === nothing
    @test PathMaps.next_bit(mask, UInt8(trailing_zeros(f))) === nothing
    m = PathMaps.ByteMask((UInt64(0), UInt64(0), UInt64(0), UInt64(0)))
    for byte in UInt8[10, 20, 70, 130, 200]
        m = PathMaps.ByteMask(PathMaps.with_bit_set(m.bits, byte))
    end
    @test PathMaps.prev_bit(m, UInt8(64)) == 20
    @test PathMaps.next_bit(m, UInt8(63)) == 70
    @test PathMaps.prev_bit(m, UInt8(130)) == 70
    @test PathMaps.next_bit(m, UInt8(70)) == 130
    @test PathMaps.prev_bit(m, UInt8(200)) == 130
    @test PathMaps.next_bit(m, UInt8(130)) == 200
end

end # testset

end # module
