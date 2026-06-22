using Pinax
using Test

# The index page is emitted only for multi-page galleries. Its verbosity is `meta.index`
# (preamble `@pinaxsetup index=…`) falling back to the theme's `index_level`:
#   :toc   — a compact link list with one-line summaries (no thumbnails)
#   :cards — thumbnail cards + per-page summary (default)
#   :rich  — cards + a per-section breakdown beneath each summary
@testset "page summary + index levels" begin
    tmp = mktempdir()
    svg = joinpath(tmp, "a.svg")
    write(svg, "<svg xmlns='http://www.w3.org/2000/svg'><rect/></svg>")
    sitedir(name) = joinpath(tmp, name)

    @testset "@page summary= is stored on the Page" begin
        Pinax.reset!()
        @page :p "P" summary = "what this page does" begin
            @section :s "S" begin
                @figure svg
            end
        end
        @test Pinax.current_document().pages[1].summary == "what this page does"
    end

    @testset "@page without summary leaves it nothing" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure svg
            end
        end
        @test Pinax.current_document().pages[1].summary === nothing
    end

    @testset "default :cards index shows the page summary (not the section breakdown)" begin
        Pinax.reset!()
        @page :a "Alpha" summary = "alpha blurb" begin
            @section :s "Sec A" summary = "inner a" begin
                @figure svg
            end
        end
        @page :b "Beta" begin   # no summary
            @section :s "Sec B" begin
                @figure svg
            end
        end
        html = read(Pinax.render(; out=sitedir("cards")), String)
        @test occursin("<div class=\"pinax-cards\">", html)
        @test occursin("<div class=\"card-summary\">alpha blurb</div>", html)
        @test !occursin("<div class=\"card-sections\">", html)  # breakdown is :rich-only
        @test !occursin("inner a", html)                        # section summary is :rich-only
        @test count("<a class=\"pinax-card\"", html) == 2       # both pages get a card
        @test count("<div class=\"card-summary\">", html) == 1  # only Alpha's summary shown
    end

    @testset "index=:rich adds a per-section breakdown under each card" begin
        @pinaxsetup index = :rich   # also resets the implicit document
        @page :a "Alpha" summary = "alpha blurb" begin
            @section :s "Sec A" summary = "inner a" begin
                @figure svg
            end
            @section :t "Sec T" begin   # section without a summary
                @figure svg
            end
        end
        @page :b "Beta" begin
            @section :s "Sec B" begin
                @figure svg
            end
        end
        html = read(Pinax.render(; out=sitedir("rich")), String)
        @test occursin("<div class=\"card-sections\">", html)
        @test occursin("alpha blurb", html)                           # page summary still shown
        @test occursin("<span class=\"sec-name\">Sec A</span>", html)  # section name
        @test occursin("— inner a", html)                             # section summary
        @test occursin("<span class=\"sec-name\">Sec T</span>", html)  # summary-less section listed
    end

    @testset "index=:toc is a compact link list, not cards" begin
        @pinaxsetup index = :toc
        @page :a "Alpha" summary = "alpha blurb" begin
            @section :s "S" begin
                @figure svg
            end
        end
        @page :b "Beta" begin
            @section :s "S" begin
                @figure svg
            end
        end
        html = read(Pinax.render(; out=sitedir("toc")), String)
        @test occursin("<ul class=\"pinax-toc\">", html)
        @test !occursin("<div class=\"pinax-cards\">", html)   # cards replaced by the list
        @test occursin("<span class=\"toc-summary\">— alpha blurb</span>", html)
        @test occursin("<a href=\"a.html\">Alpha</a>", html)
        @test occursin("<span class=\"toc-meta\">(1 section · 1 figure)</span>", html)
    end

    @testset "index=:rich with a section-less page emits no card-sections for it" begin
        @pinaxsetup index = :rich
        @page :empty "Empty" summary = "no sections yet" begin end
        @page :a "Alpha" summary = "blurb" begin
            @section :s "S" begin
                @figure svg
            end
        end
        html = read(Pinax.render(; out=sitedir("rich_empty")), String)
        @test occursin("<div class=\"card-summary\">no sections yet</div>", html)  # card still shown
        @test count("<div class=\"card-sections\">", html) == 1                    # only Alpha's
    end

    @testset "an invalid index= level is rejected, not silently degraded" begin
        @test_throws ErrorException @pinaxsetup index = :bogus
    end
end
