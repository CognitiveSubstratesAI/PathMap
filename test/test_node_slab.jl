using Test, Random

# ADR-001 increment 1 — slab scaffold. Proves the redesign's central thesis (isbits handle ⇒
# zero-box tuple) + the slab storage round-trip. The scaffold is NOT wired into the live trie.
@testset "ADR-001 increment 1 — slab scaffold" begin
    SH = PathMaps.SlabHandle
    TN = PathMaps.TrieNodeODRc{Int32, PathMaps.GlobalAlloc}

    @testset "thesis: immutable handle is isbits, the mutable node is not" begin
        @test isbitstype(SH)
        @test isbitstype(Tuple{Int, SH})                 # ⇒ stack-allocates, no heap box
        @test !isbitstype(TN)                            # current node ref: mutable ⇒ not isbits
        @test !isbitstype(Tuple{Int, TN})                # ← exactly the Cluster-3 box AllocCheck flags
    end

    @testset "zero-alloc tuple return (the residual box, eliminated)" begin
        f() = (3, PathMaps.SlabHandle(UInt32(7), PathMaps.TAG_DENSEBYTE))
        f()                                              # warm
        @test @allocated(f()) == 0
    end

    @testset "slab store/load round-trip + growth" begin
        s = PathMaps.NodeSlab(8)                          # tiny cap ⇒ forces a grow below
        o1 = PathMaps.slab_reserve!(s, 4)
        PathMaps.slab_store!(s, o1, Int32(-42))
        o2 = PathMaps.slab_reserve!(s, sizeof(SH))
        PathMaps.slab_store!(s, o2, PathMaps.SlabHandle(UInt32(99), PathMaps.TAG_BRIDGE))
        @test PathMaps.slab_load(s, o1, Int32) == Int32(-42)
        @test PathMaps.slab_load(s, o2, SH) ==
            PathMaps.SlabHandle(UInt32(99), PathMaps.TAG_BRIDGE)
        for i in 1:60
            o = PathMaps.slab_reserve!(s, 4)
            PathMaps.slab_store!(s, o, Int32(i))
        end
        @test PathMaps.slab_load(s, o1, Int32) == Int32(-42)   # earlier data survived the regrow
    end

    @testset "nil sentinel" begin
        @test PathMaps.slab_is_nil(PathMaps.SLAB_NIL)
        @test !PathMaps.slab_is_nil(PathMaps.SlabHandle(UInt32(1), PathMaps.TAG_LINELIST))
    end

    @testset "step 2: DenseByteNode in-slab round-trip" begin
        s = PathMaps.NodeSlab(16)
        mask = PathMaps.set(PathMaps.set(PathMaps.ByteMask(), 0x41), 0x7a)   # bytes 'A','z' set
        DBN = PathMaps.DBNEntry{Int32}
        entries = [
            DBN(PathMaps.SlabHandle(UInt32(100), PathMaps.TAG_LINELIST), Int32(7), true),
            DBN(PathMaps.SLAB_NIL, Int32(0), false)]
        h = PathMaps.dbn_pack!(s, mask, entries)
        @test h.tag == PathMaps.TAG_DENSEBYTE
        @test PathMaps.dbn_mask(s, h) == mask
        @test PathMaps.dbn_nentries(s, h) == 2
        e1 = PathMaps.dbn_entry(s, h, 1, Int32)
        @test e1.child == PathMaps.SlabHandle(UInt32(100), PathMaps.TAG_LINELIST)
        @test e1.val == Int32(7) && e1.has_val
        e2 = PathMaps.dbn_entry(s, h, 2, Int32)
        @test PathMaps.slab_is_nil(e2.child) && !e2.has_val
        for _ in 1:30
            PathMaps.dbn_pack!(s, mask, entries)
        end   # force regrow
        @test PathMaps.dbn_mask(s, h) == mask                      # earlier record survived
        @test PathMaps.dbn_entry(s, h, 1, Int32).val == Int32(7)
    end

    @testset "step 3 (slab read lookup): byte→entry matches packing" begin
        s = PathMaps.NodeSlab(16)
        mask = PathMaps.set(PathMaps.set(PathMaps.ByteMask(), 0x41), 0x7a)        # 'A' < 'z'
        DBN = PathMaps.DBNEntry{Int32}
        entries = [
            DBN(PathMaps.SlabHandle(UInt32(100), PathMaps.TAG_LINELIST), Int32(7), true),  # 'A'
            DBN(PathMaps.SLAB_NIL, Int32(0), false)]                                       # 'z'
        h = PathMaps.dbn_pack!(s, mask, entries)
        iA = PathMaps.dbn_slab_index(s, h, 0x41)
        iz = PathMaps.dbn_slab_index(s, h, 0x7a)
        @test iA == 1 && iz == 2                                  # mask-ordered indexing
        @test PathMaps.dbn_slab_index(s, h, 0x42) == 0            # 'B' absent
        @test PathMaps.dbn_slab_index(s, h, 0x00) == 0
        eA = PathMaps.dbn_entry(s, h, iA, Int32)
        @test eA.child == PathMaps.SlabHandle(UInt32(100), PathMaps.TAG_LINELIST) &&
            eA.val == Int32(7)
        @test PathMaps.slab_is_nil(PathMaps.dbn_entry(s, h, iz, Int32).child)   # 'z': edge, no child
    end

    @testset "step 3b: writable slab trie ≡ Dict" begin
        Random.seed!(7)
        t = PathMaps.SlabTrie{Int32}()
        d = Dict{Vector{UInt8}, Int32}()
        cs = collect(UInt8, "abcde")                    # small alphabet ⇒ heavy prefix sharing
        for _ in 1:3000
            k = UInt8[cs[rand(1:length(cs))] for _ in 1:rand(1:6)]
            v = Int32(rand(Int16))
            PathMaps.slabtrie_set!(t, k, v)
            d[k] = v
        end
        @test t.root.tag == PathMaps.TAG_LINELIST                     # increment 2: sparse list-backed
        @test all(((k, v),) -> PathMaps.slabtrie_get(t, k) == v, d)   # every key ⇒ its last value
        @test PathMaps.slabtrie_get(t, b"z") === nothing              # 'z' never inserted (not in cs)
        @test PathMaps.slabtrie_get(t, UInt8[]) === nothing           # empty key
        # value at a byte that ALSO has a child (prefix + extension), plus overwrite/sibling isolation
        PathMaps.slabtrie_set!(t, Vector{UInt8}("ab"), Int32(111))
        PathMaps.slabtrie_set!(t, Vector{UInt8}("abc"), Int32(222))
        @test PathMaps.slabtrie_get(t, Vector{UInt8}("ab")) == Int32(111)
        @test PathMaps.slabtrie_get(t, Vector{UInt8}("abc")) == Int32(222)
        PathMaps.slabtrie_set!(t, Vector{UInt8}("ab"), Int32(333))    # overwrite ab
        @test PathMaps.slabtrie_get(t, Vector{UInt8}("ab")) == Int32(333)
        @test PathMaps.slabtrie_get(t, Vector{UInt8}("abc")) == Int32(222)   # sibling unaffected
    end

    @testset "step 3c: compaction preserves ≡ Dict and shrinks the slab" begin
        Random.seed!(13)
        t = PathMaps.SlabTrie{Int32}()
        d = Dict{Vector{UInt8}, Int32}()
        cs = collect(UInt8, "abcde")
        for _ in 1:2000
            k = UInt8[cs[rand(1:5)] for _ in 1:rand(1:6)]
            v = Int32(rand(Int16))
            PathMaps.slabtrie_set!(t, k, v)
            d[k] = v
        end
        before = t.slab.len
        PathMaps.slabtrie_compact!(t)
        @test t.slab.len < before                                       # append-only leaks dropped
        @test all(((k, v),) -> PathMaps.slabtrie_get(t, k) == v, d)       # still correct post-compaction
    end

    @testset "increment 2 hybrid: high-fan-out node converts to dense" begin
        t = PathMaps.SlabTrie{Int32}()
        d = Dict{Vector{UInt8}, Int32}()
        for b in 0x01:0x28          # 40 distinct first bytes (> SLAB_MAXLIST=16) ⇒ root must go dense
            for c in 0x01:0x05
                k = UInt8[b, c]
                v = Int32(b) * Int32(100) + Int32(c)
                PathMaps.slabtrie_set!(t, k, v)
                d[k] = v
            end
        end
        @test t.root.tag == PathMaps.TAG_DENSEBYTE                        # converted past the threshold
        @test all(((k, v),) -> PathMaps.slabtrie_get(t, k) == v, d)       # dense lookup correct
        PathMaps.slabtrie_compact!(t)
        @test t.root.tag == PathMaps.TAG_DENSEBYTE                        # type preserved by compaction
        @test all(((k, v),) -> PathMaps.slabtrie_get(t, k) == v, d)       # still correct after compaction
        # a sparse child of the dense root stays a list node (hybrid coexistence)
        ci = PathMaps.node_find(t.slab, t.root, 0x01, Int32)
        @test PathMaps.node_child(t.slab, t.root, ci, Int32).tag == PathMaps.TAG_LINELIST
    end
end
