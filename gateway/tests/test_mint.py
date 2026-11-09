"""The mint route, `POST /mint?key=<attachment key>&size=<bytes>` (ADR-0046): the checks in
contract order, the present path (retention extended on a locked bucket), the absent path (a
presigned PUT and the exact headers to send), the URL lifetime and its cap."""

import base64
import hashlib
from datetime import datetime, timedelta, timezone
from urllib.parse import parse_qs, quote, urlsplit

import pytest
from botocore.exceptions import EndpointConnectionError

import handler as gw
from tests.conftest import ACCOUNT, BUCKET, POLICY, StubbedS3, event, parse

H = hashlib.sha256(b"hello").hexdigest()
KEY = f"teams/alpha/_attachments/{H}"
CHECKSUM = base64.b64encode(bytes.fromhex(H)).decode("ascii")
GIB5 = 5 * 1024 ** 3

NOW = datetime(2026, 9, 15, 12, 30, 45, 123456, tzinfo=timezone.utc)
NOW_S = NOW.replace(microsecond=0)
YOUNG = NOW - timedelta(hours=1)  # the execution environment's start: cap = 12 h - 1 h - 1 h = 10 h

KEY_ARN = "arn:aws:kms:eu-north-1:111122223333:key/9e5dac29-4bec-4c0a-be9c-b720b8013da9"
LOCK = gw.Lock(kms_key_arn=KEY_ARN, retention_days=1, now=lambda: NOW)

MINT_POLICY = {"format_version": 1, "rules": POLICY["rules"] + [
    {"prefix": "teams/alpha/_attachments", "writers": ["dave@example.com"]}]}


def arn(name):
    return f"arn:aws:sts::{ACCOUNT}:assumed-role/AWSReservedSSO_chaintables-writer_a1b2/{name}"


def mint_event(key=KEY, size="5", user_arn=arn("alice@example.com"), method="POST", path="/mint", body=b""):
    q = {k: v for k, v in (("key", key), ("size", size)) if v is not None}
    ev = event(key=key, body=body, user_arn=user_arn, method=method, path=path, query=q,
               raw_query="&".join(f"{k}={quote(v, safe='')}" for k, v in q.items()))
    if body == b"":
        ev.pop("body")
        ev["isBase64Encoded"] = False
    return ev


def make(s3, lock=None, started=YOUNG):
    return gw.Gateway(policy=gw.Policy.from_dict(MINT_POLICY), bucket=BUCKET, s3=s3.client, lock=lock,
                      now=lambda: NOW, started=started)


@pytest.fixture
def plain(s3):
    return make(s3)


@pytest.fixture
def locked(s3):
    return make(s3, lock=LOCK)


