"""
PathsSerialization — port of `pathmap/src/paths_serialization.rs`.

`.paths` is a zlib-compressed byte stream.  Each path is serialized as:
  [length: u32 LE][path bytes...]
The entire stream is a single zlib deflate block (level 7).

Uses `Zlib_jll` for the raw zlib C API.
"""

using Zlib_jll: Zlib_jll

# =====================================================================
# zlib constants and struct
# =====================================================================

const Z_OK = Cint(0)
const Z_STREAM_END = Cint(1)
const Z_NO_FLUSH = Cint(0)
const Z_FINISH = Cint(4)
const Z_DEFAULT_COMPRESSION = Cint(-1)
const ZLIB_VERSION = "1.2.11"   # version string passed to deflateInit2_

# z_stream layout differs by platform (LP64 vs LLP64):
#
# Linux / macOS (LP64): uLong = 64-bit
#   next_in  : Ptr{UInt8}  @  0  (8)
#   avail_in : UInt32      @  8  (4)  + 4 pad
#   total_in : UInt64      @ 16  (8)
#   next_out : Ptr{UInt8}  @ 24  (8)
#   avail_out: UInt32      @ 32  (4)  + 4 pad
#   total_out: UInt64      @ 40  (8)
#   msg      : Ptr{UInt8}  @ 48  (8)
#   state    : Ptr{Cvoid}  @ 56  (8)
#   zalloc   : Ptr{Cvoid}  @ 64  (8)
#   zfree    : Ptr{Cvoid}  @ 72  (8)
#   opaque   : Ptr{Cvoid}  @ 80  (8)
#   data_type: Int32       @ 88  (4)  + 4 pad
#   adler    : UInt64      @ 96  (8)
#   reserved : UInt64      @104  (8)
#   TOTAL = 112 bytes
#
# Windows (LLP64): uLong = 32-bit
#   next_in  : Ptr{UInt8}  @  0  (8)
#   avail_in : UInt32      @  8  (4)
#   total_in : UInt32      @ 12  (4)
#   next_out : Ptr{UInt8}  @ 16  (8)
#   avail_out: UInt32      @ 24  (4)
#   total_out: UInt32      @ 28  (4)
#   msg      : Ptr{UInt8}  @ 32  (8)
#   state    : Ptr{Cvoid}  @ 40  (8)
#   zalloc   : Ptr{Cvoid}  @ 48  (8)
#   zfree    : Ptr{Cvoid}  @ 56  (8)
#   opaque   : Ptr{Cvoid}  @ 64  (8)
#   data_type: Int32       @ 72  (4)
#   adler    : UInt32      @ 76  (4)
#   reserved : UInt32      @ 80  (4)
#   TOTAL = 84 bytes

if Sys.iswindows()
    mutable struct ZStream
        next_in::Ptr{UInt8}
        avail_in::UInt32
        total_in::UInt32
        next_out::Ptr{UInt8}
        avail_out::UInt32
        total_out::UInt32
        msg::Ptr{UInt8}
        state::Ptr{Cvoid}
        zalloc::Ptr{Cvoid}
        zfree::Ptr{Cvoid}
        opaque::Ptr{Cvoid}
        data_type::Int32
        adler::UInt32
        reserved::UInt32
        ZStream() =
            new(C_NULL, 0, 0, C_NULL, 0, 0, C_NULL, C_NULL, C_NULL, C_NULL, C_NULL, 0, 0, 0)
    end
else
    mutable struct ZStream
        next_in::Ptr{UInt8}
        avail_in::UInt32
        _pad1::UInt32
        total_in::UInt64
        next_out::Ptr{UInt8}
        avail_out::UInt32
        _pad2::UInt32
        total_out::UInt64
        msg::Ptr{UInt8}
        state::Ptr{Cvoid}
        zalloc::Ptr{Cvoid}
        zfree::Ptr{Cvoid}
        opaque::Ptr{Cvoid}
        data_type::Int32
        _pad3::Int32
        adler::UInt64
        reserved::UInt64
        ZStream() = new(
            C_NULL,
            0,
            0,
            0,
            C_NULL,
            0,
            0,
            0,
            C_NULL,
            C_NULL,
            C_NULL,
            C_NULL,
            C_NULL,
            0,
            0,
            0,
            0
        )
    end
end

# =====================================================================
# Statistics structs
# =====================================================================

struct SerializationStats
    bytes_out::Int
    bytes_in::Int
    path_count::Int
end

struct DeserializationStats
    bytes_in::Int
    bytes_out::Int
    path_count::Int
end

# =====================================================================
# zlib wrapper helpers
# =====================================================================

function _deflate_init!(strm::ZStream, level::Int=7)
    ret = GC.@preserve strm ccall(
        (:deflateInit2_, Zlib_jll.libz),
        Cint,
        (Ptr{ZStream}, Cint, Cint, Cint, Cint, Cint, Ptr{UInt8}, Cint),
        pointer_from_objref(strm),
        Cint(level),
        Cint(8),   # Z_DEFLATED
        Cint(15),  # windowBits
        Cint(8),   # memLevel
        Cint(0),   # Z_DEFAULT_STRATEGY
        pointer(ZLIB_VERSION),
        sizeof(ZStream)
    )
    ret == Z_OK || error("zlib deflateInit2_ failed: $ret")
    nothing
