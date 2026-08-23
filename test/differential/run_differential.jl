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
using PathMaps

const _DIFF_DIR = @__DIR__
const PMT = PathMaps.PathMap

_mk(keys) = begin
    m = PMT{PathMaps.UnitVal}()
    for k in keys
        PathMaps.set_val_at!(m, Vector{UInt8}(codeunits(k)), PathMaps.UnitVal())
    end
    m
end

"Canonical rendering — MUST match `dump()` in gen_expected.rs exactly."
function _dump(m)
    z = PathMaps.read_zipper(m)
    v = String[]
    while PathMaps.zipper_to_next_val!(z)
        push!(v, String(copy(PathMaps.zipper_path(z))))
    end
    sort!(v)
    "[" * join(v, ",") * "] vc=" * string(PathMaps.val_count(m))
end

_b(s) = Vector{UInt8}(codeunits(s))

"""
    _anr(m) -> AbstractNodeRef

Our `wz_{join,meet,subtract}_into!` take an `AbstractNodeRef` where upstream's take a read zipper
(`wz.meet_into(&src.read_zipper(), prune)`). Different API SHAPE, same operation — so the scenario
must adapt rather than the semantics. Mirrors how test/runtests.jl:277-281 builds one.
"""
_anr(m) =
    if m.root === nothing
        PathMaps.ANRNone{PathMaps.UnitVal, PathMaps.GlobalAlloc}()
    else
        PathMaps.ANRBorrowedRc{PathMaps.UnitVal, PathMaps.GlobalAlloc}(m.root)
    end

