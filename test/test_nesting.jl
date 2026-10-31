using Pinax
using Test
using JSON

# `@section` nests to any depth (#170, #173). Depth counts from the part: a page is 1, a top-level
# section 2, its child 3, and so on. Each backend maps depth to a heading in one place, and a depth
# beyond its native levels is rendered in one fixed fallback form with a diagnostic — never flattened.

# A chain of `n` sections, each nested in the previous one, with one figure per level, written out
# explicitly so the test shows the authoring form a reader would write.
function _chain!(svg)
    @page :p "P" begin
        @section :s2 "S2" begin
            @figure svg
            @section :s3 "S3" begin
                @figure svg
                @section :s4 "S4" begin
                    @figure svg
                    @section :s5 "S5" begin
                        @figure svg
                        @section :s6 "S6" begin
                            @figure svg
                            @section :s7 "S7" begin
                                @figure svg
                            end
                        end
                    end
                end
            end
        end
    end
end

@testset "nested @section" begin
    tmp = mktempdir()
    svg = joinpath(tmp, "a.svg")
    write(svg, "<svg xmlns='http://www.w3.org/2000/svg'><rect/></svg>")

    @testset "content after an inner section stays in the outer one" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :a "A" begin
                @section :b "B" begin
                    @figure svg id = :inner
                end
                @figure svg id = :after
            end
        end
        pg = Pinax.current_document().pages[1]
        @test [s.id for s in pg.sections] == [:a]
        a = pg.sections[1]
        @test [f.id for f in a.figures] == [:after]
        @test isempty(pg.figures)
        @test [s.id for s in a.sections] == [:b]
        @test [f.id for f in a.sections[1].figures] == [:inner]
        # the child is part of the parent's declaration order, before the figure that follows it
        @test first.(a.content) == [:section, :figure]
        @test Pinax.current_section() === nothing
    end

    @testset "depth, anchors and the tree for a six-deep chain" begin
        Pinax.reset!()
        _chain!(svg)
        pg = Pinax.current_document().pages[1]
        s = pg.sections[1]
        depths = Int[]
        anchors = String[]
        while true
            push!(depths, s.depth)
            push!(anchors, s.anchor)
            isempty(s.sections) && break
            s = s.sections[1]
        end
        @test depths == 2:7
        @test anchors == ["s2", "s3", "s4", "s5", "s6", "s7"]   # the id is the anchor
        # every figure in the tree is resolvable by id
        doc = Pinax.resolve!(Pinax.current_document())
        @test length(doc.refs) == 1 + 6 + 6   # page + sections + figures
    end

    @testset "@page inside a section is an error where it is written" begin
        Pinax.reset!()
        @test_throws ErrorException @page :p "P" begin
            @section :a "A" begin
                @page :q "Q" begin end
            end
        end
    end

    @testset "LaTeX: one heading per depth, a fixed fallback beyond \\subparagraph" begin
        Pinax.reset!(; theme=:latex)
        _chain!(svg)
        out = joinpath(tmp, "tex")
        Pinax.render(; out=out, theme=:latex)
        tex = read(joinpath(out, "document.tex"), String)
        @test occursin("\\subsection{S2}", tex)
        @test occursin("\\subsubsection{S3}", tex)
        @test occursin("\\paragraph{S4}", tex)
        @test occursin("\\subparagraph{S5}", tex)
        # depth 6 and 7 are beyond LaTeX's levels: a bold run-in heading, plus a diagnostic each
        @test occursin("\\par\\noindent\\textbf{S6}", tex)
        @test occursin("\\par\\noindent\\textbf{S7}", tex)
        diag = read(joinpath(out, "diagnostics.md"), String)
        @test occursin("s6", diag) && occursin("depth 6", diag)
        @test occursin("s7", diag) && occursin("depth 7", diag)
    end

    @testset "gallery: <h2>…<h6>, then an aria-level heading" begin
        Pinax.reset!()
        _chain!(svg)
        out = joinpath(tmp, "html")
        Pinax.render(; out=out)
        html = read(joinpath(out, "index.html"), String)
        for (d, t) in zip(2:6, ("S2", "S3", "S4", "S5", "S6"))
            @test occursin(Regex("<h$(d)>[^<]*$(t)"), html)
        end
        @test occursin(r"<div role=\"heading\" aria-level=\"7\"[^>]*>[^<]*S7", html)
    end

    @testset "agent.json carries the tree and each section's depth" begin
        Pinax.reset!()
        _chain!(svg)
        out = joinpath(tmp, "agent")
        Pinax.render(; out=out, theme=:agent)
        js = read(joinpath(out, "agent.json"), String)
        @test occursin("\"id\":\"s2\"", js)
        @test occursin("\"depth\":2", js)
        @test occursin("\"depth\":7", js)
        # s3 is nested inside s2's object, not listed as a sibling page section
        i2 = findfirst("\"id\":\"s2\"", js)
        i3 = findfirst("\"id\":\"s3\"", js)
        @test first(i3) > first(i2)
        @test occursin("\"content\":[{\"kind\":\"figure\"", js)
        @test occursin("{\"kind\":\"section\",\"id\":\"s3\"}", js)
        md = read(joinpath(out, "agent.md"), String)
        @test occursin("#### S2", md)
        @test occursin("##### S3", md)
        @test occursin("###### S4", md)
        @test occursin("**S5**", md)   # beyond ######: a bold line
        # and both files say so: agent.json's diagnostics are agent.md's, fallbacks included
        diag = only(filter(d -> d["item"] == "s5", JSON.parse(js)["diagnostics"]))
        @test occursin("depth 5", diag["message"])
        @test occursin("[WARNING] s5", md)
    end
end
