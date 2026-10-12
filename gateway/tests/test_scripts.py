"""The deployment scripts, offline: `setup-locked-bucket.sh --print-policies` makes no AWS call,
so the policies it would apply are checked here statement by statement; `deploy.sh` runs
against a fake `aws` on PATH that logs every call."""

import json
import os
import shutil
import subprocess
import zipfile

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
# deploy.sh reads, and reports an existing bucket, role, function and URL. The bucket's
# Object Lock state, its policy and the function's resource policy come from FAKE_LOCK,
# FAKE_BUCKET_POLICY and FAKE_LAMBDA_POLICY; unset, it has none, and the fake fails as AWS
# does; `denied` fails as AWS does for a caller without the right.
FAKE_AWS = r"""#!/usr/bin/env bash
printf '%s\0' "$@" >> "$FAKE_AWS_LOG"; printf '\n' >> "$FAKE_AWS_LOG"
case "$1 $2" in
    "sts get-caller-identity") case "$*" in *Account*) echo 111122223333 ;; *) echo arn:aws:iam::111122223333:user/admin ;; esac ;;
    "lambda get-function-url-config") case "$*" in *AuthType*) echo AWS_IAM ;; *) echo https://abc.lambda-url.eu-north-1.on.aws/ ;; esac ;;
    "lambda get-policy")
        [ -n "${FAKE_LAMBDA_POLICY:-}" ] || { echo "An error occurred (ResourceNotFoundException) when calling the GetPolicy operation: The resource you requested does not exist." >&2; exit 254; }
        [ "$FAKE_LAMBDA_POLICY" != denied ] || { echo "An error occurred (AccessDeniedException) when calling the GetPolicy operation" >&2; exit 254; }
        echo "$FAKE_LAMBDA_POLICY" ;;
    "s3api get-object-lock-configuration")
        [ -n "${FAKE_LOCK:-}" ] || { echo "An error occurred (ObjectLockConfigurationNotFoundError) when calling the GetObjectLockConfiguration operation" >&2; exit 254; }
        [ "$FAKE_LOCK" != denied ] || { echo "An error occurred (AccessDenied) when calling the GetObjectLockConfiguration operation" >&2; exit 254; }
        echo "$FAKE_LOCK" ;;
    "s3api get-bucket-policy")
        [ -n "${FAKE_BUCKET_POLICY:-}" ] || { echo "An error occurred (NoSuchBucketPolicy) when calling the GetBucketPolicy operation" >&2; exit 254; }
        [ "$FAKE_BUCKET_POLICY" != denied ] || { echo "An error occurred (AccessDenied) when calling the GetBucketPolicy operation" >&2; exit 254; }
        echo "$FAKE_BUCKET_POLICY" ;;
esac
"""

LOCK_ENV = ["--env", "CHAINTABLES_KMS_KEY_ARN=arn:aws:kms:eu-north-1:111122223333:key/k",
            "--env", "CHAINTABLES_RETENTION_DAYS=7"]


def write_zip(path, handler_source=None):
    """A deployment zip holding handler.py: by default the repository's, as build.sh would; none if False."""
    if handler_source is None:
        with open(os.path.join(HERE, "handler.py"), "rb") as f:
            handler_source = f.read()
    with zipfile.ZipFile(path, "w") as z:
        if handler_source is not False:
            z.writestr("handler.py", handler_source)
        z.writestr("policy.json", "{}")


def run_deploy(tmp_path, *args, lock="", bucket_policy="", lambda_policy="", handler_source=None):
    """deploy.sh against the fake: returns the completed process and the logged calls."""
    (tmp_path / "aws").write_text(FAKE_AWS)
    (tmp_path / "aws").chmod(0o755)
    write_zip(tmp_path / "gw.zip", handler_source)
    log = tmp_path / "log"
    log.write_text("")
    r = subprocess.run(
        ["bash", os.path.join(HERE, "deploy.sh"), "--bucket", "bkt", "--function", "gw", "--region", "eu-north-1",
         "--role", "gw-role", "--zip", str(tmp_path / "gw.zip"), "--no-smoke", *args],
        capture_output=True, text=True,
        env={**os.environ, "PATH": f"{tmp_path}:{os.environ['PATH']}", "FAKE_AWS_LOG": str(log),
             "FAKE_LOCK": lock, "FAKE_BUCKET_POLICY": bucket_policy, "FAKE_LAMBDA_POLICY": lambda_policy},
    )
    return r, [line.split("\0")[:-1] for line in log.read_text().splitlines()]


