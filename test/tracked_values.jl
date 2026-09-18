# ADR-0030 — a tripwire against deployment values coming back into the repository: the
# tracked tree (`git ls-files`) is scanned for an account id, a function URL's host id, an
# Identity Center start URL and an e-mail address that are not the documented placeholders.
# It is a tripwire, not a proof: it knows a few shapes, and a bucket or profile name has
# none. Outside a git checkout (a registry install) there is no tracked tree and nothing
# is checked.

const TRACKED_FAKE_ACCOUNTS = ("123456789012", "111122223333")     # the ones AWS's own docs use
const TRACKED_NOT_ACCOUNTS = ("200001010000",)                     # gateway/build.sh: the zip's fixed mtime
const TRACKED_SKIPPED = r"^(docs/research/|test/tracked_values\.jl$)|(^|/)(Manifest\.toml|[^/]*\.lock)$"

# (what, pattern, is this match a placeholder?)
const TRACKED_CHECKS = (
    ("a 12-digit number shaped like an AWS account id", r"(?<![0-9A-Za-z])[0-9]{12}(?![0-9A-Za-z])",
     (path, line, m) -> m.match in TRACKED_FAKE_ACCOUNTS || m.match in TRACKED_NOT_ACCOUNTS ||
                        startswith(m.match, "0000")),                                   # a slot key
    ("a function URL with a real-looking host id", r"([A-Za-z0-9<>-]+)\.lambda-url\.",
     (path, line, m) -> m.captures[1] == "<id>" || startswith(m.captures[1], "abc")),
    ("an Identity Center start URL", r"awsapps\.com/start", (path, line, m) -> false),
    ("an e-mail address not at example.com", r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}",
     (path, line, m) -> endswith(m.match, "@example.com") ||
                        (path == "Project.toml" && startswith(line, "authors"))),     # the package's public author line
)

function tracked_files(root)
    ispath(joinpath(root, ".git")) || return nothing
    Sys.which("git") === nothing && return nothing
    return readlines(`git -C $root ls-files`)
end

function tracked_value_hits(root, files)
    hits = String[]
    for path in files
        occursin(TRACKED_SKIPPED, path) && continue
        full = joinpath(root, path)
        isfile(full) || continue                        # deleted in the working tree
        text = read(full, String)
        isvalid(text) && !occursin('\0', text) || continue      # binary
        for (n, line) in enumerate(eachline(IOBuffer(text))), (what, pattern, placeholder) in TRACKED_CHECKS
            for m in eachmatch(pattern, line)
                placeholder(path, line, m) || push!(hits, "$path:$n: $what: $(m.match)")
            end
        end
    end
    return hits
end

@testset "tracked values: no deployment value in the tracked tree (ADR-0030)" begin
    # the checks themselves, on made-up lines
    hit(line) = any(((what, pattern, placeholder),) -> any(m -> !placeholder("x.md", line, m), eachmatch(pattern, line)), TRACKED_CHECKS)
    @test hit("arn:aws:iam::" * "4" ^ 12 * ":role/x") && hit("bucket-" * "9" ^ 12)
    @test !hit("arn:aws:iam::123456789012:role/x") && !hit("chain/000000000042") && !hit("0123456789abcdef0123")
    @test hit("https://" * "q7" ^ 16 * ".lambda-url.eu-north-1.on.aws")
    @test !hit("https://<id>.lambda-url.<region>.on.aws") && !hit("https://abc123.lambda-url.eu-north-1.on.aws") && !hit("*.lambda-url.<region>.on.aws")
    @test hit("https://d-0000000000." * "awsapps.com/start")
    @test hit("bob@" * "corp.example.org") && !hit("alice@example.com") && !hit("SQLite@1.8.2")

    root = dirname(@__DIR__)
    files = tracked_files(root)
    if files === nothing
        @info "tracked values: not a git checkout, nothing to scan" root
    else
        @test !isempty(files)
        hits = tracked_value_hits(root, files)
        isempty(hits) || @error "deployment values in tracked files — replace them with placeholders (ADR-0030):\n" * join(hits, "\n")
        @test isempty(hits)
    end
end
