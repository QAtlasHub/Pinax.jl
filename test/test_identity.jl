using Pinax
using Test

# Identity (Conventions › Identity): an id the author wrote is never renamed, so a collision is an
# error raised where the second node is written, naming the id. Equal ids under different parents do
# not collide — anchors are hierarchical. An id Pinax generates (a check's, a nested `@testset`'s
# section) is disambiguated with `-2` instead, since no author chose it.

mutable struct _IdentIso <: Test.AbstractTestSet
    description::String
    results::Vector{Any}
    _IdentIso(desc::AbstractString=""; kw...) = new(String(desc), Any[])
end
Test.record(r::_IdentIso, x) = (push!(r.results, x); x)
Test.finish(r::_IdentIso) = r

@testset "identity: a duplicate id is an error where it is written" begin
    @testset "two pages with one id" begin
        Pinax.reset!()
        @page :p "A" begin end
        @test_throws ":p" @page :p "B" begin end
        @test length(Pinax.current_document().pages) == 1
    end

    @testset "two sibling sections with one id; equal ids under different parents are fine" begin
        Pinax.reset!()
        @test_throws "duplicate id :s" @page :p "A" begin
            @section :s "S" begin end
            @section :s "T" begin end
        end
        Pinax.reset!()
        @page :p "A" begin
            @section :a "A" begin
                @section :x "X" begin end
            end
            @section :b "B" begin
                @section :x "X" begin end   # a different parent: a different anchor
            end
        end
        secs = Pinax._all_sections(Pinax.current_document().pages[1])
        @test count(s -> s.id === :x, secs) == 2
        @test allunique(s.anchor for s in secs)
    end

    @testset "figures, tables and code blocks share one id namespace per container" begin
        Pinax.reset!()
        @test_throws "duplicate id :f" @page :p "A" begin
            @figure 1 id = :f
            @figure 2 id = :f
        end
        Pinax.reset!()
        @test_throws "duplicate id :x" @page :p "A" begin
            @figure 1 id = :x
            @table (a=[1],) id = :x
        end
        Pinax.reset!()
        @test_throws "duplicate id :x" @page :p "A" begin
            @table (a=[1],) id = :x
            @code y = 1 id = :x
        end
        # the same explicit id in two containers is fine
        Pinax.reset!()
        @page :p "A" begin
            @section :a "A" begin
                @figure 1 id = :f
            end
            @section :b "B" begin
                @figure 1 id = :f
            end
        end
        @test length(Pinax._all_sections(Pinax.current_document().pages[1])) == 2
    end

    @testset "a nested @testset's generated section id is disambiguated, never an error" begin
        Pinax.reset!()
        @testset _IdentIso "iso" begin
            @page :p "A" begin
                for _ in 1:2
                    @testset "conv" begin
                        @test true
                    end
                end
            end
        end
        ids = [s.id for s in Pinax.current_document().pages[1].sections]
        @test ids == [:conv, Symbol("conv-2")]
    end
end
