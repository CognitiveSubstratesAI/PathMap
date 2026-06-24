# Reproducible profile of the `get_val_at` read hot path — drives the allocation-elimination work
# documented in docs/PERF_VS_UPSTREAM_2026-06-24.md. Uses BenchmarkTools (timing+allocs),
# @code_typed (allocation sites in the optimized IR), and Profile (statistical self-time ranking).
#
#   cd PathMap && julia --project=. benchmarks/profile_get_val.jl
#
# (BenchmarkTools is a dev-dependency / loadable from the shared depot.)

using PathMap, InteractiveUtils, Profile
const PM = PathMap
using BenchmarkTools

const CS = collect(UInt8, "abcdefghijklmnopqrstuvwxyz0123456789")
const M = PM.PathMap{Int32}()
let i = 0
    for c in 1:200, _ in 1:200
        i += 1
        PM.set_val_at!(M, vcat(Vector{UInt8}("cat" * lpad(string(c), 3, '0') * ":"), CS[rand(1:36, 8)]), Int32(i))
    end
end
const HIT = let kk = vcat(Vector{UInt8}("cat100:"), CS[rand(1:36, 8)]); PM.set_val_at!(M, kk, Int32(-1)); kk end
@assert PM.get_val_at(M, HIT) == Int32(-1)

println("=== 1. BenchmarkTools (rigorous time + allocs) ===")
b = @benchmark PM.get_val_at($M, $HIT)
show(stdout, MIME"text/plain"(), b); println()
println("  median=", round(median(b).time; digits=1), " ns | allocs=", b.allocs, " | memory=", b.memory, " B")

println("\n=== 2. @code_typed optimize=true — alloc/view/tuple IR statements ===")
let (ci, rt) = code_typed(PM.get_val_at, (typeof(M), Vector{UInt8}); optimize=true)[1]
    for (i, st) in enumerate(ci.code)
        s = replace(string(st), "\n" => " ")
        (occursin("new", s) || occursin("Memory", s) || occursin("tuple", s) ||
         occursin("view", s) || occursin("indexed_iterate", s)) && println("  [", i, "] ", first(s, 140))
    end
    println("  return type: ", rt)
end

profloop(m, k, n) = (s = Int32(0); for _ in 1:n; v = PM.get_val_at(m, k); s += (v === nothing ? Int32(0) : v); end; s)
println("\n=== 3. Profile flat (3e6 lookups) — top self-time frames ===")
profloop(M, HIT, 1); Profile.clear()
@profile profloop(M, HIT, 3_000_000)
Profile.print(format=:flat, sortedby=:count, mincount=100, maxdepth=40)
