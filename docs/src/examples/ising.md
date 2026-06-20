# Example 3 · Ising model (Monte Carlo)

[← All examples](../examples.md)

**Source:** self-contained — a 2-D Metropolis simulation written inline with `Plots` + `Random`.

```@raw html
<p style="margin:.2rem 0 1rem"><a href="../galleries/ising/"><b>▶ Open the compiled Pinax gallery</b></a></p>
```

A self-contained 2-D Ising Monte Carlo: Metropolis single-spin flips on a periodic lattice with
Hamiltonian $H=-J\sum_{\langle ij\rangle} s_i s_j$, accepting a flip with probability
$\min\!\bigl(1, e^{-\beta\Delta E}\bigr)$. The model orders below the Onsager temperature
$T_c=2/\ln(1+\sqrt 2)\approx 2.269$ and disorders above it. No external dependencies — just `Plots`
and `Random`.

```@example ising
using Pinax, Plots, Random

# one Metropolis sweep (L*L attempted single-spin flips) at inverse temperature β
function sweep!(s, β)
    L = size(s, 1)
    @inbounds for _ in 1:L*L
        i = rand(1:L); j = rand(1:L)
        nb = s[mod1(i-1, L), j] + s[mod1(i+1, L), j] + s[i, mod1(j-1, L)] + s[i, mod1(j+1, L)]
        dE = 2 * s[i, j] * nb
        (dE <= 0 || rand() < exp(-β * dE)) && (s[i, j] = -s[i, j])
    end
    return s
end

# run at temperature T; return the final configuration and the mean |magnetization|
function run_ising(L, T; equil, measure)
    s = rand((Int8(-1), Int8(1)), L, L)
    β = 1 / T
    for _ in 1:equil; sweep!(s, β); end
    m = 0.0
    for _ in 1:measure; sweep!(s, β); m += abs(sum(Int, s)) / (L * L); end
    return s, m / measure
end

Random.seed!(20240620)
snap(T) = heatmap(run_ising(64, T; equil=600, measure=1)[1]; aspect_ratio=:equal, c=:grays,
                  axis=false, ticks=false, colorbar=false, size=(360, 360), title="T = $T")
nothing # hide
```

```@example ising
Tc = 2 / log(1 + sqrt(2))

Pinax.reset!(; title = "2-D Ising model — Monte Carlo (Pinax demo)")

@page :ising "Ising model (Monte Carlo)" begin
    @section :snapshots "Spin configurations" begin
        @desc md"""
        Equilibrated $64\times64$ configurations (black/white = down/up spins) across the
        transition $T_c\approx2.269$: ordered, critical (large fluctuating clusters), disordered.
        """
        @figure snap(1.5)
        @caption md"$T=1.5<T_c$ — ordered"
        @figure snap(2.27)
        @caption md"$T\approx T_c$ — critical"
        @figure snap(3.5)
        @caption md"$T=3.5>T_c$ — disordered"
    end
    @section :magnetization "Magnetization curve" begin
        @desc md"""
        Order parameter $\langle\lvert m\rvert\rangle(T)$ over a temperature sweep, with the Onsager
        $T_c$ marked. It falls from $\approx1$ (ordered) toward $0$ (disordered) near $T_c$.
        """
        @figure begin
            Ts = collect(1.0:0.2:3.6)
            Ms = [run_ising(40, T; equil=400, measure=500)[2] for T in Ts]
            plot(Ts, Ms; marker=:circle, lw=1.5, legend=:topright, label="⟨|m|⟩",
                 xlabel="T", ylabel="⟨|m|⟩", size=(560, 380))
            vline!([Tc]; ls=:dash, lc=:red, label="Tc ≈ 2.269")
        end
        @caption md"$\langle\lvert m\rvert\rangle$ vs $T$ (40×40 lattice)"
    end
end

Pinax.render(; out = "galleries/ising")
nothing # hide
```

A preview of a critical-temperature snapshot, shown inline by Documenter:

```@example ising
snap(2.27)
```

```@raw html
<p style="margin:1rem 0"><a href="../galleries/ising/"><b>▶ Open the rendered gallery</b></a></p>
```
