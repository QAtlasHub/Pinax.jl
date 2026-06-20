# # Example 1 · Chaotic attractors
#
# **Source:** [DynamicalModels.jl](https://github.com/sotashimozono/DynamicalModels.jl) —
# `Lorenz`, `Rossler`, `ode_solver`.
#
# Integrate the Lorenz and Rössler systems and draw each as a 3-D attractor plus 2-D projections.
# Three figures per section lay out as a 3-column grid inside each section card.

using Pinax, DynamicalModels, Plots

# Integrate two chaotic attractors (`model(t, x) -> dx/dt`, RK4 solver):
t = collect(0.0:0.02:80.0)
lorenz = ode_solver(RK4, Lorenz(), t, [1.0, 1.0, 1.0])
rossler = ode_solver(RK4, Rossler(), t, [1.0, 1.0, 1.0])

# Plot helpers: a 3-D trajectory and a 2-D coordinate projection.
function orbit3d(tr; kw...)
    plot(tr[:, 1], tr[:, 2], tr[:, 3]; legend=false, lw=0.4, size=(420, 360), kw...)
end
function proj(tr, i, j; kw...)
    plot(tr[:, i], tr[:, j]; legend=false, lw=0.4, size=(420, 360), kw...)
end

# Describe the manuscript with the Pinax DSL, then render the gallery.
Pinax.reset!(; title="Chaotic attractors — Lorenz & Rössler")

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

Pinax.render(; out="galleries/attractors")
