"""
Utils — port of `pathmap/src/utils/mod.rs`.

Contains:
  - `BitMask` trait — generic bitmask operations
  - `ByteMask` — 256-bit fixed-size mask (= `[UInt64; 4]`)
  - `ByteMaskIter` — destructive iterator over set bytes
  - Lattice / DistributiveLattice impls on `[UInt64; 4]` and `ByteMask`
  - Integer utilities (submodule `ints`) — ported separately

1:1 port of upstream behavior, with Julia-native method dispatch replacing
Rust traits. Layout matches: `ByteMask` is a wrapper around a 4-element
UInt64 tuple; Sierpinski-subset table is computed once at module load.
"""

# =====================================================================
# BitMask — generic trait-equivalent
# =====================================================================
#
# Rust: `pub trait BitMask { fn count_bits(&self) -> usize; ... }`
# Julia: a set of generic functions dispatched on type. No abstract
# type needed — users call `count_bits(m)` and dispatch finds the impl.

"""
    count_bits(mask) -> Int

Returns the number of set bits. Port of `BitMask::count_bits`.
"""
function count_bits end

"""
    is_empty_mask(mask) -> Bool

Returns true iff all bits are clear. Port of `BitMask::is_empty_mask`.
"""
function is_empty_mask end

"""
    test_bit(mask, k::UInt8) -> Bool

Returns true iff bit `k` is set. Port of `BitMask::test_bit`.
"""
function test_bit end

"""
    set_bit(mask, k::UInt8)

Set bit `k` (mutates `mask` for mutable types; see immutable overloads
for non-mutating variants). Port of `BitMask::set_bit`.
"""
function set_bit end

"""
    clear_bit(mask, k::UInt8)
"""
function clear_bit end

"""
    make_empty(mask)

Clear all bits.
"""
function make_empty end

"""
    bor(a, b) -> same type

Bitwise OR of two masks (non-mutating). Named `bor` to avoid
collision with Julia's `Base.|`. Port of `BitMask::or`.
"""
function bor end

"""
    band(a, b) -> same type

Bitwise AND. Port of `BitMask::and`.
"""
function band end

"""
    bxor(a, b) -> same type

Bitwise XOR. Port of `BitMask::xor`.
"""
function bxor end

"""
    bandn(a, b) -> same type

Bitwise `and-not`: `a & !b`. Port of `BitMask::andn`.
"""
function bandn end

"""
    bnot(a) -> same type

Bitwise NOT. Port of `BitMask::not`.
"""
function bnot end

# =====================================================================
# BitMask impl on NTuple{4, UInt64} (= upstream's [u64; 4])
# =====================================================================

# In Rust, `[u64; 4]` is the natural backing for ByteMask. In Julia we
# use `NTuple{4, UInt64}` — stack-allocated, immutable, isbits — for the
# same role. Methods on the tuple implement the BitMask surface directly.

const Bits4 = NTuple{4, UInt64}

const EMPTY_BITS4::Bits4 = (UInt64(0), UInt64(0), UInt64(0), UInt64(0))
const FULL_BITS4::Bits4 = (
    typemax(UInt64), typemax(UInt64), typemax(UInt64), typemax(UInt64)
)

@inline count_bits(m::Bits4)::Int =
    Int(count_ones(m[1]) + count_ones(m[2]) + count_ones(m[3]) + count_ones(m[4]))

@inline is_empty_mask(m::Bits4)::Bool = m[1] == 0 && m[2] == 0 && m[3] == 0 && m[4] == 0

@inline function test_bit(m::Bits4, k::UInt8)::Bool
    idx = ((k & 0xC0) >> 6) + 1          # 1-indexed word
    bit_i = k & 0x3F
    return (m[idx] & (UInt64(1) << bit_i)) > 0
end

# Mutating variants on Bits4 don't fit (tuples are immutable). The
# BitMask trait's mutating methods (set_bit, clear_bit, make_empty) are
# implemented on ByteMask (which wraps a mutable tuple). Here we expose
# non-mutating "returns new tuple" variants for use in algebra.

