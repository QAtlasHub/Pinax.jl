using Pinax
using Test

# The comment store is read where it enters: every shape it may hold is either read or reported, and
# every comment or bookmark a face cannot show is reported the same way.

# The diagnostics `_read_comments` records for `toml` against the current document.
function _store_diags(toml)
    f = joinpath(mktempdir(), "comments.toml")
    write(f, toml)
    rdiag = Pinax.DiagEntry[]
    comments, bookmarks = Pinax._read_comments(Pinax.current_document(), f, rdiag)
    return comments, bookmarks, rdiag
end
function _said(rdiag, item, words...)
    return any(d -> d.item == item && all(w -> occursin(w, d.message), words), rdiag)
end

@testset "the comment store's top-level shape is checked where it enters" begin
    Pinax.reset!()
    @page :p "P" begin
        @section :s "S" begin end
    end
    for toml in ("[[comment]]\ntext = \"hi\"\n", "comment = \"x\"\n", "comment = 3\n")
        comments, _, rdiag = _store_diags(toml)
        @test isempty(comments)
        @test _said(rdiag, "comments.toml", "`comment`", "[[comment.<id>]]")
    end
    for toml in ("bookmark = true\n", "[[bookmark]]\ns = true\n")
        _, bookmarks, rdiag = _store_diags(toml)
        @test isempty(bookmarks)
        @test _said(rdiag, "comments.toml", "`bookmark`", "[bookmark]")
    end
    # a render reports it, and still writes its face
    out = mktempdir()
    write(joinpath(out, "comments.toml"), "comment = \"x\"\nbookmark = true\n")
    Pinax.render(; out=out, theme=:agent)
    md = read(joinpath(out, "agent.md"), String)
    diag = md[first(findfirst("## Diagnostics", md)):end]
    @test occursin("`comment`", diag) && occursin("`bookmark`", diag)
end
