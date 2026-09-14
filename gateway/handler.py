"""ChainTables gateway: the one writer of a gateway bucket.

A Lambda function behind a function URL with ``AuthType=AWS_IAM``. It fills a slot only
after checking, in this order (issue #54 §5, the first failure wins):

1. the caller is an IAM user or assumed role whose name the policy allows for the key's
   prefix, else ``403 not_allowed``;
2. the key is a slot, ``<prefix>/<12 digits>`` or ``<12 digits>`` at the bucket root, never
   a reserved name, else ``400 not_a_slot``;
3. the body decodes (``cbor2``) as a map, else ``400 not_cbor_map``;
4. ``client.user`` is present and non-empty text, else ``400 no_author``;
5. ``client.user`` equals the caller's name, else ``403 author_mismatch``;
6. the body is at most 4 MiB, else ``413 too_large``;
7. ``put_object(IfNoneMatch="*")`` under the function's own role, mapped by HTTP status:
   success → ``200 created``, 412 → ``412 slot_taken``, 409 → ``409 conflict``, anything
   else (S3 5xx, transport, or a misconfigured deployment) → ``502 s3_error``. The gateway
   never retries S3; the client's retry loop owns retries.

The gateway validates and never authors: it does not read ``prev_hash``, ``chain_id`` or
the ops, and it is not a ChainTables client. The caller's name is the text after the last
``/`` of the caller ARN, the same rule the Julia client applies to ``sts:GetCallerIdentity``.

Deployment contract: the Lambda environment carries ``CHAINTABLES_BUCKET`` (the bucket this
gateway fronts) and optionally ``CHAINTABLES_POLICY`` (path of the policy file; default
``policy.json`` beside this module). Both are read at the first request and cached for the
life of the execution environment; a missing bucket or an unreadable policy raises on every
request, so a misconfigured deployment fails loudly instead of serving some.
"""

from __future__ import annotations

import base64
import fnmatch
import json
import logging
import os
import re
from dataclasses import dataclass
from urllib.parse import parse_qs

import cbor2
from botocore.exceptions import BotoCoreError, ClientError

log = logging.getLogger("chaintables.gateway")

MAX_RECORD_BYTES = 4 * 1024 * 1024
POLICY_FORMAT_VERSION = 1

# `<prefix>/<12 digits>` with a non-empty prefix that neither begins nor ends with '/',
# or `<12 digits>` alone at the bucket root (ADR-0011).
SLOT_KEY = re.compile(r"^(?:(?P<prefix>[^/](?:.*[^/])?)/)?(?P<slot>[0-9]{12})$")

# The two principal kinds the gateway accepts. An IAM user may carry a path
# (`user/path/name`); a role session name never contains '/'.
PRINCIPAL_ARN = re.compile(
    r"^arn:[^:]+:(?:iam|sts)::[0-9]{12}:(?:assumed-role/[^/]+/(?P<session>[^/]+)|user/(?:[^/]+/)*(?P<user>[^/]+))$"
)


class ConfigError(ValueError):
    """The Lambda environment lacks a value the gateway needs."""


class PolicyError(ValueError):
    """The policy file is missing or not in the documented shape. Raised at configuration, never per request."""


@dataclass(frozen=True)
class Rule:
    prefix: str
    writers: frozenset[str]


