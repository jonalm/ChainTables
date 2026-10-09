# #81: Aqua's package hygiene checks, run with the suite so every CI cell enforces them.
using Aqua

@testset "Aqua" begin
    # Tables is in [deps] but src/ never loads it; #72 decides whether it becomes a real
    # dependency or leaves [deps]. Remove this ignore with that decision.
    Aqua.test_all(ChainTables; stale_deps = (ignore = [:Tables],))
end
