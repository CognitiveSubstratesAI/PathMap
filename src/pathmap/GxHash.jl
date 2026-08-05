# GxHash.jl — 1:1 port of upstream PathMap's `GxHasher`, the 128-bit state mixer that
# `Catamorphism::hash` folds with (`morphisms.rs:236-261`).
#
# ⚠️ WHICH GxHasher THIS IS, because upstream has TWO and they are NOT interchangeable.
# `PathMap/src/lib.rs:13-16` gates them:
#
#     #[cfg(not(any(miri, target_arch="riscv64")))]  use gxhash;          // the REAL AES-NI crate
#     #[cfg(any(miri, target_arch="riscv64"))]       mod gxhash { ... }   // this ~20-line mixer
#
# So on x86_64 — the default build, and the one the vendored `mork` binary is — `Catamorphism::hash`
# runs the AES-NI crate, and THIS port will NOT reproduce its bytes. It reproduces them exactly under
# miri/riscv64. That is a deliberate, stated trade:
#
#   * matching the AES-NI values means porting AES intrinsics through llvmcall AND PathMap's exact
#     node traversal order, for a digest nobody compares across engines;
#   * and upstream's OWN cfg is the proof that the value is a PER-TARGET ARTIFACT — a hash that
#     changes with `--target` cannot be a portable contract. Identical finding to
#     `MORK/test/conformance/ADAPTATIONS.md` entry 7 (the HashSink digest width).
#
# What we DO get, and what actually matters for a change-digest:
#   * 128 bits instead of `Base.hash`'s 64 — birthday bound 2^64 instead of 2^32;
#   * a SPECIFIED algorithm rather than `Base.hash`, which Julia does not contract as stable across
#     versions. A digest persisted in a checkpoint must survive a Julia upgrade; `Base.hash` need not.
#   * upstream's exact fold STRUCTURE (seed, then mask bytes, then child hashes, then value).
#
# ⚠️ DO NOT substitute `MORK/src/kernel/XXH3.jl` here. It is a different algorithm serving a
# different call site: xxh3_128 backs MORK's `Expr::hash` (`expr/src/lib.rs:312`) and has ZERO calls
# in upstream PathMap; `GxHasher` is PathMap-only (merkleization.rs:56,79 · morphisms.rs:242,255).
# `MORK/src/expr/Expr.jl:130-146` records that call-graph analysis — its conclusion ("port GxHasher
# INTO PathMap") is right, but its description of GxHasher as "~20 self-contained lines" silently
# describes the FALLBACK, not what x86_64 compiles. Corrected there.

"""
    GxHasher

Upstream's `GxHasher` (`PathMap/src/lib.rs:22-56`), the miri/riscv64 fallback mixer. Mutable
two-lane u64 state, read out as a `UInt128`.

Byte-for-byte faithful, including the wrapping adds and the rotate amounts, which are the whole
algorithm — get one rotate wrong and it still "works" while agreeing with nothing.
"""
mutable struct GxHasher
    state_lo::UInt64
    state_hi::UInt64
end

"""
    GxHasher(seed::Int64) -> GxHasher

`with_seed` (`lib.rs:25-29`). The seed's BITS are reinterpreted, never converted — upstream is
explicit: *"Reinterpret the bits without any kind of rounding, truncation, extension"*.
"""
function GxHasher(seed::Int64)
    s = reinterpret(UInt64, seed)
    GxHasher(s ⊻ 0xA5A5A5A5_A5A5A5A5, (~s) ⊻ 0x5A5A5A5A_5A5A5A5A)
end
GxHasher() = GxHasher(Int64(0))

"`write_u8` (lib.rs:39-43). Order-sensitive by construction: the rotate follows the add."
@inline function gx_write_u8!(h::GxHasher, i::UInt8)
    h.state_lo = h.state_lo + UInt64(i)                 # wrapping_add — UInt64 + wraps in Julia
    h.state_hi ⊻= bitrotate(UInt64(i), 11)
    h.state_lo = bitrotate(h.state_lo, 3)
    nothing
end

"`write` (lib.rs:35-38) — a byte slice is fed byte-at-a-time, NOT as a word."
@inline function gx_write!(h::GxHasher, bytes)
    for b in bytes
        gx_write_u8!(h, b)
    end
    nothing
end

"""
    gx_write_u128!(h, i)

`write_u128` (lib.rs:44-50). A DISTINCT path, not equivalent to feeding 16 bytes: it splits into
lanes and uses rotates 17/9. Upstream's `hash_with` uses this for the VALUE hash while using the
byte-wise `write` for the mask and the child hashes, so the two must stay separate here too.
"""
@inline function gx_write_u128!(h::GxHasher, i::UInt128)
    low  = UInt64(i & typemax(UInt64))
    high = UInt64(i >> 64)
    h.state_lo = h.state_lo + low
    h.state_hi ⊻= bitrotate(high, 17)
    h.state_lo ⊻= bitrotate(high, 9)
    nothing
end

"`finish_u128` (lib.rs:31-33)."
@inline gx_finish_u128(h::GxHasher)::UInt128 = (UInt128(h.state_hi) << 64) | UInt128(h.state_lo)

"Little-endian bytes of a `UInt128`, matching how upstream reinterprets a `&[u128]` as `&[u8]` on a little-endian target."
@inline function gx_u128_le_bytes(x::UInt128)
    b = Vector{UInt8}(undef, 16)
    @inbounds for k in 0:15
        b[k + 1] = UInt8((x >> (8k)) & 0xff)
    end
    b
end

"Little-endian bytes of a `UInt64` — same rationale."
@inline function gx_u64_le_bytes(x::UInt64)
    b = Vector{UInt8}(undef, 8)
    @inbounds for k in 0:7
        b[k + 1] = UInt8((x >> (8k)) & 0xff)
    end
    b
end

export GxHasher, gx_write!, gx_write_u8!, gx_write_u128!, gx_finish_u128,
       gx_u128_le_bytes, gx_u64_le_bytes
