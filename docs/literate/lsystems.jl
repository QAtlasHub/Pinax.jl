# # Example 2 · L-system fractals
#
# **Source:** [LSystems.jl](https://github.com/sotashimozono/LSystems.jl) —
# `DEFINED_LSYSTEMS`, `grow_string`, `LSystems.string2positions`.
#
# An [L-system](https://en.wikipedia.org/wiki/L-system) grows a string by substitution; a turtle
# then interprets it as geometry. We grow each system a few iterations and turn it into a polyline.

using Pinax, LSystems, Plots

# Grow an L-system `iter` times and draw the turtle path (NaN gaps = branch returns).
function lsys(name, iter; kw...)
    tile = DEFINED_LSYSTEMS[name]
    pos = LSystems.string2positions(tile, grow_string(tile, iter))
    xs = [p[1] for p in pos]
    ys = [p[2] for p in pos]
    plot(
        xs,
        ys;
        legend=false,
        aspect_ratio=:equal,
        axis=false,
        ticks=false,
        grid=false,
        lw=0.6,
        size=(380, 380),
        kw...,
    )
end

# Describe the manuscript with the Pinax DSL, then render the gallery.
Pinax.reset!(; title="L-system fractals")

@page :fractals "L-system fractals" begin
    @section :koch "Koch & Sierpiński" begin
        @desc md"""
        Boundary fractals from edge-replacement rules. The Koch curve has Hausdorff dimension
        $D=\log 4/\log 3\approx1.26$; the Sierpiński gasket, $D=\log 3/\log 2\approx1.58$.
        """
        @figure lsys("kochcurve", 4; title="Koch curve", lc=:steelblue)
        @caption "Koch curve (4 iterations)"
        @figure lsys("kocksnowflake", 4; title="Koch snowflake", lc=:steelblue)
        @caption "Koch snowflake (4 iterations)"
        @figure lsys("sierpinskigasket", 6; title="Sierpiński", lc=:seagreen)
        @caption "Sierpiński gasket (6 iterations)"
    end
    @section :curves "Dragons, space-filling & plants" begin
        @desc md"""
        A self-similar dragon, a space-filling curve that visits every cell of a grid, and a
        bracketed system whose $[\,\ldots\,]$ push/pop the turtle state to make a branching plant.
        """
        @figure lsys("heighwaydragon", 11; title="Heighway dragon", lc=:firebrick)
        @caption "Heighway dragon (11 iterations)"
        @figure lsys("hilbeltpath", 5; title="Hilbert curve", lc=:darkorange)
        @caption "Hilbert space-filling curve (5 iterations)"
        @figure lsys("ternarybranching", 6; title="Ternary branching", lc=:seagreen)
        @caption "Ternary branching plant (6 iterations)"
    end
end

Pinax.render(; out="galleries/lsystems")
