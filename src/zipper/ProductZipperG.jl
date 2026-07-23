"""
ProductZipperG — 1:1 port of `pathmap/src/product_zipper.rs` ProductZipperG.

Generic Cartesian-product zipper over N factors where primary and secondary
zippers are of arbitrary (possibly different) types.  Mirrors
`ProductZipperG<'trie, PrimaryZ, SecondaryZ, V>`.

Unlike `ProductZipper` (which requires ReadZipperCore/TrieRef secondaries),
`ProductZipperG` accepts any zipper type implementing the standard interface
(`path_exists`, `is_val`, `child_count`, `child_mask`, `descend_*`, `ascend_*`).

Used by `space_query_multi_i` when pattern factors include non-BTM sources.
"""

# =====================================================================
# Helper dispatch — generic zipper interface
# Mirrors the trait bounds on ProductZipperG (ZipperMoving + Zipper + ZipperIteration)
# Each method dispatches to the right function for the concrete zipper type.
# =====================================================================

_zpg_path_exists(z::ReadZipperCore) = zipper_path_exists(z)
_zpg_path_exists(z::PrefixZipper) = pz_path_exists(z)
_zpg_path_exists(z::DependentZipper) = dpz_path_exists(z)

_zpg_is_val(z::ReadZipperCore) = zipper_is_val(z)
_zpg_is_val(z::PrefixZipper) = pz_is_val(z)
_zpg_is_val(z::DependentZipper) = dpz_is_val(z)

_zpg_child_count(z::ReadZipperCore) = zipper_child_count(z)
_zpg_child_count(z::PrefixZipper) = pz_child_count(z)
_zpg_child_count(z::DependentZipper) = dpz_child_count(z)

_zpg_child_mask(z::ReadZipperCore) = zipper_child_mask(z)
_zpg_child_mask(z::PrefixZipper) = pz_child_mask(z)
_zpg_child_mask(z::DependentZipper) = dpz_child_mask(z)

_zpg_path(z::ReadZipperCore) = zipper_path(z)
_zpg_path(z::PrefixZipper) = pz_path(z)
_zpg_path(z::DependentZipper) = dpz_path(z)

_zpg_origin_path(z::ReadZipperCore) = z.prefix_buf  # full buffer = origin + relative path
_zpg_origin_path(z::PrefixZipper) = pz_origin_path(z)
_zpg_origin_path(z::DependentZipper) = collect(_zpg_path(z))  # no prefix for DependentZipper

_zpg_root_prefix_len(z::ReadZipperCore) = 0
_zpg_root_prefix_len(z::PrefixZipper) = z.origin_depth
_zpg_root_prefix_len(z::DependentZipper) = 0

_zpg_at_root(z::ReadZipperCore) = zipper_at_root(z)
_zpg_at_root(z::PrefixZipper) = pz_at_root(z)
_zpg_at_root(z::DependentZipper) = dpz_at_root(z)

_zpg_reset!(z::ReadZipperCore) = zipper_reset!(z)
_zpg_reset!(z::PrefixZipper) = pz_reset!(z)
_zpg_reset!(z::DependentZipper) = dpz_reset!(z)

_zpg_descend_to_existing!(z::ReadZipperCore, p) = zipper_descend_to_existing!(z, p)
_zpg_descend_to_existing!(z::PrefixZipper, p) = pz_descend_to_existing!(z, p)
_zpg_descend_to_existing!(z::DependentZipper, p) = dpz_descend_to_existing!(z, p)

_zpg_descend_to!(z::ReadZipperCore, p) = zipper_descend_to!(z, p)
_zpg_descend_to!(z::PrefixZipper, p) = pz_descend_to!(z, p)
_zpg_descend_to!(z::DependentZipper, p) = dpz_descend_to!(z, p)

_zpg_descend_to_byte!(z::ReadZipperCore, b) = zipper_descend_to_byte!(z, b)
_zpg_descend_to_byte!(z::PrefixZipper, b) = pz_descend_to_byte!(z, b)
_zpg_descend_to_byte!(z::DependentZipper, b) = dpz_descend_to_byte!(z, b)

_zpg_descend_first_byte!(z::ReadZipperCore) = zipper_descend_first_byte!(z)
_zpg_descend_first_byte!(z::PrefixZipper) = pz_descend_first_byte!(z)
_zpg_descend_first_byte!(z::DependentZipper) = dpz_descend_first_byte!(z)

