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

# The HTML attribute values a browser would read: `name="…"` with the entities decoded.
function _attr_values(html, name)
    unesc(s) = replace(s, "&quot;" => "\"", "&lt;" => "<", "&gt;" => ">", "&amp;" => "&")
    return [unesc(m.captures[1]) for m in eachmatch(Regex("$(name)=\"([^\"]*)\""), html)]
end

@testset "contents: a tag with a space filters as one tag" begin
    entries = [
        (; title="A", href="a/index.html", tags=["spin chain", "x"]),
        (; title="B", href="b/index.html", tags=["spin"]),
        (; title="C", href="c/index.html", tags=["chain"]),
    ]
    html = read(Pinax.contents(entries; out=mktempdir()), String)
    # each card's tags, as the filter reads them: one JSON array, every tag whole
    @test [JSON.parse(v) for v in _attr_values(html, "data-tags")] == [["spin chain", "x"], ["spin"], ["chain"]]
    # clicking a chip, in the page's own script (run under node with a minimal DOM)
    node = Sys.which("node")
    if node !== nothing
        script = match(r"<script>(\(function\(\)\{var bar=.*?)</script>"s, html).captures[1]
        driver = """
        const tags = $(JSON.json(_attr_values(html, "data-tags")));
        const cards = tags.map(t => ({ style: {}, getAttribute: () => t }));
        const chip = t => ({ getAttribute: () => t, closest: function () { return this; },
                             classList: { toggle() {} } });
        let onclick;
        const bar = { addEventListener: (_, f) => { onclick = f; },
                      querySelectorAll: () => [] };
        globalThis.document = { getElementById: () => bar, querySelectorAll: () => cards };
        $(script)
        const shown = t => { onclick({ target: chip(t) });
                             return cards.map(c => c.style.display !== 'none'); };
        console.log(JSON.stringify([shown('spin chain'), shown('spin'), shown('')]));
        """
        got = JSON.parse(read(`$(node) -e $(driver)`, String))
        @test got == [[true, false, false], [false, true, false], [true, true, true]]
    end
end

@testset "a markdown fallback is recorded, never silent" begin
    # the one place a face falls back from markdown to escaped text says so in its diagnostics
    rdiag = Pinax.DiagEntry[]
    out = Pinax._render_markdown(s -> error("boom"), Pinax._esc, "<b>x", "node", rdiag)
    @test out == "&lt;b&gt;x"
    @test only(rdiag).item == "node" &&
        occursin("markdown render failed", only(rdiag).message)
    @test occursin("boom", only(rdiag).message)
    @test Pinax._render_markdown(identity, Pinax._esc, "<b>", "node", rdiag) == "<b>"
    @test length(rdiag) == 1                                # a render that works records nothing

    # LaTeX, for real: the Markdown stdlib has no LaTeX form for a lone `$x` (it parses as an
    # interpolation), so the prose falls back to escaped text and the diagnostics name it
    tmp = mktempdir()
    Pinax.reset!(; title="T")
    @page :p "P" begin
        @desc "costs \$x here"
    end
    tex = read(Pinax.render(; out=tmp, theme=:latex), String)
    @test occursin("costs \\\$x here", tex)                  # escaped text, `$` included
    diag = read(joinpath(tmp, "diagnostics.md"), String)
    @test occursin(r"`p_txt_\w+` — markdown render failed", diag)
end

# A testset that keeps the results of the document's own checks, so a failing check is data here.
mutable struct _R3Iso <: Test.AbstractTestSet
    description::String
    results::Vector{Any}
    _R3Iso(desc::AbstractString=""; kw...) = new(String(desc), Any[])
end
Test.record(r::_R3Iso, x) = (push!(r.results, x); x)
Test.finish(r::_R3Iso) = r

@testset "pins for the face refactors: numbers, figure paths, verdict band, refs" begin
    tmp = mktempdir()
    svg = joinpath(tmp, "a.svg")
    write(svg, "<svg xmlns='http://www.w3.org/2000/svg'/>")
    nb(kind, c) = string(
        kind,
        " ",
        join((c.page, c.part, c.section, c.figure, c.subfigure, c.equation), "."),
        " ",
        c.page_id,
    )
    Pinax.reset!(; title="T", numberer=nb)
    @part :a "A" begin
        @testset _R3Iso "iso" begin
            @page :p "P" begin
                @figure svg id = :pf caption = "\$\$x\$\$"
                @test 1 == 2
                @section :s "S" begin
                    @figure svg id = :sf
                    @desc "\$\$ y \$\$ and \$\$ z \$\$"
                    @section :t "T" begin
                        @test 2 == 3
                        @figure svg id = :tf
                    end
                    @figure svg id = :sf2
                end
            end
        end
    end
    @page :q "Q" begin
        @thumbnail :qf
        @figure svg id = :qf
    end
    doc = Pinax.current_document()

    # numbering, in reading order: page.part.section.figure.subfigure.equation
    nums = Pinax._gallery_numbers(doc)[1]
    txt = only(
        unique(first(split(k, "_eq")) for k in keys(nums) if startswith(k, "s_txt_"))
    )
    @test nums == Dict(
        "p" => "page 1.1.0.0.0.0 p",
        "pf" => "figure 1.1.0.1.1.0 p",
        "pf_eq1" => "equation 1.1.0.1.1.1 p",
        "s" => "section 1.1.1.1.0.1 p",
        "sf" => "figure 1.1.1.2.1.1 p",
        "$(txt)_eq1" => "equation 1.1.1.2.0.2 p",
        "$(txt)_eq2" => "equation 1.1.1.2.0.3 p",
        "t" => "section 1.1.2.2.0.3 p",
        "tf" => "figure 1.1.2.3.1.3 p",
        "sf2" => "figure 1.1.2.4.2.3 p",     # after its nested section's figure, in reading order
        "q" => "page 2.0.2.4.0.3 q",
        "qf" => "figure 2.0.2.5.1.3 q",
    )

    # resolve: every page, section and figure by id; an authored thumbnail found on its page
    Pinax.resolve!(doc)
    @test Set(keys(doc.refs)) == Set([:p, :s, :t, :pf, :sf, :tf, :sf2, :q, :qf])

    # where each face writes a figure: gallery and agent under assets/, LaTeX without it; a nested
    # section's figures under its page, by its own anchor
    rendered(theme, dir) =
        try
            Pinax.render(; out=joinpath(tmp, dir), theme=theme)
        catch e
            e isa Pinax.ChecksFailed || rethrow()
        end
    for (theme, dir, root) in
        ((:gallery, "g", "assets"), (:agent, "a", "assets"), (:latex, "l", ""))
        rendered(theme, dir)
        figs = joinpath(tmp, dir, root, "figures")
        @test isfile(joinpath(figs, "p", "pf.svg"))
        @test isfile(joinpath(figs, "p", "s", "sf.svg"))
        @test isfile(joinpath(figs, "p", "t", "tf.svg"))
        @test isfile(joinpath(figs, "q", "qf.svg"))
    end

    # agent.md's band on the page names every failing check of its subtree, in order
    md = read(joinpath(tmp, "a", "agent.md"), String)
    pg = doc.pages[1]
    ids = [string(c.id) for c in (pg.checks[1], pg.sections[1].sections[1].checks[1])]
    @test occursin("**P   0/2 FAIL** — failing: $(join(ids, ", "))", md)
    @test occursin("**T   0/1 FAIL** — failing: $(ids[2])", md)
end
