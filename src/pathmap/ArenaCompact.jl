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
        ;
        push!(buf, UInt8((v >> ((i-1)*8)) & 0xff));
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
            value = v;
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
                    ;
                    w |= UInt64(data[word_off + j]) << (j*8);
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
            value = v;
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
            tmp = UInt8[];
            for j in 0:7
                ;
                push!(tmp, UInt8((w>>(j*8))&0xff));
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
        ;
        tree.data[ACT_MAGIC_LEN + i] = UInt8((v >> ((i-1)*8)) & 0xff);
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

Build a compact arena tree from a PathMap.  `map_val(v::V) → UInt64`.
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
# Integrity — DELIBERATELY OUT-OF-BAND. Read this before changing it.
# =====================================================================
#
# SURVEYED 2026-08-04 across upstream PathMap/MORK, CeTTa, JeTTa, hyperon-experimental and PeTTa.
# The conclusion that shapes every choice below: THE ACTree03 HEADER CANNOT CARRY A CHECKSUM.
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
# The implied upstream threat model is "trusted, self-produced input". `verify` is opt-in so the
# default stays byte-compatible and free.

"Path of the digest sidecar for `path` — `sha256sum -c`-compatible, so standard tooling can check it."
act_digest_path(path::AbstractString) = path * ".sha256"

"""
    act_file_digest(path) -> String

Lowercase hex SHA-256 of the file's bytes. This is the CONTENT ID of a saved trie: `act_save`
writes a deterministic byte image, so equal tries written by the same version give equal digests.

⚠️ It is an identity for the FILE IMAGE, not for the logical path-set — two tries holding the same
paths but built in a different insertion order can differ in arena layout and so in digest. For a
layout-independent identity you would hash the enumerated paths instead; that is not provided here
because nothing needs it yet, and an unused canonicalisation is a liability.
"""
act_file_digest(path::AbstractString) = bytes2hex(open(SHA.sha256, path))

"""
    act_save(tree::ArenaCompactTree, path::AbstractString; digest::Bool=false)

Write the compact tree to a file. The bytes are exactly upstream's `ACTree03` image — `digest`
adds a SIDECAR, never a header field, so the file stays readable by upstream's Rust.

The write is ATOMIC: bytes go to a temp file in the same directory and are `mv`'d into place, so a
crash or a full disk cannot leave a half-written file at `path` for a later `act_open` to misparse.
Adopted from CeTTa's `bridge_space_dump_act_transactional`, which stages and renames for exactly
this reason; ours previously wrote straight to `path`. Same-directory is required — `rename` is only
atomic within a filesystem.

`digest=true` also writes `\$path.sha256`, which `act_open(...; verify=true)` and `sha256sum -c`
both understand.
"""
function act_save(tree::ArenaCompactTree, path::AbstractString; digest::Bool=false)
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
    if digest
        open(act_digest_path(path), "w") do io
            println(io, act_file_digest(path), "  ", basename(path))
        end
    end
    path
end

"""
    act_verify(path) -> Bool

Recompute the file's SHA-256 and compare it against the sidecar written by `act_save(...; digest=true)`.

Throws if the sidecar is missing or malformed — a verification that silently passes when it could
not run is worse than no verification, which is the exact failure mode of JeTTa's fingerprint
(compared as stored strings, never recomputed from the loaded bytes).
"""
function act_verify(path::AbstractString)
    dpath = act_digest_path(path)
    isfile(dpath) || throw(ArgumentError("no digest sidecar at $dpath — save with `digest=true`"))
    line = strip(read(dpath, String))
    isempty(line) && throw(ArgumentError("empty digest sidecar at $dpath"))
    want = first(split(line))
    length(want) == 64 || throw(ArgumentError("malformed digest in $dpath: expected 64 hex chars"))
    act_file_digest(path) == want
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
        throw(ArgumentError(
            "$path is not an ACTree03 file: $(length(data)) bytes, need at least $ACT_MIN_FILE_LEN"))
    end
    if view(data, 1:ACT_MAGIC_LEN) != ACT_MAGIC
        throw(ArgumentError("$path is not an ACTree03 file: bad magic " *
                            "$(repr(String(copy(data[1:ACT_MAGIC_LEN]))))"))
    end
    nothing
end

