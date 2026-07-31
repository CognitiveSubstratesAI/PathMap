"""
DenseByteNode — port of `pathmap/src/dense_byte_node.rs`.

A 256-slot bitmap-indexed node. `mask::ByteMask` records which byte keys are
occupied; `values` is a compacted vector of `CoFreeEntry` whose length equals
`popcount(mask)`. The entry at key `k` lives at index `index_of(mask, k) + 1`
(Julia 1-based).

`DenseByteNode{V,A}` (upstream `ByteNode<OrdinaryCoFree>`) and
`CellByteNode{V,A}` (upstream `ByteNode<CellCoFree>`) share identical fields
and behavior — in Julia the GC provides the stable-address guarantee that
`Pin<Box<>>` provides in Rust. They differ only in `node_tag` and
`convert_to_cell_node!`.

`CoFreeEntry{V,A}` ports `OrdinaryCoFree<V,A>`.  `CellCoFree` is not needed.
"""

# =====================================================================
# CoFreeEntry — ports OrdinaryCoFree / CellCoFree (unified in Julia)
# =====================================================================

"""
    CoFreeEntry{V, A<:Allocator}

A single slot in a `ByteNode`: an optional child node (`rec`) and an optional
value (`val`). Ports upstream's `OrdinaryCoFree<V,A>` (and `CellCoFree`, which
is identical in Julia since the GC provides stable addresses).
"""
mutable struct CoFreeEntry{V, A <: Allocator}
    rec::Union{Nothing, TrieNodeODRc{V, A}}
    val::Union{Nothing, V}
end

@inline CoFreeEntry{V, A}() where {V, A <: Allocator} = CoFreeEntry{V, A}(nothing, nothing)

@inline has_rec(cf::CoFreeEntry) = cf.rec !== nothing
@inline has_val(cf::CoFreeEntry) = cf.val !== nothing

# Deep copy of a CoFreeEntry: copy the rc wrapper (shares inner node, increments refcount)
function _cf_copy(cf::CoFreeEntry{V, A}) where {V, A}
    new_cf = CoFreeEntry{V, A}()
    if cf.rec !== nothing
        new_cf.rec = copy(cf.rec)   # copy TrieNodeODRc: shares node, inc refcount
    end
    if cf.val !== nothing
        new_cf.val = deepcopy(cf.val)
    end
    new_cf
end

# =====================================================================
# AbstractByteNode — shared abstract base for Dense and Cell variants
# =====================================================================

"""
    AbstractByteNode{V, A<:Allocator} <: AbstractTrieNode{V,A}

Shared base for `DenseByteNode` and `CellByteNode`. All TrieNode interface
methods are implemented here; only `node_tag` and `convert_to_cell_node!`
differ between the two concrete types.
"""
abstract type AbstractByteNode{V, A <: Allocator} <: AbstractTrieNode{V, A} end

# =====================================================================
# DenseByteNode and CellByteNode concrete types
# =====================================================================

"""
    DenseByteNode{V, A<:Allocator} <: AbstractByteNode{V,A}

Non-thread-safe variant. Ports `ByteNode<OrdinaryCoFree<V,A>, A>`.
"""
mutable struct DenseByteNode{V, A <: Allocator} <: AbstractByteNode{V, A}
    mask::ByteMask
    values::Vector{CoFreeEntry{V, A}}
    alloc::A
    @atomic refcnt::UInt32   # node-keyed COW refcount (close-out 2-A)
    DenseByteNode{V, A}(m, v, a) where {V, A <: Allocator} = new{V, A}(m, v, a, UInt32(1))
end

"""
    CellByteNode{V, A<:Allocator} <: AbstractByteNode{V,A}

Thread-safe variant (in Rust, uses `Pin<Box<>>` for stable addresses).
In Julia the GC provides the same guarantee. Ports `ByteNode<CellCoFree<V,A>, A>`.
"""
mutable struct CellByteNode{V, A <: Allocator} <: AbstractByteNode{V, A}
    mask::ByteMask
    values::Vector{CoFreeEntry{V, A}}
    alloc::A
    @atomic refcnt::UInt32   # node-keyed COW refcount (close-out 2-A)
    CellByteNode{V, A}(m, v, a) where {V, A <: Allocator} = new{V, A}(m, v, a, UInt32(1))
end

# =====================================================================
# Constructors
# =====================================================================

DenseByteNode{V, A}(alloc::A) where {V, A <: Allocator} =
    DenseByteNode{V, A}(ByteMask(), CoFreeEntry{V, A}[], alloc)

DenseByteNode{V, A}(alloc::A, cap::Int) where {V, A <: Allocator} =
    DenseByteNode{V, A}(ByteMask(), sizehint!(CoFreeEntry{V, A}[], cap), alloc)

CellByteNode{V, A}(alloc::A) where {V, A <: Allocator} =
    CellByteNode{V, A}(ByteMask(), CoFreeEntry{V, A}[], alloc)

CellByteNode{V, A}(alloc::A, cap::Int) where {V, A <: Allocator} =
    CellByteNode{V, A}(ByteMask(), sizehint!(CoFreeEntry{V, A}[], cap), alloc)

# =====================================================================
# Internal helpers — slot access (ports ByteNode methods)
# =====================================================================

@inline function _bn_get(n::AbstractByteNode, k::UInt8)
    test_bit(n.mask, k) || return nothing
    idx = Int(index_of(n.mask, k)) + 1   # 0-based → 1-based
    @inbounds n.values[idx]
end

@inline function _bn_set_bit!(n::AbstractByteNode{V, A}, k::UInt8) where {V, A}
    n.mask = set(n.mask, k)
end

@inline function _bn_clear_bit!(n::AbstractByteNode{V, A}, k::UInt8) where {V, A}
    n.mask = unset(n.mask, k)
end

"""
Iterate over every (key_byte, cf_index) pair in the node, matching upstream
`for_each_item`. `func(n, key_byte, cf_index)` where `cf_index` is 1-based.
"""
@inline function _for_each_item(n::AbstractByteNode, func)
    c = 1
    for i in 1:4
        lm = n.mask.bits[i]
        while lm != 0
            index = trailing_zeros(lm)
            key_byte = UInt8(64*(i-1) + index)
            func(n, key_byte, c)
            c += 1
            lm ⊻= UInt64(1) << index
        end
    end
end

# =====================================================================
# set_child! / set_val! / remove_val! / set_dangling! — ports
# ByteNode::set_child, set_val, remove_val, set_dangling_cf
# =====================================================================

"""
    _bn_set_child!(n, k, node) → Union{Nothing, TrieNodeODRc}

Adds/replaces a child at key byte `k`. Returns old child if replaced.
Ports `ByteNode::set_child`.
"""
function _bn_set_child!(
    n::AbstractByteNode{V, A}, k::UInt8, node::TrieNodeODRc{V, A}
) where {V, A}
    if test_bit(n.mask, k)
        idx = Int(index_of(n.mask, k)) + 1
        @inbounds old_rec = n.values[idx].rec
        @inbounds n.values[idx].rec = node
        return old_rec
    else
        idx = Int(index_of(n.mask, k)) + 1   # insertion point
        _bn_set_bit!(n, k)
        insert!(n.values, idx, CoFreeEntry{V, A}(node, nothing))
        return nothing
    end
end

"""
    _bn_set_val!(n, k, val) → Union{Nothing, V}

Adds/replaces a value at key byte `k`. Returns old value if replaced.
Ports `ByteNode::set_val`.
"""
function _bn_set_val!(n::AbstractByteNode{V, A}, k::UInt8, val::V) where {V, A}
    if test_bit(n.mask, k)
        idx = Int(index_of(n.mask, k)) + 1
        @inbounds old_val = n.values[idx].val
        @inbounds n.values[idx].val = val
        return old_val
    else
        idx = Int(index_of(n.mask, k)) + 1
        _bn_set_bit!(n, k)
        insert!(n.values, idx, CoFreeEntry{V, A}(nothing, val))
        return nothing
    end
