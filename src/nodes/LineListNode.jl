"""
LineListNode — port of `pathmap/src/line_list_node.rs`.

A compact 2-slot trie node storing up to two (key, value-or-child) pairs.
Total key bytes across both slots is bounded by KEY_BYTES_CNT (14, non-slim_ptrs).
When a key exceeds available space, continuation nodes are created.
When a third entry is required, the node upgrades to a DenseByteNode.

Slot ordering invariants (maintained by all mutating methods):
  - slot0 key ≤ slot1 key (byte-lexicographic)
  - keys may share at most one prefix byte
  - if slot0 holds a child pointer, slot1's key must not be a superset of slot0's key
  - key0.len() + key1.len() <= KEY_BYTES_CNT
"""

# =====================================================================
# Constants
# =====================================================================

"""
Maximum bytes available for inline key storage (non-slim_ptrs path).
"""
const KEY_BYTES_CNT = 14

# =====================================================================
# LineListNode type
# =====================================================================

"""
    LineListNode{V, A<:Allocator} <: AbstractTrieNode{V,A}

Compact 2-slot trie node. Corresponds to upstream `LineListNode<V,A>` plus
its `TrieNode<V,A>` impl. Upgraded to `DenseByteNode` when a third slot is needed.
"""
mutable struct LineListNode{V, A <: Allocator} <: AbstractTrieNode{V, A}
    slot0::Union{Nothing, ValOrChild{V, A}}   # nothing = slot0 unused
    slot1::Union{Nothing, ValOrChild{V, A}}   # nothing = slot1 unused
    key0::Vector{UInt8}   # key for slot0; empty iff slot0 === nothing
    key1::Vector{UInt8}   # key for slot1; empty iff slot1 === nothing
    alloc::A
    @atomic refcnt::UInt32   # node-keyed COW refcount (mirrors Rust slim_ptrs refcnt: AtomicU32)
    # Inner ctor keeps the existing 5-arg call convention; refcnt always starts at 1.
    LineListNode{V, A}(s0, s1, k0, k1, a) where {V, A <: Allocator} =
        new{V, A}(s0, s1, k0, k1, a, UInt32(1))
end

# =====================================================================
# Constructor
# =====================================================================

"""
    LineListNode{V,A}(alloc) → new empty node
"""
function LineListNode(alloc::A) where {A <: Allocator}
    error("LineListNode() requires explicit type parameters: LineListNode{V,A}(alloc)")
end

function LineListNode{V, A}(alloc::A) where {V, A <: Allocator}
    LineListNode{V, A}(nothing, nothing, UInt8[], UInt8[], alloc)
end

# =====================================================================
# Utility: prefix overlap + starts_with
# (ports fast_slice_utils::{find_prefix_overlap, starts_with})
# =====================================================================

@inline function find_prefix_overlap(
    a::AbstractVector{UInt8}, b::AbstractVector{UInt8}
)::Int
    n = min(length(a), length(b))
    @inbounds for i in 1:n
        a[i] != b[i] && return i - 1
    end
    n
end

@inline function slice_starts_with(
    a::AbstractVector{UInt8}, prefix::AbstractVector{UInt8}
)::Bool
    lp = length(prefix)
    length(a) >= lp && a[1:lp] == prefix
end

# =====================================================================
# Slot predicates — direct field access (replaces bit-packed header)
# =====================================================================

@inline is_used_0(n::LineListNode) = n.slot0 !== nothing
@inline is_used_1(n::LineListNode) = n.slot1 !== nothing
@inline is_used_both(n::LineListNode) = n.slot0 !== nothing && n.slot1 !== nothing

@inline is_child_0(n::LineListNode) = n.slot0 !== nothing && is_child(n.slot0)
@inline is_child_1(n::LineListNode) = n.slot1 !== nothing && is_child(n.slot1)

@inline is_value_0(n::LineListNode) = n.slot0 !== nothing && is_val(n.slot0)
@inline is_value_1(n::LineListNode) = n.slot1 !== nothing && is_val(n.slot1)

@inline key_len_0(n::LineListNode) = length(n.key0)
@inline key_len_1(n::LineListNode) = length(n.key1)

"""
    is_available_1(n) → Bool

True if slot1 is available to be filled: slot1 is empty AND the current key0
does not consume the full KEY_BYTES_CNT, leaving room for at least one key byte.
"""
@inline function is_available_1(n::LineListNode)::Bool
    !is_used_1(n) && key_len_0(n) < KEY_BYTES_CNT
end

"""
slot count in use (0, 1, or 2).
"""
@inline function used_slot_count(n::LineListNode)::Int
    is_used_0(n) ? (is_used_1(n) ? 2 : 1) : 0
end

"""
Returns (key0, key1) byte slices for both slots.
"""
@inline get_both_keys(n::LineListNode) = (n.key0, n.key1)

# =====================================================================
# Internal slot manipulation helpers
# =====================================================================

"""
    shift_1_to_0!(n)

Moves slot1 into slot0, erasing slot0. If slot1 is empty, clears slot0 too.
Mirrors Rust's `shift_1_to_0` (called after removing slot0 payload).
"""
function shift_1_to_0!(n::LineListNode)
    if is_used_1(n)
        n.slot0 = n.slot1
        n.key0 = copy(n.key1)
        n.slot1 = nothing
        n.key1 = UInt8[]
    else
        n.slot0 = nothing
        n.key0 = UInt8[]
    end
end

"""
    take_slot0_payload!(n) → Union{Nothing, ValOrChild{V,A}}

Removes and returns the payload from slot0, shifting slot1→slot0.
"""
function take_slot0_payload!(n::LineListNode{V, A}) where {V, A}
    is_used_0(n) || return nothing
    payload = n.slot0
    shift_1_to_0!(n)
    payload
end

"""
    take_slot1_payload!(n) → Union{Nothing, ValOrChild{V,A}}

Removes and returns the payload from slot1, leaving slot0 untouched.
"""
function take_slot1_payload!(n::LineListNode{V, A}) where {V, A}
    is_used_1(n) || return nothing
    payload = n.slot1
    n.slot1 = nothing
    n.key1 = UInt8[]
    payload
end

"""
    swap_slot0_payload!(n, new_payload) → old ValOrChild{V,A}

Replaces slot0's payload with `new_payload`, returning the old one.
"""
function swap_slot0_payload!(
    n::LineListNode{V, A}, new_payload::ValOrChild{V, A}
) where {V, A}
    @assert is_used_0(n)
    old = n.slot0
    n.slot0 = new_payload
    old
end

"""
    swap_slot1_payload!(n, new_payload) → old ValOrChild{V,A}

Replaces slot1's payload with `new_payload`, returning the old one.
"""
function swap_slot1_payload!(
    n::LineListNode{V, A}, new_payload::ValOrChild{V, A}
) where {V, A}
    @assert is_used_1(n)
    old = n.slot1
    n.slot1 = new_payload
    old
end

"""
    clone_slot0_payload(n) → Union{Nothing, ValOrChild{V,A}}
"""
function clone_slot0_payload(n::LineListNode{V, A}) where {V, A}
    is_used_0(n) ? deepcopy(n.slot0) : nothing
end

"""
    clone_slot1_payload(n) → Union{Nothing, ValOrChild{V,A}}
"""
function clone_slot1_payload(n::LineListNode{V, A}) where {V, A}
    is_used_1(n) ? deepcopy(n.slot1) : nothing
end

# =====================================================================
# Low-level slot setters (mirror Rust's unsafe set_payload_{0,1})
# =====================================================================

"""
    set_slot0!(n, key, payload)

Sets slot0 with `key` (must fit in KEY_BYTES_CNT bytes), clears slot1.
"""
function set_slot0!(
    n::LineListNode{V, A}, key::AbstractVector{UInt8}, payload::ValOrChild{V, A}
) where {V, A}
    @assert length(key) <= KEY_BYTES_CNT
    n.key0 = Vector{UInt8}(key)
    n.slot0 = payload
end

"""
    set_slot1!(n, key, payload)

Sets slot1 with `key` (remaining bytes must be available).
Requires slot0 to already be set.
"""
function set_slot1!(
    n::LineListNode{V, A}, key::AbstractVector{UInt8}, payload::ValOrChild{V, A}
) where {V, A}
    @assert length(n.key0) + length(key) <= KEY_BYTES_CNT
    n.key1 = Vector{UInt8}(key)
    n.slot1 = payload
end

# =====================================================================
# Overflow-aware setters
# (mirror Rust's set_payload_0_no_overflow / set_payload_1_no_overflow)
# =====================================================================

"""
    set_slot0_no_overflow!(n, key, payload) → Bool

Sets slot0 payload. If `key` exceeds KEY_BYTES_CNT, creates continuation nodes.
Returns true if a continuation node was created.
"""
function set_slot0_no_overflow!(
    n::LineListNode{V, A}, key::AbstractVector{UInt8}, payload::ValOrChild{V, A}
) where {V, A}
    if length(key) <= KEY_BYTES_CNT
        set_slot0!(n, key, payload)
        return false
    end
    # Create a chain of intermediate nodes to hold the long key
    node_cnt = (length(key) - 1) ÷ KEY_BYTES_CNT
    child_key = key[(node_cnt * KEY_BYTES_CNT + 1):end]
    child_node = LineListNode{V, A}(n.alloc)
    set_slot0!(child_node, child_key, payload)
    next_node = TrieNodeODRc(child_node, n.alloc)
    for idx in (node_cnt - 1):-1:1
        mid_key = key[(idx * KEY_BYTES_CNT + 1):((idx + 1) * KEY_BYTES_CNT)]
        mid_node = LineListNode{V, A}(n.alloc)
        set_slot0!(mid_node, mid_key, ValOrChild(next_node))
        next_node = TrieNodeODRc(mid_node, n.alloc)
    end
    top_key = key[1:KEY_BYTES_CNT]
    set_slot0!(n, top_key, ValOrChild(next_node))
    true
end

"""
    set_slot1_no_overflow!(n, key, payload) → Bool

Sets slot1 payload. If `key` doesn't fit in remaining KEY_BYTES_CNT space,
creates a continuation chain. Handles the split-if-full case.
Returns true if a continuation node was created.
"""
function set_slot1_no_overflow!(
    n::LineListNode{V, A}, key::AbstractVector{UInt8}, payload::ValOrChild{V, A}
) where {V, A}
    @assert !is_used_1(n)
    if is_available_1(n)
        remaining = KEY_BYTES_CNT - key_len_0(n)
        if length(key) <= remaining
            set_slot1!(n, key, payload)
            return false
        else
            # Key overflows slot1; create a child node for the tail
            child_node = LineListNode{V, A}(n.alloc)
            set_slot0_no_overflow!(child_node, key[(remaining + 1):end], payload)
            child_rc = TrieNodeODRc(child_node, n.alloc)
            set_slot1!(n, key[1:remaining], ValOrChild(child_rc))
            return true
        end
    else
        # slot0 key consumes full KEY_BYTES_CNT — split it to make room
        split_slot0!(n, KEY_BYTES_CNT ÷ 2)
        set_slot1_no_overflow!(n, key, payload)
        return true
    end
