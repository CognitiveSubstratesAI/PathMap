"""
ProductZipper — port of `pathmap/src/product_zipper.rs` (upstream 0.4.0 @ f477a91).

Creates a virtual Cartesian-product trie from N source tries.  Paths in the
product trie are formed by concatenating one path from each factor in order.

Example with 2 factors A={a,b} and B={x,y}:
  Product paths = {ax, ay, bx, by}

The implementation reuses `ReadZipperCore` as the primary cursor, pushing
secondary factor roots onto its ancestor stack at factor boundaries.

Julia translation notes:
  - Rust `take_core()` + `push_node()` + `regularize()` → implemented as
    `_zc_push_node!` + `_zc_regularize!` + `_zc_deregularize!` on ReadZipperCore.
  - `TrieRefOwned` (secondary roots) → TrieRefBorrowed in Julia (GC-managed).
  - `source_zippers` ownership (to keep TrieRef alive) → Julia GC handles this.
  - Trait methods are methods of the generic functions in ZipperTraits.jl; upstream implements
    `ZipperIteration` with the trait defaults only (product_zipper.rs:313), so the k-path and
    value-iteration walks come from ZipperTraits.jl and are not repeated here.
"""

# =====================================================================
# ProductZipper struct
# =====================================================================

"""
    ProductZipper{V, A}

Cartesian-product zipper over N factors.
Mirrors `ProductZipper<'factor_z, 'trie, V, A>` (product_zipper.rs:10-19).
"""
mutable struct ProductZipper{V, A <: Allocator} <: AbstractZipper
    z::ReadZipperCore{V, A}      # primary cursor (owns the ancestor stack)
    secondaries::Vector{TrieRefBorrowed{V, A}}  # secondary factor roots
    factor_paths::Vector{Int}             # path lengths at each factor boundary
end

"""
    ProductZipper(primary_z, other_zippers) → ProductZipper

Create a ProductZipper from a primary ReadZipperCore and an iterable of
additional factor zippers (each must be a ReadZipperCore).
Mirrors `ProductZipper::new` (product_zipper.rs:42-69).
"""
function ProductZipper(primary_z::ReadZipperCore{V, A}, other_zippers) where {V, A}
    reset!(primary_z)
    secondaries = TrieRefBorrowed{V, A}[]
    for oz in other_zippers
        # Fork a TrieRef at the root of each secondary zipper
        t = trie_ref_at_path(PathMap{V, A}(oz.root_node, oz.root_val, oz.alloc), UInt8[])
        push!(secondaries, t)
    end
    # Upstream: factor_paths pre-allocated with Vec::with_capacity(secondaries.len())
    fp = Int[]
    sizehint!(fp, length(secondaries))
    ProductZipper{V, A}(primary_z, secondaries, fp)
end

"""
    ProductZipper(primary_z) → ProductZipper

Create a ProductZipper with only the primary factor.
Mirrors `ProductZipper::new_with_primary` (product_zipper.rs:72-83).
"""
function ProductZipper(primary_z::ReadZipperCore{V, A}) where {V, A}
    reset!(primary_z)
    ProductZipper{V, A}(primary_z, TrieRefBorrowed{V, A}[], Int[])
end

