# test_join_preserves_source.jl — a join NEVER writes into its source operand.
#
# 🔄 THIS FILE USED TO ASSERT THE OPPOSITE, and the reversal is the point.
#
# It was `test_join_consumes_source.jl` (commit `8fe6319`), pinning "`wz_join_map_into!` CONSUMES its
# source" as a DOCUMENTED CONTRACT, on the reasoning that upstream's signature
# `pub fn join_map_into(&mut self, map: PathMap<V, A>)` (write_zipper.rs:1680) takes the map BY
# VALUE, so Rust callers cannot observe what the join does to it and upstream is free to mutate.
# It even carried a discriminator — "an UNSHARED source is mutated identically, so this is a
# contract issue and not a copy-on-write gap".
#
# The discriminator was sound. The conclusion was wrong. By-value means upstream MAY mutate the map;
# it does not mean upstream DOES, and it does not: `LineListNode::join_into_dyn` clones the byte-node
# operand and merges into the clone (line_list_node.rs:2515-2532), and `ByteNode::join_into_dyn`
# `make_mut()`s before its `mem::swap` (dense_byte_node.rs:1306-1334). Across the 3000-case fuzz
# corpus upstream emits the source-changed marker on ZERO cases.
#
# Ours emitted it because `LineListNode::join_into_dyn!` merged into its RIGHT-HAND OPERAND —
# `merge_from_list_node!(as_tagged(other), self)` — a write into a node the caller still owns. Both
# halves of the old behaviour, shared source and unshared source, were that one write. Fixing it
# removed both, so "consumed" was never a contract; it was the defect's own footprint being read as
# a specification. Fuzz case `00324` was its only corpus witness (ratchet 31 → 30).
#
# WHAT THIS FILE PINS NOW: for every consuming op, the source survives — in BOTH handover modes.
#   DIRECT : the op is handed the source map itself
#   CLONE  : the op is handed a refcount-sharing clone, the only mode in which a missing
#            copy-on-write becomes visible to a third party (this is what the fuzz harness does)
using PathMap, Test

_b(s) = Vector{UInt8}(codeunits(s))

function _mk(keys::Vector{String})
    m = PathMap.PathMap{PathMap.UnitVal}()
    for k in keys
        PathMap.set_val_at!(m, _b(k), PathMap.UnitVal())
    end
    m
end

_paths(m) = begin
    z = PathMap.read_zipper(m)
    v = String[]
    while PathMap.zipper_to_next_val!(z)
        push!(v, String(copy(PathMap.zipper_path(z))))
    end
    sort(v)
end

# The refcount-sharing handover: `copy(root)` bumps the node refcount exactly as `s.clone()` does
# upstream. NOT `deepcopy` — a deep copy shares nothing and so could not witness the defect.
_share(m) = PathMap.PathMap{PathMap.UnitVal, PathMap.GlobalAlloc}(
    m.root === nothing ? nothing : copy(m.root), m.root_val, m.alloc)

_anr(s) =
    if s.root === nothing
        PathMap.ANRNone{PathMap.UnitVal, PathMap.GlobalAlloc}()
    else
        PathMap.ANRBorrowedRc{PathMap.UnitVal, PathMap.GlobalAlloc}(s.root)
    end

