using Test
using ChainTables: Model, Ops

@testset "apply! example" begin
    shape = Model.Shape([Model.Column("id", "int64", false)], ["id"])
    content = Model.Content()

    # One op at a time, as the write builder does: create a table at slot 1.
    Ops.apply!(content, Ops.CreateTable("samples", shape), 1)
    @test haskey(content, "samples")

    # A whole record, as replay does: the record at slot 2 inserts one row, and the row
    # is stamped with that slot.
    client = Ops.Client(nothing, nothing, "ChainTables 0.3.3", "1.13.2", 1000)
    ops = [Ops.Insert("samples", [Any[7]])]
    parent = zeros(UInt8, 32)
    fingerprint = zeros(UInt8, 32)
    record = Ops.Record(UInt8.(0:15), 2, parent, fingerprint, client, nothing, ops)
    Ops.apply!(content, record)
    @test content["samples"].slots == [2]
end
