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
                      "DenyWrongKey", "DenyNoKeyHeader", "DenyNoRetainUntil", "DenyNotCompliance", "DenyNoLockMode",
                      "DenyDeleteMarkers"}
    assert s["GatewayPuts"]["Principal"]["AWS"] == "arn:aws:iam::111122223333:role/gw-role"
    assert s["OnlyTheGatewayPuts"]["Condition"] == {"ArnNotEquals": {"aws:PrincipalArn": "arn:aws:iam::111122223333:role/gw-role"}}
    assert s["DenyInsecureTransport"]["Condition"] == {"Bool": {"aws:SecureTransport": "false"}}
    assert s["DenyNotCompliance"]["Condition"] == {"StringNotEquals": {"s3:object-lock-mode": "COMPLIANCE"}}
    # a delete marker would hide a locked slot and let the gateway fill it again (#74)
    assert s["DenyDeleteMarkers"] == {"Sid": "DenyDeleteMarkers", "Effect": "Deny", "Principal": "*",
                                      "Action": "s3:DeleteObject", "Resource": "arn:aws:s3:::bkt/*"}
    assert all(s[sid]["Effect"] == "Deny" for sid in s if sid != "GatewayPuts")


def test_print_policies_without_a_required_argument_fails():
    r = subprocess.run(["bash", os.path.join(HERE, "setup-locked-bucket.sh"), "--print-policies"],
                       capture_output=True, text=True)
    assert r.returncode != 0 and "--account" in r.stderr


# A fake AWS CLI: logs its argv one call per line (arguments NUL-separated), answers what
# deploy.sh reads, and reports an existing bucket, role, function and URL, plus one grant
# from an earlier deployment that the run must remove. The bucket's Object Lock state and
# its policy come from FAKE_LOCK and FAKE_BUCKET_POLICY; unset, it has neither, and the
# fake fails as AWS does.
FAKE_AWS = r"""#!/usr/bin/env bash
printf '%s\0' "$@" >> "$FAKE_AWS_LOG"; printf '\n' >> "$FAKE_AWS_LOG"
case "$1 $2" in
    "sts get-caller-identity") case "$*" in *Account*) echo 111122223333 ;; *) echo arn:aws:iam::111122223333:user/admin ;; esac ;;
    "lambda get-function-url-config") case "$*" in *AuthType*) echo AWS_IAM ;; *) echo https://abc.lambda-url.eu-north-1.on.aws/ ;; esac ;;
    "lambda get-policy") echo '{"Statement":[{"Sid":"chaintables-writer-1-invoke"},{"Sid":"someone-else"}]}' ;;
    "s3api get-object-lock-configuration")
        [ -n "${FAKE_LOCK:-}" ] || { echo "An error occurred (ObjectLockConfigurationNotFoundError) when calling the GetObjectLockConfiguration operation" >&2; exit 254; }
        [ "$FAKE_LOCK" != denied ] || { echo "An error occurred (AccessDenied) when calling the GetObjectLockConfiguration operation" >&2; exit 254; }
        echo "$FAKE_LOCK" ;;
    "s3api get-bucket-policy")
        [ -n "${FAKE_BUCKET_POLICY:-}" ] || { echo "An error occurred (NoSuchBucketPolicy) when calling the GetBucketPolicy operation" >&2; exit 254; }
        echo "$FAKE_BUCKET_POLICY" ;;
esac
"""

LOCK_ENV = ["--env", "CHAINTABLES_KMS_KEY_ARN=arn:aws:kms:eu-north-1:111122223333:key/k",
            "--env", "CHAINTABLES_RETENTION_DAYS=7"]


def run_deploy(tmp_path, *args, lock="", bucket_policy=""):
    """deploy.sh against the fake: returns the completed process and the logged calls."""
    (tmp_path / "aws").write_text(FAKE_AWS)
    (tmp_path / "aws").chmod(0o755)
    (tmp_path / "gw.zip").write_bytes(b"zip")
    log = tmp_path / "log"
    log.write_text("")
    r = subprocess.run(
        ["bash", os.path.join(HERE, "deploy.sh"), "--bucket", "bkt", "--function", "gw", "--region", "eu-north-1",
         "--role", "gw-role", "--zip", str(tmp_path / "gw.zip"), "--no-smoke", *args],
        capture_output=True, text=True,
        env={**os.environ, "PATH": f"{tmp_path}:{os.environ['PATH']}", "FAKE_AWS_LOG": str(log),
             "FAKE_LOCK": lock, "FAKE_BUCKET_POLICY": bucket_policy},
    )
    return r, [line.split("\0")[:-1] for line in log.read_text().splitlines()]


def put_policy(calls):
    (put,) = [c for c in calls if c[:2] == ["s3api", "put-bucket-policy"]]
    return json.loads(put[put.index("--policy") + 1])