end

"""
    _bn_remove_val!(n, k, prune) → Union{Nothing, V}

Removes value at `k`. If `prune` and no child remains, removes the CF entry.
Ports `ByteNode::remove_val`.
"""
function _bn_remove_val!(n::AbstractByteNode{V, A}, k::UInt8, prune::Bool) where {V, A}
    test_bit(n.mask, k) || return nothing
    idx = Int(index_of(n.mask, k)) + 1
    @inbounds cf = n.values[idx]
    result = cf.val
    cf.val = nothing
    if prune && cf.rec === nothing
        _bn_clear_bit!(n, k)
        deleteat!(n.values, idx)
    end
    result
end

"""
    _bn_set_dangling!(n, k) → Bool

Creates a dangling (empty) CF entry at `k` if none exists.
Returns `true` if a new entry was created. Ports `ByteNode::set_dangling_cf`.
"""
function _bn_set_dangling!(n::AbstractByteNode{V, A}, k::UInt8) where {V, A}
    test_bit(n.mask, k) && return false
    idx = Int(index_of(n.mask, k)) + 1
    _bn_set_bit!(n, k)
    insert!(n.values, idx, CoFreeEntry{V, A}())
    true
end

"""
    _bn_remove!(n, k) → Union{Nothing, CoFreeEntry}

Removes the entire CF entry at `k`. Ports `ByteNode::remove`.
"""
function _bn_remove!(n::AbstractByteNode{V, A}, k::UInt8) where {V, A}
    test_bit(n.mask, k) || return nothing
    idx = Int(index_of(n.mask, k)) + 1
    cf = n.values[idx]
    _bn_clear_bit!(n, k)
    deleteat!(n.values, idx)
    cf
end

"""
    _bn_join_child_into!(n, k, node) → AlgebraicStatus

Adds/joins a child at key byte `k`. Ports `ByteNode::join_child_into`.
"""
function _bn_join_child_into!(
    n::AbstractByteNode{V, A}, k::UInt8, node::TrieNodeODRc{V, A}
) where {V, A}
    if test_bit(n.mask, k)
        idx = Int(index_of(n.mask, k)) + 1
        @inbounds cf = n.values[idx]
        if cf.rec !== nothing
            (status, result) = join_into_dyn!(cf.rec, node)
            if result !== nothing
                cf.rec = result
            end
            return status
        else
            cf.rec = node
            return ALG_STATUS_ELEMENT
        end
    else
        idx = Int(index_of(n.mask, k)) + 1
        _bn_set_bit!(n, k)
        insert!(n.values, idx, CoFreeEntry{V, A}(node, nothing))
        return ALG_STATUS_ELEMENT
    end
end

"""
    _bn_join_val_into!(n, k, val) → AlgebraicStatus

Adds/joins a value at key byte `k`. Ports `ByteNode::join_val_into`.
"""
function _bn_join_val_into!(n::AbstractByteNode{V, A}, k::UInt8, val::V) where {V, A}
    if test_bit(n.mask, k)
        idx = Int(index_of(n.mask, k)) + 1
        @inbounds cf = n.values[idx]
        if cf.val !== nothing
            r = pjoin(cf.val, val)
            if r isa AlgResElement
                cf.val = r.value
                return ALG_STATUS_ELEMENT
            else
                return ALG_STATUS_IDENTITY
            end
        else
            cf.val = val
            return ALG_STATUS_ELEMENT
        end
    else
        idx = Int(index_of(n.mask, k)) + 1
        _bn_set_bit!(n, k)
        insert!(n.values, idx, CoFreeEntry{V, A}(nothing, val))
        return ALG_STATUS_ELEMENT
    end
end

"""
    _bn_join_payload_into!(n, k, payload) → AlgebraicStatus

Ports `ByteNode::join_payload_into`. Dispatches to `_bn_join_child_into!` or
`_bn_join_val_into!` based on payload type.
"""
function _bn_join_payload_into!(
    n::AbstractByteNode{V, A}, k::UInt8, payload::ValOrChild{V, A}
) where {V, A}
    if is_child(payload)
        _bn_join_child_into!(n, k, into_child(payload))
    else
        _bn_join_val_into!(n, k, into_val(payload))
    end
end

"""
    _bn_set_payload_owned!(n, k, payload)

Sets child or value at `k` without joining. Ports `ByteNode::set_payload_owned`.
"""
function _bn_set_payload_owned!(
    n::AbstractByteNode{V, A}, k::UInt8, payload::ValOrChild{V, A}
) where {V, A}
    if is_child(payload)
        _bn_set_child!(n, k, into_child(payload))
    else
        _bn_set_val!(n, k, into_val(payload))
    end
end

# =====================================================================
# bit_sibling — helper for get_sibling_of_child
# =====================================================================

"""
    bit_sibling(pos, x, next) → UInt8

Returns the position of the previous (`next=false`) or next (`next=true`)
active bit in word `x` relative to `pos`. If there is no such bit, returns
`pos`. Assumes `pos` is active in `x`. Ports upstream `bit_sibling`.
"""
function bit_sibling(pos::UInt8, x::UInt64, next::Bool)::UInt8
    if next
        pos == 0 && return UInt8(0)
        succ = ~UInt64(0) >> (64 - Int(pos))
        m = x & succ
        m == 0 ? pos : UInt8(63 - leading_zeros(m))
    else
        prec = ~(~UInt64(0) >> (63 - Int(pos)))
        m = x & prec
        m == 0 ? pos : UInt8(trailing_zeros(m))
    end
end

# =====================================================================
# val_count_below_node — helper for node_val_count
# =====================================================================

"""
    val_count_below_node(rc, cache) → Int

Recursively counts values in the subtree rooted at `rc`, with memoisation.
Ports upstream `val_count_below_node`.
"""
function val_count_below_node(rc::TrieNodeODRc{V, A}, cache::Dict{UInt64, Int}) where {V, A}
    # Mirrors upstream trie_node.rs:2377-2394: the empty-sentinel case (`rc.node === nothing`,
    # left behind by remove_val_at! without prune=true, the default) must short-circuit to 0
    # BEFORE as_tagged/node_val_count — it is not a node to recurse into. Caching is also
    # upstream-gated to refcount()>1 (only SHARED subtries are memoised; a uniquely-owned node
    # is walked directly, since caching it by id risks a stale hit across COW mutation).
    is_empty_node(rc) && return 0
    if refcount(rc) > 1
        id = shared_node_id(rc)
        get!(cache, id) do
            node_val_count(as_tagged(rc), cache)
        end
    else
        node_val_count(as_tagged(rc), cache)
    end
end

# =====================================================================
# CoFreeEntry lattice operations (ports HeteroLattice for CoFree)
# =====================================================================

