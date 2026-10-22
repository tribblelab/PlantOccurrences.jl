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

# the R libraries have to be loaded when the package is (not when it's precompiled)
function __init__()
    R"""
    library(gatoRs)
    library(ggplot2)
    library(sf)
    library(ggspatial)
    library(gridExtra)
    library(dplyr) #needs to be loaded in last, so it defaults to correct `filter` fxn
    """
end

# fileutils.jl goes first, since the others use it
include("fileutils.jl")
include("checklistutils.jl")
include("occpulling.jl")
include("datacleaning.jl")
include("plottingutils.jl")

end # module
