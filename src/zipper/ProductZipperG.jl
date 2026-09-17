"""
ProductZipperG — 1:1 port of `pathmap/src/product_zipper.rs` `ProductZipperG`
(upstream 0.4.0 @ f477a91, product_zipper.rs:380-832 plus the `ZipperProduct` impl at :879-891).

Generic Cartesian-product zipper over N factors: the primary trie's paths are extended with the root
of the next secondary trie, recursively.  Unlike `ProductZipper`, it never inspects the inner
workings of its factors — primary and secondaries are any `AbstractZipper`, so the whole descent is
written against the generic zipper functions in ZipperTraits.jl (upstream: the `ZipperMoving +
Zipper + ZipperIteration` trait bounds).

Used by MORK's `space_query_multi_i` when pattern factors include non-BTM sources.

Upstream's trait impls become methods of those generic functions: `Zipper` (product_zipper.rs:640-674),
`ZipperMoving` (:676-805), `ZipperPath` (:807-817), `ZipperValues`/`ZipperValuesAt` (:563-593),
`ZipperReadOnlyValues` (:595-616), `ZipperAbsolutePath` (:517-526), `ZipperConcrete` (:528-549),
`ZipperProduct` (:879-891).  `ZipperIteration` is an empty impl (:819-825) — "use the default impl for
all methods" — so we add no iteration methods and inherit the `AbstractZipper` defaults
(`to_next_val!`, `descend_first_k_path!`, `to_next_k_path!`, `descend_last_path!`, `_observed` forms).
Likewise every `ZipperMoving` default upstream does not override (`descend_to_byte!`,
`descend_to_check!`, `descend_to_existing_byte!`, `descend_indexed_byte!`, `descend_first_byte!`,
`descend_until!`, `descend_until_max_bytes!`, `ascend_byte!`, `to_next_sibling_byte!`,
`to_prev_sibling_byte!`, `to_next_step!`) is inherited: upstream's own bodies for the handful it does
spell out (`descend_indexed_byte` :739, `descend_first_byte` :746, `to_sibling_byte` :499) are
byte-identical to the trait defaults in ZipperTraits.jl, so a per-type copy would only drift.
"""

# =====================================================================
# ProductZipperG struct
# =====================================================================

# PARAMETERIZED 2026-07-23. Was `primary::Any` + `secondary::Vector{Any}` — a Vector{Any} sitting in
# the hot product-DFS descent, so every `prz.primary` / `prz.secondary[idx]` access boxed and
# DYNAMICALLY DISPATCHED the zipper operations (path/descend/ascend/child-mask, called per byte).
# Measured cost: ip_sudoku's source-join wedged with 438M allocations. Parameterizing lets the
# compiler SPECIALIZE the descent on the concrete zipper types (ReadZipperCore{V,A} / PrefixZipper{Z} /
# DependentZipper{...} / ACTZipper), union-splitting when one query mixes source kinds.
# NOTE: this only bites if the CALLER passes a concretely-typed `secondaries` (not Any[]); MORK
# `space_query_multi_i` was updated to narrow its factors. CLAUDE.md: no Vector{Any} in hot paths.
"""
    ProductZipperG{P, S}

Generic Cartesian-product zipper (product_zipper.rs:389-397).  Primary and secondaries may be any
zipper type.

`path(prz)` = `path(primary)` (the combined bytes, including the secondary extensions);
`origin_path(prz)` = `origin_path(primary)` (so it includes the prefix bytes when the primary is a
`PrefixZipper`); `path_indices(prz)` = the offsets into `path` at the factor boundaries.
"""
mutable struct ProductZipperG{P, S} <: AbstractZipper
    factor_paths::Vector{Int}
    primary::P
    secondary::Vector{S}
    total_iters::Int   # CUMULATIVE product-DFS steps across ALL descents on this zipper.
    # Fresh per query (space_query_multi_i builds a new zipper each call).
    deadline::Float64  # wall-clock fail-loud: set on the FIRST budget tick to time()+PZG_QUERY_TIME_BUDGET;
    # a runaway query (naive source-join explosion) errors here. Robust — no threshold
    # to tune, since a legit query's whole product-DFS finishes in well under a second.
end

ProductZipperG(primary, secondaries) =
    ProductZipperG(Int[], primary, collect(secondaries), 0, 0.0)

# =====================================================================
# Internal helpers — upstream's private methods (product_zipper.rs:420-514)
# =====================================================================

# `factor_idx` (product_zipper.rs:422-429). 1-based here; upstream's 0-based `checked_sub` chain
# becomes the `factor < 1 → nothing` test.
function _pzg_factor_idx(prz::ProductZipperG, truncate_up::Bool)
    len = depth(prz)
    factor = length(prz.factor_paths)
    factor == 0 && return nothing
    while truncate_up && factor >= 1 && prz.factor_paths[factor] == len
        factor -= 1
    end
    factor < 1 ? nothing : factor