"""
    act_open(path::AbstractString) → ArenaCompactTree

Load a compact tree from a file (copies bytes into memory).
Mirrors `ArenaCompactTree::open_mmap` (memory-mapped semantics optional in Julia).
"""
function act_open(path::AbstractString; verify::Bool=false)
    verify && !act_verify(path) && throw(ArgumentError("$path failed SHA-256 verification"))
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
function act_open_mmap(path::AbstractString; verify::Bool=false)
    # `verify` READS THE WHOLE FILE to hash it, which defeats the point of mmap (lazy paging of a
    # trie too large for RAM). Opt-in and documented rather than silently expensive.
    verify && !act_verify(path) && throw(ArgumentError("$path failed SHA-256 verification"))
    io = open(path, "r")
    data = Mmap.mmap(io, Vector{UInt8})   # lazy, read-only; OS faults pages on access
    close(io)
    _act_check_header(data, path)
    ArenaCompactTree(data, UInt64(length(data)), Dict{UInt64, ACT_LineId}(), Ref(UInt64(0)))
end

# =====================================================================
# ACTZipper — read-only zipper over ArenaCompactTree
# =====================================================================

mutable struct _ACTFrame
    node_id::ACT_NodeId
    child_count::Int
    child_index::Int
    next_id::Union{Nothing, ACT_NodeId}
    node_depth::Int   # bytes consumed within current line node
end

function _ACTFrame(node::ACTNode, node_id::ACT_NodeId)
    cc = act_node_child_count(node)
    _ACTFrame(node_id, cc, 0, nothing, 0)
end

"""
    ACTZipper

Read-only zipper over an `ArenaCompactTree`.
Mirrors `ACTZipper<Storage, Value>`.
"""
mutable struct ACTZipper
    tree::ArenaCompactTree
    cur_node::ACTNode
    stack::Vector{_ACTFrame}
    path::Vector{UInt8}
    origin_depth::Int
    origin_ndepth::Int     # origin_node_depth
    invalid::Int
end

function ACTZipper(tree::ArenaCompactTree)
    root, root_id = act_get_root(tree)
    frame = _ACTFrame(root, root_id)
    ACTZipper(tree, root, [frame], UInt8[], 0, 0, 0)
end

function act_zipper_with_root_here!(z::ACTZipper)
    z.origin_depth = length(z.path)
    z.origin_ndepth = z.stack[1].node_depth
    if length(z.stack) > 1
        z.stack[1] = z.stack[end]
        resize!(z.stack, 1)
    end
    z
end

"""
Create a read-only zipper over `tree`.
"""
act_read_zipper(tree::ArenaCompactTree) = ACTZipper(tree)

"""
Create a zipper pre-positioned at `path`.
"""
function act_read_zipper_at_path(tree::ArenaCompactTree, path)
    z = ACTZipper(tree)
    act_descend_to!(z, path)
    act_zipper_with_root_here!(z)
end

# Adapter: extend the canonical `read_zipper_at_path` to dispatch on
# ArenaCompactTree, so callers can pass either an in-RAM PathMap or a mmap'd
# ACT trie and get a polymorphic zipper back. All other `zipper_*` operations
# (descend / to_next_val! / path / child_mask / val …) already dispatch on
# ACTZipper via the methods below, so any zipper-algebra code becomes
# transparently mmap-capable. Mirrors upstream's `ACTZipper: impl Zipper`.
read_zipper_at_path(tree::ArenaCompactTree, path) = act_read_zipper_at_path(tree, path)

# =====================================================================
# ACTZipper — Zipper interface
# =====================================================================

act_at_root(z::ACTZipper) = length(z.path) <= z.origin_depth
act_path(z::ACTZipper) = view(z.path, (z.origin_depth + 1):length(z.path))

function act_path_exists(z::ACTZipper)
    z.invalid == 0
end

function act_is_val(z::ACTZipper)
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

function act_val(z::ACTZipper)
    act_is_val(z) || return nothing
    frame = z.stack[end]
    data = z.tree.data
    off = Int(frame.node_id.v) + 1
    head = data[off]
    head & ACT_VALUE_FLAG == 0 && return nothing
    v, _ = act_read_varint(data, off + 1)
    v
end

function act_child_count(z::ACTZipper)
    z.invalid > 0 && return 0
    cur = z.cur_node
    if cur isa ACT_NodeBranch
        return count_bits(cur.bytemask)
    else
        frame = z.stack[end]
        lpath = act_get_line(z.tree, cur.path)
        frame.node_depth < length(lpath) ? 1 : 0
    end
end

function act_child_mask(z::ACTZipper)
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
# ACTZipper — ZipperMoving
# =====================================================================

