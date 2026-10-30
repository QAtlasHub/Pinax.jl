using Pinax
using Test

# Identity (Conventions › Identity). Every id is unique in the whole document and is the node's only
# name — its anchor, comment key and agent.json address. An id the author writes is never renamed, so
# a collision is an error where the second node is written. An id Pinax generates is the container's
# id plus a short stable hash of the node's content, so inserting a node never renames another; the
# same content twice in one container gets `-2`.

mutable struct _IdentIso <: Test.AbstractTestSet
    description::String
    results::Vector{Any}
    _IdentIso(desc::AbstractString=""; kw...) = new(String(desc), Any[])
end
Test.record(r::_IdentIso, x) = (push!(r.results, x); x)
Test.finish(r::_IdentIso) = r

_pg() = Pinax.current_document().pages[1]
_sec(id) = only(s for s in Pinax._all_sections(_pg()) if s.id === id)

@testset "identity" begin
    @testset "an author's id is unique in the whole document, across kinds" begin
        Pinax.reset!()
        @page :p "A" begin end
        @test_throws "duplicate id :p" @page :p "B" begin end
        @test length(Pinax.current_document().pages) == 1

        Pinax.reset!()
        @part :g "G" begin end
        @test_throws "duplicate id :g" @part :g "G again" begin end

        Pinax.reset!()
        @test_throws "duplicate id :x" @page :p "A" begin
            @section :a "A" begin
                @section :x "X" begin end
            end
            @section :b "B" begin
                @section :x "X" begin end   # another parent, the same name: still one document
            end
        end

        Pinax.reset!()
        @test_throws "duplicate id :f" @page :p "A" begin
            @section :a "A" begin
                @figure 1 id = :f
            end
            @section :b "B" begin
                @figure 2 id = :f
            end
        end

        Pinax.reset!()
        @test_throws "duplicate id :energy" @page :energy "Energy" begin
            @table (a=[1],) id = :energy             # a table may not take a page's id
        end
    end

    @testset "the id is the anchor: no second naming scheme" begin
        Pinax.reset!()
        @page :p "A" begin
            @section :a "A" begin
                @section :b "B" begin
                    @figure 1 id = :f
                end
            end
        end
        @test _sec(:b).anchor == "b"
        @test only(_sec(:b).figures).anchor == "f"
    end

    @testset "ids are Symbols" begin
        Pinax.reset!()
        @test_throws "Symbol" @page :p "A" begin
            @table (a=[1],) id = "t"
        end
        Pinax.reset!()
        @test_throws "Symbol" @page :p "A" begin
            @code y = 1 id = "c"
        end
    end

    @testset "a generated id hashes the node's content, so inserting a node renames nothing" begin
        build(extra) = begin
            Pinax.reset!()
            @page :p "A" begin
                extra && @figure 0
                extra && @table (z=[0],)
                extra && @code w = 0
                @figure 1
                @table (a=[1],)
                @code y = 1
            end
            pg = _pg()
            (last(pg.figures).id, last(pg.tables).id, last(pg.codes).id)
        end
        before, after = build(false), build(true)
        @test before == after
        f, t, c = before
        @test startswith(string(f), "p_fig_")
        @test startswith(string(t), "p_tbl_")
        @test startswith(string(c), "p_code_")
    end

    @testset "the same content twice in one container gets -2; a generated id never errors" begin
        Pinax.reset!()
        @page :p "A" begin
            for _ in 1:2
                @figure 1
            end
        end
        a, b = (f.id for f in _pg().figures)
        @test string(b) == string(a, "-2")
    end

    @testset "a nested @testset's section id is its container's id plus the description" begin
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
        @test [s.id for s in _pg().sections] == [:p_conv, Symbol("p_conv-2")]
    end
end
