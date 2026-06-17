# Fast, node-free doctest gate for CI. Runs only the docstring doctests via
# `Documenter.doctest` — no page build, no Vitepress/npm, no deploy. The full
# `make.jl` (which also runs these as part of the Vitepress build) is exercised
# separately by Documentation.yml.
using Documenter, ParselTongue

# Work around TypeContracts ≤ 0.13: `@contract` attaches a marker docstring whose
# `:path` is `nothing`, which crashes Documenter's doctest runner (it requires a
# String path for every docstring). Backfill an empty path. See make.jl for the
# longer explanation; remove once TypeContracts sets a valid `:path`.
for (_, multidoc) in Documenter.DocSystem.getmeta(ParselTongue)
    for (_, docstr) in multidoc.docs
        if get(docstr.data, :path, "") === nothing
            docstr.data[:path] = ""
        end
    end
end

doctest(ParselTongue)
