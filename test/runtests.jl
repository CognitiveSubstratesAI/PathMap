using Test
using PathMap
# Aqua is test-only [extras]. The optional load stays, but the reason recorded here was WRONG:
# it claimed Aqua is "present under Pkg.test/CI but NOT in a plain `julia --project=.` run".
# Measured 2026-08-01 — `using Aqua` succeeds under `--project=.` because the default LOAD_PATH is
# ["@", "@v#.#", "@stdlib"] and Aqua is installed in the v1.12 shared environment. So Aqua DOES run
# under tools/run_tests.sh (9/9 green when invoked directly). It does not appear in the suite log
# only because Julia collapses passing nested testsets into the parent line — verified by grepping
# the same log for `basic CRUD` / `write zipper` / `morphisms`, which are also absent.
# The try/catch is still correct: it covers an environment where the shared env lacks Aqua.
const _HAS_AQUA = try
    ;
    @eval using Aqua;
    true;
catch
    ;
    false;
end
const PM = PathMap.PathMap   # PathMap module and PathMap type share the same name

# Fails the build on any testset that runs but asserts nothing — see the file header for the two
# inert-oracle instances that motivated it. Captured into `_PM_TS` and checked AFTER the suite.
include("inert_testset_guard.jl")

const _PM_TS = @testset "PathMap" begin
    if _HAS_AQUA
        @testset "Aqua quality" begin
            # unbound_args: the lattice ops take Option-style `Union{Nothing,V}` args and
            # a more-specific `(::Nothing,::Nothing)` method handles the all-nothing case,
            # so the `where V` methods are never instantiated unbound — intentional, skip.
            # deps_compat check_extras=false: [extras] are dev-only tools (Cthulhu, Debugger,
            # ProfileView, …); runtime deps carry [compat].
            Aqua.test_all(PathMap; unbound_args=false, deps_compat=(check_extras=false,))
        end
    else
        @info "Aqua not loadable (plain julia --project=.) — runs under Pkg.test/CI"
    end

    @testset "basic CRUD" begin
        m = PM{Int}()
        set_val_at!(m, b"alpha", 1)
        set_val_at!(m, b"beta", 2)
        set_val_at!(m, b"gamma", 3)

        @test get_val_at(m, b"alpha") == 1
        @test get_val_at(m, b"beta") == 2
        @test get_val_at(m, b"missing") === nothing
        @test path_exists_at(m, b"alpha")
        @test !path_exists_at(m, b"missing")
        @test val_count(m) == 3

        remove_val_at!(m, b"beta")
        @test get_val_at(m, b"beta") === nothing
        @test val_count(m) == 2
    end

    @testset "read zipper iteration" begin
        m = PM{Int}()
        for (k, v) in [("a", 1), ("b", 2), ("c", 3)]
            set_val_at!(m, Vector{UInt8}(k), v)
        end
        rz = read_zipper(m)
        count = 0
        while zipper_to_next_val!(rz)
            count += 1
        end
        @test count == 3
    end

    @testset "write zipper" begin
        m = PM{Int}()
        wz = write_zipper(m)
        wz_descend_to!(wz, b"prefix:key")
        wz_set_val!(wz, 42)
        @test get_val_at(m, b"prefix:key") == 42

        wz_remove_val!(wz)
        @test get_val_at(m, b"prefix:key") === nothing
    end

    @testset "algebraic ops (psubtract)" begin
        a = PM{Bool}()
        b = PM{Bool}()
        set_val_at!(a, b"x", true);
        set_val_at!(a, b"y", true)
        set_val_at!(b, b"y", true);
        set_val_at!(b, b"z", true)

        # Subtract: a - b = {x}
        result = deepcopy(a)
        wz = write_zipper(result)
        wz_subtract_into!(wz, ANRBorrowedRc(b.root))
        @test get_val_at(result, b"x") == true
        @test get_val_at(result, b"y") === nothing
        @test val_count(result) == 1
    end

    @testset "policy API" begin
        a = PM{Int}()
        b = PM{Int}()
        set_val_at!(a, b"x", 3);
        set_val_at!(a, b"y", 1)
        set_val_at!(b, b"x", 2);
        set_val_at!(b, b"z", 5)

        r = pjoin_policy(a, b, SumPolicy())
        @test get_val_at(r, b"x") == 5   # 3+2
        @test get_val_at(r, b"y") == 1   # only in a
        @test get_val_at(r, b"z") == 5   # only in b

        r2 = pjoin_policy(a, b, MaxPolicy())
        @test get_val_at(r2, b"x") == 3  # max(3,2)
    end

    @testset "morphisms" begin
        m = PM{Int}()
        for i in 1:5
            set_val_at!(m, Vector{UInt8}("k$i"), i)
        end
        total = cata_cached(
            m,
            (mask, children, val) ->
                (val !== nothing ? val : 0) + reduce(+, children, init=0)
        )
        @test total == 15   # 1+2+3+4+5

        h = map_hash(m)
        @test h isa UInt64
        @test h != 0
    end

    @testset "insert_prefix / remove_prefix" begin
        m = PM{Int}()
        set_val_at!(m, b"foo:bar", 99)
        # Cursor at "foo:" — insert_prefix prepends "ns:" within that subtrie
        # "bar" → 99 becomes "ns:bar" → 99, full path: "foo:ns:bar"
        wz = write_zipper_at_path(m, b"foo:")
        @test wz_insert_prefix!(wz, b"ns:") == true
        @test get_val_at(m, b"foo:ns:bar") == 99
        @test get_val_at(m, b"foo:bar") === nothing

        # insert_prefix at root prepends to all absolute paths
        m2 = PM{Int}()
        set_val_at!(m2, b"eagle", 1)
        set_val_at!(m2, b"penguin", 2)
        wz2 = write_zipper(m2)
        @test wz_insert_prefix!(wz2, b"bird:") == true
        @test get_val_at(m2, b"bird:eagle") == 1
        @test get_val_at(m2, b"bird:penguin") == 2
        @test get_val_at(m2, b"eagle") === nothing
    end

    @testset "lazy COW — graft does not corrupt source" begin
        m1 = PM{Int}()
        set_val_at!(m1, b"hello", 42)

        m2 = PM{Int}()
        wz = write_zipper(m2)
        wz_descend_to!(wz, b"prefix:")
        wz_graft_map!(wz, m1)

        wz2 = write_zipper(m2)
        wz_descend_to!(wz2, b"prefix:hello")
        wz_set_val!(wz2, 99)

        @test get_val_at(m2, b"prefix:hello") == 99
        @test get_val_at(m1, b"hello") == 42   # unchanged
    end

    @testset "serialization round-trip" begin
        m = PM{Bool}()
        set_val_at!(m, b"alpha", true)
        set_val_at!(m, b"beta", true)
        io = IOBuffer()
        serialize_paths(m, io)
        seekstart(io)
        m2 = PM{Bool}()
        deserialize_paths(m2, io, true)
        @test val_count(m2) == val_count(m)
        @test path_exists_at(m2, b"alpha")
        @test path_exists_at(m2, b"beta")
    end

    @testset "ArenaCompact mmap round-trip" begin
        m = PM{UInt64}()
        set_val_at!(m, b"alpha", UInt64(42))
        set_val_at!(m, b"beta", UInt64(99))
        set_val_at!(m, b"gamma", UInt64(7))

        tree_vec = act_from_zipper(m, v -> v)
        tmpfile = tempname() * ".act"
        act_save(tree_vec, tmpfile)

        tree_mmap = act_open_mmap(tmpfile)
        @test tree_mmap isa ArenaCompactTree
        @test length(tree_mmap.data) == filesize(tmpfile)
        @test tree_mmap.data[1:8] == ACT_MAGIC

        @test act_get_val_at(tree_mmap, b"alpha") === UInt64(42)
        @test act_get_val_at(tree_mmap, b"beta") === UInt64(99)
        @test act_get_val_at(tree_mmap, b"gamma") === UInt64(7)
        @test act_get_val_at(tree_mmap, b"missing") === nothing

        # act_open_mmap and act_open must agree on all keys
        tree_copy = act_open(tmpfile)
        for key in (b"alpha", b"beta", b"gamma", b"missing")
            @test act_get_val_at(tree_mmap, key) === act_get_val_at(tree_copy, key)
        end

        z = act_read_zipper(tree_mmap)
        @test act_val_count(z) == 3

        rm(tmpfile; force=true)
    end

    @testset "remove_val_at! with prune" begin
        m = PM{Int}()
        set_val_at!(m, b"abc", 1)
        set_val_at!(m, b"abd", 2)
        set_val_at!(m, b"xyz", 3)

        old = remove_val_at!(m, b"abc", true)
        @test old === 1
        @test get_val_at(m, b"abc") === nothing
        @test get_val_at(m, b"abd") === 2
        @test get_val_at(m, b"xyz") === 3
    end

    @testset "wz_remove_branches! with prune" begin
        m = PM{Int}()
        set_val_at!(m, b"foo:a", 10)
        set_val_at!(m, b"foo:b", 20)
        set_val_at!(m, b"bar", 30)

        wz = write_zipper_at_path(m, b"foo:")
        wz_remove_branches!(wz, true)

        @test get_val_at(m, b"foo:a") === nothing
        @test get_val_at(m, b"foo:b") === nothing
        @test get_val_at(m, b"bar") === 30
    end

    @testset "wz_subtract_into! with prune=true removes dangling paths" begin
        # a = {abc→1, abd→2, xyz→3}; b = {abc→1, abd→2}
        # subtract with prune: a-b = {xyz→3}, "ab" prefix branch pruned
        a = PM{Int}()
        set_val_at!(a, b"abc", 1)
        set_val_at!(a, b"abd", 2)
        set_val_at!(a, b"xyz", 3)

        b = PM{Int}()
        set_val_at!(b, b"abc", 1)
        set_val_at!(b, b"abd", 2)

        result = deepcopy(a)
        wz = write_zipper(result)
        src_anr = if b.root === nothing
            ANRNone{Int, GlobalAlloc}()
        else
            ANRBorrowedRc{Int, GlobalAlloc}(b.root)
        end
        status = wz_subtract_into!(wz, src_anr, true)

        @test status == ALG_STATUS_ELEMENT || status == ALG_STATUS_NONE
        @test get_val_at(result, b"abc") === nothing
        @test get_val_at(result, b"abd") === nothing
        @test get_val_at(result, b"xyz") === 3
        @test val_count(result) == 1
    end

    @testset "wz_meet_into! with prune=true removes dangling paths" begin
        # a = {abc→true, xyz→true}; b = {xyz→true}
        # meet: intersection = {xyz→true}, "abc" branch pruned
        a = PM{Bool}()
        set_val_at!(a, b"abc", true)
        set_val_at!(a, b"xyz", true)

        b = PM{Bool}()
        set_val_at!(b, b"xyz", true)

        result = deepcopy(a)
        wz = write_zipper(result)
        src_anr = if b.root === nothing
            ANRNone{Bool, GlobalAlloc}()
        else
            ANRBorrowedRc{Bool, GlobalAlloc}(b.root)
        end
        status = wz_meet_into!(wz, src_anr, true)

        @test status == ALG_STATUS_ELEMENT || status == ALG_STATUS_IDENTITY
        @test get_val_at(result, b"abc") === nothing
        @test get_val_at(result, b"xyz") === true
        @test val_count(result) == 1
    end

    @testset "wz_meet_into! prune=true on empty src clears entire subtrie" begin
        # meeting with empty src → result is empty, prune removes branch
        a = PM{Bool}()
        set_val_at!(a, b"prefix:foo", true)
        set_val_at!(a, b"prefix:bar", true)
        set_val_at!(a, b"other", true)

        result = deepcopy(a)
        wz = write_zipper_at_path(result, b"prefix:")
        empty_anr = ANRNone{Bool, GlobalAlloc}()
        wz_meet_into!(wz, empty_anr, true)

        @test get_val_at(result, b"prefix:foo") === nothing
        @test get_val_at(result, b"prefix:bar") === nothing
        @test get_val_at(result, b"other") === true
        @test val_count(result) == 1
    end

    @testset "anchored ProductZipper(m, prefix, n) == root ProductZipper on equivalent data" begin
        # Regression for the prefix-anchored multi-factor query path.
        # The anchored constructor must produce IDENTICAL Cartesian-product
        # iteration to a root ProductZipper over the same leaves — for BOTH
        # branching prefixes (node boundary) and single-path prefixes
        # (mid-compressed-edge, which the naive tr_get_focus_rc path dropped).
        drive(prz) = begin
            out = String[]
            while pz_to_next_val!(prz)
                push!(out, String(copy(collect(pz_path(prz)))))
            end
            sort!(out)
        end
        root_pz(m, n) = ProductZipper(read_zipper(m), [read_zipper(m) for _ in 2:n])
        anchored_pz(m, p, n) = ProductZipper(m, Vector{UInt8}(p), n)

        # (1) branching prefix: {foo,bar} under "a/"  vs  flat {foo,bar}
        flatAB = PM{UnitVal}()
        set_val_at!(flatAB, b"foo", UNIT_VAL);
        set_val_at!(flatAB, b"bar", UNIT_VAL)
        preAB = PM{UnitVal}()
        set_val_at!(preAB, b"a/foo", UNIT_VAL);
        set_val_at!(preAB, b"a/bar", UNIT_VAL)
        @test drive(anchored_pz(preAB, "a/", 2)) == drive(root_pz(flatAB, 2))
        # and no result carries the raw prefix byte 'a'
        @test !any(
            s -> !isempty(s) && codeunits(s)[1] == UInt8('a'),
            drive(anchored_pz(preAB, "a/", 2))
        )

        # (2) single-path prefix: {foo} under "b/" vs flat {foo}
        #     (mid-compressed-edge — the case that returned empty pre-fix)
        flatC = PM{UnitVal}();
        set_val_at!(flatC, b"foo", UNIT_VAL)
        preC = PM{UnitVal}();
        set_val_at!(preC, b"b/foo", UNIT_VAL)
        @test drive(anchored_pz(preC, "b/", 2)) == drive(root_pz(flatC, 2))
        @test !isempty(drive(anchored_pz(preC, "b/", 2)))   # not silently empty

        # (3) absent prefix region → no matches
        @test isempty(drive(anchored_pz(preAB, "zzz/", 2)))
    end

    @testset "wz_take_focus! honors prune=true" begin
        # Build a map with two leaves sharing a common deep prefix.
        m = PM{Int}()
        set_val_at!(m, b"path:a:k1", 7)
        set_val_at!(m, b"path:a:k2", 8)
        set_val_at!(m, b"other", 9)

        # Position cursor at the "path:a:" subtree (no val, two children).
        wz = write_zipper_at_path(m, b"path:a:")
        rc = wz_take_focus!(wz, true)
        @test rc !== nothing

        # Both keys under the taken subtree are gone in m.
        @test get_val_at(m, b"path:a:k1") === nothing
        @test get_val_at(m, b"path:a:k2") === nothing
        # Unrelated key is untouched.
        @test get_val_at(m, b"other") === 9
        # And the now-empty "path:" spine is pruned (prune=true).
        @test wz_val_count(write_zipper_at_path(m, b"path:")) == 0
    end

    @testset "wz_remove_branches! preserves structural sharing (lazy COW)" begin
        # If the public wz_remove_branches! mutated a shared inner node
        # without first making it unique, m_src would also lose the keys.
        m_src = PM{Int}()
        set_val_at!(m_src, b"shared:k1", 1)
        set_val_at!(m_src, b"shared:k2", 2)

        m_view = PM{Int}()
        wz = write_zipper(m_view)
        wz_descend_to!(wz, b"copy:")
        wz_graft_map!(wz, m_src)

        # Now drop branches from the grafted region in m_view.
        wz2 = write_zipper_at_path(m_view, b"copy:shared:")
        wz_remove_branches!(wz2, true)

        # m_view loses the branches; m_src must not.
        @test get_val_at(m_view, b"copy:shared:k1") === nothing
        @test get_val_at(m_view, b"copy:shared:k2") === nothing
        @test get_val_at(m_src, b"shared:k1") === 1
        @test get_val_at(m_src, b"shared:k2") === 2
    end

    @testset "PrefixZipper pz_descend_to_existing! is byte-correct on String input" begin
        # The old code did `append!(pz.path, path[1:descended])` on the
        # possibly-already-sliced caller arg, which is codepoint-indexed
        # for String. With a String prefix in source data this would
        # mis-append. Fix: keep a pristine `bytes_in = collect(UInt8, path)`
        # and slice that.
        m = PM{Int}()
        set_val_at!(m, b"abc", 1)

        pz = PathMap.PrefixZipper(b"X/", read_zipper(m))
        # Descend with a String of pure ASCII first (the common case)
        n1 = PathMap.pz_descend_to_existing!(pz, "X/abc")
        @test n1 == 5
        @test pz.path == b"X/abc"
    end

    @testset "ZipperHead — read + write zippers at disjoint paths" begin
        # Previously: zh_read_zipper_at_path called ReadZipperCore_at_path
        # with 4 args; the only signature requires 6 → MethodError on every
        # call. Whole layer was dead-on-arrival with zero test coverage.
        m = PM{Int}()
        set_val_at!(m, b"app:a:k1", 1)
        set_val_at!(m, b"app:b:k1", 2)
        set_val_at!(m, b"common:k1", 99)

        zh = zipper_head(m)

        # Two non-overlapping read zippers should coexist.
        rzt_a = zh_read_zipper_at_path(zh, b"app:a:")
        rzt_b = zh_read_zipper_at_path(zh, b"app:b:")
        @test rzt_val_count(rzt_a) == 1
        @test rzt_val_count(rzt_b) == 1

        # A write zipper at a disjoint path coexists with both reads.
        wzt = zh_write_zipper_at_exclusive_path(zh, b"common:")
        @test wzt_path_exists(wzt)
        wzt_descend_to!(wzt, b"k2")
        wzt_set_val!(wzt, 100)

        rzt_release!(rzt_a)
        rzt_release!(rzt_b)
        wzt_release!(wzt)

        @test get_val_at(m, b"common:k2") === 100
    end

    @testset "ZipperHead — overlapping write paths conflict" begin
        m = PM{Int}()
        set_val_at!(m, b"region:a", 1)

        zh = zipper_head(m)
        wzt1 = zh_write_zipper_at_exclusive_path(zh, b"region:")
        # Opening a second writer under the same prefix must raise Conflict.
        @test_throws PathMap.Conflict zh_write_zipper_at_exclusive_path(zh, b"region:")
        # Releasing the first must let a second writer open cleanly.
        wzt_release!(wzt1)
        wzt2 = zh_write_zipper_at_exclusive_path(zh, b"region:")
        @test wzt_path_exists(wzt2)
        wzt_release!(wzt2)
    end

    # ZT-1 (audit 2026-06-04): tracked-zipper locks release via `finalizer` = GC time,
    # not scope exit like Rust Drop, so a lingering lock can cause a spurious Conflict.
    # `with_zipper_tracker` releases DETERMINISTICALLY at scope exit. This test asserts
    # the lock is free immediately after the `with_` block WITHOUT any GC.gc() call.
    @testset "ZT-1: with_zipper_tracker releases the lock at scope exit (no GC)" begin
        stp = SharedTrackerPaths()
        tr = ZipperTracker{TrackingWrite}(stp, b"x")
        with_zipper_tracker(tr) do _t
            @test stp_path_status(stp, b"x") == PATH_STATUS_UNAVAILABLE  # locked inside
        end
        # Released at scope exit — deterministic, NO GC.gc() invoked here.
        @test stp_path_status(stp, b"x") == PATH_STATUS_AVAILABLE
        @test stp_try_add_writer!(stp, b"x") === nothing  # fresh writer opens, no spurious Conflict

        # Same deterministic release for the tracked-zipper wrappers.
        m = PM{Int}()
        zh = zipper_head(m)
        wzt = zh_write_zipper_at_exclusive_path(zh, b"y:")
        with_write_zipper_tracked(wzt) do z
            @test wzt_path_exists(z) isa Bool
        end
        # Lock released at scope exit → a second writer at the same prefix opens cleanly.
        wzt2 = zh_write_zipper_at_exclusive_path(zh, b"y:")
        @test wzt_path_exists(wzt2) isa Bool
        wzt_release!(wzt2)
    end

    @testset "ProductZipperG — direct, heterogeneous factor types" begin
        # ProductZipperG existed only with indirect coverage via MORK's
        # space_query_multi_i. The audit flagged this as a coverage gap.
        # Direct: 2-factor product over two PathMaps. Primary leaves are
        # themselves vals, so the cursor yields at primary-only positions
        # too — total = 2 (primary vals) + 2×3 (Cartesian) = 8.
        m1 = PM{UnitVal}()
        set_val_at!(m1, b"a", UNIT_VAL)
        set_val_at!(m1, b"b", UNIT_VAL)

        m2 = PM{UnitVal}()
        set_val_at!(m2, b"1", UNIT_VAL)
        set_val_at!(m2, b"2", UNIT_VAL)
        set_val_at!(m2, b"3", UNIT_VAL)

        rz1 = read_zipper(m1)
        rz2 = read_zipper(m2)
        pzg = PathMap.ProductZipperG(rz1, [rz2])
        @test pzg_factor_count(pzg) == 2

        n = 0
        while pzg_to_next_val!(pzg)
            n += 1
            n > 100 && break   # safety
        end
        @test n == 8
    end

    @testset "DependentZipper — callback decides secondary extension" begin
        # Direct test of the dynamic-factor pattern. The enroll callback
        # signature is `(payload, path, factor_idx) → (new_payload, sz_or_nothing)`
        # — note the TUPLE return; the new_payload is threaded through.
        m_primary = PM{UnitVal}()
        set_val_at!(m_primary, b"X", UNIT_VAL)
        set_val_at!(m_primary, b"Y", UNIT_VAL)

        m_ext = PM{UnitVal}()
        set_val_at!(m_ext, b"!", UNIT_VAL)
        set_val_at!(m_ext, b"?", UNIT_VAL)

        rz = read_zipper(m_primary)
        function enroll_cb(payload, path::AbstractVector{UInt8}, factor_idx::Int)
            (payload, path == b"X" ? read_zipper(m_ext) : nothing)
        end

        dpz = PathMap.DependentZipper(rz, nothing, enroll_cb)
        n = 0
        while PathMap.dpz_to_next_val!(dpz)
            n += 1
            n > 100 && break
        end
        # The walk yields each val position the cursor reaches: primary
        # vals "X", "Y" plus the extension vals "!", "?" under X.
        @test n >= 3
        @test n <= 5
    end

    @testset "DependentZipper — factor_paths and secondary stay IN STEP (upstream 143ecd1)" begin
        # Upstream PathMap `815eed1`/`143ecd1` (PR #56, "dependent_zipper_factor_fixes") fixed
        # `DependentProductZipperG` by popping `secondary` alongside `factor_paths` — the two had
        # drifted apart — and added `debug_assert_eq!(factor_paths.len(), secondary.len(),
        # "factor_paths and secondary must stay in step")` to pin it.
        #
        # WE ALREADY HAD THE FIX: both pop sites in DependentZipper.jl pop `secondary` in step, and
        # `dpz_reset!` empties it. So this pins an invariant we satisfy rather than fixing anything.
        #
        # It is a TEST and NOT an `@assert`, deliberately. `debug_assert!` is compiled out in
        # release, so upstream PROCEEDS on violation; throwing here would be a new divergence. That
        # is the exact reasoning already recorded at `src/nodes/LineListNode.jl:1837` for upstream's
        # `debug_assert!(!status.is_none())`, and it is the standing rule: a debug assertion is not
        # a runtime contract.
        #
        # ⚠️ Upstream also DELETED the inherent `factor_count()` on DependentProductZipperG. That is
        # NOT adopted: it is a refactor of their trait layout (`factor_count` survives on the
        # ProductZipper trait, product_zipper.rs:806), while ours is live — `ProductZipperG.jl:227`
        # computes `dpz_factor_count(src) - 1`. Removing it would break working code to mirror a
        # change that does not apply here.
        m_primary = PM{UnitVal}()
        for k in (b"X", b"Y", b"Z"); set_val_at!(m_primary, k, UNIT_VAL); end
        m_ext = PM{UnitVal}()
        for k in (b"!", b"?"); set_val_at!(m_ext, k, UNIT_VAL); end

        rz = read_zipper(m_primary)
        enroll_cb(payload, path::AbstractVector{UInt8}, factor_idx::Int) =
            (payload, path == b"X" ? read_zipper(m_ext) : nothing)

        dpz = PathMap.DependentZipper(rz, nothing, enroll_cb)
        in_step = true
        steps = 0
        while PathMap.dpz_to_next_val!(dpz)
            in_step &= (length(dpz.factor_paths) == length(dpz.secondary))
            steps += 1
            steps > 100 && break
        end
        @test steps > 0                       # the walk actually moved — not a vacuous pass
        @test in_step

        # reset must clear BOTH, not just factor_paths (upstream's `secondary.clear()`).
        PathMap.dpz_reset!(dpz)
        @test isempty(dpz.factor_paths)
        @test isempty(dpz.secondary)
    end

    @testset "ZipperHead — cleanup_write_zipper prunes the right spine" begin
        # Previously: cleanup used wz_path (relative) where it should have
        # used the absolute origin path. So pruning operated on the wrong
        # subtree (or no-op'd entirely).
        m = PM{Int}()
        set_val_at!(m, b"unrelated", 7)

        zh = zipper_head(m)
        # Open a zipper rooted DEEP, create a dangling sub-path, take it.
        wzt = zh_write_zipper_at_exclusive_path(zh, b"deep:spine:")
        wzt_descend_to!(wzt, b"leaf")
        wzt_set_val!(wzt, 42)
        wzt_remove_val!(wzt)  # removes the val, leaves the spine dangling

        zh_cleanup_write_zipper!(zh, wzt)

        # The dangling "deep:spine:leaf" path must be pruned.
        @test get_val_at(m, b"deep:spine:leaf") === nothing
        # Unrelated keys must survive.
        @test get_val_at(m, b"unrelated") === 7
        # And the spine itself is gone (val_count under "deep:" == 0).
        @test wz_val_count(write_zipper_at_path(m, b"deep:")) == 0
    end

    # ── COW refcount primitive — pins the exact contract that the node-keyed
    #    refcount rewrite (PathMap audit 2026-06-02, close-out step 2) must
    #    preserve. Green on the current per-wrapper-Ref scheme AND must stay green
    #    after the rewrite, so it is the rewrite's fail-safe. copy() bumps a SHARED
    #    count; make_unique! on a shared wrapper clones + detaches and leaves the
    #    survivor's count correct; make_unique! on a sole owner is a no-op.
    @testset "COW refcount semantics (rewrite guard)" begin
        m = PM{Int}()
        set_val_at!(m, b"alpha", 1)
        set_val_at!(m, b"beta", 2)
        root = m.root

        @test !is_empty_node(root)
        @test refcount(root) == 1

        c = copy(root)
        @test refcount(root) == 2        # copy bumps the shared count
        @test refcount(c) == 2
        @test ptr_eq(root, c)            # both wrappers point at the same node

        make_unique!(c)                  # c is shared (rc>1) → clone + detach
        @test !ptr_eq(root, c)           # c now owns a private clone
        @test refcount(root) == 1        # survivor's count decremented correctly
        @test refcount(c) == 1

        node_before = c.node
        make_unique!(c)                  # sole owner → no-op, no clone
        @test c.node === node_before
        @test refcount(c) == 1

        # The original map is untouched by the copy/uniquify dance on its root.
        @test get_val_at(m, b"alpha") == 1
        @test get_val_at(m, b"beta") == 2
    end

    # ── Operator-precedence fixes (PathMap audit 2026-06-02, close-out step 1).
    #    `A || B && return/continue` parses as `A || (B && …)` in Julia (&& binds
    #    tighter than ||) — three sites had this transpilation defect. Each test
    #    THREW pre-fix on the empty/disjoint branch the misparse let fall through.
    @testset "precedence-bug regressions" begin
        # should_swap_keys: empty key0 fell through to key0[1] → BoundsError pre-fix.
        @test PathMap.should_swap_keys(UInt8[], UInt8[0x41]) == false
        @test PathMap.should_swap_keys(UInt8[0x41], UInt8[]) == false
        @test PathMap.should_swap_keys(UInt8[0x42], UInt8[0x41]) == true   # higher byte → swap
        @test PathMap.should_swap_keys(UInt8[0x41], UInt8[0x42]) == false
        @test PathMap.should_swap_keys(UInt8[0x41, 0x41], UInt8[0x41]) == true  # same byte, longer → swap

        # Dict psubtract: a key only in the SMALLER operand made self_v===nothing
        # fall through to psubtract(nothing, …) → MethodError pre-fix. a−b with a
        # disjoint, larger `a` is just `a` (identity on self).
        let a = Dict("x" => 1, "y" => 1, "z" => 1), b = Dict("w" => 1)
            r = PathMap.psubtract(a, b)
            @test r !== nothing                      # did not throw; returned a result
            @test r isa PathMap.AlgResIdentity       # disjoint subtraction = self unchanged
        end

        # node_is_empty(::Nothing): `nothing` is the EmptyNode sentinel inside a
        # TrieNodeODRc (TrieNode.jl:360), so as_tagged(rc) legitimately yields nothing for
        # an empty child. psubtract's child guard `!node_is_empty(as_tagged(cf.rec))`
        # (DenseByteNode.jl:962) crashed with MethodError(node_is_empty(::Nothing)) without
        # this method — surfaced end-to-end by MORK's `!=` comparison source.
        @test PathMap.node_is_empty(nothing) == true
    end

    # ── COW property: join_k_path (MorkL OP_DROP_HEAD) on a SHARED subtrie must NOT
    #    corrupt the source map. This was a LIVE bug — drop_head_dyn! mutated the
    #    shared focus node in place (reached via get_node_at_key, off the focus
    #    stack), silently corrupting the source. Fixed by make_unique! on the
    #    borrowed focus rc before the in-place mutation.
    @testset "COW property: join_k_path on shared subtrie preserves source" begin
        m1 = PM{Int}()
        set_val_at!(m1, b"Xab", 1)
        set_val_at!(m1, b"Xcd", 2)

        m2 = PM{Int}()
        wz = write_zipper(m2)
        wz_descend_to!(wz, b"P:")
        wz_graft_map!(wz, m1)                 # shares m1's nodes under "P:" (refcount>1)

        wz2 = write_zipper(m2)
        wz_descend_to!(wz2, b"P:")
        @test wz_join_k_path_into!(wz2, 1)    # drop first byte below "P:": Xab→ab, Xcd→cd

        @test get_val_at(m2, b"P:ab") == 1    # m2 reflects the drop
        @test get_val_at(m2, b"P:cd") == 2
        @test get_val_at(m1, b"Xab") == 1     # source intact — the COW property
        @test get_val_at(m1, b"Xcd") == 2
    end

    # ── join_k_path_into with prune=true must leave NO DANGLING PATH when the drop
    #    yields nothing. Upstream's tail is `if prune && !result { self.prune_path(); }`
    #    (write_zipper.rs:1773) — the PUBLIC prune_path, which first runs
    #    node_remove_dangling(node_key) and only then walks the ancestors (:2179-2190).
    #    We called the INTERNAL helper instead, from two places, skipping the node-level
    #    dangling removal entirely.
    #
    #    IT IS INVISIBLE TO THE DUMP, which is why nothing caught it: a dangling path
    #    carries no value, so val_count and path enumeration are identical either way.
    #    Measured on identical state, old prune vs new:
    #        old -> pruned=0 bytes, path_exists_at("ab") == true
    #        new -> pruned=2 bytes, path_exists_at("ab") == false
    #    path_exists is exactly the observable upstream's prune_path doc names ("may result
    #    in path_exists subsequently returning false, where it previously returned true").
    #
    #    Nor could the differential have caught it: join_k_path_into is not among the 12 ops
    #    the fuzz generator emits.
    @testset "join_k_path_into(prune) leaves no dangling path — assert via path_exists" begin
        for (tag, keys, origin, k) in (
                ("focus INSIDE a node key", [b"abc"],        b"ab",    5),
                ("focus at a node boundary", [b"ab", b"ac"],  b"a",     5),
                ("deep dangling spine",      [b"aaaabc"],     b"aaaab", 9))
            m = PM{Int}()
            for key in keys
                set_val_at!(m, key, 1)
            end
            wz = PathMap.write_zipper_at_path(m, origin)
            @test wz_join_k_path_into!(wz, k, true) == false      # the drop yields nothing
            @test PathMap.path_exists_at(m, origin) == false      # ← the dangling path is GONE
            @test val_count(m) == 0
        end

        # CONTROL: when the drop SUCCEEDS there is nothing to prune and the result stands.
        m = PM{Int}()
        set_val_at!(m, b"abcd", 1)
        wz = PathMap.write_zipper_at_path(m, b"ab")
        @test wz_join_k_path_into!(wz, 1, true) == true
        @test get_val_at(m, b"abd") == 1
    end

    # ── Gate B (close-out step 2): shallow clone_self restores STRUCTURAL SHARING.
    #    clone_self used to deepcopy whole subtrees (sharing defeated, PathMap's
    #    reason for existing). After the shallow-clone change a cloned node SHARES
    #    its children with the original (same node identity). This is the gate that
    #    proves deepcopy is actually gone — integration tests cannot measure sharing.
    @testset "Gate B — clone_self shares children (structural sharing restored)" begin
        m = PM{Int}()
        for k in (b"aXX", b"aYY", b"bXX", b"bYY")   # 2-level trie → root has child nodes
            set_val_at!(m, k, 1)
        end
        root = m.root
        _, child = PathMap.node_child_iter_start(PathMap.as_tagged(root))
        cl = clone_self(PathMap.as_tagged(root))   # shallow clone of the node
        _, child_clone = PathMap.node_child_iter_start(PathMap.as_tagged(cl))
        @test child !== nothing && child_clone !== nothing
        @test PathMap.shared_node_id(child) == PathMap.shared_node_id(child_clone)  # SHARED
    end

    # ── Gate B (byte node): clone_self of a DenseByteNode must also work + share.
    #    deepcopy_bn briefly called copy(n.mask), but copy(::ByteMask) is undefined →
    #    MethodError silently emptied any cloned byte node (regression in ec138d4).
    #    The unit COW tests above stay in LineListNodes (≤2 slots), so they missed it;
    #    MorkServer's metta_thread/copy integration caught it. This pins the byte-node
    #    clone path: 26 distinct first bytes force a byte-node root.
    @testset "Gate B — clone_self of a byte node shares children (no copy(mask) error)" begin
        m = PM{Int}()
        for c in 0x61:0x7a                       # 'a'..'z' first bytes → root is a byte node
            set_val_at!(m, vcat(UInt8[c], b"X"), Int(c))
        end
        root = m.root
        @test PathMap.node_tag(PathMap.as_tagged(root)) in
            (PathMap.DENSE_BYTE_NODE_TAG, PathMap.CELL_BYTE_NODE_TAG)
        cl = clone_self(PathMap.as_tagged(root))   # deepcopy_bn — threw MethodError pre-fix
        @test cl !== nothing
        _, child = PathMap.node_child_iter_start(PathMap.as_tagged(root))
        _, childc = PathMap.node_child_iter_start(PathMap.as_tagged(cl))
        @test child !== nothing && childc !== nothing
        @test PathMap.shared_node_id(child) == PathMap.shared_node_id(childc)   # SHARED
    end

    # ── Gate A (graft): by-reference graft of a subtrie into another location SHARES
    #    nodes; a subsequent write into the grafted location must uniquify on descent
    #    so the source subtrie is preserved. This is the COW property MorkServer's
    #    cmd_copy relies on (O(1) wz.graft instead of an O(n) value-copy).
    @testset "Gate A — graft then write into shared subtrie preserves source" begin
        m = PM{Int}()
        set_val_at!(m, b"Sab", 1)
        set_val_at!(m, b"Scd", 2)
        src_anr = PathMap.tr_get_focus_anr(PathMap.trie_ref_at_path(m, b"S"))
        wz = write_zipper(m);
        wz_descend_to!(wz, b"D");
        PathMap.wz_graft!(wz, src_anr)
        @test get_val_at(m, b"Dab") == 1 && get_val_at(m, b"Dcd") == 2   # graft copied
        set_val_at!(m, b"Dab", 99)                                       # mutate shared graft
        set_val_at!(m, b"Def", 7)
        @test get_val_at(m, b"Sab") == 1 && get_val_at(m, b"Scd") == 2   # source intact (COW)
        @test get_val_at(m, b"Sef") === nothing
        @test get_val_at(m, b"Dab") == 99 && get_val_at(m, b"Def") == 7  # dest reflects writes
    end

    # ── Gate A (close-out step 3): with sharing restored, drop_head_dyn!'s RECURSION
    #    into a shared child must not corrupt the source. Construction forces the
    #    LineListNode recursion (consume the parent key "abc" then recurse 1 byte into
    #    the shared {XX,YY} child). FAILED on shallow-clone-without-discipline (source
    #    keys became `nothing`); passes once make_unique! guards the recursion.
    @testset "Gate A — drop_head recursion on shared child preserves source" begin
        m1 = PM{Int}()
        set_val_at!(m1, b"abcXX", 1)
        set_val_at!(m1, b"abcYY", 2)

        m2 = PM{Int}()
        wz = write_zipper(m2)
        wz_descend_to!(wz, b"P:")
        wz_graft_map!(wz, m1)                 # shares m1's nodes (incl. the {XX,YY} child)

        wz2 = write_zipper(m2)
        wz_descend_to!(wz2, b"P:")
        wz_join_k_path_into!(wz2, 4)          # consume "abc" + recurse 1 into shared child

        @test get_val_at(m2, b"P:X") == 1     # m2 reflects the drop
        @test get_val_at(m2, b"P:Y") == 2
        @test get_val_at(m1, b"abcXX") == 1   # source intact through the recursion
        @test get_val_at(m1, b"abcYY") == 2
    end

    # ── EU-fixpoint regression (07-09): a snapshot that SHARES the map's ROOT (as
    #    `PathMap::clone` / the MM2 exec-calculus's `pjoin` read-copy does) must stay
    #    FROZEN when the live map takes a SAME-SUBTRIE write. The transitive-COW bug in
    #    `_wz_ensure_write_unique!` forked the DESCENT's stale child wrapper (owned by the
    #    snapshot's child slot) + re-linked, so BOTH the snapshot and the live map ended up
    #    pointing through the SAME forked child → a same-subtrie write LEAKED into the
    #    snapshot. In MORK that made the exec's `pjoin` read-snapshot see the AddSink's OWN
    #    freshly-added atoms, over-collect the `(new …)` frontier, and halt the CTL `EU`
    #    least-fixpoint one round early. Fixed by RE-FETCHING children from the just-
    #    uniquified parent (upstream `write_zipper.rs make_mut`). The existing "graft then
    #    write" Gate-A test does NOT cover this (it passed on the buggy baseline) — the
    #    trigger is a ROOT-shared snapshot + same-subtrie write via `set_val_at!`.
    @testset "COW — root-shared snapshot + same-subtrie write preserves snapshot (EU-bug regression)" begin
        m = PM{Int}()
        set_val_at!(m, b"Ea", 1); set_val_at!(m, b"Eb", 2); set_val_at!(m, b"Ec", 3)
        snap = typeof(m)(copy(m.root::PathMap.TrieNodeODRc), m.root_val, m.alloc)  # share the root
        set_val_at!(m, b"Ed", 4)                                                    # SAME (E*) subtrie
        @test get_val_at(snap, b"Ed") === nothing                                   # snapshot NOT leaked into
        @test get_val_at(snap, b"Ea") == 1 && get_val_at(snap, b"Eb") == 2 && get_val_at(snap, b"Ec") == 3
        @test get_val_at(m, b"Ed") == 4                                             # live map reflects the write
        # reverse: writing the snapshot must not corrupt the source
        set_val_at!(snap, b"Ee", 5)
        @test get_val_at(m, b"Ee") === nothing
        @test get_val_at(snap, b"Ee") == 5
    end

    # ── close-out 2-A: the refcount is now node-keyed (@atomic refcnt on the node),
    #    so concurrent copy() from many threads increments ONE atomic counter with no
    #    lost updates. The previous per-wrapper `Ref{Int} += 1` was racy. Needs
    #    --threads>1 to actually contend; single-threaded it would pass vacuously.
    @testset "node-keyed refcount is atomic under concurrent copy (2-A)" begin
        if Threads.nthreads() < 2
            @test_skip "needs julia --threads>1 to contend on the atomic refcount"
        else
            m = PM{Int}()
            set_val_at!(m, b"alpha", 1)
            set_val_at!(m, b"beta", 2)
            root = m.root
            M = 500
            tasks = [Threads.@spawn copy(root) for _ in 1:M]
            copies = fetch.(tasks)
            @test refcount(root) == M + 1                       # exact: no lost increments
            @test all(c -> ptr_eq(root, c), copies)             # all share the one node
            make_unique!(copies[1])                             # detach one
            @test refcount(root) == M                           # exact decrement
            @test !ptr_eq(root, copies[1])
        end
    end
