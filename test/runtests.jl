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

    @testset "build_checklist (from a tiny fake WCVP)" begin
        mktempdir() do dir
            write(joinpath(dir, "wcvp_names.csv"), """
                plant_name_id|ipni_id|taxon_rank|taxon_status|family|genus|taxon_name|taxon_authors|accepted_plant_name_id|powo_id
                1|1-1|Genus|Accepted|Fooaceae|Foo|Foo|L.|1|1-1
                2|2-1|Species|Accepted|Fooaceae|Foo|Foo bar|L.|2|2-1
                3|3-1|Species|Synonym|Fooaceae|Foo|Foo baz|Smith|2|3-1
                4|4-1|Species|Synonym|Fooaceae|Foo|Foo qux|Jones|5|4-1
                5|5-1|Species|Accepted|Fooaceae|Quxia|Quxia qux|(Jones) Lee|5|5-1
                6|6-1|Species|Misapplied|Fooaceae|Foo|Foo bar|auct.|5|6-1
                7||Species|Unplaced|Fooaceae|Foo|Foo dubia|Doe||7-4
                """)
            write(joinpath(dir, "wcvp_distribution.csv"), """
                plant_locality_id|plant_name_id|continent_code_l1|continent|region_code_l2|region|area_code_l3|area|introduced|extinct|location_doubtful
                1|2|8|SOUTHERN AMERICA|85|Southern South America|CLS|Chile South|0|0|0
                2|2|8|SOUTHERN AMERICA|85|Southern South America|CLC|Chile Central|0|0|0
                3|2|8|SOUTHERN AMERICA|85|Southern South America|AGW|Argentina Northwest|1|0|0
                4|2|8|SOUTHERN AMERICA|85|Southern South America|AGS|Argentina South|0|1|0
                5|5|8|SOUTHERN AMERICA|84|Brazil|BZS|Brazil South|0|0|0
                """)

            df = build_checklist("Fooaceae", "Foo"; wcvp_dir = dir)
            @test df.name == ["Foo", "Foo bar", "Foo baz", "Foo dubia", "Foo qux"]  # no misapplied name
            @test df.accepted == [true, true, false, false, false]
            @test df.accepted_name == ["", "", "Foo bar", "", "Quxia qux"]
            @test df.accepted_author[end] == "(Jones) Lee"
            @test df.ipni_id[2] == "urn:lsid:ipni.org:names:2-1"
            @test df.native_range[2] == "Chile Central; Chile South"  # introduced & extinct areas left out
            @test checklist_native_range(df, "Foo bar") == ["CLC", "CLS"]
            @test checklist_synonyms(df, "Foo bar") == [("Foo bar", "L."), ("Foo baz", "Smith")]

            @test build_checklist("Fooaceae", "Foo"; wcvp_dir = dir, include_synonyms = false).name == ["Foo", "Foo bar"]
            @test all(isempty, build_checklist("Fooaceae", "Foo"; wcvp_dir = dir, include_distribution = false).native_range)
            both = build_checklist("Fooaceae", ["Foo", "Quxia", "Foo"]; wcvp_dir = dir)
            @test unique(both.genus_queried) == ["Foo", "Quxia"]
            @test nrow(build_checklist("Fooaceae"; wcvp_dir = dir)) == 6
            @test_throws ArgumentError build_checklist(" "; wcvp_dir = dir)
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
