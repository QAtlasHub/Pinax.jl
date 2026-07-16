# # Test → Pinax
#
# A test suite reports **one bit**: green or red. That bit throws away almost everything the suite
# knew — a `@test isapprox(E, oracle; rtol=1e-3)` *computed* `E`, the reference, and the tolerance,
# then printed a checkmark and discarded all three. A check sitting at 97 % of its tolerance is one
# refactor from red, yet the badge shows the same green as a rock-solid one.
#
# The **test bridge** turns the suite into a *document* instead: one page per test file, each check
# shown with the **margin** it passed by (`delta / tol`), versioned with the docs, readable by a human
# and by an agent. The gallery embedded above is produced by exactly the suite below.
#
# ## The only change a suite needs
#
# Wrap the root testset in `@pinaxtestset`; everything nested stays plain `@testset` / `@test`. Switch
# the report on with `PINAX_TEST_REPORT=1` in CI. With it off, `@pinaxtestset` expands to a stock
# `@testset` on `Test.DefaultTestSet` and nothing changes — so turning the report on can never regress
# a passing suite.

using Pinax, Test

# A suite writes only `@testset` and `@test`. It may *also* draw, in Pinax's own vocabulary and with
# the same macro names it would use in a manuscript — a `@desc` here, a `@figure` there — and that
# content is captured and rendered in the report. It never changes the verdict.

@pinaxtestset "DemoPkg" begin
    @testset "test_energy.jl" begin
        @desc md"Ground-state observables of the demo model against the exact reference."

        ## a comfortable check — spends only a few percent of its tolerance
        @test isapprox(-1.2731, -1.2735; rtol=0.01)

        ## a check that passed, but *barely* — it spent ~97 % of its budget and is one refactor from
        ## red. In a green CI badge it is indistinguishable from the solid one above; here it is not.
        @test isapprox(0.4122, 0.4102; rtol=0.005)
    end

    @testset "test_magnetisation.jl" begin
        @test isapprox(0.6664, 0.6667; rtol=0.002)
    end
end

# ## What you get
#
# Each test *file* becomes a `status = :benchmark` page; each nested `@testset` a section; each `@test`
# a `Check` carrying its real `got` / `want` / `tol`. From those, two figures are derivable with no
# figure code at all — a **convergence** figure (`got` vs the swept axis) and a **margin** figure
# (`delta / tol`, with the pass/fail boundary at 1.0) — and the whole thing renders to three backends
# from one document: `:gallery` (human), `:agent` (`agent.json`, for a reviewing agent), and `:latex`.
#
# Sharded CI needs nothing extra: each shard dumps its tree and one later job merges the dumps and
# renders once, so the shard boundary never appears in the output.