"""
    _cf_combine_results(a, b, rec_res, val_res) → (identity_mask, new_rec, new_val)

Ports `combine_algebraic_results` from upstream. Given separate algebraic
results for the `rec` and `val` fields, returns the merged CoFreeEntry state
as `(identity_mask::UInt64, rec, val)`. `identity_mask == 0` means Element.
"""
function _cf_combine_results(
    a::CoFreeEntry{V, A}, b::CoFreeEntry{V, A}, rec_res, val_res
) where {V, A}
    is_rec_none = rec_res isa AlgResNone
    is_rec_ident = rec_res isa AlgResIdentity
    is_val_none = val_res isa AlgResNone
    is_val_ident = val_res isa AlgResIdentity

    if is_rec_none && is_val_none
        return (UInt64(0), nothing, nothing)
    end

    if is_rec_ident && is_val_ident
        rm = rec_res.mask;
        vm = val_res.mask
        new_mask = rm & vm
        if new_mask > 0
            # Both fields agree on identity — entire CF is identity
            return (new_mask, nothing, nothing)  # caller uses original
        else
            # Fields disagree — pick each from the correct source
            new_rec = deepcopy((rm & SELF_IDENT) != 0 ? a.rec : b.rec)
            new_val = deepcopy((vm & SELF_IDENT) != 0 ? a.val : b.val)
            return (UInt64(0), new_rec, new_val)
        end
    end

    if is_rec_none && is_val_ident
        vm = val_res.mask
        new_mask = vm
        a.rec !== nothing && (new_mask = new_mask & ~SELF_IDENT)
        b.rec !== nothing && (new_mask = new_mask & ~COUNTER_IDENT)
        if new_mask > 0
            return (new_mask, nothing, nothing)  # caller uses original
        else
            # SELECT THE OPERAND BY THE MASK, do not assume `a`. Identity(mask) says the result
            # equals SELF, or COUNTER, or both; when the mask has been cleared down to 0 above, the
            # surviving side is whichever bit was set BEFORE clearing. Copying `a.val`
            # unconditionally assembles the result from the wrong operand whenever only COUNTER_IDENT
            # held. Upstream `2683d7c`, dense_byte_node.rs:1914.
            return (UInt64(0), nothing, deepcopy((vm & SELF_IDENT) != 0 ? a.val : b.val))
        end
    end

    if is_rec_ident && is_val_none
        rm = rec_res.mask
        new_mask = rm
        a.val !== nothing && (new_mask = new_mask & ~SELF_IDENT)
        b.val !== nothing && (new_mask = new_mask & ~COUNTER_IDENT)
        if new_mask > 0
            return (new_mask, nothing, nothing)  # caller uses original
        else
            # Same operand-selection fix as the val branch above (upstream `2683d7c`,
            # dense_byte_node.rs:1928) — mirrored here because the two branches are symmetric and
            # fixing only one would leave the rec half assembling from the wrong child.
            return (UInt64(0), deepcopy((rm & SELF_IDENT) != 0 ? a.rec : b.rec), nothing)
        end
    end

    # At least one is AlgResElement — build new CF from parts
    new_rec = if is_rec_none
        nothing
    elseif is_rec_ident
        deepcopy((rec_res.mask & SELF_IDENT) != 0 ? a.rec : b.rec)
    else
        rec_res.value  # TrieNodeODRc (shared ref, no deep copy needed)
    end

    new_val = if is_val_none
        nothing
    elseif is_val_ident
        deepcopy((val_res.mask & SELF_IDENT) != 0 ? a.val : b.val)
    else
        val_res.value
    end

    return (UInt64(0), new_rec, new_val)
end

"""
    _cf_pjoin(a, b) → (identity_mask, CoFreeEntry)

Ports the CoFree `pjoin` via `HeteroLattice` + `combine_algebraic_results`.
Returns `(identity_mask::UInt64, new_cf)`. Caller updates is_identity flags
from the mask. `identity_mask == 0` means result is a new Element.
"""
function _cf_pjoin(a::CoFreeEntry{V, A}, b::CoFreeEntry{V, A}) where {V, A}
    # pjoin rec (Option<TrieNodeODRc> semantics)
    rec_res = if a.rec === nothing && b.rec === nothing
        AlgResIdentity(SELF_IDENT | COUNTER_IDENT)
    elseif a.rec === nothing
        AlgResIdentity(COUNTER_IDENT)
    elseif b.rec === nothing
        AlgResIdentity(SELF_IDENT)
    else
        pjoin(a.rec, b.rec)  # AlgResIdentity or AlgResElement
    end

    # pjoin val (Union{Nothing,V} semantics matching Ring.jl)
    val_res = if a.val === nothing && b.val === nothing
        AlgResIdentity(SELF_IDENT | COUNTER_IDENT)
    elseif a.val === nothing
        AlgResIdentity(COUNTER_IDENT)
    elseif b.val === nothing
        AlgResIdentity(SELF_IDENT)
    else
        pjoin(a.val, b.val)
    end

    (id_mask, new_rec, new_val) = _cf_combine_results(a, b, rec_res, val_res)
    if id_mask != 0
        # Identity: the caller should use the appropriate original
        (id_mask, (id_mask & SELF_IDENT) != 0 ? _cf_copy(a) : _cf_copy(b))
    else
        (UInt64(0), CoFreeEntry{V, A}(new_rec, new_val))
    end
end

"""
    _cf_pmeet(a, b) → AlgebraicResult{CoFreeEntry}

Ports CoFree `pmeet` via `HeteroLattice`.
"""
function _cf_pmeet(a::CoFreeEntry{V, A}, b::CoFreeEntry{V, A}) where {V, A}
    # If either cofree is dangling (no rec, no val), identity for that side
    a_dangling = !has_rec(a) && !has_val(a)
    b_dangling = !has_rec(b) && !has_val(b)
    identity_flag = UInt64(0)
    a_dangling && (identity_flag |= SELF_IDENT)
    b_dangling && (identity_flag |= COUNTER_IDENT)
    identity_flag > 0 && return AlgResIdentity(identity_flag)

    rec_res = pmeet(a.rec, b.rec)    # Union{Nothing,TrieNodeODRc} pmeet
    val_res = pmeet(a.val, b.val)    # Union{Nothing,V} pmeet

    (id_mask, new_rec, new_val) = _cf_combine_results(a, b, rec_res, val_res)
    if id_mask != 0
        return AlgResIdentity(id_mask)
    end
    (new_rec !== nothing || new_val !== nothing) || return AlgResNone()
    AlgResElement(CoFreeEntry{V, A}(new_rec, new_val))
end

"""
    _cf_psubtract(a, b) → AlgebraicResult{CoFreeEntry}

Ports CoFree `psubtract` via `HeteroDistributiveLattice`.
"""
function _cf_psubtract(a::CoFreeEntry{V, A}, b::CoFreeEntry{V, A}) where {V, A}
    # filter out empty rec (matching Rust: `self_rec.filter(|c| !c.node_is_empty())`)
    a_rec = (a.rec !== nothing && !node_is_empty(as_tagged(a.rec))) ? a.rec : nothing
    rec_res = psubtract(a_rec, b.rec)
    val_res = psubtract(a.val, b.val)
    (id_mask, new_rec, new_val) = _cf_combine_results(a, b, rec_res, val_res)
    id_mask != 0 && return AlgResIdentity(id_mask)
    (new_rec !== nothing || new_val !== nothing) || return AlgResNone()
    AlgResElement(CoFreeEntry{V, A}(new_rec, new_val))
end

"""
    _cf_prestrict(a, b) → AlgebraicResult{CoFreeEntry}

Ports CoFree `prestrict` via `HeteroQuantale`.
"""
function _cf_prestrict(a::CoFreeEntry{V, A}, b::CoFreeEntry{V, A}) where {V, A}
    # If other has a value, keep the whole CF (identity for self)
    b.val !== nothing && return AlgResIdentity(SELF_IDENT)
    # Otherwise restrict via onward links
    a.rec === nothing && return AlgResNone()
    b.rec === nothing && return AlgResNone()
    r = prestrict(a.rec, b.rec)
    if r isa AlgResIdentity
        # check if self has a val to strip
        if a.val !== nothing
            return AlgResElement(CoFreeEntry{V, A}(copy(a.rec), nothing))
        else
            return AlgResIdentity(SELF_IDENT)
        end
    elseif r isa AlgResNone
        return AlgResNone()
    else  # AlgResElement
        return AlgResElement(CoFreeEntry{V, A}(r.value, nothing))
    end
end

# =====================================================================
# ByteNode lattice ops — pjoin/join_into/pmeet/psubtract/prestrict
# between two ByteNodes of any (Dense/Cell) combination.
# Ports HeteroLattice<ByteNode<OtherCf,A>> for ByteNode<Cf,A>.
# =====================================================================

