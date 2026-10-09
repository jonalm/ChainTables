#!/usr/bin/env bash
# Deploy the gateway: the bucket, the execution role, the function, its URL, the bucket policy.
#
#   gateway/deploy.sh --bucket <name> --function <name> --region <region> --role <name> --zip <file>
#                     [--arch arm64|x86_64] [--writer <principal ARN>]... [--reader <principal ARN>]...
#                     [--env KEY=VALUE]... [--timeout <s>] [--memory <MB>] [--log-retention <days>]
#                     [--reserved-concurrency <n>] [--no-smoke]
#
# Generic and idempotent: every account-specific value is an argument with no default, and
# each step creates what is missing or updates what exists, so re-running after a rebuild
# or a policy change is the deployment procedure. Credentials come from the ambient AWS CLI
# configuration (AWS_PROFILE and friends) and must belong to an administrator of the account.
#
# What it does, in order (docs/gateway-setup.md has the IAM contract this establishes):
#   1. bucket: create if absent, block all public access;
#   2. execution role: trust lambda.amazonaws.com; inline s3:PutObject on the bucket's keys
#      and nothing else on S3; inline logs on its own log group;
#   3. function: python3.13, handler.handler, the zip, CHAINTABLES_BUCKET plus every --env in
#      the environment, which it replaces; a bucket with Object Lock (a locked bucket) must get
#      both CHAINTABLES_KMS_KEY_ARN and CHAINTABLES_RETENTION_DAYS, and a bucket without it
#      neither, or the script refuses before changing anything (ADR-0037);
#      with --reserved-concurrency, that many concurrent executions reserved, which also caps
#      them (left as it is otherwise: an account with the minimum quota cannot reserve any);
#   4. function URL with AuthType=AWS_IAM; for each --writer, resource-based grants of both
#      lambda:InvokeFunctionUrl and lambda:InvokeFunction, the latter only when invoked via the
#      function URL (lambda:InvokedViaFunctionUrl), so a writer cannot call the Invoke API with
#      a hand-built event that names another caller (ADR-0036); a same-account writer whose
#      permission set already grants both needs no --writer; a cross-account one does;
#   5. bucket policy: the execution role may PutObject; every other principal is denied
#      PutObject; each --reader and --writer may GetObject and ListBucket; every request
#      without TLS is denied (DenyInsecureTransport, the same statement a locked bucket has).
#      Merged by Sid: the script owns GatewayPuts, OnlyTheGatewayPuts, DenyInsecureTransport
#      and Read<n>, and keeps every other statement, such as a locked bucket's denies (ADR-0037);
#   6. log retention, then a smoke invocation that proves the zip runs in the Lambda runtime
#      (the handler boots, loads its policy, and refuses an unauthenticated PUT as 403 not_allowed).
set -euo pipefail

bucket="" function="" region="" role="" zip="" arch=arm64
timeout=30 memory=256 retention=30 smoke=1 concurrency=""
writers=() readers=() envs=()
while [ $# -gt 0 ]; do
    case "$1" in
        --bucket) bucket="$2"; shift 2 ;;
        --function) function="$2"; shift 2 ;;
        --region) region="$2"; shift 2 ;;
        --role) role="$2"; shift 2 ;;
        --zip) zip="$2"; shift 2 ;;
        --arch) arch="$2"; shift 2 ;;
        --writer) writers+=("$2"); shift 2 ;;
        --reader) readers+=("$2"); shift 2 ;;
        --env) envs+=("$2"); shift 2 ;;
        --timeout) timeout="$2"; shift 2 ;;
        --memory) memory="$2"; shift 2 ;;
        --log-retention) retention="$2"; shift 2 ;;
        --reserved-concurrency) concurrency="$2"; shift 2 ;;
        --no-smoke) smoke=0; shift ;;
        -h|--help) sed -n '2,35p' "$0"; exit 0 ;;
        *) echo "deploy.sh: unknown argument $1" >&2; exit 2 ;;
    esac
done

die() { echo "deploy.sh: $*" >&2; exit 1; }
say() { echo "== $*"; }
for v in bucket function region role zip; do
    [ -n "${!v}" ] || die "--$v is required (no defaults: every account-specific value is an argument)"
