# test_act_validation.jl — the .act file is TRUSTED INPUT upstream; these pin what we check instead.
#
# Surveyed 2026-08-04: upstream PathMap validates an 8-byte magic and nothing else, then trusts every
# node offset — so in-bounds corruption is a SILENT MISPARSE, and a 1..7-byte file PANICS because
# `open_mmap` slices `&memmap[..MAGIC_LENGTH]` with no length guard (upstream's own
# `merge_zipper_into_file` HAS that guard, arena_compact.rs:1298-1305; open_mmap just lacks it).
# hyperon-experimental and PeTTa have no binary persistence at all; CeTTa delegates to MORK; JeTTa
# has a SHA-256 fingerprint that is never recomputed from the loaded bytes.
#
# The file format is UNCHANGED and stays byte-compatible with upstream's ACTree03 — integrity is a
# sidecar. Each test below names the failure it would have caught.
using Test, PathMaps


@testset "ACT validation (magic, length guard, atomic write)" begin
    mktempdir() do dir
        m = PathMaps.PathMap{UInt64}()
        for (i, k) in enumerate(("apple", "apricot", "banana", "band", "bandana"))
            set_val_at!(m, Vector{UInt8}(k), UInt64(i))
        end
        tree = act_from_zipper(m, v -> v)
        f = joinpath(dir, "t.act")

        # ── format is untouched: still exactly upstream's ACTree03 image
        act_save(tree, f)
        @test read(f)[1:8] == ACT_MAGIC

        # ── round-trip still works
        t2 = act_open(f)
        @test act_get_val_at(t2, b"apple") === UInt64(1)
        @test act_get_val_at(t2, b"bandana") === UInt64(5)

        # ── determinism: the same trie written twice is byte-identical
        g = joinpath(dir, "t2.act")
        act_save(tree, g)
        @test read(g) == read(f)

        # ── THE DEFECT NEITHER WE NOR UPSTREAM CAN SEE: in-bounds corruption. Flip one byte deep
        # in the arena; the magic still matches, so the file still "opens" and is silently misparsed.
        # Pinned deliberately — this is the accepted limit of magic-only validation, and upstream's
        # own NodeId doc concedes a bad id "can catastrophically break the implementation".
        # A digest here would DETECT it but belongs at the SMS/epoch layer, not this file — see the
        # integrity note in ArenaCompact.jl.
        h = joinpath(dir, "corrupt.act")
        act_save(tree, h)
        raw = read(h)
        raw[end] ⊻= 0xff                              # in bounds, length unchanged, magic intact
        write(h, raw)
        @test raw[1:8] == ACT_MAGIC
        @test act_open(h) isa ArenaCompactTree        # opens clean — nothing at this layer sees it

        # ── SHORT FILE: upstream PANICS here (unguarded slice). We give a typed error.
        for n in (0, 1, 7, 8, 15)
            short = joinpath(dir, "short$n.act")
            write(short, read(f)[1:min(n, end)])
            @test_throws ArgumentError act_open(short)
            @test_throws ArgumentError act_open_mmap(short)
        end

        # ── bad magic is rejected on BOTH paths, and by a throw rather than @assert (which Julia
        # documents as removable at some optimisation levels — the reason this is not an @assert)
        bad = joinpath(dir, "bad.act")
        b = read(f)
        b[1:8] = Vector{UInt8}("NOTACT01")
        write(bad, b)
        @test_throws ArgumentError act_open(bad)
        @test_throws ArgumentError act_open_mmap(bad)

        # ── atomic save: no temp files left behind in the directory
        @test isempty(filter(x -> startswith(x, "jl_"), readdir(dir)))
    end
end