def lifetime(size):
    return 900 + -(-size // (1024 * 1024))


def iso(t):
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


def signed(url):
    return set(parse_qs(urlsplit(url).query)["X-Amz-SignedHeaders"][0].split(";"))


BASE_HEADERS = {"content-type": "application/octet-stream", "content-length": "5", "if-none-match": "*",
                "x-amz-checksum-sha256": CHECKSUM, "x-amz-tagging": "chaintables=attachment"}


# --- the absent path: a minted URL ---------------------------------------------------------

def test_absent_attachment_is_minted_a_url_for_its_key_on_the_regional_host(plain, s3):
    s3.head_absent(KEY)
    status, out = parse(plain.handle(mint_event()))
    assert (status, out["code"]) == (200, "minted")
    u = urlsplit(out["url"])
    assert (u.scheme, u.netloc, u.path) == ("https", f"{BUCKET}.s3.eu-north-1.amazonaws.com", "/" + KEY)
    assert parse_qs(u.query)["X-Amz-Expires"] == [str(lifetime(5))]
    assert out["expires"] == iso(NOW_S + timedelta(seconds=lifetime(5)))
    assert "retain_until" not in out


def test_minted_headers_are_exactly_the_signed_ones_with_the_base64_checksum(plain, s3):
    s3.head_absent(KEY)
    _, out = parse(plain.handle(mint_event()))
    assert out["headers"] == BASE_HEADERS
    assert set(out["headers"]) == signed(out["url"]) - {"host"}


def test_locked_mint_adds_encryption_and_retention_past_the_margin(locked, s3):
    s3.head_absent(KEY)
    _, out = parse(locked.handle(mint_event()))
    until = NOW_S + timedelta(days=1) + timedelta(seconds=lifetime(5)) + timedelta(days=1)
    assert out["headers"] == {**BASE_HEADERS,
                              "x-amz-server-side-encryption": "aws:kms",
                              "x-amz-server-side-encryption-aws-kms-key-id": KEY_ARN,
                              "x-amz-server-side-encryption-bucket-key-enabled": "true",
                              "x-amz-object-lock-mode": "COMPLIANCE",
                              "x-amz-object-lock-retain-until-date": iso(until)}
    assert set(out["headers"]) == signed(out["url"]) - {"host"}
    assert out["retain_until"] == iso(until)


def test_an_attachment_at_the_bucket_root_is_checked_against_the_root_rule(s3):
    key = f"_attachments/{H}"
    s3.head_absent(key)
    status, out = parse(make(s3).handle(mint_event(key=key, user_arn=arn("root-writer"))))
    assert (status, out["code"]) == (200, "minted")
    assert urlsplit(out["url"]).path == "/" + key


def test_a_mint_is_logged_with_caller_size_and_expiry(plain, s3, caplog):
    s3.head_absent(KEY)
    plain.handle(mint_event())
    exp = iso(NOW_S + timedelta(seconds=lifetime(5)))
    assert f"minted {KEY} by alice@example.com (5 bytes, expires {exp})" in caplog.messages


def test_a_global_host_is_a_deployment_bug_not_a_url():
    import boto3
    client = boto3.client("s3", region_name="eu-north-1", aws_access_key_id="x", aws_secret_access_key="y")

    class Absent:
        def head_object(self, **kw):
            from botocore.exceptions import ClientError
            raise ClientError({"Error": {"Code": "404"}, "ResponseMetadata": {"HTTPStatusCode": 404}}, "HeadObject")

        def __getattr__(self, name):
            return getattr(client, name)

    g = gw.Gateway(policy=gw.Policy.from_dict(MINT_POLICY), bucket=BUCKET, s3=Absent(), now=lambda: NOW,
                   started=YOUNG)
    with pytest.raises(RuntimeError, match="addressing_style"):
        g.handle(mint_event())


@pytest.mark.parametrize("region", ["eu-north-1", "us-east-1"])
def test_the_deployed_client_presigns_on_the_regional_host(monkeypatch, region):
    # us-east-1 is the case that matters: there botocore's default is the global host
    monkeypatch.setenv("AWS_DEFAULT_REGION", region)
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "AKIATEST")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "secret")
    client = gw._s3_client()
    url = client.generate_presigned_url("put_object", Params={"Bucket": "bkt", "Key": KEY}, ExpiresIn=900)
    assert urlsplit(url).netloc == f"bkt.s3.{region}.amazonaws.com"


# --- the URL's lifetime and its cap ---------------------------------------------------------

@pytest.mark.parametrize("size, seconds", [
    ("0", 900),
    ("1", 901),
    (str(1024 * 1024), 901),
    (str(1024 * 1024 + 1), 902),
    (str(GIB5), 900 + 5120),
])
def test_lifetime_is_15_minutes_plus_the_size_at_1_mib_per_second(plain, s3, size, seconds):
    s3.head_absent(KEY)
    _, out = parse(plain.handle(mint_event(size=size)))
    assert parse_qs(urlsplit(out["url"]).query)["X-Amz-Expires"] == [str(seconds)]


