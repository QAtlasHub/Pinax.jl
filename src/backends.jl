# backends.jl — figure backend abstraction (notes 04). The core is plotting-agnostic.
#
# The contract is just two verbs:
#   is_figure(x)            … is x a backend figure object? (Plots/Makie ext sets this true)
#   pinax_save(x, base, fmt) … save the figure to base.<fmt>, return the actual path (ext implements)
# Pre-made file paths are handled directly by the core (no extension needed, notes 04).

"Is `x` a backend figure object? Defaults to false (Plots/Makie ext overrides)."
is_figure(::Any) = false

"""
    pinax_save(x, base, fmt) -> path

Save the figure object `x` to `base` (an extensionless base path) in `fmt` (:svg/:pdf/…)
and return the actual path. Per-backend implementations are injected via package
extensions (weakdeps) (notes 04).
"""
function pinax_save(x, base, fmt)
    return error(
        "Pinax: no `pinax_save` method for $(typeof(x)). " *
        "Pass a file path, or load the Plots/Makie extension.",
    )
end

"""
    _figure_table(x) -> table | nothing

Extract a backend figure's plotted data for the agent backend's text/CSV view — an LLM reasons over
numbers far more cheaply and precisely than over pixels. Returns `nothing` when the data is not
introspectable (a pre-made image path, or a plot the loaded extension can't read); plotting
extensions specialize it. Return shape: `(; xlabel, ylabel, series)`, each series `(; label, x, y)`.
"""
_figure_table(::Any) = nothing

"""
    _save_with(saver, obj, base, fmt) -> path

Helper for backend extensions. Builds the destination path `base.<fmt>`, ensures its
directory exists, runs `saver(obj, dest)` — the contract is **`(obj, dest)`: figure first,
path second** — verifies a file was actually written, and returns it.
"""
function _save_with(saver, obj, base, fmt)
    dest = string(base, ".", fmt)
    dir = dirname(dest)
    isempty(dir) || mkpath(dir)
    saver(obj, dest)
    isfile(dest) || error("Pinax: backend save produced no file at $(dest)")
    return dest
end

_ext(p) = (e=splitext(p)[2]; isempty(e) ? "" : lowercase(e[2:end]))

# Pre-made file (first-class): same-format copy (v1 has no conversion, notes 04).
function _copyfile(src::AbstractString, base)
    isfile(src) || error("Pinax: @figure file not found: $(src)")
    ext = _ext(src)
    dest = isempty(ext) ? string(base) : string(base, ".", ext)
    mkpath(dirname(dest))
    cp(src, dest; force=true)
    return dest
end

# ---- a figure's data file: what an agent reads behind the plot ----
#
# The agent face points at a figure's data and never inlines a cut copy of it (Conventions › Faces):
# the file holds every plotted point, and `agent.json` / `agent.md` describe it exactly (its columns,
# and how many points each series has) so an agent knows what is behind the pointer before opening it.

function _csv_field(v)
    # flatten newlines so a value never spans CSV lines (the reader splits on raw newlines)
    s = replace(string(v), '\n' => ' ', '\r' => ' ')
    needs = occursin(',', s) || occursin('"', s)
    return needs ? string('"', replace(s, '"' => "\"\""), '"') : s
end
_csv_num(v::Real) = isfinite(v) ? string(v) : ""   # NaN/Inf -> blank cell
_csv_num(v) = _csv_field(v)                         # categorical x (strings/dates)

# The columns of a data file: the series label, then the x and y axes, named by the plot's axis labels
# when it has them (`series,beta,E/N`), else `series,x,y`.
function _data_columns(tbl)
    name(label, fallback) = isempty(strip(string(label))) ? fallback : string(label)
    return ["series", name(get(tbl, :xlabel, ""), "x"), name(get(tbl, :ylabel, ""), "y")]
end

# A data table `(; xlabel, ylabel, series)` as a long-format CSV: the column header, then every point.
function _print_csv_table(io, tbl)
    println(io, join((_csv_field(c) for c in _data_columns(tbl)), ","))
    for s in tbl.series
        for i in 1:min(length(s.x), length(s.y))
            println(io, _csv_field(s.label), ",", _csv_num(s.x[i]), ",", _csv_num(s.y[i]))
        end
    end
    return nothing
