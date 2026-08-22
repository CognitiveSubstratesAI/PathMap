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

# `val` was missing from this dispatch table until 2026-08-03 — `_zpg_is_val` was here but nothing
# read the VALUE, so `pzg_val` could not exist. Found by porting upstream's own zipper conformance
# battery, which could not run against the composition without it (upstream ProductZipperG has
# `val`, product_zipper.rs:558-564).
_zpg_val(z::ReadZipperCore) = zipper_val(z)
_zpg_val(z::PrefixZipper) = pz_val(z)
_zpg_val(z::DependentZipper) = dpz_val(z)

_zpg_val_at(z::ReadZipperCore, path::AbstractVector{UInt8}) = zipper_val_at(z, path)
_zpg_val_at(z::PrefixZipper, path::AbstractVector{UInt8}) = pz_val_at(z, path)
_zpg_val_at(z::DependentZipper, path::AbstractVector{UInt8}) = dpz_val_at(z, path)

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

ProductZipperG(primary, secondaries) =
    ProductZipperG(Int[], primary, collect(secondaries), 0, 0.0)

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

        _zpg_reset!(s)
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

# ── the sibling pair. Upstream is `to_next_sibling_byte() = to_sibling_byte(true)` and
# `to_prev_sibling_byte() = to_sibling_byte(false)` (product_zipper.rs:752-758) — one helper with a
# direction flag. Ours had only the forward one until 2026-08-03, so `to_prev_sibling_byte` was
# ABSENT on the composition while present on the base zipper.
function _pzg_to_sibling_byte!(prz::ProductZipperG, forward::Bool)::Bool
    isempty(pzg_path(prz)) && return false
    cur_byte = last(pzg_path(prz))
    pzg_ascend!(prz, 1) || return false
    mask = pzg_child_mask(prz)
    nb = forward ? next_bit(mask, cur_byte) : prev_bit(mask, cur_byte)
    if nb !== nothing
        pzg_descend_to_byte!(prz, nb)
        return true
    else
        pzg_descend_to_byte!(prz, cur_byte)   # no sibling that way: restore the focus
        return false
    end
end

pzg_to_next_sibling_byte!(prz::ProductZipperG)::Bool = _pzg_to_sibling_byte!(prz, true)
pzg_to_prev_sibling_byte!(prz::ProductZipperG)::Bool = _pzg_to_sibling_byte!(prz, false)

# ── descend_indexed_byte. Upstream product_zipper.rs:716-722:
#     let mask = self.child_mask();
#     let Some(byte) = mask.indexed_bit::<true>(child_idx) else { return false };
#     self.descend_to_byte(byte); true
# `pzg_descend_first_byte!` above is already this with child_idx = 0 (upstream defines it exactly so,
# product_zipper.rs:724-727), so the two now share one body rather than drifting apart.
function pzg_descend_indexed_byte!(prz::ProductZipperG, child_idx::Int)::Bool
    mask = pzg_child_mask(prz)
    b = indexed_bit(mask, child_idx, true)
    b === nothing && return false
    pzg_descend_to_byte!(prz, b)
    true
end

# ── val. Upstream product_zipper.rs:558-564 dispatches on the FOCUS factor, truncating up:
#     if let Some(idx) = self.factor_idx(true) { self.secondary[idx].val() } else { self.primary.val() }
function pzg_val(prz::ProductZipperG)
    idx = _pzg_factor_idx(prz, true)
    idx === nothing ? _zpg_val(prz.primary) : _zpg_val(prz.secondary[idx])
end

# ── val_at. Upstream product_zipper.rs:565-571 — the SAME focus-factor dispatch as `val`:
#     if let Some(idx) = self.factor_idx(true) { self.secondary[idx].val_at(path) } else { self.primary.val_at(path) }
function pzg_val_at(prz::ProductZipperG, path::AbstractVector{UInt8})
    idx = _pzg_factor_idx(prz, true)
    idx === nothing ? _zpg_val_at(prz.primary, path) : _zpg_val_at(prz.secondary[idx], path)
end

