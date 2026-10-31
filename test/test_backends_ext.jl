using Pinax
using Test
using Plots: Plots

# A fake backend figure that exercises the is_figure / pinax_save extension contract without a
# real backend, so the contract is covered on every shard rather than only where a backend loads.
# The shipped extensions (ext/PinaxPlotsExt.jl, ext/PinaxMakieExt.jl) plug in exactly the same way;
# `test_readme.jl` loads the Plots one for real when it runs the README's Quickstart.
struct MockFig
    tag::String
end
Pinax.is_figure(::MockFig) = true
function Pinax.pinax_save(f::MockFig, base, fmt)
    return Pinax._save_with(
        (obj, dest) -> write(dest, "MOCK:$(obj.tag):$(fmt)"), f, base, fmt
    )
end
# a mock plot exposes its plotted data, exercising the `:table` pseudo-format without a real backend
function Pinax._figure_table(::MockFig)
    return (;
        xlabel="t",
        ylabel="v",
        series=[(; label="s1", x=[0.0, 1.0, 2.0], y=[10.0, 11.0, 12.0])],
    )
end

_has_parse_error(ex) = ex isa Expr && (ex.head === :error || any(_has_parse_error, ex.args))

@testset "backend extension contract" begin
    tmp = mktempdir()

    @testset "figure object -> pinax_save per requested format" begin
        fig = Pinax.Figure(
            :f, "f", "", nothing, () -> MockFig("z"), "code", false, String[], nothing
        )
        base = joinpath(tmp, "m", "f")
        out = Pinax._materialize(fig, base, [:svg, :pdf])
        @test out == [string(base, ".svg"), string(base, ".pdf")]
        @test read(out[1], String) == "MOCK:z:svg"
        @test read(out[2], String) == "MOCK:z:pdf"
    end

    @testset "renders a backend figure into the gallery" begin
        outdir = joinpath(tmp, "site")
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure MockFig("a") caption = "mock" id = :s_fig1
            end
        end
        html = read(Pinax.render(; out=outdir), String)
        @test isfile(joinpath(outdir, "assets", "figures", "p", "s", "s_fig1.svg"))
        @test occursin("s_fig1.svg", html)
        @test occursin("mock", html)
    end

    @testset "unknown value still errors (no pinax_save method)" begin
        @test_throws ErrorException Pinax.pinax_save(42, "x", :svg)
    end

    @testset "is_figure dispatch (default false, override true)" begin
        @test Pinax.is_figure(MockFig("x"))
        @test !Pinax.is_figure(42)
        @test !Pinax.is_figure("a/path.svg")
    end

    @testset "_materialize errors on a non-file, non-figure value" begin
        fig = Pinax.Figure(
            :bad, "bad", "", nothing, () -> 42, "code", false, String[], nothing
        )
        @test_throws ErrorException Pinax._materialize(fig, joinpath(tmp, "bad"), [:svg])
    end

    @testset "_save_with errors when the saver writes no file" begin
        @test_throws ErrorException Pinax._save_with(
            (obj, dest) -> nothing, MockFig("x"), joinpath(tmp, "noop"), :svg
        )
    end

    @testset "shipped extension files are present and parse cleanly" begin
        for f in ("PinaxPlotsExt.jl", "PinaxMakieExt.jl")
            path = joinpath(pkgdir(Pinax), "ext", f)
            @test isfile(path)
            @test !_has_parse_error(Meta.parseall(read(path, String); filename=f))
        end
    end
end

