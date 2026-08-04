"""
DependentZipper — port of `pathmap/src/dependent_zipper.rs`.

Like `ProductZipper` but secondary factors are computed on-the-fly via an
`enroll` callback.  The callback receives the current path and decides
whether to graft a new secondary zipper.

Julia translation notes:
  - Rust `for<'a> FnOnce(C, &'a[u8], usize) → (C, Option<SecondaryZ>)` →
    Julia `enroll::Function` with `enroll_payload` carrying mutable state.
  - `Clone` bound on F → Julia closures are already reference types; state is
    tracked through the mutable `enroll_payload` field.
  - `ZipperMoving` methods mirrored as `dpz_*` functions.
"""

# =====================================================================
# DependentZipper struct
# =====================================================================

"""
    DependentZipper{PZ, SZ}

Cartesian-product zipper where secondary factors are computed dynamically.
Mirrors `DependentProductZipperG<PrimaryZ, SecondaryZ, V, C, F>`.
"""
mutable struct DependentZipper{PZ, SZ}
    factor_paths::Vector{Int}     # path lengths at factor boundaries
    primary::PZ
    secondary::Vector{SZ}
    enroll_payload::Any             # C — state threaded through enroll calls
    enroll::Function        # (payload, path, factor_idx) → (payload, Union{nothing,SZ})
end

"""
    DependentZipper(primary, payload, enroll) → DependentZipper

Mirrors `DependentProductZipperG::new_enroll`.
`enroll(payload, path, factor_count) → (new_payload, Union{nothing, secondary_zipper})`
"""
function DependentZipper(primary::PZ, payload, enroll::Function) where {PZ}
    DependentZipper{PZ, Any}(Int[], primary, Any[], payload, enroll)
end

# =====================================================================
# Internal helpers
# =====================================================================

"""
Path at the primary zipper.
"""
dpz_path(dpz::DependentZipper) = rz_path(dpz.primary)

"""
Returns the 1-based index of the active secondary, or nothing if in primary.
"""
function _dpz_factor_idx(dpz::DependentZipper, truncate_up::Bool)
    len = length(dpz_path(dpz))
    isempty(dpz.factor_paths) && return nothing
    factor = length(dpz.factor_paths)
    while truncate_up && factor >= 1 && dpz.factor_paths[factor] == len
        factor -= 1
    end
    factor < 1 ? nothing : factor
end

"""
Current active zipper (secondary or primary).
"""
function _dpz_active(dpz::DependentZipper, truncate_up::Bool)
    idx = _dpz_factor_idx(dpz, truncate_up)
    idx !== nothing ? dpz.secondary[idx] : dpz.primary
end

"""
True if at the end of the current factor's path (leaf).
"""
function _dpz_is_path_end(dpz::DependentZipper)
    idx = _dpz_factor_idx(dpz, false)
    z = idx !== nothing ? dpz.secondary[idx] : dpz.primary
    _dpz_child_count_inner(z) == 0 && _dpz_path_exists_inner(z)
end

_dpz_path_exists_inner(z::ReadZipperCore) = zipper_path_exists(z)
_dpz_child_count_inner(z::ReadZipperCore) = zipper_child_count(z)
_dpz_child_mask_inner(z::ReadZipperCore) = zipper_child_mask(z)

# Generic fallbacks for any zipper type
_dpz_path_exists_inner(z) = false
_dpz_child_count_inner(z) = 0
_dpz_child_mask_inner(z) = ByteMask()

"""
Pop factor stack if top factor is at the current path length.
"""
function _dpz_exit_factors!(dpz::DependentZipper)
    len = length(dpz_path(dpz))
    exited = false
    while !isempty(dpz.factor_paths) && dpz.factor_paths[end] == len
        pop!(dpz.factor_paths)
        pop!(dpz.secondary)
        exited = true
    end
    exited
end

