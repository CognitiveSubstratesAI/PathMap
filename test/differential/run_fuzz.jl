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
#   cd test/differential/rust_probe && cargo run --release --bin gen_fuzz -- 3000 > ../fuzz/expected.tsv
using PathMap

const _FUZZ_DIR = joinpath(@__DIR__, "fuzz")
const FPMT = PathMap.PathMap

_fb(s) = Vector{UInt8}(codeunits(s))

# ── VALUE TYPES ─────────────────────────────────────────────────────────────────────────────────
# The GENERATED corpus is unit-valued (see the header). `VT bits` selects `FBits` instead, and
# exists only for hand-written `--exec` scripts.
#
# `FBits` mirrors `Bits` in gen_fuzz.rs EXACTLY — same algebra, same identity masks. It lives in the
# probe harness rather than in PathMap so that both engines agree BY CONSTRUCTION and neither
# library's own (deliberately divergent) integer lattice is involved.
struct FBits
    b::UInt64
end

# Methods on PathMap's OWN generic functions, not local ones — in-package dispatch would not see
# local definitions.
PathMap.pjoin(a::FBits, b::FBits) = _fbits_ident(FBits(a.b | b.b), a, b)
PathMap.pmeet(a::FBits, b::FBits) = _fbits_ident(FBits(a.b & b.b), a, b)

function _fbits_ident(r::FBits, a::FBits, b::FBits)
    # NO annihilation when r.b == 0: an all-zero bitset is a live value, not an absent one.
    if r.b == a.b && r.b == b.b
        PathMap.AlgResIdentity(PathMap.SELF_IDENT | PathMap.COUNTER_IDENT)
    elseif r.b == a.b
        PathMap.AlgResIdentity(PathMap.SELF_IDENT)
    elseif r.b == b.b
        PathMap.AlgResIdentity(PathMap.COUNTER_IDENT)
    else
        PathMap.AlgResElement(r)
    end
end

function PathMap.psubtract(a::FBits, b::FBits)
    r = FBits(a.b & ~b.b)
    # NEVER sets COUNTER_IDENT — ring.rs:21 forbids a non-commutative op from setting bit 1.
    r.b == 0 ? PathMap.AlgResNone() :
    r.b == a.b ? PathMap.AlgResIdentity(PathMap.SELF_IDENT) : PathMap.AlgResElement(r)
end

_fparse_val(::Type{PathMap.UnitVal}, tok::AbstractString) =
    (isempty(tok) || error("unit script carries a value token `=$tok` — use `VT bits`");
     PathMap.UnitVal())
_fparse_val(::Type{FBits}, tok::AbstractString) =
    isempty(tok) ? FBits(0x1) : FBits(parse(UInt64, tok; base = 16))

_frender(::PathMap.UnitVal) = ""
_frender(v::FBits) = "=" * string(v.b; base = 16)

"Split `ab=5` into (\"ab\", \"5\"). Keys never contain `=` — the alphabet is `ab:`."
function _fsplit_key(tok::AbstractString)
    i = findfirst(==('='), tok)
    i === nothing ? (String(tok), "") : (String(tok[1:(i - 1)]), String(tok[(i + 1):end]))
end

"Canonical rendering — MUST match `dump()` in gen_fuzz.rs exactly."
function _fdump(m)
    z = PathMap.read_zipper(m)
    paths = String[]
    vals = String[]
    while PathMap.zipper_to_next_val!(z)
        push!(paths, String(copy(PathMap.zipper_path(z))))
        v = PathMap.zipper_val(z)
        push!(vals, v === nothing ? "" : _frender(v))
    end
    # ⚠️ SORT BY PATH, THEN RENDER. A rendered entry is `path=hex` under VT bits, and `=` (0x3d)
    # sorts above `:` (0x3a) but below `a`/`b`, so sorting rendered strings would reorder siblings
    # relative to path order. Both engines would still agree, but on a renderer artefact.
    ord = sortperm(paths)
    "[" * join((paths[i] * vals[i] for i in ord), ",") * "] vc=" * string(PathMap.val_count(m))
end

"Rust prints `AlgebraicStatus` with `{:?}`; match those spellings exactly."
function _fstatus(s)
    s == PathMap.ALG_STATUS_ELEMENT && return "Element"
    s == PathMap.ALG_STATUS_IDENTITY && return "Identity"
    s == PathMap.ALG_STATUS_NONE && return "None"
    string(s)
end

function _fmk(::Type{V}, keys::Vector{String}, rootval::Bool,
              rootval_tok::AbstractString = "") where {V}
    m = FPMT{V}()
    for k in keys
        (path, tok) = _fsplit_key(k)
        PathMap.set_val_at!(m, _fb(path), _fparse_val(V, tok))
    end
    rootval && PathMap.set_val_at!(m, UInt8[], _fparse_val(V, rootval_tok))
    m
end

# Our algebra ops take an AbstractNodeRef where upstream's take a read zipper; the source's ROOT
# VALUE therefore has to be threaded separately (see wz_meet_into!). Mirrors `_anr` in
# run_differential.jl.
_fanr(m::FPMT{V}) where {V} =
    m.root === nothing ? PathMap.ANRNone{V, PathMap.GlobalAlloc}() :
                         PathMap.ANRBorrowedRc{V, PathMap.GlobalAlloc}(m.root)

