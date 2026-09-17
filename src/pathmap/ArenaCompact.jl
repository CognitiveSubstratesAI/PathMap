"""
ArenaCompact — port of `pathmap/src/arena_compact.rs`.

Compact binary trie representation stored as a flat byte array.
Supports in-memory (Vector{UInt8}) and memory-mapped file backends.

## File format
  [magic: 8 bytes "ACTree03"][root_id: u64 LE][arena of nodes...]

## Varint encoding (ACTree03 branchless variant)
  - first byte ≤ 247 → value = first byte, total = 1 byte
  - first byte > 247 → nbytes = first - 247, read nbytes little-endian
"""

# =====================================================================
# Constants
# =====================================================================

const ACT_MAGIC = b"ACTree03"
const ACT_MAGIC_LEN = 8
const ACT_ROOT_OFFSET = ACT_MAGIC_LEN           # offset of u64 root_id
const ACT_ARENA_START = ACT_MAGIC_LEN + 8       # offset where nodes begin

const ACT_LINE_FLAG = UInt8(0x80)
const ACT_VALUE_FLAG = UInt8(0x40)
const ACT_VARINT_BIAS = UInt8(0xFF - 8)         # = 247

# =====================================================================
# NodeId / LineId
# =====================================================================

struct ACT_NodeId
    v::UInt64
end

struct ACT_LineId
    v::UInt64
end

const ACT_INVALID_LINE = ACT_LineId(typemax(UInt64))

# =====================================================================
# Node types
# =====================================================================

struct ACT_NodeBranch
    bytemask::ByteMask
    first_child::Union{Nothing, ACT_NodeId}
    value::Union{Nothing, UInt64}
end
ACT_NodeBranch() = ACT_NodeBranch(ByteMask(), nothing, nothing)

struct ACT_NodeLine
    path::ACT_LineId
    value::Union{Nothing, UInt64}
    child::Union{Nothing, ACT_NodeId}
end
ACT_NodeLine() = ACT_NodeLine(ACT_INVALID_LINE, nothing, nothing)

# Discriminated union
const ACTNode = Union{ACT_NodeBranch, ACT_NodeLine}

function act_node_child_count(n::ACT_NodeBranch)::Int
    count_bits(n.bytemask)
end
function act_node_child_count(n::ACT_NodeLine)::Int
    n.child !== nothing ? 1 : 0
end

# =====================================================================
# Varint read / write
# =====================================================================

"""
    act_read_varint(data, offset=1) → (value::UInt64, bytes_consumed::Int)

Read ACTree03 branchless varint from `data` starting at 1-based `offset`.
"""
function act_read_varint(data::AbstractVector{UInt8}, offset::Int=1)
    first = data[offset]
    if first <= ACT_VARINT_BIAS
        return (UInt64(first), 1)
    end
    nbytes = Int(first - ACT_VARINT_BIAS)
    v = UInt64(0)
    for i in 1:nbytes
        v |= UInt64(data[offset + i]) << ((i-1)*8)
    end
    (v, nbytes + 1)
end

"""
    act_push_varint!(buf::Vector{UInt8}, v::UInt64) → bytes_written::Int

Append ACTree03 branchless varint encoding of `v` to `buf`.
"""
function act_push_varint!(buf::Vector{UInt8}, v::UInt64)::Int
    if v <= ACT_VARINT_BIAS
        push!(buf, UInt8(v))
        return 1
    end
    nbytes = 8 - (leading_zeros(v) ÷ 8)
    push!(buf, ACT_VARINT_BIAS + UInt8(nbytes))
    # Write nbytes LE bytes of v
    for i in 1:nbytes

        push!(buf, UInt8((v >> ((i-1)*8)) & 0xff))
    end
    nbytes + 1
end

# =====================================================================
# Node read / write
# =====================================================================

"""
Read a node from `data` at 1-based offset `off`. Returns (node, bytes_consumed).
"""
function act_read_node(data::AbstractVector{UInt8}, node_id::ACT_NodeId)
    off = Int(node_id.v) + 1   # 1-based
    head = data[off]
    pos = 2

    if (head & ACT_LINE_FLAG) == 0
        # Branch node
        has_value = (head & ACT_VALUE_FLAG) != 0
        nchildren = Int(head & 0x3f)
        value = nothing
        if has_value
            v, n = act_read_varint(data, off + pos - 1)
            value = v
            pos += n
        end
        first_child = nothing
        if nchildren > 0
            raw, n = act_read_varint(data, off + pos - 1)
            first_child = ACT_NodeId(node_id.v - raw)
            pos += n
        end
        # child bytes / mask
        bytemask = ByteMask()
        if nchildren >= 32
            # 32 bytes = 4×u64 LE
            base = off + pos - 1
            # Read 4×u64 LE words for the 32-byte child mask
            words = ntuple(4) do i
                word_off = base + (i-1)*8
                w = UInt64(0)
                for j in 0:7

                    w |= UInt64(data[word_off + j]) << (j*8)
                end
                w
            end
            bytemask = ByteMask(words)
            pos += 32
        else
            for i in 1:nchildren
                bytemask = set(bytemask, data[off + pos - 1])
                pos += 1
            end
        end
        node = ACT_NodeBranch(bytemask, first_child, value)
        (node, pos - 1)
    else
        # Line node
        has_value = (head & ACT_VALUE_FLAG) != 0
        has_child = (head & 0x1) != 0
        value = nothing
        if has_value
            v, n = act_read_varint(data, off + pos - 1)
            value = v
            pos += n
        end
        child = nothing
        if has_child
            raw, n = act_read_varint(data, off + pos - 1)
            child = ACT_NodeId(node_id.v - raw)
            pos += n
        end
        raw, n = act_read_varint(data, off + pos - 1)
        path = ACT_LineId(node_id.v - raw)
        pos += n
        node = ACT_NodeLine(path, value, child)
        (node, pos - 1)
    end
