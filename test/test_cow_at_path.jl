# test_cow_at_path.jl — writes through a zipper built at a PATH must not corrupt a map that shares
# nodes with the target.
#
# THE DEFECT THIS PINS (regression `6d3fd84`, fixed 2026-08-01). Upstream builds an at-path write
# zipper with `node_along_path_mut` (trie_node.rs:2461), which calls `make_mut()` on EVERY node it
# steps through — copy-on-write at CONSTRUCTION time, before the zipper exists. It uses that same
# mutating walker from both `mend_root` (write_zipper.rs:2452) and `new_with_node_and_path_in`
# (:1141). We called the READ-ONLY twin at both sites; the mutating twin was never ported.
#
# `_wz_ensure_write_unique!` cannot compensate: it starts at `focus_stack[1]` and walks DOWNWARD,
# and mending records the origin in the integer `root_key_start`, so nothing above the stack root
# survives to be walked. A shared ancestor absorbed by the mend was therefore never uniquified.
#
#     s = {"x:1","x:2","x:3"};  graft s into t at "g:";  write to t via
#     write_zipper_at_path(t, "g:x:1")   ->  S LOSES THE VALUE TOO
#
# 🔴 IT WAS A REGRESSION, NOT AN ANCIENT GAP, and the trade is worth remembering. Before `6d3fd84`
# ("MEND the root at construction, do not DESCEND — 75 -> 33 divergences") `write_zipper_at_path`
# DESCENDED, which built the full ancestor stack, so `_wz_ensure_write_unique!`'s `for k in 2:n`
# loop covered the chain BY ACCIDENT. Mending removed that accidental coverage. The 42 fuzz
# divergences that commit closed and the corruption it opened were the same change. Reverting to
# descend is not the fix — adding the `make_mut` upstream always had is.
#
# WHY NOTHING CAUGHT IT FOR TWO DAYS:
#   * the 3000-case differential only ever dumps the TARGET map; it never checks that a SOURCE
#     survived, and its `s` map is discarded after each case;
#   * the suite's COW tests all use `write_zipper` + `wz_descend_to!`, the shape that is safe;
#   * MORK's 2959 tests and the full PathMap suite were green throughout.
#
# ⚠️ USE DISTINGUISHABLE VALUES. An earlier probe of mine reported `write_zipper_at_path` +
# `wz_set_val!` as SAFE because it overwrote an existing `UnitVal` with another `UnitVal` — an
# unobservable write. Same class of mistake as an equivalent mutant. Every case below either uses
# `Int` payloads or changes `val_count`.
using PathMap, Test

_b(s) = Vector{UInt8}(codeunits(s))

"Build `s`, graft it into a fresh `t` under \"g:\", and hand back both. `t` now SHARES s's nodes."
function _shared_pair()
    s = PathMap.PathMap{Int}()
    PathMap.set_val_at!(s, _b("x:1"), 1)
    PathMap.set_val_at!(s, _b("x:2"), 2)
    PathMap.set_val_at!(s, _b("x:3"), 3)
    t = PathMap.PathMap{Int}()
    z = PathMap.write_zipper(t)
    PathMap.wz_descend_to!(z, _b("g:"))
    PathMap.wz_graft_map!(z, s)
    (s, t)
end

_snapshot(m) = (PathMap.val_count(m),
    PathMap.get_val_at(m, _b("x:1")),
    PathMap.get_val_at(m, _b("x:2")),
    PathMap.get_val_at(m, _b("x:3")))

@testset "writes through write_zipper_at_path do not corrupt a sharing map" begin

    @testset "remove_val_at! — the shape that surfaced it" begin
        (s, t) = _shared_pair()
        before = _snapshot(s)
        PathMap.remove_val_at!(t, _b("g:x:1"), false)
        @test PathMap.get_val_at(t, _b("g:x:1")) === nothing   # the target really changed
        @test _snapshot(s) == before                            # and the source did not
    end

    @testset "wz_set_val! OVERWRITING an existing value" begin
        # Int payloads, so overwriting is observable. With UnitVal it is not, and this case reads
        # as passing on the broken code.
        (s, t) = _shared_pair()
        before = _snapshot(s)
        z = PathMap.write_zipper_at_path(t, _b("g:x:1"))
        PathMap.wz_set_val!(z, 999)
        @test PathMap.get_val_at(t, _b("g:x:1")) == 999
        @test _snapshot(s) == before
    end

    @testset "wz_set_val! creating a NEW sibling" begin
        (s, t) = _shared_pair()
        before = _snapshot(s)
        z = PathMap.write_zipper_at_path(t, _b("g:x:4"))
        PathMap.wz_set_val!(z, 444)
        @test PathMap.get_val_at(t, _b("g:x:4")) == 444
        @test _snapshot(s) == before
        @test PathMap.get_val_at(s, _b("x:4")) === nothing
    end

    @testset "wz_remove_val! with prune" begin
        (s, t) = _shared_pair()
        before = _snapshot(s)
        z = PathMap.write_zipper_at_path(t, _b("g:x:1"))
        PathMap.wz_remove_val!(z, true)
        @test PathMap.get_val_at(t, _b("g:x:1")) === nothing
        @test _snapshot(s) == before
    end

    @testset "wz_take_map! removes the subtrie from the target only" begin
        (s, t) = _shared_pair()
        before = _snapshot(s)
        z = PathMap.write_zipper_at_path(t, _b("g:x:1"))
        PathMap.wz_take_map!(z, false)
        @test _snapshot(s) == before
    end

    @testset "wz_graft_map! over a shared position" begin
        (s, t) = _shared_pair()
        before = _snapshot(s)
        other = PathMap.PathMap{Int}()
        PathMap.set_val_at!(other, _b("q"), 7)
        z = PathMap.write_zipper_at_path(t, _b("g:x:1"))
        PathMap.wz_graft_map!(z, other)
        @test PathMap.get_val_at(t, _b("g:x:1q")) == 7
        @test _snapshot(s) == before
    end

    @testset "the MORK read/write isolation shape (Space.jl:1749)" begin
        # MORK builds `read_btm = PathMap(copy(s.btm.root), …)` purely for read/write isolation —
        # added after a DTL bug where a single-conjunct rule wrote 976 facts from 56 matches.
        # `copy(root)` bumps the refcount to 2, which is exactly the configuration this defect
        # ignored, so that isolation was void for every write through an at-path zipper.
        btm = PathMap.PathMap{Int}()
        PathMap.set_val_at!(btm, _b("a:1"), 1)
        PathMap.set_val_at!(btm, _b("a:2"), 2)
        PathMap.set_val_at!(btm, _b("b:1"), 3)
        read_btm = PathMap.PathMap{Int, PathMap.GlobalAlloc}(
            copy(btm.root), btm.root_val, btm.alloc
        )
        before = PathMap.val_count(read_btm)

        PathMap.remove_val_at!(btm, _b("a:1"), false)
        @test PathMap.get_val_at(btm, _b("a:1")) === nothing
        @test PathMap.get_val_at(read_btm, _b("a:1")) == 1
        @test PathMap.val_count(read_btm) == before
    end
end