"""
Call enroll to create a new factor if we're at a path end.
"""
function _dpz_enter_factors!(dpz::DependentZipper)
    _dpz_is_path_end(dpz) || return false
    new_payload, new_z = dpz.enroll(
        dpz.enroll_payload, copy(dpz_path(dpz)), length(dpz.secondary)
    )
    dpz.enroll_payload = new_payload
    new_z === nothing && return false
    push!(dpz.factor_paths, length(dpz_path(dpz)))
    push!(dpz.secondary, new_z)
    true
end

# =====================================================================
# Zipper interface
# =====================================================================

function dpz_path_exists(dpz::DependentZipper)
    idx = _dpz_factor_idx(dpz, true)
    if idx !== nothing
        _dpz_path_exists_inner(dpz.secondary[idx])
    else
        zipper_path_exists(dpz.primary)
    end
end

function dpz_is_val(dpz::DependentZipper)
    idx = _dpz_factor_idx(dpz, true)
    if idx !== nothing
        z = dpz.secondary[idx]
        z isa ReadZipperCore ? zipper_is_val(z) : false
    else
        zipper_is_val(dpz.primary)
    end
end

function dpz_child_count(dpz::DependentZipper)
    idx = _dpz_factor_idx(dpz, false)
    if idx !== nothing
        _dpz_child_count_inner(dpz.secondary[idx])
    else
        zipper_child_count(dpz.primary)
    end
end

function dpz_child_mask(dpz::DependentZipper)
    idx = _dpz_factor_idx(dpz, false)
    if idx !== nothing
        _dpz_child_mask_inner(dpz.secondary[idx])
    else
        zipper_child_mask(dpz.primary)
    end
end

function dpz_val(dpz::DependentZipper)
    idx = _dpz_factor_idx(dpz, true)
    if idx !== nothing
        z = dpz.secondary[idx]
        z isa ReadZipperCore ? zipper_val(z) : nothing
    else
        zipper_val(dpz.primary)
    end
end

# ── val_at — upstream dependent_zipper.rs:240-246. Identical dispatch to `val` above: the FOCUS
# factor answers, so a lookup below the focus resolves inside whichever factor the cursor is in.
function dpz_val_at(dpz::DependentZipper, path::AbstractVector{UInt8})
    idx = _dpz_factor_idx(dpz, true)
    if idx !== nothing
        z = dpz.secondary[idx]
        z isa ReadZipperCore ? zipper_val_at(z, path) : nothing
    else
        zipper_val_at(dpz.primary, path)
    end
end

dpz_at_root(dpz::DependentZipper) = isempty(dpz_path(dpz))
dpz_factor_count(dpz::DependentZipper) = length(dpz.secondary) + 1

function dpz_focus_factor(dpz::DependentZipper)
    idx = _dpz_factor_idx(dpz, true)
    idx === nothing ? 0 : idx
end

dpz_path_indices(dpz::DependentZipper) = dpz.factor_paths

# =====================================================================
# ZipperMoving
# =====================================================================

# Generic dispatch aliases so DependentZipper works wherever ReadZipperCore is expected
zipper_reset!(dpz::DependentZipper) = dpz_reset!(dpz)
zipper_path(dpz::DependentZipper) = dpz_path(dpz)
zipper_path_exists(dpz::DependentZipper) = dpz_path_exists(dpz)
zipper_is_val(dpz::DependentZipper) = dpz_is_val(dpz)
zipper_child_count(dpz::DependentZipper) = dpz_child_count(dpz)
zipper_child_mask(dpz::DependentZipper) = dpz_child_mask(dpz)
zipper_at_root(dpz::DependentZipper) = dpz_at_root(dpz)
zipper_descend_to_byte!(dpz::DependentZipper, b) = dpz_descend_to_byte!(dpz, b)
zipper_descend_to!(dpz::DependentZipper, p) = dpz_descend_to!(dpz, p)
zipper_descend_to_existing!(dpz::DependentZipper, p) = dpz_descend_to_existing!(dpz, p)
zipper_descend_first_byte!(dpz::DependentZipper) = dpz_descend_first_byte!(dpz)
zipper_descend_until!(dpz::DependentZipper) = dpz_descend_until!(dpz)
zipper_ascend!(dpz::DependentZipper, n::Int) = dpz_ascend!(dpz, n)
zipper_ascend_byte!(dpz::DependentZipper) = dpz_ascend_byte!(dpz)
zipper_ascend_until!(dpz::DependentZipper) = dpz_ascend_until!(dpz)
zipper_ascend_until_branch!(dpz::DependentZipper) = dpz_ascend_until_branch!(dpz)
zipper_to_next_sibling_byte!(dpz::DependentZipper) = dpz_to_next_sibling_byte!(dpz)
zipper_to_next_val!(dpz::DependentZipper) = dpz_to_next_val!(dpz)

