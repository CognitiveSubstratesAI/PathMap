# PathMap.jl — byte-slice-keyed trie map container
#
# Ports pathmap/src/trie_map.rs (PathMap<V,A>, lattice ops).
# Extracted from Zipper.jl to mirror upstream's standalone trie_map.rs file.
#
# Depends on: TrieNode types, ReadZipperCore, Allocator, Ring algebra

# =====================================================================
# PathMap container (ports pathmap/src/trie_map.rs — read API)
# =====================================================================

"""
    PathMap{V, A<:Allocator}

Byte-slice-keyed trie map.  Ports `PathMap<V,A>` from `trie_map.rs`.
Read API is fully implemented via `ReadZipperCore`.
Write API (`set_val_at!`, `remove_val_at!`) is in WriteZipper.jl.
"""
mutable struct PathMap{V, A <: Allocator}
    root::Union{Nothing, TrieNodeODRc{V, A}}
    root_val::Union{Nothing, V}
    alloc::A
end

PathMap{V}() where {V} = PathMap{V, GlobalAlloc}(nothing, nothing, GlobalAlloc())

PathMap{V, A}(alloc::A) where {V, A <: Allocator} = PathMap{V, A}(nothing, nothing, alloc)

function _ensure_root!(m::PathMap{V, A}) where {V, A}
    m.root === nothing || return nothing
    m.root = TrieNodeODRc(LineListNode{V, A}(m.alloc), m.alloc)
end

# ---- read zipper factories ----

"""
    read_zipper(m::PathMap) -> ReadZipperCore

Creates a read-only zipper at the root of `m`.
"""
function read_zipper(m::PathMap{V, A}) where {V, A}
    _ensure_root!(m)
    root_rc = m.root::TrieNodeODRc{V, A}
    ReadZipperCore(root_rc, UInt8[], 0, m.root_val, m.alloc)
end

"""
    read_zipper_at_path(m::PathMap, path) -> ReadZipperCore

Creates a read-only zipper pre-positioned at `path`.
"""
function read_zipper_at_path(m::PathMap{V, A}, path::AbstractVector{UInt8}) where {V, A}
    _ensure_root!(m)
    root_rc = m.root::TrieNodeODRc{V, A}
    path_v = path isa Vector{UInt8} ? path : Vector{UInt8}(path)
    rv = isempty(path_v) ? m.root_val : nothing
    ReadZipperCore_at_path(root_rc, path_v, length(path_v), 0, rv, m.alloc)
end
function read_zipper_at_path(m::PathMap{V, A}, path::AbstractString) where {V, A}
    read_zipper_at_path(m, codeunits(path))
end
function read_zipper_at_path(m::PathMap{V, A}, path) where {V, A}
    read_zipper_at_path(m, collect(UInt8, path))
end

# ---- high-level read API ----

"""
    get_val_at(m::PathMap, path) -> Union{Nothing, V}

`path` may be `Vector{UInt8}`, `AbstractVector{UInt8}`, `AbstractString`, or
any byte-iterable.

Two-phase lookup (Fix 4 corrected):
Phase 1: node_along_path — fast child-traversal, zero heap allocation.
Handles paths that terminate at a child edge boundary.
Phase 2: node_get_val fallback — handles leaf values stored directly in
a node's value slot (node_get_child returns nothing for these).
node_get_child only returns child-slot entries; value-slot entries
are invisible to node_along_path without this fallback.
"""
function get_val_at(m::PathMap{V, A}, path) where {V, A}
    _ensure_root!(m)
    m.root === nothing && return m.root_val
    path_v = path isa AbstractVector{UInt8} ? path : collect(UInt8, path)
    isempty(path_v) && return m.root_val
    last_rc, off, _ = node_along_path_off(m.root::TrieNodeODRc{V, A}, path_v)
    # Uniform value lookup at the stop node over a VIEW of the remaining bytes (no copy):
    # terminal-match → value at the matched edge; stall → value-slot or nothing.
    inner = _fnode(_rc_inner(last_rc), V, A)
    node_get_val(inner, view(path_v, (off + 1):length(path_v)))
end

