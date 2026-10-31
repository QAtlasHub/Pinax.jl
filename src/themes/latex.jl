# themes/latex.jl — a LaTeX theme: emit a compilable `.tex` (→ PDF) from the doc tree (notes 11).
#
# Enabled by the pluggable-theme framework (theme.jl). `@desc`/`@caption` markdown is converted to
# LaTeX via the Markdown stdlib (`Markdown.latex`); math is native ($…$ / display); `@ref`/`@cite`
# become `\ref`/`\cite` (LaTeX numbers them); figures are `\includegraphics` (PDF). `@newcommand`
# maps straight to `\newcommand`. If `latexmk`/`pdflatex` is on PATH the `.tex` is compiled to PDF;
# otherwise the `.tex` is emitted for the user to compile. `@raw` (HTML) is skipped by this theme.

"""
Abstract base for the LaTeX theme: its `emit_*` methods are defined on `LaTeXBase`, so a custom theme
`struct MyTeX <: LaTeXBase end` inherits the whole LaTeX renderer and overrides only the dispatch
points it wants (e.g. `emit_figure(::MyTeX, …)`).
"""
abstract type LaTeXBase <: Theme end

"LaTeX/PDF theme — emit a compilable `.tex` from the doc tree."
struct LaTeXTheme <: LaTeXBase end

output_format(::LaTeXBase) = :latex
figure_formats(::LaTeXBase) = Symbol[:pdf]   # vector PDF for print / pdflatex \includegraphics

# Single-pass LaTeX escaping for plain text (titles, bib entries). Markdown bodies instead go
# through `Markdown.latex`, which does its own escaping.
function _texesc(s)
    out = IOBuffer()
    for c in string(s)
        if c == '\\'
            print(out, "\\textbackslash{}")
        elseif c in ('&', '%', '$', '#', '_', '{', '}')
            print(out, '\\', c)
        elseif c == '~'
            print(out, "\\textasciitilde{}")
        elseif c == '^'
            print(out, "\\textasciicircum{}")
        else
            print(out, c)
        end
    end
    return String(take!(out))
end

# A display `$$…$$` block -> equation (numbered, with \label) when @label-tagged, else \[ … \].
function _latex_eq(matched)
    m = match(_EQ_RE, matched)
    label = m.captures[1]
    math = m.captures[2]
    return if label !== nothing
        string(
            "\\begin{equation}\\label{",
            _anchor(Symbol(label)),
            "} ",
            math,
            " \\end{equation}",
        )
    else
        string("\\[ ", math, " \\]")
    end
end

function _latex_ref(matched, ids, rdiag)
    m = match(_REF_RE, matched)
    text = m.captures[1]
    id = m.captures[2] !== nothing ? m.captures[2] : m.captures[3]
    anchor = get(ids, Symbol(id), nothing)
    if anchor === nothing
        push!(rdiag, DiagEntry(WARNING, "latex", "@ref to unknown id :$(id)"))
        return "??"
    end
    return if (text !== nothing && !isempty(text))
        string("\\hyperref[", anchor, "]{", _texesc(text), "}")
    else
        string("\\ref{", anchor, "}")
    end
end

function _latex_cite(matched)
    m = match(_CITE_RE, matched)
    key = m.captures[2] !== nothing ? m.captures[2] : m.captures[3]
    return string("\\cite{", key, "}")
end

# Render a desc/caption markdown source to LaTeX, protecting math + cross-references from the
# markdown pass (same token scheme as the gallery), then re-injecting their LaTeX forms.
function _latex_render(source::AbstractString, ids, rdiag)
    subs = String[]
    tok!(x) = (push!(subs, x); _tok(length(subs)))
    s = replace(source, _EQ_RE => m -> tok!(_latex_eq(m)))
    s = replace(s, _INLINE_EQ_RE => m -> tok!(m))             # native inline math, verbatim
    s = replace(s, _REF_RE => m -> tok!(_latex_ref(m, ids, rdiag)))
    s = replace(s, _CITE_RE => m -> tok!(_latex_cite(m)))
    s = replace(s, r"@label\(:\w+\)\s*" => "")
    out = try
        rstrip(Markdown.latex(Markdown.parse(s)))
    catch e
        e isa InterruptException && rethrow()
        _texesc(s)
    end
    for (k, frag) in enumerate(subs)
        out = replace(out, _tok(k) => frag)
    end
    return out
end

# Per-render LaTeX state, threaded through the per-node contract methods on `LaTeXBase`
# (emit_document/page/section/figure/text/comments). `ctx` is left UNTYPED on those methods on
# purpose — annotating it `::LaTeXCtx` would force every variant to reuse this exact struct and can
# re-introduce dispatch ambiguity. Same override *mechanism* as the gallery, not the same node set
# (the gallery additionally has emit_head/foot/index/view).
struct LaTeXCtx
    io::IOBuffer
    ids::Dict{Symbol,String}
    comments::Dict{Symbol,Vector{Comment}}
    cache::RenderCache
    rdiag::Vector{DiagEntry}
    outdir::String
