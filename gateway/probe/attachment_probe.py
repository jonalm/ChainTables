"""ADR-0046 live probe: presigned attachment PUTs on a locked gateway bucket.

    cd gateway && uv run python probe/attachment_probe.py <command> ...
      run      --bucket B --role R --function F --state S.json  # the ADR-0046 cases below
      poll     --state S.json                     # session-lifetime canary; repeat until it changes
      slot     --bucket B --role R --function F   # DenyPresignedSlotPuts: a role-signed URL for a slot is denied
      policy   --bucket B --role R --function F --retention-days N  # #92's bucket-policy statements
      expiry   --bucket B --role R --function F   # does an upload begun before its URL expires survive it?
      teardown --function F --region X            # only if a command died before its own teardown

Credentials: the ambient AWS profile (an administrator: lambda create/delete, iam:PassRole, s3
head). URLs are signed inside a throwaway Lambda F running as the gateway role R, since
OnlyTheGatewayPuts denies every other principal. run, slot, policy and expiry each deploy F and delete
it when they end, whatever the outcome: while it exists, any admin who invokes it signs as the
gateway. Every key is under attachment-probe/<run>/. What a PUT stores is COMPLIANCE-retained
and cannot be deleted until it expires: one day, except where a case below says otherwise.
Fail-fast: any unexpected AWS error in setup aborts; each case reports what S3 answered.
"""
import contextlib
import argparse, base64, hashlib, http.client, io, json, math, os, secrets, sys, time, urllib.parse, zipfile
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


@contextlib.contextmanager
def signer(role, function, region):
    """The signer Lambda, running as the gateway role, deleted on the way out whatever happens."""
    lam = boto3.client("lambda", region_name=region)
    account = boto3.client("sts", region_name=region).get_caller_identity()["Account"]
    role_arn = f"arn:aws:iam::{account}:role/{role}"
    code = build_zip()
    try:
        lam.get_function(FunctionName=function)
        sys.exit(f"function {function} already exists: pick another --function, or run teardown if it is a "
                 "probe signer left by a crash")
    except lam.exceptions.ResourceNotFoundException:
        pass
    try:
        lam.create_function(FunctionName=function, Runtime="python3.13", Role=role_arn,
                            Handler="attachment_probe_lambda.handler", Code={"ZipFile": code},
                            Architectures=["arm64"], Timeout=30, MemorySize=256,
                            Description="ChainTables ADR-0046 probe signer; deleted when the probe ends")
        lam.get_waiter("function_active_v2").wait(FunctionName=function)
        print(f"deployed signer {function} as {role_arn} in {region}")
        yield lam
    finally:
        try:
            lam.delete_function(FunctionName=function)
            print(f"deleted signer {function}")
        except lam.exceptions.ResourceNotFoundException:
            pass


def bucket_session(bucket):
    """The bucket's region, an S3 client there, and its SSE-KMS key ARN."""
    region = boto3.client("s3").get_bucket_location(Bucket=bucket)["LocationConstraint"] or "us-east-1"
    s3 = boto3.client("s3", region_name=region)
    key_arn = s3.get_bucket_encryption(Bucket=bucket)["ServerSideEncryptionConfiguration"]["Rules"][0][
        "ApplyServerSideEncryptionByDefault"]["KMSMasterKeyID"]
    assert key_arn.startswith("arn:aws:kms:"), key_arn
    return region, s3, key_arn


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
    c.request(method, f"{u.path}?{u.query}" if u.query else u.path or "/", body=body, headers=headers or {})
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
    region, s3, key_arn = bucket_session(a.bucket)
    with signer(a.role, a.function, region) as lam:
        run_cases(a, s3, lam, region, key_arn)


def run_cases(a, s3, lam, region, key_arn):
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
    region, s3, key_arn = bucket_session(a.bucket)
    with signer(a.role, a.function, region) as lam:
        slot_cases(a, s3, lam, region, key_arn)


