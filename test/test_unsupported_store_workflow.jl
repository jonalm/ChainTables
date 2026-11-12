# ADR-0016's gate end to end: a store that is not AWS syncs and reads, and refuses
# `commit!` and `create_chain` before anything is applied or written, unless the chain
# assumes the guarantee.
using Test
using ChainTables: ChainTables, Chain, Credentials, UnsupportedStoreError, column!,
    commit!, create_chain, create_table!, head, insert_rows!, open, primary_key!, sync!,
    table, tables, write_builder

include("fixtures/s3_server.jl")

const PLAIN = Credentials("AKIATEST", "topsecret")

function loopback_chain(server, cache_dir; kw...)
    return Chain(
        "bkt", "exp/run-1"; region = "eu-north-1", credentials = PLAIN,
        endpoint = s3test_endpoint(server), path_style = true, cache_dir, kw...
    )
end

function samples_builder(copy, rows)
    w = write_builder(copy)
    create_table!(w, :samples) do t
        column!(t, :id, Int64)
        column!(t, :mass, Float64)
        primary_key!(t, :id)
    end
    insert_rows!(w, :samples, rows)
    return w
end

@testset "create_chain refuses a store that is not AWS, writing nothing" begin
    with_s3_server(; bucket = "bkt", credentials = PLAIN) do server
        mktempdir() do dir
            unsure = loopback_chain(server, dir)
            endpoint = s3test_endpoint(server)
            says = "the store is not AWS S3"
            e = (@test_throws UnsupportedStoreError says create_chain(unsure)).value
            @test (e.endpoint, e.call) == (endpoint, "create_chain(chain)")
            @test occursin("If-None-Match: *", sprint(showerror, e))
            @test occursin("assume_first_writer_wins = true", sprint(showerror, e))
            @test isempty(server.requests) && isempty(server.objects)
        end
    end
end

@testset "commit! refuses a store that is not AWS before anything is applied" begin
    with_s3_server(; bucket = "bkt", credentials = PLAIN) do server
        mktempdir() do dir
            cache_dir = joinpath(dir, "cache")
            create_chain(loopback_chain(server, cache_dir; assume_first_writer_wins = true))
            copy = open(loopback_chain(server, cache_dir), joinpath(dir, "a"))
            @test sync!(copy).slot == 0
            w = samples_builder(copy, [(id = 1, mass = 1.5)])
            n = length(server.requests)
            says = "the store is not AWS S3"
            e = (@test_throws UnsupportedStoreError says commit!(w)).value
            @test e.call == "commit!(w)"
            @test length(server.requests) == n
            @test head(copy).slot == 0 && isempty(tables(copy))
            @test_throws ChainTables.WriteBuilderError "this builder is spent" commit!(w)
            close(copy)
        end
    end
end

@testset "a chain that assumes the guarantee commits, and an unsure one reads it" begin
    with_s3_server(; bucket = "bkt", credentials = PLAIN) do server
        mktempdir() do dir
            cache_dir = joinpath(dir, "cache")
            promised = loopback_chain(server, cache_dir; assume_first_writer_wins = true)
            create_chain(promised)
            writer = open(promised, joinpath(dir, "b"))
            sync!(writer)
            rows = [(id = 1, mass = 1.5), (id = 2, mass = 2.5)]
            done = commit!(samples_builder(writer, rows))
            @test done.slot == 1
            put = last(filter(r -> r.method == "PUT", server.requests))
            @test put.rawpath == "/bkt/exp/run-1/000000000001"
            @test put.headers["if-none-match"] == "*"
            reader = open(loopback_chain(server, cache_dir), joinpath(dir, "a"))
            @test sync!(reader).slot == 1
            @test table(reader, :samples)[2].mass == 2.5
            w = write_builder(reader)
            insert_rows!(w, :samples, [(id = 3, mass = 3.5)])
            @test_throws UnsupportedStoreError "the store is not AWS S3" commit!(w)
            close(reader)
            close(writer)
        end
    end
end

@testset "open of a store that is not AWS does not warn" begin
    with_s3_server(; bucket = "bkt", credentials = PLAIN) do server
        mktempdir() do dir
            unsure = loopback_chain(server, joinpath(dir, "cache"))
            cache_dir = joinpath(dir, "cache")
            create_chain(loopback_chain(server, cache_dir; assume_first_writer_wins = true))
            copy = @test_logs open(unsure, joinpath(dir, "a"))
            close(copy)
        end
    end
end

@testset "an AWS endpoint spelled out passes the gate" begin
    aws = Chain(
        "bkt", "exp/run-1"; region = "eu-north-1", credentials = PLAIN,
        endpoint = "https://s3.eu-north-1.amazonaws.com", cache_dir = "/c"
    )
    @test ChainTables.refuse_unsupported_store(aws, "commit!(w)") === nothing
end
