# A tripwire against deployment values coming back into the repository (ADR-0030): the
# tracked tree (`git ls-files`) is scanned for an account id, a function URL's host id,
# an Identity Center start URL and an e-mail address that are not the documented
# placeholders. It knows a few shapes, and a bucket or profile name has none. Outside a
# git checkout (an installed copy) there is no tracked tree, and nothing is scanned.
using Test

const ROOT = dirname(@__DIR__)

# The ones AWS's own docs use, and gateway/build.sh's fixed mtime of the zip.
const PLACEHOLDER_ACCOUNTS = ("123456789012", "111122223333", "444455556666")
const NOT_ACCOUNTS = ("200001010000",)
const SKIPPED = Regex(
    raw"^(docs/research/|test/test_tracked_values\.jl$)" *
        raw"|(^|/)(Manifest\.toml|[^/]*\.lock)$",
)

const ACCOUNT = r"(?<![0-9A-Za-z])[0-9]{12}(?![0-9A-Za-z])"
const FUNCTION_URL = r"([A-Za-z0-9<>-]+)\.lambda-url\."
const START_URL = r"awsapps\.com/start"
const EMAIL = r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}"

# A slot key is 12 digits too, and starts with zeros.
function is_placeholder_account(path, line, m)
    return m.match in PLACEHOLDER_ACCOUNTS || m.match in NOT_ACCOUNTS ||
        startswith(m.match, "0000")
end

function is_placeholder_function_url(path, line, m)
    return m.captures[1] == "<id>" || startswith(m.captures[1], "abc")
end

is_placeholder_start_url(path, line, m) = false

# The package's public author line is the one address allowed.
function is_placeholder_email(path, line, m)
    return endswith(m.match, "@example.com") ||
        (path == "Project.toml" && startswith(line, "authors"))
end

const CHECKS = (
    (
        what = "a 12-digit number shaped like an AWS account id", pattern = ACCOUNT,
        is_placeholder = is_placeholder_account,
    ),
    (
        what = "a function URL with a real-looking host id", pattern = FUNCTION_URL,
        is_placeholder = is_placeholder_function_url,
    ),
    (
        what = "an Identity Center start URL", pattern = START_URL,
        is_placeholder = is_placeholder_start_url,
    ),
    (
        what = "an e-mail address not at example.com", pattern = EMAIL,
        is_placeholder = is_placeholder_email,
    ),
)

const FLAGGED_LINES = [
    (name = "an account id in an ARN", line = "arn:aws:iam::" * "4"^12 * ":role/x"),
    (name = "an account id in a bucket name", line = "bucket-" * "9"^12),
    (
        name = "a function URL",
        line = "https://" * "q7"^16 * ".lambda-url.eu-north-1.on.aws",
    ),
    (name = "a start URL", line = "https://d-0000000000." * "awsapps.com/start"),
    (name = "an address", line = "bob@" * "corp.example.org"),
]

const PASSED_LINES = [
    (name = "AWS's placeholder account", line = "arn:aws:iam::123456789012:role/x"),
    (name = "a slot key", line = "chain/000000000042"),
    (name = "20 hex digits", line = "0123456789abcdef0123"),
    (name = "the placeholder host id", line = "https://<id>.lambda-url.<region>.on.aws"),
    (name = "an abc host id", line = "https://abc123.lambda-url.eu-north-1.on.aws"),
    (name = "a wildcard host", line = "*.lambda-url.<region>.on.aws"),
    (name = "an address at example.com", line = "alice@example.com"),
    (name = "a package version", line = "SQLite@1.8.2"),
]

function tracked_files(root)
    ispath(joinpath(root, ".git")) || return nothing
    Sys.which("git") === nothing && return nothing
    return readlines(`git -C $root ls-files`)
end

function line_hits(path, n, line)
    hits = String[]
    for check in CHECKS, m in eachmatch(check.pattern, line)
        check.is_placeholder(path, line, m) && continue
        push!(hits, "$path:$n: $(check.what): $(m.match)")
    end
    return hits
end

is_scanned(root, path) = !occursin(SKIPPED, path) && isfile(joinpath(root, path))
is_text(text) = isvalid(text) && !occursin('\0', text)

function file_hits(root, path)
    text = read(joinpath(root, path), String)
    is_text(text) || return String[]
    lines = enumerate(eachline(IOBuffer(text)))
    return reduce(vcat, [line_hits(path, n, line) for (n, line) in lines]; init = String[])
end

function tracked_value_hits(root, files)
    scanned = filter(path -> is_scanned(root, path), files)
    return reduce(vcat, [file_hits(root, path) for path in scanned]; init = String[])
end

@testset "line_hits flags a deployment value: $(case.name)" for case in FLAGGED_LINES
    @test !isempty(line_hits("x.md", 1, case.line))
end

@testset "line_hits passes a placeholder: $(case.name)" for case in PASSED_LINES
    @test isempty(line_hits("x.md", 1, case.line))
end

@testset "line_hits passes the author line of Project.toml" begin
    line = "authors = [\"A <a@" * "corp.example.org>\"]"
    @test isempty(line_hits("Project.toml", 4, line))
end

@testset "tracked_value_hits finds nothing in the tracked tree" begin
    files = tracked_files(ROOT)
    hits = files === nothing ? String[] : tracked_value_hits(ROOT, files)
    @test hits == String[]
end