end

# `is_path_end` (product_zipper.rs:433-439)
function _pzg_is_path_end(prz::ProductZipperG)
    idx = _pzg_factor_idx(prz, false)
    z = idx !== nothing ? prz.secondary[idx] : prz.primary
    child_count(z) == 0 && path_exists(z)
end

# `exit_factors` (product_zipper.rs:442-450)
function _pzg_exit_factors!(prz::ProductZipperG)
    len = depth(prz)
    exited = false
    while !isempty(prz.factor_paths) && prz.factor_paths[end] == len
        pop!(prz.factor_paths)
        exited = true
    end
    exited
end

# `enter_factors` (product_zipper.rs:453-462)
function _pzg_enter_factors!(prz::ProductZipperG)
    len = depth(prz)
    entered = false
    if length(prz.factor_paths) < length(prz.secondary) && _pzg_is_path_end(prz)
        push!(prz.factor_paths, len)
        entered = true
    end
    entered
end

# `ascend_cond` (product_zipper.rs:466-496): `ascend_until` when `allow_stop_on_val`, else
# `ascend_until_branch`. Returns the bytes ascended.
function _pzg_ascend_cond!(prz::ProductZipperG, allow_stop_on_val::Bool)::Int
    plen = depth(prz)
    ascended = 0
    while true
        while !isempty(prz.factor_paths) && prz.factor_paths[end] == plen
            pop!(prz.factor_paths)
        end
        idx = _pzg_factor_idx(prz, false)
        if idx !== nothing
            z = prz.secondary[idx]
            # the inner zipper reports how far it moved, so the primary can be brought along without
            # measuring its path before and after
            delta = allow_stop_on_val ? ascend_until!(z) : ascend_until_branch!(z)
            plen -= delta
            ascend!(prz.primary, delta)
            ascended += delta
            if delta > 0 && (child_count(prz) != 1 || (allow_stop_on_val && is_val(prz)))
                return ascended
            end
        else
            return ascended +
                   (allow_stop_on_val ? ascend_until!(prz.primary) : ascend_until_branch!(prz.primary))
        end
    end
end

# =====================================================================
# Zipper (product_zipper.rs:640-674) — the focus factor answers
# =====================================================================

function path_exists(prz::ProductZipperG)
    idx = _pzg_factor_idx(prz, true)
    idx !== nothing ? path_exists(prz.secondary[idx]) : path_exists(prz.primary)
end

function is_val(prz::ProductZipperG)
    idx = _pzg_factor_idx(prz, true)
    idx !== nothing ? is_val(prz.secondary[idx]) : is_val(prz.primary)
end

function child_count(prz::ProductZipperG)
    idx = _pzg_factor_idx(prz, false)
    idx !== nothing ? child_count(prz.secondary[idx]) : child_count(prz.primary)
end

function child_mask(prz::ProductZipperG)
    idx = _pzg_factor_idx(prz, false)
    idx !== nothing ? child_mask(prz.secondary[idx]) : child_mask(prz.primary)
end

# =====================================================================
# ZipperValues / ZipperValuesAt / ZipperReadOnlyValues (product_zipper.rs:563-616)
# =====================================================================

# `val` dispatches on the FOCUS factor, truncating up (product_zipper.rs:570-576).
# It was missing entirely until 2026-08-03 — nothing read the VALUE off the composition. Found by
# porting upstream's own zipper conformance battery, which could not run against it without one.
function val(prz::ProductZipperG)
    idx = _pzg_factor_idx(prz, true)
    idx !== nothing ? val(prz.secondary[idx]) : val(prz.primary)
end

# `val_at` — product_zipper.rs:586-592, the SAME focus-factor dispatch as `val`.
function val_at(prz::ProductZipperG, p::AbstractVector{UInt8})
    idx = _pzg_factor_idx(prz, true)
    idx !== nothing ? val_at(prz.secondary[idx], p) : val_at(prz.primary, p)
end

function get_val(prz::ProductZipperG)                       # :602-608
    idx = _pzg_factor_idx(prz, true)
    idx !== nothing ? get_val(prz.secondary[idx]) : get_val(prz.primary)
end

function get_val_at(prz::ProductZipperG, p::AbstractVector{UInt8})   # :609-615
    idx = _pzg_factor_idx(prz, true)
    idx !== nothing ? get_val_at(prz.secondary[idx], p) : get_val_at(prz.primary, p)
end

# =====================================================================
# ZipperAbsolutePath / ZipperPath / ZipperConcrete (product_zipper.rs:517-549, 807-817)
# =====================================================================

