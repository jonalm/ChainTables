"""Throwaway Lambda for the ADR-0046 probe: signs presigned URLs and POST forms under the
gateway's execution role, with the boto3 the gateway bundles. Never deployed as the gateway;
attachment_probe.py deletes it when each command ends."""
import os, time
import boto3, botocore
from botocore.config import Config

INIT = time.time()
s3 = boto3.client("s3", config=Config(s3={"addressing_style": "virtual", "us_east_1_regional_endpoint": "regional"}))  # regional host, as the gateway's


def sign(p):
    if p["method"] == "post":  # a browser-form POST: {"url", "fields"}
        fields = p["fields"]
        return s3.generate_presigned_post(p["bucket"], p["key"], Fields=fields,
                                          Conditions=[{k: v} for k, v in fields.items()], ExpiresIn=p["expires"])
    if p["method"] == "put_object_retention":
        # A presigned S3 URL signs UNSIGNED-PAYLOAD, so the caller sends the XML body. Left in,
        # botocore's presigner tries to move the body into the query as JSON. S3 refuses the
        # caller's Content-MD5 and Content-Type unsigned, so the caller names them in "headers".
        headers = p["headers"]

        def without_body(request, **_):
            request.data = b""
            for k, v in headers.items():
                request.headers[k] = v

        event = "before-sign.s3.PutObjectRetention"
        s3.meta.events.register(event, without_body, unique_id="probe-retention")
        try:
            return s3.generate_presigned_url(p["method"], Params=p["params"], ExpiresIn=p["expires"])
        finally:
            s3.meta.events.unregister(event, unique_id="probe-retention")
    return s3.generate_presigned_url(p["method"], Params=p["params"], ExpiresIn=p["expires"])


def handler(event, context):
    return {"urls": [sign(p) for p in event["presign"]],
            "init": INIT, "now": time.time(), "botocore": botocore.__version__,
            "access_key": os.environ["AWS_ACCESS_KEY_ID"]}
