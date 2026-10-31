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

# Extract per-series x/y + axis labels for the agent backend's text/CSV data view. Best-effort and
# defensive (Plots' series/axis accessors vary by version): any series that won't read is skipped,
# and missing axis guides degrade to "". Returns `nothing` if no series carry data, or one is a grid.
function Pinax._figure_table(p::Plots.Plot)
    series = NamedTuple[]
    for s in p.series_list
        try
            x = s[:x]
            y = s[:y]
            (x === nothing || y === nothing) && continue
            label = try
                string(s[:label])
            catch
                ""
            end
            # a grid (a heatmap, a surface: z holds the values) is not a list of points; a file of
            # points cannot hold it, so the figure has no data form rather than a cut one
            length(x) == length(y) || return nothing
            push!(series, (; label=label, x=collect(x), y=collect(y)))
        catch
            continue
        end
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
