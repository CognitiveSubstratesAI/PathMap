# PathMap — Julia port of adam-Vandervorst/PathMap
# Upstream reference: ~/dev-zone/PathMap
module PathMaps

using Mmap   # real OS memory-mapping for read-only .act backing (act_open_mmap)

# ── Core algebraic primitives ─────────────────────────────────────────────────

# Allocator shim (`Allocator` + `GlobalAlloc`). Ports pathmap/src/alloc.rs.
include("core/Alloc.jl")

# Core algebraic machinery (used by everything downstream).
# Ports pathmap/src/ring.rs.
include("core/Ring.jl")

# ── Utility types ─────────────────────────────────────────────────────────────

# 256-bit BitMask surface + ByteMask type + ByteMaskIter.
# Ports pathmap/src/utils/mod.rs.
include("utils/Utils.jl")

# Integer encoding utilities (BOB + weave).
# Ports pathmap/src/utils/ints.rs.
include("utils/Ints.jl")

# ── Trie node types ───────────────────────────────────────────────────────────

# TrieNode abstract interface, TrieNodeODRc, PayloadRef, ValOrChild.
# Ports pathmap/src/trie_node.rs.
include("nodes/TrieNode.jl")

# Zero-field singleton for empty trie positions. Ports pathmap/src/empty_node.rs.
include("nodes/EmptyNode.jl")

# Compact 2-slot trie node. Ports pathmap/src/line_list_node.rs.
include("nodes/LineListNode.jl")

# Read-only 1-entry borrowed view (≤7-byte key). Ports pathmap/src/tiny_node.rs.
include("nodes/TinyRefNode.jl")

# 256-slot bitmap-indexed node. Ports pathmap/src/dense_byte_node.rs.
include("nodes/DenseByteNode.jl")
include("nodes/BridgeNode.jl")

# The CLOSED union of node types + the narrowing accessors — needs every node type to exist first.
include("nodes/NodeVariant.jl")

# ── ADR-001 node-slab scaffold (additive; NOT wired into the live trie yet) ────
include("pathmap/NodeSlab.jl")
include("pathmap/SlabTrie.jl")

# ── Zipper / cursor layer ─────────────────────────────────────────────────────

# Read zipper. Ports pathmap/src/zipper.rs.
include("zipper/ZipperTraits.jl")   # upstream 0.4.0 zipper traits as generic functions
include("zipper/Zipper.jl")

# PathMap — byte-slice-keyed trie map container + lattice ops.
# Ports pathmap/src/trie_map.rs.
include("pathmap/PathMap.jl")

# Write zipper. Ports pathmap/src/write_zipper.rs.
include("zipper/WriteZipper.jl")

# Lightweight read-only trie reference. Ports pathmap/src/trie_ref.rs.
include("zipper/TrieRef.jl")

# Zipper path tracking. Ports pathmap/src/zipper_tracking.rs.
include("zipper/ZipperTracking.jl")

# ZipperHead. Ports pathmap/src/zipper_head.rs.
include("zipper/ZipperHead.jl")

# OverlayZipper. Ports pathmap/src/overlay_zipper.rs.
include("zipper/OverlayZipper.jl")

# PrefixZipper. Ports pathmap/src/prefix_zipper.rs.
include("zipper/PrefixZipper.jl")

# ProductZipper. Ports pathmap/src/product_zipper.rs.
include("zipper/ProductZipper.jl")

# EmptyZipper. Ports pathmap/src/empty_zipper.rs.
include("zipper/EmptyZipper.jl")

# DependentZipper. Ports pathmap/src/dependent_zipper.rs.
include("zipper/DependentZipper.jl")

# ProductZipperG — generic product zipper. Ports ProductZipperG in product_zipper.rs.
include("zipper/ProductZipperG.jl")

# PathTracker — gives ZipperPath to any moving zipper. Ports pathmap/src/path_tracker.rs.
include("zipper/PathTracker.jl")

# ── PathMap algorithmic layer ─────────────────────────────────────────────────

# Morphisms. Ports pathmap/src/morphisms.rs.
# GxHasher — upstream's 128-bit state mixer, which Catamorphism::hash folds with.
# Must precede Morphisms.jl: map_hash consumes it.
include("pathmap/GxHash.jl")
include("pathmap/Morphisms.jl")

# ArenaCompact. Ports pathmap/src/arena_compact.rs.
include("pathmap/ArenaCompact.jl")

# PathsSerialization. Ports pathmap/src/paths_serialization.rs.
include("pathmap/PathsSerialization.jl")

# Counters. Ports pathmap/src/counters.rs.
include("pathmap/Counters.jl")

# Viz. Ports pathmap/src/viz.rs (Mermaid trie rendering; observe structural sharing).
include("pathmap/Viz.jl")

# Policy-based algebraic operations (A.0003).
include("pathmap/PolicyOps.jl")

# Experimental N-ary zipper merge (zipper_n_join/meet/subtract).
# Ports upstream PathMap src/experimental/zipper_algebra.rs (PR #35).
include("experimental/ZipperAlgebra.jl")

# PrecompileTools workload — caches hot method instances during Pkg.precompile().
include("precompile.jl")

"""
    version() -> VersionNumber

The upstream PathMap version whose API and semantics this package ports (`~/dev-zone/PathMap` Cargo.toml).
0.4.0 since 2026-09-17: the zipper trait surface, its return shapes and the node iteration-token contract
are upstream's 0.4.0 ones (docs/ZIPPER_API_0.4.0_PORT_PLAN.md).
"""
version() = v"0.4.0"

export version

end # module PathMaps
