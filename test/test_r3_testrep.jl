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
end
