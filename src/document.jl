# document.jl — document model + structure macros (notes 02).
#
# Implements render pass 1 (structure): the macros only assemble the doc tree
# (placeholders). The `@figure` expression is NOT evaluated here — it is captured
# as the deferred generator `gen` (materialize happens in pass 3).

# ============================================================ value types

"Markdown + LaTeX source (unrendered; the theme draws it)."
struct Desc
    source::String
end

"Lightweight handle pointing at a figure (used by thumbnails, etc.)."
struct FigRef
    id::Symbol
end

"Diagnostic severity (notes 09)."
@enum Severity ERROR WARNING INFO

"One diagnostic. `item` is the anchor of the related page/section/figure."
struct DiagEntry
    severity::Severity
    item::String
    message::String
end

"error/warning entries collected during render (-> diagnostics page, notes 09)."
struct Diagnostics
    entries::Vector{DiagEntry}
end
Diagnostics() = Diagnostics(DiagEntry[])

"""
Default numbering function: `Sec. N` / `Fig. N` / `(N)` for equations. Override it in the
preamble with `@pinaxsetup numberer = (kind, c) -> …`, where `kind` is `:section`, `:figure`,
or `:equation` and `c` is `(; page, page_id, section, figure, subfigure, equation)` — `page` is
the 1-based page index and `page_id` its id (Symbol), so a numberer can prefix per "part" (e.g.
`c.page_id === :eq ? "EQ\$(c.section)" : "GQ\$(c.section)"`, usually with `numbering=:page`);
`section` is the current section number, `figure` the document-wide figure count, `subfigure`
the figure's index within its section (for hierarchical schemes like `Fig. 2.3`), and `equation`
the document-wide equation count.
"""
function _default_numberer(kind::Symbol, c)
    kind === :page && return ""   # pages are titled, not numbered, by default (override for EQ/GQ-style badges)
    kind === :section && return "Sec. $(c.section)"
    kind === :figure && return "Fig. $(c.figure)"
    return "($(c.equation))"   # :equation — paper-style "(n)"
end

"Document settings (analogous to TeX \\documentclass + preamble)."
mutable struct DocMeta
    title::String
    theme::Any                    # theme spec: a Theme instance, a registered Symbol, or a path
    bib_sources::Vector{String}
    debug::Bool
    index::Union{Symbol,Nothing}  # :toc|:cards|:rich override (nothing = theme default)
    numbering::Symbol             # counter scope :global | :page | :part
    numberer::Function            # (kind, counters) -> label string; preamble-overridable
    features::Vector{Symbol}      # gallery interactive layer toggles: :comments / :bookmarks / :export
    css::Vector{String}           # user CSS overlay files (inlined after the theme's own CSS)
    js::Vector{String}            # user JS overlay files (inlined after the theme's own JS)
    katex::Symbol                 # gallery math assets: :cdn (default) | :local (vendored, offline)
    assets::Symbol                # theme CSS/JS: :default (separate style.css/app.js) | :inline (embedded)
    appearance::Symbol            # the palette a reader who has not chosen one gets: :system | :light | :dark
end
function DocMeta(;
    title="",
    theme=:gallery,
    bib_sources=String[],
    debug=false,
    index=nothing,
    numbering=:global,
    numberer=_default_numberer,
    features=Symbol[:comments, :bookmarks, :export],
    css=String[],
    js=String[],
    katex=:cdn,
    assets=:default,
    appearance=:system,
)
    return DocMeta(
        title,
        theme,
        bib_sources,
        debug,
        index,
        numbering,
        numberer,
        collect(Symbol, features),
        collect(String, css),
        collect(String, js),
        katex,
        assets,
        appearance,
    )
end

"A single figure (placeholder). `gen` is deferred; `code` is the expression source for change detection (notes 10)."
mutable struct Figure
    id::Symbol
    anchor::String
    caption::String
    params::Any           # ParamIO.DataKey | Nothing — lineage + cache key material
    gen::Function         # () -> plot(...) (never called during structure)
    code::String          # @figure expression source
    thumbnail::Bool       # thumbnail=true marker
    assets::Vector{String}
    data::Any             # eager plotted-data (`@figure … data=(; x, y[, series])`) | nothing.
    # When set, the agent backend writes the figure's data file from THIS — no `gen()`, hence no
    # plotting backend — so the LLM artifact (agent.json) is producible Plots/Makie-free.
    defined_at::String    # where the `@figure` was written, `path:line` (see `_defined_at`), or ""
end
function Figure(id, anchor, caption, params, gen, code, thumbnail, assets, data)
    return Figure(id, anchor, caption, params, gen, code, thumbnail, assets, data, "")
end

"""
A table artifact — structured tabular data, a sibling to `Figure`. Renders as an HTML/LaTeX table for
humans and as structured rows for the agent backend. Inherently LLM-legible (it is already data).
"""
mutable struct Table
    id::Symbol
    anchor::String
    caption::String
    header::Vector{String}
    rows::Vector{Vector{Any}}
    code::String          # @table data-expression source (provenance)
    params::Any
    defined_at::String    # where the `@table` was written, `path:line`, or ""
end
function Table(id, anchor, caption, header, rows, code, params)
    return Table(id, anchor, caption, header, rows, code, params, "")
end

# A table cell as display text (HTML/LaTeX backends; the agent backend keeps native JSON types).
_cellstr(x) = x === missing ? "" : string(x)

"""
A single PASS/FAIL check (a `Test` `@test` recorded into a container) — one assertion of a computed
value against a reference. `delta` is the deviation under the term that governs the bound — `:abs`
is `|got - want|`, `:rel` is `|got - want| / max(|got|, |want|)`, as `isapprox` defines them — so
`pass` is `delta <= tol`. An `indicator` check (no recoverable numbers) is a 1/0 and carries no
margin. Renders to a row of the container's check table, a LaTeX tabular row, and a native-typed
JSON object in `agent.json` (the machine-readable verdict).
"""
mutable struct Check
    id::Symbol
    label::String
    got::Float64
    want::Float64
    delta::Float64     # resolved (rel or abs) deviation
    tol::Float64
    kind::Symbol       # :rel or :abs (resolved; never :auto in the struct)
    pass::Bool
    source::String     # "file:line" of the assertion (issue #69 I) — carried for a failing @test so the
    # report says WHERE, not just what; "" when unknown (a passing @test).
    code_anchor::String   # anchor of the `CodeBlock` holding the code that produced this check — the
    # code itself is ONE artifact in the document (a `@code` block), and this is the reference to it,
    # never a second copy of the source; "" when there is none.
    reported::Bool        # already handed to an enclosing ordinary testset (#173): a failing check is
    # reported exactly once, by that suite when there is one, else by `render`.
    indicator::Bool       # a 1/0 pass indicator (a `@test` with no recoverable numbers), not a margin
end
# Keep the shorter positional forms working (source/code_anchor default to "", reported and
# indicator to false) — every existing construction is unchanged.
function Check(id, label, got, want, delta, tol, kind, pass)
    return Check(id, label, got, want, delta, tol, kind, pass, "", "", false, false)
end
function Check(id, label, got, want, delta, tol, kind, pass, source)
    return Check(id, label, got, want, delta, tol, kind, pass, source, "", false, false)
end
function Check(id, label, got, want, delta, tol, kind, pass, source, code_anchor)
    return Check(
        id, label, got, want, delta, tol, kind, pass, source, code_anchor, false, false
    )
