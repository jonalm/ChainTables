using Test
# The table model is internal; its rules are the format's spec (ADR-0025), so they are
# tested here directly rather than through an API name.
using ChainTables: ChainTables, Column, Content, ModelError, Shape, Table, add_table!,
    content_table, remove_table!

const SHAPE = Shape([Column("id", "int64", false), Column("v", "text", true)], ["id"])

@testset "add_table! adds an empty table by name" begin
    c = Content()
    add_table!(c, "t", SHAPE)
    @test collect(keys(c)) == ["t"]
    @test content_table(c, "t") isa Table
end

@testset "add_table! accepts a name starting with _" begin
    @test add_table!(Content(), "_t", SHAPE) isa Table
end

const REFUSED_NAMES = [
    (name = "a name in use", table = "t", message = "table \"t\" already exists"),
    (
        name = "an upper-case name",
        table = "T",
        message = "table name \"T\" is not an identifier",
    ),
    (
        name = "a trailing newline",
        table = "t\n",
        message = "table name \"t\\n\" is not an identifier",
    ),
]

@testset "add_table! refuses $(case.name)" for case in REFUSED_NAMES
    c = Content("t" => Table(SHAPE))
    @test_throws ModelError case.message add_table!(c, case.table, SHAPE)
end

@testset "remove_table! removes a table by name" begin
    c = Content("t" => Table(SHAPE))
    remove_table!(c, "t")
    @test isempty(c)
end

@testset "an unknown table is refused" begin
    @test_throws ModelError "unknown table \"u\"" remove_table!(Content(), "u")
    @test_throws ModelError "unknown table \"u\"" content_table(Content(), "u")
end