@inline function with_bit_set(m::Bits4, k::UInt8)::Bits4
    idx = (k >> 6) + 1                   # 1-indexed
    bit_pos = k & 0x3F
    one_at = UInt64(1) << bit_pos
    return ntuple(i -> i == idx ? m[i] | one_at : m[i], 4)
end

@inline function with_bit_cleared(m::Bits4, k::UInt8)::Bits4
    idx = (k >> 6) + 1
    bit_pos = k & 0x3F
    clear_at = ~(UInt64(1) << bit_pos)
    return ntuple(i -> i == idx ? m[i] & clear_at : m[i], 4)
end

@inline bor(a::Bits4, b::Bits4)::Bits4 = (a[1]|b[1], a[2]|b[2], a[3]|b[3], a[4]|b[4])
@inline band(a::Bits4, b::Bits4)::Bits4 = (a[1]&b[1], a[2]&b[2], a[3]&b[3], a[4]&b[4])
@inline bxor(a::Bits4, b::Bits4)::Bits4 = (a[1]⊻b[1], a[2]⊻b[2], a[3]⊻b[3], a[4]⊻b[4])
@inline bandn(a::Bits4, b::Bits4)::Bits4 = (a[1]&~b[1], a[2]&~b[2], a[3]&~b[3], a[4]&~b[4])
@inline bnot(a::Bits4)::Bits4 = (~a[1], ~a[2], ~a[3], ~a[4])

# Lattice + DistributiveLattice on Bits4 — upstream lines 633-653

"""
    _bitmask_algebraic_result(result::Bits4, self_mask::Bits4, other_mask::Bits4) -> AlgebraicResult{Bits4}

Helper: compose AlgebraicResult after an algebraic op on Bits4.
Matches upstream `bitmask_algebraic_result` (utils/mod.rs:656).
"""
function _bitmask_algebraic_result(
    result::Bits4, self_mask::Bits4, other_mask::Bits4
)::AlgebraicResult{Bits4}
    if is_empty_mask(result)
        return AlgResNone()
    end
    mask = UInt64(0)
    if result == self_mask
        mask = SELF_IDENT
    end
    if result == other_mask
        mask |= COUNTER_IDENT
    end
    if mask > 0
        return AlgResIdentity(mask)
    else
        return AlgResElement(result)
    end
end

# Lattice for Bits4
function pjoin(a::Bits4, b::Bits4)::AlgebraicResult{Bits4}
    r = bor(a, b)
    return _bitmask_algebraic_result(r, a, b)
end

function pmeet(a::Bits4, b::Bits4)::AlgebraicResult{Bits4}
    r = band(a, b)
    return _bitmask_algebraic_result(r, a, b)
end

# DistributiveLattice for Bits4
function psubtract(a::Bits4, b::Bits4)::AlgebraicResult{Bits4}
    r = bandn(a, b)
    return _bitmask_algebraic_result(r, a, b)
end

# =====================================================================
# ByteMask — 256-bit wrapper around Bits4
# =====================================================================

"""
    ByteMask

A 256-bit fixed-size mask. 1:1 port of `pathmap::utils::ByteMask`.

Wraps a `Bits4` (= `NTuple{4, UInt64}`). Immutable — set/clear/etc.
operations produce new `ByteMask` values (matches upstream semantics
where `ByteMask: Copy`).

Layout: `#[repr(transparent)]` in Rust. In Julia, a bits-compatible
`struct` with a single `Bits4` field.
"""
struct ByteMask
    bits::Bits4
end

"""
    ByteMask() -> ByteMask

Empty mask. Port of `ByteMask::new` / `ByteMask::EMPTY`.
"""
ByteMask() = ByteMask(EMPTY_BITS4)

"""
    bytemask_full() -> ByteMask

All 256 bits set. Port of `ByteMask::FULL`.
"""
bytemask_full() = ByteMask(FULL_BITS4)

