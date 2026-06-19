module PinaxMakieExt

# Pinax backend extension for Makie.jl. Loaded automatically when both Pinax and Makie are imported.

using Pinax
using Makie

Pinax.is_figure(::Union{Makie.Figure,Makie.Scene}) = true

# Makie.save(filename, figure) — note the reversed argument order (filename first), handled by
# the lambda. A concrete Makie backend (CairoMakie, GLMakie, …) must also be loaded or save errors.
function Pinax.pinax_save(f::Union{Makie.Figure,Makie.Scene}, base, fmt)
    return Pinax._save_with((obj, dest) -> Makie.save(dest, obj), f, base, fmt)
end

end # module PinaxMakieExt
