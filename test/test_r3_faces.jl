using Pinax
using Test

# Round-3 review findings on the faces: each testset pins one finding.

# agent.md's table rows, split into cells the way a Markdown reader splits them: on a `|` that is
# not escaped.
function _md_table_rows(md)
    rows = [l for l in split(md, '\n') if startswith(l, "|") && !startswith(l, "| ---")]
    return [strip.(split(chopsuffix(chopprefix(r, "|"), "|"), r"(?<!\\)\|")) for r in rows]
end

@testset "agent.md: a `|` or a newline in a table cell stays in its cell" begin
    tmp = mktempdir()
    Pinax.reset!(; title="T")
    @page :p "P" begin
        @table [("x|y", "|0⟩"), ("two\nlines", "plain")] header = ["a|b", "state"]
    end
    Pinax.render(; out=tmp, theme=:agent)
    md = read(joinpath(tmp, "agent.md"), String)
    rows = _md_table_rows(md)
    @test length(rows) == 3                            # header + two rows; the separator is `|---`
    @test all(r -> length(r) == 2, rows)               # every row has the table's two columns
    @test rows[1] == ["a\\|b", "state"]
    @test rows[2] == ["x\\|y", "\\|0⟩"]
    @test rows[3] == ["two<br>lines", "plain"]         # the row stays on one line
end

@testset "agent.md: a page after a part's pages is not read as inside it" begin
    tmp = mktempdir()
    Pinax.reset!(; title="T")
    @page :intro "Intro" begin end
    @part :a "Part A" begin
        @page :inpart "In part" begin end
    end
    @page :after "After" begin end
    Pinax.render(; out=tmp, theme=:agent)
    md = read(joinpath(tmp, "agent.md"), String)
    heads = [l for l in split(md, '\n') if startswith(l, "## ") || startswith(l, "### ")]
    @test heads == [
        "### Intro  [id: intro]",          # before any part: no part heading is needed
        "## Part A",
        "### In part  [id: inpart]",
        "## Other  [no part]",             # the part ended: a part-level heading says so
        "### After  [id: after]",
    ]
    # agent.json already says so; the two faces agree
    aj = read(joinpath(tmp, "agent.json"), String)
    @test occursin("\"id\":\"after\",\"title\":\"After\",\"depth\":1,\"part\":null", aj)
end
