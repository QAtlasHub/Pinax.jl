# themes/agent.jl — the agent / MCP backend (notes 11). Emits the document as STRUCTURED DATA for
# LLM consumption + data verification, not human HTML. The SAME document renders to :gallery (human)
# or :agent (machine) by switching the theme — the backend abstraction's real stress test, since the
# output here is JSON/text, not a "document".
#
# It is the same compiled report as the gallery, in the same reading order, for an agent that discusses
# it or drives a revision (Conventions › The agent face). Per figure it carries what is claimed (the
# caption), where and how it was made (`defined_at`, the code, the params / DataKey) and pointers to
# what is behind it: its image and its data file, described exactly and never inlined as a cut copy.
# Output: `agent.json` (every unit id-addressable, the index tools read) and `agent.md` (the report an
# agent reads).

"""
Abstract base for the agent / MCP backend: its `emit_*` methods are defined on `AgentBase`, so a
custom theme `struct MyAgent <: AgentBase end` inherits the serializer and overrides only the dispatch
points it wants (e.g. `emit_figure(::MyAgent, …)` to add a field to the JSON).
"""
abstract type AgentBase <: Theme end

"Agent / MCP backend — emit the document as structured data (agent.json + agent.md)."
struct AgentTheme <: AgentBase end

output_format(::AgentBase) = :agent
figure_formats(::AgentBase) = Symbol[:svg, :table]   # svg (vision) + a CSV of every plotted point;
# pre-made file paths copy as-is and have no data file.

# ---------- JSON emit (the machine / MCP substrate) ----------

# Per-render agent state, threaded through the per-node contract methods on `AgentBase`
# (emit_document/page/section/figure), serializing to JSON instead of HTML. `ctx` is left UNTYPED on
# those methods on purpose — annotating it `::AgentCtx` can re-introduce dispatch ambiguity with
# variants. Same override *mechanism* as the gallery, not the same node set: the agent has no
# emit_text/emit_comments — a figure's comments are embedded inline in its JSON object.
struct AgentCtx
    io::IOBuffer
    outdir::String
    comments::Dict{Symbol,Vector{Comment}}
    cache::RenderCache
    rdiag::Vector{DiagEntry}
    # figure id => (its images, its data file or nothing), all in THIS face's directory
    files::Dict{Symbol,Tuple{Vector{String},Union{String,Nothing}}}
end
function AgentCtx(io, outdir, comments, cache, rdiag)
    return AgentCtx(io, outdir, comments, cache, rdiag, Dict{Symbol,Any}())
end

# A JSON scalar for a param/cell value: numbers/bools stay native (a tool reads 16, not "16");
# missing/nothing map to JSON null; NaN/Inf are not valid JSON numbers so they're quoted; anything
# else is stringified.
_agent_jsonval(::Missing) = "null"
_agent_jsonval(::Nothing) = "null"
_agent_jsonval(v::Bool) = v ? "true" : "false"
_agent_jsonval(v::Integer) = string(v)
_agent_jsonval(v::Real) = isfinite(v) ? string(v) : _jsonstr(string(v))
_agent_jsonval(v::AbstractString) = _jsonstr(v)
_agent_jsonval(v) = _jsonstr(string(v))

# A JSON array on `io`: `[`, then each element as `f(x)` prints it, comma-separated, then `]`.
function _json_array(f, io, xs)
    print(io, "[")
    for (i, x) in enumerate(xs)
        i == 1 || print(io, ",")
        f(x)
    end
    return print(io, "]")
end

# A JSON array of strings on `io`.
_json_strings(io, xs) = _json_array(x -> print(io, _jsonstr(x)), io, xs)

# A JSON object on `io`, the counterpart of `_json_array`: `{`, then each `"key":value`,
# comma-separated, then `}`. A value is JSON text already rendered (a string or an integer), or a
# zero-argument function that prints it on `io` — so a nested array streams in key order (a figure is
# materialized when its key is reached).
function _json_object(io, kvs...)
    print(io, "{")
    for (i, (k, v)) in enumerate(kvs)
        i == 1 || print(io, ",")
        print(io, _jsonstr(k), ":")
        _json_value(io, v)
    end
    return print(io, "}")
end
_json_value(io, v::Union{AbstractString,Integer}) = print(io, v)
_json_value(io, f) = f()

