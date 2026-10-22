using PlantOccurrences
using DataFrames
using Test

# these only test the pure-Julia helpers: the pulling, cleaning & plotting functions need
# R packages & network access

@testset "PlantOccurrences" begin
    @testset "taxon_stem" begin
        @test taxon_stem("Genus_species.csv") == "Genus_species"
        @test taxon_stem("Genus_species-2026_10_06.csv") == "Genus_species"
        @test taxon_stem("Genus_species-2026-10-06_cleaned.csv") == "Genus_species"
        @test taxon_stem("Genus_species-2026_10_06_no_coords.csv") == "Genus_species"
        @test taxon_stem("Genus_species_georef_merged.csv") == "Genus_species"
        @test taxon_stem("Genus_species_var._x.xlsx") == "Genus_species_var._x"
    end

    @testset "normalize_id" begin
        @test ismissing(normalize_id(missing))
        @test normalize_id(1260392010) == "1260392010"
        @test normalize_id(1.26039201e9) == "1260392010"
        @test normalize_id("1.26039201E9") == "1260392010"
        @test normalize_id(" 1260392010 ") == "1260392010"
        @test normalize_id("c0f3a1e2-uuid") == "c0f3a1e2-uuid"
    end

    @testset "finding files" begin
        mktempdir() do dir
            for f in ["Genus_species-2026_01_01.csv", "Genus_species-2026_02_01.csv",
                      "Genus_species_var._x-2026_03_01.csv", "Genus_species-2026_02_01_no_coords.csv"]
                touch(joinpath(dir, f))
            end
            @test latest_raw_file("Genus_species", dir) == (joinpath(dir, "Genus_species-2026_02_01.csv"), "2026_02_01")
            @test latest_raw_file("Genus_other", dir) == ("", "")
            @test latest_no_coords_file("Genus_species", dir) == joinpath(dir, "Genus_species-2026_02_01_no_coords.csv")
            @test resolve_clean_file("Genus_species", dir) == joinpath(dir, "Genus_species-2026_02_01.csv")
            @test first.(taxon_files(dir)) == ["Genus_species", "Genus_species_var._x"]
        end
    end

    @testset "masks & remove_rows" begin
        df = DataFrame(latitude=[10.0, -5.0, missing, 40.0],
                       longitude=[20.0, 30.0, 0.0, -100.0],
                       country=["Peru", "Chile", missing, "Peru"],
                       scientificName=["A b", "A c", "A b", missing])

        @test coords_mask(df; lat_min=0) == [true, false, false, true]
        @test coords_mask(df; lon_max=25) == [true, false, true, true]
        @test_throws ErrorException coords_mask(df)
        @test countries_mask(df, ["Peru"]) == [false, true, true, false]
        @test_throws ErrorException countries_mask(df, ["Peru"]; country_col=:nope)
        @test names_mask(df, ["A b"]) == [false, true, false, true]

        removed = DataFrame[]
        kept = remove_rows(df, coords_mask(df; lat_min=0), "south of the equator", removed)
        @test nrow(kept) == 2
        @test length(removed) == 1
        @test removed[1].removed_reason == ["south of the equator", "south of the equator"]

        # nothing to remove: the same df back & nothing logged
        @test remove_rows(kept, trues(nrow(kept)), "none", removed) === kept
        @test length(removed) == 1
    end
end
