# PinaxTestExt — the `Test`-dependent half of the test bridge (the Test-free half is src/testset.jl).
#
# This module is deliberately small. Its job is to observe a running suite through Test's
# `AbstractTestSet` interface: a `PinaxTestSet` is a thin adapter over one `Pinax.TestNode`, the
# Test-free tree that holds Pinax's own structs (`Figure`/`Table`/`Check`/`Desc` + content order) —
# one model, held in the task-local testset (safe under parallel tests exactly as `Test`'s own stack
# is). Summaries, the margin figure, the fold to a `Document`, and the shard dump/merge are all plain
# Julia over that tree in Pinax proper — where they need no `Test`.
#
# A content macro (`@figure`/`@desc`/…) inside a test finds this container through the ONE seam
# `Pinax._current_container()`: we register a probe at load so that seam, staying `Test`-free, can
# route into the open `PinaxTestSet`'s node (or no-op when the report is off — invariant V).
module PinaxTestExt

using Pinax
using Pinax:
    TestNode,
    _check_from,
    _looks_like_a_file,
    _nerror,
    _nfail,
    _slug,
    _summary_line,
    dump_test_report,
    render_test_report,
    report_dump,
    report_out,
    report_title
using Test: Test, AbstractTestSet

# Julia 1.13 removed `Test.push_testset` / `Test.pop_testset`: the testset stack became a
# ScopedValue (`Test.CURRENT_TESTSET`), which cannot outlive the block that sets it. This capture
# installs a root and needs it to survive into a suite that runs AFTERWARDS (the `-L` preamble runs
# before `Pkg.test` includes anything), so the mechanism is gone rather than renamed. Gate on the
# functions, not on VERSION: what matters is whether the stack can be pushed.
const TESTSET_STACK = isdefined(Test, :push_testset) && isdefined(Test, :pop_testset)

# Run `f` with `ts` as the current testset, leaving the previous one current afterwards. A BALANCED
# push is expressible on either Julia: 1.13 turned the stack into a ScopedValue, and a scoped value
# covers a block. Only the UNBALANCED root below, which has to outlive the preamble that installs
# it, has no 1.13 form. Same shape and same reason as TestShards.jl's `_with_testset`; note that
# `TESTSET_DEPTH` has to travel with `CURRENT_TESTSET`.
@static if isdefined(Test, :CURRENT_TESTSET)
    function _with_testset(f, ts)
        return Base.ScopedValues.with(
            f,
            Test.CURRENT_TESTSET => ts,
            Test.TESTSET_DEPTH => Test.get_testset_depth() + 1,
        )
    end
else
    function _with_testset(f, ts)
        Test.push_testset(ts)
        try
            return f()
        finally
            Test.pop_testset()
        end
    end
end

function __init__()
    # Register the container probe (a `Ref` assignment, not a method override — no precompile clash).
    Pinax._TEST_CONTAINER_PROBE[] = _current_test_container
    Pinax._SCOPE_HOOK[] = Pinax._ScopeHook(
        _open_container, _container_pairs, _close_container
    )
    return nothing
end

# ── a manuscript container AS the current testset (#173) ─────────────────────────────────────────
#
# While a `@page` / `@section` body runs, its container is the current testset, so `Test`'s own
# `@test` is a check of that container and a nested `@testset` is a child section (`Test` builds a
# nested set from the parent's TYPE). Every result is also handed to `outer`, the nearest ordinary
# testset, so a suite counts it exactly as if the `@test` were written there. With none open (a
# manuscript run on its own) the result is only recorded; `render` reports it.
mutable struct PinaxContainerSet <: AbstractTestSet
    description::String
    node::Any                               # the Section or Page this testset IS
    outer::Union{AbstractTestSet,Nothing}   # nearest non-container testset, or nothing
    owns::Bool                              # created by a nested @testset: closes its own section
end

_enclosing_testset() = Test.get_testset_depth() == 0 ? nothing : Test.get_testset()
_outer_of(ts::PinaxContainerSet) = ts.outer
_outer_of(ts) = ts

function _open_container(c)
    ts = PinaxContainerSet(c.title, c, _outer_of(_enclosing_testset()), false)
    TESTSET_STACK && Test.push_testset(ts)       # Julia ≤ 1.12: the stack is task-local storage
    return ts
end
_close_container(ts) = (TESTSET_STACK && Test.pop_testset(); nothing)

@static if isdefined(Test, :CURRENT_TESTSET)
    function _container_pairs(ts)
        return (
            Test.CURRENT_TESTSET => ts, Test.TESTSET_DEPTH => Test.get_testset_depth() + 1
        )
    end