"""
    _bn_pjoin(self, other) → AlgebraicResult{TrieNodeODRc}

Ports `HeteroLattice::pjoin` between two ByteNodes. Iterates through the
joined mask, merging CoFreeEntries that exist in both nodes.
"""
function _bn_pjoin(self::AbstractByteNode{V, A}, other::AbstractByteNode{V, A}) where {V, A}
    jm = self.mask | other.mask
    mm = self.mask & other.mask

    is_identity = (self.mask == jm)
    is_counter_identity = (other.mask == jm)

    n_bits = count_bits(jm)
    new_values = Vector{CoFreeEntry{V, A}}(undef, n_bits)

    l = 1;
    r = 1;
    c = 1

    for i in 1:4
        lm = jm.bits[i]
        while lm != 0
            index = Int(trailing_zeros(lm))
            bit = UInt64(1) << index

            if (bit & mm.bits[i]) != 0
                # cofree exists in both — join them
                @inbounds lv = self.values[l]
                @inbounds rv = other.values[r]
                (id_mask, new_cf) = _cf_pjoin(lv, rv)
                # pjoin of (Some, Some) is never None
                if (id_mask & SELF_IDENT) == 0
                    ;
                    is_identity = false;
                end
                if (id_mask & COUNTER_IDENT) == 0
                    ;
                    is_counter_identity = false;
                end
                @inbounds new_values[c] = new_cf
                l += 1;
                r += 1
            elseif (bit & self.mask.bits[i]) != 0
                # only in self
                is_counter_identity = false
                @inbounds new_values[c] = _cf_copy(self.values[l])
                l += 1
            else
                # only in other
                is_identity = false
                @inbounds new_values[c] = _cf_copy(other.values[r])
                r += 1
            end

            lm ⊻= bit
            c += 1
        end
    end

    actual_c = c - 1
    actual_c == 0 && return AlgResNone()
    if is_identity || is_counter_identity
        mask_bits = UInt64(0)
        is_identity && (mask_bits |= SELF_IDENT)
        is_counter_identity && (mask_bits |= COUNTER_IDENT)
        return AlgResIdentity(mask_bits)
    end
    resize!(new_values, actual_c)
    new_node = typeof(self)(jm, new_values, self.alloc)
    AlgResElement(TrieNodeODRc(new_node, self.alloc))
end

"""
    _bn_join_into!(self, other) → AlgebraicStatus

Ports `HeteroLattice::join_into` (mutating pjoin). Merges `other` into `self`.
"""
function _bn_join_into!(
    self::N, other::N
) where {V, A <: Allocator, N <: AbstractByteNode{V, A}}
    jm = self.mask | other.mask
    mm = self.mask & other.mask

    is_identity = (self.mask == jm)

    new_values = Vector{CoFreeEntry{V, A}}(undef, count_bits(jm))

    l = 1;
    r = 1;
    c = 1

    for i in 1:4
        lm = jm.bits[i]
        while lm != 0
            index = Int(trailing_zeros(lm))
            bit = UInt64(1) << index

            if (bit & mm.bits[i]) != 0
                @inbounds lv = self.values[l]
                @inbounds rv = other.values[r]
                # join_into: mutate lv with rv
                (id_mask, new_cf) = _cf_pjoin(lv, rv)
                if (id_mask & SELF_IDENT) == 0
                    ;
                    is_identity = false;
                end
                @inbounds new_values[c] = new_cf
                l += 1;
                r += 1
            elseif (bit & self.mask.bits[i]) != 0
                @inbounds new_values[c] = self.values[l]   # take from self (no copy needed)
                l += 1
            else
                is_identity = false
                @inbounds new_values[c] = _cf_copy(other.values[r])
                r += 1
            end

            lm ⊻= bit
            c += 1
        end
    end

    actual_c = c - 1
    resize!(new_values, actual_c)
    self.mask = jm
    self.values = new_values

    actual_c == 0 && return ALG_STATUS_NONE
    is_identity && return ALG_STATUS_IDENTITY
    ALG_STATUS_ELEMENT
end

"""
    _bn_pmeet(self, other) → AlgebraicResult{TrieNodeODRc}

Ports `HeteroLattice::pmeet` between two ByteNodes.
"""
function _bn_pmeet(self::AbstractByteNode{V, A}, other::AbstractByteNode{V, A}) where {V, A}
    jm = self.mask | other.mask
    mm = self.mask & other.mask

    is_identity = (self.mask == mm)
    is_counter_identity = (other.mask == mm)

    new_values = CoFreeEntry{V, A}[]
    sizehint!(new_values, count_bits(mm))
    new_mask = ByteMask()

    l = 1;
    r = 1

    for i in 1:4
        lm = jm.bits[i]
        while lm != 0
            index = Int(trailing_zeros(lm))
            bit = UInt64(1) << index

            if (bit & mm.bits[i]) != 0
                # both have it — meet the cofrees
                @inbounds lv = self.values[l]
                @inbounds rv = other.values[r]
                cf_res = _cf_pmeet(lv, rv)
                if cf_res isa AlgResNone
                    is_identity = false;
                    is_counter_identity = false
                elseif cf_res isa AlgResIdentity
                    m = cf_res.mask
                    (m & SELF_IDENT) == 0 && (is_identity = false)
                    (m & COUNTER_IDENT) == 0 && (is_counter_identity = false)
                    new_mask = set(new_mask, UInt8(64*(i-1) + index))
                    push!(new_values, (m & SELF_IDENT) != 0 ? _cf_copy(lv) : _cf_copy(rv))
                else
                    is_identity = false;
                    is_counter_identity = false
                    new_mask = set(new_mask, UInt8(64*(i-1) + index))
                    push!(new_values, cf_res.value)
                end
                l += 1;
                r += 1
            elseif (bit & self.mask.bits[i]) != 0
                l += 1
            else
                r += 1
            end

            lm ⊻= bit
        end
    end

    isempty(new_values) && return AlgResNone()
    if is_identity || is_counter_identity
        mask_bits = UInt64(0)
        is_identity && (mask_bits |= SELF_IDENT)
        is_counter_identity && (mask_bits |= COUNTER_IDENT)
        return AlgResIdentity(mask_bits)
    end
    new_node = typeof(self)(new_mask, new_values, self.alloc)
    AlgResElement(TrieNodeODRc(new_node, self.alloc))
end

"""
    _bn_psubtract(self, other) → AlgebraicResult{TrieNodeODRc}

Ports `ByteNode::psubtract` between two ByteNodes.
"""
function _bn_psubtract(
    self::AbstractByteNode{V, A}, other::AbstractByteNode{V, A}
) where {V, A}
    is_identity = true
    new_node = typeof(self)(self.alloc)
    sizehint!(new_node.values, length(self.values))

    for i in 1:4
        lm = self.mask.bits[i]
        while lm != 0
            index = Int(trailing_zeros(lm))
            bit = UInt64(1) << index
            k = UInt8(64*(i-1) + index)

            @inbounds lv = self.values[Int(index_of(self.mask, k)) + 1]

            if (bit & other.mask.bits[i]) != 0
                @inbounds rv = other.values[Int(index_of(other.mask, k)) + 1]
                cf_res = _cf_psubtract(lv, rv)
                if cf_res isa AlgResNone
                    is_identity = false
                    # drop this entry
                elseif cf_res isa AlgResIdentity
                    # SELF_IDENT — keep as-is
                    new_node.mask = set(new_node.mask, k)
                    push!(new_node.values, _cf_copy(lv))
                else
                    is_identity = false
                    new_node.mask = set(new_node.mask, k)
                    push!(new_node.values, cf_res.value)
                end
            else
                # other doesn't have this key — keep self's entry
                new_node.mask = set(new_node.mask, k)
                push!(new_node.values, _cf_copy(lv))
            end

            lm ⊻= bit
        end
    end

    is_empty_mask(new_node.mask) && return AlgResNone()
    is_identity && return AlgResIdentity(SELF_IDENT)
    AlgResElement(TrieNodeODRc(new_node, self.alloc))
end

