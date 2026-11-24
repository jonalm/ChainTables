using Test
using ChainTables: Model

@testset "write_table example" begin
    shape = Model.Shape([Model.Column("id", "int64", false)], ["id"])
    table = Model.Table(shape, [Any[1], Any[2]], 1)

    # Stream the table's file. The result is the SHA-256 of the bytes written, which
    # names the file.
    io = IOBuffer()
    hash = Model.write_table(io, table)
    @test length(hash) == 32
    @test startswith(String(take!(io)), "chaintables/v1/fp-table")
end

@testset "table_hash example" begin
    shape = Model.Shape([Model.Column("id", "int64", false)], ["id"])

    # The hash covers the shape, the rows and each row's slot.
    at_slot_1 = Model.Table(shape, [Any[1]], 1)
    at_slot_2 = Model.Table(shape, [Any[1]], 2)
    @test Model.table_hash(at_slot_1) != Model.table_hash(at_slot_2)
end

@testset "read_table example" begin
    shape = Model.Shape([Model.Column("id", "int64", false)], ["id"])
    io = IOBuffer()
    Model.write_table(io, Model.Table(shape, [Any[1], Any[2]], 1))

    # Read the file back into a table.
    table = Model.read_table(seekstart(io))
    @test table.shape == shape
    @test table.slots == [1, 1]
end
