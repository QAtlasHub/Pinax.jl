# The README's claims, checked against the package.
#
# Scope: the Quickstart is executed verbatim; every other block is checked by name. `serve` sits in
# a separate block precisely so this one can run — it starts a blocking HTTP server.
#
# Two defects motivate this. The README taught `@pinaxtestset` and `PINAX_TEST_REPORT`, neither of
# which exists anywhere in the source. And the Quickstart's figure expression was undefined, so a
# reader following it got `UndefVarError` embedded in the rendered gallery while `render` returned
# normally — a failure with no signal at the call site.

using Pinax
using Plots: Plots
using Test

const _README = read(joinpath(@__DIR__, "..", "README.md"), String)

"Every ```julia fence in the README, as one string per block."
function _julia_blocks(md)
    out = String[]
    for m in eachmatch(r"```julia\r?\n(.*?)```"s, md)
        push!(out, m.captures[1])
    end
    return out
end

# Macros the README may name without Pinax defining them.
const _FOREIGN_MACROS = Set([Symbol("@test"), Symbol("@testset"), Symbol("@time")])

@testset "every macro the README teaches exists" begin
    blocks = _julia_blocks(_README)
    @test !isempty(blocks)
    named = Set{Symbol}()
    for b in blocks, m in eachmatch(r"@[a-zA-Z_][a-zA-Z0-9_]*", b)
        push!(named, Symbol(m.match))
    end
    @test !isempty(named)
    missing_macros = sort!([
        m for m in collect(named) if m ∉ _FOREIGN_MACROS && !isdefined(Pinax, m)
    ])
    @test missing_macros == Symbol[]
end

@testset "…and the check can see a macro that does not exist" begin
    # Control: the scan only looks inside fences, so it has to be shown to fire.
    named = Set{Symbol}()
    for b in _julia_blocks("```julia\n@no_such_pinax_macro x\n```"),
        m in eachmatch(r"@[a-zA-Z_][a-zA-Z0-9_]*", b)

        push!(named, Symbol(m.match))
    end
    @test Symbol("@no_such_pinax_macro") in named
    @test !isdefined(Pinax, Symbol("@no_such_pinax_macro"))
end

@testset "every PINAX_ environment variable the README names is read by the code" begin
    # `PINAX_TEST_REPORT=1` was in the README and in no other file in the repository.
    src = join(
        [
            read(joinpath(root, f), String) for d in ("src", "ext") for
            (root, _, fs) in walkdir(joinpath(@__DIR__, "..", d)) for
            f in fs if endswith(f, ".jl")
        ],
        "\n",
    )
    named = sort!(unique!([m.match for m in eachmatch(r"PINAX_[A-Z_]+", _README)]))
    @test !isempty(named)
    @test [v for v in named if !occursin(v, src)] == String[]
end

@testset "no README code block uses a trailing backslash as a line continuation" begin
    # Julia has no line continuation; inside a fence a trailing `\` is left-division.
    offenders = [
        l for b in _julia_blocks(_README) for
        l in split(b, "\n") if endswith(rstrip(l), "\\")
    ]
    @test offenders == String[]
end

@testset "the README points at the deployed documentation, not the old host" begin
    # `codes.sota-shimozono.com` does not resolve; the site is on GitHub Pages under the org that
    # owns the repository now.
    @test !occursin("codes.sota-shimozono.com", _README)
    @test !occursin("sotashimozono/Pinax.jl", _README)
    @test occursin("qatlashub.github.io/Pinax.jl", _README)
end

@testset "the Quickstart runs verbatim and renders a figure" begin
    # Not "it did not throw": `render` returns normally with a crashed figure, so the assertion
    # has to be about the artefact. A real SVG on disk, and no exception text in the page.
    blocks = _julia_blocks(_README)
    quickstart = blocks[2]
    @test occursin("@page", quickstart)
    @test occursin("render(", quickstart)
    @test !occursin("serve(", quickstart)   # would block; it lives in the next block

    dir = mktempdir()
    m = Module(:READMEQuickstart)
    cd(dir) do
        Core.eval(m, :(using Pinax))
        Pinax.reset!()
        Core.eval(m, Meta.parseall(quickstart; filename="README.md"))
    end

    svgs = [
        joinpath(r, f) for (r, _, fs) in walkdir(joinpath(dir, "site")) for
        f in fs if endswith(f, ".svg")
    ]
    @test length(svgs) == 1
    @test filesize(only(svgs)) > 1_000

    html = read(joinpath(dir, "site", "index.html"), String)
    @test !occursin("UndefVarError", html)
    @test occursin(basename(only(svgs)), html)
end
