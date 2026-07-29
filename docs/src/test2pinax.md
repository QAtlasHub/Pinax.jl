# Test → Pinax

A test suite reports **one bit**: green or red. That bit throws away almost everything the suite knew
— a `@test isapprox(E, oracle; rtol=1e-3)` *computed* `E`, the reference, and the tolerance, then
printed a checkmark and discarded all three. A check sitting at 97 % of its tolerance is one refactor
from red, yet the badge shows the same green as a rock-solid one.

Pinax provides an interface that **outputs a testset directly** as a document — one page per test file,
each check shown with the margin it passed by (`delta / tol`) — readable by a human and by an agent.

```@raw html
<p style="font-size:1.05em"><a href="../test-report/">▶ Open Pinax's own test report</a> — rendered
from Pinax's real <code>test/runtests.jl</code> by <code>Pinax.test()</code> in CI (the delegation job
below), carried into this site unchanged. Not a contrived demo, and not re-run for the docs: it <em>is</em>
the CI run's output.</p>
```

## The interface: `Pinax.test`

The suite stays **plain `@testset` / `@test`** — there is no Pinax-specific macro to add to it. The one
Pinax touch is the *call*. Two forms:

```julia
Pinax.test()                       # test the active package: delegate to `Pkg.test`, render a report
Pinax.test("test/runtests.jl")     # render a specific suite in the current process
```

`Pinax.test()` delegates to an **unmodified `Pkg.test`**, injecting a `-L` preamble that installs a
capturing root before the suite runs and renders at exit. `Pkg.test` still does all the sandbox and
dependency work; a bare `Pkg.test()` without this installs no root and produces no report. Either way
the suite is unchanged and a red suite still fails the process — the report never touches the verdict.

A suite may *also* draw in Pinax's own vocabulary (`@desc`, `@figure`, `@table`, …); that content is
captured into the report, and is a no-op under a bare `Pkg.test()`.

## Proof by dogfood: three entry points, one suite

Pinax's own `test/runtests.jl` is plain `@testset` with **no token**, and its CI runs that same suite
three ways:

| Entry point | What it exercises |
|---|---|
| `Pkg.test()` | stock `Test` — the suite is ordinary, untouched, no report |
| `Pinax.test()` | the `Pkg.test` **delegation** — same sandbox, plus a rendered report |
| `Pinax.test("test/runtests.jl")` | the **in-process** (Test-level) entry — same suite, plus a report |

All three green — with the **same verdict** — is the proof that Pinax adds a report without changing
*what* the suite is, *how* it runs, or *whether* it passes. The two Pinax runs render Pinax's own test
report (uploaded as a CI artifact); that report *is* the example, produced from Pinax's real suite
rather than a contrived one.

## What you get

Each test *file* (a `.jl`-named `@testset`) becomes a `status = :benchmark` page, each nested
`@testset` a section, and each `@test` a `Check` carrying its real `got` / `want` / `tol`. From those,
a **convergence** figure and a **margin** figure are derivable with no figure code, and the whole thing
renders to three backends from one document: `:gallery` (human), `:agent` (`agent.json`, for a
reviewing agent), and `:latex`. Sharded CI needs nothing extra — each shard dumps its tree and one
later job merges the dumps and renders once, so the shard boundary never appears in the output.

## Sharding: TestShards

