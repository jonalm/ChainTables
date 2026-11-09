"""ChainTables gateway: the one writer of a gateway bucket.

A Lambda function behind a function URL with ``AuthType=AWS_IAM``. On ``PUT /?key=<slot key>``
it fills a slot only after checking, in this order (issue #54 §5, the first failure wins):

1. the caller is an IAM user or assumed role that the policy allows for the key's prefix
   (its name, and its account and role where the rule pins them), else ``403 not_allowed``;
2. the key is a slot, ``<prefix>/<12 digits>`` or ``<12 digits>`` at the bucket root, never
   a reserved name, with a prefix a Julia client accepts (at most 100 characters, every
   segment portable, ADR-0034), else ``400 not_a_slot``;
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

An attachment key (``<prefix>/_attachments/<sha256 hex>``) is classified before check 1, so the
policy is checked against its ``<prefix>``; on ``PUT /`` it is then ``400 not_a_slot``.

**The mint route** (ADR-0046), ``POST /mint?key=<attachment key>&size=<declared bytes>`` with
an empty body, the first failure winning:

1. method, path, ``key`` and ``size`` present, no body, else ``400 bad_request``;
2. the policy on the attachment's ``<prefix>``, else ``403 not_allowed``;
3. an attachment key with a prefix a client accepts, else ``400 not_a_slot``;
4. ``size`` a decimal count, else ``400 bad_request``; at most 5 GiB, else ``413 too_large``;
5. HEAD the key (S3 failures mapped as for the put: ``502 s3_refused`` / ``502 s3_error``).
   Present → ``200 present``; on a locked bucket the version's COMPLIANCE retain-until is
   read and moved to now + N + margin unless later, and the reply carries ``retain_until``.
   Absent → ``200 minted`` with ``url`` (regional host), ``expires`` and ``headers``, a flat
   object of the lowercase names and values the URL signs, which the client sends exactly
   (``content-type``, ``content-length``, ``if-none-match``, the base64
   ``x-amz-checksum-sha256``, ``x-amz-tagging``, and on a locked bucket the SSE-KMS and lock
   headers, plus ``retain_until`` in the reply). A URL lives 15 min plus the size at 1 MiB/s,
   capped at 12 h less the environment's age less 1 h; under 15 min it is
   ``503 session_ending``, which the client retries. The margin is the lifetime plus a day.
   The role also needs ``s3:GetObject`` and ``s3:ListBucket`` (so an absent key HEADs 404,
   not 403) and ``s3:PutObjectTagging``, and on a locked bucket ``s3:GetObjectRetention``.

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
import math
import os
import re
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Callable
from urllib.parse import parse_qs, urlsplit

import cbor2
from botocore.exceptions import BotoCoreError, ClientError

log = logging.getLogger("chaintables.gateway")
# The audit trail (`created <key> by <name>`, every refusal) is INFO; the Lambda runtime's
# text log format leaves the root logger at WARNING, which would drop it.
log.setLevel(logging.INFO)

MAX_RECORD_BYTES = 4 * 1024 * 1024
POLICY_FORMAT_VERSION = 1

# When this execution environment started, recorded at import (ADR-0046). Lambda exposes no
# expiry of the role's credentials; they were probed to last about 12 h from the
# environment's start, and a presigned URL dies with the credentials that signed it.
ENVIRONMENT_START = datetime.now(timezone.utc)

# The mint route (ADR-0046). S3's limit for one PUT; a URL lives 15 min plus the declared
# size at 1 MiB/s, capped at 12 h less the environment's age less 1 h, and none is minted
# under the 15 min floor. The margin, added to an attachment's retention, is the URL's
# lifetime plus a day between upload and commit.
MAX_ATTACHMENT_BYTES = 5 * 1024 ** 3
MIN_URL_SECONDS = 15 * 60
URL_BYTES_PER_SECOND = 1024 * 1024
SESSION_SECONDS = 12 * 3600
SESSION_SLACK_SECONDS = 3600
COMMIT_ALLOWANCE = timedelta(days=1)
ATTACHMENT_TAG = "chaintables=attachment"

# `<prefix>/<12 digits>` with a non-empty prefix that neither begins nor ends with '/',
# or `<12 digits>` alone at the bucket root (ADR-0011). DOTALL so a control character in the
# prefix reaches `prefix_problem`, which names it; `fullmatch` still refuses one after the digits.
SLOT_KEY = re.compile(r"(?:(?P<prefix>[^/](?:.*[^/])?)/)?(?P<slot>[0-9]{12})", re.DOTALL)

# `<prefix>/_attachments/<sha256 in lowercase hex>`, or `_attachments/<h>` at the bucket root
# (ADR-0046). Its chain is `<prefix>`, not the key up to its last '/'.
ATTACHMENT_KEY = re.compile(r"(?:(?P<prefix>[^/](?:.*[^/])?)/)?_attachments/(?P<hash>[0-9a-f]{64})", re.DOTALL)
DECIMAL = re.compile(r"[0-9]+")

# The Julia client's prefix rules (`check_prefix` in src/chain.jl, `portable_segment_problem`
# in src/store.jl, ADR-0034), mirrored so the gateway refuses every key a client refuses
# (ADR-0035). Change both sides together. The length cap also keeps a key far under S3's
# 1024 bytes, so S3 never refuses one as too long.
MAX_PREFIX_LENGTH = 100
PORTABLE_CHARS = frozenset("abcdefghijklmnopqrstuvwxyz0123456789._-")
WINDOWS_DEVICE_NAMES = frozenset(
    ["con", "prn", "aux", "nul"] + [f"com{i}" for i in range(10)] + [f"lpt{i}" for i in range(10)])

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
        # `type is int`: True and 1.0 compare equal to 1 but are not a format version
        if type(doc.get("format_version")) is not int or doc["format_version"] != POLICY_FORMAT_VERSION:
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


def segment_problem(s: str) -> str | None:
    """Why `s` cannot be one segment of a chain prefix, or None if it can (the Julia
    client's `portable_segment_problem`, in the same words)."""
    if s == "":
        return "is empty"
    if s in (".", ".."):
        return "names a directory relative to its parent"
    for c in s:
        if c not in PORTABLE_CHARS:
            return f"contains {c!r}; only a-z, 0-9, '.', '_' and '-' are portable to every filesystem"
    if s.endswith("."):
        return "ends with '.', which Windows strips"
    if s.split(".")[0] in WINDOWS_DEVICE_NAMES:
        return "is a Windows device name"
    return None


def prefix_problem(prefix: str) -> str | None:
    """Why a Julia client refuses `prefix` as a chain prefix, or None if it accepts it."""
    if prefix == "":
        return None
    if len(prefix) > MAX_PREFIX_LENGTH:
        return f"is {len(prefix)} characters, over {MAX_PREFIX_LENGTH}"
    for s in prefix.split("/"):
        problem = segment_problem(s)
        if problem is not None:
            return f"has the segment {s!r}, which {problem}"
    return None


def chain_prefix(key: str) -> str:
    """The key up to its last '/', or '' at the bucket root. For a slot key this is the chain prefix."""
    i = key.rfind("/")
    return "" if i < 0 else key[:i]


def classify(key: str) -> tuple[str, bool]:
    """The prefix the policy is checked against, and whether the key is an attachment key.
    An attachment's chain is the prefix before `_attachments/`: the key up to its last '/'
    would let a writer of chain `x/_attachments` write chain `x`'s attachments (ADR-0046)."""
    m = ATTACHMENT_KEY.fullmatch(key)
    if m is not None:
        return m.group("prefix") or "", True
    return chain_prefix(key), False


def iso_z(t: datetime) -> str:
    return t.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


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


def response(status: int, code: str, message: str, **extra) -> dict:
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json"},
        "body": json.dumps({"code": code, "message": message, **extra}),
    }


