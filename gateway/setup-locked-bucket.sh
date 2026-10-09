#!/usr/bin/env bash
# Set up a locked gateway bucket: Object Lock, SSE-KMS with one customer-managed key, a bucket
# policy that refuses any put without both, and the gateway deployed in locked-bucket mode.
#
#   gateway/setup-locked-bucket.sh --account <id> --region <region> --bucket <name> --function <name>
#                                  --role <name> --alias <alias/...> --retention-days <n>
#                                  --policy <gateway policy.json> [--permission-set <name>]...
#                                  [--decrypt-role <principal ARN>]... [--out <facts file>]
#                                  [--skip-gateway]
#   gateway/setup-locked-bucket.sh --print-policies --account <id> --region <region> --bucket <name>
#                                  --role <name> --alias <alias/...>      # no AWS calls
#
#   --account <id>          the account the ambient credentials must resolve to (a guard: COMPLIANCE
#                           retention cannot be undone, so the script refuses the wrong account)
#   --alias <alias/...>     KMS key alias; the key is created if the alias is absent
#   --retention-days <n>    COMPLIANCE retention the gateway puts on every record
#   --policy <file>         private gateway policy config bundled into the zip (never committed)
#   --permission-set <name> Identity Center permission set whose role gets kms:Decrypt; repeatable
#   --decrypt-role <arn>    other principal granted kms:Decrypt; repeatable
#   --out <file>            also write the facts as KEY=VALUE lines; keep it outside the repository
#   --skip-gateway          do not build/deploy the gateway (the role must already exist)
#   --print-policies        print the key, role and bucket policies and exit
#
# Generic, like deploy.sh: every account-specific value is an argument with no default, and
# credentials come from the ambient AWS CLI configuration (AWS_PROFILE and friends), which must
# belong to an administrator of --account.
#
# Idempotent: every step creates what is missing and updates what exists, so re-run it
# after a policy change. Fails fast: every AWS error aborts, and the final verification
# reads the configuration back and aborts on any drift from the spec.
#
# What it establishes (docs/gateway-setup.md, "A locked bucket"):
#   1. KMS: a customer-managed key under --alias, rotation on. Key policy: the account
#      root administers; the gateway role may GenerateDataKey/Decrypt through S3; the
#      role of each --permission-set and each --decrypt-role may Decrypt through S3.
#   2. Bucket: created with Object Lock (which also turns versioning on and pins it);
#      all four public-access blocks; ownership BucketOwnerEnforced; versioning Enabled;
#      Object Lock enabled with NO default retention (mode and retain-until are per
#      object, enforced by the bucket policy); default encryption SSE-KMS with the key
#      and Bucket Key on.
#   3. Gateway: build.sh + deploy.sh beside this script (bucket policy
#      GatewayPuts/OnlyTheGatewayPuts, execution role, function, IAM function URL), with
#      CHAINTABLES_KMS_KEY_ARN and CHAINTABLES_RETENTION_DAYS in the function's
#      environment, which makes the gateway dress every put as the contract below requires.
#      Then an extra inline policy on the execution role: s3:PutObjectRetention on the
#      bucket, kms:GenerateDataKey/Decrypt on the key.
#   4. Bucket policy: deploy.sh's statements kept, merged by Sid with
#        DenyInsecureTransport  s3:* when aws:SecureTransport is false
#        DenyNotKms / DenyNoSseHeader        PutObject unless x-amz-server-side-encryption = aws:kms
#        DenyWrongKey / DenyNoKeyHeader      PutObject unless ...-aws-kms-key-id = the key ARN
#        DenyNoRetainUntil                   PutObject unless x-amz-object-lock-retain-until-date is set
#        DenyNotCompliance / DenyNoLockMode  PutObject unless x-amz-object-lock-mode = COMPLIANCE
#      (StringNotEquals and Null are separate statements on purpose: a missing header
#      must be denied under either evaluation rule, and two keys in one Null block AND.)
#
# Per-object contract the writer (the gateway, the bucket's only PutObject principal)
# satisfies in its locked-bucket mode; a put without it is refused by S3 (502 s3_refused):
#   x-amz-server-side-encryption: aws:kms
#   x-amz-server-side-encryption-aws-kms-key-id: <KMS_KEY_ARN>
#   x-amz-object-lock-mode: COMPLIANCE
#   x-amz-object-lock-retain-until-date: <ISO 8601 UTC>
#   x-amz-checksum-sha256: <base64 SHA-256 of the body>   (integrity; not policy-enforced)
# Nothing constrains the key: a locked bucket takes a slot under any prefix (ADR-0031).
# COMPLIANCE retention cannot be shortened or removed by anyone, including root, until it
# expires: keep a test bucket's retention short.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
account="" region="" bucket="" function="" role="" alias="" policy="" out="" retention_days=""
permission_sets=() decrypt_roles=()
skip_gateway=0 print_only=0
while [ $# -gt 0 ]; do
    case "$1" in
        --account) account="$2"; shift 2 ;;
        --region) region="$2"; shift 2 ;;
        --bucket) bucket="$2"; shift 2 ;;
        --function) function="$2"; shift 2 ;;
        --role) role="$2"; shift 2 ;;
        --alias) alias="$2"; shift 2 ;;
        --policy) policy="$2"; shift 2 ;;
        --retention-days) retention_days="$2"; shift 2 ;;
        --permission-set) permission_sets+=("$2"); shift 2 ;;
        --decrypt-role) decrypt_roles+=("$2"); shift 2 ;;
        --out) out="$2"; shift 2 ;;
        --skip-gateway) skip_gateway=1; shift ;;
        --print-policies) print_only=1; shift ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "setup-locked-bucket.sh: unknown argument $1" >&2; exit 2 ;;
    esac