# ── to_next_step and descend_until_max_bytes are TRAIT DEFAULTS upstream (ZipperMoving,
# zipper.rs:426-440 and :326-337), so upstream's ProductZipperG inherits them for free and its
# forwarding macro passes them straight through (zipper.rs:849). We have no trait system, so they
# were simply absent on the composition. Ported from the default bodies verbatim.
function pzg_to_next_step!(prz::ProductZipperG)::Bool
    if pzg_child_count(prz) == 0
        # at a leaf: ascend until moving to a sibling succeeds
        while !pzg_to_next_sibling_byte!(prz)
            pzg_ascend_byte!(prz) || return false
        end
    else
        return pzg_descend_first_byte!(prz)
    end
    true
end

function pzg_descend_until_max_bytes!(prz::ProductZipperG, max_bytes::Int)::Bool
    max_bytes == 0 && return false
    target_len = length(pzg_path(prz)) + max_bytes
    descended = pzg_descend_until!(prz)
    cur_len = length(pzg_path(prz))
    cur_len > target_len && pzg_ascend!(prz, cur_len - target_len)
    descended
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
        error(
            "ProductZipperG product-DFS exceeded the $(PZG_QUERY_TIME_BUDGET[])s per-query wall-clock \
               budget — a naive product/source join is EXPLODING (no coreferential pruning on this path). \
               This was previously a SILENT `return false` that truncated the join and returned a \
               wrong/partial answer — a hang/wrong-result that reads as 'working'. Port the coreferential \
               join to the source path, fix the pattern, or raise `PathMaps.PZG_QUERY_TIME_BUDGET[]`. See \
               reference_mork_port_state_and_rule64."
        )
    end
    if prz.total_iters > PZG_QUERY_ITER_CAP[]                  # backstop for a fast (non-slow) explosion
        error(
            "ProductZipperG product-DFS exceeded $(PZG_QUERY_ITER_CAP[]) CUMULATIVE steps for one query \
               — naive product/source join explosion; see the wall-clock message / \
               reference_mork_port_state_and_rule64."
        )
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
# Additional navigation for the coreferential DFS (the coref-source-join port, 2026-07-23).
# Upstream defines these as ZipperMoving TRAIT DEFAULTS (pathmap/src/zipper.rs: descend_to_check :180,
# descend_to_existing_byte :245, descend_first_k_path :660, to_next_k_path :675) — generic over the
# basic moving interface, which is exactly why upstream's `coreferential_transition` runs over
# ProductZipperG for free. Julia has no trait defaults, so our port hand-writes them per type; this is
# the ProductZipperG set, a mechanical mirror of ProductZipper's (ProductZipper.jl:322-392), all
# generic over ProductZipperG's basic ops (pzg_descend_first_byte!/to_next_sibling!/ascend_byte!/
# descend_to_existing!/path) — which already dispatch through the source zippers (ReadZipperCore/
# DependentZipper/PrefixZipper/ACTZipper). Routing space_query_multi_i through `_coreferential_transition!`
# then gives the SOURCE path the same coreferential PRUNING the non-source path has — killing the naive
# cross-product explosion (ip_sudoku) at the algorithm. The wall-clock budget still ticks underneath
# (via pzg_descend_to_existing!), so a bug that re-explodes is caught loud, not wedged.
# =====================================================================

# single-byte existing descend: true iff the byte existed and was descended.
pzg_descend_to_existing_byte!(prz::ProductZipperG, b::UInt8)::Bool =
    pzg_descend_to_existing!(prz, UInt8[b]) == 1

# descend `bytes` iff the exact path exists; on failure ascend back to restore the prior position.
function pzg_descend_to_check!(prz::ProductZipperG, bytes)::Bool
    bv = bytes isa AbstractVector{UInt8} ? bytes : collect(UInt8, bytes)
    isempty(bv) && return true
    n = pzg_descend_to_existing!(prz, bv)
    n == length(bv) && return true
    n > 0 && pzg_ascend!(prz, n)
    false
end

# descend to the first path exactly `k` bytes below the current focus.
pzg_descend_first_k_path!(prz::ProductZipperG, k::Int)::Bool =
    _pzg_k_path_internal!(prz, k, length(pzg_path(prz)))

# move to the next path at the same depth (k bytes from the common base).
pzg_to_next_k_path!(prz::ProductZipperG, k::Int)::Bool =
    _pzg_k_path_internal!(prz, k, length(pzg_path(prz)) - k)