end

"""
    set_slot0_shift_existing!(n, key, payload) → Bool

Shifts current slot0 into slot1 and places `(key, payload)` into slot0.
Returns true if a continuation node was created.
"""
function set_slot0_shift_existing!(
    n::LineListNode{V, A}, key::AbstractVector{UInt8}, payload::ValOrChild{V, A}
) where {V, A}
    @assert is_used_0(n) && !is_used_1(n)
    if is_available_1(n)
        old_key = copy(n.key0)
        old_payload = n.slot0
        remaining = KEY_BYTES_CNT - length(old_key)
        new_key_final, new_payload_final, created = if length(key) <= remaining
            (key, payload, false)
        else
            # tail of new key needs a continuation node
            child_node = LineListNode{V, A}(n.alloc)
            set_slot0_no_overflow!(child_node, key[(remaining + 1):end], payload)
            child_rc = TrieNodeODRc(child_node, n.alloc)
            (view(key, 1:remaining), ValOrChild(child_rc), true)
        end
        # write key for slot0 (new key) then key for slot1 (old key)
        n.key0 = Vector{UInt8}(new_key_final)
        n.slot0 = new_payload_final
        n.key1 = old_key
        n.slot1 = old_payload
        return created
    else
        split_slot0!(n, KEY_BYTES_CNT ÷ 2)
        set_slot0_shift_existing!(n, key, payload)
        return true
    end
end

# =====================================================================
# Split helpers
# =====================================================================

"""
    split_slot0!(n, idx)

Splits the key in slot0 at `idx` (exclusive length). The suffix `key0[idx+1:]`
remains in slot0 under a new child node; the prefix `key0[1:idx]` becomes the
new slot0 key pointing at that child.
"""
function split_slot0!(n::LineListNode{V, A}, idx::Int) where {V, A}
    old_key = n.key0
    old_payload = n.slot0
    child_node = LineListNode{V, A}(n.alloc)
    set_slot0!(child_node, old_key[(idx + 1):end], old_payload)
    child_rc = TrieNodeODRc(child_node, n.alloc)
    # Shift slot1 key to follow the new shorter slot0 key
    if is_used_1(n)
        n.key0 = old_key[1:idx]
        n.slot0 = ValOrChild(child_rc)
        # slot1 key stays, already correct
    else
        n.key0 = old_key[1:idx]
        n.slot0 = ValOrChild(child_rc)
    end
end

"""
    split_slot1!(n, idx)

Splits the key in slot1 at `idx`. The suffix remains in the new slot1 under a
child node; slot1's key becomes the prefix pointing at that child.
"""
function split_slot1!(n::LineListNode{V, A}, idx::Int) where {V, A}
    @assert is_used_1(n)
    old_key = n.key1
    old_payload = n.slot1
    child_node = LineListNode{V, A}(n.alloc)
    set_slot0!(child_node, old_key[(idx + 1):end], old_payload)
    child_rc = TrieNodeODRc(child_node, n.alloc)
    n.key1 = old_key[1:idx]
    n.slot1 = ValOrChild(child_rc)
end

"""
    shorten_key_0!(n, new_len)

Shortens the key in slot0 to `new_len` bytes, adjusting slot1's storage
(which is physically contiguous in the Rust impl; in Julia keys are independent).
"""
function shorten_key_0!(n::LineListNode, new_len::Int)
    @assert new_len <= length(n.key0)
    resize!(n.key0, new_len)
end

function shorten_key_1!(n::LineListNode, new_len::Int)
    @assert new_len <= length(n.key1)
    resize!(n.key1, new_len)
end

# =====================================================================
# remove_dangling_payload_along_key!
# =====================================================================

"""
    remove_dangling_payload_along_key!(n, key)

If any slot holds a sentinel empty-node child whose key is a prefix of `key`,
remove that dangling entry.
"""
function remove_dangling_payload_along_key!(
    n::LineListNode{V, A}, key::AbstractVector{UInt8}
) where {V, A}
    if is_child_0(n)
        child_rc = into_child(n.slot0)
        if is_empty_node(child_rc) && slice_starts_with(key, n.key0)
            take_slot0_payload!(n)
        end
    end
    if is_child_1(n)
        child_rc = into_child(n.slot1)
        if is_empty_node(child_rc) && slice_starts_with(key, n.key1)
            take_slot1_payload!(n)
        end
    end
end

# =====================================================================
# get_child_mut-equivalent helper
# =====================================================================

"""
    get_child_for_key(n, key) → Union{Nothing, Tuple{Int, ValOrChild{V,A}}}

Returns `(consumed_bytes, slot_index)` for the first slot whose key is a
prefix of `key` and whose payload is a non-empty child, or `nothing`.
In Julia we can't return a mutable ref, so callers use the slot index.
"""
function _find_child_slot(n::LineListNode{V, A}, key::AbstractVector{UInt8}) where {V, A}
    if is_child_0(n)
        klen = key_len_0(n)
        if length(key) >= klen && key[1:klen] == n.key0
            child_rc = into_child(n.slot0)
            is_empty_node(child_rc) || return (klen, 0)
        end
    end
    if is_child_1(n)
        klen = key_len_1(n)
        if length(key) >= klen && key[1:klen] == n.key1
            child_rc = into_child(n.slot1)
            is_empty_node(child_rc) || return (klen, 1)
        end
    end
    nothing
end

# =====================================================================
# clone_with_updated_payloads helper
# (mirrors Rust's `clone_with_updated_payloads`)
# =====================================================================

function clone_with_updated_payloads(
    n::LineListNode{V, A}, payload0::Union{Nothing, ValOrChild{V, A}},
    payload1::Union{Nothing, ValOrChild{V, A}}
) where {V, A}
    if payload0 !== nothing && payload1 !== nothing
        new_n = LineListNode{V, A}(n.alloc)
        set_slot0!(new_n, n.key0, payload0)
        set_slot1!(new_n, n.key1, payload1)
        return new_n
    elseif payload0 !== nothing
        new_n = LineListNode{V, A}(n.alloc)
        set_slot0!(new_n, n.key0, payload0)
        return new_n
    elseif payload1 !== nothing
        new_n = LineListNode{V, A}(n.alloc)
        set_slot0!(new_n, n.key1, payload1)   # slot1 → slot0 in the new single-slot node
        return new_n
    else
        return nothing
    end
end

# =====================================================================
# should_swap_keys helper
# =====================================================================

"""
    should_swap_keys(key0, key1) → Bool

Returns true if `key1` should go in slot0 (i.e. `key1 < key0` or same first byte
but `key1` is shorter), preserving the invariant that slot0 key ≤ slot1 key.
"""
function should_swap_keys(key0::AbstractVector{UInt8}, key1::AbstractVector{UInt8})::Bool
    (isempty(key0) || isempty(key1)) && return false
    key0[1] > key1[1] && return true
    key0[1] == key1[1] && length(key0) > length(key1) && return true
    false
end

# =====================================================================
# validate_node (debug invariant checker)
# =====================================================================

function validate_list_node(n::LineListNode)::Bool
    (k0, k1) = get_both_keys(n)
    is_used_0(n) && isempty(k0) && (println("Invalid: zero-length key0 $(n)"); return false)
    is_used_1(n) && isempty(k1) && (println("Invalid: zero-length key1 $(n)"); return false)
    if is_child_0(n) && is_used_1(n) && slice_starts_with(k1, k0) && length(k1) > length(k0)
        println("Invalid: ambiguous path violation");
        return false
    end
    if is_used_1(n) && length(k0) > length(k1) && slice_starts_with(k0, k1)
        println("Invalid: ordering violation");
        return false
    end
    if length(k0) >= 2 && length(k1) >= 2 && k0[1] == k1[1] && k0[2] == k1[2]
        println("Invalid: prefix too long (>1 byte)");
        return false
    end
    if !is_used_1(n) && is_child_1(n)
        println("Invalid: slot1 child bit set while slot1 empty");
        return false
    end
    if length(k0) + length(k1) > KEY_BYTES_CNT
        println("Invalid: key lengths exceed KEY_BYTES_CNT");
        return false
    end
    if length(k0) == KEY_BYTES_CNT && is_used_1(n)
        println("Invalid: slot0 saturates key storage but slot1 is filled");
        return false
    end
    if is_used_1(n) && k0 > k1
        println("Invalid: keys not sorted");
        return false
    end
    true
end

# =====================================================================
# _convert_to_dense! — upgrade LineListNode → DenseByteNode
# =====================================================================

"""
    _convert_to_dense!(n, capacity) → TrieNodeODRc

Creates a DenseByteNode containing all entries from `n` and returns it as a
new `TrieNodeODRc`. Ports the `convert_to_dense` path in upstream. Called
when a third slot is required and the two existing slots cannot share a key.
"""
function _convert_to_dense!(n::LineListNode{V, A}, capacity::Int) where {V, A}
    dense = DenseByteNode{V, A}(n.alloc, capacity)   # upstream: with_capacity_in(capacity, alloc)
    merge_from_list_node!(dense, n)
    TrieNodeODRc(dense, n.alloc)
end

# =====================================================================
# remove_subtries! (used by node_remove_all_branches! + node_remove_unmasked_branches!)
# =====================================================================

function remove_subtries!(
    n::LineListNode{V, A}, remove_0::Bool, remove_1::Bool, key0_starts_with::Bool,
    prune::Bool, key_len::Int
) where {V, A}
    # Process slot1 first to avoid shifting interference
    if remove_1
        if prune || key0_starts_with || key_len == 0
            take_slot1_payload!(n)
        else
            shorten_key_1!(n, key_len)
            n.slot1 = ValOrChild(TrieNodeODRc{V, A}())   # empty sentinel
        end
    end
    if remove_0
        if prune || key_len == 0
            take_slot0_payload!(n)
        else
            shorten_key_0!(n, key_len)
            n.slot0 = ValOrChild(TrieNodeODRc{V, A}())   # empty sentinel
        end
    end
end

# =====================================================================
# set_payload_abstract! — high-level set (mirrors Rust set_payload_abstract)
# IS_CHILD: true = child pointer, false = value
# Returns either:
#   Ok((old_payload::Union{Nothing,V}, created_subnode::Bool))  → (old_payload, created)
#   Err(new_rc)  → node must be replaced by new_rc (upgrade to DenseByteNode)
# Julia mapping: return a NamedTuple distinguishing success vs. upgrade
# =====================================================================

abstract type AbstractSetPayloadResult{V, A} end
struct SetPayloadOk{V, A} <: AbstractSetPayloadResult{V, A}
    old_payload::Union{Nothing, V}   # replaced value (nothing if new insert or IS_CHILD)
    created_subnode::Bool
