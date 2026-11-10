# Live attachments (issue #90, ADR-0046's "Consequences", ADR-0030): what only S3 and a real
# gateway can answer about attachments, on a locked gateway bucket. Run by
# test/live/runtests.jl with its configuration resolved.
#
# The gateway policy must list the caller under `<prefix>/*` and under "" (the bucket root),
# and not under `<prefix>` itself: then a mint of `<prefix>/_attachments/<h>` tells checking
# the policy against the attachment's chain (`<prefix>`, refused) from checking it against the
# key up to its last '/' (`<prefix>/_attachments`, which `<prefix>/*` would admit), and a mint
# of the root `_attachments/<h>` tells it the other way round. Those mints, like every mint of
# an absent key here, store nothing: the gateway only presigns.
#
# On one URL the gateway minted: a body that does not hash to the key is BadDigest; a signed
# header omitted or altered, or an unsigned x-amz-* header, is refused; the right body is
# stored with COMPLIANCE retention, SSE-KMS under the signed key, Bucket Key, the checksum and
# the tag; the same URL again is 412. A mint of the present key mints no URL and moves its
# retain-until later. Then the client's round trip: put_attachment (over the function URL's
# 6 MB, so the bytes demonstrably bypass the gateway), touch_attachment, and attachment
# through a miss and through a hit another copy filled.
#
# Not here: a presigned PUT to a slot (DenyPresignedSlotPuts) needs a URL signed by the gateway
# role, which the gateway never mints for a slot; gateway/probe/attachment_probe.py's `slot`
# case proves it. A body shorter than the signed Content-Length: libcurl sends the signed
# length and S3 waits for the missing bytes, so it ends in a stall, not an answer; the altered
# content-length below is the signature half of it.
#
# Leaves behind for good: a genesis slot under `<prefix>/<run>/` and two attachments, each
# retained for the bucket's N days plus about a day. A locked bucket refuses lifecycle rules
# (ADR-0042), so they stay until retention ends and someone deletes them.
using ChainTables: Bucket, Chain, GatewayObjectStore, TransportError, WriteRefusedError, AttachmentChangedError,
    AttachmentAbsentError, attachment, put_attachment, touch_attachment, stat_object

# The headers of a HEAD of `key` in the chain's bucket, by the caller's own credentials.
function live_head(store::GatewayObjectStore, key)
    r = GWT.s3_request(store.s3, "HEAD", key; headers = ["x-amz-checksum-mode" => "ENABLED"])
    r.status == 200 || error("HEAD $key: HTTP $(r.status)")
    return Dict(lowercase(k) => v for (k, v) in r.headers)
end

# An ISO 8601 UTC date to the second, whatever S3 or botocore appended: comparable as text.
iso_second(s) = (occursin(r"\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d", s) || error("not an ISO 8601 date: $s"); s[1:19])
retain_until(store, key) = iso_second(live_head(store, key)["x-amz-object-lock-retain-until-date"])

# A streamed PUT of `body` to a minted URL with `headers`: S3's status and its error document.
function raw_put(url, headers, body)
    output = IOBuffer()
    r = GWT.http_stream(url, "PUT", headers; input = IOBuffer(body), output, stall = 60)
    return (; r.status, text = String(take!(output)))
end

without(headers, name) = filter(kv -> first(kv) != name, headers)
replacing(headers, name, value) = [first(kv) == name ? name => value : kv for kv in headers]
signed(headers, name) = last(headers[findfirst(kv -> first(kv) == name, headers)])
random_hash() = bytes2hex(rand(UInt8, 32))