end

"""
Write a branch node to `buf`. Returns the NodeId (position before write).
"""
function act_write_branch!(buf::Vector{UInt8}, node::ACT_NodeBranch, pos::UInt64)
    node_id = ACT_NodeId(pos)
    nchildren = count_bits(node.bytemask)
    vflag = node.value !== nothing ? ACT_VALUE_FLAG : UInt8(0)
    push!(buf, vflag | UInt8(min(nchildren, 32)))
    node.value !== nothing && act_push_varint!(buf, node.value)
    if node.first_child !== nothing
        offset = node_id.v - node.first_child.v
        act_push_varint!(buf, offset)
    end
    if nchildren >= 32
        for w in node.bytemask.bits   # Bits4 = NTuple{4,UInt64}
            tmp = UInt8[]
            for j in 0:7

                push!(tmp, UInt8((w>>(j*8))&0xff))
            end
            append!(buf, tmp)
        end
    else
        for b in iter(node.bytemask)
            push!(buf, b)
        end
    end
    node_id
end

"""
Write a line node to `buf`. Returns the NodeId.
"""
function act_write_line!(buf::Vector{UInt8}, node::ACT_NodeLine, pos::UInt64)
    node_id = ACT_NodeId(pos)
    cflag = node.child !== nothing ? UInt8(0x1) : UInt8(0)
    vflag = node.value !== nothing ? ACT_VALUE_FLAG : UInt8(0)
    push!(buf, ACT_LINE_FLAG | vflag | cflag)
    node.value !== nothing && act_push_varint!(buf, node.value)
    if node.child !== nothing
        offset = node_id.v - node.child.v
        act_push_varint!(buf, offset)
    end
    offset = node_id.v - node.path.v
    act_push_varint!(buf, offset)
    node_id
end

function act_write_node!(buf::Vector{UInt8}, node::ACTNode, pos::UInt64)
    if node isa ACT_NodeBranch
        act_write_branch!(buf, node, pos)
    else
        act_write_line!(buf, node, pos)
    end
end

# =====================================================================
# ArenaCompactTree — in-memory (Vec{UInt8}) variant
# =====================================================================

"""
    ArenaCompactTree

Compact binary trie backed by `Vector{UInt8}` (in-memory) or a
memory-mapped byte slice.  Mirrors `ArenaCompactTree<Vec<u8>>` and
`ArenaCompactTree<Mmap>` in arena_compact.rs.
"""
mutable struct ArenaCompactTree
    data::Vector{UInt8}   # raw bytes (mutable for Vec; copy for Mmap)
    position::UInt64          # write cursor (past last written byte)
    line_map::Dict{UInt64, ACT_LineId}   # hash → LineId cache
    last_val::Ref{UInt64}     # cached last-read value (replaces Cell<u64>)
end

function ArenaCompactTree()
    data = copy(ACT_MAGIC)
    append!(data, zeros(UInt8, 8))   # placeholder for root_id
    ArenaCompactTree(data, UInt64(length(data)), Dict{UInt64, ACT_LineId}(), Ref(UInt64(0)))
end

# Read helpers
function act_get_node(tree::ArenaCompactTree, node_id::ACT_NodeId)
    act_read_node(tree.data, node_id)
end

function act_get_line(tree::ArenaCompactTree, line_id::ACT_LineId)
    off = Int(line_id.v) + 1
    len, n = act_read_varint(tree.data, off)
    view(tree.data, (off + n):(off + n + Int(len) - 1))
end

function act_get_root(tree::ArenaCompactTree)
    root_off = ACT_MAGIC_LEN + 1   # 1-based
    root_id_le = reinterpret(UInt64, @view tree.data[root_off:(root_off + 7)])[1]
    root_id = ACT_NodeId(ltoh(root_id_le))
    (act_get_node(tree, root_id)[1], root_id)
end

"""
Walk to the nth sibling of node_id. Returns (node, actual_node_id, next_node_id).
"""
function act_nth_node(tree::ArenaCompactTree, node_id::ACT_NodeId, n::Int)
    node, sz = act_get_node(tree, node_id)
    next = ACT_NodeId(node_id.v + sz)
    cur_id = node_id
    for _ in 1:n
        cur_id = next
        node, sz = act_get_node(tree, cur_id)
        next = ACT_NodeId(cur_id.v + sz)
    end
    (node, cur_id, next)
end

# Write helpers (Vec only)
function act_push_node!(tree::ArenaCompactTree, node::ACTNode)
    pos = tree.position
    nid = act_write_node!(tree.data, node, pos)
    tree.position = UInt64(length(tree.data))
    nid
end

function act_set_root!(tree::ArenaCompactTree, node::ACTNode)
    nid = act_push_node!(tree, node)
    # Write root_id at bytes [9..16]
    v = nid.v
    for i in 1:8

        tree.data[ACT_MAGIC_LEN + i] = UInt8((v >> ((i-1)*8)) & 0xff)
    end
    nid
end

function act_add_path!(tree::ArenaCompactTree, path::AbstractVector{UInt8})
    h = hash(path)
    if haskey(tree.line_map, h)
        lid = tree.line_map[h]
        act_get_line(tree, lid) == path && return lid
    end
    lid = ACT_LineId(tree.position)
    act_push_varint!(tree.data, UInt64(length(path)))
    append!(tree.data, path)
    tree.position = UInt64(length(tree.data))
    tree.line_map[h] = lid
    lid
end

function act_finalize!(tree::ArenaCompactTree)
    # Append 8 zero bytes so varint reads never go OOB
    append!(tree.data, zeros(UInt8, 8))
    tree.position = UInt64(length(tree.data))
