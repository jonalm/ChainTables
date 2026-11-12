using Test
using ChainTables: ChainTables, ChainNotFoundError, ChainTablesError,
    CommitOutcomeUnknownError, GatewayMismatchError, LostRaceError, MalformedRecordError,
    RewrittenChainError, StaleHeadError, StateFingerprint, TransactionHash, TransportError,
    UnsupportedStoreError, WriteBuilderError, WriteRefusedError

const ZEROS = zeros(UInt8, 32)
const ONES = ones(UInt8, 32)
const CHAIN = "A"^26

# Each error built with Evidence and a detail, and the four parts its showerror writes.
const ERRORS = [
    (
        name = "StaleHeadError",
        error = StaleHeadError(;
            path = "/c", chain_id = CHAIN, slot = 3, chain_slot = 4,
            detail = "a sync! moved the copy",
        ),
        summary = "the write builder's head is behind the chain",
        evidence = "chain_slot = 4",
        next_move = "Run `sync!(copy)`",
    ),
    (
        name = "LostRaceError",
        error = LostRaceError(;
            location = "bkt/p", chain_id = CHAIN, slot = 4, transaction_hash = ZEROS,
            detail = "the commit lost",
        ),
        summary = "another client's record already fills the slot",
        evidence = "transaction_hash = $(bytes2hex(ZEROS))",
        next_move = "This call is spent and never retried",
    ),
    (
        name = "CommitOutcomeUnknownError",
        error = CommitOutcomeUnknownError(;
            chain_id = CHAIN, slot = 4, transaction_hash = ONES, landed = true,
            cause = ErrorException("network down"), detail = "the put failed",
        ),
        summary = "the commit may or may not have happened",
        evidence = "cause = network down",
        next_move = "the commit happened exactly when `commit_log(copy)`",
    ),
    (
        name = "UnsupportedStoreError",
        error = UnsupportedStoreError(;
            endpoint = "https://minio.local", call = "commit!",
            detail = "the endpoint is not AWS",
        ),
        summary = "the store is not AWS S3, so a commit to it is refused",
        evidence = "endpoint = https://minio.local",
        next_move = "set `assume_first_writer_wins = true`",
    ),
    (
        name = "WriteBuilderError",
        error = WriteBuilderError(;
            call = "insert_rows!(w, :t)", detail = "this builder is spent",
        ),
        summary = "the write was refused",
        evidence = "call = insert_rows!(w, :t)",
        next_move = "Fix the call named above; nothing was written.",
    ),
    (
        name = "ChainNotFoundError",
        error = ChainNotFoundError(;
            bucket = "bkt", prefix = "p", call = "open", detail = "slot 0 is absent",
        ),
        summary = "no chain at this bucket and prefix (no slot 0)",
        evidence = "prefix = p",
        next_move = "`create_chain(chain)`",
    ),
    (
        name = "RewrittenChainError",
        error = RewrittenChainError(;
            chain_id = CHAIN, slot = 2, expected = ZEROS, found = ONES,
            detail = "slot 2 changed",
        ),
        summary = "the chain contradicts what this local copy has applied",
        evidence = "found = $(bytes2hex(ONES))",
        next_move = "find out who wrote it",
    ),
    (
        name = "MalformedRecordError",
        error = MalformedRecordError(;
            chain_id = CHAIN, slot = 2, op = 1,
            detail = "insert on \"t\": unknown table \"t\"",
        ),
        summary = "the record cannot be applied under this format version",
        evidence = "op = 1",
        next_move = "The chain cannot be read beyond this slot",
    ),
    (
        name = "WriteRefusedError",
        error = WriteRefusedError(;
            chain_id = CHAIN, slot = 4, key = "p/000000000004",
            caller = "alice@example.com", reason = "not_allowed",
            detail = "the policy has no entry",
        ),
        summary = "the gateway refused the write",
        evidence = "caller = alice@example.com",
        next_move = "add this author to the gateway policy",
    ),
    (
        name = "GatewayMismatchError",
        error = GatewayMismatchError(;
            chain_id = CHAIN, slot = 4, key = "p/000000000004", bucket = "bkt",
            gateway = "https://gw", detail = "the object is absent",
        ),
        summary = "the gateway wrote to another bucket than this chain's",
        evidence = "gateway = https://gw",
        next_move = "Pair the bucket with its own gateway",
    ),
    (
        name = "TransportError",
        error = TransportError("GET p/0: HTTP 503 SlowDown"; status = 503),
        summary = "a request failed",
        evidence = "status = 503",
        next_move = "Check the network and the store, then try again.",
    ),
]

