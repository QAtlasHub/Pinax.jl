using Pinax
using Test

# A theme variant overriding emit_check: proves the check row is a dispatch point like emit_table.
struct CheckOverrideAgent <: Pinax.AgentBase end
function Pinax.emit_check(::CheckOverrideAgent, chk, ctx)
    return print(ctx.io, "{\"custom_chk\":\"", chk.id, "\"}")
end

# Checks are `Test`'s own `@test` (#173): `@expect` and `@benchmark` are gone. Every container whose
# subtree holds checks shows the same thing in every face: a verdict band over the subtree, then a
# table of its own checks. A check that fails on purpose is isolated in `_Iso`, so this file's suite
# does not count it.
mutable struct _Iso <: Test.AbstractTestSet
    description::String
    results::Vector{Any}
    _Iso(desc::AbstractString=""; kw...) = new(String(desc), Any[])
end
Test.record(r::_Iso, x) = (push!(r.results, x); x)
Test.finish(r::_Iso) = r

_page() = Pinax.current_document().pages[1]
_sec(id) = only(s for s in Pinax._all_sections(_page()) if s.id === id)

# One rel-pass, one abs-pass (a residual against zero) and one abs-FAIL, in a section.
function _mixed!()
    @testset _Iso "iso" begin
        @page :p "P" begin
            @section :aa "AA TL test set" begin
                @test isapprox(-0.81034, -0.81031; rtol=1e-2)
                @test isapprox(3.0e-5, 0.0; atol=1e-3)
                @test isapprox(0.5, 0.0; atol=1e-3)
            end
        end
    end
end

@testset "checks in a document" begin
    tmp = mktempdir()

    @testset "@expect and @benchmark are removed and name their replacement" begin
        Pinax.reset!()
        @test_throws "@test" @page :p "P" begin
            @expect "E" "e" got = 1.0 want = 1.0 tol = 1e-3
        end
        Pinax.reset!()
        @test_throws "@section" @benchmark :b "B" begin end
    end

    @testset "status is :draft or :final" begin
        Pinax.reset!()
        @page :d "D" status = :draft begin end
        @page :f "F" status = :final begin end
        @page :n "N" begin end
        @test [p.status for p in Pinax.current_document().pages] == [:draft, :final, :final]
        Pinax.reset!()
        @test_logs (:warn, r":trial.*:draft") @page :t "T" status = :trial begin end
        @test _page().status === :draft
        Pinax.reset!()
        @test_throws "status" @page :b "B" status = :benchmark begin end
        Pinax.reset!()
        @test_throws "status" @page :x "X" status = :fianl begin end
        Pinax.reset!()
        @test_throws "status" @part :pt "Part" status = :done begin end
    end

    @testset "agent.json: every container carries its verdict and its own checks" begin
        Pinax.reset!(; title="T")
        _mixed!()
        Pinax.render(; out=joinpath(tmp, "a"), theme=:agent)
        aj = read(joinpath(tmp, "a", "agent.json"), String)
        id1, _, id3 = (string(c.id) for c in _sec(:aa).checks)   # stable ids (#123)
        v = "\"verdict\":{\"verdict\":\"FAIL\",\"passed\":2,\"total\":3,\"failed\":[\"$(id3)\"]}"
        @test count(v, aj) == 2                       # the page and the section, over the subtree
        @test occursin("\"status\":\"final\"", aj)
        @test !occursin("\"benchmark\"", aj)          # no page kind of its own any more
        @test occursin("\"checks\":[{\"id\":\"$(id1)\"", aj)
        @test occursin("\"pass\":false", aj) && occursin("\"pass\":true", aj)
        @test occursin("{\"kind\":\"check\",\"id\":\"$(id3)\"}", aj)   # content refs resolve
        am = read(joinpath(tmp, "a", "agent.md"), String)
        @test occursin("2/3 FAIL", am)
        @test occursin("[FAIL]", am)
    end

    @testset "gallery: a verdict band, then the container's own checks" begin
        Pinax.reset!(; title="T")
        _mixed!()
        g = read(Pinax.render(; out=joinpath(tmp, "g"), theme=:gallery), String)
        @test occursin("AA TL test set   2/3 FAIL", g)  # the section's band
        @test occursin("P   2/3 FAIL", g)               # the page's band, over its subtree
        @test count("class=\"pinax-checks\"", g) == 1   # one table: only the section owns checks
        @test count("<tr class=\"pinax-pass\"", g) == 2
        @test count("<tr class=\"pinax-fail\"", g) == 1
    end

    @testset "LaTeX: the same band and table" begin
        Pinax.reset!(; title="T")
        _mixed!()
        lx = read(Pinax.render(; out=joinpath(tmp, "l"), theme=:latex), String)
        @test count("\\begin{tabular}{lllllll}", lx) == 1
        @test occursin("\\textbf{Verdict: FAIL} (2/3)", lx)
    end

    @testset "all-pass, empty and nested containers" begin
        Pinax.reset!(; title="T")
        @testset _Iso "iso" begin
            @page :p "P" begin
                @section :ok "All good" begin
                    @test true
                    @section :inner "Inner" begin
                        @test 1 + 1 == 2
                    end
                end
                @section :none "No checks" begin end
            end
        end
        g = read(Pinax.render(; out=joinpath(tmp, "n"), theme=:gallery), String)
        @test occursin("All good   2/2 PASS", g)       # the band covers the subtree
        @test occursin("Inner   1/1 PASS", g)
        @test count("class=\"pinax-checks\"", g) == 2  # each owner shows its own checks
        @test !occursin("No checks   ", g)              # no checks, no band — never a vacuous PASS
        @test Pinax.verdict(_sec(:none)) === nothing
    end

    @testset "the band leads, figures follow" begin
        Pinax.reset!(; title="T")
        svg = joinpath(tmp, "o.svg")
        write(svg, "<svg xmlns='http://www.w3.org/2000/svg'><rect/></svg>")
        @testset _Iso "iso" begin
            @page :p "P" begin
                @section :s "With figure" begin
                    @test true
                    @figure svg
                    @caption "FIGBELOW"
                end
            end
        end
        g = read(Pinax.render(; out=joinpath(tmp, "f"), theme=:gallery), String)
        @test first(findfirst("With figure   1/1 PASS", g)) <
            first(findfirst("FIGBELOW", g))
    end

    @testset "emit_check is an overridable dispatch point" begin
        Pinax.reset!(; title="x")
        @testset _Iso "iso" begin
            @page :p "P" begin
                @section :s "S" begin
                    @test true
                end
            end
        end
        Pinax.render(; out=joinpath(tmp, "o"), theme=CheckOverrideAgent())
        @test occursin(
            "\"custom_chk\":\"$(only(_sec(:s).checks).id)\"",
            read(joinpath(tmp, "o", "agent.json"), String),
        )
    end

    @testset "markup in a check label is escaped in every face" begin
        Pinax.reset!(; title="T")
        @testset _Iso "iso" begin
            @page :p "P" begin
                @section :s "S" begin
                    @test isequal("energy & <x>", "energy & <x>")
                end
            end
        end
        g = read(Pinax.render(; out=joinpath(tmp, "e"), theme=:gallery), String)
        @test occursin("energy &amp; &lt;x&gt;", g)
        @test !occursin("\"energy & <x>\"", g)
        aj = read(Pinax.render(; out=joinpath(tmp, "ea"), theme=:agent), String)
        @test occursin("energy \\u0026 \\u003cx\\u003e", aj)
        lx = read(Pinax.render(; out=joinpath(tmp, "el"), theme=:latex), String)
        @test occursin("energy \\&", lx)
    end
end
