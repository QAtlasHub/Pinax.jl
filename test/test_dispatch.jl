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
