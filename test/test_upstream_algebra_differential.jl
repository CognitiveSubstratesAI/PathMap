# test_upstream_algebra_differential.jl
#
# PORT OF UPSTREAM'S OWN ALGEBRA TESTS — `pathmap/tests/pathmap_algebra_differential.rs`, all four
# of them, not a reimagining. Ported 2026-08-23.
#
# 🔴 WHY THIS FILE EXISTS RATHER THAN MORE HAND-MADE FIXTURES. Chasing the `Ring.jl` blanket-impl
# divergence, four differential fixtures were INVENTED to catch it; all four passed, because the
# variant they targeted is only observable through `result_into_map`, which was not ported. Upstream
# already had this file — a seeded PRNG against a set oracle, checking the algebraic LAWS rather
# than point cases. Its own comment names the regression it was built for:
#     "Seeds 10, 77, and 287 are focused regressions for CoFree identity operand selection and
#      mixed value/onward-link exhaustiveness."
# which is exactly the `_cf_combine_results` path the blanket impls feed. Port upstream's tests
# before writing your own; they encode failures we have not had yet.
#
# ⚠️ THE PRNG MUST MATCH BIT FOR BIT or the seeds mean nothing. It is the same LCG constants as
# upstream, on wrapping UInt64 arithmetic (Julia's `*`/`+` on UInt64 already wrap).
#
# ⚠️ SEED COUNTS ARE UPSTREAM'S NON-MIRI VALUES (256 / 128 / 1 / 512). They are the whole point of a
# seeded suite — cutting them to make the file fast silently narrows coverage, and upstream's own
# focused seeds (10, 77, 287) live inside the 512.

using PathMaps, Test
const P = PathMaps

const FIXED_WIDTH_KEYS = 72

# Ports `next_u64` — an LCG, deliberately the same constants so a seed selects the same keys here
# as it does upstream.
function next_u64!(state::Base.RefValue{UInt64})
    state[] = state[] * 0x5851_f42d_4c95_7f2d + 0x1405_7b7e_f767_814f
    state[]
end

"Ports `fixed_width_set`: 72 keys of 8 random bytes, with the ordinal xored into byte 1."
function fixed_width_set(seed::UInt64, salt::UInt64)
    state = Ref(seed ⊻ salt)
    keys = Set{Vector{UInt8}}()
    for ordinal in 0:(FIXED_WIDTH_KEYS - 1)
        key = zeros(UInt8, 8)
        for i in eachindex(key)
            key[i] = UInt8((next_u64!(state) >> 32) & 0xff)
        end
        key[1] ⊻= UInt8(ordinal & 0xff)
        push!(keys, key)
    end
    keys
end

"""
Ports `prefix_heavy_set`. The shape matters more than the values: variable-length keys drawn from a
small alphabet, plus deliberate PREFIXES of existing keys and deliberate EXTENSIONS of them. That is
what forces nodes carrying both a value and onward links — the CoFree case the ring impls serve.
"""
function prefix_heavy_set(seed::UInt64, salt::UInt64)
    state = Ref(seed ⊻ salt)
    keys = Set{Vector{UInt8}}()
    (next_u64!(state) & 7) == 0 && push!(keys, UInt8[])
    for index in 0:47
        len = Int(next_u64!(state) % 9)
        key = UInt8[]
        for position in 0:(len - 1)
            selector = next_u64!(state)
            push!(key, if selector % 5 == 0
                UInt8(index)
            elseif selector % 5 == 1
                UInt8(position & 0xff)
            elseif selector % 5 == 2
                UInt8((selector >> 32) & 0xff)
            elseif selector % 5 == 3
                UInt8(UInt8('a') + UInt8(selector % 7))
            else
                UInt8(0xff - UInt8(index))
            end)
        end
        push!(keys, copy(key))
        if length(key) > 1 && index % 3 == 0
            push!(keys, key[1:(end - 1)])          # a PREFIX of an existing key
        end
        if index % 7 == 0
            push!(keys, vcat(key, UInt8[0x00, UInt8(index)]))   # an EXTENSION of one
        end
    end
    keys
end

map_from_set(keys) = begin
    m = P.PathMap{P.UnitVal}()
    for k in keys
        P.set_val_at!(m, k, P.UnitVal())
    end
    m
end

# Ports `set_from_map`: upstream is `map.iter().map(|(key, ())| key).collect()`. Ours is the same
# call now that `PathMap::iter` is ported — `Base.iterate(::PathMap)` yields the ROOT VALUE first,
# which a bare `read_zipper` walk never does.
#
# ⚠️ THE FIRST VERSION OF THIS HELPER USED THE RAW ZIPPER AND WAS WRONG. `prefix_heavy_set` inserts
# the empty key on roughly 1 seed in 8, so the oracle reported those maps as having LOST a key and
# the failure read as broken copy-on-write. Delta-reducing a 60-key failing case landed on the
# single key `UInt8[]` — no clone involved at all, which is what exposed the oracle as the bug.
# Do not "optimise" this back to a bare zipper walk.
set_from_map(m) = Set{Vector{UInt8}}(P.pm_keys(m))