"Run every scenario; return name => result string."
function differential_results()
    out = Dict{String, String}()

    # ---- path_exists_at ---------------------------------------------------
    m = _mk(["abc", "abcdefghij"])
    for p in ["a", "ab", "abc", "abcd", "abcdefghi", "abcdefghij", "abz", "abcx", ""]
        nm = "path_exists_at/" * (isempty(p) ? "<empty>" : p)
        out[nm] = string(PathMaps.path_exists_at(m, _b(p)))
    end
    empty_map = PMT{PathMaps.UnitVal}()
    out["path_exists_at/empty_map_empty_path"] = string(
        PathMaps.path_exists_at(empty_map, UInt8[])
    )
    out["path_exists_at/empty_map_some_path"] = string(
        PathMaps.path_exists_at(empty_map, _b("a"))
    )
    rootonly = PMT{PathMaps.UnitVal}()
    PathMaps.set_val_at!(rootonly, UInt8[], PathMaps.UnitVal())
    out["path_exists_at/rootval_empty_path"] = string(
        PathMaps.path_exists_at(rootonly, UInt8[])
    )
    out["path_exists_at/rootval_some_path"] = string(
        PathMaps.path_exists_at(rootonly, _b("a"))
    )

    key16 = "zzzzzzzzzzzzzzzz"
    m2 = _mk([key16])
    out["path_exists_at/16z_prefixes"] = join([
        PathMaps.path_exists_at(m2, _b(key16)[1:n]) ? "T" : "F" for n in 1:16
    ])

    # ---- basic ------------------------------------------------------------
    out["basic/mk_three"] = _dump(_mk(["a", "ab", "abc"]))
    out["basic/empty"] = _dump(PMT{PathMaps.UnitVal}())
    m = _mk(["k1", "k2", "k3"])
    PathMaps.remove_val_at!(m, _b("k2"), false)
    out["basic/remove_noprune"] = _dump(m)
    m = _mk(["k1", "k2", "k3"])
    PathMaps.remove_val_at!(m, _b("k2"), true)
    out["basic/remove_prune"] = _dump(m)

    # ---- graft / algebra at a NON-ROOT focus ------------------------------
    a = _mk(["p", "px", "q"])
    src = _mk(["y"])
    let wz = PathMaps.write_zipper_at_path(a, _b("p"))
        PathMaps.wz_graft_map!(wz, src)
    end
    out["graft/graft_map_at_p"] = _dump(a)

    a = _mk(["p", "px", "q"])
    src = _mk(["x"])
    let wz = PathMaps.write_zipper_at_path(a, _b("p"))
        PathMaps.wz_meet_into!(wz, _anr(src), false, src.root_val)
    end
    out["graft/meet_into_at_p"] = _dump(a)

    a = _mk(["p", "px", "q"])
    src = PMT{PathMaps.UnitVal}()
    PathMaps.set_val_at!(src, UInt8[], PathMaps.UnitVal())
    let wz = PathMaps.write_zipper_at_path(a, _b("p"))
        PathMaps.wz_subtract_into!(wz, _anr(src), false, src.root_val)
    end
    out["graft/subtract_into_rootval_at_p"] = _dump(a)

    a = _mk(["px", "py", "q"])
    src = _mk(["y"])
    let wz = PathMaps.write_zipper_at_path(a, _b("p"))
        PathMaps.wz_join_into!(wz, _anr(src))
    end
    out["graft/join_into_at_p"] = _dump(a)

    # ---- graft_root_vals: DISCRIMINATING cases ----------------------------
    # The three failing graft scenarios above all have the focus value PRESENT and the source
    # root value ABSENT, so they cannot distinguish "we ignore the focus value" from "we clear
    # it". These pin the other direction and the ops the first set never reaches.
    a = _mk(["px", "q"])
    src = PMT{PathMaps.UnitVal}()
    PathMaps.set_val_at!(src, UInt8[], PathMaps.UnitVal())
    PathMaps.set_val_at!(src, _b("y"), PathMaps.UnitVal())
    let wz = PathMaps.write_zipper_at_path(a, _b("p"))
        PathMaps.wz_graft_map!(wz, src)
    end
    out["graft/graft_map_rootval_sets_focus"] = _dump(a)

    # join_map_into HAS a graft_root_vals block upstream (write_zipper.rs:1682); `join_into`
    # does NOT — so `graft/join_into_at_p` passing says nothing about this one.
    a = _mk(["px", "q"])
    src = PMT{PathMaps.UnitVal}()
    PathMaps.set_val_at!(src, UInt8[], PathMaps.UnitVal())
    let wz = PathMaps.write_zipper_at_path(a, _b("p"))
        PathMaps.wz_join_map_into!(wz, src)
    end
    out["graft/join_map_into_rootval_at_p"] = _dump(a)

    # CONTROL: join must NOT clear the focus value when the source root has none.
    a = _mk(["p", "px", "q"])
    src = _mk(["y"])
    let wz = PathMaps.write_zipper_at_path(a, _b("p"))
        PathMaps.wz_join_map_into!(wz, src)
    end
    out["graft/join_map_into_keeps_focus_val"] = _dump(a)

    # take_map at a focus holding ONLY a value: upstream moves it into the returned map's
    # root_val and returns a map even with no root node.
    a = _mk(["p", "q"])
    taken = let wz = PathMaps.write_zipper_at_path(a, _b("p"))
        PathMaps.wz_take_map!(wz, false)
    end
    out["graft/take_map_valonly_taken"] = taken === nothing ? "None" : _dump(taken)
    out["graft/take_map_valonly_residue"] = _dump(a)

    # ---- algebra at ROOT --------------------------------------------------
    a = _mk(["a", "b"])
    b = _mk(["b", "c"])
    let wz = PathMaps.write_zipper(a)
        PathMaps.wz_join_into!(wz, _anr(b))
    end
    out["algebra/join_root"] = _dump(a)

    a = _mk(["a", "b", "c"])
    b = _mk(["b", "c", "d"])
    let wz = PathMaps.write_zipper(a)
        PathMaps.wz_meet_into!(wz, _anr(b), false)
    end
    out["algebra/meet_root"] = _dump(a)

    a = _mk(["a", "b", "c"])
    b = _mk(["b"])
    let wz = PathMaps.write_zipper(a)
        PathMaps.wz_subtract_into!(wz, _anr(b), false)
    end
    out["algebra/subtract_root"] = _dump(a)

    # ---- the Option<V> blanket-impl boundary --------------------------------
    # `a` has a CHILD at "a" but NO VALUE there; `b` HAS a value at "a". Both ops then drive
    # `Ring.jl`'s `Union{Nothing,V}` blanket with a === nothing and b !== nothing — the branch
    # upstream's own `option_subtract_test` never asserts (its left side is always `Some(..)`) and
    # that NONE of the previous 42 fixtures reached. Added 2026-08-23 with real upstream output.
    a = _mk(["ab"])
    b = _mk(["a"])
    let wz = PathMaps.write_zipper(a)
        PathMaps.wz_subtract_into!(wz, _anr(b), false)
    end
    out["algebra/subtract_val_absent"] = _dump(a)

    a = _mk(["ab"])
    b = _mk(["a"])
    let wz = PathMaps.write_zipper(a)
        PathMaps.wz_meet_into!(wz, _anr(b), false)
    end
    out["algebra/meet_val_absent"] = _dump(a)

    # The SAME boundary on a DENSE node — the only place CoFreeEntry pairs are subtracted/met
    # field-by-field. The two fixtures above use a single 2-byte key, which path-compresses to a
    # LineListNode and never enters `_cf_psubtract`/`_cf_pmeet` at all: a fixture that cannot reach
    # the branch cannot catch the bug in it. 300 flat 2-byte keys force a DenseByteNode root whose
    # entry for 'a' has CHILDREN BUT NO VALUE, while `b` has a VALUE at "a" and no children.
    _dense = [string(Char(0x61 + i ÷ 26)) * string(Char(0x61 + i % 26)) for i in 0:299]

    a = _mk(_dense)
    b = _mk(["a"])
    let wz = PathMaps.write_zipper(a)
        PathMaps.wz_subtract_into!(wz, _anr(b), false)
    end
    out["algebra/subtract_dense_val_absent"] = _dump(a)

    a = _mk(_dense)
    b = _mk(["a"])
    let wz = PathMaps.write_zipper(a)
        PathMaps.wz_meet_into!(wz, _anr(b), false)
    end
    out["algebra/meet_dense_val_absent"] = _dump(a)

    # ---- prefix ops -------------------------------------------------------
    m = _mk(["foo:bar"])
    let wz = PathMaps.write_zipper_at_path(m, _b("foo:"))
        PathMaps.wz_insert_prefix!(wz, _b("ns:"))
    end
    out["prefix/insert_prefix_at_foo"] = _dump(m)

    m = _mk(["foo:bar", "foo:baz"])
    let wz = PathMaps.write_zipper_at_path(m, _b("foo:"))
        PathMaps.wz_remove_prefix!(wz, 1)
    end
    out["prefix/remove_prefix_at_foo"] = _dump(m)

    # `remove_prefix` is a faithful 3-liner on both sides; the divergence is in ASCEND's clamp.
    # Upstream `at_root()` is `prefix_buf.len() <= origin_path.len()` (write_zipper.rs:1002), so
    # a zipper created AT `foo:` is already at its origin and cannot ascend. The RETURN VALUE is
    # the direct observable of that clamp.
    m = _mk(["foo:bar", "foo:baz"])
    ret_at_origin = let wz = PathMaps.write_zipper_at_path(m, _b("foo:"))
        PathMaps.wz_remove_prefix!(wz, 1)
    end
    out["prefix/remove_prefix_ret_at_origin"] = string(ret_at_origin)

    # CONTROL: from a zipper rooted at the MAP root and descended to `foo:`, the focus is BELOW
    # its origin, so ascend may move and the removal must happen. Stops a clamp fix from
    # over-correcting into "ascend never moves".
    m = _mk(["foo:bar", "foo:baz"])
    ret_below_origin = let wz = PathMaps.write_zipper(m)
        PathMaps.wz_descend_to!(wz, _b("foo:"))
        PathMaps.wz_remove_prefix!(wz, 1)
    end
    out["prefix/remove_prefix_below_origin"] = _dump(m)
    out["prefix/remove_prefix_below_origin_ret"] = string(ret_below_origin)

    # MORK's test/integration/pathmap_prefix_ops.jl "remove_prefix — full ascent to root"
    # asserts this returns true and strips `pre:`. Same at-origin case, n == origin length.
    m = _mk(["pre:alpha", "pre:beta"])
    ret_full_ascent = let wz = PathMaps.write_zipper_at_path(m, _b("pre:"))
        PathMaps.wz_remove_prefix!(wz, 4)
    end
    out["prefix/remove_prefix_full_ascent_at_origin"] = _dump(m)
    out["prefix/remove_prefix_full_ascent_at_origin_ret"] = string(ret_full_ascent)

    # OVER-ASCENT: a correct `at_root` check still does not bound a SINGLE jump. Upstream caps
    # each one with `excess_key_len()` (origin-relative, write_zipper.rs:1048/:2666); capping with
    # `node_key` length (root_key_start-relative) lets one jump cross the origin.
    m = _mk(["foo:bar"])
    ret_over = let wz = PathMaps.write_zipper_at_path(m, _b("foo:"))
        PathMaps.wz_descend_to!(wz, _b("bar"))
        r = PathMaps.wz_ascend!(wz, 5)
        PathMaps.wz_set_val!(wz, PathMaps.UnitVal())
        r
    end
    out["ascend/over_ascend_ret"] = string(ret_over)
    out["ascend/over_ascend_then_setval"] = _dump(m)

    # ---- deep / COW -------------------------------------------------------
    out["deep/long_common_prefix"] = _dump(_mk([repeat("d", 12) * string(i) for i in 0:7]))

    a = _mk(["s:1", "s:2"])
    snapshot = deepcopy(a)
    PathMaps.set_val_at!(a, _b("s:3"), PathMaps.UnitVal())
    out["cow/source_after_clone_write"] = _dump(snapshot)
    out["cow/target_after_clone_write"] = _dump(a)

    out
end

"Parse the vendored upstream ground truth."
function upstream_expected()
    exp = Dict{String, String}()
    for ln in eachline(joinpath(_DIFF_DIR, "expected", "upstream.tsv"))
        isempty(strip(ln)) && continue
        parts = split(ln, '\t'; limit=2)
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