@dataclass(frozen=True)
class Policy:
    """Which caller names may fill slots under which chain prefixes.

    File shape (JSON)::

        {"format_version": 1,
         "rules": [{"prefix": "teams/alpha", "writers": ["alice@example.com"]},
                   {"prefix": "teams/*",     "writers": ["carol@example.com"]},
                   {"prefix": "",            "writers": ["root-writer"]}]}

    ``prefix`` is a glob matched case-sensitively against the whole chain prefix (the key
    up to its last ``/``; ``""`` is the bucket root), where ``*`` matches any run of
    characters including ``/``. A caller is allowed when any matching rule lists its name;
    names match exactly and case-sensitively. Creating a chain under an allowed prefix needs
    no separate right.
    """

    rules: tuple[Rule, ...]

    @classmethod
    def from_dict(cls, doc) -> "Policy":
        if not isinstance(doc, dict):
            raise PolicyError("policy is not a JSON object")
        if doc.get("format_version") != POLICY_FORMAT_VERSION:
            raise PolicyError(f"policy format_version is {doc.get('format_version')!r}; this gateway reads {POLICY_FORMAT_VERSION}")
        unknown = set(doc) - {"format_version", "rules"}
        if unknown:
            raise PolicyError(f"policy has unknown fields {sorted(unknown)}")
        rules = doc.get("rules")
        if not isinstance(rules, list):
            raise PolicyError("policy 'rules' is not a list")
        out = []
        for i, r in enumerate(rules):
            if not isinstance(r, dict) or set(r) != {"prefix", "writers"}:
                raise PolicyError(f"policy rule {i} must be an object with exactly 'prefix' and 'writers'")
            if not isinstance(r["prefix"], str):
                raise PolicyError(f"policy rule {i}: 'prefix' is not text")
            if not isinstance(r["writers"], list) or not all(isinstance(w, str) and w for w in r["writers"]):
                raise PolicyError(f"policy rule {i}: 'writers' is not a list of non-empty names")
            out.append(Rule(r["prefix"], frozenset(r["writers"])))
        return cls(tuple(out))

    @classmethod
    def from_file(cls, path) -> "Policy":
        try:
            with open(path, "rb") as f:
                doc = json.load(f)
        except OSError as e:
            raise PolicyError(f"policy file {path} cannot be read: {e}") from e
        except ValueError as e:
            raise PolicyError(f"policy file {path} is not JSON: {e}") from e
        return cls.from_dict(doc)

    def allows(self, name: str, prefix: str) -> bool:
        return any(name in r.writers for r in self.rules if fnmatch.fnmatchcase(prefix, r.prefix))


def caller_name(user_arn) -> str | None:
    """The text after the last '/' of an IAM-user or assumed-role ARN; None for any other principal."""
    if not isinstance(user_arn, str):
        return None
    m = PRINCIPAL_ARN.match(user_arn)
    if m is None:
        return None
    return m.group("session") or m.group("user")


def chain_prefix(key: str) -> str:
    """The key up to its last '/', or '' at the bucket root. For a slot key this is the chain prefix."""
    i = key.rfind("/")
    return "" if i < 0 else key[:i]


class Refusal(Exception):
    def __init__(self, status: int, code: str, message: str):
        super().__init__(message)
        self.status, self.code, self.message = status, code, message


def response(status: int, code: str, message: str) -> dict:
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json"},
        "body": json.dumps({"code": code, "message": message}),
    }


@dataclass(frozen=True)
class Gateway:
    policy: Policy
    bucket: str
    s3: object  # a boto3 S3 client

    def handle(self, event: dict) -> dict:
        try:
            return self._handle(event)
        except Refusal as r:
            log.info("refused %s %s: %s", r.status, r.code, r.message)
            return response(r.status, r.code, r.message)

    def _handle(self, event: dict) -> dict:
        ctx = event.get("requestContext") or {}
        http = ctx.get("http") or {}
        if http.get("method") != "PUT" or http.get("path") != "/":
            raise Refusal(400, "bad_request",
                          f"{http.get('method')} {http.get('path')} is not the gateway's one route, PUT /?key=<slot key>")
        key = request_key(event)
        name = caller_name(((ctx.get("authorizer") or {}).get("iam") or {}).get("userArn"))
        prefix = chain_prefix(key)
        if name is None or not self.policy.allows(name, prefix):
            who = name if name is not None else "a principal that is neither an IAM user nor an assumed role"
            raise Refusal(403, "not_allowed",
                          f"{who} may not write under prefix {prefix!r}: "
                          "ask the bucket's operator to add the name to the gateway policy")
        if SLOT_KEY.match(key) is None:
            raise Refusal(400, "not_a_slot",
                          f"key {key!r} is not a slot: a slot key is <prefix>/<12 digits>, or <12 digits> at the "
                          "bucket root, and the gateway never writes a reserved name")
        body = request_body(event)
        author = record_author(body)
        if author != name:
            raise Refusal(403, "author_mismatch",
                          f"the record names {author!r} as client.user but the caller is {name!r}: a client bug, "
                          "or the credentials changed between the identity call and the commit; report it")
        if len(body) > MAX_RECORD_BYTES:
            raise Refusal(413, "too_large",
                          f"the record is {len(body)} bytes; a gateway bucket caps a record at {MAX_RECORD_BYTES} "
                          "bytes (4 MiB): split the write into more than one commit")
        return self._put(key, body, name)

    def _put(self, key: str, body: bytes, name: str) -> dict:
        try:
            self.s3.put_object(Bucket=self.bucket, Key=key, Body=body, IfNoneMatch="*",
                               ContentType="application/cbor")
        except ClientError as e:
            status = e.response.get("ResponseMetadata", {}).get("HTTPStatusCode")
            code = e.response.get("Error", {}).get("Code")
            if status == 412:
                raise Refusal(412, "slot_taken", f"slot {key!r} already holds a record")
            if status == 409:
                raise Refusal(409, "conflict", f"a concurrent conditional write to {key!r} is in progress; retry")
            log.error("S3 put_object %s failed: %s %s", key, status, code)
            raise Refusal(502, "s3_error", f"S3 answered {status} {code} to the put of {key!r}: "
                                           "a 5xx is transient and may be retried; anything else is the "
                                           "gateway's deployment, report it to the bucket's operator")
        except BotoCoreError as e:
            log.error("S3 put_object %s: transport failure: %s", key, e)
            raise Refusal(502, "s3_error", f"the gateway could not reach S3 for {key!r}: {e}")
        log.info("created %s by %s (%d bytes)", key, name, len(body))
        return response(200, "created", f"slot {key!r} now holds the record")


