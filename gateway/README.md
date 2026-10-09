# The gateway

The one writer of a **gateway bucket**: a Lambda function behind a function URL with
`AuthType=AWS_IAM` that fills a slot only after checking that the caller may write under
that chain's prefix and that the record's author is the caller. It validates and never
authors, and it is not a ChainTables client. The contract it implements, and that the Julia
`gateway =` store calls, is issue [#54](https://github.com/jonalm/ChainTables/issues/54);
the checks and status codes are listed at the top of [`handler.py`](handler.py).

## Layout

| file | what |
|---|---|
| `handler.py` | the whole gateway; `handler(event, context)` is the Lambda entry point |
| `tests/` | pytest, S3 stubbed with botocore's `Stubber` |
| `pyproject.toml`, `uv.lock` | dependencies, pinned exactly (`cbor2`, `boto3`) |
| `build.sh` | produces the deployment zip |
| `deploy.sh` | creates or updates the bucket, execution role, function, URL and bucket policy |
| `setup-locked-bucket.sh` | a locked bucket around `build.sh` + `deploy.sh`: KMS key, Object Lock, the deny statements, the role's extra grants |

## Tests

```sh
cd gateway && uv run pytest
```

## Configuration

The Lambda environment carries:

- `CHAINTABLES_BUCKET` — the bucket this gateway fronts. Required; no default.
- `CHAINTABLES_POLICY` — path of the policy file. Default: `policy.json` beside `handler.py`,
  which is where `build.sh --policy` puts it.

Both are read once and cached: in Lambda at startup, when `handler.py` is imported (so
importing boto3 and building the S3 client happen in the INIT phase, not inside somebody's
first request), elsewhere at the first request. A missing bucket or an unreadable policy
fails the startup, so every request errors rather than some being served.

## Policy config

JSON, one file per gateway, its *contents* private (never committed; `policy.json` under
`gateway/` is git-ignored):

```json
{"format_version": 1,
 "rules": [{"prefix": "teams/alpha", "writers": ["alice@example.com", "bob@example.com"]},
           {"prefix": "teams/*",     "writers": ["carol@example.com"]},
           {"prefix": "",            "writers": ["root-writer"]}]}
```

- `prefix` is a glob matched case-sensitively against the whole chain prefix (the key up to
  its last `/`; `""` is the bucket root). `*` matches any run of characters, `/` included;
  it is the only wildcard, and a prefix holding `?`, `[` or `]` is refused at load.
- `writers` are caller names: the text after the last `/` of the caller ARN. For an Identity
  Center session that is the role session name, which is the Identity Center user name.
  Matched exactly and case-sensitively.
- A caller is allowed when any matching rule lists its name. Creating a chain under an
  allowed prefix needs no separate right.

## Build

```sh
gateway/build.sh --arch arm64 --policy ~/private/policy.json
```

Writes `gateway/build/gateway-arm64.zip` from the locked dependencies, resolved for the
Lambda platform (`manylinux_2_28`, which the Amazon Linux 2023 runtime satisfies; Python 3.13 by default), with `boto3` vendored so the
gateway does not depend on the runtime's copy. `--arch x86_64` for an x86 function. Without
`--policy` the zip has no policy and the deployment must set `CHAINTABLES_POLICY`.

## Deploy

```sh
AWS_PROFILE=<admin profile> gateway/deploy.sh --bucket <bucket> --function <function> \
    --region <region> --role <execution role> --zip gateway/build/gateway-arm64.zip
```

Generic and idempotent; every account-specific value is an argument with no default. It merges
the bucket policy by `Sid`, keeping statements it does not own, and refuses a bucket with
Object Lock unless given both lock variables: redeploy a locked bucket with
`setup-locked-bucket.sh` (ADR-0037). `--reserved-concurrency <n>`
reserves (and so caps) the function's concurrent executions; it is off by default because an
account at the minimum concurrency quota cannot reserve any. What it
creates, the IAM contract a writer or reader must satisfy, the bucket policy, and how a
writer is onboarded are in [`docs/gateway-setup.md`](../docs/gateway-setup.md).