_zpg_descend_until!(z::ReadZipperCore) = zipper_descend_until!(z)
_zpg_descend_until!(z::PrefixZipper) = pz_descend_until!(z)
_zpg_descend_until!(z::DependentZipper) = dpz_descend_until!(z)

_zpg_ascend_byte!(z::ReadZipperCore) = zipper_ascend_byte!(z)
_zpg_ascend_byte!(z::PrefixZipper) = pz_ascend_byte!(z)
_zpg_ascend_byte!(z::DependentZipper) = dpz_ascend_byte!(z)

_zpg_ascend!(z::ReadZipperCore, n) = zipper_ascend!(z, n)
_zpg_ascend!(z::PrefixZipper, n) = pz_ascend!(z, n)
_zpg_ascend!(z::DependentZipper, n) = dpz_ascend!(z, n)

_zpg_ascend_until!(z::ReadZipperCore) = zipper_ascend_until!(z)
_zpg_ascend_until!(z::PrefixZipper) = pz_ascend_until!(z)
_zpg_ascend_until!(z::DependentZipper) = dpz_ascend_until!(z)

_zpg_ascend_until_branch!(z::ReadZipperCore) = zipper_ascend_until_branch!(z)
_zpg_ascend_until_branch!(z::PrefixZipper) = pz_ascend_until_branch!(z)
_zpg_ascend_until_branch!(z::DependentZipper) = dpz_ascend_until_branch!(z)

_zpg_to_next_sibling_byte!(z::ReadZipperCore) = zipper_to_next_sibling_byte!(z)
_zpg_to_next_sibling_byte!(z::PrefixZipper) = pz_to_next_sibling_byte!(z)
_zpg_to_next_sibling_byte!(z::DependentZipper) = dpz_to_next_sibling_byte!(z)

_zpg_to_next_val!(z::ReadZipperCore) = zipper_to_next_val!(z)
_zpg_to_next_val!(z::PrefixZipper) = pz_to_next_val!(z)
_zpg_to_next_val!(z::DependentZipper) = dpz_to_next_val!(z)

# NOTE: ACTZipper _zpg_* overloads are defined in pathmap/ArenaCompact.jl
# (after ACTZipper is defined) so they can reference ACTZipper by name.

# =====================================================================
# ProductZipperG struct
# =====================================================================

"""
    ProductZipperG

Generic Cartesian-product zipper.  Primary and secondaries may be any zipper
type.  Mirrors `ProductZipperG<PrimaryZ, SecondaryZ, V>` in product_zipper.rs.

`path()` = `primary.path()` (combined bytes including secondary extension).
`origin_path()` = `primary.origin_path()` (includes prefix bytes if primary
is a PrefixZipper).
`factor_paths` = offsets into `path()` at secondary boundaries.
"""
# PARAMETERIZED 2026-07-23. Was `primary::Any` + `secondary::Vector{Any}` — a Vector{Any} sitting in
# the hot product-DFS descent, so every `prz.primary` / `prz.secondary[idx]` access boxed and
# DYNAMICALLY DISPATCHED the `_zpg_*` zipper operations (path/descend/ascend/child-mask, called per
# byte). Measured cost: ip_sudoku's source-join wedged with 438M allocations. Parameterizing lets the
# compiler SPECIALIZE the descent on the concrete zipper types (ReadZipperCore{V,A} / PrefixZipper{Z} /
# DependentZipper{PZ,SZ} / StaticZipper), union-splitting when one query mixes source kinds. The
# `_zpg_*` helpers already dispatch on those concrete types — this just stops erasing them at the field.
# NOTE: this only bites if the CALLER passes a concretely-typed `secondaries` (not Any[]); MORK
# `space_query_multi_i` was updated to narrow its factors. CLAUDE.md: no Vector{Any} in hot paths.
mutable struct ProductZipperG{P, S}
    factor_paths::Vector{Int}
    primary::P
    secondary::Vector{S}
    total_iters::Int   # CUMULATIVE product-DFS steps across ALL pzg_to_next_val! calls on this zipper.
                       # Fresh per query (space_query_multi_i builds a new zipper each call).
    deadline::Float64  # wall-clock fail-loud: set on the FIRST budget tick to time()+PZG_QUERY_TIME_BUDGET;
                       # a runaway query (naive source-join explosion) errors here. Robust — no threshold
                       # to tune, since a legit query's whole product-DFS finishes in well under a second.
