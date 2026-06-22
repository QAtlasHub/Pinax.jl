using Pinax
using Test

# `assets=` selects how the gallery's own CSS/JS are delivered: `:default` (the default) writes a
# shared style.css / app.js that every page links (deduped, readable); `:inline` embeds them into each
# file (a single self-contained HTML). KaTeX is governed separately by `katex=`.
@testset "asset mode: :default externalizes, :inline embeds" begin
    tmp = mktempdir()
    svg = joinpath(tmp, "a.svg")
    write(svg, "<svg xmlns='http://www.w3.org/2000/svg'><rect/></svg>")
    site(n) = joinpath(tmp, n)
    function build()
        @part :t "T" begin
            @page :a "A" begin
                @figure svg
            end
            @page :b "B" begin
                @figure svg
            end
        end
    end

    @testset ":default (the default) writes a shared style.css the pages link" begin
        Pinax.reset!(; title="x")
        build()
        Pinax.render(; out=site("def"))
        @test isfile(joinpath(site("def"), "style.css"))
        a = read(joinpath(site("def"), "a.html"), String)
        @test occursin("href=\"style.css\"", a)   # links the shared sheet
        @test !occursin("body{", a)               # …gallery CSS is not inlined
    end

    @testset ":inline embeds the CSS (single self-contained file)" begin
        Pinax.reset!(; title="x", assets=:inline)
        build()
        Pinax.render(; out=site("inl"))
        @test !isfile(joinpath(site("inl"), "style.css"))
        a = read(joinpath(site("inl"), "a.html"), String)
        @test occursin("body{", a)                # gallery CSS inlined
    end

    @testset "an invalid asset mode errors" begin
        @test_throws ErrorException Pinax.reset!(; assets=:bogus)
    end
end