done
case "$arch" in arm64|x86_64) ;; *) die "--arch must be arm64 or x86_64, not $arch" ;; esac
case "$concurrency" in "") ;; *[!0-9]*|0) die "--reserved-concurrency must be a positive integer, not $concurrency" ;; esac
[ -f "$zip" ] || die "zip $zip not found; build it with gateway/build.sh --arch $arch --policy <private policy file>"
command -v aws >/dev/null || die "the AWS CLI is required"
command -v python3 >/dev/null || die "python3 is required (JSON assembly)"
for a in ${writers[@]+"${writers[@]}"} ${readers[@]+"${readers[@]}"}; do
    case "$a" in arn:*:iam::*) ;; *) die "--writer/--reader takes an IAM principal ARN, not $a" ;; esac
done
for e in ${envs[@]+"${envs[@]}"}; do
    case "$e" in
        CHAINTABLES_BUCKET=*) die "--env may not set CHAINTABLES_BUCKET; it is --bucket" ;;
        [A-Za-z_]*=*) case "$e" in *,*|*\}*) die "--env value may not contain ',' or '}': $e" ;; esac ;;
        *) die "--env takes KEY=VALUE, not $e" ;;
    esac
done
export AWS_DEFAULT_REGION="$region" AWS_PAGER=""

account="$(aws sts get-caller-identity --query Account --output text)"
say "deploying as $(aws sts get-caller-identity --query Arn --output text) into account $account, region $region"

# JSON helpers: a JSON array of the given strings, and a statement per principal.
json_array() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "$@"; }
bucket_arn="arn:aws:s3:::$bucket"
role_arn="arn:aws:iam::$account:role/$role"
function_arn="arn:aws:lambda:$region:$account:function:$function"
log_group="/aws/lambda/$function"

# 1. bucket
if aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
    say "bucket $bucket exists"
else
    say "creating bucket $bucket"
    if [ "$region" = us-east-1 ]; then
        aws s3api create-bucket --bucket "$bucket" >/dev/null
    else
        aws s3api create-bucket --bucket "$bucket" --create-bucket-configuration "LocationConstraint=$region" >/dev/null
    fi
fi
# A locked bucket's function must keep dressing every put, and a plain bucket's must not try
# (S3 refuses lock headers on a bucket without Object Lock): refuse a mismatch before any change.
if lock_out="$(aws s3api get-object-lock-configuration --bucket "$bucket" \
        --query ObjectLockConfiguration.ObjectLockEnabled --output text 2>&1)"; then
    lock="$lock_out"
elif echo "$lock_out" | grep -q ObjectLockConfigurationNotFoundError; then
    lock=none
else
    die "reading the Object Lock configuration of $bucket failed: $lock_out"
fi
lock_envs=0
for e in ${envs[@]+"${envs[@]}"}; do
    case "$e" in CHAINTABLES_KMS_KEY_ARN=?*|CHAINTABLES_RETENTION_DAYS=?*) lock_envs=$((lock_envs + 1)) ;; esac
done
if [ "$lock" = Enabled ]; then
    [ "$lock_envs" = 2 ] || die "bucket $bucket has Object Lock, so it is a locked bucket, and deploying it without both --env CHAINTABLES_KMS_KEY_ARN=... and --env CHAINTABLES_RETENTION_DAYS=... would make the gateway put records with no retention: redeploy it with gateway/setup-locked-bucket.sh"
else
    [ "$lock_envs" = 0 ] || die "bucket $bucket has no Object Lock (got '$lock'), so S3 would refuse every locked put: drop the CHAINTABLES_KMS_KEY_ARN/CHAINTABLES_RETENTION_DAYS --env, or set up a locked bucket with gateway/setup-locked-bucket.sh"
fi
aws s3api put-public-access-block --bucket "$bucket" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# 2. execution role
trust='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
if aws iam get-role --role-name "$role" >/dev/null 2>&1; then
    say "role $role exists"
else
    say "creating role $role"
    aws iam create-role --role-name "$role" --assume-role-policy-document "$trust" \
        --description "ChainTables gateway execution role for bucket $bucket" >/dev/null
fi
aws iam put-role-policy --role-name "$role" --policy-name chaintables-gateway-put --policy-document \
    "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"PutSlots\",\"Effect\":\"Allow\",\"Action\":\"s3:PutObject\",\"Resource\":\"$bucket_arn/*\"}]}"
