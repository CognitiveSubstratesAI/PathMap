# test_bool_lattice.jl — the Bool lattice, pinned EXHAUSTIVELY against upstream.
#
# All four (a,b) inputs times three ops is twelve cases, so there is no reason to sample. Each
# expectation below was read off `impl Lattice for bool` (ring.rs:891-905) and
# `impl DistributiveLattice for bool` (ring.rs:881-889), not derived from what our code does.
#
# WHY THIS FILE EXISTS. Our Bool impl deliberately diverged, on the recorded grounds that upstream's
# was a `//GOAT trash` placeholder like its integer impls. It is not: the tags sit on `usize`, `u64`,
# `u32` and `u16` only, and upstream's bool section opens with a design NOTE explaining why bool DOES
# get a real default impl. The deviation was withdrawn 2026-07-31.
#
# Two things it was hiding, neither visible in the boolean results:
#
#   1. MASK WIDTH. Ours returned `Identity(SELF|COUNTER)` for equal operands where upstream returns
#      `Identity(SELF)`. Both are legal under the contract at ring.rs:16, but the mask is consumed by
#      `rec_mask & val_mask` (dense_byte_node.rs:1934) and `AlgebraicResult::merge`'s
#      `self_mask & b_mask` (ring.rs:254) — an extra bit survives those ANDs and a different arm
#      fires. Exactly the failure shape of upstream 2683d7c.
#   2. A VALUE difference at ONE input: `psubtract(false, true)` upstream keeps the stored `false`
#      (`Identity(SELF)`); ours returned `None` and deleted the entry.
#
# ⚠️ ASSERT THE MASK, NOT JUST THE VARIANT. A test that only checked "Identity vs None" passes on
# both versions and would have caught neither problem.
using PathMap, Test

@testset "Bool lattice is 1:1 with upstream (mask included)" begin
    I(m) = (r) -> r isa PathMap.AlgResIdentity && Int(r.mask) == m
    N = (r) -> r isa PathMap.AlgResNone

    # ring.rs:892  pjoin: `if !*self && *other { Identity(COUNTER_IDENT) } else { Identity(SELF_IDENT) }`
    @test I(1)(PathMap.pjoin(false, false))
    @test I(2)(PathMap.pjoin(false, true))     # result is `other`
    @test I(1)(PathMap.pjoin(true, false))
    @test I(1)(PathMap.pjoin(true, true))     # NOT 3 — upstream claims SELF only

    # ring.rs:899  pmeet: `if *self && !*other { Identity(COUNTER_IDENT) } else { Identity(SELF_IDENT) }`
    @test I(1)(PathMap.pmeet(false, false))
    @test I(1)(PathMap.pmeet(false, true))
    @test I(2)(PathMap.pmeet(true, false))    # result is `other`
    @test I(1)(PathMap.pmeet(true, true))     # NOT 3

    # ring.rs:882  psubtract: `if *self == *other { None } else { Identity(SELF_IDENT) }`
    @test N(PathMap.psubtract(false, false))
    @test I(1)(PathMap.psubtract(false, true))  # ← was None: the entry used to be DELETED
    @test I(1)(PathMap.psubtract(true, false))
    @test N(PathMap.psubtract(true, true))

    # The INTEGER divergence is genuinely deliberate and STAYS — upstream's u64 impl really is tagged
    # `//GOAT trash` (ring.rs:836) and returns Identity(SELF) unconditionally, ignoring its operands.
    # Pinned here so the two cases are not confused with each other again.
    @test PathMap.pjoin(UInt64(3), UInt64(9)) isa PathMap.AlgResIdentity
    @test Int(PathMap.pjoin(UInt64(3), UInt64(9)).mask) == 2      # ours: real max -> COUNTER
    @test Int(PathMap.pmeet(UInt64(3), UInt64(9)).mask) == 1      # ours: real min -> SELF
end