# A figure's `params` binding as JSON: null, a structured {axis: value} object when the params object
# is introspectable (a NamedTuple/Dict, or a ParamIO.DataKey via the extension's `_params_describe`),
# else a string fallback (an opaque params value is still recorded for provenance).
function _agent_params_json(io, params)
    params === nothing && return print(io, "null")
    desc = _params_describe(params)
    desc === nothing && return print(io, _jsonstr(string(params)))
    return _json_object(io, (k => _agent_jsonval(v) for (k, v) in desc)...)
end

# One figure → its JSON object: what it claims (caption), where and how it was made (`defined_at`,
# code, params) and pointers to what is behind it — its images and its data file, described exactly
# (columns, points per series) and never inlined (Conventions › The agent face).
function emit_figure(theme::AgentBase, fig, ctx)
    io = ctx.io
    imgs, csv = get(ctx.files, fig.id, (String[], nothing))
    _json_object(
        io,
        "id" => _jsonstr(string(fig.id)),
        "caption" => _jsonstr(fig.caption),
        "defined_at" => _jsonstr(fig.defined_at),
        "code" => _jsonstr(fig.code),
        "params" => () -> _agent_params_json(io, fig.params),
        "assets" => () -> _json_strings(io, (_agent_rel(a, ctx) for a in imgs)),
        "data" => () -> _agent_data_json(io, csv, ctx),
        "comments" => () -> _agent_comments!(fig.anchor, ctx),
    )
    return nothing
end

# A path in this face's directory, as `agent.json` / `agent.md` name it.
_agent_rel(path, ctx) = _rel_url(path, ctx.outdir)

# A figure's data file as a pointer and an exact description of what it holds — its columns (named by
# the axis labels) and each series with its point count — or `null` when the figure has none.
function _agent_data_json(io, csv, ctx)
    d = csv === nothing ? nothing : _data_descriptor(csv)
    d === nothing && return print(io, "null")
    series((label, n)) = _json_object(io, "label" => _jsonstr(label), "points" => n)
    return _json_object(
        io,
        "path" => _jsonstr(_agent_rel(csv, ctx)),
        "columns" => () -> _json_strings(io, d.columns),
        "series" => () -> _json_array(series, io, d.series),
    )
end

# The id-keyed comment thread of any node (a figure, a table, a page, a section) as
# `[{author, text}]`.
function _agent_comments!(anchor, ctx)
    return _json_array(ctx.io, get(ctx.comments, Symbol(anchor), Comment[])) do c
        return _json_object(
            ctx.io, "author" => _jsonstr(c.author), "text" => _jsonstr(c.text)
        )
    end
end

# One @table -> a JSON object (header + native-typed rows, then its comments). A table is already the
# LLM-native form.
function emit_table(::AgentBase, tbl, ctx)
    io = ctx.io
    row(r) = _json_array(cell -> print(io, _agent_jsonval(cell)), io, r)
    _json_object(
        io,
        "id" => _jsonstr(string(tbl.id)),
        "caption" => _jsonstr(tbl.caption),
        "defined_at" => _jsonstr(tbl.defined_at),
        "code" => _jsonstr(tbl.code),
        "header" => () -> _json_strings(io, tbl.header),
        "rows" => () -> _json_array(row, io, tbl.rows),
        "comments" => () -> _agent_comments!(tbl.anchor, ctx),
    )
    return nothing
end

# One @code block → a JSON object: the source and its captured output (a tool reads the computation).
function emit_code(::AgentBase, blk, ctx)
    _json_object(
        ctx.io,
        "id" => _jsonstr(string(blk.id)),
        "caption" => _jsonstr(blk.caption),
        "defined_at" => _jsonstr(blk.defined_at),
        "lang" => _jsonstr(blk.lang),
        "source" => _jsonstr(blk.source),
        "output" => _jsonstr(blk.output),
    )
    return nothing
end

