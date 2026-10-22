# Example

A full run for two species of *Calceolaria*, from a name checklist to occurrence
maps. The code on this page isn't run when the documentation is built (it
downloads from POWO (or WFO), GBIF & iDigBio), so no output is shown.

```julia
using PlantOccurrences
using CSV, DataFrames
```

The folders used below:

```julia
raw_dir       = "data/pt_occs_raw"
clean_dir     = "data/pt_occs_clean"
no_coords_dir = "data/pt_occs_to_georeference"
geolocate_dir = "data/pt_occs_to_georeference_geolocate_format"
georef_dir    = "data/pt_occs_georeferenced"
final_dir     = "data/pt_occs_final"
```

## 1. Build a checklist

[`build_checklist`](@ref) gets every name in a genus (or genera, or a whole
family) from POWO: accepted names, their synonyms & each accepted name's native
range as TDWG botanical countries.

```julia
checklist = build_checklist("Calceolariaceae", "Calceolaria"; output_file="data/calceolaria_checklist.csv")
```

Looking up the native ranges takes one request per accepted name, so it's the
slow part of a large checklist. Use `include_distribution=false` to skip it.

### Or: build it from World Flora Online

[`build_wfo_checklist`](@ref) builds the same checklist from World Flora Online
(WFO) instead, & takes the same family + genus (or genera) arguments:

```julia
checklist = build_wfo_checklist("Calceolariaceae", "Calceolaria"; output_file="data/calceolaria_wfo_checklist.csv")
```

The rest of this example works the same way with either checklist, except:

- **WFO has no distribution data**, so the checklist's `native_range` &
  `native_range_codes` columns are empty. [`checklist_native_range`](@ref)
  returns an empty vector, so the `botanicalCountries` in step 7 will be empty
  too & the maps won't show a native range. To get native ranges, use
  [`build_checklist`](@ref) (POWO).
- Its synonyms are the names that point to a taxon in the genus, from any
  genus. Names *in* the genus that are synonyms of taxa in other genera aren't
  included.
- WFO also lists names it hasn't placed as either accepted or a synonym. They
  come in with `accepted = false` & no `accepted_name`; use
  `include_unplaced=false` to leave them out.

## 2. Get each taxon's synonyms & homonyms

Occurrences are pulled & cleaned from a `synonymdict`: each taxon => all of its
names, as `(name, authority)` tuples.

```julia
taxa = ["Calceolaria alba", "Calceolaria nitida"]
synonymdict = Dict(t => checklist_synonyms(checklist, t) for t in taxa)
```

Some names are used for more than one taxon, under different authorities.
[`find_homonyms_to_exclude`](@ref) works out which of those belong to a
*different* taxon, so that their records can be dropped when cleaning:

```julia
homonyms = checklist_homonyms(checklist)
homonyms_to_exclude = find_homonyms_to_exclude(synonymdict, homonyms)
```

## 3. Pull occurrences

One raw CSV per taxon, from GBIF & iDigBio (via `gatoRs`). Taxa that already
have a file for today are skipped, so this is safe to re-run.

```julia
pulled = pull_occurrences(synonymdict, raw_dir)
pulled.no_data   # taxa with no records
pulled.failed    # taxa that errored
```

## 4. Clean

[`clean_occurrences`](@ref) cleans the most recent raw file of every taxon:
it keeps the records that match the synonym list, drops duplicates, homonyms &
unwanted record types, cleans up the coordinates, and sets aside the records
that have a locality but no coordinates.

```julia
stats = clean_occurrences(synonymdict, raw_dir, clean_dir, no_coords_dir;
    homonyms_to_exclude = homonyms_to_exclude,
    lat_max = 15, lon_max = -30)    # optional bounding box
```

`stats` has the number of records left after each step, for each taxon.

## 5. Georeference the records with no coordinates

Reformat the records that were set aside for
[GEOLocate](https://www.geo-locate.org/)'s batch tool:

```julia
prepare_geolocate_files(no_coords_dir, geolocate_dir)
```

After georeferencing, add a `VIABLE` column (`TRUE` / `FALSE`, and optionally a
`NOTES` column) and save each file to `georef_dir` as `.csv` or `.xlsx`, keeping
the taxon in the file name. Then add the viable points to the cleaned
occurrences:

```julia
mkpath(final_dir)
for taxon in taxa
    filename = replace(taxon, " " => "_")
    georef_df = load_georef_df(filename, georef_dir)
    isnothing(georef_df) && continue    # nothing georeferenced for this taxon

    clean_df = read_occs(resolve_clean_file(filename, clean_dir))
    no_coords_df = read_occs(latest_no_coords_file(filename, no_coords_dir))

    merged = merge_georef(clean_df, no_coords_df, georef_df)
    CSV.write(joinpath(final_dir, "$(filename).csv"), merged)
end
```

## 6. Filter out points by hand

Each `*_mask` function returns `true` for the rows to keep, and
[`remove_rows`](@ref) applies a mask while keeping a record of what was removed
& why:

```julia
df = read_occs(resolve_clean_file("Calceolaria_nitida", clean_dir))
removed = DataFrame[]

df = remove_rows(df, coords_mask(df; lat_min=-38), "south of -38", removed)
df = remove_rows(df, countries_mask(df, ["Argentina"]), "outside native range", removed)

plot_kept_removed(df, removed; title="Calceolaria nitida")
```

There are also file-to-file versions: [`filter_coords`](@ref) (which previews
the result on a map before saving anything), [`filter_countries`](@ref) &
[`filter_scientific_names`](@ref).

## 7. Map the results

The maps need a CSV of the taxa with `scientificName` & `botanicalCountries`
columns, which is used to draw each taxon's native range under its points
(the native ranges come from a POWO checklist; with a WFO one,
`botanicalCountries` is empty & no native range is drawn):

```julia
traits = DataFrame(
    scientificName = taxa,
    botanicalCountries = [join(checklist_native_range(checklist, t), ", ") for t in taxa],
)
CSV.write("data/taxa.csv", traits)
```

The TDWG level-3 botanical country shapefile comes with the package & is used by
default. To use a different one, pass `shapefile_path`.

```julia
# one taxon, raw vs. cleaned, in the R graphics viewer
plot_species("Calceolaria alba";
    traits_path = "data/taxa.csv",
    raw_dir = raw_dir, clean_dir = clean_dir, georef_dir = georef_dir)

# every taxon, one page each
plot_all_occurrence_maps(
    traits_path = "data/taxa.csv",
    raw_dir = raw_dir, clean_dir = clean_dir, georef_dir = georef_dir,
    pdf_file = "occurrence_maps.pdf")
```

## 8. Load everything

Stack the occurrence files of every taxon into one DataFrame, with a `taxon`
column:

```julia
occs = load_pt_occs_df(clean_dir)
```
