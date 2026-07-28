# DELTA-DEBUGGER for the PathMap differential fuzzer.
#
# A random 6-op program that diverges is a bug REPORT, not a diagnosis. This reduces each failing
# case to a MINIMAL still-failing program by repeatedly deleting parts and re-checking — deleting
# ops, then source/target keys, then the root-value flags.
#
# The oracle for a reduced program cannot be looked up (it was never generated), so it is asked
# for: `gen_fuzz --exec <dir>` executes arbitrary scripts against the upstream Rust and prints
# their answers. Candidates are written as a BATCH and executed in one process — a shrink pass
# issues thousands of queries and process spawn would otherwise dominate.
#
# Usage (needs the rustup toolchain — see run_fuzz.jl for the PATH incantation):
#   PMROOT=<pathmap> ./tools/run_tests.sh test/differential/shrink.jl   # args via SHRINK_N/SHRINK_SHAPE
#
# SHRINK_SHAPE filters which divergences to work on, by comparing the `vc=` counts:
#   fewer  we produce FEWER atoms than upstream -> we LOSE data, most likely OUR defect
#   more   we produce MORE  atoms -> we PRESERVE where upstream destroys (deviation class)
#   same   equal counts, different content
#   all    (default)
# Triaging by shape FIRST is what keeps a large corpus tractable: at 3000 cases the 81 divergences
# split 33 "more" / 24 "fewer" / 24 "same", and only the "fewer" group is unambiguously ours.
using PathMap
include(joinpath(@__DIR__, "run_fuzz.jl"))

const PROBE = joinpath(@__DIR__, "rust_probe")
const CARGO = joinpath(homedir(), ".rustup/toolchains/stable-x86_64-unknown-linux-gnu/bin")

"Render a case back to script text (must round-trip `_fparse`)."
function _emit(c)
    a_keys, a_rootval, s_keys, s_rootval, origin, ops = c
    io = IOBuffer()
    println(io, "A ", join(a_keys, " "))
    println(io, "AROOTVAL ", a_rootval ? 1 : 0)
    println(io, "S ", join(s_keys, " "))
    println(io, "SROOTVAL ", s_rootval ? 1 : 0)
    println(io, "ORIGIN ", origin)
    for op in ops
        println(io, "OP ", op)
    end
    String(take!(io))
end

"Ask upstream for the answers to a batch of candidate scripts: name => result."
function _upstream_batch(scripts::Dict{String, String})
    dir = mktempdir()
    for (name, text) in scripts
        write(joinpath(dir, name * ".txt"), text)
    end
    env = copy(ENV)
    env["PATH"] = CARGO * ":" * get(env, "PATH", "")
    out = try
        read(setenv(Cmd(`cargo run --release --quiet --bin gen_fuzz -- --exec $dir`;
                        dir = PROBE), env), String)
    catch e
        @warn "upstream exec failed" exception = e
        return Dict{String, String}()
    finally
        rm(dir; recursive = true, force = true)
    end
    res = Dict{String, String}()
    for ln in split(out, '\n')
        isempty(strip(ln)) && continue
        parts = split(ln, '\t'; limit = 2)
        length(parts) == 2 && (res[String(parts[1])] = String(parts[2]))
    end
    res
end

"Our answer for a case, or an `ERROR:` marker. A throw where upstream returns a value IS a
divergence, so it must be comparable, never skipped."
function _ours(text::String)
    p, io = mktemp()
    write(io, text); close(io)
    r = try
        Base.invokelatest(fuzz_run, p)
    catch e
        "ERROR: " * first(sprint(showerror, e), 80)
    finally
        rm(p; force = true)
    end
    r
end

"True iff this candidate still shows a divergence."
_diverges(text, want) = _ours(text) != want

"""
    shrink(case_tuple) -> (script, ours, upstream)

Greedy one-pass minimisation over three axes, cheapest first. Every candidate is re-pinned
against upstream — a reduced program has a DIFFERENT correct answer, so it is never assumed.
"""
function shrink(c0)
    cur = c0
    for _round in 1:4
        a_keys, a_rv, s_keys, s_rv, origin, ops = cur
        cands = Tuple{String, Any}[]
        for i in eachindex(ops)                       # drop one op
            push!(cands, ("op$i", (a_keys, a_rv, s_keys, s_rv, origin, deleteat!(copy(ops), i))))
        end
        for i in eachindex(a_keys)                    # drop one target key
            push!(cands, ("ak$i", (deleteat!(copy(a_keys), i), a_rv, s_keys, s_rv, origin, ops)))
        end
        for i in eachindex(s_keys)                    # drop one source key
            push!(cands, ("sk$i", (a_keys, a_rv, deleteat!(copy(s_keys), i), s_rv, origin, ops)))
        end
        a_rv && push!(cands, ("arv", (a_keys, false, s_keys, s_rv, origin, ops)))
        s_rv && push!(cands, ("srv", (a_keys, a_rv, s_keys, false, origin, ops)))
        isempty(cands) && break

        scripts = Dict(n => _emit(c) for (n, c) in cands)
        want = _upstream_batch(scripts)
        progressed = false
        for (n, c) in cands
            haskey(want, n) || continue
            if _diverges(scripts[n], want[n])
                cur = c
                progressed = true
                break                                  # greedy: restart from the smaller case
            end
        end
        progressed || break
    end
    text = _emit(cur)
    w = _upstream_batch(Dict("final" => text))
    (text, _ours(text), get(w, "final", "?"))
end

_vc(s) = (m = match(r"vc=(\d+)\s*$", s); m === nothing ? -1 : parse(Int, m.captures[1]))

"Classify a divergence by atom COUNT — cheap triage that needs no shrinking."
function _shape(ours, up)
    o = _vc(split(ours, '|')[end])
    u = _vc(split(up, '|')[end])
    o > u ? "more" : (o < u ? "fewer" : "same")
end

function main()
    maxc = parse(Int, get(ENV, "SHRINK_N", "6"))
    want = get(ENV, "SHRINK_SHAPE", "all")
    all_cases = fuzz_cases()
    n, mism, errs = fuzz_compare()
    sel = want == "all" ? mism : filter(m -> _shape(m[2], m[3]) == want, mism)
    failing = vcat([(nm, "mismatch") for (nm, _, _) in sel], [(nm, "error") for (nm, _) in errs])
    println("=== $(length(mism)) mismatches of $n | shape=$want -> $(length(sel)) | shrinking $maxc ===\n")
    for (name, kind) in first(failing, maxc)
        c0 = _fparse_text(all_cases[name])
        text, ours, up = shrink(c0)
        println("### $name  [$kind]  -> minimal:")
        for ln in split(strip(text), '\n')
            println("      ", ln)
        end
        println("    ours     : ", ours)
        println("    upstream : ", up)
        println()
    end
end

main()
