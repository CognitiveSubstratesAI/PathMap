# STRUCTURAL SHARING — is the trie actually a DAG?
#
# 🔴 WHY A COUNTING TEST AND NOT A RENDERED ONE. On 2026-08-24 the conclusion "this trie has no
# structural sharing" was read off `Viz.jl`'s ASCII output — and Viz's LOGICAL path-collapse was then
# shown (by building upstream with `--features viz` and diffing the same fixture) to misrepresent
# node structure: it splits a value-bearing branch node into duplicate siblings. A structural claim
# read off a renderer is only as good as the renderer. This test needs no renderer at all.
#
# 🔴 AND NO VALUE-LEVEL TEST CAN SEE THIS. `AlgebraicResult::Identity(mask)` returning the SAME node
# rather than an EQUAL one is what produces sharing; every answer-level assertion passes either way.
# A regression here — an arena increment that copies where it used to alias, say — would be invisible
# to the whole rest of the suite while silently multiplying memory.
#
# FIXTURE: upstream's own `logical_viz_4x4` (viz.rs:714), the diagram from the book's "Structural
# Sharing" intro. Graft a CLONE of each level under all 4 bytes of the next, four levels deep:
#   4^4 = 256 stored paths, but a DAG needs only ~4 distinct nodes — each level is ONE subtrie
#   referenced four times. An unshared trie would need a distinct node per position.
using Test, PathMaps

@testset "Structural sharing — the trie is a DAG" begin
    bytes = UInt8['a', 'b', 'c', 'd']

    l3 = PathMaps.PathMap{PathMaps.UnitVal}()
    for b in bytes
        PathMaps.set_val_at!(l3, UInt8[b], PathMaps.UNIT_VAL)
    end

    function graft_level(src)
        m = PathMaps.PathMap{PathMaps.UnitVal}()
        z = PathMaps.write_zipper(m)
        for b in bytes
            PathMaps.wz_reset!(z)
            PathMaps.wz_descend_to!(z, UInt8[b])
            PathMaps.wz_graft_map!(z, PathMaps._pm_clone(src))   # upstream's `l3_map.clone()`
        end
        m
    end
    l0 = graft_level(graft_level(graft_level(l3)))

    # `shared_node_id` is `objectid(rc.node)`, so distinct identities vs positions visited is the
    # whole measurement — two wrappers of the SAME physical node collapse to one id.
    # ⚠️ THIS WALK ONLY ENUMERATES SINGLE-BYTE-KEYED NODES. It descends via
    # `node_branches_mask(n, UInt8[])`, which returns nothing for a node carrying a MULTI-BYTE key —
    # measured 2026-08-24 on a 115k-fact trie, where the same walk reported positions=1, ids=1.
    # It is correct for THIS fixture (every level is keyed by one of a,b,c,d) and the assertions
    # below would FAIL LOUDLY rather than pass wrongly if that stopped holding. Do not reuse this
    # walk as a general node counter without handling multi-byte keys.
    ids = Set{UInt64}(); positions = Ref(0)
    function walk(rc, depth)
        depth > 12 && return
        n = PathMaps._rc_inner(rc)
        n === nothing && return
        positions[] += 1
        push!(ids, objectid(n))
        for b in PathMaps.node_branches_mask(n, UInt8[])
            r = PathMaps.node_get_child(n, UInt8[b])
            r === nothing && continue
            walk(r[2], depth + 1)
        end
    end
    walk(l0.root, 0)

    @test PathMaps.val_count(l0) == 256          # the fixture built what upstream's book states
    @test positions[] > 80                       # …and the walk really visited the whole structure
    @test length(ids) <= 8                        # MEASURED 2026-08-24: exactly 4
    sharing = positions[] / length(ids)
    @test sharing > 20.0                          # MEASURED: 21.25x
    # ⚠️ A DROP HERE IS THE REGRESSION, and the numbers above are deliberately loose around the
    # measured values so an ordinary refactor does not trip them while a COLLAPSE of sharing does.
    # If this fails, something started COPYING where it used to ALIAS — check `_pm_clone`,
    # `Base.copy(::TrieNodeODRc)`'s refcount bump, and `wz_graft_map!`.
end
