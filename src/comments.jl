# comments.jl — id-keyed annotation store for the gallery (notes 01 §4).
#
# Comments are a communication layer over the rendered figures: a portable, append-only sidecar that
# the human gallery, a CLI, and an LLM loop all read/write **by the section/figure id**. The id is
# the single explicit key linking the Julia manuscript (`@section :id`), the HTML (`<section id=…>`),
# and a comment — so a comment's correspondence to its source is unambiguous.
#
# Format = TOML (robust machine read/write, human-readable, git-diffable, consistent with the
# ParamIO/DataVault stack). Append-only entries per id so multiple writers (me / advisor / LLM) add
# turns without clobbering one another:
#
#     [[comment.eq_energy]]
#     author = "llm"
#     text = "Residual growth is consistent with finite-χ truncation."
#
#     [[comment.eq_energy]]
#     author = "sensei"
#     text = "Check the clean_obs β-overlap removal."
#
#     [bookmark]
#     eq_energy = true
#
# `text` is markdown (rendered when displayed). The browser is a convenience writer (localStorage +
# export, D2); this file is the durable source of truth and is the substrate for the CLI / LLM loop.

"One comment turn: who wrote it and the markdown body."
struct Comment
    author::String
    text::String
end

"""
    read_comments(path) -> (comments, bookmarks)

Read an id-keyed comments TOML. Returns `comments::Dict{Symbol,Vector{Comment}}` (id -> turns, in
file order) and `bookmarks::Set{Symbol}`. A missing or unparseable file yields empties (non-fatal);
rendering reports an unparseable one in the document's diagnostics.
"""
read_comments(path::AbstractString) = _parse_comments(path)[1:2]

# `read_comments`, plus what the store holds that is not a comment: the parse error of an unreadable
# store, or an entry in the wrong shape, each as a diagnostic (none when it is well-formed or absent).
function _parse_comments(path::AbstractString)
    comments = Dict{Symbol,Vector{Comment}}()
    bookmarks = Set{Symbol}()
    problems = DiagEntry[]
    isfile(path) || return comments, bookmarks, problems
    data = try
        TOML.parsefile(path)
    catch e
        msg = "the comment store does not parse, so no comment is shown: $(sprint(showerror, e))"
        push!(problems, DiagEntry(ERROR, basename(path), msg))
        return comments, bookmarks, problems
    end
    bad(id, msg) = push!(problems, DiagEntry(WARNING, string(id), msg))
    for (id, entries) in get(data, "comment", Dict{String,Any}())
        if !(entries isa AbstractVector)
            bad(
                id,
                "`[comment.$(id)]` is one table, not a list of turns: write each turn as `[[comment.$(id)]]`",
            )
            continue
        end
        turns = Comment[]
        for (i, e) in enumerate(entries)
            if e isa AbstractDict && haskey(e, "text")
                push!(turns, Comment(string(get(e, "author", "")), string(e["text"])))
            else
                bad(
                    id,
                    "turn $(i) is not a comment (a table with a `text`), so it is not shown",
                )
            end
        end
        isempty(turns) || (comments[Symbol(id)] = turns)
    end
    for (id, on) in get(data, "bookmark", Dict{String,Any}())
        on === true && push!(bookmarks, Symbol(id))
    end
    return comments, bookmarks, problems
end

# The node kinds every face shows comments on (Conventions › Faces).
const _COMMENT_CARRIERS = (:page, :section, :figure, :table)
const _KIND_NAMES = Dict(
    :part => "part",
    :text => "prose block",
    :code => "code block",
    :check => "check",
    :raw => "raw block",
)

# The comments a face renders `doc` with. A comment no face can show — the store does not parse, its
# id names no node, or it names a kind that carries no comments — goes into `rdiag`, never silently
# nowhere.
function _read_comments(doc, path::AbstractString, rdiag)
    comments, bookmarks, problems = _parse_comments(path)
    append!(rdiag, problems)
    kinds = Dict(n.id => n.kind for n in node_ids(doc))
    # A comment or bookmark is stored under a node's id (the API, pinax-mcp) or its anchor (the
    # gallery writes what it shows); the faces look a node up by its anchor, so key them all that way.
    byanchor = Dict{Symbol,Symbol}(Symbol(_anchor(id)) => id for id in keys(kinds))
    askey(k) = haskey(kinds, k) ? Symbol(_anchor(k)) : k
    bookmarks = Set{Symbol}(askey(k) for k in bookmarks)
    stored = comments
    comments = Dict{Symbol,Vector{Comment}}()
    for k in sort!(collect(keys(stored)))   # a node's turns under both keys are kept, id's first
        append!(get!(comments, askey(k), Comment[]), stored[k])
    end
    for key in sort!(collect(keys(comments)))
        id = get(byanchor, key, key)
        k = get(kinds, id, nothing)
        msg = if k === nothing
            "a comment names no node in this document, so it is shown nowhere. A generated id " *
            "changes with its node's content: give a node you discuss an explicit id."
        elseif !(k in _COMMENT_CARRIERS)
            "a comment on a $(_KIND_NAMES[k]) is shown nowhere: comments are shown on pages, " *
            "sections, figures and tables."
        else
            continue
        end
        push!(rdiag, DiagEntry(WARNING, string(id), msg))
    end
    return comments, bookmarks
end

"""
    add_comment(path, id, text; author="") -> path

Append one comment turn for `id` to the TOML at `path` (created if absent), preserving existing
turns and bookmarks. This is the CLI / LLM-loop write path:
`julia -e 'using Pinax; Pinax.add_comment("comments.toml", :eq_energy, "…"; author="llm")'`.
"""
function add_comment(
    path::AbstractString, id, text::AbstractString; author::AbstractString=""
)
    data = _read_toml(path)
    cmt = get!(data, "comment", Dict{String,Any}())
    turns = get!(cmt, string(id), Any[])
    push!(turns, Dict("author" => String(author), "text" => String(text)))
    _write_toml(path, data)
    return path
end

"""
    set_bookmark!(path, id, on=true) -> path

Mark/unmark `id` as bookmarked in the TOML at `path`.
"""
function set_bookmark!(path::AbstractString, id, on::Bool=true)
    data = _read_toml(path)
    get!(data, "bookmark", Dict{String,Any}())[string(id)] = on
    _write_toml(path, data)
    return path
end

_read_toml(path) = isfile(path) ? TOML.parsefile(path) : Dict{String,Any}()

function _write_toml(path, data)
    mkpath(dirname(abspath(path)))   # allow writing to a not-yet-created location (CLI / LLM loop)
    open(path, "w") do io
        return TOML.print(io, data)
    end
    return nothing
end
