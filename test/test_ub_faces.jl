using Pinax
using Test
using JSON

# Review findings on the faces (gallery, LaTeX, agent): each testset pins one behavior that was wrong
# or untested.

# A `missing` / `nothing` in `@figure … data=` is a gap in the plot, like NaN: a blank cell in the
# data file, and not counted as a point.
@testset "data=: a missing value is a blank cell, not a point" begin
    tmp = mktempdir()
    Pinax.reset!(; title="gap")
    @page :p "P" begin
        @figure error("no gen") data = (; x=[1, 2, 3], y=[1.0, missing, 3.0]) id = :f
        @figure error("no gen") data = (; x=[1, 2], y=[nothing, 2.0]) id = :h
    end
    out = joinpath(tmp, "agent")
    j = JSON.parsefile(Pinax.render(; out=out, theme=:agent))
    figs = j["pages"][1]["figures"]
    @test only(figs[1]["data"]["series"])["points"] == 2
    @test only(figs[2]["data"]["series"])["points"] == 1
    @test read(joinpath(out, "assets", "figures", "p", "f.csv"), String) ==
        "series,x,y\ny,1,1.0\ny,2,\ny,3,3.0\n"
    @test read(joinpath(out, "assets", "figures", "p", "h.csv"), String) ==
        "series,x,y\ny,1,\ny,2,2.0\n"
end

# A figure with nothing to draw — its gen() failed, or it produced no asset — still carries its
# comments in every face: the placeholder (gallery) and the left-out note (LaTeX) keep the thread.
struct _NoAssetFig end
Pinax.is_figure(::_NoAssetFig) = true
Pinax._figure_table(::_NoAssetFig) = nothing
struct _TableOnlyGallery <: Pinax.GalleryBase end
Pinax.figure_formats(::_TableOnlyGallery) = Symbol[:table]
struct _TableOnlyTeX <: Pinax.LaTeXBase end
Pinax.figure_formats(::_TableOnlyTeX) = Symbol[:table]

@testset "comments on a figure with nothing to draw reach every face" begin
    tmp = mktempdir()
    function doc!()
        Pinax.reset!(; title="Empty figures")
        @page :p "P" begin
            @figure error("boom") id = :bad
            @figure _NoAssetFig() id = :none
        end
    end
    function comments!(out)
        mkpath(out)
        f = joinpath(out, "comments.toml")
        Pinax.add_comment(f, :bad, "NOTEBAD"; author="me")
        Pinax.add_comment(f, :none, "NOTENONE"; author="me")
        return nothing
    end
    blob = r"<script type=\"application/json\" id=\"pinax-committed\">.*?</script>"s
    for (name, theme, file) in (
        ("gallery", :gallery, "index.html"),
        ("gallery, no asset", _TableOnlyGallery(), "index.html"),
        ("LaTeX", :latex, "document.tex"),
        ("LaTeX, no asset", _TableOnlyTeX(), "document.tex"),
    )
        @testset "$name" begin
            doc!()
            out = joinpath(tmp, name)
            comments!(out)
            Pinax.render(; out=out, theme=theme)
            s = replace(read(joinpath(out, file), String), blob => "")
            @test occursin("NOTEBAD", s)
            @test occursin("NOTENONE", s)
        end
    end
end

# The index counts a page's whole section tree, as its Contents nav and figure count do: a nested
# section is a section, and the :rich card lists it.
@testset "index: section counts and the :rich card cover nested sections" begin
    tmp = mktempdir()
    svg = joinpath(tmp, "f.svg")
    write(svg, "<svg xmlns='http://www.w3.org/2000/svg'><rect/></svg>")
    function doc!(level)
        Pinax.reset!(; title="Nested")
        @pinaxsetup index = level
        @page :a "A" begin
            @section :outer "OUTER_T" begin
                @section :inner "INNER_T" begin
                    @figure svg id = :f
                end
            end
        end
        @page :b "B" begin
            @desc "b"
        end
    end
    for level in (:toc, :cards, :rich)
        doc!(level)
        idx = read(Pinax.render(; out=joinpath(tmp, string(level))), String)
        @test occursin("2 sections · 1 figure", idx)
        level === :rich && @test occursin("INNER_T", idx)
    end
end
