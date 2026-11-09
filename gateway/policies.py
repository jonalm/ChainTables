"""The gateway's own IAM documents, generated in one place (#92): the execution role's
`chaintables-gateway-put` inline policy and the bucket-policy statements `deploy.sh` owns.
`deploy.sh` writes them and `setup-locked-bucket.sh` prints and verifies them, both through
this module, so the two cannot drift apart. Standard library only: the scripts run it with
the system `python3`.

    python3 policies.py gateway-put <bucket ARN>
    python3 policies.py deploy-statements <bucket ARN> <role ARN> <JSON array of reader ARNs>
    python3 policies.py attachments <bucket ARN>
"""

import json
import sys

# A presigned attachment PUT is authorized as s3:PutObject, plus s3:PutObjectTagging for its
# signed tag and, on a locked bucket, s3:PutObjectRetention for its lock headers (AWS,
# "Required permissions for Amazon S3 API operations", PutObject). A deny on presigned
# requests must leave all three to the attachment keys, or every minted upload is 403.
PRESIGNED_PUT_ACTIONS = ["s3:PutObject", "s3:PutObjectRetention", "s3:PutObjectTagging"]

# Anything but a header-signed request: a presigned URL (REST-QUERY-STRING) or a browser-form
# POST (POST). A SigV2 header-signed request is REST-HEADER too.
NOT_HEADER_AUTH = {"StringNotEquals": {"s3:authType": "REST-HEADER"}}


def attachments(bucket_arn: str) -> list[str]:
    """The attachment keys, `<prefix>/_attachments/<h>` and `_attachments/<h>` at the root, as
    IAM resource patterns: '?' is one character, so <h> is 64 of them and a slot never ends one
    (ADR-0046)."""
    h = "?" * 64
    return [f"{bucket_arn}/_attachments/{h}", f"{bucket_arn}/*/_attachments/{h}"]


def gateway_put(bucket_arn: str) -> dict:
    """The execution role's `chaintables-gateway-put` inline policy."""
    att = attachments(bucket_arn)
    return {"Version": "2012-10-17", "Statement": [
        {"Sid": "PutSlots", "Effect": "Allow", "Action": "s3:PutObject", "Resource": f"{bucket_arn}/*"},
        {"Sid": "HeadAttachments", "Effect": "Allow", "Action": "s3:GetObject", "Resource": att},
        {"Sid": "ListBucket", "Effect": "Allow", "Action": "s3:ListBucket", "Resource": bucket_arn},
        {"Sid": "TagAttachments", "Effect": "Allow", "Action": "s3:PutObjectTagging", "Resource": att}]}


def deploy_statements(bucket_arn: str, role_arn: str, principals: list[str]) -> list[dict]:
    """The bucket-policy statements `deploy.sh` owns, `Read<n>` numbering `principals`."""
    objects = f"{bucket_arn}/*"
    st = [
        {"Sid": "GatewayPuts", "Effect": "Allow", "Principal": {"AWS": role_arn},
         "Action": "s3:PutObject", "Resource": objects},
        {"Sid": "OnlyTheGatewayPuts", "Effect": "Deny", "Principal": "*",
         "Action": "s3:PutObject", "Resource": objects,
         "Condition": {"ArnNotEquals": {"aws:PrincipalArn": role_arn}}},
        {"Sid": "DenyInsecureTransport", "Effect": "Deny", "Principal": "*",
         "Action": "s3:*", "Resource": [bucket_arn, objects],
         "Condition": {"Bool": {"aws:SecureTransport": "false"}}},
        # a gateway bug can never mint a working URL or form for a slot, which would bypass the
        # author check (ADR-0046); retention and tagging too, as a presigned PUT needs them
        {"Sid": "DenyPresignedSlotPuts", "Effect": "Deny", "Principal": "*",
         "Action": PRESIGNED_PUT_ACTIONS, "NotResource": attachments(bucket_arn),
         "Condition": NOT_HEADER_AUTH},
        # whatever signs as the gateway role (a gateway bug, the probe's signer Lambda) signs
        # nothing but a put (#92)
        {"Sid": "DenyGatewayPresignedNonPuts", "Effect": "Deny", "Principal": "*",
         "NotAction": PRESIGNED_PUT_ACTIONS, "Resource": [bucket_arn, objects],
         "Condition": {"ArnEquals": {"aws:PrincipalArn": role_arn}, **NOT_HEADER_AUTH}},
    ]
    st += [{"Sid": f"Read{n}", "Effect": "Allow", "Principal": {"AWS": arn},
            "Action": ["s3:GetObject", "s3:ListBucket"], "Resource": [bucket_arn, objects]}
           for n, arn in enumerate(principals, 1)]
    return st


def main(argv: list[str]) -> None:
    commands = {
        "gateway-put": (1, lambda a: gateway_put(a[0])),
        "deploy-statements": (3, lambda a: deploy_statements(a[0], a[1], json.loads(a[2]))),
        "attachments": (1, lambda a: attachments(a[0])),
    }
    if not argv or argv[0] not in commands or len(argv) - 1 != commands[argv[0]][0]:
        sys.exit(f"policies.py: usage: one of {sorted(commands)} with its arguments (see the module docstring); "
                 f"got {argv!r}")
    print(json.dumps(commands[argv[0]][1](argv[1:])))


if __name__ == "__main__":
    main(sys.argv[1:])
