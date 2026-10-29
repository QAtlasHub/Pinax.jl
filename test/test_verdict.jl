using Pinax
using Test

# A verdict is derived, never stored (#173): `nothing` when a container's subtree holds no checks,
# else (passed, total, failed). Every face shows it on every container that has one. A failing check
# is reported exactly once: to the enclosing ordinary testset when there is one, else by `render`,
# which raises after it has written every output.

mutable struct _Rec <: Test.AbstractTestSet
    description::String
    results::Vector{Any}
    _Rec(desc::AbstractString=""; kw...) = new(String(desc), Any[])
end
Test.record(r::_Rec, x) = (push!(r.results, x); x)
Test.finish(r::_Rec) = r

function _sec(id)
    return only(
        s for s in Pinax._all_sections(Pinax.current_document().pages[1]) if s.id === id
    )
end

# Build the document with no testset open — a manuscript run on its own.
macro _standalone(body)
    if isdefined(Test, :CURRENT_TESTSET)
        return esc(
            :(Base.ScopedValues.@with Test.CURRENT_TESTSET => Test.FallbackTestSet() Test.TESTSET_DEPTH =>
                0 $body),
        )
    else
        return esc(body)   # Julia ≤ 1.12: covered by the 1.13 CI job
    end
end

@testset "derived verdicts and how a failing check is reported" begin
    tmp = mktempdir()

    @testset "verdict: nothing without checks, aggregated over the subtree" begin
        Pinax.reset!()
        @testset _Rec "outer" begin
            @page :p "P" begin
                @section :empty "Empty" begin end
                @section :a "A" begin
                    @test true
                    @section :b "B" begin
                        @test 1 == 2
                    end
                end
            end
        end
        @test Pinax.verdict(_sec(:empty)) === nothing
        v = Pinax.verdict(_sec(:a))
        @test (v.passed, v.total, v.verdict) == (1, 2, "FAIL")
        @test v.failed == ["b_t1"]
        vb = Pinax.verdict(_sec(:b))
        @test (vb.passed, vb.total) == (0, 1)
    end

    @testset "every face shows the verdict of a container that has checks" begin
        Pinax.reset!()
        @testset _Rec "outer" begin
            @page :p "P" begin
                @section :empty "Empty" begin end
                @section :a "A" begin
                    @test true
                    @test 1 == 2
                end
            end
        end
        out = joinpath(tmp, "faces")
        Pinax.render(; out=out)
        html = read(joinpath(out, "index.html"), String)
        @test occursin(
            r"id=\"a\"><h2>[^\n]*class=\"pinax-verdict-badge fail\"[^>]*>FAIL 1/2", html
        )
        @test !occursin(r"id=\"empty\"><h2>[^\n]*pinax-verdict-badge", html)
        Pinax.render(; out=out, theme=:agent)
        js = read(joinpath(out, "agent.json"), String)
        @test occursin(
            "\"verdict\":{\"verdict\":\"FAIL\",\"passed\":1,\"total\":2,\"failed\":[\"a_t2\"]}",
            js,
        )
        @test occursin("\"id\":\"empty\"", js) && occursin("\"verdict\":null", js)
        Pinax.render(; out=out, theme=:latex)
        tex = read(joinpath(out, "document.tex"), String)
        @test occursin(
            r"\\subsection\{A\}[^\n]*\n\\noindent\\textbf\{FAIL\} 1/2 checks passed", tex
        )
        @test !occursin(r"\\subsection\{Empty\}[^\n]*\n\\noindent\\textbf", tex)
    end

    @testset "a failing check reported to an enclosing testset: render does not raise" begin
        Pinax.reset!()
        rec = @testset _Rec "outer" begin
            @page :p "P" begin
                @section :a "A" begin
                    @test 1 == 2
                end
            end
        end
        @test count(r -> r isa Test.Fail, rec.results) == 1
        @test Pinax.render(; out=joinpath(tmp, "reported")) isa AbstractString
    end

    if isdefined(Test, :CURRENT_TESTSET)
        @testset "an unreported failing check: render writes everything, then raises" begin
            Pinax.reset!()
            @_standalone begin
                @page :p "P" begin
                    @section :a "A" begin
                        @test 1 == 2
                    end
                end
            end
            out = joinpath(tmp, "standalone")
            err = try
                Pinax.render(; out=out)
                nothing
            catch e
                e
            end
            @test err isa Pinax.ChecksFailed
            @test err.failed == ["a_t1"]
            @test isfile(joinpath(out, "index.html"))   # the failing page is on disk to look at
            @test err.path == joinpath(out, "index.html")
            @test occursin("a_t1", sprint(showerror, err))
        end
    end
end
