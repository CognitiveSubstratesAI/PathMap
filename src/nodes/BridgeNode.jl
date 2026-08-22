"""
BridgeNode — port of `pathmap/src/bridge_node.rs`.

A compact single-entry trie node storing an inline key (any length) and
one payload (val or child).  When key > KEY_BYTES_CNT bytes, chains to a
child BridgeNode with the remaining key suffix.

Julia translation notes:
  - `MaybeUninit<u8>` key buffer → plain `Vector{UInt8}` (GC-managed)
  - `ValOrChildUnion` unsafe union → `ValOrChild{V,A}` tagged union
  - Chaining for long keys preserved: first node is_child=true with 31-byte key
    prefix, pointing to a child BridgeNode with the remainder
  - Most lattice ops are `unimplemented!()` in upstream → error() here
"""

const BRIDGE_KEY_MAX = 31   # KEY_BYTES_CNT in upstream

const BRIDGE_NODE_TAG = 0x05   # new tag for dispatch

"""
    BridgeNode{V, A<:Allocator}

Single-entry node with arbitrary-length inline key.
Mirrors `BridgeNode<V>` in bridge_node.rs.
"""
mutable struct BridgeNode{V, A <: Allocator} <: AbstractTrieNode{V, A}
    key::Vector{UInt8}
    is_child::Bool
    payload::Union{Nothing, ValOrChild{V, A}}   # nothing = empty sentinel
    alloc::A
    @atomic refcnt::UInt32   # node-keyed COW refcount (close-out 2-A)
    # Explicit inner constructor to suppress auto-generated default
    BridgeNode{V, A}(
        k::Vector{UInt8}, c::Bool, p::Union{Nothing, ValOrChild{V, A}}, a::A
    ) where {V, A <: Allocator} =
        new{V, A}(k, c, p, a, UInt32(1))
end

"""
Empty sentinel BridgeNode.
"""
function BridgeNode{V, A}(alloc::A) where {V, A <: Allocator}
    BridgeNode{V, A}(UInt8[], false, nothing, alloc)
end
BridgeNode{V}(alloc::A=GlobalAlloc()) where {V, A <: Allocator} = BridgeNode{V, A}(alloc)

"""
Create a BridgeNode with the given key and payload. Chains when key > KEY_BYTES_CNT.
"""
function BridgeNode(
    key::AbstractVector{UInt8}, is_child::Bool, payload::ValOrChild{V, A}, alloc::A
) where {V, A <: Allocator}
    if length(key) <= BRIDGE_KEY_MAX
        # Use fully-qualified constructor to avoid ambiguity with struct auto-ctor
        n = BridgeNode{V, A}(alloc)
        n.key = Vector{UInt8}(key)
        n.is_child = is_child
        n.payload = payload
        n
    else
        # Chain: first node stores key[1:BRIDGE_KEY_MAX], points to child with rest
        rest = key[(BRIDGE_KEY_MAX + 1):end]
        child_node = BridgeNode(rest, is_child, payload, alloc)
        child_rc = TrieNodeODRc(child_node, alloc)
        BridgeNode{V, A}(
            Vector{UInt8}(key[1:BRIDGE_KEY_MAX]), true, ValOrChild(child_rc), alloc
        )
    end
end

# =====================================================================
# TrieNode interface
# =====================================================================

node_is_empty(n::BridgeNode) = isempty(n.key) || n.payload === nothing

# Unwrap payload (only call when !node_is_empty)
@inline _bn_pl(n::BridgeNode{V, A}) where {V, A} = n.payload::ValOrChild{V, A}

function node_contains_partial_key(n::BridgeNode, key::AbstractVector{UInt8})
    slice_starts_with(n.key, key)
end

function node_get_child(n::BridgeNode{V, A}, key::AbstractVector{UInt8}) where {V, A}
    n.is_child || return nothing
    node_is_empty(n) && return nothing
    klen = length(n.key)
    length(key) >= klen && key[1:klen] == n.key || return nothing
    child_rc = into_child(_bn_pl(n))
    is_empty_node(child_rc) && return nothing
    (klen, child_rc)
end

function node_get_child_mut(n::BridgeNode{V, A}, key::AbstractVector{UInt8}) where {V, A}
    node_get_child(n, key)
end

function node_replace_child!(
    n::BridgeNode{V, A}, key::AbstractVector{UInt8}, new_rc::TrieNodeODRc{V, A}
) where {V, A}
    n.is_child && n.key == key && (n.payload=ValOrChild(new_rc); return nothing)
    error("BridgeNode::node_replace_child! — key not found")
