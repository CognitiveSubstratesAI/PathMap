#!/usr/bin/env julia
# benchmarks/benchmarks.jl — PathMap performance benchmarks
#
# Mirrors the upstream Rust PathMap benchmark suite (cities, shakespeare,
# sparse/dense keys, algebraic ops, morphisms).
#
# Run:
#   julia --project=. benchmarks/benchmarks.jl
#   julia --project=. benchmarks/benchmarks.jl --tune   # longer calibration

using PathMap, BenchmarkTools

const SUITE = BenchmarkGroup()

# ── Construction ───────────────────────────────────────────────────────

SUITE["construction"] = BenchmarkGroup()

SUITE["construction"]["dense_keys_1k"] = @benchmarkable begin
    m = PathMap.PathMap{Nothing}()
    for i in 1:1000
        set_val_at!(m, Vector{UInt8}(string(i, pad=6)), nothing)
    end
end

SUITE["construction"]["sparse_keys_1k"] = @benchmarkable begin
    m = PathMap.PathMap{Nothing}()
    for i in 1:1000
        # Random-looking keys via hash — maximally sparse
        key = reinterpret(UInt8, [hash(i)])
        set_val_at!(m, key, nothing)
    end
end

# ── Word index (Shakespeare-style text) ───────────────────────────────

SUITE["word_index"] = BenchmarkGroup()

const _HAMLET_EXCERPT = """
to be or not to be that is the question whether tis nobler in the mind
to suffer the slings and arrows of outrageous fortune or to take arms
against a sea of troubles and by opposing end them to die to sleep no
more and by a sleep to say we end the heartache and the thousand natural
shocks that flesh is heir to tis a consummation devoutly to be wished
""" ^ 10   # repeat to get more data

function _build_word_map(text)
    m = PathMap.PathMap{Int}()
    for word in split(lowercase(text), r"\W+"; keepempty=false)
        k = Vector{UInt8}(word)
        v = get_val_at(m, k)
        set_val_at!(m, k, v === nothing ? 1 : v + 1)
    end
    m
end

const _WORD_MAP = _build_word_map(_HAMLET_EXCERPT)

SUITE["word_index"]["build"] = @benchmarkable _build_word_map($_HAMLET_EXCERPT)

SUITE["word_index"]["lookup_hit"] = @benchmarkable get_val_at($_WORD_MAP, b"question")

SUITE["word_index"]["lookup_miss"] = @benchmarkable get_val_at($_WORD_MAP, b"zzzmissing")

SUITE["word_index"]["iterate_all"] = @benchmarkable begin
    rz = read_zipper($_WORD_MAP)
    n = 0
    while zipper_to_next_val!(rz)

        n += 1
    end
    n
end

# ── Algebraic operations ───────────────────────────────────────────────

SUITE["algebra"] = BenchmarkGroup()

const _MAP_A = let m = PathMap.PathMap{Bool}()
    for w in split("alpha beta gamma delta epsilon zeta eta theta", " ")
        set_val_at!(m, Vector{UInt8}(w), true)
    end
    m
end

const _MAP_B = let m = PathMap.PathMap{Bool}()
    for w in split("beta delta zeta theta iota kappa lambda", " ")
        set_val_at!(m, Vector{UInt8}(w), true)
    end
    m
end

SUITE["algebra"]["union"] = @benchmarkable begin
    r = deepcopy($_MAP_A)
    wz = write_zipper(r)
    wz_join_map_into!(wz, $_MAP_B)
    r
end

SUITE["algebra"]["subtract"] = @benchmarkable begin
    r = deepcopy($_MAP_A)
    wz = write_zipper(r)
    wz_subtract_into!(wz, ANRBorrowedRc($_MAP_B.root))
    r
end

SUITE["algebra"]["policy_sum"] = @benchmarkable begin
    ma = PathMap.PathMap{Int}()
    mb = PathMap.PathMap{Int}()
    for w in split("alpha beta gamma delta", " ")
        set_val_at!(ma, Vector{UInt8}(w), 1)
        set_val_at!(mb, Vector{UInt8}(w), 2)
    end
    pjoin_policy(ma, mb, SumPolicy())
end

# ── Morphisms ──────────────────────────────────────────────────────────

SUITE["morphisms"] = BenchmarkGroup()

const _SHARED_MAP = let m = PathMap.PathMap{Int}()
    for i in 1:500
        set_val_at!(m, Vector{UInt8}("entry:$(lpad(i,4,'0'))"), i)
    end
    m
end

SUITE["morphisms"]["cata_cached_count"] = @benchmarkable cata_cached(
    $_SHARED_MAP,
    (mask, children, val) -> (val !== nothing ? 1 : 0) + reduce(+, children, init=0)
)

SUITE["morphisms"]["cata_side_effect_paths"] = @benchmarkable begin
    count = Ref(0)
    cata_side_effect(
        $_SHARED_MAP, (mask, ch, val, path) -> (val !== nothing && (count[] += 1); nothing)
    )
    count[]
end

SUITE["morphisms"]["map_hash"] = @benchmarkable map_hash($_SHARED_MAP)

# ── Serialization ──────────────────────────────────────────────────────

SUITE["serialization"] = BenchmarkGroup()

SUITE["serialization"]["serialize_500"] = @benchmarkable begin
    io = IOBuffer()
    serialize_paths($_SHARED_MAP, io)
    take!(io)
end

const _SERIALIZED = let io = IOBuffer()
    serialize_paths(_SHARED_MAP, io)
    take!(io)
end

SUITE["serialization"]["deserialize_500"] = @benchmarkable begin
    io = IOBuffer($_SERIALIZED)
    m = PathMap.PathMap{Int}()
    deserialize_paths(m, io, 0)
    m
end

# ── Run ────────────────────────────────────────────────────────────────

if abspath(PROGRAM_FILE) == @__FILE__
    println("PathMap Benchmarks")
    println("==================")
    println("Julia version: ", VERSION)
    println()

    tune = "--tune" in ARGS
    if tune
        println("Tuning (this may take a few minutes)...")
        tune!(SUITE)
    end

    results = run(SUITE; verbose=true, seconds=tune ? 10 : 3)

    println("\n=== Results ===")
    for (group, bgroup) in results
        println("\n[$group]")
        for (name, trial) in bgroup
            t = median(trial)
            println(
                "  $(rpad(name, 30)) $(BenchmarkTools.prettytime(t.time))  allocs=$(t.allocs)"
            )
        end
    end
end
