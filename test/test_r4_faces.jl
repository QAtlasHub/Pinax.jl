using Pinax
using Test
using JSON: JSON

# Round-4 review findings on the faces: each testset pins output a mutation review found unchecked.

@testset "agent.md: every line of a figure, a check, a code block, a container and a part" begin
    tmp = mktempdir()
    svg = joinpath(tmp, "f.svg")
    write(svg, "<svg xmlns='http://www.w3.org/2000/svg'/>")
    Pinax.reset!(; title="T")
    line = @__LINE__
    @part :pa "Part A" desc = md"PART_A_DESC" begin
        @page :p "P" summary = "PAGE_SUMMARY" begin
            @figure svg id = :fig caption = "FIG_CAP"
            @test isapprox(2.0, 1.5; rtol=0.5)
            @test isapprox(0.5, 0.25; atol=0.5)
            @code CODE_VAL = 40 + 2 caption = "CODE_CAP" id = :cd
        end
    end
    at(n) = "test/test_r4_faces.jl:$(line + n)"
    write(
        joinpath(tmp, "comments.toml"),
        "[[comment.fig]]\nauthor = \"me\"\ntext = \"FIG_NOTE\"\n",
    )
    Pinax.render(; out=tmp, theme=:agent)
    md = read(joinpath(tmp, "agent.md"), String)
    c_rel, c_abs = (c.id for c in Pinax.current_document().pages[1].checks)

    # a part's heading, then its description
    @test occursin("\n## Part A\nPART_A_DESC\n", md)
    # a container's heading, its verdict band, then its summary
    @test occursin("\n### P  [id: p]\n**P   2/2 PASS**\n_PAGE_SUMMARY_\n", md)
    # a figure's block: where and how it was made, its (missing) data, its image, and its note
    # indented into the block
    @test occursin(
        """
        - [fig: fig] FIG_CAP
          - defined at: $(at(3))
          - code: `svg`
          - data: none — this figure can be read only through its image
          - image: assets/figures/p/fig.svg
          - note (me): FIG_NOTE
        """,
        md,
    )
    # a check's numbers end with its kind
    @test occursin(
        "\n- [PASS] $(c_rel) — isapprox(2.0, 1.5; rtol = 0.5): got 2.0, want 1.5 " *
        "(Δ 0.25 vs tol 0.5 rel) — defined at $(at(4))\n",
        md,
    )
    @test occursin(
        "\n- [PASS] $(c_abs) — isapprox(0.5, 0.25; atol = 0.5): got 0.5, want 0.25 " *
        "(Δ 0.25 vs tol 0.5 abs) — defined at $(at(5))\n",
        md,
    )
    # a code block: its caption on the line naming it, the fenced source, then its output
    @test occursin(
        "\n[code: cd] CODE_CAP — defined at $(at(6))\n```julia\nCODE_VAL = 40 + 2\n```\n`=> 42`\n",
        md,
    )
    # agent.json carries the part's description too
    aj = JSON.parse(read(joinpath(tmp, "agent.json"), String))
    @test aj["parts"] == [
        Dict(
            "id" => "pa", "title" => "Part A", "desc" => "PART_A_DESC", "status" => nothing
        ),
    ]
end

# A testset that keeps the results of the document's own checks, so a failing check is data here.
mutable struct _R4Iso <: Test.AbstractTestSet
    description::String
    results::Vector{Any}
    _R4Iso(desc::AbstractString=""; kw...) = new(String(desc), Any[])
end
Test.record(r::_R4Iso, x) = (push!(r.results, x); x)
Test.finish(r::_R4Iso) = r