end

function node_contains_val(n::BridgeNode, key::AbstractVector{UInt8})
    !n.is_child && !node_is_empty(n) && n.key == key
end

function node_get_val(n::BridgeNode{V, A}, key::AbstractVector{UInt8}) where {V, A}
    node_contains_val(n, key) ? into_val(_bn_pl(n)) : nothing
end

function node_get_val_mut(n::BridgeNode{V, A}, key::AbstractVector{UInt8}) where {V, A}
    node_get_val(n, key)
end

function node_set_val!(n::BridgeNode{V, A}, key::AbstractVector{UInt8}, val::V) where {V, A}
    node_is_empty(n) || return _bridge_splice!(n, key, false, ValOrChild(val), Val{false}())
    n.key = Vector{UInt8}(key)
    n.is_child = false
    n.payload = ValOrChild(val)
    (nothing, false)
end

function node_set_branch!(
    n::BridgeNode{V, A}, key::AbstractVector{UInt8}, new_rc::TrieNodeODRc{V, A}
) where {V, A}
    node_is_empty(n) ||
        return _bridge_splice!(n, key, true, ValOrChild(new_rc), Val{true}())
    n.key = Vector{UInt8}(key)
    n.is_child = true
    n.payload = ValOrChild(new_rc)
    true
end

function node_remove_val!(
    n::BridgeNode{V, A}, key::AbstractVector{UInt8}, prune::Bool
) where {V, A}
    !n.is_child && !node_is_empty(n) && n.key == key || return nothing
    old = into_val(_bn_pl(n))
    n.key = UInt8[]
    n.is_child = false
    n.payload = nothing
    old
end

function node_remove_all_branches!(
    n::BridgeNode{V, A}, key::AbstractVector{UInt8}, prune::Bool
) where {V, A}
    node_is_empty(n) && return false
    slice_starts_with(n.key, key) && (key < n.key || n.is_child) || return false
    n.key = UInt8[]
    n.is_child = false
    n.payload = nothing
    true
end

function node_remove_unmasked_branches!(
    n::BridgeNode{V, A}, key::AbstractVector{UInt8}, mask::ByteMask, prune::Bool
) where {V, A}
    node_is_empty(n) && return nothing
    !slice_starts_with(n.key, key) && return nothing
    if length(key) < length(n.key)
        byte = n.key[length(key) + 1]
        test_bit(mask, byte) && return nothing
    end
    n.key = UInt8[]
    n.is_child = false
    n.payload = nothing
end

node_create_dangling!(n::BridgeNode{V, A}, key::AbstractVector{UInt8}) where {V, A} =
    error("BridgeNode::node_create_dangling! — unreachable")
node_remove_dangling!(n::BridgeNode{V, A}, key::AbstractVector{UInt8}) where {V, A} = 0

function node_get_payloads(n::BridgeNode{V, A}, keys_expect_val, results_buf) where {V, A}
    node_is_empty(n) && return false
    requested = false
    nk = n.key
    nklen = length(nk)
    for (i, (key, expect_val)) in enumerate(keys_expect_val)
        slice_starts_with(key, nk) || continue
        if n.is_child
            if !expect_val || nklen < length(key)
                requested = true
                results_buf[i] = (
                    nklen, PayloadRef{V, A}(0x2, nothing, into_child(_bn_pl(n)))
                )
            end
        else
            if expect_val && nklen == length(key)
                requested = true
                results_buf[i] = (
                    nklen, PayloadRef{V, A}(0x1, Ref{V}(into_val(_bn_pl(n))), nothing)
                )
            end
        end
    end
    requested
end

node_val_count(n::BridgeNode{V, A}, cache::Dict{UInt64, Int}) where {V, A} =
    n.is_child ? node_val_count(as_tagged(into_child(_bn_pl(n))), cache) : 1
node_goat_val_count(n::BridgeNode) =
    if node_is_empty(n)
        0
    elseif n.is_child
        0
    else
        1
    end

function node_child_iter_start(n::BridgeNode{V, A}) where {V, A}
    n.is_child && !node_is_empty(n) && return (UInt64(0), into_child(_bn_pl(n)))
    (UInt64(0), nothing)
end
node_child_iter_next(::BridgeNode, ::UInt64) = (UInt64(0), nothing)