def slot_cases(a, s3, lam, region, key_arn):
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
        return is_stored(s3, a.bucket, key)

    control = call("PUT", urls[0], body, sent)
    denied = call("PUT", urls[1], body, sent)
    control_ok = control[0] == 200 and stored(control_key)
    slot_ok = denied[0] == 403 and denied[1] == "AccessDenied" and "explicit deny in a resource-based policy" in (denied[2] or "") \
        and not stored(slot_key)
    print(f"[control: attachment key] {control} stored={stored(control_key)} {'ok' if control_ok else 'UNEXPECTED'}")
    print(f"[slot key]                {denied} stored={stored(slot_key)} {'ok' if slot_ok else 'UNEXPECTED'}")
    if not (control_ok and slot_ok):
        sys.exit("slot probe: not the expected outcome (control 200 and stored; slot 403 AccessDenied, not stored)")


def expiry(a):
    """Does an upload that starts before its URL expires survive the expiry? Probed 2026-11-10: no,
    `403 AccessDenied` "Request has expired" (ADR-0046), which is why the gateway's URLs now allow
    256 KiB/s. A URL signed under the gateway role, as the gateway signs (every lock, KMS and checksum
    header, the length), that lives --lifetime seconds; the PUT's headers and first byte go at once,
    then one byte every --gap seconds until --past seconds after the expiry (a trickle, so S3 does
    not close the connection as idle), then the response. Reports, and exits zero, either way:
      survives        200, stored;
      does not        403 AccessDenied "Request has expired", nothing stored.
    Exits non-zero on anything else (e.g. RequestTimeout: --gap too long), or if the upload did
    not start well before the expiry or end past it. The stored object is retained one day."""
    region, s3, key_arn = bucket_session(a.bucket)
    with signer(a.role, a.function, region) as lam:
        expiry_case(a, s3, lam, region, key_arn)


def expiry_case(a, s3, lam, region, key_arn):
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + secrets.token_hex(3)
    retain_iso = iso(datetime.now(timezone.utc) + timedelta(days=1))
    n_bytes = 1 + math.ceil((a.lifetime + a.past) / a.gap)
    body = secrets.token_bytes(n_bytes)
    digest = hashlib.sha256(body).digest()
    b64 = base64.b64encode(digest).decode()
    key = f"attachment-probe/{run_id}/_attachments/{digest.hex()}"
    params = {"Bucket": a.bucket, "Key": key, "ContentLength": n_bytes, "ChecksumSHA256": b64, "IfNoneMatch": "*",
              "ContentType": "application/octet-stream", "ServerSideEncryption": "aws:kms", "SSEKMSKeyId": key_arn,
              "BucketKeyEnabled": True, "ObjectLockMode": "COMPLIANCE", "ObjectLockRetainUntilDate": retain_iso}
    sent = {"Content-Length": str(n_bytes), "x-amz-checksum-sha256": b64, "If-None-Match": "*",
            "Content-Type": "application/octet-stream", "x-amz-server-side-encryption": "aws:kms",
            "x-amz-server-side-encryption-aws-kms-key-id": key_arn,
            "x-amz-server-side-encryption-bucket-key-enabled": "true", "x-amz-object-lock-mode": "COMPLIANCE",
            "x-amz-object-lock-retain-until-date": retain_iso}
    print(f"bucket {a.bucket} ({region}), run {run_id}: a URL living {a.lifetime} s, {n_bytes} bytes, "
          f"one every {a.gap} s, ending about {a.past} s past the expiry")
    (url,) = mint(lam, a.function, [{"method": "put_object", "params": params, "expires": a.lifetime}])["urls"]
    signed_at = time.time()
    expires_at = signed_at + a.lifetime
    u = urllib.parse.urlsplit(url)
    c = http.client.HTTPSConnection(u.netloc, timeout=a.gap * 10 + 60)
    c.putrequest("PUT", f"{u.path}?{u.query}", skip_accept_encoding=True)
    for k, v in sent.items():
        c.putheader(k, v)
    c.endheaders()
    started = time.time()
    if started > expires_at - a.lifetime / 2:
        sys.exit(f"expiry probe: the upload started {started - signed_at:.0f} s after signing, too near the expiry")
    for i in range(n_bytes):
        if i:
            time.sleep(a.gap)
        c.send(body[i:i + 1])
    ended = time.time()
    r = c.getresponse()
    data = r.read()
    code = msg = None
    if data.startswith(b"<?xml") or data.startswith(b"<Error"):
        e = ET.fromstring(data)
        code, msg = e.findtext("Code"), e.findtext("Message")
    st = is_stored(s3, a.bucket, key)
    print(f"upload started {expires_at - started:.0f} s before the expiry, last byte {ended - expires_at:.0f} s after it")
    print(f"answer: {(r.status, code, msg)} stored={st}")
    if ended < expires_at + a.past / 2:
        sys.exit("expiry probe: the last byte went too soon after the expiry to tell")
    if r.status == 200 and st:
        print("expiry probe: an upload started before its URL expires SURVIVES the expiry")
    elif r.status == 403 and code == "AccessDenied" and "expired" in (msg or "") and not st:
        print("expiry probe: an upload started before its URL expires DOES NOT survive the expiry")
    else:
        sys.exit("expiry probe: neither outcome: see the answer above")