path(prz::ProductZipperG) = path(prz.primary)                         # :814
origin_path(prz::ProductZipperG) = origin_path(prz.primary)           # :524
root_prefix_path(prz::ProductZipperG) = root_prefix_path(prz.primary) # :525

function shared_node_id(prz::ProductZipperG)                          # :535-541
    idx = _pzg_factor_idx(prz, true)
    idx !== nothing ? shared_node_id(prz.secondary[idx]) : shared_node_id(prz.primary)
end

function is_shared(prz::ProductZipperG)                               # :542-548
    idx = _pzg_factor_idx(prz, true)
    idx !== nothing ? is_shared(prz.secondary[idx]) : is_shared(prz.primary)
end

# =====================================================================
# ZipperMoving (product_zipper.rs:676-805)
# =====================================================================

depth(prz::ProductZipperG) = depth(prz.primary)            # :683
focus_byte(prz::ProductZipperG) = focus_byte(prz.primary)  # :687

function reset!(prz::ProductZipperG)                       # :690-696
    empty!(prz.factor_paths)
    prz.total_iters = 0        # ADAPTATION: re-arm the per-query DFS budget (see `_pzg_budget!`)
    for s in prz.secondary
        reset!(s)
    end
    reset!(prz.primary)
    nothing
end

# :698-700 — `unimplemented!("method will probably get removed")`
val_count(::ProductZipperG) =
    error("val_count is unimplemented for ProductZipperG (product_zipper.rs:698)")

function descend_to_existing!(prz::ProductZipperG, k)      # :701-721
    kv = k isa AbstractVector{UInt8} ? k : collect(UInt8, k)
    n = length(kv)
    off = 0
    descended = 0
    while off < n
        _pzg_budget!(prz)
        _pzg_enter_factors!(prz)
        rest = view(kv, (off + 1):n)
        idx = _pzg_factor_idx(prz, false)
        good = if idx !== nothing
            g = descend_to_existing!(prz.secondary[idx], rest)
            # the primary carries the WHOLE product path, so it follows the secondary byte for byte
            descend_to!(prz.primary, view(rest, 1:g))
            g
        else
            descend_to_existing!(prz.primary, rest)
        end
        good == 0 && break
        descended += good
        off += good
    end
    _pzg_enter_factors!(prz)
    descended
end

function descend_to!(prz::ProductZipperG, k)               # :722-734
    kv = k isa AbstractVector{UInt8} ? k : collect(UInt8, k)
    good = descend_to_existing!(prz, kv)
    good == length(kv) && return nothing
    rest = view(kv, (good + 1):length(kv))
    idx = _pzg_factor_idx(prz, false)
    idx !== nothing && descend_to!(prz.secondary[idx], rest)
    descend_to!(prz.primary, rest)
    nothing
end

function descend_until_observed!(prz::ProductZipperG, obs)  # :749-768
    moved = false
    _pzg_enter_factors!(prz)
    while child_count(prz) == 1
        idx = _pzg_factor_idx(prz, false)
        moved |= if idx !== nothing
            # The primary carries the whole product path, so it has to follow whatever the secondary
            # descends. Mirroring the movement keeps it in step without buffering the bytes.
            descend_until_observed!(prz.secondary[idx], (MirrorPathObserver(prz.primary), obs))
        else
            descend_until_observed!(prz.primary, obs)
        end
        _pzg_enter_factors!(prz)
        is_val(prz) && break
    end
    moved
end

function ascend!(prz::ProductZipperG, steps::Int)::Int      # :777-792
    remaining = steps
    while remaining > 0
        _pzg_exit_factors!(prz)
        idx = _pzg_factor_idx(prz, false)
        if idx !== nothing
            len = depth(prz) - prz.factor_paths[idx]
            delta = min(len, remaining)
            ascend!(prz.secondary[idx], delta)
            ascend!(prz.primary, delta)
            remaining -= delta
        else
            return (steps - remaining) + ascend!(prz.primary, remaining)
        end
    end
    steps
end

ascend_until!(prz::ProductZipperG) = _pzg_ascend_cond!(prz, true)          # :798
ascend_until_branch!(prz::ProductZipperG) = _pzg_ascend_cond!(prz, false)  # :802

# =====================================================================
# ZipperProduct (product_zipper.rs:879-891)
# =====================================================================

"""
`focus_factor(prz)` — index of the factor holding the focus, 0 for the primary
(product_zipper.rs:882).

ADAPTATION: upstream is exactly `factor_idx(true).map_or(0, |x| x + 1)`. Ours additionally accounts
for a `DependentZipper` nested inside the primary, whose factors are enrolled at run time and are
invisible to this zipper's own `factor_paths` (MORK builds `PrefixZipper(prefix, DependentZipper(..))`
as the primary, Sources.jl:248-250). The single oracle for this pair is
test/test_pzg_factor_count_guard.jl; MORK guards on `focus_factor(prz) != factor_count(prz) - 1`
(Space.jl:919), so the two must move together.
"""
function focus_factor(prz::ProductZipperG)
    idx = _pzg_factor_idx(prz, true)
    outer = idx === nothing ? 0 : idx   # 1-based idx == upstream's 0-based `x + 1`
    outer + _pzg_inner_factor_depth(prz.primary)
