module PinaxDataVaultExt

# DataVault extension for Pinax. Loaded automatically when Pinax, DataVault, and ParamIO are all
# imported (DataVault depends on ParamIO, so importing DataVault pulls ParamIO in). Makes the render
# cache track the underlying data and records figure provenance — the `render(; vault, study)` path.

using Pinax
using ParamIO
using DataVault

# The digests of the bytes the running `report` read, by canonical key. While a report renders,
# the figure cache keys on these: a figure re-materializes when its data's bytes change, and not
# when only a marker is rewritten. `nothing` outside a report. Reports are not re-entrant.
const _READS = Ref{Union{Nothing,Dict{String,String}}}(nothing)

# The cache key's data component for a figure tagged `params`: inside a report, the digest of the
# bytes that report read; otherwise the digest the `.done` marker recorded when the key was
# computed; for a marker older than that, the marker's content (notes 10). "" when there is none,
# or DataVault's layout changes.
function Pinax._data_fingerprint(vault::DataVault.Vault, params::ParamIO.DataKey)
    reads = _READS[]
    if reads !== nothing
        digest = get(reads, ParamIO.canonical(params), nothing)
        digest === nothing || return digest
    end
    try
        recorded = get(DataVault.read_done(vault, params), "result_sha256", "unknown")
        recorded == "unknown" || return recorded
        df = DataVault._done_file(vault, params)
        return isfile(df) ? string(hash(read(df, String))) : ""
    catch e
        e isa InterruptException && rethrow()
        return ""
    end
end

# Record study-level figure provenance via DataVault (non-fatal).
function Pinax._record_provenance(vault::DataVault.Vault, study)
    try
        s = study === nothing ? vault.run : string(study)
        DataVault.record_figure(vault; study=s)
    catch e
        e isa InterruptException && rethrow()
        @warn "Pinax: DataVault.record_figure failed" exception = e
    end
    return nothing
end

# The render process's own source observation, next to the compute processes' ones: the report's
# code is part of what produced it, and `recipe` is its entry code, so the binding vouches for the
# recipe or says why not (one written in the driving script cannot be checked). A readonly vault
# cannot store one, and a failure is not fatal.
function _observe_render(vault::DataVault.Vault, recipe)
    vault.readonly && return nothing
    try
        return DataVault.observe_sources(
            vault; phase="render", process=Dict("role" => "render"), code=(recipe,)
        )
    catch e
        e isa InterruptException && rethrow()
        @warn "Pinax: DataVault.observe_sources failed; the report has no render observation" exception =
            e
        return nothing
    end
end

# vault → doc bridge. Discover the vault's completed keys, read each result with
# `DataVault.load_recorded` (one copy, hashed, then loaded, so the digest names the bytes the
# recipe saw), let the project `recipe` build the doc, and render the human gallery + the
# agent.json with the vault wired in. The driver is project-independent; only `recipe(pairs)` is
# project-specific.
#
# Returns `(; gallery, agent, n, reads, render_observation)`. `reads` holds one record per key:
# its canonical id, the file, `read_sha256`, and what the key's `.done` recorded
# (`result_sha256`, `observation`, `completed_at`). `render_observation` is the token of this
# process's source observation, or `nothing` (readonly vault, `observe=false`, or a failure).
function Pinax.report(
    vault::DataVault.Vault,
    recipe::Function;
    title::AbstractString,
    out::AbstractString,
    study=nothing,
    observe::Bool=true,
    kwargs...,
)
    loaded = [
        (k, DataVault.load_recorded(vault, k)) for k in DataVault.keys(vault; status=:done)
    ]
    isempty(loaded) && error("Pinax.report: no :done keys in vault (run=$(vault.run)).")
    pairs = [(k, data) for (k, (data, _)) in loaded]
    reads = [rec for (_, (_, rec)) in loaded]
    render_observation = observe ? _observe_render(vault, recipe) : nothing
    Pinax.reset!(; title=String(title))
    recipe(pairs)
    _READS[] = Dict(r.key => r.read_sha256 for r in reads)
    try
        gallery = Pinax.render(; out="$(out)_html", theme=:gallery, vault, study, kwargs...)
        agent = Pinax.render(; out="$(out)_agent", theme=:agent, vault, study, kwargs...)
        return (; gallery, agent, n=length(pairs), reads, render_observation)
    finally
        _READS[] = nothing
    end
end

end # module PinaxDataVaultExt
