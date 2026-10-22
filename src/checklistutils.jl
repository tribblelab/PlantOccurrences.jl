#=
checklistutils.jl

Builds a plant-name checklist for a given family + genus (or genera), using
the same underlying data source (WCVP, via the POWO search API) that powers
Kew's "Build a checklist" tool at:
https://checklistbuilder.science.kew.org/reportbuilder.do

NOTE ON WHY THIS TALKS TO powo.science.kew.org INSTEAD OF checklistbuilder:
`reportbuilder.do` is a legacy, session-bound multi-page Java web app
(jsessionid, hidden form state, a genus dropdown that's AJAX-populated only
after a family is picked). It has no documented/stable set of POST
parameters, so it can't be reliably driven from an external script -- any
attempt would be guesswork that could silently return wrong results.

The POWO search API (used internally by Kew's own `pykew` and the
community `kewr` R package) exposes the same WCVP-backed data and is
queryable directly. This function reproduces the checklist builder's
*default* settings:
  - Taxonomy filter: family + genus (or genera)
  - Distribution: none selected (i.e. worldwide / no location filter)
  - Type of taxa: "Native and Introduced taxa" (i.e. no native/introduced/
    endemic restriction)
  - Format: "Summary Checklist (Names listed by taxonomic status)" --
    accepted names first, then their synonyms grouped underneath.

`build_wfo_checklist` builds the same kind of checklist from World Flora
Online instead (see the section on it below).
=#

const POWO_SEARCH_URL = "https://powo.science.kew.org/api/1/search"
const POWO_TAXON_URL  = "https://powo.science.kew.org/api/2/taxon"

"""
    _fetch_native_range(fqid; sleep_after) -> (names, codes)

Internal: look up a single taxon's native distribution from POWO's taxon
detail endpoint (the search endpoint doesn't carry distribution data, so
this is a separate request per accepted name). Returns a "; "-joined list
of native TDWG area names and a matching "; "-joined list of their TDWG
codes (ex. "Chile Central; Chile South" and "CLC; CLS"), or "" for both if
unavailable/unparseable.
"""
function _fetch_native_range(fqid::AbstractString; sleep_after::Float64)
    isempty(fqid) && return ("", "")

    url = "$(POWO_TAXON_URL)/$(HTTP.escapeuri(fqid))"
    native_range = ""
    native_range_codes = ""
    try
        resp = HTTP.get(url; query = Dict("fields" => "distribution"),
                         retry = true, request_timeout = 30)
        body = JSON3.read(String(resp.body))

        if haskey(body, :distribution) && !isnothing(body.distribution) &&
           haskey(body.distribution, :natives) && !isnothing(body.distribution.natives)
            areas = [(string(get(area, :name, "")), string(get(area, :tdwgCode, ""))) for area in body.distribution.natives]
            filter!(area -> !isempty(first(area)), areas)
            native_range = join(first.(areas), "; ")
            native_range_codes = join(last.(areas), "; ")
        end
    catch e
        @warn "Could not fetch native range for taxon $fqid" exception = e
    end

    sleep(sleep_after)
    return (native_range, native_range_codes)
end

"One name record in the checklist."
struct ChecklistEntry
    name::String            # scientific name (genus + epithet(s))
    author::String          # author abbreviation, "" if none
    rank::String             # e.g. "Species", "Genus", "Form", "Variety"
    family::String
    genus_queried::String     # which genus this record was fetched under (helps when querying multiple genera)
    accepted::Bool           # true = accepted name, false = synonym
    accepted_name::String    # if this is a synonym, the accepted name it points to ("" otherwise)
    accepted_author::String  # author of that accepted name ("" if not a synonym, or if it has none, ex. autonyms)
    ipni_id::String          # IPNI/POWO taxon id, useful for lookups
    native_range::String     # "; "-joined list of native botanical (TDWG) country/area
                              # names, e.g. "China South-Central; China Southeast; Taiwan".
                              # Only populated for accepted names (see `include_distribution`);
                              # "" if not fetched or not available.
    native_range_codes::String # the same areas as their TDWG level-3 codes, e.g. "CHC; CHS; TAI"
end