function act_reset!(z::ACTZipper)
    root_id = z.stack[1].node_id   # preserve ACT_NodeId, not the size returned by act_get_node
    root = act_get_node(z.tree, root_id)[1]
    z.cur_node = root
    resize!(z.stack, 1)
    z.stack[1] = _ACTFrame(root, root_id)
    z.stack[1].node_depth = z.origin_ndepth
    resize!(z.path, z.origin_depth)
    z.invalid = 0
end

function _act_descend_cond!(z::ACTZipper, path::AbstractVector{UInt8}, on_val::Bool)
    z.invalid > 0 && return 0
    descended = 0
    i = 1
    while i <= length(path)
        cur = z.cur_node
        if cur isa ACT_NodeLine
            frame = z.stack[end]
            lpath = act_get_line(z.tree, cur.path)
            rest = view(lpath, (frame.node_depth + 1):length(lpath))
            common = find_prefix_overlap(view(path, i:length(path)), rest)
            descended += common
            into_child = length(rest) == common && cur.child !== nothing
            hack = into_child ? 1 : 0
            frame.node_depth += common - hack
            append!(z.path, rest[1:common])
            on_val && descended > 0 && cur.value !== nothing && break
            common < length(rest) && break
            cur.child === nothing && break
            i += common
            child_node, _ = act_get_node(z.tree, cur.child)
            push!(z.stack, _ACTFrame(child_node, cur.child))
            z.cur_node = child_node
        else  # ACT_NodeBranch
            on_val && descended > 0 && cur.value !== nothing && break
            test_bit(cur.bytemask, path[i]) || break
            idx = Int(index_of(cur.bytemask, path[i]))
            frame = z.stack[end]
            child_id, child_next =
                if frame.next_id !== nothing && frame.child_index + 1 == idx
                    (frame.next_id, nothing)
                else
                    nd = act_nth_node(z.tree, cur.first_child, idx)
                    (nd[2], nd[3])
                end
            frame.child_index = idx
            frame.next_id = child_next
            child_node = act_get_node(z.tree, child_id)[1]
            push!(z.stack, _ACTFrame(child_node, child_id))
            z.cur_node = child_node
            push!(z.path, path[i])
            i += 1
            descended += 1
        end
    end
    descended
end

function act_descend_to!(z::ACTZipper, path)
    pv = collect(UInt8, path)
    descended = _act_descend_cond!(z, pv, false)
    if descended < length(pv)
        append!(z.path, pv[(descended + 1):end])
        z.invalid += length(pv) - descended
    end
end

function act_descend_to_existing!(z::ACTZipper, path)
    _act_descend_cond!(z, collect(UInt8, path), false)
end

function act_descend_to_val!(z::ACTZipper, path)
    _act_descend_cond!(z, collect(UInt8, path), true)
end

function act_descend_to_byte!(z::ACTZipper, k::UInt8)
    act_descend_to!(z, UInt8[k])
end

function act_descend_indexed_byte!(z::ACTZipper, idx::Int)
    z.invalid > 0 && return false
    cur = z.cur_node
    child_id = nothing

    if cur isa ACT_NodeLine
        frame = z.stack[end]
        lpath = act_get_line(z.tree, cur.path)
        rest = view(lpath, (frame.node_depth + 1):length(lpath))
        (idx != 0 || isempty(rest)) && return false
        push!(z.path, rest[1])
        if length(rest) == 1 && cur.child !== nothing
            child_id = cur.child
        else
            frame.node_depth += 1
            return true
        end
    else  # Branch
        frame = z.stack[end]
        byte = indexed_bit(cur.bytemask, idx, true)
        byte === nothing && return false
        if frame.next_id !== nothing && frame.child_index + 1 == idx
            child_id = frame.next_id
        else
            child_id = act_nth_node(z.tree, cur.first_child, idx)[2]
        end
        push!(z.path, byte)
        frame.child_index = idx
    end

    if child_id !== nothing
        frame = z.stack[end]
        child_node, next_sz = act_get_node(z.tree, child_id)
        next_id = ACT_NodeId(child_id.v + next_sz)
        frame.next_id = next_id
        push!(z.stack, _ACTFrame(child_node, child_id))
        z.cur_node = child_node
    end
    true
end

act_descend_first_byte!(z::ACTZipper) = act_descend_indexed_byte!(z, 0)

