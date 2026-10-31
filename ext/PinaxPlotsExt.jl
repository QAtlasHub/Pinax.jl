module PinaxPlotsExt

# Pinax backend extension for Plots.jl. Loaded automatically when both Pinax and Plots are imported.

using Pinax
using Plots

Pinax.is_figure(::Plots.Plot) = true

# Plots.savefig(plot, filename) infers the output format from the filename extension.
# Wrapped in a lambda matching the _save_with `(obj, dest)` contract (not relying on arg order).
function Pinax.pinax_save(p::Plots.Plot, base, fmt)
    return Pinax._save_with((obj, dest) -> Plots.savefig(obj, dest), p, base, fmt)
end

# One series as `(; label, x, y)`, `:skip` when it plots no points (x or y is `nothing`), or `nothing`
# when it is not a list of points — a grid or a 3-D plot, where z holds what is drawn — or will not
# read. Then the whole figure has no data form (which the agent face says) rather than a file that
# misses part of what the plot shows.
function _points(s)
    x, y, z = try
        s[:x], s[:y], s[:z]
    catch
        return nothing
    end
    (x === nothing || y === nothing) && return :skip
    (z === nothing && length(x) == length(y)) || return nothing
    label = try
        string(s[:label])
    catch
        ""
    end
    return (; label=label, x=collect(x), y=collect(y))
end

# Every series' points + axis labels, for the agent face's data file. Missing axis guides degrade to
# "" (Plots' accessors vary by version). `nothing` when no series has points, or one is not a list
# of points, or the plot has several subplots: a data file names one x and one y axis, and each
# subplot has its own.
function Pinax._figure_table(p::Plots.Plot)
    length(p.subplots) == 1 || return nothing
    series = NamedTuple[]
    for s in p.series_list
        pts = _points(s)
        pts === :skip && continue
        pts === nothing && return nothing
        push!(series, pts)
    end
    isempty(series) && return nothing
    guide(ax) =
        try
            string(p.subplots[1][ax][:guide])
        catch
            ""
        end
    return (; xlabel=guide(:xaxis), ylabel=guide(:yaxis), series=series)
end

end # module PinaxPlotsExt
