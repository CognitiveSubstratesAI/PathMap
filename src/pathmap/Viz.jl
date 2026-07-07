# Viz — port of pathmap/src/viz.rs (the `viz` Cargo feature).
#
# Renders one or more PathMap tries to Mermaid (https://mermaid.js.org) flowchart markup, so the
# trie STRUCTURE — and in particular STRUCTURAL SHARING (nodes reachable from more than one place /
# more than one map) — can be inspected visually. Mirrors upstream `viz_maps` / `DrawConfig` /
# `VizMode` and the `viz_node_physical` recursive node walk + `color_for_bitmask` sharing colors.
#
# Ported: the PHYSICAL renderers — Mermaid (`viz_maps_mermaid`) AND the ASCII tree (`viz_maps_ascii`,
# box-drawing + `◆N` shared markers) — both walking the real in-memory nodes (the view that actually
# reveals shared nodes). Node identity uses `shared_node_id(rc)` (= `objectid(rc.node)`, already in
# TrieNode.jl), so two wrappers of the SAME physical node collapse to one graph node — that is how
# sharing becomes visible. NOT yet ported (clean follow-up; the primitives — `zipper_to_next_step!`
# etc. — exist): the LOGICAL path-collapsed renderer (`viz_zipper_logical`), for either mode.

"""Rendering mode. `MERMAID` → Mermaid flowchart markup. `ASCII` → terminal tree (not yet ported)."""
@enum VizMode MERMAID ASCII

"""
    DrawConfig(; mode, ascii_path, hide_value_paths, minimize_values, logical, color)

Configuration for [`viz_maps`](@ref). Mirrors upstream `DrawConfig`. Defaults match upstream EXCEPT
`logical` defaults to `false` here (the ported renderer is the physical one — best for observing
structural sharing).
"""
Base.@kwdef struct DrawConfig
    mode::VizMode = MERMAID
    ascii_path::Bool = false       # render edge keys as ascii vs byte-lists
    hide_value_paths::Bool = false # skip paths that terminate in values
    minimize_values::Bool = false  # render values as tiny dots
    logical::Bool = false          # false = physical (render real nodes); true not yet ported
    color::Bool = true             # colorize by structural sharing
end

mutable struct _NodeMeta
    shared::UInt64   # bitmask: which top-level maps include this node
    ref_cnt::Int     # number of references to this node from upstream
    taken::Bool
end

# DrawCmd variants (mirror upstream `enum DrawCmd`)
struct _NodeCmd;  addr::UInt64; ntype::Symbol; end
struct _EdgeCmd;  src::UInt64;  dst::UInt64;  key::Vector{UInt8}; end
struct _ValueCmd; parent::UInt64; vaddr::UInt64; key::Vector{UInt8}; vstr::String; end
struct _MapCmd;   map_idx::Int;  root_addr::UInt64; end
const _DrawCmd = Union{_NodeCmd, _EdgeCmd, _ValueCmd, _MapCmd}

mutable struct _DrawState
    root::Int
    nodes::Dict{UInt64, _NodeMeta}
    cmds::Vector{_DrawCmd}
end
_DrawState() = _DrawState(0, Dict{UInt64, _NodeMeta}(), _DrawCmd[])

# Mirrors upstream `color_for_bitmask` (maps 0-2). Upstream panics (`todo!()`) for 4+ maps; we mask to
# the low 3 bits (graceful degradation — a 4th+ map's membership is not distinctly colored).
function _color_for_bitmask(mask::UInt64)
    m = mask & 0b111
    m == 0b000 ? "black" :
    m == 0b100 ? "red"   :
    m == 0b010 ? "green" :
    m == 0b001 ? "blue"  :
    m == 0b011 ? "#0aa"  :
    m == 0b101 ? "#a0a"  :
    m == 0b110 ? "#aa0"  : "gray"
end

# Node-type label (mirrors the `TaggedNodeRef` match in viz_node_physical).
_viz_node_type(::DenseByteNode) = :Dense
_viz_node_type(::CellByteNode)  = :Cell
_viz_node_type(::LineListNode)  = :Pair
_viz_node_type(::TinyRefNode)   = :Tiny
_viz_node_type(::BridgeNode)    = :Bridge
_viz_node_type(::EmptyNode)     = :Empty
_viz_node_type(::Any)           = :Node

