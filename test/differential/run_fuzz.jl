# PathMap ⟷ upstream Rust DIFFERENTIAL FUZZER — Julia side.
#
# Reads the SAME generated scripts the Rust probe executed (fuzz/cases/*.txt) and replays them
# here, comparing `trace|dump` byte for byte against fuzz/expected.tsv.
#
# WHY A SCRIPT FILE AND NOT A SHARED SEED: reproducing a random sequence identically on two
# runtimes would require Julia and Rust to agree on PRNG, integer wrapping and iteration order.
# That class of assumption has cost this project real time before, so the program is generated
# once (in gen_fuzz.rs), written down, and merely INTERPRETED on both sides. A divergence here is
# therefore always a divergence in PathMap, never in the harness.
#
# WHY HAND-WRITTEN SCENARIOS ARE NOT ENOUGH: `gen_expected.rs`'s 42 curated scenarios only test
# what somebody thought to write down. 12 added on 2026-07-27/28 exposed 4 real defects — a hit
# rate saying the population is far from drained. This searches instead of enumerating.
#
# ⚠️ VALUES ARE UNIT, DELIBERATELY. PathMap's port has a DOCUMENTED intentional divergence on
# integer lattices (src/core/Ring.jl, audit 2026-06-02) — upstream's `impl Lattice for u64` is a
# `//GOAT trash` placeholder returning Identity, ours implements real max/min. Fuzzing u64 values
# would report that by-design difference on nearly every merge and bury real findings.
# `impl Lattice for ()` is bit-exact on both sides. So this covers value PRESENCE/ABSENCE — which
# is what the whole `graft_root_vals` family turns on — but NOT value-payload algebra.
#
# Regenerate ground truth (needs the rustup toolchain; /usr/bin/cargo CANNOT build it):
#   export PATH="$HOME/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/bin:$PATH"
#   cd test/differential/rust_probe && cargo run --release --bin gen_fuzz -- 300 > ../fuzz/expected.tsv
using PathMap

const _FUZZ_DIR = joinpath(@__DIR__, "fuzz")
const FPMT = PathMap.PathMap

_fb(s) = Vector{UInt8}(codeunits(s))

"Canonical rendering — MUST match `dump()` in gen_fuzz.rs exactly."
function _fdump(m)
    z = PathMap.read_zipper(m)
    v = String[]
    while PathMap.zipper_to_next_val!(z)
        push!(v, String(copy(PathMap.zipper_path(z))))
    end
    sort!(v)
    "[" * join(v, ",") * "] vc=" * string(PathMap.val_count(m))
end

"Rust prints `AlgebraicStatus` with `{:?}`; match those spellings exactly."
function _fstatus(s)
    s == PathMap.ALG_STATUS_ELEMENT && return "Element"
    s == PathMap.ALG_STATUS_IDENTITY && return "Identity"
    s == PathMap.ALG_STATUS_NONE && return "None"
    string(s)
end

function _fmk(keys::Vector{String}, rootval::Bool)
    m = FPMT{PathMap.UnitVal}()
    for k in keys
        PathMap.set_val_at!(m, _fb(k), PathMap.UnitVal())
    end
    rootval && PathMap.set_val_at!(m, UInt8[], PathMap.UnitVal())
    m
end

# Our algebra ops take an AbstractNodeRef where upstream's take a read zipper; the source's ROOT
# VALUE therefore has to be threaded separately (see wz_meet_into!). Mirrors `_anr` in
# run_differential.jl.
_fanr(m) = m.root === nothing ? PathMap.ANRNone{PathMap.UnitVal, PathMap.GlobalAlloc}() :
                                PathMap.ANRBorrowedRc{PathMap.UnitVal, PathMap.GlobalAlloc}(m.root)