# One check -> a JSON object with native-typed numerics (a tool reads 4.6e-5, not "4.6e-5"); an
# indicator has no numbers, so they are null.
function emit_check(::AgentBase, chk, ctx)
    num(x) = chk.kind === :indicator ? "null" : _agent_jsonval(x)
    _json_object(
        ctx.io,
        "id" => _jsonstr(string(chk.id)),
        "label" => _jsonstr(chk.label),
        "got" => num(chk.got),
        "want" => num(chk.want),
        "delta" => num(chk.delta),
        "tol" => num(chk.tol),
        "kind" => _jsonstr(string(chk.kind)),
        "outcome" => _jsonstr(string(chk.outcome)),   # pass | fail | error
        "pass" => _agent_jsonval(passed(chk)),        # derived from the outcome
        "defined_at" => _jsonstr(chk.source),   # where the @test was written, `path:line`
        # the code is ONE object in `codes` (kind "code"); a check REFERENCES it by id, or null
        "code_id" => chk.code_id === nothing ? "null" : _jsonstr(string(chk.code_id)),
    )
    return nothing
end

# A page/section's content in declaration order as {kind,id} — lets a consumer reconstruct the
# interleave of figures and tables (the typed `figures`/`tables` arrays preserve within-type order).
function _agent_content!(c, ctx)
    io = ctx.io
    _json_array(io, _content_items(c)) do (kind, item)
        item isa Union{Prose,Figure,Table,Check,CodeBlock,RawBlock,Section} ||
            _unhandled_node("agent.json", item)
        return _json_object(
            io, "kind" => _jsonstr(string(kind)), "id" => _jsonstr(string(item.id))
        )
    end
    return nothing
end

# Materialize each figure (the asset is the verifiable artifact), then emit them as a JSON array.
# Inlined rather than a shared helper so formats come straight from `figure_formats(theme)` — keeps
# the materialize-all-then-emit-all two-phase shape and mirrors `_latex_emit_fig!`.
function _agent_figs!(theme::AgentBase, figs, assetdir, ctx)
    fmts = figure_formats(theme)
    for fig in figs
        base = joinpath(assetdir, fig.anchor)
        if fig.data !== nothing
            # Eager `data=`: the data file is written from it and `gen()` — the plotting backend — is
            # never touched, so agent.json stays producible Plots/Makie-free. No image in this face.
            csv = _write_csv(fig.data, base)   # parsed where `data=` was written
            ctx.cache.new[_manifest_key(base, ctx.cache.outdir)] = Dict{String,Any}(
                "key" => "data", "assets" => [relpath(csv, ctx.cache.outdir)]
            )
            ctx.files[fig.id] = (String[], csv)
            continue
        end
        if !_try_materialize!(fig, base, fmts, ctx.cache, ctx.rdiag)   # into this face's directory
            ctx.files[fig.id] = (String[], nothing)
            continue
        end
        imgs = filter(a -> !endswith(lowercase(a), ".csv"), fig.assets)
        i = findfirst(a -> endswith(lowercase(a), ".csv"), fig.assets)
        csv = i === nothing ? nothing : fig.assets[i]
        ctx.files[fig.id] = (imgs, csv)
        # an agent reads a figure through its data; one without data is said to be so, never silent
        csv === nothing && push!(
            ctx.rdiag,
            DiagEntry(
                WARNING,
                fig.anchor,
                "this figure has no data form (a pre-made image, or a plot the loaded extension " *
                "cannot read): an agent sees it only through its image",
            ),
        )
    end
    _json_array(fig -> emit_figure(theme, fig, ctx), ctx.io, figs)
    return nothing
end

# A derived verdict as JSON (`null` when the subtree holds no checks — never a vacuous PASS).
function _agent_verdict_json(v)
    v === nothing && return "null"
    return sprint() do io
        return _json_object(
            io,
            "verdict" => _jsonstr(v.verdict),
            "passed" => v.passed,
            "total" => v.total,
            "failed" => () -> _json_strings(io, v.failed),
        )
    end
end

