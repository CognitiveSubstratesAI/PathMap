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
function dec_bool!(d::Dec)::Union{Bool, Nothing}
    b = dec_u8!(d)
    b === nothing ? nothing : isodd(b)
end
"A byte set: `n := u8 % 4` path bytes, sorted and deduplicated (the model's `ByteMask.ofList`)."
function dec_mask!(d::Dec)::Union{Vector{UInt8}, Nothing}
    n = dec_mod!(d, 4)
    n === nothing && return nothing
    p = dec_pathn!(d, n)
    p === nothing ? nothing : sort!(unique(p))
end

# ── rendering (mirrors Fuzz.hexPath / showVal / showBool / showByteOpt) ────────────────────────────────
hex_byte(b::UInt8)::String = string(b; base = 16, pad = 2)
hex_path(p::AbstractVector{UInt8})::String = isempty(p) ? "_" : join(hex_byte.(p))
show_val(::Nothing)::String = "-"
show_val(v::Integer)::String = string(v)
show_bool(b::Bool)::String = b ? "1" : "0"
show_byte_opt(::Nothing)::String = "-"
show_byte_opt(b::UInt8)::String = hex_byte(b)
function show_status(s::PathMaps.AlgebraicStatus)::String
    s == ALG_STATUS_ELEMENT ? "Element" : s == ALG_STATUS_IDENTITY ? "Identity" : "None"
end
byte_mask(bs::Vector{UInt8})::ByteMask = foldl((m, b) -> ByteMask(PathMaps.with_bit_set(m.bits, b)), bs; init = ByteMask())

# ── adapters: one name per operation for BOTH zipper types (multiple dispatch) ────────────────────────
# Only operations the write zipper really has get a WriteZipperCore method; the rest are `wz_gap`
# in ops.toml, so a missing method is a listed gap rather than harness code standing in for our API.
const RZ = ReadZipperCore
const WZ = WriteZipperCore

sp_path(z::RZ) = path(z)
sp_path(z::WZ) = path(z)
sp_origin(z::RZ) = origin_path(z)
sp_origin(z::WZ) = z.prefix_buf
sp_exists(z::RZ) = path_exists(z)
sp_exists(z::WZ) = path_exists(z)
sp_val(z::RZ) = val(z)
sp_val(z::WZ) = val(z)
sp_child_count(z::RZ) = child_count(z)
sp_child_count(z::WZ) = child_count(z)
sp_val_count(z::RZ) = val_count(z)
sp_val_count(z::WZ) = val_count(z)

sp_descend_to!(z::RZ, p) = descend_to!(z, p)
sp_descend_to!(z::WZ, p) = descend_to!(z, p)
sp_descend_to_byte!(z::RZ, b) = descend_to_byte!(z, b)
sp_descend_to_byte!(z::WZ, b) = descend_to_byte!(z, b)
sp_ascend_byte!(z::RZ) = ascend_byte!(z)
sp_ascend_byte!(z::WZ) = ascend_byte!(z)
sp_reset!(z::RZ) = reset!(z)
sp_reset!(z::WZ) = reset!(z)
sp_descend_first_byte!(z::RZ) = descend_first_byte!(z)
sp_descend_first_byte!(z::WZ) = descend_first_byte!(z)
sp_descend_indexed_byte!(z::RZ, i) = descend_indexed_byte!(z, i)
sp_descend_indexed_byte!(z::WZ, i) = descend_indexed_byte!(z, i)
sp_to_next_sibling_byte!(z::RZ) = to_next_sibling_byte!(z)
sp_to_next_sibling_byte!(z::WZ) = to_next_sibling_byte!(z)
sp_to_prev_sibling_byte!(z::RZ) = to_prev_sibling_byte!(z)
sp_to_prev_sibling_byte!(z::WZ) = to_prev_sibling_byte!(z)

# ── adapters: our API's return conventions -> the model's ─────────────────────────────────────────────
# Since the 0.4.0 zipper-API port these are IDENTITIES: `ascend*` already return the byte count and the
# byte-moves already return `Union{Nothing,UInt8}`, exactly as the Lean model specifies.
sp_ascend!(z, n::Int)::Int = ascend!(z, n)
sp_moved_byte(z, move)::Union{UInt8, Nothing} = move(z)
sp_ascended(z, move)::Int = move(z)

