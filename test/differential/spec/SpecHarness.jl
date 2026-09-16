# SpecHarness.jl — differential fuzzing of PathMaps against the Lean model (lean/PathMapsSpec).
#
#   include("PathMap/test/differential/spec/SpecHarness.jl")
#   r = SpecHarness.fuzz(2000; seed = 1)          # random programs, Julia vs `pathmaps-oracle --spec`
#   SpecHarness.report(r)                         # divergences grouped by (op, first differing field)
#
# The op table is generated from ops.toml (`julia PathMap/tools/gen_spec_ops.jl`), which also writes the
# model side; this file holds only what is Julia's own: the decoder/renderer (mirroring the model byte for
# byte), the adapters from our API's return conventions to the model's, the trace, and the driver.
#
# Designed to run inside the warm Revise session (the MettaJam :7702 server has PathMaps loaded): the
# Julia side runs in-process, and one resident Lean oracle serves all inputs over a pipe.
module SpecHarness

using PathMaps
using Random

const LEAN_DIR = normpath(joinpath(@__DIR__, "..", "..", "..", "lean"))
const ORACLE_BIN = joinpath(LEAN_DIR, ".lake", "build", "bin", "pathmaps-oracle")
const MAX_STEPS = 256
const DUMP_CAP = 64

# ── decoder (mirrors Fuzz.Dec in the model) ───────────────────────────────────────────────────────────
mutable struct Dec
    bytes::Vector{UInt8}
    pos::Int
end
Dec(bytes::Vector{UInt8}) = Dec(bytes, 1)

function dec_u8!(d::Dec)::Union{UInt8, Nothing}
    d.pos > length(d.bytes) && return nothing
    b = d.bytes[d.pos]
    d.pos += 1
    b
end
function dec_mod!(d::Dec, m::Int)::Union{Int, Nothing}
    b = dec_u8!(d)
    b === nothing ? nothing : (m == 0 ? 0 : Int(b) % m)
end
function dec_pathbyte!(d::Dec)::Union{UInt8, Nothing}
    b = dec_u8!(d)
    b === nothing ? nothing : UInt8(b % 4)
end
function dec_pathn!(d::Dec, n::Int)::Union{Vector{UInt8}, Nothing}
    p = UInt8[]
    for _ in 1:n
        b = dec_pathbyte!(d)
        b === nothing && return nothing
        push!(p, b)
    end
    p
end
function dec_path!(d::Dec, lim::Int = 6)::Union{Vector{UInt8}, Nothing}
    n = dec_mod!(d, lim)
    n === nothing ? nothing : dec_pathn!(d, n)
end

# ── rendering (mirrors Fuzz.hexPath / showVal / showBool / showByteOpt) ────────────────────────────────
hex_byte(b::UInt8)::String = string(b; base = 16, pad = 2)
hex_path(p::AbstractVector{UInt8})::String = isempty(p) ? "_" : join(hex_byte.(p))
show_val(::Nothing)::String = "-"
show_val(v::Integer)::String = string(v)
show_bool(b::Bool)::String = b ? "1" : "0"
show_byte_opt(::Nothing)::String = "-"
show_byte_opt(b::UInt8)::String = hex_byte(b)

# ── adapters: our API's return conventions -> the model's ─────────────────────────────────────────────
"Run a Bool-returning move; the model returns the byte moved to (the new last path byte), or nothing."
function sp_moved_byte(z, move)::Union{UInt8, Nothing}
    moved = move(z)
    p = zipper_path(z)
    moved && !isempty(p) ? p[end] : nothing
end

"Our `zipper_ascend!` returns Bool; the model returns the number of bytes actually ascended."
function sp_ascend!(z, n::Int)::Int
    before = length(zipper_path(z))
    zipper_ascend!(z, n)
    before - length(zipper_path(z))
end

"Our `ascend_until*` return Bool; the model returns the number of bytes ascended."
function sp_ascended(z, move)::Int
    before = length(zipper_path(z))
    move(z)
    before - length(zipper_path(z))
end

"A whole k-path walk, capped at 32 stops (mirrors Fuzz.kWalk)."
function sp_k_walk!(z, k::Int)::Vector{Vector{UInt8}}
    out = Vector{UInt8}[]
    zipper_descend_first_k_path!(z, k) || return out
    push!(out, collect(zipper_path(z)))
    while length(out) < 32 && zipper_to_next_k_path!(z, k)
        push!(out, collect(zipper_path(z)))
    end
    out
end

# ── state, trace ──────────────────────────────────────────────────────────────────────────────────────
mutable struct SpecState{Z}
    m0::PathMap{UInt64}
    m1::PathMap{UInt64}
    root1::Vector{UInt8}
    rz::Z                         # the read zipper
    out::Vector{String}
    step::Int
end

function fingerprint(z)::String
    string(hex_path(zipper_path(z)), " o", hex_path(zipper_origin_path(z)),
        " e", show_bool(zipper_path_exists(z)), " v", show_val(zipper_val(z)),
        " c", zipper_child_count(z), " n", zipper_val_count(z))
end

function emit!(st::SpecState, name::String, ret::String)
    push!(st.out, string(st.step, " ", name, " ret=", ret, " R=", fingerprint(st.rz)))
    st.step += 1
    nothing
end

"""
Every existing location at and below the map root, depth-first (= lexicographic), as `hex:val`.
Built ONLY from `child_mask` + `descend_to_byte` + `ascend_byte` on a fresh zipper, never from the
iteration primitives under test, so a traversal bug cannot hide itself in the final dump.
"""
function dump_map(m::PathMap{UInt64})::String
    z = read_zipper(m)
    lines = String[]
    function walk()
        length(lines) >= DUMP_CAP && return
        push!(lines, string(hex_path(zipper_path(z)), ":", show_val(zipper_val(z))))
        mask = zipper_child_mask(z)
        for b in 0x00:0xff
            length(lines) >= DUMP_CAP && return
            PathMaps.test_bit(mask, b) || continue
            zipper_descend_to_byte!(z, b)
            walk()
            zipper_ascend_byte!(z)
        end
    end
    walk()
    join(lines, ",")