"Sharded CI needs nothing extra" holds for the *dump and merge*, but not for the capture, and the gap
was silent. [TestShards](https://github.com/QAtlasHub/TestShards.jl) runs each shardable unit inside a
testset it builds by hand rather than through `@testset` — deliberately, so a failed unit can still be
read back. `Test` builds a nested testset from its **parent's type**, which is the only reason the
capture sees a suite at all, so with a unit's testset being TestShards' own, a `@shard` suite under
`Pinax.test` rendered `0/0 passed`: empty **and** green, indistinguishable from a suite with no tests.

`ext/PinaxTestShardsExt.jl` closes it, through the provider seam TestShards exposes
(`register_unit_provider!`). Loading both packages is the whole setup:

```julia
using MyPackage, TestShards, Pinax
TestShards.@shard begin
    include("core/a.jl")
    include("core/b.jl")
end
```

Each unit becomes a page, its `@testset`s become sections, and the margins are there as usual. The
provider **declines** unless a capture is ambient, so a bare `Pkg.test()` of a sharded suite runs
exactly as it did before — the same invariant as everywhere else here: the report changes nothing
about how the suite runs.

### When the runner owns `Pkg.test`

`Pinax.test()` gets its capture in by handing `Pkg.test` a `-L` preamble, which is what lets it leave
`runtests.jl` untouched. In CI that route is often closed: the action running the suite owns the
`Pkg.test` call and exposes no way to add a flag to it — `julia-actions/julia-runtest` has inputs for
`check_bounds`, `coverage`, `depwarn` and the rest, and none for `julia_args`. Replacing the action to
get the flag in means re-implementing whatever else it was setting, and **coverage is the one that
hurts**: a sharded suite that stops emitting `.cov` counters has nothing to merge.

So install the capture from inside the suite instead. It is one line, and it is inert unless the
environment asks for a report:

```julia
using MyPackage, TestShards, Pinax
Pinax.install_test_capture!()
TestShards.@shard begin
    include("core/a.jl")
end
```

The runner stays whoever it was, with its own flags. Per-shard dumping is then one environment
variable — set `PINAX_TEST_DUMP` to an **absolute** path, since `Pkg.test` tears its sandbox down
around you:

```yaml
- uses: julia-actions/julia-runtest@v1        # coverage, check_bounds, … all still its business
  env:
    PINAX_TEST_DUMP: ${{ github.workspace }}/pinax-dumps/${{ matrix.shard }}.toml
```

and one job afterwards merges them with [`render_test_report`](@ref).

[`Pinax.install_test_capture!`](@ref) does nothing at all unless `PINAX_TEST_OUT` or
`PINAX_TEST_DUMP` is set, so the line above can be committed and a developer's `Pkg.test()` behaves
as it always did. It is idempotent too: a `runtests.jl` carrying it is still a valid target for
`Pinax.test()`, and the second install declines rather than opening a rival root that would take the
assertions and leave the first to render empty and green.

TestShards' `evidence!` comes across too. A test that says what grounds it —

```julia
@testset "tight" begin
    evidence!(; tolerance = 0.01, achieved = 0.0097, oracle = "closed form")
    @test isapprox(1.0, 1.0098; rtol = 0.01)
end
```

— gets that as a table on the section that recorded it, beside the check and the code. From
`agent.md` of a real run:

```text
#### tight  [id: unit_a_jl_tight]
    evidence!(; tolerance = 0.01, achieved = 0.0097, oracle = "closed form")
    @test isapprox(1.0, 1.0098; rtol=0.01)

- [PASS] t1 — isapprox(1.0, 1.0098; rtol = 0.01): got 1.0, want 1.0098 (Δ 0.0097 vs tol 0.01 rel)

_What this test established (`evidence!`)._  [table: unit_a_jl_tight_tbl1]
| established | value |
| --- | --- |
| achieved | 0.0097 |
| oracle | closed form |
| tolerance | 0.01 |
```

A verdict says the test passed and the margin says by how much; this says *against what*. Being a
table it is native rows in `agent.json`, which is the binding an agent needs to reconcile a claim
against what was actually compared. Evidence recorded inside a swept `@testset for` is the one case
that does not survive — it is dropped with the rest of that sample's content, and the sweep fold
already warns about a `@table` there.

## Saying what the job knows and the tree does not

A merged report is built from the trees the shards dumped, and some things are simply not in a tree.
Whether **every** shard reported, for one: a sharded report that is missing a shard looks exactly like
a smaller suite. That verdict lives in the CI job, and until now it lived only in a log that expires.

`render_test_report(…; overview)` takes a zero-argument function and runs it with the **overview page
open**, so it writes in Pinax's ordinary vocabulary and the content lands there:

```julia
Pinax.render_test_report(
    readdir("pinax-dumps"; join=true);
    out = "test-report",
    overview = () -> begin
        @desc md"**Every unit ran exactly once** — 24 observed, 24 run."
        @table (; metric = ["units observed", "units run"], value = [24, 24]) caption = "Completeness"
    end,
)
```

A `@desc` appears above the fixed provenance and per-file tables — a page's description is not
content-ordered — which is where a verdict wants to be; tables follow them. Everything goes to every
backend, so the verdict is **data** in `agent.json` and not only pixels in the gallery.

If the hook throws, that is a diagnostic in the report and the report still renders: the same rule as
everywhere else here — the machinery that draws a run may not change its verdict, in either direction.

### Completeness, packaged

The verdict above is the one that matters most, so it comes ready-made. TestShards observes the whole
unit sequence in *every* shard, so it knows which units should exist; `completeness` compares that
against what ran, and `completeness_overview` turns the result into overview content:

```julia
using Pinax, TestShards
c = TestShards.completeness(windows, ran)
render_test_report(dumps; out = "test-report", overview = completeness_overview(c))
```

The numbers become a table — native rows in `agent.json` — and the verdict becomes the prose above it,
naming the positions of any hole:

```text
**Completeness FAILED.** 1 unit never ran: position 2. The run is green and that part of the
suite was not tested.
```

Neither package can say that alone: TestShards holds the verdict, Pinax holds the document. The method
lives in `PinaxTestShardsExt`, so it appears when both packages are loaded and costs nothing when they
are not.
