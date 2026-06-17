using Documenter, DocumenterVitepress
using ParselTongue

makedocs(;
    modules = [ParselTongue],
    authors = "el-oso",
    sitename = "ParselTongue.jl",
    remotes = nothing,
    format = DocumenterVitepress.MarkdownVitepress(
        repo = "github.com/el-oso/ParselTongue.jl",
        devbranch = "master",
        devurl = "dev",
        description = "Python extensions written in Julia, via juliac --trim.",
        sidebar_drawer = true,
    ),
    pages = [
        "Home" => "index.md",
        "Guide" => [
            "Getting Started" => "guide/getting-started.md",
            "Boundary Types" => "guide/boundary-types.md",
            "Building" => "guide/building.md",
            "The pt CLI" => "guide/cli.md",
            "Limitations" => "guide/limitations.md",
            "ParselTongue vs PyO3" => "guide/vs-pyo3.md",
        ],
        "Examples" => [
            "Scalars (mathx)" => "examples/scalars.md",
            "Strings (strx)" => "examples/strings.md",
            "Arrays & NumPy (arrx)" => "examples/arrays.md",
            "A Statistics Module" => "examples/statistics.md",
            "Scientific Module (sci)" => "examples/scientific.md",
        ],
        "Reference" => [
            "API Reference" => "reference/api.md",
        ],
    ],
    checkdocs = :exports,
    doctest = true,
    # Everything stays a soft warning EXCEPT doctests, which fail the build so CI
    # catches stale examples. (The Vitepress-style absolute cross-reference links
    # in the .md guides trip Documenter's standard checker; keep those soft.)
    warnonly = [
        :autodocs_block, :cross_references, :docs_block,
        :eval_block, :example_block, :footnote, :linkcheck_remotes, :linkcheck,
        :meta_block, :missing_docs, :parse_error, :setup_block,
    ],
)

DocumenterVitepress.deploydocs(;
    repo = "github.com/el-oso/ParselTongue.jl",
    devbranch = "master",
    push_preview = true,
)