end

function _deflate!(
    strm::ZStream, flush::Cint, buf::Vector{UInt8}, output::Vector{UInt8}
)::Cint
    GC.@preserve strm buf output begin
        strm.next_out = pointer(output)
        strm.avail_out = UInt32(length(output))
        ret = ccall(
            (:deflate, Zlib_jll.libz),
            Cint,
            (Ptr{ZStream}, Cint),
            pointer_from_objref(strm),
            flush
        )
        ret
    end
end

function _deflate_end!(strm::ZStream)
    GC.@preserve strm ccall(
        (:deflateEnd, Zlib_jll.libz), Cint, (Ptr{ZStream},), pointer_from_objref(strm)
    )
end

function _inflate_init!(strm::ZStream)
    ret = GC.@preserve strm ccall(
        (:inflateInit2_, Zlib_jll.libz),
        Cint,
        (Ptr{ZStream}, Cint, Ptr{UInt8}, Cint),
        pointer_from_objref(strm),
        Cint(15),
        pointer(ZLIB_VERSION),
        sizeof(ZStream)
    )
    ret == Z_OK || error("zlib inflateInit2_ failed: $ret")
    nothing
end

function _inflate!(strm::ZStream, flush::Cint)::Cint
    GC.@preserve strm ccall(
        (:inflate, Zlib_jll.libz),
        Cint,
        (Ptr{ZStream}, Cint),
        pointer_from_objref(strm),
        flush
    )
end

function _inflate_end!(strm::ZStream)
    GC.@preserve strm ccall(
        (:inflateEnd, Zlib_jll.libz), Cint, (Ptr{ZStream},), pointer_from_objref(strm)
    )
end

# =====================================================================
# Core serialization engine
# =====================================================================

const PATHS_CHUNK = 4096

"""
    serialize_paths(m::PathMap, target::IO) → SerializationStats

Write all paths in `m` to `target` as a zlib-compressed `.paths` stream.
Mirrors `serialize_paths`.
"""
function serialize_paths(m::PathMap{V, A}, target::IO) where {V, A}
    serialize_paths_with_auxdata(m, target, (_, _, _) -> nothing)
end

"""
    serialize_paths_with_auxdata(m, target, fv) → SerializationStats

Like `serialize_paths` but calls `fv(index, path, val)` for each path.
Mirrors `serialize_paths_with_auxdata`.
"""
function serialize_paths_with_auxdata(
    m::PathMap{V, A}, target::IO, fv::Function
) where {V, A}
    k = Ref(0)
    z = read_zipper(m)
    # Use structural DFS (zipper_is_val) instead of _to_next_get_val!
    # so that PathMap{UnitVal} works correctly (nothing val ≠ no val).
    serialize_paths_from_funcs(
        target, () -> _paths_ser_to_next_val!(z), () -> begin
            p = collect(zipper_path(z))
            v = zipper_val(z)
            fv(k[], p, v)
            k[] += 1
            p
        end
    )
end

"""
DFS to_next_val using structural zipper_is_val (works for PathMap{UnitVal}).
"""
function _paths_ser_to_next_val!(z::ReadZipperCore)
    while true
        if zipper_descend_first_byte!(z)
            zipper_is_val(z) && return true
            if zipper_descend_until!(z)

                zipper_is_val(z) && return true
            end
        else
            advanced = false
            while !advanced
                if zipper_to_next_sibling_byte!(z)
                    advanced = true
                else
                    zipper_ascend_byte!(z) || return false
                    zipper_at_root(z) && return false
                end
            end
            zipper_is_val(z) && return true
        end
    end
end

"""
    serialize_paths_from_funcs(target, advance_f, path_f) → SerializationStats

Low-level: calls `advance_f()` until false, then `path_f()` for each path.
Mirrors `serialize_paths_from_funcs`.
"""
function serialize_paths_from_funcs(
    target::IO, advance_f::Function, path_f::Function
)::SerializationStats
    strm = ZStream()
    _deflate_init!(strm, 7)
    obuf = Vector{UInt8}(undef, PATHS_CHUNK)
    npaths = 0

    function _flush_output!(flush::Cint, input_bytes::AbstractVector{UInt8}, input_len::Int)
        GC.@preserve strm input_bytes obuf begin
            strm.next_in = pointer(input_bytes)
            strm.avail_in = UInt32(input_len)
            while true
                strm.next_out = pointer(obuf)
                strm.avail_out = UInt32(PATHS_CHUNK)
                ret = ccall(
                    (:deflate, Zlib_jll.libz),
                    Cint,
                    (Ptr{ZStream}, Cint),
                    pointer_from_objref(strm),
                    flush
                )
                ret == Cint(-2) && error("zlib deflate stream error")
                have = PATHS_CHUNK - Int(strm.avail_out)
                have > 0 && write(target, @view obuf[1:have])
                flush == Z_FINISH && ret == Z_STREAM_END && break
                flush != Z_FINISH && strm.avail_out != 0 && break
                flush == Z_FINISH && ret == Z_OK && continue
            end
        end
    end

    lenbuf = Vector{UInt8}(undef, 4)
    while advance_f()
        p = path_f()
        p === nothing && continue
        pv = p isa Vector{UInt8} ? p : collect(UInt8, p)
        l = length(pv)
        # Write 4-byte LE length
        lenbuf[1] = UInt8(l & 0xff)
        lenbuf[2] = UInt8((l >> 8) & 0xff)
        lenbuf[3] = UInt8((l >> 16) & 0xff)
        lenbuf[4] = UInt8((l >> 24) & 0xff)
        _flush_output!(Z_NO_FLUSH, lenbuf, 4)
        l > 0 && _flush_output!(Z_NO_FLUSH, pv, l)
        npaths += 1
    end
    _flush_output!(Z_FINISH, UInt8[], 0)
    _deflate_end!(strm)

    SerializationStats(Int(strm.total_out), Int(strm.total_in), npaths)
