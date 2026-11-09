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
    return s3.generate_presigned_url(p["method"], Params=p["params"], ExpiresIn=p["expires"])


def handler(event, context):
    return {"urls": [sign(p) for p in event["presign"]],
            "init": INIT, "now": time.time(), "botocore": botocore.__version__,
            "access_key": os.environ["AWS_ACCESS_KEY_ID"]}
