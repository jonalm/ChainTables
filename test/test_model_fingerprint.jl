using Test
using ChainTables: CBOR, Model
# The model's rules are the format's spec. The write builder and apply report them
# through two public errors, so they are tested once here, where they live.
using ChainTables.Model: Column, Content, ModelError, Shape
using SHA: sha256

include("fixtures/determinism_vector.jl")
include("fixtures/internal_errors.jl")
include("fixtures/model_tables.jl")

const FP_SEPARATOR_BYTES = Vector{UInt8}(codeunits("chaintables/v1/fp"))
const HASH_A = sha256(b"a")
const HASH_B = sha256(b"b")
const A_THEN_B_WIRE = Any[Any["a", HASH_A], Any["b", HASH_B]]
const A_THEN_B = sha256(vcat(FP_SEPARATOR_BYTES, CBOR.encode(A_THEN_B_WIRE)))
const VECTOR_CONTENT = determinism_content()

@testset "state_fingerprint of no tables hashes the separator and an empty array" begin
    none = Pair{String, Vector{UInt8}}[]
    @test @inferred(Model.state_fingerprint(none)) == sha256(vcat(FP_SEPARATOR_BYTES, 0x80))
    @test @inferred(Model.state_fingerprint(Content())) == Model.state_fingerprint(none)
end

@testset "state_fingerprint sorts the tables by name" begin
    @test Model.state_fingerprint(["b" => HASH_B, "a" => HASH_A]) == A_THEN_B
    @test Model.state_fingerprint(["a" => HASH_A, "b" => HASH_B]) == A_THEN_B
    @test Model.state_fingerprint(["a" => HASH_A]) != A_THEN_B
end

@testset "state_fingerprint refuses a table named twice" begin
    @test_throws(
        ModelError, as_shown("duplicate table name \"a\""),
        Model.state_fingerprint(["a" => HASH_A, "a" => HASH_B])
    )
end

@testset "state_fingerprint refuses a hash that is not 32 bytes" begin
    @test_throws(
        ModelError, as_shown("table_hash of \"a\" is 1 bytes"),
        Model.state_fingerprint(["a" => UInt8[0]])
    )
end

@testset "state_fingerprint of a content hashes every table, by name" begin
    content = Content()
    Model.create_table!(content, "b", Shape([Column("k", "int64", false)], ["k"]))
    Model.create_table!(content, "a", Shape([Column("k", "text", false)], ["k"]))
    hashes = [name => Model.table_hash(content[name]) for name in ("a", "b")]
    @test Model.state_fingerprint(content) == Model.state_fingerprint(hashes)
    @test length(Model.state_fingerprint(content)) == 32
end

@testset "determinism vector: the tables that remain" begin
    @test sort(collect(keys(VECTOR_CONTENT))) == ["empty", "measurements", "points", "set"]
end

# Per table first, so that a mismatch names the table.
@testset "determinism vector: table_hash of $table" for (table, hex) in VECTOR_TABLE_HASHES
    @test bytes2hex(Model.table_hash(VECTOR_CONTENT[table])) == hex
end

@testset "determinism vector: state_fingerprint" begin
    @test bytes2hex(Model.state_fingerprint(VECTOR_CONTENT)) == VECTOR_STATE_FINGERPRINT
end

@testset "determinism vector: the same content, reached from its table files" begin
    reread = Content(
        name => Model.read_table(IOBuffer(table_bytes(table)))
            for (name, table) in VECTOR_CONTENT
    )
    @test Model.state_fingerprint(reread) == Model.state_fingerprint(VECTOR_CONTENT)
end
