using Pinax
using Test
using ParamIO

@testset "by= param facet" begin
    tmp = mktempdir()
    site(n) = joinpath(tmp, n)
    svg = joinpath(tmp, "a.svg")
    write(svg, "<svg xmlns='http://www.w3.org/2000/svg'><rect/></svg>")
    k(g) = ParamIO.DataKey(Dict{String,Any}("system.g" => g, "system.N" => 8), 0)

    @testset "figures grouped by a param axis, sorted by value" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" by = "system.g" begin
                @figure svg params = k(1.0)
                @figure svg params = k(0.5)
                @figure svg params = k(1.0)
            end
        end
        html = read(Pinax.render(; out=site("f1")), String)
        @test occursin("system.g = 0.5", html)
        @test occursin("system.g = 1.0", html)
        @test first(findfirst("system.g = 0.5", html)) <
            first(findfirst("system.g = 1.0", html))   # 0.5 group before 1.0
        @test count("class=\"facet\"", html) == 2       # two groups
    end

    @testset "figure missing the facet param -> (unset) group" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" by = "system.g" begin
                @figure svg params = k(0.5)
                @figure svg                       # no params
            end
        end
        html = read(Pinax.render(; out=site("f2")), String)
        @test occursin("system.g = 0.5", html)
        @test occursin("system.g: (unset)", html)
    end

    @testset "non-faceted section renders a single flat grid" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure svg
                @figure svg
            end
        end
        html = read(Pinax.render(; out=site("f3")), String)
        @test !occursin("class=\"facet\"", html)
        @test count("class=\"figgrid\"", html) == 1
    end
end