@testset "upstream pathmap_algebra_differential.rs (ported)" begin

    @testset "seeded_prefix_free_algebra_matches_btreeset_oracle" begin
        for seed in UInt64(0):UInt64(255)
            a = fixed_width_set(seed, 0x243f_6a88_85a3_08d3)
            b = fixed_width_set(seed, 0x1319_8a2e_0370_7344)
            c = fixed_width_set(seed, 0xa409_3822_299f_31d0)
            ma, mb, mc = map_from_set(a), map_from_set(b), map_from_set(c)

            # against the SET ORACLE, not against ourselves
            @test set_from_map(P.pm_join(ma, mb)) == union(a, b)
            @test set_from_map(P.pm_meet(ma, mb)) == intersect(a, b)
            @test set_from_map(P.pm_subtract(ma, mb)) == setdiff(a, b)

            # commutativity, idempotence, self-annihilation
            @test set_from_map(P.pm_join(ma, mb)) == set_from_map(P.pm_join(mb, ma))
            @test set_from_map(P.pm_meet(ma, mb)) == set_from_map(P.pm_meet(mb, ma))
            @test set_from_map(P.pm_join(ma, ma)) == a
            @test set_from_map(P.pm_meet(ma, ma)) == a
            @test isempty(set_from_map(P.pm_subtract(ma, ma)))

            # associativity, and meet distributing over join
            @test set_from_map(P.pm_join(P.pm_join(ma, mb), mc)) ==
                  set_from_map(P.pm_join(ma, P.pm_join(mb, mc)))
            @test set_from_map(P.pm_meet(P.pm_meet(ma, mb), mc)) ==
                  set_from_map(P.pm_meet(ma, P.pm_meet(mb, mc)))
            @test set_from_map(P.pm_meet(ma, P.pm_join(mb, mc))) ==
                  set_from_map(P.pm_join(P.pm_meet(ma, mb), P.pm_meet(ma, mc)))
        end
    end

    @testset "cloned_prefix_heavy_maps_are_logically_isolated_under_mutation" begin
        for seed in UInt64(0):UInt64(127)
            original_set = prefix_heavy_set(seed, 0x082e_fa98_ec4e_6c89)
            original = map_from_set(original_set)
            changed = P._pm_clone(original)
            removed = isempty(original_set) ? nothing : first(sort!(collect(original_set)))
            if removed !== nothing
                P.remove_val_at!(changed, removed)
            end
            inserted = UInt8[0xfe, UInt8((seed >> 8) & 0xff), UInt8(seed & 0xff), 0x01]
            P.set_val_at!(changed, inserted, P.UnitVal())

            # 🔑 THE POINT: the clone shares structure, so a write to one MUST NOT be visible in the
            # other. This is the COW check, expressed as an algebra test.
            @test set_from_map(original) == original_set
            expected = copy(original_set)
            removed !== nothing && delete!(expected, removed)
            push!(expected, inserted)
            @test set_from_map(changed) == expected
        end
    end

    @testset "prefix_valued_meet_is_associative_seed_44" begin
        seed = UInt64(44)
        a = map_from_set(prefix_heavy_set(seed, 0x243f_6a88_85a3_08d3))
        b = map_from_set(prefix_heavy_set(seed, 0x1319_8a2e_0370_7344))
        c = map_from_set(prefix_heavy_set(seed, 0xa409_3822_299f_31d0))
        @test set_from_map(P.pm_meet(P.pm_meet(a, b), c)) ==
              set_from_map(P.pm_meet(a, P.pm_meet(b, c)))
    end

    @testset "seeded_prefix_heavy_dual_distributivity_matches_btreeset_oracle" begin
        # Upstream: "Seeds 10, 77, and 287 are focused regressions for CoFree identity operand
        # selection and mixed value/onward-link exhaustiveness." Keep the full 512.
        for seed in UInt64(0):UInt64(511)
            a = prefix_heavy_set(seed, 0x243f_6a88_85a3_08d3)
            b = prefix_heavy_set(seed, 0x1319_8a2e_0370_7344)
            c = prefix_heavy_set(seed, 0xa409_3822_299f_31d0)
            ma, mb, mc = map_from_set(a), map_from_set(b), map_from_set(c)

            expected = union(a, intersect(b, c))
            @test set_from_map(P.pm_join(ma, P.pm_meet(mb, mc))) == expected
            @test set_from_map(P.pm_meet(P.pm_join(ma, mb), P.pm_join(ma, mc))) == expected
        end
    end
end