@testset "LaTeX: check rows, a code block, a comment, part headings, a stale sidecar" begin
    tmp = mktempdir()
    # a stand-in compiler, so this render records no diagnostic at all ("no LaTeX compiler" is one)
    bin = joinpath(tmp, "bin")
    mkpath(bin)
    write(joinpath(bin, "latexmk"), "#!/bin/sh\nexit 0\n")
    chmod(joinpath(bin, "latexmk"), 0o755)
    out = joinpath(tmp, "l")
    mkpath(out)
    write(joinpath(out, "diagnostics.md"), "# Diagnostics\n- STALE\n")   # an earlier render's
    write(
        joinpath(out, "comments.toml"),
        "[[comment.p1]]\nauthor = \"me\"\ntext = \"P1_NOTE\"\n",
    )
    Pinax.reset!(; title="T")
    line = @__LINE__
    @testset _R4Iso "iso" begin
        @part :a "Part A" begin
            @page :p1 "P1" begin
                @test error("boom")
                @test 1 + 1 == 2
                @code CODE_VAL = 40 + 2 caption = "CODE_CAP" id = :cd
            end
        end
        @part :b "Part B" begin
            @page :p2 "P2" begin end
        end
    end
    at(n) = "test/test_r4_faces.jl:$(line + n)"
    withenv("PATH" => string(bin, ":", ENV["PATH"])) do
        Pinax.render(; out=out, theme=:latex)
    end
    tex = read(joinpath(out, "document.tex"), String)
    texid(c) = replace(string(c.id), "_" => "\\_")
    c_err, c_ind = Pinax.current_document().pages[1].checks
    texat(n) = replace(at(n), "_" => "\\_")
    # an errored check reads ERROR, not FAIL; an indicator has blank number cells; each label ends
    # with where its @test was written
    @test occursin(
        "\n$(texid(c_err)) & error(\"boom\") @ $(texat(4)) &  &  &  &  & ERROR \\\\\n" *
        "$(texid(c_ind)) & 1 + 1 == 2 @ $(texat(5)) &  &  &  &  & PASS \\\\\n",
        tex,
    )
    # a code block: its caption, its source, then its output
    @test occursin(
        "\\par\\noindent\\textbf{CODE\\_CAP}\n\\begin{verbatim}\nCODE_VAL = 40 + 2\n" *
        "# => \n42\n\\end{verbatim}\n",
        tex,
    )
    # a comment, its author in bold
    @test occursin("\n\\item \\textbf{me} P1\\_NOTE\n", tex)
    # each part opens with its own heading, the second one too
    @test occursin("\\part{Part A}\\label{a}\n\\section{P1}\\label{p1}\n", tex)
    @test occursin("\\part{Part B}\\label{b}\n\\section{P2}\\label{p2}\n", tex)
    # a render that records no diagnostic removes the sidecar an earlier render left
    # the stand-in compiler is a POSIX shell script, so only there is this render free of diagnostics
    Sys.iswindows() || @test !isfile(joinpath(out, "diagnostics.md"))
end

# The check table of the section titled `title` in a gallery page: from its verdict band to the end of
# its table.
function _r4_checkset(html, title)
    i = findfirst(">$(title)   ", html)
    j = findnext("</tbody></table></div>", html, last(i))
    return html[first(i):last(j)]
end
_r4_rows(t, cls) = count("<tr class=\"$(cls)\">", t)

@testset "gallery: the check table's row cap, its summary row, and its cells" begin
    tmp = mktempdir()
    Pinax.reset!(; title="T")
    line = @__LINE__
    @testset _R4Iso "iso" begin
        @page :p "P" begin
            @section :big "Big" begin             # over the cap: failures first, then the count
                for i in 1:250
                    @test i < 0
                end
                for i in 1:100
                    @test i > 0
                end
            end
            @section :edge "Edge" begin           # exactly at the cap: every row, as written
                @test true
                for i in 1:199
                    @test i < 0
                end
            end
            @section :room "Room" begin           # few failures: the passes fill the room left
                for i in 1:10
                    @test i < 0
                end
                for i in 1:240
                    @test i > 0
                end
            end
            @section :cells "Cells" begin
                @test isapprox(2.0, 1.5; rtol=0.5)
                @test 1 + 1 == 2
            end
        end
    end
    at(n) = "test/test_r4_faces.jl:$(line + n)"
    html = read(Pinax.render(; out=tmp, theme=:gallery), String)

    big = _r4_checkset(html, "Big")
    @test _r4_rows(big, "pinax-fail") == 200 && _r4_rows(big, "pinax-pass") == 0
    @test occursin(
        "<tr class=\"pinax-more\"><td></td><td></td><td colspan=\"4\">… 50 failing + 100 passing " *
        "more not shown (all 350 checks are in <code>agent.json</code>)</td></tr>",
        big,
    )

    edge = _r4_checkset(html, "Edge")
    @test _r4_rows(edge, "pinax-fail") == 199 && _r4_rows(edge, "pinax-pass") == 1
    @test !occursin("pinax-more", edge)
    # in declaration order: the passing check, written first, is the first row
    @test occursin("<tbody>\n<tr class=\"pinax-pass\">", edge)

    room = _r4_checkset(html, "Room")
    @test _r4_rows(room, "pinax-fail") == 10 && _r4_rows(room, "pinax-pass") == 190
    @test occursin(
        "<td colspan=\"4\">… 50 passing more not shown (all 250 checks are in", room
    )

    cells = _r4_checkset(html, "Cells")
    c_rel, c_ind = Pinax.current_document().pages[1].sections[4].checks
    # the label cell ends with where the @test was written; a numeric check's last cell names its
    # kind; an indicator has a dash in each number cell
    @test occursin(
        "<td>$(c_rel.id)</td><td>isapprox(2.0, 1.5; rtol = 0.5) " *
        "<span class=\"pinax-src\">@ $(at(26))</span>",
        cells,
    )
    @test occursin("<td>2.0</td><td>1.5</td><td>0.25 vs 0.5 (rel)</td></tr>", cells)
    @test occursin(
        "<td>$(c_ind.id)</td><td>1 + 1 == 2 <span class=\"pinax-src\">@ $(at(27))</span>",
        cells,
    )
    @test occursin("<td>—</td><td>—</td><td>— (pass/fail only)</td></tr>", cells)
end