"""
    path_exists_at(m::PathMap, path) -> Bool

Returns true if the path structurally exists in the trie (with OR without a value).
Dangling paths (empty child nodes, no value) also return true — they are valid
structural paths created by wz_create_path!.

Two-phase:
Phase 1: node_along_path consumed all bytes → path exists (dangling or valued).
Phase 2: node_along_path stalled → check if remaining matches a value slot.
"""
function path_exists_at(m::PathMap{V, A}, path) where {V, A}
    # 1:1 with upstream trie_map.rs:328-332, which is simply
    #     let zipper = self.read_zipper_at_borrowed_path(path); zipper.path_exists()
    # This used to be a bespoke two-phase reimplementation (node_along_path_off + a value-slot
    # check) that disagreed with our OWN zipper — and the zipper was the one matching upstream.
    # Measured before the fix, map {abc, abcdefghij}:
    #     path_exists_at("a")=false / "abcd"=false / "abcdefghi"=false   (upstream: all true)
    # and for a single 16-byte key, prefixes 1..16 gave FFFFFFFFFFFFFTFT where upstream gives
    # all-true. The two-phase logic only reported a MID-EDGE prefix as existing when it happened
    # to land on a node boundary; upstream's zipper descends into the edge itself.
    # Do not reintroduce a hand-rolled traversal here: the zipper already implements it.
    _ensure_root!(m)
    path_v = path isa AbstractVector{UInt8} ? path : collect(UInt8, path)
    # The EMPTY path always exists — upstream returns true even for an empty map
    # (`read_zipper_at_borrowed_path("").path_exists()`; our own zipper_path_exists agrees,
    # Zipper.jl:483 `isempty(key) ? true : ...`). We previously returned
    # `m.root_val !== nothing`, i.e. false unless a ROOT VALUE happened to exist — measured
    # against upstream by test/differential (path_exists_at/<empty>, /empty_map_empty_path,
    # /rootval_empty_path all true upstream; /empty_map_some_path false).
    isempty(path_v) && return true
    m.root === nothing && return false
    last_rc, off, full = node_along_path_off(m.root::TrieNodeODRc{V, A}, path_v)
    # full match (remaining matched a child edge, incl. a dangling edge) → structurally exists.
    full && return true
    inner = _fnode(_rc_inner(last_rc), V, A)
    rem = view(path_v, (off + 1):length(path_v))
    # Stalled with bytes left → value-slot check (view of the remaining bytes — no copy).
    node_get_val(inner, rem) !== nothing && return true
    # …and the case this function used to MISS: the remaining bytes are a proper PREFIX of a child
    # edge. `node_get_child_nb` only matches when the remaining CONTAINS a whole edge, so a path
    # landing mid-edge broke the loop with full=false and then failed the value check, and we
    # answered false where upstream answers true. Measured on {abc, abcdefghij}: "a", "abcd",
    # "abcdefghi" were all reported absent; a single 16-byte key gave FFFFFFFFFFFFFTFT across
    # prefix lengths 1..16 instead of all-true.
    # `node_contains_partial_key` is the SAME primitive `zipper_path_exists` (Zipper.jl:482) uses,
    # so this now agrees with the zipper — and with upstream trie_map.rs:328, which is literally
    # `read_zipper_at_borrowed_path(path).path_exists()`. Kept as a direct node walk rather than
    # delegating to a zipper because zipper construction allocates and
    # test_alloc_regression.jl:36 pins this function at <= 8 bytes.
    node_contains_partial_key(inner, rem)
end

function Base.isempty(m::PathMap)
    root_empty =
        m.root === nothing ||
        node_is_empty(_fnode(_rc_inner(m.root), eltype_V(m), eltype_A(m)))
    root_empty && isnothing(m.root_val)
end

# type helpers for PathMap parameterization
eltype_V(::PathMap{V}) where {V} = V
eltype_A(::PathMap{V, A}) where {V, A} = A

"""
    val_count(m::PathMap) -> Int

Total values. O(N).
"""
function val_count(m::PathMap{V, A}) where {V, A}
    rv = isnothing(m.root_val) ? 0 : 1
    m.root === nothing ? rv : val_count_below_root(_fnode(_rc_inner(m.root), V, A)) + rv
end