else
    _container_pairs(ts) = (Pinax._NO_SCOPE => nothing, Pinax._NO_SCOPE => nothing)
end

# A `@testset "desc"` nested in a container: `Test` constructs it from the parent's type, so this is
# where a testset becomes a child section of whatever container is open.
function PinaxContainerSet(desc::AbstractString; kw...)
    parent = _enclosing_testset()
    sec = Pinax._enter_section!(_section_id(_slug(desc)), String(desc))
    return PinaxContainerSet(String(desc), sec, _outer_of(parent), true)
end

# A testset's section id is generated, not written by the author: the container's id plus the
# description, so it is unique in the document, and a repeat (the same `@testset "conv"` in a loop)
# becomes `-2`, `-3` — as any generated id does — rather than raising (Conventions › Identity).
function _section_id(slug::Symbol)
    c = something(Pinax.CTX.section, Pinax.CTX.page)
    return Pinax._free_id(Symbol(c.id, "_", slug))
end

function Test.finish(ts::PinaxContainerSet)
    ts.owns && Pinax._exit_section!()
    return ts
end

# The section tree is built as sections open; a finished child needs no recording.
Test.record(::PinaxContainerSet, child::PinaxContainerSet) = child
# Any other testset nested here (an explicit `@testset DefaultTestSet`) still reaches the suite.
function Test.record(ts::PinaxContainerSet, child::AbstractTestSet)
    ts.outer === nothing || Test.record(ts.outer, child)
    return child
end
function Test.record(ts::PinaxContainerSet, res::Test.Result)
    if res isa Test.Broken
        Pinax._record_no_check!(ts.node, _source_str(res))
    else
        chk = _push_container_check!(ts.node, res)
        chk.reported = ts.outer !== nothing   # the suite counts it; `render` will not repeat it
    end
    ts.outer === nothing || Test.record(ts.outer, res)
    return res
end

# The one place a Pass / Fail / Error enters the model as a `Check`, for a manuscript container and a
# test node alike (#173).
function _push_container_check!(c, res)
    chk = _check_from(_result_data_expr(res), _label(res), res isa Test.Pass, 0)
    # a test node's ids are its own until the fold places them; a page's or section's are the document's
    chk.id = if c isa TestNode
        Pinax._check_id(c, chk.label)
    else
        Pinax._claim_check_id!(c, chk.label)
    end
    chk.source = _source_str(res)            # WHERE it was asserted (issue #69 I)
    # By DEFAULT, the code that produced this check — captured as the same `@code` artifact a
    # manuscript would build, pushed BEFORE the check so it reads code-then-result. One block per
    # source region: a `@testset for`'s N samples all point at the one snippet they share.
    blk = _code_block_for(res)
    blk === nothing || (chk.code_id = Pinax._push_auto_code!(c, blk))
    push!(c.checks, chk)
    push!(c.content, :check => length(c.checks))
    return chk
end

# The probe `Pinax._current_container()` consults. Returns the innermost open Pinax test container,
# `:inert` (inside a test whose set is NOT ours — the report is off, so content macros no-op), or
# `:none` (not inside any testset — the manuscript path). Task-local via `Test.get_testset`.
function _current_test_container()
    Test.get_testset_depth() == 0 && return :none
    ts = Test.get_testset()
    return ts isa PinaxTestSet ? ts.node : :inert
end

# A testset as Test sees it, over the tree node it fills (#173). Everything the document needs lives
# in `node`; the adapter adds only what a running testset has and a node does not. `children` mirrors
# `node.children` as testsets because TestShards keys `evidence!` on the testset OBJECT.
mutable struct PinaxTestSet <: AbstractTestSet
    description::String
    node::TestNode
    children::Vector{PinaxTestSet}
    t0::Float64
    # --- root-only options (a nested set is built by Test as T(desc), with none of these) ---
    out::String
    dump::String
    page_when::Function
    title::String
end

# The ROOT is constructed with options (by `Pinax.test`'s in-process `@testset PinaxTestSet` or the
# delegation preamble); a NESTED `@testset` is constructed by Julia from the parent's TYPE as
# `T(desc)` with no options — which is exactly why the root's options come from the environment
# (`Pinax.test` sets `PINAX_TEST_OUT` / `_DUMP` / `_TITLE`).
function PinaxTestSet(
    description::AbstractString;
    out=report_out(),
    dump=report_dump(),
    page_when::Function=_looks_like_a_file,
    title::AbstractString="Test report",
)
    return PinaxTestSet(
        String(description),
        TestNode(description),
        PinaxTestSet[],
        time(),
        String(out),
        String(dump),
        page_when,
        String(title),
    )
