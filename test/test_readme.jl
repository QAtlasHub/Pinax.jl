# The README's claims, checked against the package.
#
# Scope: names and links, not execution. The Quickstart ends in `render` and `serve`, so running it
# verbatim would write a site and open a socket. What shipped was not a runtime fault anyway — the
# README taught `@pinaxtestset` and `PINAX_TEST_REPORT`, neither of which exists anywhere in the
# source, while `docs/src/test2pinax.md` said the opposite.

using Pinax
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