function _pzg_k_path_internal!(prz::ProductZipperG, k::Int, base_idx::Int)::Bool
    # Direct port of _pz_k_path_internal! (ProductZipper.jl:374) using pzg_* methods.
    while true
        if length(pzg_path(prz)) < base_idx + k
            while pzg_descend_first_byte!(prz)
                length(pzg_path(prz)) == base_idx + k && return true
            end
        end
        if pzg_to_next_sibling_byte!(prz)
            length(pzg_path(prz)) == base_idx + k && return true
            continue
        end
        while length(pzg_path(prz)) > base_idx
            pzg_ascend_byte!(prz)
            length(pzg_path(prz)) == base_idx && return false
            pzg_to_next_sibling_byte!(prz) && break
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
export pzg_descend_until!, pzg_ascend_byte!, pzg_ascend!, pzg_ascend_until!
export pzg_to_next_sibling_byte!, pzg_to_next_val!
export pzg_descend_to_existing_byte!, pzg_descend_to_check!
export pzg_descend_first_k_path!, pzg_to_next_k_path!
# added 2026-08-03: five ops upstream's ProductZipperG has and ours did not — found by porting
# upstream's own zipper conformance battery, which could not run against the composition without them.
export pzg_to_prev_sibling_byte!, pzg_descend_indexed_byte!, pzg_val, pzg_val_at

# ── ProductZipperG under the generic `zipper_*` names ────────────────────────────────────────────
# Upstream reaches ProductZipperG through the SAME traits as every other zipper (ZipperMoving,
# Zipper, ZipperIteration), so calling code is type-generic. Ours had only the `pzg_*` names, which
# meant any generic caller — notably upstream's conformance battery — could not touch it.
#
# These live in the package deliberately. Defining them in a test file extends PathMap's generics
# from Main, which INVALIDATES the precompiled package: measured 1.6s -> 49.3s on one battery run
# and a >20min suite. Here they compile once with everything else.
zipper_descend_to!(z::ProductZipperG, k) = pzg_descend_to!(z, k)
zipper_descend_to_byte!(z::ProductZipperG, b) = pzg_descend_to_byte!(z, b)
zipper_descend_to_existing!(z::ProductZipperG, k) = pzg_descend_to_existing!(z, k)
zipper_descend_first_byte!(z::ProductZipperG) = pzg_descend_first_byte!(z)
zipper_descend_indexed_byte!(z::ProductZipperG, i) = pzg_descend_indexed_byte!(z, i)
zipper_descend_until!(z::ProductZipperG) = pzg_descend_until!(z)
zipper_descend_until_max_bytes!(z::ProductZipperG, n) = pzg_descend_until_max_bytes!(z, n)
zipper_ascend!(z::ProductZipperG, n) = pzg_ascend!(z, n)
zipper_ascend_byte!(z::ProductZipperG) = pzg_ascend_byte!(z)
zipper_ascend_until!(z::ProductZipperG) = pzg_ascend_until!(z)
zipper_ascend_until_branch!(z::ProductZipperG) = pzg_ascend_until_branch!(z)
zipper_to_next_sibling_byte!(z::ProductZipperG) = pzg_to_next_sibling_byte!(z)
zipper_to_prev_sibling_byte!(z::ProductZipperG) = pzg_to_prev_sibling_byte!(z)
zipper_to_next_val!(z::ProductZipperG) = pzg_to_next_val!(z)
zipper_to_next_step!(z::ProductZipperG) = pzg_to_next_step!(z)
zipper_reset!(z::ProductZipperG) = pzg_reset!(z)
zipper_path(z::ProductZipperG) = pzg_path(z)
zipper_path_exists(z::ProductZipperG) = pzg_path_exists(z)
zipper_child_mask(z::ProductZipperG) = pzg_child_mask(z)
zipper_child_count(z::ProductZipperG) = pzg_child_count(z)
zipper_is_val(z::ProductZipperG) = pzg_is_val(z)
zipper_val(z::ProductZipperG) = pzg_val(z)
zipper_val_at(z::ProductZipperG, p::AbstractVector{UInt8}) = pzg_val_at(z, p)
zipper_at_root(z::ProductZipperG) = pzg_at_root(z)

export pzg_to_next_step!, pzg_descend_until_max_bytes!
