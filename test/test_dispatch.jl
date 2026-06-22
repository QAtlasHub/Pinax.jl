using Pinax
using Test

# The default HTML gallery renders by multiple dispatch on the theme type: its per-node methods
# (emit_document / emit_section / emit_view / emit_figure, notes 11) live on the abstract `GalleryBase`,
# so a custom theme `<: GalleryBase` inherits the whole gallery and overrides only the dispatch points
# it wants. Here a variant overrides just emit_figure and inherits everything else.

struct BadgeGallery <: Pinax.GalleryBase end
function Pinax.emit_figure(::BadgeGallery, fig, ctx)
    return println(ctx.io, "<figure id=\"", fig.anchor, "\">BADGE:", fig.id, "</figure>")
end

@testset "gallery dispatch: GalleryBase variant overrides one point, inherits the rest" begin
    tmp = mktempdir()
    svg = joinpath(tmp, "f.svg")
    write(svg, "<svg xmlns='http://www.w3.org/2000/svg'><rect/></svg>")
    Pinax.reset!(; title="dispatch")
    @page :p "P" begin
        @section :s "S" begin
            @figure svg
            @caption "cap"
        end
    end

    g = read(Pinax.render(; out=joinpath(tmp, "default"), theme=:gallery), String)
    b = read(Pinax.render(; out=joinpath(tmp, "variant"), theme=BadgeGallery()), String)

    @test occursin("<figcaption>", g)        # default figure rendering (caption etc.)
    @test !occursin("BADGE:", g)
    @test occursin("BADGE:s_fig1", b)         # the variant's emit_figure is dispatched
    @test !occursin("<figcaption>", b)        # …replacing the default figure entirely
    @test occursin("<title>dispatch", b)      # but emit_document (the shell) is inherited
    @test occursin("class=\"section\"", b)    # …and emit_section too
end

# The points that used to be internal `_*` helpers (emit_text/emit_comments/emit_page/emit_index) are
# now real dispatch points too — a variant can override them. No structural gap.
struct PlainText <: Pinax.GalleryBase end
Pinax.emit_text(::PlainText, source, item, ctx; block=true) = string("TXT[", source, "]")

@testset "emit_text is a dispatch point (a once-internal gap, now closed)" begin
    tmp = mktempdir()
    svg = joinpath(tmp, "f.svg")
    write(svg, "<svg xmlns='http://www.w3.org/2000/svg'><rect/></svg>")
    Pinax.reset!(; title="t")
    @page :p "P" begin
        @section :s "S" begin
            @desc md"hello"
            @figure svg
        end
    end
    h = read(Pinax.render(; out=joinpath(tmp, "o"), theme=PlainText()), String)
    @test occursin("TXT[hello]", h)   # the overridden text renderer is used for the section desc
end

# The latex and agent themes are abstract bases too (LaTeXBase / AgentBase), so they are overridable
# the same way — the per-node contract is uniform across all three formats. This also exercises
# emit_section(::AgentBase) (the "sections" array) and emit_comments(::LaTeXBase) (the Notes itemize).
struct TaggedTeX <: Pinax.LaTeXBase end
Pinax.emit_figure(::TaggedTeX, fig, ctx) = println(ctx.io, "%% TAGFIG ", fig.id)

struct TaggedAgent <: Pinax.AgentBase end
function Pinax.emit_figure(::TaggedAgent, fig, ctx)
    return print(ctx.io, "{\"id\":\"", fig.id, "\",\"tagged\":true}")
end

@testset "latex/agent variant overrides one point, inherits the rest" begin
    tmp = mktempdir()
    svg = joinpath(tmp, "f.svg")
    write(svg, "<svg xmlns='http://www.w3.org/2000/svg'><rect/></svg>")
    cf = joinpath(tmp, "comments.toml")
    mkpath(tmp)
    Pinax.reset!(; title="x")
    @page :p "P" begin
        @section :s "S" begin
            @desc md"d"
            @figure svg
            @caption "c"
        end
    end
    Pinax.add_comment(cf, :s, "a note"; author="me")

    # latex: emit_figure overridden; emit_document/page/section + emit_comments inherited
    tex = read(
        Pinax.render(; out=joinpath(tmp, "tex"), theme=TaggedTeX(), comments_file=cf),
        String,
    )
    @test occursin("%% TAGFIG s_fig1", tex)   # the override fired
    @test occursin("\\subsection{S}", tex)    # emit_section inherited
    @test occursin("Notes", tex)              # emit_comments (the section's comment) exercised

    # agent: emit_figure overridden; emit_section (the "sections" array) inherited
    Pinax.render(; out=joinpath(tmp, "agent"), theme=TaggedAgent(), comments_file=cf)
    j = read(joinpath(tmp, "agent", "agent.json"), String)
    @test occursin("\"tagged\":true", j)      # the override fired
    @test occursin("\"sections\":[", j)       # emit_section(::AgentBase) emitted the sections array
end