end
function Check(id, label, got, want, delta, tol, kind, pass, source, code_anchor, reported)
    return Check(
        id, label, got, want, delta, tol, kind, pass, source, code_anchor, reported, false
    )
end

# FNV-1a (32-bit) in base 36: the same on every machine and Julia version (unlike `Base.hash`), so the
# ids built from it are stable across runs (#123).
function _stable_hash(s::AbstractString)
    h = 0x811c9dc5
    for b in codeunits(s)
        h = (h ⊻ b) * 0x01000193
    end
    return string(h; base=36, pad=7)
end

# A check's id: its container's anchor plus the stable hash of its source text, so adding or
# reordering other checks never renumbers it (#123). The same text twice in one container is
# disambiguated in order: `…-2`, `…-3`.
function _check_id(c, key::AbstractString)
    base = Symbol(_anchor(Symbol(c.anchor)), "_t", _stable_hash(key))
    taken = Set(ch.id for ch in c.checks)
    base in taken || return base
    k = 2
    while Symbol(base, "-", k) in taken
        k += 1
    end
    return Symbol(base, "-", k)
end

# A copy of `c` with some fields replaced — so a fold can renumber or tag a check it does not own
# without mutating the caller's object (#130).
function _copy_check(c::Check; kw...)
    return Check((get(kw, f, getfield(c, f)) for f in fieldnames(Check))...)
end

"""
A code-snippet artifact — the source (and optionally its captured output), a sibling to `Figure` /
`Table`. Renders as a highlighted `<pre><code>` block (gallery), an `lstlisting`-style verbatim (LaTeX),
and a `{kind:"code", source, output, lang}` object (`agent.json`). This is how a report shows the
COMPUTATION behind a figure or check — "here is the code, here is what it produced" (`@code`, a
Documenter `@example`-like block, issue #69's recorded follow-up).
"""
mutable struct CodeBlock
    id::Symbol
    anchor::String
    source::String        # the code, as WRITTEN (read back from the file; deparsed only as a fallback)
    output::String        # captured value / printed output, or "" (show-only, or no result)
    caption::String
    lang::String          # syntax hint for the highlighter, e.g. "julia"
    defined_at::String    # where the block was written, `path:line`, or ""
end
function CodeBlock(id, anchor, source, output, caption, lang)
    return CodeBlock(id, anchor, source, output, caption, lang, "")
end

# Where a node was written, as `path:line` — the pointer an agent follows to revise it. The path is
# relative to the project that holds the file (the nearest enclosing directory with a Project.toml),
# so it names the same file wherever Julia was started; outside any project it is relative to the
# working directory, or absolute. "" where there is no file to point at (a REPL).
function _defined_at(at)
    at === nothing && return ""
    file, line = at
    (isempty(file) || file == "none" || startswith(file, "REPL")) && return ""
    p = abspath(file)
    root = _project_root(dirname(p))
    rel = relpath(p, something(root, pwd()))
    path = root === nothing && startswith(rel, "..") ? p : rel
    return string(replace(path, '\\' => '/'), ":", line)
end

# The nearest directory at or above `dir` that holds a Project.toml (or JuliaProject.toml), or nothing.
function _project_root(dir)
    while true
        any(f -> isfile(joinpath(dir, f)), ("Project.toml", "JuliaProject.toml")) &&
            return dir
        up = dirname(dir)
        up == dir && return nothing
        dir = up
    end
end

"""
A prose block — markdown and math written with `@desc`, placed in content order like any other node
(Conventions › Content). A container holds any number of them.
"""
mutable struct Prose
    id::Symbol
    anchor::String
    source::String
    defined_at::String    # where the `@desc` was written, `path:line`, or ""
end
Prose(id, anchor, source) = Prose(id, anchor, source, "")

"""
A `@raw` block: author-written HTML, kept verbatim. Like every node it has an id (written with `id=`,
or generated from its HTML), which is its gallery anchor and its `agent.json` address; `agent.json`
carries the HTML itself (Conventions › Faces).
"""
struct RawBlock
    id::Symbol
    anchor::String
    html::String
    defined_at::String    # where the `@raw` was written, `path:line`, or ""
end
RawBlock(id, anchor, html) = RawBlock(id, anchor, html, "")

"A section: a container of prose, figures, tables, code, checks and child sections, in order."
mutable struct Section
    id::Symbol
    title::String
    anchor::String
    facet::Union{String,Nothing}     # by= param axis the gallery facets figures on, or nothing
    texts::Vector{Prose}             # @desc prose blocks, in the order written
    summary::Union{String,Nothing}   # for index :rich
    thumbnail::Union{FigRef,Nothing} # section-level main figure
    layout::Union{Symbol,Nothing}    # :wide|:grid|:single (theme hint)
    figures::Vector{Figure}
    raws::Vector{RawBlock}           # @raw HTML blocks (project-specific UI escape hatch, notes 06 §6)
    tables::Vector{Table}            # @table artifacts
    checks::Vector{Check}            # PASS/FAIL checks (Test's @test written in the section body)
    codes::Vector{CodeBlock}         # @code snippet+output blocks
    content::Vector{Pair{Symbol,Int}}  # declaration order: (:text|:figure|:table|:raw|:check|:code|:section) => index into the list above
    # The section tree (#170): a `@section` nests to any depth. `depth` counts from the part (a page is
    # 1, a top-level section 2), `parent` is the enclosing section (`nothing` at the top level), and
    # `sections` holds the children, which also appear in `content` as `:section => index`.
    depth::Int
    parent::Union{Section,Nothing}
    sections::Vector{Section}
end

"""
A page = one standalone HTML file (the unit of pagination). It groups in-page `Section`s and/or
carries its own figures directly (page-as-leaf: a `@page` with figures and no `@section`). Pages are
optionally grouped into a `@part` (a navigation grouping, not a file) named by `part`.
"""
mutable struct Page
    id::Symbol
    title::String
    summary::Union{String,Nothing}   # one-line page description, shown on the multi-page index (card or toc)
    anchor::String
    thumbnail::Union{FigRef,Nothing} # explicit @thumbnail
    no_thumbnail::Bool
    sections::Vector{Section}
    part::Union{Symbol,Nothing}      # the @part this page belongs to (navigation grouping), or nothing
    texts::Vector{Prose}             # @desc prose blocks written directly in the page, in order
    figures::Vector{Figure}          # page-level figures (page-as-leaf: @figure with no enclosing @section)
    raws::Vector{RawBlock}           # page-level @raw blocks
    layout::Union{Symbol,Nothing}    # :grid|:single|:wide hint for the page-level figure grid
    tables::Vector{Table}            # page-level @table artifacts (page-as-leaf)
    checks::Vector{Check}            # page-level checks (Test's @test written in the page body)
    codes::Vector{CodeBlock}         # page-level @code snippet+output blocks
    content::Vector{Pair{Symbol,Int}}  # declaration order of texts/figures/tables/raws/checks/codes/sections
    status::Symbol                   # maturity: :draft (a manuscript) or :final (default, the published
    # version). Validated by `_status`; what kind of page it is never lives here.
end

# Every check in a container's subtree: its own, then each nested section's, in declaration order.
_subtree_checks(pg::Page) = vcat(pg.checks, (s.checks for s in _all_sections(pg))...)
function _subtree_checks(sec::Section)
    out = copy(sec.checks)
    foreach(child -> append!(out, _subtree_checks(child)), sec.sections)
    return out
end

