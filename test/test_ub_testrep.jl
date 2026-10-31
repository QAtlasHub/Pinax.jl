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
end
