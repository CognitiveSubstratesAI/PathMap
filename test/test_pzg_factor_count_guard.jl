# test_pzg_factor_count_guard.jl — the ONE oracle for ADAPTATIONS.md entry 2.
#
# THE RECORDED RISK. Upstream PR #56 (143ecd1) made DependentProductZipperG's `secondary` a STACK
# popped in step with `factor_paths`, and DELETED `factor_count()` because `secondary.len() + 1` is
# then a MOVING DEPTH, not a count — its documented contract ("the number of factors … minimum 1")
# cannot hold. We RETAINED ours, because `ProductZipperG.jl` consumes it:
#
#     pzg_factor_count(prz) = length(prz.secondary) + 1 + _pzg_inner_factor_count(prz.primary)
#     _pzg_inner_factor_count(::PrefixZipper over DependentZipper) = dpz_factor_count(src) - 1
#                                                                 = length(src.secondary)   <-- LIVE
#
# and MORK guards on `pzg_focus_factor(prz) != pzg_factor_count(prz) - 1` (Space.jl:836) — a focus
# index compared against a total that MOVES. The path is live: CmpSource (the ==/!= source) builds
# exactly `PrefixZipper(prefix, DependentZipper(...))` at MORK Sources.jl:243-246.
#
# WHY THIS FILE EXISTS SEPARATELY FROM THE BATTERY. Upstream's conformance battery cannot reach it:
# the battery asserts exact paths, and a callback that actually ENROLLS changes those paths. So the
# battery runs with a non-enrolling callback, `secondary` stays empty, `factor_count` is pinned at 1,
# and the moving-depth case never occurs. This test enrolls on purpose.
#
# ── MEASURED RESULT (2026-08-03) ────────────────────────────────────────────────────────────────
# The mechanism IS real — `factor_count` takes values {2, 1} within a single walk. The guard is NOT
# wrong: `focus_factor` is derived from the same live state, so the two move together and
# `focus_factor < factor_count` holds at every step. The PrefixZipper layer is load-bearing to
# reproduce it at all: `_pzg_inner_factor_count` has a method for PrefixZipper only, so a BARE
# DependentZipper primary falls through to the generic `= 0` and factor_count cannot move.
#
# ⚠️ SCOPE. One shape: a single enrolled secondary, empty prefix. This REFUTES the specific
# "focus index vs moving total" concern for the CmpSource shape. It does not prove the guard correct
# for every composition — multiple simultaneous secondaries, or a non-empty prefix, are not covered.
using Test, PathMaps
const PMG = PathMaps.PathMap

@testset "pzg_factor_count moves, and focus_factor moves WITH it (ADAPTATIONS entry 2)" begin
    m = PMG{UnitVal}()
    for k in ("ax", "ay", "bx", "by")
        set_val_at!(m, Vector{UInt8}(k), UNIT_VAL)
    end
    ext = PMG{UnitVal}()
    for k in ("1", "2")
        set_val_at!(ext, Vector{UInt8}(k), UNIT_VAL)
    end

    # enrols only under "a…", so the dependent stack GROWS then SHRINKS during one walk
    enrolled = Ref(0)
    cb = function (payload, p::AbstractVector{UInt8}, factor_idx::Int)
        if length(p) == 2 && p[1] == UInt8('a')
            enrolled[] += 1
            return (payload, read_zipper(ext))
        end
        (payload, nothing)
    end

    dpz = PathMaps.DependentZipper(read_zipper(m), nothing, cb)
    pz = PathMaps.PrefixZipper(UInt8[], dpz)           # CmpSource's shape — load-bearing, see header
    prz = PathMaps.ProductZipperG(pz, PathMaps.ReadZipperCore{UnitVal, PathMaps.GlobalAlloc}[])

    counts = Set{Int}()
    steps = 0
    while PathMaps.pzg_to_next_val!(prz)
        steps += 1
        steps > 200 && break                            # cycle guard: the assertions below fail, not hang
        fc = PathMaps.pzg_factor_count(prz)
        ff = PathMaps.pzg_focus_factor(prz)
        push!(counts, fc)

        # THE GUARD'S PRECONDITION. MORK compares `ff != fc - 1` to mean "focus is in the last
        # factor"; that is only meaningful while ff indexes a real factor.
        @test ff < fc
        @test ff >= 0

        # upstream PR #56's invariant, on the dependent zipper underneath
        @test length(dpz.secondary) == length(dpz.factor_paths)
    end

    @test steps == 8                    # ax ax1 ax2 ay ay1 ay2 bx by
    @test enrolled[] > 0                # the callback actually fired — not a vacuous pass
    @test length(counts) > 1            # factor_count really did MOVE; the recorded risk is real
    @test counts == Set([1, 2])
end
