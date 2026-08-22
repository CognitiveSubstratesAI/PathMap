# test_restrict.jl — `restrict` pinned against the upstream Rust engine's OWN answers.
#
# WHAT THIS CAUGHT. `LineListNode::prestrict_dyn` used to upgrade `self` to a DenseByteNode
# (`merge_from_list_node!`) and delegate to `ByteNode::prestrict`. That is not a refactor of the
# same computation — the two disagree on IDENTITY:
#
#   * `ByteNode::prestrict` (dense_byte_node.rs:2342) tests identity by MASK EQUALITY:
#     `is_identity = self.mask == mm && other.mask == mm`, which ALSO requires `other` to carry
#     exactly `self`'s set of child bytes.
#   * Upstream's LineList path (line_list_node.rs:2718) tests identity PER SLOT: a slot is
#     Identity when the restriction removed nothing FROM THAT SLOT, regardless of what else
#     `other` holds.
#
# Restrict is non-commutative — `A restrict S` keeps the paths of A that S covers — so surplus
# paths in S cannot make A's answer "changed". The dense test folded them in anyway, so
# `{a,b} restrict {a,b,c}` returned Element where upstream returns Identity.
#
# ⚠️ THE TRIE CONTENTS WERE ALREADY CORRECT IN EVERY DIVERGENT CASE — only the returned
# `AlgebraicStatus` differed. That is exactly why it survived: a test asserting the dump alone
# passes on the broken version. It is not cosmetic, because the standard saturation idiom is
# "loop until Identity", and a permanent Element never terminates. So: ASSERT THE STATUS, and
# assert it against upstream rather than against what our code happens to do.
#
# WHY THE THREE AGREEING CASES ARE IN HERE. `{a,b} restrict {a,b}` (nothing surplus in S),
# `{a,b} restrict {a}` (a genuine Element) and `{a,b,c} restrict {a,b,c,d}` (self has 3 slots, so
# self is a DENSE node and never touches the LineList path) are the CONTROLS that localise the
# defect. They pinned the bug to the LineList branch specifically: whatever the fix, the dense
# path and the genuinely-changed answers had to keep their existing values. Remove them and a
# future change that "fixes" restrict by making everything Identity would still look green.
#
# PROVENANCE OF EVERY EXPECTED STRING: `gen_fuzz --exec` run against the upstream checkout at
# git 52fd9df (test/differential/rust_probe depends on it by path). These are the Rust engine's
# bytes, not our output recorded after the fact. Regenerate with:
#   printf 'A a b\nS a b c\nOP RESTRICT\n' > /tmp/rc/case.txt
#   test/differential/rust_probe/target/release/gen_fuzz --exec /tmp/rc
#
# Note `OP RESTRICT` is `--exec`-only — the corpus generator never emits it, which is why
# `restrict` had no differential coverage at all before this file.
#
# ✅ PROVENANCE RE-VERIFIED 2026-08-01, mechanically rather than by trusting the note above: every
# script here was extracted from this file, replayed through `gen_fuzz --exec`, and diffed against
# its expected string. All matched. Worth doing because the failure mode is silent — an expectation
# transcribed from OUR output instead of the binary's would pin the port to itself and still look
# green forever.
#
# ✅ AND THE RECURSIVE BRANCH IS ACTUALLY REACHED, also measured rather than assumed. Wrapping
# `prestrict_dyn` in a depth counter shows `A={a,b}` (the shape the defect was first found with)
# reaches nesting depth 1 — a slot holding a VALUE bails at `_lln_is_child` and never recurses —
# while `A={aa,ab,b}` and `A={a:b,a::,b}` reach depth 2. A suite built only from the first shape
# would leave `_lln_restrict_slot_contents`' whole recursive arm unexecuted.
using Test

# run_fuzz.jl gives us the harness that BOTH engines drive, so the expectations below are
# upstream's stdout verbatim. fuzz_gate.jl includes the same file; guard so the second include
# is a no-op rather than a wholesale method redefinition.
isdefined(@__MODULE__, :fuzz_run_text) ||
    include(joinpath(@__DIR__, "differential", "run_fuzz.jl"))

