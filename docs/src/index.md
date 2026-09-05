# Pinax.jl

> *A board of figures that is also a catalogue.*

Pinax turns the figures your analysis scripts produce into a **structured, self-contained HTML
gallery** — sections as cards, a multi-column figure grid, markdown + math descriptions,
cross-references, citations, and an interactive comment layer — and can export the same manuscript
to **PDF** via a LaTeX theme.

It generalizes the hand-written `build_report` page that an analysis pipeline grows over time: you
describe the manuscript once with a small DSL, point each figure at the value (or data key) it
plots, and `render` writes the gallery.

## The shape of it

```julia
using Pinax, Plots

plot_energy() = plot(0.1:0.05:2, β -> 1 / β; xlabel = "β", ylabel = "E/N", legend = false)

@page :results "Results" begin
    @section :energy "Energy" begin
        @desc md"Energy density $E/N$ versus inverse temperature $\beta$."
        @figure plot_energy()          # any Plots/Makie figure — deferred until render
        @caption "χ-convergence"
    end
end

render(out = "site")                    # -> site/index.html  (self-contained)
# render(theme = :latex, out = "pdf")   # -> pdf/document.tex -> PDF
```

`@figure` captures its expression lazily, so figures are only computed (and cached) when you
`render`. Sections become cards; figures lay out in a responsive grid; `$…$` math is rendered by
KaTeX; `serve("site")` previews it over HTTP.

## Where to go next

- **[Examples](examples.md)** — a **map of contents** across every compiled gallery (a LaTeX-style
  table of contents that spans them all), plus a source walkthrough for each. Every gallery is built
  *live*: `docs/make.jl` runs `docs/literate/gallery.jl` during the build and embeds the gallery it
  renders, so the page shows the output of the source it displays.
- **[API Reference](api.md)** — every exported macro and function.