"Parse one generated script into (a_keys, a_rootval, s_keys, s_rootval, origin, ops)."
function _fparse(path::AbstractString)
    a_keys = String[]; s_keys = String[]
    a_rootval = false; s_rootval = false
    origin = "-"; ops = String[]
    for ln in eachline(path)
        isempty(ln) && continue
        parts = split(ln, ' ')
        tag = parts[1]
        rest = length(parts) > 1 ? filter(!isempty, parts[2:end]) : SubString{String}[]
        if tag == "A"
            a_keys = String.(rest)
        elseif tag == "S"
            s_keys = String.(rest)
        elseif tag == "AROOTVAL"
            a_rootval = rest[1] == "1"
        elseif tag == "SROOTVAL"
            s_rootval = rest[1] == "1"
        elseif tag == "ORIGIN"
            origin = isempty(rest) ? "-" : String(rest[1])
        elseif tag == "OP"
            push!(ops, join(rest, " "))
        end
    end
    (a_keys, a_rootval, s_keys, s_rootval, origin, ops)
end

"Execute one case; return `trace|dump`."
function fuzz_run(path::AbstractString)
    a_keys, a_rootval, s_keys, s_rootval, origin, ops = _fparse(path)
    a = _fmk(a_keys, a_rootval)
    trace = IOBuffer()
    wz = origin == "-" ? PathMap.write_zipper(a) :
                         PathMap.write_zipper_at_path(a, _fb(origin))
    for op in ops
        bits = split(op, ' ')
        name = bits[1]
        arg = length(bits) > 1 ? bits[2] : ""
        out = if name == "DESCEND"
            PathMap.wz_descend_to!(wz, _fb(arg)); "-"
        elseif name == "ASCEND"
            string(PathMap.wz_ascend!(wz, parse(Int, arg)))
        elseif name == "SETVAL"
            string(PathMap.wz_set_val!(wz, PathMap.UnitVal()) !== nothing)
        elseif name == "REMOVEVAL"
            string(PathMap.wz_remove_val!(wz, arg == "1") !== nothing)
        elseif name == "GRAFTMAP"
            PathMap.wz_graft_map!(wz, _fmk(s_keys, s_rootval)); "-"
        elseif name == "JOINMAP"
            _fstatus(PathMap.wz_join_map_into!(wz, _fmk(s_keys, s_rootval)))
        elseif name == "MEET"
            s = _fmk(s_keys, s_rootval)
            _fstatus(PathMap.wz_meet_into!(wz, _fanr(s), arg == "1", s.root_val))
        elseif name == "SUB"
            s = _fmk(s_keys, s_rootval)
            _fstatus(PathMap.wz_subtract_into!(wz, _fanr(s), arg == "1", s.root_val))
        elseif name == "TAKEMAP"
            t = PathMap.wz_take_map!(wz, arg == "1")
            t === nothing ? "None" : _fdump(t)
        elseif name == "INSPREFIX"
            string(PathMap.wz_insert_prefix!(wz, _fb(arg)))
        elseif name == "REMPREFIX"
            string(PathMap.wz_remove_prefix!(wz, parse(Int, arg)))
        elseif name == "RESET"
            PathMap.wz_reset!(wz); "-"
        else
            "?"
        end
        print(trace, out, ";")
    end
    String(take!(trace)) * "|" * _fdump(a)
end

"""
    fuzz_compare() -> (n_cases, mismatches::Vector{(name, ours, upstream)}, errors::Vector{(name, msg)})

An EXCEPTION is a divergence too — upstream returned a value where we threw — so it is reported,
never swallowed. (`wz_take_map!` threw a MethodError on its primary path for months; a harness
that treated a throw as "skip" would have hidden exactly that.)
"""
function fuzz_compare(; limit::Int=typemax(Int))
    exp_path = joinpath(_FUZZ_DIR, "expected.tsv")
    isfile(exp_path) || return (0, Tuple{String, String, String}[], Tuple{String, String}[])
    mism = Tuple{String, String, String}[]
    errs = Tuple{String, String}[]
    n = 0
    for ln in eachline(exp_path)
        isempty(strip(ln)) && continue
        n >= limit && break
        parts = split(ln, '\t'; limit = 2)
        length(parts) == 2 || continue
        name, want = String(parts[1]), String(parts[2])
        case = joinpath(_FUZZ_DIR, "cases", name * ".txt")
        if !isfile(case)
            push!(errs, (name, "case file missing — expected.tsv and cases/ are out of sync"))
            continue
        end
        n += 1
        got = try
            Base.invokelatest(fuzz_run, case)
        catch e
            push!(errs, (name, sprint(showerror, e)))
            continue
        end
        got == want || push!(mism, (name, got, want))
    end
    (n, mism, errs)
end