end

ProductZipperG(primary, secondaries) = ProductZipperG(Int[], primary, collect(secondaries), 0, 0.0)

# =====================================================================
# Internal helpers (mirrors ProductZipperG private methods)
# =====================================================================

# 1-based index of active secondary; nothing if in primary.
function _pzg_factor_idx(prz::ProductZipperG, truncate_up::Bool)
    len = length(pzg_path(prz))
    factor = length(prz.factor_paths)
    factor == 0 && return nothing
    while truncate_up && factor >= 1 && prz.factor_paths[factor] == len
        factor -= 1
    end
    factor < 1 ? nothing : factor
end

function _pzg_active(prz::ProductZipperG, truncate_up::Bool)
    idx = _pzg_factor_idx(prz, truncate_up)
    idx !== nothing ? prz.secondary[idx] : prz.primary
end

function _pzg_is_path_end(prz::ProductZipperG)
    idx = _pzg_factor_idx(prz, false)
    z = idx !== nothing ? prz.secondary[idx] : prz.primary
    _zpg_child_count(z) == 0 && _zpg_path_exists(z)
end

function _pzg_exit_factors!(prz::ProductZipperG)
    len = length(pzg_path(prz))
    exited = false
    while !isempty(prz.factor_paths) && prz.factor_paths[end] == len
        pop!(prz.factor_paths)
        exited = true
    end
    exited
end

function _pzg_enter_factors!(prz::ProductZipperG)
    len = length(pzg_path(prz))
    entered = false
    if length(prz.factor_paths) < length(prz.secondary) && _pzg_is_path_end(prz)
        push!(prz.factor_paths, len)
        entered = true
    end
    entered
end

# =====================================================================
# Public interface — mirrors ZipperProduct trait
# =====================================================================

pzg_path(prz::ProductZipperG) = _zpg_path(prz.primary)
pzg_origin_path(prz::ProductZipperG) = _zpg_origin_path(prz.primary)
pzg_root_prefix_len(prz::ProductZipperG) = _zpg_root_prefix_len(prz.primary)

pzg_is_val(prz::ProductZipperG) = _zpg_is_val(_pzg_active(prz, true))
pzg_path_exists(prz::ProductZipperG) = _zpg_path_exists(_pzg_active(prz, true))
pzg_child_count(prz::ProductZipperG) = _zpg_child_count(_pzg_active(prz, false))
pzg_child_mask(prz::ProductZipperG) = _zpg_child_mask(_pzg_active(prz, false))
pzg_at_root(prz::ProductZipperG) = isempty(pzg_path(prz))
pzg_factor_paths(prz::ProductZipperG) = prz.factor_paths

# focus_factor: mirrors ProductZipperG::ZipperProduct impl.
# For single-factor ProductZipperG with DependentZipper primary, also
# account for the DependentZipper's internal factor enrollment.
function pzg_focus_factor(prz::ProductZipperG)
    idx = _pzg_factor_idx(prz, true)
    outer = idx === nothing ? 0 : idx
    # If primary is a PrefixZipper wrapping a DependentZipper, add inner factor depth
    outer + _pzg_inner_factor_depth(prz.primary)
end

# Total factor count including inner DependentZipper factors
function pzg_factor_count(prz::ProductZipperG)
    length(prz.secondary) + 1 + _pzg_inner_factor_count(prz.primary)
end

_pzg_inner_factor_depth(z) = 0
_pzg_inner_factor_count(z) = 0

function _pzg_inner_factor_depth(pz::PrefixZipper)
    src = pz.source
    src isa DependentZipper ? dpz_focus_factor(src) : 0
end

function _pzg_inner_factor_count(pz::PrefixZipper)
    src = pz.source
    src isa DependentZipper ? (dpz_factor_count(src) - 1) : 0
end

function pzg_reset!(prz::ProductZipperG)
    empty!(prz.factor_paths)
    prz.total_iters = 0
    for s in prz.secondary
        ;
        _zpg_reset!(s);
    end
    _zpg_reset!(prz.primary)
end

# =====================================================================
# Navigation — mirrors ZipperMoving for ProductZipperG
# =====================================================================

