using Test
using ChainTables: Model
# The model's rules are the format's spec. The write builder and apply report them
# through two public errors, so they are tested once here, where they live.
using ChainTables.Model: Column, Content, ModelError, Shape, Table

include("fixtures/internal_errors.jl")

const KEY_ONLY = Shape([Column("id", "int64", false)], ["id"])

function one_table()
    content = Content()
    Model.create_table!(content, "t", KEY_ONLY)
    return content
end

@testset "create_table! adds an empty table under its name" begin
    content = one_table()
    @test collect(keys(content)) == ["t"]
    @test Model.table(content, "t") isa Table
end

@testset "create_table! takes a table name that starts with an underscore" begin
    @test Model.create_table!(Content(), "_t", KEY_ONLY) isa Table
end

@testset "create_table! refuses a name in use" begin
    @test_throws(
        ModelError, as_shown("table \"t\" already exists"),
        Model.create_table!(one_table(), "t", KEY_ONLY)
    )
end

@testset "create_table! refuses a name that is not an identifier" begin
    @test_throws(
        ModelError, as_shown("table name \"T\" is not an identifier"),
        Model.create_table!(Content(), "T", KEY_ONLY)
    )
end

@testset "drop_table! removes the table" begin
    content = one_table()
    Model.drop_table!(content, "t")
    @test isempty(content)
end

@testset "drop_table! refuses an unknown table" begin
    @test_throws(
        ModelError, as_shown("unknown table \"u\""), Model.drop_table!(one_table(), "u")
    )
end

@testset "table refuses an unknown table" begin
    @test_throws ModelError as_shown("unknown table \"u\"") Model.table(one_table(), "u")
end