"""
    verdict(container) -> (; passed, total, verdict, failed) | nothing

The verdict of a `@page` or `@section` over every check in its subtree, derived on demand and never
stored. `nothing` when the subtree holds no checks, so an empty container cannot read as PASS.
"""
function verdict(c::Union{Page,Section})
    checks = _subtree_checks(c)
    return isempty(checks) ? nothing : _verdict_of(checks)
end

"""
    ChecksFailed(failed)

Thrown by `render` after it has written every output, when the document holds failing checks that
no enclosing testset was told about. `failed` lists their ids; `path` is the entry file written.
"""
struct ChecksFailed <: Exception
    failed::Vector{String}
    path::String   # the entry file render wrote, where the failures are shown
end
function Base.showerror(io::IO, e::ChecksFailed)
    return print(
        io,
        "ChecksFailed: ",
        length(e.failed),
        " failing check(s), rendered and shown as FAIL in ",
        e.path,
        ": ",
        join(e.failed, ", "),
    )
end

# Single source of the verdict invariant — used by every backend so PASS/FAIL can never diverge.
function _verdict_of(checks)
    passed = count(c -> c.pass, checks)
    total = length(checks)
    return (
        passed=passed,
        total=total,
        verdict=(passed == total ? "PASS" : "FAIL"),
        failed=[string(c.id) for c in checks if !c.pass],
    )
end

"Implicit top level (the catalogue). Order = tree position; numbers are not stored (numbering is the theme's job)."
mutable struct Document
    meta::DocMeta
    pages::Vector{Page}
    parts::Vector{Pair{Symbol,String}}   # ordered @part registry: id => title (navigation groups)
    part_descs::Dict{Symbol,Desc}        # @part id => overview description (markdown), shown on the index
    part_status::Dict{Symbol,Symbol}     # @part id => default status its pages inherit (:draft/:final)
    refs::Dict{Symbol,Any}        # label -> node (filled in by resolve)
    bib::Dict{Symbol,Any}         # @cite resolution table (later)
    diag::Diagnostics
    newcommands::Dict{String,String}
    ids::Dict{Symbol,String}      # every id written so far => what holds it (Conventions › Identity)
end
function Document(meta::DocMeta=DocMeta())
    return Document(
        meta,
        Page[],
        Pair{Symbol,String}[],
        Dict{Symbol,Desc}(),
        Dict{Symbol,Symbol}(),
        Dict{Symbol,Any}(),
        Dict{Symbol,Any}(),
        Diagnostics(),
        Dict{String,String}(),
        Dict{Symbol,String}(),
    )
end

# ============================================================ build context

"Build state of the implicit global document (current part/page/section)."
mutable struct BuildContext
    document::Union{Document,Nothing}
    part::Union{Symbol,Nothing}      # the @part currently open (pages inherit it), or nothing
    page::Union{Page,Nothing}
    section::Union{Section,Nothing}
    captioned::Any                   # the node the latest `@caption` named (a node takes one caption)
end
const CTX = BuildContext(nothing, nothing, nothing, nothing, nothing)

current_document() = CTX.document
current_page() = CTX.page
current_section() = CTX.section

# The test bridge (`PinaxTestExt`) registers a probe here when `Test` is loaded; it stays `nothing`
# for the manuscript path, which then pays only a `Ref` read. The probe returns the innermost open
# Pinax *test* container (a `PinaxTestSet`), or `:inert` (inside a test that is NOT capturing — the
# report is off), or `:none` (not inside a testset at all). Kept `Test`-free by indirection: core
# reads a `Ref`, the extension supplies the closure at load — no method the extension must overwrite.
const _TEST_CONTAINER_PROBE = Base.RefValue{Any}(nothing)
_probe_test_container() = (p=_TEST_CONTAINER_PROBE[]; p === nothing ? :none : p())

# The container scope (#173). With `Test` loaded, an open `@page` / `@section` is the current testset
# for its body, so `Test`'s own `@test` is a check of that container and a nested `@testset` is a child
# section. Core stays `Test`-free: `PinaxTestExt` registers the hook at load, and without it the
# expansion below enters a scope that changes nothing. `@with` adds no closure, so the body's scoping
# is exactly what it was.
struct _ScopeHook
    open::Function    # container -> testset handle (or nothing)
    pairs::Function   # handle -> the two ScopedValue pairs that make it current
    close::Function   # handle -> nothing
end
const _SCOPE_HOOK = Base.RefValue{Union{_ScopeHook,Nothing}}(nothing)
const _NO_SCOPE = Base.ScopedValues.ScopedValue{Any}(nothing)
_open_scope(c) = (h=_SCOPE_HOOK[]; h === nothing ? nothing : h.open(c))
function _scope_pair(ts, i)
    h = _SCOPE_HOOK[]
    return (h === nothing || ts === nothing) ? (_NO_SCOPE => nothing) : h.pairs(ts)[i]
end
function _close_scope(ts)
    return (h=_SCOPE_HOOK[]; (h === nothing || ts === nothing) ? nothing : h.close(ts))
end

# `body` run with container `c` as the current testset (see above), for the @page / @section macros.
function _scoped_body(c, body)
    return quote
        local ts = Pinax._open_scope($c)
        try
            Base.ScopedValues.@with Pinax._scope_pair(ts, 1) Pinax._scope_pair(ts, 2) $body
        finally
            Pinax._close_scope(ts)
        end
    end
end

"Reset the implicit document (fresh, empty). The preamble `@pinaxsetup` calls this."
# Every setting `reset!` reads. A keyword outside this set is refused rather than dropped: the
# alternative is that `@pinaxsetup katx=:local` configures nothing and says nothing.
const _SETUP_KEYS = (
    :title,
    :theme,
    :debug,
    :index,
    :numbering,
    :numberer,
    :features,
    :css,
    :js,
    :katex,
    :assets,
    :appearance,
)

function reset!(; kwargs...)
    kw = Dict{Symbol,Any}(kwargs)
    for k in sort!(collect(keys(kw)))
        k in _SETUP_KEYS && continue
        k === :format && error(
            "Pinax: @pinaxsetup format= is not a setting — a theme decides which figure formats " *
            "it requests, through `figure_formats(::Theme)`. Select a theme with `theme=`.",
        )
        error(
            "Pinax: @pinaxsetup has no $(k)= setting. Known: " *
            join(_SETUP_KEYS, ", ") *
            ". Bibliography files are declared with `@bibliography`.",
        )
    end
    idx = get(kw, :index, nothing)
    idx === nothing ||
        idx in (:toc, :cards, :rich) ||
        error(
            "Pinax: @pinaxsetup index= must be :toc, :cards, or :rich (got $(repr(idx)))."
        )
    num = get(kw, :numbering, :global)
    num in (:global, :page, :part) || error(
        "Pinax: @pinaxsetup numbering= must be :global, :page, or :part (got $(repr(num))).",
    )
    ktx = get(kw, :katex, :cdn)
    ktx in (:cdn, :local) ||
        error("Pinax: @pinaxsetup katex= must be :cdn or :local (got $(repr(ktx))).")
    ast = get(kw, :assets, :default)
    ast in (:default, :inline) ||
        error("Pinax: @pinaxsetup assets= must be :default or :inline (got $(repr(ast))).")
    # `theme=` is which theme renders the page; `appearance=` is which of that theme's two palettes
    # a reader sees before choosing. `:system` — the default, and what every page did before this
    # setting existed — leaves the choice to the reader's operating system.
    app = get(kw, :appearance, :system)
    app in (:system, :light, :dark) || error(
        "Pinax: @pinaxsetup appearance= must be :system, :light, or :dark (got $(repr(app))). " *
        "It is the colour scheme, not the theme — `theme=` selects the theme.",
    )
    meta = DocMeta(;
        title=get(kw, :title, ""),
        theme=get(kw, :theme, :gallery),
        debug=get(kw, :debug, false),
        index=idx,
        numbering=num,
        numberer=get(kw, :numberer, _default_numberer),
        features=get(kw, :features, Symbol[:comments, :bookmarks, :export]),
        css=get(kw, :css, String[]),
        js=get(kw, :js, String[]),
        katex=ktx,
        assets=ast,
        appearance=app,
    )
    CTX.document = Document(meta)
    CTX.part = nothing
    CTX.page = nothing
    CTX.section = nothing
    return CTX.document
