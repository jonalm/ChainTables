using Test
using ChainTables: ChainTables, CBOR, HEAD_FIELDS, HEAD_SEPARATOR, Head, HeadRejected,
    check_head, decode_head, encode_head, head_filename, state_fingerprint

const TABLE_ENTRIES = ["t" => fill(0x01, 32), "u" => fill(0x01, 32), "w" => fill(0x02, 32)]

const HEAD = Head(
    "AAAQEAYEAUDAOCAJBIFQYDIOB4", 1, 1, fill(0x0a, 32), state_fingerprint(TABLE_ENTRIES),
    TABLE_ENTRIES, 1_700_000_000_000, (lib = "ChainTables 1.0.0", julia = "1.13.0"),
)

# The head file's bytes with fields replaced; `nothing` removes a field.
function head_bytes_with(; fields...)
    decoded = CBOR.decode(encode_head(HEAD)[(length(HEAD_SEPARATOR) + 1):end])
    foreach(k -> delete!(decoded, string(k)), [k for (k, v) in fields if v === nothing])
    merge!(decoded, Dict(string(k) => v for (k, v) in fields if v !== nothing))
    return vcat(codeunits(HEAD_SEPARATOR), CBOR.encode(decoded))
end

function rejection(bytes)
    try
        decode_head(bytes)
    catch e
        e isa HeadRejected || rethrow()
        return e
    end
    return nothing
end

@testset "head_filename is the slot in twelve digits" begin
    @test head_filename(0) == "000000000000"
    @test head_filename(42) == "000000000042"
end

@testset "encode_head writes the magic and one map of the head fields" begin
    bytes = encode_head(HEAD)
    @test bytes[1:length(HEAD_SEPARATOR)] == codeunits(HEAD_SEPARATOR)
    decoded = CBOR.decode(bytes[(length(HEAD_SEPARATOR) + 1):end])
    @test sort(collect(keys(decoded))) == sort(collect(HEAD_FIELDS))
    @test decoded["layout_version"] == 1
    @test decoded["chain_id"] == HEAD.chain_id
    @test decoded["tables"] == Any[Any[n, h] for (n, h) in HEAD.tables]
end

@testset "decode_head inverts encode_head" begin
    @test decode_head(encode_head(HEAD)) == HEAD
    @test encode_head(decode_head(encode_head(HEAD))) == encode_head(HEAD)
end

@testset "Head equality and hash agree" begin
    twin = decode_head(encode_head(HEAD))
    @test twin == HEAD
    @test hash(twin) == hash(HEAD)
    @test isequal(twin, HEAD)
    @test (twin == HEAD) isa Bool
    @test length(Set([twin, HEAD])) == 1
    @test Dict(HEAD => 1)[twin] == 1
    later = Head(
        HEAD.chain_id, 1, 2, HEAD.transaction_hash, HEAD.state_fingerprint, HEAD.tables,
        HEAD.written_at_ms, HEAD.written_by,
    )
    @test later != HEAD
end

const BODY = encode_head(HEAD)[(length(HEAD_SEPARATOR) + 1):end]
const SORTED_ENTRIES = [Any[n, h] for (n, h) in TABLE_ENTRIES]
const DUPLICATE_ENTRIES = [Any["t", fill(0x01, 32)], Any["t", fill(0x01, 32)]]
const EXTRA_WRITTEN_BY = Dict("lib" => "x", "julia" => "y", "os" => "z")

const REJECTIONS = [
    (
        name = "a foreign file",
        bytes = Vector{UInt8}("SQLite format 3\0"),
        kind = :not_ours,
        detail = "is not a ChainTables head file",
    ),
    (
        name = "another layout's magic",
        bytes = vcat(codeunits("chaintables/v2/head"), BODY),
        kind = :layout,
        detail = "begins \"chaintables/v2/head\", not \"chaintables/v1/head\"",
    ),
    (
        name = "a higher layout version",
        bytes = head_bytes_with(layout_version = 2),
        kind = :layout,
        detail = "layout version 2 is not this client's, 1",
    ),
    (
        name = "a newer record format",
        bytes = head_bytes_with(format_version = 2),
        kind = :layout,
        detail = "format_version 2 is above this client's maximum, 1",
    ),
    (
        name = "format version 0",
        bytes = head_bytes_with(format_version = 0),
        kind = :damaged,
        detail = "format_version 0 is not a version this client reads",
    ),
    (
        name = "truncated bytes",
        bytes = encode_head(HEAD)[1:(end - 3)],
        kind = :damaged,
        detail = "cannot be decoded",
    ),
    (
        name = "an unknown field",
        bytes = head_bytes_with(extra = 1),
        kind = :damaged,
        detail = "unknown head field \"extra\"",
    ),
    (
        name = "a missing field",
        bytes = head_bytes_with(written_by = nothing),
        kind = :damaged,
        detail = "has no \"written_by\"",
    ),
    (
        name = "a mis-typed field",
        bytes = head_bytes_with(slot = "1"),
        kind = :damaged,
        detail = "slot is not an integer",
    ),
    (
        name = "a chain id that is not one",
        bytes = head_bytes_with(chain_id = "ABC"),
        kind = :damaged,
        detail = "chain_id \"ABC\" is not a chain id",
    ),
    (
        name = "a bad tables entry",
        bytes = head_bytes_with(tables = [Any["t"]]),
        kind = :damaged,
        detail = "tables entry Any[\"t\"] is not [name, hash]",
    ),
    (
        name = "an unknown written_by field",
        bytes = head_bytes_with(written_by = EXTRA_WRITTEN_BY),
        kind = :damaged,
        detail = "unknown written_by field \"os\"",
    ),
    (
        name = "a short hash",
        bytes = head_bytes_with(transaction_hash = UInt8[1]),
        kind = :damaged,
        detail = "is not self-consistent: transaction_hash is 1 bytes; a SHA-256 is 32",
    ),
    (
        name = "tables out of name order",
        bytes = head_bytes_with(tables = reverse(SORTED_ENTRIES)),
        kind = :damaged,
        detail = "tables are not sorted by name",
    ),
    (
        name = "a duplicate table name",
        bytes = head_bytes_with(tables = DUPLICATE_ENTRIES),
        kind = :damaged,
        detail = "is not self-consistent: duplicate table name \"t\"",
    ),
    (
        name = "a fingerprint not of its tables",
        bytes = head_bytes_with(state_fingerprint = fill(0xee, 32)),
        kind = :damaged,
        detail = "its state_fingerprint is $("ee"^32), the fingerprint of its tables",
    ),
]

@testset "decode_head rejects $(case.name)" for case in REJECTIONS
    e = rejection(case.bytes)
    @test e isa HeadRejected
    @test e.kind === case.kind
    @test occursin(case.detail, e.detail)
end

@testset "HeadRejected shows its kind and detail" begin
    e = HeadRejected(; kind = :damaged, detail = "has no \"slot\"")
    message = sprint(showerror, e)
    summary = "HeadRejected: the head file cannot be read: has no \"slot\"."
    @test startswith(message, summary)
    @test occursin("kind = :damaged", message)
end

@testset "check_head refuses a negative slot" begin
    negative = Head(
        HEAD.chain_id, 1, -1, HEAD.transaction_hash, HEAD.state_fingerprint, HEAD.tables,
        HEAD.written_at_ms, HEAD.written_by,
    )
    @test_throws ArgumentError "slot -1 is negative" check_head(negative)
end

@testset "decode_head infers Head" begin
    @test @inferred(decode_head(encode_head(HEAD))) isa Head
end
