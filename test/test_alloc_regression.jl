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
        m = PathMap.PathMap{Int32}()
        for i in 1:64
            PathMap.set_val_at!(m, vcat(Vector{UInt8}("k" * lpad(string(i), 3, '0') * ":"), UInt8[i % 251]), Int32(i))
        end
        rz = PathMap.read_zipper(m)
        nallocs(f, ts) = length(AllocCheck.check_allocs(f, ts; ignore_throw = true))

        # zero-alloc INVARIANT — the coref de-box S1 (_coref_path_length) + S5 (@view) rely on this
        @test nallocs(PathMap.zipper_path, (typeof(rz),)) == 0

        # read-path residual — must not GROW beyond the measured optimized floor (ADR-001-gated:
        # node_get_child_nb Tuple boxing + Int64 Union returns → zero only under the isbits node slab)
        @test nallocs(PathMap.get_val_at,     (typeof(m), Vector{UInt8})) <= 8
        @test nallocs(PathMap.path_exists_at, (typeof(m), Vector{UInt8})) <= 8

        # cheap read-cursor primitives — locked at their measured floors
        @test nallocs(PathMap.zipper_child_mask,   (typeof(rz),)) <= 4
        @test nallocs(PathMap.zipper_ascend_byte!, (typeof(rz),)) <= 3
        @test nallocs(PathMap.zipper_val,          (typeof(rz),)) <= 4

        # write path: type-cascade de-box via call-site assertions (2026-07-06) took set_val_at!
        # dynamic dispatch 30 → 20 (descend `node_get_child`) → 17 (`clone_self` ×2 + the `node_set_val!`
        # closure) and insert 5662 → ~2650 ns/key (−53%). Lock the floor so a future write-path
        # type-instability regression is caught. (Full elimination of the remaining 17 needs the
        # ADR-001 isbits node slab — the `.node` field is abstract; the rest are node mutations.)
        set_dyn = count(a -> a isa AllocCheck.DynamicDispatch,
                        AllocCheck.check_allocs(PathMap.set_val_at!, (typeof(m), Vector{UInt8}, Int32); ignore_throw = true))
        @test set_dyn <= 17
    end
else
    @info "AllocCheck not loadable (plain julia --project=.) — read-path alloc guard runs under Pkg.test/CI"
end
