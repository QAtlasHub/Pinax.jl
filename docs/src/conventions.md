# Conventions

This page fixes how a Pinax document is written and what each construct means. It is the single
reference for the authoring interface: code, docs and tests follow it, and a change to a convention
starts here. Where the code does not yet follow a convention, the entry says so and names the issue
or pull request that tracks the gap.

## Structure

- A document is a tree: `@part` › `@page` › `@section`, and `@section` nests to **any depth**.
  Leaving a block returns to the enclosing one.
- Each block has one place it may be written, and anywhere else is an error raised where it is
  written:
  - `@part` at the top level;
  - `@page` at the top level or directly inside a `@part`;
  - `@section` inside a `@page` or another `@section`.
- A page and a section are the same kind of container. Each holds its content in declaration order:
  prose (`@desc`), figures, tables, code blocks, checks, `@raw` blocks and child sections, freely
  interleaved.
- Depth is counted from the part: `@part` 0, `@page` 1, a top-level `@section` 2, and so on.
- Each backend turns depth into a heading in **one** function, used for pages and sections alike;
  no emitter hard-codes a heading command.

  | depth | node | LaTeX | Markdown (`agent.md`) | gallery HTML |
  |---|---|---|---|---|
  | 0 | part | `\part` | `##` | a `<details>` group on the index |
  | 1 | page | `\section` | `###` | `<h1>` |
  | 2 | section | `\subsection` | `####` | `<h2>` |
  | 3 | | `\subsubsection` | `#####` | `<h3>` |
  | 4 | | `\paragraph` | `######` | `<h4>` |
  | 5 | | `\subparagraph` | fallback | `<h5>` |

  Beyond a backend's native levels, the node is rendered in one fixed fallback form for that
  backend and a diagnostic names it. Depth is never flattened silently. A new backend adds its
  column here. (#170, #171)

## Identity

- Every node has an id, a `Symbol`, **unique in the whole document** across all kinds: parts,
  pages, sections, prose blocks, figures, tables, code blocks and checks.
- The id is the node's only name. It is its HTML anchor, the key its comments are stored under, its
  address in `agent.json` and pinax-mcp, and what `@ref` points at. There is no second naming
  scheme.
- An id the **author writes** is never renamed. A collision is an error raised where the second
  node is written, naming the id.
- An id **Pinax generates** is the container's id plus a short stable hash of the node's own
  content, so adding, removing or reordering other nodes never changes it.

  | node | hashed content | example |
  |---|---|---|
  | figure | its code and `params` | `energy_fig_k3x9q2a` |
  | table | its code | `energy_tbl_0bqw2jb` |
  | code block | its source | `energy_code_1r2mwly` |
  | prose block | its text | `energy_txt_9d0fngk` |
  | check | its source text | `energy_t0358x5n` |
  | section of a nested `@testset` | its description | `energy_conv` |

  The same content twice in one container gets `-2`, `-3`. A generated id is never an error.
- Displayed numbers ("Fig. 3", "Sec. 2.1") are positional and separate from ids. Adding a figure
  renumbers the display, never an id.

## Maturity

- `status` takes exactly two values: `:draft` (a manuscript, work in progress) and `:final` (the
  published, curated version). Any other value is an error.
- `:trial` is accepted during 0.2 as a deprecated alias of `:draft`, with a warning.
- `status` on a `@part` is the default for its pages; a page's own `status` wins.
- `status` says only how finished a page is. What kind of page it is (for example, whether it holds
  checks) is not a status value.

## Content

- `@desc` is a **prose block**: markdown and math, placed in content order like any other node. A
  container holds any number of them, interleaved with figures, tables and code.

  ```julia
  @section :energy "Energy" begin
      @desc md"We compare the energy with the exact solution."
      @figure plot_energy()
      @caption "Energy per site."
      @desc md"The deviation stays below $10^{-3}$ for every $N$."
  end
  ```

- Each content macro takes its expression first and keywords as `name = value`, in any order.
- A caption is given either as `caption=` on `@figure`, `@table` or `@code`, or by `@caption` written
  directly after the node. A node has **at most one** caption: a second one (`caption=` and then
  `@caption`, or two `@caption`s) is an error.
- `@caption` attaches to the node **immediately before it**: a figure, table or code block (its
  caption) or a check (its label). If there is none, or that node carries no caption (prose, `@raw`,
  a section), it is an error. It never reaches back to an earlier node.
- `@raw` is the HTML escape hatch. It is shown by the gallery only; every other face records in its
  diagnostics that it was left out. Any node a face cannot show (a figure with no asset LaTeX can
  include, a table with no columns) is likewise recorded, never dropped silently.

## Checks

- There is **one** check vocabulary: `Test`'s `@testset` and `@test`. Pinax adds no check macro of
  its own.
  - A `@testset` is a section, and nested testsets are nested sections.
  - A `@test` is a check, recorded with what it compared and its margin (`delta / tol`), exactly as
    in a test report (`Pinax.test`, see "Test → Pinax").
- While a `@page` / `@section` body runs, that container is the current testset. A `@test` anywhere
  in it is a check of the innermost container, and a `@testset "x"` in it is a child section. The
  body's variable scoping is exactly what it was. (#173)
- A verdict is derived, never stored. It is `(passed, total)` over the container's subtree, and
  there is none when the subtree holds no checks, so an empty container never reads as PASS.
- A failing check is reported **exactly once**:
  - When an ordinary testset encloses the document (a test suite), the result is handed to it, and
    the suite counts it as if the `@test` were written there.
  - Otherwise `render` writes every output with the failure shown as FAIL, then raises
    `ChecksFailed`, naming the failing ids and the file written.
- `@assert` is plain Julia: a precondition. When it fails, rendering stops with the error. It is
  not recorded as a check.
- `@expect` and `@benchmark` are removed. During 0.2 each raises an error that names its
  replacement (`@test`, and a `@section` / `@testset` holding checks).

## Faces

- Every node kind has a form in every face: the gallery and LaTeX (human) and `agent.json` (LLM).
  Every face handles every kind explicitly; a kind a face does not handle is an error naming the
  face and the kind, never a silent omission. (#168)
- Every container is laid out in the same order in every face: its heading, then its verdict band
  and the table of its own checks (when its subtree holds checks), then its content in declaration
  order.
- The `agent.json` shape is a contract. The pinax-mcp fixture is generated from the emitter
  (`test/test_contract.jl`) and checked against the consumer schema, which must name every key the
  emitter writes. (#169)
- In `agent.json`, a text field the author did not write is the empty string, and an object or a
  reference that does not exist is `null`. Pages and sections carry the same keys; a page adds only
  `part` and `status`. A reference between nodes is an id (a check's `code_id`).
- `agent.json` and `agent.md` end with the document's `diagnostics` — what the build and the render
  recorded, such as a node a face left out — so an agent sees the gaps as data.

## Output

- `out` is always a **directory**. `render` writes one face into it; `report` and the test reports
  write `out/html/` and `out/agent/`, and every face of one document reads the one
  `out/comments.toml`. (in progress, #172)

## Rendering and data

- Rendering is idempotent. Rendering twice, or again after a crash halfway, gives the same output,
  and a figure is re-rendered whenever the data or code it depends on changes. (#165, #166, #117)
- Every figure can be traced back to the stored data and the code that produced it, from both the
  page and `agent.json`. (#167)

## Open questions

These are not settled yet. Each will move into a section above once decided.

- **`@raw` in `agent.json`.** Whether it gets a form there (its HTML, or a text rendering of it), or
  stays a gallery-only escape hatch.
- **The figure form in `agent.json`.** A plotted-data table may not convey a plot's features. This
  is to be measured before the form changes.