"""
    ByteMask(b::UInt8) -> ByteMask

Singleton mask with only bit `b` set. Port of `impl From<u8> for ByteMask`.
"""
ByteMask(b::UInt8) = ByteMask(with_bit_set(EMPTY_BITS4, b))

"""
    ByteMask(bits::Bits4) -> ByteMask

Already covered by the default constructor.
"""

# Equality
Base.:(==)(a::ByteMask, b::ByteMask) = a.bits == b.bits
Base.:(==)(a::ByteMask, b::Bits4) = a.bits == b
Base.:(==)(a::Bits4, b::ByteMask) = a == b.bits
Base.hash(m::ByteMask, h::UInt) = hash(m.bits, h)

# =====================================================================
# ByteMask — Sierpinski SUBSET table
# =====================================================================

"""
    SUBSET_TABLE

Precomputed table: `SUBSET_TABLE[i+1]` is the ByteMask containing all
`j` in `0..256` such that `i & j == j` (i.e., `j` is a "subset of bits
of i"). Port of upstream `ByteMask::SUBSET`.

Used by `subset(b)` to produce the nth row of the Sierpinski triangle
mask. Built once at module load (matches upstream's `const` table).
"""
const SUBSET_TABLE::NTuple{256, ByteMask} = let
    tbl = Vector{ByteMask}(undef, 256)
    for i in 0:255
        bits = EMPTY_BITS4
        for j in 0:255
            if (i & j) == j
                bits = with_bit_set(bits, UInt8(j))
            end
        end
        tbl[i + 1] = ByteMask(bits)
    end
    Tuple(tbl)
end

"""
    subset(b::UInt8) -> ByteMask

The `b`-th row of the Sierpinski triangle: mask of every `j` such that
`b & j == j`. Port of `ByteMask::subset`.
"""
@inline subset(b::UInt8)::ByteMask = @inbounds SUBSET_TABLE[Int(b) + 1]

# =====================================================================
# ByteMask — from_range
# =====================================================================

"""
    from_range(range) -> ByteMask

Build a `ByteMask` with all bits in the given range set. Port of
`ByteMask::from_range`.

Accepts `UnitRange{Int}` or any range with `Int`-compatible start/stop.
The range is interpreted over `[0, 256)`. Empty or inverted ranges
produce an empty mask.
"""
function from_range(range::AbstractRange)::ByteMask
    start = first(range)
    # stop is inclusive for Julia UnitRange — translate to Rust's exclusive end
    stop_incl = last(range)
    if isempty(range) || start > stop_incl
        return ByteMask()
    end
    start_i = Int(start)
    end_i = Int(stop_incl)   # inclusive
    if start_i < 0
        ;
        start_i = 0;
    end
    if end_i > 255
        ;
        end_i = 255;
    end
    start_i > end_i && return ByteMask()

    start_word = start_i >> 6
    end_word = end_i >> 6
    start_bit = start_i & 0x3F
    end_bit = end_i & 0x3F

    m = [UInt64(0), UInt64(0), UInt64(0), UInt64(0)]
    if start_word == end_word
        len = end_bit - start_bit + 1
        m[start_word + 1] = (typemax(UInt64) >> (64 - len)) << start_bit
    else
        m[start_word + 1] = typemax(UInt64) << start_bit
        for w in (start_word + 1):(end_word - 1)
            m[w + 1] = typemax(UInt64)
        end
        m[end_word + 1] = typemax(UInt64) >> (63 - end_bit)
    end
    return ByteMask((m[1], m[2], m[3], m[4]))
end

"""
    from_range_full() -> ByteMask

Equivalent to Rust's `ByteMask::from_range(..)` (unbounded both sides).
Returns a full 256-bit mask.
"""
from_range_full() = bytemask_full()

# =====================================================================
# ByteMask — scalar queries (BitMask trait impl)
# =====================================================================

