# Compose with TestShards: a SHARDED suite renders as one document, with margins.
#
# TestShards splits a test suite across CI jobs, and it runs each shardable unit inside a testset it
# builds by hand rather than through `@testset` — deliberately, so that a failed unit can still be
# read back (a top-level `@testset` throws before returning its tree). Two consequences for us, and
# both are silent:
#
#   TYPE     `Test` builds a nested testset from its PARENT's type, which is the only reason our
#            capture sees a suite at all. A unit's testset is not ours, so inside a unit
#            `_current_container()` is `:inert`: no checks, and a test-side `@figure` / `@code`
#            no-ops. Measured: a `@shard` suite under `Pinax.test` renders `0/0 passed` — empty AND
#            green, indistinguishable from a suite with no tests.
#   NESTING  the unit's testset is popped by hand and never `finish`ed, and we attach a child to its
#            parent IN `finish`. Measured: after the pop the root has 0 children; after
#            `Test.finish` it has 1.
#
# TestShards answers both with a registered provider (`register_unit_provider!`), and the provider
# belongs HERE: it needs the counts out of `PinaxTestSet`, which is ours and private, while its side
# of the seam is one function call and no types of theirs. The reverse placement would have TestShards
# reading six private fields of a type it does not own.
module PinaxTestShardsExt

using Pinax: Pinax
using TestShards: TestShards
using Test: Test

function __init__()
    TestShards.register_unit_provider!(; name="Pinax", open=_open, close=_close, fold=_fold)
    return nothing
end

# `PinaxTestSet` lives in `PinaxTestExt` — `Test`-triggered, because Pinax must not drag `Test` into
# every user's session. Two extensions of one package have no defined load order between them, so
# resolve the type on first use rather than at `__init__`.
const _TS_TYPE = Ref{Any}(nothing)
function _pinax_testset_type()
    _TS_TYPE[] === nothing || return _TS_TYPE[]
    ext = Base.get_extension(Pinax, :PinaxTestExt)
    ext === nothing && return nothing
    _TS_TYPE[] = ext.PinaxTestSet
    return _TS_TYPE[]
end

"""
The testset for one shardable unit, or `nothing` to decline it and leave TestShards' default.

Declined unless a capture is **ambient** — that is, the caller installed a capturing root
(`Pinax.test`), which is exactly when a document is being built. Never keyed on an environment
variable: a suite that merely depends on Pinax must not have its testset type changed underneath it,
and a bare `Pkg.test()` must run exactly as it did before (invariant V — the report changes nothing
about how the suite runs).
"""
function _open(key::AbstractString)
    T = _pinax_testset_type()
    T === nothing && return nothing
    Test.get_testset_depth() > 0 || return nothing
    Test.get_testset() isa T || return nothing
    return T(key)
end

# Attach the finished unit to the capturing root. `Test.finish` on a non-root `PinaxTestSet` does
# exactly that and cannot throw — only a root re-signals a red suite, and a unit is never the root.
_close(ts) = (Test.finish(ts); nothing)

"""
A unit's counts and structure as plain data, for TestShards' `unit_fold` —

    (; name, duration, npass, nfail, nerror, nbroken, sections)

recursively. This is what keeps TestShards' balancing history and completeness verdict correct while
the testset is ours: the same numbers by a different route, which is the first thing its tests check.

Pinax converts each result into a `Check` as it is recorded rather than keeping `Test`'s own
`results`, so the counts come from that: an ERROR is both `nerror` and a non-passing check, and a
BROKEN test is counted without becoming a check at all (it did not pass, but the runner is content,
and calling it a failure would paint the unit red).
"""
function _fold(ts)
    kids = [_fold(c) for c in ts.children]
    nerror = ts.nerror
    return (;
        name=ts.description,
        duration=isnan(ts.elapsed) ? 0.0 : ts.elapsed,
        npass=count(c -> c.pass, ts.checks) + sum(k -> k.npass, kids; init=0),
        nfail=count(c -> !c.pass, ts.checks) - nerror + sum(k -> k.nfail, kids; init=0),
        nerror=nerror + sum(k -> k.nerror, kids; init=0),
        nbroken=ts.nbroken + sum(k -> k.nbroken, kids; init=0),
        sections=kids,
    )
end

end
