"""
Morphisms — port of `pathmap/src/morphisms.rs`.

Catamorphism (fold from leaves to root) and anamorphism (build from root)
over tries.  Both stepping (every byte) and jumping (only at forks/vals)
variants are provided.  Cached variants skip recomputing shared subtries.

Julia translation notes:
  - Rust `const JUMPING` / `const DEBUG_PATH` → Julia `jumping::Bool` param.
  - Rust `CacheStrategy` trait + `NoCache`/`DoCache` → optional Dict argument.
  - `shared_node_id` → `objectid(node_inner)` for node address-based cache keys.
  - Error/infallible variants unified: Julia functions return values; errors
    propagate normally via throw/try-catch if the alg_f needs them.
"""

# =====================================================================
# CataStackFrame — bookkeeping for one forking point
# =====================================================================

mutable struct _CataFrame
    child_idx::Int
    child_cnt::Int
    child_addr::Union{Nothing, UInt64}   # for caching (objectid of node)
end

_CataFrame(z::ReadZipperCore) = _CataFrame(0, zipper_child_count(z), nothing)

function _cata_frame_reset!(f::_CataFrame, z::ReadZipperCore)
    f.child_idx = 0
    f.child_cnt = zipper_child_count(z)
    f.child_addr = nothing
end

# =====================================================================
# ascend_to_fork — internal helper shared by both engines
# =====================================================================
#
# Mirrors `ascend_to_fork` in morphisms.rs.

"""
Internal: ascend from leaf/subtrie back to the nearest fork (or root),
calling alg_f at each step.  `jumping=true` uses ascend_until jumps.
Populates `children` with results from current invocation.
"""
function _cata_ascend_to_fork!(
    z::ReadZipperCore{V, A},
    alg_f::Function,   # (ByteMask, children::Vector, jump_len::Int, val, path::Vector{UInt8}) -> W
    children::Vector,
    jumping::Bool
) where {V, A}
    if jumping
        child_mask = zipper_child_mask(z)
        z_children = children   # start with caller-supplied children
        while true
            old_path_len = length(zipper_origin_path(z))
            # Capture the OLD path BEFORE ascending (mirrors origin_path_assert_len)
            old_path = copy(zipper_origin_path(z))
            old_val = zipper_val(z)
            ascended = zipper_ascend_until!(z)
            @assert ascended "ascend_until must move"

            origin_path = zipper_origin_path(z)
            cc = zipper_child_count(z)
            is_val_here = zipper_is_val(z)

            jump_len = if cc != 1 || is_val_here
                old_path_len - (length(origin_path) + 1)
            else
                old_path_len - length(origin_path)
            end
            jump_len = max(0, jump_len)

            # Use old_path (pre-ascend) so that path[end-jump_len..] is valid
            w = alg_f(child_mask, z_children, jump_len, old_val, old_path)

            (cc != 1 || zipper_at_root(z)) && return w

            z_children = [w]
            # ⚠️ THE BYTE COMES FROM THE **PRE-ASCEND** PATH, NOT THE CURRENT ONE.
            # Upstream (morphisms.rs:571):
            #     let byte = *unsafe{ z.origin_path_assert_len(old_path_len-jump_len) }.last().unwrap();
            # `origin_path_assert_len` reaches back into the path buffer, which STILL HOLDS the bytes
            # above the current focus after ascending — that is what the `unsafe` is for — and takes
            # the byte at index `old_path_len - jump_len`. `.unwrap()` means upstream never
            # substitutes a placeholder; if it were absent that would be a bug, not a default.
            #
            # We read the POST-ascend `origin_path[end]` and fell back to `UInt8(0)` whenever the
            # ascended path was shorter. That fallback SILENTLY CORRUPTED DATA: it is taken exactly
            # when a valued node has a single child, so the child's edge byte was written as 0x00.
            #     {"band"=>1, "bandana"=>2}  round-tripped through ACT as  "band", "band\0na"
            # No test could see it — every existing round-trip used keys with no shared prefix
            # ("alpha"/"beta"/"gamma"), and the trie is only walked in the corrupted direction on the
            # way OUT, so the in-memory map stayed correct while the persisted file did not.
            idx = old_path_len - jump_len
            byte = old_path[idx]
            child_mask = ByteMask(byte)
        end
    else
        # stepping: ascend one byte at a time
        child_mask = zipper_child_mask(z)
        z_children = children
        while true
            origin_path = copy(zipper_origin_path(z))
            byte = isempty(origin_path) ? UInt8(0) : origin_path[end]
            val = zipper_val(z)
            w = alg_f(child_mask, z_children, 0, val, origin_path)

            ascended = zipper_ascend_byte!(z)
            @assert ascended "ascend_byte must move"

            (zipper_child_count(z) != 1 || zipper_at_root(z)) && return w

            z_children = [w]
            child_mask = ByteMask(byte)
        end
    end
