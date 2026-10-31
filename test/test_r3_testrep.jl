using Pinax
using Pinax: Check, TestNode, render_test_report
using Test

const R3Ext = Base.get_extension(Pinax, :PinaxTestExt)

@testset "test report: review fixes (r3-testrep)" begin
    @testset "a long label is cut at a character, never inside one" begin
        # "a" then 60 χ: every χ is two bytes, so byte 107 (and byte 31) falls inside one
        long = "a" * "χ"^60
        root = R3Ext.PinaxTestSet("Test report")
        R3Ext._with_testset(root) do
            @testset "test_label.jl" begin
                # `length("` is 8 bytes, so the literal's χ start at even bytes: 107 is inside one
                @eval @test length($("a" * "χ"^100)) > 0
                @test true
            end
        end
        node = only(root.node.children)
        # the passing test stays a pass, and the testset is not cut short by it
        @test [c.outcome for c in node.checks] == [:pass, :pass]
        @test endswith(node.checks[1].label, "…")

        # the margin figure cuts its bar labels the same way
        svg = Pinax._margin_svg(
            [Check(:t, long, 1.0, 1.0, 0.0, 0.5, :abs, :pass)], tempname() * ".svg"
        )
        @test occursin("…", read(svg, String))

        # code indented with a multi-byte space is dedented by characters
        @test Pinax._dedent(["　　x = 1", "　　y = χ"]) == "x = 1\ny = χ"
    end

    @testset "in a matrix report the cell is part of every node's identity" begin
        dir = mktempdir()
        # one file, as every cell runs it: a table its author named `:summary`, a generated prose
        # block, a check and its code
        cellroot() = TestNode(
            "root";
            children=[
                TestNode(
                    "test_m.jl";
                    checks=[Check(:t, "c", 1.0, 1.0, 0.0, 0.5, :abs, :pass)],
                    tables=[
                        Pinax.Table(
                            :summary, "summary", "", ["a"], [Any[1]], "", nothing, ""
                        ),
                    ],
                    texts=[Pinax.Prose(:test_m_jl_txt, "test_m_jl_txt", "P", "")],
                    content=[:text => 1, :table => 1, :check => 1],
                    written=Set([:summary]),
                ),
            ],
        )
        ids() = Set(n.id for n in Pinax.node_ids(Pinax.current_document()))

        # the author's id is qualified by the cell, in each cell — never a duplicate across cells
        cells = ["julia 1.11", "julia 1.12"]
        Pinax._render_matrix(
            [cellroot(), cellroot()], cells; out=joinpath(dir, "a"), title="M"
        )
        @test issubset([:julia_1_11_summary, :julia_1_12_summary], ids())
        @test issubset([:julia_1_11_test_m_jl_txt, :julia_1_12_test_m_jl_txt], ids())
        @test allunique(n.id for n in Pinax.node_ids(Pinax.current_document()))

        # two labels that slug alike are two cells: generated ids, so `-2`, never an error
        alike = ["julia 1.11 / linux", "julia-1.11 linux"]
        Pinax._render_matrix(
            [cellroot(), cellroot()], alike; out=joinpath(dir, "b"), title="M"
        )
        doc = Pinax.current_document()
        @test [first(p) for p in doc.parts] == [:cell_julia_1_11_linux, Symbol("cell_julia_1_11_linux-2")]
        @test issubset(
            [:julia_1_11_linux_summary, Symbol("julia_1_11_linux-2_summary")], ids()
        )
        @test allunique(n.id for n in Pinax.node_ids(doc))
        # each cell's pages sit in its own part
        @test count(pg -> pg.part === :cell_julia_1_11_linux, doc.pages) == 1
    end
end
