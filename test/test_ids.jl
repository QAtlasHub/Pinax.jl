using Pinax
using Test
using Pinax: TestNode, Check

# Stable ids (#123). A check's id is its container's anchor plus a short stable hash of its source
# text, so adding or reordering other checks never renumbers it; the same text twice in one container
# gets a "-2" suffix. A code block's id hashes its code, so shifting lines never changes it.

mutable struct _IdIso <: Test.AbstractTestSet
    description::String
    results::Vector{Any}
    _IdIso(desc::AbstractString=""; kw...) = new(String(desc), Any[])
end
Test.record(r::_IdIso, x) = (push!(r.results, x); x)
Test.finish(r::_IdIso) = r

function _sec_checks(id)
    return only(
        s for s in Pinax._all_sections(Pinax.current_document().pages[1]) if s.id === id
    ).checks
end

@testset "stable ids" begin
    @testset "adding a check does not renumber the others" begin
        Pinax.reset!()
        @testset _IdIso "iso" begin
            @page :p "P" begin
                @section :a "A" begin
                    @test 1 + 1 == 2
                end
            end
        end
        before = only(_sec_checks(:a)).id
        Pinax.reset!()
        @testset _IdIso "iso" begin
            @page :p "P" begin
                @section :a "A" begin
                    @test 2 + 2 == 4           # a new check, written first
                    @test 1 + 1 == 2
                end
            end
        end
        after = _sec_checks(:a)[2].id
        @test before == after
        @test startswith(string(before), "a_t")
    end

    @testset "the same expression twice in one container is disambiguated" begin
        Pinax.reset!()
        @testset _IdIso "iso" begin
            @page :p "P" begin
                @section :a "A" begin
                    @test true
                    @test true
                end
                @section :b "B" begin
                    @test true
                end
            end
        end
        a1, a2 = (c.id for c in _sec_checks(:a))
        @test string(a2) == string(a1, "-2")
        b1 = only(_sec_checks(:b)).id
        @test b1 != a1 && startswith(string(b1), "b_t")   # the container path is part of the id
    end

    @testset "a test report's check ids do not depend on earlier files" begin
        ok(label) = Check(:t, label, 1.0, 1.0, 0.0, 0.5, :abs, true)
        report(first_checks) = begin
            tree = TestNode(
                "root";
                children=[
                    TestNode("test_a.jl"; checks=first_checks),
                    TestNode("test_b.jl"; checks=[ok("b_check")]),
                ],
            )
            Pinax.render_test_report(tree; out=mktempdir())
            pg = only(p for p in Pinax.current_document().pages if p.title == "test_b.jl")
            only(pg.checks).id
        end
        @test report([ok("a1")]) == report([ok("a0"), ok("a1")])
    end

    @testset "a code block's id survives shifted lines" begin
        src = """
        using Test
        @testset "t" begin
            x = 1 + 1
            @test x == 2
        end
        """
        d1, d2 = mktempdir(), mktempdir()
        f1, f2 = joinpath(d1, "test_c.jl"), joinpath(d2, "test_c.jl")
        write(f1, src)
        write(f2, "\n\n# a comment added at the top\n" * src)
        b1 = Pinax._test_code_block(f1, 4)
        b2 = Pinax._test_code_block(f2, 7)
        @test b1 !== nothing && b2 !== nothing
        @test b1.source == b2.source
        @test b1.id == b2.id
        @test startswith(string(b1.id), "code_test_c_jl_")
    end
end
