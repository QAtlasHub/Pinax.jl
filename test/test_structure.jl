using Pinax
using Test

# Structure (Conventions › Structure). Each block has one place it may be written, and anywhere else
# is an error raised where it is written. A page and a section are the same kind of container: the
# page's top-level sections sit in its content order like a section's children do, so every face
# walks one content list and lays every container out the same way.

@testset "structure" begin
    tmp = mktempdir()

    @testset "each block has one place" begin
        Pinax.reset!()
        @test_throws "top level" @page :p "P" begin
            @part :g "G" begin end
        end
        Pinax.reset!()
        @test_throws "top level" @page :p "P" begin
            @section :s "S" begin
                @part :g "G" begin end
            end
        end
        Pinax.reset!()
        @test_throws "top level" @part :g "G" begin
            @part :h "H" begin end
        end
        Pinax.reset!()
        @test_throws "inside @page :p" @page :p "P" begin
            @page :q "Q" begin end
        end
        Pinax.reset!()
        @test_throws "@pinaxsetup" @page :p "P" begin
            @pinaxsetup title = "late"
        end
        # the legal places still work
        Pinax.reset!()
        @part :g "G" begin
            @page :p "P" begin
                @section :s "S" begin
                    @section :t "T" begin end
                end
            end
        end
        @page :q "Q" begin end
        @test [p.id for p in Pinax.current_document().pages] == [:p, :q]
    end

    @testset "a page's sections sit in its content order" begin
        Pinax.reset!()
        @page :p "P" begin
            @desc "BEFORE"
            @section :s "SECTION" begin end
            @desc "AFTER"
        end
        pg = Pinax.current_document().pages[1]
        @test [k for (k, _) in pg.content] == [:text, :section, :text]

        g = read(Pinax.render(; out=joinpath(tmp, "g")), String)
        sec_el = first(findfirst("<section class=\"section\" id=\"s\"", g))   # not the TOC entry
        @test first(findfirst("BEFORE", g)) < sec_el < first(findfirst("AFTER", g))
        lx = read(Pinax.render(; out=joinpath(tmp, "l"), theme=:latex), String)
        @test first(findfirst("BEFORE", lx)) <
            first(findfirst("\\subsection{SECTION}", lx)) <
            first(findfirst("AFTER", lx))
        Pinax.render(; out=joinpath(tmp, "a"), theme=:agent)
        md = read(joinpath(tmp, "a", "agent.md"), String)
        @test first(findfirst("BEFORE", md)) <
            first(findfirst("SECTION", md)) <
            first(findfirst("AFTER", md))
        @test count("SECTION", md) == 1   # emitted once, from the content walk
        aj = read(joinpath(tmp, "a", "agent.json"), String)
        @test occursin("{\"kind\":\"section\",\"id\":\"s\"}", aj)
    end

    @testset "every face: verdict band and own checks, then content" begin
        Pinax.reset!()
        @page :p "P" begin
            @desc "PROSE_FIRST"
            @test 1 + 1 == 2
        end
        Pinax.render(; out=joinpath(tmp, "o"), theme=:agent)
        md = read(joinpath(tmp, "o", "agent.md"), String)
        @test first(findfirst("1/1 PASS", md)) <
            first(findfirst("[PASS]", md)) <
            first(findfirst("PROSE_FIRST", md))
        g = read(Pinax.render(; out=joinpath(tmp, "og")), String)
        @test first(findfirst("pinax-checks", g)) < first(findfirst("PROSE_FIRST", g))
        lx = read(Pinax.render(; out=joinpath(tmp, "ol"), theme=:latex), String)
        @test first(findfirst("Verdict: PASS", lx)) < first(findfirst("PROSE\\_FIRST", lx))
    end

    @testset "@caption after a page's section names nothing" begin
        Pinax.reset!()
        @test_throws "follows a section" @page :p "P" begin
            @figure 1
            @section :s "S" begin end
            @caption "never reaches back to the figure"
        end
    end

    @testset "one heading function per backend, for parts, pages and sections" begin
        Pinax.reset!()
        @part :g "PartT" begin
            @page :p "PageT" begin
                @section :s "SecT" begin end
            end
        end
        lx = read(Pinax.render(; out=joinpath(tmp, "h"), theme=:latex), String)
        @test occursin("\\part{PartT}\\label{g}", lx)
        @test occursin("\\section{PageT}\\label{p}", lx)
        @test occursin("\\subsection{SecT}\\label{s}", lx)
        Pinax.render(; out=joinpath(tmp, "hm"), theme=:agent)
        md = read(joinpath(tmp, "hm", "agent.md"), String)
        @test occursin("\n## PartT", md) &&
            occursin("\n### PageT", md) &&
            occursin("\n#### SecT", md)
        # beyond ###### agent.md falls back to a bold line, and says so
        rdiag = Pinax.DiagEntry[]
        @test Pinax._agent_md_heading(5, "Deep", "deep", rdiag) == "**Deep**"
        @test only(rdiag).item == "deep" && occursin("depth 5", only(rdiag).message)
        @test Pinax._agent_md_heading(4, "Ok", "ok", rdiag) == "###### Ok"
    end

    @testset "LaTeX: the verdict band leads its check table" begin
        Pinax.reset!()
        @page :p "P" begin
            @test true
        end
        lx = read(Pinax.render(; out=joinpath(tmp, "v"), theme=:latex), String)
        @test first(findfirst("Verdict: PASS", lx)) <
            first(findfirst("\\begin{tabular}", lx))
    end

    @testset "LaTeX says what it left out, never silently" begin
        Pinax.reset!()
        @page :p "P" begin
            @raw "<b>html</b>"
            @table NamedTuple[] caption = "no columns" id = :empty_tbl
        end
        out = joinpath(tmp, "drop")
        Pinax.render(; out=out, theme=:latex)
        diag = read(joinpath(out, "diagnostics.md"), String)
        @test occursin("@raw", diag)
        @test occursin("empty_tbl", diag)
    end

    @testset "out is a directory: one face per subdirectory, one comment store" begin
        out = joinpath(tmp, "report")
        mkpath(out)
        node = Pinax.TestNode(
            "test_x.jl"; checks=[Pinax.Check(:t, "ok", 1.0, 1.0, 0.0, 0.5, :abs, true)]
        )
        Pinax.add_comment(
            joinpath(out, "comments.toml"), :test_x_jl, "SHARED_NOTE"; author="me"
        )
        res = Pinax.render_test_report(Pinax.TestNode("T"; children=[node]); out=out)
        @test res.gallery == joinpath(out, "html", "index.html")
        @test res.agent == joinpath(out, "agent", "agent.json")
        @test occursin("SHARED_NOTE", read(joinpath(out, "html", "test_x_jl.html"), String))
        @test occursin("SHARED_NOTE", read(joinpath(out, "agent", "agent.md"), String))
    end

    @testset "one way to say a thing, and a wrong argument is an error" begin
        Pinax.reset!()
        @test_throws "@pinaxsetup debug" @debug_mode true
        Pinax.reset!()
        @test_throws "Symbol" @page :p "P" begin
            @thumbnail "not an id"
        end
        Pinax.reset!()
        @page :p "P" begin
            @thumbnail :nope
            @figure 1
        end
        @test_throws "names no figure" Pinax.render(; out=joinpath(tmp, "thumb"))
        Pinax.reset!()
        @test_throws "a String" @page :p "P" begin
            @section :s "S" by = ("a", "b") begin end
        end
    end
end