def test_lifetime_is_capped_at_12_hours_less_the_environments_age_less_1_hour(s3):
    g = make(s3, started=NOW - timedelta(hours=10, minutes=30))  # cap 30 min, under the 100 min wanted
    s3.head_absent(KEY)
    _, out = parse(g.handle(mint_event(size=str(GIB5))))
    assert parse_qs(urlsplit(out["url"]).query)["X-Amz-Expires"] == ["1800"]
    assert out["expires"] == iso(NOW_S + timedelta(seconds=1800))


def test_a_cap_of_exactly_15_minutes_still_mints(s3):
    g = make(s3, started=NOW - timedelta(hours=10, minutes=45))
    s3.head_absent(KEY)
    status, out = parse(g.handle(mint_event(size=str(GIB5))))
    assert (status, out["code"]) == (200, "minted")
    assert parse_qs(urlsplit(out["url"]).query)["X-Amz-Expires"] == ["900"]


def test_a_cap_under_15_minutes_mints_nothing_and_says_retry(s3):
    g = make(s3, started=NOW - timedelta(hours=10, minutes=46))
    s3.head_absent(KEY)
    status, out = parse(g.handle(mint_event()))
    assert (status, out["code"]) == (503, "session_ending")
    assert "retry" in out["message"]
    assert "url" not in out


# --- the present path -----------------------------------------------------------------------

def test_present_attachment_on_a_plain_bucket_mints_nothing(plain, s3, caplog):
    s3.head_present(KEY)
    status, out = parse(plain.handle(mint_event()))
    assert (status, out["code"]) == (200, "present")
    assert not {"url", "headers", "retain_until"} & set(out)
    assert f"present {KEY} by alice@example.com (5 bytes)" in caplog.messages


def present_target(size=5):
    return NOW_S + timedelta(days=1) + timedelta(seconds=lifetime(size)) + timedelta(days=1)


def test_present_attachment_whose_retention_is_earlier_is_extended(locked, s3, caplog):
    s3.head_present(KEY, version="v7")
    s3.retention_is(KEY, NOW + timedelta(hours=3), version="v7")
    s3.retention_set(KEY, present_target(), version="v7")
    status, out = parse(locked.handle(mint_event()))
    assert (status, out["code"]) == (200, "present")
    assert out["retain_until"] == iso(present_target())
    assert f"present {KEY} by alice@example.com (5 bytes, retain-until {iso(present_target())}, extended)" in caplog.messages


def test_present_attachment_whose_retention_is_later_is_left_alone(locked, s3, caplog):
    later = present_target() + timedelta(days=30)
    s3.head_present(KEY)
    s3.retention_is(KEY, later)
    status, out = parse(locked.handle(mint_event()))
    assert (status, out["code"]) == (200, "present")
    assert out["retain_until"] == iso(later)
    assert f"present {KEY} by alice@example.com (5 bytes, retain-until {iso(later)}, already later)" in caplog.messages


def test_the_present_path_is_not_capped_by_the_session(s3):
    g = make(s3, lock=LOCK, started=NOW - timedelta(hours=11, minutes=59))
    s3.head_present(KEY)
    s3.retention_is(KEY, NOW)
    s3.retention_set(KEY, present_target(GIB5))
    status, out = parse(g.handle(mint_event(size=str(GIB5))))
    assert (status, out["code"]) == (200, "present")


# --- checks, first failure wins -------------------------------------------------------------

def test_another_method_on_mint_is_bad_request_naming_both_routes(plain):
    status, out = parse(plain.handle(mint_event(method="GET")))
    assert (status, out["code"]) == (400, "bad_request")
    assert "PUT /" in out["message"] and "POST /mint" in out["message"]


def test_mint_without_a_size_is_bad_request(plain):
    status, out = parse(plain.handle(mint_event(size=None)))
    assert (status, out["code"]) == (400, "bad_request")
    assert "size" in out["message"]


def test_mint_without_a_key_is_bad_request(plain):
    status, out = parse(plain.handle(mint_event(key=None)))
    assert (status, out["code"]) == (400, "bad_request")