done

die() { echo "setup-locked-bucket.sh: $*" >&2; exit 1; }
say() { echo "== $*"; }
required="account region bucket role alias"
[ "$print_only" = 1 ] || required="$required function retention_days"
[ "$print_only" = 1 ] || [ "$skip_gateway" = 1 ] || required="$required policy"
for v in $required; do
    [ -n "${!v}" ] || die "--$(echo "$v" | tr _ -) is required (no defaults: every account-specific value is an argument)"
done
command -v aws >/dev/null || die "the AWS CLI is required"
command -v python3 >/dev/null || die "python3 is required (JSON assembly and verification)"
case "$bucket" in
    *[!a-z0-9.-]*|-*|*-|.*|*.) die "bucket name '$bucket' is not a valid S3 bucket name (lowercase letters, digits, '.' and '-' only; underscores are not allowed)" ;;
esac
case "$alias" in alias/*) ;; *) die "--alias must start with alias/, not $alias" ;; esac
[ "$print_only" = 1 ] || case "$retention_days" in ''|*[!0-9]*|0) die "--retention-days must be a positive integer, not '$retention_days'" ;; esac
for a in ${decrypt_roles[@]+"${decrypt_roles[@]}"}; do
    case "$a" in arn:*:iam::*) ;; *) die "--decrypt-role takes an IAM principal ARN, not $a" ;; esac
done

bucket_arn="arn:aws:s3:::$bucket"
role_arn="arn:aws:iam::$account:role/$role"
function_arn="arn:aws:lambda:$region:$account:function:$function"
root_arn="arn:aws:iam::$account:root"

# ---------------------------------------------------------------------------- policies
# Every policy is assembled by python3 from its inputs so the JSON is exact.
json_array() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "$@"; }

key_policy() {  # $1 key policy principals allowed to Decrypt (JSON array)
    python3 - "$root_arn" "$role_arn" "$region" "$1" <<'PY'
import json, sys
root, gateway, region, readers = sys.argv[1], sys.argv[2], sys.argv[3], json.loads(sys.argv[4])
via = {"StringEquals": {"kms:ViaService": f"s3.{region}.amazonaws.com"}}
st = [
    {"Sid": "RootAdministers", "Effect": "Allow", "Principal": {"AWS": root}, "Action": "kms:*", "Resource": "*"},
    {"Sid": "GatewayEncrypts", "Effect": "Allow", "Principal": {"AWS": gateway},
     "Action": ["kms:GenerateDataKey", "kms:Decrypt"], "Resource": "*", "Condition": via},
]
if readers:
    st.append({"Sid": "ReadersDecrypt", "Effect": "Allow", "Principal": {"AWS": readers},
               "Action": "kms:Decrypt", "Resource": "*", "Condition": via})
print(json.dumps({"Version": "2012-10-17", "Statement": st}))
PY
}

role_policy() {  # $1 key ARN
    python3 - "$bucket_arn" "$1" <<'PY'
import json, sys
bucket_arn, key_arn = sys.argv[1], sys.argv[2]
print(json.dumps({"Version": "2012-10-17", "Statement": [
    {"Sid": "LockSlots", "Effect": "Allow",
     "Action": "s3:PutObjectRetention", "Resource": f"{bucket_arn}/*"},
    {"Sid": "EncryptSlots", "Effect": "Allow",
     "Action": ["kms:GenerateDataKey", "kms:Decrypt"], "Resource": key_arn}]}))
PY
}

bucket_policy() {  # $1 key ARN, $2 existing bucket policy JSON (statements kept, merged by Sid)
    python3 - "$bucket_arn" "$1" "$2" <<'PY'
import json, sys
bucket_arn, key_arn, existing = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
objects = f"{bucket_arn}/*"
def deny(sid, action, resource, condition):
    return {"Sid": sid, "Effect": "Deny", "Principal": "*", "Action": action, "Resource": resource, "Condition": condition}
ours = [
    deny("DenyInsecureTransport", "s3:*", [bucket_arn, objects], {"Bool": {"aws:SecureTransport": "false"}}),
    deny("DenyNotKms", "s3:PutObject", objects, {"StringNotEquals": {"s3:x-amz-server-side-encryption": "aws:kms"}}),
    deny("DenyNoSseHeader", "s3:PutObject", objects, {"Null": {"s3:x-amz-server-side-encryption": "true"}}),
    deny("DenyWrongKey", "s3:PutObject", objects, {"StringNotEquals": {"s3:x-amz-server-side-encryption-aws-kms-key-id": key_arn}}),
    deny("DenyNoKeyHeader", "s3:PutObject", objects, {"Null": {"s3:x-amz-server-side-encryption-aws-kms-key-id": "true"}}),
    deny("DenyNoRetainUntil", "s3:PutObject", objects, {"Null": {"s3:object-lock-retain-until-date": "true"}}),
    deny("DenyNotCompliance", "s3:PutObject", objects, {"StringNotEquals": {"s3:object-lock-mode": "COMPLIANCE"}}),
    deny("DenyNoLockMode", "s3:PutObject", objects, {"Null": {"s3:object-lock-mode": "true"}}),
]
mine = {s["Sid"] for s in ours}
kept = [s for s in existing.get("Statement", []) if s.get("Sid") not in mine]
for s in kept:
    if "Sid" not in s:
        sys.exit("setup-locked-bucket.sh: the existing bucket policy has a statement without a Sid; merge by hand")
print(json.dumps({"Version": "2012-10-17", "Statement": kept + ours}))
PY
}

if [ "$print_only" = 1 ]; then
    key_arn="arn:aws:kms:$region:$account:key/<key-id>"
    readers="$(json_array "arn:aws:iam::$account:role/aws-reserved/sso.amazonaws.com/$region/AWSReservedSSO_<permission-set>_<hash>" \
                          ${decrypt_roles[@]+"${decrypt_roles[@]}"})"
    gateway_policy='{"Version":"2012-10-17","Statement":[{"Sid":"GatewayPuts","Effect":"Allow","Principal":{"AWS":"'"$role_arn"'"},"Action":"s3:PutObject","Resource":"'"$bucket_arn"'/*"},{"Sid":"OnlyTheGatewayPuts","Effect":"Deny","Principal":"*","Action":"s3:PutObject","Resource":"'"$bucket_arn"'/*","Condition":{"ArnNotEquals":{"aws:PrincipalArn":"'"$role_arn"'"}}}]}'
    echo "# KMS key policy ($alias)";                 key_policy "$readers" | python3 -m json.tool
    echo "# execution role inline policy ($role)";   role_policy "$key_arn" | python3 -m json.tool
    echo "# bucket policy ($bucket), merged onto what gateway/deploy.sh writes"
    bucket_policy "$key_arn" "$gateway_policy" | python3 -m json.tool
    exit 0
fi

# ---------------------------------------------------------------------------- preflight
[ "$skip_gateway" = 1 ] || [ -f "$policy" ] || die "gateway policy file $policy not found (docs/gateway-setup.md has the format)"
export AWS_DEFAULT_REGION="$region" AWS_PAGER=""
caller="$(aws sts get-caller-identity --output json)"
caller_account="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["Account"])' "$caller")"
caller_arn="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["Arn"])' "$caller")"
[ "$caller_account" = "$account" ] || die "the ambient credentials resolve to account $caller_account, not --account $account"
say "running as $caller_arn in $account / $region"

# ---------------------------------------------------------------------------- 1. KMS key
key_id="$(aws kms list-aliases --query "Aliases[?AliasName=='$alias'].TargetKeyId | [0]" --output text)"
if [ -z "$key_id" ] || [ "$key_id" = None ]; then
    say "creating KMS key $alias"
    key_id="$(aws kms create-key --description "SSE-KMS key for the $bucket bucket (ChainTables)" \
        --tags "TagKey=Name,TagValue=$bucket" --query KeyMetadata.KeyId --output text)"
    aws kms create-alias --alias-name "$alias" --target-key-id "$key_id"
else
    say "KMS key $alias exists ($key_id)"
fi
key_arn="$(aws kms describe-key --key-id "$key_id" --query KeyMetadata.Arn --output text)"
key_state="$(aws kms describe-key --key-id "$key_id" --query KeyMetadata.KeyState --output text)"
[ "$key_state" = Enabled ] || die "KMS key $key_arn is in state $key_state, not Enabled"
aws kms enable-key-rotation --key-id "$key_id"

# ---------------------------------------------------------------------------- 2. bucket
if aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
    say "bucket $bucket exists"
    lock="$(aws s3api get-object-lock-configuration --bucket "$bucket" --query ObjectLockConfiguration.ObjectLockEnabled --output text 2>/dev/null || echo none)"
    [ "$lock" = Enabled ] || die "bucket $bucket exists without Object Lock, which can only be enabled at creation: delete it (or pick another --bucket) and re-run"
else
    say "creating bucket $bucket with Object Lock in $region"
    if [ "$region" = us-east-1 ]; then  # S3 refuses a LocationConstraint naming us-east-1
        aws s3api create-bucket --bucket "$bucket" --object-lock-enabled-for-bucket >/dev/null
    else
        aws s3api create-bucket --bucket "$bucket" --object-lock-enabled-for-bucket \
            --create-bucket-configuration "LocationConstraint=$region" >/dev/null
    fi
    aws s3api wait bucket-exists --bucket "$bucket"
fi
say "bucket: public access blocked, BucketOwnerEnforced, versioning, Object Lock (no default retention), SSE-KMS + Bucket Key"
aws s3api put-public-access-block --bucket "$bucket" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-ownership-controls --bucket "$bucket" \
    --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'
aws s3api put-bucket-versioning --bucket "$bucket" --versioning-configuration Status=Enabled
aws s3api put-object-lock-configuration --bucket "$bucket" \
    --object-lock-configuration '{"ObjectLockEnabled":"Enabled"}'
aws s3api put-bucket-encryption --bucket "$bucket" --server-side-encryption-configuration \
    "{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"aws:kms\",\"KMSMasterKeyID\":\"$key_arn\"},\"BucketKeyEnabled\":true}]}"

# ---------------------------------------------------------------------------- 3. gateway
if [ "$skip_gateway" = 1 ]; then
    say "skipping the gateway (--skip-gateway)"
    aws iam get-role --role-name "$role" >/dev/null 2>&1 || die "execution role $role does not exist; run without --skip-gateway first"
    url="$(aws lambda get-function-url-config --function-name "$function" --query FunctionUrl --output text 2>/dev/null || echo unknown)"
else
    say "building the gateway zip with policy $policy"
    "$here/build.sh" --arch arm64 --policy "$policy"
    say "deploying the gateway (bucket $bucket, function $function, role $role)"
    deploy_out="$("$here/deploy.sh" --bucket "$bucket" --function "$function" --region "$region" \
        --role "$role" --zip "$here/build/gateway-arm64.zip" \
        --env "CHAINTABLES_KMS_KEY_ARN=$key_arn" --env "CHAINTABLES_RETENTION_DAYS=$retention_days" | tee /dev/stderr)"
    url="$(echo "$deploy_out" | awk '/^function URL/ {print $3}')"
    [ -n "$url" ] || die "no function URL in the deploy output"
fi
say "granting $role retention and KMS on the bucket's slots"
aws iam put-role-policy --role-name "$role" --policy-name chaintables-lock-kms \
    --policy-document "$(role_policy "$key_arn")"

# ---------------------------------------------------------------------------- 4. KMS key policy
readers=()
for ps in ${permission_sets[@]+"${permission_sets[@]}"}; do
    found="$(aws iam list-roles --path-prefix /aws-reserved/sso.amazonaws.com/ \
        --query "Roles[?starts_with(RoleName, 'AWSReservedSSO_${ps}_')].Arn" --output text)"
    if [ -n "$found" ] && [ "$found" != None ]; then
        for r in $found; do readers+=("$r"); done
        echo "   permission set $ps -> $found"
    else
        die "permission set $ps has no provisioned role in account $account: provision it, or drop the --permission-set"
    fi
done
for r in ${decrypt_roles[@]+"${decrypt_roles[@]}"}; do readers+=("$r"); done
say "putting the key policy: root administers, $role encrypts, ${#readers[@]} reader principal(s) decrypt"
aws kms put-key-policy --key-id "$key_id" --policy-name default \
    --policy "$(key_policy "$(json_array ${readers[@]+"${readers[@]}"})")"

# ---------------------------------------------------------------------------- 5. bucket policy
existing="$(aws s3api get-bucket-policy --bucket "$bucket" --query Policy --output text 2>/dev/null || echo '{}')"
say "putting the bucket policy: gateway statements kept, TLS / SSE-KMS / Object Lock denies merged"
aws s3api put-bucket-policy --bucket "$bucket" --policy "$(bucket_policy "$key_arn" "$existing")"

# ---------------------------------------------------------------------------- 6. verify
say "verifying the configuration against the spec"
python3 - "$bucket" "$key_arn" "$role_arn" <<'PY'
import json, subprocess, sys
bucket, key_arn, role_arn = sys.argv[1:4]
def get(*args):
    return json.loads(subprocess.run(["aws", "s3api", *args, "--bucket", bucket, "--output", "json"],
                                     check=True, capture_output=True, text=True).stdout)
problems = []
def expect(what, got, want):
    if got != want:
        problems.append(f"{what}: got {got!r}, want {want!r}")
pab = get("get-public-access-block")["PublicAccessBlockConfiguration"]
for k in ("BlockPublicAcls", "IgnorePublicAcls", "BlockPublicPolicy", "RestrictPublicBuckets"):
    expect(f"public access block {k}", pab.get(k), True)
expect("object ownership", get("get-bucket-ownership-controls")["OwnershipControls"]["Rules"][0]["ObjectOwnership"], "BucketOwnerEnforced")
expect("versioning", get("get-bucket-versioning").get("Status"), "Enabled")
lock = get("get-object-lock-configuration")["ObjectLockConfiguration"]
expect("object lock", lock.get("ObjectLockEnabled"), "Enabled")
expect("object lock default retention", lock.get("Rule"), None)
enc = get("get-bucket-encryption")["ServerSideEncryptionConfiguration"]["Rules"][0]
expect("SSE algorithm", enc["ApplyServerSideEncryptionByDefault"].get("SSEAlgorithm"), "aws:kms")
expect("SSE key", enc["ApplyServerSideEncryptionByDefault"].get("KMSMasterKeyID"), key_arn)
expect("bucket key", enc.get("BucketKeyEnabled"), True)
policy = json.loads(get("get-bucket-policy")["Policy"])
sids = {s.get("Sid") for s in policy["Statement"]}
for sid in ("GatewayPuts", "OnlyTheGatewayPuts", "DenyInsecureTransport", "DenyNotKms", "DenyNoSseHeader",
            "DenyWrongKey", "DenyNoKeyHeader", "DenyNoRetainUntil", "DenyNotCompliance", "DenyNoLockMode"):
    if sid not in sids:
        problems.append(f"bucket policy lacks statement {sid}")
gw = [s for s in policy["Statement"] if s.get("Sid") == "GatewayPuts"]
if gw:
    expect("GatewayPuts principal", gw[0]["Principal"].get("AWS"), role_arn)
if problems:
    sys.exit("setup-locked-bucket.sh: configuration drifts from the spec:\n  " + "\n  ".join(problems))
print("   ok: public access, ownership, versioning, Object Lock, SSE-KMS, bucket policy")
PY
say "probing: a bare PutObject as $caller_arn must be denied"
probe_body="$(mktemp)"
trap 'rm -f "$probe_body"' EXIT
if probe="$(aws s3api put-object --bucket "$bucket" --key "probe/$(date -u +%s)" --body "$probe_body" 2>&1)"; then
    die "a bare PutObject succeeded; the bucket policy is not in force: $probe"
elif echo "$probe" | grep -q AccessDenied; then
    echo "   ok: AccessDenied"
else
    die "the probe failed for a reason other than AccessDenied: $probe"
fi
rm -f "$probe_body"

# ---------------------------------------------------------------------------- 7. facts
facts() {
    echo "BUCKET=$bucket"
    echo "BUCKET_ARN=$bucket_arn"
    echo "REGION=$region"
    echo "ACCOUNT_ID=$account"
    echo "KMS_ALIAS=$alias"
    echo "KMS_KEY_ID=$key_id"
    echo "KMS_KEY_ARN=$key_arn"
    echo "EXEC_ROLE_NAME=$role"
    echo "EXEC_ROLE_ARN=$role_arn"
    echo "FUNCTION_NAME=$function"
    echo "FUNCTION_ARN=$function_arn"
    echo "FUNCTION_URL=$url"
    echo "RETENTION_DAYS=$retention_days"
    echo "GATEWAY_POLICY_FILE=$policy"
    echo "DECRYPT_PRINCIPALS=$(IFS=,; echo "${readers[*]:-}")"
    echo "SET_UP_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
if [ -n "$out" ]; then
    mkdir -p "$(dirname "$out")"
    facts > "$out"
    say "done; facts written to $out"
else
    say "done"
fi
echo "bucket        $bucket"
echo "KMS key       $key_arn ($alias)"
echo "role          $role_arn"
echo "function URL  $url"