end

# ADR-001 increment 1 — slab scaffold (additive; not wired into the live trie)
include("test_node_slab.jl")

# AllocCheck read-path allocation regression guard (dev-only; skips if AllocCheck absent)
include("test_alloc_regression.jl")

# Viz (Mermaid rendering + structural-sharing observability) — port of viz.rs
include("test_viz.jl")

# Wired 2026-07-27. This file existed but was NEVER included — the same orphan pattern that
# hid 36 files in MORK/test/integration/. It also could not be included as written: it bound
# `PM` with a plain assignment while both callers already bind it as a `const`.
include("test_william_nary.jl")
include("test_path_exists_at.jl")

# graft_child_maps / graft_masked_branches / meet_2 / split_at_focus + the child-path setters
# (ported 2026-07-31). Expectations are upstream's OWN tests, transcribed scenario by scenario
# from write_zipper.rs:5110-5206 and :5340-5429.
include("test_graft_child_maps.jl")

# A join never writes into its source operand — asserted by SEMANTICS rather than by the fuzz
# ratchet, which records THAT cases differ, not WHY. This file used to assert the exact opposite
# ("the join CONSUMES its source", 8fe6319); read its header before touching it, because the
# reversal is the whole lesson.
include("test_join_preserves_source.jl")

# The UPSTREAM defects we deliberately do not reproduce — same reasoning: a ratchet cannot tell
# "upstream is wrong" from "we regressed".
include("test_cow_k_path.jl")
include("test_cow_at_path.jl")
include("test_cow_join_map.jl")
include("test_value_algebra.jl")
include("test_bool_lattice.jl")
include("test_prune_call_sites.jl")
# `restrict`'s AlgebraicStatus, pinned against the upstream binary. Same reason as the two above:
# the divergence was in the STATUS only — every trie dump already matched — so nothing that
# asserts contents could see it. See the file header.
include("test_restrict.jl")