end

# @pinaxignore, from inside the testset body. A no-op unless the innermost set is one of ours — so it
# is safe to leave in the code with the report switched off (where the set is a DefaultTestSet).
function Pinax._ignore_current_testset!()
    Test.get_testset_depth() == 0 && return nothing
    ts = Test.get_testset()
    ts isa PinaxTestSet && (ts.node.ignore = true)
    return nothing
end

# Record straight into the container: a nested set is a child; a Pass/Fail/Error becomes a `Check`
# tagged into content order at its emission site; a Broken is counted (see `finish`). Doing the
# conversion HERE (not lazily at finish) is what keeps the tree one model with no `.results` shadow.
function Test.record(ts::PinaxTestSet, res)
    n = ts.node
    if res isa PinaxTestSet
        push!(ts.children, res)                       # nest
        push!(n.children, res.node)
    elseif res isa Test.Broken
        # A broken/skipped test is deliberately NOT a Check: it did not pass, but the runner is happy
        # about it, and `pass=false` would paint the page red and flip the verdict to FAIL. Counted.
        n.nbroken += 1
    elseif res isa Test.Result                        # Pass / Fail / Error
        res isa Test.Error && (n.nerror += 1)
        _push_container_check!(n, res)
    end
    return res
end

# Where a Test result was written, `path:line` relative to its project (`Pinax._defined_at`), from its
# `source::LineNumberNode`, or "" — duck-typed via `hasproperty` since a `Pass` may carry no source
# across Julia versions.
function _source_str(res)
    loc = _source_loc(res)
    return loc === nothing ? "" : Pinax._defined_at(loc)
end

# `(file, line)` from a result's `source::LineNumberNode`, or `nothing` when it carries none.
function _source_loc(res)
    hasproperty(res, :source) || return nothing
    s = getproperty(res, :source)
    (s isa LineNumberNode && s.file !== nothing) || return nothing
    return (String(s.file), s.line)
end

# The `@code` artifact for a test result — the code that produced it, read from the file at record
# time (it exists while the suite runs, in the `Pkg.test` sandbox too) via the result's
# `LineNumberNode`. The extraction itself is core and `Test`-free (`Pinax._test_code_block`); the only
# part that needs `Test` is getting the file and line out of a `Test.Result`.
function _code_block_for(res)
    loc = _source_loc(res)
    return loc === nothing ? nothing : Pinax._test_code_block(loc...)
end

function Test.finish(ts::PinaxTestSet)
    n = ts.node
    n.elapsed = time() - ts.t0
    if Test.get_testset_depth() > 0
        Test.record(Test.get_testset(), ts)           # nest into the parent
        return ts
    end
    # ── ROOT ─────────────────────────────────────────────────────────
    _emit_root(ts)
    # Stay a well-behaved testset: a failing suite must still fail the process (invariant IV — a
    # report never turns a red suite green). Counted from the captured checks.
    nfail, nerr = _nfail(n), _nerror(n)
    if nfail + nerr > 0
        error("PinaxTestSet: $(nfail) failed, $(nerr) errored")
    end
    return ts
end

# What a finished root leaves behind: nothing when it is ignored; under a CI shard, a dump and NO
# render (one later job merges every shard's tree into the single gallery the design implies — one
# page per test FILE, not one gallery per shard); otherwise the rendered report. Then a line saying so.
function _emit_root(ts::PinaxTestSet)
    n = ts.node
    n.ignore && return nothing
    if !isempty(ts.dump)
        dump_test_report(n, ts.dump)
        println("\nPinax test report: ", _summary_line(n), "\n  dumped → ", ts.dump)
    else
        render_test_report(n; out=ts.out, title=ts.title, page_when=ts.page_when)
        println(
            "\nPinax test report: ",
            _summary_line(n),
            "\n  rendered → $(joinpath(ts.out, "html"))/  $(joinpath(ts.out, "agent"))/",
        )
    end
    return nothing
end

# The interface `Pinax.test` (docstring in src/testset.jl). In the EXTENSION, `PinaxTestSet` is an
# ordinary visible name, so the in-process form is a plain `@testset PinaxTestSet` — no gensym, no
# per-suite token; the suite the user writes is pure `@testset`.

