# jet_report.jl — JET static analysis over PathMap's write-zipper entry points.
#
# NOT part of the test suite, deliberately: JET's first load precompiles for ~8 MINUTES, which would
# dominate a suite that otherwise runs in ~3. Run it on demand:
#
#     cd PathMap && julia --project=. tools/jet_report.jl
#
# ⚠️ `JET.report_package(PathMap)` DOES NOT WORK HERE and will not be made to. It re-evaluates the
# package's top level through JuliaInterpreter and dies with `invalid redefinition of constant
# PathMap`, because the module and its principal struct share the name `PathMap` (the same collision
# `test/runtests.jl` aliases around with `const PM = PathMap.PathMap`). `report_call` on concrete
# entry points is used instead — narrower, but it analyses the code paths that actually run.
#
# ── WHAT THIS FOUND, 2026-08-01 (74 reports across 10 entry points) ──────────────────────────────
#
# Essentially all of them are one shape:
#
#     no matching method found `f(::Nothing)` (1/2 union split)
#
# arising because the node types store `Union{Nothing, T}` fields — `LineListNode.slot0/slot1`,
# `TrieNodeODRc`'s inner node — whose validity is carried by SEPARATE TAG BITS (`is_child_0`,
# `is_used_1`, …). A guard like
#
#     _lln_is_child(self, slot) || return AlgResNone()
#     self_onward_link = _lln_get_child(self, slot)      # into_child(n.slot0)
#
# is correct, but JET cannot correlate the tag bit with the field's type, so it splits the union and
# reports the `Nothing` branch. Checked by hand: the guards are present on the paths reported here.
#
# 🔴 DO NOT DISMISS THE WHOLE CLASS AS FALSE POSITIVES. Of the ten functions sampled, NINE genuinely
# have no `::Nothing` method, so any of them would be a hard MethodError if its guard were ever
# missing or wrong. The tenth, `node_is_empty`, HAS one — added reactively, and its own comment at
# src/nodes/EmptyNode.jl says why: "without it psubtract over a node with an empty child rc
# crashes". So this class has already produced one real crash in this codebase.
#
# REACHABILITY BOUND, measured rather than argued: the 3000-case differential corpus reports
# `errors=0`, and `fuzz_compare` counts a throw as a divergence rather than swallowing it. So none
# of these is reachable on the fuzzed surface. That surface is 12 ops and UNIT values only — it does
# not cover value-payload algebra, nor `restrict` / `join_k_path_into` / `graft_child_maps` /
# `meet_k_path_into` / `join_into_take`. Two real defects hid in exactly that gap this week.
#
# So: treat a NEW report here as worth investigating, and the existing ones as a known structural
# consequence of Nothing-unions guarded by tag bits — the honest fix for which is a typed slot
# representation, not scattering `f(::Nothing)` methods that would mask invariant violations.
using JET, PathMap

const P = PathMap.PathMap
const UV = PathMap.UnitVal
const GA = PathMap.GlobalAlloc

_b(s) = Vector{UInt8}(codeunits(s))
_mk(ks::Vector{String}) = begin
    m = P{UV}()
    for k in ks
        PathMap.set_val_at!(m, _b(k), UV())
    end
    m
end

const _TOTAL = Ref(0)

function _probe(name::String, f)
    r = f()
    n = length(JET.get_reports(r))
    _TOTAL[] += n
    println("\n### ", name, "  -> ", n, " report(s)")
    n > 0 && show(IOContext(stdout, :limit => false), r)
    nothing
end

# Entry points chosen to cover every algebra path plus the two prune sites fixed on 2026-08-01.
_probe("wz_restrict!", () -> (m = _mk(["aa", "ab", "b"]); s = _mk(["aa", "b"]);
    @report_call PathMap.wz_restrict!(PathMap.write_zipper(m),
                                      PathMap.ANRBorrowedRc{UV, GA}(s.root))))
_probe("wz_meet_into!", () -> (m = _mk(["aa", "b"]); s = _mk(["a", "b"]);
    @report_call PathMap.wz_meet_into!(PathMap.write_zipper(m),
                                       PathMap.ANRBorrowedRc{UV, GA}(s.root), true, s.root_val)))
_probe("wz_subtract_into!", () -> (m = _mk(["aa", "b"]); s = _mk(["a", "b"]);
    @report_call PathMap.wz_subtract_into!(PathMap.write_zipper(m),
                                           PathMap.ANRBorrowedRc{UV, GA}(s.root), true, s.root_val)))
_probe("wz_join_map_into!", () -> (m = _mk(["aa", "b"]); s = _mk(["a", "b"]);
    @report_call PathMap.wz_join_map_into!(PathMap.write_zipper(m), s)))
_probe("wz_graft_map!", () -> (m = _mk(["aa", "b"]); s = _mk(["a", "b"]);
    @report_call PathMap.wz_graft_map!(PathMap.write_zipper(m), s)))
_probe("wz_join_k_path_into!", () -> (m = _mk(["abc"]);
    @report_call PathMap.wz_join_k_path_into!(PathMap.write_zipper_at_path(m, _b("ab")), 5, true)))
_probe("wz_remove_val!", () -> (m = _mk(["aa", "ab"]);
    @report_call PathMap.wz_remove_val!(PathMap.write_zipper_at_path(m, _b("aa")), true)))
_probe("wz_take_map!", () -> (m = _mk(["aa", "ab"]);
    @report_call PathMap.wz_take_map!(PathMap.write_zipper_at_path(m, _b("a")), true)))
_probe("prestrict_dyn", () -> (m = _mk(["aa", "ab", "b"]); s = _mk(["aa", "b"]);
    @report_call PathMap.prestrict_dyn(PathMap.as_tagged(m.root), PathMap.as_tagged(s.root))))
_probe("_wz_prune_path_internal!", () -> (m = _mk(["abc"]);
    @report_call PathMap._wz_prune_path_internal!(PathMap.write_zipper_at_path(m, _b("ab")))))

println("\n=== TOTAL REPORTS: ", _TOTAL[], " (74 as of 2026-08-01 — see the header) ===")