"""
    _fetch_one(family, genus; page_size, max_results, include_synonyms, sleep_between) -> Vector{ChecklistEntry}

Internal: fetch (and page through) results for a single family/genus combination.
`genus` may be "" to fetch the whole family.
"""
function _fetch_one(family::AbstractString, genus::AbstractString;
                     page_size::Int, max_results::Int,
                     include_synonyms::Bool, sleep_between::Float64)

    query_parts = String["family:$(strip(family))"]
    if !isempty(strip(genus))
        push!(query_parts, "genus:$(strip(genus))")
    end
    query_str = join(query_parts, ",")

    entries = ChecklistEntry[]
    cursor = "*"
    fetched = 0

    while true
        params = Dict(
            "q"       => query_str,
            "perPage" => string(page_size),
            "cursor"  => cursor,
        )

        resp = HTTP.get(POWO_SEARCH_URL; query = params, retry = true, request_timeout = 30)
        body = JSON3.read(String(resp.body))

        results = haskey(body, :results) ? body.results : Any[]
        isempty(results) && break

        for r in results
            accepted = get(r, :accepted, false)
            if !accepted && !include_synonyms
                continue
            end

            name    = string(get(r, :name, ""))
            author  = string(get(r, :author, ""))
            rank    = string(get(r, :rank, ""))
            fam     = string(get(r, :family, ""))
            fqid    = string(get(r, :fqId, ""))

            accepted_name = ""
            accepted_author = ""
            if haskey(r, :synonymOf) && !isnothing(r.synonymOf)
                accepted_name = string(get(r.synonymOf, :name, ""))
                accepted_author = string(get(r.synonymOf, :author, ""))
            end

            push!(entries, ChecklistEntry(name, author, rank, fam, genus, accepted, accepted_name, accepted_author, fqid, "", ""))
        end

        fetched += length(results)
        total = get(body, :totalResults, fetched)

        next_cursor = string(get(body, :cursor, ""))
        if fetched >= total || fetched >= max_results || next_cursor == cursor || isempty(next_cursor)
            break
        end
        cursor = next_cursor

        sleep(sleep_between)
    end

    return entries
end

"""
    build_checklist(family, genus=""; kwargs...) -> DataFrame

Build a checklist for `family` (required) and optionally `genus`.

`genus` can be:
- omitted or `""`                -> whole family
- a single genus name, e.g. `"Quercus"`
- a vector of genus names, e.g. `["Quercus", "Castanea", "Fagus"]`
  (each genus is queried separately against the same family and the
  results are combined and de-duplicated)

Keyword arguments:
- `page_size::Int = 100`      : results requested per page (API max is 500)
- `max_results::Int = 100_000`: safety cap on total records fetched *per genus*
- `include_synonyms::Bool = true` : include synonym names as well as accepted ones
                                     (matches "Detailed Checklist" style completeness;
                                     set to false to mimic filtering to accepted names only)
- `sleep_between::Float64 = 0.15` : seconds to wait between paged requests (politeness)
- `include_distribution::Bool = true` : fetch each accepted name's native botanical
    (TDWG) country/area range from POWO's taxon detail endpoint. This costs one
    extra HTTP request per *unique accepted name*, so it's the slowest part of
    a large checklist -- set to `false` to skip it and get results faster.
    Synonyms are left with `native_range = ""` (their accepted name carries the
    range instead). The matching TDWG level-3 codes go in `native_range_codes`.
- `distribution_sleep::Float64 = 0.1` : seconds to wait between per-taxon
    distribution requests (politeness)
- `output_file::Union{Nothing,AbstractString} = nothing` :
    if given, also write the checklist out to this path.
    - a path ending in `.csv` is written with CSV.jl
    - any other extension (e.g. `.txt`) is written as an aligned plain-text table

Returns a `DataFrame` sorted by (genus_queried, name).
"""
function build_checklist(family::AbstractString,
                          genus::Union{AbstractString,AbstractVector{<:AbstractString}}="";
                          page_size::Int = 100,
                          max_results::Int = 100_000,
                          include_synonyms::Bool = true,
                          sleep_between::Float64 = 0.15,
                          include_distribution::Bool = true,
                          distribution_sleep::Float64 = 0.1,
                          output_file::Union{Nothing,AbstractString} = nothing)

    isempty(strip(family)) && throw(ArgumentError("`family` is required, e.g. build_checklist(\"Fagaceae\", \"Quercus\")"))

    genera = genus isa AbstractString ? [genus] : collect(genus)
    # Normalize: drop blanks/duplicates while preserving order, unless the
    # only entry is "" (whole-family request), which we keep as-is.
    if !(length(genera) == 1 && isempty(strip(genera[1])))
        seen = Set{String}()
        cleaned = String[]
        for g in genera
            gs = strip(g)
            isempty(gs) && continue
            if !(gs in seen)
                push!(seen, gs)
                push!(cleaned, gs)
            end
        end
        isempty(cleaned) && throw(ArgumentError("`genus` was provided but contained no usable genus names"))
        genera = cleaned
    end

    all_entries = ChecklistEntry[]
    seen_keys = Set{Tuple{String,String}}()  # (ipni_id, name) de-dup across genera

    for g in genera
        entries = _fetch_one(family, g;
                              page_size = page_size, max_results = max_results,
                              include_synonyms = include_synonyms, sleep_between = sleep_between)
        for e in entries
            key = (e.ipni_id, e.name)
            if !(key in seen_keys)
                push!(seen_keys, key)
                push!(all_entries, e)
            end
        end
    end

    if include_distribution
        range_cache = Dict{String,Tuple{String,String}}()  # ipni_id -> (native_range, codes), avoids re-fetching
        for (i, e) in enumerate(all_entries)
            e.accepted || continue  # synonyms don't carry their own range
            isempty(e.ipni_id) && continue

            native_range, native_range_codes = get!(range_cache, e.ipni_id) do
                _fetch_native_range(e.ipni_id; sleep_after = distribution_sleep)
            end

            if !isempty(native_range)
                all_entries[i] = ChecklistEntry(e.name, e.author, e.rank, e.family, e.genus_queried,
                                                 e.accepted, e.accepted_name, e.accepted_author, e.ipni_id,
                                                 native_range, native_range_codes)
            end
        end
    end

    sort!(all_entries, by = e -> (e.genus_queried, e.name))

    df = DataFrame(to_table(all_entries))

    if output_file !== nothing
        _write_checklist(df, output_file)
    end

    return df
