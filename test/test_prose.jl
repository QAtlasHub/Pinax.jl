using Pinax
using Test

# Prose (Conventions › Content). `@desc` is a prose block placed in content order like any other node:
# a container holds any number of them, interleaved with figures, tables and code, and every face
# shows them where they were written. A node has at most one caption.

mutable struct _ProseIso <: Test.AbstractTestSet
    description::String
    results::Vector{Any}
    _ProseIso(desc::AbstractString=""; kw...) = new(String(desc), Any[])
end
Test.record(r::_ProseIso, x) = (push!(r.results, x); x)
Test.finish(r::_ProseIso) = r

_pos(s, needle) = first(findfirst(needle, s))

@testset "prose blocks" begin
    tmp = mktempdir()
    svg = joinpath(tmp, "f.svg")
    write(svg, "<svg xmlns='http://www.w3.org/2000/svg'><rect/></svg>")

    function interleaved!()
        Pinax.reset!(; title="T")
        @page :p "P" begin
            @section :s "S" begin
                @desc md"PROSE_ONE with $$ a = 1 $$"
                @figure svg
                @caption "FIG_CAP"
                @desc md"PROSE_TWO with $$ b = 2 $$"
            end
        end
    end

    @testset "any number of prose blocks, each with a generated id, in content order" begin
        interleaved!()
        sec = Pinax.current_document().pages[1].sections[1]
        @test length(sec.texts) == 2
        @test [k for (k, _) in sec.content] == [:text, :figure, :text]
        @test all(t -> startswith(string(t.id), "s_txt_"), sec.texts)
        @test sec.texts[1].id != sec.texts[2].id
    end

    @testset "every face shows prose where it was written" begin
        interleaved!()
        g = read(Pinax.render(; out=joinpath(tmp, "g")), String)
        @test _pos(g, "PROSE_ONE") < _pos(g, "FIG_CAP") < _pos(g, "PROSE_TWO")
        # display equations are numbered in reading order: the first prose block's comes first
        @test _pos(g, "PROSE_ONE") <
            _pos(g, "\\tag{1}") <
            _pos(g, "PROSE_TWO") <
            _pos(g, "\\tag{2}")

        lx = read(Pinax.render(; out=joinpath(tmp, "l"), theme=:latex), String)
        @test _pos(lx, "PROSE\\_ONE") < _pos(lx, "FIG\\_CAP") < _pos(lx, "PROSE\\_TWO")

        Pinax.render(; out=joinpath(tmp, "a"), theme=:agent)
        md = read(joinpath(tmp, "a", "agent.md"), String)
        @test _pos(md, "PROSE_ONE") < _pos(md, "FIG_CAP") < _pos(md, "PROSE_TWO")
        aj = read(joinpath(tmp, "a", "agent.json"), String)
        t1, t2 = (string(t.id) for t in Pinax.current_document().pages[1].sections[1].texts)
        @test occursin("\"texts\":[{\"id\":\"$(t1)\",\"text\":\"PROSE_ONE", aj)
        @test occursin("{\"kind\":\"text\",\"id\":\"$(t1)\"},{\"kind\":\"figure\"", aj)
        @test occursin("{\"kind\":\"text\",\"id\":\"$(t2)\"}]", aj)
    end

    @testset "the same text twice in one container gets -2" begin
        Pinax.reset!()
        @page :p "P" begin
            @desc "same"
            @desc "same"
        end
        a, b = (t.id for t in Pinax.current_document().pages[1].texts)
        @test string(b) == string(a, "-2")
    end

    @testset "prose carries no caption" begin
        Pinax.reset!()
        @test_throws "carries no caption" @page :p "P" begin
            @desc "words"
            @caption "a caption for words"
        end
    end

    @testset "a node has at most one caption" begin
        Pinax.reset!()
        @test_throws "already has a caption" @page :p "P" begin
            @figure 1 caption = "given"
            @caption "again"
        end
        Pinax.reset!()
        @test_throws "already has a caption" @page :p "P" begin
            @table (a=[1],)
            @caption "one"
            @caption "two"
        end
        Pinax.reset!()
        err = nothing
        @testset _ProseIso "iso" begin   # a second @caption on a check (its label)
            @page :p "P" begin
                @test true
                @caption "named"
                err = try
                    Pinax._set_caption!("renamed")
                    nothing
                catch e
                    e
                end
            end
        end
        @test err isa ErrorException && occursin("already has a caption", err.msg)
    end

    @testset "prose in a captured test rides a shard dump and renders" begin
        n = Pinax.TestNode("test_x.jl")
        push!(n.texts, Pinax.Prose(:t1, "t1", "DUMPED_PROSE"))
        push!(n.content, :text => 1)
        d = Pinax.dump_test_report(
            Pinax.TestNode("r"; children=[n]), joinpath(tmp, "s.toml")
        )
        back = only(Pinax.load_test_dump(d).children)
        @test only(back.texts).source == "DUMPED_PROSE"
        @test back.content == [:text => 1]
        Pinax.render_test_report(
            Pinax.TestNode("T"; children=[back]); out=joinpath(tmp, "rep")
        )
        @test occursin(
            "DUMPED_PROSE", read(joinpath(tmp, "rep", "html", "test_x_jl.html"), String)
        )
    end
end