@inline count_bits(m::ByteMask)::Int = count_bits(m.bits)
@inline is_empty_mask(m::ByteMask)::Bool = is_empty_mask(m.bits)
@inline test_bit(m::ByteMask, k::UInt8)::Bool = test_bit(m.bits, k)

"""
    set(m::ByteMask, k::UInt8) -> ByteMask

Return a new mask with bit `k` set.
"""
@inline set(m::ByteMask, k::UInt8)::ByteMask = ByteMask(with_bit_set(m.bits, k))

"""
    unset(m::ByteMask, k::UInt8) -> ByteMask

Return a new mask with bit `k` cleared.
"""
@inline unset(m::ByteMask, k::UInt8)::ByteMask = ByteMask(with_bit_cleared(m.bits, k))

# Bitwise ops produce new ByteMasks
bor(a::ByteMask, b::ByteMask)::ByteMask = ByteMask(bor(a.bits, b.bits))
band(a::ByteMask, b::ByteMask)::ByteMask = ByteMask(band(a.bits, b.bits))
bxor(a::ByteMask, b::ByteMask)::ByteMask = ByteMask(bxor(a.bits, b.bits))
bandn(a::ByteMask, b::ByteMask)::ByteMask = ByteMask(bandn(a.bits, b.bits))
bnot(a::ByteMask)::ByteMask = ByteMask(bnot(a.bits))

# Julia stdlib operator overloading for user-convenience
Base.:(|)(a::ByteMask, b::ByteMask) = bor(a, b)
Base.:(&)(a::ByteMask, b::ByteMask) = band(a, b)
Base.xor(a::ByteMask, b::ByteMask) = bxor(a, b)
Base.:(~)(a::ByteMask) = bnot(a)

# =====================================================================
# ByteMask — unwrap
# =====================================================================

"""
    into_inner(m::ByteMask) -> Bits4

Return the underlying 4-tuple. Port of `ByteMask::into_inner`.
"""
@inline into_inner(m::ByteMask)::Bits4 = m.bits

# =====================================================================
# ByteMask — rank / select / successor / predecessor
# =====================================================================

"""
    index_of(m::ByteMask, byte::UInt8) -> UInt8

Return the count of set bits strictly below `byte`. Port of
`ByteMask::index_of`.
"""
function index_of(m::ByteMask, byte::UInt8)::UInt8
    byte == 0 && return UInt8(0)
    b = m.bits
    count = UInt32(0)
    submask = typemax(UInt64) >> (63 - ((byte - UInt8(1)) & 0x3F))
    # Unroll by word
    if byte <= 0x40
        return UInt8(count_ones(b[1] & submask) + count)
    end
    count += count_ones(b[1])
    if byte <= 0x80
        return UInt8(count_ones(b[2] & submask) + count)
    end
    count += count_ones(b[2])
    if byte <= 0xC0
        return UInt8(count_ones(b[3] & submask) + count)
    end
    count += count_ones(b[3])
    return UInt8(count_ones(b[4] & submask) + count)
end

"""
    indexed_bit(m::ByteMask, idx::Int, forward::Bool) -> Union{UInt8, Nothing}

Return the byte corresponding to the `idx`-th set bit (0-based), counting
forward (from bit 0) or backward (from bit 255). Port of
`ByteMask::indexed_bit<FORWARD>`.
"""
function indexed_bit(m::ByteMask, idx::Int, forward::Bool)::Union{UInt8, Nothing}
    b = m.bits
    idx < 0 && return nothing

    if forward
        i = 1
        word = b[i]
        c_ahead = Int(count_ones(word))
        c = 0
        while idx >= c_ahead
            i += 1
            i > 4 && return nothing
            word = b[i]
            c = c_ahead
            c_ahead += Int(count_ones(word))
        end
        # Consume bits in the current word until we reach idx
        loc = Int(trailing_zeros(word))
        while c < idx
            word ⊻= UInt64(1) << loc
            loc = Int(trailing_zeros(word))
            c += 1
        end
        byte_val = ((i - 1) << 6) | loc
        return UInt8(byte_val)
    else
        i = 4
        word = b[i]
        c_ahead = Int(count_ones(word))
        c = 0
        while idx >= c_ahead
            i -= 1
            i < 1 && return nothing
            word = b[i]
            c = c_ahead
            c_ahead += Int(count_ones(word))
        end
        loc = Int(63 - leading_zeros(word))
        while c < idx
            word ⊻= UInt64(1) << loc
            loc = Int(63 - leading_zeros(word))
            c += 1
        end
        byte_val = ((i - 1) << 6) | loc
        return UInt8(byte_val)
    end
