using Pinax
using Test
using JSON

_pos(s, needle) = first(findfirst(needle, s))

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
        for id in (:pg, :sec, :fig, :tbl)
            Pinax.add_comment(f, id, "NOTE_$(id)"; author="me")
        end
    end

    @testset "gallery" begin
        doc!()
        out = joinpath(tmp, "g")
        comments!(out)
        g = read(Pinax.render(; out=out), String)
        # every stored comment rides in the page's JSON blob for the browser layer; a node shows a
        # comment only if it is rendered outside it
        g = replace(
            g,
            r"<script type=\"application/json\" id=\"pinax-committed\">.*?</script>"s => "",
        )
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
            "NOTE_tbl",
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
            "NOTE\\_tbl",
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
        tbl = only(pg["tables"])
        @test tbl["id"] == "tbl" && only(tbl["comments"])["text"] == "NOTE_tbl"
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
        @test [r["kind"] for r in pg["content"]] == ["text", "figure", "table", "code", "code", "check", "raw", "section"]
        # @raw is carried as its HTML, under a generated id like any other node
        raw = only(pg["raws"])
        @test raw["html"] == "<b>RAW_HTML</b>" && startswith(raw["id"], "pg_raw_")
        @test only(r for r in pg["content"] if r["kind"] == "raw")["id"] == raw["id"]
        @test !any(d -> occursin("@raw", d["message"]), aj["diagnostics"])
        md = read(joinpath(out, "agent.md"), String)
        @test occursin("```html\n<b>RAW_HTML</b>\n```", md)
    end

    @testset "@raw: an id, written or generated, and its anchor in the gallery" begin
        Pinax.reset!()
        @page :p "P" begin
            @raw "<i>one</i>" id = :banner
            @raw "<i>two</i>"
        end
        pg = only(Pinax.current_document().pages)
        @test [r.id for r in pg.raws][1] === :banner
        @test startswith(string(pg.raws[2].id), "p_raw_")
        g = read(Pinax.render(; out=joinpath(tmp, "raw")), String)
        @test occursin("<div class=\"pinax-raw\" id=\"banner\"><i>one</i></div>", g)
        Pinax.reset!()
        @test_throws "duplicate id :banner" @page :p "P" begin
            @raw "<i>one</i>" id = :banner
            @desc "x"
            @table (a=[1],) id = :banner
        end
    end

    # A comment is stored under an id. One whose id names no node (a generated id changes with its
    # node's content), or names a kind that carries no comments, is shown by no face: every face
    # says so in its diagnostics instead of dropping it.
    @testset "a comment no face can show is a diagnostic" begin
        function stray!(out)
            mkpath(out)
            f = joinpath(out, "comments.toml")
            Pinax.add_comment(f, :pg_fig_gone, "ORPHAN"; author="me")
            Pinax.add_comment(f, :cd, "ON_CODE"; author="me")
        end
        doc!()
        g = joinpath(tmp, "sg")
        stray!(g)
        html = read(Pinax.render(; out=g), String)
        diag = html[first(findfirst("id=\"diagnostics\"", html)):end]
        @test occursin("pg_fig_gone", diag) && occursin("names no node", diag)
        @test occursin("cd", diag) && occursin("code block", diag)

        doc!()
        l = joinpath(tmp, "sl")
        stray!(l)
        Pinax.render(; out=l, theme=:latex)
        ld = read(joinpath(l, "diagnostics.md"), String)
        @test occursin("pg_fig_gone", ld) && occursin("code block", ld)

        doc!()
        a = joinpath(tmp, "sa")
        stray!(a)
        Pinax.render(; out=a, theme=:agent)
        ds = JSON.parse(read(joinpath(a, "agent.json"), String))["diagnostics"]
        @test any(
            d -> d["item"] == "pg_fig_gone" && occursin("names no node", d["message"]), ds
        )
        @test any(d -> d["item"] == "cd" && occursin("code block", d["message"]), ds)
    end

    # A data file's description is exact: two series never merge because they share a label, a gap
    # (NaN) is not a point, and a series whose x and y differ in length is an error where written.
    @testset "agent face: a data description counts what is plotted" begin
        Pinax.reset!()
        @page :p "P" begin
            @figure nothing data = (;
                series=[
                    (; label="a", x=[1, 2], y=[1.0, 2.0]),
                    (; label="a", x=[1, 2, 3], y=[3.0, NaN, 5.0]),
                ],
            ) id = :twins
        end
        out = joinpath(tmp, "dcount")
        Pinax.render(; out=out, theme=:agent)
        aj = JSON.parse(read(joinpath(out, "agent.json"), String))
        d = only(only(aj["pages"])["figures"])["data"]
        @test [(s["label"], s["points"]) for s in d["series"]] == [("a", 2), ("a (2)", 2)]
        Pinax.reset!()
        @test_throws r"series \"a\" has 3 x values and 2 y values" @page :q "Q" begin
            @figure nothing data = (; series=[(; label="a", x=[1, 2, 3], y=[1.0, 2.0])])
        end
    end

    # The agent face is the same compiled report: a figure sits in its block, between the prose
    # written around it, and its data is pointed to, never inlined as a cut copy. What it inlines
    # is exact (columns, series, point counts); where a node was written is a `path:line` pointer.
    @testset "agent face: exact descriptors and pointers, never a cut copy" begin
        x = collect(1.0:5000.0)
        Pinax.reset!()
        @page :p "P" begin
            @desc "BEFORE_FIG"
            @figure nothing data = (;
                xlabel="beta",
                ylabel="E/N",
                series=[(; label="a", x=x, y=sin.(x)), (; label="b", x=x[1:10], y=x[1:10])],
            ) id = :dat caption = "CAP"
            @desc "AFTER_FIG"
            @figure svg id = :img
            @table (a=[1, 2],) id = :t
            @code id = :c Q_VAL = 1
            @raw "<i>r</i>"
            @test true
        end
        out = joinpath(tmp, "ptr")
        Pinax.render(; out=out, theme=:agent)
        aj = JSON.parse(read(joinpath(out, "agent.json"), String))
        pg = only(aj["pages"])
        f = only(f for f in pg["figures"] if f["id"] == "dat")
        @test !haskey(f, "table")   # no inlined preview
        d = f["data"]
        @test d["columns"] == ["series", "beta", "E/N"]
        @test [(s["label"], s["points"]) for s in d["series"]] == [("a", 5000), ("b", 10)]
        @test countlines(joinpath(out, d["path"])) == 1 + 5010   # the header, then every point
        at = r"^test/test_faces\.jl:\d+$"   # relative to the project that holds the file
        @test occursin(at, f["defined_at"])
        @test occursin(at, only(pg["tables"])["defined_at"])
        @test occursin(at, only(c for c in pg["codes"] if c["id"] == "c")["defined_at"])
        @test all(t -> occursin(at, t["defined_at"]), pg["texts"])
        @test occursin(at, only(pg["raws"])["defined_at"])
        @test occursin(at, only(pg["checks"])["defined_at"])
        # a figure with no data form says so: an agent sees it only through its image
        img = only(f for f in pg["figures"] if f["id"] == "img")
        @test img["data"] === nothing
        @test any(
            e -> e["item"] == "img" && occursin("no data", e["message"]), aj["diagnostics"]
        )

        md = read(joinpath(out, "agent.md"), String)
        @test !occursin("| series |", md)
        @test occursin("a (5000 points), b (10 points)", md)
        @test occursin("columns: series, beta, E/N", md)
        @test _pos(md, "BEFORE_FIG") < _pos(md, "[fig: dat] CAP") < _pos(md, "AFTER_FIG")
    end

    # Each face is self-contained: rendering the gallery and then the agent face from the same
    # document never leaves the agent face pointing into the gallery's directory.
    @testset "each face points only into its own directory" begin
        Pinax.reset!()
        @page :p "P" begin
            @figure svg data = (; x=[1.0, 2.0], y=[3.0, 4.0]) id = :d
            @figure svg id = :i
        end
        out = joinpath(tmp, "both")
        Pinax.render(; out=joinpath(out, "html"))
        Pinax.render(; out=joinpath(out, "agent"), theme=:agent)
        aj = JSON.parse(read(joinpath(out, "agent", "agent.json"), String))
        figs = only(aj["pages"])["figures"]
        paths = vcat(
            (f["assets"] for f in figs)...,
            (f["data"]["path"] for f in figs if f["data"] !== nothing)...,
        )
        @test !isempty(paths)
        @test all(p -> !startswith(p, "..") && isfile(joinpath(out, "agent", p)), paths)
        md = read(joinpath(out, "agent", "agent.md"), String)
        @test !occursin("../", md)
    end
end