"""
    ProductZipper(m::PathMap, prefix, n_factors) → ProductZipper

Anchored constructor: build an `n_factors`-way Cartesian-product zipper whose
factors all traverse the **subtrie rooted at `prefix`** in `m`, rather than
the whole trie.

Why this exists (vs. `ProductZipper(read_zipper_at_path(m, prefix), …)`):
`read_zipper_at_path` records the prefix only as a *cursor position*; its
`root_node` stays the trie root.  The base `ProductZipper` constructor then
re-roots each secondary from `root_node` and resets the primary to its
origin — both of which discard the prefix anchor.  The result traverses the
whole trie and `path` carries the raw prefix bytes (which then crash
expression decoders that expect tag bytes).

This constructor instead resolves the prefix to its actual subtrie-root node
via `trie_ref_at_path` + `into_option(get_focus(...))`, wraps that node
as a fresh `PathMap` root, and builds every factor with `read_zipper` over it.
Each factor zipper therefore has `origin = 0` relative to the prefix node, so
`path` is anchor-relative (no prefix bytes) and traversal is O(subtrie) —
a true prefix-scoped view, no copy.

`get_focus` (not `_tr_get_focus_rc`) is used deliberately: when `prefix`
lands *inside* a compressed edge — e.g. a single atom `b/foo` path-compresses
`b/foo` into one edge with no node boundary at `b/` — `_tr_get_focus_rc`
returns `nothing` (no child exactly at the prefix), which would wrongly look
like an empty region.  `get_node_at_key` (reached via `get_focus`)
instead peels the consumed prefix off the compressed key and returns a node
for the remaining subtrie (`ANRBorrowedTiny`); `into_option` materializes it
as a clean root rc via a shallow node clone (children stay shared — still a
view, not an O(subtrie) copy).  Resolving to a clean root up front also keeps
the ProductZipper's own factor-enrollment (which uses `_tr_get_focus_rc`)
correct, since it then operates on a node-boundary root, never mid-edge.

An empty / absent prefix region yields a ProductZipper over an empty trie
(iteration produces nothing), matching the "no matches under this prefix"
semantics callers expect.
"""
function ProductZipper(
    m::PathMap{V, A}, prefix::AbstractVector{UInt8}, n_factors::Int
) where {V, A}
    n_factors >= 1 || throw(ArgumentError("n_factors must be >= 1"))
    _ensure_root!(m)
    tr = trie_ref_at_path(m, prefix)
    rc = _tr_is_valid(tr) ? into_option(get_focus(tr)) : nothing
    sub = if rc === nothing
        e = PathMap{V, A}(m.alloc)
        _ensure_root!(e)
        e        # empty region
    else
        PathMap{V, A}(rc, nothing, m.alloc)                    # root AT prefix node
    end
    primary = read_zipper(sub)
    n_factors == 1 && return ProductZipper(primary)
    secondaries = ReadZipperCore{V, A}[read_zipper(sub) for _ in 2:n_factors]
    ProductZipper(primary, secondaries)
end

# =====================================================================
# Internal helpers
# =====================================================================

"""
True if there is a next secondary factor not yet enrolled (`has_next_factor`,
product_zipper.rs:112-115).
"""
_pz_has_next_factor(pz::ProductZipper) = length(pz.factor_paths) < length(pz.secondaries)

"""
Push the next secondary factor's root onto the primary zipper's ancestor stack.
Mirrors `ProductZipper::enroll_next_factor` (product_zipper.rs:116-132).
"""
function _pz_enroll_next_factor!(pz::ProductZipper{V, A}) where {V, A}
    idx = length(pz.factor_paths) + 1   # 1-based secondary index
    t = pz.secondaries[idx]
    _tr_is_valid(t) || return nothing
    # Get the root node of the secondary factor
    rc = _tr_get_focus_rc(t)
    rc === nothing && return nothing
    secondary_root = _rc_inner(rc)
    _zc_deregularize!(pz.z)
    _zc_push_node!(pz.z, secondary_root)
    push!(pz.factor_paths, depth(pz.z))
end

"""
If at a factor boundary (leaf of current factor), enroll the next factor.
Mirrors `ProductZipper::ensure_descend_next_factor` (product_zipper.rs:137-150).
"""
function _pz_ensure_descend_next_factor!(pz::ProductZipper)
    _pz_has_next_factor(pz) || return nothing
    child_count(pz.z) == 0 || return nothing
    # We don't want to push the same factor on the stack twice
    last_fp = isempty(pz.factor_paths) ? 0 : pz.factor_paths[end]
    last_fp < depth(pz.z) || return nothing
    _pz_enroll_next_factor!(pz)
end

