"""
DependentZipper — port of `pathmap/src/dependent_zipper.rs` `DependentProductZipperG`
(upstream 0.4.0 @ f477a91).

Like `ProductZipperG`, but the secondary factors are computed on the fly by an `enroll` callback that
receives the path traversed so far and decides whether to graft a new secondary zipper
(dependent_zipper.rs:20-51).  The type name stays `DependentZipper` (a rename is out of scope).

Julia translation notes:
  - Rust `for<'a> FnOnce(C, &'a [u8], usize) -> (C, Option<SecondaryZ>)` → any callable `F`; the `C`
    payload is threaded through the mutable `enroll_payload` field exactly as upstream's `Option<C>`.
  - Upstream's trait impls are methods of the generic functions in ZipperTraits.jl: `Zipper`
    (dependent_zipper.rs:304-338), `ZipperMoving` (:340-466), `ZipperPath` (:468-478),
    `ZipperValues`/`ZipperValuesAt` (:227-257), `ZipperReadOnlyValues` (:259-280),
    `ZipperAbsolutePath` (:181-190), `ZipperConcrete` (:192-213).
  - `ZipperIteration` is an empty impl upstream (:480-487) — "use the default impl for all methods" —
    so we add NO iteration methods and inherit the `AbstractZipper` defaults (`to_next_val!`,
    `descend_first_k_path!`, `to_next_k_path!`, `descend_last_path!`, and their `_observed` forms).
  - Everything upstream leaves to a `ZipperMoving` default (`descend_to_byte!`,
    `descend_to_check!`, `descend_to_existing_byte!`, `descend_indexed_byte!`, `descend_first_byte!`,
    `descend_until!`, `descend_until_max_bytes!`, `ascend_byte!`, `to_next_sibling_byte!`,
    `to_prev_sibling_byte!`, `to_next_step!`) is likewise inherited — upstream's own bodies for those
    are byte-identical to the trait defaults in ZipperTraits.jl.
"""

# =====================================================================
# DependentZipper struct
# =====================================================================

"""
    DependentZipper{PZ, SZ, C, F}

Cartesian-product zipper whose secondary factors are computed dynamically.
Mirrors `DependentProductZipperG<'trie, PrimaryZ, SecondaryZ, V, C, F>` (dependent_zipper.rs:20-30).

`PZ`/`SZ` are the primary and secondary zipper types, `C` the enroll payload type (upstream's
`Option<C>`), `F` the enroll callable.  Parameterising `C`/`F` and the secondary element type keeps
the hot descent specialised — the fields used to be `Any` / `Vector{Any}`, which boxed and
dynamically dispatched every zipper operation in the product DFS (CLAUDE.md: no `Vector{Any}` in hot
paths).  The 3-argument constructor still defaults the element type to `AbstractZipper`, which admits
any zipper the callback may return.
"""
mutable struct DependentZipper{PZ, SZ, C, F} <: AbstractZipper
    factor_paths::Vector{Int}   # depths at the factor boundaries
    primary::PZ
    secondary::Vector{SZ}
    enroll_payload::C           # C — state threaded through the enroll calls
    enroll::F                   # (payload, path, factor_idx) → (payload, Union{Nothing, SZ})
end

"""
    DependentZipper(primary, payload, enroll[, SecondaryType]) → DependentZipper

Mirrors `DependentProductZipperG::new_enroll` (dependent_zipper.rs:39-51).
`enroll(payload, path, factor_count) → (new_payload, Union{Nothing, secondary_zipper})`.

`SecondaryType` is the element type of the enrolled-factor stack; it defaults to `AbstractZipper`
when the caller does not pin the concrete zipper type the callback returns.
"""
DependentZipper(primary::PZ, payload::C, enroll::F, ::Type{SZ}) where {PZ, C, F, SZ} =
    DependentZipper{PZ, SZ, C, F}(Int[], primary, SZ[], payload, enroll)

