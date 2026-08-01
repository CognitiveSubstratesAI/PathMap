# test_value_algebra.jl — value-PAYLOAD algebra, pinned against the upstream Rust engine.
#
# THE GAP THIS CLOSES. The 3000-case fuzz corpus uses UNIT values, deliberately (run_fuzz.jl's
# header explains why: our integer lattice diverges from upstream's `//GOAT trash` placeholder by
# design, so fuzzing u64 would bury real findings under an intended one). The stated limitation was
# that it covers value PRESENCE/ABSENCE but not value-PAYLOAD algebra.
#
# That was not academic. Upstream commit `2683d7c` changed WHICH OPERAND's value survives a meet:
#
#     dense_byte_node.rs:1921   - AlgebraicResult::Element(Self::new(None, self.val().cloned()))
#                               + let val = if val_mask & SELF_IDENT > 0 { self.val() } else { other.val() };
#
# Under `()` the two operands are INDISTINGUISHABLE, so nothing anywhere could tell the two versions
# apart — we ported that hunk blind, and so did upstream: its own regression test for the commit
# builds a `PathMap<()>`.
#
# ── HOW THE TWO ENGINES ARE MADE COMPARABLE ──────────────────────────────────────────────────────
# A `VT bits` header switches both harnesses to `Bits(u64)` / `FBits`, a BITSET with join = `|`,
# meet = `&`, subtract = `& !`. It is defined in the PROBE, not in either library, so:
#   * the two engines agree BY CONSTRUCTION rather than by an argument about lattices, and
#   * the documented integer divergence in src/core/Ring.jl is not involved at all.
# `bool` was considered and rejected — upstream's `impl Lattice for bool` returns `Identity(SELF)`
# for equal operands where a natural port returns `Identity(SELF|COUNTER)`, and the mask WIDTH is
# observable downstream. That difference was a real defect of ours (fixed in `de5a5b2`), which is
# precisely why it disqualifies bool as the *shared* probe type.
#
# `VT` is never emitted by the generator, so `expected.tsv`, `cases.txt` and the 30-case ratchet are
# untouched — verified by regenerating the corpus and diffing: byte-identical.
#
# ── THE ACCEPTANCE RESULT, MEASURED ──────────────────────────────────────────────────────────────
# `v1` below is not just another passing case; it is the one that proves this file has teeth.
# Reverting `2683d7c`'s val hunk in DenseByteNode.jl:432 (`? a.val : b.val` -> `a.val`) and re-running:
#
#     with the fix      [:=5,a=1,b=5]      == upstream
#     hunk reverted     [:=5,a=3,b=5]      the WRONG operand's value survives
#
# One line, one character-level decision, and the dump moves. Note the TRACE says `Element` in both
# variants — the DUMP is the discriminator, so a harness that rendered values only in the trace
# would have missed it.
#
# PROVENANCE: every expected string below is `gen_fuzz --exec` output against the upstream checkout
# at 52fd9df, not our output recorded after the fact.
using Test

isdefined(@__MODULE__, :fuzz_run_text) ||
    include(joinpath(@__DIR__, "differential", "run_fuzz.jl"))

const _VALUE_CASES = Tuple{String, String, String}[
    # ── THE ACCEPTANCE CASE ──────────────────────────────────────────────────────────────────────
    # Three distinct first bytes => dense root on both sides. Key `a` holds 3 in A and 1 in S;
    # 3 & 1 = 1, so the surviving value must come from the SECOND operand. Under `()` this case
    # cannot fail. `a:` in S (and not in A) is what forces the CoFree for 'a' to hold a value AND
    # an onward link, i.e. the exact shape 2683d7c is about.
    ("meet picks the operand the MASK names, not `self`",
     "VT bits\nA :=5 a=3 ab=5 b=5\nAROOTVAL 0\nS :=5 a=1 a:=5 b=5\nSROOTVAL 0\nORIGIN -\nOP MEET 0\n",
     "Element;|[:=5,a=1,b=5] vc=3"),

    # ── the three ops, with payloads that actually merge ──────────────────────────────────────────
    ("join unions the bitsets", "VT bits\nA a=3 b=c\nAROOTVAL 0\nS a=5 b=3\nSROOTVAL 0\nORIGIN -\nOP JOINMAP\n",
     "Element;|[a=7,b=f] vc=2"),
    ("subtract clears the shared bits; b's value annihilates",
     "VT bits\nA a=7 b=3\nAROOTVAL 0\nS a=5 b=3\nSROOTVAL 0\nORIGIN -\nOP SUB 0\n",
     "Element;|[a=2] vc=1"),
    ("SETVAL takes its argument as the payload",
     "VT bits\nA a=3\nAROOTVAL 0\nS \nSROOTVAL 0\nORIGIN -\nOP DESCEND a\nOP SETVAL c\n",
     "-;true;|[a=c] vc=1"),

    # ── CONTROL: no VT header ⇒ the unit path, byte-identical to before this file existed ─────────
    # Without this a future change could silently switch the DEFAULT value type and every generated
    # case would start comparing something other than what expected.tsv was built from.
    ("no VT header still runs the UNIT path",
     "A a b\nAROOTVAL 0\nS a\nSROOTVAL 0\nORIGIN -\nOP MEET 0\n", "Element;|[a] vc=1"),
]

@testset "value-payload algebra is 1:1 with upstream (VT bits)" begin
    for (name, script, want) in _VALUE_CASES
        got = Base.invokelatest(fuzz_run_text, script)
        @test (name, got) == (name, want)
    end

    @testset "an unknown VT ABORTS rather than silently running as unit" begin
        # The failure mode this whole feature is most likely to die of: a typo'd header falls
        # through to `()`, every value renders as "", and both engines agree on a dump that tested
        # nothing. Both parsers hard-error instead; this pins the Julia half.
        @test_throws ErrorException Base.invokelatest(
            fuzz_run_text, "VT bytes\nA a=3\nAROOTVAL 0\nS \nSROOTVAL 0\nORIGIN -\nOP SETVAL\n")
    end

    @testset "a value token under the UNIT path is an error, not a silent drop" begin
        # `A a=3` with no `VT bits` would otherwise create the key "a=3" — a path containing '=' —
        # and quietly test nothing about values.
        @test_throws ErrorException Base.invokelatest(
            fuzz_run_text, "A a=3\nAROOTVAL 0\nS \nSROOTVAL 0\nORIGIN -\nOP SETVAL\n")
    end
end