end

"""
    act_get_val_at(tree, path) → Union{Nothing, UInt64}

Return the value stored at `path`, or `nothing` if not found.
Mirrors `ArenaCompactTree::get_val_at`.
"""
function act_get_val_at(tree::ArenaCompactTree, path)
    pv = collect(UInt8, path)
    root, _ = act_get_root(tree)
    cur = root
    i = 1
    while true
        if cur isa ACT_NodeLine
            lpath = act_get_line(tree, cur.path)
            starts_with(pv, i, lpath) || return nothing
            i += length(lpath)
            if i > length(pv) && cur.value !== nothing
                return cur.value
            end
            cur.child !== nothing || return nothing
            cur = act_get_node(tree, cur.child)[1]
        else  # ACT_NodeBranch
            if i > length(pv)
                return cur.value
            end
            test_bit(cur.bytemask, pv[i]) || return nothing
            idx = Int(index_of(cur.bytemask, pv[i]))
            cur = act_nth_node(tree, cur.first_child, idx)[1]
            i += 1
        end
    end
end

"""
Helper: test if `pv[i..]` starts with `prefix`.
"""
function starts_with(pv::AbstractVector{UInt8}, start::Int, prefix::AbstractVector{UInt8})
    length(pv) - start + 1 >= length(prefix) &&
        @view(pv[start:(start + length(prefix) - 1)]) == prefix
end

# =====================================================================
# Build ArenaCompactTree from a PathMap (using cata_jumping_side_effect)
# =====================================================================

"""
    act_from_zipper(m::PathMap, map_val::Function) → ArenaCompactTree

Build a compact arena tree from a PathMaps.  `map_val(v::V) → UInt64`.
Mirrors `ArenaCompactTree::from_zipper` / `build_arena_tree`.
"""
function act_from_zipper(m::PathMap{V, A}, map_val::Function) where {V, A}
    tree = ArenaCompactTree()
    root = cata_jumping_side_effect(
        m,
        (mask, children, jump, val, path) -> begin
            first_child = nothing
            for child in children
                id = act_push_node!(tree, child)
                first_child === nothing && (first_child = id)
            end
            node = ACT_NodeBranch(
                mask, first_child, val !== nothing ? map_val(val) : nothing
            )
            if jump == 0
                return node
            end
            # Jumping: wrap in a line node
            line_path = view(path, (length(path) - jump + 1):length(path))
            line = ACT_NodeLine(
                act_add_path!(tree, collect(UInt8, line_path)),
                if !isempty(children)
                    nothing
                else
                    (val !== nothing ? map_val(val) : nothing)
                end,
                !isempty(children) ? Some_NodeId(act_push_node!(tree, node)) : nothing
            )
            line
        end
    )
    act_set_root!(tree, root)
    act_finalize!(tree)
    tree
end

# Tiny helper so the code above compiles cleanly (optional child wrapping)
Some_NodeId(id::ACT_NodeId) = id

# =====================================================================
# Integrity — DELIBERATELY NOT HERE. Read this before adding it.
# =====================================================================
#
# SURVEYED 2026-08-04 across upstream PathMap/MORK, CeTTa, JeTTa, hyperon-experimental and PeTTa.
# Two independent conclusions, and BOTH say a digest does not belong in this file.
#
# (1) THE ACTree03 HEADER CANNOT CARRY ONE.
#
# Upstream's layout is `[MAGIC 8][root_id u64 LE][arena]` (arena_compact.rs:15-27,59-62,141-145) —
# byte-identical to ours, with no length field, no checksum, and no version field beyond the digits
# in the magic. Its versioning is a hard magic bump with no migrator (ACTree01 -> 02 relative
# offsets, 02 -> 03 branchless varint), so ANY header change makes our files unreadable by upstream
# AND upstream's unreadable by us. Integrity therefore lives in a SIDECAR, never in the file.
#
# What the other implementations do, since it is the reason this is worth having at all:
#   * upstream PathMap  — magic check only; the ACT reader trusts every node offset, so in-bounds
#                         corruption is a SILENT MISPARSE. `NodeId`'s own doc concedes a bad id "can
#                         catastrophically break the implementation" (arena_compact.rs:98-107).
#   * upstream MORK     — three persistence paths, and the two that DO detect corruption get it by
#                         accident: `.paths` inherits zlib's Adler-32, symbols inherit ZIP's CRC-32.
#                         `.act`, the main one, gets nothing.
#   * hyperon-experimental — no binary space persistence at all; `.metta` source re-parse only.
#   * PeTTa            — same; its one disk cache (`.qlf`) is gated on `exists_file` alone.
#   * CeTTa            — delegates ACT to MORK. But it writes via a staged temp path + atomic
#                         rename, which is strictly better than what we did, and is adopted below.
#   * JeTTa            — the only one with a real digest: SHA-256 over a canonical sorted rendering.
#                         But it is computed at COMPILE time and compared as an opaque string; it is
#                         never recomputed from the bytes read off disk, so it catches a stale build
#                         artifact and not corruption. `act_verify` below closes exactly that gap.
#
# (2) IT IS THE WRONG LAYER ANYWAY. Whitepaper §2.6/§3.8: the State Management Subsystem "treats
# engine internals as opaque" and carries identity as `CheckpointRef` + `ChangeDigest` per COGNITIVE
# EPOCH — never inside the trie image. Content IDs live in `S_evid` ("immutable evidence shards +
# CIDs", §5) and are already implemented at `WorldModel/src/Braid.jl` `content_id` — canonical
# length-prefixed SHA-256, truncated to 128 bits because MORK's Rule of 64 caps a symbol at 63 bytes.
#
# A `.sha256` sidecar WAS built here on 2026-08-04 and REMOVED the same day: it added a `SHA`
# dependency to PathMap, which broke the manifest of all ten downstream packages, in exchange for a
# feature at a layer that already has one. The upstream threat model is "trusted, self-produced
# input"; the corruption that actually bit us was ours (see the cata note in Morphisms.jl), and a
# checksum here would have flagged it without ever explaining it.
#
# If you need tamper-evidence for a persisted Space, add it at the SMS/epoch layer, not this file.

