# upstream_defects.jl — the two UPSTREAM defects we deliberately do not reproduce.
#
# Both were reduced to minimal reproducers on 2026-07-31 and written up in
# `test/differential/UPSTREAM_BUGS.md`. The fuzz corpus scores them as "we have MORE atoms than
# upstream", which is the CORRECT side to be on: upstream silently loses data in both.
#
# WHY A SEPARATE FILE FROM THE FUZZ RATCHET. `KNOWN_DIVERGENT.txt` records THAT 33 cases differ; it
# does not record WHY, and a ratchet cannot tell "upstream is wrong" from "we regressed". These
# assert the SEMANTICS directly, so if a future change makes us match upstream's data loss, this goes
# red with a reason attached rather than the ratchet silently going green.
#
# ⚠️ These assert OUR behaviour, which is the CORRECT behaviour. Do not "fix" them toward upstream.
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

_atoms(out) = (m = match(r"\|\[(.*?)\] vc=", out)) === nothing ? String[] :
              (isempty(m.captures[1]) ? String[] : sort(String.(split(m.captures[1], ","))))

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

    @testset "graft_map destroys the subtrie it just grafted, when the source has a root value" begin
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
