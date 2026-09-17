"""
TinyRefNode — port of `pathmap/src/tiny_node.rs`.

A read-only 1-entry view node used to represent a sub-path within another
node (mainly LineListNode) without allocating a new node. Created by
`get_node_at_key` when the remaining key length is ≤ 7 bytes.

All write methods panic with `error("unreachable")` matching upstream.
Lattice ops delegate to `into_full()` (convert to LineListNode first).
"""

# Maximum inline key bytes for a TinyRefNode (matches upstream constant)
const TINY_REF_MAX_KEY = 7

"""
    TinyRefNode{V, A<:Allocator} <: AbstractTrieNode{V,A}

Single-entry read-only node holding an inline key (≤7 bytes) and a
borrowed `ValOrChild` payload.
"""
struct TinyRefNode{V, A <: Allocator} <: AbstractTrieNode{V, A}
    key::Vector{UInt8}        # 0..TINY_REF_MAX_KEY bytes
    is_child::Bool                 # true = payload is a child TrieNodeODRc
    payload::ValOrChild{V, A}      # the borrowed payload
    alloc::A
end

"""
    TinyRefNode(is_child, key, payload, alloc)

Construct a TinyRefNode. `key` must be ≤ TINY_REF_MAX_KEY bytes.
"""
function TinyRefNode(
    is_child::Bool, key::AbstractVector{UInt8}, payload::ValOrChild{V, A}, alloc::A
) where {V, A <: Allocator}
    @assert length(key) <= TINY_REF_MAX_KEY
    TinyRefNode{V, A}(Vector{UInt8}(key), is_child, payload, alloc)
end

# =====================================================================
# into_full — converts TinyRefNode → LineListNode (for write delegation)
# =====================================================================

"""
    into_full(t) → LineListNode{V,A}

Convert the TinyRefNode to a single-slot LineListNode by cloning the payload.
Panics if the node is empty (upstream: `unwrap()`).
"""
function into_full(t::TinyRefNode{V, A}) where {V, A}
    @assert !node_is_empty(t) "TinyRefNode::into_full on empty node"
    new_n = LineListNode{V, A}(t.alloc)
    set_slot0!(new_n, t.key, t.payload)
    new_n
end

# =====================================================================
# TrieNode interface implementation for TinyRefNode
# =====================================================================

function node_key_overlap(t::TinyRefNode, key::AbstractVector{UInt8})
    find_prefix_overlap(t.key, key)
end

function node_contains_partial_key(t::TinyRefNode, key::AbstractVector{UInt8})
    slice_starts_with(t.key, key)
end

function node_get_child(t::TinyRefNode{V, A}, key::AbstractVector{UInt8}) where {V, A}
    if t.is_child && !node_is_empty(t)
        klen = length(t.key)
        if length(key) >= klen && key[1:klen] == t.key
            child_rc = into_child(t.payload)
            is_empty_node(child_rc) || return (klen, child_rc)
        end
    end
    nothing
end

function node_get_child_mut(::TinyRefNode, ::AbstractVector{UInt8})
    error("TinyRefNode::node_get_child_mut — unreachable (read-only node)")
end

function node_replace_child!(::TinyRefNode, ::AbstractVector{UInt8}, ::TrieNodeODRc)
    error("TinyRefNode::node_replace_child! — unreachable (read-only node)")
end

function node_get_payloads(t::TinyRefNode{V, A}, keys_expect_val, results_buf) where {V, A}
    node_is_empty(t) && return true
    requested = false
    sk = t.key
    sklen = length(sk)
    for (i, (key, expect_val)) in enumerate(keys_expect_val)
        if slice_starts_with(key, sk)
            if t.is_child
                if !expect_val || sklen < length(key)
                    requested = true
                    results_buf[i] = (
                        sklen, PayloadRef{V, A}(0x2, nothing, into_child(t.payload))
                    )
                end
            else
                if expect_val && sklen == length(key)
                    requested = true
                    results_buf[i] = (
                        sklen, PayloadRef{V, A}(0x1, Ref{V}(into_val(t.payload)), nothing)
                    )
                end
            end
        end
    end
    requested
end

function node_contains_val(t::TinyRefNode, key::AbstractVector{UInt8})
    !t.is_child && !node_is_empty(t) && t.key == key
end

function node_get_val(t::TinyRefNode{V, A}, key::AbstractVector{UInt8}) where {V, A}
    (!t.is_child && !node_is_empty(t) && t.key == key) ? into_val(t.payload) : nothing
end

function node_get_val_mut(::TinyRefNode, ::AbstractVector{UInt8})
    error("TinyRefNode::node_get_val_mut — unreachable (read-only node)")
end

function node_set_val!(
    t::TinyRefNode{V, A}, key::AbstractVector{UInt8}, val::V
) where {V, A}
    replacement = into_full(t)
    res = node_set_val!(replacement, key, val)
    res isa TrieNodeODRc &&
        error("TinyRefNode::node_set_val! — upgrade needed (unexpected)")
    # Return the replacement node as Err variant
    TrieNodeODRc(replacement, t.alloc)
end

function node_remove_val!(::TinyRefNode, ::AbstractVector{UInt8}, ::Bool)
    error("TinyRefNode::node_remove_val! — unreachable (read-only node)")
end

function node_create_dangling!(::TinyRefNode, ::AbstractVector{UInt8})
    error("TinyRefNode::node_create_dangling! — unreachable (read-only node)")
end

function node_remove_dangling!(::TinyRefNode, ::AbstractVector{UInt8})
    error("TinyRefNode::node_remove_dangling! — unreachable (read-only node)")
end

