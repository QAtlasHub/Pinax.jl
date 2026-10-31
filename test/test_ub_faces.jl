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