# Pages and sections are one kind of container, so they share one body and one set of keys: a page
# adds only `part` and `status` (Conventions › Faces). Text the author did not write is "". Each
# array is printed when its key is reached, in this order.
function _agent_container_fields(theme::AgentBase, c, pg, assetdir, ctx)
    io = ctx.io
    # a container's prose blocks and @raw blocks (each one's HTML, as written: an agent reads what the
    # gallery shows), in the order written; their place among the other nodes is in `content`
    text(t) = _json_object(
        io,
        "id" => _jsonstr(string(t.id)),
        "text" => _jsonstr(t.source),
        "defined_at" => _jsonstr(t.defined_at),
    )
    raw(r) = _json_object(
        io,
        "id" => _jsonstr(string(r.id)),
        "html" => _jsonstr(r.html),
        "defined_at" => _jsonstr(r.defined_at),
    )
    return (
        "summary" => _jsonstr(something(c.summary, "")),
        "verdict" => _agent_verdict_json(verdict(c)),
        # its own checks, each through the `emit_check` dispatch point, so the `{kind:"check", id}`
        # entries in its `content` resolve within the same object (#173)
        "checks" => () -> _json_array(x -> emit_check(theme, x, ctx), io, c.checks),
        "texts" => () -> _json_array(text, io, c.texts),
        "figures" => () -> _agent_figs!(theme, c.figures, assetdir, ctx),
        "tables" => () -> _json_array(x -> emit_table(theme, x, ctx), io, c.tables),
        "codes" => () -> _json_array(x -> emit_code(theme, x, ctx), io, c.codes),
        "raws" => () -> _json_array(raw, io, c.raws),
        "content" => () -> _agent_content!(c, ctx),
        # a page or section carries its own thread, as a figure does
        "comments" => () -> _agent_comments!(c.anchor, ctx),
        # the section tree: children nest inside their parent's object, in declaration order
        "sections" =>
            () -> _json_array(x -> emit_section(theme, x, pg, ctx), io, c.sections),
    )
end

function emit_section(theme::AgentBase, sec, pg, ctx)
    assetdir = joinpath(ctx.outdir, "assets", "figures", pg.anchor, sec.anchor)
    return _json_object(
        ctx.io,
        "id" => _jsonstr(string(sec.id)),
        "title" => _jsonstr(sec.title),
        "depth" => sec.depth,
        _agent_container_fields(theme, sec, pg, assetdir, ctx)...,
    )
end

function emit_page(theme::AgentBase, pg, ctx)
    assetdir = joinpath(ctx.outdir, "assets", "figures", pg.anchor)
    return _json_object(
        ctx.io,
        "id" => _jsonstr(string(pg.id)),
        "title" => _jsonstr(pg.title),
        "depth" => 1,
        "part" => pg.part === nothing ? "null" : _jsonstr(string(pg.part)),
        "status" => _jsonstr(string(pg.status)),
        _agent_container_fields(theme, pg, pg, assetdir, ctx)...,
    )
end

# agent.json up to its pages (title + parts + pages, the latter via the per-node contract); the
# diagnostics close it once agent.md has run.
function _agent_json(theme::AgentBase, doc::Document, ctx)
    io = ctx.io
    print(io, "{\"title\":", _jsonstr(doc.meta.title), ",\"parts\":")
    _json_array(io, doc.parts) do (pid, ptitle)
        d = get(doc.part_descs, pid, nothing)
        st = get(doc.part_status, pid, nothing)
        return _json_object(
            io,
            "id" => _jsonstr(string(pid)),
            "title" => _jsonstr(ptitle),
            "desc" => _jsonstr(d === nothing ? "" : d.source),
            "status" => st === nothing ? "null" : _jsonstr(string(st)),
        )
    end
    print(io, ",\"pages\":")
    _json_array(pg -> emit_page(theme, pg, ctx), io, doc.pages)
    return String(take!(io))
end

# agent.json's closing `diagnostics`: what the build and this render recorded — a left-out node, a
# failed figure, an agent.md fallback heading — as data, so an agent sees the gaps instead of
# inferring them (Conventions › Faces). Written last, once agent.md has added its own.
function _agent_json_diagnostics(entries)
    io = IOBuffer()
    print(io, ",\"diagnostics\":")
    _json_array(io, entries) do e
        return _json_object(
            io,
            "severity" => _jsonstr(string(e.severity)),
            "item" => _jsonstr(e.item),
            "message" => _jsonstr(e.message),
        )
    end
    print(io, "}")
    return String(take!(io))
end

# ---------- token-lean Markdown companion (the "paste to an LLM" view) ----------

# Compact one-line param view for agent.md: "system.N=16, system.g=0.5" (structured) or a repr.
function _params_inline(params)
    desc = _params_describe(params)
    desc === nothing && return string(params)
    return join(("$k=$v" for (k, v) in desc), ", ")
end

