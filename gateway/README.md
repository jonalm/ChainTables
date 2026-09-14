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

## Tests

```sh
cd gateway && uv run pytest
```

## Configuration

The Lambda environment carries:

- `CHAINTABLES_BUCKET` — the bucket this gateway fronts. Required; no default.
- `CHAINTABLES_POLICY` — path of the policy file. Default: `policy.json` beside `handler.py`,
  which is where `build.sh --policy` puts it.

Both are read at the first request and cached; a missing bucket or an unreadable policy
raises on every request rather than serving some.

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
  its last `/`; `""` is the bucket root). `*` matches any run of characters, `/` included.
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
`--policy` the zip has no policy and the deployment must set `CHAINTABLES_POLICY`. The
deploy script and the IAM contract are the deploy ticket's ([#59](https://github.com/jonalm/ChainTables/issues/59)).