# Mirrors `update_node_hash`: record/accumulate the node's map bitmask + ref count.
# Returns true on the FIRST visit (⇒ caller descends the subtrie).
function _update_node_hash!(rc::TrieNodeODRc, ds::_DrawState)
    addr = shared_node_id(rc)
    meta = get(ds.nodes, addr, nothing)
    if meta === nothing
        ds.nodes[addr] = _NodeMeta(UInt64(1) << ds.root, 1, false)
        return true
    else
        meta.shared |= UInt64(1) << ds.root
        meta.ref_cnt += 1
        return false
    end
end

# Mirrors `viz_node_physical`: recursive walk emitting Node / Edge / Value draw commands.
function _viz_node_physical!(rc::TrieNodeODRc, dc::DrawConfig, ds::_DrawState)
    addr = shared_node_id(rc)
    node = rc.node
    node === nothing && return
    push!(ds.cmds, _NodeCmd(addr, _viz_node_type(node)))
    # TinyRefNode is a transient borrowed form that can't be iterated directly (its new_iter_token
    # errors); expand it via into_full (mirrors clone_self) so its edge/value renders vs throwing.
    iter_node = node isa TinyRefNode ? into_full(node) : node
    token = new_iter_token(iter_node)
    while token != NODE_ITER_FINISHED
        (token, key_bytes, rec, value) = next_items(iter_node, token)
        if rec !== nothing
            other = shared_node_id(rec)
            push!(ds.cmds, _EdgeCmd(addr, other, Vector{UInt8}(key_bytes)))
            _update_node_hash!(rec, ds) && _viz_node_physical!(rec, dc, ds)
        end
        if value !== nothing
            # unique per (parent, edge); mirrors upstream's per-value pointer id (hash is UInt64)
            push!(ds.cmds, _ValueCmd(addr, hash((addr, key_bytes)), Vector{UInt8}(key_bytes), string(value)))
        end
    end
end

function _viz_map_physical!(m::PathMap, dc::DrawConfig, ds::_DrawState)
    _ensure_root!(m)
    root_rc = m.root
    root_rc === nothing && return
    push!(ds.cmds, _MapCmd(ds.root, shared_node_id(root_rc)))
    _update_node_hash!(root_rc, ds)
    _viz_node_physical!(root_rc, dc, ds)
    # A value at the empty/root key lives in PathMap.root_val, NOT inside the root node — render it.
    if m.root_val !== nothing
        addr = shared_node_id(root_rc)
        push!(ds.cmds, _ValueCmd(addr, hash((addr, UInt8[])), UInt8[], string(m.root_val)))
    end
end

# Mirrors upstream str::from_utf8 (viz.rs:151): render the key as text iff valid UTF-8 AND free of
# control chars (which would break a Mermaid label); else a byte-list. Else always a byte-list.
function _render_key(key::Vector{UInt8}, ascii::Bool)
    if ascii
        s = String(copy(key))
        (isvalid(s) && !any(iscntrl, s)) && return s
    end
    string(Int.(key))
end

# Escape a label so a value/key with Mermaid-breaking chars ("/newline/{}) can't corrupt the graph.
_mermaid_escape(s::AbstractString) =
    replace(s, '"' => "#quot;", '\n' => ' ', '\r' => ' ', '{' => '(', '}' => ')')

# Emit Mermaid from the collected draw commands (mirrors the `viz_maps_mermaid` render loop, physical).
function _render_mermaid(ds::_DrawState, dc::DrawConfig, io::IO)
    println(io, "flowchart LR")
    for cmd in ds.cmds
        if cmd isa _MapCmd
            println(io, "m$(cmd.map_idx)@{ shape: cylinder, label: \"PathMap[$(cmd.map_idx)]\"}")
            println(io, "m$(cmd.map_idx) --> g$(cmd.root_addr)")
        elseif cmd isa _NodeCmd
            println(io, "g$(cmd.addr)@{ shape: rect, label: \"$(cmd.ntype)\"}")
            if dc.color
                meta = get(ds.nodes, cmd.addr, nothing)
                meta !== nothing && println(io, "style g$(cmd.addr) fill:$(_color_for_bitmask(meta.shared))")
            end
        elseif cmd isa _EdgeCmd
            jump = _mermaid_escape(_render_key(cmd.key, dc.ascii_path))
            isempty(cmd.key) ? println(io, "g$(cmd.src) --> g$(cmd.dst)") :
                               println(io, "g$(cmd.src) --\"$(jump)\"--> g$(cmd.dst)")
        elseif cmd isa _ValueCmd
            dc.hide_value_paths && continue
            jump = _mermaid_escape(_render_key(cmd.key, dc.ascii_path))
            vid = "v$(cmd.vaddr)_$(cmd.parent)"   # underscore delimiter: distinct (vaddr,parent) never alias
            isempty(cmd.key) ? println(io, "g$(cmd.parent) --> $(vid)") :
                               println(io, "g$(cmd.parent) --\"$(jump)\"--> $(vid)")
            if dc.minimize_values
                println(io, "$(vid)@{ shape: circle, label: \".\"}")
                println(io, "style $(vid) fill:black,stroke:none,color:transparent,font-size:0px")
            else
                println(io, "$(vid)@{ shape: rounded, label: \"$(_mermaid_escape(cmd.vstr))\" }")
            end
        end
    end
