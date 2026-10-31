using Pinax
using Test

# Identity (Conventions › Identity). Every id is unique in the whole document and is the node's only
# name — its anchor, comment key and agent.json address. An id the author writes is never renamed, so
# a collision is an error where the second node is written. An id Pinax generates is the container's
# id plus a short stable hash of the node's content, so inserting a node never renames another; the
# same content twice in one container gets `-2`.

mutable struct _IdentIso <: Test.AbstractTestSet
    description::String
    results::Vector{Any}
    _IdentIso(desc::AbstractString=""; kw...) = new(String(desc), Any[])
end
Test.record(r::_IdentIso, x) = (push!(r.results, x); x)
Test.finish(r::_IdentIso) = r

_pg() = Pinax.current_document().pages[1]
_sec(id) = only(s for s in Pinax._all_sections(_pg()) if s.id === id)

@testset "identity" begin
    @testset "an author's id is unique in the whole document, across kinds" begin
        Pinax.reset!()
        @page :p "A" begin end
        @test_throws "duplicate id :p" @page :p "B" begin end
        @test length(Pinax.current_document().pages) == 1

        Pinax.reset!()
        @part :g "G" begin end
        @test_throws "duplicate id :g" @part :g "G again" begin end

        Pinax.reset!()
        @test_throws "duplicate id :x" @page :p "A" begin
            @section :a "A" begin
                @section :x "X" begin end
            end
            @section :b "B" begin
                @section :x "X" begin end   # another parent, the same name: still one document
            end
        end

        Pinax.reset!()
        @test_throws "duplicate id :f" @page :p "A" begin
            @section :a "A" begin
                @figure 1 id = :f
            end
            @section :b "B" begin
                @figure 2 id = :f
            end
        end

        Pinax.reset!()
        @test_throws "duplicate id :energy" @page :energy "Energy" begin
            @table (a=[1],) id = :energy             # a table may not take a page's id
        end
    end

    @testset "the id is the anchor: no second naming scheme" begin
        Pinax.reset!()
        @page :p "A" begin
            @section :a "A" begin
                @section :b "B" begin
                    @figure 1 id = :f
                end
            end
        end
        @test _sec(:b).anchor == "b"
        @test only(_sec(:b).figures).anchor == "f"
    end

    @testset "ids are Symbols" begin
        Pinax.reset!()
        @test_throws "Symbol" @page :p "A" begin
            @table (a=[1],) id = "t"
        end
        Pinax.reset!()
        @test_throws "Symbol" @page :p "A" begin
            @code y = 1 id = "c"
        end
    end

    @testset "a generated id hashes the node's content, so inserting a node renames nothing" begin
        build(extra) = begin
            Pinax.reset!()
            @page :p "A" begin
                extra && @figure 0
                extra && @table (z=[0],)
                extra && @code w = 0
                @figure 1
                @table (a=[1],)
                @code y = 1
            end
            pg = _pg()
            (last(pg.figures).id, last(pg.tables).id, last(pg.codes).id)
        end
        before, after = build(false), build(true)
        @test before == after
        f, t, c = before
        @test startswith(string(f), "p_fig_")
        @test startswith(string(t), "p_tbl_")
        @test startswith(string(c), "p_code_")
    end

    @testset "the same content twice in one container gets -2; a generated id never errors" begin
        Pinax.reset!()
        @page :p "A" begin
            for _ in 1:2
                @figure 1
            end
        end
        a, b = (f.id for f in _pg().figures)
        @test string(b) == string(a, "-2")
    end

    @testset "a nested @testset's section id is its container's id plus the description" begin
        Pinax.reset!()
        @testset _IdentIso "iso" begin
            @page :p "A" begin
                for _ in 1:2
                    @testset "conv" begin
                        @test true
                    end
                end
            end
        end
        @test [s.id for s in _pg().sections] == [:p_conv, Symbol("p_conv-2")]
    end

    # Julia 1.13 prints the symbols `end` / `begin` as `var"end"` / `var"begin"`; 1.12 prints them as
    # written. A label, a code string and every id hashed from them must not depend on that.
    @testset "end / begin read as written, so ids do not depend on the Julia version" begin
        @test Pinax._code_str(:(isapprox(Ms[end], 0.0; atol=0.1))) ==
            "isapprox(Ms[end], 0.0; atol = 0.1)"
        @test Pinax._code_str(:(a[begin:end])) == "a[begin:end]"
        Pinax.reset!()
        Ms = [1.0, 0.0]
        @testset _IdentIso "iso" begin
            @page :p "A" begin
                @test isapprox(Ms[end], 0.0; atol=0.1)
                @figure Ms[end] id = nothing
            end
        end
        @test only(_pg().checks).label == "isapprox(Ms[end], 0.0; atol = 0.1)"
        @test only(_pg().figures).code == "Ms[end]"
    end

    # Which ids the author wrote and which Pinax generated is data, not a guess from an id's shape:
    # `node_ids` lists every node — sections at any depth included — with its kind and that flag.
    @testset "node_ids: every node, its kind, and whether Pinax generated its id" begin
        Pinax.reset!()
        @testset _IdentIso "iso" begin
            @part :grp "G" begin
                @page :p "P" begin
                    @desc "prose"
                    @figure 1 id = :named
                    @figure 2
                    @section :s "S" begin
                        @section :deep "D" begin
                            @table (a=[1],) id = :tbl
                            @raw "<i>r</i>"
                        end
                        @testset "conv" begin
                            @test true
                        end
                    end
                end
            end
        end
        ns = Pinax.node_ids(Pinax.current_document())
        byid = Dict(n.id => n for n in ns)
        @test [n.id for n in ns][1:3] == [:grp, :p, first(_pg().texts).id]
        written = Set(n.id for n in ns if !n.generated)
        @test written == Set([:grp, :p, :named, :s, :deep, :tbl])
        @test byid[:deep].kind === :section && byid[:s_conv].kind === :section
        @test byid[:s_conv].generated   # a @testset's section id is generated
        @test count(n -> n.kind === :check, ns) == 1 &&
            all(n -> n.generated, filter(n -> n.kind === :check, ns))
        @test Set(n.kind for n in ns) ==
            Set([:part, :page, :text, :figure, :section, :table, :raw, :code, :check])
    end

    @testset "node_ids: a written id survives a shard dump; test-report pages are generated" begin
        n = Pinax.TestNode("test_x.jl")
        push!(
            n.tables,
            Pinax.Table(:mine, "mine", "", ["a"], Vector{Any}[Any[1]], "", nothing),
        )
        push!(n.content, :table => 1)
        push!(n.written, :mine)
        d = Pinax.dump_test_report(
            Pinax.TestNode("r"; children=[n]), joinpath(mktempdir(), "s.toml")
        )
        back = Pinax.load_test_dump(d)
        @test :mine in only(back.children).written
        Pinax.render_test_report(back; out=mktempdir())
        ns = Pinax.node_ids(Pinax.current_document())
        @test only(n for n in ns if n.id === :mine).generated == false
        @test all(n -> n.generated, filter(n -> n.kind in (:page, :section), ns))
    end

    # The anchor names a node's HTML id, its files and its cache entry, so two ids never share one.
    # An id of safe characters is its own anchor; any other id keeps a readable form plus a hash.
    @testset "anchors are unique: an id outside [A-Za-z0-9_-] gets a hashed anchor" begin
        @test Pinax._anchor(:energy_fig1) == "energy_fig1"
        @test Pinax._anchor(Symbol("p_fig-2")) == "p_fig-2"
        a, b = Pinax._anchor(:α_fig), Pinax._anchor(:β_fig)
        @test a != b && startswith(a, "__fig-") && occursin(r"^[A-Za-z0-9_-]+$", a)
        @test Pinax._anchor(:α_fig) == a   # stable

        tmp = mktempdir()
        svg = joinpath(tmp, "f.svg")
        write(svg, "<svg xmlns='http://www.w3.org/2000/svg'/>")
        Pinax.reset!()
        @page :p "P" begin
            @figure svg id = :α_fig
            @figure svg id = :β_fig
        end
        out = joinpath(tmp, "g")
        mkpath(out)
        cf = joinpath(out, "comments.toml")
        Pinax.add_comment(cf, :α_fig, "BY_ID"; author="me")        # the MCP / API writes the id
        Pinax.add_comment(cf, Symbol(b), "BY_ANCHOR"; author="me")  # the gallery writes the anchor
        Pinax.add_comment(cf, :β_fig, "ALSOBYID"; author="me")    # both keys: both turns kept
        html = read(Pinax.render(; out=out), String)
        html = replace(
            html,
            r"<script type=\"application/json\" id=\"pinax-committed\">.*?</script>"s => "",
        )
        @test isfile(joinpath(out, "assets", "figures", "p", a * ".svg"))
        @test isfile(joinpath(out, "assets", "figures", "p", b * ".svg"))
        @test occursin("BY_ID", html) &&
            occursin("BY_ANCHOR", html) &&
            occursin("ALSOBYID", html)
        @test !occursin("names no node", html)
        Pinax.render(; out=joinpath(tmp, "a"), theme=:agent, comments_file=cf)
        md = read(joinpath(tmp, "a", "agent.md"), String)
        @test occursin("BY_ID", md) && occursin("BY_ANCHOR", md)
    end
end
