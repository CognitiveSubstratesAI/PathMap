# PathMap ⟷ upstream Rust DIFFERENTIAL.
#
# WHY THIS EXISTS: PathMap had no executable check against upstream. It was verified by paired
# READING (2026-06-26), which cannot see a divergence in a function that is deliberately not a
# transliteration — and that is exactly where `path_exists_at` was wrong for months while four
# local assertions stayed green (they only tested an exact hit and a total miss; the bug lived in
# the mid-edge prefix case between them). Reading verifies shape; only execution verifies behaviour.
#
# HOW IT WORKS (same model as MORK/test/conformance/):
#   * test/differential/rust_probe/  builds against the UPSTREAM Rust pathmap and prints
#     `SCENARIO<TAB>RESULT` for each case. Its stdout is vendored as expected/upstream.tsv,
#     so running the gate needs NO Rust toolchain.
#   * `SCENARIOS` below runs the identical cases in Julia.
#   * A scenario passes iff its string equals upstream's, byte for byte.
#   * EXPECTED_PASS.txt is a RATCHET: a listed scenario that stops matching FAILS and is named;
#     an unlisted one that starts matching only logs, asking you to lock it in.
#
# ADDING A SCENARIO: add it to gen_expected.rs AND here under the SAME name, regenerate
# expected/upstream.tsv, then add the name to EXPECTED_PASS.txt once it matches.
using PathMap

const _DIFF_DIR = @__DIR__
const PMT = PathMap.PathMap

_mk(keys) = begin
    m = PMT{PathMap.UnitVal}()
    for k in keys
        PathMap.set_val_at!(m, Vector{UInt8}(codeunits(k)), PathMap.UnitVal())
    end
    m
end

"Canonical rendering — MUST match `dump()` in gen_expected.rs exactly."
function _dump(m)
    z = PathMap.read_zipper(m)
    v = String[]
    while PathMap.zipper_to_next_val!(z)
        push!(v, String(copy(PathMap.zipper_path(z))))
    end
    sort!(v)
    "[" * join(v, ",") * "] vc=" * string(PathMap.val_count(m))
end

_b(s) = Vector{UInt8}(codeunits(s))

"""
    _anr(m) -> AbstractNodeRef

Our `wz_{join,meet,subtract}_into!` take an `AbstractNodeRef` where upstream's take a read zipper
(`wz.meet_into(&src.read_zipper(), prune)`). Different API SHAPE, same operation — so the scenario
must adapt rather than the semantics. Mirrors how test/runtests.jl:277-281 builds one.
"""
_anr(m) = m.root === nothing ? PathMap.ANRNone{PathMap.UnitVal, PathMap.GlobalAlloc}() :
                               PathMap.ANRBorrowedRc{PathMap.UnitVal, PathMap.GlobalAlloc}(m.root)

