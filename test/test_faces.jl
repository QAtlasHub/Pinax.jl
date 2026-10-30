using Pinax
using Test
using JSON

# Every node kind reaches every face (Conventions › Faces, #168). One document holds every kind;
# it is rendered to the gallery, LaTeX and the agent face, and each node is looked for in each
# one. `agent.json` is parsed, not substring-matched, so a node is found where the contract puts it.

@testset "every node kind in every face" begin
    tmp = mktempdir()
    svg = joinpath(tmp, "f.svg")
    write(svg, "<svg xmlns='http://www.w3.org/2000/svg'><rect/></svg>")

    function doc!()
        Pinax.reset!(; title="Faces")
        @part :grp "PART_T" begin
            @page :pg "PAGE_T" status = :draft begin
                @desc "PAGE_PROSE"
                @figure svg id = :fig
                @caption "FIG_CAP"
                @table (a=[1, 2], b=[3, 4]) id = :tbl caption = "TBL_CAP"
                @code id = :cd CODE_VALUE = 40 + 2
                @test 1 + 1 == 2
                @caption "CHECK_LABEL"
                @raw "<b>RAW_HTML</b>"
                @section :sec "SEC_T" begin
                    @desc "SEC_PROSE"
                    @testset "TS_T" begin
                        @test true
                    end
                end
            end
        end
    end
    # every node that carries comments, in every face's own comment store
    function comments!(out)
        mkpath(out)
        f = joinpath(out, "comments.toml")
        for id in (:pg, :sec, :fig)
            Pinax.add_comment(f, id, "NOTE_$(id)"; author="me")
        end
    end

    @testset "gallery" begin
        doc!()
        out = joinpath(tmp, "g")
        comments!(out)
        g = read(Pinax.render(; out=out), String)
        for needle in (
            "PART_T",
            "id=\"pg\"",
            "PAGE_PROSE",
            "id=\"fig\"",
            "FIG_CAP",
            "TBL_CAP",
            "CODE_VALUE",
            "CHECK_LABEL",
            "RAW_HTML",
            "id=\"sec\"",
            "SEC_PROSE",
            "TS_T",
            "NOTE_pg",
            "NOTE_sec",
            "NOTE_fig",
        )
            @test occursin(needle, g)
        end
    end

    @testset "LaTeX" begin
        doc!()
        out = joinpath(tmp, "l")
        comments!(out)
        lx = read(Pinax.render(; out=out, theme=:latex), String)
        for needle in (
            "\\part{PART\\_T}",
            "\\label{pg}",
            "PAGE\\_PROSE",
            "\\label{fig}",
            "FIG\\_CAP",
            "TBL\\_CAP",
            "CODE_VALUE = 40 + 2",   # verbatim: written as is
            "CHECK\\_LABEL",
            "\\label{sec}",
            "SEC\\_PROSE",
            "TS\\_T",
            "NOTE\\_pg",
            "NOTE\\_sec",
            "NOTE\\_fig",
        )
            @test occursin(needle, lx)
        end
        # the one kind LaTeX cannot show is named in its diagnostics, not dropped
        @test occursin("@raw", read(joinpath(out, "diagnostics.md"), String))
    end

    @testset "agent.json" begin
        doc!()
        out = joinpath(tmp, "a")
        comments!(out)
        Pinax.render(; out=out, theme=:agent)
        aj = JSON.parse(read(joinpath(out, "agent.json"), String))
        @test only(aj["parts"])["id"] == "grp"
        pg = only(aj["pages"])
        @test pg["id"] == "pg" && pg["part"] == "grp" && pg["status"] == "draft"
        @test only(pg["texts"])["text"] == "PAGE_PROSE"
        fig = only(pg["figures"])
        @test fig["id"] == "fig" && fig["caption"] == "FIG_CAP"
        @test only(fig["comments"])["text"] == "NOTE_fig"
        @test only(pg["tables"])["id"] == "tbl"
        cd = only(c for c in pg["codes"] if c["id"] == "cd")
        @test occursin("CODE_VALUE", cd["source"])
        chk = only(pg["checks"])
        @test chk["label"] == "CHECK_LABEL" && chk["pass"] === true
        @test chk["code_id"] in [c["id"] for c in pg["codes"]]   # its auto code block
        @test only(pg["comments"])["text"] == "NOTE_pg"
        sec = only(pg["sections"])
        @test sec["id"] == "sec" && only(sec["texts"])["text"] == "SEC_PROSE"
        @test only(sec["comments"])["text"] == "NOTE_sec"
        @test only(sec["sections"])["title"] == "TS_T"
        # content order holds every kind written on the page, sections included (a check is
        # preceded by its code block)
        @test [r["kind"] for r in pg["content"]] == ["text", "figure", "table", "code", "code", "check", "section"]
        # @raw has no agent form yet (an open question): it is left out of the content and named
        # in the diagnostics
        @test any(
            d -> d["item"] == "pg" && occursin("@raw", d["message"]), aj["diagnostics"]
        )
    end
end
