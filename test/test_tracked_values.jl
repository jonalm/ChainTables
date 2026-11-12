using Test

# A tripwire against deployment values coming back into the repository (ADR-0030): the
# tracked tree (`git ls-files`) is scanned for an account id, a function URL's host id, an
# Identity Center start URL and an e-mail address that are not the documented
# placeholders. It knows a few shapes; a bucket or profile name has none.

const TRACKED_FAKE_ACCOUNTS = ("123456789012", "111122223333", "444455556666")  # AWS's docs
# gateway/build.sh: the zip's fixed mtime
const TRACKED_NOT_ACCOUNTS = ("200001010000",)
const TRACKED_SKIPPED =
    r"^(docs/research/|test/test_tracked_values\.jl$)|(^|/)(Manifest\.toml|[^/]*\.lock)$"

# A slot key's twelve digits start with zeros.
function is_placeholder_account(path, line, m)
    return m.match in TRACKED_FAKE_ACCOUNTS || m.match in TRACKED_NOT_ACCOUNTS ||
        startswith(m.match, "0000")
end

function is_placeholder_host(path, line, m)
    return m.captures[1] == "<id>" || startswith(m.captures[1], "abc")
end

is_placeholder_start_url(path, line, m) = false

# The package's public author line is the one real address.
function is_placeholder_email(path, line, m)
    return endswith(m.match, "@example.com") ||
        (path == "Project.toml" && startswith(line, "authors"))
end

const TRACKED_CHECKS = [
    (
        what = "a 12-digit number shaped like an AWS account id",
        pattern = r"(?<![0-9A-Za-z])[0-9]{12}(?![0-9A-Za-z])",
        is_placeholder = is_placeholder_account,
    ),
    (
        what = "a function URL with a real-looking host id",
        pattern = r"([A-Za-z0-9<>-]+)\.lambda-url\.",
        is_placeholder = is_placeholder_host,
    ),
    (
        what = "an Identity Center start URL",
        pattern = r"awsapps\.com/start",
        is_placeholder = is_placeholder_start_url,
    ),
    (
        what = "an e-mail address not at example.com",
        pattern = r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}",
        is_placeholder = is_placeholder_email,
    ),
]

function line_hits(path, n, line)
    return [
        "$path:$n: $(check.what): $(m.match)"
            for check in TRACKED_CHECKS for m in eachmatch(check.pattern, line)
            if !check.is_placeholder(path, line, m)
    ]
end

function file_hits(root, path)
    occursin(TRACKED_SKIPPED, path) && return String[]
    full = joinpath(root, path)
    isfile(full) || return String[]                    # deleted in the working tree
    text = read(full, String)
    isvalid(text) && !occursin('\0', text) || return String[]     # binary
    lines = collect(eachline(IOBuffer(text)))
    hits = [line_hits(path, n, line) for (n, line) in enumerate(lines)]
    return reduce(vcat, hits; init = String[])
end

const LINE_CASES = [
    (name = "a real account id", line = "arn:aws:iam::" * "4"^12 * ":role/x", hit = true),
    (name = "a 12-digit bucket suffix", line = "bucket-" * "9"^12, hit = true),
    (
        name = "AWS's example account",
        line = "arn:aws:iam::123456789012:role/x",
        hit = false,
    ),
    (name = "a slot key", line = "chain/000000000042", hit = false),
    (name = "a longer hex run", line = "0123456789abcdef0123", hit = false),
    (
        name = "a real host id",
        line = "https://" * "q7"^16 * ".lambda-url.eu-north-1.on.aws",
        hit = true,
    ),
    (
        name = "the host placeholder",
        line = "https://<id>.lambda-url.<region>.on.aws",
        hit = false,
    ),
    (
        name = "an abc host",
        line = "https://abc123.lambda-url.eu-north-1.on.aws",
        hit = false,
    ),
    (name = "a wildcard host", line = "*.lambda-url.<region>.on.aws", hit = false),
    (
        name = "a start URL",
        line = "https://d-0000000000." * "awsapps.com/start",
        hit = true,
    ),
    (name = "a real address", line = "bob@" * "corp.example.org", hit = true),
    (name = "an example.com address", line = "alice@example.com", hit = false),
    (name = "a version pin", line = "SQLite@1.8.2", hit = false),
]

@testset "the tripwire's checks on $(case.name)" for case in LINE_CASES
    @test !isempty(line_hits("x.md", 1, case.line)) == case.hit
end

@testset "no deployment value in the tracked tree" begin
    root = dirname(@__DIR__)
    @test isdir(joinpath(root, ".git"))              # the tripwire needs a git checkout
    files = readlines(`git -C $root ls-files`)
    @test !isempty(files)
    hits = reduce(vcat, [file_hits(root, path) for path in files]; init = String[])
    @test hits == String[]
end
