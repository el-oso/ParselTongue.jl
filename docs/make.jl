using Documenter, DocumenterVitepress
using ParselTongue

DocMeta.setdocmeta!(ParselTongue, :DocTestSetup, :(using ParselTongue); recursive = true)

makedocs(;
    modules = [ParselTongue],
    authors = "el_oso",
    sitename = "ParselTongue.jl",
    remotes = nothing,
    format = DocumenterVitepress.MarkdownVitepress(
        repo = "github.com/el_oso/ParselTongue.jl",
        devbranch = "main",
        devurl = "dev",
        description = "Python extensions written in Julia, via juliac --trim.",
        sidebar_drawer = true,
    ),
    pages = [
        "Home" => "index.md",
        "Guide" => [
            "Getting Started"      => "guide/getting-started.md",
            "Boundary Types"       => "guide/boundary-types.md",
            "Building"             => "guide/building.md",
            "Limitations"          => "guide/limitations.md",
            "ParselTongue vs PyO3" => "guide/vs-pyo3.md",
        ],
        "Examples" => [
            "Scalars (mathx)"        => "examples/scalars.md",
            "Strings (strx)"         => "examples/strings.md",
            "Arrays & NumPy (arrx)"  => "examples/arrays.md",
            "A Statistics Module"    => "examples/statistics.md",
            "Scientific Module (sci)"=> "examples/scientific.md",
        ],
        "Reference" => [
            "API Reference" => "reference/api.md",
        ],
    ],
    checkdocs = :exports,
    warnonly = true,
)

DocumenterVitepress.deploydocs(;
    repo = "github.com/el_oso/ParselTongue.jl",
    push_preview = true,
)