# A figure in agent.md, inside its block: what it claims, where and how it was made, and pointers to
# what is behind it — the data file described exactly (columns, points per series), and its image.
function _agent_md_fig(io, fig, ctx)
    imgs, csv = get(ctx.files, fig.id, (String[], nothing))
    println(io, "- [fig: ", fig.id, "] ", fig.caption)
    isempty(fig.defined_at) || println(io, "  - defined at: ", fig.defined_at)
    isempty(fig.code) || println(io, "  - code: `", fig.code, "`")
    fig.params === nothing || println(io, "  - params: ", _params_inline(fig.params))
    d = csv === nothing ? nothing : _data_descriptor(csv)
    if d === nothing
        println(io, "  - data: none — this figure can be read only through its image")
    else
        series = join(("$(l) ($(n) points)" for (l, n) in d.series), ", ")
        println(
            io,
            "  - data: ",
            _agent_rel(csv, ctx),
            " — columns: ",
            join(d.columns, ", "),
            "; ",
            series,
        )
    end
    println(io, "  - image: ", isempty(imgs) ? "none" : _agent_rel(imgs[1], ctx))
    _agent_md_notes(io, fig.anchor, ctx; indent="  ")   # inside the figure's block
    return nothing
end

# A @table as a markdown table (the LLM read view).
function _agent_md_table(io, tbl)
    println(io)
    isempty(tbl.caption) || println(io, "_", tbl.caption, "_  [table: ", tbl.id, "]")
    if !isempty(tbl.header)
        println(io, "| ", join(tbl.header, " | "), " |")
        println(io, "|", repeat(" --- |", length(tbl.header)))
    end
    for row in tbl.rows
        println(io, "| ", join((_cellstr(c) for c in row), " | "), " |")
    end
    return nothing
end

# A single check as a markdown list line (the LLM read view): a PASS/FAIL/ERROR badge + the numbers,
# or none for an indicator, which has none.
function _agent_md_check(io, chk)
    badge = uppercase(string(chk.outcome))
    println(
        io,
        "- [",
        badge,
        "] ",
        chk.id,
        " — ",
        chk.label,
        _agent_md_numbers(chk),
        isempty(chk.source) ? "" : string(" — defined at ", chk.source),
    )
    return nothing
end
# A check's numbers in agent.md, or a note that an indicator has none.
function _agent_md_numbers(chk)
    chk.kind === :indicator && return " (pass/fail only)"
    return string(
        ": got ",
        chk.got,
        ", want ",
        chk.want,
        " (Δ ",
        chk.delta,
        " vs tol ",
        chk.tol,
        " ",
        chk.kind,
        ")",
    )
end

# A @code block in agent.md: a line naming it (id, caption, where it was written), the fenced source,
# then its captured output. A check's own block comes right before the check.
function _agent_md_code(io, blk)
    println(
        io,
        "[code: ",
        blk.id,
        "]",
        isempty(blk.caption) ? "" : string(" ", blk.caption),
        isempty(blk.defined_at) ? "" : string(" — defined at ", blk.defined_at),
    )
    println(io, "```", blk.lang)
    println(io, blk.source)
    println(io, "```")
    isempty(blk.output) || println(io, "`=> ", blk.output, "`")
    return nothing
end

# A container's content in agent.md, in declaration order: one method per node type, so a type
# agent.md has no form for is an error naming it.
_agent_md_node(io, node, ctx) = _unhandled_node("agent.md", node)
_agent_md_node(io, p::Prose, ctx) = println(io, p.source)
_agent_md_node(io, f::Figure, ctx) = _agent_md_fig(io, f, ctx)
function _agent_md_node(io, t::Table, ctx)
    _agent_md_table(io, t)
    return _agent_md_notes(io, t.anchor, ctx)
end
_agent_md_node(io, chk::Check, ctx) = _agent_md_check(io, chk)   # where it was written
_agent_md_node(io, b::CodeBlock, ctx) = _agent_md_code(io, b)
_agent_md_node(io, s::Section, ctx) = _agent_md_container(io, s, s.depth, "", ctx)   # nested, in order
_agent_md_node(io, r::RawBlock, ctx) = println(io, "```html\n", r.html, "\n```")   # @raw, as written