end

"""
    to_table(entries::Vector{ChecklistEntry})

Convenience: convert checklist entries into a Vector of NamedTuples,
handy for passing straight into DataFrame(...).
"""
function to_table(entries::Vector{ChecklistEntry})
    return [(name = e.name, author = e.author, rank = e.rank, family = e.family,
             genus_queried = e.genus_queried, accepted = e.accepted,
             accepted_name = e.accepted_name, accepted_author = e.accepted_author,
             ipni_id = e.ipni_id,
             native_range = e.native_range, native_range_codes = e.native_range_codes)
            for e in entries]
end

"""
    _write_checklist(df::DataFrame, path::AbstractString)

Internal: write a checklist DataFrame to `path`. `.csv` -> CSV.jl;
anything else -> an aligned plain-text table (one line per name, synonyms
marked with "= <accepted name>").
"""
function _write_checklist(df::DataFrame, path::AbstractString)
    if lowercase(splitext(path)[2]) == ".csv"
        CSV.write(path, df)
    else
        open(path, "w") do io
            namewidth = isempty(df.name) ? 10 : maximum(length("$(r.name) $(r.author)") for r in eachrow(df))
            statuswidth = isempty(df.name) ? 10 :
                maximum(r.accepted ? length("ACCEPTED") : length("= $(r.accepted_name)") for r in eachrow(df))
            for r in eachrow(df)
                status = r.accepted ? "ACCEPTED" : "= $(r.accepted_name)"
                label = "$(r.name) $(r.author)"
                range_str = isempty(r.native_range) ? "" : "  [$(r.native_range)]"
                println(io, rpad(label, namewidth + 2), rpad(status, statuswidth + 2), range_str)
            end
        end
    end
    return path
end


# ─────────────────────────────────────────────────────────────────────────────
# Building a checklist from World Flora Online (WFO)
#
# Builds a plant-name checklist for a given family + genus (or genera), like
# `build_checklist` above, but from the World Flora Online (WFO) Plant List
# instead of WCVP/POWO, using WFO's GraphQL API:
# https://list.worldfloraonline.org/gql.php
#
# WFO stores its names as a taxonomic tree: each accepted taxon (a "taxon
# concept") has its synonyms & unplaced names attached, and its child taxa
# (subgenera, sections, species, infraspecific taxa...) under it. So instead
# of searching by genus like the POWO version does, this finds the genus (or
# family) and walks down the tree from it, using the most recent WFO
# classification.
#
# The result has the same columns as `build_checklist`'s (plus a `wfo_id`
# column), so `checklist_synonyms` & `checklist_homonyms` work on it too.
# WFO doesn't have distribution data, so `native_range` & `native_range_codes`
# are always "" (& `checklist_native_range` will return an empty vector).
#
# A difference from the POWO version: synonyms are the ones that point to a
# taxon in the genus (in any genus), not the names in the genus (that may
# point to a taxon in another genus).
# ─────────────────────────────────────────────────────────────────────────────