end
struct SetPayloadUpgrade{V, A} <: AbstractSetPayloadResult{V, A}
    replacement::TrieNodeODRc{V, A}
end

"""
    set_payload_abstract!(n, is_child, key, payload) → AbstractSetPayloadResult

Inserts `(key, payload)` into the node:

  - If the key exactly replaces an existing entry: Ok(old, false)
  - If a new slot or sub-node was created: Ok(nothing, bool)
  - If both slots are full and no key overlap → upgrade needed: Upgrade(new_dense_rc)
"""
function set_payload_abstract!(
    n::LineListNode{V, A}, is_child::Bool, key::AbstractVector{UInt8},
    payload::ValOrChild{V, A}
) where {V, A}
    @assert !isempty(key)

    # Recursively set in a child slot
    function set_recursive(child_rc::TrieNodeODRc{V, A}, sub_key::AbstractVector{UInt8})
        child = as_tagged(child_rc)
        if is_child
            inner_rc = into_child(payload)
            res = node_set_branch!(child, sub_key, inner_rc)
            # node_set_branch! returns Bool on success or TrieNodeODRc on upgrade
            return if res isa TrieNodeODRc
                SetPayloadUpgrade{V, A}(res)
            else
                # `created_subnode` is TRUE unconditionally — upstream hardcodes it in BOTH arms
                # (`.map(|_| (None, true))` for the child arm, `.map(|(ret_val, _)| (ret_val, true))`
                # for the value arm; line_list_node.rs:944-951). We reach here only via `split_0`,
                # which by definition JUST CREATED a subnode at THIS level — what the recursive
                # call reports about ITS own slot is a different question and must not be
                # forwarded.
                #
                # ⚠️ The value arm below already hardcoded `true`; only this one forwarded `res`,
                # so the bug was an asymmetry inside this function. Forwarding a `false` made
                # `node_set_branch!` under-report, `_wz_graft_internal!` then skipped its
                # `mend_root!` + `descend_to_internal!`, and the zipper kept pointing at the parent
                # while the split had moved the value down into the new child — so the follow-up
                # `wz_remove_val!` could not FIND a value the read zipper still enumerated.
                # Symptom: graft_map at a focus that holds a value left it behind
                # (`[:ab,:abaaa]` vs upstream `[:abaaa]`). Fuzz 00106/00111/00234/00281.
                SetPayloadOk{V, A}(nothing, true)
            end
        else
            val = into_val(payload)
            r2 = node_set_val!(child, sub_key, val)
            if r2 isa TrieNodeODRc
                return SetPayloadUpgrade{V, A}(r2)
            else
                (old_val, _) = r2
                return SetPayloadOk{V, A}(old_val, true)
            end
        end
    end

    # Check if there's already an exact match → replace
    if is_child
        if is_child_0(n) && n.key0 == key
            old = swap_slot0_payload!(n, payload)
            return SetPayloadOk{V, A}(nothing, false)
        end
        if is_child_1(n) && n.key1 == key
            old = swap_slot1_payload!(n, payload)
            return SetPayloadOk{V, A}(nothing, false)
        end
    else
        if is_value_0(n) && n.key0 == key
            old = swap_slot0_payload!(n, payload)
            return SetPayloadOk{V, A}(into_val(old), false)
        end
        if is_value_1(n) && n.key1 == key
            old = swap_slot1_payload!(n, payload)
            return SetPayloadOk{V, A}(into_val(old), false)
        end
    end

    # Remove any dangling empty-node placeholders along this key path
    remove_dangling_payload_along_key!(n, key)

    # Slot0 is empty → just insert
    if !is_used_0(n)
        created = set_slot0_no_overflow!(n, key, payload)
        return SetPayloadOk{V, A}(nothing, created)
    end

    # Check overlap with slot0 key
    node_key_0 = n.key0
    overlap = find_prefix_overlap(key, node_key_0)
    if overlap > 0
        # Replace existing child branch at same key
        if is_child && is_child_0(n) && overlap == length(key)
            take_slot0_payload!(n)
            return set_payload_abstract!(n, is_child, key, payload)
        end
        # Determine split depth
        if overlap == length(node_key_0) || overlap == length(key)
            overlap -= 1
        end
        if overlap > 0
            split_slot0!(n, overlap)
            child_rc = into_child(n.slot0)
            child_mut = as_tagged(child_rc)
            return set_recursive(child_rc, key[(overlap + 1):end])
        end
    end

    # Slot1 is empty → try to fill it
    if !is_used_1(n)
        created = if should_swap_keys(node_key_0, key)
            set_slot0_shift_existing!(n, key, payload)
        else
            set_slot1_no_overflow!(n, key, payload)
        end
        return SetPayloadOk{V, A}(nothing, created)
    end

    # Check overlap with slot1 key
    node_key_1 = n.key1
    overlap1 = find_prefix_overlap(key, node_key_1)
    if overlap1 > 0
        if is_child && is_child_1(n) && overlap1 == length(key)
            take_slot1_payload!(n)
            return set_payload_abstract!(n, is_child, key, payload)
        end
        if overlap1 == length(node_key_1) || overlap1 == length(key)
            overlap1 -= 1
        end
        if overlap1 > 0
            split_slot1!(n, overlap1)
            child_rc = into_child(n.slot1)
            return set_recursive(child_rc, key[(overlap1 + 1):end])
        end
    end

    # Both slots full and no useful overlap → upgrade to DenseByteNode.
    # The upgrade node must include the NEW (key, payload) entry, mirroring
    # Rust's set_payload_abstract upgrade block (line_list_node.rs:1013-1040).
    dense_rc = _convert_to_dense!(n, 3)
    dense_node = as_tagged(dense_rc)::DenseByteNode{V, A}
    k0 = key[1]
    if length(key) > 1
        # Wrap the tail in a new LineListNode child
        child = LineListNode{V, A}(n.alloc)
        sub_key = key[2:end]
        if is_child
            inner_rc = into_child(payload)
            node_set_branch!(child, sub_key, inner_rc)
        else
            val = into_val(payload)
            r = node_set_val!(child, sub_key, val)
            @assert !(r isa TrieNodeODRc) "unexpected upgrade in fresh LineListNode"
        end
        _bn_set_child!(dense_node, k0, TrieNodeODRc(child, n.alloc))
    else
        # Single-byte key: insert directly into DenseByteNode
        if is_child
            _bn_set_child!(dense_node, k0, into_child(payload))
        else
            _bn_set_val!(dense_node, k0, into_val(payload))
        end
    end
    SetPayloadUpgrade{V, A}(dense_rc)
end

# =====================================================================
# TrieNode interface implementation for LineListNode
# =====================================================================

function node_key_overlap(n::LineListNode, key::AbstractVector{UInt8})
    (k0, k1) = get_both_keys(n)
    max(find_prefix_overlap(key, k0), find_prefix_overlap(key, k1))
end

function node_contains_partial_key(n::LineListNode, key::AbstractVector{UInt8})
    slice_starts_with(n.key0, key) || slice_starts_with(n.key1, key)
end

function node_get_child(n::LineListNode{V, A}, key::AbstractVector{UInt8}) where {V, A}
    # Mirrors upstream node_get_child: returns child even if empty (dangling).
    # Empty (dangling) children represent structural path bookmarks created by
    # wz_create_path! — they must be traversable for path_exists_at to work.
    if is_child_0(n)
        klen = key_len_0(n)
        if length(key) >= klen && key[1:klen] == n.key0
            return (klen, into_child(n.slot0))
        end
    end
    if is_child_1(n)
        klen = key_len_1(n)
        if length(key) >= klen && key[1:klen] == n.key1
            return (klen, into_child(n.slot1))
        end
    end
    nothing
end

function node_get_child_mut(n::LineListNode{V, A}, key::AbstractVector{UInt8}) where {V, A}
    node_get_child(n, key)   # Julia: no mutable reference distinction; same semantics
end

function node_replace_child!(
    n::LineListNode{V, A}, key::AbstractVector{UInt8}, new_rc::TrieNodeODRc{V, A}
) where {V, A}
    if is_child_0(n)
        klen = key_len_0(n)
        if length(key) >= klen && key[1:klen] == n.key0
            @assert klen == length(key)
            n.slot0 = ValOrChild(new_rc)
            return nothing
        end
    end
    if is_child_1(n)
        klen = key_len_1(n)
        if length(key) >= klen && key[1:klen] == n.key1
            @assert klen == length(key)
            n.slot1 = ValOrChild(new_rc)
            return nothing
        end
    end
    error("LineListNode::node_replace_child! — child key not found")
end

function node_get_payloads(n::LineListNode{V, A}, keys_expect_val, results_buf) where {V, A}
    slot0_requested = !is_used_0(n)
    slot1_requested = !is_used_1(n)
    (k0, k1) = get_both_keys(n)
    for (i, (key, expect_val)) in enumerate(keys_expect_val)
        if is_used_0(n) && slice_starts_with(key, k0)
            klen = key_len_0(n)
            if is_child_0(n)
                if !expect_val || klen < length(key)
                    slot0_requested = true
                    results_buf[i] = (
                        klen, PayloadRef{V, A}(0x2, nothing, into_child(n.slot0))
                    )
                end
            else
                if expect_val && klen == length(key)
                    slot0_requested = true
                    results_buf[i] = (
                        klen, PayloadRef{V, A}(0x1, Ref{V}(into_val(n.slot0)), nothing)
                    )
                end
            end
        end
        if is_used_1(n) && slice_starts_with(key, k1)
            klen = key_len_1(n)
            if is_child_1(n)
                if !expect_val || klen < length(key)
                    slot1_requested = true
                    results_buf[i] = (
                        klen, PayloadRef{V, A}(0x2, nothing, into_child(n.slot1))
                    )
                end
            else
                if expect_val && klen == length(key)
                    slot1_requested = true
                    results_buf[i] = (
                        klen, PayloadRef{V, A}(0x1, Ref{V}(into_val(n.slot1)), nothing)
                    )
                end
            end
        end
    end
    slot0_requested && slot1_requested
end

function node_contains_val(n::LineListNode, key::AbstractVector{UInt8})
    (is_value_0(n) && n.key0 == key) || (is_value_1(n) && n.key1 == key)
end

function node_get_val(n::LineListNode{V, A}, key::AbstractVector{UInt8}) where {V, A}
    is_value_0(n) && n.key0 == key && return into_val(n.slot0)
    is_value_1(n) && n.key1 == key && return into_val(n.slot1)
    nothing
end

function node_get_val_mut(n::LineListNode{V, A}, key::AbstractVector{UInt8}) where {V, A}
    node_get_val(n, key)   # Julia: no mutable reference distinction
end

