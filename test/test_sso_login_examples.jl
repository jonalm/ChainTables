using Test
using ChainTables: sso_login

@testset "sso_login example" begin
    # `sso_login("lab")` runs `aws sso login --profile lab`, which opens a browser and
    # waits. Here a Fake runner stands in for the AWS CLI.
    ran = Cmd[]
    sso_login("lab"; runner = command -> push!(ran, command))
    @test only(ran).exec == ["aws", "sso", "login", "--profile", "lab"]
end
