# Setting up a gateway bucket

A **gateway bucket** is a bucket whose only writer is the **gateway**: one Lambda function,
behind a function URL with `AuthType=AWS_IAM`, that fills a slot only after checking that the
caller may write under that chain's prefix and that the record's author is the caller
([ADR-0028](adr/0028-a-gateway-bucket-verifies-the-author-and-nothing-else.md)). Reads never
touch it. This page is the operator's contract: what to deploy, what IAM rights a writer or
reader principal must hold, how the author name is derived, and how a writer is onboarded.
Nothing here depends on which identity provider sits behind AWS IAM Identity Center, or on
Identity Center at all: an IAM user works, and so does any role whose session name is bound
by an identity provider.

The code, tests and build are under [`gateway/`](../gateway/README.md).

## What gets deployed

| resource | name | holds |
|---|---|---|
| S3 bucket | your choice, e.g. `chaintables-gateway-<account>-<region>` | the chains; public access blocked; the bucket policy below |
| IAM role | your choice, e.g. `chaintables-gateway` | the function's execution role: `s3:PutObject` on the bucket's keys and nothing else on S3, plus its own log group |
| Lambda function | your choice, e.g. `chaintables-gateway` | `gateway/handler.py` with the policy config bundled as `policy.json`; `CHAINTABLES_BUCKET` in its environment |
| function URL | assigned by AWS: `https://<id>.lambda-url.<region>.on.aws/` | `AuthType=AWS_IAM`, buffered |

One gateway per bucket. The names are yours; the writer and reader permission sets (below)
name the bucket and the function, so fix the names before provisioning identity.

## The policy config

A JSON file, one per gateway, whose *contents* are private (never committed; `gateway/policy.json`
is git-ignored). It says which caller names may fill slots under which chain prefixes:

```json
{"format_version": 1,
 "rules": [{"prefix": "teams/alpha", "writers": ["alice@example.com", "bob@example.com"]},
           {"prefix": "teams/*",     "writers": ["carol@example.com"]},
           {"prefix": "",            "writers": ["root-writer"]}]}
```

- `prefix` is a glob matched case-sensitively against the whole chain prefix, which is the
  slot key up to its last `/` (`""` is the bucket root). `*` matches any run of characters,
  `/` included.
- `writers` are caller names (next section), matched exactly and case-sensitively.
- A caller is allowed when any matching rule lists its name. Creating a chain under an
  allowed prefix needs no separate right.

Changing the policy is a rebuild and a redeploy: `build.sh --policy` bundles the file, and
`deploy.sh` updates the function's code in place.

## The author name

**Author = the text after the last `/` of the caller's ARN.** The client takes it from
`sts:GetCallerIdentity`, the gateway from the function URL's request context, and the gateway
refuses a record whose `client.user` differs from it. The gateway accepts only two principal
kinds:

| principal | ARN | author |
|---|---|---|
| IAM user | `arn:aws:iam::<account>:user/[path/]<name>` | the user name |
| assumed role | `arn:aws:sts::<account>:assumed-role/<role>/<session name>` | the session name |

Anything else — the account root, a service principal — is refused as `not_allowed`.

For an **Identity Center** session the session name is the Identity Center user name. With
an external identity provider federated over SAML and SCIM, that is whatever the SCIM
`userName` mapping supplies; with Entra ID mapped in the usual way it is the user principal
name. AWS documents this nowhere; it was verified live and the live gateway test re-verifies
it. So a writer named `alice@example.com` in the policy is the Identity Center user whose
user name is exactly that.

**Only grant invoke to principals whose session name is bound.** An IAM user's name is
fixed, and Identity Center sets the session name itself. A plain IAM role that a caller can
assume with `sts:AssumeRole` lets the caller *choose* the session name, and with it the
author: never list such a role among the writers. Cross-account writers are fine as long as
the same holds on their side.

## The IAM contract

### The execution role

Created by `deploy.sh`. Trusts `lambda.amazonaws.com`; two inline policies:

```json
{"Sid": "PutSlots", "Effect": "Allow", "Action": "s3:PutObject", "Resource": "arn:aws:s3:::<bucket>/*"}
{"Sid": "OwnLogs",  "Effect": "Allow", "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
 "Resource": "arn:aws:logs:<region>:<account>:log-group:/aws/lambda/<function>:*"}
```

No `GetObject`: the conditional put (`If-None-Match: *`) needs none. No managed policies.

### A writer principal

Must hold all four statements. As an Identity Center permission set, the inline policy is:

```json
{"Version": "2012-10-17",
 "Statement": [
  {"Sid": "ReadObjects", "Effect": "Allow", "Action": "s3:GetObject",  "Resource": "arn:aws:s3:::<bucket>/*"},
  {"Sid": "ListBucket",  "Effect": "Allow", "Action": "s3:ListBucket", "Resource": "arn:aws:s3:::<bucket>"},
  {"Sid": "InvokeGatewayUrl", "Effect": "Allow", "Action": "lambda:InvokeFunctionUrl",
   "Resource": "arn:aws:lambda:<region>:<account>:function:<function>",
   "Condition": {"StringEquals": {"lambda:FunctionUrlAuthType": "AWS_IAM"}}},
  {"Sid": "InvokeGatewayViaUrl", "Effect": "Allow", "Action": "lambda:InvokeFunction",
   "Resource": "arn:aws:lambda:<region>:<account>:function:<function>",
   "Condition": {"Bool": {"lambda:InvokedViaFunctionUrl": "true"}}}]}
```

