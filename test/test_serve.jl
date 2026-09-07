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
function _raw_get(port, target; timeout=10)
    sock = Pinax.Sockets.connect("127.0.0.1", port)
    try
        write(
            sock, "GET $(target) HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
        )
        # `read` returns when the server closes the connection. The timer is the only thing that
        # bounds it: TestShards runs a whole shard in one process, so a hang here would stall every
        # file after this one and surface as a silent CI timeout rather than a red test.
        t = Timer(_ -> close(sock), timeout)
        try
            return read(sock, String)
        finally
            close(t)
        end
    finally
        close(sock)
    end
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

        # A symlink INSIDE the root pointing out of it: every path component of the target is still
        # under the root, so the component test cannot see this one. No `..` is involved, and the
        # request is ordinary — it is `realpath` that has to catch it.
        if !Sys.iswindows()                     # creating a symlink there needs privileges
            symlink(
                joinpath(tmp, "gallery-secrets", "secret.txt"), joinpath(root, "escape")
            )
            resp = _raw_get(h.port, "/escape")
            @test occursin("403 Forbidden", resp)
            @test !occursin("TOP SECRET", resp)
        end
    finally
        close(h.server)
    end
end

@testset "serve: a symlink that stays inside the root is still served" begin
    # The control for the test above: `realpath` must not refuse an ordinary link, or the guard
    # would be passing by refusing everything.
    tmp = mktempdir()
    root = joinpath(tmp, "gallery")
    mkpath(joinpath(root, "real"))
    write(joinpath(root, "index.html"), "<html>ok</html>")
    write(joinpath(root, "real", "asset.txt"), "INSIDE THE ROOT")

    h = Pinax.serve(root; host="127.0.0.1", blocking=false, port=8139)
    try
        if !Sys.iswindows()
            symlink(joinpath(root, "real", "asset.txt"), joinpath(root, "link.txt"))
            resp = _raw_get(h.port, "/link.txt")
            @test occursin("200 OK", resp)
            @test occursin("INSIDE THE ROOT", resp)
        end
    finally
        close(h.server)
    end
end
