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
end