end

# =====================================================================
# _zipper_origin_path / _zipper_shared_node_id helpers
# =====================================================================

"""
Full path from the ReadZipperCore's origin to cursor.
"""
function zipper_origin_path(z::ReadZipperCore)
    view(z.prefix_buf, 1:length(z.prefix_buf))
end

"""
Unique ID for the current focus node (for caching). 0 if not at node root.
"""
function zipper_shared_node_id(z::ReadZipperCore)
    # Only meaningful when node_key is empty (at a node boundary)
    isempty(_znode_key(z)) || return nothing
    z.focus_node === nothing ? nothing : UInt64(objectid(z.focus_node))
end

# =====================================================================
# Side-effect catamorphism engine
# =====================================================================
#
# Mirrors `cata_side_effect_body<JUMPING>` in morphisms.rs.

"""
    _cata_side_effect!(z, alg_f, jumping) → W

DFS fold from leaves to root.  At each forking point, calls:
`alg_f(child_mask::ByteMask, children::Vector{W}, jump_len::Int, val::Union{Nothing,V}, path::Vector{UInt8}) → W`
`jumping=true` skips monotone paths between forks.
"""
function _cata_side_effect!(
    z::ReadZipperCore{V, A}, alg_f::Function, jumping::Bool
) where {V, A}
    stack = _CataFrame[]
    children = []
    frame_idx = 0

    zipper_reset!(z)
    push!(stack, _CataFrame(z))

    if !zipper_descend_first_byte!(z)
        # Empty trie special case
        return alg_f(
            zipper_child_mask(z), [], 0, zipper_val(z), copy(zipper_origin_path(z))
        )
    end

    while true
        # Descend to leaf or fork
        is_leaf = false
        while zipper_child_count(z) < 2
            if !zipper_descend_until!(z)
                is_leaf = true
                break
            end
        end

        if is_leaf
            cur_w = _cata_ascend_to_fork!(z, alg_f, [], jumping)
            push!(children, cur_w)
            stack[frame_idx + 1].child_idx += 1

            # Keep ascending until we reach an unfinished fork
            while stack[frame_idx + 1].child_idx == stack[frame_idx + 1].child_cnt
                if frame_idx == 0
                    sf = stack[1]
                    val = zipper_val(z)
                    cm = zipper_child_mask(z)
                    @assert sf.child_idx == sf.child_cnt
                    @assert sf.child_cnt == length(children)
                    w = if sf.child_cnt != 1 || val !== nothing || !jumping
                        alg_f(cm, children, 0, val, copy(zipper_origin_path(z)))
                    else
                        pop!(children)
                    end
                    return w
                else
                    sf = stack[frame_idx + 1]
                    child_start = length(children) - sf.child_cnt
                    sub_ch = children[(child_start + 1):end]
                    cur_w = _cata_ascend_to_fork!(z, alg_f, sub_ch, jumping)
                    resize!(children, child_start)
                    frame_idx -= 1
                    push!(children, cur_w)
                    stack[frame_idx + 1].child_idx += 1
                end
            end

            # Descend the next child branch
            descended = zipper_descend_indexed_byte!(z, stack[frame_idx + 1].child_idx)
            @assert descended
        else
            # Push new frame and descend first child
            frame_idx += 1
            if frame_idx < length(stack)
                _cata_frame_reset!(stack[frame_idx + 1], z)
            else
                push!(stack, _CataFrame(z))
            end
            zipper_descend_first_byte!(z)
        end
    end
end

