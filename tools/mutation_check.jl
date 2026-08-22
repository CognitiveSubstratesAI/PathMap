# mutation_check.jl — is a branch actually COVERED, or does it just happen to pass?
#
#     cd PathMap && julia --project=. tools/mutation_check.jl
#
# Rewrites one operand-selection site at a time to always take `a`, re-runs the value-algebra probes,
# and reports whether the mutant DIES. A surviving mutant means nothing in the suite distinguishes
# the two versions — the site is untested however green the suite looks.
#
# This exists because that question came up for real: upstream `2683d7c` changed WHICH OPERAND's
# value survives a meet, we ported it, and under unit values NOTHING could tell the two versions
# apart. Reading the code cannot answer "is this covered"; mutating it can.
#
# ── WHY IT USES REVISE, AND WHY THAT NEEDED A GUARD ─────────────────────────────────────────────
# Cold, each mutation costs a full PathMap recompile (~60 s) and the run times out. Warm, with
# Revise reloading the edit in-process, it is ~1 s. But Revise's file watcher POLLS: writing the
# file and calling `Revise.revise()` immediately RACES, and the first version of this script did
# exactly that — every mutant "survived", including one already PROVEN covered. A warm harness that
# silently serves stale code reports total coverage and total non-coverage identically.
#
# Hence `CONTROL_LINE`: a site known to be covered, asserted to die. If it does not, the run is
# declared VOID rather than reported. Never trust a warm reload you have not proved is live.
#
# ⚠️ MUTATES A SOURCE FILE. It restores it in a `finally` and verifies byte-equality at the end;
# still, do not run it against a dirty working tree.
using Revise, PathMap

const REPO = normpath(joinpath(@__DIR__, ".."))
const TARGET = joinpath(REPO, "src/nodes/DenseByteNode.jl")
const CASES_FILE = joinpath(REPO, "test/test_value_algebra.jl")
const CONTROL_LINE = 432

include(joinpath(REPO, "test/differential/run_fuzz.jl"))

"""
Pull the probe scripts out of test_value_algebra.jl rather than keeping a second copy. A separate
probe directory would drift from the tests silently, and a mutation run against stale probes is
worse than none — it would report coverage the suite does not actually have.
"""
function probe_scripts()
    src = read(CASES_FILE, String)
    lo = findfirst("_VALUE_CASES", src)[1]
    hi = findfirst("@testset", src)[1]
    body = src[lo:hi]
    out = String[]
    for m in eachmatch(r"\"((?:[^\"\\]|\\.)*)\"", body)
        lit = m.captures[1]
        occursin("OP ", lit) || continue
        push!(out, unescape_string(lit))
    end
    out
end

const SCRIPTS = probe_scripts()
probe() = join([Base.invokelatest(fuzz_run_text, s) for s in SCRIPTS], "\n")

# (line, needle, mutation) — every operand selection in `_cf_combine_results`.
const MUTATIONS = [
    (413, "deepcopy((rm & SELF_IDENT) != 0 ? a.rec : b.rec)", "deepcopy(a.rec)"),
    (414, "deepcopy((vm & SELF_IDENT) != 0 ? a.val : b.val)", "deepcopy(a.val)"),
    (432, "deepcopy((vm & SELF_IDENT) != 0 ? a.val : b.val)", "deepcopy(a.val)"),
    (447, "deepcopy((rm & SELF_IDENT) != 0 ? a.rec : b.rec)", "deepcopy(a.rec)"),
    (455, "deepcopy((rec_res.mask & SELF_IDENT) != 0 ? a.rec : b.rec)", "deepcopy(a.rec)"),
    (463, "deepcopy((val_res.mask & SELF_IDENT) != 0 ? a.val : b.val)", "deepcopy(a.val)")
]

function main()
    println("probes extracted from test_value_algebra.jl: ", length(SCRIPTS))
    original = read(TARGET, String)
    baseline = probe()
    results = Tuple{Int, Bool}[]
    try
        for (lineno, needle, mutant) in MUTATIONS
            lines = split(original, '\n')
            if !occursin(needle, lines[lineno])
                println("  line $lineno  ANCHOR MISS — the file moved; update MUTATIONS")
                continue
            end
            lines[lineno] = replace(lines[lineno], needle => mutant)
            write(TARGET, join(lines, '\n'))
            sleep(1.0)          # let Revise's watcher see the write — see the header
            Revise.revise()
            killed = probe() != baseline
            push!(results, (lineno, killed))
            println("  line $(lpad(lineno, 3))  ",
                killed ? "KILLED   (covered)" : "SURVIVED (NOT covered)")
            write(TARGET, original)
            sleep(1.0)
            Revise.revise()
        end
    finally
        write(TARGET, original)
        sleep(1.0)
        Revise.revise()
    end

    idx = findfirst(r -> r[1] == CONTROL_LINE, results)
    if idx === nothing || !results[idx][2]
        println(
            "\n🔴 CONTROL (line $CONTROL_LINE) DID NOT DIE — Revise is serving STALE code. RESULTS VOID."
        )
    else
        println(
            "\n✅ control line $CONTROL_LINE killed — Revise is live, verdicts are trustworthy"
        )
        println("   covered     : ", [r[1] for r in results if r[2]])
        println("   NOT covered : ", [r[1] for r in results if !r[2]])
    end
    println("source restored byte-for-byte: ", read(TARGET, String) == original)
end

main()
