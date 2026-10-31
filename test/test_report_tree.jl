using Pinax
using Test
using Pinax: TestNode, Check

# The test-report fold (#130): nested testsets keep their depth, the 1/0 indicator is a field (not a
# magic triple), folding never mutates the tree it reads, and a sweep's reference line and tolerance
# band belong to each legend series rather than to whichever series was folded last.

function _ok(label; got=1.0, want=1.0)
    return Check(:t, label, got, want, abs(got - want), 0.5, :abs, true)
end
_report_page(title) = only(p for p in Pinax.current_document().pages if p.title == title)

# Absorbs the results a document records, so a deliberate error does not count in this suite.
mutable struct _TreeIso <: Test.AbstractTestSet
    description::String
    results::Vector{Any}
    _TreeIso(desc::AbstractString=""; kw...) = new(String(desc), Any[])
end
Test.record(r::_TreeIso, x) = (push!(r.results, x); x)
Test.finish(r::_TreeIso) = r

@testset "test-report tree (#130)" begin
    tmp = mktempdir()

    @testset "nested testsets stay nested, to any depth" begin
        tree = TestNode(
            "root";
            children=[
                TestNode(
                    "test_x.jl";
                    children=[
                        TestNode(
                            "a";
                            children=[
                                TestNode(
                                    "b"; children=[TestNode("c"; checks=[_ok("deep")])]
                                ),
                            ],
                        ),
                    ],
                ),
            ],
        )
        Pinax.render_test_report(tree; out=joinpath(tmp, "depth"))
        pg = _report_page("test_x.jl")
        a = only(pg.sections)
        b = only(a.sections)
        c = only(b.sections)
        @test (a.title, b.title, c.title) == ("a", "b", "c")
        @test (a.depth, b.depth, c.depth) == (2, 3, 4)
        @test length(c.checks) == 1
    end

    @testset "folding does not mutate the tree, so it is idempotent" begin
        chk = _ok("x")
        chk.id = :orig
        tree = TestNode("root"; children=[TestNode("test_y.jl"; checks=[chk])])
        Pinax.render_test_report(tree; out=joinpath(tmp, "i1"))
        ids1 = [c.id for c in Pinax._subtree_checks(_report_page("test_y.jl"))]
        @test chk.id === :orig            # the tree's own Check is untouched…
        @test !chk.reported               # …including the reported flag set on the document's copy
        Pinax.render_test_report(tree; out=joinpath(tmp, "i2"))
        ids2 = [c.id for c in Pinax._subtree_checks(_report_page("test_y.jl"))]
        @test ids1 == ids2
    end

    @testset "an indicator is a kind with no numbers, not a magic (abs, 0.5, 1.0) triple" begin
        ind = Pinax._check_from(nothing, "x < 1", true, 1)                   # not an isapprox
        apx = Pinax._check_from(:(isapprox(1.4, 1.0; atol=0.5)), "apx", true, 2)
        @test ind.kind === :indicator
        @test all(isnan, (ind.got, ind.want, ind.delta, ind.tol))   # nothing was measured
        @test Pinax._margin(ind) === nothing
        @test (apx.kind, apx.tol, apx.want) == (:abs, 0.5, 1.0)  # the triple the old heuristic matched
        node = TestNode("f.jl"; checks=[apx, ind])
        @test Pinax._worst_margin(node) ≈ 0.8                   # the isapprox check counts; the indicator not
        # …and the kind survives a shard dump, still without numbers
        p = joinpath(tmp, "dump.toml")
        Pinax.dump_test_report(TestNode("root"; children=[node]), p)
        back = Pinax._dict_to_node(only(Pinax.TOML.parsefile(p)["root"]["child"]))
        @test [c.kind for c in back.checks] == [:abs, :indicator]
        @test isnan(back.checks[2].got)
        # an older dump flagged it `indicator = true` beside made-up numbers
        old = Dict{String,Any}(
            "label" => "x < 1",
            "got" => 1.0,
            "want" => 1.0,
            "delta" => 0.0,
            "tol" => 0.5,
            "kind" => "abs",
            "pass" => true,
            "indicator" => true,
        )
        o = Pinax._dict_to_check(old)
        @test o.kind === :indicator && isnan(o.got)
    end

    @testset "a check's kind is abs, rel or indicator, and only an indicator lacks numbers" begin
        @test_throws r"kind :auto" Check(:t, "x", 1.0, 1.0, 0.0, 0.5, :auto, true)
        @test_throws r"indicator" Check(:t, "x", 1.0, 1.0, 0.0, 0.5, :indicator, true)
        @test_throws r"abs" Check(:t, "x", NaN, 1.0, NaN, 0.5, :abs, true)
        @test Check(:t, "x", NaN, NaN, NaN, NaN, :indicator, true).kind === :indicator
        bad = Dict{String,Any}(
            "label" => "x", "got" => 1.0, "want" => 1.0, "delta" => 0.0, "tol" => 0.5
        )
        @test_throws r"kind \"auto\"" Pinax._dict_to_check(
            merge(bad, Dict("kind" => "auto", "pass" => true))
        )
    end

    # One outcome per check, so failed and errored counts are read from the checks themselves and
    # can never disagree with them (or go negative on a hand-built or merged node).
    @testset "a check's outcome is pass, fail or error, and the counts come from it" begin
        @test_throws r"outcome :maybe" Check(:t, "x", 1.0, 1.0, 0.0, 0.5, :abs, :maybe)
        @test_throws r":error check has no numbers" Check(
            :t, "x", 1.0, 1.0, 0.0, 0.5, :abs, :error
        )
        e = Check(:t, "boom", NaN, NaN, NaN, NaN, :indicator, :error)
        @test e.outcome === :error && !Pinax.passed(e)
        @test Check(:t, "x", 1.0, 1.0, 0.0, 0.5, :abs, true).outcome === :pass
        @test Check(:t, "x", 1.0, 1.0, 0.0, 0.5, :abs, false).outcome === :fail
        node = TestNode("f.jl"; checks=[e, _ok("a")])
        @test (Pinax._nfail(node), Pinax._nerror(node)) == (0, 1)
        @test startswith(Pinax._summary_line(node), "1/2 passed · 1 errored")
        # a dump carries the outcome; an older one wrote `pass`
        p = joinpath(tmp, "outcome.toml")
        Pinax.dump_test_report(TestNode("root"; children=[node]), p)
        back = Pinax.load_test_dump(p)
        @test [c.outcome for c in only(back.children).checks] == [:error, :pass]
        old = Dict{String,Any}(
            "label" => "x",
            "got" => 2.0,
            "want" => 1.0,
            "delta" => 1.0,
            "tol" => 0.5,
            "kind" => "abs",
            "pass" => false,
        )
        @test Pinax._dict_to_check(old).outcome === :fail
        @test_throws r"outcome \"maybe\"" Pinax._dict_to_check(
            merge(old, Dict("outcome" => "maybe"))
        )
    end

    @testset "a @test that throws is an error check, in every face" begin
        Pinax.reset!()
        @testset _TreeIso "iso" begin
            @page :p "P" begin
                @test error("boom")
            end
        end
        chk = only(only(Pinax.current_document().pages).checks)
        @test chk.outcome === :error && chk.kind === :indicator
        out = joinpath(tmp, "err")
        Pinax.render(; out=out, theme=:agent)
        aj = read(joinpath(out, "agent.json"), String)
        @test occursin("\"kind\":\"indicator\",\"outcome\":\"error\",\"pass\":false", aj)
        @test occursin(
            r"- \[ERROR\] \S+ — error\(\"boom\"\)", read(joinpath(out, "agent.md"), String)
        )
        Pinax.render(; out=joinpath(tmp, "errtex"), theme=:latex)
        tex = read(
            only(filter(endswith(".tex"), readdir(joinpath(tmp, "errtex"); join=true))),
            String,
        )
        @test occursin("ERROR \\\\", tex)
    end

    # An indicator has no margin, so nothing drawn from margins shows it: not the page's margin
    # figure or its data, and not a sweep's figures. It still counts in the verdict.
    @testset "every margin consumer skips an indicator" begin
        ind(label, pass) = Check(:t, label, NaN, NaN, NaN, NaN, :indicator, pass)
        sample(L) = TestNode("L = $(L)"; checks=[ind("flag", L < 8), _ok("E")])
        tree = TestNode(
            "root";
            children=[
                TestNode("test_ind.jl"; checks=[ind("only a flag", false)]),
                TestNode(
                    "test_mix.jl";
                    checks=[ind("a flag", true), _ok("num"; got=1.2)],
                    children=[TestNode("sweep"; children=[sample(4), sample(8)])],
                ),
            ],
        )
        out = joinpath(tmp, "ind")
        Pinax.render_test_report(tree; out=out)   # a report states failures; it does not throw
        pg = _report_page("test_ind.jl")
        @test Pinax.verdict(pg).verdict == "FAIL"                 # counted in the verdict
        @test isempty(pg.figures)                                 # no margin to draw
        mix = _report_page("test_mix.jl")
        figs = vcat(mix.figures, (s.figures for s in Pinax._all_sections(mix))...)
        margin = only(f for f in mix.figures if endswith(string(f.id), "_margins"))
        @test margin.data.series[1].x == [2, 4, 6]                # by number on the page: no flags
        @test margin.data.series[1].y ≈ [0.4, 0.0, 0.0]
        @test !any(f -> occursin("flag", f.caption), figs)        # no sweep figure for the flag
        @test any(f -> occursin("_conv_", string(f.id)), figs)    # the numeric quantity keeps its own
        aj = read(joinpath(out, "agent", "agent.json"), String)
        @test occursin(
            "\"got\":null,\"want\":null,\"delta\":null,\"tol\":null,\"kind\":\"indicator\"",
            aj,
        )
        md = read(joinpath(out, "agent", "agent.md"), String)
        @test occursin(r"only a flag(?!: got)", md) && !occursin("got NaN", md)
        html = read(joinpath(out, "html", "test_ind_jl.html"), String)
        @test !occursin("NaN", html)
    end

    @testset "a sweep's reference and band belong to each series" begin
        sample(L, m, want) = TestNode(
            "m = $(m), L = $(L)";
            checks=[_ok("E"; got=want + 0.01, want=want)],   # x = L (innermost)
        )
        tree = TestNode(
            "root";
            children=[
                TestNode(
                    "test_sweep.jl";
                    children=[
                        TestNode(
                            "energy";
                            children=[
                                sample(4, "a", 1.0),
                                sample(8, "a", 1.0),
                                sample(4, "b", 2.0),
                                sample(8, "b", 2.0),
                            ],
                        ),
                    ],
                ),
            ],
        )
        Pinax.render_test_report(tree; out=joinpath(tmp, "sweep"))
        pg = _report_page("test_sweep.jl")
        figs = vcat(pg.figures, (s.figures for s in Pinax._all_sections(pg))...)
        conv = only(f for f in figs if occursin("_conv_", string(f.id)))
        # the data file holds what the plot draws: each series' values, reference and band
        y = Dict(s.label => s.y for s in conv.data.series)
        @test sort!(collect(keys(y))) ==
            sort!(["m = $m $f" for m in ("a", "b") for f in ("got", "want", "lo", "hi")])
        @test y["m = a want"] == [1.0, 1.0] && y["m = b want"] == [2.0, 2.0]
        @test y["m = b lo"] == [1.5, 1.5] && y["m = b hi"] == [2.5, 2.5]
        svg = read(conv.gen(), String)
        @test count("<polygon", svg) == 2          # one tolerance band per series, not the last one
    end
end
