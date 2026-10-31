# testset.jl — the Test-FREE half of the `Test` bridge (the other half is ext/PinaxTestExt.jl).
#
# A test suite is normally a binary: green or red. But Pinax already has the pieces to say
# something much more useful — a `Check(got, want, delta, tol, pass)` per assertion, and every
# container holding checks renders them as a colored pass/fail report (and emits its `verdict` and
# `checks` into `agent.json`). All that was missing was the bridge FROM `Test`:
#
#     test file  (@testset "test_foo.jl")  →  @page
#     @testset   (nested)                  →  @section  (recursively)
#     @test                                →  a Check  +  the @code that produced it
#
# THE POINT — a margin, not a verdict. For any `@test isapprox(got, want; rtol=…)` the real
# numbers are recovered, so the report shows `delta/tol`: how much room a test passed BY. A
# check sitting at 99% of its tolerance is one refactor away from red and looks identical to a
# rock-solid one in a green CI badge. Here they look nothing alike.
#
# WHY THE SPLIT. `Test` is a weakdep: Pinax is a rendering package, and `using Pinax` must not drag
# in Test (and with it Random/Logging/Serialization/InteractiveUtils) for the majority of users who
# never render a test suite. Everything here is Test-free — Expr parsing, the Check, the figure —
# so it is also directly testable without the extension loaded. Only the `AbstractTestSet` subtype
# and the `record`/`finish` machinery live in the extension.

