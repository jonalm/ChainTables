"""The policy config: shape, glob matching, and the errors a bad file raises at cold start."""

import json

import pytest

import handler as gw
from tests.conftest import ACCOUNT, POLICY

OTHER_ACCOUNT = "444455556666"
SSO_ROLE = "AWSReservedSSO_chaintables-writer_a1b2c3d4e5f6"


def sso(name, account=ACCOUNT, role=SSO_ROLE):
    return gw.Caller(account=account, role=role, name=name)


def iam_user(name, account=ACCOUNT):
    return gw.Caller(account=account, role=None, name=name)


@pytest.fixture
def policy():
    return gw.Policy.from_dict(POLICY)


@pytest.fixture
def pinned():
    return gw.Policy.from_dict({"format_version": 1, "rules": [
        {"prefix": "teams/alpha", "writers": ["alice@example.com"],
         "accounts": [ACCOUNT], "roles": ["AWSReservedSSO_chaintables-writer_*"]},
        {"prefix": "teams/beta", "writers": ["bob@example.com"], "accounts": [ACCOUNT]},
    ]})


def test_exact_prefix_rule_allows_listed_names_only(policy):
    assert policy.allows(sso("alice@example.com"), "teams/alpha")
    assert policy.allows(sso("bob@example.com"), "teams/alpha")
    assert not policy.allows(sso("mallory@example.com"), "teams/alpha")
    assert not policy.allows(sso("alice@example.com"), "teams/beta")


def test_glob_prefix_matches_across_slashes(policy):
    assert policy.allows(sso("carol@example.com"), "teams/beta")
    assert policy.allows(sso("carol@example.com"), "teams/beta/sub")
    assert not policy.allows(sso("carol@example.com"), "other/beta")


def test_empty_prefix_rule_is_the_bucket_root_only(policy):
    assert policy.allows(iam_user("root-writer"), "")
    assert not policy.allows(iam_user("root-writer"), "teams/alpha")


def test_name_match_is_case_sensitive(policy):
    assert not policy.allows(sso("Alice@example.com"), "teams/alpha")


def test_unpinned_rule_admits_the_name_from_any_account_and_principal_kind(policy):
    assert policy.allows(sso("alice@example.com", account=OTHER_ACCOUNT, role="anything"), "teams/alpha")
    assert policy.allows(iam_user("alice@example.com", account=OTHER_ACCOUNT), "teams/alpha")


def test_account_pin_refuses_the_name_from_another_account(pinned):
    assert pinned.allows(sso("bob@example.com"), "teams/beta")
    assert pinned.allows(iam_user("bob@example.com"), "teams/beta")
    assert not pinned.allows(sso("bob@example.com", account=OTHER_ACCOUNT), "teams/beta")


def test_role_pin_refuses_a_role_outside_its_globs_and_every_iam_user(pinned):
    assert pinned.allows(sso("alice@example.com"), "teams/alpha")
    assert not pinned.allows(sso("alice@example.com", role="chaintables-writer"), "teams/alpha")
    assert not pinned.allows(sso("alice@example.com", role="AWSReservedSSO_admin_a1b2"), "teams/alpha")
    assert not pinned.allows(iam_user("alice@example.com"), "teams/alpha")
    assert not pinned.allows(sso("alice@example.com", account=OTHER_ACCOUNT), "teams/alpha")


def test_role_glob_is_case_sensitive(pinned):
    assert not pinned.allows(sso("alice@example.com", role="awsreservedsso_chaintables-writer_a1b2"), "teams/alpha")


def test_rules_are_alternatives_so_a_pinned_and_an_unpinned_rule_widen(pinned):
    widened = gw.Policy(pinned.rules + (gw.Rule("teams/alpha", frozenset({"alice@example.com"})),))
    assert widened.allows(iam_user("alice@example.com", account=OTHER_ACCOUNT), "teams/alpha")


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
    ({"format_version": 1, "rules": [{"prefix": "teams/?", "writers": ["a"]}]}, "'*' is the only wildcard"),
    ({"format_version": 1, "rules": [{"prefix": "teams/[ab]", "writers": ["a"]}]}, "'*' is the only wildcard"),
    ({"format_version": 1, "rules": [{"prefix": "teams]", "writers": ["a"]}]}, "'*' is the only wildcard"),
    ({"format_version": 1, "rules": [{"prefix": "a", "writers": [], "users": []}]}, "optionally 'accounts' and 'roles'"),
    ({"format_version": 1, "rules": [{"prefix": "a", "writers": [], "accounts": []}]}, "non-empty list of 12-digit"),
    ({"format_version": 1, "rules": [{"prefix": "a", "writers": [], "accounts": "111122223333"}]}, "12-digit"),
    ({"format_version": 1, "rules": [{"prefix": "a", "writers": [], "accounts": [111122223333]}]}, "12-digit"),
    ({"format_version": 1, "rules": [{"prefix": "a", "writers": [], "accounts": ["11112222333"]}]}, "12-digit"),
    ({"format_version": 1, "rules": [{"prefix": "a", "writers": [], "accounts": [ACCOUNT], "roles": []}]},
     "non-empty list of role-name globs"),
    ({"format_version": 1, "rules": [{"prefix": "a", "writers": [], "accounts": [ACCOUNT], "roles": "r"}]},
     "role-name globs"),
    ({"format_version": 1, "rules": [{"prefix": "a", "writers": [], "accounts": [ACCOUNT],
                                      "roles": [f"arn:aws:iam::{ACCOUNT}:role/r"]}]}, "never a role ARN or path"),
    ({"format_version": 1, "rules": [{"prefix": "a", "writers": [], "accounts": [ACCOUNT],
                                      "roles": ["aws-reserved/sso.amazonaws.com/r"]}]}, "never a role ARN or path"),
    ({"format_version": 1, "rules": [{"prefix": "a", "writers": [], "accounts": [ACCOUNT], "roles": ["r?"]}]},
     "'\\*' as the only wildcard"),
    ({"format_version": 1, "rules": [{"prefix": "a", "writers": [], "roles": ["r"]}]}, "'roles' without 'accounts'"),
])
def test_malformed_policy_raises_policy_error(doc, needle):
    with pytest.raises(gw.PolicyError, match=needle.replace("[", r"\[").replace("]", r"\]")):
        gw.Policy.from_dict(doc)


def test_policy_file_that_is_not_json_raises_policy_error(tmp_path):
    p = tmp_path / "policy.json"
    p.write_text("{not json")
    with pytest.raises(gw.PolicyError, match="not JSON"):
        gw.Policy.from_file(p)
