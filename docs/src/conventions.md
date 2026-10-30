# Conventions

This page fixes how a Pinax document is written and what each construct means. It is the single
reference for the authoring interface: code, docs and tests follow it, and a change to a convention
starts here. Where the code does not yet follow a convention, the entry names the issue that tracks
the gap.

## Structure

- A document is a tree: `@part` › `@page` › `@section`, and `@section` nests to **any depth**. Leaving
  a block returns to the enclosing one. `@page` or `@part` inside a section is an error raised where
  it is written. (#170)
- Depth is counted from the part: `@part` 0, `@page` 1, a top-level `@section` 2, and so on.
- Each backend turns depth into a heading in **one** place (`emit_heading`), never by hard-coding a
  heading command in an emitter:

  | depth | LaTeX | Typst | Markdown | gallery HTML |
  |---|---|---|---|---|
  | 1 (page) | `\section` | `=` | `##` | page title |
  | 2 | `\subsection` | `==` | `###` | `<h2>` |
  | 3 | `\subsubsection` | `===` | `####` | `<h3>` |
  | 4 | `\paragraph` | `====` | `#####` | `<h4>` |
  | 5 | `\subparagraph` | `=====` | `######` | `<h5>` |

  Beyond a backend's native levels, the node is rendered in one fixed fallback form for that
  backend and a diagnostic names it. Depth is never flattened silently. (#170)

## Identity

- Every node id is unique within the document. A collision (two pages with one id, two figures with
  the same `params` in one section, two checks with one id) is an **error raised where the second
  node is written**, naming both. There is no automatic renaming, so ids and links stay stable.
- Anchors are hierarchical paths (`page.section.subsection`), so equal ids under different parents
  do not collide.
- Comments, cross-references and `agent.json` all address a node by the same id. There is no second
  naming scheme.

## Maturity

- `status` takes exactly two values: `:draft` (a manuscript, work in progress) and `:final` (the
  published, curated version). Any other value is an error.
- `:trial` is accepted during 0.2 as a deprecated alias of `:draft`, with a warning.
- `status` says only how finished a page is. What kind of page it is (for example, whether it holds
  checks) is not a status value.

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
  there is none when the subtree holds no checks, so an empty container never reads as PASS. Every
  face shows it on every container that has one.
- A failing check is reported **exactly once**:
  - When an ordinary testset encloses the document (a test suite), the result is handed to it, and
    the suite counts it as if the `@test` were written there.
  - Otherwise `render` writes every output with the failure shown as FAIL, then raises
    `ChecksFailed`, naming the failing ids and the file written.
- `@assert` is plain Julia: a precondition. When it fails, rendering stops with the error. It is
  not recorded as a check.
- `@expect` and `@benchmark` are removed. During 0.2 each raises an error that names its
  replacement (`@test`, and a `@section` / `@testset` holding checks).
- Every container whose subtree holds checks shows them the same way in every face: a verdict band
  over the subtree, then a table of the checks it owns.

## Captions and descriptions

- A caption can be given two ways: `caption=` on `@figure` / `@table`, or `@caption` written
  directly after the node.
- `@caption` attaches to the node **immediately before it**. If there is none, or that node cannot
  carry a caption, it is an error. It never reaches back to an earlier figure. (#159)

## Faces

- Every node kind has a form in every face: the gallery and LaTeX (human) and `agent.json` (LLM).
  Backends dispatch on the node type. A node kind a backend does not handle is an error, never a
  silent omission. (#168)
- The `agent.json` shape is a contract. It is documented from what the emitter writes, and the
  pinax-mcp fixture is generated from the emitter and checked against the consumer schema. (#169)

## Rendering and data

- Rendering is idempotent. Rendering twice, or again after a crash halfway, gives the same output,
  and a figure is re-rendered whenever the data or code it depends on changes. (#165, #166, #117)
- Every figure can be traced back to the stored data and the code that produced it, from both the
  page and `agent.json`. (#167)

## Open questions

These are not settled yet. Each will move into a section above once decided.

- **`@desc`.** What a second `@desc` in one container means, and whether `@desc` keeps its position
  in content order.
- **`@raw`.** What form it takes in `agent.json`.
- **The figure form in `agent.json`.** A plotted-data table may not convey a plot's features. This
  is to be measured before the form changes.