function act_descend_until!(z::ACTZipper)
    descended = false
    while act_child_count(z) == 1
        cur = z.cur_node
        if cur isa ACT_NodeLine
            frame = z.stack[end]
            lpath = act_get_line(z.tree, cur.path)
            rest = view(lpath, (frame.node_depth + 1):length(lpath))
            hack = cur.child !== nothing ? 1 : 0
            frame.node_depth += length(rest) - hack
            append!(z.path, rest)
            cur.value !== nothing && (descended=true; break)
            cur.child !== nothing || break
            child_node = act_get_node(z.tree, cur.child)[1]
            push!(z.stack, _ACTFrame(child_node, cur.child))
            z.cur_node = child_node
        else  # Branch
            byte = next_bit(cur.bytemask, UInt8(0))
            byte === nothing && break
            child_id = act_nth_node(z.tree, cur.first_child, 0)[2]
            push!(z.path, byte)
            child_node = act_get_node(z.tree, child_id)[1]
            push!(z.stack, _ACTFrame(child_node, child_id))
            z.cur_node = child_node
            cur.value !== nothing && (descended=true; break)
        end
        descended = true
    end
    descended
end

function act_ascend!(z::ACTZipper, steps::Int=1)
    # First clear any invalid bytes
    if z.invalid > 0
        cut = min(z.invalid, steps, max(0, length(z.path) - z.origin_depth))
        resize!(z.path, length(z.path) - cut)
        z.invalid -= cut
        steps -= cut
        z.invalid == 0 || return steps == 0
    end
    for _ in 1:steps
        length(z.path) <= z.origin_depth && return false
        cur = z.cur_node
        if cur isa ACT_NodeLine
            frame = z.stack[end]
            if frame.node_depth > 0
                frame.node_depth -= 1
                pop!(z.path)
                continue
            end
        end
        length(z.stack) <= 1 && return false
        pop!(z.stack)
        z.cur_node = act_get_node(z.tree, z.stack[end].node_id)[1]
        pop!(z.path)
    end
    true
end

act_ascend_byte!(z::ACTZipper) = act_ascend!(z, 1)

function act_ascend_until!(z::ACTZipper)
    act_at_root(z) && return false
    while true
        cur = z.cur_node
        if cur isa ACT_NodeLine
            frame = z.stack[end]
            if frame.node_depth > 0
                act_ascend!(z, frame.node_depth)
                cur.value !== nothing && return true
            end
        end
        length(z.stack) <= 1 && return false
        nchildren = z.stack[end - 1].child_count
        act_ascend!(z, 1)
        (nchildren > 1 || act_is_val(z)) && return true
        act_at_root(z) && return true
    end
end

function act_ascend_until_branch!(z::ACTZipper)
    act_at_root(z) && return false
    while true
        act_ascend!(z, 1) || return false
        z.stack[end].child_count > 1 && return true
        act_at_root(z) && return true
    end
end

function act_to_next_sibling_byte!(z::ACTZipper)
    length(z.stack) <= 1 && return false
    frame = z.stack[end]
    frame.node_depth > 0 && return false
    parent = z.stack[end - 1]
    idx = parent.child_index + 1
    idx >= parent.child_count && return false
    act_ascend!(z, 1) && act_descend_indexed_byte!(z, idx)
end

function act_to_prev_sibling_byte!(z::ACTZipper)
    length(z.stack) <= 1 && return false
    parent = z.stack[end - 1]
    parent.child_index == 0 && return false
    act_ascend!(z, 1) && act_descend_indexed_byte!(z, parent.child_index - 1)
end

function act_to_next_val!(z::ACTZipper)
    loop_count = 0
    while true
        loop_count += 1;
        loop_count > 500_000 && return false
        if act_descend_first_byte!(z)
            act_is_val(z) && return true
            act_descend_until!(z)
            act_is_val(z) && return true
        else
            while true
                act_to_next_sibling_byte!(z) && break
                act_ascend_byte!(z) || return false
                act_at_root(z) && return false
            end
            act_is_val(z) && return true
        end
    end
end

function Base.copy(z::ACTZipper)
    ACTZipper(
        z.tree,
        z.cur_node,
        copy(z.stack),
        copy(z.path),
        z.origin_depth,
        z.origin_ndepth,
        z.invalid
    )
end

act_fork!(z::ACTZipper) = act_zipper_with_root_here!(copy(z))

act_val_count(z::ACTZipper) = begin
    z2 = copy(z);
    act_reset!(z2)
    n = act_is_val(z2) ? 1 : 0
    while act_to_next_val!(z2)
        ;
        n += 1;
    end
    n
end

# =====================================================================
# zipper_* dispatch aliases so ACTZipper satisfies the generic zipper interface.
# Required for PrefixZipper{ACTZipper} and ProductZipperG factor dispatch.
# =====================================================================

