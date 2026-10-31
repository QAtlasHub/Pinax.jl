using Pinax
using Test

# Checks are `Test`'s own `@test` / `@testset` (#173): inside a `@page` / `@section`, a `@test` is a
# check of the innermost container, and a `@testset` is a child section. The same result is also
# handed to the nearest enclosing ordinary testset, so a suite counts it exactly as if the `@test`
# were written there; with no enclosing testset (a manuscript run on its own) it is only recorded.

# An isolated outer testset: records what reaches it and never reports to the real suite, so a test
# can assert that a failing check was counted without failing this file.
mutable struct _Recorder <: Test.AbstractTestSet
    description::String
    results::Vector{Any}
    _Recorder(desc::AbstractString=""; kw...) = new(String(desc), Any[])
end
Test.record(r::_Recorder, x) = (push!(r.results, x); x)
Test.finish(r::_Recorder) = r

function _section(id)
    return only(
        s for s in Pinax._all_sections(Pinax.current_document().pages[1]) if s.id === id
    )
end

@testset "Test's @test / @testset inside a document" begin
    @testset "@test inside @section is a check of that section" begin
        Pinax.reset!()
        rec = @testset _Recorder "outer" begin
            @page :p "P" begin
                @section :a "A" begin
                    @test 1 + 1 == 2
                    @test isapprox(1.0, 1.0001; rtol=1e-3)
                end
            end
        end
        a = _section(:a)
        @test length(a.checks) == 2
        @test all(c -> Pinax.passed(c), a.checks)
        @test first.(a.content) == [:code, :check, :code, :check] ||
            first.(a.content) == [:check, :check]
        # the outer testset saw both results, exactly once each
        @test count(r -> r isa Test.Pass, rec.results) == 2
    end

    @testset "a failing @test is recorded as FAIL and counted by the outer testset" begin
        Pinax.reset!()
        rec = @testset _Recorder "outer" begin
            @page :p "P" begin
                @section :a "A" begin
                    @test 1 + 1 == 3
                end
            end
        end
        a = _section(:a)
        @test length(a.checks) == 1
        @test !Pinax.passed(a.checks[1])
        @test count(r -> r isa Test.Fail, rec.results) == 1
    end

    @testset "@testset inside @section is a child section, to any depth" begin
        Pinax.reset!()
        rec = @testset _Recorder "outer" begin
            @page :p "P" begin
                @section :a "A" begin
                    @testset "energy" begin
                        @test true
                        @testset "per site" begin
                            @test true
                        end
                    end
                end
            end
        end
        a = _section(:a)
        @test [s.title for s in a.sections] == ["energy"]
        energy = a.sections[1]
        @test energy.depth == 3
        @test length(energy.checks) == 1
        @test [s.title for s in energy.sections] == ["per site"]
        @test energy.sections[1].depth == 4
        @test length(energy.sections[1].checks) == 1
        @test count(r -> r isa Test.Pass, rec.results) == 2
        # the section stack is balanced after the testsets close
        @test Pinax.current_section() === nothing
    end

    @testset "scoping is unchanged: a section body is its own scope, as before" begin
        Pinax.reset!()
        outer_value = 1
        @page :p "P" begin
            @section :a "A" begin
                seen = outer_value          # outer variables are visible inside
                inner_only = 2
            end
        end
        @test !@isdefined(inner_only)
    end

    @static if isdefined(Test, :CURRENT_TESTSET)
        @testset "with no enclosing testset, a failing check is only recorded" begin
            Pinax.reset!()
            # simulate a manuscript run on its own: no testset is open
            Base.ScopedValues.@with Test.CURRENT_TESTSET => Test.FallbackTestSet() Test.TESTSET_DEPTH =>
                0 begin
                @page :p "P" begin
                    @section :a "A" begin
                        @test 1 + 1 == 3      # would throw from FallbackTestSet if it reached it
                    end
                end
            end
            @test !Pinax.passed(_section(:a).checks[1])
        end
    end
end