end

# `@desc`/`@caption` markdown → LaTeX (the latex theme's emit_text).
function emit_text(::LaTeXBase, source, item, ctx; block=true)
    return _latex_render(source, ctx.ids, ctx.rdiag)
end

# A node's co-located comments as a "Notes" itemize.
function emit_comments(theme::LaTeXBase, anchor, ctx)
    turns = get(ctx.comments, Symbol(anchor), Comment[])
    isempty(turns) && return nothing
    io = ctx.io
    println(io, "\\par\\noindent\\textbf{Notes.}\\begin{itemize}")
    for c in turns
        who = isempty(c.author) ? "" : string("\\textbf{", _texesc(c.author), "} ")
        println(io, "\\item ", who, emit_text(theme, c.text, anchor, ctx))
    end
    println(io, "\\end{itemize}")
    return nothing
end

# A node LaTeX cannot show is recorded in its diagnostics, never dropped silently (Conventions › Faces).
function _latex_left_out!(ctx, anchor, why)
    push!(
        ctx.rdiag,
        DiagEntry(WARNING, string(anchor), string(why, "; left out of the LaTeX output")),
    )
    return nothing
end

# One (already-materialized) figure → a \includegraphics figure.
function emit_figure(theme::LaTeXBase, fig, ctx)
    if isempty(fig.assets)
        _latex_left_out!(ctx, fig.anchor, "figure has no asset to include")
        return emit_comments(theme, fig.anchor, ctx)   # its comments stay, as in every face
    end
    io = ctx.io
    rel = replace(relpath(fig.assets[1], ctx.outdir), '\\' => '/')
    println(io, "\\begin{figure}[htbp]\\centering")
    println(io, "\\includegraphics[width=0.8\\linewidth]{", rel, "}")
    cap = isempty(fig.caption) ? "" : emit_text(theme, fig.caption, fig.anchor, ctx)
    isempty(cap) || println(io, "\\caption{", cap, "}")
    println(io, "\\label{", fig.anchor, "}\\end{figure}")
    emit_comments(theme, fig.anchor, ctx)   # a figure's comments follow it, as in every face
    return nothing
end

# Materialize one figure to `assetdir`, then emit it.
function _latex_emit_fig!(theme::LaTeXBase, fig, assetdir, ctx)
    try
        materialize!(fig, joinpath(assetdir, fig.anchor), figure_formats(theme), ctx.cache)
    catch e
        e isa InterruptException && rethrow()
        push!(ctx.rdiag, DiagEntry(ERROR, fig.anchor, "materialize failed: $(e)"))
        return emit_comments(theme, fig.anchor, ctx)   # a failed figure keeps its comments
    end
    emit_figure(theme, fig, ctx)
    return nothing
end

# Emit a container's content in declaration order (a @raw block is HTML: left out, and said so;
# checks are rendered by the container's check table, not inline).
function _latex_emit_content!(theme::LaTeXBase, c, assetdir, ctx; page=nothing)
    for (_, node) in _content_items(c)
        if node isa Figure
            _latex_emit_fig!(theme, node, assetdir, ctx)
        elseif node isa Section   # a nested section, in declaration order
            emit_section(theme, node, page, ctx)
        elseif node isa Check
            nothing   # in the container's check table, under its verdict band
        else
            emit_node(theme, node, ctx)
        end
    end
    return nothing
end

# The leaves of a LaTeX content walk.
function emit_node(theme::LaTeXBase, p::Prose, ctx)
    return println(ctx.io, emit_text(theme, p.source, p.anchor, ctx))
end
emit_node(theme::LaTeXBase, t::Table, ctx) = emit_table(theme, t, ctx)
emit_node(theme::LaTeXBase, b::CodeBlock, ctx) = emit_code(theme, b, ctx)
function emit_node(::LaTeXBase, r::RawBlock, ctx)
    return _latex_left_out!(ctx, r.anchor, "a @raw block is HTML, which has no LaTeX form")
end

# A `@code` block → a verbatim listing of the source, then its captured output.
function emit_code(::LaTeXBase, blk, ctx)
    io = ctx.io
    isempty(blk.caption) ||
        println(io, "\\par\\noindent\\textbf{", _texesc(blk.caption), "}")
    println(io, "\\begin{verbatim}")
    println(io, blk.source)
    isempty(blk.output) || (println(io, "# => "); println(io, blk.output))
    println(io, "\\end{verbatim}")
    return nothing