"""
After any ascend, pop factor_paths entries that are now above the cursor.
Mirrors `ProductZipper::fix_after_ascend` (product_zipper.rs:152-161).
"""
function _pz_fix_after_ascend!(pz::ProductZipper)
    d = depth(pz.z)
    while !isempty(pz.factor_paths) && d < pz.factor_paths[end]
        pop!(pz.factor_paths)
    end
end

# =====================================================================
# Zipper (product_zipper.rs:348-362)
# =====================================================================

path_exists(pz::ProductZipper) = path_exists(pz.z)
is_val(pz::ProductZipper) = is_val(pz.z)
child_count(pz::ProductZipper) = child_count(pz.z)
child_mask(pz::ProductZipper) = child_mask(pz.z)

# ── ZipperValues / ZipperValuesAt (product_zipper.rs:315-325): the values come from the primary
#    core's read-only accessors, because the focus may sit inside a pushed secondary node.
val(pz::ProductZipper) = get_val(pz.z)
get_val(pz::ProductZipper) = get_val(pz.z)
val_at(pz::ProductZipper, p::AbstractVector{UInt8}) = get_val_at(pz.z, p)
get_val_at(pz::ProductZipper, p::AbstractVector{UInt8}) = get_val_at(pz.z, p)

# ── ZipperConcrete (product_zipper.rs:364-367)
shared_node_id(pz::ProductZipper) = shared_node_id(pz.z)
is_shared(pz::ProductZipper) = is_shared(pz.z)

# =====================================================================
# ZipperMoving (product_zipper.rs:164-304)
# =====================================================================

depth(pz::ProductZipper) = depth(pz.z)
focus_byte(pz::ProductZipper) = focus_byte(pz.z)

function reset!(pz::ProductZipper)
    empty!(pz.factor_paths)
    reset!(pz.z)
    nothing
end

function val_count(pz::ProductZipper)
    @assert focus_factor(pz) == factor_count(pz) - 1
    val_count(pz.z)
end

function descend_to_existing!(pz::ProductZipper, k)
    kv = k isa AbstractVector{UInt8} ? k : collect(UInt8, k)
    descended = 0
    while descended < length(kv)
        this_step = descend_to_existing!(pz.z, view(kv, (descended + 1):length(kv)))
        this_step == 0 && break
        descended += this_step
        if _pz_has_next_factor(pz)
            if child_count(pz.z) == 0 &&
               (isempty(pz.factor_paths) ? 0 : pz.factor_paths[end]) < depth(pz)
                _pz_enroll_next_factor!(pz)
            end
        else
            break
        end
    end
    descended
end

function descend_to!(pz::ProductZipper, k)
    kv = k isa AbstractVector{UInt8} ? k : collect(UInt8, k)
    descended = descend_to_existing!(pz, kv)
    if descended != length(kv)
        descend_to!(pz.z, view(kv, (descended + 1):length(kv)))
    end
    nothing
end

# product_zipper.rs:209-217 — like `descend_to!`, but reporting whether the whole key existed
function descend_to_check!(pz::ProductZipper, k)
    kv = k isa AbstractVector{UInt8} ? k : collect(UInt8, k)
    descended = descend_to_existing!(pz, kv)
    if descended != length(kv)
        descend_to!(pz.z, view(kv, (descended + 1):length(kv)))
        return false
    end
    true
end

function descend_to_byte!(pz::ProductZipper, k::UInt8)
    descend_to_byte!(pz.z, k)
    if child_count(pz.z) == 0
        if _pz_has_next_factor(pz) && path_exists(pz.z)
            @assert (isempty(pz.factor_paths) ? 0 : pz.factor_paths[end]) < depth(pz)
            _pz_enroll_next_factor!(pz)
            isempty(_zc_node_key(pz.z)) || _zc_regularize!(pz.z)
        end
    end
    nothing
end