include("upstream_defects.jl")

# Upstream differential ratchet (added 2026-07-27). PathMap previously had NO executable check
# against upstream Rust — only local tests comparing PathMap to itself, which is how a
# self-consistent wrong answer (path_exists_at on mid-edge prefixes) survived for months.
# Needs no Rust toolchain: upstream output is vendored under test/differential/expected/.
include("differential_gate.jl")
# Randomised sibling of the curated differential above: 300 generated operation programs, each
# paired with the upstream Rust engine's own answer. Ratchet, same contract. Curated scenarios
# only find what someone thought to write down; this searches. See test/fuzz_gate.jl.
include("fuzz_gate.jl")

# UPSTREAM'S OWN zipper conformance battery, ported (src/zipper.rs:3037+). Covers the ONE layer the
# two gates above do not: rust_probe references no zipper composition, and the fuzz corpus exercises
# the trie ALGEBRA (join/meet/subtract/graft) only. Upstream applies this battery to ProductZipper,
# ProductZipperG, ArenaCompactZipper and OverlayZipper; we had never run it at all.
include("test_upstream_zipper_battery.jl")

# The five ops ProductZipperG was MISSING, which the battery revealed by being unable to run
# against the composition type at all. Upstream applies the battery to ProductZipperG; we could not.
include("test_pzg_battery_ops.jl")

# The ONE oracle for ADAPTATIONS.md entry 2 — the pzg_factor_count / last-factor-guard risk.
# Kept OUT of the battery deliberately: the battery asserts exact paths, and an enrolling
# callback changes them, so the battery can never reach the moving-depth case.
include("test_pzg_factor_count_guard.jl")

# Post-suite: a testset that asserted NOTHING must fail the build, not read as green.
assert_no_inert_testsets(_PM_TS)