end

# One check -> a tabular row: id, label, got, want, Δ, tol, PASS/FAIL (cells escaped as text).
function emit_check(::LaTeXBase, chk, ctx)
    io = ctx.io
    println(
        io,
        join(
            (
                _texesc(string(chk.id)),
                _texesc(
                    isempty(chk.source) ? chk.label : string(chk.label, " @ ", chk.source)
                ),
                _texesc(_cellstr(chk.got)),
                _texesc(_cellstr(chk.want)),
                _texesc(_cellstr(chk.delta)),
                _texesc(_cellstr(chk.tol)),
                chk.pass ? "PASS" : "FAIL",
            ),
            " & ",
        ),
        " \\\\",
    )
    return nothing
end

# The checks of any container (#173): a `tabular` of the checks it owns, then a verdict line over its
# whole subtree. Nothing when the subtree has none.
function _latex_checks!(theme::LaTeXBase, c, ctx)
    io = ctx.io
    v = verdict(c)
    v === nothing && return nothing
    # the verdict band over the subtree leads, then the container's own checks (Conventions › Faces)
    println(
        io,
        "\\par\\noindent\\textbf{Verdict: ",
        v.verdict,
        "} (",
        v.passed,
        "/",
        v.total,
        ")",
    )
    isempty(c.checks) || _latex_check_table!(theme, c.checks, ctx)
    return nothing
end

function _latex_check_table!(theme::LaTeXBase, checks, ctx)
    io = ctx.io
    println(io, "\\begin{tabular}{lllllll}\\hline")
    println(io, "id & label & got & want & \$\\Delta\$ & tol & result \\\\\\hline")
    for chk in checks
        emit_check(theme, chk, ctx)
    end
    println(io, "\\hline\\end{tabular}")
    return nothing
end

# A @table artifact -> a LaTeX `table`/`tabular` (cells escaped as text).
function emit_table(theme::LaTeXBase, tbl, ctx)
    io = ctx.io
    ncol = if isempty(tbl.header)
        (isempty(tbl.rows) ? 0 : length(tbl.rows[1]))
    else
        length(tbl.header)
    end
    ncol == 0 && return _latex_left_out!(ctx, tbl.anchor, "table has no columns")
    rowend = "\\\\"
    println(io, "\\begin{table}[htbp]\\centering")
    isempty(tbl.caption) ||
        println(io, "\\caption{", emit_text(theme, tbl.caption, tbl.anchor, ctx), "}")
    println(io, "\\label{", tbl.anchor, "}")
    println(io, "\\begin{tabular}{", repeat("l", ncol), "}\\hline")
    isempty(tbl.header) ||
        println(io, join((_texesc(h) for h in tbl.header), " & "), " ", rowend, "\\hline")
    for row in tbl.rows
        println(io, join((_texesc(_cellstr(c)) for c in row), " & "), " ", rowend)
    end
    println(io, "\\hline\\end{tabular}")
    println(io, "\\end{table}")
    emit_comments(theme, tbl.anchor, ctx)   # a table's comments follow it, as a figure's do
    return nothing
end

# The one place LaTeX turns depth into a heading, for parts (0), pages (1, `\\section`) and sections
# (2…, a top-level one is `\\subsection`). Past `\\subparagraph` the level is kept as a bold run-in
# heading, with a diagnostic (never flattened).
const _LATEX_HEADINGS = (
    "part", "section", "subsection", "subsubsection", "paragraph", "subparagraph"
)
_latex_heading(sec, ctx) = _latex_heading(sec.depth, sec.title, sec.anchor, ctx)
function _latex_heading(depth::Int, title, anchor, ctx)
    t = _texesc(title)
    depth < length(_LATEX_HEADINGS) &&
        return string("\\", _LATEX_HEADINGS[depth + 1], "{", t, "}\\label{", anchor, "}")
    push!(
        ctx.rdiag,
        DiagEntry(
            WARNING,
            anchor,
            "section at depth $(depth) is deeper than \\subparagraph; rendered as a bold run-in heading",
        ),
    )
    return string("\\par\\noindent\\textbf{", t, "}\\label{", anchor, "}")
end

function emit_section(theme::LaTeXBase, sec, pg, ctx)
    io = ctx.io
    println(io, _latex_heading(sec, ctx))
    _latex_checks!(theme, sec, ctx)
    _latex_emit_content!(
        theme, sec, joinpath(ctx.outdir, "figures", pg.anchor, sec.anchor), ctx; page=pg
    )
    emit_comments(theme, sec.anchor, ctx)
    return nothing
end

