# PlantOccurrences.jl

Build a plant name checklist (WCVP / POWO), pull occurrence records for each
taxon & its synonyms (GBIF / iDigBio), then clean, georeference & map them.

The package covers the steps *before* niche modeling: it gets you from a list of
taxa to one cleaned occurrence file per taxon.

- [Example](@ref): a full run, from checklist to maps
- [Functions](@ref): every exported function

## Installing

### R packages

The pulling, cleaning & plotting functions call R (via
[RCall](https://github.com/JuliaInterop/RCall.jl)), so R needs to be installed,
along with these packages. They're loaded when the package is, so install them
first:

```r
packages <- c("gatoRs", "ggplot2", "sf", "ggspatial", "gridExtra", "readxl", "dplyr")
new_packages <- packages[!(packages %in% installed.packages()[,"Package"])]
if(length(new_packages)) install.packages(new_packages)
```

### The package

The package isn't registered (yet), so add it from GitHub:

```julia
using Pkg
Pkg.add(url="https://github.com/tribblelab/PlantOccurrences.jl")
```

```julia
using PlantOccurrences
```

## File naming

The functions expect one file per taxon, named with the taxon (spaces →
underscores) & the date it was pulled:

| | file name |
|---|---|
| raw occurrences | `<taxon>-<yyyy_mm_dd>.csv` |
| cleaned occurrences | `<taxon>-<yyyy_mm_dd>_cleaned.csv` |
| occurrences with no coordinates | `<taxon>-<yyyy_mm_dd>_no_coords.csv` |
| final occurrences (cleaned + georeferenced + filtered) | `<taxon>.csv` |

When a taxon has been pulled more than once, the most recent file is used.
