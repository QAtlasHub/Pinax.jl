# Example 2 · L-system fractals

[← All examples](../examples.md)

**Source:** [LSystems.jl](https://github.com/sotashimozono/LSystems.jl) — `DEFINED_LSYSTEMS`, `grow_string`, `LSystems.string2positions`.

```@raw html
<p style="margin:.2rem 0 1rem"><a href="../galleries/lsystems/"><b>▶ Open the compiled Pinax gallery</b></a></p>
```

An [L-system](https://en.wikipedia.org/wiki/L-system) grows a string by repeatedly applying
substitution rules to an axiom, then a turtle interprets the string as geometry.
[LSystems.jl](https://github.com/sotashimozono/LSystems.jl) loads each system from a JSON config;
we grow it a few iterations and turn it into a polyline with `string2positions`.

```@example lsystems
using Pinax, LSystems, Plots

# grow an L-system `iter` times and draw the turtle path (NaN gaps = branch returns)
function lsys(name, iter; kw...)
    tile = DEFINED_LSYSTEMS[name]
    pos  = LSystems.string2positions(tile, grow_string(tile, iter))
    xs = [p[1] for p in pos]
    ys = [p[2] for p in pos]
    plot(xs, ys; legend=false, aspect_ratio=:equal, axis=false, ticks=false,
         grid=false, lw=0.6, size=(380, 380), kw...)
end
nothing # hide
```

```@example lsystems
Pinax.reset!(; title = "L-system fractals (Pinax demo)")

@page :fractals "L-system fractals" begin
    @section :koch "Koch & Sierpiński" begin
        @desc md"""
        Boundary fractals from simple edge-replacement rules. The Koch curve has Hausdorff
        dimension $D=\log 4/\log 3\approx1.26$; the Sierpiński gasket, $D=\log 3/\log 2\approx1.58$.
        """
        @figure lsys("kochcurve", 4; title="Koch curve", lc=:steelblue)
        @caption "Koch curve (4 iterations)"
        @figure lsys("kocksnowflake", 4; title="Koch snowflake", lc=:steelblue)
        @caption "Koch snowflake (4 iterations)"
        @figure lsys("sierpinskigasket", 6; title="Sierpiński gasket", lc=:seagreen)
        @caption "Sierpiński gasket (6 iterations)"
    end
    @section :curves "Dragons, space-filling & plants" begin
        @desc md"""
        A self-similar dragon, a space-filling curve that visits every cell of a grid as the
        iteration count grows, and a bracketed system whose $[\,\ldots\,]$ push/pop the turtle
        state to make a branching plant.
        """
        @figure lsys("heighwaydragon", 11; title="Heighway dragon", lc=:firebrick)
        @caption "Heighway dragon (11 iterations)"
        @figure lsys("hilbeltpath", 5; title="Hilbert curve", lc=:darkorange)
        @caption "Hilbert space-filling curve (5 iterations)"
        @figure lsys("ternarybranching", 6; title="Ternary branching", lc=:seagreen)
        @caption "Ternary branching plant (6 iterations)"
    end
end

Pinax.render(; out = "galleries/lsystems")
nothing # hide
```

A preview of the Hilbert curve, shown inline by Documenter:

```@example lsystems
lsys("hilbeltpath", 5; title="Hilbert curve", lc=:darkorange)
```

```@raw html
<p style="margin:1rem 0"><a href="../galleries/lsystems/"><b>▶ Open the rendered gallery</b></a></p>
```