"Run every scenario; return name => result string."
function differential_results()
    out = Dict{String, String}()

    # ---- path_exists_at ---------------------------------------------------
    m = _mk(["abc", "abcdefghij"])
    for p in ["a", "ab", "abc", "abcd", "abcdefghi", "abcdefghij", "abz", "abcx", ""]
        nm = "path_exists_at/" * (isempty(p) ? "<empty>" : p)
        out[nm] = string(PathMap.path_exists_at(m, _b(p)))
    end
    key16 = "zzzzzzzzzzzzzzzz"
    m2 = _mk([key16])
    out["path_exists_at/16z_prefixes"] =
        join([PathMap.path_exists_at(m2, _b(key16)[1:n]) ? "T" : "F" for n in 1:16])

    # ---- basic ------------------------------------------------------------
    out["basic/mk_three"] = _dump(_mk(["a", "ab", "abc"]))
    out["basic/empty"] = _dump(PMT{PathMap.UnitVal}())
    m = _mk(["k1", "k2", "k3"]); PathMap.remove_val_at!(m, _b("k2"), false)
    out["basic/remove_noprune"] = _dump(m)
    m = _mk(["k1", "k2", "k3"]); PathMap.remove_val_at!(m, _b("k2"), true)
    out["basic/remove_prune"] = _dump(m)

    # ---- graft / algebra at a NON-ROOT focus ------------------------------
    a = _mk(["p", "px", "q"]); src = _mk(["y"])
    let wz = PathMap.write_zipper_at_path(a, _b("p"))
        PathMap.wz_graft_map!(wz, src)
    end
    out["graft/graft_map_at_p"] = _dump(a)

    a = _mk(["p", "px", "q"]); src = _mk(["x"])
    let wz = PathMap.write_zipper_at_path(a, _b("p"))
        PathMap.wz_meet_into!(wz, _anr(src), false)
    end
    out["graft/meet_into_at_p"] = _dump(a)

    a = _mk(["p", "px", "q"])
    src = PMT{PathMap.UnitVal}(); PathMap.set_val_at!(src, UInt8[], PathMap.UnitVal())
    let wz = PathMap.write_zipper_at_path(a, _b("p"))
        PathMap.wz_subtract_into!(wz, _anr(src), false)
    end
    out["graft/subtract_into_rootval_at_p"] = _dump(a)

    a = _mk(["px", "py", "q"]); src = _mk(["y"])
    let wz = PathMap.write_zipper_at_path(a, _b("p"))
        PathMap.wz_join_into!(wz, _anr(src))
    end
    out["graft/join_into_at_p"] = _dump(a)

    # ---- algebra at ROOT --------------------------------------------------
    a = _mk(["a", "b"]); b = _mk(["b", "c"])
    let wz = PathMap.write_zipper(a)
        PathMap.wz_join_into!(wz, _anr(b))
    end
    out["algebra/join_root"] = _dump(a)

    a = _mk(["a", "b", "c"]); b = _mk(["b", "c", "d"])
    let wz = PathMap.write_zipper(a)
        PathMap.wz_meet_into!(wz, _anr(b), false)
    end
    out["algebra/meet_root"] = _dump(a)

    a = _mk(["a", "b", "c"]); b = _mk(["b"])
    let wz = PathMap.write_zipper(a)
        PathMap.wz_subtract_into!(wz, _anr(b), false)
    end
    out["algebra/subtract_root"] = _dump(a)

    # ---- prefix ops -------------------------------------------------------
    m = _mk(["foo:bar"])
    let wz = PathMap.write_zipper_at_path(m, _b("foo:"))
        PathMap.wz_insert_prefix!(wz, _b("ns:"))
    end
    out["prefix/insert_prefix_at_foo"] = _dump(m)

    m = _mk(["foo:bar", "foo:baz"])
    let wz = PathMap.write_zipper_at_path(m, _b("foo:"))
        PathMap.wz_remove_prefix!(wz, 1)
    end
    out["prefix/remove_prefix_at_foo"] = _dump(m)

    # ---- deep / COW -------------------------------------------------------
    out["deep/long_common_prefix"] = _dump(_mk([repeat("d", 12) * string(i) for i in 0:7]))

    a = _mk(["s:1", "s:2"])
    snapshot = deepcopy(a)
    PathMap.set_val_at!(a, _b("s:3"), PathMap.UnitVal())
    out["cow/source_after_clone_write"] = _dump(snapshot)
    out["cow/target_after_clone_write"] = _dump(a)

    out
end

"Parse the vendored upstream ground truth."
function upstream_expected()
    exp = Dict{String, String}()
    for ln in eachline(joinpath(_DIFF_DIR, "expected", "upstream.tsv"))
        isempty(strip(ln)) && continue
        parts = split(ln, '\t'; limit = 2)
        length(parts) == 2 && (exp[parts[1]] = parts[2])
    end
    exp
end

"Compare; return (passing, total, missing_scenarios, mismatches::Dict)."
function differential_compare()
    exp = upstream_expected()
    got = differential_results()
    passing = Set{String}()
    mism = Dict{String, Tuple{String, String}}()
    for (k, want) in exp
        if !haskey(got, k)
            continue                       # reported separately as missing
        elseif got[k] == want
            push!(passing, k)
        else
            mism[k] = (got[k], want)
        end
    end
    missing_s = sort!(collect(setdiff(keys(exp), keys(got))))
    (passing, length(exp), missing_s, mism)
end
