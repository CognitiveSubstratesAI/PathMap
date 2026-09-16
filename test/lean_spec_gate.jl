# PathMaps ⟷ Lean model (lean/PathMapsSpec) DIFFERENTIAL — RATCHET.
#
# 1000 random programs over 49 read / write / algebra operations (test/differential/spec/ops.toml),
# run in-process on PathMaps and on the resident `pathmaps-oracle --spec`. The model specifies the
# INTENDED behaviour of our port, so every divergence is a defect or a model error, attributed in
# docs/UPSTREAM_DELTA_2026-09-16.md. Same ratchet contract as fuzz_gate.jl:
#
#   * a program NOT in spec/KNOWN_DIVERGENT.tsv that diverges      -> FAILS, and is NAMED
#   * a listed program whose first divergence CHANGED class         -> FAILS (re-attribute it)
#   * a listed program that now matches                             -> only LOGS (remove its line)
#
# The list is keyed to the op-table version; regenerating ops.toml invalidates it (fails with a message).
# Regenerate after attributing: SpecHarness.write_known()   (in the warm session)
#
# Needs the Lean model built (`cd lean && lake build`). Without it the gate is a VISIBLE skip, not a pass.
using Test

include(joinpath(@__DIR__, "differential", "spec", "SpecHarness.jl"))

@testset "PathMaps vs Lean model (differential ratchet)" begin
    if !isfile(SpecHarness.ORACLE_BIN)
        @warn "Lean model not built — lean_spec_gate skipped" build = "cd $(SpecHarness.LEAN_DIR) && lake build"
        @test_skip false
    else
        ver, n, seed, known = SpecHarness.read_known()
        @test ver == SpecHarness.SPEC_VERSION
        if ver == SpecHarness.SPEC_VERSION
            now = Base.invokelatest(SpecHarness.gate_classes; n, seed)
            new = sort!([i for i in keys(now) if !haskey(known, i)])
            changed = sort!([i for i in keys(now) if haskey(known, i) && known[i] != now[i]])
            fixed = sort!([i for i in keys(known) if !haskey(now, i)])
            @info "PathMaps vs Lean model" programs = n divergent = length(now) known = length(known) new = length(new) changed = length(changed) now_matching = length(fixed)
            for i in new
                @error "NEW divergence — attribute it (replay the state), then fix or record" program = i class = now[i]
            end
            for i in changed
                @error "divergence class CHANGED — re-attribute" program = i was = known[i] now = now[i]
            end
            isempty(fixed) || @info "listed programs now match — remove them (SpecHarness.write_known())" programs = fixed
            @test isempty(new)
            @test isempty(changed)
        end
    end
end