end

_ensure_document!() = (CTX.document === nothing && reset!(); CTX.document)

"Build a scoped document: `doc = document() do … end` (for test isolation)."
function document(f)
    saved = (CTX.document, CTX.part, CTX.page, CTX.section)
    CTX.document = Document()
    CTX.part = nothing
    CTX.page = nothing
    CTX.section = nothing
    local doc
    try
        f()
        doc = CTX.document        # capture after f, so a @pinaxsetup reset! inside f is still picked up
    finally
        CTX.document, CTX.part, CTX.page, CTX.section = saved
    end
    return doc
end

# ============================================================ helpers

# Anchor used both in HTML attributes and as a filesystem path component, so restrict it to a safe charset.
_anchor(id::Symbol) = replace(string(id), r"[^A-Za-z0-9_-]" => "_")
# ── identity (Conventions › Identity) ───────────────────────────────
#
# Every id is unique in the whole document and is the node's only name: its anchor, comment key and
# agent.json address. An id the AUTHOR writes is claimed as written and a collision is an error where
# the second node is written. An id Pinax GENERATES is the container's id plus a short stable hash of
# the node's own content, so inserting a node renames nothing; a repeat of the same content gets
# `-2`, `-3`, and never errors.

function _symbol_id(id, what)
    id isa Symbol && return id
    return error("Pinax: the id of a $(what) is a Symbol — write `:$(id)`, not $(repr(id))")
end

# Claim an id the author wrote, in the document-wide registry.
function _claim!(id::Symbol, what::AbstractString)
    doc = _ensure_document!()
    prev = get(doc.ids, id, nothing)
    prev === nothing || error(
        "Pinax: duplicate id :$(id) — this $(what) reuses the id of the $(prev) written earlier. Ids " *
        "are unique in the whole document and never renamed: give one of them another id.",
    )
    doc.ids[id] = what
    return id
end

# The first of `base`, `base-2`, `base-3`, … that `taken` does not hold.
function _free_id(base::Symbol, taken)
    taken(base) || return base
    k = 2
    while taken(Symbol(base, "-", k))
        k += 1
    end
    return Symbol(base, "-", k)
end
_free_id(base::Symbol) = _free_id(base, id -> haskey(_ensure_document!().ids, id))

# The id of a content node in container `c`: the author's, claimed, or one generated from `base`. A
# test node is folded into a document only after the run, so inside one the ids are kept unique
# among its own nodes; the fold places them.
function _node_id!(c, id, base::Symbol, what::AbstractString)
    where = string(what, " in \"", c.anchor, "\"")
    if c isa Union{Page,Section}
        return if id === nothing
            _claim!(_free_id(base), where)
        else
            _claim!(_symbol_id(id, what), where)
        end
    end
    taken(x) = any(
        n -> n.id === x,
        Iterators.flatten((c.texts, c.figures, c.tables, c.codes, c.raws)),
    )
    id === nothing && return _free_id(base, taken)
    sid = _symbol_id(id, what)
    taken(sid) && error(
        "Pinax: duplicate id :$(sid) — this $(where) reuses an id already written there. Ids are " *
        "never renamed: give one of them another id.",
    )
    return sid
end

# Stringify the @figure expression for change detection, stripping source line numbers so that
# moving a figure to a different line does not spuriously invalidate its cache entry (notes 10).
_code_str(expr) = string(expr isa Expr ? Base.remove_linenums!(deepcopy(expr)) : expr)

# A canonical string for a figure's `params`, hashed into its generated id. The PinaxParamIOExt
# extension specializes this on a ParamIO.DataKey (its canonical key); anything else uses its repr.
_param_tag(params) = nothing
_params_key(params) = (
    t=_param_tag(params);
    if t !== nothing
        t
    elseif params === nothing
        ""
    else
        repr(params)
    end
)

# Structured description of a figure's `params` binding — an ordered `Vector{Pair{String,Any}}` of
# axis => value — for the agent backend's data-reconciliation view (an LLM sees the bound axes, not a
# repr blob). `nothing` means "no introspectable scheme" (the agent then falls back to a string).
# A NamedTuple keeps its declared order; a Dict is sorted for determinism; the PinaxParamIOExt
# extension specializes this on a ParamIO.DataKey (delegating to its dotted-key param Dict).
_params_describe(params) = nothing
_params_describe(nt::NamedTuple) = Pair{String,Any}[string(k) => v for (k, v) in pairs(nt)]
function _params_describe(d::AbstractDict)
    return Pair{String,Any}[string(k) => d[k] for k in sort!(collect(keys(d)); by=string)]
end

function _diag!(sev::Severity, item, msg)
    doc = CTX.document
    if doc === nothing
        @warn "Pinax diagnostic dropped (no active document)" severity = sev item = string(
            item
        ) message = msg
    else
        push!(doc.diag.entries, DiagEntry(sev, string(item), msg))
    end
    return nothing
end

# key=val Exprs -> Expr(:kw, …) (values escaped). Macro-internal.
function _kwspecs(args)
    return Expr[
        if (a isa Expr && a.head === :(=))
            Expr(:kw, a.args[1], esc(a.args[2]))
        else
            error("expected key=value, got $(a)")
        end for a in args
    ]
end

# Build a call Expr. With no kwspecs, omit the `;` (an empty Expr(:parameters) is invalid syntax).
function _call(f, posargs, kwspecs)
    return if isempty(kwspecs)
        Expr(:call, f, posargs...)
    else
        Expr(:call, f, Expr(:parameters, kwspecs...), posargs...)
    end
end

# ============================================================ preamble macros

"Document settings + reset of the implicit document. `@pinaxsetup theme=… index=… numbering=… debug=…`"
macro pinaxsetup(args...)
    return _call(:_pinaxsetup!, (), _kwspecs(args))
end
# `@pinaxsetup` starts a new document, so it cannot be written inside an open part, page or section.
function _pinaxsetup!(; kwargs...)
    (CTX.part === nothing && CTX.page === nothing && CTX.section === nothing) || error(
        "@pinaxsetup inside an open @part/@page/@section — it starts a new document, so it is " *
        "written before any of them",
    )
    return reset!(; kwargs...)
end

"""
`@debug_mode true` is deprecated during 0.2 and is removed afterwards: a setting is written in the
`@pinaxsetup` that starts the document (`@pinaxsetup debug = true`). Until then it still switches
debug on the open document without starting a new one, and warns once.
"""
macro debug_mode(x)
    return :(_debug_mode!($(esc(x))))
end
function _debug_mode!(on)
    @warn "Pinax: `@debug_mode` is deprecated — add `debug = true` to the `@pinaxsetup` that " *
        "starts the document. `@pinaxsetup` starts a new document, so writing it in place of " *
        "`@debug_mode` would discard everything written above it." maxlog = 1
    _ensure_document!().meta.debug = on
    return nothing
