#!/usr/bin/env julia
# tools/repl.jl — development REPL
#
# Interactive:
#   julia --project=. -i tools/repl.jl
#
# Scripted / CI — USE THE RUNNER, it is the only form that can fail:
#   tools/run_tests.sh              # whole suite, exits 0 green / 1 red
#   tools/run_tests.sh path/to.jl   # one file
#
# DO NOT use the form this header advertised until 2026-07-23:
#   printf 'include("test/runtests.jl")\n' | julia --project=. tools/repl.jl
# It NEVER RAN THE TESTS. Without `-i`, julia executes the script argument and never reads stdin, so
# the piped `include` is silently discarded — measured: 0 output lines, 0 test summaries, exit 0.
# Adding `-i` runs them but still always exits 0 (interactive mode swallows exceptions), so a suite
# ending `151 passed, 0 failed, 1 errored` still reported success. See tools/run_tests.sh.

try
    using Revise
catch
end

using PathMaps

const PM = PathMaps.PathMap

# ── Shortcuts ─────────────────────────────────────────────────────────────────

t(path=joinpath(@__DIR__, "..", "test", "runtests.jl")) = include(path)

# Quick map builder
function mkmap(pairs::Pair...)
    m = PM{Int}()
    for (k, v) in pairs
        set_val_at!(m, Vector{UInt8}(string(k)), v)
    end
    m
end

if isinteractive()
    println("PathMap v0.3.0 loaded.")
    println("  t()              — run full test suite")
    println("  mkmap(k=>v, ...) — build a test PathMap")
end
