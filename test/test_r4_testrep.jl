using Pinax
using Pinax: Check, TestNode, render_test_report
using Test
using JSON
using TestShards: TestShards

const R4Ext = Base.get_extension(Pinax, :PinaxTestExt)

# The page of a rendered report's agent.json with id `id`.
_r4_page(aj, id) = only(p for p in aj["pages"] if p["id"] == id)
_r4_agent(out) = JSON.parsefile(joinpath(out, "agent", "agent.json"))

# Every content node of a container, sections at any depth included, as (kind, node).
function _r4_nodes(c, out=Tuple{Symbol,Any}[])
    for (k, node) in Pinax._content_items(c)
        node isa Pinax.Section ? _r4_nodes(node, out) : push!(out, (k, node))
    end
    return out
end

@testset "test report: review fixes (r4-testrep)" begin
    @testset "the per-file profile counts every outcome, once per file" begin
        ok(l, m) = Check(:t, l, 1.0, 1.0, m, 1.0, :abs, :pass)   # spends `m` of its tolerance
        bad(l) = Check(:t, l, NaN, NaN, NaN, NaN, :indicator, :fail)
        err(l) = Check(:t, l, NaN, NaN, NaN, NaN, :indicator, :error)
        root = TestNode(
            "root";
            children=[
                # a pass, a fail, an error and a broken test, and its worst margin in a child
                TestNode(
                    "test_a.jl";
                    elapsed=1.23456,
                    nbroken=1,
                    checks=[ok("a1", 0.3), bad("a2"), err("a3")],
                    children=[TestNode("inner"; checks=[ok("i1", 0.81234)])],
                ),
                # a grouping wrapper: its file is a row of its own, the wrapper is none
                TestNode("group"; children=[TestNode("test_b.jl"; checks=[ok("b1", 0.1)])]),
                # an ignored file is no row
                TestNode("test_ign.jl"; ignore=true, checks=[ok("g1", 0.2)]),
            ],
        )
        out = joinpath(mktempdir(), "rep")
        render_test_report(root; out=out)
        ov = _r4_page(_r4_agent(out), "overview")
        t = only(t for t in ov["tables"] if t["id"] == "per_file")
        @test t["header"] ==
            ["file", "tests", "passed", "failed", "errored", "seconds", "worst_margin"]
        # 5 tests: 2 passed, 1 failed, 1 errored, 1 broken; the worst margin is the child's,
        # rounded; a file never timed has no seconds
        @test t["rows"] == [
            ["test_a.jl", 5, 2, 1, 1, 1.23, 0.812], ["test_b.jl", 1, 1, 0, 0, nothing, 0.1]
        ]
    end

    @testset "a generated id that steps aside takes the anchor that follows it" begin
        # Two sections of one name, each with the same @desc: the captured prose ids coincide, so
        # the fold places the second under `-2` — and its anchor must be that id's, not the first's.
        root = R4Ext.PinaxTestSet("Test report")
        R4Ext._with_testset(root) do
            @testset "test_dup.jl" begin
                @testset "same" begin
                    @desc md"SAME_PROSE"
                    @test true
                end
                @testset "same" begin
                    @desc md"SAME_PROSE"
                    @test true
                end
            end
        end
        render_test_report(root.node; out=joinpath(mktempdir(), "rep"))
        doc = Pinax.current_document()
        texts = [n for pg in doc.pages for (k, n) in _r4_nodes(pg) if k === :text]
        @test length(texts) == 2
        @test !allunique(n.id for n in only(root.node.children).children for n in n.texts)
        @test allunique(n.id for n in texts)
        @test all(n.anchor == Pinax._anchor(n.id) for n in texts)
        @test allunique(n.anchor for n in texts)
    end

    @testset "a shard root's own prose and table survive the merge, with its drops and ids" begin
        dir = mktempdir()
        root = R4Ext.PinaxTestSet("Test report")
        R4Ext._with_testset(root) do
            @desc md"ROOT_PROSE"
            @table (; a=[1, 2]) id = :root_tab
            @figure "x.svg"          # cannot cross a dump: recorded as dropped in the root
            @testset "test_f.jl" begin
                @test true
            end
        end
        other = TestNode(
            "Test report";
            children=[
                TestNode(
                    "test_g.jl"; checks=[Check(:t, "g", 1.0, 1.0, 0.0, 0.5, :abs, true)]
                ),
            ],
        )
        dumps = [
            (@test_logs (:warn, r"cannot cross a shard dump") Pinax.dump_test_report(
                root.node, joinpath(dir, "s1.toml")
            )),
            Pinax.dump_test_report(other, joinpath(dir, "s2.toml")),
        ]
        out = joinpath(dir, "rep")
        render_test_report(dumps; out=out, title="Merged")
        doc = Pinax.current_document()
        # the root's prose-and-table, with no check of its own, still gets a page
        @test [pg.id for pg in doc.pages] == [:overview, :merged, :test_f_jl, :test_g_jl]
        merged = _r4_page(_r4_agent(out), "merged")
        @test [t["text"] for t in merged["texts"]] == ["ROOT_PROSE"]
        @test [t["rows"] for t in merged["tables"]] == [[[1], [2]]]
        # the figure it dropped is stated in the merged document
        @test any(
            e ->
                occursin("cannot cross a shard dump", e.message) &&
                occursin("@figure", e.message),
            doc.diag.entries,
        )
        # `root_tab` was written by its author, and stays so in the merged document
        ids = Pinax.node_ids(doc)
        @test only(n for n in ids if n.id === :root_tab).generated == false
    end

end