"""
    Pinax.test([runtests]; out="test-report", title="Test report", dump="") -> nothing

Run a test suite and render it as a Pinax document — the interface that outputs a testset directly.
There is **no Pinax-specific macro** in the suite: it stays plain `@testset` / `@test`. The only Pinax
touch is the call. Two forms:

  - `Pinax.test()` — test the *active package*. Delegates to an unmodified `Pkg.test`, passing a `-L`
    preamble that installs a capturing root before the suite runs (so its `@testset` tree is captured)
    and renders at exit. `Pkg.test` still does all the sandbox / dependency work; a bare `Pkg.test()`
    without this installs no root and produces no report.
  - `Pinax.test(runtests::AbstractString)` — render a specific test file in the current process (no
    sandbox): open a capturing root testset, `include` the file, render.

Each test *file* (a `.jl`-named `@testset`) becomes a page, each nested
`@testset` a section, each `@test` a `Check` carrying its real `got`/`want`/`tol` — and, by default,
a `@code` block holding the source that produced it, so a reader sees what was measured and not only
whether it passed. Writes
`<out>/html/` + `<out>/agent/`; with `dump` set, dumps the tree there instead (a sharded CI shard) for
[`render_test_report`](@ref) to merge later. A red suite still fails the process — the report never
changes the verdict. A suite may also draw (`@desc`/`@figure`/`@table`/…); that content is captured,
and is a no-op under a bare `Pkg.test()`.

The `test()` delegation is `Test`-free (only `Pkg`, a stdlib); the in-process `test(runtests)` form
lives in `PinaxTestExt` and needs `Test` loaded.
"""
function test(; out=report_out(), dump=report_dump(), title::AbstractString=report_title())
    # Delegate to an UNMODIFIED `Pkg.test`, injecting a `-L` preamble that installs a capturing root
    # before the suite's include (invariant V′). `Pkg.test` does all the sandbox/dependency work; we
    # add one flag and make `out` ABSOLUTE (the caller's dir) so the report survives sandbox teardown.
    Pkg = Base.require(Base.PkgId(Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"), "Pkg"))
    preamble = joinpath(pkgdir(@__MODULE__), "src", "test_preamble.jl")
    withenv(
        "PINAX_TEST_OUT" => abspath(out),
        "PINAX_TEST_DUMP" => (isempty(dump) ? "" : abspath(dump)),
        "PINAX_TEST_TITLE" => String(title),
    ) do
        return Pkg.test(; julia_args=`-L $(preamble)`)
    end
    return nothing
end

"""
    _install_test_capture!()

Push a capturing root `PinaxTestSet` onto the (task-local) testset stack and register an `atexit` hook
that renders/dumps it and sets the exit code — the `Pkg.test`-delegation half of [`test`](@ref). The
`-L` preamble the delegating `Pinax.test()` hands to `Pkg.test` calls this; the method lives in
`PinaxTestExt` (needs `Test`). Returns whether it installed — it declines during precompilation
and when a capture is already open.
"""
function _install_test_capture! end

"Set once a capturing root is installed in this process, so a second install declines."
const _CAPTURE_INSTALLED = Ref(false)

"""
    capture_requested() -> Bool

Whether the environment asked for a test report at all: `PINAX_TEST_OUT` or `PINAX_TEST_DUMP`
present. **Presence** is the request — `report_out` has a default, so no particular value can be
one — which is what lets [`install_test_capture!`](@ref) sit in a committed `runtests.jl`.
"""
capture_requested() = haskey(ENV, "PINAX_TEST_OUT") || haskey(ENV, "PINAX_TEST_DUMP")

"""
    install_test_capture!() -> Bool

Install the capturing root from *inside* the suite, so a report comes out of a plain `Pkg.test()`
— whoever owns that call keeps owning it, along with the sandbox, the coverage flags and
everything else it sets.

[`test`](@ref) reaches the same installer through a `-L` preamble, which is what lets it leave
`runtests.jl` untouched. That route is not always open: a CI action that owns the `Pkg.test` call
exposes no way to add `-L` — `julia-actions/julia-runtest` has no such input — and replacing it
to get one costs whatever else it was setting, coverage included. This is the other way in, and
it composes with anything that can set an environment variable.

    using MyPackage, Test, Pinax
    Pinax.install_test_capture!()
    @testset "MyPackage" begin
        include("a.jl")
    end

**It does nothing unless the environment asked** — see [`capture_requested`](@ref). So the line
can be committed and a developer's `Pkg.test()` behaves exactly as it did; CI turns it on by
setting `PINAX_TEST_OUT` or, per shard, `PINAX_TEST_DUMP`.

It is also idempotent. Called when a capture is already open — under [`test`](@ref), whose
preamble installed one before the suite was even read — it declines. A second root would take
every assertion and leave the first to render an empty and green report, which is the exact
failure this seam exists to prevent.
"""
function install_test_capture!()
    capture_requested() || return false
    if !applicable(_install_test_capture!)
        # Asked for a report, and there is no `Test` to capture. Silence here would reproduce the
        # empty-and-green failure by another route, so say so.
        @warn "Pinax.install_test_capture!: `Test` is not loaded, so there is nothing to capture — \
               no report will be written."
        return false
    end
    return _install_test_capture!()
end

"Where the test report is written (`PINAX_TEST_OUT`, default `test-report`) → `<out>/html/` + `<out>/agent/`."
report_out() = get(ENV, "PINAX_TEST_OUT", "test-report")

"Report title (`PINAX_TEST_TITLE`, default `Test report`) — the document title + overview heading."
report_title() = get(ENV, "PINAX_TEST_TITLE", "Test report")

"""
    @pinaxignore

Drop the enclosing `@testset` — and everything under it — from the rendered document. The tests still
RUN and still count toward pass/fail; they simply do not become a page or a section. For the noise
you do not want in a report (a smoke check, an Aqua block, a slow fixture):

    @testset "Aqua tests" begin
        @pinaxignore
        Aqua.test_all(MyPkg)
    end

A no-op when the report is off, so it is safe to leave in the code permanently.
"""
macro pinaxignore()
    return :($(_ignore_current_testset!)())
end

"""
    _ignore_current_testset!()

Mark the innermost enclosing testset as excluded from the document. Declared with no methods on
purpose: the only method lives in `PinaxTestExt`, and it cannot be missing where it matters, since
`@pinaxignore` is only ever reachable from inside a `@testset` — which means `Test` is loaded, which
means the extension is too. (A fallback method HERE would be overwritten by the extension's, and
method overwriting during precompilation is an error.)
"""
function _ignore_current_testset! end

_looks_like_a_file(desc::AbstractString) = endswith(desc, ".jl")

# A description as an id: its letters and digits, in any script, joined by `_` (`:エネルギー`,
# `:test_foo_jl`); one with none (`"!!"`) is a hash of itself, so it is still its own and not positional.
function _slug(s)
    t = replace(lowercase(strip(s)), r"[^\p{L}\p{N}]+" => "_")
    return occursin(r"[\p{L}\p{N}]", t) ? Symbol(t) : Symbol("t", _stable_hash(s))
end

# ── the code behind a check: one code format, captured by default ────
#
# A check shows a verdict and a margin, and a reader still cannot tell WHAT was measured — the
# computation is right there in the test file and the report never showed it. So by default every
# assertion carries its source region, and it is carried as the SAME artifact an explicit `@code`
# builds (a `CodeBlock`, rendered by `emit_code` in every backend). One code format in the document,
# not a second one for tests — a second renderer is a second thing to drift.
#
# The region is read SYNTACTICALLY, from the file's own parse tree: the statements of the innermost
# block that lead up to the assertion, starting after the previous assertion in that block. Pinax
# content macros (`@desc` / `@code` / `@figure` / …) are dropped, because each of them renders itself
# — including their source would show them twice, in two different formats. An unnamed `@testset for`
# is a sample rather than a section, so nothing else in the document shows its header: that one gets
# prepended (with a closing `end`), which makes the snippet the sweep's specification.

# Statements of a `:block` / `:toplevel` as (line, stmt) pairs — a LineNumberNode sets the line.
function _blk_stmts(x::Expr)
    out = Tuple{Int,Any}[]
    line = 0
    for a in x.args
        a isa LineNumberNode ? (line = a.line) : push!(out, (line, a))
    end
    return out
end

# The greatest line mentioned anywhere in a subtree (0 when it mentions none).
function _maxline(x)
    x isa LineNumberNode && return x.line
    x isa Expr || return 0
    m = 0
    for a in x.args
        m = max(m, _maxline(a))
    end
    return m
end

struct _CodeBlk
    stmts::Vector{Tuple{Int,Any}}
    lo::Int
    hi::Int
    owners::Vector{Any}      # enclosing expressions, innermost first
end

function _walk_code_blocks!(out::Vector{_CodeBlk}, x, owners::Vector{Any})
    x isa Expr || return nothing
    if x.head === :block || x.head === :toplevel
        st = _blk_stmts(x)
        isempty(st) ||
            push!(out, _CodeBlk(st, first(st)[1], max(_maxline(x), first(st)[1]), owners))
        for a in x.args
            _walk_code_blocks!(out, a, owners)
        end
    else
        inner = Any[x]
        append!(inner, owners)
        for a in x.args
            _walk_code_blocks!(out, a, inner)
        end
    end
    return nothing
end

function _macroname(x)
    x isa Expr && x.head === :macrocall && !isempty(x.args) && x.args[1] isa Symbol ||
        return ""
    return String(x.args[1])
end

# Statements that render themselves as their own artifact (so their source is not this check's code).
const _SELF_RENDERING_MACROS = Set([
    "@desc",
    "@code",
    "@caption",
    "@figure",
    "@table",
    "@raw",
    "@thumbnail",
    "@no_thumbnail",
    "@label",
    "@pinaxignore",
    "@section",
    "@page",
    "@part",
    "@pinaxsetup",
    "@newcommand",
    "@bibliography",
    "@testset",
])
# Statements that END a region: the code before an assertion belongs to THAT assertion, so the next
# one starts fresh (consecutive checks never repeat each other's setup).
const _ASSERTION_MACROS = Set([
    "@test",
    "@test_throws",
    "@test_broken",
    "@test_skip",
    "@test_logs",
    "@test_deprecated",
    "@test_warn",
    "@test_nowarn",
])

_is_assertion_stmt(s) = _macroname(s) in _ASSERTION_MACROS
_is_self_rendering_stmt(s) = _macroname(s) in _SELF_RENDERING_MACROS

function _code_parses(text)
    return try
        e = Meta.parseall(text)
        !any(a -> a isa Expr && a.head === :incomplete, e.args)
    catch
        false
    end
end

# The header line of the unnamed `@testset for` whose body is this block, or 0.
function _sweep_header_line(b::_CodeBlk)
    length(b.owners) >= 2 || return 0
    f, mc = b.owners[1], b.owners[2]
    (f isa Expr && f.head === :for) || return 0
    _macroname(mc) == "@testset" || return 0
    # `@testset for …` is [@testset, LNN, for]; a DESCRIBED one has a String before the `for`, and
    # its description is the section title, so its header is already in the document.
    length(mc.args) == 3 || return 0
    ln = mc.args[2]
    return ln isa LineNumberNode ? ln.line : 0
end

# Last source line of statement `i`. One followed by a sibling ends where the sibling begins; the
# block's LAST statement has no such bound (and the block's extent may include its closing `end`), so
# grow it line by line until the text PARSES — the minimal complete expression.
function _stmt_hi(b::_CodeBlk, i::Int, lines)
    lo = b.stmts[i][1]
    i < length(b.stmts) && return max(lo, b.stmts[i + 1][1] - 1)
    for hi in lo:min(length(lines), lo + 20)
        _code_parses(join(lines[lo:hi], "\n")) && return hi
    end
    return lo
end

const _MAX_CODE_LINES = 12
# file → (lines, parse tree). Test files do not change while the suite runs, so parse each once.
const _FILE_AST = Dict{String,Union{Nothing,Tuple{Vector{String},Expr}}}()

function _file_ast(file::AbstractString)
    return get!(_FILE_AST, String(file)) do
        isfile(file) || return nothing
        try
            src = read(file, String)
            ast = Meta.parseall(src; filename=file)
            (String.(split(src, '\n')), ast)
        catch
            nothing
        end
    end
end

# The statement written at `file:line`: the innermost block holding a statement there, that
# statement's index in it, and the file's lines — or `nothing` when the file is not readable (a REPL,
# a Documenter `@example`) or no statement starts at that line.
function _code_site(file, line)
    fa = _file_ast(file)
    fa === nothing && return nothing
    lines, ast = fa
    blks = _CodeBlk[]
    _walk_code_blocks!(blks, ast, Any[])
    cands = filter(b -> any(s -> s[1] == line, b.stmts), blks)
    isempty(cands) && return nothing
    b = argmin(x -> x.hi - x.lo, cands)          # the innermost block holding a statement at `line`
    return (; lines, b, idx=findlast(s -> s[1] == line, b.stmts))
end

"""
    _test_code_block(file, line) -> CodeBlock | nothing

The `@code` artifact for the assertion at `file:line` — the code that produced it. The id hashes
the code text (#123), so shifted lines never move it, and every sample of a `@testset for` (the same
code, N iterations) maps to ONE block: the sweep shows its specification once, not once per point.
"""
function _test_code_block(file::AbstractString, line::Integer)
    site = _code_site(file, line)
    site === nothing && return nothing
    (; lines, b, idx) = site
    pieces = _region_pieces(b, idx, lines)
    out = _region_lines(pieces, lines)
    isempty(out) && return nothing
    hdr = _sweep_header_line(b)
    src = _snippet_source(out, lines, b, hdr)
    # keyed on the code itself, not its line span, so shifting lines never changes it (#123)
    id = Symbol("code_", _slug(basename(String(file))), "_", _stable_hash(src))
    at = _defined_at((String(file), hdr == 0 ? pieces[1][1] : hdr))
    return CodeBlock(id, _anchor(id), src, "", "", "julia", at)
end

# The `(first, last)` source lines of the statements behind assertion `idx` of block `b`: those after
# the block's previous assertion, up to it, less the Pinax content macros (they render themselves).
function _region_pieces(b::_CodeBlk, idx::Int, lines)
    prev = findlast(i -> _is_assertion_stmt(b.stmts[i][2]), 1:(idx - 1))
    from = prev === nothing ? 1 : prev + 1
    return [
        (b.stmts[i][1], _stmt_hi(b, i, lines)) for
        i in from:idx if !_is_self_rendering_stmt(b.stmts[i][2])
    ]
end

# The text of those statements. A trailing blank / comment line introduces whatever comes NEXT, not
# this region, so it is left off.
function _region_lines(pieces, lines)
    out = String[]
    for (lo, hi) in pieces
        append!(out, lines[lo:min(hi, length(lines))])
    end
    while !isempty(out) && _blank_or_comment(out[end])
        pop!(out)
    end
    return out
end
_blank_or_comment(l) = (t=strip(l); isempty(t) || startswith(t, "#"))

# The snippet: a sweep's header (line `hdr`, 0 when none) ahead of the region and its `end` after,
# within `_MAX_CODE_LINES`. Never silently truncated: an elided region says so (the full file is a
# click away in CI).
function _snippet_source(out, lines, b::_CodeBlk, hdr::Int)
    head = hdr == 0 ? String[] : lines[hdr:(b.lo - 1)]
    budget = _MAX_CODE_LINES - length(head) - (hdr == 0 ? 0 : 1)
    length(out) > budget && (out = vcat(["#   …"], out[(end - budget + 2):end]))
    src = _dedent(vcat(head, out))
    return hdr == 0 ? src : string(src, "\nend")
end

_strip_lnn(x) = x
function _strip_lnn(e::Expr)
    return Expr(e.head, Any[_strip_lnn(a) for a in e.args if !(a isa LineNumberNode)]...)
end

function _dedent(ls)
    indents = [length(l) - length(lstrip(l)) for l in ls if !isempty(strip(l))]
    ind = isempty(indents) ? 0 : minimum(indents)
    return rstrip(join((isempty(strip(l)) ? "" : l[(ind + 1):end] for l in ls), "\n"))
end

"""
    _verbatim_code(file, line, expr) -> String | nothing

The source of an `@code` block's expression **as written** at `file:line`, rather than deparsed from
the AST — `@code f(x) = sum(k -> g(k), 1:x)` should read back as itself, not as the `begin`-blocked
normal form `string(::Expr)` produces. The statement's text is read from the file and the leading
`@code` (with its keywords) is peeled off by trying each token boundary of the first line until the
remainder parses to the very expression the macro was handed. `nothing` when the file is not readable
(a REPL, a Documenter `@example`), where the deparsed form is all there is.
"""
function _verbatim_code(file, line, expr)
    site = _code_site(file, line)
    site === nothing && return nothing
    (; lines, b, idx) = site
    hi = min(_stmt_hi(b, idx, lines), length(lines))
    text = _dedent(lines[b.stmts[idx][1]:hi])
    target = _strip_lnn(expr)
    for s in _first_line_starts(text)
        _parses_to(text, s, target) && return _dedent(split(SubString(text, s), '\n'))
    end
    return nothing
end

# Where each token of `text`'s first line starts: where a peeled-off macro call may end.
function _first_line_starts(text)
    nl = something(findfirst('\n', text), length(text) + 1)
    starts = Int[1]
    for (j, ch) in enumerate(text)
        j >= nl && break
        isspace(ch) && j < length(text) && push!(starts, j + 1)
    end
    return starts
end

# Whether `text` from `s` on parses, completely, to `target` (line numbers aside).
function _parses_to(text, s, target)
    e = try
        Meta.parse(SubString(text, s))
    catch
        return false
    end
    e isa Expr && e.head === :incomplete && return false
    return _strip_lnn(e) == target
end

"""
    _push_auto_code!(container, blk) -> Symbol

Place an auto-captured `@code` artifact into a container, at most once per id, and return the id it
holds there. Deduplication by id is what collapses a sweep's N samples — and N shards' dumps — onto
the one block they share. A test node keeps the block as captured (the fold places it in the
document); a document container places it now, under an id no other node holds.
"""
function _push_auto_code!(c, blk)
    if !(c isa TestNode)
        _place_code!(c, blk, ())
        return _ensure_document!().fold_codes[(c.id, blk.id)]
    end
    any(b -> b.id === blk.id, c.codes) && return blk.id
    push!(c.codes, blk)
    push!(c.content, :code => length(c.codes))
    return blk.id
end

# ── recovering the NUMBERS out of a test's expression ────────────────
#
# `isapprox(got, want; rtol=…, atol=…)` / `got ≈ want` → (; got, want, atol, rtol), with isapprox's
# own defaults filled in, or nothing. The Expr arrives with its arguments already EVALUATED (that is
# what `Test` records), so these are the real numbers the assertion actually compared.
function _approx_numbers(e::Expr)
    (e.head === :call && e.args[1] in (:isapprox, :≈)) || return nothing
    args = _flat_args(e.args[2:end])
    kw = Dict(a.args[1] => _tofloat(a.args[2]) for a in args if _is_kw(a))
    pos = Float64[v for v in (_tofloat(a) for a in args if !_is_kw(a)) if v !== nothing]
    length(pos) >= 2 || return nothing
    a = something(get(kw, :atol, nothing), 0.0)
    # isapprox's default: rtol = √eps when no atol is given, 0 when one is.
    r = something(get(kw, :rtol, nothing), a > 0 ? 0.0 : sqrt(eps(Float64)))
    return (; got=pos[1], want=pos[2], atol=a, rtol=r)
end
_is_kw(a) = a isa Expr && a.head === :kw
# A call's arguments with its `; …` keywords spliced in, in order (a bare `; rtol` is not a value).
function _flat_args(args)
    return reduce(
        vcat,
        (
            a isa Expr && a.head === :parameters ? filter(_is_kw, a.args) : Any[a] for
            a in args
        );
        init=Any[],
    )
end
_approx_numbers(::Any) = nothing

# A recorded number. `Test` stores a failing expression as a string and it is reparsed, which turns a
# NaN/Inf value back into an identifier (and -Inf into a call): read those as the floats they were
# (#116), so a diverged computation keeps its numbers instead of losing them.
_tofloat(x::Real) = Float64(x)
function _tofloat(x::Symbol)
    x in (:NaN, :NaN64, :NaN32, :NaN16) && return NaN
    x in (:Inf, :Inf64, :Inf32, :Inf16) && return Inf
    return nothing
end
function _tofloat(x::Expr)
    (x.head === :call && length(x.args) == 2 && x.args[1] === :-) || return nothing
    v = _tofloat(x.args[2])
    return v === nothing ? nothing : -v
end
_tofloat(x::Any) = nothing

_margin(c::Check) = c.tol > 0 ? c.delta / c.tol : 0.0

# A stable fingerprint of the data a DERIVED figure (the margin / convergence SVGs) draws, folded into
# the figure's `code` so the render cache (which keys on code+params, computed without calling `gen`)
# re-materializes the SVG iff the underlying checks changed (issue #69 L). Without it, `code=""` gives
# every derived figure a CONSTANT key, so a docs rebuild falsely reuses a stale SVG when the numbers
# moved. Dumps carry the checks, so they carry this key material implicitly — no separate cache key.
function _checks_fingerprint(checks)
    return string(
        hash([(c.label, c.got, c.want, c.delta, c.tol, c.kind, c.pass) for c in checks])
    )
end

# ── the checks ───────────────────────────────────────────────────────

# One Check per @test. A numeric `isapprox` keeps its real got/want/tol (that is the whole point);
# anything else is encoded as a 1/0 indicator so that EVERY assertion still shows up in the
# machine-readable verdict rather than silently vanishing.
#
# `passed` is the TEST RUNNER's verdict, never recomputed from delta<=tol: isapprox combines atol and
# rtol in a way a single-kind Check cannot reproduce, and a report that disagrees with the test
# runner is worse than no report.
function _check_from(expr, label::AbstractString, passed::Bool, i::Int)
    id = Symbol("t", i)
    nums = _approx_numbers(expr)
    nums === nothing && return _indicator_check(id, label, passed)
    (; got, want, atol, rtol) = nums
    # No margin exists for a non-finite value or a zero tolerance: say so on the check, flagged as an
    # indicator, rather than emitting a non-finite delta or fabricated numbers (#116).
    (isfinite(got) && isfinite(want)) || return _indicator_check(
        id, "$(label)  [got = $(got), want = $(want): no margin]", passed
    )
    # isapprox passes iff |x-y| <= max(atol, rtol*max(|x|,|y|)) (#115). Record the term that
    # governs, so `delta <= tol` is exactly that test: absolute when atol is the larger bound, else
    # relative to max(|x|,|y|).
    scale = max(abs(got), abs(want))
    atol <= 0 &&
        rtol * scale <= 0 &&
        return _indicator_check(id, "$(label)  [zero tolerance: no margin]", passed)
    if atol >= rtol * scale
        return Check(id, String(label), got, want, abs(got - want), atol, :abs, passed)
    end
    return Check(id, String(label), got, want, abs(got - want) / scale, rtol, :rel, passed)
end

# A 1/0 pass indicator: every assertion still shows up in the verdict, but carries no margin.
function _indicator_check(id, label, passed)
    got = passed ? 1.0 : 0.0
    return Check(
        id, String(label), got, 1.0, abs(got - 1.0), 0.5, :abs, passed, "", "", false, true
    )
end

# ── the test tree (Test-free) ────────────────────────────────────────
#
# `TestNode` is the ONE shape of a captured suite: a live run builds it (each `PinaxTestSet` in the
# extension is a thin `AbstractTestSet` adapter holding one, #173), a shard dumps and reloads it, and
# the fold below walks it. It is a container in its own right — the same payload a `Section` carries
# (id/anchor, figures/tables/raws/codes/checks/texts + content order) — so a content macro inside a
# test pushes into it through the `_current_container()` seam exactly as into a section.
#
# It is not a `Section` because a section's place in the document is not known while the suite runs:
# whether a testset is a page (a file), a section, a grouping to flatten, or one sample of a swept
# `@testset for` is decided by the fold, from its siblings and `page_when`, after the run. The TOML
# dump persists checks + structure + tables/codes/desc (a `Figure.gen` is a closure and cannot cross
# the process boundary — carrying user figures through a shard is the E/L follow-up), so a loaded
# `TestNode` has no figures.
#
# This is what makes sharded CI work. Eight shards each run a disjoint set of test FILES; instead of
# eight disconnected galleries, each shard dumps its tree (no rendering at all) and one later job
# merges the trees and renders the single coherent gallery: one page per test file.
mutable struct TestNode
    description::String
    id::Symbol                  # the slug of `description` — what content-macro ids are built from
    anchor::String
    elapsed::Float64
    ignore::Bool                # @pinaxignore: ran and counted, but kept out of the document
    checks::Vector{Check}       # one per Pass / Fail / Error recorded directly here
    nbroken::Int                # @test_broken / skipped: counted, never a Check — see below
    nerror::Int                 # how many of the failing checks were ERRORS rather than plain fails
    children::Vector{TestNode}
    figures::Vector{Figure}
    tables::Vector{Table}
    raws::Vector{RawBlock}
    codes::Vector{CodeBlock}
    texts::Vector{Prose}                # @desc prose blocks
    content::Vector{Pair{Symbol,Int}}   # declaration order of texts/figures/tables/raws/checks/codes
    written::Set{Symbol}                # ids of its content the author wrote (`id=`); others generated
    dropped::Vector{Pair{String,String}} # id => why: what a shard dump could not carry (see the dump)
end

function TestNode(
    description::AbstractString;
    elapsed::Real=NaN,
    ignore::Bool=false,
    checks::Vector{Check}=Check[],
    nbroken::Integer=0,
    nerror::Integer=0,
    children::Vector{TestNode}=TestNode[],
    figures::Vector{Figure}=Figure[],
    tables::Vector{Table}=Table[],
    raws::Vector{RawBlock}=RawBlock[],
    codes::Vector{CodeBlock}=CodeBlock[],
    texts::Vector{Prose}=Prose[],
    content::Vector{Pair{Symbol,Int}}=Pair{Symbol,Int}[],
    written::Set{Symbol}=Set{Symbol}(),
    dropped::Vector{Pair{String,String}}=Pair{String,String}[],
)
    id = _slug(description)
    return TestNode(
        String(description),
        id,
        _anchor(id),
        Float64(elapsed),
        ignore,
        checks,
        nbroken,
        nerror,
        children,
        figures,
        tables,
        raws,
        codes,
        texts,
        content,
        written,
        dropped,
    )
end

# A broken/skipped test is deliberately NOT a Check. It has no verdict to show: it did not pass, but
# it did not fail either, and encoding it as `pass=false` would paint the page red and flip the
# benchmark verdict to FAIL — for a test the runner is perfectly happy about.
_ntests(n) = length(n.checks) + n.nbroken + sum(_ntests, n.children; init=0)
_nerror(n) = n.nerror + sum(_nerror, n.children; init=0)
_nbroken(n) = n.nbroken + sum(_nbroken, n.children; init=0)
function _nfail(n)
    here = count(c -> !c.pass, n.checks) - n.nerror
    return here + sum(_nfail, n.children; init=0)
end

function _summary_line(n)
    total, f, e, b = _ntests(n), _nfail(n), _nerror(n), _nbroken(n)
    t = isnan(n.elapsed) ? "" : " · $(round(n.elapsed; digits=2))s"
    return "$(total - f - e - b)/$(total) passed" *
           (f > 0 ? " · $(f) failed" : "") *
           (e > 0 ? " · $(e) errored" : "") *
           (b > 0 ? " · $(b) broken" : "") *
           t
end

# The largest delta/tol among this subtree's NUMERIC checks — how close the file came to red.
function _worst_margin(n)
    worst = nothing
    for c in n.checks
        c.indicator && continue   # a 1/0 pass indicator carries no margin
        m = _margin(c)
        worst = worst === nothing ? m : max(worst, m)
    end
    for ch in n.children
        m = _worst_margin(ch)
        m === nothing || (worst = worst === nothing ? m : max(worst, m))
    end
    return worst
end

# ── the margin profile figure ────────────────────────────────────────
#
# A hand-written SVG, on purpose. `@figure`'s `gen` may return a FILE PATH (backends.jl) — a
# first-class case needing no plotting extension — so a test report draws itself without dragging
# Plots/Makie into every package's test env, which is the only reason this bridge is free to adopt.
#
# The bar is `delta/tol` (how much of its tolerance budget the check spent), clipped at 1.2 with the
# real value always printed. The line at 1.0 IS the pass/fail boundary: a bar that nearly touches it
# is a green test that is one refactor from red — the thing a CI badge cannot tell you.
const _MARGIN_W = 620
const _BAR_H = 18

function _margin_svg(checks::Vector{Check}, path::AbstractString)
    n = length(checks)
    left, top = 250, 26
    h = top + n * _BAR_H + 34
    axis_w = _MARGIN_W - left - 60
    x_of(m) = left + axis_w * min(m, 1.2) / 1.2
    io = IOBuffer()
    print(
        io,
        """<svg xmlns="http://www.w3.org/2000/svg" width="$(_MARGIN_W)" height="$(h)" font-family="ui-monospace,SFMono-Regular,Menlo,monospace" font-size="11">
        <text x="8" y="14" font-size="12" fill="#444">tolerance budget spent (delta / tol)</text>
        """,
    )
    for (i, c) in enumerate(checks)
        m = _margin(c)
        y = top + (i - 1) * _BAR_H
        fill = if !c.pass
            "#d9534f"
        elseif m > 0.75
            "#e8a33d"
        else
            "#4c9f70"
        end
        lab = length(c.label) > 34 ? c.label[1:31] * "…" : c.label
        w = max(x_of(m) - left, 1.0)
        print(
            io,
            """<text x="$(left - 8)" y="$(y + 13)" text-anchor="end" fill="#333">$(_xml(lab))</text>
            <rect x="$(left)" y="$(y + 3)" width="$(round(w; digits=1))" height="$(_BAR_H - 7)" fill="$(fill)" rx="2"/>
            <text x="$(round(x_of(m) + 6; digits=1))" y="$(y + 13)" fill="#666">$(_fmt_margin(m))</text>
            """,
        )
    end
    # the pass/fail boundary
    xt = x_of(1.0)
    print(
        io,
        """<line x1="$(xt)" y1="$(top - 4)" x2="$(xt)" y2="$(top + n * _BAR_H + 2)" stroke="#d9534f" stroke-width="1" stroke-dasharray="3,2"/>
        <text x="$(xt + 3)" y="$(top + n * _BAR_H + 14)" fill="#d9534f">tol</text>
        <line x1="$(left)" y1="$(top - 4)" x2="$(left)" y2="$(top + n * _BAR_H + 2)" stroke="#bbb" stroke-width="1"/>
        </svg>
        """,
    )
    write(path, take!(io))
    return path
end

_xml(s) = replace(String(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", "\"" => "&quot;")
_fmt_margin(m) = m >= 10 ? "$(round(Int, m))×" : "$(round(m; digits=2))"

# The largest number of bars the per-page margin figure draws (issue #69 J): a 10k-check suite would
# otherwise emit a 10k-bar SVG that no one can read. We keep the WORST `_MAX_MARGIN_BARS` (highest
# delta/tol — so every failure and every near-miss survives; only comfortably-passing bars are dropped),
# and the caption says how many of how many are shown. The full per-check data is still in `agent.json`.
const _MAX_MARGIN_BARS = 40

# The figure for one page's checks: how far each assertion sat from its own tolerance.
function _push_margin_figure!(page_id::Symbol, checks::Vector{Check})
    isempty(checks) && return nothing
    total = length(checks)
    # the checks drawn, by their number on the page, in that order — capped or not
    xs = if total <= _MAX_MARGIN_BARS
        collect(1:total)
    else
        sort(partialsortperm(checks, 1:_MAX_MARGIN_BARS; by=_margin, rev=true))
    end
    shown = checks[xs]
    capped = length(shown) < total
    # `data=` must be plot-data (`series=[(; label, x, y)]`) — it is the figure's TEXT channel for the
    # agent backend. The per-check got/want/tol already ride along in the benchmark `checks` JSON, so
    # the series carries only what the picture itself shows: the margin of check number i.
    data = (;
        xlabel="check #",
        ylabel="delta / tol",
        series=[
            (; label="margin", x=xs, y=[_margin(c) for c in shown]),
            (; label="pass/fail boundary", x=xs, y=fill(1.0, length(xs))),
        ],
    )
    cap_note = if capped
        " Showing the $(length(shown)) worst of $(total) checks (the rest are in agent.json)."
    else
        ""
    end
    _push_figure!(;
        gen=() -> _margin_svg(shown, tempname() * ".svg"),
        code=_checks_fingerprint(shown),   # data-keyed so a rebuild re-draws iff the checks moved (L)
        caption="Tolerance budget spent by each check. The dashed line is the pass/fail " *
                "boundary — a bar close to it passed, but barely." *
                cap_note,
        gen_id=Symbol(page_id, :_margins),
        data=data,
    )
    return nothing
end

# ── sweeps: an unnamed `@testset for` is a SAMPLE, not a section (issue #69 point C) ──
#
# Test's `testset_forloop` emits, for `@testset for χ in (8, 16)` written with NO description, one child
# testset per iteration whose description is the machine-generated canonical string `"χ = 8"` (and
# `"χ = 8, β = 0.1"` for a multi-variable `for χ in …, β in …`). We read the axis ONLY from that
# canonical string (invariant III) — never from a human-written description. When EVERY child of a
# level parses to a binding over the SAME variables, that level is a SWEEP, not a stack of sections: its
# checks are collected, keyed by test expression (the quantity), each tagged with its binding, and drawn
# as a convergence figure (got vs axis, want reference, tolerance band) and a margin figure (delta/tol
# vs axis) — one pair per quantity — instead of N near-identical repeated sections. The INNERMOST loop
# is the x-axis; the outer loops collapse into the series legend (C3: no facet grid, one composite key).
#
# Decisions for the open points in #69 C:
#   • C1 non-numeric axis (`for model in (:TFIM, :Heisenberg)`) → a CATEGORICAL x-axis (evenly-spaced
#     ticks labelled by the value string). Same figure, categorical ticks — not small multiples.
#   • C2 a binding that does not round-trip → a non-issue here: the axis key is ALWAYS the canonical
#     STRING Test already produced, never the live object, so nothing needs to serialize. No index
#     fallback is needed; the string label IS the stable key (and it dumps as-is for a sharded run).
#   • C3 three or more nested loops → innermost = x, ALL outer bindings join into ONE legend key.
#   • C4 a render-side `x_axis=` override is deferred: the code is the figure spec (innermost = x).
#
# The whole thing is Test-free and walks the same `TestNode` tree `_emit_node!` does, so a
# sharded run gets its sweeps too: a dump carries child descriptions + checks, and the fold rebuilds the
# convergence figure from the merged tree with no extra machinery.

const _SERIES_COLORS = [
    "#4c78a8", "#f58518", "#54a24b", "#e45756", "#72b7b2", "#b279a2", "#ff9da6", "#9d755d"
]

# Split on top-level commas only — a bound value may itself be a tuple `(1, 2)`, so track bracket depth.
function _split_top_commas(s::AbstractString)
    segs = String[]
    depth = 0
    start = firstindex(s)
    for (i, ch) in pairs(s)
        if ch in ('(', '[', '{')
            depth += 1
        elseif ch in (')', ']', '}')
            depth = max(depth - 1, 0)
        elseif ch == ',' && depth == 0
            push!(segs, s[start:prevind(s, i)])
            start = nextind(s, i)
        end
    end
    push!(segs, s[start:end])
    return segs
end

# Parse Test's canonical forloop description into `[var => value-string, …]`, or `nothing` if it is not
# canonical. Each top-level segment must be `<identifier> = <value>` (an identifier LHS is exactly what
# a loop variable produces); anything else — a human sentence, a name with no `=` — does not fold.
function _parse_binding(desc::AbstractString)
    out = Pair{Symbol,String}[]
    for seg in _split_top_commas(desc)
        eq = findfirst('=', seg)
        eq === nothing && return nothing
        lhs = strip(seg[1:prevind(seg, eq)])
        rhs = strip(seg[nextind(seg, eq):end])
        # LHS must be a real identifier (a loop variable), and the RHS must not itself start with `=`
        # (guards `==`/`>=`/`<=` — a human comparison, never a Test forloop binding). Unicode-aware, so
        # `χ`/`β`/… parse (a character-class regex would miss them).
        (isempty(lhs) || isempty(rhs) || startswith(rhs, "=")) && return nothing
        Base.isidentifier(lhs) || return nothing
        push!(out, Symbol(lhs) => String(rhs))
    end
    return isempty(out) ? nothing : out
end

_binding_vars(b) = Symbol[k for (k, _) in b]
_binding_str(b) = join(("$(k) = $(v)" for (k, v) in b), ", ")

# A level is a sweep iff it has children, every non-ignored one parses to a binding, and they all agree
# on the variable sequence. A test FILE is never a sample (it is a page), and a mix of canonical and
# non-canonical siblings does not fold (we keep them as sections and warn — never silently).
function _is_swept(n, page_when::Function)
    vars = nothing
    any = false
    for ch in n.children
        ch.ignore && continue
        page_when(ch.description) && return false
        b = _parse_binding(ch.description)
        b === nothing && return false
        v = _binding_vars(b)
        vars === nothing ? (vars = v) : (v == vars || return false)
        any = true
    end
    return any
end

# Every leaf Check under a swept node, each tagged with its full binding stack (recursing through nested
# sweeps, flattening any non-sweep structure inside a sample). Returns `[(bindings, check), …]`.
function _sweep_samples!(out, n, prefix, page_when::Function)
    for ch in n.children
        ch.ignore && continue
        b = _parse_binding(ch.description)
        stack = b === nothing ? prefix : vcat(prefix, b)
        if _is_swept(ch, page_when)
            _sweep_samples!(out, ch, stack, page_when)
        else
            for c in _collect_checks!(Check[], ch)
                push!(out, (stack, c))
            end
        end
    end
    return out
end

function _collect_checks!(acc, n)
    append!(acc, n.checks)
    for ch in n.children
        ch.ignore || _collect_checks!(acc, ch)
    end
    return acc
end

# Every distinct `@code` artifact captured anywhere in a swept subtree, in first-seen order.
function _swept_codes(n, out=CodeBlock[])
    for blk in n.codes
        any(b -> b.id === blk.id, out) || push!(out, blk)
    end
    for ch in n.children
        _swept_codes(ch, out)
    end
    return out
end

# What a sweep cannot place: the content its samples wrote besides checks and code (the checks and
# the code are folded), as `macro => count` in a fixed order, over the whole swept subtree.
const _SWEEP_UNPLACED = (
    "@desc" => :texts, "@figure" => :figures, "@table" => :tables, "@raw" => :raws
)
_sweep_unplaced(n) = [m => _subtree_count(n, f) for (m, f) in _SWEEP_UNPLACED]
function _subtree_count(n, f)
    return length(getfield(n, f)) + sum(ch -> _subtree_count(ch, f), n.children; init=0)
end

# Group samples by quantity = the check label (the test expression `orig_expr`, which is loop-invariant,
# so it is a stable identity across iterations — issue #69 B). Preserves first-seen order.
function _group_quantities(samples)
    order = String[]
    groups = Dict{String,typeof(samples)}()
    for s in samples
        key = s[2].label
        haskey(groups, key) || (push!(order, key); groups[key]=typeof(samples)())
        push!(groups[key], s)
    end
    return [(k, groups[k]) for k in order]
end

# Render a swept level: a convergence + margin figure per quantity, then every sample check placed flat
# (binding-tagged) so the page's pass/fail counts and `agent.json` verdict stay exactly what they were —
# the sweep changes only how the checks are DRAWN, never the verdict.
function _emit_sweep!(n, page_when::Function, acc::Vector{Check})
    c = _ctx_container()
    samples = _sweep_samples!(
        Tuple{Vector{Pair{Symbol,String}},Check}[], n, Pair{Symbol,String}[], page_when
    )
    isempty(samples) && return acc
    unplaced = join(("$(k) × $(m)" for (m, k) in _sweep_unplaced(n) if k > 0), ", ")
    isempty(unplaced) || _diag!(
        WARNING,
        string(c.id, "_sweep"),
        "$(unplaced) inside a swept `@testset for` is not folded yet — omitted from the sweep view (issue #69 E follow-up)",
    )
    # The samples are folded away, but the CODE they captured is the sweep's specification (the loop
    # header + the assertion), so it must survive the fold: lift it to the section, deduplicated, ahead
    # of the figures it explains.
    for blk in _swept_codes(n)
        _place_code!(c, blk, n.written)
    end
    qi = Ref(0)
    for (label, pts) in _group_quantities(samples)
        _push_sweep_figures!(c.id, qi, label, pts)
    end
    for (bind, chk) in samples
        tagged = _copy_check(chk; label=string(chk.label, "  [", _binding_str(bind), "]"))
        _place_check!(c, tagged, acc)
    end
    return acc
end

# Build the two figures for one quantity. Innermost binding = x (numeric → a real axis, else categorical
# ticks); outer bindings = the legend. `want`/`tol` recover the reference line and tolerance band.
function _push_sweep_figures!(cid::Symbol, qi::Ref{Int}, label::AbstractString, pts)
    ax = _sweep_axis(pts)
    conv, marg = _sweep_series(pts, ax)
    qi[] += 1
    q = _trunc(label, 44)
    # both SVGs derive from `pts` (+ the axis) — one data fingerprint keys their cache (issue #69 L).
    fp = string(
        hash((
            ax.xvar,
            ax.labels,
            [
                (_binding_str(b), c.got, c.want, c.delta, c.tol, c.kind, c.pass) for
                (b, c) in pts
            ],
        )),
    )
    _conv_figure!(Symbol(cid, :_conv_, qi[]), q, ax, conv, fp)
    _margin_figure!(Symbol(cid, :_swpmargin_, qi[]), q, ax, marg, fp)
    return nothing
end

# The swept axis: its variable, its ticks in order (numeric ones by value), their labels, and each
# tick's position.
function _sweep_axis(pts)
    vals = _sweep_x.(pts)
    numeric = all(v -> tryparse(Float64, v) !== nothing, vals)
    ticks = numeric ? sort(unique(vals); by=s -> parse(Float64, s)) : unique(vals)
    return (;
        xvar=last(_binding_vars(pts[1][1])),
        numeric,
        ticks,
        labels=numeric ? [_fmt_num(parse(Float64, t)) for t in ticks] : ticks,
        index=Dict(t => i for (i, t) in enumerate(ticks)),
    )
end
_sweep_x(p) = last(p[1])[2]
_legend_key(p) = _binding_str(p[1][1:(end - 1)])
# The axis's value at a tick: the number itself, or the category — what a data file must hold (a
# tick's position is a drawing detail).
_axis_value(ax, i) = ax.numeric ? parse(Float64, ax.ticks[i]) : ax.ticks[i]

# One convergence and one margin series per legend entry. Each series keeps its own reference and
# tolerance band (#130): two series with different `want` at one tick must not share whichever band
# was folded last.
function _sweep_series(pts, ax)
    both = [
        _one_series(filter(p -> _legend_key(p) == lg, pts), ax, lg) for
        lg in unique(_legend_key.(pts))
    ]
    return NamedTuple[first(b) for b in both], NamedTuple[last(b) for b in both]
end

function _one_series(pts, ax, lg)
    xs = [ax.index[_sweep_x(p)] for p in pts]
    perm = sortperm(xs)
    cs = [p[2] for p in pts][perm]
    # the pass boundary isapprox applies: rel is relative to max(|got|,|want|) (#115)
    tolabs = [c.kind === :rel ? c.tol * max(abs(c.got), abs(c.want)) : c.tol for c in cs]
    want = [c.want for c in cs]
    ok = [c.pass for c in cs]
    conv = (;
        label=lg,
        xs=xs[perm],
        ys=[c.got for c in cs],
        ok,
        want,
        lo=want .- tolabs,
        hi=want .+ tolabs,
    )
    return conv, (; label=lg, xs=xs[perm], ys=_margin.(cs), ok)
end

function _conv_figure!(id, q, ax, series, fp)
    _push_figure!(;
        gen=() -> _sweep_plot_svg(
            tempname() * ".svg";
            title="convergence — $(q)",
            xlabel=string(ax.xvar),
            ylabel="got",
            xticklabels=ax.labels,
            series=series,
        ),
        code=fp,
        caption="Convergence of `$(q)` over the swept axis `$(ax.xvar)`. Dashed line = `want`; the shaded " *
                "band is the tolerance; a red marker is a failed check.",
        gen_id=id,
        data=(;
            xlabel=string(ax.xvar),
            ylabel="got",
            # what the plot draws, per series: the values, the reference and the tolerance band
            series=[
                (;
                    label=isempty(s.label) ? name : string(s.label, " ", name),
                    x=[_axis_value(ax, i) for i in s.xs],
                    y=getfield(s, field),
                ) for s in series for
                (name, field) in (("got", :ys), ("want", :want), ("lo", :lo), ("hi", :hi))
            ],
        ),
    )
    return nothing
end

function _margin_figure!(id, q, ax, series, fp)
    _push_figure!(;
        gen=() -> _sweep_plot_svg(
            tempname() * ".svg";
            title="margin — $(q)",
            xlabel=string(ax.xvar),
            ylabel="delta / tol",
            xticklabels=ax.labels,
            series=series,
            hline=1.0,
        ),
        code=fp,
        caption="Tolerance budget `delta/tol` of `$(q)` over `$(ax.xvar)`; the dashed line at 1.0 is the " *
                "pass/fail boundary.",
        gen_id=id,
        data=(;
            xlabel=string(ax.xvar),
            ylabel="delta / tol",
            series=[
                (;
                    label=isempty(s.label) ? "margin" : s.label,
                    x=[_axis_value(ax, i) for i in s.xs],
                    y=s.ys,
                ) for s in series
            ],
        ),
    )
    return nothing
end

_trunc(s, n) = length(s) > n ? first(s, n - 1) * "…" : String(s)
function _fmt_num(v)
    isfinite(v) || return ""
    return (isinteger(v) && abs(v) < 1e15) ? string(Int(v)) : string(round(v; sigdigits=4))
end

# A small multi-series line plot as hand-written SVG (same reason as `_margin_svg`: `@figure`'s gen may
# return a file path, so a test report draws itself without dragging a plotting backend into every test
# env). `series` is `[(; label, xs::Vector{Int}, ys::Vector{Float64}, ok::Vector{Bool}), …]` where `xs`
# index into `xticklabels`; a series carrying `want`/`lo`/`hi` also gets its own shaded tolerance band
# and dashed reference; `hline` draws one horizontal boundary. y is auto-scaled over everything drawn.
function _sweep_plot_svg(
    path; title, xlabel, ylabel, xticklabels::Vector{String}, series, hline=nothing
)
    g = _plot_frame(length(xticklabels), _y_extent(series, hline)...)
    io = IOBuffer()
    _svg_axes(io, g, title, xlabel, ylabel, xticklabels)
    _svg_bands(io, g, series)
    hline === nothing || _svg_hline(io, g, hline)
    _svg_series(io, g, series)
    print(io, "</svg>\n")
    write(path, take!(io))
    return path
end

_series_color(si) = _SERIES_COLORS[(si - 1) % length(_SERIES_COLORS) + 1]

# The y range drawn — every finite value, reference and band edge, and `hline` — padded by 8%, with
# the pad itself (the outer ticks sit one pad inside the range).
function _y_extent(series, hline)
    ys = Float64[]
    for s in series
        append!(ys, filter(isfinite, s.ys))
        hasproperty(s, :want) && append!(
            ys, filter(isfinite, s.lo), filter(isfinite, s.hi), filter(isfinite, s.want)
        )
    end
    hline === nothing || push!(ys, hline)
    isempty(ys) && (ys = [0.0, 1.0])
    ylo, yhi = extrema(ys)
    ylo == yhi && (ylo -= 0.5; yhi += 0.5)
    pad = 0.08 * (yhi - ylo)
    return ylo - pad, yhi + pad, pad
end

# The plot's geometry: the canvas, its margins, and where tick `i` and value `v` land.
function _plot_frame(K, ylo, yhi, pad)
    W, H, L, R, T, Bm = 640, 300, 66, 150, 30, 46
    plotw, ploth = W - L - R, H - T - Bm
    xat(i) = K <= 1 ? L + plotw / 2 : L + plotw * (i - 1) / (K - 1)
    yat(v) = T + ploth * (1 - (v - ylo) / (yhi - ylo))
    return (; W, H, L, T, plotw, ploth, ylo, yhi, pad, xat, yat)
end

# The canvas, the title, both axes with their labels and ticks.
function _svg_axes(io, g, title, xlabel, ylabel, xticklabels)
    (; W, H, L, T, plotw, ploth, ylo, yhi, pad, xat, yat) = g
    print(
        io,
        """<svg xmlns="http://www.w3.org/2000/svg" width="$(W)" height="$(H)" font-family="ui-monospace,Menlo,monospace" font-size="11">
        <text x="$(L)" y="16" font-size="12" fill="#444">$(_xml(title))</text>
        <line x1="$(L)" y1="$(T)" x2="$(L)" y2="$(T + ploth)" stroke="#bbb"/>
        <line x1="$(L)" y1="$(T + ploth)" x2="$(L + plotw)" y2="$(T + ploth)" stroke="#bbb"/>
        <text x="$(L + plotw / 2)" y="$(H - 8)" text-anchor="middle" fill="#444">$(_xml(xlabel))</text>
        <text x="14" y="$(T + ploth / 2)" transform="rotate(-90 14 $(T + ploth / 2))" text-anchor="middle" fill="#444">$(_xml(ylabel))</text>
        """,
    )
    for v in (ylo + pad, (ylo + yhi) / 2, yhi - pad)
        y = yat(v)
        print(
            io,
            """<line x1="$(L - 4)" y1="$(y)" x2="$(L)" y2="$(y)" stroke="#bbb"/><text x="$(L - 7)" y="$(y + 3)" text-anchor="end" fill="#888">$(_fmt_num(v))</text>\n""",
        )
    end
    for (i, lab) in enumerate(xticklabels)
        x = xat(i)
        print(
            io,
            """<line x1="$(x)" y1="$(T + ploth)" x2="$(x)" y2="$(T + ploth + 4)" stroke="#bbb"/><text x="$(x)" y="$(T + ploth + 16)" text-anchor="middle" fill="#888">$(_xml(lab))</text>\n""",
        )
    end
    return nothing
end

# Each series' own tolerance band and dashed reference, in its colour (#130); a band identical to
# one already drawn (series sharing a reference) is drawn once.
function _svg_bands(io, g, series)
    drawn = Set{Any}()
    for (si, s) in enumerate(series)
        hasproperty(s, :want) || continue
        key = (s.xs, s.lo, s.hi, s.want)
        key in drawn && continue
        push!(drawn, key)
        _svg_band(io, g, s, _series_color(si))
    end
    return nothing
end

function _svg_band(io, g, s, col)
    (; xat, yat) = g
    keep = [j for j in eachindex(s.xs) if isfinite(s.lo[j]) && isfinite(s.hi[j])]
    hi_pts = ["$(xat(s.xs[j])),$(yat(s.hi[j]))" for j in keep]
    lo_pts = reverse!(["$(xat(s.xs[j])),$(yat(s.lo[j]))" for j in keep])
    isempty(hi_pts) || print(
        io,
        """<polygon points="$(join(vcat(hi_pts, lo_pts), " "))" fill="$(col)" fill-opacity="0.12"/>\n""",
    )
    _svg_polyline(
        io,
        g,
        s.xs,
        s.want,
        "stroke=\"$(col)\" stroke-width=\"1.3\" stroke-dasharray=\"4,3\"",
    )
    return nothing
end

# A line through the finite points of `ys` at ticks `xs`, when there are two to join.
function _svg_polyline(io, g, xs, ys, style)
    (; xat, yat) = g
    d = ["$(xat(xs[j])),$(yat(ys[j]))" for j in eachindex(xs) if isfinite(ys[j])]
    length(d) >= 2 &&
        print(io, """<polyline points="$(join(d, " "))" fill="none" $(style)/>\n""")
    return nothing
end

function _svg_hline(io, g, hline)
    (; L, plotw, yat) = g
    y = yat(hline)
    print(
        io,
        """<line x1="$(L)" y1="$(y)" x2="$(L + plotw)" y2="$(y)" stroke="#d9534f" stroke-width="1" stroke-dasharray="3,2"/><text x="$(L + plotw)" y="$(y - 3)" text-anchor="end" fill="#d9534f">tol</text>\n""",
    )
    return nothing
end

# Each series' line and markers (a failed check's in red), and its legend entry when it has a label.
function _svg_series(io, g, series)
    (; L, T, plotw, xat, yat) = g
    ly = T + 4
    for (si, s) in enumerate(series)
        col = _series_color(si)
        _svg_polyline(io, g, s.xs, s.ys, "stroke=\"$(col)\" stroke-width=\"1.6\"")
        for j in eachindex(s.xs)
            isfinite(s.ys[j]) || continue
            print(
                io,
                """<circle cx="$(xat(s.xs[j]))" cy="$(yat(s.ys[j]))" r="3" fill="$(s.ok[j] ? col : "#d9534f")" stroke="#fff" stroke-width="0.6"/>\n""",
            )
        end
        isempty(s.label) && continue
        print(
            io,
            """<line x1="$(L + plotw + 10)" y1="$(ly)" x2="$(L + plotw + 26)" y2="$(ly)" stroke="$(col)" stroke-width="2"/><text x="$(L + plotw + 30)" y="$(ly + 3)" fill="#555">$(_xml(_trunc(s.label, 18)))</text>\n""",
        )
        ly += 15
    end
    return nothing
end

# ── the document ─────────────────────────────────────────────────────

# Assign a COLLISION-FREE id: `base` if unseen, else `base-2`, `base-3`, … plus a loud diagnostic —
# two distinct nodes must never fold onto one anchor / `agent.json` id silently (a `_slug(desc)` is
# flat, so two same-named test files or sections would otherwise clash). `seen` accumulates every
# page/section id assigned in the document; page ids are global, section ids are page-qualified.
function _unique_id!(seen::Set{Symbol}, base::Symbol, desc)
    id = _free_id(base, in(seen))
    push!(seen, id)
    id === base || _diag!(
        WARNING,
        string(id),
        "duplicate id \"$(base)\" (from \"$(desc)\") → disambiguated to $(id); rename the testset to fix",
    )
    return id
end

# `acc` collects every Check pushed anywhere in this subtree, in emission order. A page's checks are
# spread across its @sections (that is the whole nesting), so the page-level margin figure cannot be
# rebuilt from the page container alone — it has to be accumulated on the way down.
#
# `n` is a live run's tree (it carries user `@figure`s too) or a merged shard dump (no figures) — the
# same `TestNode` either way, so there is one fold.
function _emit_node!(
    n::TestNode,
    page_when::Function,
    seen::Set{Symbol},
    acc::Vector{Check}=Check[];
    id_prefix::AbstractString="",
)
    if _ctx_container() === nothing && _has_own_content(n)
        # content written at the top level (the usual `@testset "MyPkg"` wrapper holds checks and
        # prose of its own) has no page to land on, so it gets one — never folded away while the
        # overview counts it
        _emit_page_node!(n, n, page_when, seen, acc; id_prefix, recurse=false)
    else
        _emit_own_content!(n, acc)
    end
    # A level whose children are all canonical `@testset for` samples is a SWEEP, not a stack of
    # sections: fold it into convergence + margin figures (issue #69 C). Only inside an open container
    # (a page/section) — never at the root, where children are files and the grouping-flatten runs.
    if _ctx_container() !== nothing && _is_swept(n, page_when)
        _emit_sweep!(n, page_when, acc)
        return acc
    end
    # Nested testsets become pages (a file) or sections (a group). @pinaxignore'd ones are skipped
    # HERE only — never in the counts, so an ignored subtree still fails the suite if it is red.
    for ch in n.children
        ch.ignore || _emit_child!(ch, page_when, seen, acc, id_prefix)
    end
    return acc
end

function _emit_child!(ch::TestNode, page_when, seen, acc, id_prefix)
    if _ctx_container() !== nothing
        # A file is a page only at the top level: a page is never written inside another page
        # (Conventions › Structure), so a file-like testset inside one is a section of it.
        _emit_section_node!(ch, page_when, seen, acc, id_prefix)
    elseif page_when(ch.description)
        # Page ids are GLOBAL. Under a CI matrix (issue #69 K) the same file appears in every cell,
        # so `id_prefix` qualifies the id per cell — distinct pages under distinct `@part`s, no
        # spurious duplicate-id collisions.
        _emit_page_node!(ch, ch, page_when, seen, acc; id_prefix)
    else
        # At the root with no page open, a non-file testset is a GROUPING (e.g. the top-level
        # `@testset "MyPkg"` that most runtests wrap everything in) → flatten it: its children
        # become top-level pages, exactly as `_collect_rows!` already treats it. A section needs a
        # page, which a grouping at this level does not provide.
        _emit_node!(ch, page_when, seen, acc; id_prefix=id_prefix)
    end
    return acc
end

function _emit_section_node!(ch::TestNode, page_when, seen, acc, id_prefix)
    _warn_unfolded_sample!(ch, seen)
    # Section ids are PAGE-QUALIFIED (`<pageid>_<slug>`) so a "conv" section in two files does
    # not clash; a true sibling collision within one page then gets the `-2` suffix.
    sid = _unique_id!(
        seen, Symbol(current_page().id, :_, _slug(ch.description)), ch.description
    )
    _enter_section!(sid, ch.description; summary=_summary_line(ch))
    try
        _emit_node!(ch, page_when, seen, acc; id_prefix=id_prefix)
    finally
        _exit_section!()
    end
    return acc
end

# A child that parses as a canonical binding but is being rendered as a SECTION means its siblings
# are not a consistent sweep (mixed/partial) — so it was not folded. Say so once (invariant III:
# never fall back to silence); it is then rendered as an ordinary section.
function _warn_unfolded_sample!(ch::TestNode, seen)
    (_parse_binding(ch.description) === nothing || :_sweep_warned in seen) && return nothing
    push!(seen, :_sweep_warned)
    _diag!(
        WARNING,
        "sweep",
        "a `@testset for` sample could not be folded (its siblings are not a consistent " *
        "canonical sweep) — rendered as a section instead",
    )
    return nothing
end

# Move THIS node's own captured content (texts + figures/tables/raws + checks) into the CTX
# container just entered, preserving declaration order. A captured node carries the full interleaved
# `content`; one without it (a legacy dump, or a node built by hand) falls back to its checks. Uses
# `_ctx_container()` (never the probe) — the fold builds the doc in `CTX`.
function _emit_own_content!(n::TestNode, acc::Vector{Check})
    c = _ctx_container()
    c === nothing && return acc
    union!(_ensure_document!().written, n.written)   # the ids its author wrote stay written
    # No interleaved `content` (a legacy dump, a hand-built node) — place checks then codes directly,
    # so a dumped `@code` still shows.
    if isempty(n.content) && (!isempty(n.checks) || !isempty(n.codes))
        placed = [_place_check!(c, chk, acc) for chk in n.checks]
        for blk in n.codes
            _place_code!(c, blk, n.written)
        end
        foreach(chk -> _repoint_code!(c, chk), placed)   # its code block was placed after it
        return acc
    end
    # the one registry of content kinds: a kind it does not know is an error, never dropped
    for (kind, node) in _content_items(n)
        if kind === :check
            _place_check!(c, node, acc)
        elseif kind === :code
            _place_code!(c, node, n.written)
        else
            nodes = getfield(c, _content_field(c, kind))
            push!(nodes, _place_captured(c, node, n.written, _KIND_NAME[kind]))
            push!(c.content, kind => length(nodes))
        end
    end
    return acc
end

# What a placed node is called in an id collision's error.
const _KIND_NAME = (; figure="figure", table="table", raw="raw block", text="prose block")

# A node captured in a test, placed in the document: its id is claimed in the whole document
# (Conventions › Identity), since it was named inside its test node only. An id the author wrote is
# claimed as is — a repeat is an error, as everywhere — and a generated one steps aside with `-2`.
function _place_captured(c, node, written, what)
    where = string(what, " in \"", c.anchor, "\"")
    id = node.id in written ? _claim!(node.id, where) : _claim!(_free_id(node.id), where)
    return id === node.id ? node : _with_id(node, id)
end

# The same node under another id, with the anchor that follows it.
function _with_id(x::T, id::Symbol) where {T}
    return T((
        if f === :id
            id
        elseif f === :anchor
            _anchor(id)
        else
            getfield(x, f)
        end for f in fieldnames(T)
    )...)
end

# A captured code block, placed at most once per container: a sweep's samples and a sweep's shards
# carry the same snippet under one id, and it shows once. Its id in the document is remembered, so
# the checks that point at it keep pointing at it. The same snippet in another container is a node
# of its own, under a free id.
function _place_code!(c, blk, written)
    key = (c.id, blk.id)
    haskey(_ensure_document!().fold_codes, key) && return nothing
    placed = _place_captured(c, blk, written, "code block")
    _ensure_document!().fold_codes[key] = placed.id
    push!(c.codes, placed)
    push!(c.content, :code => length(c.codes))
    return placed
end

# Point a placed check at its code block's id in the document.
function _repoint_code!(c, chk)
    isempty(chk.code_anchor) && return chk
    id = get(_ensure_document!().fold_codes, (c.id, Symbol(chk.code_anchor)), nothing)
    id === nothing || (chk.code_anchor = _anchor(id))
    return chk
end

function _has_own_content(n::TestNode)
    return !isempty(n.checks) || !isempty(n.content) || !isempty(n.codes)
end

# `n` as a page of its own: its content and (with `recurse`) its subtree, then its margin figure.
# `summary_of` is the node whose verdict the page header states.
function _emit_page_node!(
    n::TestNode, summary_of, page_when, seen, acc; id_prefix="", recurse=true
)
    pid = _unique_id!(seen, Symbol(id_prefix, _slug(n.description)), n.description)
    _enter_page!(pid, n.description; summary=_summary_line(summary_of))
    try
        page_checks = Check[]
        if recurse
            _emit_node!(n, page_when, seen, page_checks; id_prefix=id_prefix)
        else
            _emit_own_content!(n, page_checks)
        end
        append!(acc, page_checks)
        # Back at page level (every section closed), so the figure lands on the page.
        _push_margin_figure!(pid, page_checks)
    finally
        _exit_page!()
    end
    return acc
end

# A check's id in a page or section — stable: container + source text (#123) — claimed in the whole
# document, so no node written later takes it (Conventions › Identity).
function _claim_check_id!(c, label)
    return _claim!(_check_id(c, label), string("check in \"", c.anchor, "\""))
end

# Assign the check its id in the document (a dump carries none, so N merged shards never collide)
# and place it into the current container + content order + margin accumulator.
function _place_check!(c, chk::Check, acc::Vector{Check})
    # a copy: the fold must not renumber (or later tag) the tree's own Check (#130)
    chk = _copy_check(chk; id=_claim_check_id!(c, chk.label))
    _repoint_code!(c, chk)
    push!(c.checks, chk)
    push!(c.content, :check => length(c.checks))
    push!(acc, chk)
    return chk
end

function _collect_rows!(rows::Vector{NamedTuple}, n, page_when::Function)
    for ch in n.children
        ch.ignore && continue
        if page_when(ch.description)
            m = _worst_margin(ch)
            push!(
                rows,
                (
                    file=ch.description,
                    tests=_ntests(ch),
                    passed=_ntests(ch) - _nfail(ch) - _nerror(ch) - _nbroken(ch),
                    failed=_nfail(ch),
                    errored=_nerror(ch),
                    seconds=isnan(ch.elapsed) ? missing : round(ch.elapsed; digits=2),
                    worst_margin=m === nothing ? missing : round(m; digits=3),
                ),
            )
        else
            _collect_rows!(rows, ch, page_when)
        end
    end
    return rows
end

# ── provenance (issue #69 H) ─────────────────────────────────────────
#
# The facts a test artifact must record to not lie: WHEN it ran, against WHAT code, on WHICH Julia/OS.
# A green report with no commit/date is indistinguishable from a stale one, and a stochastic suite with
# no recorded seed/commit is an artifact you cannot trust. Captured NON-FATALLY at render — any field
# that cannot be read is simply omitted (never an error, invariant IV) — with CI variables preferred
# over a local `git` probe (they are reliable inside the `Pkg.test` sandbox, where `git` may be absent).
function _provenance_rows()
    rows = NamedTuple[]
    add(f, v) =
        (v === nothing || isempty(string(v))) || push!(rows, (field=f, value=string(v)))
    add("generated", Base.Libc.strftime("%Y-%m-%d %H:%M:%S", time()))
    add("julia", VERSION)
    add("os", string(Sys.KERNEL, " / ", Sys.ARCH))
    add("threads", Threads.nthreads())
    sha = get(ENV, "GITHUB_SHA", "")
    isempty(sha) && (sha = try
        readchomp(pipeline(`git rev-parse HEAD`; stderr=devnull))
    catch
        ""
    end)
    isempty(sha) || add("commit", first(sha, 12))
    add("repo", get(ENV, "GITHUB_REPOSITORY", ""))
    add("ref", get(ENV, "GITHUB_REF_NAME", ""))
    add("matrix", report_matrix())     # the CI matrix cell (issue #69 K), when set — a single-cell report is self-identifying
    add("package", _active_package_line())
    return rows
end

_active_package_line() = _package_line(Base.active_project())

# `name v<version>` from a Project.toml, or "" if it has no name / cannot be read (non-fatal). Split
# from the `Base.active_project()` lookup so the parse is unit-testable without activating an env.
function _package_line(p)
    try
        (p === nothing || !isfile(p)) && return ""
        d = TOML.parsefile(p)
        name = get(d, "name", "")
        isempty(name) && return ""
        ver = get(d, "version", "")
        return isempty(ver) ? String(name) : "$(name) v$(ver)"
    catch
        return ""
    end
end

"""
    completeness_overview(c) -> Function

The overview content for a TestShards completeness verdict — pass it as `overview` to
[`render_test_report`](@ref):

```julia
c = TestShards.completeness(windows, ran)
render_test_report(dumps; out = "test-report", overview = completeness_overview(c))
```

A sharded report that is missing a shard looks exactly like a smaller suite, and nothing in the
artifact contradicts that reading. This puts the verdict IN the artifact: the numbers as a table
(native rows in `agent.json`, so a registry or an agent reads them) and the verdict — with the
positions of any hole — as prose above it.

Declared here with no methods: the one method lives in `PinaxTestShardsExt`, because it takes
TestShards' `Completeness`. `TestShards.completeness_report` renders the same verdict for a CI job
summary; this renders it for the document, and the two surfaces are deliberately separate.
"""
function completeness_overview end

# The caller's own content on the overview page. What the CI job knows and the document does not — a
# completeness verdict, a note about the environment — belongs IN the artifact rather than in a log
# that expires, and the way to say it is Pinax's own vocabulary rather than a second one: the hook
# runs with the overview page open, so `@desc` / `@table` / `@raw` land on it. It runs FIRST, so its
# content — in the order written — leads the page, above the fixed provenance and per-file tables,
# which is where a verdict wants to be.
#
# It cannot break the render. A throwing hook is recorded as a diagnostic — loud in the artifact,
# silent in the exit code — exactly like every other failure in the report machinery.
function _overview_hook(overview)
    overview === nothing && return nothing
    try
        overview()
    catch err
        _diag!(
            ERROR,
            "overview",
            "the `overview` hook threw, so its content is missing from this page: " *
            sprint(showerror, err),
        )
    end
    return nothing
end

"""
    render_test_report(root::TestNode; out, title="Test report", page_when=…) -> (; gallery, agent)
    render_test_report(dumps::AbstractVector{<:AbstractString}; out, …)       -> (; gallery, agent)

Render a testset tree as a Pinax document: an overview page (one row per test file, ranked by
`worst margin`), then one page per file whose sections mirror the nested
testsets, each with its margin figure.

Given a list of TOML dumps (see [`dump_test_report`](@ref)) their trees are **merged** under one root
first — which is how a sharded CI run becomes a single coherent gallery instead of N disconnected
ones.

`overview` is an optional zero-argument function run with the **overview page open**, so it writes
with Pinax's ordinary content macros — `@desc`, `@table`, `@raw` — and its content lands there. This
is how something the running job knows but the tree does not gets into the artifact instead of into a
CI log that expires: a completeness verdict ("every unit ran exactly once"), the environment, a note
about what was skipped. Its content leads the page, above the fixed tables. If the hook throws, that is a
diagnostic in the report, not a failed render.

Writes `<out>/html/` (the human gallery) and `<out>/agent/` (`agent.json`), which share one
`<out>/comments.toml` — the same layout as [`report`](@ref).

```julia
render_test_report(dumps; out="test-report", overview = () -> begin
    @desc md"**Every unit ran exactly once** — 24 observed, 24 run."
    @table (; metric=["units observed", "units run"], value=[24, 24]) caption = "Completeness"
end)
```
"""
function render_test_report(
    root;
    out::AbstractString,
    title::AbstractString="Test report",
    page_when::Function=_looks_like_a_file,
    overview=nothing,
)
    reset!(; title=title)
    _diag_dropped!(root)
    seen = _overview_page!(title, root, overview) do
        prov = _provenance_rows()
        isempty(prov) || _push_table!(;
            data=prov,
            code="",
            caption="Provenance — when this report ran, against what code, on which Julia / OS. " *
                    "A report that omits these cannot be told apart from a stale one.",
            gen_id=:provenance,
        )
        rows = NamedTuple[]
        _collect_rows!(rows, root, page_when)
        return isempty(rows) || _push_table!(;
            data=rows,
            code="",
            caption="Per-file result profile. `worst margin` is the largest `delta/tol` seen in " *
                    "that file: 1.0 means a check landed exactly on its tolerance.",
            gen_id=:per_file,
        )
    end
    _emit_node!(root, page_when, seen)
    return _render_report_doc(current_document(), out)
end

# The ids the overview page owns, so no testset's page takes one.
const _OVERVIEW_IDS = (:overview, :per_file, :provenance)

# An overview page first: one row per file, so the whole suite is one glance — and the SAME rows land
# in agent.json as data, so an LLM reads the suite without scraping a log. The caller's `overview`
# hook leads, above the fixed tables `tables()` pushes. Returns the page ids taken so far.
function _overview_page!(tables::Function, title, root, overview)
    _enter_page!(:overview, title; layout=:wide, summary=_summary_line(root))
    try
        _overview_hook(overview)
        tables()
    finally
        _exit_page!()
    end
    return Set{Symbol}(_OVERVIEW_IDS)
end

# Render a test report's document to both faces. Every check in it came from a `@test` the test runner
# already counted and reported, so `render` must not report it a second time (#173: a failing check
# is reported exactly once).
function _render_report_doc(doc, out)
    for pg in doc.pages, c in _subtree_checks(pg)
        c.reported = true
    end
    # `out` is a directory (Conventions › Output): one face per subdirectory, one comment store
    cf = joinpath(out, "comments.toml")
    gallery = render(doc; out=joinpath(out, "html"), theme=:gallery, comments_file=cf)
    agent = render(doc; out=joinpath(out, "agent"), theme=:agent, comments_file=cf)
    return (; gallery, agent)
end

function render_test_report(
    dumps::AbstractVector{<:AbstractString}; title::AbstractString="Test report", kwargs...
)
    isempty(dumps) && error("Pinax.render_test_report: no dumps given.")
    parsed = [TOML.parsefile(d) for d in dumps]
    roots = [_dict_to_node(d["root"], p) for (d, p) in zip(parsed, dumps)]
    cells = [String(get(d, "matrix", "")) for d in parsed]
    # A CI MATRIX (issue #69 K): ≥2 distinct cells means the SAME files ran in each cell — NOT disjoint
    # like shards — so we group each cell under a `@part` rather than concatenating (which would merge
    # cells away). One report, structure preserved, navigable by cell; the cell IS the provenance.
    if length(unique(c for c in cells if !isempty(c))) >= 2
        k = findfirst(isempty, cells)
        k === nothing || error(
            "Pinax.render_test_report: $(dumps[k]) has no matrix cell (PINAX_TEST_MATRIX), while " *
            "the other dumps name theirs: a matrix report has no place for it. Set the cell in " *
            "the job that wrote it, or leave it out.",
        )
        return _render_matrix(roots, cells; title=title, kwargs...)
    end
    return render_test_report(_merge_shards(roots, title); title=title, kwargs...)
end

# SHARDS partition the test FILES, so their children are disjoint and concatenating is the whole merge
# (invariant VI). Elapsed time is summed, not maxed: CPU time spent, not wall clock.
# A root's own content (checks, prose, tables, … written at its top level) is kept too, each root's
# after the last, in its own order.
function _merge_shards(roots, title)
    m = TestNode(
        title;
        elapsed=sum(r -> isnan(r.elapsed) ? 0.0 : r.elapsed, roots; init=0.0),
        children=reduce(vcat, (r.children for r in roots); init=TestNode[]),
        nbroken=sum(r -> r.nbroken, roots; init=0),
        nerror=sum(r -> r.nerror, roots; init=0),
        dropped=reduce(vcat, (r.dropped for r in roots); init=Pair{String,String}[]),
    )
    foreach(r -> _append_content!(m, r), roots)
    return m
end

# `r`'s own content after `m`'s: its nodes appended to `m`'s, its `content` indices shifted past them.
function _append_content!(m::TestNode, r::TestNode)
    # a node with no `content` order (a legacy dump) reads as its checks, then its codes
    order = if isempty(r.content)
        vcat(
            [:check => i for i in eachindex(r.checks)],
            [:code => i for i in eachindex(r.codes)],
        )
    else
        r.content
    end
    for (k, i) in order
        nodes = getfield(m, _content_field(m, k))
        push!(nodes, getfield(r, _content_field(r, k))[i])
        push!(m.content, k => length(nodes))
    end
    union!(m.written, r.written)
    return m
end

# A CI matrix merge (issue #69 K): each cell is a `@part` holding that cell's file pages (ids qualified
# by the cell so the same file across cells does not collide). One overview across all cells, then the
# cells; nothing is merged away and the file structure is preserved. The `julia/os/commit` provenance
# of a merge job is not the cells', so the cell label carries that instead.
function _render_matrix(
    roots,
    cells;
    out::AbstractString,
    title::AbstractString="Test report",
    page_when::Function=_looks_like_a_file,
    overview=nothing,
)
    # A cell may arrive as several shard dumps: merge each cell's shards first (they partition its
    # files), so every cell is one part.
    order = unique(cells)
    pairs = [
        (_merge_shards([r for (r, rc) in zip(roots, cells) if rc == c], c), c) for
        c in order
    ]
    reset!(; title=title)
    foreach(((r, _),) -> _diag_dropped!(r), pairs)
    # the overview states the verdict of every cell together: the cells merged as if shards
    seen = _overview_page!(title, _merge_shards(first.(pairs), title), overview) do
        _push_table!(;
            data=[(;
                field="matrix cells", value=join(unique(c for (_, c) in pairs), "  ·  ")
            )],
            code="",
            gen_id=:provenance,
            caption="This report merges CI matrix cells (issue #69 K); each cell is a part below. " *
                    "The provenance (Julia / OS / commit) is the cell label — a merge job's own is not the cells'.",
        )
        rows = NamedTuple[]
        for (r, c) in pairs
            cr = NamedTuple[]
            _collect_rows!(cr, r, page_when)
            append!(rows, (merge((; cell=c), row) for row in cr))
        end
        return isempty(rows) || _push_table!(;
            data=rows,
            code="",
            gen_id=:per_file,
            caption="Per-cell, per-file result profile. `worst margin` is the largest `delta/tol` in that (cell, file).",
        )
    end
    for (r, c) in pairs
        _enter_part!(Symbol("cell_", _slug(c)), c)
        try
            _emit_node!(r, page_when, seen; id_prefix=string(_slug(c), "_"))
        finally
            _exit_part!()
        end
    end
    doc = current_document()
    gallery, agent = _render_report_doc(doc, out)
    return (; gallery, agent)
end

# ── the dump (how a sharded run gets merged) ─────────────────────────
#
# TOML, because Pinax already depends on it and it round-trips Float64 exactly. A shard writes its
# tree and renders NOTHING; one later job (the docs build) merges every shard's tree and renders once.

"""
    dump_test_report(root::TestNode, path) -> path

Write a testset tree to `path` as TOML, to be merged and rendered later by
[`render_test_report`](@ref). This is what a CI shard emits instead of rendering its own partial
gallery.
"""
function dump_test_report(root, path::AbstractString)
    dir = dirname(path)
    isempty(dir) || mkpath(dir)
    d = Dict{String,Any}("root" => _node_to_dict(root))
    m = report_matrix()
    isempty(m) || (d["matrix"] = m)   # the CI matrix cell, so a later merge can group cells (#69 K)
    open(path, "w") do io
        return TOML.print(io, d)
    end
    return path
end

# Everything a test captures crosses a shard dump EXCEPT a `@figure` (its `gen` is a closure, and a
# closure cannot be serialized; materializing the asset would make the dump a directory — deliberately
# not done) and a `@table`'s `params`. A sharded report must never be quietly missing content, so each
# such node is written INTO the dump as `id => why`, and the merged report states every one in its
# diagnostics (`_diag_dropped!`); the shard's log says it too. `@desc` / `@table` / `@raw` /
# declaration order all ride along, which is what makes the sharded and unsharded documents the same.
function _dump_drops(n)
    at = "in testset \"$(n.description)\""
    fig = [
        String(f.id) =>
            "the `@figure` $(f.id) $(at) cannot cross a shard dump (its generator is a closure) — " *
            "it appears in a direct (non-sharded) render only" for f in n.figures
    ]
    tbl = [
        String(t.id) => "the `@table` $(t.id) $(at) lost its `params` in a shard dump — its data and caption crossed"
        for t in n.tables if t.params !== nothing
    ]
    return vcat(n.dropped, fig, tbl)
end

# Every node the shard dumps dropped, as a diagnostic of the document being built.
function _diag_dropped!(n)
    n.ignore && return nothing
    foreach(((id, why),) -> _diag!(WARNING, id, why), n.dropped)
    foreach(_diag_dropped!, n.children)
    return nothing
end

"""
    load_test_dump(path) -> TestNode

Read back a tree written by [`dump_test_report`](@ref).
"""
load_test_dump(path::AbstractString) = _dict_to_node(TOML.parsefile(path)["root"], path)

function _node_to_dict(n)
    d = Dict{String,Any}(
        "description" => n.description,
        "ignore" => n.ignore,
        "nbroken" => n.nbroken,
        "nerror" => n.nerror,
    )
    # TOML has no NaN, so an unmeasured elapsed is simply absent.
    isnan(n.elapsed) || (d["elapsed"] = n.elapsed)
    _put!(d, "check", n.checks, _check_to_dict)
    # Everything except a `@figure` closure is plain data, so it crosses the dump — and so does the
    # DECLARATION ORDER, without which a merged shard would re-order its own content (issue #67: the
    # sharded and unsharded documents must be the same document, by construction).
    _put!(d, "code", n.codes, _code_to_dict)
    _put!(d, "table", n.tables, _table_to_dict)
    _put!(d, "raw", n.raws, _raw_to_dict)
    _put!(d, "text", n.texts, _text_to_dict)
    _put!(
        d,
        "content",
        n.content,
        ((k, i),) -> Dict{String,Any}("kind" => String(k), "i" => i),
    )
    isempty(n.written) || (d["written"] = sort!([String(id) for id in n.written]))
    drops = _dump_drops(n)
    foreach(((_, why),) -> @warn("Pinax: $(why)."), drops)
    _put!(d, "dropped", drops, ((id, why),) -> Dict{String,Any}("id" => id, "why" => why))
    _put!(d, "child", n.children, _node_to_dict)
    return d
end

# `d[key]`, each of `xs` as a dump entry — and no key at all for none, so an empty list is absent.
_put!(d, key, xs, f) = (isempty(xs) || (d[key] = [f(x) for x in xs]); d)

function _raw_to_dict(r::RawBlock)
    return Dict{String,Any}(
        "id" => String(r.id), "html" => r.html, "defined_at" => r.defined_at
    )
end
function _dict_to_raw(r::AbstractDict)
    id = Symbol(r["id"])
    return RawBlock(id, _anchor(id), r["html"], get(r, "defined_at", ""))
end
function _text_to_dict(t::Prose)
    return Dict{String,Any}(
        "id" => String(t.id), "source" => t.source, "defined_at" => t.defined_at
    )
end
function _dict_to_text(t::AbstractDict)
    id = Symbol(t["id"])
    return Prose(id, _anchor(id), t["source"], get(t, "defined_at", ""))
end

# TOML holds integers, floats, booleans and strings. `missing` / `nothing` cross as a marker table and
# come back as themselves; any other cell (a `1//3`, a `π`, an object) as its display string — the
# same text the gallery shows for it.
_toml_cell(x::Union{Integer,AbstractFloat,Bool,AbstractString}) = x
_toml_cell(::Missing) = Dict{String,Any}("missing" => true)
_toml_cell(::Nothing) = Dict{String,Any}("nothing" => true)
_toml_cell(x) = _cellstr(x)
_from_toml_cell(x) = x
_from_toml_cell(d::AbstractDict) = haskey(d, "missing") ? missing : nothing

function _table_to_dict(t::Table)
    return Dict{String,Any}(
        "id" => String(t.id),
        "caption" => t.caption,
        "header" => collect(t.header),
        "rows" => [[_toml_cell(c) for c in row] for row in t.rows],
        "code" => t.code,
        "defined_at" => t.defined_at,
    )
end
function _dict_to_table(d::AbstractDict)
    id = Symbol(d["id"])
    return Table(
        id,
        _anchor(id),
        get(d, "caption", ""),
        String[string(h) for h in get(d, "header", Any[])],
        Vector{Any}[Any[_from_toml_cell(c) for c in row] for row in get(d, "rows", Any[])],
        get(d, "code", ""),
        nothing,
        get(d, "defined_at", ""),
    )
end
function _code_to_dict(c::CodeBlock)
    return Dict{String,Any}(
        "id" => String(c.id),
        "source" => c.source,
        "output" => c.output,
        "caption" => c.caption,
        "lang" => c.lang,
        "defined_at" => c.defined_at,
    )
end
function _dict_to_code(d::AbstractDict)
    return CodeBlock(
        Symbol(d["id"]),
        _anchor(Symbol(d["id"])),
        d["source"],
        get(d, "output", ""),
        get(d, "caption", ""),
        get(d, "lang", "julia"),
        get(d, "defined_at", ""),
    )
end

# `id` is deliberately NOT dumped: it is assigned at render time (t1, t2, …) so that merging several
# shards produces one clean numbering rather than N colliding ones.
function _check_to_dict(c::Check)
    d = Dict{String,Any}(
        "label" => c.label,
        "got" => c.got,
        "want" => c.want,
        "delta" => c.delta,
        "tol" => c.tol,
        "kind" => String(c.kind),
        "pass" => c.pass,
    )
    isempty(c.source) || (d["source"] = c.source)   # carry WHERE it failed across a shard dump
    # …and the REFERENCE to the code block that produced it (the block itself rides `n.codes`).
    isempty(c.code_anchor) || (d["code_anchor"] = c.code_anchor)
    c.indicator && (d["indicator"] = true)
    return d
end

# A dump is outside data: it is checked here, where it is read, so a stale or edited one is an error
# naming its entry rather than a BoundsError deep in the fold. `path` is the dump file.
function _dict_to_node(d::AbstractDict, path::AbstractString="")
    at = string("test dump ", path, ", testset \"", d["description"], "\"")
    n = TestNode(
        d["description"];
        elapsed=get(d, "elapsed", NaN),
        ignore=get(d, "ignore", false),
        nbroken=get(d, "nbroken", 0),
        nerror=get(d, "nerror", 0),
        checks=Check[_dict_to_check(c, at) for c in get(d, "check", Any[])],
        codes=CodeBlock[_dict_to_code(c) for c in get(d, "code", Any[])],
        tables=Table[_dict_to_table(t) for t in get(d, "table", Any[])],
        raws=RawBlock[_dict_to_raw(r) for r in get(d, "raw", Any[])],
        texts=Prose[_dict_to_text(t) for t in get(d, "text", Any[])],
        children=TestNode[_dict_to_node(c, path) for c in get(d, "child", Any[])],
        written=Set{Symbol}(Symbol(id) for id in get(d, "written", Any[])),
        dropped=Pair{String,String}[e["id"] => e["why"] for e in get(d, "dropped", Any[])],
    )
    # A `@figure` did not survive, so any `:figure` entry in the recorded order is dropped — the rest
    # keeps its declared position (a legacy dump with no `content` falls back to checks-then-codes in
    # `_emit_own_content!`).
    for (j, e) in enumerate(get(d, "content", Any[]))
        e["kind"] == "figure" || push!(n.content, _dump_entry(n, e, j, at))
    end
    return n
end

# One `content` entry of a dumped node, checked against the node's own nodes.
function _dump_entry(n::TestNode, e::AbstractDict, j::Int, at)
    bad(msg) = error("Pinax: $(at): content entry $(j) $(msg)")
    kind, i = e["kind"], e["i"]
    k = Symbol(kind)
    f = get(_CONTENT_FIELDS, k, nothing)
    (f !== nothing && hasfield(TestNode, f)) || bad("has unknown kind \"$(kind)\"")
    len = length(getfield(n, f))
    (i isa Integer && 1 <= i <= len) ||
        bad("points at $(kind) $(i), and the testset has $(len) of them")
    return k => Int(i)
end

function _dict_to_check(d::AbstractDict, at::AbstractString="a test dump")
    kind = d["kind"]
    kind in ("abs", "rel") || error(
        "Pinax: $(at): check \"$(d["label"])\" has kind \"$(kind)\" — a check is abs or rel",
    )
    return Check(
        :t0,                        # renumbered on render
        d["label"],
        Float64(d["got"]),
        Float64(d["want"]),
        Float64(d["delta"]),
        Float64(d["tol"]),
        Symbol(kind),
        d["pass"],
        get(d, "source", ""),
        get(d, "code_anchor", ""),
        false,
        get(d, "indicator", false),
    )
end

"Where a shard writes its tree instead of rendering (`PINAX_TEST_DUMP`); empty = render directly."
report_dump() = get(ENV, "PINAX_TEST_DUMP", "")

"The CI matrix cell this run belongs to (`PINAX_TEST_MATRIX`, e.g. `\"julia 1.11 · ubuntu\"`); empty = not a matrix run. Set by the CI job; carried into the dump so a later merge can group cells (issue #69 K)."
report_matrix() = get(ENV, "PINAX_TEST_MATRIX", "")
