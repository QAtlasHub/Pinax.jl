using Pinax
using Test

# `Pinax.contents` builds a cross-gallery meta-index: a standalone page linking to several
# independently rendered galleries' index.html files. It reuses the gallery card/toc markup.
@testset "contents: cross-gallery meta-index" begin
    tmp = mktempdir()
    sitedir(name) = joinpath(tmp, name)

    entries = [
        (;
            title="Thermal",
            href="thermal/index.html",
            summary="Equilibrium TPQ",
            thumbnail="thermal/cv.svg",
            meta="3 pages · 40 figures",
            items=["Heat capacity", "Entropy"],
        ),
        (; title="Quench", href="quench/index.html"),   # only the required fields
    ]

    @testset "returns the written index.html path" begin
        path = Pinax.contents(entries; out=sitedir("c1"), title="Atlas")
        @test path == joinpath(sitedir("c1"), "index.html")
        @test isfile(path)
    end

    @testset "default :cards renders a card per entry" begin
        html = read(Pinax.contents(entries; out=sitedir("c2"), title="Atlas"), String)
        @test occursin("<title>Atlas</title>", html)
        @test occursin("2 galleries", html)
        @test occursin("<div class=\"pinax-cards\">", html)
        @test occursin("<a class=\"pinax-card\" href=\"thermal/index.html\">", html)
        @test occursin("<a class=\"pinax-card\" href=\"quench/index.html\">", html)
        @test occursin("<div class=\"card-title\">Thermal</div>", html)
        @test occursin("<div class=\"card-summary\">Equilibrium TPQ</div>", html)
        @test occursin("<img src=\"thermal/cv.svg\"", html)            # thumbnail referenced as-is
        @test occursin("<div class=\"card-meta\">3 pages · 40 figures</div>", html)
        # the bare entry: empty thumb, no summary, no meta
        @test occursin("card-thumb card-thumb-empty", html)
        @test count("<div class=\"card-summary\">", html) == 1         # only Thermal has one
        @test !occursin("<div class=\"card-sections\">", html)         # items shown only at :rich
    end

    @testset "level=:rich lists each entry's items" begin
        html = read(
            Pinax.contents(entries; out=sitedir("c3"), title="Atlas", level=:rich), String
        )
        @test occursin("<div class=\"card-sections\">", html)
        @test occursin("<div class=\"sec-item\">Heat capacity</div>", html)
        @test occursin("<div class=\"sec-item\">Entropy</div>", html)
        @test occursin("<div class=\"card-summary\">Equilibrium TPQ</div>", html)  # still shown
        # an explicit empty `items` vector is suppressed too (distinct from an absent field)
        empty_items = read(
            Pinax.contents(
                [(; title="A", href="a.html", items=String[])];
                out=sitedir("c3b"),
                level=:rich,
            ),
            String,
        )
        @test !occursin("<div class=\"card-sections\">", empty_items)
    end

    @testset "level=:toc is a compact link list, not cards" begin
        html = read(
            Pinax.contents(entries; out=sitedir("c4"), title="Atlas", level=:toc), String
        )
        @test occursin("<ul class=\"pinax-toc\">", html)
        @test !occursin("<div class=\"pinax-cards\">", html)
        @test occursin("<a href=\"thermal/index.html\">Thermal</a>", html)
        @test occursin("<span class=\"toc-summary\">— Equilibrium TPQ</span>", html)
        @test occursin("<span class=\"toc-meta\">(3 pages · 40 figures)</span>", html)
    end

    @testset "HTML in fields is escaped" begin
        html = read(
            Pinax.contents(
                [(; title="A & B", href="a.html", summary="x<y")]; out=sitedir("c5")
            ),
            String,
        )
        @test occursin("A &amp; B", html)
        @test occursin("x&lt;y", html)
    end

    @testset "errors: missing required field and bad level" begin
        @test_throws ErrorException Pinax.contents([(; title="no href")]; out=sitedir("e1"))
        @test_throws ErrorException Pinax.contents(
            [(; title="A", href="a.html")]; out=sitedir("e2"), level=:bogus
        )
    end

    @testset "no entries renders a valid, empty index" begin
        path = Pinax.contents(NamedTuple[]; out=sitedir("c6"), title="Empty Atlas")
        html = read(path, String)
        @test isfile(path)
        @test occursin("0 galleries", html)
        @test occursin("<div class=\"pinax-cards\">", html)   # container present, no cards inside
        @test !occursin("<a class=\"pinax-card\"", html)
    end
end

@testset "contents: the collection's own numbers, above the entries" begin
    out = mktempdir()
    html = read(
        Pinax.contents(
            [(; title="A", href="a/index.html"), (; title="B", href="b/index.html")];
            out=out,
            title="Registry",
            stats=["records" => 2, "projects" => 1, "unreproducible" => 0],
        ),
        String,
    )
    @test occursin("<div class=\"pinax-stats\">", html)
    @test occursin(">records<", html)
    @test occursin(">unreproducible<", html)
    @test occursin(">0<", html)                       # a zero is a result, not a reason to hide the row

    # no stats, no strip: the page a caller already has does not change
    plain = read(
        Pinax.contents([(; title="A", href="a/index.html")]; out=mktempdir()), String
    )
    # the class name is in the stylesheet on every page, so the claim is about the MARKUP
    @test !occursin("<div class=\"pinax-stats\">", plain)

    # values are escaped, not trusted
    esc = read(
        Pinax.contents(
            [(; title="A", href="a/index.html")];
            out=mktempdir(),
            stats=["<b>label</b>" => "<script>x</script>"],
        ),
        String,
    )
    @test !occursin("<script>x</script>", esc)
    @test occursin("&lt;script&gt;", esc)
end

@testset "contents: tags are shown, filterable, and search is opt-in" begin
    entries = [
        (; title="A", href="a/index.html", tags=["chaos", "example"]),
        (; title="B", href="b/index.html", tags=["example"]),
        (; title="C", href="c/index.html"),
    ]
    html = read(Pinax.contents(entries; out=mktempdir()), String)

    # the chips a reader clicks, one per distinct tag, and an "all" that clears
    @test occursin("<div class=\"pinax-filters\"", html)
    @test occursin("data-tag=\"chaos\"", html)
    @test count("data-tag=\"example\"", html) == 1        # distinct, not once per card
    @test occursin("data-tag=\"\"", html)

    # the cards carry what the filter matches on, and show it
    @test occursin("data-tags=\"chaos example\"", html)
    @test occursin("<span class=\"card-tag\">chaos</span>", html)
    @test !occursin("data-tags=\"\"", html)               # an untagged card carries no empty attr

    # a collection with no tags gets no bar at all
    plain = read(
        Pinax.contents([(; title="A", href="a/index.html")]; out=mktempdir()), String
    )
    @test !occursin("<div class=\"pinax-filters\"", plain)

    # the same at :toc — the bar is emitted at every level, so the rows must match on something
    toc = read(Pinax.contents(entries; out=mktempdir(), level=:toc), String)
    @test occursin("<li data-tags=\"chaos example\">", toc)
    @test occursin("<div class=\"pinax-filters\"", toc)

    # search is emitted only when asked: a box over an index that was never built is worse than none
    @test !occursin("pagefind-ui.js", html)
    withsearch = read(Pinax.contents(entries; out=mktempdir(), search=true), String)
    @test occursin("pagefind/pagefind-ui.js", withsearch)
    @test occursin("pagefind/pagefind-ui.css", withsearch)
    @test occursin("id=\"pinax-search\"", withsearch)
end
