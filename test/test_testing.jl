using Test
using ChainTables: ChainTables

@testset "Testing makes only InMemoryObjectStore public, and exports nothing" begin
    @test names(ChainTables.Testing) == [:InMemoryObjectStore, :Testing]
    @test Base.ispublic(ChainTables.Testing, :InMemoryObjectStore)
    @test !Base.isexported(ChainTables.Testing, :InMemoryObjectStore)
end
