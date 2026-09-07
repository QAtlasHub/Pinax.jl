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

# Send a request line verbatim. `Downloads` (libcurl) collapses `..` in the target before the
# request leaves the client, so a download-based probe cannot reach the containment branch at all.
function _raw_get(port, target)
    sock = Pinax.Sockets.connect("127.0.0.1", port)
    write(sock, "GET $(target) HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
    resp = read(sock, String)
    close(sock)
    return resp
end

@testset "serve: containment is a path boundary, not a string prefix" begin
    # The layout that matters is a sibling whose name *extends* the served root — `out/` rendered
    # beside `out-draft/`, or a gallery beside the scratch directory it was built from.
    root = normpath(abspath(joinpath(mktempdir(), "gallery")))
    sibling = joinpath(dirname(root), "gallery-secrets", "secret.txt")

    @test startswith(sibling, root)                 # control: the string test accepts the sibling
    @test !Pinax._under_root(sibling, root)         # the path test does not
    @test Pinax._under_root(root, root)             # the root itself is inside it
    @test Pinax._under_root(joinpath(root, "assets", "a.svg"), root)
end

@testset "serve: a target that leaves the root is refused over HTTP" begin
    tmp = mktempdir()
    root = joinpath(tmp, "gallery")
    mkpath(root)
    write(joinpath(root, "index.html"), "<html>ok</html>")
    mkpath(joinpath(tmp, "gallery-secrets"))
    write(joinpath(tmp, "gallery-secrets", "secret.txt"), "TOP SECRET NEIGHBOUR CONTENT")

    h = Pinax.serve(root; host="127.0.0.1", blocking=false, port=8138)
    try
        ok = _raw_get(h.port, "/index.html")        # control: the server does serve its own root
        @test occursin("200 OK", ok)
        @test occursin("<html>ok</html>", ok)

        for target in
            ("/../gallery-secrets/secret.txt", "/..%2Fgallery-secrets%2Fsecret.txt")
            resp = _raw_get(h.port, target)
            @test occursin("403 Forbidden", resp)
            @test !occursin("TOP SECRET", resp)
        end
    finally
        close(h.server)
    end
end
