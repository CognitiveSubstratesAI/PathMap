using Documenter
using PathMaps

DocMeta.setdocmeta!(PathMaps, :DocTestSetup, :(using PathMaps); recursive=true)

makedocs(;
    modules=[PathMaps],
    authors="CognitiveSubstrates AI",
    repo=Remotes.GitHub("CognitiveSubstratesAI", "PathMap"),
    sitename="PathMap.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        canonical="https://cognitivesubstratesai.github.io/PathMap/stable/",
        edit_link="main",
        assets=String[]
    ),
    pages=[
        "Home" => "index.md",
        "Guide" => [
            "Getting Started" => "guide/getting_started.md",
            "Zippers" => "guide/zippers.md",
            "Algebra" => "guide/algebra.md",
            "Morphisms" => "guide/morphisms.md",
            "Serialization" => "guide/serialization.md"
        ],
        "Advanced" => [
            "Lazy COW" => "advanced/lazy_cow.md",
            "Policy API" => "advanced/policy_api.md",
            "Hybrid Catamorphism" => "advanced/hybrid_cata.md"
        ],
        "API Reference" => "api/README.md"
    ],
    # Pre-existing guide/advanced markdown wasn't authored for Documenter; tolerate
    # warnings on the first build (tighten once the pages are Documenter-native).
    warnonly=true
)

deploydocs(; repo="github.com/CognitiveSubstratesAI/PathMap", devbranch="main")