def request_body(event: dict) -> bytes:
    body = event.get("body")
    if body is None:
        return b""
    if not isinstance(body, str):
        raise Refusal(400, "bad_request", "the request body is not text")
    if event.get("isBase64Encoded") is True:
        try:
            return base64.b64decode(body, validate=True)
        except ValueError as e:
            raise Refusal(400, "bad_request", f"the request body is flagged base64 but does not decode: {e}") from e
    return body.encode("utf-8")


def record_author(body: bytes) -> str:
    """`client.user` of the CBOR map in `body`; refuses a non-map body and a missing or empty author."""
    try:
        doc = cbor2.loads(body)
    except (cbor2.CBORDecodeError, TypeError, RecursionError) as e:
        raise Refusal(400, "not_cbor_map", f"the body does not decode as CBOR: {e}") from e
    if not isinstance(doc, dict):
        raise Refusal(400, "not_cbor_map", f"the body decodes as CBOR {type(doc).__name__}, not a map")
    client = doc.get("client")
    if not isinstance(client, dict):
        raise Refusal(400, "no_author", "the record has no 'client' map, so no client.user: a gateway bucket "
                                        "refuses a record without an author")
    user = client.get("user")
    if not isinstance(user, str) or user == "":
        raise Refusal(400, "no_author", "the record has no non-empty client.user: a gateway bucket refuses a "
                                        "record without an author (record_user = false is not allowed here)")
    return user


def request_key(event: dict) -> str:
    q = event.get("queryStringParameters")
    if isinstance(q, dict) and isinstance(q.get("key"), str):
        return q["key"]
    raw = event.get("rawQueryString")
    if isinstance(raw, str):
        keys = parse_qs(raw, keep_blank_values=True).get("key")
        if keys:
            return keys[0]
    raise Refusal(400, "bad_request", "the request has no 'key' query parameter")


# --- the Lambda entry point ---------------------------------------------------------------

_gateway: Gateway | None = None


def _s3_client():
    import boto3  # imported here so the tests, which inject a client, never build one

    return boto3.client("s3")


def configure(environ=os.environ, s3=None) -> Gateway:
    """Build the gateway from the environment: `CHAINTABLES_BUCKET` (required) and
    `CHAINTABLES_POLICY` (default `policy.json` beside this module)."""
    bucket = environ.get("CHAINTABLES_BUCKET")
    if not bucket:
        raise ConfigError("CHAINTABLES_BUCKET is not set in the Lambda environment: the gateway has no bucket to write")
    path = environ.get("CHAINTABLES_POLICY") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "policy.json")
    policy = Policy.from_file(path)
    log.info("gateway configured: bucket %s, policy %s (%d rules)", bucket, path, len(policy.rules))
    return Gateway(policy=policy, bucket=bucket, s3=s3 if s3 is not None else _s3_client())


def handler(event, context):
    """The Lambda handler. Configuration is read on the first call and kept; every request
    then runs through `Gateway.handle`. Anything but a contract refusal propagates, so an
    unexpected failure is a function error in CloudWatch, never a quiet 200."""
    global _gateway
    if _gateway is None:
        _gateway = configure()
    return _gateway.handle(event)
