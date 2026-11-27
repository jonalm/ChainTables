using Test
using ChainTables: Chain, sso_credentials

@testset "sso_credentials example" begin
    # After `aws sso login --profile lab`, a chain signs with the profile's session.
    # Here a Fake stands in for the AWS CLI.
    exported = "AWS_ACCESS_KEY_ID=AKIAEXAMPLE\nAWS_SECRET_ACCESS_KEY=secret\n" *
        "AWS_SESSION_TOKEN=token\nAWS_CREDENTIAL_EXPIRATION=2099-01-01T00:00:00Z\n"
    credentials = sso_credentials("lab"; exporter = profile -> exported)
    chain = Chain("lab-bucket", "experiments/run-7"; region = "eu-north-1", credentials)

    # Each call returns the credentials, and runs the CLI again only near their end.
    @test credentials().access_key_id == "AKIAEXAMPLE"
    @test chain.bucket == "lab-bucket"
end