end

# ── ASCII tree mode ──────────────────────────────────────────────────────────
# A terminal-friendly tree of the PHYSICAL nodes (mirrors upstream viz_maps_ascii's box-drawing +
# `◆N` shared markers, but node-based like our physical Mermaid rather than the logical path-collapsed
# walk — which is best for observing real shared nodes). A structurally-shared node (ref_cnt>1) is
# marked `◆N` on first appearance and `↩ ◆N` (with its subtree elided) on every later appearance.

# recursive prepass: populate ds.nodes with per-node ref_cnt + map-bitmask across ALL maps (mirrors
# upstream pre_init_node_hashes). Needed BEFORE rendering so shared nodes (ref_cnt>1) are known.
function _pre_init_node_hashes!(rc::TrieNodeODRc, ds::_DrawState)
    _update_node_hash!(rc, ds) || return
    node = rc.node
    node === nothing && return
    iter_node = node isa TinyRefNode ? into_full(node) : node
    token = new_iter_token(iter_node)
    while token != NODE_ITER_FINISHED
        (token, _key, rec, _val) = next_items(iter_node, token)
        rec !== nothing && _pre_init_node_hashes!(rec, ds)
    end
end

struct _AEdge; label::Vector{UInt8}; is_node::Bool; node_id::UInt64; vstr::String; end
mutable struct _ANode; ntype::Symbol; inline::Union{Nothing, String}; edges::Vector{_AEdge}; shared::Bool; end

# Build the physical adjacency graph for one map (each node once — a DAG under sharing).
function _build_ascii!(rc::TrieNodeODRc, ds::_DrawState, graph::Dict{UInt64, _ANode})
    addr = shared_node_id(rc)
    haskey(graph, addr) && return addr
    node = rc.node
    node === nothing && return addr
    meta = get(ds.nodes, addr, nothing)
    an = _ANode(_viz_node_type(node), nothing, _AEdge[], meta !== nothing && meta.ref_cnt > 1)
    graph[addr] = an
    iter_node = node isa TinyRefNode ? into_full(node) : node
    token = new_iter_token(iter_node)
    while token != NODE_ITER_FINISHED
        (token, key, rec, value) = next_items(iter_node, token)
        if rec !== nothing
            cid = _build_ascii!(rec, ds, graph)
            push!(an.edges, _AEdge(Vector{UInt8}(key), true, cid, ""))
        end
        if value !== nothing
            if isempty(key)
                an.inline === nothing && (an.inline = string(value))
            else
                push!(an.edges, _AEdge(Vector{UInt8}(key), false, UInt64(0), string(value)))
            end
        end
    end
    addr
end

_val_part(v::Union{Nothing, String}, dc::DrawConfig) =
    (v === nothing || dc.minimize_values) ? "" : " = $v"

function _shared_marker(id::Int, dc::DrawConfig)
    if dc.color
        c = ("31", "32", "33", "34", "35", "36")[(id - 1) % 6 + 1]
        "\e[$(c)m◆$(id)\e[0m"
    else
        "◆$(id)"
    end
end

function _render_ascii(map_idx::Int, root_id::UInt64, graph::Dict{UInt64, _ANode}, dc::DrawConfig, io::IO)
    shared_addrs = sort!(UInt64[a for (a, n) in graph if n.shared])
    shared_ids = Dict{UInt64, Int}(a => i for (i, a) in enumerate(shared_addrs))
    visited = Set{UInt64}()
    root = get(graph, root_id, nothing)
    if root === nothing
        println(io, "PathMap[$map_idx]"); println(io, "(empty)"); return
    end
    line = "PathMap[$map_idx]" * _val_part(root.inline, dc)
    if root.shared && haskey(shared_ids, root_id)
        push!(visited, root_id); line *= " " * _shared_marker(shared_ids[root_id], dc)
    end
    println(io, line)
    if isempty(root.edges) && root.inline === nothing
        println(io, "(empty)"); return
    end
    _render_ascii_children(root, graph, dc, shared_ids, visited, "", io)
