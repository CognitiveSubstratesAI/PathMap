"""
EmptyNode — port of `pathmap/src/empty_node.rs`.

A zero-field singleton representing an empty trie node. All query methods
return trivial values; all write methods that would be called on a non-empty
node panic with `error("unreachable")` to match upstream's `unreachable!()`.

Used as the sentinel value for empty-child positions in the trie, replacing
`TrieNodeODRc::new_empty()` (which returns nothing rather than allocating).
"""

# =====================================================================
# EmptyNode type
# =====================================================================
#
# Rust: `#[derive(Clone, Copy, Default, Debug)] pub struct EmptyNode;`
# Julia: immutable zero-field struct (singleton-equivalent).

"""
    EmptyNode{V,A<:Allocator} <: AbstractTrieNode{V,A}

Singleton node type representing an empty trie position.
Corresponds to upstream `EmptyNode` + its `TrieNode<V,A>` impl.
"""
struct EmptyNode{V, A <: Allocator} <: AbstractTrieNode{V, A} end

# =====================================================================
# TrieNode interface implementation for EmptyNode
# =====================================================================

node_key_overlap(::EmptyNode, ::AbstractVector{UInt8}) = 0
node_contains_partial_key(::EmptyNode, ::AbstractVector{UInt8}) = false

node_get_child(::EmptyNode{V, A}, ::AbstractVector{UInt8}) where {V, A} = nothing

node_get_child_mut(::EmptyNode{V, A}, ::AbstractVector{UInt8}) where {V, A} = nothing

function node_replace_child!(::EmptyNode, ::AbstractVector{UInt8}, ::TrieNodeODRc)
    error("EmptyNode::node_replace_child! — unreachable (no child to replace)")
end

node_get_payloads(::EmptyNode, ::Any, ::Any) = true   # vacuously exhaustive

node_contains_val(::EmptyNode, ::AbstractVector{UInt8}) = false

node_get_val(::EmptyNode{V}, ::AbstractVector{UInt8}) where {V} = nothing

function node_get_val_mut(::EmptyNode{V}, ::AbstractVector{UInt8}) where {V}
    nothing
end

function node_set_val!(::EmptyNode{V, A}, ::AbstractVector{UInt8}, ::V) where {V, A}
    error("EmptyNode::node_set_val! — unreachable (should be headed off upstream)")
end

function node_remove_val!(::EmptyNode, ::AbstractVector{UInt8}, ::Bool)
    error("EmptyNode::node_remove_val! — unreachable")
end

function node_create_dangling!(::EmptyNode, ::AbstractVector{UInt8})
    error("EmptyNode::node_create_dangling! — unreachable")
end

function node_remove_dangling!(::EmptyNode, ::AbstractVector{UInt8})
    error("EmptyNode::node_remove_dangling! — unreachable")
end

function node_set_branch!(::EmptyNode, ::AbstractVector{UInt8}, ::TrieNodeODRc)
    error("EmptyNode::node_set_branch! — unreachable (should be headed off upstream)")
end

node_remove_all_branches!(::EmptyNode, ::AbstractVector{UInt8}, ::Bool) = false

node_remove_unmasked_branches!(::EmptyNode, ::AbstractVector{UInt8}, ::ByteMask, ::Bool) =
    nothing

node_is_empty(::EmptyNode) = true

# `nothing` is the EmptyNode sentinel inside a TrieNodeODRc (see TrieNode.jl:360), so
# `as_tagged(rc)` legitimately yields `nothing` for an empty child. Callers that guard with
# `!node_is_empty(as_tagged(rc))` (e.g. DenseByteNode.jl:524, 962 in psubtract) need this
# method; without it psubtract over a node with an empty child rc crashes (`node_is_empty(::Nothing)`).
node_is_empty(::Nothing) = true

# ---------------------------------------------------------------------------------------------
# The REST of the `nothing`-as-EmptyNode-sentinel contract.
#
# `node_is_empty(::Nothing)` above established that a null inside a TrieNodeODRc IS the empty
# node. Only that one method existed, so every OTHER accessor blew up with
# `MethodError: no method matching node_<x>(::Nothing, …)` the moment a caller reached a null
# focus — which upstream's type system makes impossible (its `MutNodeStack` hands out a
# `&mut dyn TrieNode`, never a null), so there is no upstream guard to port and the call sites
# read as correct.
#
# The differential FUZZER found this: SEVEN of its 34 divergences were null-node MethodErrors
# across `node_get_child`, `node_get_val` and `node_remove_val!` — one contract hole surfacing in
# three functions, always as "an op empties the trie, then any further access". Fixing the three
# call sites would have been whack-a-mole; the rule is that EVERY read/removal must treat the
# sentinel as an empty node ([[feedback_recurring_defect_derive_the_rule]]).
#
# ⚠️ Deliberately NOT extended to the mutating constructors (`node_set_val!`, `node_set_branch!`,
# `node_create_dangling!`): writing INTO a null cannot be a no-op — it has to materialise a node —
# so those must keep failing loudly, exactly as the EmptyNode methods above do. Reads and removals
# have a correct empty answer; writes do not.
#
# These are behavioural claims, so they are checked by execution rather than argued: the fuzz gate
# (test/fuzz_gate.jl) compares every one of these paths against the upstream binary.
node_contains_partial_key(::Nothing, ::AbstractVector{UInt8}) = false

