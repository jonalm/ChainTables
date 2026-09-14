"""The Lambda entry point: configuration from the environment, read once and cached."""

import json

import pytest

import handler as gw
from tests.conftest import BUCKET, POLICY, StubbedS3, event, parse, record


def test_missing_bucket_variable_raises(tmp_path):
    with pytest.raises(gw.ConfigError, match="CHAINTABLES_BUCKET"):
        gw.configure({}, s3=object())


def test_missing_policy_file_raises_naming_the_path(tmp_path):
    env = {"CHAINTABLES_BUCKET": BUCKET, "CHAINTABLES_POLICY": str(tmp_path / "nope.json")}
    with pytest.raises(gw.PolicyError, match="nope.json"):
        gw.configure(env, s3=object())


def test_policy_path_defaults_to_policy_json_beside_the_handler(monkeypatch):
    seen = {}
    monkeypatch.setattr(gw.Policy, "from_file", classmethod(lambda cls, p: seen.setdefault("path", str(p)) and gw.Policy(())))
    gw.configure({"CHAINTABLES_BUCKET": BUCKET}, s3=object())
    assert seen["path"].endswith("/policy.json")
    assert seen["path"].rsplit("/", 1)[0] == gw.__file__.rsplit("/", 1)[0]


def test_handler_serves_the_configured_gateway(tmp_path, monkeypatch):
    (tmp_path / "policy.json").write_text(json.dumps(POLICY))
    stub = StubbedS3()
    monkeypatch.setenv("CHAINTABLES_BUCKET", BUCKET)
    monkeypatch.setenv("CHAINTABLES_POLICY", str(tmp_path / "policy.json"))
    monkeypatch.setattr(gw, "_gateway", None)
    monkeypatch.setattr(gw, "_s3_client", lambda: stub.client)
    body = record()
    stub.put_succeeds("teams/alpha/000000000003", body)
    status, out = parse(gw.handler(event(body=body), context=None))
    assert (status, out["code"]) == (200, "created")
    stub.assert_done()
    # cached: a second call must not re-read the environment
    monkeypatch.delenv("CHAINTABLES_BUCKET")
    status, out = parse(gw.handler(event(key="teams/alpha/_x"), context=None))
    assert (status, out["code"]) == (400, "not_a_slot")