def test_mint_with_a_body_is_bad_request(plain):
    status, out = parse(plain.handle(mint_event(body=b"bytes")))
    assert (status, out["code"]) == (400, "bad_request")
    assert "body" in out["message"]


def test_caller_not_allowed_on_the_attachments_chain_is_refused(plain):
    status, out = parse(plain.handle(mint_event(user_arn=arn("mallory@example.com"))))
    assert (status, out["code"]) == (403, "not_allowed")
    assert "'teams/alpha'" in out["message"]


def test_an_attachment_is_checked_against_its_chains_prefix_not_the_key_up_to_its_last_slash(plain):
    # dave writes the chain at `teams/alpha/_attachments`, which must not let him write chain `teams/alpha`'s attachments
    status, out = parse(plain.handle(mint_event(user_arn=arn("dave@example.com"))))
    assert (status, out["code"]) == (403, "not_allowed")


def test_a_malformed_attachment_key_is_checked_against_the_key_up_to_its_last_slash(plain):
    status, out = parse(plain.handle(mint_event(key=f"teams/alpha/_attachments/{H.upper()}")))
    assert (status, out["code"]) == (403, "not_allowed")
    assert "'teams/alpha/_attachments'" in out["message"]


def test_a_present_attachment_without_a_version_id_on_a_locked_bucket_is_s3_refused(locked, s3):
    # a locked bucket is versioned: no version id means the gateway fronts another bucket
    s3.stubber.add_response("head_object", {"ContentLength": 5}, {"Bucket": BUCKET, "Key": KEY})
    st, out = parse(locked.handle(mint_event()))
    assert (st, out["code"]) == (502, "s3_refused")
    assert "no version id" in out["message"]


def test_a_retention_not_in_compliance_mode_is_s3_refused(locked, s3):
    s3.head_present(KEY)
    s3.stubber.add_response("get_object_retention",
                            {"Retention": {"Mode": "GOVERNANCE", "RetainUntilDate": NOW}},
                            {"Bucket": BUCKET, "Key": KEY, "VersionId": "v1"})
    st, out = parse(locked.handle(mint_event()))
    assert (st, out["code"]) == (502, "s3_refused")
    assert "GOVERNANCE" in out["message"]


def test_policy_is_checked_before_the_key_shape(plain):
    status, out = parse(plain.handle(mint_event(key="teams/alpha/000000000003", user_arn=arn("mallory@example.com"))))
    assert (status, out["code"]) == (403, "not_allowed")


@pytest.mark.parametrize("key", [
    "teams/alpha/000000000003",                     # a slot
    f"teams/alpha/_attachments/{H.upper()}",        # uppercase hex
    f"teams/alpha/_attachments/{H[:-1]}",           # 63 characters
    f"teams/alpha/_attachments/{H}0",               # 65 characters
    f"teams/alpha/_attachments/{H}\n",
    "teams/alpha/_attachments",
])
def test_a_key_that_is_not_an_attachment_is_not_a_slot(plain, key):
    # carol's `teams/*` admits the prefix such a key is checked against, the key up to its last '/'
    status, out = parse(plain.handle(mint_event(key=key, user_arn=arn("carol@example.com"))))
    assert (status, out["code"]) == (400, "not_a_slot")
    assert "neither a slot nor an attachment" in out["message"]


@pytest.mark.parametrize("key", [
    f"teams/alpha/_attachments/{H}/_attachments/{H}",     # the chain teams/alpha/_attachments/<h>
    f"teams/alpha/_attachments/_attachments/{H}",         # the chain teams/alpha/_attachments
], ids=["under an attachment", "under _attachments"])
def test_an_attachment_of_a_chain_under_an_attachments_segment_is_not_a_slot(plain, key):
    # such a chain's key is also a "directory" of another chain's attachments (#92)
    status, out = parse(plain.handle(mint_event(key=key, user_arn=arn("carol@example.com"))))
    assert (status, out["code"]) == (400, "not_a_slot")
    assert "'_attachments', which is reserved for a chain's attachments" in out["message"]