"""
    act_save(tree::ArenaCompactTree, path::AbstractString)

Write the compact tree to a file — exactly upstream's `ACTree03` byte image.

The write is ATOMIC: bytes go to a temp file in the same directory and are `mv`'d into place, so a
crash or a full disk cannot leave a half-written file at `path` for a later `act_open` to misparse.
Adopted from CeTTa's `bridge_space_dump_act_transactional`, which stages and renames for exactly
this reason; ours previously wrote straight to `path`. Same-directory is required — `rename` is only
atomic within a filesystem.

⚠️ INTEGRITY IS DELIBERATELY ABSENT HERE — see the note above `_act_check_header`.
"""
function act_save(tree::ArenaCompactTree, path::AbstractString)
    dir = dirname(abspath(path))
    tmp = tempname(dir; cleanup=false)
    try
        open(tmp, "w") do io
            write(io, tree.data)
        end
        mv(tmp, path; force=true)          # atomic within one filesystem
    catch
        isfile(tmp) && rm(tmp; force=true)  # never leave a stray temp behind
        rethrow()
    end
    path
end

# Minimum bytes any readable ACTree03 file must have: magic + root_id. Upstream ALREADY has this
# guard — `merge_zipper_into_file` checks `old.len() < MAGIC_LENGTH + U64_SIZE + MAX_VARINT_SIZE`
# (arena_compact.rs:1298-1305) — but its `open_mmap` does not, so upstream PANICS on a 1..7-byte
# file when it slices `&memmap[..MAGIC_LENGTH]`. Applying upstream's own guard on the open path is
# consistency, not deviation.
const ACT_MIN_FILE_LEN = ACT_MAGIC_LEN + 8

"Shared header validation for both open paths. Returns nothing; throws a typed error on bad input."
function _act_check_header(data::AbstractVector{UInt8}, path::AbstractString)
    # NOT `@assert`: Julia documents assertions as removable at some optimisation levels, so using
    # one to validate FILE INPUT means the check can vanish. Both open paths used `@assert` before.
    if length(data) < ACT_MIN_FILE_LEN
        throw(
            ArgumentError(
                "$path is not an ACTree03 file: $(length(data)) bytes, need at least $ACT_MIN_FILE_LEN"
            )
        )
    end
    if view(data, 1:ACT_MAGIC_LEN) != ACT_MAGIC
        throw(
            ArgumentError(
                "$path is not an ACTree03 file: bad magic " *
                "$(repr(String(copy(data[1:ACT_MAGIC_LEN]))))"
            )
        )
    end
    nothing
end

"""
    act_open(path::AbstractString) → ArenaCompactTree

Load a compact tree from a file (copies bytes into memory).
Mirrors `ArenaCompactTree::open_mmap` (memory-mapped semantics optional in Julia).
"""
function act_open(path::AbstractString)
    data = read(path)
    _act_check_header(data, path)
    tree = ArenaCompactTree(
        data, UInt64(length(data)), Dict{UInt64, ACT_LineId}(), Ref(UInt64(0))
    )
    tree
end

"""
    act_open_mmap(path::AbstractString) → ArenaCompactTree

Open a compact tree file for **read-only** access via a true OS memory map.
Mirrors `ArenaCompactTree<Mmap>::open_mmap` in arena_compact.rs (which backs the
trie with `memmap2::Mmap`).

The backing `data` is a lazy `Mmap.mmap` of the file: the OS pages bytes in on
access, so the full file is **not** read into RAM — only the touched
pages (faulted in by `act_get_node`/`act_get_line` as a query descends).
This is the "space too large to fit in memory → access as needed" path.

The map is read-only (file opened `"r"`); only the read helpers may be used —
the write helpers (`act_push_node!` etc.) assume an owned `Vector{UInt8}` and
must not be called on an mmap-backed tree.  The mapping survives the fd `close`
(POSIX: `mmap` holds its own reference); the returned array's finalizer unmaps.
"""
function act_open_mmap(path::AbstractString)
    io = open(path, "r")
    data = Mmap.mmap(io, Vector{UInt8})   # lazy, read-only; OS faults pages on access
    close(io)
    _act_check_header(data, path)
    ArenaCompactTree(data, UInt64(length(data)), Dict{UInt64, ACT_LineId}(), Ref(UInt64(0)))
end


# =====================================================================
# ACTZipper — read-only zipper over ArenaCompactTree
# =====================================================================
#
# Upstream `ACTZipper<'tree, Storage, Value>` (arena_compact.rs:2303 @ f477a91) and its trait impls:
# `Zipper` :2429, `ZipperPath` :2505, `ZipperAbsolutePath` :2512, `ZipperValues`/`ZipperValuesAt`
# :2800-2825, `ZipperForking` :2834, `ZipperConcrete` :2895, `ZipperMoving` :2909 and
# `ZipperIteration` :3187. Value type is upstream's `Value = u64` instantiation.
#
# Everything upstream leaves as a trait default (`descend_to_check`, `descend_to_existing_byte`,
# `descend_last_byte`, `descend_until`, `descend_until_max_bytes*`, `ascend_byte`, `to_next_step*`,
# `move_to_path`, `descend_last_path*`, `to_next_k_path*`, `to_next_get_val*`) is a method on
# `AbstractZipper` in src/zipper/ZipperTraits.jl and is NOT repeated here.