const WFO_GQL_URL = "https://list.worldfloraonline.org/gql.php"

# no paging count is given for unplaced names, so just ask for lots
const _WFO_MAX_UNPLACED = 100_000

const _WFO_NAME_FIELDS = "id fullNameStringNoAuthorsPlain authorsString rank role identifiersOther { kind value }"
const _WFO_CONCEPT_FIELDS = """
    id partsCount
    hasName { $_WFO_NAME_FIELDS }
    hasSynonym { $_WFO_NAME_FIELDS }
    hasUnplacedName(limit: $_WFO_MAX_UNPLACED) { $_WFO_NAME_FIELDS }
    """

# The WFO server doesn't send the intermediate certificate its TLS certificate
# is signed with (browsers & curl fetch it themselves, Julia's HTTP doesn't), so
# its certificate can't be verified with the usual root certificates alone.
# This is that intermediate (GeoTrust TLS RSA CA G1, signed by DigiCert Global
# Root G2, expires 2027-11-02), from
# http://cacerts.geotrust.com/GeoTrustTLSRSACAG1.crt
const _WFO_INTERMEDIATE_CERT = """
-----BEGIN CERTIFICATE-----
MIIEjTCCA3WgAwIBAgIQDQd4KhM/xvmlcpbhMf/ReTANBgkqhkiG9w0BAQsFADBh
MQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3
d3cuZGlnaWNlcnQuY29tMSAwHgYDVQQDExdEaWdpQ2VydCBHbG9iYWwgUm9vdCBH
MjAeFw0xNzExMDIxMjIzMzdaFw0yNzExMDIxMjIzMzdaMGAxCzAJBgNVBAYTAlVT
MRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5j
b20xHzAdBgNVBAMTFkdlb1RydXN0IFRMUyBSU0EgQ0EgRzEwggEiMA0GCSqGSIb3
DQEBAQUAA4IBDwAwggEKAoIBAQC+F+jsvikKy/65LWEx/TMkCDIuWegh1Ngwvm4Q
yISgP7oU5d79eoySG3vOhC3w/3jEMuipoH1fBtp7m0tTpsYbAhch4XA7rfuD6whU
gajeErLVxoiWMPkC/DnUvbgi74BJmdBiuGHQSd7LwsuXpTEGG9fYXcbTVN5SATYq
DfbexbYxTMwVJWoVb6lrBEgM3gBBqiiAiy800xu1Nq07JdCIQkBsNpFtZbIZhsDS
fzlGWP4wEmBQ3O67c+ZXkFr2DcrXBEtHam80Gp2SNhou2U5U7UesDL/xgLK6/0d7
6TnEVMSUVJkZ8VeZr+IUIlvoLrtjLbqugb0T3OYXW+CQU0kBAgMBAAGjggFAMIIB
PDAdBgNVHQ4EFgQUlE/UXYvkpOKmgP792PkA76O+AlcwHwYDVR0jBBgwFoAUTiJU
IBiV5uNu5g/6+rkS7QYXjzkwDgYDVR0PAQH/BAQDAgGGMB0GA1UdJQQWMBQGCCsG
AQUFBwMBBggrBgEFBQcDAjASBgNVHRMBAf8ECDAGAQH/AgEAMDQGCCsGAQUFBwEB
BCgwJjAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEIGA1Ud
HwQ7MDkwN6A1oDOGMWh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydEds
b2JhbFJvb3RHMi5jcmwwPQYDVR0gBDYwNDAyBgRVHSAAMCowKAYIKwYBBQUHAgEW
HGh0dHBzOi8vd3d3LmRpZ2ljZXJ0LmNvbS9DUFMwDQYJKoZIhvcNAQELBQADggEB
AIIcBDqC6cWpyGUSXAjjAcYwsK4iiGF7KweG97i1RJz1kwZhRoo6orU1JtBYnjzB
c4+/sXmnHJk3mlPyL1xuIAt9sMeC7+vreRIF5wFBC0MCN5sbHwhNN1JzKbifNeP5
ozpZdQFmkCo+neBiKR6HqIA+LMTMCMMuv2khGGuPHmtDze4GmEGZtYLyF8EQpa5Y
jPuV6k2Cr/N3XxFpT3hRpt/3usU/Zb9wfKPtWpoznZ4/44c1p9rzFcZYrWkj3A+7
TNBJE0GmP2fhXhP1D/XVfIW/h0yCJGEiV9Glm/uGOa3DXHlmbAcxSyCRraG+ZBkA
7h4SeM6Y8l/7MBRpPCz6l8Y=
-----END CERTIFICATE-----
"""

