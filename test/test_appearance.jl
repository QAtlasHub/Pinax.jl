using Pinax
using Test

# `appearance=` is which of the theme's two palettes a reader gets before they have chosen one;
# `theme=` is which theme renders the page at all. Two axes, two words a page author will mix up.
#
# What these check is the shape of the page, not the shade of it: that the default reaches the
# markup, that the control is there and self-contained, and that the two dark blocks say the same
# thing. Whether the cascade then lands on the right colour is a browser's job, and the cycle the
# control performs was measured in one — neither belongs in a Julia test suite.

function svg_in(dir)
    p = joinpath(dir, "a.svg")
    write(p, "<svg xmlns='http://www.w3.org/2000/svg'><rect/></svg>")
    return p
end

# One page, rendered: its HTML, and the stylesheet that page is actually styled by (the shared
# style.css under `assets=:default`, the page itself under `:inline`).
function rendered(; kw...)
    tmp = mktempdir()
    svg = svg_in(tmp)
    Pinax.reset!(; title="x", kw...)
    @page :a "A" begin
        @figure svg
    end
    out = joinpath(tmp, "site")
    Pinax.render(; out=out)
    html = read(joinpath(out, "index.html"), String)
    sheet = joinpath(out, "style.css")
    return (; html, css=isfile(sheet) ? read(sheet, String) : html)
end

@testset "appearance=: the colour scheme a reader gets before choosing one" begin
    @testset "it is not theme=, and says so" begin
        e = try
            Pinax.reset!(; appearance=:midnight)
            nothing
        catch err
            err
        end
        @test e isa ErrorException
        @test occursin(":system, :light, or :dark", e.msg)
        @test occursin(":midnight", e.msg)
        @test occursin("`theme=`", e.msg)          # the setting they probably meant
    end

    @testset "the default is :system, and it reaches the page" begin
        for want in ("system", "light", "dark")
            r = want == "system" ? rendered() : rendered(; appearance=Symbol(want))
            m = match(r"<script>\(function\(\)\{var d=\"(\w+)\",v;", r.html)
            @test m !== nothing
            @test m[1] == want
        end
    end

    @testset "the choice is applied before the stylesheet, or the page flashes" begin
        r = rendered(; appearance=:dark)
        @test occursin("setAttribute(\"data-theme\",v)", r.html)
        # Before *every* stylesheet, not just the theme's own. KaTeX's comes from a CDN, and a
        # blocking sheet in front of this script holds the attribute behind a round trip.
        link = findfirst("<link rel=\"stylesheet\"", r.html)
        @test link !== nothing
        @test findfirst("data-theme", r.html)[1] < link[1]
    end

    @testset "the control is on the page, hidden until its script runs" begin
        r = rendered()
        @test occursin("<button class=\"pinax-appearance\" type=\"button\" hidden>", r.html)
        @test occursin("b.hidden=false", r.html)   # unhidden only where JavaScript runs
    end

    @testset "both palettes ship, in both asset modes" begin
        for mode in (:default, :inline)
            r = rendered(; assets=mode)
            @test occursin("prefers-color-scheme:dark", r.css)
            @test occursin(":root[data-theme=\"dark\"]", r.css)
            # An explicit light has to win over a dark desktop, so the query steps aside for it.
            @test occursin(":root:not([data-theme=\"light\"])", r.css)
        end
    end

    @testset "the two dark blocks are one block, printed twice" begin
        # They are interpolated from `_DARK_TOKENS` precisely so they cannot drift; this is the
        # test that notices if someone ever hand-edits one of them.
        r = rendered()
        blocks = [m[1] for m in eachmatch(r"--bg:#0d1117;(.*?)--warn-bg:#\w+;"s, r.css)]
        @test length(blocks) == 2
        @test blocks[1] == blocks[2]
    end

    # Relative luminance and contrast, as WCAG 2.1 defines them.
    _lin(c) = c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055)^2.4
    function _lum(hex)
        h = lstrip(hex, '#')
        length(h) == 3 && (h = join(c^2 for c in h))
        r, g, b = (parse(Int, h[i:(i + 1)]; base=16) / 255 for i in (1, 3, 5))
        return 0.2126_lin(r) + 0.7152_lin(g) + 0.0722_lin(b)
    end
    function contrast(a, b)
        lo, hi = extrema((_lum(a) + 0.05, _lum(b) + 0.05))
        return hi / lo
    end

    # The tokens as the sheet that ships defines them, light and dark, so this measures what a reader
    # gets rather than what a table in a test says they get.
    function tokens(block)
        return Dict(
            m[1] => m[2] for
            m in eachmatch(r"--([a-z0-9-]+)\s*:\s*(#[0-9a-fA-F]{3,6})", block)
        )
    end

    @testset "the control can be found as well as read" begin
        # A button is not text, and the rule for it is different: WCAG 1.4.11 asks 3:1 of the boundary
        # that says a control is there. The fill cannot do that job — `--card` on `--bg` is 1.04:1 in
        # light and 1.09:1 in dark — so the border carries it, and both palettes are measured, because
        # a control visible in one and not the other is one half the readers never find.
        light = tokens(match(r":root\{(.*?)\}"s, Pinax._GALLERY_CSS)[1])
        dark = tokens(Pinax._DARK_TOKENS)
        for P in (light, dark)
            @test contrast(P["card"], P["bg"]) < 1.5           # the fill really is no boundary
            @test contrast(P["mut"], P["bg"]) >= 3.0           # …so the border is, against the page
            @test contrast(P["mut"], P["card"]) >= 4.5         # the label, on its own fill
            @test contrast(P["fg"], P["card"]) >= 4.5          # and on hover
        end
        # …and nothing in the rule dims it back down. `opacity` composites the button toward the page:
        # at .75 it took the label to 3.62 in light and 3.88 in dark, under the 4.5 text wants.
        rule = match(r"\.pinax-appearance\{(.*?)\}"s, Pinax._GALLERY_CSS)[1]
        @test !occursin("opacity", rule)
        @test occursin("border:1px solid var(--mut)", rule)
    end

    @testset "the control does not depend on an external script" begin
        # A report is archived as a directory and read again years later, possibly without the
        # `app.js` that did not travel with it. Under `assets=:default` everything else is
        # externalized; this must not be.
        r = rendered(; assets=:default)
        @test occursin("addEventListener(\"click\"", r.html)
        @test occursin("localStorage.setItem", r.html)
    end
end
