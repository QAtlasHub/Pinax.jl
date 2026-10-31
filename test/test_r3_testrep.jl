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

    @testset "Pinax.test(file) is the one capture: a suite's install_test_capture! declines" begin
        # Pinax.test(file) sets PINAX_TEST_OUT, so a runtests.jl carrying the install line asks for a
        # capture while one is already open: it must decline, or a second root takes every assertion
        # (and, where the stack can be pushed, leaks past the call with no report written).
        dir = mktempdir()
        suite = joinpath(dir, "runtests.jl")
        write(
            suite,
            """
            using Pinax, Test
            println("INSTALLED=", Pinax.install_test_capture!())
            @testset "test_once.jl" begin
                @test 1 == 1
            end
            """,
        )
        out = joinpath(dir, "rep")
        script = joinpath(dir, "run.jl")
        write(
            script,
            """
            using Pinax, Test
            Pinax.test($(repr(suite)); out=$(repr(out)))
            println("REPORT=", isfile(joinpath($(repr(out)), "agent", "agent.json")))
            println("AFTER=", Pinax._CAPTURE_INSTALLED[])
            """,
        )
        log = tempname()
        cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(Base.active_project())) $script`
        ok = success(run(pipeline(ignorestatus(cmd); stdout=log, stderr=log)))
        txt = read(log, String)
        @test ok
        @test occursin("INSTALLED=false", txt)     # declined: the open capture is Pinax.test's
        @test !occursin("no report is produced", txt)   # …and not for a reason that is untrue here
        @test occursin("REPORT=true", txt)         # written when the call returns
        @test occursin("AFTER=false", txt)         # and the call leaves no capture open behind it
        @test occursin("1/1 PASS", read(joinpath(out, "agent", "agent.md"), String))
    end

    @testset "a @caption after @test_broken in a test names nothing, as in a page" begin
        root = R3Ext.PinaxTestSet("Test report")
        R3Ext._with_testset(root) do
            @testset "test_broken.jl" begin
                @test 1 == 1
                @test_broken 1 == 2
                @caption "RELABELED"
            end
        end
        node = only(root.node.children)
        @test node.nbroken == 1
        # the earlier check keeps its label; the @caption is an error where it is written
        @test node.checks[1].label == "1 == 1"
        @test node.checks[1].outcome === :pass
        @test [c.outcome for c in node.checks[2:end]] == [:error]
        @test !any(c -> c.label == "RELABELED", node.checks)
    end

    @testset "a red suite exits nonzero even when its report cannot be written" begin
        dir = mktempdir()
        blocker = joinpath(dir, "not-a-dir")
        write(blocker, "")   # `out` under a file: the render throws
        script = joinpath(dir, "run.jl")
        write(
            script,
            """
            using Pinax, Test
            Ext = Base.get_extension(Pinax, :PinaxTestExt)
            root = Ext.PinaxTestSet("T"; out=$(repr(joinpath(blocker, "rep"))))
            bad = Pinax.Check(:t, "c", 2.0, 1.0, 1.0, 0.5, :abs, :fail)
            push!(root.node.children, Pinax.TestNode("test_red.jl"; checks=[bad]))
            atexit(() -> Ext._finalize_test_capture!(root))
            """,
        )
        cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(Base.active_project())) $script`
        log = tempname()
        p = run(pipeline(ignorestatus(cmd); stdout=log, stderr=log))
        @test p.exitcode != 0
        @test occursin("could not be written", read(log, String))   # and says why
    end

    @testset "a sweep with no checks still places its code and names what it omits" begin
        root = R3Ext.PinaxTestSet("Test report")
        R3Ext._with_testset(root) do
            @testset "test_nochecks.jl" begin
                @testset for chi in (8, 16)
                    @desc md"SWEEP_ONLY_PROSE"
                    @code sweep_marker = chi + 1
                end
            end
        end
        render_test_report(root.node; out=joinpath(mktempdir(), "rep"))
        doc = Pinax.current_document()
        page = only(p for p in doc.pages if p.title == "test_nochecks.jl")
        # the code its samples ran is the sweep's specification, lifted as with checks
        @test any(c -> occursin("sweep_marker", c.source), page.codes)
        # what the sweep cannot place is named, never dropped silently
        @test any(d -> occursin("@desc", d.message), doc.diag.entries)
    end
end