end

"Declare the .bib source(s) used to resolve `@cite`. `@bibliography \"refs/a.bib\" …`"
macro bibliography(paths...)
    ps = map(esc, paths)
    return quote
        append!(_ensure_document!().meta.bib_sources, String[$(ps...)])
        nothing
    end
end

"Notation macro. `@newcommand \"\\E\" raw\"\\langle H\\rangle\"`"
macro newcommand(name, def)
    return quote
        _ensure_document!().newcommands[$(esc(name))] = $(esc(def))
        nothing
    end
end

# ============================================================ structure macros

"""
A page. `@page :id "Title" [summary=…] [layout=…] [status=…] begin … end`

`status` is the page's maturity: `:draft` (a manuscript, work in progress) or `:final` (the default,
the published version); anything else is an error. Pinax only carries it: the agent backend exposes
it as `"status"` and the gallery badges a `:draft` page. A page inherits its enclosing `@part`'s
status default unless it sets its own. A page is written at the top level or directly in a `@part`.
"""
macro page(args...)
    length(args) >= 3 || error("@page needs :id, \"title\", and a begin…end body")
    id, title, body = args[1], args[2], args[end]
    enter = _call(:_enter_page!, (esc(id), esc(title)), _kwspecs(args[3:(end - 1)]))
    return quote
        local pg = $enter
        try
            $(_scoped_body(:pg, esc(body)))
        finally
            _exit_page!()
        end
        nothing
    end
end

# A page's maturity: `:draft` (a manuscript) or `:final` (the published version), nothing else.
# `:trial` is the 0.1 spelling of `:draft`, accepted with a warning during 0.2.
function _status(s)
    st = Symbol(s)
    st in (:draft, :final) && return st
    if st === :trial
        @warn "Pinax: status=:trial is deprecated; use status=:draft (the same meaning)." maxlog =
            1
        return :draft
    end
    return error("Pinax: status must be :draft or :final (got $(repr(st))).")
end

function _enter_page!(id, title; summary=nothing, layout=nothing, status=nothing)
    id = _symbol_id(id, "page")
    CTX.section === nothing || error(
        "@page :$(id) inside @section :$(CTX.section.id) — a page is written at the top level " *
        "or directly inside a @part",
    )
    CTX.page === nothing || error(
        "@page :$(id) inside @page :$(CTX.page.id) — a page is written at the top level or " *
        "directly inside a @part",
    )
    layout === nothing ||
        layout in (:grid, :single, :wide) ||
        error(
            "Pinax: @page layout= must be :grid, :single, or :wide (got $(repr(layout)))."
        )
    doc = _ensure_document!()
    _claim!(id, "page")
    # status resolution: explicit @page status= wins; else inherit the open @part's
    # default status; else :final (the ordinary shaped/curated page).
    st = status === nothing ? get(doc.part_status, CTX.part, :final) : _status(status)
    pg = Page(
        id,
        string(title),
        summary === nothing ? nothing : string(summary),
        _anchor(id),
        nothing,
        false,
        Section[],
        CTX.part,          # inherit the open @part, if any
        Prose[],
        Figure[],
        RawBlock[],
        layout,
        Table[],
        Check[],
        CodeBlock[],
        Pair{Symbol,Int}[],
        st,
    )
    push!(doc.pages, pg)
    CTX.page = pg
    CTX.section = nothing
    return pg
end
_exit_page!() = (CTX.page=nothing; CTX.section=nothing)

"""
`@benchmark` was removed in 0.2 (#173). Checks go in any `@section` (or a `@testset` inside one), and
every container whose subtree holds checks shows its verdict and its check table in every face.
Using `@benchmark` raises an error that says so.
"""
macro benchmark(args...)
    return :(error(
        "Pinax: `@benchmark` was removed in 0.2 — put the `@test` checks in a @section (or a " *
        "@testset inside one); every container with checks shows its verdict (#173).",
    ))
end

"""
A navigation group of pages (LaTeX `\\part`). `@part :id \"Title\" [desc=md\"…\"] begin … end` — the
pages declared inside belong to this part and are grouped (collapsibly) under it in the index and nav.
`desc=` is an overview shown beneath the part heading on the index (what this whole group covers).
A part is NOT a file; each `@page` (or top-level `@section`) inside it is still its own HTML page.
`status=` sets a default maturity (`:draft` or `:final`) that the part's pages inherit — so a whole
group of drafts is declared once, the published result living in a separate part. A part is written
at the top level.
"""
macro part(args...)
    length(args) >= 3 || error("@part needs :id, \"title\", and a begin…end body")
    id, title, body = args[1], args[2], args[end]
    enter = _call(:_enter_part!, (esc(id), esc(title)), _kwspecs(args[3:(end - 1)]))
    return quote
        $enter
        try
            $(esc(body))
        finally
            _exit_part!()
        end
        nothing
    end
end

function _enter_part!(id, title; desc=nothing, status=nothing)
    id = _symbol_id(id, "part")
    open = if CTX.section !== nothing
        "@section :$(CTX.section.id)"
    elseif CTX.page !== nothing
        "@page :$(CTX.page.id)"
    elseif CTX.part !== nothing
        "@part :$(CTX.part)"
    else
        nothing
    end
    open === nothing ||
        error("@part :$(id) inside $(open) — a part is written at the top level")
    doc = _ensure_document!()
    _claim!(id, "part")
    # register (id => title) once, in declaration order, for the grouped navigation
    any(p -> first(p) === id, doc.parts) || push!(doc.parts, id => string(title))
    desc === nothing || (doc.part_descs[id] = Desc(string(desc)))
    status === nothing || (doc.part_status[id] = _status(status))  # default status its pages inherit
    CTX.part = id
    CTX.page = nothing
    CTX.section = nothing
    return id
end
_exit_part!() = (CTX.part=nothing; CTX.page=nothing; CTX.section=nothing)

"A section. `@section :id \"Title\" [by=…] [summary=…] [layout=…] begin … end`"
macro section(args...)
    length(args) >= 3 || error("@section needs :id, \"title\", and a begin…end body")
    id, title, body = args[1], args[2], args[end]
    enter = _call(:_enter_section!, (esc(id), esc(title)), _kwspecs(args[3:(end - 1)]))
    return quote
        local sec = $enter
        try
            $(_scoped_body(:sec, esc(body)))
        finally
            _exit_section!()
        end
        nothing
    end
end

function _enter_section!(id, title; by=nothing, summary=nothing, layout=nothing)
    id = _symbol_id(id, "section")
    (by === nothing || by isa AbstractString) ||
        error("Pinax: @section by= names one param axis, a String (got $(repr(by)))")
    pg = CTX.page
    pg === nothing && error("@section outside of a @page")
    parent = CTX.section
    _claim!(id, string("section in \"", (parent === nothing ? pg : parent).anchor, "\""))
    layout === nothing ||
        layout in (:grid, :single, :wide) ||
        error(
            "Pinax: @section layout= must be :grid, :single, or :wide (got $(repr(layout))).",
        )
    sec = Section(
        id,
        string(title),
        _anchor(id),   # the id is the anchor: ids are unique in the whole document
        by === nothing ? nothing : String(by),
        Prose[],
        summary === nothing ? nothing : string(summary),
        nothing,
        layout,
        Figure[],
        RawBlock[],
        Table[],
        Check[],
        CodeBlock[],
        Pair{Symbol,Int}[],
        parent === nothing ? 2 : parent.depth + 1,
        parent,
        Section[],
    )
    # a page and a section are the same kind of container: a child sits in its content order
    owner = parent === nothing ? pg : parent
    push!(owner.sections, sec)
    push!(owner.content, :section => length(owner.sections))
    CTX.section = sec
    return sec
