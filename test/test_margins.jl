using Pinax
using Test
using Random

# A check's margin from `@test isapprox(…)` (#115, #116). The deviation and tolerance reproduce the
# bound isapprox actually applies, |x-y| <= max(atol, rtol*max(|x|,|y|)), recorded as whichever term
# governs, so `delta <= tol` agrees with the runner's verdict. Values with no margin (non-finite,
# zero tolerance) become a flagged 1/0 indicator — never a fabricated number or a JSON string.

_chk(ex) = Pinax._check_from(ex, string(ex), Base.eval(ex), 1)
_chk(s::AbstractString, passed) = Pinax._check_from(Meta.parse(s), s, passed, 1)

@testset "margins from @test isapprox" begin
    @testset "the governing term is the larger one, not the nonzero reference (#115)" begin
        c = _chk(:(isapprox(1e-12, 1e-13; rtol=1e-6, atol=1e-9)))
        @test (c.kind, c.tol) == (:abs, 1e-9)
        @test c.delta ≈ 9e-13
        @test c.pass && c.delta <= c.tol
    end

    @testset "a relative deviation is normalised by max(|got|, |want|) (#115)" begin
        c = _chk(:(isapprox(2.0, 1.0; rtol=0.6)))
        @test (c.kind, c.tol) == (:rel, 0.6)
        @test c.delta ≈ 0.5
        @test c.pass && c.delta <= c.tol
    end

    @testset "≈ uses isapprox's default rtol" begin
        c = _chk(:(≈(1.0, $(1.0 + 1e-10))))
        @test (c.kind, c.tol) == (:rel, sqrt(eps(Float64)))
        @test c.pass && c.delta <= c.tol
    end

    @testset "a zero reference with rtol gives a finite relative deviation (#116)" begin
        c = _chk(:(isapprox(5.0, 0.0; rtol=1e-3)))
        @test c.kind === :rel && isfinite(c.delta)
        @test !c.pass && c.delta > c.tol
    end

    @testset "NaN and Inf survive the reparse and become a flagged indicator (#116)" begin
        for (s, tok) in (
            ("isapprox(NaN, 0.0; rtol = 1.0e-6)", "NaN"),
            ("isapprox(-Inf, 1.0; atol = 1.0)", "-Inf"),
            ("isapprox(1.0, Inf; rtol = 0.1)", "Inf"),
        )
            c = _chk(s, false)
            @test c.indicator
            @test !c.pass
            @test all(isfinite, (c.got, c.want, c.delta, c.tol))   # JSON numbers, never "NaN"
            @test occursin(tok, c.label) && occursin("no margin", c.label)
        end
    end

    @testset "a zero tolerance has no margin either" begin
        c = _chk(:(isapprox(0.0, 0.0; atol=0.0, rtol=0.0)))
        @test c.indicator && c.pass
        @test occursin("no margin", c.label)
    end

    @testset "delta <= tol agrees with isapprox on random inputs" begin
        rng = MersenneTwister(173)
        disagree = 0
        for _ in 1:2000
            x = exp10(rand(rng, -12:6)) * (2rand(rng) - 1)
            y = x * (1 + exp10(rand(rng, -9:0)) * (2rand(rng) - 1))
            atol = rand(rng) < 0.5 ? 0.0 : exp10(rand(rng, -12:2))
            rtol = rand(rng) < 0.3 ? 0.0 : exp10(rand(rng, -9:0))
            atol == 0 && rtol == 0 && continue
            ex = :(isapprox($x, $y; atol=($atol), rtol=($rtol)))
            c = _chk(ex)
            c.indicator && continue
            disagree += ((c.delta <= c.tol) != c.pass)
        end
        @test disagree == 0
    end
end