# A figure's data file holds every plotted point and the agent face points at it, describing it
# exactly; nothing is inlined as a cut copy (Conventions › The agent face).
@testset "figure data file: every point, described exactly" begin
    tmp = mktempdir()

    @testset ":table pseudo-format writes every point, columns named by the axes" begin
        fig = Pinax.Figure(
            :f, "f", "", nothing, () -> MockFig("z"), "code", false, String[], nothing
        )
        base = joinpath(tmp, "f")
        out = Pinax._materialize(fig, base, [:svg, :table])
        @test out == [string(base, ".svg"), string(base, ".csv")]   # image + data file
        @test read(out[2], String) == "series,t,v\ns1,0.0,10.0\ns1,1.0,11.0\ns1,2.0,12.0\n"
    end

    @testset "a pre-made file path exposes no data (no csv)" begin
        src = joinpath(tmp, "p.svg")
        write(src, "<svg/>")
        fig = Pinax.Figure(:g, "g", "", nothing, () -> src, "c", false, String[], nothing)
        out = Pinax._materialize(fig, joinpath(tmp, "g"), [:svg, :table])
        @test all(p -> !endswith(p, ".csv"), out)
    end

    @testset "a dense series is written whole, never cut" begin
        io = IOBuffer()
        ys = [i == 373 ? 999.0 : 1.0 for i in 1:5000]
        Pinax._print_csv_table(
            io, (; xlabel="", ylabel="", series=[(; label="a", x=collect(1.0:5000), y=ys)])
        )
        s = String(take!(io))
        @test startswith(s, "series,x,y\n")   # unlabelled axes fall back to x / y
        @test count('\n', s) == 5001
        @test occursin("a,373.0,999.0", s)
    end

    @testset "the agent face points at the data file and describes it" begin
        out = joinpath(tmp, "agent")
        Pinax.reset!(; title="d")
        @page :p "P" begin
            @figure MockFig("a") caption = "m"
        end
        j = read(Pinax.render(; out=out, theme=:agent), String)
        @test occursin(r"\"data\":\{\"path\":\"assets/figures/p/[^\"]+\.csv\"", j)
        @test occursin(
            "\"columns\":[\"series\",\"t\",\"v\"],\"series\":[{\"label\":\"s1\",\"points\":3}]",
            j,
        )
        @test !occursin("\"table\":", j)
        md = read(joinpath(out, "agent.md"), String)
        @test occursin(
            r"- data: assets/figures/p/\S+\.csv — columns: series, t, v; s1 \(3 points\)",
            md,
        )
        @test !occursin("| series |", md)
    end

    @testset "_data_descriptor: columns and per-series counts, in order" begin
        csv = joinpath(tmp, "t.csv")
        write(csv, "series,x,y\n\"a,b\",0.0,1.5\nc,2.0,3.0\nc,3.0,4.0\n")
        d = Pinax._data_descriptor(csv)
        @test d.columns == ["series", "x", "y"]
        @test d.series == ["a,b" => 1, "c" => 2]   # a quoted comma stays in the label
        @test Pinax._data_descriptor(joinpath(tmp, "missing.csv")) === nothing
    end

    @testset "csv round-trip edge cases" begin
        @test Pinax._split_csv_line("a,b,") == ["a", "b", ""]                       # trailing empty field
        @test Pinax._split_csv_line("a,,c") == ["a", "", "c"]                       # empty middle field
        @test Pinax._split_csv_line("\"x,y\",z") == ["x,y", "z"]                    # quoted comma
        @test Pinax._split_csv_line("\"say \"\"hi\"\"\",z") == ["say \"hi\"", "z"]  # escaped quote
        @test !occursin('\n', Pinax._csv_field("a\nb"))   # writer flattens newlines (no line-spanning field)
    end
end

# `@figure … data=` carries the plotted data eagerly, so the agent face writes the figure's data file
# from it WITHOUT calling gen() — agent.json is producible with no plotting backend. We prove gen is
# never called by making it throw; render(:agent) must still succeed.
@testset "figure data=: the data file without building the plot (Plots-free LLM face)" begin
    tmp = mktempdir()
    Pinax.reset!(; title="d")
    @page :p "P" begin
        @figure error("gen must not run for a data= figure") data = (
            x=[1.0, 2.0, 3.0], y=[10.0, 20.0, 30.0]
        ) caption = "f" id = :f
    end
    out = joinpath(tmp, "agent")
    j = read(Pinax.render(; out=out, theme=:agent), String)   # must NOT throw (gen skipped)
    @test occursin("\"assets\":[]", j)                         # never materialized → no image
    @test occursin("\"data\":{\"path\":\"assets/figures/p/f.csv\"", j)
    @test read(joinpath(out, "assets", "figures", "p", "f.csv"), String) ==
        "series,x,y\ny,1.0,10.0\ny,2.0,20.0\ny,3.0,30.0\n"
    md = read(joinpath(out, "agent.md"), String)
    @test occursin("- image: none", md)

    # several series, and axis labels name the columns
    Pinax.reset!(; title="d2")
    @page :q "Q" begin
        @figure error("no gen") data = (;
            xlabel="N",
            ylabel="gap",
            series=[(; label="a", x=[0, 1], y=[2, 3]), (; label="b", x=[0, 1], y=[4, 5])],
        ) id = :g
    end
    out2 = joinpath(tmp, "a2")
    Pinax.render(; out=out2, theme=:agent)
    @test read(joinpath(out2, "assets", "figures", "q", "g.csv"), String) ==
        "series,N,gap\na,0,2\na,1,3\nb,0,4\nb,1,5\n"
end

@testset "the Plots extension: a figure's data is its points, or none" begin
    # a line is a list of points; a heatmap is a grid (x and y differ in length, z holds the
    # values), which a points file cannot hold — so it has no data form, and the agent face says so
    line = Pinax._figure_table(Plots.plot([1, 2, 3], [4.0, 5.0, 6.0]; label="L"))
    @test only(line.series).label == "L" && only(line.series).y == [4.0, 5.0, 6.0]
    @test Pinax._figure_table(Plots.heatmap(1:4, 1:3, rand(3, 4))) === nothing
end
