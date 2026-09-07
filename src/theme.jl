# theme.jl — the theme framework (notes 06/08).
#
# The SHELL only: the abstract `Theme` type, the generic functions a theme specializes, the registry,
# and resolution from a spec. Concrete themes live in `themes/` — the default `GalleryTheme` is
# `themes/gallery.jl`. How to write one is the `Theme` docstring below.

"""
    abstract type Theme

A renderer over the presentation-neutral document tree: one theme is one way to write a `Document`
out. `render(; theme = …)` resolves a `Theme` instance, a registered `Symbol`, or a path to a file
that defines one.

`emit_document` is the one required method — it receives the whole document and writes the output.
A theme that subtypes `Theme` directly owns that traversal, so it needs nothing else:

```julia
struct MyTheme <: Pinax.Theme end
Pinax.emit_document(::MyTheme, doc, out, cache; comments_file="") = ...   # write files, return a path
Pinax.register_theme!(:mine, MyTheme())                                   # optional: resolve by theme=:mine
```

Then `render(; out, theme=MyTheme())`, `theme=:mine`, or `theme="path/to/mytheme.jl"`. Omitting
`emit_document` is refused by name at the first `render`, not at subtyping time.

The shipped bases — `GalleryBase` (HTML), `LaTeXBase`, `AgentBase` — instead implement
`emit_document` as a walk that dispatches to one generic per node (`emit_page`, `emit_section`,
`emit_figure`, `emit_table`, `emit_check`, `emit_code`, `emit_text`, `emit_view`, `emit_comments`,
`emit_index`). Subtype one of those to change some nodes and inherit the rest; those generics have
no fallback of their own, so they are only relevant once something calls them.

Traits, which do have defaults: `output_format` (`:html` | `:latex` | `:agent`), `figure_formats`
(which formats are requested from figure objects), `index_level`, `figure_as_table` and `number`.
"""
abstract type Theme end

# ---- renderer contract (themes override these; only emit_document is required) ----

output_format(::Theme) = :html            # :html | :latex
figure_formats(::Theme) = Symbol[:svg]    # formats requested from figure objects (paths copied as-is)
index_level(::Theme) = :cards             # default table-of-contents verbosity (:toc | :cards | :rich)
figure_as_table(::Theme) = false          # if true, a backend presents a @figure AS its data table (LLM view)
number(::Theme, node) = nothing           # optional numbering override (the gallery numbers server-side)

# ---- per-node rendering contract (the "display UI" for each IR node; notes 11) ----
#
# A theme renders by specializing these generic functions on its theme type via multiple dispatch.
# The default HTML gallery defines them on the abstract `GalleryBase` (themes/gallery.jl), so a custom
# theme `struct MyTheme <: GalleryBase end` inherits them all and overrides only what it needs.
# `ctx` is the theme's own per-render state, passed opaquely.

"Render the multi-page index of pages. `emit_index(theme, doc, io, outdir, bookmarks)`."
function emit_index end

"Render one page's body (its page-level content + in-page sections). `emit_page(theme, page, ctx)`."
function emit_page end

"Render one section into the theme's output stream. `emit_section(theme, section, page, ctx)`."
function emit_section end

"""
    emit_view(theme, ::Val{view}, figs, assetdir, layout, ctx)

Render a unit's figures in the named `view`. The default view is `:grid`; add a method on
`::Val{:graph}` / `::Val{:table}` (etc.) to introduce a new per-unit presentation.
"""
function emit_view end

"Render one figure — its assets, caption and co-located comments. `emit_figure(theme, figure, ctx)`."
function emit_figure end

"Render one table artifact (an HTML/LaTeX table, or a JSON object with native-typed rows). `emit_table(theme, table, ctx)`."
function emit_table end

"Render one `@expect` check (a gallery `<tr>`, a LaTeX tabular row, or a JSON check object). `emit_check(theme, check, ctx)`."
function emit_check end

"Render one `@code` block (source + captured output). `emit_code(theme, codeblock, ctx)`."
function emit_code end

"Render a markdown+math source (a `@desc`/`@caption`). `emit_text(theme, source, item, ctx; block)`."
function emit_text end

"Render a node's id-keyed comments inline. `emit_comments(theme, anchor, ctx)`."
function emit_comments end

"""
    emit_document(theme, doc, outdir, cache; comments_file) -> path

Render `doc` into `outdir` and return the entry-file path. This is the one method every theme must
implement; `render` dispatches here on the resolved theme.
"""
function emit_document(theme::Theme, doc, outdir, cache; kwargs...)
    return error(
        "Pinax: theme $(typeof(theme)) does not implement `emit_document`. " *
        "Define `Pinax.emit_document(::$(typeof(theme)), doc, outdir, cache; comments_file)`.",
    )
end

# ---- theme registry + resolution ----

const _THEMES = Dict{Symbol,Theme}()

"Register `theme` under `name` so it can be selected with `@pinaxsetup theme=name` / `render(theme=name)`."
register_theme!(name::Symbol, theme::Theme) = (_THEMES[name] = theme)

"""
    _resolve_theme(spec) -> Theme

Resolve a theme spec to a `Theme`: a `Theme` instance is returned as-is; a `Symbol` is looked up in
the registry; an `AbstractString` is treated as a path to a `.jl` file that must evaluate to a `Theme`.
"""
_resolve_theme(t::Theme) = t
function _resolve_theme(name::Symbol)
    haskey(_THEMES, name) || error(
        "Pinax: unknown theme :$(name). Registered themes: $(sort(collect(keys(_THEMES)))).",
    )
    return _THEMES[name]
end
function _resolve_theme(path::AbstractString)
    isfile(path) || error("Pinax: theme file not found: $(path)")
    # Evaluated as a script in Main, so a user theme file reads naturally:
    # `using Pinax; struct MyTheme <: Pinax.Theme end; Pinax.emit_document(...) = …; MyTheme()`.
    t = Base.include(Main, abspath(path))
    t isa Theme || error(
        "Pinax: theme file $(path) must evaluate to a Theme (its last expression); got $(typeof(t)).",
    )
    return t
end
function _resolve_theme(x)
    return error(
        "Pinax: cannot resolve theme from $(repr(x)); pass a Theme, Symbol, or path."
    )
end

include("themes/gallery.jl")   # default theme (registers :gallery)
include("themes/latex.jl")     # LaTeX/PDF theme (registers :latex); reuses gallery helpers
include("themes/agent.jl")     # agent/MCP backend (registers :agent); structured data, not HTML