end

function seed!(m::PathMap{UInt64}, d::Dec, n::Int)::Bool
    for _ in 1:n
        p = dec_path!(d)
        p === nothing && return false
        v = dec_u8!(d)
        v === nothing && return false
        set_val_at!(m, p, UInt64(v))
    end
    true
end

function create_root!(m::PathMap{UInt64}, r::Vector{UInt8})
    isempty(r) && return
    wz = write_zipper_at_path(m, r)
    wz_create_path!(wz)
    nothing
end

include("ops_generated.jl")

"Decode and run one input on PathMaps; the trace lines (same format as `pathmaps-oracle --spec`)."
function run_julia(bytes::Vector{UInt8})::Vector{String}
    d = Dec(bytes)
    m0 = PathMap{UInt64}()
    n0 = dec_mod!(d, 8); n0 === nothing && return ["EMPTY"]
    seed!(m0, d, n0) || return ["EMPTY"]
    m1 = PathMap{UInt64}()
    n1 = dec_mod!(d, 8); n1 === nothing && return ["EMPTY"]
    seed!(m1, d, n1) || return ["EMPTY"]
    r0 = dec_path!(d, 4); r0 === nothing && return ["EMPTY"]
    r1 = dec_path!(d, 4); r1 === nothing && return ["EMPTY"]
    create_root!(m0, r0)
    create_root!(m1, r1)
    st = SpecState(m0, m1, r1, read_zipper_at_path(m1, r1), String[], 0)
    while st.step < MAX_STEPS && spec_step!(st, d)
    end
    vcat(st.out, ["MAP0 " * dump_map(m0), "MAP1 " * dump_map(m1), "ROOT1 " * hex_path(r1)])
end

# ── the Lean oracle, resident ─────────────────────────────────────────────────────────────────────────
mutable struct Oracle
    proc::Base.Process
end

function Oracle()
    isfile(ORACLE_BIN) || error("build the model first: cd $LEAN_DIR && lake build")
    Oracle(open(`$ORACLE_BIN --server --spec`, "r+"))
end

function run_model(o::Oracle, bytes::Vector{UInt8})::Vector{String}
    println(o.proc, "run-input 5000 ", bytes2hex(bytes))
    flush(o.proc)
    lines = String[]
    while true
        l = readline(o.proc)
        startswith(l, "!") && (l == "!DONE" || error("oracle: $l"); break)
        push!(lines, l)
    end
    lines
end

Base.close(o::Oracle) = (println(o.proc, "quit"); close(o.proc))

# ── comparison and driver ─────────────────────────────────────────────────────────────────────────────
struct Divergence
    idx::Int
    bytes::Vector{UInt8}
    line::Int
    julia::String
    model::String
end

"""
Fingerprint fields to IGNORE when comparing, e.g. `Set(["n"])` while a known `val_count` defect would
otherwise mask every later difference in the same trace. Masking is applied to both sides identically.
"""
const IGNORE_FIELDS = Ref(Set{String}())

function normalize(l::String)::String
    isempty(IGNORE_FIELDS[]) && return l
    for f in IGNORE_FIELDS[]
        l = replace(l, Regex(" " * f * "\\S*") => " " * f * "*")
    end
    l
end

"Compare one input. `nothing` if the traces agree (after `IGNORE_FIELDS` masking)."
function compare(o::Oracle, bytes::Vector{UInt8}; idx::Int = 0)::Union{Divergence, Nothing}
    jl = try
        run_julia(bytes)
    catch e
        ["THROW " * replace(sprint(showerror, e), '\n' => ' ')[1:min(end, 200)]]
    end
    md = run_model(o, bytes)
    for i in 1:max(length(jl), length(md))
        a = normalize(get(jl, i, "<missing>"))
        b = normalize(get(md, i, "<missing>"))
        a == b || return Divergence(idx, bytes, i, a, b)
    end
    nothing
end

"Random programs: `n` inputs of `len` bytes, deterministic per (seed, index)."
function fuzz(n::Int; seed::Int = 1, len::Int = 64)::Vector{Divergence}
    o = Oracle()
    out = Divergence[]
    try
        for i in 1:n
            bytes = rand(Xoshiro(hash((seed, i))), UInt8, len)
            dv = compare(o, bytes; idx = i)
            dv === nothing || push!(out, dv)
        end
    finally
        close(o)
    end
    out
end

"The op name of a trace line (`<step> <name> ret=...`), or the line kind (MAP0/MAP1/ROOT1/THROW)."
line_kind(l::String) = (parts = split(l); length(parts) >= 2 && all(isdigit, parts[1]) ? parts[2] : parts[1])

"Group divergences by the op (or final-dump line) where they first differ."
function report(ds::Vector{Divergence}; examples::Int = 1)
    groups = Dict{String, Vector{Divergence}}()
    for dv in ds
        push!(get!(groups, line_kind(dv.model == "<missing>" ? dv.julia : dv.model), Divergence[]), dv)
    end
    for (k, v) in sort(collect(groups); by = kv -> -length(kv[2]))
        println(rpad(k, 26), length(v))
        for dv in v[1:min(end, examples)]
            println("    #", dv.idx, " line ", dv.line)
            println("      julia: ", dv.julia)
            println("      model: ", dv.model)
        end
    end
end

end # module