function emit_page(theme::LaTeXBase, pg, ctx)
    io = ctx.io
    # a page = one \section; then its content in declaration order (its subsections included)
    println(io, _latex_heading(1, pg.title, pg.anchor, ctx))
    pg.status === :draft && println(io, "\\par\\noindent\\textit{Draft.}")   # its maturity, as every face shows it
    # checks lead (tabular of the page's own checks + a verdict line over its subtree)
    _latex_checks!(theme, pg, ctx)
    _latex_emit_content!(
        theme, pg, joinpath(ctx.outdir, "figures", pg.anchor), ctx; page=pg
    )
    emit_comments(theme, pg.anchor, ctx)
    return nothing
end

function _part_title(doc::Document, pid)
    return (
        i=findfirst(p -> first(p) === pid, doc.parts);
        i === nothing ? string(pid) : last(doc.parts[i])
    )
end

function emit_document(
    theme::LaTeXBase,
    doc::Document,
    outdir::AbstractString,
    cache::RenderCache;
    comments_file::AbstractString=joinpath(outdir, "comments.toml"),
)
    io = IOBuffer()
    rdiag = DiagEntry[]
    ids = Dict{Symbol,String}(id => n.anchor for (id, n) in doc.refs)
    bib = _load_bib(doc.meta.bib_sources, rdiag)
    _, citeorder = _gallery_citations(doc, bib)
    comments, _bm = _read_comments(doc, comments_file, rdiag)
    title = isempty(doc.meta.title) ? "Pinax gallery" : doc.meta.title
    ctx = LaTeXCtx(io, ids, comments, cache, rdiag, String(outdir))

    println(io, "\\documentclass{article}")
    println(
        io,
        "\\usepackage{graphicx}\\usepackage{amsmath}\\usepackage{hyperref}",
        "\\usepackage[margin=1in]{geometry}",
    )
    for (name, defn) in doc.newcommands
        println(io, "\\newcommand{", name, "}{", defn, "}")
    end
    println(io, "\\title{", _texesc(title), "}\\date{}")
    println(io, "\\begin{document}\\maketitle")
    prev_part = :__start__
    for pg in doc.pages
        if pg.part !== prev_part && pg.part !== nothing
            println(io, _latex_heading(0, _part_title(doc, pg.part), _anchor(pg.part), ctx))
        end
        prev_part = pg.part
        emit_page(theme, pg, ctx)
    end
    if !isempty(citeorder)
        println(io, "\\begin{thebibliography}{99}")
        for key in citeorder
            println(io, "\\bibitem{", key, "} ", _texesc(format_bib_entry(bib[key])))
        end
        println(io, "\\end{thebibliography}")
    end
    println(io, "\\end{document}")

    texpath = joinpath(outdir, "document.tex")
    write(texpath, String(take!(io)))
    result = _latex_compile(texpath, outdir, rdiag)
    _write_latex_diagnostics(outdir, doc, rdiag)   # after compiling, so what it said is included
    return result
end

# Diagnostics for non-gallery themes are a markdown sidecar (notes 09): the build's and this render's,
# compiling included. With none, a sidecar left by an earlier render is removed.
function _write_latex_diagnostics(outdir, doc, rdiag)
    es = vcat(doc.diag.entries, rdiag)
    f = joinpath(outdir, "diagnostics.md")
    isempty(es) && return rm(f; force=true)
    open(f, "w") do io
        println(io, "# Diagnostics")
        for e in es
            println(io, "- **", e.severity, "** `", e.item, "` — ", e.message)
        end
    end
    return nothing
end

# Compile to PDF with latexmk/pdflatex if available; otherwise leave the .tex for the user.
function _latex_compile(texpath, outdir, rdiag)
    name = basename(texpath)
    if Sys.which("latexmk") !== nothing
        cmd = `latexmk -pdf -interaction=nonstopmode $(name)`
    elseif Sys.which("pdflatex") !== nothing
        cmd = `pdflatex -interaction=nonstopmode $(name)`
    else
        push!(
            rdiag,
            DiagEntry(
                INFO,
                "latex",
                "no LaTeX compiler (latexmk/pdflatex) found; emitted .tex only",
            ),
        )
        return texpath
    end
    try
        # pdflatex needs two passes to resolve \ref/\cite; latexmk handles passes itself.
        run(Cmd(cmd; dir=outdir))
        endswith(string(cmd.exec[1]), "pdflatex") && run(Cmd(cmd; dir=outdir))
        pdf = replace(texpath, r"\.tex$" => ".pdf")
        return isfile(pdf) ? pdf : texpath
    catch e
        e isa InterruptException && rethrow()
        push!(rdiag, DiagEntry(ERROR, "latex", "LaTeX compile failed: $(e)"))
        return texpath
    end
end

# Register, selectable via `@pinaxsetup theme=:latex` / `render(theme=:latex)`.
register_theme!(:latex, LaTeXTheme())