"""
    _bn_prestrict(self, other) → AlgebraicResult{TrieNodeODRc}

Ports `ByteNode::prestrict` between two ByteNodes.
"""
function _bn_prestrict(
    self::AbstractByteNode{V, A}, other::AbstractByteNode{V, A}
) where {V, A}
    jm = self.mask | other.mask
    mm = self.mask & other.mask

    is_identity = (self.mask == mm)

    new_values = CoFreeEntry{V, A}[]
    sizehint!(new_values, count_bits(mm))
    new_mask = ByteMask()

    l = 1;
    r = 1

    for i in 1:4
        lm = jm.bits[i]
        while lm != 0
            index = Int(trailing_zeros(lm))
            bit = UInt64(1) << index

            if (bit & mm.bits[i]) != 0
                @inbounds lv = self.values[l]
                @inbounds rv = other.values[r]
                cf_res = _cf_prestrict(lv, rv)
                if cf_res isa AlgResNone
                    is_identity = false
                elseif cf_res isa AlgResIdentity
                    k = UInt8(64*(i-1) + index)
                    new_mask = set(new_mask, k)
                    push!(new_values, _cf_copy(lv))
                else
                    is_identity = false
                    k = UInt8(64*(i-1) + index)
                    new_mask = set(new_mask, k)
                    push!(new_values, cf_res.value)
                end
                l += 1;
                r += 1
            else
                is_identity = false
                if (bit & self.mask.bits[i]) != 0
                    ;
                    l += 1
                else
                    ;
                    r += 1
                end
            end

            lm ⊻= bit
        end
    end

    isempty(new_values) && return AlgResNone()
    is_identity && return AlgResIdentity(SELF_IDENT)
    new_node = typeof(self)(new_mask, new_values, self.alloc)
    AlgResElement(TrieNodeODRc(new_node, self.alloc))
end

# =====================================================================
# merge_from_list_node! — used by LineListNode upgrade path
# =====================================================================

"""
    merge_from_list_node!(n, list_node) → AlgebraicStatus

Merges both slots of `list_node` into `n`. Ports `ByteNode::merge_from_list_node`.
Called by `LineListNode._convert_to_dense!` when a third entry is needed.
"""
function merge_from_list_node!(
    n::AbstractByteNode{V, A}, list_node::LineListNode{V, A}
) where {V, A}
    self_was_empty = is_empty_mask(n.mask)
    sizehint!(n.values, length(n.values) + 2)

    function _merge_slot(key, payload)
        if length(key) > 1
            child_node = LineListNode{V, A}(n.alloc)
            set_slot0!(child_node, key[2:end], payload)
            _bn_join_child_into!(n, key[1], TrieNodeODRc(child_node, n.alloc))
        else
            _bn_join_payload_into!(n, key[1], payload)
        end
    end

    slot0_status = if is_used_0(list_node)
        _merge_slot(list_node.key0, list_node.slot0)
    else
        self_was_empty ? ALG_STATUS_NONE : ALG_STATUS_IDENTITY
    end

    slot1_status = if is_used_1(list_node)
        _merge_slot(list_node.key1, list_node.slot1)
    else
        self_was_empty ? ALG_STATUS_NONE : ALG_STATUS_IDENTITY
    end

    merge_status(slot0_status, slot1_status, true, true)
end

# =====================================================================
# _psubtract_abstract / _prestrict_abstract — cross-type lattice helpers
# =====================================================================

"""
    _bn_psubtract_abstract(self, other::AbstractTrieNode) → AlgebraicResult{TrieNodeODRc}

Ports `psubtract_abstract` — subtract using abstract trie interface for `other`.
Used when `other` is not a ByteNode (e.g. LineListNode, TinyRefNode).
"""
function _bn_psubtract_abstract(
    self::AbstractByteNode{V, A}, other::AbstractTrieNode{V, A}
) where {V, A}
    is_identity = true
    new_node = typeof(self)(self.alloc)

    _for_each_item(
        self,
        (sn, key_byte, cf_idx) -> begin
            @inbounds cf = sn.values[cf_idx]
            new_cf = CoFreeEntry{V, A}()

            if node_contains_partial_key(other, UInt8[key_byte])
                if cf.val !== nothing
                    other_val = node_get_val(other, UInt8[key_byte])
                    if other_val !== nothing
                        r = psubtract(cf.val, other_val)
                        if r isa AlgResNone
                            is_identity = false
                        elseif r isa AlgResIdentity
                            new_cf.val = deepcopy(cf.val)
                        else
                            is_identity = false
                            new_cf.val = r.value
                        end
                    else
                        # ⚠️ MISSING BRANCH — this `else` did not exist, and its absence was SILENT
                        # DATA LOSS. `other` reaching this key means it has SOMETHING at this byte,
                        # but that something may be a CHILD (deeper structure) rather than a VALUE.
                        # Subtracting `{ab}` from `{a}` must leave `a` alone: a value is removed only
                        # when the source has a VALUE AT THE SAME PATH, never merely structure below
                        # it. Without this branch `new_cf.val` was left unset and our value vanished.
                        #
                        # Upstream keeps it: `subtract_from_slot_contents` matches
                        # `onward_node.node_get_val(onward_key)` and returns
                        # `AlgebraicResult::Identity(SELF_IDENT)` on `None` (line_list_node.rs:1153-1156),
                        # and the CoFree `(None, Identity)` combine arm preserves it
                        # (dense_byte_node.rs:1944-1956).
                        #
                        # Measured before/after against the binary:
                        #   {a}    - {ab}   upstream Identity [a]      ours was None []
                        #   {a,ab} - {ab}   upstream Element  [a]      ours was None []
                        #   {:b:}  - {:b:b} upstream Identity [:b:]    ours was None []
                        # Five of the fuzzer's ten shrunk "we lose data" cases were this one branch.
                        new_cf.val = deepcopy(cf.val)
                    end
                end

                if cf.rec !== nothing && !node_is_empty(as_tagged(cf.rec))
                    other_child = get_node_at_key(other, UInt8[key_byte])
                    other_node = if (other_child isa ANRNone)
                        nothing
                    else
                        try_as_tagged(other_child)
                    end
                    if other_node !== nothing
                        r = psubtract_dyn(as_tagged(cf.rec), other_node)
                        if r isa AlgResNone
                            is_identity = false
                        elseif r isa AlgResIdentity
                            new_cf.rec = copy(cf.rec)
                        else
                            is_identity = false
                            new_cf.rec = r.value
                        end
                    else
                        new_cf.rec = copy(cf.rec)
                    end
                end

                if has_rec(new_cf) || has_val(new_cf)
                    new_node.mask = set(new_node.mask, key_byte)
                    push!(new_node.values, new_cf)
                end
            else
                new_node.mask = set(new_node.mask, key_byte)
                push!(new_node.values, _cf_copy(cf))
            end
        end
    )

    is_empty_mask(new_node.mask) && return AlgResNone()
    is_identity && return AlgResIdentity(SELF_IDENT)
    AlgResElement(TrieNodeODRc(new_node, self.alloc))
end

"""
    _bn_prestrict_abstract(self, other::AbstractTrieNode) → AlgebraicResult{TrieNodeODRc}

Ports `prestrict_abstract`.
"""
function _bn_prestrict_abstract(
    self::AbstractByteNode{V, A}, other::AbstractTrieNode{V, A}
) where {V, A}
    is_identity = true
    new_node = typeof(self)(self.alloc)

    _for_each_item(
        self,
        (sn, key_byte, cf_idx) -> begin
            @inbounds cf = sn.values[cf_idx]

            if node_contains_partial_key(other, UInt8[key_byte])
                other_val = node_get_val(other, UInt8[key_byte])
                if other_val !== nothing
                    # other has a value: keep entire cf
                    new_node.mask = set(new_node.mask, key_byte)
                    push!(new_node.values, _cf_copy(cf))
                else
                    if cf.rec !== nothing
                        other_child = get_node_at_key(other, UInt8[key_byte])
                        other_node = if (other_child isa ANRNone)
                            nothing
                        else
                            try_as_tagged(other_child)
                        end
                        if other_node !== nothing
                            new_cf = CoFreeEntry{V, A}()
                            r = prestrict_dyn(as_tagged(cf.rec), other_node)
                            if r isa AlgResNone
                                is_identity = false
                            elseif r isa AlgResIdentity
                                new_cf.rec = copy(cf.rec)
                            else
                                is_identity = false
                                new_cf.rec = r.value
                            end
                            if has_rec(new_cf)
                                new_node.mask = set(new_node.mask, key_byte)
                                push!(new_node.values, new_cf)
                            end
                        else
                            is_identity = false
                        end
                    end
                end
            else
                is_identity = false
            end
        end
    )

    is_empty_mask(new_node.mask) && return AlgResNone()
    is_identity && return AlgResIdentity(SELF_IDENT)
    AlgResElement(TrieNodeODRc(new_node, self.alloc))
