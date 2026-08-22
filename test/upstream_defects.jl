# upstream_defects.jl — the UPSTREAM defects we deliberately do not reproduce.
#
# Each was reduced to a minimal reproducer and written up in `test/differential/UPSTREAM_BUGS.md`.
# The fuzz corpus scores them as "we have MORE atoms than upstream", which is the CORRECT side to be
# on: upstream silently loses data in all of them.
#
# WHY A SEPARATE FILE FROM THE FUZZ RATCHET. `KNOWN_DIVERGENT.txt` records THAT 34 cases differ; it
# does not record WHY, and a ratchet cannot tell "upstream is wrong" from "we regressed". These
# assert the SEMANTICS directly, so if a future change makes us match upstream's data loss, this goes
# red with a reason attached rather than the ratchet silently going green.
#
# ⚠️ These assert OUR behaviour, which is the CORRECT behaviour. Do not "fix" them toward upstream.
#
# 🔴 2026-07-31 — "MORE ATOMS THAN UPSTREAM" DOES NOT MEAN WE ARE RIGHT, and reading it that way hid
# three defects OF OURS for a whole triage cycle. The corpus was classified by comparing `vc=`, and
# the class labelled OVER-RETENTION was assumed to be upstream losing data. Shrinking every case to a
# minimal reproducer showed 31 of 34 really are upstream's — and 3 are ours, one of them a plainly
# wrong ANSWER (`meet` returning its input unchanged). Attribution has to be established per case;
# it cannot be inferred from which side has more atoms. See `fuzz/TRIAGE.md`.
using PathMap, Test

include(joinpath(@__DIR__, "differential", "run_fuzz.jl"))

const _DEFECT_TRACE = get(ENV, "PM_DEFECT_TRACE", "1") != "0"

"Run a fuzz script, print a trace, return the `trace|dump` string."
function _defect_run(tag::String, script::String)
    out = fuzz_run_text(script)
    if _DEFECT_TRACE
        prog = join(["      " * l for l in split(strip(script), "\n")], "\n")
        println("\n  ── $tag ──\n$prog\n       => $out")
    end
    out
end

_atoms(out) =
    if (m = match(r"\|\[(.*?)\] vc=", out)) === nothing
        String[]
    else
        (isempty(m.captures[1]) ? String[] : sort(String.(split(m.captures[1], ","))))
    end