def s3_failure(e: Exception, what: str) -> Refusal:
    """The refusal for an S3 call that failed: an S3 4xx is a misconfigured deployment, which
    the client does not retry; an S3 5xx or a transport failure is transient."""
    if isinstance(e, BotoCoreError):
        log.error("S3 %s: transport failure: %s", what, e)
        return Refusal(502, "s3_error", f"the gateway could not reach S3 for {what}: {e}")
    status = e.response.get("ResponseMetadata", {}).get("HTTPStatusCode")
    code = e.response.get("Error", {}).get("Code")
    log.error("S3 %s failed: %s %s", what, status, code)
    if isinstance(status, int) and 400 <= status < 500:
        return Refusal(502, "s3_refused", f"S3 answered {status} {code} to {what}: the gateway's deployment (its "
                                          "role, its bucket or the lock) is wrong; report it to the bucket's operator")
    return Refusal(502, "s3_error", f"S3 answered {status} {code} to {what}: transient, retry")


@dataclass(frozen=True)
class Gateway:
    policy: Policy
    bucket: str
    s3: object  # a boto3 S3 client, with virtual addressing so that a presigned URL's host is regional
    lock: Lock | None = None  # set on a locked bucket
    now: Callable[[], datetime] = lambda: datetime.now(timezone.utc)  # the mint route's clock
    started: datetime = ENVIRONMENT_START  # injectable so a test can age the environment

    def handle(self, event: dict) -> dict:
        try:
            return self._handle(event)
        except Refusal as r:
            log.info("refused %s %s: %s", r.status, r.code, r.message)
            return response(r.status, r.code, r.message)

    def _handle(self, event: dict) -> dict:
        http = (event.get("requestContext") or {}).get("http") or {}
        route = (http.get("method"), http.get("path"))
        if route == ("PUT", "/"):
            return self._slot(event)
        if route == ("POST", "/mint"):
            return self._mint(event)
        raise Refusal(400, "bad_request",
                      f"{http.get('method')} {http.get('path')} is not one of the gateway's routes, "
                      "PUT /?key=<slot key> and POST /mint?key=<attachment key>&size=<bytes>")

    def _allowed(self, event: dict, prefix: str) -> str:
        """The caller's name, if the policy allows it on `prefix`; else `403 not_allowed`."""
        ctx = event.get("requestContext") or {}
        caller = parse_caller(((ctx.get("authorizer") or {}).get("iam") or {}).get("userArn"))
        if caller is None or not self.policy.allows(caller, prefix):
            who = ("a principal that is neither an IAM user nor an assumed role" if caller is None else
                   f"{caller.name} (account {caller.account}, "
                   f"{'IAM user' if caller.role is None else 'role ' + caller.role})")
            raise Refusal(403, "not_allowed",
                          f"{who} may not write under prefix {prefix!r}: "
                          "ask the bucket's operator to add the name to the gateway policy")
        return caller.name

    def _slot(self, event: dict) -> dict:
        key = request_param(event, "key")
        prefix, is_attachment = classify(key)
        name = self._allowed(event, prefix)
        if is_attachment:
            raise Refusal(400, "not_a_slot",
                          f"key {key!r} is an attachment, not a slot: an attachment is written through the mint "
                          "route, POST /mint?key=<attachment key>&size=<bytes>")
        if SLOT_KEY.fullmatch(key) is None:
            raise Refusal(400, "not_a_slot",
                          f"key {key!r} is not a slot: a slot key is <prefix>/<12 digits>, or <12 digits> at the "
                          "bucket root, and the gateway never writes a reserved name")
        problem = prefix_problem(prefix)
        if problem is not None:
            raise Refusal(400, "not_a_slot",
                          f"key {key!r} is not a slot: its prefix {problem}; a ChainTables client refuses such a "
                          "prefix, so the gateway never writes under it")
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
            if status == 412:
                raise Refusal(412, "slot_taken", f"slot {key!r} already holds a record")
            if status == 409:
                raise Refusal(409, "conflict", f"a concurrent conditional write to {key!r} is in progress; retry")
            raise s3_failure(e, f"the put of {key!r}")
        except BotoCoreError as e:
            raise s3_failure(e, f"the put of {key!r}")
        log.info("created %s by %s (%d bytes)", key, name, len(body))
        return response(200, "created", f"slot {key!r} now holds the record")

    # --- the mint route (ADR-0046) ---------------------------------------------------------

    def _mint(self, event: dict) -> dict:
        key = request_param(event, "key")
        size_text = request_param(event, "size")
        if request_body(event) != b"":
            raise Refusal(400, "bad_request", "the mint route takes no body: the attachment's bytes go to S3 through "
                                              "the minted URL")
        prefix, is_attachment = classify(key)
        name = self._allowed(event, prefix)
        if not is_attachment:
            raise Refusal(400, "not_a_slot",
                          f"key {key!r} is neither a slot nor an attachment: an attachment key is "
                          "<prefix>/_attachments/<SHA-256 in 64 lowercase hex>, or _attachments/<hash> at the "
                          "bucket root")
        problem = prefix_problem(prefix)
        if problem is not None:
            raise Refusal(400, "not_a_slot",
                          f"key {key!r} is neither a slot nor an attachment: its prefix {problem}; a ChainTables "
                          "client refuses such a prefix, so the gateway never writes under it")
        if DECIMAL.fullmatch(size_text) is None:
            raise Refusal(400, "bad_request", f"size {size_text!r} is not a decimal count of bytes")
        size = int(size_text)
        if size > MAX_ATTACHMENT_BYTES:
            raise Refusal(413, "too_large", f"the attachment is declared {size} bytes; S3 takes at most "
                                            f"{MAX_ATTACHMENT_BYTES} bytes (5 GiB) in one PUT")
        try:
            head = self.s3.head_object(Bucket=self.bucket, Key=key)
        except ClientError as e:
            if e.response.get("ResponseMetadata", {}).get("HTTPStatusCode") != 404:
                raise s3_failure(e, f"the HEAD of {key!r}")
            return self._mint_absent(key, size, name)
        except BotoCoreError as e:
            raise s3_failure(e, f"the HEAD of {key!r}")
        return self._present(key, size, name, head.get("VersionId"))

    def _wanted_seconds(self, size: int) -> int:
        return MIN_URL_SECONDS + -(-size // URL_BYTES_PER_SECOND)

    def _present(self, key: str, size: int, name: str, version: str | None) -> dict:
        """The attachment is present: nothing is uploaded, and on a locked bucket its retention
        is moved to now + N + margin unless it is already later. The margin is uncapped here,
        since no URL is minted."""
        if self.lock is None:
            log.info("present %s by %s", key, name)
            return response(200, "present", f"attachment {key!r} is already stored; upload nothing")
        if not version:
            raise Refusal(502, "s3_refused", f"S3 gave no version id for {key!r}: a locked bucket is versioned, so "
                                             "the gateway's bucket is wrong; report it to the bucket's operator")
        now = self.now().astimezone(timezone.utc).replace(microsecond=0)
        target = (now + timedelta(days=self.lock.retention_days) + timedelta(seconds=self._wanted_seconds(size))
                  + COMMIT_ALLOWANCE)
        try:
            retention = self.s3.get_object_retention(Bucket=self.bucket, Key=key, VersionId=version)["Retention"]
        except (ClientError, BotoCoreError) as e:
            raise s3_failure(e, f"GetObjectRetention of {key!r}")
        if retention.get("Mode") != "COMPLIANCE":
            raise Refusal(502, "s3_refused", f"attachment {key!r} is retained in mode {retention.get('Mode')!r}, not "
                                             "COMPLIANCE: the bucket is not locked as the gateway was told; report it "
                                             "to the bucket's operator")
        current = retention["RetainUntilDate"]
        if current >= target:
            until, how = current, "already later"
        else:
            try:
                self.s3.put_object_retention(Bucket=self.bucket, Key=key, VersionId=version,
                                             Retention={"Mode": "COMPLIANCE", "RetainUntilDate": target})
            except (ClientError, BotoCoreError) as e:
                raise s3_failure(e, f"PutObjectRetention of {key!r}")
            until, how = target, "extended"
        log.info("present %s by %s (retain-until %s, %s)", key, name, iso_z(until), how)
        return response(200, "present", f"attachment {key!r} is already stored and retained until {iso_z(until)}; "
                                         "upload nothing", retain_until=iso_z(until))

    def _mint_absent(self, key: str, size: int, name: str) -> dict:
        clock = self.now()
        now = clock.astimezone(timezone.utc).replace(microsecond=0)
        cap = math.floor(SESSION_SECONDS - SESSION_SLACK_SECONDS - (clock - self.started).total_seconds())
        if cap < MIN_URL_SECONDS:
            raise Refusal(503, "session_ending",
                          f"this gateway's AWS session ends too soon to mint a URL that lives {MIN_URL_SECONDS} "
                          "seconds: retry, and another execution environment answers")
        seconds = min(self._wanted_seconds(size), cap)
        params = {"Bucket": self.bucket, "Key": key, "ContentType": "application/octet-stream", "ContentLength": size,
                  "IfNoneMatch": "*", "ChecksumSHA256": base64.b64encode(bytes.fromhex(key[-64:])).decode("ascii"),
                  "Tagging": ATTACHMENT_TAG}
        extra = {}
        if self.lock is not None:
            until = now + timedelta(days=self.lock.retention_days) + timedelta(seconds=seconds) + COMMIT_ALLOWANCE
            params |= {"ServerSideEncryption": "aws:kms", "SSEKMSKeyId": self.lock.kms_key_arn,
                       "BucketKeyEnabled": True, "ObjectLockMode": "COMPLIANCE", "ObjectLockRetainUntilDate": until}
            extra["retain_until"] = iso_z(until)
        url, headers = self._presign(params, seconds)
        expires = iso_z(now + timedelta(seconds=seconds))
        log.info("minted %s by %s (%d bytes, expires %s)", key, name, size, expires)
        return response(200, "minted", f"PUT the attachment's {size} bytes to the url with exactly these headers "
                                       f"before {expires}", url=url, expires=expires, headers=headers, **extra)

    def _presign(self, params: dict, seconds: int) -> tuple[str, dict]:
        """A presigned PUT and the headers it signs, in botocore's own serialization, so the
        client sends exactly what was signed. A URL on any host but the bucket's regional one
        is a deployment bug: the global host answers a young bucket with 307."""
        headers = {}

        def grab(request, **_):
            headers.update((k.lower(), v.decode("ascii") if isinstance(v, bytes) else v)
                           for k, v in request.headers.items())

        events = self.s3.meta.events
        events.register("before-sign.s3.PutObject", grab, unique_id="chaintables-mint")
        try:
            url = self.s3.generate_presigned_url("put_object", Params=params, ExpiresIn=seconds)
        finally:
            events.unregister("before-sign.s3.PutObject", unique_id="chaintables-mint")
        u = urlsplit(url)
        host = f"{self.bucket}.s3.{self.s3.meta.region_name}.amazonaws.com"
        if u.scheme != "https" or u.netloc != host:
            raise RuntimeError(f"presigned {u.scheme}://{u.netloc}, not https://{host}: the S3 client must be built "
                               "with addressing_style 'virtual' and the bucket's region")
        signed = set(parse_qs(u.query)["X-Amz-SignedHeaders"][0].split(";")) - {"host"}
        if set(headers) != signed:
            raise RuntimeError(f"captured headers {sorted(headers)} are not the signed ones {sorted(signed)}")
        return url, headers


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


def request_param(event: dict, name: str) -> str:
    q = event.get("queryStringParameters")
    if isinstance(q, dict) and isinstance(q.get(name), str):
        return q[name]
    raw = event.get("rawQueryString")
    if isinstance(raw, str):
        values = parse_qs(raw, keep_blank_values=True).get(name)
        if values:
            return values[0]
    raise Refusal(400, "bad_request", f"the request has no {name!r} query parameter")


# --- the Lambda entry point ---------------------------------------------------------------

_gateway: Gateway | None = None


def _s3_client():
    import boto3  # imported here so the tests, which inject a client, never build one
    from botocore.config import Config

    # virtual addressing presigns the bucket's regional host; the default global one 307s (ADR-0046).
    # In us-east-1 botocore's default host is the global one, so ask for the regional one there too.
    return boto3.client("s3", config=Config(s3={"addressing_style": "virtual", "us_east_1_regional_endpoint": "regional"}))


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