end

"""
    next_bit(m::ByteMask, byte::UInt8) -> Union{UInt8, Nothing}

Return the smallest bit > `byte` that is set, or `nothing` if none.
Port of `ByteMask::next_bit`.
"""
function next_bit(m::ByteMask, byte::UInt8)::Union{UInt8, Nothing}
    byte == 0xFF && return nothing
    start = byte + UInt8(1)
    word_idx = Int(start >> 6)                 # 0..3
    mod_idx = Int(start & 0x3F)
    b = m.bits
    submask = typemax(UInt64) << mod_idx

    if word_idx == 0
        cnt = trailing_zeros(b[1] & submask)
        if cnt < 64
            return UInt8(cnt)
        end
        submask = typemax(UInt64)
    end
    if word_idx < 2
        cnt = trailing_zeros(b[2] & submask)
        if cnt < 64
            return UInt8(64 + cnt)
        end
        if word_idx == 1
            submask = typemax(UInt64)
        end
    end
    if word_idx < 3
        cnt = trailing_zeros(b[3] & submask)
        if cnt < 64
            return UInt8(128 + cnt)
        end
        if word_idx == 2
            submask = typemax(UInt64)
        end
    end
    cnt = trailing_zeros(b[4] & submask)
    if cnt < 64
        return UInt8(192 + cnt)
    end
    return nothing
end

"""
    prev_bit(m::ByteMask, byte::UInt8) -> Union{UInt8, Nothing}

Return the largest bit < `byte` that is set, or `nothing` if none.
Port of `ByteMask::prev_bit`.
"""
function prev_bit(m::ByteMask, byte::UInt8)::Union{UInt8, Nothing}
    byte == 0 && return nothing
    start = byte - UInt8(1)
    word_idx = Int(start >> 6)
    mod_idx = Int(start & 0x3F)
    b = m.bits
    submask = typemax(UInt64) >> (63 - mod_idx)

    if word_idx == 3
        cnt = leading_zeros(b[4] & submask)
        if cnt < 64
            return UInt8(255 - cnt)
        end
        submask = typemax(UInt64)
    end
    if word_idx > 1
        cnt = leading_zeros(b[3] & submask)
        if cnt < 64
            return UInt8(191 - cnt)
        end
        if word_idx == 2
            submask = typemax(UInt64)
        end
    end
    if word_idx > 0
        cnt = leading_zeros(b[2] & submask)
        if cnt < 64
            return UInt8(127 - cnt)
        end
        if word_idx == 1
            submask = typemax(UInt64)
        end
    end
    cnt = leading_zeros(b[1] & submask)
    if cnt < 64
        return UInt8(63 - cnt)
    end
    return nothing
end

# =====================================================================
# ByteMaskIter — iterator over set bits, destructive
# =====================================================================

"""
    ByteMaskIter

Iterator over set bits in ascending order. 1:1 port of upstream
`ByteMaskIter`. Destructive: mutates its internal mask copy as bits are
consumed.

Julia iterator protocol: `iterate(it::ByteMaskIter, state=nothing)`
returns `(byte::UInt8, nothing)` per step or `nothing` when exhausted.
"""
mutable struct ByteMaskIter
    i::UInt8
    mask::Vector{UInt64}   # mutable; destructive consume

    ByteMaskIter(bits::Bits4) = new(UInt8(0), UInt64[bits[1], bits[2], bits[3], bits[4]])