DependentZipper(primary, payload, enroll) =
    DependentZipper(primary, payload, enroll, AbstractZipper)

# =====================================================================
# Internal helpers — upstream's private methods (dependent_zipper.rs:53-178)
# =====================================================================

# `factor_idx` (dependent_zipper.rs:63-72). 1-based here; upstream's 0-based `checked_sub` chain
# becomes the `factor < 1 → nothing` test.
function _dpz_factor_idx(dz::DependentZipper, truncate_up::Bool)
    @assert length(dz.factor_paths) == length(dz.secondary) "factor_paths and secondary must stay in step"
    len = depth(dz)
    factor = length(dz.factor_paths)
    factor == 0 && return nothing
    while truncate_up && factor >= 1 && dz.factor_paths[factor] == len
        factor -= 1
    end
    factor < 1 ? nothing : factor
end

# `is_path_end` (dependent_zipper.rs:89-95): the last active factor sits at the end of a valid path,
# i.e. a stitch point for the next factor.
function _dpz_is_path_end(dz::DependentZipper)
    idx = _dpz_factor_idx(dz, false)
    z = idx !== nothing ? dz.secondary[idx] : dz.primary
    child_count(z) == 0 && path_exists(z)
end

# `exit_factors` (dependent_zipper.rs:98-107) — pops BOTH stacks, since the factor zipper itself is
# dropped when we ascend out of it (unlike ProductZipperG, whose secondaries are pre-supplied).
function _dpz_exit_factors!(dz::DependentZipper)
    len = depth(dz)
    exited = false
    while !isempty(dz.factor_paths) && dz.factor_paths[end] == len
        pop!(dz.factor_paths)
        pop!(dz.secondary)
        exited = true
    end
    exited
end

# `enter_factors` (dependent_zipper.rs:110-125): ask the callback for the next factor at a path end.
function _dpz_enter_factors!(dz::DependentZipper)
    len = depth(dz)
    _dpz_is_path_end(dz) || return false
    # ADAPTATION: upstream hands the callback a borrowed `&[u8]`; `path` is a view over the primary's
    # buffer here, so it is copied — the callback may outlive the next move (MORK's compare policy
    # builds a PathMap from it).
    new_payload, new_z = dz.enroll(dz.enroll_payload, copy(path(dz)), length(dz.secondary))
    dz.enroll_payload = new_payload
    new_z === nothing && return false
    push!(dz.factor_paths, len)
    push!(dz.secondary, new_z)
    true
end

# `ascend_cond` (dependent_zipper.rs:129-160): `ascend_until` when `allow_stop_on_val`, else
# `ascend_until_branch`. Returns the bytes ascended.
function _dpz_ascend_cond!(dz::DependentZipper, allow_stop_on_val::Bool)::Int
    plen = depth(dz)
    ascended = 0
    while true
        while !isempty(dz.factor_paths) && dz.factor_paths[end] == plen
            pop!(dz.factor_paths)
            pop!(dz.secondary)
        end
        idx = _dpz_factor_idx(dz, false)
        if idx !== nothing
            z = dz.secondary[idx]
            # the inner zipper reports how far it moved, so the primary can be brought along without
            # measuring its path before and after
            delta = allow_stop_on_val ? ascend_until!(z) : ascend_until_branch!(z)
            plen -= delta
            ascend!(dz.primary, delta)
            ascended += delta
            if delta > 0 && (child_count(dz) != 1 || (allow_stop_on_val && is_val(dz)))
                return ascended
            end
        else
            return ascended + (allow_stop_on_val ? ascend_until!(dz.primary) : ascend_until_branch!(dz.primary))
        end
    end
end

# =====================================================================
# Zipper (dependent_zipper.rs:304-338) — the focus factor answers
# =====================================================================

function path_exists(dz::DependentZipper)
    idx = _dpz_factor_idx(dz, true)
    idx !== nothing ? path_exists(dz.secondary[idx]) : path_exists(dz.primary)
end

