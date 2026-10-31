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

# Pins for behavior-preserving refactors of the structure and content macros.
function _expand_error(ex)
    try
        macroexpand(@__MODULE__, ex)
    catch e
        return sprint(showerror, e isa LoadError ? e.error : e)
    end
    return ""
end

@testset "structure macros: arity, keywords and the written id" begin
    for (m, ex) in (
        ("@page", :(@page :p "T")),
        ("@part", :(@part :g "G")),
        ("@section", :(@section :s "S")),
    )
        @test occursin("$(m) needs :id, \"title\", and a begin…end body", _expand_error(ex))
    end
    Pinax.reset!()
    @part :g "G" status = :draft desc = md"overview" begin
        @page :p "P" summary = "sum" layout = :wide begin
            @section :s "S" by = "L" summary = "ss" begin end
        end
    end
    @page :q "Q" status = :final begin end
    doc = Pinax.current_document()
    p, q = doc.pages
    @test (p.part, p.status, p.summary, p.layout) == (:g, :draft, "sum", :wide)
    @test (q.part, q.status) == (nothing, :final)
    s = p.sections[1]
    @test (s.facet, s.summary, s.depth) == ("L", "ss", 2)
    @test doc.part_descs[:g].source == "overview"
    @test issubset([:g, :p, :s, :q], doc.written)
end

@testset "@raw: one expression, an optional id, in any order" begin
    Pinax.reset!()
    @page :p "P" begin
        @raw "<i>a</i>"
        @raw id = :r "<i>b</i>"
        @raw "<i>c</i>" id = :r2
    end
    raws = Pinax.current_document().pages[1].raws
    @test [r.html for r in raws] == ["<i>a</i>", "<i>b</i>", "<i>c</i>"]
    @test raws[1].id === :p_raw_18o6f69
    @test raws[2].id === :r && raws[3].id === :r2
    @test endswith(raws[1].defined_at, "test_r3_doc.jl:$(@__LINE__() - 8)")
    @test occursin("@raw", _expand_error(:(@raw "a" "b")))
    @test occursin("@raw needs", _expand_error(:(@raw id = :x)))
end

@testset "content order, captions and subtree checks" begin
    Pinax.reset!()
    @page :p "P" begin
        @test 1 == 1
        @caption "pd"
        @desc md"text"
        @section :s1 "S1" begin
            @test 2 == 2
            @caption "a"
            @section :s2 "S2" begin
                @test 3 == 3
                @caption "b"
            end
            @test 4 == 4
            @caption "c"
        end
        @figure "x.svg" id = :f
        @caption "fig"
        @section :s3 "S3" begin
            @test 5 == 5
            @caption "d"
        end
    end
    pg = Pinax.current_document().pages[1]
    @test [k for (k, _) in Pinax._content_items(pg)] == [:code, :check, :text, :section, :figure, :section]   # a @test brings its code
    @test Pinax._content_items(pg)[5][2].caption == "fig"
    labels(c) = [chk.label for chk in Pinax._subtree_checks(c)]
    @test labels(pg) == ["pd", "a", "c", "b", "d"]   # own checks, then each section's subtree
    @test labels(pg.sections[1]) == ["a", "c", "b"]
    @test Pinax.verdict(pg.sections[1]).total == 3
end
