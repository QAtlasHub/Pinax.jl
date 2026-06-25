# Examples — Pinax as the report layer (the two faces of a result)

Pinax turns a finished computation into the **two faces** every research result needs:

- a **human gallery** (figures you scan, a colored test-report) — `:gallery` (HTML) / `:latex` (print),
- an **LLM-readable `agent.json`** (the *numbers* an LLM reasons over, never pixels),

from **one source**, chosen by who reads it — neither face is a downgrade. This is the *report* half
of the infra loop `compute → report → {human confirms / LLM steers}`. If you're learning to **use**
Pinax (not extend it), read this directory.

## The two faces — who reads what

| you write | human sees (gallery) | LLM reads (`agent.json`) |
| --- | --- | --- |
| `@figure plot(…)` | the curve | the **plotted data as a table** (`figure_as_table`) — it can't read a value off a chart |
| `@table` | an HTML table | the rows |
| `@benchmark` / `@expect` | a colored **test-report** (green/red) | a **verdict**: `{verdict, passed, total, failed, checks:[{id,got,want,delta,tol,pass}]}` |
| `@desc` · comments · `status` | rendered prose | the same text |

An LLM reasons over numbers far more precisely than over images (and image tokens are costly +
non-deterministic); a human reads a curve's shape at a glance. So the *same* doc emits both.

## LLM ↔ human collaboration — the point

This is the substrate for **trustworthy LLM-driven research**: the doer (an LLM) produces a result,
and a reviewer (you, or another LLM) checks it — but **never by reading the doer's prose**.

- **Human** opens `out/.../index.html` → browses figures, sees the benchmark's **green/red**
  test-report, annotates / **confirms** (via Archeion).
- **LLM** reads `agent.json` (directly, or `npx pinax-mcp --agent <out>`) → the numbers + the
  **verdict** → reasons → writes the next `config.toml` (the steering loop).
- The `@benchmark` **verdict is the trust contract** between them: it is *computed from the data*, not
  narrated by the doer. "the benchmark *seems* to pass" becomes a checked `PASS/FAIL` — the LLM can't
  claim a success the numbers don't show, and the reviewer reads the verdict, not a `println`.

## The examples (what's here)

```
examples/
├── Project.toml             # self-contained env (Pinax + DataVault + ParamIO + Plots)
├── configs/ising.toml       # the sweep config — the compute stack's input
├── ising_datavault.jl       # ★ THE research flow to COPY: a Monte-Carlo sweep → DataVault →
│                            #   render(; vault) (BOTH faces) + a @benchmark (M(T) vs the known
│                            #   Ising limits — ordered below Tc, disordered above)
└── finitetemperature_demo.jl  # a real-project report: figures from a project's output → gallery + latex
```

## Run it

```bash
julia --project=examples examples/ising_datavault.jl
```

Then look at the **two faces of the same result**:

- **human** → `examples/out/gallery/index.html` — the `M(T)` curve, the spin-lattice GIF, and the
  benchmark's green/red rows.
- **LLM** → `examples/out/agent/agent.json` — the `M(T)` figure *as a data table* + the benchmark
  **verdict** (`grep -o '"verdict":"[A-Z]*"' …/agent.json`).

The Monte Carlo runs once into the vault; re-running rebuilds the figures from stored data (the
`render(; vault)` cache is data-aware), so the two faces stay in lock-step with the numbers.

## How it plugs into your research flow

`ising_datavault.jl` is the shape to copy. In a real run the **compute stack** writes the vault
(`ParamIO` → `DataVault` → `ParallelManager.run!`), then **`Pinax.report(vault, recipe)`** (or
`render(; vault)`) builds the two faces, and **Archeion** ingests them (the registry / regression
memory). The `recipe` is the *only* project-specific part — the same `@page` / `@figure` / `@table` /
`@benchmark` macros this example uses. See [`../../CLAUDE.md`](../../CLAUDE.md) for the whole loop, and
[`../CLAUDE.md`](../CLAUDE.md) for the Pinax seam card.
