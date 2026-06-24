using Test

# ADR-001 increment 1 — slab scaffold. Proves the redesign's central thesis (isbits handle ⇒
# zero-box tuple) + the slab storage round-trip. The scaffold is NOT wired into the live trie.
@testset "ADR-001 increment 1 — slab scaffold" begin
    SH = PathMap.SlabHandle
    TN = PathMap.TrieNodeODRc{Int32, PathMap.GlobalAlloc}

    @testset "thesis: immutable handle is isbits, the mutable node is not" begin
        @test isbitstype(SH)
        @test isbitstype(Tuple{Int, SH})                 # ⇒ stack-allocates, no heap box
        @test !isbitstype(TN)                            # current node ref: mutable ⇒ not isbits
        @test !isbitstype(Tuple{Int, TN})                # ← exactly the Cluster-3 box AllocCheck flags
    end

    @testset "zero-alloc tuple return (the residual box, eliminated)" begin
        f() = (3, PathMap.SlabHandle(UInt32(7), PathMap.TAG_DENSEBYTE))
        f()                                              # warm
        @test @allocated(f()) == 0
    end

    @testset "slab store/load round-trip + growth" begin
        s = PathMap.NodeSlab(8)                          # tiny cap ⇒ forces a grow below
        o1 = PathMap.slab_reserve!(s, 4); PathMap.slab_store!(s, o1, Int32(-42))
        o2 = PathMap.slab_reserve!(s, sizeof(SH))
        PathMap.slab_store!(s, o2, PathMap.SlabHandle(UInt32(99), PathMap.TAG_BRIDGE))
        @test PathMap.slab_load(s, o1, Int32) == Int32(-42)
        @test PathMap.slab_load(s, o2, SH) == PathMap.SlabHandle(UInt32(99), PathMap.TAG_BRIDGE)
        for i in 1:60
            o = PathMap.slab_reserve!(s, 4); PathMap.slab_store!(s, o, Int32(i))
        end
        @test PathMap.slab_load(s, o1, Int32) == Int32(-42)   # earlier data survived the regrow
    end

    @testset "nil sentinel" begin
        @test PathMap.slab_is_nil(PathMap.SLAB_NIL)
        @test !PathMap.slab_is_nil(PathMap.SlabHandle(UInt32(1), PathMap.TAG_LINELIST))
    end

    @testset "step 2: DenseByteNode in-slab round-trip" begin
        s = PathMap.NodeSlab(16)
        mask = PathMap.set(PathMap.set(PathMap.ByteMask(), 0x41), 0x7a)   # bytes 'A','z' set
        DBN = PathMap.DBNEntry{Int32}
        entries = [DBN(PathMap.SlabHandle(UInt32(100), PathMap.TAG_LINELIST), Int32(7), true),
                   DBN(PathMap.SLAB_NIL, Int32(0), false)]
        h = PathMap.dbn_pack!(s, mask, entries)
        @test h.tag == PathMap.TAG_DENSEBYTE
        @test PathMap.dbn_mask(s, h) == mask
        @test PathMap.dbn_nentries(s, h) == 2
        e1 = PathMap.dbn_entry(s, h, 1, Int32)
        @test e1.child == PathMap.SlabHandle(UInt32(100), PathMap.TAG_LINELIST)
        @test e1.val == Int32(7) && e1.has_val
        e2 = PathMap.dbn_entry(s, h, 2, Int32)
        @test PathMap.slab_is_nil(e2.child) && !e2.has_val
        for _ in 1:30; PathMap.dbn_pack!(s, mask, entries); end   # force regrow
        @test PathMap.dbn_mask(s, h) == mask                      # earlier record survived
        @test PathMap.dbn_entry(s, h, 1, Int32).val == Int32(7)
    end

    @testset "step 3 (slab read lookup): byte→entry matches packing" begin
        s = PathMap.NodeSlab(16)
        mask = PathMap.set(PathMap.set(PathMap.ByteMask(), 0x41), 0x7a)        # 'A' < 'z'
        DBN = PathMap.DBNEntry{Int32}
        entries = [DBN(PathMap.SlabHandle(UInt32(100), PathMap.TAG_LINELIST), Int32(7), true),  # 'A'
                   DBN(PathMap.SLAB_NIL, Int32(0), false)]                                       # 'z'
        h = PathMap.dbn_pack!(s, mask, entries)
        iA = PathMap.dbn_slab_index(s, h, 0x41); iz = PathMap.dbn_slab_index(s, h, 0x7a)
        @test iA == 1 && iz == 2                                  # mask-ordered indexing
        @test PathMap.dbn_slab_index(s, h, 0x42) == 0            # 'B' absent
        @test PathMap.dbn_slab_index(s, h, 0x00) == 0
        eA = PathMap.dbn_entry(s, h, iA, Int32)
        @test eA.child == PathMap.SlabHandle(UInt32(100), PathMap.TAG_LINELIST) && eA.val == Int32(7)
        @test PathMap.slab_is_nil(PathMap.dbn_entry(s, h, iz, Int32).child)   # 'z': edge, no child
    end
end