# =====================================================================
# Cached catamorphism engine
# =====================================================================
#
# Mirrors `into_cata_cached_body<JUMPING>`.

"""
    _cata_cached!(z, alg_f, jumping) → W

Like `_cata_side_effect!` but caches W by node identity (objectid).
Reuses cached results when the zipper reaches a previously seen node.
`alg_f` receives `(child_mask, children, val, sub_path::Vector{UInt8}) → W`
where `sub_path` is the "jumped" sub-path for jumping variant (else `[]`).
"""
function _cata_cached!(z::ReadZipperCore{V, A}, alg_f::Function, jumping::Bool) where {V, A}
    zipper_reset!(z)

    stack = _CataFrame[]
    children = []
    cache = Dict{UInt64, Any}()   # node objectid → cached W

    push!(stack, _CataFrame(z))

    while true
        frame = stack[end]

        if frame.child_idx < frame.child_cnt
            zipper_descend_indexed_byte!(z, frame.child_idx)
            frame.child_idx += 1
            nid = zipper_shared_node_id(z)
            frame.child_addr = nid

            # Check cache
            if nid !== nothing && haskey(cache, nid)
                push!(children, cache[nid])
                zipper_ascend_byte!(z)
                continue
            end

            # Descend to leaf or fork
            is_leaf = false
            while zipper_child_count(z) < 2
                !zipper_descend_until!(z) && (is_leaf=true; break)
            end

            if is_leaf
                inner_alg =
                    (mask, ch, jump, val, path) -> begin
                        sub_path = if jumping
                            view(path, max(1, length(path) - jump):length(path))
                        else
                            UInt8[]
                        end
                        alg_f(mask, ch, val, collect(sub_path))
                    end
                cur_w = _cata_ascend_to_fork!(z, inner_alg, [], jumping)
                if nid !== nothing

                    cache[nid] = cur_w
                end
                push!(children, cur_w)
                continue
            end

            # Recurse deeper
            push!(stack, _CataFrame(z))
            continue
        end

        # All children of this frame processed
        frame_idx = length(stack)
        sf = pop!(stack)
        child_start = length(children) - sf.child_cnt

        if frame_idx == 1
            # Root
            @assert zipper_at_root(z)
            val = zipper_val(z)
            child_mask = zipper_child_mask(z)
            sub_ch = children[(child_start + 1):end]
            w = if jumping && sf.child_cnt == 1 && val === nothing
                pop!(children)
            else
                alg_f(child_mask, sub_ch, val, UInt8[])
            end
            return w
        end

        # Aggregate subtree + ascend
        sub_ch = children[(child_start + 1):end]
        inner_alg =
            (mask, ch, jump, val2, path) -> begin
                sub_path = if jumping
                    view(path, max(1, length(path) - jump):length(path))
                else
                    UInt8[]
                end
                alg_f(mask, ch, val2, collect(sub_path))
            end
        cur_w = _cata_ascend_to_fork!(z, inner_alg, sub_ch, jumping)
        resize!(children, child_start)

        parent_frame = stack[end]
        if parent_frame.child_addr !== nothing
            cache[parent_frame.child_addr] = cur_w
        end
        push!(children, cur_w)
    end
end

# =====================================================================
# Public catamorphism API on PathMap and ReadZipperCore
# =====================================================================

"""
    cata_side_effect(m::PathMap, alg_f) → W

Stepping catamorphism on `m`.  `alg_f(child_mask, children, val, path) → W`.
Mirrors `PathMap::into_cata_side_effect`.
"""
function cata_side_effect(m::PathMap{V, A}, alg_f::Function) where {V, A}
    z = read_zipper(m)
    _cata_side_effect!(z, (mask, ch, jump, val, path) -> alg_f(mask, ch, val, path), false)
end

"""
    cata_jumping_side_effect(m::PathMap, alg_f) → W

Jumping catamorphism.  `alg_f(child_mask, children, jump_len, val, path) → W`.
Mirrors `PathMap::into_cata_jumping_side_effect`.
"""
function cata_jumping_side_effect(m::PathMap{V, A}, alg_f::Function) where {V, A}
    z = read_zipper(m)
    _cata_side_effect!(z, alg_f, true)
end