function pzg_descend_to_existing!(prz::ProductZipperG, path)
    pv = collect(UInt8, path)
    descended = 0
    while !isempty(pv)
        _pzg_budget!(prz)
        _pzg_enter_factors!(prz)
        idx = _pzg_factor_idx(prz, false)
        good = if idx !== nothing
            g = _zpg_descend_to_existing!(prz.secondary[idx], pv)
            g > 0 && _zpg_descend_to!(prz.primary, pv[1:g])
            g
        else
            _zpg_descend_to_existing!(prz.primary, pv)
        end
        good == 0 && break
        descended += good
        pv = pv[(good + 1):end]
    end
    _pzg_enter_factors!(prz)
    descended
end

function pzg_descend_to!(prz::ProductZipperG, path)
    pv = collect(UInt8, path)
    good = pzg_descend_to_existing!(prz, pv)
    good == length(pv) && return nothing
    rest = pv[(good + 1):end]
    idx = _pzg_factor_idx(prz, false)
    if idx !== nothing
        _zpg_descend_to!(prz.secondary[idx], rest)
    end
    _zpg_descend_to!(prz.primary, rest)
end

pzg_descend_to_byte!(prz::ProductZipperG, k::UInt8) = pzg_descend_to!(prz, UInt8[k])

function pzg_descend_first_byte!(prz::ProductZipperG)::Bool
    mask = pzg_child_mask(prz)
    b = indexed_bit(mask, 0, true)
    b === nothing && return false
    pzg_descend_to_byte!(prz, b)
    true
end

function pzg_descend_until!(prz::ProductZipperG)::Bool
    moved = false
    _pzg_enter_factors!(prz)
    while pzg_child_count(prz) == 1
        idx = _pzg_factor_idx(prz, false)
        moved |= if idx !== nothing
            z = prz.secondary[idx]
            before = length(_zpg_path(z))
            rv = _zpg_descend_until!(z)
            after = _zpg_path(z)
            after_len = length(after)
            after_len > before &&
                _zpg_descend_to!(prz.primary, after[(before + 1):after_len])
            rv
        else
            _zpg_descend_until!(prz.primary)
        end
        _pzg_enter_factors!(prz)
        pzg_is_val(prz) && break
    end
    moved
end

function pzg_ascend!(prz::ProductZipperG, steps::Int)::Bool
    remaining = steps
    while remaining > 0
        _pzg_exit_factors!(prz)
        idx = _pzg_factor_idx(prz, false)
        if idx !== nothing
            len = length(pzg_path(prz)) - prz.factor_paths[idx]
            delta = min(len, remaining)
            _zpg_ascend!(prz.secondary[idx], delta)
            _zpg_ascend!(prz.primary, delta)
            remaining -= delta
        else
            return _zpg_ascend!(prz.primary, remaining)
        end
    end
    true
end

pzg_ascend_byte!(prz::ProductZipperG) = pzg_ascend!(prz, 1)

function _pzg_ascend_cond!(prz::ProductZipperG, allow_val::Bool)::Bool
    plen = length(pzg_path(prz))
    while true
        while !isempty(prz.factor_paths) && prz.factor_paths[end] == plen
            pop!(prz.factor_paths)
        end
        idx = _pzg_factor_idx(prz, false)
        if idx !== nothing
            z = prz.secondary[idx]
            before = length(_zpg_path(z))
            rv = allow_val ? _zpg_ascend_until!(z) : _zpg_ascend_until_branch!(z)
            delta = before - length(_zpg_path(z))
            plen -= delta
            _zpg_ascend!(prz.primary, delta)
            if rv && (pzg_child_count(prz) != 1 || (allow_val && pzg_is_val(prz)))
                return true
            end
        else
            return if allow_val
                _zpg_ascend_until!(prz.primary)
            else
                _zpg_ascend_until_branch!(prz.primary)
            end
        end
    end
end

pzg_ascend_until!(prz::ProductZipperG) = _pzg_ascend_cond!(prz, true)
pzg_ascend_until_branch!(prz::ProductZipperG) = _pzg_ascend_cond!(prz, false)

function pzg_to_next_sibling_byte!(prz::ProductZipperG)::Bool
    isempty(pzg_path(prz)) && return false
    cur_byte = last(pzg_path(prz))
    pzg_ascend!(prz, 1) || return false
    mask = pzg_child_mask(prz)
    nb = next_bit(mask, cur_byte)
    if nb !== nothing
        pzg_descend_to_byte!(prz, nb)
        return true
    else
        pzg_descend_to_byte!(prz, cur_byte)
        return false
    end