"""
    node_set_val!(n, key, val) → Union{Tuple, TrieNodeODRc}

Returns `(old_val::Union{Nothing,V}, created_subnode::Bool)` on success,
or a `TrieNodeODRc` replacement node when upgrade to DenseByteNode is needed.
"""
function node_set_val!(
    n::LineListNode{V, A}, key::AbstractVector{UInt8}, val::V
) where {V, A}
    @assert !isempty(key)
    res = set_payload_abstract!(n, false, key, ValOrChild(val))
    if res isa SetPayloadOk
        return (res.old_payload, res.created_subnode)
    else
        return res.replacement
    end
end

function node_remove_val!(
    n::LineListNode{V, A}, key::AbstractVector{UInt8}, prune::Bool
) where {V, A}
    if is_value_0(n)
        k0 = n.key0
        if k0 == key
            if prune
                return into_val(take_slot0_payload!(n))
            else
                # Turn into dangling empty node if the path isn't preserved by slot1
                k1 = n.key1
                overlap = find_prefix_overlap(k0, k1)
                if length(k0) == overlap
                    return into_val(take_slot0_payload!(n))
                else
                    old = swap_slot0_payload!(n, ValOrChild(TrieNodeODRc{V, A}()))
                    return into_val(old)
                end
            end
        end
    end
    if is_value_1(n) && n.key1 == key
        if prune
            return into_val(take_slot1_payload!(n))
        else
            # 🔴 THE SAME GUARD THE SLOT-0 BRANCH ABOVE ALREADY HAD — ports upstream `02afb73`.
            # `prune=false` keeps the path alive for a positioned write zipper by turning the removed
            # value into an EMPTY SENTINEL CHILD. That is only safe when the other slot does not
            # already keep this path: if it does, the node ends up holding TWO CHILDREN UNDER ONE
            # KEY, which is not a valid LineListNode, and everything walking it downstream sees a
            # truncated trie.
            #
            # Reached constantly, because `graft_map` with a source that has NO root value runs
            # `remove_val(false)` immediately after planting the child (write_zipper.rs:1473) — so the
            # other slot is exactly where the freshly grafted child sits.
            #
            # Fuzz 02004 is the witness: after this ran, `val_count` said 4 while enumeration reached
            # ONE path. The values were still counted and no longer reachable. Only slot 0 was
            # guarded here; slot 1 swapped unconditionally.
            k0 = n.key0
            overlap = find_prefix_overlap(n.key1, k0)
            if length(n.key1) == overlap
                return into_val(take_slot1_payload!(n))
            else
                old = swap_slot1_payload!(n, ValOrChild(TrieNodeODRc{V, A}()))
                return into_val(old)
            end
        end
    end
    nothing
end

"""
    node_create_dangling!(n, key) → Union{Tuple{Bool,Bool}, TrieNodeODRc}

Creates a sentinel empty-node child at `key` if the key is not already present.
Returns `(was_created::Bool, created_subnode::Bool)` or a replacement node.
"""
function node_create_dangling!(
    n::LineListNode{V, A}, key::AbstractVector{UInt8}
) where {V, A}
    @assert !isempty(key)
    if !node_contains_partial_key(n, key)
        res = set_payload_abstract!(n, true, key, ValOrChild(TrieNodeODRc{V, A}()))
        if res isa SetPayloadOk
            return (true, res.created_subnode)
        else
            return res.replacement
        end
    end
    (false, false)
end

function node_remove_dangling!(
    n::LineListNode{V, A}, key::AbstractVector{UInt8}
) where {V, A}
    @assert !isempty(key)
    (k0, k1) = get_both_keys(n)
    if is_child_0(n) && k0 == key
        child_rc = into_child(n.slot0)
        if is_empty_node(child_rc)
            pruned = if is_used_1(n) && !isempty(k1) && (isempty(key) || key[1] == k1[1])
                length(key) - 1
            else
                length(key)
            end
            take_slot0_payload!(n)
            return pruned
        end
    end
    if is_child_1(n) && k1 == key
        child_rc = into_child(n.slot1)
        if is_empty_node(child_rc)
            pruned = if !isempty(k0) && !isempty(key) && key[1] == k0[1]
                length(key) - 1
            else
                length(key)
            end
            take_slot1_payload!(n)
            return pruned
        end
    end
    0
end

"""
    node_set_branch!(n, key, new_rc) → Union{Bool, TrieNodeODRc}

Returns `created_subnode::Bool` on success, or replacement node on upgrade.
"""
function node_set_branch!(
    n::LineListNode{V, A}, key::AbstractVector{UInt8}, new_rc::TrieNodeODRc{V, A}
) where {V, A}
    res = set_payload_abstract!(n, true, key, ValOrChild(new_rc))
    if res isa SetPayloadOk
        return res.created_subnode
    else
        return res.replacement
    end
end

function node_remove_all_branches!(
    n::LineListNode{V, A}, key::AbstractVector{UInt8}, prune::Bool
) where {V, A}
    klen = length(key)
    (k0, k1) = get_both_keys(n)
    k0sw = slice_starts_with(k0, key)
    remove_0 = k0sw && (length(k0) > klen || is_child_0(n))
    remove_1 = slice_starts_with(k1, key) && (length(k1) > klen || is_child_1(n))
    remove_subtries!(n, remove_0, remove_1, k0sw, prune, klen)
    remove_0 || remove_1
end

function node_remove_unmasked_branches!(
    n::LineListNode{V, A}, key::AbstractVector{UInt8}, mask::ByteMask, prune::Bool
) where {V, A}
    klen = length(key)
    (k0, k1) = get_both_keys(n)
    remove_0 = false
    remove_1 = false
    k0sw = slice_starts_with(k0, key)
    if k0sw && length(k0) > klen
        remove_0 = !test_bit(mask, k0[klen + 1])
    end
    if slice_starts_with(k1, key) && length(k1) > klen
        remove_1 = !test_bit(mask, k1[klen + 1])
    end
    remove_subtries!(n, remove_0, remove_1, k0sw, prune, klen)
end

node_is_empty(n::LineListNode) = !is_used_0(n)

# =====================================================================
# Iteration
# =====================================================================

# iter_token meanings for LineListNode:
#   0 = not yet begun → next_items returns slot0 entry
#   1 = slot0 returned → next_items returns slot1 if present
#   2 = slot1 returned → done

new_iter_token(::LineListNode) = UInt128(0)

function iter_token_for_path(n::LineListNode, key::AbstractVector{UInt8})
    isempty(key) && return UInt128(0)
    (k0, k1) = get_both_keys(n)
    key < k0 && return UInt128(0)
    key < k1 && return UInt128(1)
    key == k1 && return UInt128(2)
    NODE_ITER_FINISHED
end

function next_items(n::LineListNode{V, A}, token::UInt128) where {V, A}
    if token == UInt128(0)
        !is_used_0(n) && return (NODE_ITER_FINISHED, UInt8[], nothing, nothing)
        (k0, k1) = get_both_keys(n)
        child = nothing
        value = nothing
        next_tok = UInt128(1)
        if is_child_0(n)
            child = into_child(n.slot0)
        else
            value = into_val(n.slot0)
        end
        # If slot0 and slot1 share the same key, return both at once
        if is_used_1(n) && k0 == k1
            if is_child_1(n)
                child = into_child(n.slot1)
            else
                value = into_val(n.slot1)
            end
            next_tok = UInt128(2)
        end
        return (next_tok, copy(k0), child, value)
    elseif token == UInt128(1)
        if is_used_1(n)
            k1 = n.key1
            child = nothing
            value = nothing
            if is_child_1(n)
                child = into_child(n.slot1)
            else
                value = into_val(n.slot1)
            end
            return (UInt128(2), copy(k1), child, value)
        else
            return (NODE_ITER_FINISHED, UInt8[], nothing, nothing)
        end
    else
        return (NODE_ITER_FINISHED, UInt8[], nothing, nothing)
    end
end

# =====================================================================
# node_val_count / node_goat_val_count
# =====================================================================

function node_val_count(n::LineListNode, cache::Dict{UInt64, Int})
    result = 0
    is_value_0(n) && (result += 1)
    is_value_1(n) && (result += 1)
    if is_child_0(n)
        child_rc = into_child(n.slot0)
        # skip empty-sentinel children (node == nothing means TrieNodeODRc::new_empty)
        !is_empty_node(child_rc) && (result += node_val_count(as_tagged(child_rc), cache))
    end
    if is_child_1(n)
        child_rc = into_child(n.slot1)
        !is_empty_node(child_rc) && (result += node_val_count(as_tagged(child_rc), cache))
    end
    result
end

function node_goat_val_count(n::LineListNode)
    Int(is_value_0(n)) + Int(is_value_1(n))
end

# =====================================================================
# child iterator
# =====================================================================

function node_child_iter_start(n::LineListNode{V, A}) where {V, A}
    is_child_0(n) && return (UInt64(1), into_child(n.slot0))
    is_child_1(n) && return (UInt64(2), into_child(n.slot1))
    (UInt64(0), nothing)
end

function node_child_iter_next(n::LineListNode{V, A}, token::UInt64) where {V, A}
    token == UInt64(1) && is_child_1(n) && return (UInt64(2), into_child(n.slot1))
    (UInt64(0), nothing)
end

# =====================================================================
# first_val_depth_along_key
# =====================================================================

function node_first_val_depth_along_key(n::LineListNode, key::AbstractVector{UInt8})
    @assert !isempty(key)
    (k0, k1) = get_both_keys(n)
    is_value_0(n) && slice_starts_with(key, k0) && return length(k0) - 1
    is_value_1(n) && slice_starts_with(key, k1) && return length(k1) - 1
    nothing
end

# =====================================================================
# nth_child_from_key
# =====================================================================

function nth_child_from_key(
    n::LineListNode{V, A}, key::AbstractVector{UInt8}, idx::Int
) where {V, A}
    (k0, k1) = get_both_keys(n)
    klen = length(key)
    if idx == 0
        if slice_starts_with(k0, key) && length(k0) > klen
            if k0 != k1
                if klen + 1 == length(k0) && is_child_0(n)
                    return (k0[klen + 1], as_tagged(into_child(n.slot0)))
                else
                    return (k0[klen + 1], nothing)
                end
            end
            # 🔴 BOTH SLOTS HOLD THE SAME KEY — ports upstream `987bebf`.
            # A LineListNode keeps the VALUE at a path and the ONWARD CHILD at that same path in its
            # two slots, under one key. We used to fall straight THROUGH this branch and then look
            # for the child in slot 1 only, so a child sitting in slot 0 was reported as "no child"
            # — where `node_get_child` checks both slots and finds it.
            #
            # The damage is not local: `wz_descend_indexed_byte!`/`ez_descend_indexed_byte!` descend
            # BY INDEX through here, so the zipper's focus stayed in the PARENT node. The position
            # then reports child_count 0 and an empty child mask, which silently TRUNCATES anything
            # walking the trie that way — path enumeration, and upstream notes the cached
            # catamorphisms and `PathMap::hash` too.
            #
            # Caught by fuzz cases 01959 (`[] vc=3` — zero paths enumerated where three exist) and
            # 02004 (one of four), which only became visible once the vendored upstream was updated:
            # the old ground truth had this same bug baked in on BOTH sides.
            if klen + 1 == length(k0)
                is_child_0(n) && return (k0[klen + 1], as_tagged(into_child(n.slot0)))
                is_child_1(n) && return (k0[klen + 1], as_tagged(into_child(n.slot1)))
            end
            return (k0[klen + 1], nothing)
        end
        if slice_starts_with(k1, key) && length(k1) > klen
            if klen + 1 == length(k1) && is_child_1(n)
                return (k1[klen + 1], as_tagged(into_child(n.slot1)))
            else
                return (k1[klen + 1], nothing)
            end
        end
    elseif idx == 1
        if is_used_1(n)
            klen > 0 && return (nothing, nothing)
            if !isempty(k1)
                (!isempty(k0) && k0[1] == k1[1]) && return (nothing, nothing)
                if length(k1) == 1 && is_child_1(n)
                    return (k1[klen + 1], as_tagged(into_child(n.slot1)))
                else
                    return (k1[1], nothing)
                end
            end
        end
    end
    (nothing, nothing)
