# #81: Aqua's package hygiene checks, run with the suite so every CI cell enforces them.
using Aqua

@testset "Aqua" begin
    Aqua.test_all(ChainTables)
end
