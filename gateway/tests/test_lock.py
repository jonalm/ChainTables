"""A locked bucket: every put carries SSE-KMS, COMPLIANCE retention and a checksum, at any prefix."""

import base64
import hashlib
from datetime import datetime, timedelta, timezone

import pytest

import handler as gw
from tests.conftest import BUCKET, POLICY, StubbedS3, event, parse, record

KEY_ARN = "arn:aws:kms:eu-north-1:111122223333:key/9e5dac29-4bec-4c0a-be9c-b720b8013da9"
NOW = datetime(2026, 9, 15, 12, 30, 45, 123456, tzinfo=timezone.utc)
LOCK = gw.Lock(kms_key_arn=KEY_ARN, retention_days=1, now=lambda: NOW)
LOCKED_POLICY = {"format_version": 1, "rules": [{"prefix": "*", "writers": ["alice@example.com"]}]}


@pytest.fixture
def locked(s3):
    return gw.Gateway(policy=gw.Policy.from_dict(LOCKED_POLICY), bucket=BUCKET, s3=s3.client, lock=LOCK)


def expected_extra(body):
    until = datetime(2026, 9, 16, 12, 30, 45, tzinfo=timezone.utc)
    return {
        "ServerSideEncryption": "aws:kms", "SSEKMSKeyId": KEY_ARN, "BucketKeyEnabled": True,
        "ObjectLockMode": "COMPLIANCE", "ObjectLockRetainUntilDate": until,
        "ChecksumSHA256": base64.b64encode(hashlib.sha256(body).digest()).decode("ascii"),
    }


# A locked bucket reads nothing into the prefix (ADR-0031): any slot a plain bucket takes.
@pytest.mark.parametrize("key", [
    "000000000003",                           # bucket root
    "scratch_1/000000000003",                 # one segment
    "teams/alpha/run 7/000000000003",         # nested
])
def test_put_at_any_prefix_carries_encryption_retention_and_checksum(locked, s3, key):
    body = record()
    s3.put_succeeds(key, body, **expected_extra(body))
    status, out = parse(locked.handle(event(key=key, body=body)))
    assert (status, out["code"]) == (200, "created")


def test_retain_until_is_now_plus_the_days_at_whole_seconds():
    kw = gw.Lock(KEY_ARN, 30, now=lambda: NOW).put_kwargs(b"x")
    assert kw["ObjectLockRetainUntilDate"] == NOW.replace(microsecond=0) + timedelta(days=30)


def test_nothing_is_derived_from_the_key():
    assert "Tagging" not in LOCK.put_kwargs(b"x")


def test_a_non_slot_is_still_not_a_slot(locked):
    status, out = parse(locked.handle(event(key="scratch_1/000000000003x")))
    assert (status, out["code"]) == (400, "not_a_slot")


def test_policy_is_still_checked(locked):
    status, out = parse(locked.handle(event(key="000000000003", user_arn="arn:aws:iam::111122223333:user/mallory")))
    assert (status, out["code"]) == (403, "not_allowed")


def test_plain_bucket_sends_none_of_it(gateway, s3):
    body = record()
    s3.put_succeeds("teams/alpha/000000000003", body)
    status, out = parse(gateway.handle(event(body=body)))
    assert (status, out["code"]) == (200, "created")


# --- configuration -------------------------------------------------------------------------

def test_both_variables_configure_a_lock(tmp_path):
    (tmp_path / "policy.json").write_text('{"format_version": 1, "rules": []}')
    env = {"CHAINTABLES_BUCKET": BUCKET, "CHAINTABLES_POLICY": str(tmp_path / "policy.json"),
           "CHAINTABLES_KMS_KEY_ARN": KEY_ARN, "CHAINTABLES_RETENTION_DAYS": "7"}
    g = gw.configure(env, s3=object())
    assert (g.lock.kms_key_arn, g.lock.retention_days) == (KEY_ARN, 7)


def test_neither_variable_is_a_plain_bucket():
    assert gw.lock_from_environ({}) is None


@pytest.mark.parametrize("env, needle", [
    ({"CHAINTABLES_KMS_KEY_ARN": KEY_ARN}, "both CHAINTABLES_KMS_KEY_ARN and CHAINTABLES_RETENTION_DAYS"),
    ({"CHAINTABLES_RETENTION_DAYS": "1"}, "both CHAINTABLES_KMS_KEY_ARN and CHAINTABLES_RETENTION_DAYS"),
    ({"CHAINTABLES_KMS_KEY_ARN": "alias/x", "CHAINTABLES_RETENTION_DAYS": "1"}, "must be a key ARN"),
    ({"CHAINTABLES_KMS_KEY_ARN": KEY_ARN, "CHAINTABLES_RETENTION_DAYS": "0"}, "positive integer"),
    ({"CHAINTABLES_KMS_KEY_ARN": KEY_ARN, "CHAINTABLES_RETENTION_DAYS": "1.5"}, "positive integer"),
])
def test_half_or_bad_configuration_raises(env, needle):
    with pytest.raises(gw.ConfigError, match=needle):
        gw.lock_from_environ(env)