mutable struct _ACTFrame
    node_id::ACT_NodeId
    child_count::Int
    child_index::Int
    next_id::Union{Nothing, ACT_NodeId}
    node_depth::Int   # bytes consumed within current line node
end

function _ACTFrame(node::ACTNode, node_id::ACT_NodeId)
    _ACTFrame(node_id, act_node_child_count(node), 0, nothing, 0)
end

# 🔴 A FRAME IS A VALUE UPSTREAM (`#[derive(Clone)] struct StackFrame`, arena_compact.rs:2283), so
# `stack.clone()` there copies every frame. Ours is a MUTABLE struct, so `copy(z.stack)` would hand
# the clone the very same frame objects — and `fork_read_zipper`/`val_count` both clone and then
# move, which mutates `node_depth`/`child_index` of the ORIGINAL zipper's frames.
Base.copy(f::_ACTFrame) = _ACTFrame(f.node_id, f.child_count, f.child_index, f.next_id, f.node_depth)

"""
    ACTZipper

Read-only zipper over an `ArenaCompactTree`. Mirrors `ACTZipper<Storage, Value>`
(arena_compact.rs:2303); `origin_*` remember where the zipper's root sits.
"""
mutable struct ACTZipper <: AbstractZipper
    tree::ArenaCompactTree
    cur_node::ACTNode
    stack::Vector{_ACTFrame}
    path::Vector{UInt8}
    origin_depth::Int
    origin_ndepth::Int     # origin_node_depth
    invalid::Int
    origin_invalid::Int
end

# upstream `ACTZipper::from_tree` (arena_compact.rs:2381)
function ACTZipper(tree::ArenaCompactTree)
    root, root_id = act_get_root(tree)
    ACTZipper(tree, root, [_ACTFrame(root, root_id)], UInt8[], 0, 0, 0, 0)
end

# upstream `ACTZipper::clone` (arena_compact.rs:2318)
function Base.copy(z::ACTZipper)
    ACTZipper(
        z.tree,
        z.cur_node,
        [copy(f) for f in z.stack],
        copy(z.path),
        z.origin_depth,
        z.origin_ndepth,
        z.invalid,
        z.origin_invalid
    )
end

# upstream `ACTZipper::with_root_here` (arena_compact.rs:2396): re-root the zipper at its focus.
# `origin_node_depth` is read AFTER the swap (ours read it before, off the OLD stack top) and
# `origin_invalid` is captured so `reset!` restores a root that sits on a non-existent path (cab3ed7).
function _act_with_root_here!(z::ACTZipper)
    z.origin_depth = length(z.path)
    z.origin_invalid = z.invalid
    if length(z.stack) > 1
        last_frame = z.stack[end]
        z.stack[end] = z.stack[1]
        z.stack[1] = last_frame
        resize!(z.stack, 1)
    end
    z.origin_ndepth = z.stack[1].node_depth
    z
end

@inline _act_bytes(p::AbstractVector{UInt8}) = p
@inline _act_bytes(p) = collect(UInt8, p)

"""
    read_zipper(tree::ArenaCompactTree) → ACTZipper

Read-only zipper over `tree`; upstream `ArenaCompactTree::read_zipper` (arena_compact.rs:2361).
"""
read_zipper(tree::ArenaCompactTree) = ACTZipper(tree)

"""
    read_zipper_at_path(tree::ArenaCompactTree, path) → ACTZipper

Zipper pre-positioned at `path`; upstream `ArenaCompactTree::read_zipper_at_path`
(arena_compact.rs:2366) — descend, then re-root at the focus.

This is the canonical constructor extended to `ArenaCompactTree`, so a caller can pass either an
in-RAM `PathMap` or an mmap'd ACT trie and get a zipper that answers the same generic functions;
every zipper-algebra routine becomes transparently mmap-capable.
"""
function read_zipper_at_path(tree::ArenaCompactTree, p)
    z = ACTZipper(tree)
    descend_to!(z, p)
    _act_with_root_here!(z)
end

# =====================================================================
# Zipper (arena_compact.rs:2429)
# =====================================================================

path_exists(z::ACTZipper) = z.invalid == 0

function is_val(z::ACTZipper)
    z.invalid > 0 && return false
    cur = z.cur_node
    if cur isa ACT_NodeBranch
        return cur.value !== nothing
    else
        cur.value === nothing && return false
        frame = z.stack[end]
        lpath = act_get_line(z.tree, cur.path)
        return length(lpath) == frame.node_depth
    end
end

function child_count(z::ACTZipper)::Int
    z.invalid > 0 && return 0
    cur = z.cur_node
    if cur isa ACT_NodeBranch
        return count_bits(cur.bytemask)
    else
        frame = z.stack[end]
        lpath = act_get_line(z.tree, cur.path)
        return frame.node_depth < length(lpath) ? 1 : 0
    end
end

function child_mask(z::ACTZipper)
    z.invalid > 0 && return ByteMask()
    cur = z.cur_node
    if cur isa ACT_NodeBranch
        return cur.bytemask
    else
        frame = z.stack[end]
        lpath = act_get_line(z.tree, cur.path)
        frame.node_depth >= length(lpath) && return ByteMask()
        return ByteMask(lpath[frame.node_depth + 1])
    end
end

# =====================================================================
# ZipperPath (:2505) / ZipperAbsolutePath (:2512)
# =====================================================================

path(z::ACTZipper) = view(z.path, (z.origin_depth + 1):length(z.path))
origin_path(z::ACTZipper) = z.path
root_prefix_path(z::ACTZipper) = view(z.path, 1:z.origin_depth)

# =====================================================================
# ZipperValues / ZipperValuesAt / ZipperReadOnlyValues (:2800-2830)
# =====================================================================

