module PlantOccurrences

using CSV
using DataFrames
using Dates
using HTTP
using JSON3
using NetworkOptions
using RCall

export build_checklist, build_wfo_checklist, ChecklistEntry, to_table, checklist_synonyms, checklist_native_range, checklist_homonyms
export pull_occurrences, append_occurrences
export latest_raw_file, resolve_clean_file, latest_no_coords_file, taxon_files, taxon_stem, read_occs,
    normalize_id, load_taxa_data, read_georef_file, load_georef_df, load_pt_occs_df
export find_homonyms_to_exclude, clean_occurrences, prepare_geolocate_files, merge_georef, carry_over_georef,
    coords_mask, countries_mask, names_mask, remove_rows,
    filter_coords, filter_countries, filter_scientific_names, plot_kept_removed
export plot_species, plot_all_occurrence_maps

# the R packages the pulling, cleaning & plotting functions use
const R_PACKAGES = ["gatoRs", "ggplot2", "sf", "ggspatial", "gridExtra", "readxl", "dplyr"]
const R_PACKAGES_LOADED = Ref(false)

"""
    load_r_packages()

Load the R packages the pulling, cleaning & plotting functions need. It's called by
those functions the first time one runs (not when the package is imported, so
`using PlantOccurrences` works without them), & errors with an install command if
any are missing.
"""
function load_r_packages()
    R_PACKAGES_LOADED[] && return nothing
    r_packages = R_PACKAGES
    @rput r_packages
    missing_pkgs = rcopy(Vector{String}, R"as.character(setdiff(r_packages, rownames(installed.packages())))")
    if !isempty(missing_pkgs)
        error("these R packages need to be installed first: $(join(missing_pkgs, ", ")). in R, run:\n" *
              "    install.packages(c($(join(repr.(missing_pkgs), ", "))))")
    end
    R"""
    library(gatoRs)
    library(ggplot2)
    library(sf)
    library(ggspatial)
    library(gridExtra)
    library(dplyr) #needs to be loaded in last, so it defaults to correct `filter` fxn
    """
    R_PACKAGES_LOADED[] = true
    return nothing
end

# fileutils.jl goes first, since the others use it
include("fileutils.jl")
include("checklistutils.jl")
include("occpulling.jl")
include("datacleaning.jl")
include("plottingutils.jl")

end # module
