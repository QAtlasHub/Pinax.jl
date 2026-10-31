using Pinax
using Pinax: Check, CodeBlock, TestNode, render_test_report
using Test

const UbExt = Base.get_extension(Pinax, :PinaxTestExt)

# The diagnostics a render recorded, as `item => message` strings.
_ub_diags() = [(d.item, d.message) for d in Pinax.current_document().diag.entries]

@testset "test report: review fixes (ub-testrep)" begin
    @testset "a @desc inside an unnamed `@testset for` is never dropped silently" begin
        root = UbExt.PinaxTestSet("Test report")
        UbExt._with_testset(root) do
            @testset "test_sweepdesc.jl" begin
                @testset for chi in (8, 16)
                    @desc md"SWEEP_NOTE"
                    @test chi > 0
                end
            end
        end
        out = joinpath(mktempdir(), "rep")
        render_test_report(root.node; out=out)
        aj = read(joinpath(out, "agent", "agent.json"), String)
        # the sweep cannot place it, so the document says so — in the diagnostics both faces carry
        @test any(((item, msg),) -> occursin("@desc", msg), _ub_diags())
        @test occursin("@desc", aj)
    end

    @testset "a check's id is claimed in the document's id registry" begin
        hashed(anchor, label) = Symbol(anchor, "_t", Pinax._stable_hash(label))
        doc_ids() = [n.id for n in node_ids(Pinax.current_document())]

        # manuscript: an author id written after a check that holds it is an error naming it…
        Pinax.reset!()
        @page :p "P" begin
            @test 1 == 1
        end
        cid = Pinax.current_document().pages[1].checks[1].id
        @test cid === hashed(:p, "1 == 1")
        @test_throws Regex(string(cid)) @eval @page $(QuoteNode(cid)) "Q" begin end
        @test allunique(doc_ids())

        # …and a generated check id steps aside from an author id written before it
        Pinax.reset!()
        taken = hashed(:p, "1 == 1")
        @page :p "P" begin
            @raw "<b>taken</b>" id = taken
            @test 1 == 1
        end
        @test Pinax.current_document().pages[1].checks[1].id === Symbol(cid, "-2")
        @test allunique(doc_ids())

        # the fold: a captured node's id that a placed check holds steps aside when generated…
        lbl = "LBL"
        tid = hashed(:test_a_jl, lbl)
        file(written) = TestNode(
            "test_a.jl";
            checks=[Check(:t, lbl, 1.0, 1.0, 0.0, 0.5, :abs, true)],
            texts=[Pinax.Prose(tid, string(tid), "PROSE", "")],
            content=[:check => 1, :text => 1],
            written=written,
        )
        out = mktempdir()
        render_test_report(TestNode("T"; children=[file(Set{Symbol}())]); out=out)
        @test allunique(doc_ids())
        # …and is an error naming it when the author wrote it
        @test_throws Regex(string(tid)) render_test_report(
            TestNode("T"; children=[file(Set([tid]))]); out=out
        )
    end

    @testset "a dump's content is validated where it is read" begin
        dir = mktempdir()
        node = TestNode(
            "test_d.jl";
            checks=[Check(:t, "ok", 1.0, 1.0, 0.0, 0.5, :abs, true)],
            content=[:check => 1],
        )
        good = Pinax.dump_test_report(
            TestNode("T"; children=[node]), joinpath(dir, "g.toml")
        )
        # an edited copy of the good dump: `edit!` changes the file's only testset's dict
        function edited(name, edit!)
            d = Pinax.TOML.parsefile(good)
            edit!(only(d["root"]["child"]))
            p = joinpath(dir, name)
            open(io -> Pinax.TOML.print(io, d), p, "w")
            return p
        end
        bad_kind = edited("k.toml", f -> (f["content"][1]["kind"] = "bogus"))
        bad_index = edited("i.toml", f -> (f["content"][1]["i"] = 99))
        bad_check = edited("c.toml", f -> (f["check"][1]["kind"] = "sqrt"))
        for (p, what) in ((bad_kind, "bogus"), (bad_index, "99"), (bad_check, "sqrt"))
            # an error naming the entry and the file, never a BoundsError deep in the fold
            err = try
                Pinax.load_test_dump(p)
                nothing
            catch e
                e
            end
            @test err isa ErrorException
            @test occursin(what, sprint(showerror, err)) &&
                occursin(basename(p), sprint(showerror, err)) &&
                occursin("test_d.jl", sprint(showerror, err))
            @test_throws ErrorException render_test_report([p]; out=joinpath(dir, "r"))
        end
        @test Pinax.load_test_dump(good).children[1].content == [:check => 1]
    end

    @testset "every node a shard dump drops is a diagnostic of the merged report" begin
        fig(id) = Pinax.Figure(
            id, string(id), "", nothing, () -> "x.svg", "code", false, String[], nothing
        )
        tbl(id) = Pinax.Table(id, string(id), "", ["a"], [Any[1]], "", (; n=1))
        shard(file, figs, tbls) = TestNode(
            "T";
            children=[
                TestNode(
                    file;
                    checks=[Check(:t, "ok", 1.0, 1.0, 0.0, 0.5, :abs, true)],
                    figures=fig.(figs),
                    tables=tbl.(tbls),
                ),
            ],
        )
        dir = mktempdir()
        d1 = joinpath(dir, "s1.toml")
        d2 = joinpath(dir, "s2.toml")
        # each dropped node is said in the shard's log too — every one, not the first only
        @test_logs (:warn, r"FIG_A") (:warn, r"FIG_B") (:warn, r"TBL_A") match_mode = :any Pinax.dump_test_report(
            shard("test_a.jl", [:FIG_A, :FIG_B], [:TBL_A]), d1
        )
        @test_logs (:warn, r"FIG_C") (:warn, r"TBL_B") match_mode = :any Pinax.dump_test_report(
            shard("test_b.jl", [:FIG_C], [:TBL_B]), d2
        )
        out = joinpath(dir, "rep")
        render_test_report([d1, d2]; out=out)
        diags = _ub_diags()
        for id in ("FIG_A", "FIG_B", "FIG_C", "TBL_A", "TBL_B")
            @test count(((item, msg),) -> occursin(id, item * msg), diags) == 1
        end
        aj = read(joinpath(out, "agent", "agent.json"), String)
        @test occursin("FIG_B", aj) && occursin("TBL_B", aj)
        # …and of a CI-matrix report, where each cell is a part
        cells = map(["1.10", "1.11"]) do v
            withenv("PINAX_TEST_MATRIX" => v) do
                @test_logs (:warn,) match_mode = :any Pinax.dump_test_report(
                    shard("test_a.jl", [Symbol("FIG_M", v)], Symbol[]),
                    joinpath(dir, "m$(v).toml"),
                )
            end
        end
        render_test_report(cells; out=joinpath(dir, "mrep"))
        @test count(((item, _),) -> startswith(item, "FIG_M"), _ub_diags()) == 2
    end

    @testset "the fold places a node of an unknown kind nowhere: it is an error" begin
        bad = TestNode(
            "test_k.jl";
            checks=[Check(:t, "ok", 1.0, 1.0, 0.0, 0.5, :abs, true)],
            content=[:check => 1, :bogus => 1],
        )
        @test_throws "unknown content kind :bogus" render_test_report(
            TestNode("T"; children=[bad]); out=mktempdir()
        )
    end
end
