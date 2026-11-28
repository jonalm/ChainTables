# `assumed-role/<role>/<session>` or `user/[path/]<name>`. The gateway refuses any other
# principal (the account root, a bare role, a service) as not_allowed, so it is refused
# here without the round trip. `\z`, not `$`, which would also match before a final
# newline; names hold no whitespace.
const PRINCIPAL_ARN = Regex(
    "\\Aarn:[^:\\s]+:(?:iam|sts)::[0-9]{12}:(?:" *
        "assumed-role/[^/\\s]+/(?<session>[^/\\s]+)|" *
        "user/(?:[^/\\s]+/)*(?<user>[^/\\s]+))\\z"
)

const GET_CALLER_IDENTITY = "Action=GetCallerIdentity&Version=2011-06-15"

const FORM_CONTENT_TYPE = "application/x-www-form-urlencoded; charset=utf-8"

# The gateway applies the same rule to the request context (ADR-0028). The author is
# memoized per access key id, so that credentials of another identity fetch it again.
# The environment is never read.
function record_author(store::GatewayObjectStore)
    credentials = current_credentials(store.s3)
    memo = store.author_memo
    memo !== nothing && memo.access_key_id == credentials.access_key_id &&
        return memo.author
    author = fetch_caller_author(store, credentials)
    store.author_memo = (; credentials.access_key_id, author)
    return author
end

function fetch_caller_author(store::GatewayObjectStore, credentials::Credentials)
    url = store.sts_endpoint * "/"
    host = last(split(store.sts_endpoint, "://"; limit = 2))
    body = Vector{UInt8}(GET_CALLER_IDENTITY)
    headers = signed_headers(
        credentials; store.s3.region, service = "sts", host,
        method = "POST", path = "/", body, headers = ["content-type" => FORM_CONTENT_TYPE],
    )
    response = http_request("POST", url; headers, body, store.s3.timeout)
    response.status == 200 || throw(TransportError("POST", url, response))
    arn = try_parse_caller_arn(response.body)
    arn === nothing && throw(
        TransportError(;
            method = "POST", url, status = 200,
            detail = "the sts:GetCallerIdentity response has no Arn",
        )
    )
    return author_from_arn(arn, store.function_url)
end

function try_parse_caller_arn(body::Vector{UInt8})
    m = match(r"<Arn>([^<]*)</Arn>", String(copy(body)))
    return m === nothing ? nothing : xml_unescape(m[1])
end

# For an Identity Center session the session name is the user's name.
function author_from_arn(arn::AbstractString, gateway::String)
    m = match(PRINCIPAL_ARN, arn)
    m === nothing && throw(
        WriteRefusedError(;
            gateway, reason = "not_allowed",
            detail = "the caller $arn is neither an IAM user nor an assumed role",
        )
    )
    return String(something(m[:session], m[:user]))
end
