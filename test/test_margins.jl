using Pinax
using Test

# A check's margin from `@test isapprox(…)` (#115, #116). The deviation and tolerance reproduce the
# bound isapprox actually applies, |x-y| <= max(atol, rtol*max(|x|,|y|)), recorded as whichever term
# governs, so `delta <= tol` agrees with the runner's verdict. Values with no margin (non-finite,
# zero tolerance) become an indicator check with no numbers — never a fabricated number.

_chk(ex) = Pinax._check_from(ex, string(ex), Base.eval(ex), 1)
_chk(s::AbstractString, passed) = Pinax._check_from(Meta.parse(s), s, passed, 1)

@testset "margins from @test isapprox" begin
    @testset "the governing term is the larger one, not the nonzero reference (#115)" begin
        c = _chk(:(isapprox(1e-12, 1e-13; rtol=1e-6, atol=1e-9)))
        @test (c.kind, c.tol) == (:abs, 1e-9)
        @test c.delta ≈ 9e-13
        @test Pinax.passed(c) && c.delta <= c.tol
    end

    @testset "a relative deviation is normalised by max(|got|, |want|) (#115)" begin
        c = _chk(:(isapprox(2.0, 1.0; rtol=0.6)))
        @test (c.kind, c.tol) == (:rel, 0.6)
        @test c.delta ≈ 0.5
        @test Pinax.passed(c) && c.delta <= c.tol
    end

    @testset "≈ uses isapprox's default rtol" begin
        c = _chk(:(≈(1.0, $(1.0 + 1e-10))))
        @test (c.kind, c.tol) == (:rel, sqrt(eps(Float64)))
        @test Pinax.passed(c) && c.delta <= c.tol
    end

    @testset "a zero reference with rtol gives a finite relative deviation (#116)" begin
        c = _chk(:(isapprox(5.0, 0.0; rtol=1e-3)))
        @test c.kind === :rel && isfinite(c.delta)
        @test !Pinax.passed(c) && c.delta > c.tol
    end

    @testset "NaN and Inf survive the reparse and become a flagged indicator (#116)" begin
        for (s, tok) in (
            ("isapprox(NaN, 0.0; rtol = 1.0e-6)", "NaN"),
            ("isapprox(-Inf, 1.0; atol = 1.0)", "-Inf"),
            ("isapprox(1.0, Inf; rtol = 0.1)", "Inf"),
        )
            c = _chk(s, false)
            @test c.kind === :indicator
            @test !Pinax.passed(c)
            @test all(isnan, (c.got, c.want, c.delta, c.tol))   # no numbers: null in agent.json
            @test occursin(tok, c.label) && occursin("no margin", c.label)
        end
    end

    @testset "a zero tolerance has no margin either" begin
        c = _chk(:(isapprox(0.0, 0.0; atol=0.0, rtol=0.0)))
        @test c.kind === :indicator && Pinax.passed(c)
        @test occursin("no margin", c.label)
    end

    @testset "delta <= tol agrees with isapprox over a grid of inputs" begin
        # a deterministic grid (no Random: it is not a test dependency) spanning 18 decades of
        # magnitude, both signs, near and far deviations, and every atol/rtol combination
        disagree, n = 0, 0
        for e in -12:3:6, sgn in (1.0, -0.37)
            x = sgn * 10.0^e
            for p in (1e-9, 3e-7, -1e-5, 1e-4, 0.02, 0.3, -0.5, 0.9)
                y = x * (1 + p)
                for atol in (0.0, 1e-12, 1e-9, 1e-6, 1e-3, 1.0, 100.0),
                    rtol in (0.0, 1e-9, 1e-6, 1e-3, 0.1, 0.5)

                    atol == 0 && rtol == 0 && continue
                    c = _chk(:(isapprox($x, $y; atol=($atol), rtol=($rtol))))
                    c.kind === :indicator && continue
                    n += 1
                    disagree += ((c.delta <= c.tol) != Pinax.passed(c))
                end
            end
        end
        @test n > 4000
        @test disagree == 0
    end
end
