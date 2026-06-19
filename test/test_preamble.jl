using Pinax
using Test

@testset "preamble extensions (@newcommand -> KaTeX macros, css/js overlay)" begin
    tmp = mktempdir()
    site(n) = joinpath(tmp, n)
    svg = joinpath(tmp, "a.svg")
    write(svg, "<svg xmlns='http://www.w3.org/2000/svg'><rect/></svg>")

    @testset "@newcommand is wired into KaTeX macros" begin
        Pinax.reset!()
        @newcommand raw"\E" raw"\langle H\rangle"
        @page :p "P" begin
            @section :s "S" begin
                @figure svg
            end
        end
        html = read(Pinax.render(; out=site("nc")), String)
        @test occursin("macros:{", html)
        @test occursin("\\\\E", html)                    # the \E command (JSON-escaped) in macros
        @test occursin("\\\\langle H\\\\rangle", html)   # its expansion
    end

    @testset "no @newcommand -> empty macros object" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure svg
            end
        end
        html = read(Pinax.render(; out=site("nc0")), String)
        @test occursin("macros:{}", html)
    end

    @testset "css overlay is inlined after the theme CSS" begin
        cssf = joinpath(tmp, "extra.css")
        write(cssf, ".MYMARK{color:red}")
        Pinax.reset!(; css=[cssf])
        @page :p "P" begin
            @section :s "S" begin
                @figure svg
            end
        end
        html = read(Pinax.render(; out=site("css")), String)
        @test occursin(".MYMARK{color:red}", html)
    end

    @testset "js overlay is inlined" begin
        jsf = joinpath(tmp, "extra.js")
        write(jsf, "console.log('MYJSMARK');")
        Pinax.reset!(; js=[jsf])
        @page :p "P" begin
            @section :s "S" begin
                @figure svg
            end
        end
        html = read(Pinax.render(; out=site("js")), String)
        @test occursin("console.log('MYJSMARK');", html)
    end

    @testset "missing overlay file -> diagnostic (non-fatal)" begin
        Pinax.reset!(; css=[joinpath(tmp, "nope.css")])
        @page :p "P" begin
            @section :s "S" begin
                @figure svg
            end
        end
        html = read(Pinax.render(; out=site("miss")), String)   # must not throw
        @test occursin("overlay file not found", html)
    end
end