Both `lambda:` actions are required: function URLs created since October 2025 check
`lambda:InvokeFunction` as well as `lambda:InvokeFunctionUrl`
([Control access to function URLs](https://docs.aws.amazon.com/lambda/latest/dg/urls-auth.html)).
A principal lacking either gets a 403 from AWS before the handler runs, which the client
reports as `WriteRefusedError` with `reason = "forbidden"`.

The reads are direct: the client's fetch, stat, list and the read-back after a commit go to
S3, not through the gateway. Nothing in a writer's policy grants `PutObject`.

### A reader principal

The two S3 statements only (`ReadObjects`, `ListBucket`).

### Same account or cross account

For a principal in the **same account** as the bucket and the function, the identity policy
above is sufficient, and `deploy.sh` needs no `--writer`/`--reader`. For a principal in
**another account**, the resource side must grant too: pass its ARN as `--writer` (both
invoke actions on the function, plus reads in the bucket policy) or `--reader` (reads in the
bucket policy). A role named this way must exist when the script runs; S3 rejects a policy
naming a role that does not.

### The bucket policy

`deploy.sh` writes this, and it is what makes the bucket a gateway bucket:

```json
{"Version": "2012-10-17",
 "Statement": [
  {"Sid": "GatewayPuts", "Effect": "Allow", "Principal": {"AWS": "arn:aws:iam::<account>:role/<role>"},
   "Action": "s3:PutObject", "Resource": "arn:aws:s3:::<bucket>/*"},
  {"Sid": "OnlyTheGatewayPuts", "Effect": "Deny", "Principal": "*",
   "Action": "s3:PutObject", "Resource": "arn:aws:s3:::<bucket>/*",
   "Condition": {"ArnNotEquals": {"aws:PrincipalArn": "arn:aws:iam::<account>:role/<role>"}}},
  {"Sid": "Read1", "Effect": "Allow", "Principal": {"AWS": "<each --reader and --writer ARN>"},
   "Action": ["s3:GetObject", "s3:ListBucket"], "Resource": ["arn:aws:s3:::<bucket>", "arn:aws:s3:::<bucket>/*"]}]}
```

The Deny is the guarantee: an administrator with `s3:*` on the account cannot fill a slot
either, only the gateway can. What the policy does **not** prevent: an administrator can
still delete objects, and can rewrite this policy. The trust boundary is one fact wide, that
a record in the bucket names the principal that filled its slot and that principal was
allowed to (ADR-0028); it is not tamper-evidence against the account's owners.

## Deploying

Prerequisites: the AWS CLI v2, `uv`, `python3`, and administrator credentials for the
account in the ambient CLI configuration (`AWS_PROFILE=<admin profile>`).

```sh
gateway/build.sh --arch arm64 --policy <private dir>/policy.json
AWS_PROFILE=<admin profile> gateway/deploy.sh \
    --bucket <bucket> --function <function> --region <region> --role <role> \
    --zip gateway/build/gateway-arm64.zip \
    [--writer <cross-account writer ARN>]... [--reader <cross-account reader ARN>]...
```

Every account-specific value is an argument with no default. The script is idempotent: it
creates what is missing and updates what exists, so a rebuilt zip or a changed policy is
deployed by running it again. Its last step invokes the function once with an
unauthenticated `PUT`, which must come back `403 not_allowed`: that proves the zip imports
in the Lambda runtime (the `cbor2` extension matches the architecture), the bundled
`policy.json` parses, and `CHAINTABLES_BUCKET` is set. It prints the function URL, which
writers pass to `Chain` as `gateway`.

Keep the real invocation, the policy contents, the URL and the ARNs outside the repository.

## Onboarding a writer

Three independent gates, each with its own failure:

1. **Sign-in**: the person is assigned to the identity provider's Identity Center
   application. Missing: `aws sso login` refuses them.
2. **AWS rights**: a writer permission-set assignment for the account. Missing:
   `WriteRefusedError` with `reason = "forbidden"`.
3. **The gateway policy** lists their name under the prefix. Missing: `WriteRefusedError`
   with `reason = "not_allowed"`.

A reader needs gates 1 and 2 with the reader permission set.

If `aws sso login`'s browser flow cannot reach the `oidc.<region>.amazonaws.com/authorize`
page (some browsers block it), `aws sso login --use-device-code` works.

## Using it from Julia

A writer logs in once per session with the AWS CLI and hands the session to `Chain` as a
`credentials` callable:

```sh
aws sso login --profile <profile>            # --use-device-code if the browser cannot reach the authorize page
```

```julia
credentials = ChainTables.sso_credentials("<profile>")
chain = ChainTables.Chain(bucket, prefix; gateway = "https://<id>.lambda-url.<region>.on.aws",
                          region, credentials)
```

`sso_credentials` reads the CLI's own cache of the login through
`aws configure export-credentials --profile <profile> --format env-no-export`, keeps the
result, and runs the CLI again only within five minutes of the expiry it reported, so a
long-lived process outlives one set of temporary credentials without a second login for as
long as the SSO session lasts. It needs the AWS CLI v2 on `PATH`, only when called. Without
a login, with an expired session, or with an unknown profile, `Chain` fails at construction
(credentials resolve then, ADR-0019) with the CLI's message and the login command to run.

The `profile` is an SSO profile in `~/.aws/config` (`aws configure sso` writes one) naming the
Identity Center start URL, the account and the writer permission set; nothing about it is
ChainTables-specific. Any other credentials the CLI can export work the same way, and so do
the `credentials` forms a plain bucket takes: a `ChainTables.Credentials`, or `nothing` for
the `AWS_*` environment that `aws-vault exec` injects.

The bucket is named once, the `region` must agree with the one in the URL, the author is
fetched from STS at the first write, and a record over 4 MiB fails at commit before any call
is made. The live gateway test (`test/gateway.jl`, run line in `test/runtests.jl`) is this
section end to end: it constructs the chain exactly like this and commits, races and is
refused against the real bucket.
