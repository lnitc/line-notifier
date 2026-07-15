# LINE Group ⇄ Email

A two-way bridge between a LINE group and email, provisioned with Terraform on
AWS.

- **Outbound** — a Lambda behind a public Function URL receives
  [LINE Messaging API](https://developers.line.biz/en/docs/messaging-api/)
  webhooks, verifies the signature, and emails you (via Amazon SES) whenever
  someone posts in the group.
- **Inbound** *(optional)* — you email a secret address; SES authenticates the
  message and a Lambda posts its body back into the group.

```
Outbound:  LINE group ──webhook──▶ Function URL ▶ Lambda (verify+parse) ▶ SES ▶ your inbox
Inbound:   your email ──▶ SES (MX) ▶ S3 + Lambda (authenticate+parse) ▶ LINE push ▶ group
```

This guide is self-contained: it walks from zero (no LINE channel, no AWS setup)
to a working system. Steps owned by an external console link to that console's
official docs rather than duplicating screenshots that go stale.

---

## Repository layout

| File | Purpose |
|------|---------|
| `main.tf` | Outbound: IAM, SES sender/recipient, Lambda, log group, Function URL |
| `inbound.tf` | Inbound: SES receipt rule, S3, Lambda, IAM (email → group push) |
| `variables.tf` | Input variables |
| `src/lambda_fn.py` | Webhook handler (signature check, parse, email) |
| `src/inbound_fn.py` | Inbound handler (authenticate, parse body, push to group) |
| `terraform.tfvars.example` | Template for your values — copy to `terraform.tfvars` |
| `.gitignore` | Keeps state, tfvars, and build artifacts out of git |

> **Secrets never enter git.** Terraform state (`*.tfstate`) and
> `terraform.tfvars` hold your channel secret and token in plaintext and are
> gitignored. Only `terraform.tfvars.example` is committed. If you fork/publish
> this, keep it that way.

---

## Prerequisites

You need all of these before starting:

- **A LINE account** (personal is fine) to create the Messaging API channel.
- **An AWS account** with permission to manage IAM, Lambda, SES, S3, and
  CloudWatch. Prefer an IAM user/role over the root user.
- **A domain you own** with access to its DNS records (to add TXT/CNAME/MX).
  This is required — you cannot send notifications "from" a `@gmail.com` /
  `@yahoo.com` address (see [why](#why-you-need-your-own-domain)). A cheap
  domain is fine.
- **[Terraform CLI](https://developer.hashicorp.com/terraform/install)** ≥ 1.9
  (this project uses cross-variable validation).
- **[AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)**,
  configured with your credentials (`aws configure`) — used for verification
  commands and to authenticate Terraform.

**Region note:** deploy in an AWS region that supports **SES email receiving**
if you want the inbound feature. Not every region does; check the
[SES email-receiving endpoints](https://docs.aws.amazon.com/general/latest/gr/ses.html)
list. The outbound feature works in any SES region.

---

## Part A — Create the LINE channel and get credentials

You will collect three things here: the **Channel Secret**, a **Channel Access
Token**, and (later) the **Group ID**.

### A1. Create a Messaging API channel

1. Sign in to the [LINE Developers Console](https://developers.line.biz/console/).
2. Create a **Provider** (any name — e.g. your project or company).
3. Create a **Messaging API channel** under that provider. This also creates a
   LINE Official Account.
   Full walkthrough: [Getting started with the Messaging API](https://developers.line.biz/en/docs/messaging-api/getting-started/).

### A2. Copy the Channel Secret

In the channel → **Basic settings** tab → **Channel secret**. This goes into
`line_channel_secret`. It's used to verify that webhooks genuinely came from
LINE (HMAC-SHA256 of the request body).

### A3. Issue a Channel Access Token (long-lived)

In the channel → **Messaging API** tab → **Channel access token (long-lived)** →
**Issue**. Copy it into `line_channel_access_token`.
Background: [Channel access tokens](https://developers.line.biz/en/docs/basics/channel-access-token/).

This token lets the bot look up sender display names and (for the inbound
feature) push messages. It's optional for bare outbound notifications but
recommended, and **required** for inbound.

### A4. Set the response behaviour

A LINE Official Account defaults to auto-reply "chat" mode, which **disables
webhooks**. Fix this:

- In the **Messaging API** tab (or the linked
  [LINE Official Account Manager](https://manager.line.biz/) → **Settings →
  Response settings**):
  - **Response mode / Chat**: set to **Bot** (not Chat).
  - **Webhooks**: **enabled**.
  - **Auto-reply** and **Greeting messages**: **off** (so the bot stays silent).
  - **Allow bot to join group chats**: **on** (else it receives nothing in
    groups).

You'll set the actual **Webhook URL** in [Part C](#c4-connect-the-webhook),
after Terraform gives you one.

---

## Part B — Prepare AWS

1. **Credentials.** Configure the AWS CLI (`aws configure`) with an IAM user/role
   that can manage the services listed in Prerequisites. Verify with
   `aws sts get-caller-identity`.
2. **Pick a region** and note it (e.g. `ap-northeast-1`). Use the same region for
   everything.
3. **SES starts in the "sandbox".** New accounts can only send to *verified*
   addresses and at low rates. That's fine here (you send to your own inbox). To
   email arbitrary recipients later, request
   [production access](https://docs.aws.amazon.com/ses/latest/dg/request-production-access.html).
   The **inbound** (receiving) side is **not** limited by the sandbox.

### Why you need your own domain

Mailbox providers (Gmail, Yahoo, …) publish a strict **DMARC** policy for their
own domains. If you send mail whose `From:` is `you@gmail.com` but it's actually
sent and DKIM-signed by `amazonses.com`, DMARC fails and the mail is rejected
(`554 5.7.9 ... DMARC`). Verifying a domain *you* own with SES **Easy DKIM**
makes SES sign as your domain, DMARC aligns, and mail is delivered. So the
notification **sender** must be an address at your domain (e.g.
`notify@example.com`).

---

## Part C — Deploy the outbound notifier

### C1. Configure your values

```bash
git clone <this-repo> && cd <this-repo>
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
aws_region          = "ap-northeast-1"          # your region
line_channel_secret = "…"                        # from A2
ses_sender_domain   = "example.com"              # a domain you own
ses_sender_email    = "notify@example.com"       # any address at that domain
ses_recipient_email = "you@example.com"          # where notifications go (any inbox)

line_channel_access_token = "…"                  # from A3 (recommended)
```

`terraform.tfvars` is gitignored. Alternatively, pass values via
`TF_VAR_<name>` environment variables to keep them out of files entirely.

### C2. Deploy

```bash
terraform init
terraform apply
```

At the end Terraform prints a `webhook_url` and the DNS records to add.

### C3. Verify the sender domain (DKIM) and the recipient

Print the DNS records and add them at your DNS provider:

```bash
terraform output ses_domain_verification_txt   # 1 TXT record
terraform output ses_dkim_cname_records        # 3 CNAME records
```

Tips: most DNS editors auto-append your domain, so enter the **host** part only
(e.g. `_amazonses`, `<token>._domainkey`). On Cloudflare, set the CNAMEs to
**DNS only** (not proxied). Within minutes to hours SES marks the domain
**Verified**:

```bash
aws ses get-identity-verification-attributes --identities example.com
```

**Recipient:** in the sandbox, the recipient is also verified — `terraform
apply` sends it a one-click confirmation email. Click it.

### C4. Connect the webhook

In the [LINE Developers Console](https://developers.line.biz/console/) → your
channel → **Messaging API** tab:

1. Set **Webhook URL** to the `webhook_url` output
   (`terraform output -raw webhook_url`).
2. Click **Verify** — it should succeed.
3. Confirm **Use webhook** is on (and the response settings from
   [A4](#a4-set-the-response-behaviour)).

### C5. Add the bot to your group and confirm

1. Add your Official Account as a friend (its ID/QR code is in the **Messaging
   API** tab or the Official Account Manager), then invite it into your LINE
   group.
2. Post a message in the group. You should get an email within seconds. First
   mail from a new domain can land in **spam** — mark it "not spam".

---

## Part D — Optional: inbound (email → group)

Lets you post into the group by sending an email. The email **body** becomes the
LINE message.

**How it's secured.** A post is made only if the email clears all three:
1. SES's **DMARC verdict is PASS** (plus no spam/virus failure) — the `From`
   can't be spoofed;
2. the `From` address is in **`allowed_senders`**; and
3. it was sent to the **secret address** (`inbound_local_part@inbound_subdomain`).

Note you send *from* your normal inbox (Gmail/Yahoo/etc.). Real mail from those
providers passes DMARC — that's exactly the signal used here. (This is the
opposite of the outbound *sender*, which must be your own domain.)

### D1. Get the Group ID

The Group ID isn't shown in any console — it only appears in a webhook event.
The easiest way: with outbound working (Part C) and the bot in the group, post a
message; the **notification email** (and the CloudWatch logs) include the
`GroupID`. Copy that value.

### D2. Configure and deploy

Add to `terraform.tfvars`:

```hcl
# A subdomain of a domain you own, dedicated to receiving (keeps your normal
# mail/MX untouched). It does NOT need to match ses_sender_domain.
inbound_subdomain  = "post.example.com"
inbound_local_part = "line-<random>"     # secret; address = <this>@<subdomain>
allowed_senders    = ["you@example.com"] # From addresses allowed to post
line_group_id      = "Cxxxxxxxx…"        # from D1
# line_channel_access_token must be set (Part A3).
```

Pick an unguessable `inbound_local_part` (e.g.
`line-$(python -c 'import secrets;print(secrets.token_hex(5))')`). Then:

```bash
terraform apply
```

### D3. Add the receiving DNS records

```bash
terraform output inbound_mx_record           # MX  -> inbound-smtp.<region>.amazonaws.com
terraform output inbound_verification_txt     # TXT proving ownership
terraform output -raw inbound_email_address   # the secret address to email
```

Add the **MX** (priority 10) and **TXT** for the subdomain. Wait until SES shows
it **Verified** (`aws ses get-identity-verification-attributes --identities
post.example.com`).

> Only **one** SES receipt rule set can be active per account/region. If you
> already have one, adopt it instead of activating a second (see `inbound.tf`).

### D4. Test

From an allowlisted account, email the secret address. The body appears in the
group within seconds (signatures and quoted replies are trimmed; capped at
~4900 chars). If nothing posts, check
`aws logs tail /aws/lambda/<function_name>-inbound --since 15m` — it logs exactly
why a message was rejected (verdict, sender, or empty body).

---

## Configuration reference

| Variable | Required | Default | Notes |
|----------|----------|---------|-------|
| `aws_region` | yes | — | No default, to keep it out of source. Set in tfvars or `TF_VAR_aws_region`. |
| `line_channel_secret` | yes | — | Sensitive. Basic settings tab (A2). |
| `ses_sender_domain` | yes | — | A domain you own, verified via DKIM. Not gmail/yahoo. |
| `ses_sender_email` | yes | — | The From address; must be at `ses_sender_domain`. |
| `ses_recipient_email` | yes | — | Where notifications are sent (any inbox). |
| `line_channel_access_token` | no* | `""` | Adds sender display names. *Required for inbound.* |
| `function_name` | no | `line-notifier` | Names the Lambda and prefixes inbound resources. |
| `log_retention_days` | no | `14` | CloudWatch log retention. |
| `inbound_subdomain` | inbound | — | Subdomain whose MX points at SES (e.g. `post.example.com`). |
| `inbound_local_part` | inbound | — | Sensitive. Secret local-part of the trigger address. |
| `allowed_senders` | inbound | — | List of `From` addresses allowed to post (must pass DMARC). |
| `line_group_id` | inbound | — | Sensitive. Group that inbound emails post into. |
| `inbound_retention_days` | no | `7` | Days to keep raw received emails in S3. |

"inbound" = required only if you enable the inbound feature.

---

## Notes & caveats

- **Every** group message generates an email. For a busy group, add filtering in
  `src/lambda_fn.py` (e.g. by keyword).
- The Function URL uses `authorization_type = NONE`; authenticity is enforced by
  HMAC-SHA256 verification of the `X-Line-Signature` header in the function.
- Display names are the sender's **global** LINE name, not a per-group nickname
  (LINE's API doesn't expose group nicknames). Non-text messages show as
  `[<type> message]`.
- **Provider version:** requires AWS provider **≥ 6.28**. Since Oct 2025 a public
  Function URL needs both `lambda:InvokeFunctionUrl` and `lambda:InvokeFunction`
  grants; ≥ 6.28 adds both automatically (older versions cause a 403).
- **Cost.** AWS side is negligible (Lambda + SES within/near free tiers).
  Inbound posts are LINE **push** messages, billed **per recipient**: one post to
  a group of N people counts as N messages against your
  [LINE plan](https://developers.line.biz/en/docs/messaging-api/pricing/) quota.

---

## Troubleshooting

**No email arrives when a message is posted.** Work top-down. Set your region
first: `export AWS_REGION=<your-region>` (and `<function_name>` defaults to
`line-notifier`).

1. **Is the function invoked at all?**
   ```bash
   aws logs tail /aws/lambda/line-notifier --since 15m --format short
   ```
   - *No log events* → LINE never reached the function. Go to step 2.
   - *`Invalid LINE signature`* → `line_channel_secret` doesn't match the calling
     channel. Fix and re-apply.
   - *`Email sent. Message ID: …`* → pipeline works; check spam and that SES
     addresses are verified (step 4).

2. **Is the public endpoint reachable?**
   ```bash
   curl -s -w '\n%{http_code}\n' -X POST "$(terraform output -raw webhook_url)" \
     -H 'Content-Type: application/json' -d '{"events":[]}'
   ```
   - **400 Bad Request** → endpoint healthy (function ran, rejected the unsigned
     request). Problem is LINE-side — go to step 3.
   - **403 `{"Message":"Forbidden…"}`** → AWS blocked it before your code. Ensure
     AWS provider **≥ 6.28** and re-apply, or add the missing grant manually:
     ```bash
     aws lambda add-permission --function-name line-notifier \
       --statement-id FunctionURLInvokeAllowPublicAccess \
       --action lambda:InvokeFunction --principal '*' --invoked-via-function-url
     ```

3. **LINE-side checklist** (Developers Console + Official Account Manager):
   - Webhook URL matches `terraform output -raw webhook_url`; **Use webhook** on.
   - **Verify** returns success.
   - **Allow bot to join group chats** on, and the bot is in the group.
   - **Response mode** is **Bot**, not **Chat** (Chat disables webhooks).

4. **SES / delivery:** confirm sender **domain** and recipient are verified:
   ```bash
   aws ses get-identity-verification-attributes --identities example.com you@example.com
   ```
   A `554 5.7.9 ... DMARC` bounce means the `From` is a domain you haven't
   DKIM-verified (e.g. a gmail/yahoo address) — see [Part C3](#c3-verify-the-sender-domain-dkim-and-the-recipient).

**Inbound: email sent but nothing posts.** Check
`aws logs tail /aws/lambda/line-notifier-inbound --since 15m`. `Rejected …
verdicts` = failed DMARC/spam/virus; `sender … not allowlisted` = add it to
`allowed_senders`; nothing at all = the subdomain isn't verified or the MX is
missing/wrong.

---

## Tear down

```bash
terraform destroy
```

Note: SES does not delete the resource-based policy grants added for a public
Function URL when the URL is destroyed; that's harmless, but you can remove them
manually if you like.