end

# The naive product DFS has NO coreferential pruning (the coref join was ported only to MORK's
# NON-source query path — see MORK `space_query_multi_i` / [[reference_mork_port_state_and_rule64]]).
# A higher-order self-referential SOURCE pattern (e.g. ip_sudoku's priority-decrement meta-exec) makes
# the product DFS enumerate an EXPLODING cross-product. The budget below now FAILS LOUD, and it is
# CUMULATIVE over the whole query (prz.total_iters), NOT per-call: the old per-call cap (200k) never
# fired here because each next-value advance stayed just under it while the query performed MILLIONS of
# advances. The old behavior was worse still — a `@warn maxlog=1` + SILENT `return false` that truncated
# the join mid-enumeration, surfacing as wrong results or a program-level non-termination (each capped
# advance returns an incomplete match → the exec respawns → repeat). A silent cap that changes the
# ANSWER is exactly the hazard this session set out to kill: a hang or wrong result that reads as
# "working". A well-behaved query over Rule-of-64-scale data does far fewer than this many total DFS
# steps; raise `PZG_QUERY_ITER_CAP[]` for a legitimately huge join (and file the coref-source port).
const PZG_QUERY_ITER_CAP = Ref(100_000_000)

# One unit of product-DFS work — ticked from BOTH the outer next-value loop AND the inner descend loop,
# because the explosion spins inside the descend sub-operations (pzg_descend_to_existing!), not the
# outer advance. Fails loud when the cumulative budget is blown (see the block comment above).
const PZG_QUERY_TIME_BUDGET = Ref(30.0)   # seconds — a single query's product-DFS may not exceed this
const PZG_PEAK_ITERS = Ref(0)             # diagnostic: high-water mark of per-query DFS steps (any query)
@inline function _pzg_budget!(prz::ProductZipperG)
    prz.total_iters += 1
    prz.total_iters > PZG_PEAK_ITERS[] && (PZG_PEAK_ITERS[] = prz.total_iters)
    if prz.total_iters == 1
        prz.deadline = time() + PZG_QUERY_TIME_BUDGET[]        # arm the wall-clock on the first step
    elseif prz.total_iters & 0xffff == 0 && time() > prz.deadline
        error("ProductZipperG product-DFS exceeded the $(PZG_QUERY_TIME_BUDGET[])s per-query wall-clock \
               budget — a naive product/source join is EXPLODING (no coreferential pruning on this path). \
               This was previously a SILENT `return false` that truncated the join and returned a \
               wrong/partial answer — a hang/wrong-result that reads as 'working'. Port the coreferential \
               join to the source path, fix the pattern, or raise `PathMap.PZG_QUERY_TIME_BUDGET[]`. See \
               reference_mork_port_state_and_rule64.")
    end
    if prz.total_iters > PZG_QUERY_ITER_CAP[]                  # backstop for a fast (non-slow) explosion
        error("ProductZipperG product-DFS exceeded $(PZG_QUERY_ITER_CAP[]) CUMULATIVE steps for one query \
               — naive product/source join explosion; see the wall-clock message / \
               reference_mork_port_state_and_rule64.")
    end
    nothing
end

# ZipperIteration default impl
function pzg_to_next_val!(prz::ProductZipperG)::Bool
    while true
        _pzg_budget!(prz)
        if pzg_descend_first_byte!(prz)
            pzg_is_val(prz) && return true
            pzg_descend_until!(prz) && pzg_is_val(prz) && return true
        else
            ascending = true
            while ascending
                if pzg_to_next_sibling_byte!(prz)
                    pzg_is_val(prz) && return true
                    ascending = false
                else
                    pzg_ascend_byte!(prz) || return false
                    pzg_at_root(prz) && return false
                end
            end
        end
    end
end

# =====================================================================
# Exports
# =====================================================================

export ProductZipperG
export pzg_path, pzg_origin_path, pzg_root_prefix_len
export pzg_is_val, pzg_path_exists, pzg_child_count, pzg_child_mask
export pzg_at_root, pzg_factor_count, pzg_focus_factor, pzg_factor_paths
export pzg_reset!, pzg_descend_to_byte!, pzg_descend_first_byte!
export pzg_descend_until!, pzg_ascend_byte!, pzg_ascend_until!
export pzg_to_next_sibling_byte!, pzg_to_next_val!
