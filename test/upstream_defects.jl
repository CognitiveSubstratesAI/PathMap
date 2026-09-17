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
using PathMaps, Test

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

    # ─── 2026-09-17: THE GRAFT / INSERT_PREFIX / JOIN FAMILY BELOW WAS RE-BASELINED TO UPSTREAM f0cd6b7 ───
    # These testsets used to pin behaviour from BEFORE upstream f0cd6b7 ("Fixes for a number of issues
    # adjacent to PathMap#79", 2026-09-02): a graft at a focus inside a compressed key run KEPT THE OLD
    # RUN beside the grafted one. That was SHARED by old upstream and by us, which is why the old
    # assertions expected e.g. `[::aa, :ab::]` after a graft at `:` and a `bb` enumerated twice after a
    # join. Upstream fixed it (graft_internal removes all branches before setting the new one; LineList
    # set_payload_abstract replaces a value under a longer compressed key); we ported the fix (delta
    # P1 #5), and the PathMapsSpec Lean model — our intended semantics — agrees with every expectation
    # below. The old narrative (an "ambiguous LineListNode" clobbered on overflow to dense, 26 of 34 fuzz
    # cases) described that pre-fix shape; see git history for it. The vendored fuzz answers were
    # regenerated from upstream HEAD the same day and agree with every expectation below.
    @testset "graft replaces the key run below the focus (upstream f0cd6b7)" begin
        # graft at `:` replaces `:aa` (below the focus) with the source
        a = _defect_run("graft alone", "A ::aa\nAROOTVAL 0\nS ab::\nSROOTVAL 0\nORIGIN :\nOP GRAFTMAP\n")
        @test _atoms(a) == [":ab::"]
        b = _defect_run("graft then SETVAL", "A ::aa\nAROOTVAL 0\nS ab::\nSROOTVAL 0\nORIGIN :\nOP GRAFTMAP\nOP SETVAL\n")
        @test _atoms(b) == [":", ":ab::"]
        d2 = _defect_run("graft, REMOVEVAL, SETVAL", "A ::aa\nAROOTVAL 0\nS ab::\nSROOTVAL 0\nORIGIN :\nOP GRAFTMAP\nOP REMOVEVAL 0\nOP SETVAL\n")
        @test _atoms(d2) == [":", ":ab::"]
        # parent already dense (3 first bytes): same replacement, siblings untouched
        d3 = _defect_run("parent dense", "A ::aa b c\nAROOTVAL 0\nS ab::\nSROOTVAL 0\nORIGIN :\nOP GRAFTMAP\nOP SETVAL\n")
        @test _atoms(d3) == [":", ":ab::", "b", "c"]
        d4 = _defect_run("nothing below the focus", "A :\nAROOTVAL 0\nS ab::\nSROOTVAL 0\nORIGIN :\nOP GRAFTMAP\nOP SETVAL\n")
        @test _atoms(d4) == [":", ":ab::"]
    end

    @testset "insert_prefix moves the key run instead of copying it (upstream f0cd6b7)" begin
        c = _defect_run("insert_prefix", "A bb:\nAROOTVAL 0\nS \nSROOTVAL 0\nORIGIN bb\nOP INSPREFIX a\n")
        @test _atoms(c) == ["bba:"]
        d = _defect_run("insert_prefix then SETVAL", "A bb:\nAROOTVAL 0\nS \nSROOTVAL 0\nORIGIN bb\nOP INSPREFIX a\nOP SETVAL\n")
        @test _atoms(d) == ["bb", "bba:"]
        # the same focus reached by DESCEND from the map root gives the same answer
        h = _defect_run("focus by DESCEND", "A bb:\nAROOTVAL 0\nS \nSROOTVAL 0\nORIGIN -\nOP DESCEND bb\nOP INSPREFIX a\nOP SETVAL\n")
        @test _atoms(h) == _atoms(d)
    end

    @testset "graft_map: the source root value becomes the focus value, the run below is replaced" begin
        out = _defect_run("source HAS a root value", "A ::b\nAROOTVAL 0\nS bb::\nSROOTVAL 1\nORIGIN ::\nOP GRAFTMAP\n")
        @test _atoms(out) == ["::", "::bb::"]
        ctl = _defect_run("source has NO root value", "A ::b\nAROOTVAL 0\nS bb::\nSROOTVAL 0\nORIGIN ::\nOP GRAFTMAP\n")
        @test _atoms(ctl) == ["::bb::"]
        one = _defect_run("single-byte origin", "A :b\nAROOTVAL 0\nS bb::\nSROOTVAL 1\nORIGIN :\nOP GRAFTMAP\n")
        @test _atoms(one) == [":", ":bb::"]
    end

    @testset "join_map_into at a mid-key focus enumerates each path once (upstream f0cd6b7)" begin
        e = _defect_run("join", "A ::\nAROOTVAL 0\nS :aa ab ba\nSROOTVAL 0\nORIGIN :\nOP JOINMAP\n")
        @test _atoms(e) == ["::", "::aa", ":ab", ":ba"]
        f = _defect_run("join then SETVAL", "A ::\nAROOTVAL 0\nS :aa ab ba\nSROOTVAL 0\nORIGIN :\nOP JOINMAP\nOP SETVAL\n")
        @test _atoms(f) == [":", "::", "::aa", ":ab", ":ba"]
        # used to enumerate `bb` twice on both engines (the old "SHARED duplicate")
        for (tag, src, want) in (("S = a:b ab ba", "a:b ab ba", ["ba:b", "bab", "bb", "bba"]),
                                 ("S = ba", "ba", ["bb", "bba"]), ("S = a", "a", ["ba", "bb"]))
            out = _defect_run("join — $tag", "A bb\nAROOTVAL 0\nS $src\nSROOTVAL 0\nORIGIN b\nOP JOINMAP\n")
            @test _atoms(out) == want
            @test count(==("bb"), _atoms(out)) == 1
        end
    end
end
