# Migrating from 0.1 to 0.2

0.2 settles the authoring conventions ([Conventions](conventions.md)) and changes code that
relied on the old behaviour. This page lists every change you may have to make, grouped by who makes
it: a report's author, a test suite, a program that reads `agent.json`, and a theme's author.

Whatever 0.2 still accepts for compatibility warns once and names the replacement; whatever it no
longer accepts is an error that says what to write instead.

## Authors of reports

| 0.1 | 0.2 |
|---|---|
| `@expect cond` | `@test cond` (with `using Test`) inside the `@page` / `@section`. It is recorded as a check of that container, with what it compared and its margin. |
| `@benchmark …` | A `@section` (or a `@testset` inside one) holding `@test` checks. |
| `@debug_mode true` | `@pinaxsetup debug = true`, in the `@pinaxsetup` that starts the document. `@debug_mode` still works during 0.2, with a warning. Do not put `@pinaxsetup` where `@debug_mode` was: it starts a new document and discards everything above it. |
| `status = :trial` | `status = :draft`. `:trial` is accepted during 0.2, with a warning. Any other value is an error. |
| `@thumbnail "fig_id"` | `@thumbnail :fig_id` — a Symbol, naming a figure on the page. |
| `@section … by = ("N", "g")` | `by = "N"`: one axis, a String. |

### Ids

- An id is unique in the **whole document**, across kinds: a figure cannot share an id with a
  section, a page or a table. A repeated id is an error that names both nodes.
- An id Pinax generates is no longer a position (`energy_fig1`). It is the container's id plus a hash
  of the node's own content (`energy_fig_k3x9q2a`), so adding or moving other nodes leaves it alone.
  Editing the node's own code changes it.
- So: **give an explicit `id=` to every node something else refers to** — an `@ref`, a comment, a
  record that keeps the id across revisions. A comment stored under a 0.1 id such as `energy_fig1`
  now names no node; rendering says so in its diagnostics. Re-key it in `comments.toml`, or give the
  figure back that id with `id = :energy_fig1`.

### Content and structure

- `@desc` is a prose block placed where it is written. A container holds any number of them,
  interleaved with figures, tables and code; it no longer has one description.
- `@caption` names only the node written immediately before it, and a node takes one caption. A
  `@caption` after `caption=`, after prose, or a second `@caption`, is an error.
- Each block has one place: `@part` at the top level, `@page` at the top level or directly in a
  `@part`, `@section` in a page or a section (to any depth), `@pinaxsetup` outside every block.
- `@raw html` has an id (`id=`, or one generated from the HTML). The gallery wraps it in
  `<div class="pinax-raw" id="…">`; `agent.json` and `agent.md` now carry its HTML.
- Put a check in the section whose claim it verifies, so the claim, its evidence and its verdict are
  read together.

### Output

- `out` is always a directory. `report`, `render_test_report` and `Pinax.test` write `out/html/` and
  `out/agent/` (0.1 wrote `<out>_html` and `<out>_agent` beside it), and both faces read one
  `out/comments.toml`. Move an existing comment store there.
- `render` throws `ChecksFailed` after writing every output when the document holds a failing check
  that no enclosing testset counted.

## Test suites

- `Pinax.test` and `render_test_report` write `out/html/` and `out/agent/` (see Output above).
- A check's location is the file's path relative to its project (`test/test_x.jl:42`), not a bare
  file name.
- Ids generated from a check's or code block's text no longer depend on the Julia version (1.13
  prints `end` as `var"end"`).

## Programs that read `agent.json`

The shape is a contract, and 0.2 settles it; pinax-mcp moves with it. Every node now names where it
was written, every container carries the same keys, and nothing is inlined as a cut copy.

| 0.1 | 0.2 |
|---|---|
| a page's or section's `desc` | `texts: [{id, text, defined_at}]`, placed in order by `{kind: "text", id}` refs in `content` |
| a figure's `data: "<path>.csv"` and `table: {header, rows, total}` (a 20-row preview) | `data: {path, columns, series: [{label, points}]}` or `null`. The file holds every plotted point; there is no inline preview. |
| a code block's `anchor` | removed — the id is the only name |
| a check's `code_anchor` | `code_id` (`null` when there is none) |
| a check's `source` | `defined_at` |
| text the author did not write: `null` | `""` |

New in 0.2:
- `defined_at` (`path:line`, relative to the project that holds the file) on every prose block,
  figure, table, code block, `@raw` block and check.
- `comments` on every page, section and table, as on figures.
- `raws: [{id, html, defined_at}]` and `{kind: "raw"}` refs.
- `depth` on pages (1) and sections (2 and deeper), `status` on parts.
- A top-level `diagnostics` array: what the build and the render recorded, such as a figure with no
  data form or a comment that names no node.

A figure's data file is a CSV whose header names the columns by the plot's axis labels —
`series,beta,E/N`, or `series,x,y` when the plot has none — followed by every point. 0.1 started it
with a `# pinax figure data …` comment line and cut each series to 2000 points.

To keep a reference across revisions, use [`node_ids`](@ref): it lists every node with its kind and
whether Pinax generated its id. Do not infer that from an id's shape.

## Authors of themes

- Leaf content — `Prose`, `Table`, `CodeBlock`, `RawBlock` — goes through one generic,
  `emit_node(theme, node, ctx)`. Override it for one node type to change that type alone.
- The `figure_as_table` trait is removed: the agent face points at a figure's data and never inlines
  it.
- `@raw` blocks are `RawBlock`s: a container's `panels::Vector{String}` is now
  `raws::Vector{RawBlock}`, and the content kind `:panel` is `:raw`. `TestNode` changed the same way.
- The gallery renders a one-page document through `emit_page` too.
- The gallery's status badge class is `pinax-status` (was `card-status`); verdict badges are
  `pinax-vbadge-pass` / `pinax-vbadge-fail`.
