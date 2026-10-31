using Pinax
using Test

@testset "incremental render cache" begin
    tmp = mktempdir()
    svg1 = joinpath(tmp, "a.svg")
    write(svg1, "<svg xmlns='http://www.w3.org/2000/svg'><rect/></svg>")
    svg2 = joinpath(tmp, "b.svg")
    write(svg2, "<svg xmlns='http://www.w3.org/2000/svg'><circle/></svg>")

    @testset "cache hit skips gen()" begin
        cnt = Ref(0)
        outdir = joinpath(tmp, "hit")
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure begin
                    cnt[] += 1
                    svg1
                end
            end
        end
        Pinax.render(; out=outdir)
        @test cnt[] == 1                      # materialized once
        @test isfile(joinpath(outdir, ".pinax-manifest.toml"))
        Pinax.render(; out=outdir)            # same doc + outdir -> key unchanged, asset present
        @test cnt[] == 1                      # cache hit: gen NOT called again
    end

    @testset "force re-materializes" begin
        cnt = Ref(0)
        outdir = joinpath(tmp, "force")
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure begin
                    cnt[] += 1
                    svg1
                end
            end
        end
        Pinax.render(; out=outdir)
        @test cnt[] == 1
        Pinax.render(; out=outdir, force=true)
        @test cnt[] == 2                      # force bypasses the cache
    end

    @testset "changed @figure code -> cache miss" begin
        cnt = Ref(0)
        outdir = joinpath(tmp, "codechange")
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure begin
                    cnt[] += 1
                    svg1
                end
            end
        end
        Pinax.render(; out=outdir)
        @test cnt[] == 1
        # rebuild with different code at the same figure position (same anchor, different key)
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure begin
                    cnt[] += 10
                    svg2
                end
            end
        end
        Pinax.render(; out=outdir)
        @test cnt[] == 11                     # miss: gen called again
    end

    @testset "orphan asset removed on re-render" begin
        outdir = joinpath(tmp, "orphan")
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure svg1 id = :s_fig1
                @figure svg2 id = :s_fig2
            end
        end
        Pinax.render(; out=outdir)
        a1 = joinpath(outdir, "assets", "figures", "p", "s", "s_fig1.svg")
        a2 = joinpath(outdir, "assets", "figures", "p", "s", "s_fig2.svg")
        @test isfile(a1)
        @test isfile(a2)
        # rebuild with only the first figure -> the second figure's asset is now an orphan
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure svg1 id = :s_fig1
            end
        end
        Pinax.render(; out=outdir)
        @test isfile(a1)                      # still referenced
        @test !isfile(a2)                     # orphan cleaned up
    end
end

@testset "a corrupt render manifest is a warning, and the render rebuilds it" begin
    tmp = mktempdir()
    svg = joinpath(tmp, "a.svg")
    write(svg, "<svg xmlns='http://www.w3.org/2000/svg'/>")
    out = joinpath(tmp, "site")
    mkpath(out)
    write(joinpath(out, Pinax.MANIFEST_FILE), "this is = = not toml [")
    @test_logs (:warn, r"manifest.*not valid TOML") Pinax.rendered_assets(out)
    Pinax.reset!()
    @page :p "P" begin
        @figure svg id = :f
    end
    @test_logs (:warn, r"manifest") match_mode = :any Pinax.render(; out=out)
    # the derived cache is rebuilt: the next read sees this render's assets, without a warning
    @test (@test_logs Pinax.rendered_assets(out)) == ["assets/figures/p/f.svg"]
end
