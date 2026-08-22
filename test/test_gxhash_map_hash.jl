# test_gxhash_map_hash.jl — GxHasher against an INDEPENDENT reference, and map_hash's digest contract.
#
# WHY THE VECTORS ARE PINNED. A hash is the one thing where "it runs and looks random" is worthless:
# every wrong rotate amount still produces plausible garbage. These expected values were produced by
# a SEPARATE re-implementation written from upstream's Rust (`PathMap/src/lib.rs:22-56`) in another
# language, then compared — not by running our own code and recording what it said. Self-confirmation
# would pin the bug along with the algorithm.
#
# ⚠️ WHAT THESE DIGESTS ARE NOT. They do NOT match the `mork` binary on x86_64. Upstream gates two
# different `GxHasher`s (`lib.rs:13-16`): the real AES-NI crate by default, this ~20-line mixer only
# under miri/riscv64. We port the mixer deliberately — matching AES-NI would mean AES intrinsics via
# llvmcall plus upstream's exact node traversal order, for a digest nobody compares across engines,
# and upstream's own cfg proves the value is a PER-TARGET artifact. Same call as ADAPTATIONS entry 7.
using Test, PathMap

@testset "GxHasher — 1:1 with upstream lib.rs:22-56" begin
    # (seed, bytes, optional u128 via the SEPARATE write_u128 path, expected u128)
    # Independent reference; edge cases chosen for the things that silently differ:
    # empty input, a single byte, exactly 32 bytes (the ByteMask width), the u128 lane path,
    # a NEGATIVE seed (bit-reinterpretation, not conversion), and a saturated u128.
    vectors = [
        (Int64(0), UInt8[], nothing,
            UInt128(220182708007666064593948275397026489765)),
        (Int64(0), UInt8[0x61], nothing,
            UInt128(220182708007667311290018932242793705525)),
        (Int64(0), Vector{UInt8}("hello world"), nothing,
            UInt128(220182708007664855661618046230779051371)),
        (PathMap._MAP_HASH_SEED, UInt8[], nothing,
            UInt128(307095087557724141754317945346449730642)),
        (PathMap._MAP_HASH_SEED, UInt8[i for i in 0x00:0x1f], nothing,
            UInt128(307095087557724141747313161787170070674)),
        (PathMap._MAP_HASH_SEED, UInt8[i for i in 0x00:0x1f],
            UInt128(12345678901234567890123456789),
            UInt128(307093591089338380782026710111025841575)),
        (Int64(7), UInt8[0x00, 0xff, 0x7f, 0x80], UInt128(1),
            UInt128(220182708007666064533182530213042211867)),
        (Int64(-1), Vector{UInt8}("xyz"), typemax(UInt128),
            UInt128(220182708007667084618597959684965677372))
    ]
    for (seed, bytes, u, want) in vectors
        h = GxHasher(seed)
        gx_write!(h, bytes)
        u === nothing || gx_write_u128!(h, u)
        @test gx_finish_u128(h) === want
    end

    # write_u128 is NOT equivalent to feeding 16 bytes — it is a distinct lane path with different
    # rotates (17/9 vs 11/3). Upstream uses the byte path for mask+children and this one for the
    # value, so conflating them would silently change every digest that has a value.
    a = GxHasher(Int64(0))
    gx_write_u128!(a, UInt128(1))
    b = GxHasher(Int64(0))
    gx_write!(b, gx_u128_le_bytes(UInt128(1)))
    @test gx_finish_u128(a) != gx_finish_u128(b)

    # the seed is REINTERPRETED, not converted: -1 and typemax(UInt64) are the same bits
    @test gx_finish_u128(GxHasher(Int64(-1))) ===
        gx_finish_u128(GxHasher(reinterpret(Int64, typemax(UInt64))))

    # order sensitivity — a mixer that ignored order would make the Merkle fold meaningless
    x = GxHasher(Int64(0))
    gx_write!(x, UInt8[1, 2])
    y = GxHasher(Int64(0))
    gx_write!(y, UInt8[2, 1])
    @test gx_finish_u128(x) != gx_finish_u128(y)
end

@testset "map_hash — 128-bit Merkle fold over the logical trie" begin
    mk(ps) = (m=PathMap.PathMap{UInt64}();
        for (k, v) in ps
            set_val_at!(m, Vector{UInt8}(k), UInt64(v))
        end; m)

    a = mk([("band", 1), ("bandana", 2), ("apple", 3)])
    b = mk([("apple", 3), ("bandana", 2), ("band", 1)])   # same content, different insertion order
    c = mk([("band", 1), ("bandana", 2), ("apple", 4)])   # one VALUE differs
    d = mk([("band", 1), ("bandana", 2)])                 # one KEY missing

    @test map_hash(a) isa UInt128                          # was UInt64 until 2026-08-05
    @test map_hash(a) === map_hash(b)                      # CONTENT-addressed, not construction-addressed
    @test map_hash(a) !== map_hash(c)                      # a changed value is visible
    @test map_hash(a) !== map_hash(d)                      # a removed key is visible
    @test map_hash(mk([])) === map_hash(mk([]))            # empty is well-defined and stable

    # DETERMINISM ACROSS CALLS. `_cata_cached!` rebuilds its memo per call, so this also asserts the
    # memo cannot leak state between invocations — the property any future PERSISTED memo must keep.
    @test map_hash(a) === map_hash(a) === map_hash(a)

    # A pinned digest. If the fold order changes (mask, then children, then value) this fires — which
    # is the point: a checkpoint digest whose meaning drifts silently is worse than none.
    @test map_hash(a) === UInt128(0xe7085ccc27c1bc52e8a14da474677f37)

    # custom val_hash, mirroring upstream's `hash_with`
    @test map_hash(a, _ -> UInt128(0)) !== map_hash(a)     # the value hash genuinely participates
    @test map_hash(a, _ -> UInt128(0)) === map_hash(c, _ -> UInt128(0))  # ...and only via that fn
end
