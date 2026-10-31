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

# A figure's `params` binding as JSON: null, a structured {axis: value} object when the params object
# is introspectable (a NamedTuple/Dict, or a ParamIO.DataKey via the extension's `_params_describe`),
# else a string fallback (an opaque params value is still recorded for provenance).
function _agent_params_json(io, params)
    params === nothing && return print(io, "null")
    desc = _params_describe(params)
    desc === nothing && return print(io, _jsonstr(string(params)))
    print(io, "{")
    for (i, (k, v)) in enumerate(desc)
        i == 1 || print(io, ",")
        print(io, _jsonstr(k), ":", _agent_jsonval(v))
    end
    return print(io, "}")
end

# One figure → its JSON object: what it claims (caption), where and how it was made (`defined_at`,
# code, params) and pointers to what is behind it — its images and its data file, described exactly
# (columns, points per series) and never inlined (Conventions › The agent face).
function emit_figure(theme::AgentBase, fig, ctx)
    io = ctx.io
    imgs, csv = get(ctx.files, fig.id, (String[], nothing))
    print(
        io,
        "{\"id\":",
        _jsonstr(string(fig.id)),
        ",\"caption\":",
        _jsonstr(fig.caption),
        ",\"defined_at\":",
        _jsonstr(fig.defined_at),
        ",\"code\":",
        _jsonstr(fig.code),
        ",\"params\":",
    )
    _agent_params_json(io, fig.params)
    print(io, ",\"assets\":[")
    for (i, a) in enumerate(imgs)
        i == 1 || print(io, ",")
        print(io, _jsonstr(_agent_rel(a, ctx)))
    end
    print(io, "],\"data\":")
    _agent_data_json(io, csv, ctx)
    print(io, ",\"comments\":")
    _agent_comments!(fig.anchor, ctx)
    print(io, "}")
    return nothing
end

# The id-keyed comment thread of any node (a figure, a page, a section) as `[{author, text}]`.
# A path in this face's directory, as `agent.json` / `agent.md` name it.
_agent_rel(path, ctx) = replace(relpath(path, ctx.outdir), '\\' => '/')

# A figure's data file as a pointer and an exact description of what it holds — its columns (named by
# the axis labels) and each series with its point count — or `null` when the figure has none.
function _agent_data_json(io, csv, ctx)
    d = csv === nothing ? nothing : _data_descriptor(csv)
    d === nothing && return print(io, "null")
    print(io, "{\"path\":", _jsonstr(_agent_rel(csv, ctx)), ",\"columns\":[")
    join(io, (_jsonstr(c) for c in d.columns), ",")
    print(io, "],\"series\":[")
    for (i, (label, n)) in enumerate(d.series)
        i == 1 || print(io, ",")
        print(io, "{\"label\":", _jsonstr(label), ",\"points\":", n, "}")
    end
    return print(io, "]}")
end

function _agent_comments!(anchor, ctx)
    print(ctx.io, "[")
    for (i, c) in enumerate(get(ctx.comments, Symbol(anchor), Comment[]))
        i == 1 || print(ctx.io, ",")
        print(
            ctx.io, "{\"author\":", _jsonstr(c.author), ",\"text\":", _jsonstr(c.text), "}"
        )
    end
    return print(ctx.io, "]")
end

# One @table -> a JSON object (header + native-typed rows, then its comments). A table is already the
# LLM-native form.
function emit_table(::AgentBase, tbl, ctx)
    io = ctx.io
    print(
        io,
        "{\"id\":",
        _jsonstr(string(tbl.id)),
        ",\"caption\":",
        _jsonstr(tbl.caption),
        ",\"defined_at\":",
        _jsonstr(tbl.defined_at),
        ",\"code\":",
        _jsonstr(tbl.code),
        ",\"header\":[",
    )
    for (i, h) in enumerate(tbl.header)
        i == 1 || print(io, ",")
        print(io, _jsonstr(h))
    end
    print(io, "],\"rows\":[")
    for (i, row) in enumerate(tbl.rows)
        i == 1 || print(io, ",")
        print(io, "[")
        for (j, cell) in enumerate(row)
            j == 1 || print(io, ",")
            print(io, _agent_jsonval(cell))
        end
        print(io, "]")
    end
    print(io, "],\"comments\":")
    _agent_comments!(tbl.anchor, ctx)
    print(io, "}")
    return nothing
