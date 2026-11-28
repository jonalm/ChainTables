using Test
using ChainTables: Model

@testset "Table example" begin
    columns = [Model.Column("id", "int64", false), Model.Column("label", "text", true)]
    shape = Model.Shape(columns, ["id"])

    # An empty table of that shape.
    @test isempty(Model.Table(shape).slots)

    # A table with two rows, in key order. Each row is stamped with the slot of the
    # record that wrote it, here slot 3.
    table = Model.Table(shape, [Any[1, "a"], Any[2, missing]], 3)
    @test table.slots == [3, 3]
end
