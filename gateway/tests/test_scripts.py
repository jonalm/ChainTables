"""The deployment scripts, offline: `setup-locked-bucket.sh --print-policies` makes no AWS call,
so the policies it would apply are checked here statement by statement; `deploy.sh` runs
against a fake `aws` on PATH that logs every call."""

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


# A fake AWS CLI: logs its argv one call per line (arguments NUL-separated), answers what
# deploy.sh reads, and reports an existing bucket, role, function and URL, plus one grant
# from an earlier deployment that the run must remove.
FAKE_AWS = r"""#!/usr/bin/env bash
printf '%s\0' "$@" >> "$FAKE_AWS_LOG"; printf '\n' >> "$FAKE_AWS_LOG"
case "$1 $2" in
    "sts get-caller-identity") case "$*" in *Account*) echo 111122223333 ;; *) echo arn:aws:iam::111122223333:user/admin ;; esac ;;
    "lambda get-function-url-config") case "$*" in *AuthType*) echo AWS_IAM ;; *) echo https://abc.lambda-url.eu-north-1.on.aws/ ;; esac ;;
    "lambda get-policy") echo '{"Statement":[{"Sid":"chaintables-writer-1-invoke"},{"Sid":"someone-else"}]}' ;;
esac
"""


def test_deploy_grants_writers_invoke_only_via_the_function_url(tmp_path):
    (tmp_path / "aws").write_text(FAKE_AWS)
    (tmp_path / "aws").chmod(0o755)
    (tmp_path / "gw.zip").write_bytes(b"zip")
    log = tmp_path / "log"
    writers = ["arn:aws:iam::444455556666:role/w1", "arn:aws:iam::444455556666:user/w2"]
    subprocess.run(
        ["bash", os.path.join(HERE, "deploy.sh"), "--bucket", "bkt", "--function", "gw", "--region", "eu-north-1",
         "--role", "gw-role", "--zip", str(tmp_path / "gw.zip"), "--no-smoke",
         *[a for w in writers for a in ("--writer", w)]],
        check=True, capture_output=True, text=True,
        env={**os.environ, "PATH": f"{tmp_path}:{os.environ['PATH']}", "FAKE_AWS_LOG": str(log)},
    )
    calls = [line.split("\0")[:-1] for line in log.read_text().splitlines()]
    removed = [c for c in calls if c[:2] == ["lambda", "remove-permission"]]
    assert removed == [["lambda", "remove-permission", "--function-name", "gw", "--statement-id", "chaintables-writer-1-invoke"]]
    grants = [c for c in calls if c[:2] == ["lambda", "add-permission"]]
    assert len(grants) == 2 * len(writers)
    for c in grants:
        action, principal = c[c.index("--action") + 1], c[c.index("--principal") + 1]
        assert principal in writers
        if action == "lambda:InvokeFunctionUrl":
            assert c[c.index("--function-url-auth-type") + 1] == "AWS_IAM"
        else:
            # unconditioned, a writer could call the Invoke API with a forged authorizer (#68)
            assert action == "lambda:InvokeFunction" and "--invoked-via-function-url" in c