function dpz_reset!(dpz::DependentZipper)
    empty!(dpz.factor_paths)
    for sz in dpz.secondary
        ;
        sz isa ReadZipperCore && zipper_reset!(sz);
    end
    empty!(dpz.secondary)
    zipper_reset!(dpz.primary)
end

function dpz_descend_to_existing!(dpz::DependentZipper, path)
    pv = collect(UInt8, path)
    descended = 0
    while !isempty(pv)
        _dpz_enter_factors!(dpz)
        idx = _dpz_factor_idx(dpz, false)
        if idx !== nothing
            sz = dpz.secondary[idx]
            good = sz isa ReadZipperCore ? zipper_descend_to_existing!(sz, pv) : 0
            good > 0 && zipper_descend_to!(dpz.primary, pv[1:good])
            good == 0 && break
            descended += good
            pv = pv[(good + 1):end]
        else
            good = zipper_descend_to_existing!(dpz.primary, pv)
            descended += good
            break
        end
    end
    _dpz_enter_factors!(dpz)
    descended
end

function dpz_descend_to!(dpz::DependentZipper, path)
    pv = collect(UInt8, path)
    good = dpz_descend_to_existing!(dpz, pv)
    good == length(pv) && return nothing
    rest = pv[(good + 1):end]
    idx = _dpz_factor_idx(dpz, false)
    if idx !== nothing
        sz = dpz.secondary[idx]
        sz isa ReadZipperCore && zipper_descend_to!(sz, rest)
    end
    zipper_descend_to!(dpz.primary, rest)
end

dpz_descend_to_byte!(dpz::DependentZipper, k::UInt8) = dpz_descend_to!(dpz, UInt8[k])

function dpz_descend_indexed_byte!(dpz::DependentZipper, idx::Int)
    mask = dpz_child_mask(dpz)
    byte = indexed_bit(mask, idx, true)
    byte === nothing && return false
    dpz_descend_to_byte!(dpz, byte)
    true
end

dpz_descend_first_byte!(dpz::DependentZipper) = dpz_descend_indexed_byte!(dpz, 0)

function dpz_descend_until!(dpz::DependentZipper)
    moved = false
    _dpz_enter_factors!(dpz)
    while dpz_child_count(dpz) == 1
        idx = _dpz_factor_idx(dpz, false)
        if idx !== nothing
            sz = dpz.secondary[idx]
            if sz isa ReadZipperCore
                before = length(zipper_path(sz))
                rv = zipper_descend_until!(sz)
                after_path = zipper_path(sz)
                length(after_path) > before &&
                    zipper_descend_to!(dpz.primary, after_path[(before + 1):end])
                moved |= rv
            end
        else
            moved |= zipper_descend_until!(dpz.primary)
        end
        _dpz_enter_factors!(dpz)
        dpz_is_val(dpz) && break
    end
    moved
end

function dpz_ascend!(dpz::DependentZipper, steps::Int=1)
    remaining = steps
    while remaining > 0
        _dpz_exit_factors!(dpz)
        idx = _dpz_factor_idx(dpz, false)
        if idx !== nothing
            len = length(dpz_path(dpz)) - dpz.factor_paths[idx]
            delta = min(len, remaining)
            sz = dpz.secondary[idx]
            sz isa ReadZipperCore && zipper_ascend!(sz, delta)
            zipper_ascend!(dpz.primary, delta)
            remaining -= delta
        else
            return zipper_ascend!(dpz.primary, remaining)
        end
    end
    true
