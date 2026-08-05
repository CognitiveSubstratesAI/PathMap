# test_trie_ref_cow.jl — `tr_make_map` must SHARE a subtrie without letting writes leak between maps.
#
# THE DEFECT THIS PINS (found 2026-08-05, latent — the function had no callers). `tr_make_map` did:
#     m = PathMap{V,A}(t.alloc);  m.root = focus_rc          # raw alias, no refcount bump
# so two maps pointed at one node whose `refcnt` still read 1. `_cow_in_place!` forks only ABOVE 1,
# so a write to either map mutated the shared node IN PLACE and appeared in BOTH:
#     src = {"ab"=>1,"ac"=>2,"ad"=>3};  m = tr_make_map(trie_ref_at_path(src, []))
#     set_val_at!(m, b"az", 99)   ⇒   get_val_at(src, b"az") == 99      (!!)
#
# Upstream cannot have it: `make_map` (trie_ref.rs:290-298) builds from `get_focus().into_option()`
# on a `&self`, so producing an owned node ref requires an Rc clone and the refcount rises. Julia has
# no implicit clone — `Base.copy(::TrieNodeODRc)` ("mirrors Arc::clone") must be written explicitly.
#
# WHY IT MATTERS BEYOND THIS FUNCTION: `pathmap_rs_reference.md` §1.2 invariant 2 says a write zipper
# "must uniquify the nodes along its path before modifying them" — and uniquification is DRIVEN BY
# the refcount. A share that never raises it is invisible to the very mechanism meant to protect it.
# So the assertions below are on REFCOUNTS as well as values: equal values could pass while sharing
# is silently broken, and a refcount of 1 on a shared node is the defect regardless of what a read
# returns today.
using Test, PathMap
const P = PathMap

@testset "tr_make_map — shares structurally, isolates writes (COW)" begin
    mk() = (m = P.PathMap{UInt64}();
            for (k, v) in [("ab", 1), ("ac", 2), ("ad", 3)]
                set_val_at!(m, Vector{UInt8}(k), UInt64(v))
            end; m)

    @testset "the derived map sees the source's contents" begin
        src = mk()
        m = P.tr_make_map(P.trie_ref_at_path(src, UInt8[]))
        @test get_val_at(m, b"ab") === UInt64(1)
        @test get_val_at(m, b"ac") === UInt64(2)
        @test get_val_at(m, b"ad") === UInt64(3)
    end

    @testset "sharing RAISES the refcount — the mechanism COW depends on" begin
        src = mk()
        before = P._node_refcount(src.root.node)
        m = P.tr_make_map(P.trie_ref_at_path(src, UInt8[]))
        @test P._node_refcount(m.root.node) > before        # >1 ⇒ a write is FORCED to fork
        @test P._node_refcount(m.root.node) >= 2
    end

    @testset "writing the DERIVED map leaves the source untouched" begin
        src = mk()
        m = P.tr_make_map(P.trie_ref_at_path(src, UInt8[]))
        set_val_at!(m, b"az", UInt64(99))
        @test get_val_at(m, b"az") === UInt64(99)
        @test get_val_at(src, b"az") === nothing            # was 99 before the fix
        for (k, v) in [("ab", 1), ("ac", 2), ("ad", 3)]     # ...and nothing else moved
            @test get_val_at(src, Vector{UInt8}(k)) === UInt64(v)
        end
    end

    @testset "writing the SOURCE leaves the derived map untouched" begin
        # the symmetric direction — a fork must protect BOTH holders, not just the writer
        src = mk()
        m = P.tr_make_map(P.trie_ref_at_path(src, UInt8[]))
        set_val_at!(src, b"aq", UInt64(77))
        @test get_val_at(src, b"aq") === UInt64(77)
        @test get_val_at(m, b"aq") === nothing
        for (k, v) in [("ab", 1), ("ac", 2), ("ad", 3)]
            @test get_val_at(m, Vector{UInt8}(k)) === UInt64(v)
        end
    end

    @testset "removal is isolated too, in both directions" begin
        src = mk()
        m = P.tr_make_map(P.trie_ref_at_path(src, UInt8[]))
        remove_val_at!(m, b"ab")
        @test get_val_at(m, b"ab") === nothing
        @test get_val_at(src, b"ab") === UInt64(1)          # the source keeps it

        src2 = mk()
        m2 = P.tr_make_map(P.trie_ref_at_path(src2, UInt8[]))
        remove_val_at!(src2, b"ac")
        @test get_val_at(src2, b"ac") === nothing
        @test get_val_at(m2, b"ac") === UInt64(2)
    end

    @testset "a subtrie taken at a NON-EMPTY path isolates as well" begin
        # the ShardZipper use: a map made from a region under a prefix, not the whole trie
        src = P.PathMap{UInt64}()
        for (k, v) in [("pre:x", 1), ("pre:y", 2), ("other:z", 3)]
            set_val_at!(src, Vector{UInt8}(k), UInt64(v))
        end
        m = P.tr_make_map(P.trie_ref_at_path(src, Vector{UInt8}("pre:")))
        @test get_val_at(m, b"x") === UInt64(1)             # relative to the prefix
        @test get_val_at(m, b"y") === UInt64(2)
        set_val_at!(m, b"w", UInt64(9))
        @test get_val_at(src, b"pre:w") === nothing         # does not leak back
        @test get_val_at(src, Vector{UInt8}("other:z")) === UInt64(3)
    end

    @testset "an empty source yields an empty, writable map" begin
        src = P.PathMap{UInt64}()
        m = P.tr_make_map(P.trie_ref_at_path(src, UInt8[]))
        @test get_val_at(m, b"anything") === nothing
        set_val_at!(m, b"k", UInt64(1))                      # must not throw on a nothing-root
        @test get_val_at(m, b"k") === UInt64(1)
        @test get_val_at(src, b"k") === nothing
    end
end