end

function _agent_tables!(theme::AgentBase, tables, ctx)
    io = ctx.io
    print(io, "[")
    for (i, tbl) in enumerate(tables)
        i == 1 || print(io, ",")
        emit_table(theme, tbl, ctx)
    end
    print(io, "]")
    return nothing
end

# One @code block → a JSON object: the source and its captured output (a tool reads the computation).
function emit_code(::AgentBase, blk, ctx)
    io = ctx.io
    print(
        io,
        "{\"id\":",
        _jsonstr(string(blk.id)),
        ",\"caption\":",
        _jsonstr(blk.caption),
        ",\"defined_at\":",
        _jsonstr(blk.defined_at),
        ",\"lang\":",
        _jsonstr(blk.lang),
        ",\"source\":",
        _jsonstr(blk.source),
        ",\"output\":",
        _jsonstr(blk.output),
        "}",
    )
    return nothing
end

function _agent_codes!(theme::AgentBase, codes, ctx)
    io = ctx.io
    print(io, "[")
    for (i, blk) in enumerate(codes)
        i == 1 || print(io, ",")
        emit_code(theme, blk, ctx)
    end
    print(io, "]")
    return nothing
end

# A container's @raw blocks: each one's HTML, as written (an agent reads what the gallery shows).
function _agent_raws!(raws, ctx)
    io = ctx.io
    print(io, "[")
    for (i, r) in enumerate(raws)
        i == 1 || print(io, ",")
        print(
            io,
            "{\"id\":",
            _jsonstr(string(r.id)),
            ",\"html\":",
            _jsonstr(r.html),
            ",\"defined_at\":",
            _jsonstr(r.defined_at),
            "}",
        )
    end
    print(io, "]")
    return nothing
end

# One check -> a JSON object with native-typed numerics (a tool reads 4.6e-5, not "4.6e-5").
function emit_check(::AgentBase, chk, ctx)
    io = ctx.io
    print(
        io,
        "{\"id\":",
        _jsonstr(string(chk.id)),
        ",\"label\":",
        _jsonstr(chk.label),
        ",\"got\":",
        _agent_jsonval(chk.got),
        ",\"want\":",
        _agent_jsonval(chk.want),
        ",\"delta\":",
        _agent_jsonval(chk.delta),
        ",\"tol\":",
        _agent_jsonval(chk.tol),
        ",\"kind\":",
        _jsonstr(string(chk.kind)),
        ",\"pass\":",
        _agent_jsonval(chk.pass),
        ",\"defined_at\":",   # where the @test was written, `path:line`, as for every node
        _jsonstr(chk.source),
        # the code is ONE object in `codes` (kind "code"); a check REFERENCES it by id, or null
        ",\"code_id\":",
        isempty(chk.code_anchor) ? "null" : _jsonstr(chk.code_anchor),
        "}",
    )
    return nothing
end

# A container's own checks as a JSON array (each through the `emit_check` dispatch point), so the
# `{kind:"check", id}` entries in its `content` resolve within the same object (#173).
function _agent_checks!(theme::AgentBase, checks, ctx)
    io = ctx.io
    print(io, "[")
    for (i, c) in enumerate(checks)
        i == 1 || print(io, ",")
        emit_check(theme, c, ctx)
    end
    print(io, "]")
    return nothing
end

# A page/section's content in declaration order as {kind,id} — lets a consumer reconstruct the
# interleave of figures and tables (the typed `figures`/`tables` arrays preserve within-type order).
function _agent_content!(c, ctx)
    io = ctx.io
    print(io, "[")
    for (i, (kind, item)) in enumerate(_content_items(c))
        item isa Union{Prose,Figure,Table,Check,CodeBlock,RawBlock,Section} ||
            _unhandled_node("agent.json", item)
        i == 1 || print(io, ",")
        print(
            io,
            "{\"kind\":",
            _jsonstr(string(kind)),
            ",\"id\":",
            _jsonstr(string(item.id)),
            "}",
        )
    end
    print(io, "]")
    return nothing
