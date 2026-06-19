module PinaxPlotsExt

# Pinax backend extension for Plots.jl. Loaded automatically when both Pinax and Plots are imported.

using Pinax
using Plots

Pinax.is_figure(::Plots.Plot) = true

# Plots.savefig(plot, filename) infers the output format from the filename extension.
# Wrapped in a lambda matching the _save_with `(obj, dest)` contract (not relying on arg order).
function Pinax.pinax_save(p::Plots.Plot, base, fmt)
    return Pinax._save_with((obj, dest) -> Plots.savefig(obj, dest), p, base, fmt)
end

end # module PinaxPlotsExt
