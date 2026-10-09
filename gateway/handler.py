"""ChainTables gateway: the one writer of a gateway bucket.

A Lambda function behind a function URL with ``AuthType=AWS_IAM``. It fills a slot only
after checking, in this order (issue #54 §5, the first failure wins):

1. the caller is an IAM user or assumed role that the policy allows for the key's prefix
   (its name, and its account and role where the rule pins them), else ``403 not_allowed``;
2. the key is a slot, ``<prefix>/<12 digits>`` or ``<12 digits>`` at the bucket root, never
   a reserved name, else ``400 not_a_slot``;
3. the body is a CBOR map in the record format the Julia reader accepts (``src/cbor.jl``,
   ADR-0006): text keys, no tags, int64 integers, at most 64 levels deep, and the
   deterministic encoding — no duplicate or unsorted keys, no indefinite lengths, no
   non-shortest heads or floats, no trailing bytes — else ``400 not_cbor_map``. A record the
   gateway accepts but clients refuse would break the chain for every reader;
4. ``client.user`` is present and non-empty text, else ``400 no_author``;
5. ``client.user`` equals the caller's name, else ``403 author_mismatch``;
6. the body is at most 4 MiB, else ``413 too_large``;
7. ``put_object(IfNoneMatch="*")`` under the function's own role, mapped by HTTP status:
   success → ``200 created``, 412 → ``412 slot_taken``, 409 → ``409 conflict``, any other
   S3 4xx (a misconfigured deployment: the role, the bucket, the lock) → ``502 s3_refused``,
   which the client does not retry, and an S3 5xx or a transport failure → ``502 s3_error``,
   which it does. The gateway never retries S3; the client's retry loop owns retries.

The gateway validates and never authors: it does not read ``prev_hash``, ``chain_id`` or
the ops, and it is not a ChainTables client. The caller's name is the text after the last
``/`` of the caller ARN, the same rule the Julia client applies to ``sts:GetCallerIdentity``.

Deployment contract: the Lambda environment carries ``CHAINTABLES_BUCKET`` (the bucket this
gateway fronts) and optionally ``CHAINTABLES_POLICY`` (path of the policy file; default
``policy.json`` beside this module). In Lambda both are read once at startup, when this
module is imported (the INIT phase, see the end of the file), and kept for the life of the
execution environment; elsewhere at the first request. A missing bucket or an unreadable
policy raises at startup, so a misconfigured deployment fails on every request instead of
serving some.

A **locked bucket** is one whose bucket policy refuses a put unless it is SSE-KMS encrypted
with one key and carries a COMPLIANCE-mode Object Lock retention. Setting both
``CHAINTABLES_KMS_KEY_ARN`` and ``CHAINTABLES_RETENTION_DAYS`` (a positive integer) makes
every put carry: ``ServerSideEncryption=aws:kms`` with that key and the bucket key,
``ObjectLockMode=COMPLIANCE`` with ``ObjectLockRetainUntilDate`` = now + the days, a SHA-256
checksum of the body. Nothing is derived from the key: a locked bucket takes a slot under any
prefix a plain one does (ADR-0031). Setting one variable without the other is a configuration
error. The execution role then also needs ``s3:PutObjectRetention`` and ``kms:GenerateDataKey``.
"""

from __future__ import annotations

import base64
import fnmatch
import hashlib
import json
import logging
import os
import re
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Callable
from urllib.parse import parse_qs

import cbor2
from botocore.exceptions import BotoCoreError, ClientError

log = logging.getLogger("chaintables.gateway")

MAX_RECORD_BYTES = 4 * 1024 * 1024
POLICY_FORMAT_VERSION = 1

# `<prefix>/<12 digits>` with a non-empty prefix that neither begins nor ends with '/',
# or `<12 digits>` alone at the bucket root (ADR-0011).
SLOT_KEY = re.compile(r"(?:(?P<prefix>[^/](?:.*[^/])?)/)?(?P<slot>[0-9]{12})")

# The two principal kinds the gateway accepts. An IAM user may carry a path
# (`user/path/name`); a role session name never contains '/'; neither contains whitespace.
PRINCIPAL_ARN = re.compile(
    r"arn:[^:\s]+:(?:iam|sts)::(?P<account>[0-9]{12}):"
    r"(?:assumed-role/(?P<role>[^/\s]+)/(?P<session>[^/\s]+)|user/(?:[^/\s]+/)*(?P<user>[^/\s]+))"
)

# A policy rule's pins: an account id, and a role-name glob (IAM's role-name characters,
# with '*' as the only wildcard).
ACCOUNT_ID = re.compile(r"[0-9]{12}")
ROLE_GLOB = re.compile(r"[A-Za-z0-9+=,.@_*-]+")

