# Examples

This section is a small catalogue of galleries built with Pinax. It governs the example pages that
follow: each one runs a real computation and then follows the **same Pinax workflow** —

1. compute something (integrate an ODE, grow an L-system, run a Monte Carlo sweep),
2. describe a manuscript with `@page` / `@section` / `@figure` / `@desc`,
3. `render` it into a **self-contained gallery** you can open and share.

So the example pages double as copy-paste templates: read one for the source and the walkthrough,
then open its compiled gallery to see what Pinax produces.

## The galleries

### 1 · Chaotic attractors

Lorenz & Rössler as 3-D attractors plus 2-D projections — a multi-section gallery with KaTeX math.
[Source & walkthrough](examples/attractors.md).

```@raw html
<p style="margin:.2rem 0 1.4rem"><a href="galleries/attractors/"><b>▶ Open the compiled gallery</b></a></p>
```

### 2 · L-system fractals

Koch, Sierpiński, the Heighway dragon, a Hilbert space-filling curve and a branching plant, grown
by substitution and drawn by turtle geometry.
[Source & walkthrough](examples/lsystems.md).

```@raw html
<p style="margin:.2rem 0 1.4rem"><a href="galleries/lsystems/"><b>▶ Open the compiled gallery</b></a></p>
```

### 3 · Ising model (Monte Carlo)

A 2-D Metropolis simulation: spin snapshots across the transition plus the magnetization curve.
[Source & walkthrough](examples/ising.md).

```@raw html
<p style="margin:.2rem 0 1.4rem"><a href="galleries/ising/"><b>▶ Open the compiled gallery</b></a></p>
```
