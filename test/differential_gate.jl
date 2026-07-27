# PathMap ⟷ upstream Rust differential — RATCHET.
#
# PathMap had no executable check against upstream until 2026-07-27. It was verified by paired
# READING, which cannot see a divergence in a function that is deliberately not a transliteration —
# and that is exactly where `path_exists_at` was wrong for months behind four green local
# assertions. MORK has had this kind of gate (281 probes) and every MORK bug found on 2026-07-27
# came from it. This is PathMap's equivalent.
#
# SEMANTICS (same as MORK/test/integration/conformance_gate.jl):
#   * a scenario listed in test/differential/EXPECTED_PASS.txt that stops matching upstream
#     -> FAILS, and is NAMED
#   * a scenario NOT listed that starts matching -> only logs, asking you to lock it in
# So it is green at the current fidelity level and can only tighten.
#
# Needs NO Rust toolchain: upstream's output is vendored at test/differential/expected/upstream.tsv.
# Regenerate it (after adding scenarios to BOTH sides) with:
#   cd test/differential/rust_probe && cargo run --release --bin gen_expected > ../expected/upstream.tsv
using Test

include(joinpath(@__DIR__, "differential", "run_differential.jl"))

@testset "PathMap differential (vs upstream Rust pathmap)" begin
    passing, total, missing_s, mism = Base.invokelatest(differential_compare)

    baseline = Set(
        filter(
            !isempty,
            map(strip, readlines(joinpath(@__DIR__, "differential", "EXPECTED_PASS.txt"))),
        ),
    )

    @info "PathMap differential" total passing = length(passing) baseline = length(baseline)

    # A scenario present in the vendored ground truth but not runnable here is INERT — it silently
    # checks nothing. Same failure mode as a .mm2 with no .expected in MORK's corpus (fixed 6e12d7d).
    isempty(missing_s) || @info "differential: scenarios in upstream.tsv with no Julia case" missing_s
    @test isempty(missing_s)

    regressed = sort!(collect(setdiff(baseline, passing)))
    isempty(regressed) || @info "differential REGRESSED — these matched upstream and no longer do" regressed
    @test isempty(regressed)

    improved = sort!(collect(setdiff(passing, baseline)))
    isempty(improved) ||
        @info "differential IMPROVED — add to test/differential/EXPECTED_PASS.txt to lock in" improved

    # The 5 known divergences are DELIBERATELY outside the baseline, not hidden: they are real
    # fidelity gaps to close (graft_root_vals family, empty-path existence, remove_prefix at a
    # non-root focus), each with upstream's answer recorded in expected/upstream.tsv.
    @test length(passing) >= length(baseline)
end