node_contains_val(::Nothing, ::AbstractVector{UInt8}) = false

node_get_val(::Nothing, ::AbstractVector{UInt8}) = nothing

node_get_val_mut(::Nothing, ::AbstractVector{UInt8}) = nothing

node_get_child(::Nothing, ::AbstractVector{UInt8}) = nothing

node_get_child_mut(::Nothing, ::AbstractVector{UInt8}) = nothing

# No value to remove, so nothing was removed.
node_remove_val!(::Nothing, ::AbstractVector{UInt8}, ::Bool) = nothing

# No branches to remove ⇒ removed nothing.
node_remove_all_branches!(::Nothing, ::AbstractVector{UInt8}, ::Bool) = false

node_remove_unmasked_branches!(::Nothing, ::AbstractVector{UInt8}, ::ByteMask, ::Bool) =
    nothing

# Returns the number of bytes pruned; an empty node has none.
node_remove_dangling!(::Nothing, ::AbstractVector{UInt8}) = 0

node_branches_mask(::Nothing, ::AbstractVector{UInt8}) = ByteMask()

# Nothing to take out of an empty node. (`get_node_at_key` is NOT here: its empty answer is
# `ANRNone{V,A}()`, which needs type params a bare `::Nothing` method cannot supply, so it is
# guarded at its call site in WriteZipper.jl instead.)
take_node_at_key!(::Nothing, ::AbstractVector{UInt8}, ::Bool) = nothing

new_iter_token(::EmptyNode) = UInt128(0)

iter_token_for_path(::EmptyNode, ::AbstractVector{UInt8}) = UInt128(0)

function next_items(::EmptyNode{V, A}, ::UInt128) where {V, A}
    # (next_token, path, child_node, value)
    (NODE_ITER_FINISHED, UInt8[], nothing, nothing)
end

node_val_count(::EmptyNode, ::Dict{UInt64, Int}) = 0
node_goat_val_count(::EmptyNode) = 0

function node_child_iter_start(::EmptyNode{V, A}) where {V, A}
    (UInt64(0), nothing)
end

function node_child_iter_next(::EmptyNode{V, A}, ::UInt64) where {V, A}
    (UInt64(0), nothing)
end

node_first_val_depth_along_key(::EmptyNode, ::AbstractVector{UInt8}) = nothing

function nth_child_from_key(::EmptyNode, ::AbstractVector{UInt8}, ::Int)
    (nothing, nothing)
end

function first_child_from_key(::EmptyNode, ::AbstractVector{UInt8})
    (nothing, nothing)
end

count_branches(::EmptyNode, ::AbstractVector{UInt8}) = 0

node_branches_mask(::EmptyNode, ::AbstractVector{UInt8}) = ByteMask()

prior_branch_key(::EmptyNode, ::AbstractVector{UInt8}) = UInt8[]

function get_sibling_of_child(::EmptyNode, ::AbstractVector{UInt8}, ::Bool)
    (nothing, nothing)
end

function get_node_at_key(e::EmptyNode{V, A}, ::AbstractVector{UInt8}) where {V, A}
    ANRNone{V, A}()
end

function take_node_at_key!(::EmptyNode, ::AbstractVector{UInt8}, ::Bool)
    nothing
end

# ------------------------------------------------------------------
# Lattice operations on EmptyNode (dispatch via pjoin_dyn etc.)
# ------------------------------------------------------------------
#
# Rust semantics:
#   pjoin_dyn(empty, other):   other.empty? → None   else → Identity(COUNTER)
#   join_into_dyn(empty, other): other.empty? → (None, Ok(())) else → (Element, Err(other))
#   pmeet_dyn(empty, other):   other.empty? → Identity(SELF|COUNTER) else → Identity(SELF)
#   psubtract_dyn: always None
#   prestrict_dyn: always None

function pjoin_dyn(e::EmptyNode{V, A}, other::AbstractTrieNode{V, A}) where {V, A}
    node_is_empty(other) ? AlgResNone() : AlgResIdentity(COUNTER_IDENT)
end

function join_into_dyn!(e::EmptyNode{V, A}, other::TrieNodeODRc{V, A}) where {V, A}
    if is_empty_node(other)
        (ALG_STATUS_NONE, nothing)      # Ok(())
    else
        (ALG_STATUS_ELEMENT, copy(other))  # Err(other)
    end
end

function drop_head_dyn!(::EmptyNode, ::Int)
    nothing
end

function pmeet_dyn(::EmptyNode{V, A}, other::AbstractTrieNode{V, A}) where {V, A}
    if node_is_empty(other)
        AlgResIdentity(SELF_IDENT | COUNTER_IDENT)
    else
        AlgResIdentity(SELF_IDENT)
    end
end

function psubtract_dyn(::EmptyNode{V, A}, ::AbstractTrieNode{V, A}) where {V, A}
    AlgResNone()
end

function prestrict_dyn(::EmptyNode{V, A}, ::AbstractTrieNode{V, A}) where {V, A}
    AlgResNone()
end

function clone_self(::EmptyNode)
    error("EmptyNode::clone_self — unreachable (change at call site)")
end

# TrieNodeDowncast equivalents
node_tag(::EmptyNode) = EMPTY_NODE_TAG

function convert_to_cell_node!(::EmptyNode)
    error("EmptyNode::convert_to_cell_node! — unreachable")
end

# =====================================================================
# Exports
# =====================================================================

export EmptyNode