end

dpz_ascend_byte!(dpz::DependentZipper) = dpz_ascend!(dpz, 1)

function _dpz_ascend_cond!(dpz::DependentZipper, allow_val::Bool)
    plen = length(dpz_path(dpz))
    while true
        while !isempty(dpz.factor_paths) && dpz.factor_paths[end] == plen
            pop!(dpz.factor_paths)
            pop!(dpz.secondary)
        end
        idx = _dpz_factor_idx(dpz, false)
        if idx !== nothing
            sz = dpz.secondary[idx]
            if sz isa ReadZipperCore
                before = length(zipper_path(sz))
                rv = allow_val ? zipper_ascend_until!(sz) : zipper_ascend_until_branch!(sz)
                delta = before - length(zipper_path(sz))
                plen -= delta
                zipper_ascend!(dpz.primary, delta)
                (rv && (dpz_child_count(dpz) != 1 || (allow_val && dpz_is_val(dpz)))) &&
                    return true
            end
        else
            return if allow_val
                zipper_ascend_until!(dpz.primary)
            else
                zipper_ascend_until_branch!(dpz.primary)
            end
        end
    end
end

dpz_ascend_until!(dpz::DependentZipper) = _dpz_ascend_cond!(dpz, true)
dpz_ascend_until_branch!(dpz::DependentZipper) = _dpz_ascend_cond!(dpz, false)

function dpz_to_next_sibling_byte!(dpz::DependentZipper)
    isempty(dpz_path(dpz)) && return false
    cur_byte = last(dpz_path(dpz))
    dpz_ascend!(dpz, 1) || return false
    mask = dpz_child_mask(dpz)
    nxt = next_bit(mask, cur_byte)
    if nxt !== nothing
        dpz_descend_to_byte!(dpz, nxt)
        return true
    else
        dpz_descend_to_byte!(dpz, cur_byte)
        return false
    end
end

function dpz_to_prev_sibling_byte!(dpz::DependentZipper)
    isempty(dpz_path(dpz)) && return false
    cur_byte = last(dpz_path(dpz))
    dpz_ascend!(dpz, 1) || return false
    mask = dpz_child_mask(dpz)
    prv = prev_bit(mask, cur_byte)
    if prv !== nothing
        dpz_descend_to_byte!(dpz, prv)
        return true
    else
        dpz_descend_to_byte!(dpz, cur_byte)
        return false
    end
end

# ZipperIteration — DFS default
function dpz_to_next_val!(dpz::DependentZipper)
    loop_count = 0
    while true
        loop_count += 1
        if loop_count > 200_000
            @warn "DependentZipper dpz_to_next_val! hit iteration cap (200k); returning false. This indicates a likely infinite loop in dependent DFS." maxlog=1
            return false
        end
        if dpz_descend_first_byte!(dpz)
            dpz_is_val(dpz) && return true
            if dpz_descend_until!(dpz)
                ;
                dpz_is_val(dpz) && return true;
            end
        else
            ascending = true
            while ascending
                if dpz_to_next_sibling_byte!(dpz)
                    dpz_is_val(dpz) && return true
                    ascending = false
                else
                    dpz_ascend_byte!(dpz) || return false
                    dpz_at_root(dpz) && return false
                end
            end
        end
    end
end

# =====================================================================
# Exports
# =====================================================================

export DependentZipper
export dpz_path, dpz_path_exists, dpz_is_val, dpz_child_count, dpz_child_mask
export dpz_val, dpz_val_at, dpz_at_root, dpz_factor_count, dpz_focus_factor, dpz_path_indices
export dpz_reset!, dpz_descend_to!, dpz_descend_to_byte!
export dpz_descend_to_existing!, dpz_descend_indexed_byte!
export dpz_descend_first_byte!, dpz_descend_until!
export dpz_ascend!, dpz_ascend_byte!, dpz_ascend_until!, dpz_ascend_until_branch!
export dpz_to_next_sibling_byte!, dpz_to_prev_sibling_byte!
export dpz_to_next_val!