end

# Materialize each figure (the asset is the verifiable artifact), then emit them as a JSON array.
# Inlined rather than a shared helper so formats come straight from `figure_formats(theme)` — keeps
# the materialize-all-then-emit-all two-phase shape and mirrors `_latex_emit_figs!`.
function _agent_figs!(theme::AgentBase, figs, assetdir, ctx)
    fmts = figure_formats(theme)
    for fig in figs
        base = joinpath(assetdir, fig.anchor)
        if fig.data !== nothing
            # Eager `data=`: the data file is written from it and `gen()` — the plotting backend — is
            # never touched, so agent.json stays producible Plots/Makie-free. No image in this face.
            csv = _write_csv(_table_of_data(fig.data), base)
            ctx.cache.new[_manifest_key(base, ctx.cache.outdir)] = Dict{String,Any}(
                "key" => "data", "assets" => [relpath(csv, ctx.cache.outdir)]
            )
            ctx.files[fig.id] = (String[], csv)
            continue
        end
        try
            materialize!(fig, base, fmts, ctx.cache)   # into this face's directory
        catch e
            e isa InterruptException && rethrow()
            push!(ctx.rdiag, DiagEntry(ERROR, fig.anchor, "materialize failed: $(e)"))
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
    io = ctx.io
    print(io, "[")
    for (i, fig) in enumerate(figs)
        i == 1 || print(io, ",")
        emit_figure(theme, fig, ctx)
    end
    print(io, "]")
    return nothing
end

# A derived verdict as JSON (`null` when the subtree holds no checks — never a vacuous PASS).
function _agent_verdict_json(v)
    v === nothing && return "null"
    return string(
        "{\"verdict\":",
        _jsonstr(v.verdict),
        ",\"passed\":",
        v.passed,
        ",\"total\":",
        v.total,
        ",\"failed\":[",
        join((_jsonstr(f) for f in v.failed), ","),
        "]}",
    )
end

# A container's prose blocks: `[{id, text}]`, in the order written (their place among the other
# nodes is in `content`).
function _agent_texts!(texts, ctx)
    print(ctx.io, "[")
    for (i, t) in enumerate(texts)
        i == 1 || print(ctx.io, ",")
        print(
            ctx.io,
            "{\"id\":",
            _jsonstr(string(t.id)),
            ",\"text\":",
            _jsonstr(t.source),
            ",\"defined_at\":",
            _jsonstr(t.defined_at),
            "}",
        )
    end
    return print(ctx.io, "]")
end

# Pages and sections are one kind of container, so they share one body and one set of keys: a page
# adds only `part` and `status` (Conventions › Faces). Text the author did not write is "".
function _agent_container!(theme::AgentBase, c, pg, assetdir, ctx)
    io = ctx.io
    print(
        io,
        ",\"summary\":",
        _jsonstr(something(c.summary, "")),
        ",\"verdict\":",
        _agent_verdict_json(verdict(c)),
        ",\"checks\":",
    )
    _agent_checks!(theme, c.checks, ctx)
    print(io, ",\"texts\":")
    _agent_texts!(c.texts, ctx)
    print(io, ",\"figures\":")
    _agent_figs!(theme, c.figures, assetdir, ctx)
    print(io, ",\"tables\":")
    _agent_tables!(theme, c.tables, ctx)
    print(io, ",\"codes\":")
    _agent_codes!(theme, c.codes, ctx)
    print(io, ",\"raws\":")
    _agent_raws!(c.raws, ctx)
    print(io, ",\"content\":")
    _agent_content!(c, ctx)
    print(io, ",\"comments\":")   # a page or section carries its own thread, as a figure does
    _agent_comments!(c.anchor, ctx)
    # the section tree: children nest inside their parent's object, in declaration order
    print(io, ",\"sections\":[")
    for (j, child) in enumerate(c.sections)
        j == 1 || print(io, ",")
        emit_section(theme, child, pg, ctx)
    end
    print(io, "]}")
    return nothing
