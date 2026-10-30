using Pinax
using Test
using ParamIO

@testset "ParamIO lineage: param-derived ids + canonical cache key" begin
    tmp = mktempdir()
    svg = joinpath(tmp, "a.svg")
    write(svg, "<svg xmlns='http://www.w3.org/2000/svg'><rect/></svg>")

    kA = ParamIO.DataKey(Dict{String,Any}("system.N" => 8, "system.g" => 0.5), 0)
    kA2 = ParamIO.DataKey(Dict{String,Any}("system.g" => 0.5, "system.N" => 8), 0)  # same params, reordered
    kB = ParamIO.DataKey(Dict{String,Any}("system.N" => 16, "system.g" => 0.5), 0)

    @testset "id is derived from params (not positional), order-independent" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure svg params = kA
                @figure svg params = kB
            end
        end
        figs = Pinax.current_document().pages[1].sections[1].figures
        # generated: the container id plus a hash of the code and the key's canonical form
        @test startswith(String(figs[1].id), "s_fig_")
        @test figs[1].id !== figs[2].id              # different params -> different id

        # same params in a different insertion order -> same canonical -> same id
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure svg params = kA2
            end
        end
        @test Pinax.current_document().pages[1].sections[1].figures[1].id === figs[1].id
    end

    @testset "ids stay put when figures are reordered" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure svg params = kA
                @figure svg params = kB
            end
        end
        ab = [f.id for f in Pinax.current_document().pages[1].sections[1].figures]
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure svg params = kB
                @figure svg params = kA
            end
        end
        ba = [f.id for f in Pinax.current_document().pages[1].sections[1].figures]
        @test Set(ab) == Set(ba)                     # same id set regardless of order
        @test ab[1] === ba[2]                        # kA's id is identical in both layouts
    end

    @testset "explicit id wins; non-DataKey params hash their repr" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure svg params = (N=8,)          # NamedTuple, not a DataKey
                @figure svg id = :custom params = kA # explicit id wins
            end
        end
        figs = Pinax.current_document().pages[1].sections[1].figures
        @test startswith(String(figs[1].id), "s_fig_")  # non-DataKey -> its repr is hashed
        @test figs[2].id === :custom                 # explicit id wins over params
    end

    @testset "cache key uses canonical params (reordered params -> cache hit)" begin
        cnt = Ref(0)
        outdir = joinpath(tmp, "canon")
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure begin
                    cnt[] += 1
                    svg
                end params = kA
            end
        end
        Pinax.render(; out=outdir)
        @test cnt[] == 1
        # rebuild with the SAME params in a different insertion order: canonical equal -> hit
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure begin
                    cnt[] += 1
                    svg
                end params = kA2
            end
        end
        Pinax.render(; out=outdir)
        @test cnt[] == 1                             # cache hit: gen NOT called again
    end
end