end
# Leaving a section returns to the one that encloses it (or to the page at the top level).
_exit_section!() = (CTX.section = CTX.section === nothing ? nothing : CTX.section.parent)

# Every section of a page, depth first in declaration order: the one walk for anything that must see
# the whole tree (id resolution, figure counts, thumbnails), so no caller can stop at the top level.
function _all_sections(pg)
    out = Section[]
    walk(s) = (push!(out, s); foreach(walk, s.sections))
    foreach(walk, pg.sections)
    return out
end

"Register a plot; the expression is DEFERRED. `@figure expr [params=…] [caption=…] [id=…] [thumbnail=…]` / `@figure [kw] begin … end`"
macro figure(args...)
    isempty(args) && error("@figure needs a plot expression")
    expr = nothing
    kws = Expr[]
    for a in args
        if a isa Expr &&
            a.head === :(=) &&
            a.args[1] isa Symbol &&
            a.args[1] in (:params, :caption, :id, :thumbnail, :data)
            push!(kws, a)
        elseif expr === nothing
            expr = a
        else
            error("@figure takes a single plot expression (plus kwargs)")
        end
    end
    expr === nothing && error("@figure needs a plot expression")
    allk = vcat(
        Expr(:kw, :gen, Expr(:(->), Expr(:tuple), esc(expr))),
        Expr(:kw, :code, _code_str(expr)),
        Expr(:kw, :at, (String(string(__source__.file)), __source__.line)),
        _kwspecs(kws),
    )
    return _call(:_push_figure!, (), allk)
end

# The manuscript container from the module-global build state only (no probe). The test-report fold
# builds a `Document` in `CTX` post-hoc and must resolve against `CTX` directly — never the probe,
# which could still see the finishing root testset. This is also the one integration seam: every
# content macro resolves its target through `_current_container` below and nowhere else.
_ctx_container() = CTX.section !== nothing ? CTX.section : CTX.page

# Precedence: an open Pinax *test* container (report on) captures the test content; else an open
# manuscript `CTX` container wins — a manuscript built even *inside* a stock `@testset` (as Pinax's
# own tests do) must still go to `CTX`; else, if we are inside a stock testset with no manuscript
# open, the content is test content with the report OFF → `:inert` (the caller no-ops, invariant V);
# else nothing is open at all → `nothing` (the caller errors on manuscript misuse).
function _current_container()
    ctx = _ctx_container()
    ctx === nothing || return ctx                   # an EXPLICITLY-open manuscript container wins — a
    # manuscript built inside a test (even a captured one, via `document()`/`@page`) writes to `CTX`,
    # not the testset; only when nothing is open does the enclosing testset capture the content.
    tc = _probe_test_container()
    (tc === :none || tc === :inert) || return tc    # an open PinaxTestSet — capture the test content
    return tc === :inert ? :inert : nothing
end

function _push_figure!(;
    gen,
    code,
    at=nothing,
    params=nothing,
    caption="",
    id=nothing,
    thumbnail=false,
    data=nothing,
)
    c = _current_container()
    c === :inert && return nothing   # inside a test with the report off — no-op (invariant V)
    c === nothing && error("@figure outside of a @section or @page")
    base = Symbol(c.id, "_fig_", _stable_hash(string(code, "|", _params_key(params))))
    fid = _node_id!(c, id, base, "figure")
    fig = Figure(
        fid,
        _anchor(fid),
        string(caption),
        params,
        gen,
        code,
        thumbnail,
        String[],
        data,
        _defined_at(at),
    )
    push!(c.figures, fig)
    push!(c.content, :figure => length(c.figures))
    return fig
end

"""
Register a table artifact — first-class tabular data (sibling to `@figure`). `data` may be a
NamedTuple of columns `(T=…, M=…)`, a `Matrix` (with `header=`), a `Vector` of NamedTuple rows, or a
`Vector` of row-vectors/tuples (with `header=`). `@table data [caption=…] [id=…] [header=…] [params=…]`.
"""
macro table(args...)
    isempty(args) && error("@table needs a data expression")
    data = nothing
    kws = Expr[]
    for a in args
        if a isa Expr &&
            a.head === :(=) &&
            a.args[1] isa Symbol &&
            a.args[1] in (:caption, :id, :header, :params)
            push!(kws, a)
        elseif data === nothing
            data = a
        else
            error("@table takes a single data expression (plus kwargs)")
        end
    end
    data === nothing && error("@table needs a data expression")
    allk = vcat(
        Expr(:kw, :data, esc(data)),
        Expr(:kw, :code, _code_str(data)),
        Expr(:kw, :at, (String(string(__source__.file)), __source__.line)),
        _kwspecs(kws),
    )
    return _call(:_push_table!, (), allk)
end

function _push_table!(;
    data, code, at=nothing, caption="", id=nothing, header=nothing, params=nothing
)
    c = _current_container()
    c === :inert && return nothing   # inside a test with the report off — no-op (invariant V)
    c === nothing && error("@table outside of a @section or @page")
    hdr, rows = _normalize_table(data, header)
    if !isempty(hdr)   # every row must be header-wide (catches a wrong-length header= or ragged rows)
        bad = findfirst(r -> length(r) != length(hdr), rows)
        bad === nothing || error(
            "Pinax: @table row $(bad) has $(length(rows[bad])) cells but the header has " *
            "$(length(hdr)) columns — check `header=` length or ragged rows",
        )
    end
    tid = _node_id!(c, id, Symbol(c.id, "_tbl_", _stable_hash(string(code))), "table")
    tbl = Table(
        tid, _anchor(tid), string(caption), hdr, rows, code, params, _defined_at(at)
    )
    push!(c.tables, tbl)
    push!(c.content, :table => length(c.tables))
    return tbl
end

"""
`@expect` was removed in 0.2 (#173). A check is `Test`'s own `@test`: with `using Test`, a `@test`
written in a `@page` / `@section` is recorded as a check of that container, with the numbers it
compared and its margin. Using `@expect` raises an error that says so.
"""
macro expect(args...)
    return :(error(
        "Pinax: `@expect` was removed in 0.2 — write `@test` (with `using Test`) inside the " *
        "@page/@section; Pinax records it as a check of that container (#173).",
    ))
end