def mutations(calls):
    reads = ("get-", "head-", "list-", "wait")
    return [c for c in calls if c[0] != "sts" and not c[1].startswith(reads)]


def test_deploy_grants_writers_invoke_only_via_the_function_url(tmp_path):
    writers = ["arn:aws:iam::444455556666:role/w1", "arn:aws:iam::444455556666:user/w2"]
    r, calls = run_deploy(tmp_path, *[a for w in writers for a in ("--writer", w)])
    assert r.returncode == 0, r.stderr
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


# Re-running deploy.sh on its own must not turn a locked bucket back into a plain one (#69, ADR-0037).

def locked_policy():
    """The bucket policy setup-locked-bucket.sh leaves: deploy.sh's statements plus the lock denies."""
    return print_policies()["bucket policy (bkt), merged onto what gateway/deploy.sh writes"]


def test_deploy_keeps_every_statement_it_does_not_own(tmp_path):
    before = locked_policy()
    before["Statement"].append({"Sid": "Read3", "Effect": "Allow", "Principal": {"AWS": "arn:aws:iam::1:role/gone"},
                                "Action": "s3:GetObject", "Resource": "arn:aws:s3:::bkt/*"})
    r, calls = run_deploy(tmp_path, *LOCK_ENV, "--reader", "arn:aws:iam::444455556666:role/r1",
                          lock="Enabled", bucket_policy=json.dumps(before))
    assert r.returncode == 0, r.stderr
    after = by_sid(put_policy(calls))
    lock_denies = {sid: st for sid, st in by_sid(before).items() if sid.startswith("Deny") and sid != "DenyInsecureTransport"}
    assert len(lock_denies) == 8
    for sid, st in lock_denies.items():
        assert after[sid] == st
    # its own statements are rewritten from the arguments: the stale Read3 is gone
    assert set(after) == set(lock_denies) | {"GatewayPuts", "OnlyTheGatewayPuts", "DenyInsecureTransport", "Read1"}
    assert after["Read1"]["Principal"] == {"AWS": "arn:aws:iam::444455556666:role/r1"}


def test_deploy_on_a_plain_bucket_without_a_policy_writes_its_own(tmp_path):
    r, calls = run_deploy(tmp_path)
    assert r.returncode == 0, r.stderr
    assert set(by_sid(put_policy(calls))) == {"GatewayPuts", "OnlyTheGatewayPuts", "DenyInsecureTransport"}


def test_deploy_keeps_the_lock_variables_in_the_function_environment(tmp_path):
    r, calls = run_deploy(tmp_path, *LOCK_ENV, lock="Enabled")
    assert r.returncode == 0, r.stderr
    (update,) = [c for c in calls if c[:2] == ["lambda", "update-function-configuration"]]
    assert update[update.index("--environment") + 1] == (
        "Variables={CHAINTABLES_BUCKET=bkt,CHAINTABLES_KMS_KEY_ARN=arn:aws:kms:eu-north-1:111122223333:key/k,"
        "CHAINTABLES_RETENTION_DAYS=7}")


@pytest.mark.parametrize("env", [[], LOCK_ENV[:2], LOCK_ENV[2:]])
def test_deploy_refuses_a_locked_bucket_without_both_lock_variables(tmp_path, env):
    r, calls = run_deploy(tmp_path, *env, lock="Enabled", bucket_policy=json.dumps(locked_policy()))
    assert r.returncode != 0
    assert "bucket bkt has Object Lock, so it is a locked bucket" in r.stderr
    assert "gateway/setup-locked-bucket.sh" in r.stderr
    assert mutations(calls) == []


def test_deploy_refuses_lock_variables_on_a_plain_bucket(tmp_path):
    r, calls = run_deploy(tmp_path, *LOCK_ENV)
    assert r.returncode != 0
    assert "bucket bkt has no Object Lock" in r.stderr and "S3 would refuse every locked put" in r.stderr
    assert mutations(calls) == []


def test_deploy_fails_when_the_lock_configuration_cannot_be_read(tmp_path):
    r, calls = run_deploy(tmp_path, lock="denied")
    assert r.returncode != 0
    assert "reading the Object Lock configuration of bkt failed" in r.stderr and "AccessDenied" in r.stderr
    assert mutations(calls) == []


def test_deploy_refuses_to_merge_a_statement_without_a_sid(tmp_path):
    r, calls = run_deploy(tmp_path, bucket_policy=json.dumps({"Statement": [{"Effect": "Deny"}]}))
    assert r.returncode != 0
    assert "has a statement without a Sid, which cannot be merged" in r.stderr
    assert not [c for c in calls if c[:2] == ["s3api", "put-bucket-policy"]]
