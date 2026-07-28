using Pinax
using Test
using TestShards        # loading it is what triggers the extension — there is no switch to set

# The TestShards provider, end to end. Without it the two packages are mutually blind and silently
# so: a `@shard` suite under `Pinax.test` renders `0/0 passed` — empty AND green, indistinguishable
# from a suite with no tests. Every assertion below is the difference between composing and not.
#
# This file is NOT part of the default suite, which is why it sits in `test/ext/` rather than being a
# `test/test_*.jl` the suite globs: TestShards is not in General yet, so it cannot be an `[extras]`
# dependency (`Pkg.test` would demand a registered package). The `testshards` CI job installs it and
# runs this file. Once TestShards is registered, move this to `test/test_testshards.jl` — the glob
# picks it up — and delete the job.
#
# Everything runs in SUBPROCESSES: a capture is installed by a root testset at depth 0, which cannot
# be done from inside this suite, and a fixture's own results must not fold into it.

# A fixture whose numbers are the point: a check that passes with almost no room left, and a
# `@testset for` sweep, which Pinax folds into a convergence figure rather than three sections.
function shard_suite()
    d = mktempdir()
    write(
        joinpath(d, "unit_a.jl"),
        """
        using Test
        using TestShards: evidence!
        @testset "tight" begin
            evidence!(; tolerance = 0.01, achieved = 0.0097, oracle = "closed form")
            @test isapprox(1.0, 1.0098; rtol=0.01)
        end
        @testset "sweep" begin
            @testset for n in (8, 32, 128)
                @test isapprox(1 / n, 0.0; atol=0.2)
            end
        end
        """,
    )
    write(
        joinpath(d, "unit_b.jl"),
        "using Test\n@testset \"plain\" begin\n    @test true\nend\n",
    )
    write(
        joinpath(d, "runtests.jl"),
        """
        using TestShards
        TestShards.@shard begin
            include("unit_a.jl")
            include("unit_b.jl")
        end
        """,
    )
    return d
end

# Run a fixture in a subprocess, optionally under a capture. Returns (ok, log, records_dir, report).
# `TESTSHARDS_*` is stripped first: when THIS suite is itself sharded, the child would otherwise
# inherit the outer shard's id and split the fixture too.
function run_fixture(d; capture::Bool, env=Dict{String,String}())
    records = mktempdir()
    rep = joinpath(mktempdir(), "report")
    e = copy(ENV)
    for k in collect(keys(e))
        startswith(k, "TESTSHARDS_") && delete!(e, k)
    end
    merge!(e, env)
    e["TESTSHARDS_OUT"] = records
    proj = dirname(Base.active_project())
    runtests = joinpath(d, "runtests.jl")
    cmd = if capture
        driver = """
            using Pinax, Test
            Pinax.test($(repr(runtests)); out = $(repr(rep)), title = "Fixture")
            """
        `$(Base.julia_cmd()) --startup-file=no --project=$proj -e $driver`
    else
        `$(Base.julia_cmd()) --startup-file=no --project=$proj $runtests`
    end
    io = IOBuffer()
    ok = success(pipeline(ignorestatus(setenv(cmd, e)); stdout=io, stderr=io))
    return (ok, String(take!(io)), records, rep)
end

# Each subprocess loads Pinax, so the fixture and the one captured run are built ONCE and shared.
const _FIXTURE = Ref{Union{Nothing,String}}(nothing)
fixture() = (_FIXTURE[] === nothing && (_FIXTURE[] = shard_suite()); _FIXTURE[])

const _RUN = Ref{Any}(nothing)
function captured_run()
    return (_RUN[] === nothing && (_RUN[] = run_fixture(fixture(); capture=true)); _RUN[])
end

# TestShards' per-unit counts, from its JSONL records. Duration is deliberately excluded: it is wall
# clock and differs run to run.
function unit_counts(dir)
    out = Tuple{String,Int,Int,Int,Int}[]
    for f in readdir(dir; join=true)
        startswith(basename(f), "records-") || continue
        for l in readlines(f)
            num(k) = parse(Int, match(Regex("\"$(k)\":(-?[0-9]+)"), l).captures[1])
            push!(
                out,
                (
                    match(r"\"key\":\"([^\"]*)\"", l).captures[1],
                    num("npass"),
                    num("nfail"),
                    num("nerror"),
                    num("nbroken"),
                ),
            )
        end
    end
    return sort(out)
end

