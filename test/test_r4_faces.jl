using Pinax
using Test
using JSON: JSON

# Round-4 review findings on the faces: each testset pins output a mutation review found unchecked.

@testset "agent.md: every line of a figure, a check, a code block, a container and a part" begin
    tmp = mktempdir()
    svg = joinpath(tmp, "f.svg")
    write(svg, "<svg xmlns='http://www.w3.org/2000/svg'/>")
    Pinax.reset!(; title="T")
    line = @__LINE__
    @part :pa "Part A" desc = md"PART_A_DESC" begin
        @page :p "P" summary = "PAGE_SUMMARY" begin
            @figure svg id = :fig caption = "FIG_CAP"
            @test isapprox(2.0, 1.5; rtol=0.5)
            @test isapprox(0.5, 0.25; atol=0.5)
            @code CODE_VAL = 40 + 2 caption = "CODE_CAP" id = :cd
        end
    end
    at(n) = "test/test_r4_faces.jl:$(line + n)"
    write(
        joinpath(tmp, "comments.toml"),
        "[[comment.fig]]\nauthor = \"me\"\ntext = \"FIG_NOTE\"\n",
    )
    Pinax.render(; out=tmp, theme=:agent)
    md = read(joinpath(tmp, "agent.md"), String)
    c_rel, c_abs = (c.id for c in Pinax.current_document().pages[1].checks)

    # a part's heading, then its description
    @test occursin("\n## Part A\nPART_A_DESC\n", md)
    # a container's heading, its verdict band, then its summary
    @test occursin("\n### P  [id: p]\n**P   2/2 PASS**\n_PAGE_SUMMARY_\n", md)
    # a figure's block: where and how it was made, its (missing) data, its image, and its note
    # indented into the block
    @test occursin(
        """
        - [fig: fig] FIG_CAP
          - defined at: $(at(3))
          - code: `svg`
          - data: none — this figure can be read only through its image
          - image: assets/figures/p/fig.svg
          - note (me): FIG_NOTE
        """,
        md,
    )
    # a check's numbers end with its kind
    @test occursin(
        "\n- [PASS] $(c_rel) — isapprox(2.0, 1.5; rtol = 0.5): got 2.0, want 1.5 " *
        "(Δ 0.25 vs tol 0.5 rel) — defined at $(at(4))\n",
        md,
    )
    @test occursin(
        "\n- [PASS] $(c_abs) — isapprox(0.5, 0.25; atol = 0.5): got 0.5, want 0.25 " *
        "(Δ 0.25 vs tol 0.5 abs) — defined at $(at(5))\n",
        md,
    )
    # a code block: its caption on the line naming it, the fenced source, then its output
    @test occursin(
        "\n[code: cd] CODE_CAP — defined at $(at(6))\n```julia\nCODE_VAL = 40 + 2\n```\n`=> 42`\n",
        md,
    )
    # agent.json carries the part's description too
    aj = JSON.parse(read(joinpath(tmp, "agent.json"), String))
    @test aj["parts"] == [
        Dict(
            "id" => "pa", "title" => "Part A", "desc" => "PART_A_DESC", "status" => nothing
        ),
    ]
end
