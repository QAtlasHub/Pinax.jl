using Pinax
using Test

@testset "equations + KaTeX" begin
    tmp = mktempdir()
    site(n) = joinpath(tmp, n)
    svg = joinpath(tmp, "a.svg")
    write(svg, "<svg xmlns='http://www.w3.org/2000/svg'><rect/></svg>")

    @testset "KaTeX assets are included" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @desc md"text"
            end
        end
        html = read(Pinax.render(; out=site("k")), String)
        @test occursin("katex.min.css", html)
        @test occursin("auto-render.min.js", html)
        @test occursin("renderMathInElement", html)
    end

    @testset "display equation is numbered and wrapped" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @desc md"The energy is $$ E = \langle H \rangle $$ and more."
            end
        end
        html = read(Pinax.render(; out=site("eq1")), String)
        @test occursin("\\tag{1}", html)              # numbered for KaTeX
        @test occursin("\\langle H \\rangle", html)   # math content preserved
        @test occursin("class=\"pinax-eq\"", html)    # wrapped in an anchored span
    end

    @testset "@label + @ref to an equation (forward reference)" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @desc md"See @ref(:E). @label(:E) $$ a = b $$"
            end
        end
        html = read(Pinax.render(; out=site("eqref")), String)
        @test occursin("id=\"E\"", html)                 # equation anchored by its label
        @test occursin("<a href=\"#E\">(1)</a>", html)   # @ref resolves to the number, even forward
        @test !occursin("@label", html)                  # the @label token is consumed
    end

    @testset "multiple equations number sequentially" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @desc md"$$ x = 1 $$ then $$ y = 2 $$"
            end
        end
        html = read(Pinax.render(; out=site("eqmulti")), String)
        @test occursin("\\tag{1}", html)
        @test occursin("\\tag{2}", html)
    end

    @testset "inline math is left for KaTeX (not numbered)" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @desc md"inline $x^2$ here"
            end
        end
        html = read(Pinax.render(; out=site("inline")), String)
        @test occursin("\$x^2\$", html)   # single-$ survives for client-side KaTeX
        @test !occursin("\\tag", html)     # not numbered
    end

    @testset "equation numbering is preamble-overridable" begin
        nb(kind, c) = kind === :equation ? "Eq. $(c.equation)" : "Sec. $(c.section)"
        @pinaxsetup numberer = nb
        @page :p "P" begin
            @section :s "S" begin
                @desc md"see @ref(:e). @label(:e) $$ z = 0 $$"
            end
        end
        html = read(Pinax.render(; out=site("eqover")), String)
        @test occursin("<a href=\"#e\">Eq. 1</a>", html)   # overridden equation label in @ref
    end

    @testset "unlabeled equation gets an auto-anchor" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @desc md"$$ q = 1 $$"
            end
        end
        html = read(Pinax.render(; out=site("eqauto")), String)
        @test occursin("id=\"s_eq1\"", html)   # <section anchor>_eq<k>
    end

    @testset "equation in a figure caption is numbered" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @desc md"$$ A = 1 $$"               # eq 1 in the desc
                @figure svg
                @caption md"see $$ B = 2 $$"        # eq 2 in the caption
            end
        end
        html = read(Pinax.render(; out=site("eqcap")), String)
        @test occursin("\\tag{1}", html)
        @test occursin("\\tag{2}", html)
        @test count("class=\"pinax-eq\"", html) == 2
    end

    @testset "@ref to an equation in a later section (cross-node forward ref)" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :a "A" begin
                @desc md"see @ref(:E)."
            end
            @section :b "B" begin
                @desc md"@label(:E) $$ x = 0 $$"
            end
        end
        html = read(Pinax.render(; out=site("eqxref")), String)
        @test occursin("<a href=\"#E\">(1)</a>", html)
    end

    @testset "math with < / & is escaped (safe: KaTeX reads decoded textContent)" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @desc md"$$ a < b $$"
            end
        end
        html = read(Pinax.render(; out=site("eqesc")), String)
        @test occursin("a &lt; b", html)       # escaped in the serialized HTML...
        @test !occursin("\$\$ a < b", html)     # ...not raw (the HTML parser would mis-read `<`)
    end

    @testset "equation @label colliding with a section/figure id is diagnosed" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure svg id = :dup
                @desc md"@label(:dup) $$ y = 0 $$"
            end
        end
        html = read(Pinax.render(; out=site("eqdup")), String)
        @test occursin("collides with a section/figure id", html)
    end
end