# =====================================================================
# PathMap lattice ops — ports trie_map.rs Lattice/DistributiveLattice/Quantale impls
# =====================================================================

# Helper: build a new PathMap from merged root_node and root_val results.
function _pm_build(
    root_node_res, root_val_res, self_root, other_root, self_val, other_val, alloc::A
) where {A <: Allocator}
    alg_merge(
        root_node_res,
        root_val_res,
        function (which)
            which == 0 ? self_root : other_root
        end,
        function (which)
            which == 0 ? self_val : other_val
        end,
        function (rn, rv)
            flat_rn = rn isa TrieNodeODRc ? rn : nothing
            flat_rv = rv
            AlgResElement(PathMap(flat_rn, flat_rv, alloc))
        end
    )
end

"""
    pjoin(a::PathMap{V,A}, b::PathMap{V,A}) → AlgebraicResult{PathMap{V,A}}

Lattice join. Ports `Lattice::pjoin` for PathMap (trie_map.rs line 685).
"""
function pjoin(a::PathMap{V, A}, b::PathMap{V, A}) where {V, A}
    node_res = pjoin(a.root, b.root)
    val_res = pjoin(a.root_val, b.root_val)
    alg_merge(
        node_res,
        val_res,
        which -> which == 0 ? a.root : b.root,
        which -> which == 0 ? a.root_val : b.root_val,
        (rn, rv) -> AlgResElement(PathMap{V, A}(rn, rv, a.alloc))
    )
end

"""
    pmeet(a::PathMap{V,A}, b::PathMap{V,A}) → AlgebraicResult{PathMap{V,A}}

Lattice meet. Ports `Lattice::pmeet` for PathMap (trie_map.rs line 725).
"""
function pmeet(a::PathMap{V, A}, b::PathMap{V, A}) where {V, A}
    node_res = pmeet(a.root, b.root)
    val_res = pmeet(a.root_val, b.root_val)
    alg_merge(
        node_res,
        val_res,
        which -> which == 0 ? a.root : b.root,
        which -> which == 0 ? a.root_val : b.root_val,
        (rn, rv) -> AlgResElement(PathMap{V, A}(rn, rv, a.alloc))
    )
end

"""
    psubtract(a::PathMap{V,A}, b::PathMap{V,A}) → AlgebraicResult{PathMap{V,A}}

Lattice subtract. Ports `DistributiveLattice::psubtract` for PathMap (trie_map.rs line 747).
"""
function psubtract(a::PathMap{V, A}, b::PathMap{V, A}) where {V, A}
    node_res = psubtract(a.root, b.root)
    val_res = psubtract(a.root_val, b.root_val)
    alg_merge(
        node_res,
        val_res,
        which -> which == 0 ? a.root : b.root,
        which -> which == 0 ? a.root_val : b.root_val,
        (rn, rv) -> AlgResElement(PathMap{V, A}(rn, rv, a.alloc))
    )
end

"""
    prestrict(a::PathMap{V,A}, b::PathMap{V,A}) → AlgebraicResult{PathMap{V,A}}

Quantale restrict. Ports `Quantale::prestrict` for PathMap (trie_map.rs line 769).
"""
function prestrict(a::PathMap{V, A}, b::PathMap{V, A}) where {V, A}
    b.root_val !== nothing && return AlgResIdentity(SELF_IDENT)
    a_root = a.root
    b_root = b.root
    if a_root === nothing || b_root === nothing
        return AlgResNone()
    end
    r = prestrict_dyn(as_tagged(a_root), as_tagged(b_root))
    if r isa AlgResElement
        return AlgResElement(PathMap{V, A}(r.value, nothing, a.alloc))
    elseif r isa AlgResIdentity
        if a.root_val !== nothing
            return AlgResElement(PathMap{V, A}(a_root, nothing, a.alloc))
        else
            return AlgResIdentity(SELF_IDENT)
        end
    else
        return AlgResNone()
    end
end

# =====================================================================
# Exports
# =====================================================================

export PathMap, _ensure_root!, read_zipper, read_zipper_at_path
export get_val_at, path_exists_at, val_count, eltype_V, eltype_A
export pjoin, pmeet, psubtract, prestrict
