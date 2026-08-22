"""
Counters — port of `pathmap/src/counters.rs`.

Diagnostic statistics for trie structure analysis: node counts by depth,
branch factor histograms, run-length analysis, list-node-specific stats.
"""

# =====================================================================
# Counters struct
# =====================================================================

mutable struct PathMapCounters
    total_nodes_by_depth::Vector{Int}
    total_child_items_by_depth::Vector{Int}
    max_child_items_by_depth::Vector{Int}
    total_dense_byte_nodes_by_depth::Vector{Int}
    total_list_nodes_by_depth::Vector{Int}
    total_slot0_length_by_depth::Vector{Int}
    slot1_occupancy_count_by_depth::Vector{Int}
    total_slot1_length_by_depth::Vector{Int}
    list_node_single_byte_keys_by_depth::Vector{Int}
    run_length_histogram::Vector{Vector{Int}}   # [run_len][byte_depth]
    cur_run_start_depth::Int
end

PathMapCounters() = PathMapCounters(
    Int[], Int[], Int[], Int[], Int[], Int[], Int[], Int[], Int[], Vector{Int}[], 0
)

total_nodes(c::PathMapCounters) = sum(c.total_nodes_by_depth; init=0)
total_child_items(c::PathMapCounters) = sum(c.total_child_items_by_depth; init=0)

# =====================================================================
# Internal helpers
# =====================================================================

function _cnt_resize!(c::PathMapCounters, depth::Int)
    length(c.total_nodes_by_depth) > depth && return nothing
    for v in [
        c.total_nodes_by_depth,
        c.total_child_items_by_depth,
        c.max_child_items_by_depth,
        c.total_dense_byte_nodes_by_depth,
        c.total_list_nodes_by_depth,
        c.total_slot0_length_by_depth,
        c.slot1_occupancy_count_by_depth,
        c.total_slot1_length_by_depth,
        c.list_node_single_byte_keys_by_depth
    ]
        while length(v) <= depth

            push!(v, 0)
        end
    end
end

function _cnt_common!(c::PathMapCounters, node::AbstractTrieNode, depth::Int)
    _cnt_resize!(c, depth)
    ic = _cnt_item_count(node)
    c.total_nodes_by_depth[depth + 1] += 1
    c.total_child_items_by_depth[depth + 1] += ic
    c.max_child_items_by_depth[depth + 1] < ic &&
        (c.max_child_items_by_depth[depth + 1] = ic)
end

function _cnt_item_count(node::AbstractTrieNode)
    # Approximate: count_branches(node, []) for root-level branches
    count_branches(node, UInt8[])
end

function _cnt_end_run!(c::PathMapCounters, depth::Int)
    depth > c.cur_run_start_depth || return nothing
    run_len = depth - c.cur_run_start_depth
    _cnt_push_run!(c, run_len, depth-1)
    c.cur_run_start_depth = depth
end

function _cnt_push_run!(c::PathMapCounters, run_len::Int, byte_depth::Int)
    while length(c.run_length_histogram) <= run_len
        push!(c.run_length_histogram, Int[])
    end
    h = c.run_length_histogram[run_len + 1]
    while length(h) <= byte_depth

        push!(h, 0)
    end
    h[byte_depth + 1] += 1
end

function _cnt_count_node!(c::PathMapCounters, node::AbstractTrieNode, depth::Int)
    if node isa DenseByteNode
        _cnt_item_count(node) != 1 && _cnt_end_run!(c, depth)
        _cnt_common!(c, node, depth)
        c.total_dense_byte_nodes_by_depth[depth + 1] += 1
    elseif node isa LineListNode
        _cnt_item_count(node) != 1 && _cnt_end_run!(c, depth)
        _cnt_common!(c, node, depth)
        c.total_list_nodes_by_depth[depth + 1] += 1
        k0, k1 = get_both_keys(node)
        c.total_slot0_length_by_depth[depth + 1] += length(k0)
        if !isempty(k1)
            c.slot1_occupancy_count_by_depth[depth + 1] += 1
            c.total_slot1_length_by_depth[depth + 1] += length(k1)
        end
        (length(k0) == 1 || length(k1) == 1) &&
            (c.list_node_single_byte_keys_by_depth[depth + 1] += 1)
    else
        _cnt_common!(c, node, depth)
    end
end

