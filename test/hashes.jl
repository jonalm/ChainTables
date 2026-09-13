# #34 step 8 — ADR-0019: TransactionHash and StateFingerprint, 32 bytes each, shown as hex,
# distinct so one is never passed for the other.
using ChainTables: TransactionHash, StateFingerprint

@testset "hashes" begin
    b = UInt8.(0:31)
    hx = bytes2hex(b)
    for T in (TransactionHash, StateFingerprint)
        h = T(b)
        @test h.bytes == b && h.bytes !== b                     # its own copy
        @test T(hx) == h && T(uppercase(hx)) == h               # hex in, case-insensitive
        @test bytes2hex(h) == hx
        @test T(h) === h
        @test h == b && b == h                                  # the bytes are the value
        @test h == T(copy(b)) && isequal(h, T(copy(b)))
        @test hash(h) == hash(T(copy(b))) == hash(b)
        @test h != T(zeros(UInt8, 32)) && h != zeros(UInt8, 32)
        @test sprint(show, h) == "$(nameof(T))(\"$hx\")"
        @test_throws "a $(nameof(T)) is 32 bytes, got 2" T(UInt8[1, 2])
        @test_throws "a $(nameof(T)) is 32 bytes, got 31" T(hx[1:62])
        @test_throws "is not 64 hex characters" T("zz" * hx[3:end])
        @test_throws "is 32 bytes or 64 hex characters, got a value of type Int64" T(7)
    end
    # the two are never equal and never accept each other
    th, fp = TransactionHash(b), StateFingerprint(b)
    @test th != fp && fp != th && !isequal(th, fp)
    @test_throws "a TransactionHash is 32 bytes or 64 hex characters, got a value of type StateFingerprint" TransactionHash(fp)
    @test_throws "got a value of type TransactionHash" StateFingerprint(th)
    # inside a Dict and a Set, by value
    d = Dict(TransactionHash(b) => 1)
    @test d[TransactionHash(hx)] == 1
    @test TransactionHash(b) in Set([TransactionHash(copy(b))])
end
