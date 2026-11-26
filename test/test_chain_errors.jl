using Test
using ChainTables: ChainNotFoundError, DivergenceError, FingerprintMismatchError,
    MalformedRecordError, RecordCacheError, RewrittenChainError, StateFingerprint,
    TransactionHash

include("fixtures/evidence.jl")

@testset "FingerprintMismatchError shows what happened, the evidence, the next move" begin
    e = FingerprintMismatchError(;
        path = COPY_PATH, chain_id = CHAIN_ID, slot = 3,
        expected = StateFingerprint(ZEROS), computed = StateFingerprint(ONES),
        record_client = (; lib = "ChainTables 0.3.1", julia = "1.12.0"),
        this_client = (; lib = "ChainTables 0.3.2", julia = "1.13.2")
    )
    @test sprint(showerror, e) ==
        "FingerprintMismatchError: a state fingerprint is not the one this client " *
        "computes.\n" *
        "  path = /lab/copy\n" *
        "  chain_id = AAAAAAAAAAAAAAAAAAAAAAAAAA\n" *
        "  slot = 3\n" *
        "  expected = $ZEROS_HEX\n" *
        "  computed = $ONES_HEX\n" *
        "  record_client = ChainTables 0.3.1 on Julia 1.12.0\n" *
        "  this_client = ChainTables 0.3.2 on Julia 1.13.2\n" *
        "Run `repair!(copy)`: it rewrites damaged table files and says whether this " *
        "machine reproduces the chain."
end

@testset "DivergenceError shows what happened, the evidence and the next move" begin
    e = DivergenceError(;
        path = COPY_PATH, chain_id = CHAIN_ID, slot = 3,
        expected = StateFingerprint(ZEROS), computed = StateFingerprint(ONES),
        tables = ["pairs", "samples"],
    )
    @test sprint(showerror, e) ==
        "DivergenceError: a fresh replay of the record cache does not give the " *
        "head's state fingerprint.\n" *
        "  path = /lab/copy\n" *
        "  chain_id = AAAAAAAAAAAAAAAAAAAAAAAAAA\n" *
        "  slot = 3\n" *
        "  expected = $ZEROS_HEX\n" *
        "  computed = $ONES_HEX\n" *
        "  tables = [\"pairs\", \"samples\"]\n" *
        "This machine cannot reproduce the chain. Nothing was written; the local " *
        "copy stays readable and never commits onto this chain."
end

@testset "RewrittenChainError shows what happened, the evidence and the next move" begin
    e = RewrittenChainError(;
        path = COPY_PATH, bucket = "bkt", prefix = "p", chain_id = CHAIN_ID, slot = 3,
        expected = TransactionHash(ZEROS), found = TransactionHash(ONES),
    )
    @test sprint(showerror, e) ==
        "RewrittenChainError: the bucket contradicts what the local copy has " *
        "applied.\n" *
        "  path = /lab/copy\n" *
        "  bucket = bkt\n" *
        "  prefix = p\n" *
        "  chain_id = AAAAAAAAAAAAAAAAAAAAAAAAAA\n" *
        "  slot = 3\n" *
        "  expected = $ZEROS_HEX\n" *
        "  found = $ONES_HEX\n" *
        "The bucket was written from outside the protocol, and nothing heals it. " *
        "The local copy stays readable."
end

@testset "ChainNotFoundError shows what happened, the evidence and the next move" begin
    e = ChainNotFoundError(; bucket = "bkt", prefix = "p")
    @test sprint(showerror, e) ==
        "ChainNotFoundError: there is no slot 0 at this bucket and prefix.\n" *
        "  bucket = bkt\n" *
        "  prefix = p\n" *
        "Either the bucket or prefix is not the chain's, or no chain was created " *
        "there; the two cannot be told apart from here. `create_chain(chain)` " *
        "writes slot 0."
end

@testset "RecordCacheError shows what happened, the evidence and the next move" begin
    e = RecordCacheError(;
        chain_id = CHAIN_ID, slot = 2, path = "/c/bkt/p/000000000002",
        expected = TransactionHash(ZEROS), found = TransactionHash(ONES)
    )
    @test sprint(showerror, e) ==
        "RecordCacheError: the record cache does not hold the record that the " *
        "chain names for this slot.\n" *
        "  chain_id = AAAAAAAAAAAAAAAAAAAAAAAAAA\n" *
        "  slot = 2\n" *
        "  path = /c/bkt/p/000000000002\n" *
        "  expected = $ZEROS_HEX\n" *
        "  found = $ONES_HEX\n" *
        "The record cache is damaged, not the chain. Run `repair!(copy)`, which " *
        "fetches the record from the object store and replaces the file."
end

@testset "MalformedRecordError shows what happened, the evidence and the next move" begin
    e = MalformedRecordError(;
        chain_id = CHAIN_ID, slot = 2, op = 1, detail = "op 1: unknown table \"t\""
    )
    @test sprint(showerror, e) ==
        "MalformedRecordError: no client can apply this record under its format " *
        "version.\n" *
        "op 1: unknown table \"t\"\n" *
        "  chain_id = AAAAAAAAAAAAAAAAAAAAAAAAAA\n" *
        "  slot = 2\n" *
        "  op = 1\n" *
        "Whoever committed it had a bug, and the chain is dead beyond this slot. " *
        "A new chain is the recovery."
end