# The container's content (prose / figures / tables / @raw blocks / checks / code / sections) in declaration order, as (kind, item) pairs.
"""
    @code [caption=…] [id=…] [lang="julia"] [run=true] expr
    @code [kw…] begin … end

Show a **code snippet** — the computation behind a figure or check — and, by default, RUN it and show
its result. `@code E = compute(χ)` renders the source `E = compute(χ)` and its value; the assignment
still happens in the enclosing scope, so following code (a `@test`, a `@figure`) uses `E`. `run=false`
shows the source only (no evaluation). It captures the block's **return value** (not stdout).

The snippet is the source **as written** — read back from the file, so comments and formatting survive
and a definition does not come back as a `begin`-blocked normal form. (Where there is no readable
source file — a REPL, a Documenter `@example` — it falls back to deparsing the expression.)

Inside a test, every `@test` already gets one of these automatically, holding the code that produced
it; an explicit `@code` is for showing a computation deliberately (a definition above a sweep, say).

Content, not structure (law II): it needs `using Pinax`, is purely additive, and has no bearing on a
verdict — a Documenter `@example`-like block, rendered as code + output by every backend.
"""
macro code(args...)
    isempty(args) && error("@code needs an expression")
    expr = nothing
    kws = Expr[]
    run = true
    # A `key = value` arg is a KEYWORD only for the reserved names — anything else with `head === :(=)`
    # is the expression itself (an assignment like `E = compute(x)`, the common case). So `@code caption`
    # is reserved; a variable literally named `caption` cannot be the shown assignment (as in `@table`).
    for a in args
        if a isa Expr &&
            a.head === :(=) &&
            a.args[1] isa Symbol &&
            a.args[1] in (:caption, :id, :lang, :run)
            a.args[1] === :run ? (run = a.args[2] === true) : push!(kws, a)
        elseif expr === nothing
            expr = a
        else
            error("@code takes a single expression (plus kwargs)")
        end
    end
    expr === nothing && error("@code needs an expression")
    src = _code_str(expr)
    _kw(k, v) = Expr(:kw, k, v)
    # `source` is the deparsed normal form; `at`/`ast` let `_push_code!` recover what was actually
    # WRITTEN at that line (see `_verbatim_code`) and fall back to the deparse when it cannot.
    ksrc = [
        _kw(:source, src),
        _kw(:at, (String(string(__source__.file)), __source__.line)),
        _kw(:ast, QuoteNode(expr)),
    ]
    isassign = expr isa Expr && expr.head === :(=) && expr.args[1] isa Symbol
    isdefn =
        expr isa Expr && (
            expr.head in _CODE_STMT_HEADS ||
            (expr.head === :(=) && !(expr.args[1] isa Symbol))
        )
    if !run
        # show-only — do not evaluate at all
        return Expr(
            :block,
            Expr(
                :call,
                _push_code!,
                Expr(:parameters, ksrc..., _kw(:output, ""), _kwspecs(kws)...),
            ),
            nothing,
        )
    elseif isassign
        # a simple `sym = rhs`: run it BARE (so `sym` leaks to the caller exactly as without @code),
        # then read the value back off `sym` — capturing output without a wrapper that would relocalise.
        sym = expr.args[1]
        params = Expr(
            :parameters,
            ksrc...,
            _kw(:output, Expr(:call, _repr_output, esc(sym))),
            _kwspecs(kws)...,
        )
        return Expr(:block, esc(expr), Expr(:call, _push_code!, params), esc(sym))
    elseif isdefn
        # a function/other definition or a compound statement: run BARE (its scoping must be identical
        # to writing it without @code — a value wrapper would relocalise the definition); no output.
        params = Expr(:parameters, ksrc..., _kw(:output, ""), _kwspecs(kws)...)
        return Expr(:block, esc(expr), Expr(:call, _push_code!, params), nothing)
    else
        # a pure expression (leaks nothing): wrap it to capture its value as the output.
        v = gensym(:codeval)
        params = Expr(
            :parameters,
            ksrc...,
            _kw(:output, Expr(:call, _repr_output, v)),
            _kwspecs(kws)...,
        )
        return Expr(:block, Expr(:(=), v, esc(expr)), Expr(:call, _push_code!, params), v)
    end
end

# Heads that must run BARE under `@code` (a value-capturing wrapper would change their scoping): a
# definition, a control-flow / scope block, an import, etc.
const _CODE_STMT_HEADS = (
    :function,
    :block,
    :const,
    :for,
    :while,
    :let,
    :struct,
    :abstract,
    :primitive,
    :macro,
    :module,
    :using,
    :import,
    :global,
    :local,
    :do,
    :toplevel,
    :if,
    :try,
)

# A code result rendered for display: the return value's `repr`, "" for `nothing`, bounded in size.
function _repr_output(v)
    v === nothing && return ""
    s = try
        repr(v)
    catch
        try
            string(v)
        catch
            "«unprintable»"
        end
    end
    return length(s) > 2000 ? string(first(s, 1997), "…") : s
end

function _push_code!(;
    source, output="", caption="", id=nothing, lang="julia", at=nothing, ast=nothing
)
    c = _current_container()
    c === :inert && return nothing   # inside a test with the report off — no-op (invariant V)
    c === nothing && error("@code outside of a @section or @page")
    # Prefer the source as WRITTEN over the deparsed normal form (`_verbatim_code`, which returns
    # `nothing` when the file is not readable — a REPL, a Documenter `@example`).
    src = string(source)
    if ast !== nothing && at !== nothing
        v = _verbatim_code(at[1], at[2], ast)
        v === nothing || (src = v)
    end
    cid = _node_id!(c, id, Symbol(c.id, "_code_", _stable_hash(src)), "code block")
    blk = CodeBlock(
        cid,
        _anchor(cid),
        src,
        string(output),
        string(caption),
        string(lang),
        _defined_at(at),
    )
    push!(c.codes, blk)
    push!(c.content, :code => length(c.codes))
    return blk
end

# A container's content as `(kind, item)` in declaration order — the ONE registry of node kinds every
# backend walks. A kind not listed here is an error, never misread as another kind's index (#168).
function _content_items(c)
    return [
        (
            k,
            if k === :text
                c.texts[i]
            elseif k === :figure
                c.figures[i]
            elseif k === :table
                c.tables[i]
            elseif k === :check
                c.checks[i]
            elseif k === :code
                c.codes[i]
            elseif k === :section
                c.sections[i]
            elseif k === :raw
                c.raws[i]
            else
                error("Pinax: unknown content kind :$(k) in \"$(c.anchor)\"")
            end,
        ) for (k, i) in c.content
    ]
end

# A node (or content kind) a face has no form for: every content walk ends in this, so a node type
# added to `_content_items` fails loudly in each face until that face handles it — never printed
# verbatim or silently dropped (#168).
function _unhandled_node(face, node)
    name = face isa AbstractString ? face : string(nameof(typeof(face)), " theme")
    what = node isa Symbol ? ":$(node) node" : string(nameof(typeof(node)))
    return error(
        "Pinax: the $(name) has no form for a $(what) — every node kind needs one in every face",
    )
end

# Normalize the accepted @table inputs into (header::Vector{String}, rows::Vector{Vector{Any}}).
function _normalize_table(data, header)
    if data isa NamedTuple                          # columnar: (a=[…], b=[…])
        cols = collect(values(data))
        hdr = header === nothing ? collect(string.(keys(data))) : collect(string.(header))
        n = isempty(cols) ? 0 : maximum(length, cols)
        rows = [Any[i <= length(c) ? c[i] : missing for c in cols] for i in 1:n]
        return hdr, rows
    elseif data isa AbstractMatrix
        nc = size(data, 2)
        hdr = header === nothing ? [string(j) for j in 1:nc] : collect(string.(header))
        rows = [Any[data[i, j] for j in 1:nc] for i in 1:size(data, 1)]
        return hdr, rows
    elseif data isa AbstractVector
        if !isempty(data) && first(data) isa NamedTuple   # row records: [(a=…,b=…), …]
            ks = keys(first(data))
            hdr = header === nothing ? collect(string.(ks)) : collect(string.(header))
            rows = [Any[getfield(r, k) for k in ks] for r in data]
            return hdr, rows
        else                                              # vector of row-vectors/tuples
            rows = [Any[x for x in r] for r in data]
            width = isempty(rows) ? 0 : length(rows[1])
            hdr =
                header === nothing ? [string(j) for j in 1:width] : collect(string.(header))
            return hdr, rows
        end
    end
    return error(
        "Pinax: @table data must be a NamedTuple of columns, a Matrix, or a Vector of " *
        "NamedTuple/Vector rows (got $(typeof(data)))",
    )