# product_zipper.rs:233-246
function descend_to_existing_byte!(pz::ProductZipper, k::UInt8)
    descended = descend_to_existing_byte!(pz.z, k)
    if descended && child_count(pz.z) == 0
        if _pz_has_next_factor(pz)
            @assert (isempty(pz.factor_paths) ? 0 : pz.factor_paths[end]) < depth(pz)
            _pz_enroll_next_factor!(pz)
            isempty(_zc_node_key(pz.z)) || _zc_regularize!(pz.z)
        end
    end
    descended
end

function descend_indexed_byte!(pz::ProductZipper, idx::Int)::Union{Nothing, UInt8}
    result = descend_indexed_byte!(pz.z, idx)
    _pz_ensure_descend_next_factor!(pz)
    result
end

function descend_first_byte!(pz::ProductZipper)::Union{Nothing, UInt8}
    result = descend_first_byte!(pz.z)
    _pz_ensure_descend_next_factor!(pz)
    result
end

function descend_until_observed!(pz::ProductZipper, obs)
    moved = false
    while child_count(pz.z) == 1
        moved |= descend_until_observed!(pz.z, obs)
        _pz_ensure_descend_next_factor!(pz)
        is_val(pz.z) && break
    end
    moved
end

function to_next_sibling_byte!(pz::ProductZipper)::Union{Nothing, UInt8}
    if !isempty(pz.factor_paths) && pz.factor_paths[end] == depth(pz)
        pop!(pz.factor_paths)
    end
    moved = to_next_sibling_byte!(pz.z)
    _pz_ensure_descend_next_factor!(pz)
    moved
end

function to_prev_sibling_byte!(pz::ProductZipper)::Union{Nothing, UInt8}
    if !isempty(pz.factor_paths) && pz.factor_paths[end] == depth(pz)
        pop!(pz.factor_paths)
    end
    moved = to_prev_sibling_byte!(pz.z)
    _pz_ensure_descend_next_factor!(pz)
    moved
end

function ascend!(pz::ProductZipper, steps::Int)::Int
    ascended = ascend!(pz.z, steps)
    _pz_fix_after_ascend!(pz)
    ascended
end

function ascend_byte!(pz::ProductZipper)
    ascended = ascend_byte!(pz.z)
    _pz_fix_after_ascend!(pz)
    ascended
end

function ascend_until!(pz::ProductZipper)::Int
    ascended = ascend_until!(pz.z)
    _pz_fix_after_ascend!(pz)
    ascended
end

function ascend_until_branch!(pz::ProductZipper)::Int
    ascended = ascend_until_branch!(pz.z)
    _pz_fix_after_ascend!(pz)
    ascended
end

# =====================================================================
# ZipperPath / ZipperAbsolutePath (product_zipper.rs:306-311, 375-378)
# =====================================================================

path(pz::ProductZipper) = path(pz.z)
origin_path(pz::ProductZipper) = origin_path(pz.z)
root_prefix_path(pz::ProductZipper) = root_prefix_path(pz.z)

# `ZipperIteration` (`to_next_val!`, `descend_last_path!`, `descend_first_k_path!`,
# `to_next_k_path!` and their `_observed` forms) uses the trait defaults for this type —
# product_zipper.rs:313 ("Use the default impl for all methods").

# =====================================================================
# ZipperProduct (product_zipper.rs:833-877)
# =====================================================================

"`factor_count(pz)` — the number of factors, counting the primary (so always >= 1)."
function factor_count end
"`focus_factor(pz)` — the index (0-based) of the factor containing the focus."
function focus_factor end
"`path_indices(pz)` — the end-points, within `path`, of each factor's portion of the path."
function path_indices end

factor_count(pz::ProductZipper) = length(pz.secondaries) + 1

function focus_factor(pz::ProductZipper)::Int
    isempty(pz.factor_paths) && return 0
    factor_idx = length(pz.factor_paths)
    pz.factor_paths[end] < depth(pz) ? factor_idx : factor_idx - 1
end

path_indices(pz::ProductZipper) = pz.factor_paths

# =====================================================================
# Exports
# =====================================================================

export ProductZipper
export factor_count, focus_factor, path_indices
