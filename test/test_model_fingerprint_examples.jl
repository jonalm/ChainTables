using Test
using ChainTables: Model

@testset "state_fingerprint example" begin
    shape = Model.Shape([Model.Column("id", "int64", false)], ["id"])
    content = Model.Content("samples" => Model.Table(shape, [Any[1]], 1))

    # The fingerprint of a whole content: 32 bytes.
    fingerprint = Model.state_fingerprint(content)
    @test length(fingerprint) == 32

    # The same fingerprint from each table's name and hash, as a head file lists them.
    listed = ["samples" => Model.table_hash(content["samples"])]
    @test Model.state_fingerprint(listed) == fingerprint
end