end

function emit_section(theme::AgentBase, sec, pg, ctx)
    print(
        ctx.io,
        "{\"id\":",
        _jsonstr(string(sec.id)),
        ",\"title\":",
        _jsonstr(sec.title),
        ",\"depth\":",
        sec.depth,
    )
    assetdir = joinpath(ctx.outdir, "assets", "figures", pg.anchor, sec.anchor)
    return _agent_container!(theme, sec, pg, assetdir, ctx)
end

function emit_page(theme::AgentBase, pg, ctx)
    print(
        ctx.io,
        "{\"id\":",
        _jsonstr(string(pg.id)),
        ",\"title\":",
        _jsonstr(pg.title),
        ",\"depth\":1,\"part\":",
        pg.part === nothing ? "null" : _jsonstr(string(pg.part)),
        ",\"status\":",
        _jsonstr(string(pg.status)),
    )
    assetdir = joinpath(ctx.outdir, "assets", "figures", pg.anchor)
    return _agent_container!(theme, pg, pg, assetdir, ctx)
end

# Build the whole agent.json (title + parts + pages, the latter via the per-node contract).
function _agent_json(theme::AgentBase, doc::Document, ctx)
    io = ctx.io
    print(io, "{\"title\":", _jsonstr(doc.meta.title), ",\"parts\":[")
    for (i, (pid, ptitle)) in enumerate(doc.parts)
        i == 1 || print(io, ",")
        d = get(doc.part_descs, pid, nothing)
        print(
            io,
            "{\"id\":",
            _jsonstr(string(pid)),
            ",\"title\":",
            _jsonstr(ptitle),
            ",\"desc\":",
            _jsonstr(d === nothing ? "" : d.source),
            ",\"status\":",
            haskey(doc.part_status, pid) ? _jsonstr(string(doc.part_status[pid])) : "null",
            "}",
        )
    end
    print(io, "],\"pages\":[")
    for (i, pg) in enumerate(doc.pages)
        i == 1 || print(io, ",")
        emit_page(theme, pg, ctx)
    end
    # what the build and this render recorded — a left-out node, a failed figure — as data, so an
    # agent sees the gaps instead of inferring them (Conventions › Faces)
    print(io, "],\"diagnostics\":[")
    for (i, e) in enumerate(vcat(doc.diag.entries, ctx.rdiag))
        i == 1 || print(io, ",")
        print(
            io,
            "{\"severity\":",
            _jsonstr(string(e.severity)),
            ",\"item\":",
            _jsonstr(e.item),
            ",\"message\":",
            _jsonstr(e.message),
            "}",
        )
    end
    print(io, "]}")
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
function _agent_md_fig(io, fig, outdir, comments, files)
    imgs, csv = get(files, fig.id, (String[], nothing))
    rel(p) = replace(relpath(p, outdir), '\\' => '/')
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
            io, "  - data: ", rel(csv), " — columns: ", join(d.columns, ", "), "; ", series
        )
    end
    println(io, "  - image: ", isempty(imgs) ? "none" : rel(imgs[1]))
    for c in get(comments, Symbol(fig.anchor), Comment[])
        println(io, "  - note (", c.author, "): ", c.text)
    end
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

# A single check as a markdown list line (the LLM read view): a ✓/✗ badge + the numbers.
function _agent_md_check(io, chk)
    badge = chk.pass ? "PASS" : "FAIL"
    println(
        io,
        "- [",
        badge,
        "] ",
        chk.id,
        " — ",
        chk.label,
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
        isempty(chk.source) ? "" : string(" — defined at ", chk.source),
    )
    return nothing
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
# agent.md has no form for is an error naming it. `env` is (outdir, comments, files, rdiag).
function _agent_md_content(io, c, outdir, comments, files, rdiag)
    env = (; outdir, comments, files, rdiag)
    foreach(((_, node),) -> _agent_md_node(io, node, env), _content_items(c))
    return nothing
