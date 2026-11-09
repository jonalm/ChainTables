"""Throwaway Lambda for the ADR-0046 probe: signs presigned URLs under the gateway's
execution role, with the boto3 the gateway bundles. Never deployed as the gateway."""
import os, time
import boto3, botocore
from botocore.config import Config

INIT = time.time()
s3 = boto3.client("s3", config=Config(s3={"addressing_style": "virtual", "us_east_1_regional_endpoint": "regional"}))  # regional host, as the gateway's


def handler(event, context):
    return {"urls": [s3.generate_presigned_url(p["method"], Params=p["params"], ExpiresIn=p["expires"])
                     for p in event["presign"]],
            "init": INIT, "now": time.time(), "botocore": botocore.__version__,
            "access_key": os.environ["AWS_ACCESS_KEY_ID"]}
