using Pinax
using Test

# The agent.json contract (#169). The fixture pinax-mcp tests against is GENERATED here, from the
# emitter, so the two sides cannot drift: this file builds one document holding every node kind,
# renders the agent face, and compares it byte for byte with the committed fixture. pinax-mcp then
# checks that same file against its schema, including that the schema names every key it holds.
#
# After an intended change to the emitter (or to this file — check sources carry line numbers):
#
#     PINAX_REGEN_CONTRACT=1 julia --project -e 'using Pkg; Pkg.test()'
#
# and commit the fixture together with the matching `clients/pinax-mcp/src/schema.ts` change.

const _CONTRACT_DIR = normpath(
    joinpath(@__DIR__, "..", "clients", "pinax-mcp", "test", "fixtures", "emitted")
)

# A deliberately failing check is absorbed here, so this file's suite does not count it.
mutable struct _ContractIso <: Test.AbstractTestSet
    description::String
    results::Vector{Any}
    _ContractIso(desc::AbstractString=""; kw...) = new(String(desc), Any[])
end
Test.record(r::_ContractIso, x) = (push!(r.results, x); x)
Test.finish(r::_ContractIso) = r

function _contract_document!()
    Pinax.reset!(; title="Contract")
    @testset _ContractIso "contract" begin
        @part :grp "Group" begin
            @page :p1 "Page One" status = :draft summary = "every node kind" begin
                @desc md"A page description with math, $E = -J \sum_i s_i s_{i+1}$."
                @figure nothing data = (; x=[0.1, 0.2, 0.3], y=[0.99, 0.8, 0.55]) caption = "magnetization"
                @table (; N=[8, 16], Tc=[2.1, 2.2]) caption = "critical temperatures"
                @code E = 1.0 + 1.0 / 8 caption = "the energy"
                @section :s1 "Section One" begin
                    @desc md"A section description."
                    @test isapprox(1.0001, 1.0; rtol=1e-3)
                    @section :s2 "Section Two" begin
                        @test isapprox(0.5, 0.0; atol=1e-3)
                    end
                end
                @section :s3 "Section Three" begin
                    @test 1 + 1 == 2
                end
            end
        end
        @page :p2 "Page Two" begin
            @table [(model="TFIM", gap=1.0), (model="XXZ", gap=0.0)] caption = "rows of named tuples"
            @raw "<b>verbatim HTML</b>"   # carried as its HTML, under a generated id
            @figure error("no plotting backend") caption = "broken"   # a `diagnostics` entry
        end
    end
    return Pinax.current_document()
end

@testset "agent.json contract fixture (#169)" begin
    _contract_document!()
    out = mktempdir()
    Pinax.render(; out=out, theme=:agent)
    emitted = read(joinpath(out, "agent.json"), String)
    fixture = joinpath(_CONTRACT_DIR, "agent.json")
    if get(ENV, "PINAX_REGEN_CONTRACT", "") == "1"
        mkpath(_CONTRACT_DIR)
        write(fixture, emitted)
        @info "regenerated the agent.json contract fixture" fixture
    end
    @test isfile(fixture)
    # Drift is a failure, never a silent rewrite: regenerate on purpose (see the top of this file).
    @test emitted == read(fixture, String)
    # The fixture holds what the contract promises pinax-mcp: every node kind, both verdicts, a
    # verdict-less page, a status, a @raw block and a diagnostic.
    for token in (
        "\"status\":\"draft\"",
        "\"kind\":\"figure\"",
        "\"kind\":\"table\"",
        "\"kind\":\"code\"",
        "\"kind\":\"check\"",
        "\"kind\":\"section\"",
        "\"caption\":\"the energy\"",
        "\"verdict\":\"PASS\"",
        "\"verdict\":\"FAIL\"",
        "\"verdict\":null",
        "\"depth\":3",
        "\"depth\":1",                      # a page carries depth like a section
        "\"summary\":\"\"",                  # text the author did not write is the empty string
        "\"code_id\":\"",                    # a check points at its code block by id
        "\"defined_at\":\"test/test_contract.jl:",   # where a node was written, from the project root
        "\"data\":{\"path\":\"assets/figures/p1/",       # a figure's data file, described not inlined
        "\"kind\":\"raw\"",
        "\"raws\":[{\"id\":\"p2_raw_",
        "\"diagnostics\":[{\"severity\":\"ERROR\",\"item\":\"p2_fig_",
    )
        @test occursin(token, emitted)
    end
    # one naming scheme: no anchor beside the id, and no null standing in for unwritten text
    for token in (
        "\"anchor\":",
        "\"code_anchor\":",
        "\"summary\":null",
        "\"desc\":null",
        "\"table\":{",
    )
        @test !occursin(token, emitted)
    end
end
