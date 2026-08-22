# test_pzg_battery_ops.jl — the five ops ProductZipperG was MISSING, found by the battery.
#
# Upstream applies its zipper conformance battery to FOUR zipper types, ProductZipperG among them
# (product_zipper.rs:1811). Ours could not run it: five operations the battery exercises had no
# ProductZipperG implementation at all —
#
#   descend_indexed_byte      upstream implements directly (product_zipper.rs:716)
#   to_prev_sibling_byte      upstream implements directly (:756, = to_sibling_byte(false))
#   val                       upstream implements directly (:558, dispatches on factor_idx(true))
#   to_next_step              upstream inherits as a ZipperMoving TRAIT DEFAULT (zipper.rs:426)
#   descend_until_max_bytes   upstream inherits as a TRAIT DEFAULT (zipper.rs:326)
#
# The first three are port omissions. The last two upstream gets free from trait defaults and its
# forwarding macro passes straight through (zipper.rs:849) — we have no trait system, so they were
# simply absent. `_zpg_val` was missing from the dispatch table entirely, which is why `pzg_val`
# could not exist.
#
# This is what the battery bought: the gap was invisible because nothing exercised these ops on a
# product zipper. Same shape as the corrupt fixtures and the COW class — no probe, no defect.
#
# ⚠️ These assertions cover the ops in ISOLATION. Running the FULL battery against ProductZipperG
# (as upstream does) is the next step and is what would answer the open pzg_factor_count /
# last-factor-guard question in test/differential/ADAPTATIONS.md entry 2.
using Test, PathMap
const PM = PathMap.PathMap
const P = PathMap

@testset "ProductZipperG now implements the battery ops" begin
    m = PM{UnitVal}()
    for k in [
        "romane", "romanus", "romulus", "rubens", "ruber", "rubicon", "rubicundus", "rom'i"
    ]
        set_val_at!(m, Vector{UInt8}(k), UNIT_VAL)
    end
    mk() = P.ProductZipperG(read_zipper(m), P.ReadZipperCore{UnitVal, P.GlobalAlloc}[])
    pstr(z) = String(copy(collect(P.pzg_path(z))))

    z = mk()
    P.pzg_descend_to!(z, b"rom")
    @test P.pzg_descend_indexed_byte!(z, 0)
    @test pstr(z) == "rom'"
    @test P.pzg_ascend!(z, 1)
    @test P.pzg_descend_indexed_byte!(z, 1)
    @test pstr(z) == "roma"
    @test !P.pzg_descend_indexed_byte!(mk(), 99)

    z2 = mk()
    P.pzg_descend_to!(z2, b"roma")
    @test P.pzg_to_prev_sibling_byte!(z2)
    @test pstr(z2) == "rom'"

    z3 = mk()
    P.pzg_descend_to!(z3, b"romane")
    @test P.pzg_val(z3) === UNIT_VAL
    z3b = mk()
    P.pzg_descend_to!(z3b, b"roman")
    @test P.pzg_val(z3b) === nothing

    @test P.pzg_to_next_step!(mk())
    @test P.pzg_descend_until_max_bytes!(mk(), 2) isa Bool
    @test !P.pzg_descend_until_max_bytes!(mk(), 0)
end
