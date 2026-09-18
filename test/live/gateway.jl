# Live gateway (issue #60, ADR-0030): the one test only AWS can answer for ADR-0028, and the
# live coverage of `Bucket` / `Chain(bucket, prefix)` (ADR-0029) — every commit's post-200
# HEAD passing means the bucket and the gateway really are paired. Run by
# test/live/runtests.jl with its configuration resolved. Under the profile's login session
# it creates a chain under a fresh prefix the policy lists the caller under and commits
# through the gateway; a direct put to the bucket is denied; a commit racing for a slot
# loses; a record naming another author, and a chain under an unlisted prefix, are refused;
# a record over 4 MiB fails at commit before any call. Never deletes (the port has no delete
# verb): the bucket's operator expires `<prefix>/` objects, or keeps them.
using ChainTables: Bucket, Chain, GatewayObjectStore, PutOutcome, TransportError, WriteRefusedError, WriteBuilderError,
    LostRaceError, fetch_object, put_object_if_absent, stat_object, list_objects

# ---------------------------------------------------------------------------
# A store wrapper that runs a hook ahead of each put, so a competing commit can land
# between a commit's preflight and its put — the race test/chain.jl injects through the
# double's fault hook.
# ---------------------------------------------------------------------------

mutable struct RacingGateway <: GWT.AbstractObjectStore
    const inner::GatewayObjectStore
    before_put::Any               # key -> nothing, run ahead of every put
end
GWT.is_aws(s::RacingGateway) = GWT.is_aws(s.inner)
GWT.record_cap(s::RacingGateway) = GWT.record_cap(s.inner)
GWT.record_author(s::RacingGateway) = GWT.record_author(s.inner)
GWT.fetch_object(s::RacingGateway, key::AbstractString) = fetch_object(s.inner, key)
GWT.stat_object(s::RacingGateway, key::AbstractString) = stat_object(s.inner, key)
GWT.list_objects(s::RacingGateway, prefix::AbstractString; start_after = nothing) = list_objects(s.inner, prefix; start_after)
function GWT.put_object_if_absent(s::RacingGateway, key::AbstractString, bytes)
    s.before_put(key)
    return put_object_if_absent(s.inner, key, bytes)
end

