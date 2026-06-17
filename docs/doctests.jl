# Fast, node-free doctest gate for CI. Runs only the docstring doctests via
# `Documenter.doctest` — no page build, no Vitepress/npm, no deploy. The full
# `make.jl` (which also runs these as part of the Vitepress build) is exercised
# separately by Documentation.yml.
using Documenter, ParselTongue

doctest(ParselTongue)