end

# Write a data table as `<base>.csv` and return its path.
function _write_csv(tbl, base)
    dest = string(base, ".csv")
    mkpath(dirname(dest))
    open(io -> _print_csv_table(io, tbl), dest, "w")
    return dest
end

# A figure object's plotted data as `<base>.csv`, or `nothing` if it exposes none.
function _write_table(x, base)
    tbl = _figure_table(x)
    return tbl === nothing ? nothing : _write_csv(tbl, base)
end

# Split one CSV line into fields, honoring "quoted" fields and "" escapes (inverse of `_csv_field`).
function _split_csv_line(line)
    fields = String[]
    buf = IOBuffer()
    inq = false
    chars = collect(line)
    i = 1
    while i <= length(chars)
        ch = chars[i]
        if inq
            if ch == '"'
                if i < length(chars) && chars[i + 1] == '"'
                    print(buf, '"')
                    i += 1
                else
                    inq = false
                end
            else
                print(buf, ch)
            end
        elseif ch == '"'
            inq = true
        elseif ch == ','
            push!(fields, String(take!(buf)))
        else
            print(buf, ch)
        end
        i += 1
    end
    push!(fields, String(take!(buf)))
    return fields
end

# What an agent is told about a data file without reading it: its columns and, per series in order,
# how many points it holds. Exact — read from the file itself.
function _data_descriptor(path)
    isfile(path) || return nothing
    lines = [l for l in eachline(path) if !isempty(l)]
    isempty(lines) && return nothing
    series = Pair{String,Int}[]
    at = Dict{String,Int}()
    for l in @view lines[2:end]
        lbl = _split_csv_line(l)[1]
        k = get!(at, lbl) do
            push!(series, lbl => 0)
            return length(series)
        end
        series[k] = lbl => last(series[k]) + 1
    end
    return (columns=_split_csv_line(lines[1]), series=series)
end

# `@figure … data=` as a data table `(; xlabel, ylabel, series)` — the shape `_figure_table` returns.
# Axis labels are optional `xlabel=` / `ylabel=` fields beside the series.
function _table_of_data(data)
    label(k) = hasproperty(data, k) ? string(getproperty(data, k)) : ""
    return (; xlabel=label(:xlabel), ylabel=label(:ylabel), series=_series_of(data))
end

# Normalize a `@figure … data=` NamedTuple into a list of `(; label, x, y)` series. Accepts
# `(; series=[(; label, x, y)], …)` or a convenience `(; x, y[, label])`.
function _series_of(data)
    if hasproperty(data, :series)
        out = NamedTuple[]
        for (i, s) in enumerate(data.series)
            lbl = hasproperty(s, :label) ? string(s.label) : "y$(i)"
            push!(out, (; label=lbl, x=s.x, y=s.y))
        end
        return out
    elseif hasproperty(data, :x) && hasproperty(data, :y)
        lbl = hasproperty(data, :label) ? string(data.label) : "y"
        return [(; label=lbl, x=data.x, y=data.y)]
    end
    return error(
        "Pinax: @figure data= needs `series=[(; label, x, y)]` or `(; x, y[, label])`."
    )
end

"""
    _materialize(fig, base, fmts) -> Vector{String}

Call the deferred `fig.gen` **exactly once** to produce the figure, write the assets,
and return their paths (notes 02 pass 3). Figure objects are saved per `fmt` via
`pinax_save`; an existing file path is copied (the file must exist when `gen()` returns).
"""
function _materialize(fig::Figure, base, fmts)
    x = fig.gen()
    if is_figure(x)
        out = String[]
        for fmt in fmts
            # `:table` is a pseudo-format: a CSV of the plotted data, not an image (skipped when the
            # figure exposes no introspectable data, e.g. a Makie scene the ext can't read).
            path = fmt === :table ? _write_table(x, base) : pinax_save(x, base, fmt)
            path === nothing || push!(out, path)
        end
        return out
    elseif x isa AbstractString
        return String[_copyfile(x, base)]
    else
        error(
            "Pinax: @figure produced $(typeof(x)); expected a file path or a known plot " *
            "(load the Plots/Makie extension).",
        )
    end
end
