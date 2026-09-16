# contents.jl — a standalone "map of contents": a meta-index that spans several independently
# rendered galleries. Where the gallery index links to the pages *within* one gallery, this links
# *across* galleries — each entry points at another gallery's `index.html`, one level up. It reuses
# the gallery card/toc CSS (`_GALLERY_CSS`) so the meta-index looks like a per-gallery index, but is
# otherwise a light, self-contained page (no KaTeX, no doc tree): the targets are pre-rendered.

# Read an optional entry field. Entries are NamedTuples (the documented form); the generic
# fallback also serves any Symbol-keyed collection (e.g. `Dict{Symbol,Any}`) via `get`.
_entry_get(e::NamedTuple, k::Symbol, default) = haskey(e, k) ? e[k] : default
_entry_get(e, k::Symbol, default) = get(e, k, default)

function _entry_str(e, k::Symbol)
    v = _entry_get(e, k, nothing)
    v === nothing && error("Pinax.contents: each entry needs a `$(k)` field; got $(e).")
    return string(v)
end

"""
    contents(entries; out, title="Contents", level=:cards, stats=(), search=false) -> path

Render a standalone meta-index linking to several separately rendered galleries, and return the
written `index.html` path. Use it to put a customizable "map of contents" one level above galleries
that were each produced by their own [`render`](@ref) call.

Each entry is a `NamedTuple` describing one target gallery:

| field       | required | meaning                                                       |
| ----------- | :------: | ------------------------------------------------------------- |
| `title`     |   yes    | gallery name (card title)                                     |
| `href`      |   yes    | link to that gallery's `index.html` (relative path or URL)    |
| `summary`   |    no    | one-line description                                          |
| `thumbnail` |    no    | image path/URL for the card thumbnail (referenced as-is)      |
| `meta`      |    no    | small caption line, e.g. `"12 pages · 540 figures"`           |
| `items`     |    no    | list of strings, shown under the summary at `:rich` (each `string`-ified) |
| `tags`      |    no    | list of strings, shown as chips and used by the filter bar     |

`stats` is an iterable of `label => value` pairs shown as a strip under the title, for the numbers
that describe the collection rather than any one entry (how many, how recent, how many of them are
missing something). A meta-index over many galleries is read for those first; without them the page
answers "what is here" and not "what state is it in".

Entries carrying `tags` also get a filter bar above the cards: clicking a chip narrows the page to
the entries that carry it. The filtering is a few lines of inline JavaScript over `data-tags`, so a
reader without a server, and a reader without JavaScript, both still get the whole list.

`search=true` mounts the [Pagefind](https://pagefind.app/) UI from `pagefind/` NEXT TO the generated
page, which is where `add_search` puts it. It is emitted only when asked, because a search box over
an index that was never built is worse than no box.

`level` mirrors the gallery index verbosity: `:toc` (link list), `:cards` (thumbnail cards,
default), `:rich` (cards + each entry's `items`). Hrefs and thumbnails are emitted verbatim, so give
paths relative to the generated `index.html` (or absolute URLs); this neither renders the galleries
nor copies their assets — the targets are expected to already exist.

```julia
Pinax.contents(
    [
        (; title="Thermal", href="thermal/index.html",
           summary="Equilibrium TPQ", thumbnail="thermal/assets/figures/cv.svg"),
        (; title="Quench", href="quench/index.html", summary="Global-quench dynamics"),
    ];
    out="site", title="Project Atlas",
)
```
"""
function contents(
    entries;
    out::AbstractString,
    title::AbstractString="Contents",
    level::Symbol=:cards,
    stats=(),
    search::Bool=false,
)
    level in (:toc, :cards, :rich) ||
        error("Pinax.contents: level must be :toc, :cards, or :rich (got :$(level)).")
    es = collect(entries)
    mkpath(out)
    io = IOBuffer()
    print(io, "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">")
    print(io, "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">")
    print(io, "<title>", _esc(title), "</title>", _GALLERY_CSS, "</head><body>\n")
    println(io, "<h1>", _esc(title), "</h1>")
    n = length(es)
    println(
        io, "<div class=\"pinax-meta\">", n, n == 1 ? " gallery" : " galleries", "</div>"
    )
    _emit_contents_stats(io, stats)
    search && _emit_contents_search(io)
    _emit_contents_filters(io, es)
    if level === :toc
        _emit_contents_toc(io, es)
    else
        _emit_contents_cards(io, es, level === :rich)
    end
    println(io, "</body></html>")
    path = joinpath(out, "index.html")
    write(path, String(take!(io)))
    return path
end

# The collection's own numbers, under the title. Values are stringified and escaped: the caller
# supplies data, the theme supplies the look, so a meta-index cannot grow a second style vocabulary.
function _emit_contents_stats(io, stats)
    ss = collect(stats)
    isempty(ss) && return nothing
    println(io, "<div class=\"pinax-stats\">")
    for kv in ss
        label, value = first(kv), last(kv)
        print(
            io,
            "<div class=\"pinax-stat\"><span class=\"stat-value\">",
            _esc(string(value)),
            "</span><span class=\"stat-label\">",
            _esc(string(label)),
            "</span></div>",
        )
    end
    println(io, "\n</div>")
    return nothing
end

# Pagefind's own UI, served from the bundle `add_search` writes beside this page. Self-hosted: no
# CDN, nothing to resolve at read time, and a registry read off a laptop behaves like the published
# one.
function _emit_contents_search(io)
    println(io, "<link rel=\"stylesheet\" href=\"pagefind/pagefind-ui.css\">")
    println(io, "<div class=\"pinax-search\" id=\"pinax-search\"></div>")
    println(io, "<script src=\"pagefind/pagefind-ui.js\"></script>")
    println(
        io,
        "<script>window.addEventListener('DOMContentLoaded',function(){",
        "if(window.PagefindUI){new PagefindUI({element:'#pinax-search',showImages:false});}",
        "else{document.getElementById('pinax-search').remove();}});</script>",
    )
    return nothing
end

# Every tag that appears, as a row of toggles. The cards carry `data-tags`, so the filter is a
# string match in the page rather than a query anywhere.
function _emit_contents_filters(io, entries)
    tags = String[]
    for e in entries
        for t in _entry_get(e, :tags, ())
            st = string(t)
            (isempty(st) || st in tags) || push!(tags, st)
        end
    end
    isempty(tags) && return nothing
    sort!(tags)
    println(io, "<div class=\"pinax-filters\" id=\"pinax-filters\">")
    print(io, "<button class=\"pinax-chip is-on\" data-tag=\"\">all</button>")
    for t in tags
        print(
            io,
            "<button class=\"pinax-chip\" data-tag=\"",
            _esc(t),
            "\">",
            _esc(t),
            "</button>",
        )
    end
    println(io, "\n</div>")
    println(
        io,
        "<script>(function(){var bar=document.getElementById('pinax-filters');",
        "if(!bar)return;bar.addEventListener('click',function(ev){",
        "var b=ev.target.closest('.pinax-chip');if(!b)return;",
        "var t=b.getAttribute('data-tag');",
        "bar.querySelectorAll('.pinax-chip').forEach(function(c){c.classList.toggle('is-on',c===b);});",
        "document.querySelectorAll('.pinax-card,.pinax-toc>li').forEach(function(card){",
        "var ts=(card.getAttribute('data-tags')||'').split(' ');",
        "card.style.display=(!t||ts.indexOf(t)>=0)?'':'none';});});})();</script>",
    )
    return nothing
end

function _emit_contents_cards(io, entries, rich::Bool)
    println(io, "<div class=\"pinax-cards\">")
    for e in entries
        thumb = _entry_get(e, :thumbnail, nothing)
        summary = _entry_get(e, :summary, nothing)
        metaline = _entry_get(e, :meta, nothing)
        items = _entry_get(e, :items, nothing)
        tags = String[string(t) for t in _entry_get(e, :tags, ())]
        print(io, "<a class=\"pinax-card\"")
        isempty(tags) || print(io, " data-tags=\"", _esc(join(tags, " ")), "\"")
        print(io, " href=\"", _esc(_entry_str(e, :href)), "\">")
        if thumb === nothing
            print(io, "<div class=\"card-thumb card-thumb-empty\"></div>")
        else
            print(
                io,
                "<div class=\"card-thumb\"><img src=\"",
                _esc(string(thumb)),
                "\" alt=\"\"></div>",
            )
        end
        print(
            io,
            "<div class=\"card-body\"><div class=\"card-title\">",
            _esc(_entry_str(e, :title)),
            "</div>",
        )
        summary === nothing ||
            print(io, "<div class=\"card-summary\">", _esc(string(summary)), "</div>")
        if rich && items !== nothing && !isempty(items)
            print(io, "<div class=\"card-sections\">")
            for it in items
                print(io, "<div class=\"sec-item\">", _esc(string(it)), "</div>")
            end
            print(io, "</div>")
        end
        if !isempty(tags)
            print(io, "<div class=\"card-tags\">")
            for t in tags
                print(io, "<span class=\"card-tag\">", _esc(t), "</span>")
            end
            print(io, "</div>")
        end
        metaline === nothing ||
            print(io, "<div class=\"card-meta\">", _esc(string(metaline)), "</div>")
        print(io, "</div></a>")
    end
    return println(io, "</div>")
end

function _emit_contents_toc(io, entries)
    println(io, "<ul class=\"pinax-toc\">")
    for e in entries
        summary = _entry_get(e, :summary, nothing)
        metaline = _entry_get(e, :meta, nothing)
        tags = String[string(t) for t in _entry_get(e, :tags, ())]
        # The filter bar is emitted at every level, so a `:toc` row has to carry what it matches on
        # or a click would empty the page.
        print(io, "<li")
        isempty(tags) || print(io, " data-tags=\"", _esc(join(tags, " ")), "\"")
        print(
            io,
            "><a href=\"",
            _esc(_entry_str(e, :href)),
            "\">",
            _esc(_entry_str(e, :title)),
            "</a>",
        )
        summary === nothing ||
            print(io, " <span class=\"toc-summary\">— ", _esc(string(summary)), "</span>")
        metaline === nothing ||
            print(io, " <span class=\"toc-meta\">(", _esc(string(metaline)), ")</span>")
        print(io, "</li>")
    end
    return println(io, "</ul>")
end
