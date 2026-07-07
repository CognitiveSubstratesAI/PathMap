# test/test_viz.jl — Viz (port of pathmap/src/viz.rs). Renders tries to Mermaid; the point is to make
# STRUCTURAL SHARING observable. Sharing constructions verified against upstream by the port review.
using PathMap, Test
const _PMv = PathMap.PathMap

@testset "Viz — Mermaid render + structural sharing" begin
    # ── basic render ────────────────────────────────────────────────────────
    m = _PMv{Int}()
    for (i, s) in enumerate(["roman", "romane", "romanus", "bow"])
        PathMap.set_val_at!(m, Vector{UInt8}(s), i)
    end
    out = PathMap.viz_maps([m]; ascii_path = true)   # → Mermaid String
    @test occursin("flowchart LR", out)
    @test occursin("shape: rect", out)               # node boxes
    @test occursin("shape: rounded", out)            # value boxes
    @test occursin("--\"", out)                      # at least one labeled edge

    # ── CROSS-MAP sharing: graft m1's root into m2 under "prefix:" ⇒ ONE physical
    #    node in both maps ⇒ rendered ONCE, colored by the two-map bitmask 0b011 = "#0aa".
    m1 = _PMv{Int}(); PathMap.set_val_at!(m1, b"hello", 42)
    m2 = _PMv{Int}()
    wz = PathMap.write_zipper(m2); PathMap.wz_descend_to!(wz, b"prefix:")
    PathMap.wz_graft_map!(wz, m1)
    @test PathMap.refcount(m1.root) == 2                                    # sharing is real
    shared_id = PathMap.shared_node_id(m1.root)
    node_in_m2 = PathMap.tr_get_focus_rc(PathMap.trie_ref_at_path(m2, b"prefix:"))
    @test PathMap.shared_node_id(node_in_m2) == shared_id                   # same object
    mmd = PathMap.viz_maps([m1, m2])
    @test count("g$(shared_id)@{ shape: rect", mmd) == 1                    # emitted once
    @test occursin("style g$(shared_id) fill:#0aa", mmd)                    # two-map sharing color

    # ── WITHIN-MAP sharing (ref_cnt>1 inside one map) ⇒ rendered once, map color (blue).
    mw = _PMv{Int}()
    PathMap.set_val_at!(mw, b"Sab", 1); PathMap.set_val_at!(mw, b"Scd", 2)
    src_anr = PathMap.tr_get_focus_anr(PathMap.trie_ref_at_path(mw, b"S"))
    wzg = PathMap.write_zipper(mw); PathMap.wz_descend_to!(wzg, b"D")
    PathMap.wz_graft!(wzg, src_anr)
    shared_rc = PathMap.tr_get_focus_rc(PathMap.trie_ref_at_path(mw, b"S"))
    @test PathMap.refcount(shared_rc) >= 2
    id_S = PathMap.shared_node_id(shared_rc)
    mmd2 = PathMap.viz_maps([mw])
    @test count("g$(id_S)@{ shape: rect", mmd2) == 1
    @test occursin("style g$(id_S) fill:blue", mmd2)

    # ── edge cases the port review flagged ──────────────────────────────────
    # root value (empty key) lives in PathMap.root_val — must still render
    mr = _PMv{Int}(); PathMap.set_val_at!(mr, b"", 7)
    @test occursin("label: \"7\"", PathMap.viz_maps([mr]))

    # value with a Mermaid-breaking char must be escaped, not emitted raw
    ms = _PMv{String}(); PathMap.set_val_at!(ms, b"k", "a\"b")
    esc = PathMap.viz_maps([ms])
    @test occursin("#quot;", esc)              # quote escaped
    @test !occursin("\"a\"b\"", esc)           # no raw quote breaking the label

    # ── ASCII tree mode ─────────────────────────────────────────────────────
    ascii(mp) = String(take!(PathMap.viz_maps(mp,
        PathMap.DrawConfig(; mode = PathMap.ASCII, ascii_path = true, color = false), IOBuffer())))
    at = ascii([m])
    @test occursin("PathMap[0]", at)
    @test occursin("├── ", at) || occursin("└── ", at)   # box-drawing tree
    @test occursin(" = 4", at)                            # a value leaf (bow=4)

    # ASCII shows structural sharing as ◆N (first) + ↩ ◆N (revisited, subtree elided)
    ash = ascii([mw])                                     # mw has the within-map grafted shared node
    @test occursin("◆1", ash)
    @test occursin("↩ ◆1", ash)

    # only the still-deferred logical (path-collapsed) mode errors
    @test_throws ErrorException PathMap.viz_maps([m], PathMap.DrawConfig(; logical = true), IOBuffer())
end
