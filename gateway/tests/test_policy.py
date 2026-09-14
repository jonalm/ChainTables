"""The policy config: shape, glob matching, and the errors a bad file raises at cold start."""

import json

import pytest

import handler as gw
from tests.conftest import POLICY


@pytest.fixture
def policy():
    return gw.Policy.from_dict(POLICY)


def test_exact_prefix_rule_allows_listed_names_only(policy):
    assert policy.allows("alice@example.com", "teams/alpha")
    assert policy.allows("bob@example.com", "teams/alpha")
    assert not policy.allows("mallory@example.com", "teams/alpha")
    assert not policy.allows("alice@example.com", "teams/beta")


def test_glob_prefix_matches_across_slashes(policy):
    assert policy.allows("carol@example.com", "teams/beta")
    assert policy.allows("carol@example.com", "teams/beta/sub")
    assert not policy.allows("carol@example.com", "other/beta")


def test_empty_prefix_rule_is_the_bucket_root_only(policy):
    assert policy.allows("root-writer", "")
    assert not policy.allows("root-writer", "teams/alpha")


def test_name_match_is_case_sensitive(policy):
    assert not policy.allows("Alice@example.com", "teams/alpha")


def test_file_round_trip(tmp_path):
    p = tmp_path / "policy.json"
    p.write_text(json.dumps(POLICY))
    assert gw.Policy.from_file(p) == gw.Policy.from_dict(POLICY)


@pytest.mark.parametrize("doc, needle", [
    ([], "not a JSON object"),
    ({"rules": []}, "format_version"),
    ({"format_version": 2, "rules": []}, "format_version is 2"),
    ({"format_version": 1, "rules": [], "extra": 1}, "unknown fields ['extra']"),
    ({"format_version": 1, "rules": {}}, "'rules' is not a list"),
    ({"format_version": 1, "rules": [{"prefix": "a"}]}, "rule 0"),
    ({"format_version": 1, "rules": [{"prefix": 1, "writers": []}]}, "'prefix' is not text"),
    ({"format_version": 1, "rules": [{"prefix": "a", "writers": [""]}]}, "non-empty names"),
    ({"format_version": 1, "rules": [{"prefix": "a", "writers": "alice"}]}, "list of non-empty names"),
])
def test_malformed_policy_raises_policy_error(doc, needle):
    with pytest.raises(gw.PolicyError, match=needle.replace("[", r"\[").replace("]", r"\]")):
        gw.Policy.from_dict(doc)


def test_policy_file_that_is_not_json_raises_policy_error(tmp_path):
    p = tmp_path / "policy.json"
    p.write_text("{not json")
    with pytest.raises(gw.PolicyError, match="not JSON"):
        gw.Policy.from_file(p)