const _WFO_CLIENT = Ref{Union{Nothing,HTTP.Client}}(nothing)

"""
    _wfo_client() -> HTTP.Client

Internal: an HTTP client that verifies the WFO server's certificate against
the usual root certificates plus `_WFO_INTERMEDIATE_CERT`. It's built the
first time it's needed.
"""
function _wfo_client()
    if isnothing(_WFO_CLIENT[])
        ca_bundle = tempname() * ".pem"
        write(ca_bundle, read(NetworkOptions.ca_roots_path(), String) * "\n" * _WFO_INTERMEDIATE_CERT)
        tls_config = HTTP.TLS.Config(ca_file = ca_bundle)
        _WFO_CLIENT[] = HTTP.Client(transport = HTTP.Transport(tls_config = tls_config))
    end
    return _WFO_CLIENT[]
end

"""
    _wfo_query(query; variables) -> JSON3.Object

Internal: run a GraphQL `query` against the WFO Plant List API & return its
`data`. Throws if the API returns errors.
"""
function _wfo_query(query::AbstractString; variables = Dict{String,Any}())
    resp = HTTP.post(WFO_GQL_URL, ["Content-Type" => "application/json"],
                     JSON3.write(Dict("query" => query, "variables" => variables));
                     client = _wfo_client(), retry = true, request_timeout = 120)
    body = JSON3.read(String(resp.body))
    if haskey(body, :errors) && !isempty(body.errors)
        error("WFO API error: " * join([string(get(e, :message, e)) for e in body.errors], "; "))
    end
    return body.data
end

_wfo_str(x) = isnothing(x) ? "" : string(x)
_wfo_list(x) = isnothing(x) ? Any[] : x

"""
    _wfo_resolve(name, rank, family) -> String

Internal: find the id of the accepted WFO taxon concept for `name` at `rank`
("family" or "genus"). For a genus, the one in `family` is picked (genus names
can be homonyms across families).
"""
function _wfo_resolve(name::AbstractString, rank::AbstractString, family::AbstractString)
    namefields = "id fullNameStringNoAuthorsPlain rank role currentPreferredUsage { id pathString }"
    data = _wfo_query("""
        query(\$name: String) {
            taxonNameMatch(inputString: \$name, checkRank: false) {
                match { $namefields }
                candidates { $namefields }
            }
        }""";
        variables = Dict("name" => name))

    result = data.taxonNameMatch
    names = filter(!isnothing, [result.match; _wfo_list(result.candidates)])
    usages = String[]
    for n in names
        _wfo_str(n.fullNameStringNoAuthorsPlain) == name || continue
        lowercase(_wfo_str(n.rank)) == rank || continue
        usage = n.currentPreferredUsage
        isnothing(usage) && continue
        # the path runs from the root of the tree down to this taxon, ex.
        # "Code/Plantae/Pteridobiotina/Angiosperms/Fagales/Fagaceae/Quercus"
        family in split(_wfo_str(usage.pathString), "/") || continue
        push!(usages, string(usage.id))
    end
    unique!(usages)

    isempty(usages) && error("Couldn't find an accepted $rank \"$name\" in $family on WFO " *
                             "(it may be a synonym, or placed in another family there)")
    length(usages) > 1 && error("Found more than one accepted $rank \"$name\" in $family on WFO: " *
                                join(usages, ", "))
    return only(usages)
end

"""
    _wfo_add_concept!(rows, concept, ctx; include_synonyms, include_unplaced)

Internal: add a WFO taxon concept's accepted name, and (optionally) its
synonyms & unplaced names, to `rows`.
"""
function _wfo_add_concept!(rows, concept, ctx; include_synonyms::Bool, include_unplaced::Bool)
    accepted = concept.hasName
    accepted_name = _wfo_str(accepted.fullNameStringNoAuthorsPlain)
    accepted_author = _wfo_str(accepted.authorsString)
    push!(rows, _wfo_row(accepted, ctx; accepted = true))

    if include_synonyms
        for syn in _wfo_list(concept.hasSynonym)
            push!(rows, _wfo_row(syn, ctx; accepted = false,
                                 accepted_name = accepted_name, accepted_author = accepted_author))
        end
    end
    if include_unplaced
        for name in _wfo_list(concept.hasUnplacedName)
            _wfo_str(name.role) == "unplaced" || continue
            push!(rows, _wfo_row(name, ctx; accepted = false))
        end
    end
    return rows
end

