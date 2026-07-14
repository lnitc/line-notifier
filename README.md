# LINE Group → Email Notifier

An AWS Lambda function (behind a public Lambda Function URL) that receives
[LINE Messaging API](https://developers.line.biz/en/docs/messaging-api/)
webhooks, verifies the request signature, and emails you whenever a new message
is posted in a LINE group your bot has been added to. Email is sent via Amazon
SES. Everything is provisioned with Terraform.

```
LINE group ──webhook──▶ Lambda Function URL ──▶ Lambda (verify + parse) ──▶ SES ──▶ your inbox
```

## Repository layout

| File | Purpose |
|------|---------|
| `main.tf` | Infrastructure: IAM, SES identities, Lambda, log group, Function URL |
| `variables.tf` | Input variables |
| `src/lambda_fn.py` | Webhook handler (signature check, parse, email) |
| `terraform.tfvars.example` | Template for your secret values |
| `.gitignore` | Keeps state, tfvars, and build artifacts out of git |

> **Secrets never enter git.** Terraform state (`*.tfstate`) and `terraform.tfvars`
> hold your channel secret in plaintext and are gitignored. Only
> `terraform.tfvars.example` is committed.

## Prerequisites

- [Terraform CLI](https://developer.hashicorp.com/terraform/install) installed
- AWS credentials configured (e.g. `aws configure`, or `AWS_ACCESS_KEY_ID` /
  `AWS_SECRET_ACCESS_KEY` env vars) with permission to manage IAM, Lambda, SES,
  and CloudWatch Logs
- A LINE Messaging API channel — you already have the **Channel Secret**

## Setup

### 1. Provide your values

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars with your region, channel secret, and emails
```

The sender and recipient can be the **same** address (notify yourself). For a
first setup, using your own email for both is simplest.

### 2. Deploy

```bash
terraform init
terraform apply
```

Terraform prints a `webhook_url` at the end.

### 3. Verify the sender domain (DKIM) and the recipient

**Sender = a domain you own.** You cannot send `From` a `@gmail.com`/`@yahoo.com`
address: those providers publish a strict DMARC policy for their own domain and
reject mail that claims to be from them but is DKIM-signed by `amazonses.com`
(`554 5.7.9 ... DMARC`). Verifying your own domain with Easy DKIM makes SES sign
as your domain, so DMARC aligns and mail is delivered.

`terraform apply` creates the domain identity and prints the DNS records to add:

```bash
terraform output ses_domain_verification_txt   # one TXT record
terraform output ses_dkim_cname_records        # three CNAME records
```

Add all four records at your DNS provider. Within minutes to hours SES marks the
domain **Verified** (check the SES console, or
`aws ses get-identity-verification-attributes --identities yourdomain.com`).

**Recipient:** while the account is in the **SES sandbox**, the recipient inbox
must also be verified — `terraform apply` emails it a one-click verification
link. (To send to arbitrary recipients later, request
[production access](https://docs.aws.amazon.com/ses/latest/dg/request-production-access.html).)

> Optional hardening: add a DMARC record (`_dmarc.yourdomain.com TXT
> "v=DMARC1; p=none"`) and a [custom MAIL FROM domain](https://docs.aws.amazon.com/ses/latest/dg/mail-from.html)
> for SPF alignment. Easy DKIM alone already satisfies DMARC.

### 4. Point LINE at the webhook

In the [LINE Developers Console](https://developers.line.biz/console/) → your
channel → **Messaging API**:

1. Set **Webhook URL** to the `webhook_url` output and click **Verify**
   (should return success).
2. Turn **Use webhook** **on**.
3. Under **LINE Official Account features**, set **Allow bot to join group chats**
   to **on** (otherwise it receives nothing in groups).
4. Optional but recommended: turn **Auto-reply messages** and **Greeting messages**
   **off** so the bot stays silent.

### 5. Add the bot to your group

Invite the official account into the LINE group. New messages now trigger an email.

## Configuration reference

| Variable | Required | Default | Notes |
|----------|----------|---------|-------|
| `aws_region` | yes | — | No default, to keep it out of source. Set in tfvars or `TF_VAR_aws_region`. |
| `line_channel_secret` | yes | — | Sensitive. From the LINE console. |
| `ses_sender_domain` | yes | — | A domain you own, verified in SES via DKIM. Not gmail/yahoo. |
| `ses_sender_email` | yes | — | The From address; must be at `ses_sender_domain`. |
| `ses_recipient_email` | yes | — | Where notifications are sent. |
| `line_channel_access_token` | no | `""` | If set, notifications include the sender's display name. |
| `function_name` | no | `line-notifier` | |
| `log_retention_days` | no | `14` | CloudWatch log retention. |

### Avoiding secrets on the command line

Instead of `terraform.tfvars` you can export environment variables, which keeps
values out of shell history files too:

```bash
export TF_VAR_aws_region="ap-northeast-1"
export TF_VAR_line_channel_secret="..."
export TF_VAR_ses_sender_email="you@example.com"
export TF_VAR_ses_recipient_email="you@example.com"
terraform apply
```

## Notes & caveats

- **Every** message in the group generates an email — a busy group means a busy
  inbox. Adjust `src/lambda_fn.py` (e.g. filter by keyword) if that's too noisy.
- The Function URL uses `authorization_type = NONE`; authenticity is enforced by
  HMAC-SHA256 verification of the `X-Line-Signature` header inside the function.
- Non-text messages (stickers, images, etc.) are reported as `[<type> message]`.

## Troubleshooting

**No email arrives when a message is posted.** Work top-down — each step tells
you where the request is (or isn't) getting to. Set your region first:
`export AWS_REGION=<your-region>`.

1. **Is the function being invoked at all?**
   ```bash
   aws logs tail /aws/lambda/line-notifier --since 15m --format short
   ```
   - *No log events* → LINE never reached the function. Continue to step 2.
   - *`Invalid LINE signature`* → the Channel Secret in `terraform.tfvars`
     doesn't match the channel whose webhook is calling. Fix and re-apply.
   - *`Email sent. Message ID: …`* → the pipeline works; check your spam folder
     and that both SES addresses are verified (step 4).

2. **Is the public endpoint reachable?**
   ```bash
   curl -s -w '\n%{http_code}\n' -X POST "$(terraform output -raw webhook_url)" \
     -H 'Content-Type: application/json' -d '{"events":[]}'
   ```
   - **400 Bad Request** → the endpoint is healthy (the function ran and rejected
     the unsigned request). The problem is on the LINE side — go to step 3.
   - **403 `{"Message":"Forbidden…"}`** → AWS is blocking the request *before* it
     reaches your code. Since October 2025 a public (`NONE`) Function URL needs
     **both** `lambda:InvokeFunctionUrl` **and** `lambda:InvokeFunction` in its
     resource policy. This project requires AWS provider **>= 6.28**, which adds
     both automatically. If you pinned an older provider you'll get this 403 —
     bump the provider and `terraform apply`, or add the missing grant manually:
     ```bash
     aws lambda add-permission --function-name line-notifier \
       --statement-id FunctionURLInvokeAllowPublicAccess \
       --action lambda:InvokeFunction --principal '*' --invoked-via-function-url
     ```

3. **LINE-side checklist** (LINE Developers Console + Official Account Manager):
   - Webhook URL matches `terraform output -raw webhook_url`, and **Use webhook** is on.
   - The **Verify** button returns success.
   - **Allow bot to join group chats** is on, and the bot is actually in the group.
   - In the Official Account Manager, **Response mode** is **Bot** (not **Chat**) —
     Chat mode disables webhook delivery.

4. **SES / delivery:** confirm the sender **domain** is verified and the
   recipient is verified (sandbox):
   `aws ses get-identity-verification-attributes --identities yourdomain.com you@example.com`.
   A `554 5.7.9 ... DMARC` bounce means the `From` is a domain you haven't
   DKIM-verified (e.g. a gmail/yahoo address) — see step 3 of Setup.

## Tear down

```bash
terraform destroy
```