end

"""
    iter(m::ByteMask) -> ByteMaskIter

Build a `ByteMaskIter` from a `ByteMask`. Port of `ByteMask::iter`.
"""
iter(m::ByteMask)::ByteMaskIter = ByteMaskIter(m.bits)

# Julia iterator protocol
Base.IteratorSize(::Type{ByteMaskIter}) = Base.SizeUnknown()
Base.eltype(::Type{ByteMaskIter}) = UInt8

function _bytemask_iter_next!(it::ByteMaskIter)::Union{UInt8, Nothing}
    while true
        i1 = Int(it.i) + 1                  # 1-indexed
        w = @inbounds it.mask[i1]
        if w != 0
            wi = trailing_zeros(w)
            @inbounds it.mask[i1] = w ⊻ (UInt64(1) << wi)
            return UInt8((Int(it.i) << 6) | wi)
        elseif it.i < 3
            it.i += UInt8(1)
        else
            return nothing
        end
    end
end

function Base.iterate(it::ByteMaskIter, state=nothing)
    nxt = _bytemask_iter_next!(it)
    nxt === nothing && return nothing
    return (nxt, nothing)
end

# ByteMask directly iterable — ascending order
Base.IteratorSize(::Type{ByteMask}) = Base.HasLength()
Base.eltype(::Type{ByteMask}) = UInt8
Base.length(m::ByteMask) = count_bits(m)
function Base.iterate(m::ByteMask, state::Tuple{Int, UInt64} = (1, @inbounds m.bits[1]))
    # ctz word-walk (non-destructive): O(popcount) per full pass, not O(256).
    # Mirrors next_bit / ByteMaskIter (trailing_zeros + clear-lowest-set-bit),
    # non-allocating, ascending byte order. Replaces a 256-way linear test_bit
    # scan that did a runtime Bits4-tuple index each step (the exec-loop hot leaf).
    wi, w = state
    b = m.bits
    while w == UInt64(0)
        wi >= 4 && return nothing
        wi += 1
        w = wi == 2 ? b[2] : (wi == 3 ? b[3] : b[4])   # static word indices only
    end
    tz = trailing_zeros(w)
    byte = UInt8(((wi - 1) << 6) | tz)
    return (byte, (wi, w & (w - UInt64(1))))           # clear lowest set bit, resume
end

# =====================================================================
# ByteMask — Lattice + DistributiveLattice (delegates to Bits4 impls)
# =====================================================================

function pjoin(a::ByteMask, b::ByteMask)::AlgebraicResult{ByteMask}
    r = pjoin(a.bits, b.bits)
    Base.map(ByteMask, r)
end

function pmeet(a::ByteMask, b::ByteMask)::AlgebraicResult{ByteMask}
    r = pmeet(a.bits, b.bits)
    Base.map(ByteMask, r)
end

function psubtract(a::ByteMask, b::ByteMask)::AlgebraicResult{ByteMask}
    r = psubtract(a.bits, b.bits)
    Base.map(ByteMask, r)
end

# =====================================================================
# Show
# =====================================================================

function Base.show(io::IO, m::ByteMask)
    n = count_bits(m)
    print(io, "ByteMask(", n, " set")
    if 0 < n <= 8
        bits = UInt8[]
        for b in m
            push!(bits, b)
        end
        print(io, ": ", join(string.(bits), ", "))
    end
    print(io, ")")
end

# =====================================================================
# Exports
# =====================================================================

export Bits4, EMPTY_BITS4, FULL_BITS4
export with_bit_set, with_bit_cleared
export count_bits, is_empty_mask, test_bit, set_bit, clear_bit, make_empty
export bor, band, bxor, bandn, bnot

export ByteMask, bytemask_full
export subset, from_range, from_range_full, into_inner
export index_of, indexed_bit, next_bit, prev_bit
export set, unset
export ByteMaskIter, iter
