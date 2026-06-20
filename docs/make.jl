ENV["GKSwstype"] = "100"   # headless GR backend for compiling the example galleries

using Pinax
using Documenter
using Downloads
using Literate

const EXAMPLES = ["attractors", "lsystems", "ising"]
const LITDIR = joinpath(@__DIR__, "literate")
const GENDIR = joinpath(@__DIR__, "src", "examples")

# Turn each Pinax example script into a docs page that shows its source verbatim — plain `julia`
# code blocks, NOT executed. The gallery the script produces is compiled separately (below), so the
# page only documents the code; it links to the compiled gallery.
rm(GENDIR; force=true, recursive=true)
mkpath(GENDIR)
for name in EXAMPLES
    link =
        "\n```@raw html\n<p style=\"margin:.4rem 0 1.2rem\">" *
        "<a href=\"../../galleries/$(name)/\"><b>▶ Open the compiled Pinax gallery</b></a></p>\n```\n"
    # insert the gallery link right after the page's H1 (the first line)
    add_link = function (content)
        i = findfirst('\n', content)
        return if i === nothing
            content * link
        else
            content[1:i] * link * content[(i + 1):end]
        end
    end
    Literate.markdown(
        joinpath(LITDIR, "$name.jl"),
        GENDIR;
        documenter=false,    # plain ```julia fences, not @example
        execute=false,       # do not run during page generation
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
        "Examples" => [
            "Overview" => "examples.md",
            "Chaotic attractors" => "examples/attractors.md",
            "L-system fractals" => "examples/lsystems.md",
            "Ising model (Monte Carlo)" => "examples/ising.md",
        ],
        "API Reference" => "api.md",
    ],
)

# Compile the galleries by RUNNING each example script with the build directory as the working
# directory, so `render(out="galleries/<name>")` writes into build/galleries/<name>/ for deploy.
# Each script runs in its own module so their helper definitions do not collide.
let build = joinpath(@__DIR__, "build")
    cd(build) do
        for name in EXAMPLES
            Base.include(
                Module(Symbol("PinaxExample_", name)), joinpath(LITDIR, "$name.jl")
            )
        end
    end
end

deploydocs(;
    versions=["stable", "dev"],
    repo="github.com/sotashimozono/Pinax.jl.git",
    devbranch="main",
    push_preview=true,
)
