using Test
using ChainTables: Model, Ops

@testset "CreateTable example" begin
    shape = Model.Shape([Model.Column("id", "int64", false)], ["id"])
    op = Ops.CreateTable("samples", shape)
    @test op.table == "samples"
end

@testset "AddColumn example" begin
    # Every existing row gets the fill, here 0.0.
    op = Ops.AddColumn("samples", Model.Column("mass", "float64", false), 0.0)
    @test op.fill == 0.0
end

@testset "DropColumn example" begin
    op = Ops.DropColumn("samples", "mass")
    @test op.column == "mass"
end

@testset "DropTable example" begin
    op = Ops.DropTable("samples")
    @test op.table == "samples"
end

@testset "Insert example" begin
    # Two rows of a table with the columns `id` and `label`, in key order.
    op = Ops.Insert("samples", [Any[1, "a"], Any[2, missing]])
    @test length(op.rows) == 2
end

@testset "Update example" begin
    # Set `label` of the row with key 1. Each row is the key, then the new values.
    op = Ops.Update("samples", ["label"], [Any[1, "b"]])
    @test op.columns == ["label"]
end

@testset "Delete example" begin
    # Delete the rows with keys 1 and 2.
    op = Ops.Delete("samples", [Any[1], Any[2]])
    @test length(op.keys) == 2
end