"Internal: one checklist row (with the same columns as `to_table`, plus `wfo_id`) for a WFO name."
function _wfo_row(name, ctx; accepted::Bool, accepted_name::String = "", accepted_author::String = "")
    ipni_ids = [_wfo_str(i.value) for i in _wfo_list(name.identifiersOther) if _wfo_str(i.kind) == "ipni"]
    return (name = _wfo_str(name.fullNameStringNoAuthorsPlain),
            author = _wfo_str(name.authorsString),
            rank = uppercasefirst(_wfo_str(name.rank)),
            family = ctx.family,
            genus_queried = ctx.genus,
            accepted = accepted,
            accepted_name = accepted_name,
            accepted_author = accepted_author,
            wfo_id = _wfo_str(name.id),
            ipni_id = isempty(ipni_ids) ? "" : first(ipni_ids),
            native_range = "",
            native_range_codes = "")
end

"""
    _wfo_walk!(rows, concept_id, ctx; nest, page_size, sleep_between, kwargs...)

Internal: add all the taxa below a WFO taxon concept to `rows`, paging
through its children. With `nest=true`, each child's own children come back in
the same request (fast for a genus; too big a response for a family), and only
taxa deeper than that need requests of their own.
"""
function _wfo_walk!(rows, concept_id::AbstractString, ctx;
                    nest::Bool, page_size::Int, sleep_between::Float64, kwargs...)
    nested = nest ? "hasPart(limit: \$limit) { $_WFO_CONCEPT_FIELDS }" : ""
    query = """
        query(\$id: String, \$offset: Int, \$limit: Int) {
            taxonConceptById(taxonId: \$id) {
                partsCount
                hasPart(offset: \$offset, limit: \$limit) { $_WFO_CONCEPT_FIELDS $nested }
            }
        }"""

    offset = 0
    while true
        data = _wfo_query(query; variables = Dict("id" => concept_id, "offset" => offset, "limit" => page_size))
        concept = data.taxonConceptById
        isnothing(concept) && error("WFO taxon concept $concept_id not found")
        children = _wfo_list(concept.hasPart)
        sleep(sleep_between)

        for child in children
            _wfo_add_concept!(rows, child, ctx; kwargs...)
            child.partsCount > 0 || continue
            grandchildren = nest ? _wfo_list(child.hasPart) : Any[]

            if length(grandchildren) < child.partsCount
                # didn't get all its children in this request: fetch them separately
                _wfo_walk!(rows, string(child.id), ctx; nest = true, page_size, sleep_between, kwargs...)
                continue
            end
            for grandchild in grandchildren
                _wfo_add_concept!(rows, grandchild, ctx; kwargs...)
                if grandchild.partsCount > 0
                    _wfo_walk!(rows, string(grandchild.id), ctx; nest = true, page_size, sleep_between, kwargs...)
                end
            end
        end

        offset += length(children)
        (isempty(children) || offset >= concept.partsCount) && break
    end
    return rows
end

