"""ADR-0046 live probe: presigned attachment PUTs on a locked gateway bucket.

    cd gateway && uv run python probe/attachment_probe.py <command> ...
      deploy   --role R --function F --region X   # throwaway signer Lambda under the gateway role R
      run      --bucket B --function F --state S.json   # the cases below
      poll     --state S.json                     # session-lifetime canary; repeat until it changes
      slot     --bucket B --function F            # DenyPresignedSlotPuts: a role-signed URL for a slot is denied
      teardown --function F --region X

Credentials: the ambient AWS profile (an administrator: lambda create, iam:PassRole, s3 head).
URLs are signed inside Lambda under the gateway role, since OnlyTheGatewayPuts denies every
other principal. Every key is under attachment-probe/<run>/_attachments/; a PUT that succeeds
leaves a COMPLIANCE object retained one day (bucket policy needs a retain-until, not a minimum).
Fail-fast: any unexpected AWS error in setup aborts; each case reports what S3 answered.
"""
import argparse, base64, hashlib, http.client, io, json, os, secrets, sys, time, urllib.parse, zipfile
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone

import boto3

HERE = os.path.dirname(os.path.abspath(__file__))
PKG = os.path.join(HERE, "..", "build", "pkg")  # build.sh's pinned arm64 deps: run gateway/build.sh first


def build_zip() -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for root, _, files in os.walk(PKG):
            for f in files:
                full = os.path.join(root, f)
                rel = os.path.relpath(full, PKG)
                if rel in ("handler.py", "policy.json"):
                    continue
                z.write(full, rel)
        z.write(os.path.join(HERE, "attachment_probe_lambda.py"), "attachment_probe_lambda.py")
    return buf.getvalue()


def deploy(a):
    sess = boto3.Session(region_name=a.region)
    account = sess.client("sts").get_caller_identity()["Account"]
    lam = sess.client("lambda")
    role_arn = f"arn:aws:iam::{account}:role/{a.role}"
    code = build_zip()
    try:
        lam.get_function(FunctionName=a.function)
        lam.update_function_code(FunctionName=a.function, ZipFile=code)
    except lam.exceptions.ResourceNotFoundException:
        lam.create_function(FunctionName=a.function, Runtime="python3.13", Role=role_arn,
                            Handler="attachment_probe_lambda.handler", Code={"ZipFile": code},
                            Architectures=["arm64"], Timeout=30, MemorySize=256,
                            Description="ChainTables ADR-0046 probe; delete after use")
    lam.get_waiter("function_active_v2").wait(FunctionName=a.function)
    lam.get_waiter("function_updated_v2").wait(FunctionName=a.function)
    print(f"deployed {a.function} as {role_arn} in {a.region}")


def teardown(a):
    boto3.client("lambda", region_name=a.region).delete_function(FunctionName=a.function)
    print(f"deleted {a.function}")


def mint(lam, function, specs):
    r = lam.invoke(FunctionName=function, Payload=json.dumps({"presign": specs}).encode())
    body = json.loads(r["Payload"].read())
    if "FunctionError" in r:
        sys.exit(f"probe Lambda failed: {body}")
    return body


def call(method, url, body=b"", headers=None):
    u = urllib.parse.urlsplit(url)
    c = http.client.HTTPSConnection(u.netloc, timeout=60)
    c.request(method, f"{u.path}?{u.query}", body=body, headers=headers or {})
    r = c.getresponse()
    data = r.read()
    code = msg = None
    if data.startswith(b"<?xml") or data.startswith(b"<Error"):
        e = ET.fromstring(data)
        code, msg = e.findtext("Code"), e.findtext("Message")
    return r.status, code, msg


def signed_headers(url):
    return urllib.parse.parse_qs(urllib.parse.urlsplit(url).query)["X-Amz-SignedHeaders"][0]