end

# =====================================================================
# Core deserialization engine
# =====================================================================

"""
    deserialize_paths(m::PathMap, source::IO, v) → DeserializationStats

Read paths from `.paths` zlib stream and insert them into `m` with value `v`.
Mirrors `deserialize_paths`.
"""
function deserialize_paths(m::PathMap{V, A}, source::IO, v::V) where {V, A}
    deserialize_paths_with_auxdata(m, source, (_, _) -> v)
end

"""
    deserialize_paths_with_auxdata(m, source, fv) → DeserializationStats

Like `deserialize_paths` but values are produced by `fv(index, path)`.
Mirrors `deserialize_paths_with_auxdata`.
"""
function deserialize_paths_with_auxdata(
    m::PathMap{V, A}, source::IO, fv::Function
) where {V, A}
    for_each_deserialized_path(source) do k, p
        v = fv(k, p)
        set_val_at!(m, p, v)
    end
end

"""
    for_each_deserialized_path(f, source::IO) → DeserializationStats

Decompress `.paths` stream from `source` and call `f(index, path)` for each path.
Mirrors `for_each_deserialized_path`.
"""
function for_each_deserialized_path(f::Function, source::IO)::DeserializationStats
    strm = ZStream()
    _inflate_init!(strm)

    ibuf = Vector{UInt8}(undef, 1024)
    obuf = Vector{UInt8}(undef, 2048)
    wzbuf = UInt8[]
    lbuf = zeros(UInt8, 4)
    lbuf_offset = 0
    l = UInt32(0)
    finished_path = true
    npaths = 0

    loop_done = false
    while !loop_done
        nb = readbytes!(source, ibuf, length(ibuf))
        nb == 0 && break

        GC.@preserve strm ibuf begin
            strm.next_in = pointer(ibuf)
            strm.avail_in = UInt32(nb)
        end

        while true  # decompressing inner loop
            GC.@preserve strm obuf begin
                strm.next_out = pointer(obuf)
                strm.avail_out = UInt32(length(obuf))
            end
            ret = _inflate!(strm, Z_NO_FLUSH)
            ret == Cint(-2) && error("zlib inflate stream error")

            if Int(strm.avail_out) == length(obuf)
                ret == Z_STREAM_END && (loop_done = true)
                break
            end

            decompressed_end = length(obuf) - Int(strm.avail_out)
            pos = 1

            # Descending inner loop: parse (length, path) pairs from obuf[1:decompressed_end]
            while pos <= decompressed_end
                if finished_path
                    # Read 4-byte LE length
                    have = min(decompressed_end - pos + 1, 4 - lbuf_offset)
                    copyto!(lbuf, lbuf_offset+1, obuf, pos, have)
                    pos += have
                    lbuf_offset += have
                    lbuf_offset < 4 && break
                    l = ltoh(reinterpret(UInt32, lbuf)[1])
                    lbuf_offset = 0
                    finished_path = false
                end

                remain = decompressed_end - pos + 1
                if remain >= Int(l)
                    append!(wzbuf, @view obuf[pos:(pos + Int(l) - 1)])
                    f(npaths, wzbuf)
                    empty!(wzbuf)
                    npaths += 1
                    pos += Int(l)
                    finished_path = true
                    l = UInt32(0)
                else
                    append!(wzbuf, @view obuf[pos:decompressed_end])
                    l -= UInt32(remain)
                    break
                end
            end

            ret == Z_STREAM_END && (loop_done = true)
            Int(strm.avail_in) == 0 && break
        end
    end

    _inflate_end!(strm)
    DeserializationStats(Int(strm.total_in), Int(strm.total_out), npaths)
end

# =====================================================================
# Exports
# =====================================================================

export SerializationStats, DeserializationStats
export serialize_paths, serialize_paths_with_auxdata, serialize_paths_from_funcs
export deserialize_paths, deserialize_paths_with_auxdata, for_each_deserialized_path