# =====================================================================
# count_occupancy — main entry point
# =====================================================================

"""
    count_occupancy(m::PathMap) → PathMapCounters

Traverse the PathMap and collect structural statistics.
Mirrors `Counters::count_ocupancy`.
"""
function count_occupancy(m::PathMap{V, A}) where {V, A}
    c = PathMapCounters()
    isempty(m) && return c

    root_inner = _fnode(_rc_inner(m.root), V, A)
    root_inner !== nothing && _cnt_count_node!(c, root_inner, 0)

    z = read_zipper(m)
    while zipper_to_next_step!(z)
        depth = length(zipper_path(z))
        depth > c.cur_run_start_depth || (c.cur_run_start_depth = depth)
        inner = z.focus_node
        if inner !== nothing
            _cnt_count_node!(c, inner, depth)
        else
            depth > 0 && _cnt_end_run!(c, depth-1)
        end
    end
    c
end

# =====================================================================
# Printing utilities
# =====================================================================

"""
Print per-depth histogram of nodes and branch counts.
"""
function print_histogram_by_depth(c::PathMapCounters)
    println(
        "\n\ttotal_nodes\ttot_child_cnt\tavg_branch\tmax_child_items\tdense_nodes\tlist_nodes"
    )
    for depth in 0:(length(c.total_nodes_by_depth) - 1)
        n = c.total_nodes_by_depth[depth + 1]
        ci = c.total_child_items_by_depth[depth + 1]
        avg = n > 0 ? ci / n : 0.0
        println(
            "$depth\t$n\t\t$ci\t\t$(round(avg,digits=4))\t\t$(c.max_child_items_by_depth[depth+1])\t\t$(c.total_dense_byte_nodes_by_depth[depth+1])\t\t$(c.total_list_nodes_by_depth[depth+1])"
        )
    end
    tn = total_nodes(c)
    tc = total_child_items(c)
    avg = tn > 0 ? tc/tn : 0.0
    println("TOTAL nodes: $tn, items: $tc, avg children-per-node: $(round(avg,digits=4))")
end

"""
Print run-length histogram.
"""
function print_run_length_histogram(c::PathMapCounters)
    println("run_len\trun_cnt\trun_end_mean_depth")
    for (run_len, depths) in enumerate(c.run_length_histogram)
        isempty(depths) && continue
        total = sum(depths; init=0)
        depth_sum = sum((d*cnt for (d, cnt) in enumerate(depths)); init=0)
        avg = total > 0 ? depth_sum/total : 0.0
        println("$(run_len-1)\t$total\t$(round(avg,digits=4))")
    end
end

"""
Print list-node-specific statistics.
"""
function print_list_node_stats(c::PathMapCounters)
    println(
        "\n\ttotal_nodes\tlist_node_cnt\tlist_node_rto\tavg_slot0_len\tslot1_cnt\tslot1_used_rto\tavg_slot1_len\tone_byte_keys\tone_byte_rto"
    )
    for depth in 0:(length(c.total_nodes_by_depth) - 1)
        n = c.total_nodes_by_depth[depth + 1]
        ln = c.total_list_nodes_by_depth[depth + 1]
        s1 = c.slot1_occupancy_count_by_depth[depth + 1]
        obk = c.list_node_single_byte_keys_by_depth[depth + 1]
        sl0 = c.total_slot0_length_by_depth[depth + 1]
        sl1 = c.total_slot1_length_by_depth[depth + 1]
        println(
            "$depth\t$n\t\t$ln\t\t$(round(ln/max(1,n)*100,digits=1))%\t\t$(round(sl0/max(1,ln),digits=4))\t\t$s1\t\t$(round(s1/max(1,ln)*100,digits=1))%\t\t$(round(sl1/max(1,s1),digits=4))\t\t$obk\t\t$(round(obk/max(1,ln)*100,digits=1))%"
        )
    end
end

"""
Print all paths in a zipper.
"""
function print_traversal(m::PathMap{V, A}) where {V, A}
    z = read_zipper(m)
    println(zipper_path(z))
    while zipper_to_next_val!(z)
        println(collect(zipper_path(z)))
    end
end

# =====================================================================
# Exports
# =====================================================================

export PathMapCounters, total_nodes, total_child_items
export count_occupancy
export print_histogram_by_depth, print_run_length_histogram, print_list_node_stats
export print_traversal
