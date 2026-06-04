#!/usr/bin/env julia
# tools/repl.jl — development REPL
#
# Interactive:
#   julia --project=. -i tools/repl.jl
#
# Scripted:
#   printf 'include("test/runtests.jl")\n' | julia --project=. tools/repl.jl
#   printf 't()\n' | julia --project=. tools/repl.jl

try
    using Revise
catch
end

using PathMap

const PM = PathMap.PathMap

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
