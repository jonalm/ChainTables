"""The gateway's checks, in contract order, and the S3 outcome mapping (issue #54 §5)."""

from tests.conftest import ACCOUNT, event, parse, record


# --- 1. policy ---------------------------------------------------------------------------

def test_caller_not_in_policy_for_prefix_is_refused(gateway):
    arn = f"arn:aws:sts::{ACCOUNT}:assumed-role/AWSReservedSSO_chaintables-writer_a1b2/mallory@example.com"
    status, body = parse(gateway.handle(event(user_arn=arn)))
    assert status == 403
    assert body["code"] == "not_allowed"
    assert "mallory@example.com" in body["message"]
    assert "teams/alpha" in body["message"]


def test_root_principal_is_refused_as_not_allowed(gateway):
    status, body = parse(gateway.handle(event(user_arn=f"arn:aws:iam::{ACCOUNT}:root")))
    assert status == 403
    assert body["code"] == "not_allowed"
    assert "neither an IAM user nor an assumed role" in body["message"]


def test_policy_is_checked_before_the_key_shape(gateway):
    # A stranger probing a reserved name learns nothing about the layout: refused at check 1.
    arn = f"arn:aws:sts::{ACCOUNT}:assumed-role/r/mallory@example.com"
    status, body = parse(gateway.handle(event(key="teams/alpha/_snapshots/x", user_arn=arn)))
    assert (status, body["code"]) == (403, "not_allowed")


# --- 2. slot key -------------------------------------------------------------------------

def test_reserved_name_under_an_allowed_prefix_is_not_a_slot(gateway):
    status, body = parse(gateway.handle(event(key="teams/alpha/_snapshots")))
    assert status == 400
    assert body["code"] == "not_a_slot"
    assert "teams/alpha/_snapshots" in body["message"]
    assert "12" in body["message"]


# --- 3–5. body and author ----------------------------------------------------------------

def test_body_that_is_not_cbor_is_refused(gateway):
    status, body = parse(gateway.handle(event(body=b"\xff\xff not cbor")))
    assert (status, body["code"]) == (400, "not_cbor_map")


def test_cbor_that_is_not_a_map_is_refused(gateway):
    import cbor2
    status, body = parse(gateway.handle(event(body=cbor2.dumps([1, 2, 3]))))
    assert (status, body["code"]) == (400, "not_cbor_map")
    assert "map" in body["message"]


def test_record_without_client_user_is_refused(gateway):
    status, body = parse(gateway.handle(event(body=record(user=None))))
    assert (status, body["code"]) == (400, "no_author")
    assert "client.user" in body["message"]


def test_record_with_empty_client_user_is_refused(gateway):
    status, body = parse(gateway.handle(event(body=record(user=""))))
    assert (status, body["code"]) == (400, "no_author")


def test_record_whose_client_is_not_a_map_is_refused_as_no_author(gateway):
    import cbor2
    status, body = parse(gateway.handle(event(body=cbor2.dumps({"client": "alice@example.com"}))))
    assert (status, body["code"]) == (400, "no_author")


def test_author_other_than_the_caller_is_refused(gateway):
    status, body = parse(gateway.handle(event(body=record(user="bob@example.com"))))
    assert (status, body["code"]) == (403, "author_mismatch")
    assert "bob@example.com" in body["message"] and "alice@example.com" in body["message"]


def test_author_comparison_is_case_sensitive(gateway):
    status, body = parse(gateway.handle(event(body=record(user="Alice@example.com"))))
    assert (status, body["code"]) == (403, "author_mismatch")


# --- 6. size ------------------------------------------------------------------------------

def test_record_over_4mib_is_refused_before_any_put(gateway):
    big = record(comment="x" * (4 * 1024 * 1024))
    assert len(big) > 4 * 1024 * 1024
    status, body = parse(gateway.handle(event(body=big)))
    assert (status, body["code"]) == (413, "too_large")
    assert str(len(big)) in body["message"] and "4194304" in body["message"]


# --- 7. the put and its outcome ----------------------------------------------------------

def test_allowed_author_fills_the_slot(gateway, s3):
    body = record()
    s3.put_succeeds("teams/alpha/000000000003", body)
    status, out = parse(gateway.handle(event(body=body)))
    assert (status, out["code"]) == (200, "created")