# upstream `ACTZipper::get_value` (arena_compact.rs:2561): the varint value follows the head byte.
function _act_get_value(z::ACTZipper)::Union{Nothing, UInt64}
    is_val(z) || return nothing
    frame = z.stack[end]
    data = z.tree.data
    off = Int(frame.node_id.v) + 1
    head = data[off]
    head & ACT_VALUE_FLAG == 0 && return nothing
    v, _ = act_read_varint(data, off + 1)
    v
end

val(z::ACTZipper) = _act_get_value(z)
get_val(z::ACTZipper) = _act_get_value(z)

# upstream `ACTZipper::with_lookup_from_focus` (:2576) + `get_value_at` (:2627): resolve a path
# RELATIVE TO THE FOCUS without moving the zipper (so a miss cannot strand the focus).
function _act_get_value_at(z::ACTZipper, p::AbstractVector{UInt8})::Union{Nothing, UInt64}
    z.invalid > 0 && return nothing
    cur = z.cur_node
    node_depth = z.stack[end].node_depth
    i = 1
    while true
        if cur isa ACT_NodeBranch
            i > length(p) && return cur.value
            test_bit(cur.bytemask, p[i]) || return nothing
            cur.first_child === nothing && return nothing
            idx = Int(index_of(cur.bytemask, p[i]))
            cur = act_nth_node(z.tree, cur.first_child::ACT_NodeId, idx)[1]
            node_depth = 0
            i += 1
        else
            lpath = act_get_line(z.tree, cur.path)
            rest = view(lpath, (node_depth + 1):length(lpath))
            # upstream `starts_with(path, rest_path)`: the remaining path must cover the whole of
            # the line's tail. Stopping INSIDE a line node is a miss either way — a line carries its
            # value only at its end (upstream's `node_depth < line_path.len() => None`).
            starts_with(p, i, rest) || return nothing
            i += length(rest)
            if i > length(p) && cur.value !== nothing
                return cur.value
            end
            cur.child === nothing && return nothing
            cur = act_get_node(z.tree, cur.child::ACT_NodeId)[1]
            node_depth = 0
        end
    end
end

val_at(z::ACTZipper, p::AbstractVector{UInt8}) = _act_get_value_at(z, p)
val_at(z::ACTZipper, p) = _act_get_value_at(z, _act_bytes(p))
get_val_at(z::ACTZipper, p) = val_at(z, p)

# =====================================================================
# ZipperForking (:2834) / ZipperConcrete (:2895)
# =====================================================================

fork_read_zipper(z::ACTZipper) = _act_with_root_here!(copy(z))

# An ACT trie is a flat arena: node sharing is invisible from a node id (upstream returns the same).
shared_node_id(z::ACTZipper) = nothing
is_shared(z::ACTZipper) = false

# =====================================================================
# ZipperMoving (arena_compact.rs:2909)
# =====================================================================

depth(z::ACTZipper) = max(length(z.path) - z.origin_depth, 0)
at_root(z::ACTZipper) = length(z.path) <= z.origin_depth

# arena_compact.rs:2913-2919: the LAST byte of the whole buffer — at the root that is the last byte
# of the root prefix, which is why `at_root` (not `focus_byte`) decides whether a move is possible.
focus_byte(z::ACTZipper) = isempty(z.path) ? nothing : @inbounds(z.path[end])

# upstream `ACTZipper::reset` (arena_compact.rs:2922, cab3ed7): truncate to the ROOT FRAME — which
# is kept, not rebuilt, so its `child_index`/`next_id` cache for that node stays valid — and restore
# the origin's `node_depth` and `invalid`.
function reset!(z::ACTZipper)
    z.cur_node = act_get_node(z.tree, z.stack[1].node_id)[1]
    resize!(z.stack, 1)
    z.stack[1].node_depth = z.origin_ndepth
    resize!(z.path, z.origin_depth)
    z.invalid = z.origin_invalid
    nothing
end

# upstream `ACTZipper::val_count` (arena_compact.rs:2938): order-N, counts the focus itself.
function val_count(z::ACTZipper)::Int
    z2 = copy(z)
    reset!(z2)
    n = is_val(z2) ? 1 : 0
    while to_next_val!(z2)
        n += 1
    end
    n
end

# upstream `ACTZipper::descend_cond` (arena_compact.rs:2718), shared by `descend_to_existing!`
# (`on_val == false`) and `descend_to_val!` (`on_val == true`); returns the bytes descended.
function _act_descend_cond!(z::ACTZipper, p::AbstractVector{UInt8}, on_val::Bool)
    z.invalid > 0 && return 0
    descended = 0
    i = 1
    while i <= length(p)
        cur = z.cur_node
        if cur isa ACT_NodeLine
            frame = z.stack[end]
            lpath = act_get_line(z.tree, cur.path)
            rest = view(lpath, (frame.node_depth + 1):length(lpath))
            common = find_prefix_overlap(view(p, i:length(p)), rest)
            descended += common
            i += common
            into_child = length(rest) == common && cur.child !== nothing
            line_child_hack = into_child ? 1 : 0
            frame.node_depth += common - line_child_hack
            append!(z.path, view(rest, 1:common))
            on_val && descended > 0 && cur.value !== nothing && break
            common < length(rest) && break
            cur.child === nothing && break
            line_child = cur.child::ACT_NodeId
            child_node, _ = act_get_node(z.tree, line_child)
            push!(z.stack, _ACTFrame(child_node, line_child))
            z.cur_node = child_node
        else  # ACT_NodeBranch
            on_val && descended > 0 && cur.value !== nothing && break
            test_bit(cur.bytemask, p[i]) || break
            idx = Int(index_of(cur.bytemask, p[i]))
            frame = z.stack[end]
            child_id = if frame.next_id !== nothing && frame.child_index + 1 == idx
                frame.next_id::ACT_NodeId   # the node right after the last one we stepped into
            else
                act_nth_node(z.tree, cur.first_child::ACT_NodeId, idx)[2]
            end
            child_node, child_sz = act_get_node(z.tree, child_id)
            frame.child_index = idx
            # upstream keeps the cache live by storing the node AFTER the one descended into
            # (arena_compact.rs:2765); ours cleared it in the fast arm, losing the optimisation.
            frame.next_id = ACT_NodeId(child_id.v + child_sz)
            push!(z.stack, _ACTFrame(child_node, child_id))
            z.cur_node = child_node
            push!(z.path, p[i])
            i += 1
            descended += 1
        end
    end
    descended