"""
    build_wfo_checklist(family, genus=""; kwargs...) -> DataFrame

Build a checklist for `family` (required) and optionally `genus`, from the
World Flora Online (WFO) Plant List — the WFO version of [`build_checklist`](@ref).

`genus` can be:
- omitted or `""`                -> whole family
- a single genus name, e.g. `"Quercus"`
- a vector of genus names, e.g. `["Quercus", "Castanea", "Fagus"]`
  (each genus is fetched separately and the results are combined and
  de-duplicated)

The family & genera have to be accepted in WFO's current classification.
Everything below them is included: intermediate ranks (subgenera,
sections...), species & infraspecific taxa.

Keyword arguments:
- `include_synonyms::Bool = true` : include the synonyms of each accepted name
- `include_unplaced::Bool = true` : include names WFO hasn't placed as either
    accepted or a synonym (as `accepted = false`, with no `accepted_name`)
- `page_size::Int = 1000`         : child taxa requested per page
- `sleep_between::Float64 = 0.15` : seconds to wait between requests (politeness)
- `output_file::Union{Nothing,AbstractString} = nothing` :
    if given, also write the checklist out to this path (`.csv`, or any other
    extension for an aligned plain-text table)

Returns a `DataFrame` sorted by (genus_queried, name), with the same columns as
`build_checklist`'s plus `wfo_id`. `ipni_id` is the name's (first) IPNI id,
where WFO has one. WFO has no distribution data, so `native_range` &
`native_range_codes` are always `""`.

Note that the synonyms are the ones that point to a taxon in the genus (from
any genus), which is what `checklist_synonyms` needs; names in the genus that
are synonyms of taxa in other genera aren't included.
"""
function build_wfo_checklist(family::AbstractString,
                             genus::Union{AbstractString,AbstractVector{<:AbstractString}} = "";
                             include_synonyms::Bool = true,
                             include_unplaced::Bool = true,
                             page_size::Int = 1000,
                             sleep_between::Float64 = 0.15,
                             output_file::Union{Nothing,AbstractString} = nothing)

    family = strip(family)
    isempty(family) && throw(ArgumentError("`family` is required, e.g. build_wfo_checklist(\"Fagaceae\", \"Quercus\")"))

    genera = genus isa AbstractString ? [genus] : collect(genus)
    genera = unique(String.(strip.(genera)))
    if genera != [""]
        filter!(!isempty, genera)
        isempty(genera) && throw(ArgumentError("`genus` was provided but contained no usable genus names"))
    end

    all_rows = NamedTuple[]
    seen_keys = Set{Tuple{String,String}}()  # (wfo_id, accepted_name) de-dup across genera

    for g in genera
        whole_family = isempty(g)
        root_id = whole_family ? _wfo_resolve(family, "family", family) : _wfo_resolve(g, "genus", family)
        ctx = (family = String(family), genus = g)

        rows = NamedTuple[]
        root = _wfo_query("query(\$id: String) { taxonConceptById(taxonId: \$id) { $_WFO_CONCEPT_FIELDS } }";
                          variables = Dict("id" => root_id)).taxonConceptById
        _wfo_add_concept!(rows, root, ctx; include_synonyms, include_unplaced)
        # a family's children (genera) are each walked with their own requests
        _wfo_walk!(rows, root_id, ctx; nest = !whole_family, page_size, sleep_between,
                   include_synonyms, include_unplaced)

        for r in rows
            key = (r.wfo_id, r.accepted_name)
            if !(key in seen_keys)
                push!(seen_keys, key)
                push!(all_rows, r)
            end
        end
    end

    sort!(all_rows, by = r -> (r.genus_queried, r.name))
    df = DataFrame(all_rows)

    if output_file !== nothing
        _write_checklist(df, output_file)
    end

    return df
end


# ─────────────────────────────────────────────────────────────────────────────
# Working with a checklist: synonyms, native ranges & homonyms
#
# These take the DataFrame returned by `build_checklist` (or the CSV it wrote,
# read back in — blank fields can be "" or `missing`).
# ─────────────────────────────────────────────────────────────────────────────

_blank(x) = ismissing(x) || isempty(x)
_or_missing(x) = _blank(x) ? missing : String(x)

# is `name` this taxon — or, if `include_infraspecific`, one of its infraspecific taxa?
_is_taxon(name, taxon, include_infraspecific) =
    !_blank(name) && (name == taxon || (include_infraspecific && startswith(name, taxon * " ")))

"""
    checklist_synonyms(checklist, taxon; include_infraspecific=false) -> Vector{Tuple{String, Union{String, Missing}}}

All the names for an accepted `taxon`, as `(name, author)` tuples: the accepted
name itself first, then every synonym that points to it (at any rank, in any
genus). The author is `missing` if the checklist has none (ex. autonyms).

With `include_infraspecific=true`, a species also gets the accepted names &
synonyms of all of its infraspecific taxa — useful for pulling occurrences at
the species level.

Returns an empty vector if `taxon` isn't an accepted name in the checklist.
"""
function checklist_synonyms(checklist::AbstractDataFrame, taxon::AbstractString; include_infraspecific::Bool=false)
    syns = Tuple{String, Union{String, Missing}}[]

    for row in eachrow(checklist)
        row.accepted && _is_taxon(row.name, taxon, include_infraspecific) || continue
        push!(syns, (row.name, _or_missing(row.author)))
    end
    isempty(syns) && return syns
    # the taxon itself goes first (it's used as the accepted name downstream)
    sort!(syns, by = syn -> first(syn) != taxon)

    for row in eachrow(checklist)
        !row.accepted && _is_taxon(row.accepted_name, taxon, include_infraspecific) || continue
        push!(syns, (row.name, _or_missing(row.author)))
    end

    return unique(syns)
end

"""
    checklist_native_range(checklist, taxon; include_infraspecific=false) -> Vector{String}

The native range of an accepted `taxon`, as sorted TDWG level-3 botanical
country codes (ex. `["CLC", "CLS"]`). Needs a checklist built with
`include_distribution=true`.

With `include_infraspecific=true`, the ranges of the species' accepted
infraspecific taxa are pooled in.
"""
function checklist_native_range(checklist::AbstractDataFrame, taxon::AbstractString; include_infraspecific::Bool=false)
    codes = String[]
    for row in eachrow(checklist)
        row.accepted && _is_taxon(row.name, taxon, include_infraspecific) || continue
        _blank(row.native_range_codes) && continue
        append!(codes, strip.(split(row.native_range_codes, ";")))
    end
    return sort(unique(filter(!isempty, codes)))
