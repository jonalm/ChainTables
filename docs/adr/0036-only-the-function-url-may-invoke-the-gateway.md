---
status: accepted
---

# Only the function URL may invoke the gateway

ADR-0028's one guarantee is that a record in a gateway bucket names the
principal that filled its slot. The gateway learns that principal from
`requestContext.authorizer.iam.userArn` in its event. AWS writes that field
when a request arrives through the function URL with `AuthType=AWS_IAM`. But
the same function can also be called through the Lambda Invoke API, and then
the event is whatever the caller sends, authorizer included. Nothing in the
event, or in the Lambda context, tells the handler which path it came by.

`deploy.sh` gave each `--writer` an unconditioned `lambda:InvokeFunction`
grant next to `lambda:InvokeFunctionUrl`. With it, a writer could call Invoke
with a hand-built event that names any principal, and the gateway would fill a
slot as that principal. Issue #68.

## Decision

**The Invoke permission a writer holds is valid only through the function
URL.** `deploy.sh` adds the writer's `lambda:InvokeFunction` grant with
`--invoked-via-function-url`, which conditions it on
`lambda:InvokedViaFunctionUrl`. The writer permission set in
`docs/gateway-setup.md` already had that condition. Re-running `deploy.sh`
replaces the earlier unconditioned grants, because it drops every
`chaintables-writer-*` statement before it adds the current ones.

**The handler does not try to detect a direct invocation.** The event is
the caller's to write, so any field the handler checked could be forged too.
The guarantee rests on AWS refusing the call, not on the handler.

**The trust boundary includes every principal that may call Invoke without
the condition.** That covers an identity policy granting `lambda:InvokeFunction`
or `lambda:*` on the function or on `*`, such as `AdministratorAccess` and
`PowerUserAccess`, and any resource grant an operator adds by hand. Such a
principal can fill a slot under any listed name. In practice these are the
account's administrators, who can already rewrite the bucket policy (ADR-0028).
So ADR-0028's sentence that "an administrator with `s3:*` cannot fill a slot"
holds only for an administrator who lacks unconditioned Invoke.

**The live gateway test checks the negative case.** It calls Invoke directly
with an event whose authorizer names another principal and asserts that AWS
denies the call (`test/live/gateway.jl`). To do that, it needs the function's
name, `CHAINTABLES_LIVE_GATEWAY_FUNCTION`.

## Considered options

- **Verify a signature inside the handler.** The SigV4 signature is checked by
  AWS and is not passed to the function, and a secret shared with the clients
  would be a new credential to distribute. Rejected.
- **Drop the Invoke grant altogether.** Function URLs created since October
  2025 need both actions, so a writer without `lambda:InvokeFunction` gets a
  403 from AWS. Rejected.

## Consequences

- An existing deployment stays exposed until `deploy.sh` runs again (#83).
- An operator who grants Invoke to anyone outside `deploy.sh` must add the
  same condition, or accept that principal into the trust boundary.
- `deploy.sh`'s smoke invocation still calls Invoke directly. It runs as the
  administrator, whose identity policy allows that, so it is not affected.
