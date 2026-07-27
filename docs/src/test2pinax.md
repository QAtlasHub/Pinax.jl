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
