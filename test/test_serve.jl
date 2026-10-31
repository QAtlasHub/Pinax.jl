using Pinax
using Test
using Downloads: Downloads
using Logging: Logging

@testset "serve: static HTTP preview server" begin
    tmp = mktempdir()
    svg = joinpath(tmp, "a.svg")
    write(svg, "<svg xmlns='http://www.w3.org/2000/svg'><rect/></svg>")
    Pinax.reset!()
    @page :p "P" begin
        @section :s "S" begin
            @figure svg id = :s_fig1
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

@testset "serve: a missing file is 404; a request with no request line gets no reply" begin
    root = mktempdir()
    write(joinpath(root, "index.html"), "<html>ok</html>")
    h = Pinax.serve(root; host="127.0.0.1", blocking=false, port=8158)
    try
        @test occursin("404 Not Found: nope.html", _raw_get(h.port, "/nope.html"))
        # a client that opens and sends only a blank line: the server closes it without a response
        sock = Pinax.Sockets.connect("127.0.0.1", h.port)
        write(sock, "\r\n")
        t = Timer(_ -> close(sock), 10)
        try
            @test isempty(read(sock, String))
        finally
            close(t)
        end
    finally
        close(h.server)
    end
end

# A connection that a test drives directly: the request is read from `req`, the response is written
# to `resp`. `_serve_handle` is called in the test's own task, so its log records can be checked.
struct _MockConn <: IO
    req::IOBuffer
    resp::IOBuffer
end
_MockConn(request::AbstractString) = _MockConn(IOBuffer(request), IOBuffer())
Base.eof(c::_MockConn) = eof(c.req)
Base.read(c::_MockConn, ::Type{UInt8}) = read(c.req, UInt8)
Base.unsafe_write(c::_MockConn, p::Ptr{UInt8}, n::UInt) = unsafe_write(c.resp, p, n)
Base.close(::_MockConn) = nothing

# A client that has gone away: writing to it fails as a closed socket does.
struct _GoneConn <: IO
    req::IOBuffer
end
Base.eof(c::_GoneConn) = eof(c.req)
Base.read(c::_GoneConn, ::Type{UInt8}) = read(c.req, UInt8)
function Base.unsafe_write(::_GoneConn, ::Ptr{UInt8}, ::UInt)
    return throw(Base.IOError("broken pipe", -32))
end
Base.close(::_GoneConn) = nothing

# The response `_serve_handle` writes for a GET of `target` with the given extra header lines.
function _handle(root, target, headers...)
    conn = _MockConn(join(["GET $(target) HTTP/1.1", headers..., "", ""], "\r\n"))
    Pinax._serve_handle(conn, root)
    return String(take!(conn.resp))
end

@testset "serve: byte ranges" begin
    root = mktempdir()
    write(joinpath(root, "f.bin"), "0123456789")
    write(joinpath(root, "empty.bin"), "")
    range(r) = _handle(root, "/f.bin", "Range: bytes=$(r)")

    r = range("2-4")
    @test startswith(r, "HTTP/1.1 206 Partial Content\r\n")
    @test occursin("Content-Range: bytes 2-4/10\r\n", r) && endswith(r, "\r\n\r\n234")
    @test endswith(range("7-"), "\r\n\r\n789")
    @test endswith(range("8-99"), "\r\n\r\n89")                 # an end past the file is cut to it

    # a suffix range is the LAST n bytes
    r = range("-3")
    @test occursin("Content-Range: bytes 7-9/10\r\n", r) && endswith(r, "\r\n\r\n789")
    @test endswith(range("-99"), "\r\n\r\n0123456789")          # longer than the file: all of it

    # a range the file cannot satisfy is 416, naming the file's length
    for r in ("10-", "99999999999999999999-", "-0")
        resp = range(r)
        @test startswith(resp, "HTTP/1.1 416 Range Not Satisfiable\r\n")
        @test occursin("Content-Range: bytes */10\r\n", resp)
    end
    @test startswith(
        _handle(root, "/empty.bin", "Range: bytes=0-"), "HTTP/1.1 416 Range Not Satisfiable"
    )

    # a range this server does not read is ignored: the whole file, as without one
    for r in ("5-2", "-", "0-1,4-5")
        resp = range(r)
        @test startswith(resp, "HTTP/1.1 200 OK\r\n") &&
            endswith(resp, "\r\n\r\n0123456789")
    end
end

@testset "serve: a failure is a 500 and a warning; a client gone is neither" begin
    root = mktempdir()
    write(joinpath(root, "index.html"), "<html>ok</html>")
    # a NUL in the path is no file name the system accepts: the lookup throws an ArgumentError
    resp = @test_logs (:warn, r"Pinax.serve: .*/%00") match_mode = :any _handle(
        root, "/%00"
    )
    @test startswith(resp, "HTTP/1.1 500 Internal Server Error\r\n")
    # a client that went away before the response: nothing to answer, nothing to warn about
    gone = _GoneConn(IOBuffer("GET /index.html HTTP/1.1\r\n\r\n"))
    @test_logs min_level = Logging.Warn Pinax._serve_handle(gone, root)
    # a failure on a client that has also gone: still a warning, and the 500 it cannot receive is
    # let go rather than thrown out of the handler
    gone = _GoneConn(IOBuffer("GET /%00 HTTP/1.1\r\n\r\n"))
    @test_logs (:warn, r"Pinax.serve: .*/%00") match_mode = :any Pinax._serve_handle(
        gone, root
    )
    # every status the server sends has its own reason phrase; one it does not know is an error
    @test_throws KeyError Pinax._respond(IOBuffer(), 418, "text/plain", UInt8[])
end

@testset "serve: a busy port moves the server to the next one" begin
    root = mktempdir()
    write(joinpath(root, "index.html"), "<html>ok</html>")
    a = Pinax.serve(root; host="127.0.0.1", blocking=false, port=8160)
    try
        b = Pinax.serve(root; host="127.0.0.1", blocking=false, port=a.port)
        try
            @test b.port == a.port + 1
            @test occursin("200 OK", _raw_get(b.port, "/index.html"))
        finally
            close(b.server)
        end
    finally
        close(a.server)
    end
end
