# precompile.jl — PrecompileTools workload for PathMap
#
# Covers the hot paths exercised by MORK and typical PathMap users.
# Julia executes this block during `Pkg.precompile()` and caches the
# compiled method instances, eliminating JIT latency on first use.

using PrecompileTools

@compile_workload begin
    # ── Core PathMap ops ──────────────────────────────────────────────
    m = PathMap{Int32}()
    set_val_at!(m, b"alpha", Int32(1))
    set_val_at!(m, b"beta", Int32(2))
    set_val_at!(m, b"gamma", Int32(3))
    set_val_at!(m, b"alpha:x", Int32(4))
    set_val_at!(m, b"alpha:y", Int32(5))

    get_val_at(m, b"alpha")
    get_val_at(m, b"missing")
    path_exists_at(m, b"alpha")
    val_count(m)
    remove_val_at!(m, b"gamma")

    # ── Read zipper ───────────────────────────────────────────────────
    rz = read_zipper(m)
    descend_to!(rz, b"alpha")
    val(rz)
    is_val(rz)
    path(rz)
    child_mask(rz)
    child_count(rz)
    ascend!(rz, 5)

    rz2 = read_zipper_at_path(m, b"alpha:")
    to_next_val!(rz2)
    val(rz2)

    # ── Write zipper ──────────────────────────────────────────────────
    m2 = PathMap{Int32}()
    wz = write_zipper(m2)
    descend_to!(wz, b"x:a")
    set_val!(wz, Int32(10))
    descend_to!(wz, b"x:b")
    set_val!(wz, Int32(20))
    reset!(wz)
    val(wz)
    child_mask(wz)

    wz2 = write_zipper_at_path(m2, b"x:")
    is_val(wz2)
    path_exists(wz2)

    # ── Algebraic ops ─────────────────────────────────────────────────
    a = PathMap{Nothing}()
    b = PathMap{Nothing}()
    set_val_at!(a, b"p", nothing)
    set_val_at!(a, b"q", nothing)
    set_val_at!(b, b"q", nothing)
    set_val_at!(b, b"r", nothing)

    pjoin(a, b)
    pmeet(a, b)
    psubtract(a, b)
    prestrict(a, b)

    # ── Write zipper algebraic ops ────────────────────────────────────
    wz3 = write_zipper(a)
    join_map_into!(wz3, b)

    # ── Graft / take ─────────────────────────────────────────────────
    m3 = PathMap{Int32}()
    set_val_at!(m3, b"sub:x", Int32(99))
    wz4 = write_zipper(m2)
    descend_to!(wz4, b"grafted:")
    graft_map!(wz4, m3)

    # ── Prefix ops ────────────────────────────────────────────────────
    m4 = PathMap{Int32}()
    set_val_at!(m4, b"foo:bar", Int32(1))
    wz5 = write_zipper_at_path(m4, b"foo:")
    insert_prefix!(wz5, b"ns:")
    wz6 = write_zipper_at_path(m4, b"ns:foo:")
    remove_prefix!(wz6, 3)

    # ── Morphisms ─────────────────────────────────────────────────────
    cata_cached(
        m, (mask, children, val) -> (val !== nothing ? 1 : 0) + reduce(+, children, init=0)
    )

    cata_side_effect(
        m,
        (mask, children, val, path) ->
            (val !== nothing ? 1 : 0) + reduce(+, children, init=0)
    )

    cata_jumping_cached(
        m,
        (mask, children, val, sub) ->
            (val !== nothing ? 1 : 0) + reduce(+, children, init=0)
    )

    cata_hybrid_cached(
        m,
        (mask, children, val, sub, path) ->
            ((val !== nothing ? 1 : 0) + reduce(+, children, init=0), 0)
    )

    map_hash(m)

    # ── Policy API ───────────────────────────────────────────────────
    mf = PathMap{Float64}()
    mg = PathMap{Float64}()
    set_val_at!(mf, b"x", 1.0)
    set_val_at!(mf, b"y", 2.0)
    set_val_at!(mg, b"y", 3.0)
    set_val_at!(mg, b"z", 4.0)

    pjoin_policy(mf, mg, SumPolicy())
    pjoin_policy(mf, mg, MaxPolicy())
    pjoin_policy(mf, mg, MinPolicy())
    pjoin_policy(mf, mg, TakeFirst())
    pjoin_policy(mf, mg, TakeLast())

    # ── Serialization ────────────────────────────────────────────────
    ms = PathMap{Nothing}()
    set_val_at!(ms, b"x:alpha", nothing)
    set_val_at!(ms, b"x:beta", nothing)
    io = IOBuffer()
    serialize_paths(ms, io)
    seekstart(io)
    ms2 = PathMap{Nothing}()
    deserialize_paths(ms2, io, nothing)
end