# The record format's bounds (src/cbor.jl): integers are int64, nesting is at most 64 levels.
INT64_MIN, INT64_MAX = -(2**63), 2**63 - 1
MAX_DEPTH = 64


class ConfigError(ValueError):
    """The Lambda environment lacks a value the gateway needs."""


class PolicyError(ValueError):
    """The policy file is missing or not in the documented shape. Raised at configuration, never per request."""


@dataclass(frozen=True)
class Caller:
    """The principal named by a caller ARN: its account, its role (None for an IAM user), and
    its name, the text after the last '/' (ADR-0028)."""

    account: str
    role: str | None
    name: str


@dataclass(frozen=True)
class Rule:
    prefix: str
    writers: frozenset[str]
    accounts: frozenset[str] | None = None  # None: any account (ADR-0039)
    roles: tuple[str, ...] | None = None  # None: any principal; else an assumed role whose name matches a glob

    def admits(self, caller: Caller) -> bool:
        return (caller.name in self.writers
                and (self.accounts is None or caller.account in self.accounts)
                and (self.roles is None
                     or caller.role is not None and any(fnmatch.fnmatchcase(caller.role, g) for g in self.roles)))


@dataclass(frozen=True)
class Policy:
    """Which caller names may fill slots under which chain prefixes.

    File shape (JSON)::

        {"format_version": 1,
         "rules": [{"prefix": "teams/alpha", "writers": ["alice@example.com"],
                    "accounts": ["111122223333"], "roles": ["AWSReservedSSO_chaintables-writer_*"]},
                   {"prefix": "teams/*",     "writers": ["carol@example.com"]},
                   {"prefix": "",            "writers": ["root-writer"]}]}

    ``prefix`` is a glob matched case-sensitively against the whole chain prefix (the key
    up to its last ``/``; ``""`` is the bucket root), where ``*`` matches any run of
    characters including ``/``; ``*`` is the only wildcard, and a prefix holding ``?``,
    ``[`` or ``]`` is refused at load, since no chain prefix contains them (ADR-0034). A caller is allowed when any matching rule admits it:
    the rule lists its name (exactly, case-sensitively) and, where the rule has them, its
    account is in ``accounts`` and it is an assumed role whose role name matches a glob in
    ``roles`` (an IAM user never matches a rule with ``roles``). ``roles`` needs ``accounts``:
    a role name is whatever its account's administrators chose, so alone it pins nothing
    (ADR-0039). Creating a chain under an allowed prefix needs no separate right.
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
            if not isinstance(r, dict) or not {"prefix", "writers"} <= set(r) <= {"prefix", "writers", "accounts", "roles"}:
                raise PolicyError(f"policy rule {i} must be an object with 'prefix' and 'writers', and optionally "
                                  "'accounts' and 'roles'")
            if not isinstance(r["prefix"], str):
                raise PolicyError(f"policy rule {i}: 'prefix' is not text")
            if any(c in r["prefix"] for c in "?[]"):
                raise PolicyError(f"policy rule {i}: prefix {r['prefix']!r} holds '?', '[' or ']'; '*' is the only "
                                  "wildcard, and no chain prefix contains those characters (ADR-0034)")
            if not isinstance(r["writers"], list) or not all(isinstance(w, str) and w for w in r["writers"]):
                raise PolicyError(f"policy rule {i}: 'writers' is not a list of non-empty names")
            accounts = r.get("accounts")
            if accounts is not None:
                if not isinstance(accounts, list) or not accounts or \
                        not all(isinstance(a, str) and ACCOUNT_ID.fullmatch(a) for a in accounts):
                    raise PolicyError(f"policy rule {i}: 'accounts' is not a non-empty list of 12-digit account ids "
                                      "(as text)")
                accounts = frozenset(accounts)
            roles = r.get("roles")
            if roles is not None:
                if not isinstance(roles, list) or not roles or \
                        not all(isinstance(g, str) and ROLE_GLOB.fullmatch(g) for g in roles):
                    raise PolicyError(f"policy rule {i}: 'roles' is not a non-empty list of role-name globs: a glob "
                                      "matches the role name alone (letters, digits, '+=,.@_-', and '*' as the only "
                                      "wildcard), never a role ARN or path")
                if accounts is None:
                    raise PolicyError(f"policy rule {i}: 'roles' without 'accounts' pins nothing, since any account's "
                                      "administrators can create a role of any name: add 'accounts' (ADR-0039)")
                roles = tuple(roles)
            out.append(Rule(r["prefix"], frozenset(r["writers"]), accounts, roles))
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

    def allows(self, caller: Caller, prefix: str) -> bool:
        # fnmatch's other wildcards, '?' and '[...]', are refused at load, so '*' is the only one here.
        return any(r.admits(caller) for r in self.rules if fnmatch.fnmatchcase(prefix, r.prefix))


def parse_caller(user_arn) -> Caller | None:
    """The principal of an IAM-user or assumed-role ARN; None for any other principal."""
    if not isinstance(user_arn, str):
        return None
    m = PRINCIPAL_ARN.fullmatch(user_arn)
    if m is None:
        return None
    return Caller(account=m.group("account"), role=m.group("role"), name=m.group("session") or m.group("user"))


def chain_prefix(key: str) -> str:
    """The key up to its last '/', or '' at the bucket root. For a slot key this is the chain prefix."""
    i = key.rfind("/")
    return "" if i < 0 else key[:i]


@dataclass(frozen=True)
class Lock:
    """How a put to a locked bucket is dressed: the KMS key, the retention, and the clock
    (injectable so a test can pin the retain-until date)."""

    kms_key_arn: str
    retention_days: int
    now: Callable[[], datetime] = lambda: datetime.now(timezone.utc)

    def put_kwargs(self, body: bytes) -> dict:
        retain_until = self.now().astimezone(timezone.utc).replace(microsecond=0) + timedelta(days=self.retention_days)
        return {
            "ServerSideEncryption": "aws:kms",
            "SSEKMSKeyId": self.kms_key_arn,
            "BucketKeyEnabled": True,
            "ObjectLockMode": "COMPLIANCE",
            "ObjectLockRetainUntilDate": retain_until,
            "ChecksumSHA256": base64.b64encode(hashlib.sha256(body).digest()).decode("ascii"),
        }


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
    lock: Lock | None = None  # set on a locked bucket

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
        caller = parse_caller(((ctx.get("authorizer") or {}).get("iam") or {}).get("userArn"))
        prefix = chain_prefix(key)
        if caller is None or not self.policy.allows(caller, prefix):
            who = ("a principal that is neither an IAM user nor an assumed role" if caller is None else
                   f"{caller.name} (account {caller.account}, "
                   f"{'IAM user' if caller.role is None else 'role ' + caller.role})")
            raise Refusal(403, "not_allowed",
                          f"{who} may not write under prefix {prefix!r}: "
                          "ask the bucket's operator to add the name to the gateway policy")
        name = caller.name
        if SLOT_KEY.fullmatch(key) is None:
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
        extra = self.lock.put_kwargs(body) if self.lock is not None else {}
        try:
            self.s3.put_object(Bucket=self.bucket, Key=key, Body=body, IfNoneMatch="*",
                               ContentType="application/cbor", **extra)
        except ClientError as e:
            status = e.response.get("ResponseMetadata", {}).get("HTTPStatusCode")
            code = e.response.get("Error", {}).get("Code")
            if status == 412:
                raise Refusal(412, "slot_taken", f"slot {key!r} already holds a record")
            if status == 409:
                raise Refusal(409, "conflict", f"a concurrent conditional write to {key!r} is in progress; retry")
            log.error("S3 put_object %s failed: %s %s", key, status, code)
            if isinstance(status, int) and 400 <= status < 500:
                raise Refusal(502, "s3_refused", f"S3 answered {status} {code} to the put of {key!r}: the gateway's "
                                                 "deployment (its role, its bucket or the lock) is wrong; report it to "
                                                 "the bucket's operator")
            raise Refusal(502, "s3_error", f"S3 answered {status} {code} to the put of {key!r}: transient, retry")
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


def decode_record(body: bytes):
    """The CBOR item in `body`, refused unless the Julia reader would accept it (``src/cbor.jl``):
    `cbor2` is lenient (it takes duplicate keys, trailing bytes, indefinite lengths, tags), so
    the item is checked against the format's domain and then re-encoded canonically, which must
    give back `body` byte for byte. `cbor2`'s canonical encoder matched the Julia encoder on the
    whole conformance corpus (``test/conformance``)."""
    try:
        doc = cbor2.loads(body)
    except (cbor2.CBORDecodeError, TypeError, RecursionError) as e:
        raise Refusal(400, "not_cbor_map", f"the body does not decode as CBOR: {e}") from e
    try:
        problem = format_problem(doc, 0)
    except RecursionError:  # a cycle, which only a shared-reference tag builds
        problem = "a shared reference (tag 28/29); tags are not in the record format"
    if problem is not None:
        raise Refusal(400, "not_cbor_map", f"the body is CBOR but not in the record format: {problem}")
    canonical = cbor2.dumps(doc, canonical=True)
    if canonical != body:
        at = next((i for i, (a, b) in enumerate(zip(canonical, body)) if a != b), min(len(canonical), len(body)))
        raise Refusal(400, "not_cbor_map",
                      f"the body is CBOR but not in the record format's deterministic encoding (RFC 8949 §4.2.1), from "
                      f"byte {at}: a duplicate or unsorted map key, an indefinite length, a tag, a non-shortest integer "
                      f"or float, a non-canonical NaN, or trailing bytes ({len(body)} bytes sent, {len(canonical)} "
                      "canonical)")
    return doc


def format_problem(x, depth: int) -> str | None:
    """What puts `x` outside the record format's domain (``src/cbor.jl``), or None."""
    if depth > MAX_DEPTH:
        return f"nesting deeper than {MAX_DEPTH} levels"
    if x is None or isinstance(x, (bool, float, bytes)):
        return None
    if isinstance(x, int):
        return None if INT64_MIN <= x <= INT64_MAX else f"integer {x} is outside the int64 domain"
    if isinstance(x, str):
        return "text contains U+0000" if "\x00" in x else None
    if isinstance(x, list):
        return next((p for v in x if (p := format_problem(v, depth + 1)) is not None), None)
    if isinstance(x, dict):
        for k, v in x.items():
            if not isinstance(k, str):
                return f"map key {k!r} is {type(k).__name__}, not text"
            p = format_problem(k, depth + 1) or format_problem(v, depth + 1)
            if p is not None:
                return p
        return None
    return f"{type(x).__name__} {x!r} (a tag or simple value) is not a value of the format"