aws iam put-role-policy --role-name "$role" --policy-name chaintables-gateway-logs --policy-document \
    "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"OwnLogs\",\"Effect\":\"Allow\",\"Action\":[\"logs:CreateLogGroup\",\"logs:CreateLogStream\",\"logs:PutLogEvents\"],\"Resource\":\"arn:aws:logs:$region:$account:log-group:$log_group:*\"}]}"

# 3. function
env_vars="Variables={CHAINTABLES_BUCKET=$bucket$(for e in ${envs[@]+"${envs[@]}"}; do printf ',%s' "$e"; done)}"
if aws lambda get-function --function-name "$function" >/dev/null 2>&1; then
    say "updating function $function"
    aws lambda update-function-configuration --function-name "$function" --runtime python3.13 \
        --handler handler.handler --role "$role_arn" --environment "$env_vars" \
        --timeout "$timeout" --memory-size "$memory" >/dev/null
    aws lambda wait function-updated-v2 --function-name "$function"
    aws lambda update-function-code --function-name "$function" --zip-file "fileb://$zip" --architectures "$arch" >/dev/null
    aws lambda wait function-updated-v2 --function-name "$function"
else
    say "creating function $function ($arch, python3.13)"
    # A freshly created role takes a few seconds to become assumable by Lambda.
    for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
        if out="$(aws lambda create-function --function-name "$function" --runtime python3.13 \
                --architectures "$arch" --handler handler.handler --role "$role_arn" \
                --zip-file "fileb://$zip" --environment "$env_vars" \
                --timeout "$timeout" --memory-size "$memory" \
                --description "ChainTables gateway for bucket $bucket" 2>&1)"; then
            break
        elif echo "$out" | grep -q "cannot be assumed"; then
            echo "   role not yet assumable (attempt $attempt), retrying in 5 s"; sleep 5
        else
            die "create-function failed: $out"
        fi
        [ "$attempt" -lt 12 ] || die "create-function: role $role_arn never became assumable"
    done
    aws lambda wait function-active-v2 --function-name "$function"
fi
if [ -n "$concurrency" ]; then
    say "reserving $concurrency concurrent executions"
    aws lambda put-function-concurrency --function-name "$function" \
        --reserved-concurrent-executions "$concurrency" >/dev/null
fi

# 4. function URL and the writers' invoke grants
if url="$(aws lambda get-function-url-config --function-name "$function" --query FunctionUrl --output text 2>/dev/null)"; then
    auth="$(aws lambda get-function-url-config --function-name "$function" --query AuthType --output text)"
    [ "$auth" = AWS_IAM ] || die "function URL exists with AuthType=$auth, not AWS_IAM: delete it or fix it by hand, the gateway must not be public"
    say "function URL exists"
else
    say "creating function URL (AuthType=AWS_IAM)"
    url="$(aws lambda create-function-url-config --function-name "$function" --auth-type AWS_IAM \
        --invoke-mode BUFFERED --query FunctionUrl --output text)"
fi
# Drop every grant this script owns, then re-add one pair per --writer, so the resource
# policy always reflects exactly the current argument list.
existing="$(aws lambda get-policy --function-name "$function" --query Policy --output text 2>/dev/null || echo '{}')"
for sid in $(python3 -c 'import json,sys; p=json.loads(sys.argv[1]); print(" ".join(s["Sid"] for s in p.get("Statement",[]) if s["Sid"].startswith("chaintables-writer-")))' "$existing"); do
    aws lambda remove-permission --function-name "$function" --statement-id "$sid"
done
i=0
for w in ${writers[@]+"${writers[@]}"}; do
    i=$((i + 1))
    say "granting writer $i invoke on the URL: $w"
    aws lambda add-permission --function-name "$function" --statement-id "chaintables-writer-$i-url" \
        --action lambda:InvokeFunctionUrl --principal "$w" --function-url-auth-type AWS_IAM >/dev/null
    aws lambda add-permission --function-name "$function" --statement-id "chaintables-writer-$i-invoke" \
        --action lambda:InvokeFunction --principal "$w" --invoked-via-function-url >/dev/null
done

# 5. bucket policy, merged by Sid onto the one in place
if existing_policy="$(aws s3api get-bucket-policy --bucket "$bucket" --query Policy --output text 2>&1)"; then
    :