"""
    cata_cached(m::PathMap, alg_f) → W

Cached stepping catamorphism.  `alg_f(child_mask, children, val) → W`.
Mirrors `PathMap::into_cata_cached`.
"""
function cata_cached(m::PathMap{V, A}, alg_f::Function) where {V, A}
    z = read_zipper(m)
    _cata_cached!(z, (mask, ch, val, _sub) -> alg_f(mask, ch, val), false)
end

"""
    cata_jumping_cached(m::PathMap, alg_f) → W

Cached jumping catamorphism.  `alg_f(child_mask, children, val, sub_path) → W`.
Mirrors `PathMap::into_cata_jumping_cached`.
"""
function cata_jumping_cached(m::PathMap{V, A}, alg_f::Function) where {V, A}
    z = read_zipper(m)
    _cata_cached!(z, alg_f, true)
end

# ReadZipperCore variants (take the zipper directly)
function cata_side_effect(z::ReadZipperCore{V, A}, alg_f::Function) where {V, A}
    _cata_side_effect!(z, (mask, ch, jump, val, path) -> alg_f(mask, ch, val, path), false)
end
function cata_jumping_side_effect(z::ReadZipperCore{V, A}, alg_f::Function) where {V, A}
    _cata_side_effect!(z, alg_f, true)
end
function cata_cached(z::ReadZipperCore{V, A}, alg_f::Function) where {V, A}
    _cata_cached!(z, (mask, ch, val, _sub) -> alg_f(mask, ch, val), false)
end
function cata_jumping_cached(z::ReadZipperCore{V, A}, alg_f::Function) where {V, A}
    _cata_cached!(z, alg_f, true)
end

# Upstream's seed for the structural fold — `morphisms.rs:255`, verbatim.
const _MAP_HASH_SEED = reinterpret(Int64,
    0b0100001010101101111110010110100110000010011000100100100111110111 % UInt64)

"""
    map_hash_value(v) → UInt128

Per-VALUE hash. Upstream's default `val_hash` (`morphisms.rs:241-245`): a fresh `GxHasher` seeded 0,
the value hashed into it, read out as u128. Julia's `hash(v)` is used to reduce an arbitrary `V` to
bytes first — `V` is user-chosen and has no byte encoding of its own, exactly as upstream leans on
`V: std::hash::Hash`.
"""
function map_hash_value(v)::UInt128
    h = GxHasher(Int64(0))
    gx_write!(h, gx_u64_le_bytes(UInt64(hash(v))))
    gx_finish_u128(h)
end