function node_first_val_depth_along_key(n::BridgeNode, key::AbstractVector{UInt8})
    !isempty(key) || return nothing
    if (!n.is_child && !node_is_empty(n) && slice_starts_with(key, n.key))
        length(n.key) - 1
    else
        nothing
    end
end

# Iteration — BridgeNode is similar to TinyRefNode (unreachable in normal iteration)
new_iter_token(::BridgeNode) = UInt128(0)
function iter_token_for_path(n::BridgeNode, key::AbstractVector{UInt8})
    nk = n.key
    nklen = length(nk)
    length(key) <= nklen || return (NODE_ITER_FINISHED, UInt8[])
    short = nk[1:length(key)]
    key < short && return (UInt128(0), UInt8[])
    key == short && return (UInt128(1), nk)
    (NODE_ITER_FINISHED, UInt8[])
end
function next_items(n::BridgeNode{V, A}, tok::UInt128) where {V, A}
    tok == 0 || return (NODE_ITER_FINISHED, UInt8[], nothing, nothing)
    nk = n.key
    n.is_child && !node_is_empty(n) &&
        return (UInt128(1), nk, into_child(_bn_pl(n)), nothing)
    !n.is_child && !node_is_empty(n) &&
        return (UInt128(1), nk, nothing, into_val(_bn_pl(n)))
    (NODE_ITER_FINISHED, UInt8[], nothing, nothing)
end

# Navigation helpers
function count_branches(n::BridgeNode, key::AbstractVector{UInt8})
    node_is_empty(n) && return 0
    slice_starts_with(n.key, key) && (n.is_child || length(n.key) > length(key)) ? 1 : 0
end

function node_branches_mask(n::BridgeNode, key::AbstractVector{UInt8})
    node_is_empty(n) && return ByteMask()
    nk = n.key
    klen = length(key)
    length(nk) > klen && slice_starts_with(nk, key) ? ByteMask(nk[klen + 1]) : ByteMask()
end

function prior_branch_key(::BridgeNode, ::AbstractVector{UInt8})
    UInt8[]  # BridgeNodes never have internal branches
end
function get_sibling_of_child(::BridgeNode, ::AbstractVector{UInt8}, ::Bool)
    (nothing, nothing)
end

function nth_child_from_key(
    n::BridgeNode{V, A}, key::AbstractVector{UInt8}, idx::Int
) where {V, A}
    idx != 0 && return (nothing, nothing)
    nk = n.key
    klen = length(key)
    length(nk) > klen && slice_starts_with(nk, key) || return (nothing, nothing)
    byte = nk[klen + 1]
    n.is_child ? (byte, as_tagged(into_child(_bn_pl(n)))) : (byte, nothing)
end

function first_child_from_key(n::BridgeNode{V, A}, key::AbstractVector{UInt8}) where {V, A}
    nk = n.key
    klen = length(key)
    length(nk) > klen && slice_starts_with(nk, key) || return (nothing, nothing)
    rest = nk[(klen + 1):end]
    n.is_child ? (rest, as_tagged(into_child(_bn_pl(n)))) : (rest, nothing)
end

function get_node_at_key(n::BridgeNode{V, A}, key::AbstractVector{UInt8}) where {V, A}
    node_is_empty(n) && return ANRNone{V, A}()
    isempty(key) && return ANRBorrowedDyn{V, A}(n)
    nk = n.key
    n.is_child && nk == key && return ANRBorrowedRc{V, A}(into_child(_bn_pl(n)))
    length(nk) > length(key) && slice_starts_with(nk, key) || return ANRNone{V, A}()
    new_key = nk[(length(key) + 1):end]
    new_n = BridgeNode{V, A}(new_key, n.is_child, _bn_pl(n), n.alloc)
    ANROwnedRc{V, A}(TrieNodeODRc(new_n, n.alloc))
end

function take_node_at_key!(
    n::BridgeNode{V, A}, key::AbstractVector{UInt8}, prune::Bool
) where {V, A}
    nk = n.key
    slice_starts_with(nk, key) || return nothing
    length(nk) == length(key) && n.is_child || return nothing
    rc = into_child(_bn_pl(n))
    n.key = UInt8[]
    n.is_child = false
    n.payload = nothing
    rc
end

# =====================================================================
# Lattice ops
# =====================================================================

