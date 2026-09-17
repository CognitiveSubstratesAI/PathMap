"""
EmptyZipper — port of `pathmap/src/empty_zipper.rs` (upstream 0.4.0 @ f477a91).

A zipper type that moves over a completely empty trie.  All path-existence
and value queries return false/nothing.  Navigation still tracks the path
buffer so absolute-path methods work correctly.

Trait methods are the generic functions from `ZipperTraits.jl`; everything upstream leaves to a
default body (`descend_to_check!`, `descend_to_existing!`, `descend_last_byte!`, `move_to_path!`,
`to_next_step!`, …) falls through to the `AbstractZipper` methods.
"""

mutable struct EmptyZipper <: AbstractZipper
    path::Vector{UInt8}
    path_start_idx::Int
end

"""
    EmptyZipper() → EmptyZipper

New zipper starting at the root of an empty trie.  Mirrors `EmptyZipper::new` (empty_zipper.rs:14).
"""
EmptyZipper() = EmptyZipper(UInt8[], 0)

"""
    EmptyZipper(root_prefix) → EmptyZipper

New zipper with the given root prefix path.
Mirrors `EmptyZipper::new_at_path` (empty_zipper.rs:18).
"""
function EmptyZipper(root_prefix)
    pv = collect(UInt8, root_prefix)
    EmptyZipper(pv, length(pv))
end

# =====================================================================
# Zipper (empty_zipper.rs:27-32)
# =====================================================================

path_exists(::EmptyZipper) = false
is_val(::EmptyZipper) = false
child_count(::EmptyZipper) = 0
child_mask(::EmptyZipper) = ByteMask()

# =====================================================================
# ZipperMoving (empty_zipper.rs:34-73)
# =====================================================================

# `depth` and `focus_byte` are required in 0.4.0; `at_root` uses the AbstractZipper default
# (`depth == 0`), which is exactly upstream's default body.
depth(z::EmptyZipper) = length(z.path) - z.path_start_idx
focus_byte(z::EmptyZipper) = isempty(z.path) ? nothing : @inbounds(z.path[end])

function reset!(z::EmptyZipper)
    resize!(z.path, z.path_start_idx)
    nothing
end

val_count(::EmptyZipper) = 0

function descend_to!(z::EmptyZipper, k)
    append!(z.path, k)
    nothing
end

function descend_to_byte!(z::EmptyZipper, k::UInt8)
    push!(z.path, k)
    nothing
end

# Nothing exists below the focus, so every "descend into a child" move fails without moving.
descend_indexed_byte!(::EmptyZipper, ::Int)::Union{Nothing, UInt8} = nothing
descend_first_byte!(::EmptyZipper)::Union{Nothing, UInt8} = nothing
descend_until_observed!(::EmptyZipper, _obs) = false

# empty_zipper.rs:49-54 — returns the bytes actually ascended, clamped at the root.
function ascend!(z::EmptyZipper, steps::Int)::Int
    available = length(z.path) - z.path_start_idx
    ascended = min(steps, available)
    resize!(z.path, length(z.path) - ascended)
    ascended
end

function ascend_byte!(z::EmptyZipper)
    length(z.path) > z.path_start_idx || return false
    pop!(z.path)
    true
end

# empty_zipper.rs:63-70 — with no branches and no values, "ascend until" goes all the way to the root.
function ascend_until!(z::EmptyZipper)::Int
    ascended = length(z.path) - z.path_start_idx
    reset!(z)
    ascended
end

ascend_until_branch!(z::EmptyZipper)::Int = ascend_until!(z)

to_next_sibling_byte!(::EmptyZipper)::Union{Nothing, UInt8} = nothing
to_prev_sibling_byte!(::EmptyZipper)::Union{Nothing, UInt8} = nothing

# =====================================================================
# ZipperPath / ZipperAbsolutePath (empty_zipper.rs:75-82)
# =====================================================================

path(z::EmptyZipper) = view(z.path, (z.path_start_idx + 1):length(z.path))
origin_path(z::EmptyZipper) = z.path
root_prefix_path(z::EmptyZipper) = view(z.path, 1:z.path_start_idx)

# =====================================================================
# ZipperIteration (empty_zipper.rs:84-89) — an empty trie has nowhere to go
# =====================================================================

to_next_val_observed!(::EmptyZipper, _obs) = false
descend_last_path_observed!(::EmptyZipper, _obs) = false
descend_first_k_path_observed!(::EmptyZipper, ::Int, _obs) = false
to_next_k_path_observed!(::EmptyZipper, ::Int, _obs) = false

# =====================================================================
# Values / forking (empty_zipper.rs:91-117)
# =====================================================================

val(::EmptyZipper) = nothing
val_at(::EmptyZipper, _path) = nothing
get_val(::EmptyZipper) = nothing                 # ZipperReadOnlyValues
get_val_at(::EmptyZipper, _path) = nothing       # ZipperReadOnlyValues
to_next_get_val_observed!(::EmptyZipper, _obs) = nothing   # ZipperReadOnlyIteration

# empty_zipper.rs:99-102 — the fork is rooted at the focus, so the whole origin path becomes its prefix.
fork_read_zipper(z::EmptyZipper) = EmptyZipper(origin_path(z))

# =====================================================================
# Exports
# =====================================================================

export EmptyZipper