@testset "live gateway" begin
    config = LIVE_CONFIG[:gateway]
    b = Bucket(config.bucket; config.region, gateway = config.url, config.profile)
    bucket = b.name
    listed = config.prefix                       # a prefix the policy lists the caller under
    unlisted = config.unlisted_prefix            # one it does not
    run = bytes2hex(rand(UInt8, 8))
    prefix = "$listed/$run"
    mktempdir() do dir
        cache_dir = joinpath(dir, "cache")
        chain = Chain(b, prefix; cache_dir)
        @test chain isa Chain{GatewayObjectStore} && GWT.is_aws(chain.store)
        store = chain.store
        # the author: the session name of the SSO role from STS, under the session's own key
        author = GWT.record_author(store)
        @test author isa String && !isempty(author) && store.author_key == GWT.current_credentials(store.s3).access_key_id
        # create_chain through the gateway; the genesis carries the author; reads are direct
        key0 = GWT.slot_key(chain, 0)
        @test fetch_object(store, key0) === nothing && stat_object(store, key0) === nothing && isempty(list_objects(store, prefix * "/"))
        created = GWT.create_chain(chain)
        @test created.slot == 0
        genesis = fetch_object(store, key0)
        @test genesis !== nothing && GWT.Ops.decode_record(genesis; slot = 0).client.user == author
        @test [m.key for m in list_objects(store, prefix * "/")] == [key0]
        # the bucket policy's Deny: a direct put by the writer is refused by S3, only the gateway fills slots
        key1 = GWT.slot_key(chain, 1)
        e = try put_object_if_absent(store.s3, key1, genesis); nothing catch e; e end
        @test e isa TransportError && e.status == 403 && occursin("AccessDenied", sprint(showerror, e))
        @test stat_object(store, key1) === nothing
        # a taken slot through the gateway is slot_taken, never an overwrite
        @test put_object_if_absent(store, key0, gwtest_record(author)) == PutOutcome(false, 412)
        @test fetch_object(store, key0) == genesis
        # a commit round-trips through two local copies; the record names the author
        a = GWT.open(chain, joinpath(dir, "a"))
        @test GWT.sync!(a).slot == 0
        w = GWT.write_builder(a)
        GWT.create_table!(w, :samples) do t
            GWT.column!(t, :id, Int64); GWT.column!(t, :note, String); GWT.primary_key!(t, :id)
        end
        GWT.insert_rows!(w, :samples, [(id = 1, note = "live"), (id = 2, note = "gateway")])
        done = GWT.commit!(w; comment = "the live gateway test")
        @test done.slot == 1
        @test GWT.Ops.decode_record(fetch_object(store, key1); slot = 1).client.user == author
        b = GWT.open(chain, joinpath(dir, "b"))
        @test GWT.sync!(b) == (; applied = 2, slot = 1, transaction_hash = done.transaction_hash)
        @test GWT.table(b, :samples)[2].note == "gateway"
        @test GWT.verify(b; full = true) === nothing
        close(b)
        # the lost race: a's record lands while c's put is in flight (after c's preflight); c
        # gets slot_taken, reads a's record back, and loses; its head and files stand
        racing = RacingGateway(store, _ -> nothing)
        c = GWT.open(Chain(b, prefix; store = racing, cache_dir), joinpath(dir, "c"))
        @test GWT.sync!(c).slot == 1
        wa = GWT.write_builder(a)
        GWT.insert_rows!(wa, :samples, [(id = 3, note = "from a")])
        wc = GWT.write_builder(c)
        GWT.insert_rows!(wc, :samples, [(id = 4, note = "from c")])
        ra = Ref{Any}(nothing)
        racing.before_put = key -> (racing.before_put = _ -> nothing; ra[] = GWT.commit!(wa); nothing)
        e = try GWT.commit!(wc); nothing catch e; e end
        @test ra[] !== nothing && ra[].slot == 2
        @test e isa LostRaceError && (e.chain_id, e.slot, e.transaction_hash) == (created.chain_id, 2, ra[].transaction_hash)
        @test GWT.head(c).slot == 1 && length(GWT.table(c, :samples)) == 2
        @test GWT.sync!(c).slot == 2 && [r.note for r in GWT.table(c, :samples)] == ["live", "gateway", "from a"]
        @test_throws "this builder is spent" GWT.commit!(wc)
        # a record naming another author is refused as author_mismatch; nothing lands
        key3 = GWT.slot_key(chain, 3)
        e = try put_object_if_absent(store, key3, gwtest_record(author * ".impostor")); nothing catch e; e end
        @test e isa WriteRefusedError && e.reason == "author_mismatch" && e.key == key3 && e.caller == author
        @test occursin("author_mismatch: the record names '$author.impostor' as client.user but the caller is '$author'", sprint(showerror, e))
        @test stat_object(store, key3) === nothing
        # a chain under a prefix the policy does not list the caller under: not_allowed at slot 0
        denied = Chain(b, "$unlisted/$run"; cache_dir)
        e = try GWT.create_chain(denied); nothing catch e; e end
        @test e isa WriteRefusedError && e.reason == "not_allowed" && e.slot == 0 && e.caller == author
        @test e.key == GWT.slot_key(denied, 0) && stat_object(denied.store, e.key) === nothing
        @test startswith(sprint(showerror, e), "WriteRefusedError: write refused for slot 0 of chain $(e.chain_id) at $bucket/$unlisted/$run: ")
        @test occursin("not_allowed: ", sprint(showerror, e)) && occursin("ask the bucket's operator to add the name to the gateway policy", sprint(showerror, e))
        # the cap: a record over 4 MiB is refused at commit before any put; the copy stands at its head
        # (c's store is the wrapper, and the message names the store it was asked about)
        puts = Ref(0)
        racing.before_put = _ -> (puts[] += 1; nothing)
        w = GWT.write_builder(c)
        GWT.insert_rows!(w, :samples, [(id = 5, note = "x"^(4 * 1024 * 1024 + 100))])
        e = try GWT.commit!(w); nothing catch e; e end
        @test e isa WriteBuilderError && occursin("the cap on a RacingGateway is 4194304 bytes (4 MiB)", sprint(showerror, e))
        @test puts[] == 0 && GWT.head(c).slot == 2 && stat_object(store, key3) === nothing
        close(a); close(c)
    end
end
