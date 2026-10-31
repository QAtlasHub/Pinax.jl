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
    @testset "settings are validated where they enter; comments the gallery hides are said" begin
        @test_throws r"features=.*:comment\b.*:comments, :bookmarks, :export" Pinax.reset!(;
            features=[:comment]
        )
        @test_throws "katex= must be :cdn or :local (got :foo)" Pinax.DocMeta(; katex=:foo)
        @test_throws "index= must be :toc" Pinax.DocMeta(; index=:nope)
        @test_throws "unknown feature" Pinax.DocMeta(; features=[:export, :bogus])
        @test Pinax.DocMeta(; features=Symbol[]).features == Symbol[]

        dir = mktempdir()
        store = joinpath(dir, "comments.toml")
        write(
            store,
            """
            [[comment.p]]
            author = "a"
            text = "hello"

            [bookmark]
            p = "yes"
            q = false
            """,
        )
        _, bookmarks, problems = Pinax._parse_comments(store)
        @test isempty(bookmarks)
        @test only(problems).item == "p"
        @test occursin("\"yes\"", only(problems).message)

        Pinax.reset!(; features=[:bookmarks])
        @page :p "P" begin end
        rdiag = Pinax.DiagEntry[]
        Pinax._read_comments(Pinax.current_document(), store, rdiag)
        hidden = filter(d -> occursin("hides", d.message), rdiag)
        @test length(hidden) == 1 && only(hidden).severity == Pinax.WARNING
        Pinax.reset!()   # :comments on (the default): nothing to say
        @page :p "P" begin end
        rdiag = Pinax.DiagEntry[]
        Pinax._read_comments(Pinax.current_document(), store, rdiag)
        @test !any(d -> occursin("hides", d.message), rdiag)
    end
    @testset "content macros: one expression plus reserved keywords; @code's four forms" begin
        expand(ex) = macroexpand(@__MODULE__, ex)
        @test_throws "@figure needs a plot expression" expand(:(@figure caption = "c"))
        @test_throws "@figure takes a single plot expression (plus kwargs)" expand(
            :(@figure 1 2)
        )
        @test_throws "@table needs a data expression" expand(:(@table id = :t))
        @test_throws "@table takes a single data expression (plus kwargs)" expand(
            :(@table 1 2)
        )
        @test_throws "@code needs an expression" expand(:(@code))
        @test_throws "@code takes a single expression (plus kwargs)" expand(:(@code 1 2))

        Pinax.reset!()
        ran = Ref(0)
        local leaked, r, f1
        @page :p "P" begin
            @code run = false (ran[] += 1)                     # shown, never run
            @code leaked = 6 * 7 caption = "assign"            # runs bare; the value is shown
            @code function _ubdoc_f(x)                         # a definition: runs bare, no output
                return x + 1
            end
            f1 = _ubdoc_f(1)
            r = @code 2 + 3 id = :val                          # a value: captured, and returned
        end
        @test r == 5
        codes = Pinax.current_document().pages[1].codes
        @test ran[] == 0 && codes[1].output == ""
        @test leaked == 42 && codes[2].output == "42" && codes[2].caption == "assign"
        @test f1 == 2 && codes[3].output == ""
        @test codes[4].id === :val && codes[4].output == "5"
    end
end