@testset "ACT round-trip with PREFIX-NESTED keys (cata byte-fallback corruption)" begin
    # REGRESSION. `_cata_ascend_to_fork!` read the child edge byte from the POST-ascend path and
    # substituted `UInt8(0)` when that path was too short (Morphisms.jl). Upstream reads it from the
    # PRE-ascend buffer and never substitutes (morphisms.rs:571, `.last().unwrap()`).
    # The fallback fired exactly when a VALUED node has a single child, so the child's edge byte was
    # persisted as 0x00:  {"band"=>1,"bandana"=>2}  round-tripped as  "band", "band\0na".
    #
    # Invisible to every existing test: the ArenaCompact round-trips all used keys with NO shared
    # prefix ("alpha"/"beta"/"gamma"), and the in-memory map stayed correct — only the persisted
    # image was wrong. Boundary case = one key that is a strict extension of another valued key.
    for ks in (("band", "bandana"),
        ("a", "ab"),
        ("x", "xy", "xyz"),
        ("band", "bandana", "bandanas"),
        ("a", "ab", "abc", "abcd"),
        ("apple", "apricot", "banana", "band", "bandana"),
        ("alpha", "beta", "gamma"))                       # control: no shared prefixes
        m = PathMaps.PathMap{UInt64}()
        for (i, k) in enumerate(ks)
            set_val_at!(m, Vector{UInt8}(k), UInt64(i))
        end
        t = act_from_zipper(m, v -> v)
        for (i, k) in enumerate(ks)
            @test act_get_val_at(t, Vector{UInt8}(k)) === UInt64(i)   # was `nothing` for the longer key
        end
        mktempdir() do dir                                            # and it survives a save/open
            f = joinpath(dir, "n.act")
            act_save(t, f)
            t2 = act_open(f)
            for (i, k) in enumerate(ks)
                @test act_get_val_at(t2, Vector{UInt8}(k)) === UInt64(i)
            end
        end
    end
end

@testset "act_to_next_val! reaches a value on a branch UNDER A LINE NODE (regression)" begin
    # WAS AN OPEN DEFECT, pinned here with @test_broken until 2026-08-05. `act_descend_until!`
    # violated upstream's contract — "descend until a branch OR A VALUE is encountered"
    # (zipper.rs:299-316, which tests `is_val()` after every single-byte step). Our line arm stepped
    # onto the child node and re-entered the `child_count == 1` loop WITHOUT testing it, so a valued
    # branch sitting under a line node was walked straight past:
    #
    #     {"band"=>1, "bandana"=>2}   walk went  "b" -> "banda"   (measured, by trace)
    #     act_to_next_val! yielded only "bandana"; "band" was invisible to every enumeration
    #
    # The bytes on disk were CORRECT throughout — `act_get_val_at` returned both values — so this was
    # purely an iterator defect. That is exactly why no round-trip test caught it: round-trips assert
    # lookups, and the pre-existing ArenaCompact tests used keys with no shared prefix
    # ("alpha"/"beta"/"gamma"), the one shape where a value can never sit under a line node.
    # It matters because CheckpointRef IS full-state `.act`: anything ENUMERATING a checkpoint
    # silently under-reported.
    #
    # The boundary condition is one key being a strict extension of another VALUED key, so the
    # shorter key's value lands on a branch beneath the shared line. Both are asserted below —
    # enumeration AND lookup — because they failed independently.
    for ks in (("band", "bandana"),                       # the original repro
        ("a", "ab"),                               # minimal
        ("x", "xy", "xyz"),                        # chained extensions
        ("band", "bandana", "bandanas"),           # two levels of nesting
        ("a", "ab", "abc", "abcd"),                # deep chain
        ("apple", "apricot", "banana", "band", "bandana"),  # nesting mixed with forks
        ("a",),                                    # single key, no branching
        ("aa", "ab", "ba", "bb"),                  # forks, no nesting
        ("alpha", "beta", "gamma"))                # control: no shared prefixes at all
        m = PathMaps.PathMap{UInt64}()
        for (i, k) in enumerate(ks)
            set_val_at!(m, Vector{UInt8}(k), UInt64(i))
        end
        t = act_from_zipper(m, v -> v)

        z = act_read_zipper(t)
        seen = String[]
        while act_to_next_val!(z)
            push!(seen, String(copy(act_path(z))))
        end
        @test sort(seen) == sort(collect(ks))          # every key REACHABLE by enumeration
        @test length(seen) == length(ks)               # ...exactly once, no duplicates

        for (i, k) in enumerate(ks)                    # ...and lookup still agrees
            @test act_get_val_at(t, Vector{UInt8}(k)) === UInt64(i)
        end
    end
end
