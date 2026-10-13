using Documenter
using PlantOccurrences

makedocs(
    sitename = "PlantOccurrences.jl",
    modules = [PlantOccurrences],
    authors = "Lauren Frankel",
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", "false") == "true",
        canonical = "https://tribblelab.github.io/PlantOccurrences.jl",
        edit_link = "main",
    ),
    pages = [
        "Home" => "index.md",
        "Example" => "example.md",
        "Functions" => "functions.md",
    ],
    checkdocs = :exports,
)

deploydocs(
    repo = "github.com/tribblelab/PlantOccurrences.jl.git",
    devbranch = "main",
)