function pjoin_dyn(n::BridgeNode{V, A}, other::AbstractTrieNode{V, A}) where {V, A}
    # Merge with other node type → upgrade to DenseByteNode
    if other isa BridgeNode{V, A}
        return _bridge_merge(n, other)
    end
    # Delegate: convert self to LineListNode first
    lln = LineListNode{V, A}(n.alloc)
    set_slot0!(lln, n.key, _bn_pl(n))
    pjoin_dyn(lln, other)
end

function _bridge_merge(a::BridgeNode{V, A}, b::BridgeNode{V, A}) where {V, A}
    # Merge two BridgeNodes → create DenseByteNode with both entries
    dense = DenseByteNode{V, A}(a.alloc)
    node_add_payload!(dense, a.key, a.is_child, a.payload)
    node_add_payload!(dense, b.key, b.is_child, b.payload)
    AlgResElement(TrieNodeODRc(dense, a.alloc))
end

join_into_dyn!(::BridgeNode, ::TrieNodeODRc) =
    error("BridgeNode::join_into_dyn! — unimplemented (upstream)")
drop_head_dyn!(::BridgeNode, ::Int) =
    error("BridgeNode::drop_head_dyn! — unimplemented (upstream)")
pmeet_dyn(n::BridgeNode{V, A}, other::AbstractTrieNode{V, A}) where {V, A} =
    error("BridgeNode::pmeet_dyn — unimplemented (upstream)")
psubtract_dyn(n::BridgeNode{V, A}, other::AbstractTrieNode{V, A}) where {V, A} =
    error("BridgeNode::psubtract_dyn — unimplemented (upstream)")
prestrict_dyn(n::BridgeNode{V, A}, other::AbstractTrieNode{V, A}) where {V, A} =
    error("BridgeNode::prestrict_dyn — unimplemented (upstream)")

function clone_self(n::BridgeNode{V, A}) where {V, A}
    new_n = BridgeNode{V, A}(
        copy(n.key), n.is_child, _clone_val_or_child(_bn_pl(n), n.is_child), n.alloc
    )
    TrieNodeODRc(new_n, n.alloc)
end

function _clone_val_or_child(vc::ValOrChild{V, A}, is_child::Bool) where {V, A}
    # Child: SHARE via copy() (bumps the child refcount) — was sharing the raw rc
    # wrapper with no count bump (undercount → unsafe once make_unique! relies on it).
    is_child ? ValOrChild(copy(into_child(vc))) : ValOrChild(Ref{V}(into_val(vc)))
end

node_tag(::BridgeNode) = BRIDGE_NODE_TAG
convert_to_cell_node!(::BridgeNode) =
    error("BridgeNode::convert_to_cell_node! — unreachable")

# =====================================================================
# Internal splice helper
# =====================================================================

"""
Splice a new payload into a non-empty BridgeNode. Returns (old_val, created_subnode) or TrieNodeODRc.
"""
function _bridge_splice!(
    n::BridgeNode{V, A}, key::AbstractVector{UInt8}, is_child::Bool,
    payload::ValOrChild{V, A}, ::Val{IS_CHILD}
) where {V, A <: Allocator, IS_CHILD}
    nk = n.key
    overlap = find_prefix_overlap(collect(key), collect(nk))
    if overlap > 0
        # Exact match same type → replace
        if overlap == length(nk) && overlap == length(key) && IS_CHILD == n.is_child
            old_payload = _bn_pl(n)
            n.payload = payload
            old_val = IS_CHILD ? nothing : into_val(old_payload)
            return (old_val, false)
        end
        # Partial overlap → split
        if overlap == length(nk) || overlap == length(key)
            overlap -= 1
        end
        dense = DenseByteNode{V, A}(n.alloc)
        node_add_payload!(dense, nk[(overlap + 1):end], n.is_child, _bn_pl(n))
        node_add_payload!(dense, collect(key)[(overlap + 1):end], is_child, payload)
        if overlap > 0
            n.key = nk[1:overlap]
            n.is_child = true
            n.payload = ValOrChild(TrieNodeODRc(dense, n.alloc))
            return IS_CHILD ? true : (nothing, true)
        else
            return TrieNodeODRc(dense, n.alloc)
        end
    else
        # No overlap → create DenseByteNode with both
        dense = DenseByteNode{V, A}(n.alloc)
        node_add_payload!(dense, nk, n.is_child, _bn_pl(n))
        node_add_payload!(dense, collect(key), is_child, payload)
        return TrieNodeODRc(dense, n.alloc)
    end
end

# =====================================================================
# Exports
# =====================================================================

export BridgeNode, BRIDGE_NODE_TAG, BRIDGE_KEY_MAX
