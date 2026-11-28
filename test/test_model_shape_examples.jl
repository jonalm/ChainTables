using Test
using ChainTables: Model

@testset "Column example" begin
    # A column that holds 64-bit floats and admits null.
    mass = Model.Column("mass", "float64", true)
    @test mass.nullable
end

@testset "Shape example" begin
    # Two columns in declaration order; the primary key is `id`.
    columns = [Model.Column("id", "int64", false), Model.Column("mass", "float64", true)]
    shape = Model.Shape(columns, ["id"])
    @test [c.name for c in shape.columns] == ["id", "mass"]
    @test shape.key == ["id"]

    # The same shape read from its wire form, as a record or a table file carries it.
    wire = Dict{String, Any}(
        "columns" => Any[Any["id", "int64", false], Any["mass", "float64", true]],
        "key" => Any["id"],
    )
    @test Model.Shape(wire) == shape
end