def put_policy(calls):
    (put,) = [c for c in calls if c[:2] == ["s3api", "put-bucket-policy"]]
    return json.loads(put[put.index("--policy") + 1])


def mutations(calls):
    reads = ("get-", "head-", "list-", "wait")
    return [c for c in calls if c[0] != "sts" and not c[1].startswith(reads)]


def writer_grants(*principals, sids=None):
    """A function resource policy as an earlier deploy.sh left it, plus a statement it does not own."""
    sids = sids or [f"chaintables-writer-{i}" for i in range(1, len(principals) + 1)]
    st = [{"Sid": f"{sid}-{kind}", "Effect": "Allow", "Principal": {"AWS": p}}
          for sid, p in zip(sids, principals) for kind in ("url", "invoke")]
    return json.dumps({"Statement": st + [{"Sid": "someone-else", "Effect": "Allow",
                                           "Principal": {"Service": "events.amazonaws.com"}}]})


def test_deploy_grants_writers_invoke_only_via_the_function_url(tmp_path):
    writers = ["arn:aws:iam::444455556666:role/w1", "arn:aws:iam::444455556666:user/w2"]
    r, calls = run_deploy(tmp_path, *[a for w in writers for a in ("--writer", w)],
                          lambda_policy=writer_grants(writers[0]))
    assert r.returncode == 0, r.stderr
    removed = [c for c in calls if c[:2] == ["lambda", "remove-permission"]]
    assert removed == [["lambda", "remove-permission", "--function-name", "gw", "--statement-id", f"chaintables-writer-1-{k}"]
                       for k in ("url", "invoke")]
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


def test_deploy_refuses_a_zip_built_from_another_handler(tmp_path):
    r, calls = run_deploy(tmp_path, handler_source=b"# an older gateway\n")
    assert r.returncode != 0
    assert "the handler.py in zip" in r.stderr and "differs from" in r.stderr and "gateway/build.sh" in r.stderr
    assert mutations(calls) == []


def test_deploy_refuses_a_zip_without_a_handler(tmp_path):
    r, calls = run_deploy(tmp_path, handler_source=False)
    assert r.returncode != 0 and "holds no handler.py" in r.stderr
    assert mutations(calls) == []


# A grant's statement id is named by its principal (the first 8 hex digits of the SHA-256 of
# the ARN), so a redeploy adds what is missing before it removes anything: a writer that
# stays never loses its grant, not even for a moment.

W1, W2 = "arn:aws:iam::444455556666:role/w1", "arn:aws:iam::444455556666:user/w2"
W1_SID, W2_SID = "chaintables-writer-a260edbf", "chaintables-writer-4d2906b2"


def grant_calls(calls):
    return [(c[1], c[c.index("--statement-id") + 1]) for c in calls
            if c[:2] in (["lambda", "add-permission"], ["lambda", "remove-permission"])]


def test_deploy_adds_new_grants_before_it_removes_old_ones(tmp_path):
    r, calls = run_deploy(tmp_path, "--writer", W1, "--writer", W2, lambda_policy=writer_grants(W1))
    assert r.returncode == 0, r.stderr
    assert grant_calls(calls) == [("add-permission", f"{W1_SID}-url"), ("add-permission", f"{W1_SID}-invoke"),
                                  ("add-permission", f"{W2_SID}-url"), ("add-permission", f"{W2_SID}-invoke"),
                                  ("remove-permission", "chaintables-writer-1-url"),
                                  ("remove-permission", "chaintables-writer-1-invoke")]


def test_deploy_leaves_a_grant_it_would_make_again_in_place(tmp_path):
    r, calls = run_deploy(tmp_path, "--writer", W1, lambda_policy=writer_grants(W1, sids=[W1_SID]))
    assert r.returncode == 0, r.stderr
    assert grant_calls(calls) == []


# A grant is revoked only on purpose: a principal with a grant from an earlier deployment
# but missing from the arguments is a refusal, unless --revoke-unlisted says to drop it.

OLD_WRITER = "arn:aws:iam::444455556666:role/old-writer"
OLD_READER = "arn:aws:iam::444455556666:role/old-reader"


def read_grant(n, principal):
    return {"Sid": f"Read{n}", "Effect": "Allow", "Principal": {"AWS": principal},
            "Action": ["s3:GetObject", "s3:ListBucket"], "Resource": ["arn:aws:s3:::bkt", "arn:aws:s3:::bkt/*"]}


