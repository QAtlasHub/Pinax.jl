using Pinax
using Test
using DataVault: DataVault
using ParamIO: ParamIO

@testset "DataVault integration: data-content cache fingerprint + provenance" begin
    tmp = mktempdir()
    cfg = joinpath(tmp, "config.toml")
    write(
        cfg,
        """
        [study]
        project_name = "demo"
        total_samples = 1
        outdir = "$(joinpath(tmp, "vault"))"

        [datavault]
        path_keys = ["system.N"]

        [[paramsets]]
        [paramsets.system]
        N = [24]
        """,
    )
    spec = ParamIO.load(cfg)
    key = ParamIO.expand(spec)[1]
    vault = DataVault.Vault(cfg; run="phase1")
    DataVault.save!(vault, key, Dict("x" => 1))
    DataVault.mark_done!(vault, key)

    # a figure whose deferred gen() bumps a counter, so we can detect (re)materialization
    calls = Ref(0)
    svgsrc = joinpath(tmp, "src.svg")
    function build()
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure params = key begin
                    calls[] += 1
                    write(svgsrc, "<svg xmlns='http://www.w3.org/2000/svg'><rect/></svg>")
                    svgsrc
                end
            end
        end
    end

    @testset "recomputing the data invalidates the cache (critique #8)" begin
        out = joinpath(tmp, "site")
        build()
        Pinax.render(; out=out, vault=vault)
        @test calls[] == 1                   # first render materializes
        build()
        Pinax.render(; out=out, vault=vault)
        @test calls[] == 1                   # unchanged data -> cache HIT (gen not called)
        sleep(1.1)
        DataVault.mark_done!(vault, key)      # data "recomputed" -> .done rewritten
        build()
        Pinax.render(; out=out, vault=vault)
        @test calls[] == 2                   # data changed -> cache MISS -> re-materialized
    end

    @testset "data that cannot be fingerprinted is said, and never served from the cache" begin
        # a vault that holds no `.done` for the key: nothing says when its data changes, so a cache
        # hit could show a stale figure — the figure re-renders every time, and a warning says why
        empty = DataVault.Vault(cfg; run="never_done")
        calls[] = 0
        out3 = joinpath(tmp, "site3")
        for n in 1:2
            build()
            @test_logs (:warn, r"cannot fingerprint the data") match_mode = :any Pinax.render(;
                out=out3, vault=empty
            )
            @test calls[] == n
        end
    end

    @testset "without a vault, data changes are not detected (prior behavior)" begin
        calls[] = 0
        out2 = joinpath(tmp, "site2")
        build()
        Pinax.render(; out=out2)             # no vault
        @test calls[] == 1
        sleep(1.1)
        DataVault.mark_done!(vault, key)
        build()
        Pinax.render(; out=out2)             # no vault -> still a hit despite data change
        @test calls[] == 1
    end

    @testset "record_figure writes study provenance meta.toml" begin
        build()
        Pinax.render(; out=joinpath(tmp, "site3"), vault=vault)
        meta = joinpath(vault.outdir, "figure", "phase1", "meta.toml")
        @test isfile(meta)
        @test occursin("git_hash", read(meta, String))
    end
end

# `report(vault, recipe)` — the vault → doc bridge. Discovers :done keys, loads each Dict,
# hands the (key, dict) pairs to a project recipe, renders gallery + agent.json. Driver generic.
@testset "report(vault, recipe): vault → gallery + agent.json" begin
    tmp = mktempdir()
    cfg = joinpath(tmp, "config.toml")
    write(
        cfg,
        """
 [study]
 project_name = "sweep"
 total_samples = 1
 outdir = "$(joinpath(tmp, "vault"))"
 [datavault]
 path_keys = ["system.N"]
 [[paramsets]]
 [paramsets.system]
 N = [8, 16, 24]
 """,
    )
    spec = ParamIO.load(cfg)
    vault = DataVault.Vault(cfg; run="phase1")
    for key in ParamIO.expand(spec)            # 3 keys; save a scalar result each
        n = key.params["system.N"]
        DataVault.save!(vault, key, Dict("N" => n, "val" => float(n)^2))
        DataVault.mark_done!(vault, key)
    end

    # generic helper aggregates val(N) across the swept axis; recipe builds a @table (no plot backend)
    recipe = function (pairs)
        Ns, vals = Pinax.sweep_mean(pairs, "val", "system.N")
        @page :sweep "val(N)" begin
            @desc md"auto report from the vault"
            @table (N=Ns, val=vals) caption = "val vs swept N"
        end
    end
    res = Pinax.report(vault, recipe; title="Sweep report", out=joinpath(tmp, "rep"))
    @test res.n == 3                                            # discovered all 3 :done keys
    @test isfile(res.gallery)                                   # human gallery
    @test isfile(res.agent)                                     # agent.json
    @test occursin("\"val\"", read(res.agent, String))         # the table reached agent.json
    @test occursin("64", read(res.agent, String))              # val(8)=64 present (native rows)
    md = read(joinpath(dirname(res.agent), "agent.md"), String)
    @test occursin("| N | val |", md)                          # LLM-readable table inline

    # `out` is a directory: one face per subdirectory, and both read one comment store
    @test res.gallery == joinpath(tmp, "rep", "html", "index.html")
    @test res.agent == joinpath(tmp, "rep", "agent", "agent.json")
    Pinax.add_comment(
        joinpath(tmp, "rep", "comments.toml"), :sweep, "SHARED_NOTE"; author="me"
    )
    res = Pinax.report(vault, recipe; title="Sweep report", out=joinpath(tmp, "rep"))
    @test occursin("SHARED_NOTE", read(res.gallery, String))
    @test occursin("SHARED_NOTE", read(joinpath(dirname(res.agent), "agent.md"), String))

    # a failing check nobody counted: both faces are written, then `report` throws (render's rule)
    failing = function (pairs)
        @page :f "F" begin
            @desc md"one failing check"
        end
        push!(
            Pinax.current_document().pages[1].checks,
            Pinax.Check(:bad, "bad", 2.0, 1.0, 1.0, 0.5, :abs, false),
        )
    end
    out = joinpath(tmp, "repfail")
    err = try
        Pinax.report(vault, failing; title="F", out=out)
        nothing
    catch e
        e
    end
    @test err isa Pinax.ChecksFailed && err.failed == ["bad"]
    @test isfile(joinpath(out, "html", "index.html"))
    @test isfile(joinpath(out, "agent", "agent.json"))

    # core method without DataVault loaded would error; here the ext is loaded, so the typed
    # method wins. A non-vault first arg still hits the core fallback error:
    @test_throws ErrorException Pinax.report(42, recipe; title="x", out=joinpath(tmp, "z"))
end