end

"""
Name the node written **immediately before** it (like `\\caption`), replacing that node's caption:

  - after a `@figure`, `@table` or `@code` → its caption (the same as passing `caption=`);
  - after a `@test` → the **check's quantity name** (its label). This is how a swept
    `@testset for` names the quantity a convergence figure plots — `@test isapprox(E, oracle; rtol=…)`
    followed by `@caption "energy"` titles the check (and its convergence figure) `energy` instead of
    the raw expression (issue #69 C). Grouping is by this label, so every iteration's `@caption` folds
    the sweep into one named quantity.

It never reaches back past another node to an earlier one (#159): with nothing before it, or after a
node that carries no caption (`@raw`, a child `@section`), it is an error where it is written.
"""
macro caption(x)
    return quote
        _set_caption!($(esc(x)))
    end
end
function _set_caption!(s)
    c = _current_container()
    c === :inert && return nothing   # inside a test with the report off — no-op (invariant V)
    c === nothing && error("@caption outside of a @section or @page")
    isempty(c.content) && error(
        "Pinax: @caption in \"$(c.anchor)\" has nothing before it to name — write it directly " *
        "after a @figure, @table, @code or @test, or pass `caption=` to that node",
    )
    kind, i = c.content[end]
    kind in (:check, :figure, :table, :code) || error(
        "Pinax: @caption in \"$(c.anchor)\" follows a $(kind), which carries no caption — " *
        "@caption names only the node written immediately before it",
    )
    node = _content_items(c)[end][2]
    # one caption per node: `caption=` and then `@caption`, or two `@caption`s, is an error
    (node === CTX.captioned || (kind !== :check && !isempty(node.caption))) && error(
        "Pinax: @caption in \"$(c.anchor)\" names a $(kind) that already has a caption — a node " *
        "takes one caption, from `caption=` or from one `@caption`",
    )
    kind === :check ? (node.label = string(s)) : (node.caption = string(s))   # a check: its quantity
    CTX.captioned = node
    return nothing
end

"""
    @desc md"…"

A prose block (markdown + math), placed in content order like any other node. A container holds any
number of them, interleaved with figures, tables and code (Conventions › Content).
"""
macro desc(x)
    at = (String(string(__source__.file)), __source__.line)
    return quote
        _set_desc!($(esc(x)); at=($(at)))
    end
end
function _set_desc!(s; at=nothing)
    c = _current_container()
    c === :inert && return nothing   # inside a test with the report off — no-op (invariant V)
    c === nothing && error("@desc outside of a @section or @page")
    src = string(s)
    tid = _node_id!(c, nothing, Symbol(c.id, "_txt_", _stable_hash(src)), "prose block")
    push!(c.texts, Prose(tid, _anchor(tid), src, _defined_at(at)))
    push!(c.content, :text => length(c.texts))
    return nothing
end

"""
Inject a raw block into the current section — the escape hatch for project-specific UI that markdown
can't express (coverage tables, broken-data banners; notes 06 §6). `@raw x [id=:name]` evaluates `x`
to a string: the gallery emits it verbatim (trusted author content) under its id, `agent.json` and
`agent.md` carry the HTML itself, and LaTeX leaves it out with a diagnostic. Without `id=` the id is
generated from the HTML. `@raw raw\"<table class=cov>…</table>\"`. Use `@desc` for prose; `@raw` for
hand-built markup.
"""
macro raw(args...)
    html = nothing
    id = nothing
    for a in args
        if a isa Expr && a.head === :(=) && a.args[1] === :id
            id = a.args[2]
        elseif html === nothing
            html = a
        else
            error("@raw takes one HTML expression (plus `id=`)")
        end
    end
    html === nothing && error("@raw needs an HTML expression")
    at = (String(string(__source__.file)), __source__.line)
    return :(_push_raw!($(esc(html)); id=($(esc(id))), at=($(at))))
end
function _push_raw!(s; id=nothing, at=nothing)
    c = _current_container()
    c === :inert && return nothing   # inside a test with the report off — no-op (invariant V)
    c === nothing && error("@raw outside of a @section or @page")
    html = string(s)
    rid = _node_id!(c, id, Symbol(c.id, "_raw_", _stable_hash(html)), "raw block")
    push!(c.raws, RawBlock(rid, _anchor(rid), html, _defined_at(at)))
    push!(c.content, :raw => length(c.raws))
    return nothing
end

"Set the page main figure. `@thumbnail :figid` (priority: explicit `@thumbnail` > a `thumbnail=true` `@figure` > the top figure; notes 02 resolve)."
macro thumbnail(x)
    return quote
        _set_thumbnail!($(esc(x)))
    end
end
function _set_thumbnail!(x)
    pg = CTX.page
    if pg === nothing
        _probe_test_container() === :none || return nothing   # inside a test, no @page → no-op
        error("@thumbnail outside of a @page")
    end
    x isa Symbol || error(
        "Pinax: @thumbnail takes the id of a figure on its page, a Symbol (got $(repr(x))); " *
        "to make an inline plot the main figure, give it `thumbnail = true`",
    )
    pg.thumbnail = FigRef(x)   # checked against the page's figures when the document is resolved
    return nothing
end

"This page contributes no main figure to the index."
macro no_thumbnail()
    return quote
        $(_set_no_thumbnail!)()
    end
end
function _set_no_thumbnail!()
    pg = CTX.page
    if pg === nothing
        _probe_test_container() === :none || return nothing   # inside a test, no @page → no-op
        error("@no_thumbnail outside of a @page")
    end
    pg.no_thumbnail = true
    return nothing
end

"Raw string (preserves `\$…\$`). Used by `@desc md\"…\"` etc."
macro md_str(s)
    return s
end

# ============================================================ resolve (minimal: thumbnail)

"Resolve a page's main figure: explicit `@thumbnail` > `thumbnail=true` marker > top (first) figure (notes 02)."
function resolved_thumbnail(pg::Page)
    pg.no_thumbnail && return nothing
    pg.thumbnail === nothing || return pg.thumbnail
    # a thumbnail=true marker anywhere (page-level figures first, then sections)
    for f in pg.figures
        f.thumbnail && return FigRef(f.id)
    end
    for sec in _all_sections(pg), f in sec.figures
        f.thumbnail && return FigRef(f.id)
    end
    # else the first figure (page-level, then the first section's)
    isempty(pg.figures) || return FigRef(pg.figures[1].id)
    for sec in _all_sections(pg)
        isempty(sec.figures) || return FigRef(sec.figures[1].id)
    end
    return nothing
end

# ============================================================ show (ergonomics)

function Base.show(io::IO, d::Document)
    return print(
        io,
        "Pinax.Document(",
        length(d.pages),
        " pages, theme=",
        repr(d.meta.theme),
        ", ",
        length(d.diag.entries),
        " diag)",
    )
end
function Base.show(io::IO, p::Page)
    return print(io, "Pinax.Page(", repr(p.id), ", ", length(p.sections), " sections)")
end
function Base.show(io::IO, s::Section)
    return print(io, "Pinax.Section(", repr(s.id), ", ", length(s.figures), " figures)")
end
function Base.show(io::IO, f::Figure)
    return print(
        io, "Pinax.Figure(", repr(f.id), f.params === nothing ? "" : ", params=set", ")"
    )
end