end

# =====================================================================
# first_child_from_key
# =====================================================================

function first_child_from_key(
    n::LineListNode{V, A}, key::AbstractVector{UInt8}
) where {V, A}
    (k0, k1) = get_both_keys(n)
    !is_used_0(n) && return (nothing, nothing)

    # Case 1: zero-length key
    if isempty(key)
        if !isempty(k1) && !isempty(k0) && k0[1] == k1[1]
            if length(k0) == 1 && is_child_0(n)
                return (copy(k0), as_tagged(into_child(n.slot0)))
            end
            if length(k1) == 1 && is_child_1(n)
                return (copy(k0), as_tagged(into_child(n.slot1)))
            end
            return (k0[1:1], nothing)
        else
            if is_child_0(n)
                return (copy(k0), as_tagged(into_child(n.slot0)))
            else
                return (copy(k0), nothing)
            end
        end
    end

    # Case 2 & 3: key.len() == 1, matches k0[1]
    if length(key) == 1 && length(k0) == 1 && k0[1] == key[1]
        # Case 2: k1 also matches
        if !isempty(k1) && length(k1) == 1 && k1[1] == key[1]
            is_child_0(n) && return (UInt8[], as_tagged(into_child(n.slot0)))
            is_child_1(n) && return (UInt8[], as_tagged(into_child(n.slot1)))
        end
        # Case 3: k1 is longer and starts with key[1]
        if !isempty(k1) && length(k1) > 1 && k1[1] == key[1]
            rem = k1[2:end]
            if is_child_1(n)
                return (rem, as_tagged(into_child(n.slot1)))
            else
                return (rem, nothing)
            end
        end
    end

    # Case 4: key is a prefix of k0
    if slice_starts_with(k0, key)
        rem = k0[(length(key) + 1):end]
        if is_child_0(n)
            return (rem, as_tagged(into_child(n.slot0)))
        else
            return (rem, nothing)
        end
    end

    # Case 5: key is a prefix of k1
    if slice_starts_with(k1, key)
        rem = k1[(length(key) + 1):end]
        if is_child_1(n)
            return (rem, as_tagged(into_child(n.slot1)))
        else
            return (rem, nothing)
        end
    end

    (nothing, nothing)
end

# =====================================================================
# count_branches / node_branches_mask / prior_branch_key
# =====================================================================

function count_branches(n::LineListNode, key::AbstractVector{UInt8})
    klen = length(key)
    (k0, k1) = get_both_keys(n)
    c0 = (length(k0) > klen && slice_starts_with(k0, key)) ? k0[klen + 1] : nothing
    c1 = (length(k1) > klen && slice_starts_with(k1, key)) ? k1[klen + 1] : nothing
    if c0 === nothing && c1 === nothing
        return 0
    elseif c0 === nothing || c1 === nothing
        return 1
    else
        c0 == c1 ? 1 : 2
    end
end

function node_branches_mask(n::LineListNode, key::AbstractVector{UInt8})
    (k0, k1) = get_both_keys(n)
    m = ByteMask()
    if length(k0) > length(key) && slice_starts_with(k0, key)
        m = set(m, k0[length(key) + 1])
    end
    if length(k1) > length(key) && slice_starts_with(k1, key)
        m = set(m, k1[length(key) + 1])
    end
    m
end

function prior_branch_key(n::LineListNode, key::AbstractVector{UInt8})
    klen = length(key)
    klen == 1 && return UInt8[]
    (k0, k1) = get_both_keys(n)
    # key1 first (may be superset of key0)
    if !isempty(k1) && klen > length(k1) && key[1:length(k1)] == k1
        return key[1:length(k1)]
    end
    if !isempty(k0) && klen > length(k0) && key[1:length(k0)] == k0
        return key[1:length(k0)]
    end
    kb = isempty(key) ? nothing : key[1]
    k0b = isempty(k0) ? nothing : k0[1]
    k1b = isempty(k1) ? nothing : k1[1]
    (k0b == kb && k1b == kb) ? key[1:1] : UInt8[]
end

# =====================================================================
# get_sibling_of_child
# =====================================================================

function get_sibling_of_child(
    n::LineListNode{V, A}, key::AbstractVector{UInt8}, next::Bool
) where {V, A}
    @assert !isempty(key)
    last_idx = length(key) - 1
    common_key = key[1:last_idx]
    (k0, k1) = get_both_keys(n)
    if next
        if slice_starts_with(k0, key) && slice_starts_with(k1, common_key)
            last_idx_1based = last_idx + 1   # Julia 1-based
            length(k1) < last_idx_1based && return (nothing, nothing)
            k1_last = k1[last_idx_1based]
            if k1_last != key[end]
                sib = if length(k1) == length(key) && is_child_1(n)
                    as_tagged(into_child(n.slot1))
                else
                    nothing
                end
                return (k1_last, sib)
            end
        end
    else
        if slice_starts_with(k1, key) && slice_starts_with(k0, common_key)
            last_idx_1based = last_idx + 1
            length(k0) < last_idx_1based && return (nothing, nothing)
            k0_last = k0[last_idx_1based]
            if k0_last != key[end]
                sib = if length(k0) == length(key) && is_child_0(n)
                    as_tagged(into_child(n.slot0))
                else
                    nothing
                end
                return (k0_last, sib)
            end
        end
    end
    (nothing, nothing)
end

# =====================================================================
# get_node_at_key
# =====================================================================

function get_node_at_key(n::LineListNode{V, A}, key::AbstractVector{UInt8}) where {V, A}
    # Zero-length key → return this node
    if isempty(key)
        return node_is_empty(n) ? ANRNone{V, A}() : ANRBorrowedDyn{V, A}(n)
    end
    (k0, k1) = get_both_keys(n)
    # Exact match → return the child rc
    if is_child_0(n) && k0 == key
        return ANRBorrowedRc{V, A}(into_child(n.slot0))
    end
    if is_child_1(n) && k1 == key
        return ANRBorrowedRc{V, A}(into_child(n.slot1))
    end
    # Partial match → construct sub-node
    if length(k0) > length(key) && slice_starts_with(k0, key)
        new_key = k0[(length(key) + 1):end]
        new_n = LineListNode{V, A}(n.alloc)
        p0 = clone_slot0_payload(n)
        p0 !== nothing && set_slot0_no_overflow!(new_n, new_key, p0)
        return ANROwnedRc{V, A}(TrieNodeODRc(new_n, n.alloc))
    end
    if length(k1) > length(key) && slice_starts_with(k1, key)
        new_key = k1[(length(key) + 1):end]
        new_n = LineListNode{V, A}(n.alloc)
        p1 = clone_slot1_payload(n)
        p1 !== nothing && set_slot0_no_overflow!(new_n, new_key, p1)
        return ANROwnedRc{V, A}(TrieNodeODRc(new_n, n.alloc))
    end
    ANRNone{V, A}()
end

# =====================================================================
# take_node_at_key!
# =====================================================================

function take_node_at_key!(
    n::LineListNode{V, A}, key::AbstractVector{UInt8}, prune::Bool
) where {V, A}
    @assert !isempty(key)
    (k0, k1) = get_both_keys(n)
    # Exact slot0 child match
    if is_child_0(n) && k0 == key
        if prune
            return into_child(take_slot0_payload!(n))
        else
            old = swap_slot0_payload!(n, ValOrChild(TrieNodeODRc{V, A}()))
            return into_child(old)
        end
    end
    # Exact slot1 child match
    if is_child_1(n) && k1 == key
        if prune
            return into_child(take_slot1_payload!(n))
        else
            old = swap_slot1_payload!(n, ValOrChild(TrieNodeODRc{V, A}()))
            return into_child(old)
        end
    end
    # Partial match slot0
    if length(k0) > length(key) && slice_starts_with(k0, key)
        new_key = k0[(length(key) + 1):end]
        new_n = LineListNode{V, A}(n.alloc)
        p0 = if prune
            take_slot0_payload!(n)
        else
            shorten_key_0!(n, length(key))
            swap_slot0_payload!(n, ValOrChild(TrieNodeODRc{V, A}()))
        end
        p0 !== nothing && set_slot0_no_overflow!(new_n, new_key, p0)
        return TrieNodeODRc(new_n, n.alloc)
    end
    # Partial match slot1
    if length(k1) > length(key) && slice_starts_with(k1, key)
        new_key = k1[(length(key) + 1):end]
        new_n = LineListNode{V, A}(n.alloc)
        p1 = if prune
            take_slot1_payload!(n)
        else
            shorten_key_1!(n, length(key))
            swap_slot1_payload!(n, ValOrChild(TrieNodeODRc{V, A}()))
        end
        p1 !== nothing && set_slot0_no_overflow!(new_n, new_key, p1)
        return TrieNodeODRc(new_n, n.alloc)
    end
    nothing
end

# =====================================================================
# merge_list_nodes helpers
# =====================================================================
#
# Ports Rust line_list_node.rs: try_merge, merge_guts, merge_list_nodes,
# merge_into_list_nodes (lines 1263-1609).
#
# Rust uses const-generic slot indices; Julia uses explicit Int slot args.

@inline _lln_is_child(n::LineListNode, slot::Int) =
    slot == 0 ? is_child_0(n) : is_child_1(n)
@inline _lln_is_val(n::LineListNode, slot::Int) = slot == 0 ? is_value_0(n) : is_value_1(n)
@inline _lln_is_used(n::LineListNode, slot::Int) = slot == 0 ? is_used_0(n) : is_used_1(n)
@inline _lln_get_child(n::LineListNode, slot::Int) =
    into_child(slot == 0 ? n.slot0 : n.slot1)
