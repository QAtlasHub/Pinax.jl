using Pinax
using Test
using JSON: JSON

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

@testset "agent.json: a number JSON cannot write bare is a string" begin
    tmp = mktempdir()
    Pinax.reset!(; title="T")
    @page :p "P" begin
        @table [(1 // 3, π, Float32(0.5), Float32(1.0e10), 2, 0.25)] header = [
            "q", "pi", "f32", "f32e", "int", "f64"
        ]
    end
    Pinax.render(; out=joinpath(tmp, "a"), theme=:agent)
    aj = read(joinpath(tmp, "a", "agent.json"), String)
    doc = JSON.parse(aj)                                   # parses at all
    row = doc["pages"][1]["tables"][1]["rows"][1]
    @test row[1] == "1//3"                                 # a Rational: its Julia form, quoted
    @test row[2] == "π"                                    # an Irrational: likewise
    @test row[3] == 0.5                                    # a Float32 is still a number…
    @test row[4] == 1.0e10                                 # …with no `f0` suffix
    @test row[5] == 2
    @test row[6] == 0.25
    # the human faces show the same text for the cells agent.json quotes
    g = read(Pinax.render(; out=joinpath(tmp, "g"), theme=:gallery), String)
    @test occursin("<td>1//3</td>", g) && occursin("<td>π</td>", g)
    lx = read(Pinax.render(; out=joinpath(tmp, "l"), theme=:latex), String)
    @test occursin("1//3 & π", lx)
end

@testset "agent.json: every float is written as a JSON number" begin
    for v in (Float32(0.5), Float32(1.0e10), Float16(0.5), 0.1, big"1.5", -0.0)
        @test JSON.parse(Pinax._agent_jsonval(v)) == v
    end
    @test Pinax._agent_jsonval(NaN) == "\"NaN\""          # not a JSON number: quoted
    @test Pinax._agent_jsonval(1 // 3) == "\"1//3\""
end
