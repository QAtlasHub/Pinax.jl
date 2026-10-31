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

    @testset "the 1/0 indicator is a field, not a magic (abs, 0.5, 1.0) triple" begin
        ind = Pinax._check_from(nothing, "x < 1", true, 1)                   # not an isapprox
        apx = Pinax._check_from(:(isapprox(1.4, 1.0; atol=0.5)), "apx", true, 2)
        @test ind.indicator
        @test !apx.indicator
        @test (apx.kind, apx.tol, apx.want) == (:abs, 0.5, 1.0)  # the triple the old heuristic matched
        node = TestNode("f.jl"; checks=[apx, ind])
        @test Pinax._worst_margin(node) ≈ 0.8                   # the isapprox check counts; the indicator not
        # …and the field survives a shard dump
        p = joinpath(tmp, "dump.toml")
        Pinax.dump_test_report(TestNode("root"; children=[node]), p)
        back = Pinax._dict_to_node(only(Pinax.TOML.parsefile(p)["root"]["child"]))
        @test [c.indicator for c in back.checks] == [false, true]
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