end

# Helper to try getting a tagged node ref from AbstractNodeRef
function try_as_tagged(r::AbstractNodeRef)
    r isa ANRNone && return nothing
    as_tagged(r)
end

# =====================================================================
# TrieNode interface on AbstractByteNode
# =====================================================================

function node_key_overlap(n::AbstractByteNode, key::AbstractVector{UInt8})
    test_bit(n.mask, key[1]) ? 1 : 0
end

function node_contains_partial_key(n::AbstractByteNode, key::AbstractVector{UInt8})
    length(key) == 1 && test_bit(n.mask, key[1])
end

function node_get_child(n::AbstractByteNode{V, A}, key::AbstractVector{UInt8}) where {V, A}
    cf = _bn_get(n, key[1])
    cf === nothing && return nothing
    cf.rec === nothing && return nothing
    (1, cf.rec)
end

function node_get_child_mut(
    n::AbstractByteNode{V, A}, key::AbstractVector{UInt8}
) where {V, A}
    cf = _bn_get(n, key[1])
    cf === nothing && return nothing
    cf.rec === nothing && return nothing
    (1, cf.rec)
end

function node_replace_child!(
    n::AbstractByteNode{V, A}, key::AbstractVector{UInt8}, new_node::TrieNodeODRc{V, A}
) where {V, A}
    idx = Int(index_of(n.mask, key[1])) + 1
    @inbounds n.values[idx].rec = new_node
end

function node_get_payloads(
    n::AbstractByteNode{V, A}, keys_expect_val, results_buf
) where {V, A}
    # See upstream dense_byte_node.rs for the state-machine rationale:
    # CoFree entries can have both rec (child) and val; a rec request must
    # precede a val request for the same byte, so the val is stashed until
    # the next (val) request for that byte arrives.
    unrequested_cofree_half = false
    stashed_val = nothing   # Union{Nothing, V}
    last_byte = nothing   # Union{Nothing, UInt8}
    requested_mask = n.mask

    for (i, (key, expect_val)) in enumerate(keys_expect_val)
        isempty(key) && continue
        byte = key[1]

        # Moving to a different byte — abandon any stashed val
        if last_byte !== nothing && byte != last_byte
            if stashed_val !== nothing
                unrequested_cofree_half = true
            end
            stashed_val = nothing
            last_byte = nothing
        end

        # Serve stashed val if this is the matching val request
        if stashed_val !== nothing
            if length(key) == 1 && expect_val
                results_buf[i] = (1, PayloadRef{V, A}(0x1, Ref{V}(stashed_val), nothing))
                stashed_val = nothing
                continue
            end
        end

        # Mark this byte as queried (clear from requested_mask)
        requested_mask = unset(requested_mask, byte)
        cf = _bn_get(n, byte)
        cf === nothing && continue

        # An exact value-only request does NOT enumerate an onward link stored in the same CoFree,
        # so the enumeration is not exhaustive and the caller must not treat its answer as covering
        # this node. The stashed-val fast path above `continue`s, so we only reach here when that
        # link was not requested separately. Upstream `2683d7c` — omitting this is what let a
        # left-only chain survive an intersection: `{aa,b,baa} ∩ {a,b}` returned `{aa,b,baa}`
        # (Identity) instead of `{b}`, because the request for `b`'s VALUE looked exhaustive while
        # `b`'s child `aa` went unexamined. dense_byte_node.rs:698.
        if length(key) == 1 && expect_val && cf.rec !== nothing
            unrequested_cofree_half = true
        end

        # Fill child result for rec requests
        if length(key) > 1 || !expect_val
            if cf.rec !== nothing
                results_buf[i] = (1, PayloadRef{V, A}(0x2, nothing, cf.rec))
            end
        end

        # Fill or stash val
        if cf.val !== nothing
            if length(key) == 1 && expect_val
                results_buf[i] = (1, PayloadRef{V, A}(0x1, Ref{V}(cf.val), nothing))
            else
                if last_byte === nothing
                    stashed_val = cf.val
                    last_byte = byte
                end
            end
        end
    end

    !unrequested_cofree_half && stashed_val === nothing && is_empty_mask(requested_mask)
end

function node_contains_val(n::AbstractByteNode, key::AbstractVector{UInt8})
    length(key) == 1 || return false
    cf = _bn_get(n, key[1])
    cf !== nothing && cf.val !== nothing
end

function node_get_val(n::AbstractByteNode{V, A}, key::AbstractVector{UInt8}) where {V, A}
    length(key) == 1 || return nothing
    cf = _bn_get(n, key[1])
    cf === nothing ? nothing : cf.val
end

function node_get_val_mut(
    n::AbstractByteNode{V, A}, key::AbstractVector{UInt8}
) where {V, A}
    length(key) == 1 || return nothing
    cf = _bn_get(n, key[1])
    cf === nothing ? nothing : cf.val
end

function node_set_val!(
    n::AbstractByteNode{V, A}, key::AbstractVector{UInt8}, val::V
) where {V, A}
    if length(key) > 1
        child = LineListNode{V, A}(n.alloc)
        node_set_val!(child, key[2:end], val)
        _bn_set_child!(n, key[1], TrieNodeODRc(child, n.alloc))
        return (nothing, true)
    else
        return (_bn_set_val!(n, key[1], val), false)
    end
end

function node_remove_val!(
    n::AbstractByteNode{V, A}, key::AbstractVector{UInt8}, prune::Bool
) where {V, A}
    length(key) == 1 || return nothing
    _bn_remove_val!(n, key[1], prune)
end

function node_create_dangling!(
    n::AbstractByteNode{V, A}, key::AbstractVector{UInt8}
) where {V, A}
    if length(key) > 1
        child = LineListNode{V, A}(n.alloc)
        node_create_dangling!(child, key[2:end])
        _bn_set_child!(n, key[1], TrieNodeODRc(child, n.alloc))
        return (true, true)
    else
        return (_bn_set_dangling!(n, key[1]), false)
    end
end

function node_remove_dangling!(
    n::AbstractByteNode{V, A}, key::AbstractVector{UInt8}
) where {V, A}
    length(key) == 1 || return 0
    k = key[1]
    test_bit(n.mask, k) || return 0
    idx = Int(index_of(n.mask, k)) + 1
    @inbounds cf = n.values[idx]
    if !has_rec(cf) && !has_val(cf)
        n.mask = unset(n.mask, k)
        deleteat!(n.values, idx)
        return 1
    end
    # Clean up empty node rec
    if cf.rec !== nothing && node_is_empty(as_tagged(cf.rec))
        if has_val(cf)
            cf.rec = nothing
        else
            n.mask = unset(n.mask, k)
            deleteat!(n.values, idx)
            return 1
        end
    end
    0
end

function node_set_branch!(
    n::AbstractByteNode{V, A}, key::AbstractVector{UInt8}, new_rc::TrieNodeODRc{V, A}
) where {V, A}
    if length(key) > 1
        child = LineListNode{V, A}(n.alloc)
        node_set_branch!(child, key[2:end], new_rc)
        _bn_set_child!(n, key[1], TrieNodeODRc(child, n.alloc))
        return true
    else
        _bn_set_child!(n, key[1], new_rc)
        return false
    end
end

