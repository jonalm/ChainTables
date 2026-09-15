"""Shared fixtures: a function-URL event builder, a policy, and a gateway over a stubbed S3.

The seam under test is `Gateway.handle(event) -> response` (the Lambda entry point
`handler` is a one-line adapter over it). S3 is a real boto3 client wrapped in botocore's
`Stubber`, so every test also checks the exact `put_object` parameters the gateway sends.
"""

import base64
import json
from urllib.parse import quote

import boto3
import cbor2
import pytest
from botocore.stub import Stubber

import handler as gw

ACCOUNT = "111122223333"
WRITER_ARN = f"arn:aws:sts::{ACCOUNT}:assumed-role/AWSReservedSSO_chaintables-writer_a1b2c3d4e5f6/alice@example.com"
BUCKET = "test-bucket"

POLICY = {
    "format_version": 1,
    "rules": [
        {"prefix": "teams/alpha", "writers": ["alice@example.com", "bob@example.com"]},
        {"prefix": "teams/*", "writers": ["carol@example.com"]},
        {"prefix": "", "writers": ["root-writer"]},
    ],
}


def record(user="alice@example.com", **extra):
    """A minimal record-shaped CBOR map: the gateway reads only `client.user`."""
    client = {"lib": "ChainTables 0.1.0", "julia": "1.11.0", "time_ms": 0}
    if user is not None:
        client["user"] = user
    return cbor2.dumps({"format_version": 1, "slot": 3, "client": client, **extra})


def event(
    key="teams/alpha/000000000003",
    body=None,
    user_arn=WRITER_ARN,
    method="PUT",
    path="/",
    base64_body=True,
    raw_query=None,
    query=None,
    authorizer="iam",
):
    """A Lambda function-URL event (API Gateway payload format 2.0 with `authorizer.iam`)."""
    if body is None:
        body = record()
    if base64_body:
        wire_body = base64.b64encode(body).decode("ascii")
    else:
        wire_body = body.decode("utf-8")
    if raw_query is None:
        raw_query = "" if key is None else "key=" + quote(key, safe="")
    if query is None:
        query = {} if key is None else {"key": key}
    ctx = {
        "accountId": ACCOUNT,
        "http": {"method": method, "path": path, "protocol": "HTTP/1.1", "sourceIp": "192.0.2.1"},
    }
    if authorizer == "iam":
        ctx["authorizer"] = {
            "iam": {
                "accessKey": "ASIAEXAMPLE",
                "accountId": ACCOUNT,
                "callerId": "AROAEXAMPLE:alice@example.com",
                "userArn": user_arn,
                "userId": "AROAEXAMPLE:alice@example.com",
            }
        }
    elif authorizer is None:
        ctx["authorizer"] = None
    ev = {
        "version": "2.0",
        "routeKey": "$default",
        "rawPath": path,
        "rawQueryString": raw_query,
        "headers": {"content-type": "application/cbor"},
        "requestContext": ctx,
        "body": wire_body,
        "isBase64Encoded": base64_body,
    }
    if query:
        ev["queryStringParameters"] = query
    return ev


class StubbedS3:
    """A boto3 S3 client under `Stubber`, with helpers for the outcomes the gateway maps."""

    def __init__(self):
        self.client = boto3.client("s3", region_name="eu-north-1",
                                   aws_access_key_id="x", aws_secret_access_key="y")
        self.stubber = Stubber(self.client)
        self.stubber.activate()

    def expect_put(self, key, body, **extra):
        return {"Bucket": BUCKET, "Key": key, "Body": body, "IfNoneMatch": "*",
                "ContentType": "application/cbor", **extra}

    def put_succeeds(self, key, body, **extra):
        self.stubber.add_response("put_object", {"ETag": '"abc"'}, self.expect_put(key, body, **extra))

    def put_fails(self, key, body, status, code, message="stubbed"):
        self.stubber.add_client_error("put_object", service_error_code=code,
                                      service_message=message, http_status_code=status,
                                      expected_params=self.expect_put(key, body))

    def assert_done(self):
        self.stubber.assert_no_pending_responses()


@pytest.fixture
def s3():
    stub = StubbedS3()
    yield stub
    stub.assert_done()


@pytest.fixture
def gateway(s3):
    return gw.Gateway(policy=gw.Policy.from_dict(POLICY), bucket=BUCKET, s3=s3.client)


def parse(response):
    """Status and decoded JSON body of a gateway response."""
    assert response["headers"]["content-type"] == "application/json"
    return response["statusCode"], json.loads(response["body"])