@testset "live attachments" begin
    config = LIVE_CONFIG[:attachments]
    gwbucket = Bucket(config.bucket; config.region, gateway = config.url, config.profile)
    base = config.prefix
    run_id = bytes2hex(rand(UInt8, 8))
    prefix = "$base/$run_id"
    mktempdir() do dir
        cache_dir = joinpath(dir, "cache")
        chain = Chain(gwbucket, prefix; cache_dir)
        store = chain.store
        @test store isa GatewayObjectStore && GWT.is_aws(store)
        author = GWT.record_author(store)

        @testset "the policy is checked against the attachment's chain" begin
            # <base>/_attachments/<h> belongs to chain <base>, which the policy does not list
            key = "$base/_attachments/$(random_hash())"
            e = try GWT.mint(store, key, Int64(1)); nothing catch e; e end
            @test e isa WriteRefusedError && e.reason == "not_allowed" && e.key == key && e.caller == author
            @test occursin("may not write under prefix '$base'", sprint(showerror, e))
            # the root _attachments/<h> belongs to the root chain, which it does
            @test GWT.mint(store, "_attachments/$(random_hash())", Int64(1)).code == "minted"
            # this run's chain: listed under <base>/*
            @test GWT.mint(store, GWT.attachment_key(chain, random_hash()), Int64(1)).code == "minted"
            # a slot key is not minted for
            e = try GWT.mint(store, "$prefix/000000000000", Int64(1)); nothing catch e; e end
            @test e isa TransportError && e.status == 400 && occursin("not_a_slot", sprint(showerror, e))
        end

        @testset "S3 enforces what the minted URL signs" begin
            body = rand(UInt8, 4096)
            h = bytes2hex(GWT.sha256(body))
            key = GWT.attachment_key(chain, h)
            reply = GWT.mint(store, key, Int64(length(body)))
            @test reply.code == "minted"
            @test startswith(reply.url, "https://$(config.bucket).s3.$(config.region).amazonaws.com/$key?")
            # the deployed gateway's lifetime: 15 min plus the size at 256 KiB/s (an upload must end before its URL
            # expires, ADR-0046), as the reply says and the URL signs; a fresh environment is not capped at this size
            @test (reply.seconds, reply.capped) == (900 + cld(length(body), 256 * 1024), false)
            @test occursin("X-Amz-Expires=$(reply.seconds)&", reply.url * "&")
            names = Set(first.(reply.headers))
            @test names == Set(["content-type", "content-length", "if-none-match", "x-amz-checksum-sha256", "x-amz-tagging",
                                "x-amz-server-side-encryption", "x-amz-server-side-encryption-aws-kms-key-id",
                                "x-amz-server-side-encryption-bucket-key-enabled", "x-amz-object-lock-mode",
                                "x-amz-object-lock-retain-until-date"])
            @test signed(reply.headers, "x-amz-checksum-sha256") == GWT.checksum_sha256(h)
            @test signed(reply.headers, "content-length") == string(length(body))
            # a body of the signed length that does not hash to the key: BadDigest, nothing stored
            wrong = copy(body); wrong[1] ⊻= 0x01
            e = try GWT.upload_minted(store, key, IOBuffer(wrong), Int64(length(wrong)), reply); nothing catch e; e end
            @test e isa AttachmentChangedError && e.key == key
            r = raw_put(reply.url, reply.headers, wrong)
            @test r.status == 400 && occursin("<Code>BadDigest</Code>", r.text)
            # a signed header omitted or altered: the signature fails
            for name in ("if-none-match", "x-amz-checksum-sha256", "x-amz-tagging", "x-amz-object-lock-retain-until-date",
                         "x-amz-server-side-encryption-aws-kms-key-id")
                r = raw_put(reply.url, without(reply.headers, name), body)
                @test (name, r.status, occursin("<Code>SignatureDoesNotMatch</Code>", r.text)) == (name, 403, true)
            end
            later = "2099-01-01T00:00:00Z"
            r = raw_put(reply.url, replacing(reply.headers, "x-amz-object-lock-retain-until-date", later), body)
            @test r.status == 403 && occursin("<Code>SignatureDoesNotMatch</Code>", r.text)
            r = raw_put(reply.url, replacing(reply.headers, "content-length", string(length(body) - 1)), body[1:end-1])
            @test r.status == 403 && occursin("<Code>SignatureDoesNotMatch</Code>", r.text)
            # an x-amz-* header the URL does not sign
            r = raw_put(reply.url, [reply.headers; "x-amz-meta-note" => "unsigned"], body)
            @test r.status == 403 && occursin("<Code>AccessDenied</Code>", r.text)
            @test stat_object(store, key) === nothing
            # the right body: stored, locked, encrypted under the signed key, checksummed, tagged
            @test GWT.upload_minted(store, key, IOBuffer(body), Int64(length(body)), reply) === true
            head = live_head(store, key)
            @test parse(Int, head["content-length"]) == length(body)
            @test head["x-amz-object-lock-mode"] == "COMPLIANCE"
            @test iso_second(head["x-amz-object-lock-retain-until-date"]) == iso_second(signed(reply.headers, "x-amz-object-lock-retain-until-date"))
            @test head["x-amz-server-side-encryption"] == "aws:kms"
            @test head["x-amz-server-side-encryption-aws-kms-key-id"] == signed(reply.headers, "x-amz-server-side-encryption-aws-kms-key-id")
            @test head["x-amz-server-side-encryption-bucket-key-enabled"] == "true"
            @test head["x-amz-checksum-sha256"] == GWT.checksum_sha256(h)
            tagging = GWT.s3_request(store.s3, "GET", key; query = ["tagging" => ""])
            @test tagging.status == 200 &&
                  occursin(r"<Tag><Key>chaintables</Key><Value>attachment</Value></Tag>", String(tagging.body))
            @test signed(reply.headers, "x-amz-tagging") == "chaintables=attachment"
            # the same URL again: If-None-Match refuses it, and there is still one version
            @test GWT.upload_minted(store, key, IOBuffer(body), Int64(length(body)), reply) === false
            r = raw_put(reply.url, reply.headers, body)
            @test r.status == 412
            versions = GWT.s3_request(store.s3, "GET", ""; query = ["prefix" => key, "versions" => ""])
            @test versions.status == 200 && length(collect(eachmatch(r"<Version>", String(versions.body)))) == 1
            # a mint of the present key mints no URL and moves its retain-until later (dates
            # are whole seconds: wait for the next one)
            before = retain_until(store, key)
            sleep(2)
            again = GWT.mint(store, key, Int64(length(body)))
            @test again.code == "present" && again.url === nothing
            @test retain_until(store, key) > before
            @test live_head(store, key)["x-amz-object-lock-mode"] == "COMPLIANCE"
        end

        @testset "put_attachment, touch_attachment and attachment" begin
            GWT.create_chain(chain)
            # over the function URL's 6 MB: the bytes cannot have gone through the gateway
            bytes = rand(UInt8, 7 * 1024 * 1024)
            file = joinpath(dir, "upload.bin")
            write(file, bytes)
            h = put_attachment(chain, file)
            @test h == bytes2hex(GWT.sha256(bytes))
            key = GWT.attachment_key(chain, h)
            @test stat_object(store, key).size == length(bytes)
            @test live_head(store, key)["x-amz-object-lock-mode"] == "COMPLIANCE"
            # putting it again finds it present and uploads nothing
            @test Base.open(io -> put_attachment(chain, io), file) == h
            # touch moves its retain-until later
            before = retain_until(store, key)
            sleep(2)
            @test touch_attachment(chain, h) === nothing
            @test retain_until(store, key) > before
            absent = random_hash()
            @test_throws AttachmentAbsentError touch_attachment(chain, absent)
            # a reader's copy: a miss fetches it, a hit is the same file with no request
            a = GWT.open(chain, joinpath(dir, "a"))
            @test GWT.sync!(a).slot == 0
            path = attachment(a, h)
            @test read(path) == bytes && (filemode(path) & 0o222) == 0
            @test attachment(a, h) == path
            @test isfile(joinpath(a.path, "confirmed", h))
            @test GWT.verify(a; full = true) === nothing
            @test_throws AttachmentAbsentError attachment(a, absent)
            # a second copy on the same cache: a hit, confirmed by one HEAD in the chain's store
            b = GWT.open(chain, joinpath(dir, "b"))
            GWT.sync!(b)
            @test !isfile(joinpath(b.path, "confirmed", h))
            @test attachment(b, h) == path && isfile(joinpath(b.path, "confirmed", h))
            close(a); close(b)
        end
    end
end
