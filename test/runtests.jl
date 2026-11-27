using Test
import ChainTables

# ---------------------------------------------------------------------------
# One test file per src file, in the build order of #34 §3. The suite is offline: it
# runs against the doubles and loopback servers with no credentials, reads no
# CHAINTABLES_LIVE_* variable, and makes no request to anything but 127.0.0.1, whatever
# is exported in the shell. The tests only AWS can answer are a separate command,
# test/live/run.sh (ADR-0030), and are never part of `Pkg.test()`.
#
# The suite resolves against the package's own environment. Its dependencies of
# its own are test-target extras: Tables.jl, because test/test_table_view.jl proves a
# TableView is a Tables.jl table and nothing in the package itself depends on
# Tables.jl (ADR-0022, ADR-0024); and Aqua.jl, for test/aqua.jl's hygiene checks.
# ---------------------------------------------------------------------------

# A test file in the Guide's shape includes its own fixtures and runs alone. Here each one
# runs in a module of its own, as it will under the Guide's runner, so that two files
# may include one fixture or give two consts one name.
function in_own_module(file)
    return @eval module $(gensym(file))
    include($(joinpath(@__DIR__, file)))
    end
end

@testset "ChainTables" begin
    @testset "package loads" begin
        @test ChainTables isa Module
    end

    include("fixtures/s3_server.jl")     # the loopback S3: gateway.jl, attachments.jl
    include("fixtures/gateway.jl")       # gwtest_record: gateway.jl, live/gateway.jl

    in_own_module("test_hashes.jl")
    in_own_module("test_hashes_examples.jl")
    in_own_module("test_errors.jl")
    in_own_module("test_commit_errors.jl")
    in_own_module("test_chain_errors.jl")
    in_own_module("test_local_copy_errors.jl")
    in_own_module("test_gateway_errors.jl")
    in_own_module("test_attachment_errors.jl")
    in_own_module("test_cbor_encode.jl")
    in_own_module("test_cbor_encode_examples.jl")
    in_own_module("test_cbor_decode.jl")
    in_own_module("test_cbor_decode_examples.jl")
    in_own_module("test_model_shape.jl")
    in_own_module("test_model_shape_examples.jl")
    in_own_module("test_model_row_checks.jl")
    in_own_module("test_model_table.jl")
    in_own_module("test_model_table_examples.jl")
    in_own_module("test_model_content.jl")
    in_own_module("test_model_table_file.jl")
    in_own_module("test_model_table_file_examples.jl")
    in_own_module("test_model_fingerprint.jl")
    in_own_module("test_model_fingerprint_examples.jl")
    in_own_module("test_ops_op.jl")
    in_own_module("test_ops_op_examples.jl")
    in_own_module("test_ops_record.jl")
    in_own_module("test_ops_record_examples.jl")
    in_own_module("test_ops_record_bytes.jl")
    in_own_module("test_ops_record_bytes_examples.jl")
    in_own_module("test_ops_apply.jl")
    in_own_module("test_ops_apply_examples.jl")
    in_own_module("test_chain_id_text.jl")
    in_own_module("test_chain_id_text_examples.jl")
    in_own_module("test_local_copy.jl")
    in_own_module("test_local_copy_examples.jl")
    in_own_module("test_open_heads_workflow.jl")
    in_own_module("test_table_files.jl")
    in_own_module("test_table_view.jl")
    in_own_module("test_table_view_examples.jl")
    in_own_module("test_views.jl")
    in_own_module("test_views_examples.jl")
    in_own_module("test_write_builder.jl")
    in_own_module("test_write_builder_examples.jl")
    in_own_module("test_row_ops.jl")
    in_own_module("test_row_ops_examples.jl")
    in_own_module("test_object_store.jl")
    in_own_module("test_object_store_examples.jl")
    in_own_module("test_chain.jl")
    in_own_module("test_chain_examples.jl")
    in_own_module("test_create_chain.jl")
    in_own_module("test_create_chain_examples.jl")
    in_own_module("test_sync.jl")
    in_own_module("test_sync_examples.jl")
    in_own_module("test_commit.jl")
    in_own_module("test_commit_examples.jl")
    in_own_module("test_commit_outcomes_workflow.jl")
    in_own_module("test_record_cache_workflow.jl")
    in_own_module("test_read_forward_workflow.jl")
    in_own_module("test_head_discovery_workflow.jl")
    in_own_module("test_verify.jl")
    in_own_module("test_verify_examples.jl")
    in_own_module("test_repair.jl")
    in_own_module("test_repair_examples.jl")
    in_own_module("test_as_of.jl")
    in_own_module("test_as_of_examples.jl")
    in_own_module("test_slot_at.jl")
    in_own_module("test_slot_at_examples.jl")
    in_own_module("test_commit_log.jl")
    in_own_module("test_commit_log_examples.jl")
    in_own_module("test_transport_errors.jl")
    in_own_module("test_credential_errors.jl")
    in_own_module("test_sigv4_signature.jl")
    in_own_module("test_sigv4_signature_examples.jl")
    in_own_module("test_credentials.jl")
    in_own_module("test_credentials_examples.jl")
    in_own_module("test_sso_credentials.jl")
    in_own_module("test_sso_credentials_examples.jl")
    in_own_module("test_sso_login.jl")
    in_own_module("test_sso_login_examples.jl")
    in_own_module("test_s3_store_workflow.jl")
    in_own_module("test_s3_streaming_workflow.jl")
    include("gateway.jl")
    include("bucket.jl")
    include("attachments.jl")    # after gateway.jl: it uses the gateway double
    include("Testing.jl")
    include("readme.jl")
    in_own_module("test_commit_faults_workflow.jl")   # commit! against a reference model
    include("tracked_values.jl")
    include("live_calls.jl")      # the live suite still calls what exists
    include("aqua.jl")
end
