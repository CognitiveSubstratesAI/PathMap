# test_prune_call_sites.jl — pins WHICH prune helper each call site uses.
#
# Upstream has two prune entry points and deliberately uses DIFFERENT ONES at different sites:
#
#     prune_path_internal(false)   the ancestor walk, run unconditionally
#     prune_path()                 node_remove_dangling(node_key) FIRST, then the ancestor walk
#                                  ONLY if that returned > 0        (write_zipper.rs:2179-2190)
#
#     remove_val        -> prune_path_internal(false)   write_zipper.rs:1415
#     join_k_path_into  -> prune_path()                 write_zipper.rs:1773
#
# We had BOTH BACKWARDS, in opposite directions, and each was invisible to a different gate:
#
#   * `wz_remove_val!` used the public one. Its `node_pruned > 0` gate NEVER OPENS here, because
#     `node_remove_val!(focus_node, nk, prune)` has already taken the payload whole — so we never
#     pruned ancestors at all and a `parent -> empty-child` link upstream deletes survived. The fuzz
#     corpus can express this shape but never generated it: it needs two pruning REMOVEVALs emptying
#     one shared node plus a repositioning op, which is deep for `n_ops <= 6` at REMOVEVAL's weight.
#   * `wz_join_k_path_into!` used the internal one, skipping the node-level dangling removal. The
#     corpus could not reach it at all — `join_k_path_into` is not one of the 12 generated ops. That
#     one is pinned in runtests.jl via `path_exists_at`, since a dangling path is invisible to the
#     dump.
#
# The two scripts below were MEASURED against the upstream release binary
# (`gen_fuzz --exec`, 52fd9df, default features); the expected strings are its exact output.
using PathMap, Test

include(joinpath(@__DIR__, "differential", "run_fuzz.jl"))

@testset "prune call sites use the same helper upstream uses" begin

    # Both scripts build {aa, ab, ba}, then empty the node under "a" with two pruning REMOVEVALs.
    # Upstream's unconditional ancestor walk removes the now-empty "a" link; ours used not to.
    prefix = "A aa ab ba\nAROOTVAL 0\n"

    @testset "remove_val(prune) prunes ancestors — visible through TAKEMAP" begin
        # `wz_take_map!` calls `wz_remove_val!(z, prune)`, so TAKEMAP inherited the defect.
        # The tell is None vs an EMPTY MAP: upstream finds nothing at "a", we found a husk.
        out = fuzz_run_text(prefix * "S \nSROOTVAL 0\nORIGIN -\n" *
                            "OP DESCEND aa\nOP REMOVEVAL 1\nOP ASCEND 1\n" *
                            "OP DESCEND b\nOP REMOVEVAL 1\nOP ASCEND 1\nOP TAKEMAP 0\n")
        @test out == "-;true;true;-;true;true;None;|[ba] vc=1"
        @test occursin(";None;", out)          # NOT ";[] vc=0;" — an empty map is the bug
    end

    @testset "remove_val(prune) prunes ancestors — visible in an algebra op's status" begin
        # Same cause with no TAKEMAP: the surviving empty child made SUB report Element where
        # upstream reports None. A status-only divergence, and still a real one.
        out = fuzz_run_text(prefix * "S ba\nSROOTVAL 0\nORIGIN -\n" *
                            "OP DESCEND aa\nOP REMOVEVAL 1\nOP ASCEND 1\n" *
                            "OP DESCEND b\nOP REMOVEVAL 1\nOP RESET\nOP SUB 0\n")
        @test out == "-;true;true;-;true;-;None;|[] vc=0"
        @test !occursin(";Element;", out)
    end
end