@pytest.mark.parametrize("key, problem", [
    (f"teams/../_attachments/{H}", "names a directory relative to its parent"),
    (f"teams//_attachments/{H}", "neither a slot nor an attachment"),  # the key regex refuses a prefix ending in '/'
    (f"teams//x/_attachments/{H}", "is empty"),
    (f"teams/\uff41/_attachments/{H}", "contains '\uff41'"),   # fullwidth a
    (f"teams/\u0430/_attachments/{H}", "contains '\u0430'"),   # Cyrillic a
    (f"teams/\u00e9/_attachments/{H}", "contains '\u00e9'"),
])
def test_an_attachment_under_a_path_trick_is_not_a_slot(plain, key, problem):
    status, out = parse(plain.handle(mint_event(key=key, user_arn=arn("carol@example.com"))))
    assert (status, out["code"]) == (400, "not_a_slot")
    assert problem in out["message"]


def test_an_attachment_key_with_a_leading_slash_is_not_an_attachment(s3):
    # the chain would be "" (root rule) up to its '/'; the key regex refuses an empty first segment
    g = gw.Gateway(policy=gw.Policy.from_dict({"format_version": 1, "rules": [{"prefix": "*", "writers": ["w"]}]}),
                   bucket=BUCKET, s3=s3.client, now=lambda: NOW, started=YOUNG)
    status, out = parse(g.handle(mint_event(key=f"/teams/_attachments/{H}", user_arn=arn("w"))))
    assert (status, out["code"]) == (400, "not_a_slot")


def test_an_attachment_under_a_prefix_a_client_refuses_is_not_a_slot(plain):
    status, out = parse(plain.handle(mint_event(key=f"teams/X/_attachments/{H}", user_arn=arn("carol@example.com"))))
    assert (status, out["code"]) == (400, "not_a_slot")
    assert "contains 'X'" in out["message"]


@pytest.mark.parametrize("size", ["", "abc", "-1", "+5", " 5", "5.0", "1e3", "٣"])
def test_a_size_that_is_not_a_decimal_count_is_bad_request(plain, size):
    status, out = parse(plain.handle(mint_event(size=size)))
    assert (status, out["code"]) == (400, "bad_request")
    assert "size" in out["message"]


@pytest.mark.parametrize("size", ["9" * 5000, "0" * 12, "1" + "0" * 11], ids=["5000 nines", "12 zeros", "1e11"])
def test_a_size_of_more_than_11_digits_is_bad_request_before_it_is_parsed(plain, size):
    # past ~4300 digits int() raises ValueError (Python's integer-string limit), which would be a function error
    status, out = parse(plain.handle(mint_event(size=size)))
    assert (status, out["code"]) == (400, "bad_request")
    assert "11 digits" in out["message"]


def test_a_size_of_11_digits_with_leading_zeros_is_read(plain, s3):
    s3.head_absent(KEY)
    status, out = parse(plain.handle(mint_event(size="00000000005")))
    assert (status, out["code"]) == (200, "minted")
    assert out["headers"]["content-length"] == "5"


def test_a_size_over_5_gib_is_too_large(plain):
    status, out = parse(plain.handle(mint_event(size=str(GIB5 + 1))))
    assert (status, out["code"]) == (413, "too_large")
    assert str(GIB5 + 1) in out["message"] and str(GIB5) in out["message"]


# --- S3 failures ------------------------------------------------------------------------------

@pytest.mark.parametrize("status, code, reply", [
    (403, "AccessDenied", "s3_refused"),   # e.g. the role lacks s3:ListBucket, so an absent key is 403
    (500, "InternalError", "s3_error"),
])
def test_head_failure_is_mapped_as_for_the_put(plain, s3, status, code, reply):
    s3.head_fails(KEY, status, code)
    st, out = parse(plain.handle(mint_event()))
    assert (st, out["code"]) == (502, reply)
    assert code in out["message"]


