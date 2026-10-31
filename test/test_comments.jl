using Pinax
using Test

@testset "comment store + inline rendering" begin
    tmp = mktempdir()
    site(n) = joinpath(tmp, n)
    svg = joinpath(tmp, "a.svg")
    write(svg, "<svg xmlns='http://www.w3.org/2000/svg'><rect/></svg>")

    @testset "read_comments on a missing file is empty" begin
        c, b = Pinax.read_comments(joinpath(tmp, "nope.toml"))
        @test isempty(c)
        @test isempty(b)
    end

    @testset "add_comment appends turns (multi-writer, no clobber)" begin
        f = joinpath(tmp, "cm1.toml")
        Pinax.add_comment(f, :energy, "first note"; author="me")
        Pinax.add_comment(f, :energy, "a reply"; author="llm")
        Pinax.add_comment(f, :other, "elsewhere"; author="sensei")
        c, b = Pinax.read_comments(f)
        @test length(c[:energy]) == 2
        @test c[:energy][1].author == "me"
        @test c[:energy][1].text == "first note"
        @test c[:energy][2].author == "llm"
        @test c[:other][1].author == "sensei"
        @test isempty(b)
    end

    @testset "set_bookmark! round-trips and preserves comments" begin
        f = joinpath(tmp, "cm2.toml")
        Pinax.add_comment(f, :energy, "note"; author="me")
        Pinax.set_bookmark!(f, :energy, true)
        c, b = Pinax.read_comments(f)
        @test :energy in b
        @test length(c[:energy]) == 1   # bookmark write preserved the comment
    end

    @testset "comments render inline under their section" begin
        f = joinpath(tmp, "cm3.toml")
        Pinax.add_comment(f, :energy, "residual looks **large**"; author="llm")
        Pinax.reset!()
        @page :p "P" begin
            @section :energy "Energy" begin
                @figure svg
            end
        end
        html = read(Pinax.render(; out=site("s3"), comments_file=f), String)
        @test occursin("<div class=\"pinax-comments\">", html)
        @test occursin("<span class=\"author\">llm</span>", html)
        @test occursin("<strong>large</strong>", html)   # body markdown rendered server-side
    end

    @testset "bookmarked section shows a marker + class" begin
        f = joinpath(tmp, "cm4.toml")
        Pinax.set_bookmark!(f, :energy, true)
        Pinax.reset!()
        @page :p "P" begin
            @section :energy "Energy" begin
                @figure svg
            end
        end
        html = read(Pinax.render(; out=site("s4"), comments_file=f), String)
        @test occursin("class=\"pinax-bm-on\"", html)
        @test occursin("class=\"section bookmarked\"", html)
    end

    @testset "a bookmark reaches its section by id, whatever characters the id has" begin
        f = joinpath(tmp, "cm4u.toml")
        Pinax.set_bookmark!(f, :α_sec, true)   # stored under the id; its anchor is hashed
        Pinax.reset!()
        @page :p "P" begin
            @section :α_sec "Alpha" begin end
        end
        html = read(Pinax.render(; out=site("s4u"), comments_file=f), String)
        @test occursin("class=\"section bookmarked\"", html)
    end

    @testset "no comments file -> no comment markup" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure svg
            end
        end
        html = read(Pinax.render(; out=site("s5")), String)   # default comments_file absent
        @test !occursin("<div class=\"pinax-comments\">", html)   # CSS rule may exist; no div emitted
    end

    @testset "raw HTML in a comment is escaped" begin
        f = joinpath(tmp, "cm6.toml")
        Pinax.add_comment(f, :s, "<script>alert(1)</script>"; author="x")
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure svg
            end
        end
        html = read(Pinax.render(; out=site("s6"), comments_file=f), String)
        @test occursin("&lt;script&gt;", html)
        @test !occursin("<script>alert", html)
    end

    @testset "render only reads the comments file (never clobbers it)" begin
        f = joinpath(tmp, "cm7.toml")
        Pinax.add_comment(f, :s, "keep me"; author="me")
        before = read(f, String)
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure svg
            end
        end
        Pinax.render(; out=site("s7"), comments_file=f)
        @test read(f, String) == before   # untouched by render
    end

    @testset "comments attach to a figure (co-located inside its card)" begin
        f = joinpath(tmp, "cmfig.toml")
        Pinax.add_comment(f, :myfig, "look at this peak"; author="me")
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure svg id = :myfig
            end
        end
        html = read(Pinax.render(; out=site("sfig"), comments_file=f), String)
        # the comment must render INSIDE the figure card (visual binding to its target)
        card = split(split(html, "<figure id=\"myfig\">")[2], "</figure>")[1]
        @test occursin("<div class=\"pinax-comments\">", card)
        @test occursin("look at this peak", card)
        @test occursin("<span class=\"author\">me</span>", card)
    end

    @testset "an unparseable store is a diagnostic, not silence" begin
        f = joinpath(tmp, "broken.toml")
        write(f, "[comment\nthis is not toml")
        @test Pinax.read_comments(f) ==
            (Dict{Symbol,Vector{Pinax.Comment}}(), Set{Symbol}())
        Pinax.reset!()
        @page :p "P" begin end
        html = read(Pinax.render(; out=site("sbroken"), comments_file=f), String)
        diag = html[first(findfirst("id=\"diagnostics\"", html)):end]
        @test occursin("broken.toml", diag) && occursin("does not parse", diag)
    end

    @testset "a store entry in the wrong shape is a diagnostic, not silence" begin
        # `[comment.p]` is one table, not a turn list; a turn that is not a table, or has no text,
        # is not a turn either — each is said, and the well-formed turns are still shown
        f = joinpath(tmp, "shapes.toml")
        write(
            f,
            """
            comment.p = [{ author = "me", text = "KEPT_TURN" }, "not a table", { author = "me" }]
            [comment.q]
            author = "me"
            text = "one table"
            """,
        )
        Pinax.reset!()
        @page :p "P" begin end
        @page :q "Q" begin end
        Pinax.render(; out=site("sshapes"), theme=:agent, comments_file=f)
        md = read(joinpath(site("sshapes"), "agent.md"), String)
        @test occursin("KEPT_TURN", md)
        diag = md[first(findfirst("## Diagnostics", md)):end]
        @test occursin("q:", diag) && occursin("[[comment.q]]", diag)
        @test occursin("p:", diag) && occursin("turn 2", diag) && occursin("turn 3", diag)
    end
end