function is_val(dz::DependentZipper)
    idx = _dpz_factor_idx(dz, true)
    idx !== nothing ? is_val(dz.secondary[idx]) : is_val(dz.primary)
end

function child_count(dz::DependentZipper)
    idx = _dpz_factor_idx(dz, false)
    idx !== nothing ? child_count(dz.secondary[idx]) : child_count(dz.primary)
end

function child_mask(dz::DependentZipper)
    idx = _dpz_factor_idx(dz, false)
    idx !== nothing ? child_mask(dz.secondary[idx]) : child_mask(dz.primary)
end

# =====================================================================
# ZipperValues / ZipperValuesAt / ZipperReadOnlyValues (dependent_zipper.rs:227-280)
# =====================================================================

function val(dz::DependentZipper)
    idx = _dpz_factor_idx(dz, true)
    idx !== nothing ? val(dz.secondary[idx]) : val(dz.primary)
end

# val_at — dependent_zipper.rs:250-256. The same focus-factor dispatch as `val`, so a lookup below the
# focus resolves inside whichever factor the cursor is in.
function val_at(dz::DependentZipper, p::AbstractVector{UInt8})
    idx = _dpz_factor_idx(dz, true)
    idx !== nothing ? val_at(dz.secondary[idx], p) : val_at(dz.primary, p)
end

function get_val(dz::DependentZipper)
    idx = _dpz_factor_idx(dz, true)
    idx !== nothing ? get_val(dz.secondary[idx]) : get_val(dz.primary)
end

function get_val_at(dz::DependentZipper, p::AbstractVector{UInt8})
    idx = _dpz_factor_idx(dz, true)
    idx !== nothing ? get_val_at(dz.secondary[idx], p) : get_val_at(dz.primary, p)
end

# =====================================================================
# ZipperAbsolutePath / ZipperPath / ZipperConcrete (dependent_zipper.rs:181-213, 468-478)
# =====================================================================

path(dz::DependentZipper) = path(dz.primary)                        # :475
origin_path(dz::DependentZipper) = origin_path(dz.primary)          # :188
root_prefix_path(dz::DependentZipper) = root_prefix_path(dz.primary) # :189

function shared_node_id(dz::DependentZipper)                        # :199-205
    idx = _dpz_factor_idx(dz, true)
    idx !== nothing ? shared_node_id(dz.secondary[idx]) : shared_node_id(dz.primary)
end

function is_shared(dz::DependentZipper)                             # :206-212
    idx = _dpz_factor_idx(dz, true)
    idx !== nothing ? is_shared(dz.secondary[idx]) : is_shared(dz.primary)
end

# =====================================================================
# ZipperMoving (dependent_zipper.rs:340-466)
# =====================================================================

depth(dz::DependentZipper) = depth(dz.primary)            # :347
focus_byte(dz::DependentZipper) = focus_byte(dz.primary)  # :351

function reset!(dz::DependentZipper)                      # :354-358
    empty!(dz.factor_paths)
    empty!(dz.secondary)   # the enrolled factors are recomputed by the callback on the way down
    reset!(dz.primary)
    nothing
end

# :359-361 — `unimplemented!("method will probably get removed")`
val_count(::DependentZipper) =
    error("val_count is unimplemented for DependentZipper (dependent_zipper.rs:359)")

function descend_to_existing!(dz::DependentZipper, k)     # :362-382
    kv = k isa AbstractVector{UInt8} ? k : collect(UInt8, k)
    n = length(kv)
    off = 0
    descended = 0
    while off < n
        _dpz_enter_factors!(dz)
        rest = view(kv, (off + 1):n)
        idx = _dpz_factor_idx(dz, false)
        good = if idx !== nothing
            g = descend_to_existing!(dz.secondary[idx], rest)
            # the primary carries the WHOLE product path, so it follows the secondary byte for byte
            descend_to!(dz.primary, view(rest, 1:g))
            g
        else
            # NOTE: upstream does NOT break out of the loop here (only `good == 0` breaks); ours used
            # to `break` unconditionally after a primary descent, which stopped the walk at the first
            # factor boundary instead of entering the next factor.
            descend_to_existing!(dz.primary, rest)
        end
        good == 0 && break
        descended += good
        off += good
    end
    _dpz_enter_factors!(dz)
    descended
