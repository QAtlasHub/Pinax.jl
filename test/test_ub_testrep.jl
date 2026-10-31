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
end
