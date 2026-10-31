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
                tfim = (; L=16, J=1.0, model="TFIM")   # structured params: one value per axis
                m = (; x=[0.1, 0.2, 0.3], y=[0.99, 0.8, 0.55])
                @figure nothing data = m caption = "magnetization" id = :mag params = tfim
                @figure nothing data = (;
                    xlabel="T",
                    ylabel="E",
                    series=[
                        (; label="up", x=[1.0, 2.0, 3.0], y=[-1.0, -0.5, -0.25]),
                        (; label="down", x=[1.0, 2.0, 3.0], y=[-0.9, -0.6, -0.3]),
                    ],
                ) caption = "two sweeps" id = :sweeps
                @table (; N=[8, 16], Tc=[2.1, 2.2]) caption = "critical temperatures" id =
                    :tc
                @code E = 1.0 + 1.0 / 8 caption = "the energy"
                @section :s1 "Section One" begin
                    @desc md"A section description."
                    @test isapprox(1.0001, 1.0; rtol=1e-3)
                    @section :s2 "Section Two" begin
                        @test isapprox(0.5, 0.0; atol=1e-3)
                    end
                end
                @section :s3 "Section Three" begin
                    @test 1 + 1 == 2   # an indicator: no numbers to record
                end
                @section :s4 "Section Four" begin
                    @test error("boom")   # an error: the assertion threw
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
    # a comment on every kind that carries one (a figure, a section, a table, a page), as the comment
    # store holds them
    write(
        joinpath(out, "comments.toml"),
        """
        [[comment.mag]]
        author = "llm"
        text = "The drop near 0.3 is the finite-size crossover."

        [[comment.s1]]
        author = "sensei"
        text = "Tighten the tolerance."

        [[comment.tc]]
        author = "me"
        text = "ON_TABLE"

        [[comment.p2]]
        author = "me"
        text = "ON_PAGE"
        """,
    )
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
    # Every entry of each registry the emitter writes from is in the fixture, so a kind, a check
    # kind or an outcome added to Pinax cannot be missing from what pinax-mcp is tested against.
    for k in keys(Pinax._CONTENT_FIELDS)
        @test occursin("\"kind\":\"$(k)\"", emitted)   # in a container's content order
    end
    for k in Pinax._CHECK_KINDS
        @test occursin("\"kind\":\"$(k)\",\"outcome\":", emitted)
    end
    for o in Pinax._CHECK_OUTCOMES
        @test occursin("\"outcome\":\"$(o)\"", emitted)
    end
    # a comment on a table sits on that table, and one on a page after that page's content
    @test occursin(
        r"\"id\":\"tc\"[^}]*\"comments\":\[\{\"author\":\"me\",\"text\":\"ON_TABLE\"",
        emitted,
    )
    @test occursin(
        r"\"content\":\[[^\]]*\"p2_raw_[^\]]*\],\"comments\":\[\{\"author\":\"me\",\"text\":\"ON_PAGE\"",
        emitted,
    )
    # The fixture holds what the contract promises pinax-mcp: both verdicts, a verdict-less page, a
    # status, a @raw block, a diagnostic, comments on a figure and a section, structured params, a
    # two-series data file, an indicator check and an error check.
    for token in (
        "\"status\":\"draft\"",
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
        "\"comments\":[{\"author\":\"llm\",\"text\":\"The drop",       # on a figure
        "\"comments\":[{\"author\":\"sensei\",\"text\":\"Tighten",     # on a section
        "\"params\":{\"L\":16,\"J\":1.0,\"model\":\"TFIM\"}",
        "\"series\":[{\"label\":\"up\",\"points\":3},{\"label\":\"down\",\"points\":3}]",
        "\"got\":null,\"want\":null,\"delta\":null,\"tol\":null,\"kind\":\"indicator\",\"outcome\":\"pass\"",
        "\"kind\":\"indicator\",\"outcome\":\"error\",\"pass\":false",
        "\"kind\":\"rel\",\"outcome\":\"pass\",\"pass\":true",
        "\"kind\":\"abs\",\"outcome\":\"fail\",\"pass\":false",
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

# Which kinds carry a comment or a bookmark is decided once in Pinax and refused by pinax-mcp's write
# tools by the same sets: read the literals out of its source, so the decision cannot drift across the
# language boundary unnoticed.
@testset "pinax-mcp refuses comments and bookmarks by Pinax's carrier sets" begin
    server = read(
        normpath(joinpath(@__DIR__, "..", "clients", "pinax-mcp", "src", "server.ts")),
        String,
    )
    function carriers(name)
        m = match(Regex("const $(name) = new Set\\(\\[([^\\]]*)\\]\\)"), server)
        m === nothing && error("server.ts has no `const $(name) = new Set([...])` literal")
        return Set(Symbol(x[1]) for x in eachmatch(r"\"([a-z]+)\"", m[1]))
    end
    @test carriers("COMMENT_CARRIERS") == Set(Pinax._COMMENT_CARRIERS)
    @test carriers("BOOKMARK_CARRIERS") == Set(Pinax._BOOKMARK_CARRIERS)
end
