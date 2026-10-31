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

    @testset "a dump is validated where it is read, each error naming its entry" begin
        blk = Pinax.CodeBlock(:code_v, "code_v", "x = 1", "", "", "julia")
        node = TestNode(
            "test_v.jl";
            checks=[Check(:t, "c", 1.0, 1.0, 0.0, 0.5, :abs, :pass, "", :code_v)],
            codes=[blk],
            tables=[Pinax.Table(:tv, "tv", "", ["a", "b"], [Any[1, 2]], "", nothing, "")],
            content=[:code => 1, :check => 1, :table => 1],
        )
        good() = Pinax._node_to_dict(node)
        load(d) = Pinax._dict_to_node(d, "v.toml")
        @test length(load(good()).tables) == 1   # the good dump reads back
        edit(f) = (d=good(); f(d); d)

        # a table cell's marker table is `missing` or `nothing`, nothing else
        @test_throws r"v\.toml.*table 1.*marker" load(
            edit(
                d -> d["table"][1]["rows"] = Any[Any[Dict{String,Any}("weird" => true), 2]]
            ),
        )
        # a table has its rows and its header, every row as wide as the header
        @test_throws r"v\.toml.*table 1 has no \"rows\"" load(
            edit(d -> delete!(d["table"][1], "rows"))
        )
        @test_throws r"v\.toml.*table 1 has no \"header\"" load(
            edit(d -> delete!(d["table"][1], "header"))
        )
        @test_throws r"v\.toml.*table 1.*row 1 has 1 cell" load(
            edit(d -> d["table"][1]["rows"][1] = Any[1])
        )
        # every node is placed by `content`, once
        @test_throws r"v\.toml.*table" load(edit(d -> pop!(d["content"])))
        @test_throws r"v\.toml.*check" load(
            edit(d -> push!(d["content"], Dict{String,Any}("kind" => "check", "i" => 1)))
        )
        # with no `content` (an older dump) only checks and code blocks have a place
        @test_throws r"v\.toml.*table" load(edit(d -> delete!(d, "content")))
        # a check's code reference names a code block of its own testset
        @test_throws r"v\.toml.*check 1.*code_nope" load(
            edit(d -> d["check"][1]["code_id"] = "code_nope")
        )
        # a missing key is named, never a bare KeyError
        for key in ("label", "kind")
            @test_throws Regex("v\\.toml.*check 1 has no \"$(key)\"") load(
                edit(d -> delete!(d["check"][1], key))
            )
        end
        @test_throws r"v\.toml.*check 1 has no \"outcome\"" load(
            edit(d -> delete!(d["check"][1], "outcome"))
        )
        @test_throws r"v\.toml.*check 1 has no \"tol\"" load(
            edit(d -> delete!(d["check"][1], "tol"))
        )
        @test_throws r"v\.toml.*content entry 1 has no \"i\"" load(
            edit(d -> delete!(d["content"][1], "i"))
        )
        @test_throws r"v\.toml.*has no \"description\"" load(
            edit(d -> delete!(d, "description"))
        )

        # the fold never leaves a check pointing at a code block it did not place
        Pinax.reset!()
        @page :p "P" begin end
        pg = Pinax.current_document().pages[1]
        @test_throws r"code_gone" Pinax._repoint_code!(
            pg, Check(:t, "c", 1.0, 1.0, 0.0, 0.5, :abs, :pass, "", :code_gone)
        )
    end

    @testset "a non-finite tolerance has no margin: an indicator, never tol = Inf" begin
        for e in (:(isapprox(1.0, 1.1; atol=Inf)), :(isapprox(1.0, 1.1; rtol=Inf)))
            c = Pinax._check_from(e, "x", :pass, 0)
            @test c.kind === :indicator
            @test occursin("no margin", c.label)
        end
        # a difference too large for a Float64 has no margin either
        @test Pinax._check_from(:(isapprox(1e308, -1e308; rtol=0.1)), "x", :fail, 0).kind ===
            :indicator
        # live: the check reaches agent.json with null numbers, not the string "Inf"
        root = R3Ext.PinaxTestSet("Test report")
        R3Ext._with_testset(root) do
            @testset "test_inf.jl" begin
                @test isapprox(1.0, 1.1; atol=Inf)
            end
        end
        @test only(only(root.node.children).checks).kind === :indicator
        out = joinpath(mktempdir(), "rep")
        render_test_report(root.node; out=out)
        @test !occursin("\"Inf\"", read(joinpath(out, "agent", "agent.json"), String))
        # and a margin check refuses an infinite number where it is built
        @test_throws r"finite" Check(:t, "x", 1.0, 1.1, 0.1, Inf, :abs, :pass)
        @test_throws r"finite" Check(:t, "x", Inf, 1.0, Inf, 0.5, :rel, :fail)
    end
end