"""
    map_hash(m::PathMap) → UInt128
    map_hash(m::PathMap, val_hash) → UInt128

Hash the LOGICAL trie — a Merkle-style fold in which each node's digest is computed from its
children's digests — exploiting structural sharing via `cata_cached`. Mirrors `Catamorphism::hash` /
`hash_with` (`morphisms.rs:236-261`), fold order included:

    seed  = 0b01000010…110111                       (morphisms.rs:255)
    write(bytemask as 32 bytes)                      byte-wise
    write(child hashes as 16*len bytes)              byte-wise, little-endian u128s
    if value: write_u128(val_hash(value))            the SEPARATE u128 path, not 16 bytes
    finish_u128()

⚠️ **128 bits, and NOT byte-identical to the `mork` binary.** Upstream's `GxHasher` is the AES-NI
crate on x86_64 and this ~20-line mixer only under miri/riscv64 (`lib.rs:13-16`) — so these digests
match upstream there and not on x86_64. Deliberate: upstream's own cfg makes the value a PER-TARGET
artifact, so it cannot be a portable contract, and nothing compares this across engines. See the
header of `GxHash.jl`, and `MORK/test/conformance/ADAPTATIONS.md` entry 7 for the identical call on
the HashSink digest.

WHAT CHANGED 2026-08-05 and why. This returned a `UInt64` built from `Base.hash`. Two problems for
its intended consumer (WP §2.6 `ChangeDigest`): 64 bits puts the birthday bound at ~2^32 subtries,
and `Base.hash` is not contracted stable across Julia versions — a digest written into a checkpoint
must survive a Julia upgrade. Measured before changing it: the old form WAS stable across processes
on 1.12.6, order-independent, and detected both value changes and key removals — so this widens and
pins the algorithm; it does not fix a correctness bug.

⚠️ NOT INCREMENTAL, AND A PERSISTED MEMO IS UNSOUND HERE AS-IS — BUILT, MEASURED, REVERTED 2026-08-05.
`_cata_cached!` builds its memo FRESH PER CALL, so a whole-trie hash is O(distinct nodes) every time,
where `sms_spec_corrections_2026-07-11.md` §5.3 wants only CHANGED subtries recomputed. The obvious
fix — let the caller pass a memo that survives across calls, keyed on the node object — was
implemented and it SILENTLY RETURNED THE WRONG DIGEST:

    m = build(2000 keys); memo = MapHashMemo()
    h1 = map_hash(m; memo)                 # populate
    set_val_at!(m, b"key000001x", 99)      # a real edit
    map_hash(m; memo) === h1               # true (!!)  — reports NOTHING CHANGED
    map_hash(m; memo) != map_hash(m)       # disagrees with ground truth

WHY, and it is the exact inverse of what upstream's own note suggests. `set_val_at!` MUTATES A NODE
IN PLACE when its refcnt == 1 — `_cow_in_place!` forks only at refcnt > 1. The node OBJECT is
unchanged, so an object-keyed entry still hits and answers with the pre-edit digest. The invariant a
persisted memo needs — *object identity implies content* — is FALSE for unshared nodes.

✅ **MECHANISM RE-VERIFIED IN THE BODY 2026-08-14** (previously this paragraph was the only record, and
a reader was right to ask whether it had gone stale). `zipper/Zipper.jl:118-125`:

    @inline function _cow_in_place!(rc::TrieNodeODRc{V, A}, inner) where {V, A}
        if hasfield(typeof(inner), :refcnt) && Int(getfield(inner, :refcnt, :acquire)) > 1
            _node_dec_refcnt!(inner)
            rc.node = (clone_self(inner)::TrieNodeODRc{V, A}).node
            return _fnode(_rc_inner(rc), V, A)
        end
        inner                    # <- refcnt <= 1 (or no refcnt field): the SAME object, unforked
    end

The guard is `> 1` and the fall-through returns `inner` itself, so the write lands on the same object.
The unsoundness conclusion therefore rests on code, not on this docstring's testimony.

⚠️ **WHAT IS STILL TESTIMONY, AND SHOULD BE RE-RUN BEFORE IT IS PLANNED AROUND:** the 2026-08-05
experiment itself, and every NUMBER below (0.3x, 93x, the 441 B/entry and ~316 B/entry figures). They
were not re-measured on 2026-08-14. Quote them as "reported", never as a current measurement.

🔴 UPSTREAM IS SAFE FOR A REASON IT RECORDS AS A COST. `merkleization.rs`'s header warns that a
persisted memo "would increase the node refcounts and lead to copying". That extra copying IS the
correctness mechanism: an `Rc` clone in the memo bumps the refcount, so the next write is FORCED to
COW-fork, producing a NEW object that MISSES the memo. Julia's semantics remove that cost — a
reference here never touches our MANUAL `refcnt` field — and remove the safety with it. Do not read
that note as "a hazard we happily avoid"; we avoid the copying and inherit the staleness.

⚠️ THE CONTAINER WAS NOT THE PROBLEM — do not retry this with a different map. Reviewed 2026-08-05
with measurements: `WeakKeyDict` is mechanically sound for this. The node structs define NO custom
`hash`/`==` (checked across all 7 in `src/nodes/`), so both fall to Julia's identity fallbacks —
verified live that two CONTENT-IDENTICAL nodes from separate PathMaps do not collide. A GC-dropped
entry is always a benign MISS, never a stale hit. It carries an internal `ReentrantLock` that plain
`Dict`/`IdDict` lack; 20k concurrent ops across 2 threads on one shared memo gave 0 errors. Costs are
modest and characterised: ~441 B/entry vs `IdDict`'s ~316 B, and `length()` pays an O(table-size)
sweep on the first touch after a GC that finalized a key. `IdDict` + explicit eviction, or an epoch
counter, have THE IDENTICAL DEFECT — the failure is upstream of the container, in node mutability vs
key stability.

WHAT WOULD ACTUALLY WORK, when SMS needs it (there is no consumer today, so this was not pushed
through): store into the memo THROUGH A REFCOUNT-BUMPING hold, so any later write to a memoized
subtrie is forced to COW. That is the same medicine `sms_spec_corrections` §3 already prescribes,
normatively, for `CheckpointRef` — "MUST hold the region root via a refcount-bumping `copy()`". It
then needs explicit RELEASE on eviction, which rules out `WeakKeyDict` (finalizers touching refcnt at
GC time), and lands squarely on upstream's other open question: the eviction heuristic. That is a
design task, not a keyword argument.

Measured while it was in place, for whoever picks this up: memo reuse on an UNCHANGED 20k-key trie
was 0.3x — SLOWER than recomputing, the bookkeeping costing more than the fold it skipped. Only the
post-edit path looked fast (93x), and that number was measuring the wrong answer.
"""
map_hash(m::PathMap{V, A}) where {V, A} = map_hash(m, map_hash_value)