def record_author(body: bytes) -> str:
    """`client.user` of the CBOR map in `body`; refuses a body outside the record format, a
    non-map body, and a missing or empty author."""
    doc = decode_record(body)
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
    """Build the gateway from the environment: `CHAINTABLES_BUCKET` (required),
    `CHAINTABLES_POLICY` (default `policy.json` beside this module), and for a locked bucket
    both `CHAINTABLES_KMS_KEY_ARN` and `CHAINTABLES_RETENTION_DAYS`."""
    bucket = environ.get("CHAINTABLES_BUCKET")
    if not bucket:
        raise ConfigError("CHAINTABLES_BUCKET is not set in the Lambda environment: the gateway has no bucket to write")
    path = environ.get("CHAINTABLES_POLICY") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "policy.json")
    policy = Policy.from_file(path)
    lock = lock_from_environ(environ)
    log.info("gateway configured: bucket %s, policy %s (%d rules), %s", bucket, path, len(policy.rules),
             "plain bucket" if lock is None else f"locked bucket: {lock.kms_key_arn}, {lock.retention_days} day(s)")
    return Gateway(policy=policy, bucket=bucket, s3=s3 if s3 is not None else _s3_client(), lock=lock)


def lock_from_environ(environ) -> Lock | None:
    key_arn, days = environ.get("CHAINTABLES_KMS_KEY_ARN"), environ.get("CHAINTABLES_RETENTION_DAYS")
    if not key_arn and not days:
        return None
    if not key_arn or not days:
        raise ConfigError("a locked bucket needs both CHAINTABLES_KMS_KEY_ARN and CHAINTABLES_RETENTION_DAYS in the "
                          f"Lambda environment; got key {key_arn!r} and days {days!r}")
    if not key_arn.startswith("arn:"):
        raise ConfigError(f"CHAINTABLES_KMS_KEY_ARN must be a key ARN (the bucket policy compares the ARN), not {key_arn!r}")
    if not days.isdigit() or int(days) < 1:
        raise ConfigError(f"CHAINTABLES_RETENTION_DAYS must be a positive integer, not {days!r}")
    return Lock(kms_key_arn=key_arn, retention_days=int(days))


def handler(event, context):
    """The Lambda handler. Configuration is read on the first call and kept; every request
    then runs through `Gateway.handle`. Anything but a contract refusal propagates, so an
    unexpected failure is a function error in CloudWatch, never a quiet 200."""
    global _gateway
    if _gateway is None:
        _gateway = configure()
    return _gateway.handle(event)


# In Lambda, configure at import. The expensive part of a fresh execution environment is
# not the runtime init (~0.1 s) but importing boto3 and building the S3 client, whose
# endpoint ruleset is large: done lazily in the first request on a 256 MB function it cost
# that request 5.1–5.4 s (six cold environments measured on 2026-09-15, against 30 ms for
# a warm request). At import it runs in the INIT phase, which has the full vCPU and which
# Lambda may run ahead of the first request. Outside Lambda (the tests, which inject a
# client) nothing happens here. A configuration error then fails the init, which Lambda
# reports on every invocation, as loud as before.
if os.environ.get("AWS_LAMBDA_FUNCTION_NAME"):
    _gateway = configure()