def is_stored(s3, bucket, key):
    try:
        s3.head_object(Bucket=bucket, Key=key)
        return True
    except s3.exceptions.ClientError as e:
        if e.response["ResponseMetadata"]["HTTPStatusCode"] != 404:
            raise
        return False


def iso(t):
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


def form_post(url, fields, body):
    """A browser-form POST of `fields` and the file `body` (multipart/form-data, the file last)."""
    boundary = "chaintables" + secrets.token_hex(8)
    parts = [f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode()
             for k, v in fields.items()]
    parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="probe"\r\n'
                 "Content-Type: application/octet-stream\r\n\r\n".encode() + body + f"\r\n--{boundary}--\r\n".encode())
    return call("POST", url, b"".join(parts), {"Content-Type": f"multipart/form-data; boundary={boundary}"})


def policy(a):
    """#92's bucket-policy statements, live, with URLs and forms signed under the gateway role.

    Required (exit non-zero otherwise); every "403 AccessDenied" below must say "explicit deny in a
    resource-based policy", since S3 also answers 403 AccessDenied to an unsigned header or a bad form:
      - the bucket policy's DenyLongRetention caps retention at --retention-days + 3 (N + 3);
      - PUT to an attachment key retained 1 day: stored (the control);
      - PUT to an attachment key retained N + 2 days: stored (under the cap);
      - PUT to an attachment key retained N + 4 days: 403 AccessDenied, nothing stored (the cap);
      - PUT to a slot key: 403 AccessDenied, nothing stored (DenyPresignedSlotPuts);
      - presigned PutObjectRetention moving the control to N + 4 days: 403 AccessDenied (the cap);
      - presigned PutObjectRetention on an absent slot key: 403 AccessDenied, not 404 NoSuchKey.
        Probed 2026-11-10: S3 looks the key up first and the 403 is the role's denied
        s3:ListBucket (DenyGatewayPresignedNonPuts), so the key's absence does not leak; the
        slot PUT's deny, on s3:PutObjectRetention, is what shows DenyPresignedSlotPuts;
      - presigned GetObject of the control: 403 AccessDenied, not 200, though the role holds
        s3:GetObject on attachment keys (DenyGatewayPresignedNonPuts);
      - form POST to a slot key: 403 AccessDenied, nothing stored (DenyPresignedSlotPuts, POST).
    Reported only:
      - PUT retained N + 3 days + 1 hour: how S3 rounds the remaining days (probed 2026-11-10:
        down, stored, so the effective cap is just under N + 4 days), which AWS does not
        document (ceiling: denied; floor: stored);
      - form POST to an attachment key, the POST case's control.
    A required case that fails open leaves its object retained as long as it asked: N + 4 days
    at most. Everything stored is retained at least a day and cannot be deleted before.
    """
    region, s3, key_arn = bucket_session(a.bucket)
    n = a.retention_days
    held = json.loads(s3.get_bucket_policy(Bucket=a.bucket)["Policy"])
    caps = [st for st in held["Statement"] if st.get("Sid") == "DenyLongRetention"]
    cap = caps[0].get("Condition", {}).get("NumericGreaterThan", {}).get("s3:object-lock-remaining-retention-days") \
        if caps else None
    if cap != str(n + 3):
        sys.exit(f"the bucket policy's DenyLongRetention caps at {cap!r} days, not {n + 3}: run setup-locked-bucket.sh "
                 f"with --retention-days {n} first, or pass the bucket's own --retention-days")
    with signer(a.role, a.function, region) as lam:
        policy_cases(a, s3, lam, region, key_arn, n)


