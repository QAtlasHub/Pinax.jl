using Pinax
using Test
using Test: DefaultTestSet   # explicit stock context for report-off (inert) assertions

const SIDE = Ref(0)   # for checking @figure deferral

@testset "document model (structure pass)" begin
    @testset "tree shape" begin
        Pinax.reset!()
        @page :eq "Thermal Equilibrium" begin
            @section :energy "Energy vs T" begin
                @desc md"intent $E=\langle H\rangle$"
                @figure 1 + 1
                @figure 2 + 2
            end
            @section :conv "Convergence" by = "system.g" begin
                @figure 3 + 3
            end
        end
        doc = Pinax.current_document()
        @test length(doc.pages) == 1
        pg = doc.pages[1]
        @test pg.id === :eq
        @test pg.title == "Thermal Equilibrium"
        @test pg.anchor == "eq"
        @test length(pg.sections) == 2
        @test pg.sections[1].id === :energy
        @test pg.sections[2].id === :conv
        @test length(pg.sections[1].figures) == 2
        @test length(pg.sections[2].figures) == 1
        @test pg.sections[2].facet == "system.g"
        @test occursin("langle", only(pg.sections[1].texts).source)   # @desc: a prose block
    end

    @testset "@figure is deferred" begin
        SIDE[] = 0
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure begin
                    SIDE[] += 1
                    42
                end
            end
        end
        fig = Pinax.current_document().pages[1].sections[1].figures[1]
        @test SIDE[] == 0                 # build did NOT evaluate the plot expr
        @test fig.gen() == 42             # materialize on demand
        @test SIDE[] == 1                 # side effect ran exactly once
        @test occursin("42", fig.code)    # source captured for change detection
    end

    @testset "ids: auto vs explicit" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure 1
                @figure 2 id = :custom
            end
        end
        figs = Pinax.current_document().pages[1].sections[1].figures
        @test startswith(string(figs[1].id), "s_fig_")   # container id + a hash of its code
        @test figs[1].anchor == string(figs[1].id)        # the id is the anchor
        @test figs[2].id === :custom
    end

    @testset "params lineage" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure 1 params = (N=8, g=0.5)
            end
        end
        fig = Pinax.current_document().pages[1].sections[1].figures[1]
        @test fig.params == (N=8, g=0.5)
    end

    @testset "caption: one per node, from caption= or @caption" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure 1
                @caption md"from the macro"
                @figure 2 caption = "from the keyword"
            end
        end
        figs = Pinax.current_document().pages[1].sections[1].figures
        @test figs[1].caption == "from the macro"
        @test figs[2].caption == "from the keyword"
        Pinax.reset!()
        @test_throws "already has a caption" @page :p "P" begin
            @figure 1 caption = "kw"
            @caption md"a second caption"
        end

        # @caption names the node IMMEDIATELY before it — never an earlier figure (#159)
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure 1
                @caption "fig a"
                @table (x=[1], y=[2])
                @caption "the table"
                @code E = 1.0 + 1.0
                @caption "the energy"
            end
        end
        sec = Pinax.current_document().pages[1].sections[1]
        @test sec.figures[1].caption == "fig a"      # not overwritten by the table's caption
        @test sec.tables[1].caption == "the table"
        @test sec.codes[1].caption == "the energy"

        # nothing before it, or a node that carries no caption, is an error where it is written
        Pinax.reset!()
        @test_throws "nothing before it" @page :p "P" begin
            @section :s "S" begin
                @caption md"orphan"
            end
        end
        Pinax.reset!()
        @test_throws "carries no caption" @page :p "P" begin
            @figure 1
            @raw "<b>x</b>"
            @caption "meant for the figure"
        end
        Pinax.reset!()
        @test_throws "carries no caption" @page :p "P" begin
            @figure 1
            @section :s "S" begin end
            @caption "never reaches back past the section to the figure"
        end
        @test Pinax.current_document().pages[1].figures[1].caption == ""
        Pinax.reset!()
        @test_throws "carries no caption" @page :p "P" begin
            @section :s "S" begin
                @figure 1
                @section :t "T" begin end
                @caption "nor past a nested one"
            end
        end
    end

    @testset "thumbnail resolution (explicit > marker > top > none)" begin
        Pinax.reset!()
        @page :a "A" begin
            @thumbnail :picked
            @section :sa "S" begin
                @figure 1
            end
        end
        @page :b "B" begin
            @section :sb "S" begin
                @figure 1
                @figure 2 thumbnail = true
            end
        end
        @page :c "C" begin
            @section :sc "S" begin
                @figure 1
                @figure 2
            end
        end
        @page :d "D" begin
            @no_thumbnail
            @section :sd "S" begin
                @figure 1
            end
        end
        pgs = Pinax.current_document().pages
        @test Pinax.resolved_thumbnail(pgs[1]) == Pinax.FigRef(:picked)      # explicit
        @test Pinax.resolved_thumbnail(pgs[2]) ==
            Pinax.FigRef(pgs[2].sections[1].figures[2].id)  # marker
        @test Pinax.resolved_thumbnail(pgs[3]) ==
            Pinax.FigRef(pgs[3].sections[1].figures[1].id)  # top
        @test Pinax.resolved_thumbnail(pgs[4]) === nothing                    # @no_thumbnail
    end

    @testset "section kwargs: summary, layout" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" summary = "blurb" layout = :wide begin
                @figure 1
            end
        end
        sec = Pinax.current_document().pages[1].sections[1]
        @test sec.summary == "blurb"
        @test sec.layout === :wide
    end

    @testset "preamble: @pinaxsetup / @bibliography / @newcommand" begin
        Pinax.reset!()
        @pinaxsetup theme = :gallery debug = true numbering = :page index = :rich
        m = Pinax.current_document().meta
        @test m.theme === :gallery
        @test m.debug
        @test m.numbering === :page
        @test m.index === :rich

        # theme-specific kw (css/js/features) are ignored in the structure layer (not an error)
        @pinaxsetup theme = :gallery css = ["x.css"] js = ["y.js"] features = (:comments,)
        @test Pinax.current_document().meta.theme === :gallery

        Pinax.reset!()
        @bibliography "a.bib" "b.bib"
        @test Pinax.current_document().meta.bib_sources == ["a.bib", "b.bib"]

        Pinax.reset!()
        @newcommand raw"\E" raw"\langle H\rangle"
        @test Pinax.current_document().newcommands[raw"\E"] == raw"\langle H\rangle"
    end

    @testset "md\"…\" preserves \$ and backslash" begin
        s = md"E = $H$ and \alpha"
        @test s == raw"E = $H$ and \alpha"
    end

    @testset "document() do-block isolates global state" begin
        Pinax.reset!()
        outer = Pinax.current_document()
        doc = Pinax.document() do
            @page :scoped "S" begin
                @section :s "S" begin
                    @figure 1
                end
            end
        end
        @test length(doc.pages) == 1
        @test doc.pages[1].id === :scoped
        @test Pinax.current_document() === outer   # global state restored
    end

    @testset DefaultTestSet "misuse errors" begin
        # Inside a testset, a content macro with no container open is invariant-V test-content: it
        # no-ops (returns nothing, adds nothing) rather than erroring, so a bare `Pkg.test()` with a
        # stray `@figure` in a test can never break. The manuscript-misuse error still fires at depth
        # 0 — a docs build script — where the content seam is not inert.
        Pinax.reset!()
        @test (@figure 1) === nothing                         # @figure outside @section → inert no-op
        @test isempty(Pinax.current_document().pages)         # …and nothing was added
        # A structure macro resolves against CTX directly (not the content seam), so it still errors.
        Pinax.reset!()
        @test_throws ErrorException (@section :s "S" begin
            @figure 1
        end)                                                  # @section outside @page
    end

    @testset DefaultTestSet "@pinaxsetup refuses a keyword it cannot honour" begin
        # A setting that is accepted and then ignored is the defect this gate exists for: the caller
        # believes they configured something. Each of these used to be silently dropped.
        @test_throws ErrorException Pinax.reset!(; format=[:svg, :pdf])   # removed knob, by name
        @test_throws ErrorException Pinax.reset!(; fromat=[:svg])         # a typo of it
        @test_throws ErrorException Pinax.reset!(; bib_sources=["x.bib"]) # @bibliography's job
        @test_throws ErrorException Pinax.reset!(; numbering=:pge)        # value outside the domain
        @test_throws ErrorException Pinax.reset!(; katex=:locale)
        # …and the settings it does take still go through, so the gate is not refusing everything.
        @test Pinax.reset!(; title="t", numbering=:part, katex=:local).meta.numbering ===
            :part
        @test Pinax.reset!(; katex=:local).meta.katex === :local
        Pinax.reset!()
    end
end
