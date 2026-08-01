# test_cow_k_path.jl — `wz_join_k_path_into!` must not write through a SHARED ANCESTOR.
#
# THE DEFECT (pre-existing; found 2026-08-01 by a randomized source/destination sweep, 204-206 of
# 800 cases). Every mutating write-zipper op calls `_wz_ensure_write_unique!` to copy-on-write the
# ancestor chain on `focus_stack` — set_val, remove_val, take_focus, remove_branches,
# remove_unmasked_branches. `wz_join_k_path_into!` did not, so a write reached a map SHARING those
# ancestors:
#
#     a = {":b"=>101, ":a"=>102};  ac = share(a)        # copy(root) -> refcount 2
#     z = write_zipper(a); descend ":"; wz_join_k_path_into!(z, 1, prune)
#       a  -> []    intended
#       ac -> []    *** THE SHARED CLONE WAS EMPTIED ***
#
# 🔴 THE DESCENT IS LOAD-BEARING, and it is why this survived the existing COW coverage. AT THE ROOT
# the shared node IS `focus_stack[1]`, so the op's own `make_unique!(focus_rc)` happens to cover it
# and nothing leaks. The suite's COW test at runtests.jl:639 shares a subtrie BELOW the focus and
# never descends past the shared node, so it could not see this.
#
# Same signature as the `write_zipper_at_path` hole fixed in `38dcfbd`: the node actually written has
# REFCOUNT 1 and the sharing is ONE LEVEL UP, so uniquifying the focus finds nothing to fork. Any fix
# framed as "make the focus unique" is looking at the wrong node.
#
# ⚠️ TWO COW STEPS, NEITHER REDUNDANT. `_wz_ensure_write_unique!` covers the STACK (ancestors);
# `make_unique!(focus_rc)` covers the FOCUS NODE, which is reached via `get_node_at_key` and is not
# on the stack at all. Removing either one reopens a different leak.
#
# Values are `Int` throughout: a `UnitVal` probe cannot tell "the clone kept its entries" from "the
# clone was rebuilt with different ones", and that ambiguity has already produced two false
# all-clear readings in this codebase.
using PathMap, Test

_b(s) = Vector{UInt8}(codeunits(s))

function _mk(pairs::Vector{Pair{String, Int}})
    m = PathMap.PathMap{Int}()
    for (k, v) in pairs
        PathMap.set_val_at!(m, _b(k), v)
    end
    m
end

"A second PathMap sharing `m`'s nodes by refcount — what `copy(root)` gives, and what MORK's
`read_btm` (Space.jl:1749) is."
_share(m) = PathMap.PathMap{Int, PathMap.GlobalAlloc}(
    m.root === nothing ? nothing : copy(m.root), m.root_val, m.alloc)

function _entries(m)
    z = PathMap.read_zipper(m)
    out = Tuple{String, Int}[]
    while PathMap.zipper_to_next_val!(z)
        push!(out, (String(copy(PathMap.zipper_path(z))), PathMap.zipper_val(z)))
    end
    sort(out)
end

@testset "join_k_path_into does not write through a shared ancestor" begin

    @testset "descended focus — the shape that leaked" begin
        for (k, prune) in ((1, true), (2, true), (1, false), (2, false))
            a = _mk([":b" => 101, ":a" => 102])
            ac = _share(a)
            before = _entries(ac)
            z = PathMap.write_zipper(a)
            PathMap.wz_descend_to!(z, _b(":"))
            PathMap.wz_join_k_path_into!(z, k, prune)
            @test (k, prune, _entries(ac)) == (k, prune, before)   # the clone is untouched
        end
    end

    @testset "the op still does its job — the target really changes" begin
        # Guards against a "fix" that makes the op a no-op, which would also leave the clone intact.
        a = _mk([":b" => 101, ":a" => 102])
        z = PathMap.write_zipper(a)
        PathMap.wz_descend_to!(z, _b(":"))
        PathMap.wz_join_k_path_into!(z, 1, true)
        @test _entries(a) == Tuple{String, Int}[]        # dropping 1 byte leaves nothing under ":"
    end

    @testset "at the ROOT — the control that localises it" begin
        # Never leaked: with no descent the shared node IS focus_stack[1]. Pinned so a future change
        # to the focus-vs-stack split shows up as a behaviour change rather than silently.
        a = _mk([":b" => 101, ":a" => 102])
        ac = _share(a)
        before = _entries(ac)
        PathMap.wz_join_k_path_into!(PathMap.write_zipper(a), 1, true)
        @test _entries(ac) == before
    end

    @testset "deeper descent, and a sibling that stays live" begin
        a = _mk(["x:b" => 1, "x:a" => 2, "y:q" => 3])
        ac = _share(a)
        before = _entries(ac)
        z = PathMap.write_zipper(a)
        PathMap.wz_descend_to!(z, _b("x:"))
        PathMap.wz_join_k_path_into!(z, 1, true)
        @test _entries(ac) == before
        @test PathMap.get_val_at(a, _b("y:q")) == 3      # the untouched branch survives in the target
    end

    @testset "meet_k_path — clean before and after, kept as the negative control" begin
        a = _mk([":b" => 101, ":a" => 102])
        ac = _share(a)
        before = _entries(ac)
        z = PathMap.write_zipper(a)
        PathMap.wz_descend_to!(z, _b(":"))
        PathMap.wz_meet_k_path_into!(z, 1, true)
        @test _entries(ac) == before
    end
end