end

# upstream `ACTZipper::descend_to` (arena_compact.rs:2955): the focus moves whether or not the path
# exists; the non-existent tail is counted in `invalid`.
function descend_to!(z::ACTZipper, k)
    kv = _act_bytes(k)
    n = length(kv)
    descended = _act_descend_cond!(z, kv, false)
    if descended != n
        append!(z.path, view(kv, (descended + 1):n))
        z.invalid += n - descended
    end
    nothing
end

descend_to_existing!(z::ACTZipper, k) = _act_descend_cond!(z, _act_bytes(k), false)   # :2974
descend_to_val!(z::ACTZipper, k) = _act_descend_cond!(z, _act_bytes(k), true)         # :2985

# upstream `ACTZipper::descend_indexed_byte` (arena_compact.rs:3004): the descended byte, or
# `nothing` — with no move — when `idx` is out of range.
function descend_indexed_byte!(z::ACTZipper, idx::Int)::Union{Nothing, UInt8}
    z.invalid > 0 && return nothing
    frame = z.stack[end]
    cur = z.cur_node
    child_id::Union{Nothing, ACT_NodeId} = nothing
    descended_byte::Union{Nothing, UInt8} = nothing
    if cur isa ACT_NodeLine
        lpath = act_get_line(z.tree, cur.path)
        rest = view(lpath, (frame.node_depth + 1):length(lpath))
        (idx != 0 || isempty(rest)) && return nothing
        descended_byte = rest[1]
        push!(z.path, rest[1])
        if length(rest) == 1 && cur.child !== nothing
            child_id = cur.child
        else
            frame.node_depth += 1
            return descended_byte
        end
    else  # ACT_NodeBranch
        idx > frame.child_count && return nothing   # upstream tests `>`, not `>=` (:3034)
        byte = indexed_bit(cur.bytemask, idx, true)
        byte === nothing && return nothing
        descended_byte = byte
        child_id = if frame.next_id !== nothing && frame.child_index + 1 == idx
            frame.next_id::ACT_NodeId
        else
            act_nth_node(z.tree, cur.first_child::ACT_NodeId, idx)[2]
        end
        push!(z.path, byte)
    end
    child_id === nothing && return nothing
    child_node, child_sz = act_get_node(z.tree, child_id)
    frame.child_index = idx
    frame.next_id = ACT_NodeId(child_id.v + child_sz)
    push!(z.stack, _ACTFrame(child_node, child_id))
    z.cur_node = child_node
    descended_byte
end

# upstream `ACTZipper::descend_until_observed` (arena_compact.rs:3070): descend while the focus has
# exactly one child, stopping ON a value or a branch. The stop test is on the node STEPPED ONTO —
# a valued branch under a line node used to be walked straight past (measured on
# {"band"=>1,"bandana"=>2}: the walk went "b" -> "banda" and "band" was never enumerated).
function descend_until_observed!(z::ACTZipper, obs)
    descended = false
    while child_count(z) == 1
        frame = z.stack[end]
        cur = z.cur_node
        child_id::Union{Nothing, ACT_NodeId} = nothing
        if cur isa ACT_NodeLine
            lpath = act_get_line(z.tree, cur.path)
            rest = view(lpath, (frame.node_depth + 1):length(lpath))
            line_child_hack = cur.child === nothing ? 0 : 1
            frame.node_depth += length(rest) - line_child_hack
            append!(z.path, rest)
            descend_to!(obs, rest)
            child_id = cur.child
            if cur.value !== nothing
                descended = true
                break
            end
        else  # ACT_NodeBranch
            byte = indexed_bit(cur.bytemask, 0, true)   # upstream `bytemask.iter().next()`
            byte === nothing && break
            push!(z.path, byte)
            descend_to_byte!(obs, byte)
            child_id = cur.first_child
        end
        descended = true
        if child_id !== nothing
            child_node, child_sz = act_get_node(z.tree, child_id)
            frame.child_index = 0
            frame.next_id = ACT_NodeId(child_id.v + child_sz)
            child_frame = _ACTFrame(child_node, child_id)
            nchildren = child_frame.child_count
            push!(z.stack, child_frame)
            z.cur_node = child_node
            if child_node isa ACT_NodeBranch && (child_node.value !== nothing || nchildren > 1)
                break
            end
        end
    end
    descended
end

# upstream `ACTZipper::ascend_invalid` (arena_compact.rs:2645): drop the non-existent tail of the
# path; returns the steps ascended. `limit === nothing` is upstream's `None` (no bound).
function _act_ascend_invalid!(z::ACTZipper, limit::Union{Nothing, Int})::Int
    z.invalid == 0 && return 0
    cut = min(z.invalid, length(z.path) - z.origin_depth)
    limit === nothing || (cut = min(cut, limit))
    resize!(z.path, length(z.path) - cut)
    z.invalid -= cut
    cut
end

