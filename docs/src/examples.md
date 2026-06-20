# Examples

Each example below is built **live** on its own page as a Documenter `@example`: it runs a real
computation, plots it, assembles a Pinax manuscript with `@page` / `@section` / `@figure`, and
`render`s a self-contained gallery you can open. They double as copy-paste templates for your own
analysis scripts.

| # | Example | What it shows | Source |
| :-: | :-- | :-- | :-- |
| 1 | **[Chaotic attractors](examples/attractors.md)** | Lorenz & Rössler as 3-D attractors plus 2-D projections — a multi-section gallery with KaTeX math. | [DynamicalModels.jl](https://github.com/sotashimozono/DynamicalModels.jl) |
| 2 | **[L-system fractals](examples/lsystems.md)** | Koch, Sierpiński, Heighway dragon, Hilbert, Peano and a branching plant, grown by substitution and drawn by turtle geometry. | [LSystems.jl](https://github.com/sotashimozono/LSystems.jl) |
| 3 | **[Ising model (Monte Carlo)](examples/ising.md)** | A 2-D Metropolis simulation: spin snapshots across the transition plus the magnetization curve $\langle\lvert m\rvert\rangle(T)$. | self-contained |

Every example renders into its own gallery under `galleries/`, deployed alongside these docs.