"A whole k-path walk, capped at 32 stops (mirrors Fuzz.kWalk)."
function sp_k_walk!(z, k::Int)::Vector{Vector{UInt8}}
    out = Vector{UInt8}[]
    descend_first_k_path!(z, k) || return out
    push!(out, collect(path(z)))
    while length(out) < 32 && to_next_k_path!(z, k)
        push!(out, collect(path(z)))
    end
    out
end

# ── state, trace ──────────────────────────────────────────────────────────────────────────────────────
mutable struct SpecState{W, R}
    m0::PathMap{UInt64}           # written through wz
    m1::PathMap{UInt64}           # read through rz; the source of every graft / algebra op
    root0::Vector{UInt8}
    root1::Vector{UInt8}
    wz::W
    rz::R
    out::Vector{String}
    step::Int
    cur::Int                      # op code being run (for attributing a throw)
    phase::Symbol                 # :header, :op or :fingerprint (ditto)
end
SpecState(m0, m1, r0, r1, wz, rz) = SpecState(m0, m1, r0, r1, wz, rz, String[], 0, -1, :op)

function fingerprint(z)::String
    string(hex_path(sp_path(z)), " o", hex_path(sp_origin(z)),
        " e", show_bool(sp_exists(z)), " v", show_val(sp_val(z)),
        " c", sp_child_count(z), " n", sp_val_count(z))
end

function emit!(st::SpecState, name::String, ret::String)
    st.phase = :fingerprint
    push!(st.out, string(st.step, " ", name, " ret=", ret,
        " W=", fingerprint(st.wz), " R=", fingerprint(st.rz)))
    st.step += 1
    st.phase = :op
    nothing
end

# ── sources and focus snapshots, through our TrieRef API ──────────────────────────────────────────────
# Our algebra ops take an AbstractNodeRef where upstream's take a read zipper; the port's way to get the
# node (and value) at a read zipper's focus is a TrieRef at the same absolute path.
focus_map(st::SpecState, z::RZ) = st.m1
focus_map(st::SpecState, z::WZ) = st.m0
sp_focus_ref(st::SpecState, z, extra::Vector{UInt8} = UInt8[]) =
    trie_ref_at_path(focus_map(st, z), vcat(collect(sp_origin(z)), extra))
src_anr(st::SpecState, extra::Vector{UInt8} = UInt8[]) = get_focus(sp_focus_ref(st, st.rz, extra))
src_val(st::SpecState) = get_val(sp_focus_ref(st, st.rz))
src_map(st::SpecState) = make_map(sp_focus_ref(st, st.rz))

"""
Every existing location at and below the map root, depth-first (= lexicographic), as `hex:val`.
Built ONLY from `child_mask` + `descend_to_byte` + `ascend_byte` on a fresh zipper, never from the
iteration primitives under test, so a traversal bug cannot hide itself in the final dump.
"""
dump_map(m::PathMap{UInt64})::String = dump_walk(read_zipper(m))

"The subtrie at `z`'s focus, via a forked read zipper (the model's `dumpAt trie focus`)."
function sp_dump_focus(st::SpecState, z)::String
    t = sp_focus_ref(st, z)
    path_exists(t) || return "_:-"      # the model lists the (absent) focus itself only
    dump_walk(fork_read_zipper(t))
end

function dump_walk(z::RZ)::String
    lines = String[]
    function walk()
        length(lines) >= DUMP_CAP && return
        push!(lines, string(hex_path(path(z)), ":", show_val(val(z))))
        mask = child_mask(z)
        for b in 0x00:0xff
            length(lines) >= DUMP_CAP && return
            PathMaps.test_bit(mask, b) || continue
            descend_to_byte!(z, b)
            walk()
            ascend_byte!(z)
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
    create_path!(wz)
    nothing
end

include("ops_generated.jl")