# `Pinax.test(runtests)` — render a specific file in the CURRENT process (no sandbox): a capturing
# root, include, render. The root's `finish` renders and re-throws on a red suite.
function Pinax.test(
    runtests::AbstractString; out=report_out(), title::AbstractString=report_title()
)
    file = abspath(runtests)
    isfile(file) || error("Pinax.test: no such test file — $(file)")
    # A fresh `Module()` has NO module-local `include` / `eval` (unlike a `module … end`), so a
    # `runtests.jl` that `include`s its test files would hit `UndefVarError: include`. Define them.
    m = Module(gensym(:PinaxTest))
    Core.eval(m, :(include(p) = $(Base.include)($m, p)))
    Core.eval(m, :(eval(x) = $(Core.eval)($m, x)))
    empty!(Pinax._FILE_AST)
    withenv("PINAX_TEST_OUT" => String(out), "PINAX_TEST_TITLE" => String(title)) do
        Test.@testset PinaxTestSet "$(title)" begin
            Base.include(m, file)
        end
    end
    return nothing
end

# The `Pkg.test`-delegation half (called by the `-L` preamble): push an UNBALANCED capturing root, so
# the suite's top-level `@testset` — which the preamble runs BEFORE — inherits it and records into it.
# Test never `finish`es our root, so its natural throw is suppressed; the atexit hook re-imposes the
# verdict via the process exit code.
function Pinax._install_test_capture!()
    # The `-L` preamble runs in EVERY `Pkg.test` subprocess. During precompilation (`generating_output`)
    # our side effects (`push_testset`, `atexit`) would break the cache image — and there is no suite to
    # capture there anyway — so install NOTHING then. The cache-flags probe is handled by the empty-root
    # guard in `_finalize_test_capture!` (it installs but renders nothing). Only the test run captures.
    Base.generating_output() && return false
    # One root per process. Both ways in reach here — the preamble, and `install_test_capture!` from
    # the suite — and a `runtests.jl` carrying the call is still a valid target for `Pinax.test()`, so
    # they meet routinely. A second root would take every assertion and leave the first to render an
    # empty, green report.
    Pinax._CAPTURE_INSTALLED[] && return false
    if !TESTSET_STACK
        @warn """
        Pinax: the test report needs `Test.push_testset` / `Test.pop_testset`, which Julia \
        $(VERSION) no longer has (1.13 moved the testset stack to a ScopedValue, which cannot \
        outlive the block that sets it). The suite runs normally and its verdict is unchanged; \
        no report is produced.""" maxlog = 1
        return false
    end
    Pinax._CAPTURE_INSTALLED[] = true
    empty!(Pinax._FILE_AST)
    root = PinaxTestSet(
        report_title(); out=report_out(), dump=report_dump(), title=report_title()
    )
    Test.push_testset(root)
    atexit(() -> _finalize_test_capture!(root))
    return true
end

function _finalize_test_capture!(root::PinaxTestSet)
    TESTSET_STACK && Test.get_testset_depth() > 0 && Test.pop_testset()
    # A `-L` preamble runs in EVERY `Pkg.test` subprocess — the cache-flags probe and precompile, not
    # just the test run — and those capture nothing. An empty root therefore means "not the test run":
    # do nothing (no render, no print, no exit) so their stdout stays clean for `Pkg` to parse.
    n = root.node
    (isempty(n.children) && isempty(n.checks)) && return nothing
    _emit_root(root)
    nfail, nerr = _nfail(n), _nerror(n)
    (nfail + nerr > 0) && exit(1)   # red suite → nonzero exit (finish's throw can't fire in atexit)
    return nothing
end

# ── recovering the NUMBERS out of a Test result ──────────────────────
#
# Measured on Julia 1.12 (do not "simplify" this — the asymmetry is real):
#   Test.Pass.data  is an **Expr** with the arguments already EVALUATED:
#                     :(isapprox(-0.10203, -0.10242; rtol = 0.01, atol = 1.0e-10))
#   Test.Fail.data  is a **String** of the same thing — it must be Meta.parse'd.
# Miss that and every *failing* check silently loses its numbers, which are precisely the ones you
# want to look at.
_result_data_expr(r::Test.Pass) = r.data isa Expr ? r.data : nothing
function _result_data_expr(r::Test.Fail)
    r.data === nothing && return nothing
    try
        e = Meta.parse(String(r.data))
        return e isa Expr ? e : nothing
    catch
        return nothing
    end
end
_result_data_expr(::Any) = nothing

function _label(r::Test.Result)
    e = hasproperty(r, :orig_expr) ? getproperty(r, :orig_expr) : nothing
    s = e === nothing ? string(typeof(r)) : Pinax._expr_str(e)
    length(s) > 110 && (s = s[1:107] * "…")
    return s
end

end # module