function node_remove_all_branches!(
    n::AbstractByteNode{V, A}, key::AbstractVector{UInt8}, prune::Bool
) where {V, A}
    length(key) > 1 && return false
    k = key[1]
    test_bit(n.mask, k) || return false
    idx = Int(index_of(n.mask, k)) + 1
    @inbounds cf = n.values[idx]
    if has_rec(cf)
        if has_val(cf)
            cf.rec = nothing
        else
            if prune
                n.mask = unset(n.mask, k)
                deleteat!(n.values, idx)
            else
                cf.rec = nothing
            end
        end
        return true
    end
    false
end

node_is_empty(n::AbstractByteNode) = isempty(n.values)

function new_iter_token(n::AbstractByteNode)
    UInt128(n.mask.bits[1])
end

function iter_token_for_path(n::AbstractByteNode, key::AbstractVector{UInt8})
    length(key) != 1 && return new_iter_token(n)
    k = Int(key[1])
    idx = (k & 0b11000000) >> 6
    bit_i = k & 0b00111111
    mask_val = if bit_i + 1 < 64
        (0xFFFFFFFFFFFFFFFF << (bit_i + 1)) & n.mask.bits[idx + 1]
    else
        UInt64(0)
    end
    (UInt128(idx) << 64) | UInt128(mask_val)
end

function next_items(n::AbstractByteNode{V, A}, token::UInt128) where {V, A}
    i = UInt8((token >> 64) & 0xFF)
    w = token % UInt64   # truncate lower 64 bits (silent, matches Rust `as u64`)
    # ALL_BYTES array: byte k → &[k..=k] slice
    while true
        if w != 0
            wi = UInt8(trailing_zeros(w))
            w ⊻= UInt64(1) << wi
            k = i * UInt8(64) + wi
            new_token = (UInt128(i) << 64) | UInt128(w)
            idx = Int(index_of(n.mask, k)) + 1
            @inbounds cf = n.values[idx]
            return (new_token, UInt8[k], cf.rec, cf.val)
        elseif i < 3
            i += UInt8(1)
            w = n.mask.bits[Int(i) + 1]
        else
            return (NODE_ITER_FINISHED, UInt8[], nothing, nothing)
        end
    end
end

function node_val_count(n::AbstractByteNode, cache::Dict{UInt64, Int})
    sum(
        cf ->
            (cf.val !== nothing ? 1 : 0) +
            (cf.rec !== nothing ? val_count_below_node(cf.rec, cache) : 0),
        n.values;
        init=0
    )
end

node_goat_val_count(n::AbstractByteNode) =
    sum(cf -> cf.val !== nothing ? 1 : 0, n.values; init=0)

function node_child_iter_start(n::AbstractByteNode{V, A}) where {V, A}
    for (pos, cf) in enumerate(n.values)
        cf.rec !== nothing && return (UInt64(pos + 1), cf.rec)
    end
    (UInt64(0), nothing)
end

function node_child_iter_next(n::AbstractByteNode{V, A}, token::UInt64) where {V, A}
    for (i, cf) in enumerate(@view n.values[Int(token):end])
        cf.rec !== nothing && return (UInt64(Int(token) + i), cf.rec)
    end
    (UInt64(0), nothing)
end

function node_first_val_depth_along_key(n::AbstractByteNode, key::AbstractVector{UInt8})
    @assert !isempty(key)
    cf = _bn_get(n, key[1])
    (cf !== nothing && cf.val !== nothing) ? 0 : nothing
end

function nth_child_from_key(
    n::AbstractByteNode{V, A}, key::AbstractVector{UInt8}, nth::Int
) where {V, A}
    !isempty(key) && return (nothing, nothing)
    nth >= length(n.values) && return (nothing, nothing)
    idx = nth + 1  # 0-based nth → 1-based index
    k = indexed_bit(n.mask, nth, true)
    child = n.values[idx].rec
    (k, child === nothing ? nothing : as_tagged(child))
end

function first_child_from_key(
    n::AbstractByteNode{V, A}, key::AbstractVector{UInt8}
) where {V, A}
    @assert isempty(key)
    @assert !isempty(n.values)
    k = indexed_bit(n.mask, 0, true)
    @inbounds child = n.values[1].rec
    (k === nothing ? nothing : UInt8[k], child === nothing ? nothing : as_tagged(child))
end

function node_remove_unmasked_branches!(
    n::AbstractByteNode{V, A}, key::AbstractVector{UInt8}, mask::ByteMask, prune::Bool
) where {V, A}
    @assert isempty(key)
    new_values = CoFreeEntry{V, A}[]
    sizehint!(new_values, length(n.values))
    idx = 1
    for i in 1:4
        lm = n.mask.bits[i]
        while lm != 0
            index = Int(trailing_zeros(lm))
            bit = UInt64(1) << index
            if (bit & mask.bits[i]) != 0
                push!(new_values, n.values[idx])
            end
            idx += 1
            lm ⊻= bit
        end
    end
    n.mask = n.mask & mask
    n.values = new_values
    nothing
end

function node_branches_mask(n::AbstractByteNode, key::AbstractVector{UInt8})
    isempty(key) ? n.mask : ByteMask()
end

function count_branches(n::AbstractByteNode, key::AbstractVector{UInt8})
    isempty(key) ? length(n.values) : 0
end

function prior_branch_key(n::AbstractByteNode, key::AbstractVector{UInt8})
    @assert !isempty(key)
    length(key) == 1 && return UInt8[]
    k = key[1]
    test_bit(n.mask, k) ? UInt8[k] : UInt8[]
end

function get_sibling_of_child(
    n::AbstractByteNode{V, A}, key::AbstractVector{UInt8}, nxt::Bool
) where {V, A}
    length(key) != 1 && return (nothing, nothing)
    k = key[1]
    mask_i = ((k & 0xC0) >> 6) + 1   # 1-based word index
    bit_i = k & UInt8(0x3F)

    nb = bit_sibling(bit_i, n.mask.bits[mask_i], !nxt)
    if nb == bit_i  # no sibling in this word — search adjacent words
        local found = false
        local new_mask_i = mask_i
        while true
            nxt ? (new_mask_i += 1) : (new_mask_i -= 1)
            (new_mask_i < 1 || new_mask_i > 4) && break
            w = n.mask.bits[new_mask_i]
            w == 0 && continue
            nb = nxt ? UInt8(trailing_zeros(w)) : UInt8(63 - leading_zeros(w))
            mask_i = new_mask_i
            found = true
            break
        end
        found || return (nothing, nothing)
    end

    sibling_key = nb | (UInt8((mask_i - 1) << 6))
    @assert test_bit(n.mask, sibling_key)
    idx = Int(index_of(n.mask, sibling_key)) + 1
    @inbounds cf = n.values[idx]
    child = cf.rec === nothing ? nothing : as_tagged(cf.rec)
    (sibling_key, child)
end

function get_node_at_key(n::AbstractByteNode{V, A}, key::AbstractVector{UInt8}) where {V, A}
    if length(key) < 2
        if isempty(key)
            return node_is_empty(n) ? ANRNone{V, A}() : ANRBorrowedDyn{V, A}(n)
        else
            cf = _bn_get(n, key[1])
            cf === nothing && return ANRNone{V, A}()
            cf.rec === nothing && return ANRNone{V, A}()
            return ANRBorrowedRc{V, A}(cf.rec)
        end
    end
    ANRNone{V, A}()
end

function take_node_at_key!(
    n::AbstractByteNode{V, A}, key::AbstractVector{UInt8}, prune::Bool
) where {V, A}
    length(key) < 2 || return nothing
    @assert length(key) == 1
    k = key[1]
    test_bit(n.mask, k) || return nothing
    idx = Int(index_of(n.mask, k)) + 1
    @inbounds cf = n.values[idx]
    result = cf.rec
    cf.rec = nothing
    if prune && !has_val(cf)
        n.mask = unset(n.mask, k)
        deleteat!(n.values, idx)
    end
    result
end