function map_hash(m::PathMap{V, A}, val_hash::Function)::UInt128 where {V, A}
    cata_cached(
        m,
        (mask, children, val) -> begin
            h = GxHasher(_MAP_HASH_SEED)
            for w in mask.bits                       # ByteMask = 4 x UInt64 = 32 bytes
                gx_write!(h, gx_u64_le_bytes(w))
            end
            for c in children                        # child digests, 16 bytes each
                gx_write!(h, gx_u128_le_bytes(c::UInt128))
            end
            val !== nothing && gx_write_u128!(h, val_hash(val))
            gx_finish_u128(h)
        end
    )
end

# =====================================================================
# Hybrid cached catamorphism — A.0005
# =====================================================================
#
# Implements the "logical_cached_cata" design from A.0005.
#
# Problem: the existing cata_cached passes NO path to alg_f because
# a full path would break cache sharing (two nodes at different paths
# but with the same node_id would produce different W values).
# cata_side_effect passes the full path but has NO caching.
#
# Solution (A.0005 option 2, not yet implemented in upstream Rust):
#   alg_f(mask, children, val, sub_path, full_path) → (W, used_bytes::Int)
#
# `used_bytes` tells how many trailing bytes of `full_path` were
# incorporated into W.  The implementation stores the path suffix of
# that length alongside W in the cache.  On a subsequent visit to the
# same node, the cached W is reused only if the current path suffix
# (of `used_bytes` length) matches the stored one.
#
# When used_bytes == 0: path-independent, same cache behaviour as cata_cached.
# When used_bytes == n: cache is specific to the last n bytes of the path.