@inline _lln_get_val(n::LineListNode, slot::Int) = into_val(slot == 0 ? n.slot0 : n.slot1)
@inline _lln_key(n::LineListNode, slot::Int) = slot == 0 ? n.key0 : n.key1
@inline _lln_clone_payload(n::LineListNode, slot::Int) =
    slot == 0 ? clone_slot0_payload(n) : clone_slot1_payload(n)

# _try_merge: attempt to merge one slot from each node.
# Returns AlgResElement{Tuple{Vector{UInt8}, ValOrChild}} | AlgResIdentity | AlgResNone
function _try_merge(
    a_key, a::LineListNode{V, A}, a_slot::Int, b_key, b::LineListNode{V, A}, b_slot::Int
) where {V, A}
    overlap = find_prefix_overlap(a_key, b_key)
    overlap > 0 ? _merge_guts(overlap, a_key, a, a_slot, b_key, b, b_slot) : AlgResNone()
end

# _merge_guts: the substance of slot-pair merging.
# Mirrors merge_guts (line 1273).
function _merge_guts(
    overlap::Int, a_key, a::LineListNode{V, A}, a_slot::Int, b_key, b::LineListNode{V, A},
    b_slot::Int
) where {V, A}
    a_key_len = length(a_key)
    b_key_len = length(b_key)

    # Identical keys: join payloads directly.
    # r.map(f) in Rust preserves AlgResIdentity without calling f — mirror that here.
    if overlap == a_key_len && overlap == b_key_len
        if _lln_is_child(a, a_slot) && _lln_is_child(b, b_slot)
            a_child = _lln_get_child(a, a_slot)
            b_child = _lln_get_child(b, b_slot)
            r = pjoin(a_child, b_child)
            if r isa AlgResElement
                return AlgResElement{Tuple{Vector{UInt8}, ValOrChild{V, A}}}((
                    Vector{UInt8}(a_key), ValOrChild(r.value)
                ))
            elseif r isa AlgResIdentity
                return AlgResIdentity(r.mask)
            else  # AlgResNone
                return AlgResNone()
            end
        elseif _lln_is_val(a, a_slot) && _lln_is_val(b, b_slot)
            a_val = _lln_get_val(a, a_slot)
            b_val = _lln_get_val(b, b_slot)
            r = pjoin(a_val, b_val)
            if r isa AlgResElement
                return AlgResElement{Tuple{Vector{UInt8}, ValOrChild{V, A}}}((
                    Vector{UInt8}(a_key), ValOrChild(r.value)
                ))
            elseif r isa AlgResIdentity
                return AlgResIdentity(r.mask)
            else
                return AlgResNone()
            end
        end
        # one is child, one is val — fall through
    end

    # b shorter + child: split a, merge intermediate with b's child
    if b_key_len == overlap && _lln_is_child(b, b_slot) && a_key_len > overlap
        a_payload = _lln_clone_payload(a, a_slot)
        b_child = _lln_get_child(b, b_slot)
        inter = LineListNode{V, A}(a.alloc)
        set_slot0!(inter, a_key[(overlap + 1):end], a_payload)
        inter_rc = TrieNodeODRc(inter, a.alloc)
        joined_r = pjoin(b_child, inter_rc)
        joined = if joined_r isa AlgResElement
            joined_r.value
        elseif joined_r isa AlgResIdentity
            (joined_r.mask & SELF_IDENT != 0) ? b_child : inter_rc
        else
            return AlgResNone()
        end
        return AlgResElement{Tuple{Vector{UInt8}, ValOrChild{V, A}}}((
            Vector{UInt8}(a_key[1:overlap]), ValOrChild(joined)
        ))
    end

    # a shorter + child: split b, merge intermediate with a's child
    if a_key_len == overlap && _lln_is_child(a, a_slot) && b_key_len > overlap
        b_payload = _lln_clone_payload(b, b_slot)
        a_child = _lln_get_child(a, a_slot)
        inter = LineListNode{V, A}(a.alloc)
        set_slot0!(inter, b_key[(overlap + 1):end], b_payload)
        inter_rc = TrieNodeODRc(inter, a.alloc)
        joined_r = pjoin(a_child, inter_rc)
        joined = if joined_r isa AlgResElement
            joined_r.value
        elseif joined_r isa AlgResIdentity
            (joined_r.mask & SELF_IDENT != 0) ? a_child : inter_rc
        else
            return AlgResNone()
        end
        return AlgResElement{Tuple{Vector{UInt8}, ValOrChild{V, A}}}((
            Vector{UInt8}(a_key[1:overlap]), ValOrChild(joined)
        ))
    end

    # Shared prefix node: build a LineListNode at common prefix, two slots beyond it
    local eff_overlap = overlap
    if eff_overlap == a_key_len || eff_overlap == b_key_len
        eff_overlap -= 1
    end
    if eff_overlap > 0
        new_n = LineListNode{V, A}(a.alloc)
        a_payload = _lln_clone_payload(a, a_slot)
        b_payload = _lln_clone_payload(b, b_slot)
        new_a_key = a_key[(eff_overlap + 1):end]
        new_b_key = b_key[(eff_overlap + 1):end]
        if should_swap_keys(new_a_key, new_b_key)
            set_slot0!(new_n, new_b_key, b_payload)
            set_slot1!(new_n, new_a_key, a_payload)
        else
            set_slot0!(new_n, new_a_key, a_payload)
            set_slot1!(new_n, new_b_key, b_payload)
        end
        return AlgResElement{Tuple{Vector{UInt8}, ValOrChild{V, A}}}((
            Vector{UInt8}(a_key[1:eff_overlap]), ValOrChild(TrieNodeODRc(new_n, a.alloc))
        ))
    end

    AlgResNone()
end

# merge_list_nodes: join two LineListNodes into either a new LineListNode (≤2 entries)
# or a DenseByteNode (>2 entries).
# Returns AlgebraicResult{TrieNodeODRc{V,A}}.
# Ports Rust merge_list_nodes (line 1377) + merge_into_list_nodes (line 1590).
function merge_list_nodes(a::LineListNode{V, A}, b::LineListNode{V, A}) where {V, A}
    (ak0, ak1) = (a.key0, a.key1)
    (bk0, bk1) = (b.key0, b.key1)
    # entries: (key, payload) pairs; identity_masks[i] = which arg was identity for entry i
    entries = Vector{Tuple{Vector{UInt8}, ValOrChild{V, A}}}()
    identity_masks = UInt64[]
    used = falses(4)  # [a_slot0, a_slot1, b_slot0, b_slot1]

    function record!(r, a_idx::Int, b_idx::Int)
        if r isa AlgResElement
            push!(entries, r.value);
            push!(identity_masks, UInt64(0))
            used[a_idx + 1] = true;
            used[b_idx + 1] = true
            return true
        elseif r isa AlgResIdentity
            mask = r.mask
            b_slot = b_idx - 2  # b_idx is used-array index (2 or 3); convert to slot (0 or 1)
            pair = if mask & SELF_IDENT != 0
                (_lln_key(a, a_idx), _lln_clone_payload(a, a_idx))
            else
                (_lln_key(b, b_slot), _lln_clone_payload(b, b_slot))
            end
            push!(entries, (Vector{UInt8}(pair[1]), pair[2]));
            push!(identity_masks, mask)
            used[a_idx + 1] = true;
            used[b_idx + 1] = true
            return true
        end
        false
    end

    # Try all 4 pairings (Rust processes (0,0),(0,1),(1,0),(1,1) in order)
    if _lln_is_used(a, 0) && _lln_is_used(b, 0)
        record!(_try_merge(ak0, a, 0, bk0, b, 0), 0, 2)
    end
    if !used[1] && !used[3] && _lln_is_used(a, 0) && _lln_is_used(b, 1)
        record!(_try_merge(ak0, a, 0, bk1, b, 1), 0, 3)
    end
    if !used[2] && _lln_is_used(a, 1) && _lln_is_used(b, 0)
        record!(_try_merge(ak1, a, 1, bk0, b, 0), 1, 2)
    end
    if !used[2] && !used[4] && _lln_is_used(a, 1) && _lln_is_used(b, 1)
        record!(_try_merge(ak1, a, 1, bk1, b, 1), 1, 3)
    end

    # Add un-merged single entries
    for (a_idx, a_key) in ((0, ak0), (1, ak1))
        !used[a_idx + 1] && _lln_is_used(a, a_idx) &&
            begin
                p = _lln_clone_payload(a, a_idx)
                p !== nothing && begin
                    push!(entries, (Vector{UInt8}(a_key), p))
                    push!(identity_masks, SELF_IDENT)
                end
            end
    end
    for (b_idx, b_key) in ((0, bk0), (1, bk1))
        !used[b_idx + 3] && _lln_is_used(b, b_idx) &&
            begin
                p = _lln_clone_payload(b, b_idx)
                p !== nothing && begin
                    push!(entries, (Vector{UInt8}(b_key), p))
                    push!(identity_masks, COUNTER_IDENT)
                end
            end
    end

    n = length(entries)

    # ≤ 2 entries → stays as LineListNode
    if n <= 2
        n == 0 && return AlgResNone()
        new_node = LineListNode{V, A}(a.alloc)
        if n == 1
            imask = identity_masks[1]
            imask != 0 && return AlgResIdentity(imask)
            set_slot0!(new_node, entries[1][1], entries[1][2])
            return AlgResElement{TrieNodeODRc{V, A}}(TrieNodeODRc(new_node, a.alloc))
        else  # n == 2
            imask = identity_masks[1] & identity_masks[2]
            imask != 0 && return AlgResIdentity(imask)
            (k0, p0), (k1, p1) = entries[1], entries[2]
            if should_swap_keys(k0, k1)
                set_slot0!(new_node, k1, p1);
                set_slot1!(new_node, k0, p0)
            else
                set_slot0!(new_node, k0, p0);
                set_slot1!(new_node, k1, p1)
            end
            return AlgResElement{TrieNodeODRc{V, A}}(TrieNodeODRc(new_node, a.alloc))
        end
    end

    # > 2 entries → upgrade to DenseByteNode
    dense = DenseByteNode{V, A}(a.alloc, n)
    for (key, payload) in entries
        k0 = key[1]
        if length(key) > 1
            child_lln = LineListNode{V, A}(a.alloc)
            set_slot0!(child_lln, key[2:end], payload)
            _bn_join_child_into!(dense, k0, TrieNodeODRc(child_lln, a.alloc))
        else
            _bn_set_payload_owned!(dense, k0, payload)
        end
    end
    AlgResElement{TrieNodeODRc{V, A}}(TrieNodeODRc(dense, a.alloc))
end

# =====================================================================
# Lattice operations
# =====================================================================

