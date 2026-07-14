ENV["GKSwstype"] = "100"   # headless GR backend for compiling the example gallery

using Pinax
using Documenter
using Downloads
using Literate

const GALLERY_JL = joinpath(@__DIR__, "literate", "gallery.jl")

# The "Examples" page shows the gallery script's source verbatim (plain `julia` blocks, NOT
# executed). The gallery itself is compiled separately (below) and linked from the top of the page.
let
    link =
        "\n```@raw html\n<p style=\"margin:.4rem 0 1.2rem\"><a href=\"../gallery/\">" *
        "<b>▶ Open the compiled gallery</b></a> — a thumbnail index with one page per example.</p>\n```\n"
    add_link = function (content)
        i = findfirst('\n', content)
        return if i === nothing
            content * link
        else
            content[1:i] * link * content[(i + 1):end]
        end
    end
    Literate.markdown(
        GALLERY_JL,
        joinpath(@__DIR__, "src");
        name="examples",
        documenter=false,   # plain ```julia fences, not @example
        execute=false,      # do not run during page generation
        credit=false,
        postprocess=add_link,
    )
end

assets_dir = joinpath(@__DIR__, "src", "assets")
mkpath(assets_dir)
Downloads.download(
    "https://github.com/sotashimozono.png", joinpath(assets_dir, "favicon.ico")
)
Downloads.download("https://github.com/sotashimozono.png", joinpath(assets_dir, "logo.png"))

makedocs(;
    sitename="Pinax.jl",
    format=Documenter.HTML(;
        canonical="https://codes.sota-shimozono.com/Pinax.jl/stable/",
        prettyurls=get(ENV, "CI", "false") == "true",
        mathengine=MathJax3(
            Dict(
                :tex => Dict(
                    :inlineMath => [["\$", "\$"], ["\\(", "\\)"]],
                    :tags => "ams",
                    :packages => ["base", "ams", "autoload", "physics"],
                ),
            ),
        ),
        assets=["assets/favicon.ico", "assets/custom.css"],
    ),
    modules=[Pinax],
    pages=[
        "Home" => "index.md",
        "Examples" => "examples.md",
        "Comments" => "comments.md",
        "API Reference" => "api.md",
    ],
)

# Compile the gallery by RUNNING the script with the build directory as the working directory, so
# `render(out="gallery")` writes build/gallery/ (a multi-page gallery: index.html of thumbnail cards
# plus one HTML page per @page) for deploy. A fresh module keeps its definitions out of Main.
let build = joinpath(@__DIR__, "build")
    # Pull the precomputed heavy media (the Ising DataVault store + spin gif) off the `media` branch
    # so the gallery compile reuses it instead of re-running the Monte Carlo (the build-media workflow
    # keeps `media` up to date). Absent — e.g. media not built yet — the gallery computes it inline.
    try
        run(`git fetch --depth=1 origin media`)
        run(`git --work-tree=$build checkout FETCH_HEAD -- ising_data gallery_media`)
        run(`git reset -q`)   # keep the restored files in build/, drop them from the index
        @info "restored Ising media from the `media` branch"
    catch
        @info "no `media` branch — the gallery will compute the Ising example inline"
    end
    cd(build) do
        return Base.include(Module(:PinaxGallery), GALLERY_JL)
    end
end

# The TEST REPORT, grafted into the docs. Documenter deploys `build/` as-is, so this lands next to
# the manual at `<docs-url>/dev/tests/` (and `/stable/tests/`, and — because `push_preview=true` —
# at every PR's preview URL). No separate hosting, no separate versioning: the report of a release is
# the report that shipped with it.
#
# The dumps come off the `test-report` branch, which CI pushes after the suite runs — the same shape
# as the `media` branch above. That indirection is what lets a SHARDED run work: each shard dumps its
# own tree and renders nothing, and this single call merges them into one gallery whose pages are the
# test files, with the shard boundary invisible.
let build = joinpath(@__DIR__, "build")
    try
        dumps = mktempdir()
        run(`git fetch --depth=1 origin test-report`)
        run(`git --work-tree=$dumps checkout FETCH_HEAD -- .`)
        run(`git reset -q`)
        files = String[]
        for (root, _, fs) in walkdir(dumps), f in fs
            endswith(f, ".toml") && push!(files, joinpath(root, f))
        end
        isempty(files) && error("the test-report branch carries no dumps")
        Pinax.render_test_report(
            sort(files); out=joinpath(build, "tests"), title="Test report"
        )
        mv(joinpath(build, "tests_html"), joinpath(build, "tests"); force=true)
        mv(joinpath(build, "tests_agent"), joinpath(build, "tests-agent"); force=true)
        @info "grafted the test report into build/tests/ ($(length(files)) dump(s))"
    catch e
        # Non-fatal, exactly like the media branch: a repo that has not published a report yet (or a
        # fork with no access) still builds its docs.
        @info "no usable `test-report` branch — skipping the test report" e
    end
end

deploydocs(;
    versions=["stable", "dev"],
    repo="github.com/sotashimozono/Pinax.jl.git",
    devbranch="main",
    push_preview=true,
)