def policy_cases(a, s3, lam, region, key_arn, n):
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + secrets.token_hex(3)
    base = f"attachment-probe/{run_id}/"
    now = datetime.now(timezone.utc).replace(microsecond=0)
    days = {"control": timedelta(days=1), "under": timedelta(days=n + 2), "over": timedelta(days=n + 4),
            "edge": timedelta(days=n + 3, hours=1), "slot": timedelta(days=1)}
    bodies = {name: secrets.token_bytes(64) for name in (*days, "post", "post-slot")}
    digest = {name: hashlib.sha256(b).digest() for name, b in bodies.items()}
    keys = {name: base + f"_attachments/{digest[name].hex()}" for name in bodies}
    keys["slot"], keys["post-slot"], keys["absent-slot"] = base + "000000000000", base + "000000000001", base + "000000000002"
    print(f"bucket {a.bucket} ({region}), run {run_id}, retention days {n}, cap {n + 3}")

    def lock(until):
        return {"ServerSideEncryption": "aws:kms", "SSEKMSKeyId": key_arn, "BucketKeyEnabled": True,
                "ObjectLockMode": "COMPLIANCE", "ObjectLockRetainUntilDate": iso(until)}

    def put_spec(name):
        return {"method": "put_object", "expires": 900, "params": {
            "Bucket": a.bucket, "Key": keys[name], "ChecksumSHA256": base64.b64encode(digest[name]).decode(),
            "IfNoneMatch": "*", "ContentType": "application/octet-stream", **lock(now + days[name])}}

    def put_headers(name):
        return {"x-amz-checksum-sha256": base64.b64encode(digest[name]).decode(), "If-None-Match": "*",
                "Content-Type": "application/octet-stream", "x-amz-server-side-encryption": "aws:kms",
                "x-amz-server-side-encryption-aws-kms-key-id": key_arn,
                "x-amz-server-side-encryption-bucket-key-enabled": "true", "x-amz-object-lock-mode": "COMPLIANCE",
                "x-amz-object-lock-retain-until-date": iso(now + days[name])}

    def retention_spec(key, until):
        return {"method": "put_object_retention", "expires": 900, "headers": retention_body(until)[1], "params": {
            "Bucket": a.bucket, "Key": key, "Retention": {"Mode": "COMPLIANCE", "RetainUntilDate": iso(until)}}}

    def retention_body(until):
        xml = (f'<Retention xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Mode>COMPLIANCE</Mode>'
               f"<RetainUntilDate>{iso(until)}</RetainUntilDate></Retention>").encode()
        return xml, {"Content-MD5": base64.b64encode(hashlib.md5(xml).digest()).decode(), "Content-Type": "application/xml"}

    def post_spec(name):
        fields = {"Content-Type": "application/octet-stream", "x-amz-server-side-encryption": "aws:kms",
                  "x-amz-server-side-encryption-aws-kms-key-id": key_arn,
                  "x-amz-server-side-encryption-bucket-key-enabled": "true", "x-amz-object-lock-mode": "COMPLIANCE",
                  "x-amz-object-lock-retain-until-date": iso(now + timedelta(days=1)),
                  "x-amz-checksum-algorithm": "SHA256", "x-amz-checksum-sha256": base64.b64encode(digest[name]).decode()}
        return {"method": "post", "bucket": a.bucket, "key": keys[name], "fields": fields, "expires": 900}

    over_cap = now + timedelta(days=n + 4)
    names = ["control", "under", "over", "edge", "slot"]
    specs = [put_spec(x) for x in names] + [
        retention_spec(keys["control"], over_cap),
        retention_spec(keys["absent-slot"], now + timedelta(days=1)),
        {"method": "get_object", "expires": 900, "params": {"Bucket": a.bucket, "Key": keys["control"]}},
        post_spec("post"), post_spec("post-slot")]
    signed = mint(lam, a.function, specs)["urls"]
    put_url = dict(zip(names, signed))
    retention_url, absent_retention_url, get_url, post, post_slot = signed[5:]

    failures = []

    def check(case, got, ok, required=True):
        print(f"[{case}] {got} {'ok' if ok else ('UNEXPECTED' if required else '(reported)')}")
        if required and not ok:
            failures.append(case)

    def put(name):
        got = call("PUT", put_url[name], bodies[name], put_headers(name))
        return got, is_stored(s3, a.bucket, keys[name])

    def denied(got):  # by the bucket policy: a 403 for a bad signature or form proves nothing
        return got[0] == 403 and got[1] == "AccessDenied" and "explicit deny in a resource-based policy" in (got[2] or "")

    got, st = put("control")
    check("PUT attachment, 1 day (control)", (got, f"stored={st}"), got[0] == 200 and st)
    got, st = put("under")
    check(f"PUT attachment, {n + 2} days (under the cap)", (got, f"stored={st}"), got[0] == 200 and st)
    got, st = put("over")
    check(f"PUT attachment, {n + 4} days (over the cap)", (got, f"stored={st}"), denied(got) and not st)
    got, st = put("edge")
    check(f"PUT attachment, {n + 3} days + 1 h (rounding)", (got, f"stored={st}"), denied(got) and not st,
          required=False)
    got, st = put("slot")
    check("PUT slot key", (got, f"stored={st}"), denied(got) and not st)
    xml, h = retention_body(over_cap)
    got = call("PUT", retention_url, xml, h)
    check(f"presigned PutObjectRetention of the control to {n + 4} days", got, denied(got))
    xml, h = retention_body(now + timedelta(days=1))
    got = call("PUT", absent_retention_url, xml, h)
    check("presigned PutObjectRetention on an absent slot key", got, denied(got))
    got = call("GET", get_url)
    check("presigned GetObject of the control", got, denied(got))
    got = form_post(post["url"], {**post["fields"]}, bodies["post"])
    st = is_stored(s3, a.bucket, keys["post"])
    check("form POST attachment (control)", (got, f"stored={st}"), got[0] in (200, 204) and st, required=False)
    got = form_post(post_slot["url"], {**post_slot["fields"]}, bodies["post-slot"])
    st = is_stored(s3, a.bucket, keys["post-slot"])
    check("form POST slot key", (got, f"stored={st}"), denied(got) and not st)
    if failures:
        sys.exit(f"policy probe: {len(failures)} case(s) not as required: {failures}")
    print("policy probe: every required case as expected")


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
    for name in ("run", "slot", "policy", "expiry"):
        c = sp.add_parser(name)
        for arg in ("--bucket", "--role", "--function"):
            c.add_argument(arg, required=True)
        if name == "run":
            c.add_argument("--state", required=True)
        if name == "policy":
            c.add_argument("--retention-days", type=int, required=True)
        if name == "expiry":
            c.add_argument("--lifetime", type=int, default=60, help="the URL's lifetime, seconds")
            c.add_argument("--gap", type=float, default=3, help="seconds between bytes")
            c.add_argument("--past", type=int, default=60, help="seconds the upload runs past the expiry")
    q = sp.add_parser("poll"); q.add_argument("--state", required=True)
    t = sp.add_parser("teardown"); t.add_argument("--function", required=True); t.add_argument("--region", required=True)
    a = p.parse_args()
    {"run": run, "poll": poll, "slot": slot, "policy": policy, "expiry": expiry, "teardown": teardown}[a.cmd](a)


if __name__ == "__main__":
    main()