@testset "$(case.name) is a ChainTablesError" for case in ERRORS
    @test case.error isa ChainTablesError
end

@testset "$(case.name) shows its summary and detail first" for case in ERRORS
    text = sprint(showerror, case.error)
    @test startswith(text, "$(case.name): $(case.summary): $(case.error.detail).")
end

@testset "$(case.name) shows its Evidence" for case in ERRORS
    @test occursin("\n  $(case.evidence)", sprint(showerror, case.error))
end

@testset "$(case.name) shows its next move" for case in ERRORS
    @test occursin(case.next_move, sprint(showerror, case.error))
end

@testset "$(case.name) leaves out unknown Evidence" for case in ERRORS
    T = typeof(case.error)
    bare = T === TransportError ? TransportError("x") : T(; detail = "x")
    @test !occursin(" = nothing", sprint(showerror, bare))
end

@testset "an empty detail leaves the summary alone" begin
    @test startswith(
        sprint(showerror, WriteBuilderError()),
        "WriteBuilderError: the write was refused.\n",
    )
end

@testset "a hash given as bytes is carried as its type" begin
    e = RewrittenChainError(; expected = ZEROS, found = TransactionHash(ONES))
    @test e.expected isa TransactionHash
    @test e.found isa TransactionHash
    @test e.found == ONES
    @test LostRaceError(; transaction_hash = ZEROS).transaction_hash isa TransactionHash
    unknown = CommitOutcomeUnknownError(; transaction_hash = ZEROS)
    @test unknown.transaction_hash isa TransactionHash
end

@testset "a hash Evidence refuses what is not 32 bytes" begin
    @test_throws(
        ArgumentError, "a TransactionHash is 32 bytes, got 3",
        LostRaceError(; transaction_hash = UInt8[1, 2, 3]),
    )
end

const REFUSAL_REASONS = [
    (reason = "not_allowed", next_move = "Ask the bucket's operator to add this author"),
    (reason = "author_mismatch", next_move = "report it as a bug"),
    (reason = "forbidden", next_move = "Ask the operator for the writer permission set"),
    (reason = "something_new", next_move = "A person must act before a retry can succeed."),
]

@testset "WriteRefusedError for $(case.reason) names who acts" for case in REFUSAL_REASONS
    e = WriteRefusedError(; reason = case.reason)
    @test occursin(case.next_move, sprint(showerror, e))
end

@testset "WriteRefusedError keeps the fields test/live reads" begin
    e = WriteRefusedError(;
        key = "p/000000000004", caller = "alice@example.com", reason = "not_allowed",
        slot = 4,
    )
    @test (e.key, e.caller, e.reason, e.slot) == (
        "p/000000000004", "alice@example.com", "not_allowed", 4,
    )
end

@testset "TransportError keeps the status and puts the detail in the text" begin
    e = TransportError("PUT p/1: HTTP 403 AccessDenied"; status = 403)
    @test e.status == 403
    @test occursin("AccessDenied", sprint(showerror, e))
    @test TransportError("no answer").status === nothing
end

@testset "error constructors infer" begin
    @test @inferred(StaleHeadError(; path = "/c", slot = 1)).slot == 1
    @test @inferred(LostRaceError(; slot = 1, transaction_hash = ZEROS)).slot == 1
    @test @inferred(CommitOutcomeUnknownError(; slot = 1, landed = true)).landed
    @test @inferred(UnsupportedStoreError(; endpoint = "e")).endpoint == "e"
    @test @inferred(WriteBuilderError(; call = "c")).call == "c"
    @test @inferred(ChainNotFoundError(; bucket = "b")).bucket == "b"
    @test @inferred(RewrittenChainError(; expected = ZEROS, found = ONES)).expected == ZEROS
    @test @inferred(MalformedRecordError(; op = 1)).op == 1
    @test @inferred(WriteRefusedError(; reason = "forbidden")).reason == "forbidden"
    @test @inferred(GatewayMismatchError(; gateway = "g")).gateway == "g"
    @test @inferred(TransportError("x"; status = 500)).status == 500
end
