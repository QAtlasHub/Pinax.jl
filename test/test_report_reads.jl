using Pinax
using Test
using DataVault: DataVault
using ParamIO: ParamIO
using TOML: TOML

# report(vault, recipe) reads each result through DataVault.load_recorded: it returns what it read,
# observes the render process's sources, and keys the figure cache on the bytes it read.

function report_reads_vault(tmp)
    cfg = joinpath(tmp, "config.toml")
    write(
        cfg,
        """
        [study]
        project_name = "reads"
        total_samples = 1
        outdir = "$(joinpath(tmp, "vault"))"
        [datavault]
        path_keys = ["system.N"]
        [[paramsets]]
        [paramsets.system]
        N = [8, 16]
        """,
    )
    return cfg
end

function save_done!(vault, key, value)
    saved = DataVault.save!(vault, key, Dict("val" => value))
    DataVault.mark_done!(vault, key; result=saved)
    return saved
end

@testset "report: reads, render observation, and a cache keyed on the bytes read" begin
    tmp = mktempdir()
    cfg = report_reads_vault(tmp)
    vault = DataVault.Vault(cfg; run="phase1")
    keys = ParamIO.expand(ParamIO.load(cfg))
    for k in keys
        save_done!(vault, k, float(k.params["system.N"]))
    end

    calls = Ref(0)
    svg = joinpath(tmp, "fig.svg")
    recipe = function (pairs)
        @page :p "P" begin
            @section :s "S" begin
                @figure params = first(pairs)[1] begin
                    calls[] += 1
                    write(svg, "<svg xmlns='http://www.w3.org/2000/svg'><rect/></svg>")
                    svg
                end
            end
        end
    end
    out = joinpath(tmp, "rep")
    res = Pinax.report(vault, recipe; title="Reads", out=out)

    @test res.n == 2 && length(res.reads) == 2
    @test all(r -> r.read_sha256 == r.result_sha256, res.reads)
    @test Set(r.key for r in res.reads) == Set(ParamIO.canonical(k) for k in keys)
    @test res.render_observation isa String && startswith(res.render_observation, "obs1-")
    obs = joinpath(
        vault.outdir,
        ".datavault",
        "reads",
        "observations",
        "$(res.render_observation).toml",
    )
    @test TOML.parsefile(obs)["phase"] == "render"
    @test calls[] == 2                                  # gallery + agent each materialize once

    Pinax.report(vault, recipe; title="Reads", out=out)
    @test calls[] == 2                                  # same bytes: cache hit

    first_key = first(keys)
    sleep(1.1)
    DataVault.mark_done!(
        vault,
        first_key;
        result=(;
            file=DataVault._data_file(vault, first_key),
            sha256=res.reads[findfirst(
                r -> r.key == ParamIO.canonical(first_key), res.reads
            )].read_sha256,
        ),
    )
    Pinax.report(vault, recipe; title="Reads", out=out)
    @test calls[] == 2                                  # the marker alone changed: still a hit

    save_done!(vault, first_key, -1.0)                  # the data's bytes change
    Pinax.report(vault, recipe; title="Reads", out=out)
    @test calls[] == 4                                  # re-materialized, in both faces
end

@testset "report: no render observation with observe=false or a readonly vault" begin
    tmp = mktempdir()
    cfg = report_reads_vault(tmp)
    vault = DataVault.Vault(cfg; run="phase1")
    for k in ParamIO.expand(ParamIO.load(cfg))
        save_done!(vault, k, 1.0)
    end
    recipe = pairs -> (@page :p "P" begin
        @desc md"no figures"
    end)
    @test Pinax.report(vault, recipe; title="R", out=joinpath(tmp, "a"), observe=false).render_observation ===
        nothing
    ro = DataVault.Vault(cfg; run="phase1", readonly=true)
    @test Pinax.report(ro, recipe; title="R", out=joinpath(tmp, "b")).render_observation ===
        nothing
end