# (name, script, upstream answer). Script grammar: `A`/`S` = the two key sets, `AROOTVAL`/
# `SROOTVAL` = a value at the empty path, `ORIGIN` = where the write zipper starts, `OP` = an op.
const _RESTRICT_CASES = Tuple{String, String, String}[
    # ── the defect: LineList self, S a strict superset ───────────────────────────────────────
    ("{a,b} ⊑ {a,b,c}", "A a b\nS a b c\nOP RESTRICT\n", "Identity;|[a,b] vc=2"),
    ("{a,b} ⊑ {a,b,c,d,e}", "A a b\nS a b c d e\nOP RESTRICT\n", "Identity;|[a,b] vc=2"),
    (
        "{aa,ab} ⊑ {aa,ab,ac}",
        "A aa ab\nS aa ab ac\nOP RESTRICT\n",
        "Identity;|[aa,ab] vc=2"
    ),

    # ── controls: these AGREED before the fix and must not move ──────────────────────────────
    ("control: S exactly equal", "A a b\nS a b\nOP RESTRICT\n", "Identity;|[a,b] vc=2"),
    ("control: DENSE self (3 slots)", "A a b c\nS a b c d\nOP RESTRICT\n",
        "Element;|[a,b,c] vc=3"),
    ("control: genuine Element", "A a b\nS a\nOP RESTRICT\n", "Element;|[a] vc=1"),

    # ── coverage of the paths the per-slot port introduced ───────────────────────────────────
    # `_lln_restrict_slot_contents` early-outs, `_follow_path_to_value`'s three answers, and
    # `_lln_combine_slot_results_into_node_result`'s four arms.
    (
        "one slot survives, one dies",
        "A aa ab ba\nS aa ba\nOP RESTRICT\n",
        "Element;|[aa,ba] vc=2"
    ),
    ("child slot, S superset below", "A abc abd\nS abc abd abe\nOP RESTRICT\n",
        "Identity;|[abc,abd] vc=2"),
    (
        "S holds a VALUE above the path",
        "A abc abd\nS ab\nOP RESTRICT\n",
        "Identity;|[abc,abd] vc=2"
    ),
    ("S only continues past self", "A abc abd\nS abcd\nOP RESTRICT\n", "None;|[] vc=0"),
    ("disjoint ⇒ None", "A a\nS b\nOP RESTRICT\n", "None;|[] vc=0"),
    ("dense self, S subset", "A a b c d e f\nS a b\nOP RESTRICT\n", "Element;|[a,b] vc=2"),
    (
        "S root value ignored",
        "A a b\nS a b c\nSROOTVAL 1\nOP RESTRICT\n",
        "Identity;|[a,b] vc=2"
    ),
    (
        "A root value survives",
        "A a b\nAROOTVAL 1\nS a b c\nOP RESTRICT\n",
        "Identity;|[a,b] vc=3"
    ),
    ("dense below a shared prefix", "A abc abd abe\nS abc abd abe abf\nOP RESTRICT\n",
        "Element;|[abc,abd,abe] vc=3"),
    ("two levels, half kept", "A aaa aab aba abb\nS aaa abb\nOP RESTRICT\n",
        "Element;|[aaa,abb] vc=2"),
    (
        "self is a prefix of S's only path",
        "A abc\nS abcdef\nOP RESTRICT\n",
        "None;|[] vc=0"
    ),
    ("origin below root, S unshifted", "A ab ac\nS ab ac ad\nORIGIN a\nOP RESTRICT\n",
        "None;|[] vc=0"),
    ("origin below root, S shifted", "A ab ac\nS b c d\nORIGIN a\nOP RESTRICT\n",
        "Identity;|[ab,ac] vc=2"),
    ("keys longer than KEY_BYTES_CNT",
        "A abcdefgh abcdefgi\nS abcdefgh abcdefgi abcdefgj\nOP RESTRICT\n",
        "Identity;|[abcdefgh,abcdefgi] vc=2"),
    # The saturation idiom the Element-forever bug broke: the SECOND restrict must also say
    # Identity, which is the whole reason the status matters.
    ("idempotent — twice ⇒ Identity twice", "A a b\nS a b c\nOP RESTRICT\nOP RESTRICT\n",
        "Identity;Identity;|[a,b] vc=2"),
    ("value slot under a covering path", "A ab\nS a\nOP RESTRICT\n", "Identity;|[ab] vc=1"),
    (
        "value + child at the same key",
        "A a ab\nS a\nOP RESTRICT\n",
        "Identity;|[a,ab] vc=2"
    ),
    (
        "value + child, only child covered",
        "A a ab\nS ab\nOP RESTRICT\n",
        "Element;|[ab] vc=1"
    ),

    # ── added 2026-08-01 while re-verifying the port: shapes the set above did not reach ──────
    # An EMPTY `other` is the one input that exercises `_lln_restrict_slot_contents`'s
    # `onward === nothing` exit for BOTH slots at once, and it is also the arm where the new
    # `prestrict_dyn` no longer dispatches on `node_tag` — an EmptyNode now falls out as
    # (None, None) rather than hitting the old `error`.
    ("empty S ⇒ None", "A a b\nS \nOP RESTRICT\n", "None;|[] vc=0"),
    # S carries ONLY a root value. `restrict` takes no root value (upstream's signature has no
    # such parameter), so the root value must not rescue anything.
    ("S root value only ⇒ None", "A a b\nS \nSROOTVAL 1\nOP RESTRICT\n", "None;|[] vc=0"),
    # ':' (0x3a) sorts BELOW 'a'/'b', so these exercise slot ordering and multi-byte node keys
    # together — the `should_swap_keys` invariant, not just the algebra.
    ("':' alphabet, equal", "A a:b a:: b\nS a:b a:: b\nOP RESTRICT\n",
        "Identity;|[a::,a:b,b] vc=3"),
    (
        "':' alphabet, partial",
        "A a:b a:: b\nS a:b b\nOP RESTRICT\n",
        "Element;|[a:b,b] vc=2"
    )
]

@testset "restrict is 1:1 with upstream (STATUS, not just contents)" begin
    for (name, script, want) in _RESTRICT_CASES
        # invokelatest: run_fuzz.jl's methods may have been defined inside this running suite.
        got = Base.invokelatest(fuzz_run_text, script)
        @test (name, got) == (name, want)
    end
end