function pjoin_dyn(self::LineListNode{V, A}, other::AbstractTrieNode{V, A}) where {V, A}
    tag = node_tag(other)
    if tag == EMPTY_NODE_TAG
        return AlgResIdentity(SELF_IDENT)
    elseif tag == LINE_LIST_NODE_TAG
        return merge_list_nodes(self, other)
    elseif tag == DENSE_BYTE_NODE_TAG || tag == CELL_BYTE_NODE_TAG
        # LineListNode joins into a DenseByteNode: clone the ByteNode and merge self into it
        r = pjoin_dyn(other, self)   # ByteNode dispatches merge_from_list_node!
        return invert_identity(r)
    elseif tag == TINY_REF_NODE_TAG
        # Delegate to TinyRefNode::pjoin_dyn(self) — mirrors Rust: tiny_node.pjoin_dyn(self.as_tagged())
        # into_full() inside TinyRefNode::pjoin_dyn converts it to a LineListNode first.
        pjoin_dyn(other, self)
    else
        error("LineListNode::pjoin_dyn — unknown node tag $tag")
    end
end

function join_into_dyn!(self::LineListNode{V, A}, other::TrieNodeODRc{V, A}) where {V, A}
    is_empty_node(other) && return (ALG_STATUS_IDENTITY, nothing)
    other_tag = node_tag(as_tagged(other))
    if other_tag == LINE_LIST_NODE_TAG
        r = merge_list_nodes(self, as_tagged(other))
        if r isa AlgResElement
            return (ALG_STATUS_ELEMENT, r.value)  # new node (may be dense or list)
        elseif r isa AlgResIdentity
            if r.mask & SELF_IDENT != 0
                return (ALG_STATUS_IDENTITY, nothing)   # self unchanged
            else
                return (ALG_STATUS_ELEMENT, other)       # other won
            end
        else
            return (ALG_STATUS_NONE, nothing)
        end
    elseif other_tag == DENSE_BYTE_NODE_TAG || other_tag == CELL_BYTE_NODE_TAG
        # Merge self (LineListNode) into the DenseByteNode
        other_node = as_tagged(other)
        status = merge_from_list_node!(other_node, self)
        return (status, other)   # Err(other): caller replaces node with dense
    else
        error("LineListNode::join_into_dyn! — unknown node tag $other_tag")
    end
end

# factor_prefix!: if the two slots share an illegal key overlap, merge them
# into a single slot at the shared prefix.  Ports Rust fn factor_prefix (line 1046).
function factor_prefix!(n::LineListNode{V, A}) where {V, A}
    (!is_used_0(n) || !is_used_1(n)) && return nothing
    key0, key1 = n.key0, n.key1
    overlap = find_prefix_overlap(key0, key1)
    # overlap == 1 is legal if: slot0 is a val OR (both len==1 and slot1 is a val)
    legal_overlap =
        overlap == 1 &&
        (!is_child_0(n) || (!is_child_1(n) && length(key0) == 1 && length(key1) == 1))
    (overlap == 0 || legal_overlap) && return nothing

    r = _merge_guts(overlap, key0, n, 0, key1, n, 1)
    if r isa AlgResElement
        (shared_key, merged_payload) = r.value
        n.key0 = Vector{UInt8}(shared_key)
        n.slot0 = merged_payload
        n.slot1 = nothing
        n.key1 = UInt8[]
    elseif r isa AlgResIdentity
        # Both sides equal → keep slot0, clear slot1
        n.slot1 = nothing
        n.key1 = UInt8[]
    end
    # AlgResNone: no change needed
end

function drop_head_dyn!(self::LineListNode{V, A}, byte_cnt::Int) where {V, A}
    @assert byte_cnt > 0
    # Drop values whose keys are fully consumed by byte_cnt
    is_value_1(self) && key_len_1(self) <= byte_cnt && take_slot1_payload!(self)
    is_value_0(self) && key_len_0(self) <= byte_cnt && take_slot0_payload!(self)

    !is_used_0(self) && return nothing

    if !is_used_1(self)
        # Single-slot case
        klen0 = key_len_0(self)
        if byte_cnt < klen0
            self.key0 = self.key0[(byte_cnt + 1):end]
            return TrieNodeODRc(self, self.alloc)
        else
            remaining = byte_cnt - klen0
            @assert is_child_0(self)
            child_rc = into_child(take_slot0_payload!(self))
            if remaining > 0
                # COW: the child may be SHARED (shallow clone). drop_head_dyn! mutates
                # it in place, so make it unique first — mirrors Rust
                # `child.make_mut().drop_head_dyn(remaining)` (line_list_node.rs:2562).
                make_unique!(child_rc)
                return drop_head_dyn!(as_tagged(child_rc), remaining)
            else
                return child_rc
            end
        end
    end

    # Both slots filled
    key0 = copy(self.key0)
    key1 = copy(self.key1)
    key0_len = length(key0)
    key1_len = length(key1)

    # Case A: byte_cnt < both key lengths → shorten keys in-place, re-sort, factor
    if byte_cnt < key0_len && byte_cnt < key1_len
        new_key0 = key0[(byte_cnt + 1):end]
        new_key1 = key1[(byte_cnt + 1):end]
        if new_key0 <= new_key1
            self.key0 = new_key0
            self.key1 = new_key1
        else
            # Swap to preserve slot0 ≤ slot1 key order
            self.key0 = new_key1
            self.key1 = new_key0
            self.slot0, self.slot1 = self.slot1, self.slot0
        end
        factor_prefix!(self)
        return TrieNodeODRc(self, self.alloc)
    end

    # Case B: at least one key is fully consumed; merge and recurse.
    # chop_bytes = length of the shortest key.
    # new_key{0,1} start one byte before chop_bytes (Rust: key[chop_bytes-1..]).
    chop_bytes = min(key0_len, key1_len)
    new_key0 = key0[chop_bytes:end]   # 1-indexed: = key0[(chop_bytes-1+1):end]
    new_key1 = key1[chop_bytes:end]
    # overlap of the parts BEYOND chop_bytes (0-indexed equiv: key[chop_bytes..])
    overlap_suffix = find_prefix_overlap(
        chop_bytes < key0_len ? key0[(chop_bytes + 1):end] : UInt8[],
        chop_bytes < key1_len ? key1[(chop_bytes + 1):end] : UInt8[]
    )
    r = _merge_guts(overlap_suffix + 1, new_key0, self, 0, new_key1, self, 1)

    merged_payload = if r isa AlgResElement
        r.value[2]
    elseif r isa AlgResIdentity
        if (r.mask & SELF_IDENT != 0)
            clone_slot0_payload(self)
        else
            clone_slot1_payload(self)
        end
    else
        error("drop_head_dyn!: _merge_guts returned None — should be unreachable")
    end

    @assert is_child(merged_payload) "drop_head_dyn!: merged payload must be a child"
    child_rc = into_child(merged_payload)
    if chop_bytes == byte_cnt
        return child_rc
    else
        # COW: same as the single-slot recursion — the merged child may be shared.
        make_unique!(child_rc)
        return drop_head_dyn!(as_tagged(child_rc), byte_cnt - chop_bytes)
    end
end

"""
    _lln_payload_ref(n, slot) → PayloadRef{V,A}

Returns a `PayloadRef` for slot `slot` (0 or 1) of `n`.
Ports `unsafe { self.payload_in_slot::<SLOT>() }` in upstream.
"""
function _lln_payload_ref(n::LineListNode{V, A}, slot::Int) where {V, A}
    if _lln_is_child(n, slot)
        child_rc = into_child(slot == 0 ? n.slot0 : n.slot1)
        PayloadRef{V, A}(0x2, nothing, child_rc)
    elseif _lln_is_val(n, slot)
        val = into_val(slot == 0 ? n.slot0 : n.slot1)
        PayloadRef{V, A}(0x1, Ref{V}(val), nothing)
    else
        PayloadRef{V, A}()
    end
end

function pmeet_dyn(self::LineListNode{V, A}, other::AbstractTrieNode{V, A}) where {V, A}
    node_is_empty(self) && return AlgResNone()
    sc = used_slot_count(self)
    sc == 0 && return AlgResNone()

    self_payloads = if sc == 1
        [(copy(self.key0), _lln_payload_ref(self, 0))]
    else
        [
            (copy(self.key0), _lln_payload_ref(self, 0)),
            (copy(self.key1), _lln_payload_ref(self, 1))
        ]
    end

    pmeet_generic(
        self_payloads,
        other,
        function (payloads)
            p0 = sc >= 1 ? payloads[1] : nothing
            p1 = sc >= 2 ? payloads[2] : nothing
            new_n = clone_with_updated_payloads(self, p0, p1)
            @assert new_n !== nothing "pmeet_dyn merge_f: all payloads None (should have been AlgResNone)"
            TrieNodeODRc(new_n, self.alloc)
        end
    )
end

# =====================================================================
# Per-slot RESTRICT
# =====================================================================
#
# Ports line_list_node.rs `follow_path_to_value` (:1642), `restrict_slot_contents`
# (:1175) and `combine_slot_results_into_node_result` (:1206).
#
# 🔴 WHY THIS EXISTS AS ITS OWN PATH RATHER THAN "UPGRADE TO DENSE AND DELEGATE".
# `prestrict_dyn` used to build a DenseByteNode from `self` and hand the problem to
# `ByteNode::prestrict`. The two are NOT interchangeable, because the two implementations
# compute IDENTITY differently:
#
#   * `ByteNode::prestrict` (dense_byte_node.rs:2342) decides identity by MASK EQUALITY —
#     `is_identity = self.mask == mm && other.mask == mm`, i.e. it also requires `other`
#     to have EXACTLY the same set of child bytes as `self`.
#   * The per-slot version below decides identity PER SLOT — a slot is Identity when the
#     restriction did not remove anything FROM THAT SLOT — and never looks at what else
#     `other` contains.
#
# Restrict is non-commutative: `A restrict S` keeps the paths of A that S covers, so extra
# paths in S are irrelevant to whether A came back unchanged. The dense identity test folds
# them in anyway, so `{a,b} restrict {a,b,c}` reported Element where upstream reports
# Identity. The trie DUMP agreed in every measured case — only the returned AlgebraicStatus
# differed — but that is not cosmetic: a caller that loops "until Identity" (the standard
# saturation idiom) never terminates if the answer is permanently Element.
# Measured before/after on six scripts in test/test_restrict.jl.

"""
    _as_tagged_or_empty(rc) → AbstractTrieNode

`as_tagged` on a `TrieNodeODRc` yields `nothing` for the empty sentinel (TrieNode.jl:360);
upstream's `TrieNodeODRc::as_tagged()` yields a `TaggedNodeRef::EmptyNode` there, which
answers every `TrieNode` query as empty. Substituting the `EmptyNode` singleton is what makes
the ports below literally 1:1 instead of needing `nothing` branches everywhere.
"""
@inline function _as_tagged_or_empty(rc::TrieNodeODRc{V, A}) where {V, A}
    t = as_tagged(rc)
    t === nothing ? EmptyNode{V, A}() : t
end