def test_deploy_refuses_to_drop_a_writer_it_was_not_given(tmp_path):
    r, calls = run_deploy(tmp_path, lambda_policy=writer_grants(OLD_WRITER))
    assert r.returncode != 0
    assert f"writer {OLD_WRITER}" in r.stderr and "--revoke-unlisted" in r.stderr
    assert mutations(calls) == []


def test_deploy_refuses_to_drop_a_reader_it_was_not_given(tmp_path):
    r, calls = run_deploy(tmp_path, "--writer", OLD_WRITER, lambda_policy=writer_grants(OLD_WRITER),
                          bucket_policy=json.dumps({"Statement": [read_grant(1, OLD_WRITER), read_grant(2, OLD_READER)]}))
    assert r.returncode != 0
    assert f"reader {OLD_READER}" in r.stderr and "--revoke-unlisted" in r.stderr
    assert OLD_WRITER not in r.stderr
    assert mutations(calls) == []


def test_deploy_drops_unlisted_grants_when_told_to(tmp_path):
    r, calls = run_deploy(tmp_path, "--revoke-unlisted", lambda_policy=writer_grants(OLD_WRITER),
                          bucket_policy=json.dumps({"Statement": [read_grant(1, OLD_READER)]}))
    assert r.returncode == 0, r.stderr
    assert not [c for c in calls if c[:2] == ["lambda", "add-permission"]]
    assert len([c for c in calls if c[:2] == ["lambda", "remove-permission"]]) == 2
    assert set(by_sid(put_policy(calls))) == {"GatewayPuts", "OnlyTheGatewayPuts", "DenyInsecureTransport"}


def test_deploy_fails_when_the_function_resource_policy_cannot_be_read(tmp_path):
    r, calls = run_deploy(tmp_path, lambda_policy="denied")
    assert r.returncode != 0
    assert "reading the resource policy of function gw failed" in r.stderr and "AccessDeniedException" in r.stderr
    assert mutations(calls) == []


def test_deploy_fails_when_the_bucket_policy_cannot_be_read(tmp_path):
    r, calls = run_deploy(tmp_path, bucket_policy="denied")
    assert r.returncode != 0
    assert "reading the bucket policy of bkt failed" in r.stderr and "AccessDenied" in r.stderr
    assert mutations(calls) == []


# Re-running deploy.sh on its own must not turn a locked bucket back into a plain one (#69, ADR-0037).

def locked_policy():
    """The bucket policy setup-locked-bucket.sh leaves: deploy.sh's statements plus the lock denies."""
    return print_policies()["bucket policy (bkt), merged onto what gateway/deploy.sh writes"]


def test_deploy_keeps_every_statement_it_does_not_own(tmp_path):
    before = locked_policy()
    before["Statement"].append({"Sid": "Read3", "Effect": "Allow", "Principal": {"AWS": "arn:aws:iam::1:role/gone"},
                                "Action": "s3:GetObject", "Resource": "arn:aws:s3:::bkt/*"})
    r, calls = run_deploy(tmp_path, *LOCK_ENV, "--reader", "arn:aws:iam::444455556666:role/r1", "--revoke-unlisted",
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


# build.sh checks the policy as the gateway will load it, before it resolves or installs
# anything: a fake `uv` on PATH passes `uv run` through and fails every other subcommand.

@pytest.mark.parametrize("doc, problem", [
    ("{not json", "is not JSON"),
    (json.dumps({"format_version": 1, "rules": [{"prefix": "teams/?", "writers": ["a"]}]}), "'*' is the only wildcard"),
])
def test_build_refuses_a_policy_the_gateway_would_refuse_before_installing_anything(tmp_path, doc, problem):
    real_uv = shutil.which("uv")
    (tmp_path / "uv").write_text(f'#!/usr/bin/env bash\n[ "$1" = run ] && exec {real_uv} "$@"\n'
                                 'echo "fake uv: $1 must not run" >&2; exit 99\n')
    (tmp_path / "uv").chmod(0o755)
    (tmp_path / "policy.json").write_text(doc)
    r = subprocess.run(["bash", os.path.join(HERE, "build.sh"), "--policy", str(tmp_path / "policy.json"),
                        "--out", str(tmp_path / "gw.zip")],
                       capture_output=True, text=True, env={**os.environ, "PATH": f"{tmp_path}:{os.environ['PATH']}"})
    assert r.returncode != 0
    assert problem in r.stderr and "fake uv" not in r.stderr
    assert not (tmp_path / "gw.zip").exists()
