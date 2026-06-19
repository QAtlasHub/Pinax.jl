# Pinax.jl

> *A board of figures that is also a catalogue.*

Pinax turns the figures your analysis scripts produce into a structured, self-contained HTML
gallery — sections wrapped as cards, a multi-column figure grid, markdown + math descriptions,
cross-references, citations, and an interactive comment layer — and can export the same manuscript
to PDF via a LaTeX theme.

See the [API Reference](api.md) for the full list of macros and functions.

## Example: a gallery of chaotic attractors

The gallery linked below is built **live on this page** as a Documenter `@example`: it integrates
the Lorenz and Rössler systems from
[DynamicalModels.jl](https://github.com/sotashimozono/DynamicalModels.jl), draws each as a **3-D
attractor plus 2-D projections**, and renders a Pinax gallery — the same flow you would use in an
analysis script.

```@example lorenz
using Pinax, DynamicalModels, Plots

# integrate two chaotic attractors (DynamicalModels.jl: model(t, x) -> dx/dt, RK4 solver)
t = collect(0.0:0.02:80.0)
lorenz  = ode_solver(RK4, Lorenz(),  t, [1.0, 1.0, 1.0])
rossler = ode_solver(RK4, Rossler(), t, [1.0, 1.0, 1.0])

# plot helpers: a 3-D trajectory and a 2-D coordinate projection
orbit3d(tr; kw...) = plot(tr[:, 1], tr[:, 2], tr[:, 3]; legend=false, lw=0.4, size=(420, 360), kw...)
proj(tr, i, j; kw...) = plot(tr[:, i], tr[:, j]; legend=false, lw=0.4, size=(420, 360), kw...)
nothing # hide
```

Each `@figure` expression is **deferred** and materialized at render time; three figures per section
lay out as a 3-column grid inside the section card. Descriptions are markdown + `$…$` math
(rendered by KaTeX in the gallery):

```@example lorenz
Pinax.reset!(; title = "DynamicalModels.jl — chaotic attractors (Pinax demo)")

@page :attractors "Chaotic attractors" begin
    @section :lorenz "Lorenz" begin
        @desc md"""
        The **Lorenz** system $\dot x=\sigma(y-x),\ \dot y=x(\rho-z)-y,\ \dot z=xy-\beta z$
        with $\sigma=10,\ \rho=28,\ \beta=8/3$ — the classic butterfly attractor.
        """
        @figure orbit3d(lorenz; xlabel="x", ylabel="y", zlabel="z", title="Lorenz 3-D")
        @caption md"3-D attractor"
        @figure proj(lorenz, 1, 3; xlabel="x", ylabel="z", title="x–z")
        @caption md"$x$–$z$ projection"
        @figure proj(lorenz, 1, 2; xlabel="x", ylabel="y", title="x–y")
        @caption md"$x$–$y$ projection"
    end
    @section :rossler "Rössler" begin
        @desc md"""
        The **Rössler** system $\dot x=-y-z,\ \dot y=x+ay,\ \dot z=b+z(x-c)$
        with $a=b=0.2,\ c=5.7$.
        """
        @figure orbit3d(rossler; xlabel="x", ylabel="y", zlabel="z", title="Rössler 3-D")
        @caption md"3-D attractor"
        @figure proj(rossler, 1, 2; xlabel="x", ylabel="y", title="x–y")
        @caption md"$x$–$y$ projection"
        @figure proj(rossler, 2, 3; xlabel="y", ylabel="z", title="y–z")
        @caption md"$y$–$z$ projection"
    end
end

Pinax.render(; out = "gallery")   # writes build/gallery/index.html — deployed with these docs
nothing # hide
```

A preview of the Lorenz attractor, shown inline by Documenter:

```@example lorenz
orbit3d(lorenz; xlabel="x", ylabel="y", zlabel="z", title="Lorenz attractor")
```

```@raw html
<p style="margin:1rem 0"><a href="gallery/index.html"><b>▶ Open the interactive Pinax gallery</b></a>
— section cards, a 3-column figure grid, KaTeX math, and the comment layer.</p>
```