function _cata_hybrid_cached!(
    z::ReadZipperCore{V, A}, alg_f::Function, jumping::Bool
) where {V, A}
    zipper_reset!(z)

    stack = _CataFrame[]
    children = []
    # Cache: node_id → (W, path_suffix::Vector{UInt8})
    # suffix is empty when used_bytes == 0 (path-independent result)
    cache = Dict{UInt64, Tuple{Any, Vector{UInt8}}}()
    used_ref = Ref(0)   # captures used_bytes from the most recent alg_f call

    # Wrapper: strips the (W, used) return, captures used into used_ref
    function inner_alg(mask, ch, jump_len, val, path)
        sub_path =
            jumping ? view(path, max(1, length(path) - jump_len):length(path)) : UInt8[]
        (w, used) = alg_f(mask, ch, val, collect(sub_path), path)
        used_ref[] = used
        w
    end

    push!(stack, _CataFrame(z))

    while true
        frame = stack[end]

        if frame.child_idx < frame.child_cnt
            zipper_descend_indexed_byte!(z, frame.child_idx)
            frame.child_idx += 1
            nid = zipper_shared_node_id(z)
            frame.child_addr = nid

            # Cache lookup: check if stored suffix matches current path suffix
            if nid !== nothing && haskey(cache, nid)
                (cached_w, stored_suffix) = cache[nid]
                if isempty(stored_suffix)
                    # Path-independent — always valid
                    push!(children, cached_w)
                    zipper_ascend_byte!(z)
                    continue
                else
                    cur_path = zipper_origin_path(z)
                    n = length(stored_suffix)
                    if length(cur_path) >= n &&
                        view(cur_path, (length(cur_path) - n + 1):length(cur_path)) ==
                       stored_suffix
                        push!(children, cached_w)
                        zipper_ascend_byte!(z)
                        continue
                    end
                    # Suffix mismatch — fall through and recompute
                end
            end

            # Descend to leaf or fork
            is_leaf = false
            while zipper_child_count(z) < 2
                !zipper_descend_until!(z) && (is_leaf=true; break)
            end

            if is_leaf
                used_ref[] = 0
                cur_w = _cata_ascend_to_fork!(z, inner_alg, [], jumping)
                if nid !== nothing
                    used = used_ref[]
                    suffix = if used == 0
                        UInt8[]
                    else
                        copy(
                            view(
                                zipper_origin_path(z),
                                max(1, length(zipper_origin_path(z)) - used + 1):length(
                                    zipper_origin_path(z)
                                )
                            )
                        )
                    end
                    cache[nid] = (cur_w, suffix)
                end
                push!(children, cur_w)
                continue
            end

            push!(stack, _CataFrame(z))
            continue
        end

        # All children of this frame processed
        frame_idx = length(stack)
        sf = pop!(stack)
        child_start = length(children) - sf.child_cnt

        if frame_idx == 1
            @assert zipper_at_root(z)
            val = zipper_val(z)
            child_mask = zipper_child_mask(z)
            sub_ch = children[(child_start + 1):end]
            w = if jumping && sf.child_cnt == 1 && val === nothing
                pop!(children)
            else
                used_ref[] = 0
                full_path = copy(zipper_origin_path(z))
                (w, _used) = alg_f(child_mask, sub_ch, val, UInt8[], full_path)
                w
            end
            return w
        end

        sub_ch = children[(child_start + 1):end]
        used_ref[] = 0
        cur_w = _cata_ascend_to_fork!(z, inner_alg, sub_ch, jumping)
        resize!(children, child_start)

        parent_frame = stack[end]
        if parent_frame.child_addr !== nothing
            nid = parent_frame.child_addr
            used = used_ref[]
            suffix = if used == 0
                UInt8[]
            else
                copy(
                    view(
                        zipper_origin_path(z),
                        max(1, length(zipper_origin_path(z)) - used + 1):length(
                            zipper_origin_path(z)
                        )
                    )
                )
            end
            cache[nid] = (cur_w, suffix)
        end
        push!(children, cur_w)
    end
end

# =====================================================================
# Public hybrid cached cata API
# =====================================================================

"""
    cata_hybrid_cached(m::PathMap, alg_f) → W

Hybrid cached catamorphism (A.0005).  Provides BOTH caching and full
path visibility — ahead of upstream Rust which only has a debug variant.

`alg_f(child_mask, children, val, sub_path, full_path) → (W, used_bytes::Int)`

`used_bytes` controls cache sharing:

  - `0`  → path-independent; cached entry is valid for ANY path (fastest)
  - `n>0`→ cached entry is only reused when the last `n` bytes of the current
    path match the path suffix when the entry was stored.

Example — hash a trie where leaf symbols are path-qualified:

```julia
cata_hybrid_cached(m, (mask, children, val, sub, path) -> begin
    w = hash(mask, hash(path[end:end]))   # uses only last byte
    (w, 1)                                 # used_bytes = 1
end)
```
"""
function cata_hybrid_cached(m::PathMap{V, A}, alg_f::Function) where {V, A}
    z = read_zipper(m)
    _cata_hybrid_cached!(z, alg_f, false)
end

"""
    cata_jumping_hybrid_cached(m::PathMap, alg_f) → W

Jumping variant of `cata_hybrid_cached`.  Skips monotone paths between forks.
Same closure signature: `alg_f(...) → (W, used_bytes::Int)`.
"""
function cata_jumping_hybrid_cached(m::PathMap{V, A}, alg_f::Function) where {V, A}
    z = read_zipper(m)
    _cata_hybrid_cached!(z, alg_f, true)
end

function cata_hybrid_cached(z::ReadZipperCore{V, A}, alg_f::Function) where {V, A}
    _cata_hybrid_cached!(z, alg_f, false)
