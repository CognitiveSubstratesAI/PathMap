# PathMap ⟷ upstream Rust DIFFERENTIAL FUZZ — RATCHET.
#
# 3000 randomly generated operation programs, each paired with the upstream Rust engine's own
# answer. Same ratchet contract as test/differential_gate.jl and MORK's conformance gate:
#
#   * a case NOT listed in fuzz/KNOWN_DIVERGENT.txt that stops matching -> FAILS, and is NAMED
#   * a listed case that starts matching                                -> only LOGS, asking you
#                                                                          to remove its line
#
# So it is green at today's fidelity and can only tighten. 2970 of 3000 currently match
# (the gate's own `@info` line prints this each run; the previous "2919" here was stale).
#
# WHY IT EXISTS. The 42 CURATED scenarios in test/differential/ only find what someone thought to
# write down; 12 added on 2026-07-27/28 yielded 4 real defects, a hit rate saying the population
# was nowhere near drained. Measured on one identical population, the fixes in PathMap 045a17b
# moved a 159-case subset from 46 mismatches + 19 crashes to 15 + 1. Every defect involved dated
# to the ORIGINAL port commit (e34ed80, 2026-04-24) — this is a pre-existing population being
# drained, not new breakage, and the fuzzer is what makes its SIZE visible instead of guessed.
#
# An EXCEPTION counts as a divergence, never a skip — `wz_take_map!` threw MethodError on its
# primary path for months, and a harness that treated a throw as "not applicable" would have
# hidden exactly that.
#
# Needs NO Rust toolchain: cases and upstream answers are vendored under test/differential/fuzz/.
# Regenerate (see run_fuzz.jl for why /usr/bin/cargo cannot do it):
#   export PATH="$HOME/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/bin:$PATH"
#   cd test/differential/rust_probe && cargo run --release --bin gen_fuzz -- 3000 > ../fuzz/expected.tsv
#
# CASE NUMBERING IS STABLE ACROSS COUNTS — verified 2026-07-28 by regenerating at 3000 and
# diffing the first 300 lines against the committed 300-case corpus: IDENTICAL. `gen_case` draws
# sequentially from the seeded stream, so case `i` depends only on the SEED, never on `n`. Growing
# the corpus is therefore PURELY ADDITIVE and preserves every KNOWN_DIVERGENT entry.
# ⚠️ Changing the SEED does reshuffle everything and invalidates KNOWN_DIVERGENT.txt wholesale.
# (An earlier version of this comment claimed the COUNT mattered too. It does not.)
#
# Minimise a failure to a 1-2 op reproducer with test/differential/shrink.jl (needs the toolchain).
using Test

include(joinpath(@__DIR__, "differential", "run_fuzz.jl"))

@testset "PathMap differential FUZZ (vs upstream Rust pathmap)" begin
    n, mism, errs = Base.invokelatest(fuzz_compare)

    known_path = joinpath(@__DIR__, "differential", "fuzz", "KNOWN_DIVERGENT.txt")
    known = isfile(known_path) ?
        Set(filter(!isempty, map(strip, readlines(known_path)))) : Set{String}()

    failing = Set{String}()
    for (nm, _, _) in mism
        push!(failing, nm)
    end
    for (nm, _) in errs
        push!(failing, nm)
    end

    @info "PathMap fuzz" cases = n matching = n - length(failing) known_divergent = length(known)

    # Zero cases would make every assertion below vacuously true — the corpus must be present.
    @test n > 0

    regressed = sort!(collect(setdiff(failing, known)))
    if !isempty(regressed)
        @info "fuzz REGRESSED — these matched upstream and no longer do" regressed
        for nm in first(regressed, 5)
            hit = findfirst(m -> m[1] == nm, mism)
            hit === nothing || @info "  $nm" ours = mism[hit][2] upstream = mism[hit][3]
        end
    end
    @test isempty(regressed)

    improved = sort!(collect(setdiff(known, failing)))
    isempty(improved) ||
        @info "fuzz IMPROVED — remove these from fuzz/KNOWN_DIVERGENT.txt to lock in" improved
end