# The one place agent.md turns depth into a heading, for parts (0, `##`), pages (1, `###`) and
# sections (2, `####` …). Past `######` the level is kept as a bold line (Markdown has no deeper
# heading), and a diagnostic says so.
function _agent_md_heading(depth::Int, title, anchor, rdiag)
    n = depth + 2
    n <= 6 && return string("#"^n, " ", title)
    push!(
        rdiag,
        DiagEntry(
            WARNING,
            string(anchor),
            "section at depth $(depth) is deeper than ######; rendered as a bold line in agent.md",
        ),
    )
    return string("**", title, "**")
end

# A container's verdict band in agent.md: the count over its subtree and which checks fail. The checks
# themselves are blocks in the content, each where it was written, after its code.
function _agent_md_verdict(io, c)
    v = verdict(c)
    v === nothing && return nothing
    failing = [chk.id for chk in _subtree_checks(c) if !passed(chk)]
    println(
        io,
        "**",
        c.title,
        "   ",
        v.passed,
        "/",
        v.total,
        " ",
        v.verdict,
        "**",
        isempty(failing) ? "" : string(" — failing: ", join(failing, ", ")),
    )
    return nothing
end

# A node's comment thread, after it (where the gallery and LaTeX put it); a figure's is indented
# into its block.
function _agent_md_notes(io, anchor, ctx; indent="")
    for c in get(ctx.comments, Symbol(anchor), Comment[])
        println(io, indent, "- note (", c.author, "): ", c.text)
    end
    return nothing
end

# A page or section in agent.md: its heading (with its id, and `badge` after it), its verdict band and
# summary, its content in declaration order (nested sections included), then its comments.
function _agent_md_container(io, c, depth, badge, ctx)
    heading = _agent_md_heading(depth, c.title, c.anchor, ctx.rdiag)
    println(io, "\n", heading, "  [id: ", c.id, "]", badge)
    _agent_md_verdict(io, c)
    c.summary === nothing || println(io, "_", c.summary, "_")
    foreach(((_, node),) -> _agent_md_node(io, node, ctx), _content_items(c))
    _agent_md_notes(io, c.anchor, ctx)
    return nothing
end

# agent.md's body: the title, then each page under the heading of the part it opens.
function _agent_markdown(doc::Document, ctx)
    io = IOBuffer()
    isempty(doc.meta.title) || println(io, "# ", doc.meta.title)
    curpart = :__start__
    for pg in doc.pages
        pg.part === curpart || _agent_md_part(io, doc, pg.part, ctx)
        curpart = pg.part
        badge = pg.status === :final ? "" : "  [status: $(pg.status)]"
        _agent_md_container(io, pg, 1, badge, ctx)
    end
    return String(take!(io))
end

# A part's heading and description in agent.md, where its first page begins (nothing for the pages
# outside any part).
function _agent_md_part(io, doc, pid, ctx)
    pid === nothing && return nothing
    println(io, "\n", _agent_md_heading(0, _part_title(doc, pid), _anchor(pid), ctx.rdiag))
    d = get(doc.part_descs, pid, nothing)
    d === nothing || println(io, d.source)
    return nothing
end

# The diagnostics as a closing agent.md section ("" when there are none).
function _agent_md_diagnostics(entries)
    isempty(entries) && return ""
    lines = ("- [$(e.severity)] $(e.item): $(e.message)" for e in entries)
    return string("\n## Diagnostics\n", join(lines, "\n"), "\n")
end

# ---------- emit ----------

function emit_document(
    theme::AgentBase,
    doc::Document,
    outdir::AbstractString,
    cache::RenderCache;
    comments_file::AbstractString=joinpath(outdir, "comments.toml"),
)
    rdiag = DiagEntry[]
    comments, _bm = _read_comments(doc, comments_file, rdiag)
    mkpath(outdir)
    ctx = AgentCtx(IOBuffer(), String(outdir), comments, cache, rdiag)
    # agent.json's body first: it materializes the figures agent.md then reads. Both files end with
    # the same diagnostics, agent.md's own (a fallback heading) included.
    body = _agent_json(theme, doc, ctx)
    md = _agent_markdown(doc, ctx)
    entries = vcat(doc.diag.entries, rdiag)
    write(joinpath(outdir, "agent.json"), string(body, _agent_json_diagnostics(entries)))
    write(joinpath(outdir, "agent.md"), string(md, _agent_md_diagnostics(entries)))
    return joinpath(outdir, "agent.json")
end

register_theme!(:agent, AgentTheme())