# =====================================================================
# Lattice ops on AbstractByteNode
# =====================================================================

function pjoin_dyn(n::AbstractByteNode{V, A}, other::AbstractTrieNode{V, A}) where {V, A}
    tag = node_tag(other)
    if tag == DENSE_BYTE_NODE_TAG || tag == CELL_BYTE_NODE_TAG
        _bn_pjoin(n, other)
    elseif tag == LINE_LIST_NODE_TAG
        new_node = deepcopy_bn(n)
        status = merge_from_list_node!(new_node, other)
        from_status(status, () -> TrieNodeODRc(new_node, n.alloc))
    elseif tag == TINY_REF_NODE_TAG
        # delegate to tiny.pjoin_dyn(self) — tiny calls into_full first
        r = pjoin_dyn(other, n)   # other is TinyRefNode, dispatches its method
        invert_identity(r)
    elseif tag == EMPTY_NODE_TAG
        AlgResIdentity(SELF_IDENT)
    else
        error("DenseByteNode::pjoin_dyn — unknown tag $tag")
    end
end

# Shallow clone: copy the bitmask (a value), and SHARE child subtries per-entry via
# _cf_copy (copy() of cf.rec bumps the child refcount), instead of deepcopy(values)
# which deep-copied whole subtrees and defeated structural sharing (audit 2026-06-02,
# close-out step 2). Kept sound by the COW make_unique! discipline before mutation.
# `n.mask` is an immutable ByteMask (wraps Bits4 = NTuple{4,UInt64}), so it is shared
# by value — no copy needed (and `copy(::ByteMask)` is not defined; calling it threw a
# MethodError that silently emptied any cloned byte node — caught by MorkServer's
# metta_thread/copy integration, missed by the unit COW tests which stay in list nodes).
function deepcopy_bn(n::DenseByteNode{V, A}) where {V, A}
    DenseByteNode{V, A}(n.mask, CoFreeEntry{V, A}[_cf_copy(cf) for cf in n.values], n.alloc)
end
function deepcopy_bn(n::CellByteNode{V, A}) where {V, A}
    CellByteNode{V, A}(n.mask, CoFreeEntry{V, A}[_cf_copy(cf) for cf in n.values], n.alloc)
end

function join_into_dyn!(n::AbstractByteNode{V, A}, other::TrieNodeODRc{V, A}) where {V, A}
    other_node = as_tagged(other)
    tag = node_tag(other_node)
    if tag == DENSE_BYTE_NODE_TAG || tag == CELL_BYTE_NODE_TAG
        status = _bn_join_into!(n, other_node)
        (status, nothing)
    elseif tag == LINE_LIST_NODE_TAG
        status = merge_from_list_node!(n, other_node)
        (status, nothing)
    elseif tag == EMPTY_NODE_TAG
        (ALG_STATUS_IDENTITY, nothing)
    else
        error("DenseByteNode::join_into_dyn! — unknown tag $tag")
    end
end

function drop_head_dyn!(n::AbstractByteNode{V, A}, byte_cnt::Int) where {V, A}
    len = length(n.values)
    if len == 0
        return nothing
    elseif len == 1
        @inbounds cf = n.values[1]
        cf.rec === nothing && return nothing
        child = copy(cf.rec)
        if byte_cnt > 1
            make_unique!(child)
            return drop_head_dyn!(as_tagged(child), byte_cnt - 1)
        else
            return child
        end
    else
        new_node = typeof(n)(n.alloc)
        for cf in n.values
            cf.rec === nothing && continue
            child = copy(cf.rec)
            if byte_cnt > 1
                make_unique!(child)
                child_result = drop_head_dyn!(as_tagged(child), byte_cnt - 1)
                child_result === nothing && continue
                join_into_dyn!(new_node, child_result)
            else
                join_into_dyn!(new_node, child)
            end
        end
        node_is_empty(new_node) && return nothing
        TrieNodeODRc(new_node, n.alloc)
    end
end

function pmeet_dyn(n::AbstractByteNode{V, A}, other::AbstractTrieNode{V, A}) where {V, A}
    tag = node_tag(other)
    if tag == DENSE_BYTE_NODE_TAG || tag == CELL_BYTE_NODE_TAG
        _bn_pmeet(n, other)
    elseif tag == LINE_LIST_NODE_TAG || tag == TINY_REF_NODE_TAG
        r = pmeet_dyn(other, n)
        invert_identity(r)
    elseif tag == EMPTY_NODE_TAG
        AlgResNone()
    else
        error("DenseByteNode::pmeet_dyn — unknown tag $tag")
    end
end

function psubtract_dyn(
    n::AbstractByteNode{V, A}, other::AbstractTrieNode{V, A}
) where {V, A}
    tag = node_tag(other)
    if tag == DENSE_BYTE_NODE_TAG || tag == CELL_BYTE_NODE_TAG
        _bn_psubtract(n, other)
    elseif tag == LINE_LIST_NODE_TAG || tag == TINY_REF_NODE_TAG
        _bn_psubtract_abstract(n, other)
    elseif tag == EMPTY_NODE_TAG
        AlgResIdentity(SELF_IDENT)
    else
        error("DenseByteNode::psubtract_dyn — unknown tag $tag")
    end
end

function prestrict_dyn(
    n::AbstractByteNode{V, A}, other::AbstractTrieNode{V, A}
) where {V, A}
    tag = node_tag(other)
    if tag == DENSE_BYTE_NODE_TAG || tag == CELL_BYTE_NODE_TAG
        _bn_prestrict(n, other)
    elseif tag == LINE_LIST_NODE_TAG || tag == TINY_REF_NODE_TAG
        _bn_prestrict_abstract(n, other)
    elseif tag == EMPTY_NODE_TAG
        AlgResNone()
    else
        error("DenseByteNode::prestrict_dyn — unknown tag $tag")
    end
end

function clone_self(n::DenseByteNode{V, A}) where {V, A}
    TrieNodeODRc(deepcopy_bn(n), n.alloc)   # deepcopy_bn is now a shallow (sharing) clone
end
function clone_self(n::CellByteNode{V, A}) where {V, A}
    TrieNodeODRc(deepcopy_bn(n), n.alloc)
end

# =====================================================================
# TrieNodeDowncast — node_tag and convert_to_cell_node!
# =====================================================================

node_tag(::DenseByteNode) = DENSE_BYTE_NODE_TAG
node_tag(::CellByteNode) = CELL_BYTE_NODE_TAG

function convert_to_cell_node!(n::DenseByteNode{V, A}) where {V, A}
    # Convert by copying all CoFreeEntries into a new CellByteNode
    cell = CellByteNode{V, A}(n.mask, copy(n.values), n.alloc)
    TrieNodeODRc(cell, n.alloc)
end

function convert_to_cell_node!(::CellByteNode)
    error("CellByteNode::convert_to_cell_node! — unreachable (already a cell node)")
end

# =====================================================================
# Exports
# =====================================================================

"""
    node_add_payload!(n::DenseByteNode, key, is_child, payload)

Add a (key, payload) entry to a DenseByteNode.  For keys > 1 byte, a
BridgeNode child is created to hold the remaining suffix.
Mirrors `DenseByteNode::add_payload` in dense_byte_node.rs.
"""
function node_add_payload!(
    n::DenseByteNode{V, A}, key::AbstractVector{UInt8}, is_child::Bool,
    payload::ValOrChild{V, A}
) where {V, A}
    @assert !isempty(key)
    if length(key) > 1
        child_node = BridgeNode(key[2:end], is_child, payload, n.alloc)
        _bn_set_child!(n, key[1], TrieNodeODRc(child_node, n.alloc))
    else
        if is_child
            _bn_set_child!(n, key[1], into_child(payload))
        else
            _bn_set_val!(n, key[1], into_val(payload))
        end
    end
end

export CoFreeEntry, has_rec, has_val
export AbstractByteNode, DenseByteNode, CellByteNode
export merge_from_list_node!, bit_sibling, val_count_below_node
export node_add_payload!