end

"""
`factor_count(prz)` — the number of factors, counting the primary (product_zipper.rs:885).

ADAPTATION: the `+ _pzg_inner_factor_count` term, for the same nested-`DependentZipper` reason as
`focus_factor` above. Unlike upstream's static count, this GROWS as the inner zipper enrolls factors.
"""
factor_count(prz::ProductZipperG) =
    length(prz.secondary) + 1 + _pzg_inner_factor_count(prz.primary)

"""
`path_indices(prz)` — the end-points, as offsets into `path(prz)`, of each completed factor's portion
of the path (product_zipper.rs:888). Its length is upstream's `focus_factor`.
"""
path_indices(prz::ProductZipperG) = prz.factor_paths

# The nested-factor accounting behind the two ADAPTATIONS above. No upstream counterpart, hence the
# `_`-prefixed internal names. Only a PrefixZipper-wrapped DependentZipper contributes.
_pzg_inner_factor_depth(_) = 0
_pzg_inner_factor_count(_) = 0

function _pzg_inner_factor_depth(pz::PrefixZipper)
    src = pz.source
    src isa DependentZipper ? focus_factor(src) : 0
end

function _pzg_inner_factor_count(pz::PrefixZipper)
    src = pz.source
    src isa DependentZipper ? (factor_count(src) - 1) : 0
end

# =====================================================================
# Product-DFS budget (no upstream counterpart — fail-loud guard)
# =====================================================================

# The naive product DFS has NO coreferential pruning (the coref join was ported only to MORK's
# NON-source query path — see MORK `space_query_multi_i` / [[reference_mork_port_state_and_rule64]]).
# A higher-order self-referential SOURCE pattern (e.g. ip_sudoku's priority-decrement meta-exec) makes
# the product DFS enumerate an EXPLODING cross-product. The budget below FAILS LOUD, and it is
# CUMULATIVE over the whole query (prz.total_iters), NOT per-call: the old per-call cap (200k) never
# fired because each next-value advance stayed just under it while the query performed MILLIONS of
# advances. The old behavior was worse still — a `@warn maxlog=1` + SILENT `return false` that
# truncated the join mid-enumeration, surfacing as wrong results or a program-level non-termination
# (each capped advance returns an incomplete match → the exec respawns → repeat). A silent cap that
# changes the ANSWER is exactly that hazard: a hang or wrong result that reads as "working".
# A well-behaved query over Rule-of-64-scale data does far fewer than this many total DFS steps;
# raise `PZG_QUERY_ITER_CAP[]` for a legitimately huge join (and file the coref-source port).
const PZG_QUERY_ITER_CAP = Ref(100_000_000)

# One unit of product-DFS work — ticked from `descend_to_existing!`, through which EVERY product-DFS
# descent passes (`descend_to!` / `descend_to_byte!` / `descend_first_byte!` / the sibling moves all
# route through it), because the explosion spins inside the descend sub-operations rather than the
# outer next-value advance. Fails loud when the cumulative budget is blown (see the block comment).
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

# =====================================================================
# Coreferential-DFS helper with NO upstream counterpart
# =====================================================================

# `descend_to_check!` that RESTORES the focus when the path does not exist. The upstream
# `ZipperMoving::descend_to_check` default (zipper.rs:180, ported in ZipperTraits.jl) descends first
# and LEAVES the focus off the trie, which is fine for upstream's `coreferential_transition` because
# it ascends explicitly; MORK's `_coref_descend_check!` (Space.jl:1313, 1367) instead relies on the
# restoring behaviour our coref-source port was written against. Kept as an internal — it is our
# semantics, not upstream's — so that nothing reaches for it thinking it is the trait method.
function _pzg_descend_to_check_restoring!(prz::ProductZipperG, bytes)::Bool
    bv = bytes isa AbstractVector{UInt8} ? bytes : collect(UInt8, bytes)
    isempty(bv) && return true
    n = descend_to_existing!(prz, bv)
    n == length(bv) && return true
    n > 0 && ascend!(prz, n)
    false
end

# =====================================================================
# Exports — trait functions are exported from ZipperTraits.jl
# =====================================================================

export ProductZipperG
# `factor_count` / `focus_factor` / `path_indices` (upstream's ZipperProduct, non-trait) are
# declared and exported by ProductZipper.jl:363-367,384 — this file only adds methods for them.