"""
    fuzz_cases() -> Dict{String,String}

Load the whole corpus from the single `fuzz/cases.txt`, split on `### <name>` headers.
ONE file rather than one per case: at 3000 cases the per-file layout meant 3000 git blobs and
12 MB of block overhead for 278 KB of content.
"""
function fuzz_cases()
    path = joinpath(_FUZZ_DIR, "cases.txt")
    d = Dict{String, String}()
    isfile(path) || return d
    name = ""
    buf = IOBuffer()
    for ln in eachline(path)
        if startswith(ln, "### ")
            isempty(name) || (d[name] = String(take!(buf)))
            name = strip(ln[5:end])
        else
            println(buf, ln)
        end
    end
    isempty(name) || (d[name] = String(take!(buf)))
    d
end

"""
Parse a generated script (TEXT) into a NamedTuple. Mirrors `parse()` in gen_fuzz.rs.

A NamedTuple rather than the old 6-tuple: the shape grew by three fields (`vt` and the two
root-value tokens) and positional unpacking at four call sites would silently mis-bind.
"""
function _fparse_text(text::AbstractString)
    a_keys = String[]; s_keys = String[]
    a_rootval = false; s_rootval = false
    a_rootval_tok = ""; s_rootval_tok = ""
    origin = "-"; ops = String[]; vt = ""
    for ln in split(text, '\n')
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
            length(rest) > 1 && (a_rootval_tok = String(rest[2]))
        elseif tag == "SROOTVAL"
            s_rootval = rest[1] == "1"
            length(rest) > 1 && (s_rootval_tok = String(rest[2]))
        elseif tag == "ORIGIN"
            origin = isempty(rest) ? "-" : String(rest[1])
        elseif tag == "OP"
            push!(ops, join(rest, " "))
        elseif tag == "VT"
            # ABORT on an unknown VT rather than falling through to unit. A silently-ignored
            # header would run the script under UnitVal, render every value as "", and have both
            # engines agree on a dump that tested nothing.
            vt = isempty(rest) ? "" : String(rest[1])
            vt in ("unit", "bits") || error("unknown VT `$vt` (expected `unit` or `bits`)")
        end
    end
    (; a_keys, a_rootval, a_rootval_tok, s_keys, s_rootval, s_rootval_tok, origin, ops, vt)
end

# Kept so callers holding a PATH (e.g. shrink.jl's temp-file probes) still work.
_fparse(path::AbstractString) = _fparse_text(read(path, String))
fuzz_run(path::AbstractString) = fuzz_run_text(read(path, String))

"""
Execute one case given its script TEXT; return `trace|dump`.

Dispatches on the script's `VT` header to a `V`-parameterised inner function. `VT` is absent from
every generated case, so the 3000-case corpus runs exactly the `UnitVal` path it always did.
"""
function fuzz_run_text(text::AbstractString)
    c = _fparse_text(text)
    c.vt == "bits" ? _fuzz_run(FBits, c) : _fuzz_run(PathMap.UnitVal, c)
end

function _fuzz_run(::Type{V}, c) where {V}
    (; a_keys, a_rootval, a_rootval_tok, s_keys, s_rootval, s_rootval_tok, origin, ops) = c
    _smk() = _fmk(V, s_keys, s_rootval, s_rootval_tok)
    a = _fmk(V, a_keys, a_rootval, a_rootval_tok)
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
            string(PathMap.wz_set_val!(wz, _fparse_val(V, arg)) !== nothing)
        elseif name == "REMOVEVAL"
            string(PathMap.wz_remove_val!(wz, arg == "1") !== nothing)
        elseif name == "GRAFTMAP"
            PathMap.wz_graft_map!(wz, _smk()); "-"
        elseif name == "JOINMAP"
            _fstatus(PathMap.wz_join_map_into!(wz, _smk()))
        elseif name == "MEET"
            s = _smk()
            _fstatus(PathMap.wz_meet_into!(wz, _fanr(s), arg == "1", s.root_val))
        elseif name == "SUB"
            s = _smk()
            _fstatus(PathMap.wz_subtract_into!(wz, _fanr(s), arg == "1", s.root_val))
        elseif name == "RESTRICT"
            # NOT emitted by the generator — `--exec` only, for hand-written scripts. `restrict` was
            # the one full algebra op with no differential coverage at all. Note it takes no `prune`
            # and no root value: upstream's `restrict(&read_zipper)` (write_zipper.rs:253) has
            # neither, so this deliberately does not thread `s.root_val` the way MEET/SUB do.
            s = _smk()
            _fstatus(PathMap.wz_restrict!(wz, _fanr(s)))
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
    cases = fuzz_cases()
    mism = Tuple{String, String, String}[]
    errs = Tuple{String, String}[]
    n = 0
    for ln in eachline(exp_path)
        isempty(strip(ln)) && continue
        n >= limit && break
        parts = split(ln, '\t'; limit = 2)
        length(parts) == 2 || continue
        name, want = String(parts[1]), String(parts[2])
        if !haskey(cases, name)
            push!(errs, (name, "case missing — expected.tsv and cases.txt are out of sync"))
            continue
        end
        n += 1
        got = try
            Base.invokelatest(fuzz_run_text, cases[name])
        catch e
            push!(errs, (name, sprint(showerror, e)))
            continue
        end
        got == want || push!(mism, (name, got, want))
    end
    (n, mism, errs)
end