def test_record_of_exactly_4mib_is_accepted(gateway, s3):
    n = 4 * 1024 * 1024 - 200
    for _ in range(3):  # the text-string length header grows with n; converge on the exact size
        n += 4 * 1024 * 1024 - len(record(comment="x" * n))
    body = record(comment="x" * n)
    assert len(body) == 4 * 1024 * 1024
    s3.put_succeeds("teams/alpha/000000000003", body)
    status, out = parse(gateway.handle(event(body=body)))
    assert (status, out["code"]) == (200, "created")


def test_slot_already_taken_is_412(gateway, s3):
    body = record()
    s3.put_fails("teams/alpha/000000000003", body, 412, "PreconditionFailed")
    status, out = parse(gateway.handle(event(body=body)))
    assert (status, out["code"]) == (412, "slot_taken")


def test_concurrent_conditional_write_is_409(gateway, s3):
    body = record()
    s3.put_fails("teams/alpha/000000000003", body, 409, "ConditionalRequestConflict")
    status, out = parse(gateway.handle(event(body=body)))
    assert (status, out["code"]) == (409, "conflict")


def test_s3_server_error_is_502(gateway, s3):
    body = record()
    s3.put_fails("teams/alpha/000000000003", body, 503, "SlowDown")
    status, out = parse(gateway.handle(event(body=body)))
    assert (status, out["code"]) == (502, "s3_error")
    assert "503" in out["message"] and "SlowDown" in out["message"]


def test_s3_refusing_the_gateway_role_is_502_naming_the_cause(gateway, s3):
    # A misconfigured deployment (the execution role lacks PutObject) must surface, not hide.
    body = record()
    s3.put_fails("teams/alpha/000000000003", body, 403, "AccessDenied")
    status, out = parse(gateway.handle(event(body=body)))
    assert (status, out["code"]) == (502, "s3_error")
    assert "AccessDenied" in out["message"]


def test_transport_failure_to_s3_is_502():
    from botocore.exceptions import EndpointConnectionError
    import handler as gw
    from tests.conftest import BUCKET, POLICY

    class Down:
        def put_object(self, **kw):
            raise EndpointConnectionError(endpoint_url="https://s3.example")

    g = gw.Gateway(policy=gw.Policy.from_dict(POLICY), bucket=BUCKET, s3=Down())
    status, out = parse(g.handle(event()))
    assert (status, out["code"]) == (502, "s3_error")


# --- request shape (400 bad_request) -----------------------------------------------------

def test_method_other_than_put_is_bad_request(gateway):
    status, body = parse(gateway.handle(event(method="GET")))
    assert (status, body["code"]) == (400, "bad_request")
    assert "PUT" in body["message"]


def test_path_other_than_root_is_bad_request(gateway):
    status, body = parse(gateway.handle(event(path="/teams/alpha/000000000003")))
    assert (status, body["code"]) == (400, "bad_request")


def test_missing_key_is_bad_request(gateway):
    status, body = parse(gateway.handle(event(key=None)))
    assert (status, body["code"]) == (400, "bad_request")
    assert "key" in body["message"]


def test_key_is_read_from_the_raw_query_string_when_the_parsed_map_is_absent(gateway, s3):
    body = record()
    s3.put_succeeds("teams/alpha/000000000003", body)
    ev = event(body=body, raw_query="key=teams%2Falpha%2F000000000003", query={})
    assert "queryStringParameters" not in ev
    status, out = parse(gateway.handle(ev))
    assert (status, out["code"]) == (200, "created")


def test_unflagged_body_is_taken_verbatim_not_base64_decoded(gateway):
    # "hello world!" is valid base64 text; taking it verbatim yields not_cbor_map, decoding it
    # would have yielded something else.
    status, body = parse(gateway.handle(event(body=b"hello world!", base64_body=False)))
    assert (status, body["code"]) == (400, "not_cbor_map")


def test_body_flagged_base64_that_does_not_decode_is_bad_request(gateway):
    ev = event()
    ev["body"] = "not*base64"
    status, body = parse(gateway.handle(ev))
    assert (status, body["code"]) == (400, "bad_request")
    assert "base64" in body["message"]


def test_request_without_an_iam_authorizer_is_not_allowed(gateway):
    status, body = parse(gateway.handle(event(authorizer=None)))
    assert (status, body["code"]) == (403, "not_allowed")


def test_iam_user_with_a_path_is_named_by_its_last_segment(gateway, s3):
    body = record(user="alice@example.com")
    s3.put_succeeds("teams/alpha/000000000003", body)
    arn = f"arn:aws:iam::{ACCOUNT}:user/engineering/alice@example.com"
    status, out = parse(gateway.handle(event(body=body, user_arn=arn)))
    assert (status, out["code"]) == (200, "created")
