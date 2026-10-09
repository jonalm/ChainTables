"""The deployment scripts, offline: `setup-locked-bucket.sh --print-policies` makes no AWS call,
so the policies it would apply are checked here statement by statement."""

import json
import os
import subprocess

import pytest

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def print_policies(*extra):
    out = subprocess.run(
        ["bash", os.path.join(HERE, "setup-locked-bucket.sh"), "--print-policies", "--account", "111122223333",
         "--region", "eu-north-1", "--bucket", "bkt", "--role", "gw-role", "--alias", "alias/chaintables", *extra],
        check=True, capture_output=True, text=True,
    ).stdout
    sections, title, lines = {}, None, []
    for line in out.splitlines():
        if line.startswith("# "):
            if title is not None:
                sections[title] = json.loads("\n".join(lines))
            title, lines = line[2:], []
        else:
            lines.append(line)
    sections[title] = json.loads("\n".join(lines))
    return sections


@pytest.fixture(scope="module")
def policies():
    return print_policies("--decrypt-role", "arn:aws:iam::111122223333:role/auditor")


def by_sid(doc):
    return {s["Sid"]: s for s in doc["Statement"]}


def test_print_policies_prints_the_three_policies(policies):
    assert list(policies) == ["KMS key policy (alias/chaintables)", "execution role inline policy (gw-role)",
                              "bucket policy (bkt), merged onto what gateway/deploy.sh writes"]


def test_key_policy_lets_the_gateway_encrypt_and_the_readers_decrypt_through_s3_only(policies):
    s = by_sid(policies["KMS key policy (alias/chaintables)"])
    assert set(s) == {"RootAdministers", "GatewayEncrypts", "ReadersDecrypt"}
    assert s["GatewayEncrypts"]["Principal"]["AWS"] == "arn:aws:iam::111122223333:role/gw-role"
    assert "arn:aws:iam::111122223333:role/auditor" in s["ReadersDecrypt"]["Principal"]["AWS"]
    assert s["ReadersDecrypt"]["Action"] == "kms:Decrypt"
    for sid in ("GatewayEncrypts", "ReadersDecrypt"):
        assert s[sid]["Condition"] == {"StringEquals": {"kms:ViaService": "s3.eu-north-1.amazonaws.com"}}


def test_role_policy_grants_retention_on_the_bucket(policies):
    s = by_sid(policies["execution role inline policy (gw-role)"])
    assert s["LockSlots"] == {"Sid": "LockSlots", "Effect": "Allow", "Action": "s3:PutObjectRetention",
                              "Resource": "arn:aws:s3:::bkt/*"}


def test_bucket_policy_refuses_every_put_but_the_gateways_locked_kms_put(policies):
    s = by_sid(policies["bucket policy (bkt), merged onto what gateway/deploy.sh writes"])
    assert set(s) == {"GatewayPuts", "OnlyTheGatewayPuts", "DenyInsecureTransport", "DenyNotKms", "DenyNoSseHeader",
                      "DenyWrongKey", "DenyNoKeyHeader", "DenyNoRetainUntil", "DenyNotCompliance", "DenyNoLockMode"}
    assert s["GatewayPuts"]["Principal"]["AWS"] == "arn:aws:iam::111122223333:role/gw-role"
    assert s["OnlyTheGatewayPuts"]["Condition"] == {"ArnNotEquals": {"aws:PrincipalArn": "arn:aws:iam::111122223333:role/gw-role"}}
    assert s["DenyInsecureTransport"]["Condition"] == {"Bool": {"aws:SecureTransport": "false"}}
    assert s["DenyNotCompliance"]["Condition"] == {"StringNotEquals": {"s3:object-lock-mode": "COMPLIANCE"}}
    assert all(s[sid]["Effect"] == "Deny" for sid in s if sid != "GatewayPuts")


def test_print_policies_without_a_required_argument_fails():
    r = subprocess.run(["bash", os.path.join(HERE, "setup-locked-bucket.sh"), "--print-policies"],
                       capture_output=True, text=True)
    assert r.returncode != 0 and "--account" in r.stderr
