# The author on a gateway store (ADR-0028): the rule the gateway applies to the request
# context, applied here to `sts:GetCallerIdentity`, so a record names its caller.

# `assumed-role/<role>/<session>` or `user/[path/]<name>`; anything else (the account root,
# a bare role, a service principal) the gateway refuses as not_allowed, so it is refused
# here without the round trip. `\z`, not `$`, which also matches before a final newline.
const PRINCIPAL_ARN = Regex(
    "\\Aarn:[^:\\s]+:(?:iam|sts)::[0-9]{12}:(?:assumed-role/[^/\\s]+/(?<session>[^/\\s]+)" *
        "|user/(?:[^/\\s]+/)*(?<user>[^/\\s]+))\\z"
)

const GET_CALLER_IDENTITY = "Action=GetCallerIdentity&Version=2011-06-15"

const FORM_CONTENT_TYPE = "application/x-www-form-urlencoded; charset=utf-8"

# Memoized per access key id: a second call under the same key makes no request, and
# credentials for another key fetch again. The environment is never consulted.
function record_author(store::GatewayObjectStore)
    credentials = current_credentials(store.s3)
    is_memoized(store, credentials) && return store.author::String
    author = fetch_caller_author(store, credentials)
    store.author_key = credentials.access_key_id
    store.author = author
    return author
end

function is_memoized(store::GatewayObjectStore, credentials::Credentials)
    return store.author !== nothing && store.author_key == credentials.access_key_id
end

"""
    fetch_caller_author(store, credentials)

Return the author `sts:GetCallerIdentity` names for `credentials`, signed for service
`sts` at `store.sts_endpoint`. Throws `WriteRefusedError` for a principal the gateway
refuses, and `TransportError` when STS fails.
"""
function fetch_caller_author(store::GatewayObjectStore, credentials::Credentials)
    body = Vector{UInt8}(GET_CALLER_IDENTITY)
    host = split(store.sts_endpoint, "://"; limit = 2)[2]
    headers = signed_headers(
        credentials, store.s3.region, "sts", host, "POST", "/";
        body, headers = ["content-type" => FORM_CONTENT_TYPE]
    )
    url = store.sts_endpoint * "/"
    response = http_request(url, "POST", headers, body, store.timeout)
    response.status == 200 || failure("POST", url, response)
    return author_from_sts_response(response.body)
end

function author_from_sts_response(body)
    text = String(copy(body))
    m = match(r"<Arn>([^<]*)</Arn>", text)
    m === nothing && throw(TransportError(no_arn_detail(text); status = 200))
    return author_from_arn(xml_unescape(m.captures[1]))
end

no_arn_detail(text) = "sts:GetCallerIdentity returned no Arn: $(first(text, 200))"

"""
    author_from_arn(arn)

Return the author a caller ARN names: the text after its last `/`, for an IAM user
(`user/[path/]<name>`) or an assumed role (`assumed-role/<role>/<session>`); for an
Identity Center session the session name is the user name. Throws `WriteRefusedError`
with `reason = "not_allowed"` for any other principal, the gateway's own verdict on it.
"""
function author_from_arn(arn::AbstractString)
    m = match(PRINCIPAL_ARN, arn)
    m === nothing &&
        throw(WriteRefusedError(; reason = "not_allowed", detail = arn_detail(arn)))
    return String(something(m[:session], m[:user]))
end

arn_detail(arn) = "the caller $arn is neither an IAM user nor an assumed role"
