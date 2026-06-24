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
end
