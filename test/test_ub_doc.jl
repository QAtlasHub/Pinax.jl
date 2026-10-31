using Pinax
using Test

# Review fixes for the document model: each testset pins one behavior a review found missing.

@testset "ub-doc review fixes" begin
    @testset "a ragged @table is an error where it is written, naming it and the mismatch" begin
        Pinax.reset!()
        @test_throws r"@table :cols in \"p\".*column b has 2 rows but column a has 3" @page :p "P" begin
            @table (a=[1, 2, 3], b=[1, 2]) id = :cols
        end
        Pinax.reset!()
        @test_throws r"@table :recs in \"p\".*row 2 has keys \(a, b\) but row 1 has \(a\)" @page :p "P" begin
            @table [(a=1,), (a=2, b=3)] id = :recs
        end
        # without an id, the table is named by its data expression
        Pinax.reset!()
        @test_throws r"@table \(a = \[1, 2, 3\], b = \[1, 2\]\) in \"p\"" @page :p "P" begin
            @table (a=[1, 2, 3], b=[1, 2])
        end
        # a failed @table claims nothing: the same id can be written again
        Pinax.reset!()
        @page :q "Q" begin
            try
                @table (a=[1, 2], b=[1]) id = :t
            catch
            end
            @table (a=[1, 2], b=[3, 4]) id = :t
        end
        @test only(Pinax.current_document().pages[1].tables).rows == [[1, 3], [2, 4]]
        # records with the same keys in another order are one table
        h, r = Pinax._normalize_table([(a=1, b=2), (b=3, a=4)], nothing)
        @test h == ["a", "b"] && r == [[1, 2], [4, 3]]
    end
    @testset "a refused @part/@page/@section claims nothing: a retry is not a duplicate" begin
        Pinax.reset!()
        @test_throws "status must be" @part :g "G" status = :bogus begin end
        @part :g "G" begin end
        doc = Pinax.current_document()
        @test doc.parts == [:g => "G"]
        @test_throws "status must be" @page :p "P" status = :bogus begin end
        @page :p "P" begin end
        @test [pg.id for pg in doc.pages] == [:p]
        @test_throws "layout= must be" @page :q "Q" layout = :bogus begin end
        err = nothing
        @page :q "Q" begin
            err = try
                @section :s "S" layout = :bogus begin end
            catch e
                e
            end
            @section :s "S" begin end
        end
        @test occursin("layout= must be", sprint(showerror, err))
        @test [s.id for s in doc.pages[2].sections] == [:s]
        @test !(:never in doc.written)
        @test_throws "outside of a @page" @section :never "S" begin end
        @test !(:never in doc.written) && !haskey(doc.ids, :never)
    end
end
