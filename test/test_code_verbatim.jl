using Pinax
using Test

# `@code` shows its expression as written, read back from the file. Each token start on the first
# line is a byte position, so text in any script before the expression does not shift it.
@testset "@code: the expression as written, after non-ASCII text on its line" begin
    Pinax.reset!()
    @page :p "P" begin
        @code caption = "αβγ — 収束" y = 1_000
    end
    @test only(Pinax.current_document().pages[1].codes).source == "y = 1_000"   # deparsed: 1000
end