end

function _render_ascii_children(node::_ANode, graph, dc, shared_ids, visited, prefix, io)
    edges = sort(node.edges; by = e -> e.label)
    for (i, e) in enumerate(edges)
        last = i == length(edges)
        connector = last ? "└── " : "├── "
        label = _render_key(e.label, dc.ascii_path)
        if !e.is_node
            println(io, "$(prefix)$(connector)$(label)$(_val_part(e.vstr, dc))")
        else
            child = get(graph, e.node_id, nothing)
            child === nothing && continue
            vpart = _val_part(child.inline, dc)
            if child.shared && haskey(shared_ids, e.node_id)
                sid = shared_ids[e.node_id]
                if e.node_id in visited
                    println(io, "$(prefix)$(connector)$(label)$(vpart) ↩ $(_shared_marker(sid, dc))")
                    continue
                end
                push!(visited, e.node_id)
                println(io, "$(prefix)$(connector)$(label)$(vpart) $(_shared_marker(sid, dc))")
            else
                println(io, "$(prefix)$(connector)$(label)$(vpart)")
            end
            _render_ascii_children(child, graph, dc, shared_ids, visited, prefix * (last ? "    " : "│   "), io)
        end
    end
end

"""
    viz_maps(maps, dc::DrawConfig=DrawConfig(), io::IO=stdout)
    viz_maps(m::PathMap; kwargs...) -> String

Render `maps` (a PathMap or a vector of them) to `io` as Mermaid flowchart markup. Structural sharing
is made visible: a node reachable from more than one map is colored by its map-membership bitmask
(`color_for_bitmask`), and physically-shared subtries (a node with `ref_cnt > 1`) collapse to a single
graph node because identity is keyed by `shared_node_id` (`objectid` of the physical node).

Mirrors upstream `viz_maps`. `VizMode.MERMAID` (graph markup) and `VizMode.ASCII` (terminal tree with
`◆N` shared-node markers) are ported, both PHYSICAL (`logical=false`); the LOGICAL path-collapsed walk
(`logical=true`) throws a clear error (follow-up). The 1-arg keyword form returns a `String`.
"""
# Core (no default positional args, so it does not generate a `viz_maps(::AbstractVector)` that would
# collide with the kwargs convenience method below).
function viz_maps(maps::AbstractVector{<:PathMap}, dc::DrawConfig, io::IO)
    dc.logical && error("viz: logical (path-collapsed) mode not yet ported (use logical=false / physical); see Viz.jl header")
    if dc.mode === ASCII
        ds = _DrawState()                       # prepass over ALL maps for cross-map ref_cnt
        for m in maps
            _ensure_root!(m); m.root !== nothing && _pre_init_node_hashes!(m.root, ds); ds.root += 1
        end
        ds.root = 0
        for m in maps
            ds.root > 0 && println(io)
            _ensure_root!(m)
            if m.root === nothing
                println(io, "PathMap[$(ds.root)]"); println(io, "(empty)")
            else
                graph = Dict{UInt64, _ANode}()
                _build_ascii!(m.root, ds, graph)
                if m.root_val !== nothing        # value at the empty/root key lives in root_val
                    an = get(graph, shared_node_id(m.root), nothing)
                    an !== nothing && an.inline === nothing && (an.inline = string(m.root_val))
                end
                _render_ascii(ds.root, shared_node_id(m.root), graph, dc, io)
            end
            ds.root += 1
        end
        return io
    end
    ds = _DrawState()                           # MERMAID physical
    for m in maps
        _viz_map_physical!(m, dc, ds)
        ds.root += 1
    end
    _render_mermaid(ds, dc, io)
    io
end

viz_maps(m::PathMap, dc::DrawConfig, io::IO) = viz_maps([m], dc, io)

# Convenience: keyword form → Mermaid `String`. The ONLY 1-positional-arg method, so no overwrite.
function viz_maps(m::PathMap; kwargs...)
    buf = IOBuffer()
    viz_maps([m], DrawConfig(; kwargs...), buf)
    String(take!(buf))
end
viz_maps(maps::AbstractVector{<:PathMap}; kwargs...) =
    (buf = IOBuffer(); viz_maps(maps, DrawConfig(; kwargs...), buf); String(take!(buf)))