def run(a):
    sess = boto3.Session()
    s3 = sess.client("s3")
    region = s3.get_bucket_location(Bucket=a.bucket)["LocationConstraint"] or "us-east-1"
    s3 = sess.client("s3", region_name=region)
    lam = sess.client("lambda", region_name=region)
    enc = s3.get_bucket_encryption(Bucket=a.bucket)["ServerSideEncryptionConfiguration"]["Rules"][0]
    key_arn = enc["ApplyServerSideEncryptionByDefault"]["KMSMasterKeyID"]
    assert key_arn.startswith("arn:aws:kms:"), key_arn
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + secrets.token_hex(3)
    base = f"attachment-probe/{run_id}/_attachments/"
    retain = (datetime.now(timezone.utc) + timedelta(days=1)).replace(microsecond=0)
    retain_iso = retain.strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"bucket {a.bucket} ({region}), key {key_arn}, run {run_id}, retain-until {retain_iso}\n")

    def body():
        b = secrets.token_bytes(64)
        h = hashlib.sha256(b).digest()
        return b, h.hex(), base64.b64encode(h).decode()

    lock = {"ServerSideEncryption": "aws:kms", "SSEKMSKeyId": key_arn, "BucketKeyEnabled": True,
            "ObjectLockMode": "COMPLIANCE", "ObjectLockRetainUntilDate": retain_iso}
    send_lock = {"x-amz-server-side-encryption": "aws:kms", "x-amz-server-side-encryption-aws-kms-key-id": key_arn,
                 "x-amz-server-side-encryption-bucket-key-enabled": "true",
                 "x-amz-object-lock-mode": "COMPLIANCE", "x-amz-object-lock-retain-until-date": retain_iso}

    def spec(h, b64, expires=900, extra=None, with_lock=True):
        p = {"Bucket": a.bucket, "Key": base + h, "ChecksumSHA256": b64, "IfNoneMatch": "*",
             "ContentType": "application/octet-stream", **(lock if with_lock else {}), **(extra or {})}
        return {"method": "put_object", "params": p, "expires": expires}

    def headers(b64, with_lock=True):
        return {"x-amz-checksum-sha256": b64, "If-None-Match": "*", "Content-Type": "application/octet-stream",
                **(send_lock if with_lock else {})}

    def head(h):
        try:
            r = s3.head_object(Bucket=a.bucket, Key=base + h, ChecksumMode="ENABLED")
            return {k: str(r.get(k)) for k in ("VersionId", "ObjectLockMode", "ObjectLockRetainUntilDate",
                                               "ServerSideEncryption", "SSEKMSKeyId", "BucketKeyEnabled",
                                               "ChecksumSHA256", "ContentType", "ContentLength")}
        except s3.exceptions.ClientError as e:
            return f"absent ({e.response['Error']['Code']})"

    def versions(h):
        r = s3.list_object_versions(Bucket=a.bucket, Prefix=base + h)
        return len(r.get("Versions", [])), len(r.get("DeleteMarkers", []))

    def report(name, got, note=""):
        print(f"[{name}] {got} {note}")

    # one mint call for every URL, so they share one Lambda credential set
    bA, hA, cA = body()
    bD, hD, cD = body()
    bE, hE, cE = body()
    bF, hF, cF = body()
    bG, hG, cG = body()
    bH, hH, cH = body()
    bI, hI, cI = body()
    bJ, hJ, cJ = body()
    bK, hK, cK = body()
    bL, hL, cL = body()
    specs = [spec(hA, cA),                                                     # 0 A
             spec(hD, cD), spec(hE, cE), spec(hF, cF), spec(hG, cG), spec(hH, cH),  # 1-5
             spec(hI, cI, extra={"ContentLength": len(bI) + 1}),              # 6 I
             spec(hJ, cJ, extra={"Tagging": "chaintables=attachment"}),       # 7 J
             spec(hK, cK, expires=1),                                         # 8 K
             spec(hL, cL, with_lock=False),                                   # 9 L
             {"method": "get_object", "params": {"Bucket": a.bucket, "Key": f"attachment-probe/{run_id}/session-canary"},
              "expires": 604800}]                                             # 10 canary
    m = mint(lam, a.function, specs)
    u = m["urls"]
    print(f"lambda botocore {m['botocore']}, env age at mint {m['now'] - m['init']:.0f} s, key {m['access_key'][:8]}…")
    print(f"signed headers (A): {signed_headers(u[0])}")
    print(f"signed headers (I): {signed_headers(u[6])}")
    print(f"signed headers (J): {signed_headers(u[7])}\n")

    report("A ok", call("PUT", u[0], bA, headers(cA)))
    report("A head", head(hA))
    report("B replay same URL", call("PUT", u[0], bA, headers(cA)), f"versions,markers={versions(hA)}")
    uC = mint(lam, a.function, [spec(hA, cA)])["urls"][0]
    report("C fresh URL, key present", call("PUT", uC, bA, headers(cA)), f"versions,markers={versions(hA)}")
    wrong = secrets.token_bytes(len(bD))
    report("D wrong body (BadDigest?)", call("PUT", u[1], wrong, headers(cD)), f"after: {head(hD)}")
    hdr = headers(cE); del hdr["If-None-Match"]
    report("E omit If-None-Match", call("PUT", u[2], bE, hdr), f"after: {head(hE)}")
    hdr = headers(cF); del hdr["x-amz-checksum-sha256"]
    report("F omit checksum", call("PUT", u[3], bF, hdr), f"after: {head(hF)}")
    hdr = headers(cG); hdr["x-amz-object-lock-retain-until-date"] = (retain + timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
    report("G alter retain-until", call("PUT", u[4], bG, hdr), f"after: {head(hG)}")
    hdr = headers(cH); hdr["x-amz-meta-extra"] = "1"
    report("H extra unsigned x-amz header", call("PUT", u[5], bH, hdr), f"after: {head(hH)}")
    report("I signed Content-Length = len+1, true body", call("PUT", u[6], bI, headers(cI)), f"after: {head(hI)}")
    hdr = headers(cJ); hdr["x-amz-tagging"] = "chaintables=attachment"
    report("J tagging signed (role lacks PutObjectTagging?)", call("PUT", u[7], bJ, hdr), f"after: {head(hJ)}")
    time.sleep(3)
    report("K expired URL", call("PUT", u[8], bK, headers(cK)), f"after: {head(hK)}")
    report("L no lock headers (bucket policy applies to presigned?)", call("PUT", u[9], bL, headers(cL, with_lock=False)),
           f"after: {head(hL)}")
    canary = call("GET", u[10])
    report("M session canary now (expect 403 AccessDenied while creds live)", canary)

    state = {"run": run_id, "bucket": a.bucket, "minted_at": m["now"], "env_init": m["init"],
             "canary": u[10], "polls": [[time.time(), *canary]]}
    with open(a.state, "w") as f:
        json.dump(state, f, indent=1)
    print(f"\nstate → {a.state}; run `attachment_probe.py poll --state {a.state}` until the canary's code changes")


def slot(a):
    """ADR-0046's "a presigned PUT to a slot is denied", which the live suite cannot prove: the
    gateway never mints for a slot. Two URLs signed in one Lambda call under the gateway role,
    each with every lock and KMS header the bucket policy requires, so that only
    DenyPresignedSlotPuts can refuse the slot: an attachment key (the control, which must be
    stored) and a slot key in the same run. A slot PUT that is stored instead leaves a COMPLIANCE
    object at attachment-probe/<run>/000000000000 for a day. Exits non-zero unless the control is
    200 and the slot 403 AccessDenied with nothing stored."""
    sess = boto3.Session()
    region = sess.client("s3").get_bucket_location(Bucket=a.bucket)["LocationConstraint"] or "us-east-1"
    s3 = sess.client("s3", region_name=region)
    lam = sess.client("lambda", region_name=region)
    key_arn = s3.get_bucket_encryption(Bucket=a.bucket)["ServerSideEncryptionConfiguration"]["Rules"][0][
        "ApplyServerSideEncryptionByDefault"]["KMSMasterKeyID"]
    assert key_arn.startswith("arn:aws:kms:"), key_arn
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + secrets.token_hex(3)
    retain_iso = (datetime.now(timezone.utc) + timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
    body = secrets.token_bytes(64)
    digest = hashlib.sha256(body).digest()
    b64 = base64.b64encode(digest).decode()
    control_key = f"attachment-probe/{run_id}/_attachments/{digest.hex()}"
    slot_key = f"attachment-probe/{run_id}/000000000000"
    print(f"bucket {a.bucket} ({region}), run {run_id}, retain-until {retain_iso}")
    params = {"Bucket": a.bucket, "ChecksumSHA256": b64, "IfNoneMatch": "*", "ContentType": "application/octet-stream",
              "ServerSideEncryption": "aws:kms", "SSEKMSKeyId": key_arn, "BucketKeyEnabled": True,
              "ObjectLockMode": "COMPLIANCE", "ObjectLockRetainUntilDate": retain_iso}
    sent = {"x-amz-checksum-sha256": b64, "If-None-Match": "*", "Content-Type": "application/octet-stream",
            "x-amz-server-side-encryption": "aws:kms", "x-amz-server-side-encryption-aws-kms-key-id": key_arn,
            "x-amz-server-side-encryption-bucket-key-enabled": "true", "x-amz-object-lock-mode": "COMPLIANCE",
            "x-amz-object-lock-retain-until-date": retain_iso}
    urls = mint(lam, a.function, [{"method": "put_object", "params": {**params, "Key": k}, "expires": 900}
                                  for k in (control_key, slot_key)])["urls"]

    def stored(key):
        try:
            s3.head_object(Bucket=a.bucket, Key=key)
            return True
        except s3.exceptions.ClientError as e:
            if e.response["ResponseMetadata"]["HTTPStatusCode"] != 404:
                raise
            return False

    control = call("PUT", urls[0], body, sent)
    denied = call("PUT", urls[1], body, sent)
    control_ok = control[0] == 200 and stored(control_key)
    slot_ok = denied[0] == 403 and denied[1] == "AccessDenied" and not stored(slot_key)
    print(f"[control: attachment key] {control} stored={stored(control_key)} {'ok' if control_ok else 'UNEXPECTED'}")
    print(f"[slot key]                {denied} stored={stored(slot_key)} {'ok' if slot_ok else 'UNEXPECTED'}")
    if not (control_ok and slot_ok):
        sys.exit("slot probe: not the expected outcome (control 200 and stored; slot 403 AccessDenied, not stored)")


def poll(a):
    with open(a.state) as f:
        st = json.load(f)
    got = call("GET", st["canary"])
    st["polls"].append([time.time(), *got])
    with open(a.state, "w") as f:
        json.dump(st, f, indent=1)
    age = (time.time() - st["minted_at"]) / 3600
    print(f"{age:.2f} h after mint ({(time.time() - st['env_init']) / 3600:.2f} h after env init): {got}")


def main():
    p = argparse.ArgumentParser()
    sp = p.add_subparsers(dest="cmd", required=True)
    d = sp.add_parser("deploy"); d.add_argument("--role", required=True)
    d.add_argument("--function", required=True); d.add_argument("--region", required=True)
    r = sp.add_parser("run"); r.add_argument("--bucket", required=True); r.add_argument("--function", required=True)
    r.add_argument("--state", required=True)
    q = sp.add_parser("poll"); q.add_argument("--state", required=True)
    s = sp.add_parser("slot"); s.add_argument("--bucket", required=True); s.add_argument("--function", required=True)
    t = sp.add_parser("teardown"); t.add_argument("--function", required=True); t.add_argument("--region", required=True)
    a = p.parse_args()
    {"deploy": deploy, "run": run, "poll": poll, "slot": slot, "teardown": teardown}[a.cmd](a)


if __name__ == "__main__":
    main()