"""
    _follow_path_to_value(node, key) → (found_val::Bool, onward)

Follows `key` down from `node`. Returns `(true, nothing)` if a VALUE was encountered
anywhere along the path, `(false, (rest_key, node))` if the path continues below the
returned node, and `(false, nothing)` if the path does not descend from `node` at all.

1:1 port of the free function `follow_path_to_value` (line_list_node.rs:1642). Julia is
1-based, so upstream's `&key[consumed..]` is `@view key[(consumed + 1):end]`. The key is
made a view up front so its type does not change between the first and later iterations.
"""
function _follow_path_to_value(
    node::AbstractTrieNode{V, A}, key::AbstractVector{UInt8}
) where {V, A}
    k = @view key[1:end]
    while true
        r = node_get_child(node, k)
        r === nothing && break
        (consumed, next_rc) = r
        # Path ran out inside this node's edge — the caller continues from HERE, holding the
        # node that owns the child, not the child itself. (Upstream returns `node`, not
        # `next_node`, in this arm; that is deliberate, not a typo.)
        consumed >= length(k) && return (false, (k, node))
        node = _as_tagged_or_empty(next_rc)
        k = @view k[(consumed + 1):end]
    end
    node_first_val_depth_along_key(node, k) !== nothing && return (true, nothing)
    node_contains_partial_key(node, k) && return (false, (k, node))
    (false, nothing)
end

"""
    _lln_clone_payload_shared(n, slot) → Union{Nothing, ValOrChild{V,A}}

Ports `clone_payload::<SLOT>` (line_list_node.rs:908): a CHILD payload is cloned by bumping
the refcount (structural sharing), a VALUE payload by cloning the value. Deliberately NOT
`_lln_clone_payload`, which `deepcopy`s the whole subtree — that both defeats sharing and
duplicates the node's `@atomic refcnt` field into the copy.
"""
@inline function _lln_clone_payload_shared(n::LineListNode{V, A}, slot::Int) where {V, A}
    _lln_is_used(n, slot) || return nothing
    _shallow_clone_slot(slot == 0 ? n.slot0 : n.slot1)
end

"""
    _lln_restrict_slot_contents(self, slot, other) → AlgebraicResult{ValOrChild{V,A}}

Restrict the contents of `slot` by the contents of `other`.
1:1 port of `restrict_slot_contents::<SLOT>` (line_list_node.rs:1175); Rust's const-generic
slot index becomes an explicit `Int` argument, as everywhere else in this file.
"""
function _lln_restrict_slot_contents(
    self::LineListNode{V, A}, slot::Int, other::AbstractTrieNode{V, A}
) where {V, A}
    _lln_is_used(self, slot) || return AlgResNone()
    path = _lln_key(self, slot)
    (found_val, onward) = _follow_path_to_value(other, path)
    # `other` holds a VALUE at or above this slot's key, so `other` covers the ENTIRE subtrie
    # hanging off the slot and nothing is removed from it. Identity of SELF only — restrict is
    # non-commutative, so COUNTER_IDENT must never be set (ring.rs invariant).
    found_val && return AlgResIdentity(SELF_IDENT)
    # The path does not descend from `other` at all ⇒ nothing in this slot is covered.
    onward === nothing && return AlgResNone()
    (onward_key, onward_node) = onward
    # A VALUE slot that `other` did not cover with a value of its own (that case returned
    # Identity above) is not kept: restrict retains covered paths, and a partial path is
    # not coverage.
    _lln_is_child(self, slot) || return AlgResNone()
    self_onward_link = _lln_get_child(self, slot)
    r = if isempty(onward_key)
        prestrict_dyn(_as_tagged_or_empty(self_onward_link), onward_node)
    else
        other_onward = get_node_at_key(onward_node, onward_key)
        # Upstream calls `.as_tagged()` here, which PANICS on `AbstractNodeRef::None`,
        # because its `follow_path_to_value` guarantees the remaining path exists. Ours can
        # additionally land on the `nothing`-inside-a-`TrieNodeODRc` empty sentinel (e.g. a
        # value-only byte in a dense node, DenseByteNode.jl:1504). The correct answer for
        # "restrict by a subtrie that is not there" is None — exactly what
        # `prestrict_dyn(child, EmptyNode)` returns — so we answer it directly rather than
        # throwing. Same shape as `_bn_prestrict_abstract`'s `try_as_tagged` guard.
        onward_tagged = try_as_tagged(other_onward)
        if onward_tagged === nothing
            AlgResNone()
        else
            prestrict_dyn(_as_tagged_or_empty(self_onward_link), onward_tagged)
        end
    end
    # `map` leaves Identity/None untouched and only rewraps an Element — same as Rust's
    # `AlgebraicResult::map`, so an unmodified child stays Identity(SELF_IDENT) here.
    Base.map(node -> ValOrChild(node), r)
end

"""
    _lln_combine_slot_results_into_node_result(self, slot0_result, slot1_result)
        → AlgebraicResult{TrieNodeODRc{V,A}}

Combine per-slot results of a **non-commutative** op into one node-level result.
1:1 port of `combine_slot_results_into_node_result` (line_list_node.rs:1206).

Written against the op-agnostic slot contract, so `psubtract_dyn` can adopt it unchanged if
its own per-slot port lands (upstream shares this helper between subtract and restrict).
"""
function _lln_combine_slot_results_into_node_result(
    self::LineListNode{V, A}, slot0_result::AlgebraicResult, slot1_result::AlgebraicResult
) where {V, A}
    slot0_payload::Union{Nothing, ValOrChild{V, A}} = nothing
    slot1_payload::Union{Nothing, ValOrChild{V, A}} = nothing

    if slot0_result isa AlgResIdentity && slot1_result isa AlgResIdentity
        # Neither slot lost anything ⇒ the whole node is unchanged.
        @assert slot0_result.mask == SELF_IDENT
        @assert slot1_result.mask == SELF_IDENT
        return AlgResIdentity(SELF_IDENT)
    elseif slot0_result isa AlgResNone && slot1_result isa AlgResNone
        return AlgResNone()
    elseif slot0_result isa AlgResIdentity && slot1_result isa AlgResNone
        # slot1 was never occupied ⇒ "slot1 annihilated" removed nothing, so still Identity.
        if !_lln_is_used(self, 1)
            @assert slot0_result.mask == SELF_IDENT
            return AlgResIdentity(SELF_IDENT)
        end
        # slot1 WAS occupied and is now gone ⇒ a new single-slot node carrying slot0 as-is.
        slot0_payload = _lln_clone_payload_shared(self, 0)
        slot1_payload = nothing
    else
        # NOTE (upstream): there is deliberately no (None, Identity) arm. slot1 cannot hold
        # contents while slot0 is empty, so if slot0 is None and we did not match (None, None)
        # above, this arm is the correct handler.
        slot0_payload = map_into_option(
            slot0_result, function (arg_idx)
                @assert arg_idx == 0
                _lln_clone_payload_shared(self, 0)
            end
        )
        slot1_payload = map_into_option(
            slot1_result, function (arg_idx)
                @assert arg_idx == 0
                _lln_clone_payload_shared(self, 1)
            end
        )
    end

    @assert slot0_payload !== nothing || slot1_payload !== nothing
    new_n = clone_with_updated_payloads(self, slot0_payload, slot1_payload)
    @assert new_n !== nothing "combine_slot_results: both payloads None (handled above)"
    AlgResElement(TrieNodeODRc(new_n, self.alloc))
end

function psubtract_dyn(self::LineListNode{V, A}, other::AbstractTrieNode{V, A}) where {V, A}
    tag = node_tag(other)
    if tag == EMPTY_NODE_TAG
        return AlgResIdentity(SELF_IDENT)
    elseif tag == DENSE_BYTE_NODE_TAG || tag == CELL_BYTE_NODE_TAG
        # Upgrade self to dense, then subtract via dense impl
        dense = DenseByteNode{V, A}(self.alloc, 2)
        merge_from_list_node!(dense, self)
        return psubtract_dyn(dense, other)
    elseif tag == LINE_LIST_NODE_TAG || tag == TINY_REF_NODE_TAG
        # Use abstract subtract path via dense upgrade
        dense = DenseByteNode{V, A}(self.alloc, 2)
        merge_from_list_node!(dense, self)
        return psubtract_dyn(dense, other)
    else
        error("LineListNode::psubtract_dyn — unknown tag $tag")
    end
end

function prestrict_dyn(self::LineListNode{V, A}, other::AbstractTrieNode{V, A}) where {V, A}
    # 1:1 with line_list_node.rs:2718. No dispatch on `node_tag(other)`: the per-slot walk
    # goes through the TrieNode interface, so an EmptyNode `other` falls out as
    # (None, None) → AlgResNone by itself, and a node type this file does not enumerate
    # (BridgeNode) no longer hits an `error`.
    slot0_result = _lln_restrict_slot_contents(self, 0, other)
    slot1_result = _lln_restrict_slot_contents(self, 1, other)
    _lln_combine_slot_results_into_node_result(self, slot0_result, slot1_result)
end

# Shallow clone of one slot payload: SHARE a child subtrie via copy() (bumps the
# child's refcount — structural sharing, PathMap's reason for existing), copy a
# leaf value. Replaces the old deepcopy(slot), which deep-copied whole subtrees
# and defeated sharing (audit 2026-06-02, close-out step 2). Sharing is kept sound
# by the COW make_unique! discipline before any in-place mutation of a shared node.
@inline function _shallow_clone_slot(voc::ValOrChild{V, A}) where {V, A}
    if is_child(voc)
        ValOrChild(copy(into_child(voc)))
    else
        ValOrChild{V, A}(0x0, deepcopy(into_val(voc)), nothing)
    end
end

function clone_self(n::LineListNode{V, A}) where {V, A}
    new_n = LineListNode{V, A}(n.alloc)
    if is_used_0(n)
        new_n.slot0 = _shallow_clone_slot(n.slot0)
        new_n.key0 = copy(n.key0)
    end
    if is_used_1(n)
        new_n.slot1 = _shallow_clone_slot(n.slot1)
        new_n.key1 = copy(n.key1)
    end
    TrieNodeODRc(new_n, n.alloc)
end

# TrieNodeDowncast equivalents
node_tag(::LineListNode) = LINE_LIST_NODE_TAG

function convert_to_cell_node!(n::LineListNode{V, A}) where {V, A}
    _convert_to_dense!(n, 3)
end

# =====================================================================
# Exports
# =====================================================================

export LineListNode, KEY_BYTES_CNT
export is_used_0, is_used_1, is_child_0, is_child_1, is_value_0, is_value_1
export key_len_0, key_len_1, is_available_1, used_slot_count, get_both_keys
export take_slot0_payload!, take_slot1_payload!
export swap_slot0_payload!, swap_slot1_payload!
export clone_slot0_payload, clone_slot1_payload
export set_slot0!, set_slot1!
export validate_list_node
export factor_prefix!
