#!/usr/bin/env julia
# examples/word_index.jl — Build a word frequency index using PathMap
#
# Demonstrates:
#   - PathMap construction from real text
#   - Write zipper for incremental updates
#   - Policy API (SumPolicy) for frequency aggregation
#   - Read zipper iteration
#   - cata_cached for structural statistics
#
# Run:
#   julia --project=. examples/word_index.jl

using PathMap

# ── Build a word → count map from a string corpus ─────────────────────
function word_frequency(text::String)
    m = PathMap.PathMap{Int}()
    for word in split(lowercase(text), r"\W+"; keepempty=false)
        key = Vector{UInt8}(word)
        existing = get_val_at(m, key)
        set_val_at!(m, key, existing === nothing ? 1 : existing + 1)
    end
    m
end

corpus = """
to be or not to be that is the question
whether tis nobler in the mind to suffer
the slings and arrows of outrageous fortune
or to take arms against a sea of troubles
"""

println("=== Word Frequency Index ===")
freq = word_frequency(corpus)
println("Unique words: ", val_count(freq))

# ── Iterate top words via read zipper ─────────────────────────────────
println("\nAll words (alphabetical, DFS order):")
rz = read_zipper(freq)
while to_next_val!(rz)
    word = String(copy(path(rz)))
    count = val(rz)
    count > 1 && println("  $word => $count")
end

# ── Merge two corpora with SumPolicy ──────────────────────────────────
corpus2 = "to be or not to be again and again"
freq2 = word_frequency(corpus2)

println("\nAfter merging second corpus (SumPolicy):")
merged = pjoin_policy(freq, freq2, SumPolicy())
println("  'to'  => ", get_val_at(merged, b"to"))
println("  'be'  => ", get_val_at(merged, b"be"))
println("  'the' => ", get_val_at(merged, b"the"))

# ── Structural statistics via cata_cached ─────────────────────────────
total_occurrences = cata_cached(
    merged,
    (mask, children, val) -> (val !== nothing ? val : 0) + reduce(+, children; init=0)
)

println("\nTotal word occurrences: ", total_occurrences)
println("Unique words in merged: ", val_count(merged))
