using Pinax
using Test
using Downloads: Downloads

@testset "serve: static HTTP preview server" begin
    tmp = mktempdir()
    svg = joinpath(tmp, "a.svg")
    write(svg, "<svg xmlns='http://www.w3.org/2000/svg'><rect/></svg>")
    Pinax.reset!()
    @page :p "P" begin
        @section :s "S" begin
            @figure svg
        end
    end
    out = joinpath(tmp, "site")
    Pinax.render(; out=out)

    h = Pinax.serve(out; blocking=false, port=8137)
    try
        # index.html served at /
        idx = joinpath(tmp, "got.html")
        Downloads.download(h.url, idx)
        body = read(idx, String)
        @test occursin("<section class=\"section\"", body)
        @test occursin("id=\"s\"", body)

        # an asset (the copied figure) is served too
        a = joinpath(tmp, "got.svg")
        Downloads.download(h.url * "assets/figures/p/s/s_fig1.svg", a)
        @test occursin("<svg", read(a, String))

        # a missing path -> HTTP 404 (Downloads throws on >=400)
        @test_throws Downloads.RequestError Downloads.download(
            h.url * "nope.bin", joinpath(tmp, "x")
        )
    finally
        close(h.server)
    end
end