end
_agent_md_node(io, node, env) = _unhandled_node("agent.md", node)
_agent_md_node(io, p::Prose, env) = println(io, p.source)
function _agent_md_node(io, f::Figure, env)
    return _agent_md_fig(io, f, env.outdir, env.comments, env.files)
end
function _agent_md_node(io, t::Table, env)
    _agent_md_table(io, t)
    return _agent_md_notes(io, t.anchor, env.comments)
end
_agent_md_node(io, chk::Check, env) = _agent_md_check(io, chk)   # where it was written
_agent_md_node(io, b::CodeBlock, env) = _agent_md_code(io, b)
function _agent_md_node(io, s::Section, env)   # a nested section, in declaration order
    return _agent_md_section(io, s, env.outdir, env.comments, env.files, env.rdiag)
end
_agent_md_node(io, r::RawBlock, env) = println(io, "```html\n", r.html, "\n```")   # @raw, as written

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

# A container's verdict over its subtree as one bold line ("" when it holds no checks).
# A container's verdict band over its subtree, then its own checks — the same place every face puts
# them, ahead of the content (Conventions › Faces).
# A container's verdict band in agent.md: the count over its subtree and which checks fail. The checks
# themselves are blocks in the content, each where it was written, after its code.
function _agent_md_verdict(io, c)
    v = verdict(c)
    v === nothing && return nothing
    failing = [chk.id for chk in _subtree_checks(c) if !chk.pass]
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

# A node's comment thread, after it (where the gallery and LaTeX put it).
function _agent_md_notes(io, anchor, comments)
    for c in get(comments, Symbol(anchor), Comment[])
        println(io, "- note (", c.author, "): ", c.text)
    end
    return nothing
end

function _agent_md_section(io, sec, outdir, comments, files, rdiag)
    println(
        io,
        "\n",
        _agent_md_heading(sec.depth, sec.title, sec.anchor, rdiag),
        "  [id: ",
        sec.id,
        "]",
    )
    _agent_md_verdict(io, sec)
    sec.summary === nothing || println(io, "_", sec.summary, "_")
    _agent_md_content(io, sec, outdir, comments, files, rdiag)
    _agent_md_notes(io, sec.anchor, comments)
    return nothing
end

function _agent_markdown(doc::Document, outdir, comments, files, rdiag)
    io = IOBuffer()
    isempty(doc.meta.title) || println(io, "# ", doc.meta.title)
    curpart = :__start__
    for pg in doc.pages
        if pg.part !== curpart
            curpart = pg.part
            if pg.part !== nothing
                k = findfirst(p -> first(p) === pg.part, doc.parts)
                ptitle = k === nothing ? string(pg.part) : last(doc.parts[k])
                println(io, "\n", _agent_md_heading(0, ptitle, _anchor(pg.part), rdiag))
                d = get(doc.part_descs, pg.part, nothing)
                d === nothing || println(io, d.source)
            end
        end
        badge = pg.status === :final ? "" : "  [status: $(pg.status)]"
        println(
            io,
            "\n",
            _agent_md_heading(1, pg.title, pg.anchor, rdiag),
            "  [id: ",
            pg.id,
            "]",
            badge,
        )
        _agent_md_verdict(io, pg)
        pg.summary === nothing || println(io, "_", pg.summary, "_")
        _agent_md_content(io, pg, outdir, comments, files, rdiag)   # sections included, in order
        _agent_md_notes(io, pg.anchor, comments)
    end
    return String(take!(io))
end

# The diagnostics as a closing agent.md section ("" when there are none).
function _agent_md_diagnostics(doc, rdiag)
    entries = vcat(doc.diag.entries, rdiag)
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
    # agent.json first: it materializes the figures agent.md then reads. agent.md ends with every
    # diagnostic, its own (a fallback heading) included.
    write(joinpath(outdir, "agent.json"), _agent_json(theme, doc, ctx))
    md = _agent_markdown(doc, outdir, comments, ctx.files, rdiag)
    write(joinpath(outdir, "agent.md"), string(md, _agent_md_diagnostics(doc, rdiag)))
    return joinpath(outdir, "agent.json")
end

register_theme!(:agent, AgentTheme())