# upstream `ACTZipper::ascend` (arena_compact.rs:3117): returns the bytes ACTUALLY ascended, which
# stops at the root. (Our `ascend!` alias reported `n > 0` and so could not see a short move.)
function ascend!(z::ACTZipper, steps::Int)::Int
    remaining = steps
    remaining -= _act_ascend_invalid!(z, remaining)
    z.invalid > 0 && return steps - remaining
    while !isempty(z.stack)
        frame = z.stack[end]
        rest_len = length(z.path) - z.origin_depth
        this_steps = min(remaining, frame.node_depth, rest_len)
        frame.node_depth -= this_steps
        remaining -= this_steps
        if frame.node_depth == 0 && length(z.stack) > 1 && remaining > 0
            pop!(z.stack)
            z.cur_node = act_get_node(z.tree, z.stack[end].node_id)[1]
            this_steps += 1
            remaining -= 1
        end
        resize!(z.path, length(z.path) - this_steps)
        (at_root(z) || remaining == 0) && return steps - remaining
    end
    error("ACTZipper ascend!: empty stack (upstream `unreachable!()`, arena_compact.rs:3141)")
end

# upstream `ACTZipper::ascend_to_branch` (arena_compact.rs:2683), shared by `ascend_until!`
# (`need_value == true`) and `ascend_until_branch!`; returns the bytes ascended.
function _act_ascend_to_branch!(z::ACTZipper, need_value::Bool)::Int
    start_len = length(z.path)
    if z.invalid > 0
        _act_ascend_invalid!(z, nothing)
        z.invalid > 0 && return start_len - length(z.path)
        need_value && z.cur_node.value !== nothing && return start_len - length(z.path)
    end
    while !isempty(z.stack)
        frame = z.stack[end]
        nchildren = frame.child_count
        remaining = length(z.path) - z.origin_depth
        this_steps = min(frame.node_depth, remaining)
        frame.node_depth -= this_steps
        if length(z.stack) > 1 && remaining > this_steps
            pop!(z.stack)
            prev = z.stack[end]
            z.cur_node = act_get_node(z.tree, prev.node_id)[1]
            nchildren = prev.child_count
            this_steps += 1
        end
        resize!(z.path, length(z.path) - this_steps)
        cur = z.cur_node
        brk = cur isa ACT_NodeBranch && (nchildren > 1 || (need_value && cur.value !== nothing))
        (brk || at_root(z)) && break
    end
    start_len - length(z.path)
end

ascend_until!(z::ACTZipper) = _act_ascend_to_branch!(z, true)          # arena_compact.rs:3152
ascend_until_branch!(z::ACTZipper) = _act_ascend_to_branch!(z, false)  # arena_compact.rs:3160

# upstream `ACTZipper::to_sibling` (arena_compact.rs:2765): the sibling's byte, or `nothing` with no
# move. Siblings exist only at a node boundary — never part-way along a line node.
function _act_to_sibling!(z::ACTZipper, next::Bool)::Union{Nothing, UInt8}
    frame = z.stack[end]
    (length(z.stack) <= 1 || frame.node_depth > 0) && return nothing
    parent = z.stack[end - 1]
    sibling_idx = if next
        idx = parent.child_index + 1
        idx >= parent.child_count && return nothing
        idx
    else
        parent.child_index == 0 && return nothing
        parent.child_index - 1
    end
    ascend!(z, 1) == 0 && return nothing
    descend_indexed_byte!(z, sibling_idx)
end

to_next_sibling_byte!(z::ACTZipper) = _act_to_sibling!(z, true)   # arena_compact.rs:3166
to_prev_sibling_byte!(z::ACTZipper) = _act_to_sibling!(z, false)  # arena_compact.rs:3172

# =====================================================================
# ZipperIteration (arena_compact.rs:3187)
# =====================================================================

# upstream `ACTZipper::to_next_val_observed` (arena_compact.rs:3194): step over every existing path
# until one carries a value.
function to_next_val_observed!(z::ACTZipper, obs)
    while to_next_step_observed!(z, obs)
        is_val(z) && return true
    end
    false
end

# upstream `ACTZipper::descend_first_k_path_observed` (arena_compact.rs:3214, 556c4ed): depth-first
# search for the FIRST location exactly `k` bytes below the focus — on a dead end above `k`, back up
# to the nearest ancestor with an unvisited sibling. `false` leaves the focus where it started.
function descend_first_k_path_observed!(z::ACTZipper, k::Int, obs)
    # ⚠️ UPSTREAM QUIRK, PORTED AS-IS: `k == 0` reports success without moving (:3216), where the
    # `AbstractZipper` default (zipper.rs:1112) returns `false` for `k == 0`.
    k == 0 && return true
    d = 0
    while true
        while d < k
            byte = descend_first_byte!(z)
            byte === nothing && break
            descend_to_byte!(obs, byte)
            d += 1
        end
        d == k && return true
        while true
            d == 0 && return false
            sib = to_next_sibling_byte!(z)
            if sib !== nothing
                # a sibling step is one byte up and one byte down, as the observer sees it
                ascend!(obs, 1)
                descend_to_byte!(obs, sib)
                break
            end
            ascend_byte!(z)
            ascend!(obs, 1)
            d -= 1
        end
    end
end

# =====================================================================
# Exports
# =====================================================================
#
# The zipper surface is the generic functions of src/zipper/ZipperTraits.jl (exported there), so no
# `act_*` zipper name is exported any more — `read_zipper`/`read_zipper_at_path` construct, and
# `path_exists`/`is_val`/`val`/`child_count`/`descend_to!`/`ascend!`/`to_next_val!`/… dispatch.

export ArenaCompactTree, ACTZipper, ACT_NodeId, ACT_LineId
export ACT_NodeBranch, ACT_NodeLine, ACT_MAGIC
export act_read_varint, act_push_varint!
export act_from_zipper, act_save, act_open, act_open_mmap
export act_get_val_at