elif echo "$existing_policy" | grep -q NoSuchBucketPolicy; then
    existing_policy='{}'
else
    die "reading the bucket policy of $bucket failed: $existing_policy"
fi
say "putting bucket policy: PutObject for $role only; reads for ${#readers[@]} reader(s) and ${#writers[@]} writer(s); TLS only; other statements kept"
policy="$(python3 - "$bucket_arn" "$role_arn" "$(json_array ${readers[@]+"${readers[@]}"} ${writers[@]+"${writers[@]}"})" "$existing_policy" <<'EOF'
import json, re, sys
bucket_arn, role_arn, principals, existing = sys.argv[1], sys.argv[2], json.loads(sys.argv[3]), json.loads(sys.argv[4])
statements = [
    {"Sid": "GatewayPuts", "Effect": "Allow", "Principal": {"AWS": role_arn},
     "Action": "s3:PutObject", "Resource": f"{bucket_arn}/*"},
    {"Sid": "OnlyTheGatewayPuts", "Effect": "Deny", "Principal": "*",
     "Action": "s3:PutObject", "Resource": f"{bucket_arn}/*",
     "Condition": {"ArnNotEquals": {"aws:PrincipalArn": role_arn}}},
    {"Sid": "DenyInsecureTransport", "Effect": "Deny", "Principal": "*",
     "Action": "s3:*", "Resource": [bucket_arn, f"{bucket_arn}/*"],
     "Condition": {"Bool": {"aws:SecureTransport": "false"}}},
]
for n, arn in enumerate(principals, 1):
    statements.append({"Sid": f"Read{n}", "Effect": "Allow", "Principal": {"AWS": arn},
                       "Action": ["s3:GetObject", "s3:ListBucket"],
                       "Resource": [bucket_arn, f"{bucket_arn}/*"]})
# The statements of this script are replaced, Read<n> included so a dropped reader loses its grant;
# every other statement (the denies of a locked bucket, a hand-added grant) is kept as it is.
kept = existing.get("Statement", [])
kept = [kept] if isinstance(kept, dict) else kept
if any("Sid" not in s for s in kept):
    sys.exit("deploy.sh: the bucket policy in place has a statement without a Sid, which cannot be merged; give it a Sid or remove it")
ours = {"GatewayPuts", "OnlyTheGatewayPuts", "DenyInsecureTransport"}
kept = [s for s in kept if s["Sid"] not in ours and not re.fullmatch(r"Read[0-9]+", s["Sid"])]
print(json.dumps({"Version": "2012-10-17", "Statement": statements + kept}))
EOF
)"
aws s3api put-bucket-policy --bucket "$bucket" --policy "$policy"

# 6. logs and the smoke invocation
aws logs create-log-group --log-group-name "$log_group" 2>/dev/null || true
aws logs put-retention-policy --log-group-name "$log_group" --retention-in-days "$retention"
if [ "$smoke" = 1 ]; then
    say "smoke invocation: an unauthenticated PUT must be refused as 403 not_allowed"
    out="$(mktemp)"
    trap 'rm -f "$out"' EXIT
    event='{"requestContext":{"http":{"method":"PUT","path":"/"}},"rawQueryString":"key=000000000000","body":"","isBase64Encoded":false}'
    result="$(aws lambda invoke --function-name "$function" --payload "$event" --cli-binary-format raw-in-base64-out "$out")"
    if echo "$result" | grep -q FunctionError; then
        die "the function errored in the Lambda runtime (a bad zip, a missing policy.json, or a wrong architecture): $(cat "$out")"
    fi
    python3 - "$out" <<'EOF'
import json, sys
r = json.load(open(sys.argv[1]))
body = json.loads(r.get("body", "{}"))
if r.get("statusCode") != 403 or body.get("code") != "not_allowed":
    sys.exit(f"deploy.sh: smoke invocation expected 403 not_allowed, got {r.get('statusCode')} {body.get('code')}: {body.get('message')}")
print(f"   ok: {r['statusCode']} {body['code']}")
EOF
    rm -f "$out"
fi

say "deployed"
echo "bucket        $bucket"
echo "function      $function_arn ($arch)"
echo "role          $role_arn"
echo "function URL  $url"
echo "log group     $log_group ($retention days)"
