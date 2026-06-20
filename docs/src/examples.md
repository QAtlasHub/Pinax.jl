# Examples

A small catalogue of galleries built with Pinax. Every example is a short, self-contained Pinax
script — compute something, describe a manuscript, then `render` it into a gallery. Each example
page below shows that script's **source verbatim**; open the compiled gallery beside it.

A Pinax script reads like this:

```julia
using Pinax

@page :results "Results" begin
    @section :energy "Energy" begin
        @desc md"Energy density $E/N$ versus inverse temperature."
        @figure plot_energy()
        @caption "χ-convergence"
    end
end

render(out = "gallery")
```

## The examples

### 1 · Chaotic attractors

Lorenz & Rössler as 3-D attractors plus 2-D projections, from
[DynamicalModels.jl](https://github.com/sotashimozono/DynamicalModels.jl).
[Source](examples/attractors.md).

```@raw html
<p style="margin:.2rem 0 1.2rem"><a href="../galleries/attractors/"><b>▶ Open the compiled gallery</b></a></p>
```

### 2 · L-system fractals

Koch, Sierpiński, the Heighway dragon, a Hilbert curve and a branching plant, from
[LSystems.jl](https://github.com/sotashimozono/LSystems.jl). [Source](examples/lsystems.md).

```@raw html
<p style="margin:.2rem 0 1.2rem"><a href="../galleries/lsystems/"><b>▶ Open the compiled gallery</b></a></p>
```

### 3 · Ising model (Monte Carlo)

A self-contained 2-D Metropolis simulation: spin snapshots across the transition plus the
magnetization curve. [Source](examples/ising.md).

```@raw html
<p style="margin:.2rem 0 1.2rem"><a href="../galleries/ising/"><b>▶ Open the compiled gallery</b></a></p>
```