end
function cata_jumping_hybrid_cached(z::ReadZipperCore{V, A}, alg_f::Function) where {V, A}
    _cata_hybrid_cached!(z, alg_f, true)
end

# =====================================================================
# Anamorphism — build a trie from a generating function
# =====================================================================
#
# Mirrors `new_map_from_ana_jumping`.

"""
    ana_jumping!(wz::WriteZipperCore, w, coalg_f)

Recursively build a trie by calling `coalg_f(w, path) → (prefix, ByteMask, ws, val)`.
Mirrors `new_map_from_ana_jumping`.
"""
function ana_jumping!(wz::WriteZipperCore{V, A}, w, coalg_f::Function) where {V, A}
    path = collect(wz_path(wz))
    result = coalg_f(w, path)
    prefix, bm, ws_iter, mv = result
    prefix_v = collect(UInt8, prefix)
    prefix_len = length(prefix_v)

    wz_descend_to!(wz, prefix_v)
    mv !== nothing && wz_set_val!(wz, mv)

    for (b, wi) in zip(bitmask_iter(bm), ws_iter)
        wz_descend_to_byte!(wz, b)
        ana_jumping!(wz, wi, coalg_f)
        wz_ascend_byte!(wz)
    end

    wz_ascend!(wz, prefix_len)
end

"""
Helper: iterate bytes set in a ByteMask (returns a ByteMaskIter).
"""
bitmask_iter(mask::ByteMask) = iter(mask)

# =====================================================================
# TrieBuilder — anamorphism helper for building tries from callbacks
# =====================================================================
#
# Mirrors `TrieBuilder<V, W, A>` in morphisms.rs.
# Used by callers to declare children before building sub-tries.

"""
    TrieBuilder{V, W, A}

Accumulates child branches (byte + `W` result) for an anamorphism step.
Mirrors `TrieBuilder<V, W, A>`.
"""
mutable struct TrieBuilder{V, W, A <: Allocator}
    child_mask::ByteMask
    child_paths::Vector{Vector{UInt8}}  # sub-paths > 1 byte
    child_ws::Vector{Any}            # W or TrieNodeODRc (WOrNode)
    alloc::A
end

TrieBuilder{V, W}(alloc::A) where {V, W, A} =
    TrieBuilder{V, W, A}(ByteMask(), Vector{UInt8}[], Any[], alloc)
TrieBuilder{V, W}() where {V, W} = TrieBuilder{V, W}(GlobalAlloc())

"""
Push a single-byte child branch with result `w`.
"""
function tb_push_byte!(tb::TrieBuilder, byte::UInt8, w)
    tb.child_mask = set(tb.child_mask, byte)
    push!(tb.child_ws, w)
end

"""
Push a multi-byte sub-path child.
"""
function tb_push!(tb::TrieBuilder, sub_path::AbstractVector{UInt8}, w)
    @assert !isempty(sub_path)
    length(sub_path) > 1 && push!(tb.child_paths, collect(sub_path))
    tb_push_byte!(tb, sub_path[1], w)
end

"""
Number of children pushed so far.
"""
tb_len(tb::TrieBuilder) = length(tb.child_ws)

"""
Returns the child mask.
"""
tb_child_mask(tb::TrieBuilder) = tb.child_mask

"""
Graft a read zipper's focus at `byte`.
"""
function tb_graft_at_byte!(
    tb::TrieBuilder{V, W, A}, byte::UInt8, rc::TrieNodeODRc{V, A}
) where {V, W, A}
    tb.child_mask = set(tb.child_mask, byte)
    push!(tb.child_ws, rc)
end

"""
Reset the builder for reuse.
"""
function tb_reset!(tb::TrieBuilder)
    tb.child_mask = ByteMask()
    empty!(tb.child_paths)
    empty!(tb.child_ws)
end

# =====================================================================
# Exports
# =====================================================================

export cata_side_effect, cata_jumping_side_effect
export cata_cached, cata_jumping_cached
export cata_hybrid_cached, cata_jumping_hybrid_cached
export ana_jumping!
export TrieBuilder, tb_push_byte!, tb_push!, tb_len, tb_child_mask
export tb_graft_at_byte!, tb_reset!
export map_hash, map_hash_value
export zipper_origin_path, zipper_shared_node_id