"""
Decode and run one input on PathMaps; the trace lines (same format as `pathmaps-oracle --spec`).
A throw ends the trace with `THROW <phase> <op> <exception>` after the lines already emitted, so it
is compared at the step where it happened.
"""
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
    st = try
        create_root!(m0, r0)
        create_root!(m1, r1)
        SpecState(m0, m1, r0, r1, write_zipper_at_path(m0, r0), read_zipper_at_path(m1, r1))
    catch e
        return [throw_line("header", e, catch_backtrace())]
    end
    try
        while st.step < MAX_STEPS && spec_step!(st, d)
        end
        st.phase = :dump
        vcat(st.out, ["MAP0 " * dump_map(m0), "MAP1 " * dump_map(m1),
            "ROOT0 " * hex_path(r0), "ROOT1 " * hex_path(r1)])
    catch e
        where = st.phase == :dump ? "dump" : string(st.phase, " ", st.cur < 0 ? "-" : OP_NAMES[st.cur + 1])
        vcat(st.out, [throw_line(where, e, catch_backtrace())])
    end
end

"""
`THROW <where> <exception type> @<file>:<function> <message>` — the site is the innermost frame inside
PathMap's `src/`, so throws are grouped by where they happen, not by their message. Function, not line:
a class must survive unrelated edits to the file.
"""
function throw_line(where::String, e, bt)::String
    site = "?"
    for fr in stacktrace(bt)
        f = string(fr.file)
        if occursin("/PathMap/src/", f)
            site = string(basename(f), ":", fr.func)
            break
        end
    end
    msg = replace(sprint(showerror, e), '\n' => ' ')
    string("THROW ", where, " ", typeof(e).name.name, " @", site, " ", msg[1:min(end, 120)])
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
Fingerprint fields to IGNORE when comparing, as `"R.n"` (the read zipper's value count), `"W.c"`, or a
bare `"n"` for both zippers — e.g. while a known `val_count` defect would otherwise mask every later
difference in the same trace. Masking is applied to both sides identically.
"""
const IGNORE_FIELDS = Ref(Set{String}())

"Split a trace line into (head, W fingerprint, R fingerprint); a line without them is all head."
function split_line(l::AbstractString)
    iw = findfirst(" W=", l); ir = findfirst(" R=", l)
    (iw === nothing || ir === nothing) && return (String(l), "", "")
    (l[1:(first(iw) - 1)], l[(last(iw) + 1):(first(ir) - 1)], l[(last(ir) + 1):end])
end

mask_fp(fp::AbstractString, fields) =
    foldl((acc, f) -> replace(acc, Regex(" " * f * "\\S*") => " " * f * "*"), fields; init = String(fp))

function normalize(l::String)::String
    isempty(IGNORE_FIELDS[]) && return l
    head, w, r = split_line(l)
    isempty(w) && return l
    fw = [last(split(f, '.')) for f in IGNORE_FIELDS[] if !startswith(f, "R.")]
    fr = [last(split(f, '.')) for f in IGNORE_FIELDS[] if !startswith(f, "W.")]
    string(head, " W=", mask_fp(w, fw), " R=", mask_fp(r, fr))
end

"The first differing field of two trace lines: `ret`, `W.<f>`, `R.<f>`, `THROW …`, or the line kind."
function first_diff(a::String, b::String)::String
    startswith(a, "THROW") && return join(split(a)[[1, 2, 4, 5]], " ")
    startswith(b, "THROW") && return "model THROW"
    ha, wa, ra = split_line(a); hb, wb, rb = split_line(b)
    ha == hb || return (occursin("ret=", ha) ? "ret" : line_kind(a))
    for (tag, x, y) in (("W", wa, wb), ("R", ra, rb))
        x == y && continue
        tx = split(x); ty = split(y)
        i = findfirst(k -> get(tx, k, "") != get(ty, k, ""), 1:max(length(tx), length(ty)))
        i == 1 && return tag * ".path"
        return tag * "." * string(first(get(tx, i, get(ty, i, "?"))))
    end
    "?"
end

"Compare one input. `nothing` if the traces agree (after `IGNORE_FIELDS` masking)."
function compare(o::Oracle, bytes::Vector{UInt8}; idx::Int = 0)::Union{Divergence, Nothing}
    jl = run_julia(bytes)
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

"The class of a divergence: the op (or final line) where it first differs, and the first field."
divergence_class(dv::Divergence)::String =
    string(line_kind(dv.model == "<missing>" ? dv.julia : dv.model), "  ", first_diff(dv.julia, dv.model))

"Group divergences by class, largest first."
function classes(ds::Vector{Divergence})::Dict{String, Vector{Divergence}}
    groups = Dict{String, Vector{Divergence}}()
    for dv in ds
        push!(get!(groups, divergence_class(dv), Divergence[]), dv)
    end
    groups
end

function report(ds::Vector{Divergence}; examples::Int = 1)
    for (k, v) in sort(collect(classes(ds)); by = kv -> -length(kv[2]))
        println(rpad(k, 60), length(v))
        for dv in v[1:min(end, examples)]
            println("    #", dv.idx, " line ", dv.line)
            println("      julia: ", dv.julia)
            println("      model: ", dv.model)
        end
    end
end

# ── the known-divergence ratchet (test/lean_spec_gate.jl) ─────────────────────────────────────────────
# SEVERAL seeds: on 2026-09-17 seed 1 alone reported 0/1000 while seeds 2-6 still held 42 divergences.
const KNOWN_PATH = joinpath(@__DIR__, "KNOWN_DIVERGENT.tsv")
const GATE_N = 1000
const GATE_SEEDS = (1, 2, 3)

"The gate's population: (seed, program index) => divergence class (unmasked, first divergence only)."
function gate_classes(; n::Int = GATE_N, seeds = GATE_SEEDS)::Dict{Tuple{Int, Int}, String}
    IGNORE_FIELDS[] = Set{String}()
    out = Dict{Tuple{Int, Int}, String}()
    for seed in seeds
        for dv in fuzz(n; seed = seed)
            out[(seed, dv.idx)] = divergence_class(dv)
        end
    end
    out
end

"Read KNOWN_DIVERGENT.tsv -> (spec_version, n, seeds, Dict((seed, idx) => class))."
function read_known(path::String = KNOWN_PATH)
    ver = n = -1
    seeds = Int[]
    known = Dict{Tuple{Int, Int}, String}()
    for l in eachline(path)
        if startswith(l, "#")
            m = match(r"spec_version=(\d+) n=(\d+) seeds=([\d,]+)", l)
            if m !== nothing
                ver, n = parse(Int, m[1]), parse(Int, m[2])
                seeds = parse.(Int, split(m[3], ','))
            end
        elseif !isempty(strip(l))
            sd, i, c = split(l, '\t'; limit = 3)
            known[(parse(Int, sd), parse(Int, i))] = String(c)
        end
    end
    (ver, n, Tuple(seeds), known)
end

"""
    write_known(; n, seeds)

Regenerate KNOWN_DIVERGENT.tsv from the current port. Only after every new or changed class has been
attributed (replay the program, test the mechanism) and recorded in docs/UPSTREAM_DELTA_*.md.
"""
function write_known(path::String = KNOWN_PATH; n::Int = GATE_N, seeds = GATE_SEEDS)
    cls = gate_classes(; n, seeds)
    open(path, "w") do io
        println(io, "# KNOWN_DIVERGENT — PathMaps vs the Lean model (lean/PathMapsSpec), first divergence per program.")
        println(io, "# Generated by SpecHarness.write_known; gated by test/lean_spec_gate.jl. Attribution: docs/UPSTREAM_DELTA_2026-09-16.md.")
        println(io, "# Remaining `join_into` / `join_map_into` / `restrict` `ret` entries are upstream lean/FINDINGS.md #8: the")
        println(io, "# status is Element although the destination is unchanged (it depends on node shape) — ported as is.")
        println(io, "# spec_version=$(SPEC_VERSION) n=$(n) seeds=$(join(seeds, ','))")
        for k in sort!(collect(keys(cls)))
            println(io, k[1], '\t', k[2], '\t', cls[k])
        end
    end
    length(cls)
end

end # module