@testset "TestShards provider" begin
    @testset "registered by loading, and it declines outside a capture" begin
        @test Base.get_extension(Pinax, :PinaxTestShardsExt) !== nothing
        @test TestShards.UNIT_PROVIDER[].name == "Pinax"
        # This suite is its own witness: it is running right now with the extension loaded, and no
        # capture is installed, so a unit's testset is still TestShards' own default.
        @test TestShards._unit_testset("u.jl") isa Test.DefaultTestSet
    end

    @testset "an unsharded run renders one document with margins" begin
        ok, log, _, rep = captured_run()
        @test ok
        @test occursin("2/2 units ran", log)
        html = read(joinpath(rep * "_html", "unit_a_jl.html"), String)
        # the checks reached Pinax at all — the assertion that fails without the provider
        @test occursin("PASS", html)
        # …with their NUMBERS: 1.0 against 1.0098 spent 97% of its tolerance
        @test occursin("1.0098", html)
        # …the sweep folded into a convergence figure rather than three sections
        @test occursin("over the swept axis", html)
        # …and each check shows the code that produced it, as a @code block
        @test occursin("@test isapprox(1.0, 1.0098; rtol=0.01)", html)
        # one page per unit, and the second unit is there too
        @test isfile(joinpath(rep * "_html", "unit_b_jl.html"))
    end

    @testset "what a test established becomes content, not only a record" begin
        # `evidence!` is a test saying what grounds it. A verdict and a margin leave that unsaid, so
        # the provider attaches it as a @table on the node that recorded it — legible for a reader,
        # and native rows in agent.json, where it is the binding for reconciling a claim.
        _, _, _, rep = captured_run()
        html = read(joinpath(rep * "_html", "unit_a_jl.html"), String)
        @test occursin("What this test established", html)
        @test occursin("closed form", html) && occursin("tolerance", html)
        agent = read(joinpath(rep * "_agent", "agent.json"), String)
        # native rows, and sorted keys so a rebuild is the same table rather than the same facts
        # in a different order
        @test occursin("[\"achieved\",0.0097]", agent)
        @test occursin("[\"oracle\",\"closed form\"]", agent)
        i_ach = findfirst("\"achieved\"", agent)
        i_tol = findfirst("\"tolerance\"", agent)
        @test i_ach !== nothing && i_tol !== nothing && first(i_ach) < first(i_tol)
        # it landed on the section that recorded it, not on the page — and the table id is
        # UNIT-qualified, so two files each with a `@testset "tight"` cannot share one anchor
        @test occursin("\"id\":\"unit_a_jl_tight_tbl1\"", agent)
    end

    @testset "TestShards' own records are unchanged" begin
        # The regression that would corrupt its balancing without ever looking wrong: it reads the
        # per-unit counts out of a testset WE created. The same fixture, captured and not, must give
        # the same numbers — that is what `_fold` is for.
        _, _, plain, _ = run_fixture(fixture(); capture=false)
        _, _, captured, _ = captured_run()
        @test !isempty(unit_counts(plain))
        @test unit_counts(plain) == unit_counts(captured)
    end

    @testset "the completeness verdict rides in the artifact" begin
        # Neither package can state this alone: TestShards observes the whole unit sequence in every
        # shard and so knows which units should exist; we hold the document. Without it, a report
        # missing a shard reads as a smaller suite.
        w(shard, seen) = TestShards.ShardWindow(shard, 0.0, 1.0, 1, 1.0, seen)
        node = Pinax.TestNode(
            "f.jl"; checks=[Pinax.Check(:c, "ok", 1.0, 1.0, 0.0, 0.5, :abs, true)]
        )

        whole = TestShards.completeness(
            [w("s1", 2), w("s2", 2)], [(1, "s1", "a.jl"), (2, "s2", "b.jl")]
        )
        @test TestShards.complete(whole)
        dir = mktempdir()
        Pinax.render_test_report(
            Pinax.TestNode("T"; children=[node]);
            out=joinpath(dir, "rep"),
            overview=Pinax.completeness_overview(whole),
        )
        html = read(joinpath(dir, "rep_html", "overview.html"), String)
        @test occursin("Every unit ran exactly once", html)
        @test occursin("units observed", html) &&
            occursin("every unit ran exactly once", html)
        agent = read(joinpath(dir, "rep_agent", "agent.json"), String)
        @test occursin("[\"units observed\",2]", agent)      # native, not "2"
        @test occursin("\"id\":\"completeness\"", agent)

        # A hole is NAMED — the whole point is that the artifact contradicts "smaller suite"
        holed = TestShards.completeness([w("s1", 2), w("s2", 2)], [(1, "s1", "a.jl")])
        @test !TestShards.complete(holed)
        d2 = mktempdir()
        Pinax.render_test_report(
            Pinax.TestNode("T"; children=[node]);
            out=joinpath(d2, "rep"),
            overview=Pinax.completeness_overview(holed),
        )
        h2 = read(joinpath(d2, "rep_html", "overview.html"), String)
        @test occursin("Completeness FAILED", h2)
        @test occursin("1 unit never ran", h2) && occursin("position 2", h2)
        @test occursin("FAILED", read(joinpath(d2, "rep_agent", "agent.json"), String))
    end

    @testset "sharded, the shards merge into one document" begin
        # Each shard dumps instead of rendering; one merge renders every dump as a single document.
        dumps = mktempdir()
        for k in 1:2
            ok, _, _, _ = run_fixture(
                fixture();
                capture=true,
                env=Dict(
                    "TESTSHARDS_ID" => "s$k",
                    "TESTSHARDS_N" => "2",
                    "PINAX_TEST_DUMP" => joinpath(dumps, "s$k.toml"),
                ),
            )
            @test ok
        end
        @test length(readdir(dumps)) == 2
        merged = joinpath(mktempdir(), "merged")
        Pinax.render_test_report(readdir(dumps; join=true); out=merged, title="Merged")
        md = read(joinpath(merged * "_agent", "agent.md"), String)
        # Both units, ONE page each — a per-shard document would repeat them. Asserted on the ids
        # rather than on the ABSENCE of the word "shard": TestShards' own name contains it, and the
        # provenance table carries the repository name, so the tidier assertion is a false positive
        # in CI that passes locally.
        @test count("[id: unit_a_jl]", md) == 1
        @test count("[id: unit_b_jl]", md) == 1
        # …and the overview counts EVERY check across the shards: 4 from one, 1 from the other.
        @test occursin("5/5 passed", md)
    end
end
