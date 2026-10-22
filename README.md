# PlantOccurrences.jl

Plant biologists often use publicly available datasets from herbaria to know the temporal + spatial range of their organisms (aka occurrence data). This package interfaces with commonly used databases to build a checklist of currently accepted species names + previously accepted names from [WCVP / POWO](https://powo.science.kew.org/), or [World Flora Online](https://www.worldfloraonline.org/). With those checklists, we can now pull occurrence records for each taxon & its synonyms from [GBIF](https://www.gbif.org/) / [iDigBio](https://idigbio.gbif.us/). With our data in hand, we then clean points & map them.

documentation & a worked example: <https://tribblelab.github.io/PlantOccurrences.jl/dev/>

## R package dependencies + install

the cleaning, pulling & plotting functions call R (via RCall), so R needs to be installed, along with these packages. they're loaded when the package is, so install them first:

```R
packages <- c("gatoRs", "ggplot2", "sf", "ggspatial", "gridExtra", "readxl", "dplyr")
new_packages <- packages[!(packages %in% installed.packages()[,"Package"])]
if(length(new_packages)) install.packages(new_packages)
```

## installing

the package isn't registered (yet), so add it from GitHub:

```julia
using Pkg
Pkg.add(url="https://github.com/tribblelab/PlantOccurrences.jl")
```

or, to work on the package itself, clone the repo & start Julia in it with `julia --project`:

```julia
using Pkg
# install the packages listed in the environment
Pkg.instantiate()
```

then:

```julia
using PlantOccurrences
```

## what's in `src/`

| file | functions |
|---|---|
| `checklistutils.jl` | `build_checklist`: build a WCVP/POWO name checklist for a family + genus (or `build_wfo_checklist` for one from World Flora Online, without native ranges); then `checklist_synonyms`, `checklist_native_range` & `checklist_homonyms` to get each taxon's synonyms, native range & homonyms out of it |
| `occpulling.jl` | `pull_occurrences` (GBIF / iDigBio, via gatoRs), `append_occurrences` |
| `fileutils.jl` | find & load per-taxon files: `latest_raw_file`, `resolve_clean_file`, `latest_no_coords_file`, `taxon_files`, `taxon_stem`, `read_occs`, `normalize_id`, `load_taxa_data`, `read_georef_file`, `load_georef_df`, `load_pt_occs_df` |
| `datacleaning.jl` | `find_homonyms_to_exclude`, `clean_occurrences` (batch gatoRs cleaning), `prepare_geolocate_files`, `merge_georef`, `carry_over_georef`; filters as masks (`coords_mask`, `countries_mask`, `names_mask`, applied & logged with `remove_rows`) or file to file (`filter_coords`, `filter_countries`, `filter_scientific_names`); `plot_kept_removed` |
| `plottingutils.jl` | `plot_species`, `plot_all_occurrence_maps` |

the functions expect one file per taxon, named with the taxon (spaces → underscores) & the date it was pulled:

- raw occurrences: `<taxon>-<yyyy_mm_dd>.csv`
- cleaned occurrences: `<taxon>-<yyyy_mm_dd>_cleaned.csv`
- occurrences with no coordinates: `<taxon>-<yyyy_mm_dd>_no_coords.csv`
- final occurrences (cleaned + georeferenced + filtered): `<taxon>.csv`

a typical run:

```julia
using PlantOccurrences

# names, synonyms & native ranges for a genus
checklist = build_checklist("Calceolariaceae", "Calceolaria")

# taxon => its synonyms, as (name, authority) tuples
taxa = ["Calceolaria alba", "Calceolaria nitida"]
synonymdict = Dict(t => checklist_synonyms(checklist, t) for t in taxa)
homonyms_to_exclude = find_homonyms_to_exclude(synonymdict, checklist_homonyms(checklist))

pull_occurrences(synonymdict, "data/pt_occs_raw")
stats = clean_occurrences(synonymdict, "data/pt_occs_raw", "data/pt_occs_clean", "data/pt_occs_to_georeference";
    homonyms_to_exclude = homonyms_to_exclude)
prepare_geolocate_files("data/pt_occs_to_georeference", "data/pt_occs_to_georeference_geolocate_format")
```

## Botanical country shapefiles

In [data/bot_country_shapefiles](https://github.com/tribblelab/PlantOccurrences.jl/tree/main/data/bot_country_shapefiles), there are shapefiles for plotting botanical countries, copied from the [World Geographical Scheme for Recording Plant Distributions](https://github.com/tdwg/wgsrpd/tree/master/level3). These were downloaded on 2026-4-15.

## AI usage

This package has been developed with help from Anthropic's Claude (mainly Opus 5.5 model), refactoring code written by the developer for [hyb_niches](https://github.com/tribblelab/hyb_niches) to be generalizable for all plant taxa. All functions/examples have been tested by the developer.