zipper_reset!(z::ACTZipper) = act_reset!(z)
zipper_path(z::ACTZipper) = act_path(z)
zipper_path_exists(z::ACTZipper) = act_path_exists(z)
zipper_is_val(z::ACTZipper) = act_is_val(z)
zipper_child_count(z::ACTZipper) = act_child_count(z)
zipper_child_mask(z::ACTZipper) = act_child_mask(z)
zipper_val_count(z::ACTZipper) = act_val_count(z)
zipper_at_root(z::ACTZipper) = act_at_root(z)
zipper_descend_to!(z::ACTZipper, p) = act_descend_to!(z, p)
zipper_descend_to_existing!(z::ACTZipper, p) = act_descend_to_existing!(z, p)
zipper_descend_to_byte!(z::ACTZipper, b::UInt8) = act_descend_to_byte!(z, b)
zipper_descend_first_byte!(z::ACTZipper) = act_descend_first_byte!(z)
zipper_descend_until!(z::ACTZipper) = act_descend_until!(z)
zipper_ascend!(z::ACTZipper, n::Int=1) = (act_ascend!(z, n); n > 0)
zipper_ascend_byte!(z::ACTZipper) = act_ascend_byte!(z)
zipper_ascend_until!(z::ACTZipper) = act_ascend_until!(z)
zipper_ascend_until_branch!(z::ACTZipper) = act_ascend_until_branch!(z)
zipper_to_next_sibling_byte!(z::ACTZipper) = act_to_next_sibling_byte!(z)
zipper_to_prev_sibling_byte!(z::ACTZipper) = act_to_prev_sibling_byte!(z)
zipper_to_next_val!(z::ACTZipper) = act_to_next_val!(z)

# =====================================================================
# _zpg_* dispatch so ACTZipper works as a ProductZipperG factor.
# Defined here (after ACTZipper) so they resolve; _zpg_* functions
# themselves are defined earlier in zipper/ProductZipperG.jl.
# =====================================================================

_zpg_path_exists(z::ACTZipper) = act_path_exists(z)
_zpg_is_val(z::ACTZipper) = act_is_val(z)
_zpg_child_count(z::ACTZipper) = act_child_count(z)
_zpg_child_mask(z::ACTZipper) = act_child_mask(z)
_zpg_path(z::ACTZipper) = act_path(z)
_zpg_origin_path(z::ACTZipper) = z.path
_zpg_root_prefix_len(z::ACTZipper) = z.origin_depth
_zpg_at_root(z::ACTZipper) = act_at_root(z)
_zpg_reset!(z::ACTZipper) = act_reset!(z)
_zpg_descend_to_existing!(z::ACTZipper, p) = act_descend_to_existing!(z, p)
_zpg_descend_to!(z::ACTZipper, p) = act_descend_to!(z, p)
_zpg_descend_to_byte!(z::ACTZipper, b) = act_descend_to_byte!(z, b)
_zpg_descend_first_byte!(z::ACTZipper) = act_descend_first_byte!(z)
_zpg_descend_until!(z::ACTZipper) = act_descend_until!(z)
_zpg_ascend_byte!(z::ACTZipper) = act_ascend_byte!(z)
_zpg_ascend!(z::ACTZipper, n) = (act_ascend!(z, n); true)
_zpg_ascend_until!(z::ACTZipper) = act_ascend_until!(z)
_zpg_ascend_until_branch!(z::ACTZipper) = act_ascend_until_branch!(z)
_zpg_to_next_sibling_byte!(z::ACTZipper) = act_to_next_sibling_byte!(z)
_zpg_to_next_val!(z::ACTZipper) = act_to_next_val!(z)

# =====================================================================
# Exports
# =====================================================================

export ArenaCompactTree, ACTZipper, ACT_NodeId, ACT_LineId
export ACT_NodeBranch, ACT_NodeLine, ACT_MAGIC
export act_read_varint, act_push_varint!
export act_from_zipper, act_save, act_open, act_open_mmap
export act_file_digest, act_digest_path, act_verify
export act_read_zipper, act_read_zipper_at_path
export act_get_val_at
export act_at_root, act_path, act_path_exists, act_is_val, act_val
export act_child_count, act_child_mask, act_val_count
export act_reset!, act_descend_to!, act_descend_to_byte!
export act_descend_to_existing!, act_descend_to_val!
export act_descend_indexed_byte!, act_descend_first_byte!, act_descend_until!
export act_ascend!, act_ascend_byte!, act_ascend_until!, act_ascend_until_branch!
export act_to_next_sibling_byte!, act_to_prev_sibling_byte!, act_to_next_val!
export act_fork!