end

"""
    checklist_homonyms(checklist) -> DataFrame

Find the homonyms in a checklist: names that are used for more than one taxon,
under different authors. That's either a name that's both an accepted name &
a synonym of something else, or a name that's a synonym of two different
accepted taxa.

Occurrence records filed under a homonym can only be assigned to the right
taxon by their author (see `find_homonyms_to_exclude` in `datacleaning.jl`).

Returns one row per use of each homonym, with the columns:
- `scientificName`: the shared name
- `genus`, `specificEpithet`
- `accepted`: is this use of the name an accepted name?
- `authority`: the author of this use of the name
- `validName`: the accepted name it's a synonym of (`missing` if `accepted`,
  or if the name is unplaced)
- `synonymAuthority`: the author of `validName`
"""
function checklist_homonyms(checklist::AbstractDataFrame)
    homonyms = DataFrame(
        scientificName = String[],
        genus = String[],
        specificEpithet = String[],
        accepted = Bool[],
        authority = String[],
        validName = Union{String, Missing}[],
        synonymAuthority = Union{String, Missing}[]
    )

    accepted_authors = Dict(row.name => _or_missing(row.author) for row in eachrow(checklist) if row.accepted)

    for group in groupby(checklist, :name)
        name_parts = split(group.name[1], " ")
        length(name_parts) < 2 && continue  # genus & family records

        # the taxon each use of the name belongs to
        taxa = [row.accepted ? row.name : coalesce(row.accepted_name, "") for row in eachrow(group)]
        length(unique(taxa)) > 1 || continue

        for (row, taxon) in zip(eachrow(group), taxa)
            valid_name = row.accepted ? missing : _or_missing(taxon)
            valid_author = ismissing(valid_name) ? missing : get(accepted_authors, valid_name, missing)
            push!(homonyms, (row.name, name_parts[1], name_parts[2], row.accepted,
                             coalesce(row.author, ""), valid_name, valid_author))
        end
    end

    return sort!(homonyms, [:scientificName, order(:accepted, rev=true), :authority])
end

# --- Example usage ---
# using PlantOccurrences
#
# # single genus, get a DataFrame:
# df = build_checklist("Fagaceae", "Quercus")
#
# # whole family, no genus filter:
# df = build_checklist("Nepenthaceae")
#
# # accepted names only (skip synonyms):
# df = build_checklist("Fagaceae", "Quercus"; include_synonyms=false)
#
# # multiple genera from the same family, combined into one checklist:
# df = build_checklist("Fagaceae", ["Quercus", "Castanea", "Fagus"])
#
# # write results out while you're at it:
# df = build_checklist("Fagaceae", ["Quercus", "Castanea"]; output_file="fagaceae_checklist.csv")
# df = build_checklist("Fagaceae", ["Quercus", "Castanea"]; output_file="fagaceae_checklist.txt")
#
# # df.native_range now holds each accepted name's native TDWG country/area range,
# # e.g. "China South-Central; China Southeast; Taiwan"
#
# # ...and df.native_range_codes holds the same areas as TDWG codes, e.g. "CHC; CHS; TAI"
#
# # skip the (slower) per-taxon distribution lookups if you don't need ranges:
# df = build_checklist("Fagaceae", "Quercus"; include_distribution=false)
#
# # all the names for an accepted taxon, as (name, author) tuples:
# checklist_synonyms(df, "Quercus alba")
#
# # its native range, as TDWG codes:
# checklist_native_range(df, "Quercus alba")
#
# # names used for more than one taxon, under different authors:
# checklist_homonyms(df)
#
# # the same kind of checklist from World Flora Online (no native ranges):
# df = build_wfo_checklist("Pteridaceae", "Pentagramma")
# df = build_wfo_checklist("Pteridaceae", "Pentagramma"; output_file="pentagramma_wfo_checklist.csv")
#
# # accepted names only:
# df = build_wfo_checklist("Pteridaceae", "Pentagramma"; include_synonyms=false, include_unplaced=false)
#
# # and the same helpers work on it:
# checklist_synonyms(df, "Pentagramma triangularis"; include_infraspecific=true)
# checklist_homonyms(df)