@testset "upstream defects we deliberately do NOT reproduce" begin

    @testset "subtract_into removes a value at a PREFIX of a subtracted path (dense nodes)" begin
        # MINIMAL: one op, three keys, no join, at the root.
        #   upstream -> [a]     it drops `b`, a proper prefix of the subtracted `bbba`
        #   ours     -> [a,b]   correct: only `bbba` is subtracted
        out = _defect_run("MINIMAL — 3 distinct first bytes => dense node",
            "A a b bbba\nAROOTVAL 0\nS bbba\nSROOTVAL 0\nORIGIN -\nOP SUB 1\n")
        @test _atoms(out) == ["a", "b"]

        # Each condition shown NECESSARY. Two distinct first bytes keeps the node a Pair, and
        # upstream is CORRECT there — which is why every hand-built probe missed this for so long.
        two = _defect_run("2 first bytes — Pair, upstream agrees",
            "A b bbba\nAROOTVAL 0\nS bbba\nSROOTVAL 0\nORIGIN -\nOP SUB 1\n")
        @test _atoms(two) == ["b"]

        four = _defect_run("4 first bytes — still dense",
            "A a c b bbba\nAROOTVAL 0\nS bbba\nSROOTVAL 0\nORIGIN -\nOP SUB 1\n")
        @test _atoms(four) == ["a", "b", "c"]

        # No value at a prefix of the subtracted path -> nothing to over-remove, both agree.
        nopfx = _defect_run("no value at a prefix — both agree",
            "A a c bbba\nAROOTVAL 0\nS bbba\nSROOTVAL 0\nORIGIN -\nOP SUB 1\n")
        @test _atoms(nopfx) == ["a", "c"]

        # prune is IRRELEVANT — the same divergence with SUB 0.
        np = _defect_run("prune=0 — same result",
            "A a b bbba\nAROOTVAL 0\nS bbba\nSROOTVAL 0\nORIGIN -\nOP SUB 0\n")
        @test _atoms(np) == ["a", "b"]
    end

    @testset "a grafted subtrie is lost when an ambiguous LineListNode overflows to dense — 26 of 34" begin
        # This subsumes the `graft_map` testset below: graft_map's trailing `set_val(src_root_val)`
        # is just one way to trigger it.
        #
        # HOW IT WAS ESTABLISHED, because the method is the point. All 34 divergences were shrunk to
        # minimal reproducers, then each was run TWICE: once as-is, and once with every set_val at
        # the focus disabled (drop the explicit `SETVAL`, and clear `SROOTVAL` so graft_map's and
        # join_map_into's internal `set_val(src_root_val)` cannot fire).
        #
        #     set_val DISABLED  ->  the two engines agree byte for byte on 26 of 26
        #     set_val ENABLED   ->  all 26 diverge, upstream losing the grafted content
        #
        # One controlled variable, 26 independent cases. That is why the pairs below are written as
        # PAIRS: the no-set_val member is not decoration, it is the control that makes the other
        # member mean something. Delete it and all you have left is two engines disagreeing.
        #
        # ⚠️ THE OBVIOUS READING OF THAT EXPERIMENT IS WRONG, and it was written down here before it
        # was checked. "set_val discards the immediately preceding op" fits all 26 cases and fits the
        # controlled pairs — and it is false. Two upstream defects cooperate:
        #
        #   CREATION   `set_payload_abstract`'s branch that clears a colliding slot before installing
        #              a child is guarded on `is_child_ptr::<0>()` (line_list_node.rs:977). When the
        #              colliding slot holds a VALUE at a longer key it does not fire, so the graft is
        #              parked in the free slot and the node ends up `slot0 = child at K`,
        #              `slot1 = payload at K…` — the shape upstream's own `validate_node` calls an
        #              "ambiguous path violation" and panics on (:2784). Nothing on this path calls
        #              `validate_node`, so it is built silently and still enumerates correctly.
        #   DETONATION the next op needing a third payload overflows the node into `convert_to_dense`
        #              (:1086), which transplants both slots with `set_child` keyed on the FIRST BYTE
        #              only (:1101, :1121). Both keys share that byte, and `set_child` on an occupied
        #              byte is `swap_rec` — a clobber whose return value is dropped.
        #
        # set_val is merely the cheapest way to force the overflow. The four probes below are the
        # discriminators that separate the two stories; the last two AGREE with upstream, and a test
        # that only recorded disagreements would have thrown away the evidence that matters.
        #
        # WE WIN THESE FOR A REAL REASON, not by luck: our `_convert_to_dense!` goes through
        # `merge_from_list_node!` -> `_bn_join_child_into!`, the JOINING transplant. Upstream's
        # `convert_to_dense` cannot call its own `join_child_into` because that method needs
        # `V: Lattice` and the impl block at line_list_node.rs:576 does not have the bound. That is an
        # UNDOCUMENTED DEVIATION of ours that happens to be correct — recorded here so nobody
        # "restores parity" by making our transplant clobber too.

        # --- PAIR 1: graft, no source root value -------------------------------------------------
        a = _defect_run("graft alone — engines AGREE (control)",
            "A ::aa\nAROOTVAL 0\nS ab::\nSROOTVAL 0\nORIGIN :\nOP GRAFTMAP\n")
        @test _atoms(a) == ["::aa", ":ab::"]

        b = _defect_run("graft then SETVAL — upstream drops the graft",
            "A ::aa\nAROOTVAL 0\nS ab::\nSROOTVAL 0\nORIGIN :\nOP GRAFTMAP\nOP SETVAL\n")
        @test _atoms(b) == [":", "::aa", ":ab::"]     # upstream: [:, ::aa] — `:ab::` gone
        @test ":ab::" in _atoms(b)                     # the grafted path SURVIVES the set_val

        # --- PAIR 2: insert_prefix. NO graft involved, which is what generalises the defect --------
        c = _defect_run("insert_prefix alone — engines AGREE (control)",
            "A bb:\nAROOTVAL 0\nS \nSROOTVAL 0\nORIGIN bb\nOP INSPREFIX a\n")
        @test _atoms(c) == ["bb:", "bba:"]

        d = _defect_run("insert_prefix then SETVAL — upstream reverts the prefix insertion",
            "A bb:\nAROOTVAL 0\nS \nSROOTVAL 0\nORIGIN bb\nOP INSPREFIX a\nOP SETVAL\n")
        @test _atoms(d) == ["bb", "bb:", "bba:"]      # upstream: [bb, bb:] — `bba:` gone
        @test "bba:" in _atoms(d)

        # --- PAIR 3: join_map_into --------------------------------------------------------------
        e = _defect_run("join alone — engines AGREE (control)",
            "A ::\nAROOTVAL 0\nS :aa ab ba\nSROOTVAL 0\nORIGIN :\nOP JOINMAP\n")
        @test _atoms(e) == ["::", "::", "::aa", ":ab", ":ba"]   # `::` twice: SHARED duplicate, see below

        f = _defect_run("join then SETVAL — upstream drops everything the join added",
            "A ::\nAROOTVAL 0\nS :aa ab ba\nSROOTVAL 0\nORIGIN :\nOP JOINMAP\nOP SETVAL\n")
        @test _atoms(f) == [":", "::", "::aa", ":ab", ":ba"]    # upstream: [:, ::] — 3 paths gone
        @test all(p -> p in _atoms(f), ["::aa", ":ab", ":ba"])

        # --- CONTROL: set_val ALONE is harmless on both sides ------------------------------------
        # Without this the defect could be read as "upstream's set_val is destructive", which is
        # wrong and would send a reader hunting in the wrong function. It is destructive only when
        # it follows an op that replaced the node at the focus.
        g = _defect_run("SETVAL with no preceding op — engines AGREE",
            "A ::aa\nAROOTVAL 0\nS \nSROOTVAL 0\nORIGIN :\nOP SETVAL\n")
        @test _atoms(g) == [":", "::aa"]

        # --- CONTROL: it is NOT about zippers created at a path ----------------------------------
        # Reaching the same focus by DESCEND from the map root instead of write_zipper_at_path gives
        # byte-identical results on both engines, so `root_key_start` / the origin is not involved.
        h = _defect_run("same as PAIR 2 but focus reached by DESCEND — identical",
            "A bb:\nAROOTVAL 0\nS \nSROOTVAL 0\nORIGIN -\nOP DESCEND bb\nOP INSPREFIX a\nOP SETVAL\n"
        )
        @test _atoms(h) == _atoms(d)

        # --- THE FOUR DISCRIMINATORS: node SHAPE decides, not op adjacency --------------------
        # Each outcome was predicted from the Rust source BEFORE being run, and all four matched on
        # both engines. Two of them agree with upstream, which is exactly why they are convincing.
        base = "A ::aa\nAROOTVAL 0\nS ab::\nSROOTVAL 0\nORIGIN :\nOP GRAFTMAP\n"

        d1 = _defect_run(
            "D1 graft + SETVAL — upstream loses the graft", base * "OP SETVAL\n"
        )
        @test _atoms(d1) == [":", "::aa", ":ab::"]              # upstream: [:, ::aa]

        # D2 kills "set_val discards the PRECEDING op": put an unrelated op in between and upstream
        # still loses the graft. The graft was already corrupted; set_val only detonates it.
        d2 = _defect_run(
            "D2 graft + REMOVEVAL + SETVAL — STILL lost, so adjacency is irrelevant",
            base * "OP REMOVEVAL 0\nOP SETVAL\n")
        @test _atoms(d2) == [":", "::aa", ":ab::"]              # upstream: [:, ::aa] — still

        # D3 kills it from the other side: make the parent DENSE already (3 distinct first bytes)
        # and there is no LineList overflow to trigger, so set_val directly after the graft is
        # harmless — and BOTH ENGINES AGREE, including that the graft correctly REPLACED `::aa`.
        d3 = _defect_run("D3 parent already dense — no overflow, engines AGREE",
            "A ::aa b c\nAROOTVAL 0\nS ab::\nSROOTVAL 0\nORIGIN :\nOP GRAFTMAP\nOP SETVAL\n"
        )
        @test _atoms(d3) == [":", ":ab::", "b", "c"]            # `::aa` correctly gone on BOTH

        # D4 isolates the colliding sibling: with slot_1 free there is no ambiguous node to build,
        # so again no loss and the engines AGREE.
        d4 = _defect_run("D4 slot_1 free — no ambiguous node, engines AGREE",
            "A :\nAROOTVAL 0\nS ab::\nSROOTVAL 0\nORIGIN :\nOP GRAFTMAP\nOP SETVAL\n")
        @test _atoms(d4) == [":", ":ab::"]
    end

    @testset "graft_map destroys the subtrie it just grafted, when the source has a root value" begin
        # ⚠️ A SPECIAL CASE of the testset above — kept because it is the shape the defect was first
        # found in and the one the upstream report leads with. graft_map = graft_internal(src root)
        # followed by set_val(src root value) under the default `graft_root_vals` feature, so the
        # source's root value is what supplies the destroying set_val here.
        # `graft_map` = graft_internal(src_root_node) then, under the DEFAULT `graft_root_vals`
        # feature, set_val(src_root_val). That set_val lands in the slot the graft just wrote.
        #   upstream -> [::,::b]            the source's `bb::` is GONE
        #   ours     -> [::,::b,::bb::]     the graft survives AND the root value is set
        out = _defect_run("source HAS a root value",
            "A ::b\nAROOTVAL 0\nS bb::\nSROOTVAL 1\nORIGIN ::\nOP GRAFTMAP\n")
        @test _atoms(out) == ["::", "::b", "::bb::"]

        # CONTROL that isolates the cause: same program, root value removed. Upstream keeps the
        # graft here, so the root value is what destroys it — not the graft point's key width.
        ctl = _defect_run("source has NO root value — upstream agrees",
            "A ::b\nAROOTVAL 0\nS bb::\nSROOTVAL 0\nORIGIN ::\nOP GRAFTMAP\n")
        @test _atoms(ctl) == ["::b", "::bb::"]

        # Single-byte graft point: retires the "multi-byte node key" hypothesis this family was
        # once attributed to — the defect fires here too.
        one = _defect_run("single-byte origin — still diverges upstream",
            "A :b\nAROOTVAL 0\nS bb::\nSROOTVAL 1\nORIGIN :\nOP GRAFTMAP\n")
        @test ":" in [string(c) for c in ":"]           # (guard: origin is a single byte)
        @test _atoms(one) == [":", ":b", ":bb::"]
    end

    @testset "the [bb,bb] duplicate is SHARED upstream behaviour, not our corruption" begin
        # After a join at a focus inside a multi-byte slot key, one value is reachable through two
        # slot encodings, so it enumerates twice. BOTH engines do this identically — verified on
        # three shapes against the release binary. It looked exactly like our structural corruption
        # until the join was run alone on both sides; that is the `00020` lesson.
        for (tag, s) in (("S = a:b ab ba", "a:b ab ba"), ("S = ba", "ba"), ("S = a", "a"))
            out = _defect_run("duplicate after join — $tag",
                "A bb\nAROOTVAL 0\nS $s\nSROOTVAL 0\nORIGIN b\nOP JOINMAP\n")
            @test count(==("bb"), _atoms(out)) == 2
        end
    end
end