end

function descend_to!(dz::DependentZipper, k)              # :383-395
    kv = k isa AbstractVector{UInt8} ? k : collect(UInt8, k)
    good = descend_to_existing!(dz, kv)
    good == length(kv) && return nothing
    rest = view(kv, (good + 1):length(kv))
    idx = _dpz_factor_idx(dz, false)
    idx !== nothing && descend_to!(dz.secondary[idx], rest)
    descend_to!(dz.primary, rest)
    nothing
end

function descend_until_observed!(dz::DependentZipper, obs)  # :410-429
    moved = false
    _dpz_enter_factors!(dz)
    while child_count(dz) == 1
        idx = _dpz_factor_idx(dz, false)
        moved |= if idx !== nothing
            # The primary carries the whole product path, so it has to follow whatever the secondary
            # descends. Mirroring the movement keeps it in step without buffering the bytes.
            descend_until_observed!(dz.secondary[idx], (MirrorPathObserver(dz.primary), obs))
        else
            descend_until_observed!(dz.primary, obs)
        end
        _dpz_enter_factors!(dz)
        is_val(dz) && break
    end
    moved
end

function ascend!(dz::DependentZipper, steps::Int)::Int      # :438-453
    remaining = steps
    while remaining > 0
        _dpz_exit_factors!(dz)
        idx = _dpz_factor_idx(dz, false)
        if idx !== nothing
            len = depth(dz) - dz.factor_paths[idx]
            delta = min(len, remaining)
            ascend!(dz.secondary[idx], delta)
            ascend!(dz.primary, delta)
            remaining -= delta
        else
            return (steps - remaining) + ascend!(dz.primary, remaining)
        end
    end
    steps
end

ascend_until!(dz::DependentZipper) = _dpz_ascend_cond!(dz, true)          # :459
ascend_until_branch!(dz::DependentZipper) = _dpz_ascend_cond!(dz, false)  # :463

# =====================================================================
# Product-factor accessors (upstream's inherent methods, dependent_zipper.rs:53-85)
# =====================================================================

"`focus_factor(dz)` — index of the factor holding the focus, 0 for the primary (dependent_zipper.rs:57)."
function focus_factor(dz::DependentZipper)
    idx = _dpz_factor_idx(dz, true)
    idx === nothing ? 0 : idx    # 1-based idx == upstream's 0-based `x + 1`
end

"""
`path_indices(dz)` — the end-points, as offsets into `path(dz)`, of each completed factor's portion
of the path (dependent_zipper.rs:83).  Its length is `focus_factor(dz)`.
"""
path_indices(dz::DependentZipper) = dz.factor_paths

"""
`factor_count(dz)` — the number of factors enrolled so far, counting the primary.

ADAPTATION: upstream's `DependentProductZipperG` does NOT implement `ZipperProduct`, so it has no
`factor_count` (product_zipper.rs:833-891 lists only `ProductZipper`, `ProductZipperG` and
`OneFactor`).  Ours keeps one because `ProductZipperG`'s factor accounting reaches into a
`DependentZipper` primary (see `_pzg_inner_factor_count` in ProductZipperG.jl and
test/test_pzg_factor_count_guard.jl).  Unlike the static product zippers this value GROWS as factors
are enrolled.
"""
factor_count(dz::DependentZipper) = length(dz.secondary) + 1

# =====================================================================
# Exports — trait functions are exported from ZipperTraits.jl
# =====================================================================

export DependentZipper
# `factor_count` / `focus_factor` / `path_indices` (upstream's ZipperProduct, non-trait) are
# declared and exported by ProductZipper.jl:363-367,384 — this file only adds methods for them.
