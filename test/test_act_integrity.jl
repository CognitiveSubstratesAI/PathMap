# test_act_integrity.jl — the .act file is TRUSTED INPUT upstream; these pin what we check instead.
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
using Test, PathMap


@testset "ACT integrity" begin
    mktempdir() do dir
        m = PathMap.PathMap{UInt64}()
        for (i, k) in enumerate(("apple", "apricot", "banana", "band", "bandana"))
            set_val_at!(m, Vector{UInt8}(k), UInt64(i))
        end
        tree = act_from_zipper(m, v -> v)
        f = joinpath(dir, "t.act")

        # ── format is untouched: still exactly upstream's ACTree03 image
        act_save(tree, f)
        @test read(f)[1:8] == ACT_MAGIC
        @test !isfile(act_digest_path(f))          # no sidecar unless asked — default is free

        # ── round-trip still works
        t2 = act_open(f)
        @test act_get_val_at(t2, b"apple")   === UInt64(1)
        @test act_get_val_at(t2, b"bandana") === UInt64(5)

        # ── digest sidecar
        act_save(tree, f; digest=true)
        @test isfile(act_digest_path(f))
        @test act_verify(f)
        @test act_file_digest(f) == first(split(strip(read(act_digest_path(f), String))))
        # sha256sum -c compatible: "<64 hex>  <basename>"
        @test occursin(Regex("^[0-9a-f]{64}  " * basename(f) * "\$"), strip(read(act_digest_path(f), String)))

        # ── determinism: the same trie saved twice has the same content ID
        g = joinpath(dir, "t2.act")
        act_save(tree, g; digest=true)
        @test act_file_digest(g) == act_file_digest(f)

        # ── THE DEFECT UPSTREAM CANNOT SEE: in-bounds corruption. Flip one byte deep in the arena;
        # the magic still matches, so upstream would misparse it silently. verify catches it.
        h = joinpath(dir, "corrupt.act")
        act_save(tree, h; digest=true)
        raw = read(h)
        raw[end] ⊻= 0xff                              # in bounds, length unchanged, magic intact
        write(h, raw)
        @test raw[1:8] == ACT_MAGIC                   # ...so the magic check still passes
        @test act_open(h) isa ArenaCompactTree        # ...and the file still "opens"
        @test !act_verify(h)                          # only the digest sees it
        @test_throws ArgumentError act_open(h; verify=true)

        # ── a verification that cannot run must THROW, not silently pass (JeTTa's failure mode)
        rm(act_digest_path(h))
        @test_throws ArgumentError act_verify(h)
        write(act_digest_path(h), "not-a-digest\n")
        @test_throws ArgumentError act_verify(h)

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
        b = read(f); b[1:8] = Vector{UInt8}("NOTACT01"); write(bad, b)
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
        m = PathMap.PathMap{UInt64}()
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

@testset "OPEN DEFECT — act_to_next_val! skips a value on a branch under a line node" begin
    # SEPARATE from the corruption above and NOT fixed here. The bytes on disk are correct — every
    # `act_get_val_at` below returns the right value — but the ITERATOR misses one entry.
    #
    # Shape: {"band"=>1, "bandana"=>2}. The cata emits one node (path="band", jump=4, val=1, one
    # child 'a'), which `act_from_zipper` writes as a LINE node ("band", value=nothing because it has
    # children) wrapping a BRANCH that carries value 1. Walking with act_to_next_val! yields only
    # "bandana" — the branch's value is stepped over.
    #
    # `@test_broken` on purpose: it records the defect AND fails loudly the moment it is fixed, so
    # this cannot silently rot into a wrong expectation.
    m = PathMap.PathMap{UInt64}()
    set_val_at!(m, b"band", UInt64(1)); set_val_at!(m, b"bandana", UInt64(2))
    t = act_from_zipper(m, v -> v)

    @test act_get_val_at(t, b"band")    === UInt64(1)     # data IS present...
    @test act_get_val_at(t, b"bandana") === UInt64(2)

    z = act_read_zipper(t); seen = String[]
    while act_to_next_val!(z); push!(seen, String(copy(act_path(z)))); end
    @test_broken sort(seen) == ["band", "bandana"]        # ...but the walk yields only "bandana"
    @test "bandana" in seen                               # pins what it DOES yield today
end