@testset "a join never writes into its source operand" begin

    # The exact shape reduced from fuzz 00324, and the shape 00324 itself runs.
    A_MIN = ["ab:", "b", "b:a"]
    S_MIN = ["a:a", "aa", "ab"]
    A_324 = ["aab", "ab:", "b", "b::b", "b:a"]

    @testset "the target is still correct — the fix changes only whose node gets written" begin
        a = _mk(A_MIN)
        PathMap.wz_join_map_into!(PathMap.write_zipper(a), _mk(S_MIN))
        @test _paths(a) == ["a:a", "aa", "ab", "ab:", "b", "b:a"]
        @test PathMap.val_count(a) == 6
    end

    @testset "wz_join_map_into! — source survives, handed DIRECTLY" begin
        a = _mk(A_MIN)
        s = _mk(S_MIN)
        PathMap.wz_join_map_into!(PathMap.write_zipper(a), s)
        @test _paths(s) == S_MIN            # `s` used to gain "ab:" here
        @test PathMap.val_count(s) == 3
    end

    @testset "wz_join_map_into! — source survives THROUGH A SHARING CLONE" begin
        # The third-party case: `shared` is never passed to the op at all. Only a clone sharing its
        # nodes is. A write that skipped copy-on-write reaches `shared` through those nodes.
        shared = _mk(S_MIN)
        PathMap.wz_join_map_into!(PathMap.write_zipper(_mk(A_MIN)), _share(shared))
        @test _paths(shared) == S_MIN
        @test PathMap.val_count(shared) == 3
    end

    @testset "fuzz 00324 verbatim: RESET · ASCEND 4 · RESET · JOINMAP" begin
        shared = _mk(S_MIN)
        a = _mk(A_324)
        wz = PathMap.write_zipper(a)
        PathMap.wz_reset!(wz)
        PathMap.wz_ascend!(wz, 4)
        PathMap.wz_reset!(wz)
        PathMap.wz_join_map_into!(wz, _share(shared))
        @test _paths(shared) == S_MIN       # used to become [a:a, aa, aab, ab, ab:]
        @test PathMap.val_count(shared) == 3
        @test PathMap.val_count(a) == 8     # and the join itself is unaffected
    end

    @testset "wz_join_into! — the read-zipper form had the SAME hole, via the same node path" begin
        # Not a bonus check: `wz_join_into!` reaches `pjoin_dyn` identically, so it corrupted the
        # source identically (measured at 6/1200 on the same random sweep as the map form). It has
        # no by-value signature upstream to hide behind, which on its own refutes the reading that a
        # consumed source was faithful to a by-value parameter.
        shared = _mk(S_MIN)
        PathMap.wz_join_into!(PathMap.write_zipper(_mk(A_MIN)), _anr(_share(shared)))
        @test _paths(shared) == S_MIN
    end

    @testset "the sibling consuming ops, same two handover modes" begin
        # MEASURED clean before AND after the fix (0/1200 each on the random sweep) — kept so that a
        # future operand write in meet/subtract/restrict/graft fails HERE rather than in the corpus.
        for (name, op) in (
            ("graft_map", (wz, s) -> PathMap.wz_graft_map!(wz, s)),
            ("meet_into", (wz, s) -> PathMap.wz_meet_into!(wz, _anr(s), false, s.root_val)),
            (
                "meet_into prune",
                (wz, s) -> PathMap.wz_meet_into!(wz, _anr(s), true, s.root_val)
            ),
            (
                "subtract_into",
                (wz, s) -> PathMap.wz_subtract_into!(wz, _anr(s), false, s.root_val)
            ),
            ("subtract_into prune",
                (wz, s) -> PathMap.wz_subtract_into!(wz, _anr(s), true, s.root_val)),
            ("restrict", (wz, s) -> PathMap.wz_restrict!(wz, _anr(s)))
        )
            @testset "$name" begin
                direct = _mk(S_MIN)
                op(PathMap.write_zipper(_mk(A_324)), direct)
                @test _paths(direct) == S_MIN

                shared = _mk(S_MIN)
                op(PathMap.write_zipper(_mk(A_324)), _share(shared))
                @test _paths(shared) == S_MIN
            end
        end
    end

    @testset "repeated joins from one source — the source is reusable, not single-shot" begin
        # The old contract said a passed source was gone. If that were still true the second join
        # would read a source already polluted by the first, and `b` would not equal `a`.
        s = _mk(S_MIN)
        a = _mk(A_MIN)
        b = _mk(A_MIN)
        PathMap.wz_join_map_into!(PathMap.write_zipper(a), s)
        PathMap.wz_join_map_into!(PathMap.write_zipper(b), s)
        @test _paths(a) == _paths(b)
        @test _paths(s) == S_MIN
    end
end
