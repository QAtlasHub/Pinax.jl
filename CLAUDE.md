# CLAUDE.md — Pinax.jl

**The artifact / report layer above the HPC compute stack** (ParamIO → DataVault →
ParallelManager → **Pinax**). One presentation-neutral doc → three backends. Its job in the
workflow: turn results — including a finished `DataVault` sweep, via `report` — into a **human
gallery** *and* an **LLM-readable `agent.json`**. The LLM-facing seam of the whole pipeline is
`agent.json` (data, not pixels). See [`../CLAUDE.md`](../CLAUDE.md) for the compute stack.

## The two faces — human vs LLM (the point of the agent backend)

The same doc has **two representations, chosen by who reads it** — neither is a downgrade:

- **Human → the gallery (pixels).** A plot is the *right* human view: you read a curve's shape and
  scan a dozen panels at a glance. `:gallery` (interactive HTML) and `:latex` (print) are the human
  faces.
- **LLM → `agent.md` / `agent.json` (data).** An LLM reads to discuss a report or to drive its
  revision, and it reasons over *numbers* far more precisely than over pixels (image tokens are
  costly + non-deterministic). The agent face is the **same compiled report**, in reading order,
  each `@desc`/`@figure`/`@caption` kept one block — and it is **exact or a pointer, never a cut
  copy**: a figure points at its data file (every plotted point, columns named by the axis labels,
  described by its columns and points per series; read it via the MCP `get_figure_data`), its image,
  and where it was written (`defined_at`). Conventions › The agent face.

`@table`, `@desc`/`@caption`, comments, `status`, and each container's **verdict** flow to **both**
faces from one source. This duality — *figure for humans, data for LLMs, single source* — is why the
agent backend exists; the verdict is its sharpest case: a human scans a colored check table, an LLM
reads a machine-checkable `PASS/FAIL` instead of trusting a `println`. Keep it
when adding any node type: it needs a human render **and** an agent-data form.

## Role / public API — the seam

- **Build a doc** (macros populate an implicit global document): `@pinaxsetup` ·
  `@part`/`@page`/`@section` (structure; sections nest to any depth; `status=:draft|:final`) ·
  `@figure` (a deferred `plot(...)` / Makie scene / image path) · `@caption`/`@desc`
  (markdown+math) · `@table` (a sibling to figures) · checks are `Test`'s own `@test` / `@testset`
  written in a container (a `@testset` is a child section) · `@raw` (HTML escape hatch). The full
  authoring contract is `docs/src/conventions.md`.
- **Render** `render(; out, theme=:gallery|:agent|:latex)` — one doc, three backends:
  `:gallery` (self-contained HTML notebook), `:agent` (`agent.json` + `agent.md`, the LLM view),
  `:latex`. Optional `vault=`/`study=` wires DataVault in (cache tracks the data's `.done`
  fingerprint; provenance recorded).
- **Bridge a sweep** `report(vault, recipe; title, out)` — discover the vault's `:done` keys, load
  each Dict, hand the `(key, dict)` pairs to a project `recipe` (which builds the doc), render
  gallery + agent.json into `<out>/html/` and `<out>/agent/`, which share `<out>/comments.toml`
  (`out` is always a directory). Driver project-independent; only `recipe` is project-specific.
  `sweep_mean(pairs, quantity, axis)` is a generic scalar-vs-swept-param reduction.

## Contracts that trip up callers — read this

- **`@figure`'s expression is DEFERRED** — captured, not run, until `render` (so structure is
  cheap and figures cache). The cache keys on code + `params`, plus the data's digest when a
  `vault` is given: inside `report`, the digest of the bytes the recipe actually read; otherwise the
  one the key's `.done` marker recorded.
- **`agent.json` is the neutral LLM seam** (the data face above) that pinax-mcp, registries
  (Archeion), and LLMs all read — treat its shape as a contract, not an internal detail.
- **`status` is a page's maturity:** `:draft` (a manuscript) or `:final` (the published version);
  anything else is an error. Pinax only carries it.
- **Every container with checks carries `verdict` + `checks` in `agent.json`** — `verdict` is
  `{verdict:"PASS|FAIL", passed, total, failed}` over the subtree (`null` with no checks, never a
  vacuous PASS) and `checks` holds the container's own `{id,label,got,want,delta,tol,kind,pass,…}`.
  Pages and sections share one set of keys; nodes reference each other by id (a check's `code_id`),
  and the document ends with its `diagnostics`.
  A failing check is reported once: to the enclosing testset, else `render` raises `ChecksFailed`
  after writing every output.
- **Two-env reality:** Pinax needs a plotting backend (Plots/Makie, heavy); compute needs its own
  heavy deps (ITensorMPS, …). They don't share an env in practice — compute writes a `DataVault`
  (or CSV), Pinax reads it. On HPC this maps to compute-node vs login-node; the seam is the vault.
- **pinax-mcp is a SEPARATE PROCESS** (`npx pinax-mcp --agent <out>`), not a Julia import. The
  neutral seam is the `agent.json` contract, not a repo/language boundary (it lives in
  `clients/pinax-mcp/` of this repo so emitter + schema co-evolve).

## Where to look for usage

- `test/test_datavault.jl` — the `report(vault, recipe)` bridge end-to-end.
- `test/test_agent.jl`, `test/test_table.jl` — the agent backend + `@table` / figure-as-table.
- `test/test_checks.jl`, `test/test_capture.jl`, `test/test_verdict.jl` — `@test` in a document, the
  verdict contract and the check table; `test/test_nesting.jl` — nested sections and headings.
- `ext/PinaxDataVaultExt.jl` / `PinaxParamIOExt.jl` — the DataVault/ParamIO seams (vault → doc,
  DataKey → stable figure id).
- `notes/00–11` (gitignored, Japanese OK) — the design spec.

## Invariants when changing this package

- **All shipped code comments & docstrings are ENGLISH** (notes/ may be Japanese).
- **Format in a clean env with JuliaFormatter v2** (`Pkg.activate(mktempdir()); Pkg.add(name="JuliaFormatter", version="2"); format(".")`) — the default env's stale formatter diverges from CI.
- CI gates **every** PR: `FormatCheck` (v2, no auto-fix) + `VersionCheck` (bump `Project.toml`) +
  Documentation/preview. Bump the Julia version even for a Node-only `clients/pinax-mcp` change.
- **Keep the `agent.json` contract stable** — it is the seam the MCP server, registries (Archeion),
  and LLMs depend on. Evolve emitter (`themes/agent.jl`) + consumer schema (`clients/pinax-mcp`) +
  the shared fixture together, in one PR. The fixture `clients/pinax-mcp/test/fixtures/emitted/` is
  generated by `test/test_contract.jl` (`PINAX_REGEN_CONTRACT=1` regenerates it; drift fails), and
  pinax-mcp fails when its schema does not name a key the emitter writes.
