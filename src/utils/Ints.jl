"""
Ints — port of `pathmap/src/utils/ints.rs`.

Utilities for encoding, decoding, and working with integers represented
within paths.

**Portable section (landed now):**
  - `PathInteger` — Union-typed analog of Rust's `PathInteger<N>` trait
  - `indices_to_bob!` / `bob_to_indices!` — Bits-of-Byte (bit-plane)
  - `indices_to_weave!` / `weave_to_indices!` — round-robin big-endian

**Not-yet-ported (no consumer):**
  - `gen_int_range` / `gen_int_range_in`
  - `gen_child_level_in` / `gen_value_level_in` / `get_from_cache`

These range generators construct a `PathMap` from a numeric range via
`write_zipper_at_path` + `graft_map`.

IN-DOC1 (audit 2026-06-04): the old note said these "will be ported once trie_map.rs +
write_zipper.rs land" — but PathMap + WriteZipper HAVE landed (the precondition is met).
They remain unported only because no consumer needs them yet; the dependency is no longer
the blocker. Port them when a numeric-range PathMap consumer appears.

1:1 port: verbatim control flow, bit-endianness, and assertion set.
"""

# =====================================================================
# PathInteger — trait-equivalent for encodable integer types
# =====================================================================
#
# Rust:
#   pub trait PathInteger<const N: usize>: ...
#   impl PathInteger<1>  for u8
#   impl PathInteger<2>  for u16
#   impl PathInteger<4>  for u32
#   impl PathInteger<8>  for u64
#   impl PathInteger<8>  for usize     (on 64-bit platforms)
#   impl PathInteger<16> for u128
#
# Julia: a Union over the built-in unsigned integer types. `sizeof(T)`
# recovers NUM_SIZE. `UInt` is `UInt64` on 64-bit platforms, matching
# upstream's `usize` cfg-gated impl.

"""
    PathInteger

Type alias for integers encodable as path elements — `UInt8`, `UInt16`,
`UInt32`, `UInt64`, `UInt128`. Mirrors upstream `PathInteger<N>` where
`N == sizeof(T)`.
"""
const PathInteger = Union{UInt8, UInt16, UInt32, UInt64, UInt128}

# =====================================================================
# Bits-of-Byte (BOB) encoding
# =====================================================================

"""
    indices_to_bob!(bob::Vector{UInt8}, xs::AbstractVector{<:Unsigned}) -> Int

"Bits of Byte". Encode up to 8 natural numbers into `bob` by combining
the bits into path bytes. Does not pad to number bit length. Returns
the number of bit-planes written (`steps`).

Bit-planes are appended in descending order: the most significant
plane becomes `bob[1]`, the least significant becomes `bob[steps]`.

Port of `pathmap::utils::indices_to_bob`.
"""
function indices_to_bob!(bob::Vector{UInt8}, xs::AbstractVector{R}) where {R <: Unsigned}
    @assert length(xs) <= 8
    num_size = sizeof(R)
    steps = isempty(xs) ? 0 : maximum(num_size*8 - leading_zeros(x) for x in xs)
    for c in (steps - 1):-1:0
        push!(bob, UInt8(0))
        for i in 0:(length(xs) - 1)
            bit = UInt8((xs[i + 1] >> c) & one(R))
            bob[end] |= bit << i
        end
    end
    return steps
end

"""
    bob_to_indices!(xs::AbstractVector{<:Unsigned}, bob::AbstractVector{UInt8})

Decode a BOB path into `xs`. Caller must zero `xs` before calling
(matches upstream's "`xs` required to be zeroed" contract).

Asserts `length(xs) <= 8` and `length(bob) <= sizeof(eltype(xs))*8`.

Port of `pathmap::utils::bob_to_indices`.
"""
function bob_to_indices!(
    xs::AbstractVector{R}, bob::AbstractVector{UInt8}
) where {R <: Unsigned}
    @assert length(xs) <= 8 && length(bob) <= sizeof(R)*8
    for i in 0:(length(bob) - 1)
        for k in 0:(length(xs) - 1)
            xs[k + 1] |= R((bob[i + 1] >> k) & 0x1) << (length(bob) - 1 - i)
        end
    end
    return nothing
end

# =====================================================================
# Weave encoding (round-robin big-endian)
# =====================================================================

"""
    indices_to_weave!(weave::Vector{UInt8}, xs::AbstractVector{<:Integer}, num_size::Int)

Encode multiple integers big-endian round-robin wise into a byte path.
Writes `num_size` bytes per element, most-significant byte plane first.
Does not pad to number byte length — caller controls `num_size`.

Port of `pathmap::utils::indices_to_weave`. Upstream takes
`xs: &[usize]` regardless of the `PathInteger<NUM_SIZE>` phantom; here
`num_size` is an explicit parameter because Julia lacks const generics.
"""
function indices_to_weave!(
    weave::Vector{UInt8}, xs::AbstractVector{<:Integer}, num_size::Int
)
    for c in (num_size - 1):-1:0
        for i in eachindex(xs)
            push!(weave, UInt8((xs[i] >> (c*8)) & 0xFF))
        end
    end
    return nothing
end

"""
    weave_to_indices!(xs::AbstractVector{<:Unsigned}, weave::AbstractVector{UInt8})

Decode a weave path into `xs`. Caller must zero `xs` before calling.

Asserts `length(weave) % length(xs) == 0`. The `steps` count is derived
from `length(weave) ÷ length(xs)`.

Port of `pathmap::utils::weave_to_indices`.
"""
function weave_to_indices!(
    xs::AbstractVector{R}, weave::AbstractVector{UInt8}
) where {R <: Unsigned}
    n = length(xs)
    n == 0 && return nothing
    @assert length(weave) % n == 0
    steps = length(weave) ÷ n
    for c in (steps - 1):-1:0
        for i in 0:(n - 1)
            xs[i + 1] |= R(weave[n * c + i + 1]) << (8*steps - (c+1)*8)
        end
    end
    return nothing
end

# =====================================================================
# Range generators — DEFERRED (depend on PathMap + WriteZipper)
# =====================================================================
#
# Upstream `ints.rs` additionally exports:
#
#   gen_int_range<V, NUM_SIZE, R>(start, stop, step, value) -> PathMap<V>
#   gen_int_range_in<V, NUM_SIZE, R, A>(..., alloc) -> PathMap<V, A>
#   gen_child_level_in (pub(crate))
#   gen_value_level_in
#   get_from_cache
#
# These build a `PathMap` from a numeric range by drilling down byte
# levels and grafting child sub-maps via `WriteZipper::graft_map`. Both
# `PathMap` (trie_map.rs) and `WriteZipper` (write_zipper.rs) are not
# yet ported. When they land, the full generator plus its five test
# cases (int_range_generator_0..5) move here.
#
# See `docs/architecture/MORK_PACKAGE_PLAN.md` Phase 1c.

# =====================================================================
# Exports
# =====================================================================

export PathInteger
export indices_to_bob!, bob_to_indices!
export indices_to_weave!, weave_to_indices!
