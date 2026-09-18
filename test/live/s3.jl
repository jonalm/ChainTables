# Live S3 (issue #6, ADR-0030): the one test only AWS can answer for the plain S3 client
# (ADR-0010, ADR-0016) — a plain bucket, since it puts directly. Run by test/live/runtests.jl
# with its configuration resolved. Builds the chain from a `Bucket` (ADR-0029) under a fresh
# prefix and never deletes: the port has no delete verb, so the bucket's operator expires
# `chaintables-test/`, or keeps it.
using ChainTables: Bucket, Chain, S3ObjectStore, PutOutcome, fetch_object, put_object_if_absent, stat_object, list_objects
const S3T = ChainTables

@testset "live S3" begin
    config = LIVE_CONFIG[:s3]
    b = Bucket(config.bucket; config.region, config.profile)
    prefix = LIVE_S3_PREFIX * "/" * bytes2hex(rand(UInt8, 8))
    mktempdir() do dir
        cache_dir = joinpath(dir, "cache")
        chain = Chain(b, prefix; cache_dir)
        @test chain.store isa S3ObjectStore && S3T.is_aws(chain.store)
        store = chain.store
        # under a session, the token is signed and sent — the request below would be 403 otherwise
        session = S3T.current_credentials(store).session_token !== nothing
        req = S3T.request_headers(store, "GET", S3T.slot_key(chain, 0))
        @test session == any(kv -> kv[1] == "x-amz-security-token", req.headers)
        @test session == occursin("x-amz-security-token", last(req.headers[findfirst(kv -> kv[1] == "authorization", req.headers)]))
        key = S3T.slot_key(chain, 0)
        @test fetch_object(store, key) === nothing && stat_object(store, key) === nothing && isempty(list_objects(store, prefix * "/"))
        created = S3T.create_chain(chain)
        # the header is not silently dropped: the second conditional PUT to the key fails 412 …
        @test put_object_if_absent(store, key, b"an impostor genesis") == PutOutcome(false, 412)
        # … a GET of the just-created key returns it …
        bytes = fetch_object(store, key)
        @test bytes !== nothing && S3T.TransactionHash(S3T.Ops.transaction_hash(bytes)) == created.transaction_hash
        meta = stat_object(store, key)
        @test meta.key == key && meta.size == length(bytes) && abs(meta.modified - time()) < 300
        @test [m.key for m in list_objects(store, prefix * "/")] == [key]
        # … and a chain round-trips through two local copies
        copy = S3T.open(chain, joinpath(dir, "a"))
        @test S3T.sync!(copy).slot == 0
        w = S3T.write_builder(copy)
        S3T.create_table!(w, :samples) do t
            S3T.column!(t, :id, Int64); S3T.column!(t, :label, String); S3T.primary_key!(t, :id)
        end
        S3T.insert_rows!(w, :samples, [(id = 1, label = "live"), (id = 2, label = "s3")])
        done = S3T.commit!(w; comment = "the live test")
        @test done.slot == 1
        other = S3T.open(chain, joinpath(dir, "b"))
        @test S3T.sync!(other) == (; applied = 2, slot = 1, transaction_hash = done.transaction_hash)
        @test S3T.table(other, :samples)[2].label == "s3"
        @test S3T.verify(other; full = true) === nothing
        close(copy); close(other)
    end
end