def test_reading_the_retention_refused_is_s3_refused(locked, s3):
    s3.head_present(KEY)
    s3.retention_fails(KEY, 403, "AccessDenied")
    st, out = parse(locked.handle(mint_event()))
    assert (st, out["code"]) == (502, "s3_refused")
    assert "AccessDenied" in out["message"]


def test_extending_the_retention_failing_is_s3_error(locked, s3):
    s3.head_present(KEY)
    s3.retention_is(KEY, NOW)
    s3.retention_set_fails(KEY, present_target(), 503, "SlowDown")
    st, out = parse(locked.handle(mint_event()))
    assert (st, out["code"]) == (502, "s3_error")


@pytest.mark.parametrize("stored", [present_target(), present_target() + timedelta(seconds=7)], ids=["at", "past"])
def test_a_refused_extension_that_a_concurrent_touch_already_made_is_present(locked, s3, caplog, stored):
    # B's later PutObjectRetention lands first; COMPLIANCE refuses A's earlier date with 403
    s3.head_present(KEY)
    s3.retention_is(KEY, NOW)
    s3.retention_set_fails(KEY, present_target(), 403, "AccessDenied")
    s3.retention_is(KEY, stored)
    status, out = parse(locked.handle(mint_event()))
    assert (status, out["code"]) == (200, "present")
    assert out["retain_until"] == iso(stored)
    assert (f"present {KEY} by alice@example.com (5 bytes, retain-until {iso(stored)}, already later after a "
            "refused extension)") in caplog.messages


def test_a_refused_extension_still_short_of_the_target_is_s3_refused(locked, s3):
    s3.head_present(KEY)
    s3.retention_is(KEY, NOW)
    s3.retention_set_fails(KEY, present_target(), 403, "AccessDenied")
    s3.retention_is(KEY, present_target() - timedelta(seconds=1))
    st, out = parse(locked.handle(mint_event()))
    assert (st, out["code"]) == (502, "s3_refused")
    assert "AccessDenied" in out["message"] and "PutObjectRetention" in out["message"]


def test_a_refused_extension_whose_reread_fails_is_mapped_as_that_failure(locked, s3):
    s3.head_present(KEY)
    s3.retention_is(KEY, NOW)
    s3.retention_set_fails(KEY, present_target(), 403, "AccessDenied")
    s3.retention_fails(KEY, 500, "InternalError")
    st, out = parse(locked.handle(mint_event()))
    assert (st, out["code"]) == (502, "s3_error")
    assert "GetObjectRetention" in out["message"]


def test_transport_failure_on_head_is_s3_error():
    class Down:
        def head_object(self, **kw):
            raise EndpointConnectionError(endpoint_url="https://s3.example")

    g = gw.Gateway(policy=gw.Policy.from_dict(MINT_POLICY), bucket=BUCKET, s3=Down(), now=lambda: NOW, started=YOUNG)
    st, out = parse(g.handle(mint_event()))
    assert (st, out["code"]) == (502, "s3_error")


# --- an attachment key on the slot route --------------------------------------------------

def test_an_attachment_key_put_to_the_slot_route_is_not_a_slot_and_names_the_mint_route(plain):
    status, out = parse(plain.handle(event(key=KEY)))
    assert (status, out["code"]) == (400, "not_a_slot")
    assert "POST /mint" in out["message"]


def test_an_attachment_key_on_the_slot_route_is_checked_against_its_chains_prefix(plain):
    status, out = parse(plain.handle(event(key=KEY, user_arn=arn("dave@example.com"))))
    assert (status, out["code"]) == (403, "not_allowed")


# --- the environment's start --------------------------------------------------------------

def test_the_environments_start_is_recorded_at_import_and_is_the_default():
    assert gw.ENVIRONMENT_START.tzinfo is not None
    g = gw.Gateway(policy=gw.Policy(()), bucket=BUCKET, s3=object())
    assert g.started == gw.ENVIRONMENT_START
