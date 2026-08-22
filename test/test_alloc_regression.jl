# test/test_alloc_regression.jl
#
# AllocCheck read-path allocation regression guard. `check_allocs` STATICALLY analyzes the compiled
# IR for a (function, arg-types) pair — it is deterministic and independent of trie contents — so
# these are stable regression bounds, not flaky runtime measurements. Locks the optimized read path:
# the residual allocs (get_val_at / path_exists_at = 8) are the `node_get_child_nb` Tuple boxing +
# `Int64` Union returns, eliminable only by the ADR-001 isbits node slab (deferred) — we assert they
# do NOT grow. `zipper_path == 0` is a genuine zero-alloc invariant the coref de-box (MORK 1d7599b:
# S1 `_coref_path_length`, S5 `@view`) builds on. AllocCheck is NOT a PathMap dependency — it is
# loaded OPTIONALLY from the developer's global environment (no hardcoded UUID in Project.toml); the
# guard runs in a dev `julia --project=.` run and skips cleanly where AllocCheck is absent. (A Julia /
# AllocCheck version bump may shift these static counts and require re-baselining — that is the guard
# doing its job, not a spurious failure.)
const _HAS_ALLOCCHECK = try
    @eval using AllocCheck
    true
catch
    false
end

if _HAS_ALLOCCHECK
    @testset "AllocCheck read-path residual (regression guard)" begin
        m = PathMaps.PathMap{Int32}()
        for i in 1:64
            PathMaps.set_val_at!(
                m,
                vcat(Vector{UInt8}("k" * lpad(string(i), 3, '0') * ":"), UInt8[i % 251]),
                Int32(i)
            )
        end
        rz = PathMaps.read_zipper(m)
        nallocs(f, ts) = length(AllocCheck.check_allocs(f, ts; ignore_throw=true))

        # zero-alloc INVARIANT — the coref de-box S1 (_coref_path_length) + S5 (@view) rely on this
        @test nallocs(PathMaps.zipper_path, (typeof(rz),)) == 0

        # read-path residual — must not GROW beyond the measured optimized floor (ADR-001-gated:
        # node_get_child_nb Tuple boxing + Int64 Union returns → zero only under the isbits node slab)
        @test nallocs(PathMaps.get_val_at, (typeof(m), Vector{UInt8})) <= 8
        # path_exists_at: floor moved 8 -> 11 on 2026-07-27, DELIBERATELY. The old floor was
        # measured on an implementation that answered WRONG for mid-edge prefixes (it reported
        # "a"/"abcd"/"abcdefghi" as absent in {abc, abcdefghij}, disagreeing with our own
        # zipper and with upstream trie_map.rs:328). The correctness fix adds a
        # `node_contains_partial_key` call, costing 3 more alloc SITES. A correct answer at 11
        # beats a wrong one at 8. Still a ratchet — pinned at the new measured floor, not
        # loosened to a round number. Reducing it again is a real optimisation opportunity
        # (the residual is node-type dynamic dispatch, same class as the ADR-001 note above).
        @test nallocs(PathMaps.path_exists_at, (typeof(m), Vector{UInt8})) <= 11

        # cheap read-cursor primitives — locked at their measured floors
        @test nallocs(PathMaps.zipper_child_mask, (typeof(rz),)) <= 4
        @test nallocs(PathMaps.zipper_ascend_byte!, (typeof(rz),)) <= 3
        @test nallocs(PathMaps.zipper_val, (typeof(rz),)) <= 4

        # write path: type-cascade de-box via call-site assertions (2026-07-06) took set_val_at!
        # dynamic dispatch 30 → 20 (descend `node_get_child`) → 17 (`clone_self` ×2 + the `node_set_val!`
        # closure) and insert 5662 → ~2650 ns/key (−53%). Lock the floor so a future write-path
        # type-instability regression is caught. (Full elimination of the remaining 17 needs the
        # ADR-001 isbits node slab — the `.node` field is abstract; the rest are node mutations.)
        # RE-BASELINED 17 -> 21 (2026-08-01) for a CORRECTNESS fix, on the same principle as the
        # `path_exists_at` 8 -> 11 note above: a correct answer at 21 beats a wrong one at 17.
        #
        # `_wz_mend_root!` now walks the origin chain with `node_along_path_mut!`, which
        # copy-on-writes each node instead of only reading it. Without it, every write through a
        # zipper built by `write_zipper_at_path` corrupted any map SHARING those nodes — 17 op
        # shapes, `remove_val_at!` among them. Regression from `6d3fd84`; see the header on
        # `node_along_path_mut!` (src/zipper/Zipper.jl).
        #
        # ⚠️ THE COUNT WENT UP; THE RUNTIME WENT DOWN. These are static dispatch SITES, and the new
        # ones are union-split over `TrieNodeVariant`, so they cost nothing at run time. Measured
        # `remove_val_at!` x20_000 over an UNSHARED map, 3 runs, build excluded via `setup=`:
        #     with the fix   86.2 / 88.8 / 89.9 ms
        #     without it     97.4 / 101.7 / 108.1 ms
        #     allocations    807,981 in BOTH — nothing clones on the unshared path
        # A naive version of the same fix (calling `make_unique!` on the abstract `rc.node`, whose
        # `@nospecialize` helpers force a real dynamic dispatch) measured 42 -> 76 ms instead. The
        # difference is passing the already-narrowed `inner` from `_fnode`; that is what this
        # ratchet is really protecting, so do not "fix" the count by reverting to the abstract call.
        set_dyn = count(a -> a isa AllocCheck.DynamicDispatch,
            AllocCheck.check_allocs(
                PathMaps.set_val_at!, (typeof(m), Vector{UInt8}, Int32); ignore_throw=true
            ))
        @test set_dyn <= 21
    end
else
    @info "AllocCheck not loadable (plain julia --project=.) — read-path alloc guard runs under Pkg.test/CI"
end
