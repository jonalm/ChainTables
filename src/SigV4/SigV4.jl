"""
AWS Signature Version 4, which S3, a Lambda function URL and STS check on every request.
"""
module SigV4

using SHA: hmac_sha256, sha256

public amz_date, canonical_query, sign_request, uri_encode

include("signature.jl")

end
