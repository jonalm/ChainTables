"""The ADR-0046 probe's signer Lambda: it must presign every request the `policy` command sends.

A presigned S3 URL signs UNSIGNED-PAYLOAD, so an operation with a request body (PutObjectRetention's
XML) is signed without it and the probe sends the body. botocore's presigner instead tries to move
a body into the query string as JSON, which raised JSONDecodeError in the live probe (#92). Then S3
refused the probe's unsigned Content-MD5 and Content-Type: "There were headers present in the
request which were not signed", so the probe names them and the signer signs them.
"""

import importlib.util
import pathlib
import urllib.parse

import pytest

PROBE = pathlib.Path(__file__).resolve().parent.parent / "probe" / "attachment_probe_lambda.py"


@pytest.fixture
def signer(monkeypatch):
    for k in ("AWS_PROFILE", "AWS_SESSION_TOKEN"):
        monkeypatch.delenv(k, raising=False)
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "AKIDEXAMPLE")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "secret")
    monkeypatch.setenv("AWS_DEFAULT_REGION", "eu-north-1")
    monkeypatch.setenv("AWS_CONFIG_FILE", "/dev/null")
    monkeypatch.setenv("AWS_SHARED_CREDENTIALS_FILE", "/dev/null")
    spec = importlib.util.spec_from_file_location("attachment_probe_lambda", PROBE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_put_object_retention_is_presigned_without_its_body(signer):
    sent = {"Content-MD5": "1B2M2Y8AsgTpgAmY7PhCfg==", "Content-Type": "application/xml"}
    url = signer.sign({"method": "put_object_retention", "expires": 900, "headers": sent, "params": {
        "Bucket": "probe-bucket", "Key": "attachment-probe/run/000000000002",
        "Retention": {"Mode": "COMPLIANCE", "RetainUntilDate": "2026-11-11T00:00:00Z"}}})
    u = urllib.parse.urlsplit(url)
    q = urllib.parse.parse_qs(u.query, keep_blank_values=True)
    assert u.netloc == "probe-bucket.s3.eu-north-1.amazonaws.com"
    assert u.path == "/attachment-probe/run/000000000002"
    assert "retention" in q
    assert q["X-Amz-SignedHeaders"] == ["content-md5;content-type;host"]
    assert not any(k.lower().startswith("x-amz-checksum") or k == "Retention" for k in q)


def test_the_retention_headers_do_not_leak_into_later_signatures(signer):
    signer.sign({"method": "put_object_retention", "expires": 900,
                 "headers": {"Content-MD5": "1B2M2Y8AsgTpgAmY7PhCfg==", "Content-Type": "application/xml"},
                 "params": {"Bucket": "probe-bucket", "Key": "a",
                            "Retention": {"Mode": "COMPLIANCE", "RetainUntilDate": "2026-11-11T00:00:00Z"}}})
    url = signer.sign({"method": "get_object", "expires": 900, "params": {"Bucket": "probe-bucket", "Key": "a"}})
    q = urllib.parse.parse_qs(urllib.parse.urlsplit(url).query)
    assert q["X-Amz-SignedHeaders"] == ["host"]
