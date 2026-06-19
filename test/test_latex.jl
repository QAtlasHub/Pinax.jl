using Pinax
using Test

# No TeX compiler in CI, so these assert the emitted .tex (the user compiles it to PDF locally).
@testset "LaTeX theme (.tex emission)" begin
    tmp = mktempdir()
    site(n) = joinpath(tmp, n)
    pdf = joinpath(tmp, "fig.pdf")
    write(pdf, "%PDF-1.4 stub")
    bibf = joinpath(tmp, "r.bib")
    write(
        bibf,
        """
@article{key1,
  author = {Author, A.},
  title = {A title},
  journal = {J},
  year = {2020},
}
""",
    )

    @testset "structure / markdown->latex / math / figure / ref / cite / newcommand" begin
        Pinax.reset!(; title="My Report")
        @newcommand raw"\E" raw"\langle H\rangle"
        @bibliography bibf
        @page :p "Thermal" begin
            @section :energy "Energy" begin
                @desc md"**intro** see @ref(:cv) and @cite(:key1), inline $x^2$."
                @figure pdf id = :efig
                @caption md"a *caption*"
            end
            @section :cv "Cv" begin
                @figure pdf
            end
        end
        out = site("tex")
        path = Pinax.render(; out=out, theme=:latex)
        @test endswith(path, ".tex")                     # no compiler -> .tex returned
        tex = read(path, String)
        @test occursin("\\documentclass{article}", tex)
        @test occursin("\\title{My Report}", tex)
        @test occursin("\\section{Thermal}", tex)
        @test occursin("\\subsection{Energy}\\label{energy}", tex)
        @test occursin("\\textbf{intro}", tex)           # markdown bold -> \textbf
        @test occursin("\$x^2\$", tex)                   # native inline math
        @test occursin("\\ref{cv}", tex)                 # @ref -> \ref (forward ref resolved)
        @test occursin("\\cite{key1}", tex)              # @cite -> \cite
        @test occursin("\\includegraphics", tex)
        @test occursin("\\caption{", tex)
        @test occursin("\\label{efig}", tex)
        @test occursin("\\newcommand{\\E}{\\langle H\\rangle}", tex)
        @test occursin("\\begin{thebibliography}", tex)
        @test occursin("\\bibitem{key1}", tex)
        @test occursin("\\end{document}", tex)
        @test isfile(joinpath(out, "figures", "p", "energy", "efig.pdf"))   # figure materialized
    end

    @testset "theme=:latex selected from the document" begin
        Pinax.reset!(; theme=:latex, title="T2")
        @page :p "P" begin
            @section :s "S" begin
                @figure pdf
            end
        end
        path = Pinax.render(; out=site("tex2"))          # theme taken from @pinaxsetup
        @test endswith(path, ".tex")
        @test occursin("\\documentclass", read(path, String))
    end
end