function node_set_branch!(
    t::TinyRefNode{V, A}, key::AbstractVector{UInt8}, new_rc::TrieNodeODRc{V, A}
) where {V, A}
    replacement = into_full(t)
    node_set_branch!(replacement, key, new_rc)
    TrieNodeODRc(replacement, t.alloc)
end

function node_remove_all_branches!(::TinyRefNode, ::AbstractVector{UInt8}, ::Bool)
    error("TinyRefNode::node_remove_all_branches! — unreachable (read-only node)")
end

function node_remove_unmasked_branches!(
    ::TinyRefNode, ::AbstractVector{UInt8}, ::ByteMask, ::Bool
)
    error("TinyRefNode::node_remove_unmasked_branches! — unreachable (read-only node)")
end

node_is_empty(t::TinyRefNode) = isempty(t.key)   # empty iff header bit7 == 0 (no payload)

# Iteration — TinyRefNode is never iterated directly (unreachable in upstream)
new_iter_token(::TinyRefNode) = error("TinyRefNode::new_iter_token — unreachable")
iter_token_for_path(::TinyRefNode, ::AbstractVector{UInt8}) =
    error("TinyRefNode::iter_token_for_path — unreachable")
ascend_iter_token(::TinyRefNode, ::IterToken, ::Int) = error("TinyRefNode::ascend_iter_token — unreachable")
next_items(::TinyRefNode, ::IterToken, ::Bool) = error("TinyRefNode::next_items — unreachable")

function node_val_count(t::TinyRefNode, cache::Dict{UInt64, Int})::Int
    node_val_count(into_full(t), cache)
end

node_goat_val_count(t::TinyRefNode) = node_goat_val_count(into_full(t))

function node_child_iter_start(t::TinyRefNode{V, A}) where {V, A}
    t.is_child && !node_is_empty(t) && return (UInt64(0), into_child(t.payload))
    (UInt64(0), nothing)
end

node_child_iter_next(::TinyRefNode, ::UInt64) = (UInt64(0), nothing)

function node_first_val_depth_along_key(t::TinyRefNode, key::AbstractVector{UInt8})
    @assert !isempty(key)
    if (!t.is_child && !node_is_empty(t) && slice_starts_with(key, t.key))
        length(t.key) - 1
    else
        nothing
    end
end

function nth_child_from_key(::TinyRefNode, ::AbstractVector{UInt8}, ::Int)
    error("TinyRefNode::nth_child_from_key — unreachable")
end

function first_child_from_key(::TinyRefNode, ::AbstractVector{UInt8})
    error("TinyRefNode::first_child_from_key — unreachable")
end

function count_branches(::TinyRefNode, ::AbstractVector{UInt8})
    error("TinyRefNode::count_branches — unreachable")
end

function node_branches_mask(::TinyRefNode, ::AbstractVector{UInt8})
    error("TinyRefNode::node_branches_mask — unreachable")
end

function prior_branch_key(::TinyRefNode, ::AbstractVector{UInt8})
    error("TinyRefNode::prior_branch_key — unreachable")
end

function get_sibling_of_child(::TinyRefNode, ::AbstractVector{UInt8}, ::Bool)
    error("TinyRefNode::get_sibling_of_child — unreachable")
end

function get_node_at_key(t::TinyRefNode{V, A}, key::AbstractVector{UInt8}) where {V, A}
    @assert !node_is_empty(t) "TinyRefNode::get_node_at_key on empty node"
    if isempty(key)
        return ANRBorrowedDyn{V, A}(t)
    end
    nk = t.key
    if t.is_child && nk == key
        return ANRBorrowedRc{V, A}(into_child(t.payload))
    end
    if length(nk) > length(key) && slice_starts_with(nk, key)
        new_key = nk[(length(key) + 1):end]
        new_t = TinyRefNode(t.is_child, new_key, t.payload, t.alloc)
        return ANRBorrowedTiny{V, A}(new_t)
    end
    ANRNone{V, A}()
end

function take_node_at_key!(::TinyRefNode, ::AbstractVector{UInt8}, ::Bool)
    error("TinyRefNode::take_node_at_key! — unreachable (read-only node)")
end

# =====================================================================
# Lattice ops — delegate to into_full() like upstream TODO comment
# =====================================================================

function pjoin_dyn(t::TinyRefNode{V, A}, other::AbstractTrieNode{V, A}) where {V, A}
    pjoin_dyn(into_full(t), other)
end

function join_into_dyn!(::TinyRefNode, ::TrieNodeODRc)
    error("TinyRefNode::join_into_dyn! — unreachable (read-only node)")
end

function drop_head_dyn!(::TinyRefNode, ::Int)
    error("TinyRefNode::drop_head_dyn! — unreachable (read-only node)")
end

function pmeet_dyn(t::TinyRefNode{V, A}, other::AbstractTrieNode{V, A}) where {V, A}
    pmeet_dyn(into_full(t), other)
end

function psubtract_dyn(t::TinyRefNode{V, A}, other::AbstractTrieNode{V, A}) where {V, A}
    psubtract_dyn(into_full(t), other)
end

function prestrict_dyn(t::TinyRefNode{V, A}, other::AbstractTrieNode{V, A}) where {V, A}
    prestrict_dyn(into_full(t), other)
end

function clone_self(t::TinyRefNode{V, A}) where {V, A}
    TrieNodeODRc(into_full(t), t.alloc)
end

# TrieNodeDowncast equivalents
node_tag(::TinyRefNode) = TINY_REF_NODE_TAG

function convert_to_cell_node!(::TinyRefNode)
    error("TinyRefNode::convert_to_cell_node! — unreachable (read-only node)")
end

# =====================================================================
# Exports
# =====================================================================

export TinyRefNode, TINY_REF_MAX_KEY, into_full
