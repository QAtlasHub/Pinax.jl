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

@testset "a bookmark no face can show is a diagnostic, like a comment" begin
    Pinax.reset!()
    @page :p "P" begin
        @figure "a.svg" id = :f
        @section :s "S" begin end
    end
    toml = """
    [bookmark]
    s = true
    f = true
    p = true
    gone = true
    off = false
    """
    _, bookmarks, rdiag = _store_diags(toml)
    @test Set([:s, :f, :p, :gone]) == bookmarks   # read as written; only the faces decide
    @test _said(rdiag, "gone", "bookmark", "names no node")
    @test _said(rdiag, "f", "bookmark on a figure", "sections")
    @test _said(rdiag, "p", "bookmark on a page", "sections")
    @test !any(d -> d.item in ("s", "off"), rdiag)   # a shown one, and one that is off
    @test !any(d -> occursin("feature is off", d.message), rdiag)

    # the :bookmarks feature off hides every bookmark, and is said once, like comments
    Pinax.reset!(; features=(:comments,))
    @page :p "P" begin
        @section :s "S" begin end
    end
    _, _, rdiag = _store_diags("[bookmark]\ns = true\n")
    @test _said(rdiag, "comments.toml", "bookmarks", ":bookmarks feature is off")
    _, _, rdiag = _store_diags("[bookmark]\ns = false\n")
    @test isempty(rdiag)   # nothing set, nothing hidden
end

@testset "a data= figure's generated id follows its data, not its position" begin
    a = (; x=[1.0, 2.0], y=[3.0, 4.0])
    b = (; x=[1.0, 2.0], y=[3.0, 5.0])
    function ids(first, second)
        Pinax.reset!()
        @page :p "P" begin
            @figure nothing data = first
            @figure nothing data = second
            @figure "plain.svg"
        end
        return [f.id for f in Pinax.current_document().pages[1].figures]
    end
    ab = ids(a, b)
    ba = ids(b, a)
    @test ab[1] == ba[2] && ab[2] == ba[1]   # reordering keeps each figure's id
    @test !any(id -> endswith(string(id), "-2"), ab)
    @test ab[3] === :p_fig_0zfg0yp   # a figure without data= keeps the id it had
end
