# Pinax.jl

[![docs: dev](https://img.shields.io/badge/docs-dev-purple.svg)](https://qatlashub.github.io/Pinax.jl/dev/)
[![Julia](https://img.shields.io/badge/julia-v1.12+-9558b2.svg)](https://julialang.org)
[![Code Style: Blue](https://img.shields.io/badge/Code%20Style-Blue-4495d1.svg)](https://github.com/invenia/BlueStyle)

<a id="badge-top"></a>
[![codecov](https://codecov.io/gh/QAtlasHub/Pinax.jl/graph/badge.svg?token=Q3oEEiz9A2)](https://codecov.io/gh/QAtlasHub/Pinax.jl)
[![Build Status](https://github.com/QAtlasHub/Pinax.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/QAtlasHub/Pinax.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Aqua QA](https://raw.githubusercontent.com/JuliaTesting/Aqua.jl/master/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

> *A board of figures that is also a catalogue.*

**Pinax** turns the figures and tables your analysis scripts produce into a **structured,
self-contained catalogue** of a computational study — described once and rendered three ways:

- **HTML gallery** — sections as cards, a responsive figure grid, markdown + KaTeX math,
  cross-references, citations, and an interactive comment layer;
- **LaTeX → PDF** — the same manuscript as a typeset document;
- **`agent.json`** — a machine-readable view (figures *as data tables*, sections, captions) that an
  LLM or downstream tool can read.

It generalizes the hand-written `build_report` page an analysis pipeline grows over time: you
describe the manuscript once with a small DSL, point each figure at the value (or data key) it
plots, and `render` writes the artifact.

> *πίναξ* (Ancient Greek) — "tablet / catalogue / register"; the *Pinakes* were the catalogue of the
> Library of Alexandria.

## Installation

```julia
pkg> add https://github.com/QAtlasHub/Pinax.jl
```

Requires Julia v1.12+. Not in the General registry yet.

## Quickstart

```julia
using Pinax

@page :results "Results" begin
    @section :energy "Energy" begin
        @desc md"Energy density $E/N$ versus inverse temperature $\beta$."
        @figure plot_energy()      # any Plots/Makie figure — captured lazily
        @caption "χ-convergence"
    end
end

render(out = "site")               # -> site/index.html    (self-contained HTML gallery)
serve("site")                      # preview over HTTP

# render(theme = :latex, out = "pdf")     # -> pdf/document.tex  -> PDF
# render(theme = :agent, out = "agent")   # -> agent/agent.json  (machine-readable)
```

`@figure` captures its expression lazily, so figures are computed (and cached) only when you
`render`. Sections become cards; figures lay out in a responsive grid; `$…$` math is rendered by
KaTeX.

## Three faces of one report

| `theme` | output | for |
| --- | --- | --- |
| `:gallery` *(default)* | self-contained HTML | humans browsing results |
| `:latex` | LaTeX → PDF | manuscripts / sharing |
| `:agent` | `agent.json` | LLMs / downstream tooling |

The same source — sections, `@desc`/`@caption`, `@table`, citations, a `@benchmark`'s PASS/FAIL
verdict — flows to every face. Themes are pluggable: `render(; theme = MyTheme())`,
`register_theme!(:mine, MyTheme())`, or `theme = "path/to/mytheme.jl"`.

## Bridging a parameter sweep

`report(vault, recipe; title, out)` discovers a finished sweep's results, hands each `(key, dict)`
pair to a project-specific `recipe` that builds the doc, and renders both the gallery and
`agent.json` — so the same results become a human notebook and an LLM-readable artifact in one call.

## Bridging a test suite

A test suite reports one bit: green or red. A `@test isapprox(E, oracle; rtol=1e-3)` computed `E`,
the reference and the tolerance, then threw all three away. `Pinax.test` renders the suite instead —
one page per test file, each check carrying the margin it passed by.

**The suite is not touched.** There is no Pinax macro to add to it; the suite stays plain
`@testset` / `@test`, and the one Pinax touch is the call:

```julia
using Pinax, Test

Pinax.test()                     # delegate to an unmodified `Pkg.test`, and render a report
Pinax.test("test/runtests.jl")   # render a specific suite in the current process
```

`Pinax.test()` injects a `-L` preamble that installs a capturing root before the suite runs and
renders at exit; `Pkg.test` still does all the sandbox and dependency work. A bare `Pkg.test()`
installs no root and produces no report, so switching the report on cannot regress a passing suite.
A red suite always fails the process — a report must never turn a failing suite green.

A test *file* becomes a page, a nested `@testset` a section, and each `@test` a `Check` with its real
`got` / `want` / `tol`. `@pinaxignore` drops a testset from the document while still running and
counting it.

Sharded CI uses the same primitive: with `PINAX_TEST_DUMP` a run dumps its testset tree as TOML
instead of rendering, and `render_test_report(dumps; out)` merges the dumps into one gallery whose
pages are the test files — the shard boundary never appears in the output. Publishing that report
alongside the Documenter docs is [#68](https://github.com/QAtlasHub/Pinax.jl/issues/68).

## MCP server

`render(theme = :agent)` emits an `agent.json` an LLM can read. **[`clients/pinax-mcp`](clients/pinax-mcp)**
is a Node MCP server over that artifact: it serves every unit (figure / table / section) by id and
presents a figure as its underlying data table — `npx pinax-mcp --agent <render-out>`. See its
[README](clients/pinax-mcp/README.md).

## Development

This package is written with the assistance of [Claude Code](https://claude.com/claude-code). The
design is mine — the DSL, the three faces of one document, and the test-suite bridge. The
implementation, the test suite and the reference documentation are LLM-assisted and reviewed by me
before merging.
