# Lambda function URL, IAM principal, STS and Identity Center facts the gateway rests on

Research note for [issue #53](https://github.com/jonalm/ChainTables/issues/53) (map: [#52](https://github.com/jonalm/ChainTables/issues/52)).
Date: 2026-09-14. Sources are primary: the AWS Lambda Developer Guide and API Reference,
the IAM and STS user guides and API references, the S3 User Guide and API Reference, the
boto3 reference, the IAM Identity Center User Guide, the AWS SDKs and Tools Reference Guide,
and Microsoft Learn for the Entra side.

Following the convention of [`s3-conditional-writes.md`](s3-conditional-writes.md),
**[G]** marks something AWS (or Microsoft) states *in writing* — a guarantee the design may
rest on — and **[ND]** marks something that is **not documented**. An [ND] fact may well be
true, and may even be what every implementation does, but the design must not rest on it
without an empirical check of its own.

A third mark is needed here and is used sparingly: **[I]** marks an *inference by
composition* — two documented facts that together imply a third, where AWS never writes the
third sentence. An [I] is stronger than an [ND] and weaker than a [G].

---

## Verdict

Six questions, six answers, in one line each:

1. **6 MB each way** ([G]), and the 4 MiB record cap is **safe** — but only with ~683 KiB of
   headroom, and only under the *conservative* reading that the limit is measured after
   base64 ([I], not [G]). See [§1](#1-function-url-payload-limits).
2. The principal arrives at **`requestContext.authorizer.iam.*`** with exactly the fields the
   map assumed ([G]) — but the session name in `userArn` is the problem below. See
   [§2](#2-iam-auth-on-a-function-url-the-callers-principal).
3. `GetCallerIdentity` returns `{Account, Arn, UserId}` ([G]), needs **no IAM permission and
   cannot be denied** ([G]), and is one extra SigV4 target: service `sts`, `POST` with a form
   body. See [§3](#3-stsgetcalleridentity).
4. Sign with service **`lambda`** and the function's region, and the caller now needs **two**
   actions, not one — `lambda:InvokeFunctionUrl` *and* `lambda:InvokeFunction`, as of
   October 2025. See [§4](#4-signing-a-function-url-request).
5. `put_object(IfNoneMatch='*')` is supported ([G]); branch on **HTTP status**, not on the
   error-code string. See [§5](#5-conditional-put-from-the-gateway).
6. SAML + SCIM from the Entra gallery app ([G]); `sso_role_name` is the **permission set**
   name, not the role name ([G]); UPN → Identity Center user name is the documented
   *intent* but **never stated as the gallery app's SCIM default** ([ND]). See
   [§6](#6-identity-center--entra-id).

### The one finding that threatens the design

> **[ND] AWS documents nowhere what the role session name is for an IAM Identity Center
> permission-set session.**

The map's identity plan is: `client.user` = the Identity Center user name (Entra UPN), and
the gateway checks `client.user` against "the caller's name" read out of the request context.
The only place a name *could* come from in that context is the session-name tail of
`userArn`. That tail is undocumented for Identity Center sessions.

This is not a gap that a more careful search closes. Two independent searches converged on
the same answer, having read between them: the Identity Center pages on IAM roles created by
Identity Center, referencing permission sets, attributes for access control, attribute
mappings, identity-enhanced role sessions, CloudTrail information and CloudTrail use cases;
the IAM pages on identifiers, policy variables, condition keys and monitoring assumed-role
actions; and the STS API reference. **No statement exists.** Worse, AWS actively steers
integrators *away* from this approach:

> "We recommend you use `userId` and `identityStoreArn` for identifying the user behind IAM
> Identity Center CloudTrail events. The `userName` and `principalId` fields under the
> `userIdentity` element are no longer available."
> — [CloudTrail use cases for IAM Identity Center](https://docs.aws.amazon.com/singlesignon/latest/userguide/sso-cloudtrail-use-cases.html)

and documents the very attribute the session name would presumably be derived from as
*mutable*:

> "`username` – A customer-provided value that **users usually sign in with**. The value can
> change (for example, with a SCIM update)."
> — [same page](https://docs.aws.amazon.com/singlesignon/latest/userguide/sso-cloudtrail-use-cases.html)

And where AWS *does* show an Identity Center session ARN, the session name is an opaque
service-generated string, not a user identity — e.g.
`arn:aws:sts::123456789012:assumed-role/accessGrantsTestRole/access-grants-e653760c-4e8b-44fd-94d9-309e035b75ab`
([Lake Formation Identity Center CloudTrail logs](https://docs.aws.amazon.com/lake-formation/latest/dg/identity-center-ct-logs.html)).
The identity-enhanced role session page, which is the one page whose whole subject is
carrying a user identity into a role session, uses the deliberately generic
`arn:aws:sts::111111111111:assumed-role/MyRole/MySession` and carries the identity in
`sts:identity_context` instead —
[source](https://docs.aws.amazon.com/singlesignon/latest/userguide/trustedidentitypropagation-identity-enhanced-iam-role-sessions.html).

**What saves the design is that it does not actually need the session name to be trustworthy
in the AWS sense — it needs the client and the gateway to derive the *same* string.** The
client reads `sts:GetCallerIdentity.Arn`; the gateway reads `userArn`. If those two strings
are equal, the check "`client.user` equals the caller's name" reduces to a string comparison
on whatever the session name happens to be, and the gateway never has to know that it is a
UPN. That is a much weaker requirement — but it is *also* [ND] (§3), so it is the thing to
verify first. See [§7](#7-what-must-be-verified-empirically); this feeds #54 and #55.

---

## 1. Function URL payload limits

### 1.1 The numbers

| Quota | Value | Mark |
|---|---|---|
| Invocation payload, synchronous | **6 MB each for request and response** | [G] |
| Streamed response, synchronous | 200 MB | [G] |
| Invocation payload, asynchronous | 1 MB | [G] |
| Request line + header values, combined | 1 MB | [G] |
| Function timeout | 900 s (15 min) | [G] |

Source: [Lambda quotas](https://docs.aws.amazon.com/lambda/latest/dg/gettingstarted-limits.html).
Restated for the API: "For synchronous invocations, the maximum payload size is 6 MB." —
[API_Invoke](https://docs.aws.amazon.com/lambda/latest/api/API_Invoke.html).

**"MB" here means MiB.** The quotas page says so explicitly:

> "The Lambda documentation, log messages, and console use the abbreviation MB (rather than
> MiB) to refer to 1,024 KB."
> — [Lambda quotas](https://docs.aws.amazon.com/lambda/latest/dg/gettingstarted-limits.html)

So the limit is **6,291,456 bytes**, not 6,000,000. This matters: the whole headroom argument
below is 699,048 bytes, which is smaller than the 291,456-byte difference between the two
readings would leave if we had guessed wrong in the other direction.

### 1.2 There is no function-URL-specific quota [ND]

The map's phrasing ("function URL limit is 6 MB") happens to land on the right number, but
not for the stated reason. **AWS publishes no payload quota specific to function URLs at
all.** The string "function URL" does not appear in the Lambda quotas table, and none of the
function URL pages state a payload size — checked:
[quotas](https://docs.aws.amazon.com/lambda/latest/dg/gettingstarted-limits.html),
[urls-configuration](https://docs.aws.amazon.com/lambda/latest/dg/urls-configuration.html),
[urls-invocation](https://docs.aws.amazon.com/lambda/latest/dg/urls-invocation.html),
[urls-monitoring](https://docs.aws.amazon.com/lambda/latest/dg/urls-monitoring.html),
[function URL vs API Gateway](https://docs.aws.amazon.com/lambda/latest/dg/furls-http-invoke-decision.html).

The general 6 MB synchronous invocation-payload quota is the only documented number that can
apply, so it is the number to design against — but record that it is inherited, not stated.

### 1.3 Base64: when, and does it count? [G] then [ND]

**When** — the event carries the flag, and the gateway must read it:

> "`body` – The body of the request. **If the content type of the request is binary, the body
> is base64-encoded.**"
> "`isBase64Encoded` – `TRUE` if the body is a binary payload and base64-encoded. `FALSE`
> otherwise."
> — [Invoking function URLs](https://docs.aws.amazon.com/lambda/latest/dg/urls-invocation.html)

**[ND] AWS does not define which content types count as "binary" for a function URL.** There
is no `binaryMediaTypes` setting (that is an API Gateway REST API concept) and no published
text-vs-binary list. So "will `application/cbor` arrive base64?" is not answerable from
primary sources. **Consequence for the gateway: read `isBase64Encoded` and decode
conditionally. Never hardcode either branch.** A record is CBOR, so the binary branch is the
expected one — but a gateway that assumes it will mis-decode the day the assumption is wrong,
and the failure is silent (a CBOR decode error on a perfectly good record) rather than loud.

**Does it count toward the 6 MB?** **[ND] — not documented either way.** This is the question
the ticket flagged as critical, and AWS has never written the sentence. Three documented
facts point one way:

1. The quota is attached to the **invocation payload**, worded as the JSON: "**Payload** – The
   JSON that you want to provide to your Lambda function as input. The maximum payload size is
   6 MB…" — [API_Invoke](https://docs.aws.amazon.com/lambda/latest/api/API_Invoke.html).
2. The error names the JSON, not the wire body: `RequestTooLargeException` — "The request
   payload exceeded the `Invoke` **request body JSON input quota**." (HTTP 413) — same page.
3. The base64 string lives *inside* that JSON, in the `body` field —
   [urls-invocation](https://docs.aws.amazon.com/lambda/latest/dg/urls-invocation.html).

**[I] Together these imply the binding limit is on the post-base64 JSON event.** Design
against that, the conservative reading.

### 1.4 Is the 4 MiB cap safe? Yes, with 683 KiB of headroom

Under the conservative reading, with `n` the raw record size:

```
base64(n)     = ceil(n/3) * 4
4 MiB         = 4,194,304 B
base64(4 MiB) = 1,398,102 * 4 = 5,592,408 B
6 MB          =                 6,291,456 B
headroom      =                   699,048 B  ≈ 683 KiB ≈ 11.1% of the limit
```

The headroom must cover the JSON envelope: `requestContext` (including the whole
`authorizer.iam` object and the `userArn`), headers, cookies, query string. Base64's output
alphabet needs no JSON string escaping, so the `body` field costs exactly its own length plus
two quotes — the envelope is the only consumer of the 683 KiB, and an envelope is kilobytes,
not hundreds of kilobytes.

**Break-even raw size: `6,291,456 / 4 * 3` = 4,718,592 B = exactly 4.5 MiB.** So the 4 MiB cap
sits half a MiB of raw payload below the cliff even under the pessimistic reading, and is
trivially safe under the optimistic one. **The 4 MiB cap is sound.** [I]

Note it is sound *with* a caveat the map should absorb: 4 MiB is not "comfortably under 6 MB",
it is 89% of the limit once encoded. There is no room to raise the cap to 5 MiB later without
re-deriving this.

### 1.5 Other quotas that touch the design

- **Response streaming raises only the response limit**, to 200 MB, and is irrelevant here —
  the gateway's response is an ack. It is also Node.js-only on managed runtimes ("For other
  languages, including Python, you can use a custom runtime…") and **not supported for
  function URLs in a VPC**. No doc states that streaming raises the *request* limit.
  — [Response streaming](https://docs.aws.amazon.com/lambda/latest/dg/configuration-response-streaming.html)
- **Throttling** — "Whenever your function concurrency exceeds the reserved concurrency, your
  function URL returns an HTTP `429` status code"; max RPS is 10× reserved concurrency.
  — [urls-configuration](https://docs.aws.amazon.com/lambda/latest/dg/urls-configuration.html).
  The client's error taxonomy needs a 429 branch distinct from a 412.
- **No PrivateLink** — "You can access your function URL through the public Internet only.
  While Lambda functions do support AWS PrivateLink, function URLs do not." — same page.
- **[ND] No function-URL-layer timeout is documented** distinct from the function's own 900 s
  ceiling. The commonly-repeated "function URLs time out at 15 minutes" is the *function*
  timeout, not a URL-layer one. Timeouts surface as `Url5xxCount` —
  [urls-monitoring](https://docs.aws.amazon.com/lambda/latest/dg/urls-monitoring.html).
- **`InvokeFunctionUrl` is a CloudTrail *data* event, off by default** — "By default,
  CloudTrail doesn't log `InvokeFunctionUrl` requests, which are considered data events."
  — [urls-monitoring](https://docs.aws.amazon.com/lambda/latest/dg/urls-monitoring.html).
  Relevant if auditing gateway callers via CloudTrail is ever wanted; it must be turned on.

---

## 2. IAM auth on a function URL: the caller's principal

### 2.1 The event fields — confirmed exactly as the map assumed [G]

The event follows "the same schema as the Amazon API Gateway payload format version 2.0", but
the `authorizer.iam` object is the function-URL-specific variant — API Gateway's v2.0 example
carries `authorizer.jwt` instead, so
[urls-invocation](https://docs.aws.amazon.com/lambda/latest/dg/urls-invocation.html) is the
only authoritative source for it. Documented fragment, verbatim:

```json
"requestContext": {
  "accountId": "123456789012",
  "apiId": "<urlid>",
  "authentication": null,
  "authorizer": {
      "iam": {
              "accessKey": "AKIA...",
              "accountId": "111122223333",
              "callerId": "AIDA...",
              "cognitoIdentity": null,
              "principalOrgId": null,
              "userArn": "arn:aws:iam::111122223333:user/example-user",
              "userId": "AIDA..."
      }
  }
}
```

| Field | Documented description | Example |
|---|---|---|
| `authorizer` | "An object that contains information about the caller identity, if the function URL uses the `AWS_IAM` auth type. Otherwise, Lambda sets this to `null`." | — |
| `…iam.accessKey` | "The access key of the caller identity." | `AKIAIOSFODNN7EXAMPLE` |
| `…iam.accountId` | "The AWS account ID of the caller identity." | `111122223333` |
| `…iam.callerId` | "The ID (user ID) of the caller." | `AIDACKCEVSQ6C2EXAMPLE` |
| `…iam.cognitoIdentity` | "Function URLs don't use this parameter. Lambda sets this to `null` or excludes this from the JSON." | `null` |
| `…iam.principalOrgId` | "The principal org ID associated with the caller identity." | `AIDACKCEVSQORGEXAMPLE` |
| `…iam.userArn` | "The user Amazon Resource Name (ARN) of the caller identity." | `arn:aws:iam::111122223333:user/example-user` |
| `…iam.userId` | "The user ID of the caller identity." | `AIDACOSFODNN7EXAMPLE2` |

Source for the whole table:
[Invoking Lambda function URLs](https://docs.aws.amazon.com/lambda/latest/dg/urls-invocation.html).

Three gotchas for the gateway's parser:

- **Fields may be absent, not merely null.** "Lambda sets this to `null` **or excludes this
  from the JSON**." A `KeyError` on `cognitoIdentity` or `principalOrgId` is a real failure
  mode.
- **[ND] `callerId` and `userId` are documented as distinct fields with different example
  values** (`AIDACKCEVSQ6C2EXAMPLE` vs `AIDACOSFODNN7EXAMPLE2`) and AWS never explains the
  difference. Do not assume they are equal; pick one deliberately.
- **Every documented `userArn` example is an IAM *user*.** There is no documented function-URL
  event example for an assumed-role caller, which is the only kind the gateway will ever see.

### 2.2 Assumed-role shapes [G] for the shapes, [I] for this event

The shapes themselves are documented, just not on the Lambda page:

> syntax: `arn:aws:sts::{account}:assumed-role/{role-name}/{role-session-name}`
> example: "The active session of someone assuming the role of 'Accounting-Role', with a role
> session name of 'Mary': `arn:aws:sts::123456789012:assumed-role/Accounting-Role/Mary`"
> — [IAM identifiers](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_identifiers.html)

> `aws:userid` for an assumed role: "`{role-id}:{caller-specified-role-name}` where `role-id`
> is the unique id of the role and the caller-specified-role-name is specified by the
> RoleSessionName parameter passed to the AssumeRole request."
> — [IAM policy variables](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_variables.html)

Role unique IDs carry the `AROA` prefix ([IAM identifiers](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_identifiers.html)),
and a concrete pair appears at
[Monitoring assumed-role actions](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_temp_control-access_monitor.html):
`"assumedRoleId": "AROACQRSTUVWRAOEXAMPLE:matjac"` with
`"arn": "arn:aws:sts::111122223333:assumed-role/MateoRole/matjac"`.

**A load-bearing detail, documented only through differing placeholders [I]:** in the IAM
identifiers syntax table the *IAM role* ARN is written
`arn:aws:iam::{account}:role/{role-name-with-path}` while the *STS assumed-role* ARN is
written `assumed-role/{role-name}/…` — **role-name, not role-name-with-path**. So the
`/aws-reserved/sso.amazonaws.com/<region>/` path that appears in an Identity Center role's IAM
ARN is **absent** from the assumed-role ARN the gateway will see. AWS never says this in a
sentence. It matters: a gateway matching `userArn` against a configured role ARN will never
match if it expects the path.

**Session name constraints** (`RoleSessionName`, from
[API_AssumeRole](https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRole.html)):
2–64 characters, alphanumerics plus `_ . , + = @ -`. **An email address or UPN is a legal
session name** — `@`, `.` and `-` are all in the set — **but a UPN longer than 64 characters
is not.** If the design does end up comparing UPNs, that is a real constraint on the Entra
tenant's naming, and a user whose UPN exceeds 64 characters would be silently unable to write.

### 2.3 The Identity Center role name [G], and the session name [ND]

**Role name — documented precisely:**

> "When you assign a permission set to an AWS account, IAM Identity Center creates a role with
> a name that begins with `AWSReservedSSO_`."
> — [Referencing permission sets](https://docs.aws.amazon.com/singlesignon/latest/userguide/referencingpermissionsets.html)

- Name: `AWSReservedSSO_<permission-set-name>_<unique-suffix>`
- IAM ARN: `arn:aws:iam::<account>:role/aws-reserved/sso.amazonaws.com/<region>/AWSReservedSSO_<permission-set-name>_<unique-suffix>`
- Documented example: `AWSReservedSSO_DatabaseAdministrator_1234567890abcdef`
- "If your identity source in IAM Identity Center is hosted in us-east-1, there is no
  `<aws-region>` in the ARN."

Two warnings from the same page, both of which the gateway's policy config must respect:

- **[ND] The suffix is called "a unique suffix", never "a hash".** Its length and alphabet are
  not a contract; only the example looks like 16 hex characters. **Do not regex on hex-16.**
  (The ticket's phrasing "`AWSReservedSSO_<PermissionSetName>_<hash>`" should be corrected.)
- **The suffix is unstable.** "If you delete all assignments to this permission set in the AWS
  account, the corresponding role that IAM Identity Center created is also deleted. If you
  make a new assignment to the same permission set later, IAM Identity Center creates a new
  role for the permission set. The name and ARN of the new role include **a different, unique
  suffix**." AWS's own remedy is wildcarding: "the `Condition` element includes the `ArnLike`
  condition operator and uses a wildcard at the end of the permission set role ARN, rather
  than a unique suffix." **Never pin the gateway's authorization to a full role name.**

**Session name — not documented.** See [the Verdict](#the-one-finding-that-threatens-the-design).
The nearest documented statements, and why each falls short:

1. `sts:RoleSessionName`'s availability clause **does not list SSO or SAML at all**: "This key
   is present in the request when the principal assumes the role using the AWS Management
   Console, any assume-role CLI command, or any AWS STS `AssumeRole` API operation." —
   [IAM condition keys](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_iam-condition-keys.html).
   The key is framed as *caller-specified*, which is exactly what the Identity Center path is
   not.
2. The generic SAML federation path does define a
   `https://aws.amazon.com/SAML/Attributes/RoleSessionName` attribute (max 64 chars) —
   [Configuring SAML assertions](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_saml_assertions.html)
   — but **Identity Center permission sets do not use that customer-configured path**, and no
   AWS doc states what Identity Center populates instead.
3. ABAC carries Identity Center attributes as **session tags**, not as the session name: "they
   are sent as session tags that you can reference using the `aws:PrincipalTag/{tag-key}`
   condition key" —
   [Attributes for access control](https://docs.aws.amazon.com/singlesignon/latest/userguide/attributesforaccesscontrol.html).
   That page mentions role session name zero times.
4. The closest thing to support for "session name == UPN" is that the Identity Center
   `username` attribute defaults to the UPN for an AD identity source — "username |
   `${userprincipalname}`" —
   [Attribute mappings](https://docs.aws.amazon.com/singlesignon/latest/userguide/attributemappingsconcept.html).
   **But no AWS doc connects the `username` attribute to the STS role session name**, and the
   same page notes administrators may remap it.

**Documented alternatives, if the session name proves unusable.** Match on the *role ARN
prefix* — `…:assumed-role/AWSReservedSSO_<PermissionSetName>_*` — which is documented and
which AWS itself recommends wildcarding; that authorizes a *group* (everyone holding the
permission set) rather than naming an individual. Individual attribution would then have to
come from ABAC session tags (`aws:PrincipalTag/<key>`, configurable per Identity Center
attribute) or from the identity-enhanced role session's `sts:identity_context`. Both are
documented; both are more machinery than the map assumes.

---

## 3. `sts:GetCallerIdentity`

### 3.1 Response [G]

Three elements only, returned as XML (`Content-Type: text/xml`):

| Element | Documented description |
|---|---|
| `Account` | "The AWS account ID number of the account that owns or contains the calling entity." |
| `Arn` | "The AWS ARN associated with the calling entity." Length 20–2048. |
| `UserId` | "The unique identifier of the calling entity. The exact value depends on the type of entity that is making the call. The values returned are those listed in the **aws:userid** column in the Principal table…" |

Source: [API_GetCallerIdentity](https://docs.aws.amazon.com/STS/latest/APIReference/API_GetCallerIdentity.html).
boto3 mirrors it exactly as `{'UserId': ..., 'Account': ..., 'Arn': ...}` —
[boto3 sts.get_caller_identity](https://docs.aws.amazon.com/boto3/latest/reference/services/sts/client/get_caller_identity.html).

The API reference's own **Example 2** ("Called by user created with AssumeRole") settles the
assumed-role rendering [G]:

```xml
<Arn>arn:aws:sts::123456789012:assumed-role/my-role-name/my-role-session-name</Arn>
<UserId>ARO123EXAMPLE123:my-role-session-name</UserId>
```

So `Arn` and `UserId` carry the session name in different shapes, and `UserId` is **not** a
prefix or suffix of `Arn`. A client deriving a name must parse the `Arn` tail, or split
`UserId` on `:`.

### 3.2 No permission needed, and it cannot be denied [G]

This is a genuinely useful property for the client, and worth stating plainly:

> "**No permissions are required to perform this operation.** If an administrator attaches a
> policy to your identity that explicitly denies access to the `sts:GetCallerIdentity` action,
> **you can still perform this operation**. Permissions are not required because the same
> information is returned when access is denied."
> — [API_GetCallerIdentity](https://docs.aws.amazon.com/STS/latest/APIReference/API_GetCallerIdentity.html)

So the client's `open` can always fill `client.user`, in any account, under any policy. There
is no "ask the admin to grant STS" step in the setup docs.

### 3.3 Does its `Arn` equal the gateway's `userArn`? [ND] — verify this first

**This is the hinge the design actually turns on, and it is undocumented.** No AWS page
relates `GetCallerIdentity.Arn` to a function URL's
`requestContext.authorizer.iam.userArn`. The Lambda page's only `userArn` example is an IAM
user; the STS page's assumed-role example is not about function URLs. The two strings
*should* be the same rendering of the same principal, but "should" is not a citation.

**[ND] Nor does any page compose the full STS ARN for an Identity Center session.** The form
`arn:aws:sts::<account>:assumed-role/AWSReservedSSO_<PermissionSet>_<suffix>/<session>` is the
logical composition of §2.2's ARN shape with §2.3's role name, and §2.2's placeholder
difference says the `aws-reserved/…` path is dropped — but that is [I], assembled from three
pages, not a documented example.

### 3.4 Calling it: the extra SigV4 target

The client already signs for `s3`; `sts` is one more target, and the differences are small.

- **Method: GET and POST both work** [G] — "IAM and AWS STS support GET and POST requests for
  all actions… However, GET requests are subject to the limitation size of a URL". HTTPS is
  mandatory. — [Making query requests](https://docs.aws.amazon.com/IAM/latest/UserGuide/programming.html)
- **POST form body** [G], from the API reference's own sample request:

  ```http
  POST / HTTP/1.1
  Host: sts.amazonaws.com
  Content-Type: application/x-www-form-urlencoded
  X-Amz-Date: 20160126T215751Z
  Authorization: AWS4-HMAC-SHA256 Credential=AKIAI44QH8DHBEXAMPLE/20160126/us-east-1/sts/aws4_request,
          SignedHeaders=host;user-agent;x-amz-date, Signature=...

  Action=GetCallerIdentity&Version=2011-06-15
  ```

  — [API_GetCallerIdentity](https://docs.aws.amazon.com/STS/latest/APIReference/API_GetCallerIdentity.html)
- **Service name `sts`** [G] and, for the global endpoint, **region `us-east-1`** — visible in
  that sample's credential scope `…/20160126/us-east-1/sts/aws4_request` against
  `Host: sts.amazonaws.com`. **[ND] There is no prose sentence saying "sign the global
  endpoint with us-east-1"** — this is example-level evidence. It is corroborated by "Requests
  made to the AWS STS global endpoint have a value of `us-east-1` for the
  `aws:RequestedRegion` condition key, regardless of which Region served the request" —
  [Regional endpoints](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_temp_region-endpoints.html).
- **The session token header must be inside the canonical request** [G] — the assumed-role
  sample includes `X-Amz-Security-Token` in `SignedHeaders=host;user-agent;x-amz-date;x-amz-security-token`.
  Same source. (Contrast §4.3, where Lambda's requirement is unstated.)
- **`Content-Type` must be signed** whenever present, per the generic rule in §4.2 — so the
  form body's `application/x-www-form-urlencoded` goes into `SignedHeaders`.

### 3.5 Which region to sign for [G]

> "AWS Security Token Service (AWS STS) is available both as a global and Regional service.
> Some of AWS SDKs and CLIs use the global service endpoint (`https://sts.amazonaws.com`) by
> default, while some use the Regional service endpoints (`https://sts.{region}.{partition_domain}`)."

Best practice is regional; customers outside the commercial partition **must** use regional.
The setting is `sts_regional_endpoints` / `AWS_STS_REGIONAL_ENDPOINTS`, **default `regional`**,
and "All new SDK major versions releasing after July 2022 will default to `regional`." To hit
the global endpoint while regional is enabled, set the region to `aws-global`.
— [STS regionalized endpoints](https://docs.aws.amazon.com/sdkref/latest/guide/feature-sts-regionalized-endpoints.html)

Per-SDK behaviour differs, which is a trap for a hand-rolled client that tries to match "what
the CLI does": AWS CLI v1 is `legacy`/global; CLI v2 is regional with a global fallback when
no region is set; boto3 defaults to `regional` but its "Default service client target STS
Endpoint" is the global one. Same source.

**Recommendation: sign the regional endpoint `sts.<region>.amazonaws.com` with the same region
the client already uses for S3.** It avoids the `us-east-1`-for-global special case entirely,
it is AWS's stated best practice, and it is the only form that works in GovCloud or China. The
global endpoint is also single-homed — "it's hosted in a single AWS Region, US East (N.
Virginia), and like other endpoints, it doesn't provide automatic failover" —
[STS endpoints](https://docs.aws.amazon.com/general/latest/gr/sts.html).

---

## 4. Signing a function URL request

### 4.1 Signing is mandatory, and Lambda checks it [G]

> "If your function URL uses the `AWS_IAM` auth type, you must sign each HTTP request using
> AWS Signature Version 4 (SigV4)… When your function URL receives a request, Lambda also
> calculates the SigV4 signature. **Lambda processes the request only if the signatures
> match.**"
> — [Invoking function URLs](https://docs.aws.amazon.com/lambda/latest/dg/urls-invocation.html)

The endpoint is `https://<url-id>.lambda-url.<region>.on.aws` (same page).

### 4.2 Service name and region — right answer, weak citation [ND in prose, [G] by example]

**Service `lambda`, region = the function's region.** The Lambda function URL pages **never
state the SigV4 service name in prose.** The strongest primary evidence is the CloudFront
origin-access-control page, whose official Python sample signs a POST to a function URL:

> `sign_request(request, credentials, region, 'lambda')`, with `region = "us-east-1"  # example`
> — [Restricting access to a Lambda function URL origin](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-restricting-access-to-lambda.html)

The same page's CloudFormation type uses `OriginAccessControlOriginType: lambda` with
`SigningProtocol: sigv4`. The region follows from the credential scope being
`YYYYMMDD/region/service/aws4_request`
([Create a signed request](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-create-signed-request.html))
and the endpoint carrying the region. The answer is not in doubt; the citation is indirect,
and worth recording as such.

### 4.3 Required headers [G], with one Lambda-specific gap

From [Create a signed AWS API request](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-create-signed-request.html):

- Canonical request is
  `HTTPMethod\nCanonicalURI\nCanonicalQueryString\nCanonicalHeaders\nSignedHeaders\nHashedPayload`.
- Must sign: "CanonicalHeaders list must include the following: HTTP `host` header. **If the
  `Content-Type` header is present in the request, you must add it** to the CanonicalHeaders
  list. Any `x-amz-*` headers that you plan to include in your request must also be added."
- **The payload hash is always part of the canonical request:** "`HashedPayload` – A string
  created using the payload in the body of the HTTP request as input to a hash function… If
  there is no payload in the request, you compute a hash of the empty string."
- Do not sign hop-by-hop headers (`connection`, `x-amzn-trace-id`, `user-agent`,
  `keep-alive`, `transfer-encoding`).
- `Authorization` format:
  `AWS4-HMAC-SHA256 Credential=<AKID>/<YYYYMMDD>/<region>/<service>/aws4_request, SignedHeaders=host;x-amz-date, Signature=<sig>`
  — no comma after the algorithm, commas between the other elements.

**`x-amz-content-sha256`:** the generic reference says it "is **required for Amazon S3** AWS
requests" and says nothing about Lambda. **The function URL pages never mention it.** The only
primary statement tying it to Lambda is again the CloudFront page, and it is unambiguous
there:

> "**Important**: If you use `PUT` or `POST` methods with your Lambda function URL, your users
> must compute the SHA256 of the body and include the payload hash value of the request body
> in the `x-amz-content-sha256` header when sending the request to CloudFront. **Lambda
> doesn't support unsigned payloads.**"
> — [Restricting access to a Lambda function URL origin](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-restricting-access-to-lambda.html)

**[ND] Whether that header is strictly required for a *direct* (non-CloudFront) function URL
call is not stated anywhere.** What is certain: the body's SHA-256 must be in the canonical
request's `HashedPayload` regardless, and `UNSIGNED-PAYLOAD` is an S3-only affordance —
consistent with "Lambda doesn't support unsigned payloads". **Safe choice: always send
`x-amz-content-sha256` with the real body hash and include it in `SignedHeaders`.** It is
never wrong, and it is what the one AWS sample does.

**`Host` must be signed, and against the function URL domain** [G] — AWS states this while
explaining a CloudFront failure mode, but the statement is about Lambda's validation:

> "Lambda will validate the signature against the host of the Lambda URL domain. If the
> signature isn't based on the Lambda URL domain, the host in the signature won't match the
> host used by the Lambda URL origin… the request will fail, resulting in a signature
> validation error."
> — same page

**`X-Amz-Security-Token`: [ND] for Lambda.** The generic rule is explicitly service-dependent:

> "When you use temporary security credentials, you must add `X-Amz-Security-Token` to the
> Authorization header or include it in the query string… **Some services require that you add
> `X-Amz-Security-Token` to the canonical request. Other services require only that you add
> `X-Amz-Security-Token` at the end, after you calculate the signature. Check the
> documentation for each AWS service for specific requirements.**"
> — [Create a signed request](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-create-signed-request.html)

**Lambda's documentation does not say which variant it uses.** Temporary credentials plainly
do work — the event surfaces `accessKey` and `principalOrgId`, and the CloudFront sample signs
with `boto3.Session().get_credentials()`. botocore's `SigV4Auth` signs `x-amz-security-token`
*into* the canonical request, which is the behaviour to match, but that is SDK behaviour, not
a Lambda statement. Since every writer here is an SSO user on temporary credentials, **this is
on the empirical checklist** (§7).

### 4.4 The IAM action — the map is out of date [G]

> "**Starting in October 2025, new function URLs will require both `lambda:InvokeFunctionUrl`
> and `lambda:InvokeFunction` permissions.**"
> "If you choose the `AWS_IAM` auth type, users who need to invoke your Lambda function URL
> must have the `lambda:InvokeFunctionUrl` and `lambda:InvokeFunction` permissions."
> — [Function URL security and auth](https://docs.aws.amazon.com/lambda/latest/dg/urls-auth.html)

Restated on [urls-invocation](https://docs.aws.amazon.com/lambda/latest/dg/urls-invocation.html):
"To invoke a function URL, you must have `lambda:InvokeFunctionUrl` and `lambda:InvokeFunction`
permissions."

**The ticket's `lambda:InvokeFunctionUrl` alone is no longer sufficient**, and a gateway
provisioned today is a "new function URL". The two condition keys pair with the two actions:

| Statement | Action | Condition |
|---|---|---|
| 1 | `lambda:InvokeFunctionUrl` | `"StringEquals": {"lambda:FunctionUrlAuthType": "AWS_IAM"}` |
| 2 | `lambda:InvokeFunction` | `"Bool": {"lambda:InvokedViaFunctionUrl": "true"}` |

- `lambda:FunctionUrlAuthType` – "Defines an enum value describing the auth type that your
  function URL uses. The value can be either `AWS_IAM` or `NONE`."
- `lambda:InvokedViaFunctionUrl` – "Restricts the `lambda:InvokeFunction` action to calls made
  through the function URL." And: "**If you don't include `lambda:InvokedViaFunctionUrl`, the
  principal can invoke your function through other invocation methods**, in addition to the
  function URL." — omitting it is a real privilege leak, not a formality.
- Via the CLI the two statements are added separately
  (`aws lambda add-permission … --function-url-auth-type AWS_IAM` and `… --invoked-via-function-url`).

All from [urls-auth](https://docs.aws.amazon.com/lambda/latest/dg/urls-auth.html).

**Resource ARN**: `arn:aws:lambda:<region>:<account-id>:function:<function-name>`, with
qualified forms `…:function:my-function:1` (version) and `…:function:my-function:TEST`
(alias). Matching is strict — "if your policy references the unqualified ARN, Lambda accepts
requests that reference the unqualified ARN but denies requests that reference a qualified
ARN"; `:*` matches any qualified ARN but denies the unqualified one; a trailing `*` matches
both. — [Lambda API permissions](https://docs.aws.amazon.com/lambda/latest/dg/lambda-api-permissions-ref.html).
The `urls-auth` examples all use the **unqualified** ARN. Note function URLs attach only to
`$LATEST` or an alias: "You can apply function URLs to any function alias, or to the `$LATEST`
unpublished function version." — [urls-configuration](https://docs.aws.amazon.com/lambda/latest/dg/urls-configuration.html).

**Identity-based vs resource-based** [G], and it decides how much the deploy script must do:

- **Same account** — "the principal must **either** have `lambda:InvokeFunctionUrl` and
  `lambda:InvokeFunction` permissions in their identity-based policy, **or** have permissions
  granted to them in the function's resource-based policy… a resource-based policy is optional
  if the user already has [those] permissions in their identity-based policy."
- **Cross-account** — "the principal must have **both** an identity-based policy… **and**
  permissions granted to them in a resource-based policy."
- Failure mode: "users get a **403 Forbidden** error code when they try to invoke your function
  URL."

Both from [urls-auth](https://docs.aws.amazon.com/lambda/latest/dg/urls-auth.html). Since the
writers' permission set lives in the same account as the gateway, either half suffices —
putting the grant in the **permission set's** policy is the option that keeps the gateway's
resource policy empty and the writer list in Identity Center.

### 4.5 Two things not to assume

- **[ND] Presigned (query-string) signing for function URLs is not documented as supported.**
  The function URL pages describe only header-based signing and never mention
  `X-Amz-Signature`/`X-Amz-Expires`. The generic spec defines query-string auth in general but
  its worked examples are S3-only
  ([Signing methods](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-authentication-methods.html)),
  and AWS's own survey of how services use presigned URLs lists Lambda `GetFunction` but **not
  function URLs**
  ([Prescriptive guidance, appendix A](https://docs.aws.amazon.com/prescriptive-guidance/latest/presigned-url-best-practices/appendix-a.html)).
  Do not design around it.
- **[ND] Whether a CORS preflight `OPTIONS` must itself be signed under `AWS_IAM` is not
  stated.** Function URLs do have a CORS config, and "For preflight requests such as OPTIONS
  requests, the configured CORS headers on the function URL take precedence. Lambda returns
  only these CORS headers in the response."
  ([urls-configuration](https://docs.aws.amazon.com/lambda/latest/dg/urls-configuration.html))
  — which reads as Lambda answering before the function runs. But browsers do not attach
  `Authorization` to preflights and AWS documents the interaction nowhere. Irrelevant to a
  Julia client; relevant if a browser ever calls the gateway.

---

## 5. Conditional put from the gateway

**This section is deliberately short: the S3 semantics are already settled in
[`s3-conditional-writes.md`](s3-conditional-writes.md), which covers the 412/409 taxonomy, the
`If-Match` comparison, the in-progress-MPU hazard, versioned-bucket behaviour and the MinIO
gap in full.** Only what is new for a *Python* gateway is recorded here, plus the points where
the present research either confirms or sharpens that note.

### 5.1 boto3 [G]

- The parameter is **`IfNoneMatch`** (type `string`), documented with the same wording as the
  API reference including "Expects the '\*' (asterisk) character." `IfMatch` likewise. So the
  call is `s3.put_object(Bucket=…, Key=…, Body=…, IfNoneMatch='*')`.
  — [boto3 s3.put_object](https://docs.aws.amazon.com/boto3/latest/reference/services/s3/client/put_object.html)
  (the older `boto3.amazonaws.com/v1/documentation/api/latest/…` URL 301-redirects here)
- Errors arrive as `ClientError` with the service's code **verbatim**: "The error response
  provided to your client from the AWS service follows a common structure and is **minimally
  processed and not obfuscated by Boto3**." The structure is
  `{'Error': {'Code': …, 'Message': …}, 'ResponseMetadata': {'HTTPStatusCode': …}}`.
  — [boto3 error handling](https://docs.aws.amazon.com/boto3/latest/guide/error-handling.html)

So the gateway reads `err.response['Error']['Code']` → `'PreconditionFailed'` (412) and
`'ConditionalRequestConflict'` (409), and `err.response['ResponseMetadata']['HTTPStatusCode']`
→ `412` / `409`.

### 5.2 Branch on the status, not the string [ND] — and this research adds a second reason

`s3-conditional-writes.md` already concludes that the XML `<Code>` is [ND] and that clients
must match on HTTP status, because `ConditionalRequestConflict` has no entry in S3's canonical
error-code list and the User Guide and API Reference disagree on its name. **That conclusion is
confirmed, and there is a further wrinkle:** the canonical error list's only 409-with-
conditional-wording entry is a *differently named* code —

> "Code: `OperationAborted` / Description: A conflicting conditional action is currently in
> progress against this resource. Try again. / HTTP Status Code: 409 Conflict"
> — [S3 error responses](https://docs.aws.amazon.com/AmazonS3/latest/API/API_Error.html)

while `PreconditionFailed` *is* in that list ("At least one of the preconditions you specified
did not hold. / HTTP Status Code: 412"). No primary doc reconciles `ConditionalRequestConflict`
with `OperationAborted`. **The gateway must key its retry branch off
`HTTPStatusCode == 409`**; if it must also match strings, it should accept both.

### 5.3 Points worth re-stating for the gateway [G]

- **Only `*` is accepted** for `If-None-Match` — "The `If-None-Match` header expects the \*
  (asterisk) value." An ETag there is not a supported form.
  — [Conditional writes](https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes.html)
- **`s3:PutObject` alone suffices** for `If-None-Match` — "To perform conditional writes with
  the HTTP `If-None-Match` header you must have the `s3:PutObject` permission." (`If-Match`
  additionally needs `s3:GetObject`.) Same source. This matches the map's "only the gateway
  role gets `PutObject`" — **no `GetObject` is needed by the gateway role for the commit
  itself.**
- **SigV4 is mandatory** — "To use conditional writes, you must use AWS Signature Version 4 to
  sign the request." Same source. boto3 does this; worth knowing it is a requirement, not a
  default.
- **Failed requests are still billed** — "You are only charged existing rates for the
  applicable requests, **including for failed requests**."
  — [Conditional requests](https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-requests.html)
  A hot retry loop on 412 costs money as well as time.
- **The 409 trigger is narrow**, and is *not* "two concurrent conditional writes" (that case is
  412): "You can also receive a `409 Conflict` response in the case of concurrent requests **if
  a delete request to an object succeeds before a conditional write operation on that object
  completes**."
  — [Conditional writes](https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes.html)
  An append-only chain never deletes, so 409 should be unreachable — handle it anyway, as that
  note already argues.
- **Not supported on S3 on Outposts** — "This functionality is not supported for S3 on
  Outposts." — [API_PutObject](https://docs.aws.amazon.com/AmazonS3/latest/API/API_PutObject.html).
  Irrelevant under ADR-0016 (AWS S3 only), but records the boundary.
- **[ND] Directory buckets (S3 Express One Zone):** PutObject marks many other headers "not
  supported for directory buckets" but carries **no such exclusion on `If-Match`/`If-None-Match`**,
  and no primary sentence affirmatively confirms support either. Not contradicted, not
  confirmed.
- **[ND] No storage-class restriction on conditional writes is stated** anywhere — which is the
  absence of a stated restriction, not a stated absence of one.

---

## 6. Identity Center + Entra ID

### 6.1 The documented setup [G]

From [Microsoft Entra ID as an identity source](https://docs.aws.amazon.com/singlesignon/latest/userguide/idp-microsoft-entra.html)
(note: the `gs-entra.html` URL returns an empty shell; `idp-microsoft-entra.html` is the live
page), mirrored by Microsoft at
[the SSO tutorial](https://learn.microsoft.com/en-us/entra/identity/saas-apps/aws-single-sign-on-tutorial)
and [the provisioning tutorial](https://learn.microsoft.com/en-us/entra/identity/saas-apps/aws-single-sign-on-provisioning-tutorial):

1. Add the **AWS IAM Identity Center** enterprise app from the Entra gallery; assign users.
2. In Identity Center: **Settings → Identity source → Actions → Change identity source →
   External identity provider**. Download the **service provider metadata**; copy the **AWS
   access portal sign-in URL**.
3. In Entra: **Single sign-on → SAML → Upload metadata file**; check **Identifier** (Issuer)
   and **Reply URL (ACS)**; paste the access-portal URL into **Sign on URL**; download the
   **Federation Metadata XML**.
4. Back in Identity Center: upload the IdP metadata, type `ACCEPT`, **Change identity source**.
5. SCIM: **Settings → Automatic provisioning → Enable**; copy the **SCIM endpoint**
   (`https://scim.<region>.amazonaws.com/<id>/scim/v2`) and **Access token** — "**This is the
   only time where you can obtain the SCIM endpoint and access token.**"
6. In Entra → the app → **Provisioning → Automatic**: SCIM endpoint into **Tenant URL**, token
   into **Secret Token**, **Test Connection**, **Save**, assign users/groups, **Start
   provisioning**.

Three constraints the wizard ticket should carry:

- **Nested groups do not work** — "The Microsoft Entra ID user provisioning service cannot read
  or provision users in nested groups. **Only users that are immediate members of an explicitly
  assigned group can be read and provisioned.**" — AWS page above.
- **Required SCIM attributes** — "When provisioning a user to AWS, they're required to have the
  following attributes: firstName, lastName, displayName, userName". Multi-valued `email` or
  `phone numbers` are rejected by AWS. — Microsoft provisioning tutorial.
- **Guest users break** unless the NameID claim is conditional — a guest's email is
  `user_domain.com#EXT#@tenant.onmicrosoft.com`. AWS's fix: "For Microsoft Entra ID users,
  create a user type for members with source attribute set to `user.userprincipalname`. For
  Microsoft Entra ID guest users, create a user type for external guests with the source
  attribute set to `user.mail`." — AWS page above.

### 6.2 Which Entra attribute becomes the Identity Center user name — [ND], with a caveat

The map states "`client.user` = the Identity Center user name (Entra UPN)". **That is the
documented intent and almost certainly what a tenant will observe, but it is not stated as the
Entra gallery app's SCIM default mapping in any primary source.**

What the sources actually say:

- Microsoft's provisioning tutorial lists **only the SCIM target attributes** (`userName`,
  `active`, `displayName`, `emails[type eq "work"].value`, `name.givenName`,
  `name.familyName`, `externalId`, …) under the columns *Attribute | Type | Supported for
  Filtering*. `userName` is the sole attribute marked **supported for filtering**, i.e. the
  matching key. **The table has no source-attribute column**, so it never says
  `userPrincipalName → userName`.
  — [Provisioning tutorial](https://learn.microsoft.com/en-us/entra/identity/saas-apps/aws-single-sign-on-provisioning-tutorial)
- AWS's Entra tutorial creates the Entra test user by **User principal name**
  (`NikkiWolf@example.org`) and then: "For both **Username** and **Email address** – Enter the
  **same** `NikkiWolf@yourcompanydomain.extension` that you used when creating your Microsoft
  Entra ID user." — [AWS Entra page](https://docs.aws.amazon.com/singlesignon/latest/userguide/idp-microsoft-entra.html)
- Microsoft: "Make sure the username and email address entered in AWS IAM Identity Center
  matches the user's Microsoft Entra sign-in name." — [SSO tutorial](https://learn.microsoft.com/en-us/entra/identity/saas-apps/aws-single-sign-on-tutorial)
- For the **Active Directory** identity source (a different source, but the only one where AWS
  writes the mapping down) the default is explicit: "username | `${userprincipalname}`", and
  "'username' is a mandatory attribute in IAM Identity Center."
  — [Attribute mappings](https://docs.aws.amazon.com/singlesignon/latest/userguide/attributemappingsconcept.html)

**Conclusion: UPN → `userName` is the documented intent and the AD-source default, and it is
what every AWS and Microsoft walkthrough implies — but no primary page states it as the Entra
gallery app's SCIM default, and the mapping is editable per tenant.** Verify in the tenant's
Provisioning → Attribute Mapping blade rather than assuming. This is a setup-documentation
item, not a code item.

**Email**: the SCIM attribute is `emails[type eq "work"].value`; AWS's manual-user step sets
Username and Email to the same UPN-shaped string; for the AD source AWS documents
`emails[?primary].value` ← `${mail}` with "The email attribute in IAM Identity Center must be
unique within the directory."

**Uniqueness and whether it is the login name** [G]:

> "**A unique string used to identify the user.** The length limit is 128 characters… This
> value is specified at the time the user is created and stored as an attribute of the user
> object in the identity store. `Administrator` and `AWSAdministrators` are reserved names…"
> — [IdentityStore CreateUser](https://docs.aws.amazon.com/singlesignon/latest/IdentityStoreAPIReference/API_CreateUser.html)

Creating a duplicate returns `ConflictException`. And it is the sign-in name — "`username` – A
customer-provided value that users usually sign in with" — but **mutable**: "The value can
change (for example, with a SCIM update)"
([CloudTrail use cases](https://docs.aws.amazon.com/singlesignon/latest/userguide/sso-cloudtrail-use-cases.html)).

**Note the length mismatch.** The Identity Center user name may be up to **128** characters,
but a role session name is capped at **64** (§2.2). If the session name really is the user
name, users with a UPN between 65 and 128 characters are in undocumented territory.

### 6.3 Permission set → assumable role [G]

> "A permission set is a template that you create and maintain that defines a collection of one
> or more IAM policies." … "When you assign a permission set, IAM Identity Center creates
> corresponding IAM Identity Center-controlled IAM roles in each account, and attaches the
> policies specified in the permission set to those roles. **IAM Identity Center manages the
> role, and allows the authorized users you've defined to assume the role, by using the IAM
> Identity Center User Portal or AWS CLI.**"
> — [Permission sets](https://docs.aws.amazon.com/singlesignon/latest/userguide/permissionsetsconcept.html)

Also: "Each permission set that you create and assign to your user appears as an available role
in the AWS access portal." (same page) and "you might notice role names beginning with
'AWSReservedSSO\_'. These are the roles which the IAM Identity Center service has created in the
account" —
[Identity Center and IAM roles](https://docs.aws.amazon.com/singlesignon/latest/userguide/identity-center-and-iam-roles.html).
Name and ARN formats are in §2.3.

**Session duration**: a permission-set property, **default 1 hour, max 12 hours**; the access
portal session defaults to 8 hours, max 90 days.
— [Permission sets](https://docs.aws.amazon.com/singlesignon/latest/userguide/permissionsetsconcept.html).
Relevant to the client: a long replay or a long-lived `ChainTable` handle can outlive its
credentials, so the signer must tolerate refreshed credentials rather than caching a signing
key for the process lifetime.

### 6.4 `sso_role_name` is the permission set name, not the role name [G]

A likely source of confusion in the deploy script and the setup docs, so quoted in full:

> "**`sso_role_name`** – The name of a **permission set** provisioned as an IAM role that
> defines the user's resulting permissions. The role must exist in the AWS account specified by
> `sso_account_id`. **Use the role name, not the role Amazon Resource Name (ARN).**"
> — [SSO credentials](https://docs.aws.amazon.com/sdkref/latest/guide/feature-sso-credentials.html)

The value is the **bare permission set name** (e.g. `PowerUserAccess`), **not** the
`AWSReservedSSO_…` role name — AWS's own examples use `readOnly` and `SampleRole`. Shape
produced by `aws configure sso`:

```ini
[profile my-dev-profile]
sso_session = my-sso
sso_account_id = 123456789011
sso_role_name = readOnly
region = us-west-2

[sso-session my-sso]
sso_region = us-east-1
sso_start_url = https://my-sso-portal.awsapps.com/start
sso_registration_scopes = sso:account:access
```

"The `sso_region` and `sso_start_url` settings must be set within the `sso-session` section.
Typically, `sso_account_id` and `sso_role_name` must be set in the `profile` section so that
the SDK can request SSO credentials." And `aws sso login`: "Your IAM Identity Center session
credentials are cached and the AWS CLI uses them to securely retrieve AWS credentials for the
IAM role specified in the profile." Token cache lives in `~/.aws/sso/cache`; PKCE is the
default from CLI 2.22.0 (`--use-device-code` for the device flow).
— [Configuring IAM Identity Center authentication](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sso.html)

---

## 7. What must be verified empirically

Everything below is [ND] and load-bearing. None of it can be closed by more reading; each needs
one live call under a real Identity Center session. These belong to the build/provision tickets
(#54, #55), not to this note — a research session has no AWS identity to test with.

1. **Does `GetCallerIdentity.Arn` equal the gateway's `userArn`, character for character?**
   The whole identity check reduces to this. Run `aws sts get-caller-identity` under
   `aws sso login`, then invoke the gateway and log `requestContext.authorizer.iam.userArn`,
   and `assert` the two strings. **If they differ, the design needs rework, not a patch.**
2. **What is the session name for an Identity Center session?** Read the tail of the ARN from
   step 1. Record the observed value, and record that it is an observation. If it is an opaque
   service-generated id rather than the UPN, `client.user` cannot be derived from STS and
   §2.3's alternatives (role-ARN-prefix authorization plus ABAC session tags) come into play.
3. **Does a 4 MiB record actually get through?** Send 4 MiB and confirm success; send 4.6 MiB
   (just over the 4.5 MiB break-even) and confirm a 413. This settles §1.3's before/after
   question in one experiment, and it is cheap.
4. **Does the body arrive base64-encoded for the record's content type?** Log
   `isBase64Encoded` on the first real commit. The gateway must handle both branches either
   way, but knowing which one fires is worth a line in the ADR.
5. **Is `x-amz-security-token` required inside the canonical request for a function URL?** The
   existing SigV4 signer's behaviour under temporary credentials decides whether every SSO
   writer works or none do. A single signed call under SSO credentials answers it.
6. **Confirm the two-action policy.** Provision with both `lambda:InvokeFunctionUrl` and
   `lambda:InvokeFunction` (§4.4) and confirm a 403 when `lambda:InvokeFunction` is withheld —
   this is a 2025 change and the most likely way a first deploy fails with a confusing error.
7. **Check the tenant's SCIM mapping** for `userName` (§6.2) rather than assuming UPN, and
   check that no writer's UPN exceeds 64 characters (§2.2).
