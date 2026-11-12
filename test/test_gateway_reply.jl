# Python's json.dumps writes a character outside the BMP as a surrogate pair; a malformed
# escape is kept, never raised over the error the message explains. The cases come from
# JSON's grammar, so these tests call the reader directly.
using Test
using ChainTables: ChainTables

const UNESCAPE_CASES = [
    (name = "surrogate pair", s = "a\\ud83d\\ude00b", text = "a😀b"),
    (name = "simple escapes", s = "\\u00e9\\n\\\"\\t\\/", text = "é\n\"\t/"),
    (name = "bad hex", s = "x\\uZZZZ y", text = "x\\uZZZZ y"),
    (name = "lone high surrogate", s = "lone \\ud83d end", text = "lone \\ud83d end"),
    (name = "low surrogate first", s = "\\ude00 low first", text = "\\ude00 low first"),
    (name = "short escape", s = "tail\\u12", text = "tail\\u12"),
    (name = "high surrogate before UTF-8", s = "\\ud83dé", text = "\\ud83dé"),
    (name = "trailing backslash", s = "end\\", text = "end\\"),
]

@testset "json_unescape: $(case.name)" for case in UNESCAPE_CASES
    text = ChainTables.json_unescape(case.s)
    @test text == case.text
    @test isvalid(text)
end

@testset "gateway_reply reads the code and the unescaped message" begin
    body = Vector{UInt8}(
        "{\"code\": \"not_allowed\", \"message\": \"\\ud83d\\ude00 may not \\uZZ\"}"
    )
    @test ChainTables.gateway_reply(body) == ("not_allowed", "😀 may not \\uZZ")
    lambda = Vector{UInt8}("{\"Message\":\"Forbidden\"}")
    @test ChainTables.gateway_reply(lambda) == (nothing, "Forbidden")
    @test ChainTables.gateway_reply(UInt8[]) == (nothing, nothing)
end
