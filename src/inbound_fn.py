"""Inbound bridge: a verified email becomes a push message to the LINE group.

Triggered by an SES receipt rule (S3 action stores the raw email, then a Lambda
action invokes this function). Every message is authenticated before anything
is posted:

  1. SES anti-spoofing verdicts must pass (DMARC especially).
  2. The From address must be on an allowlist.
  3. Delivery to the secret address is already enforced by the SES rule.

Only then is the email body extracted and pushed to the group.
"""

import email
import email.policy
import json
import logging
import os
import re
import urllib.error
import urllib.request

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3_client = boto3.client("s3")

TOKEN = os.environ["LINE_CHANNEL_ACCESS_TOKEN"]
GROUP_ID = os.environ["LINE_GROUP_ID"]
BUCKET = os.environ["S3_BUCKET"]
PREFIX = os.environ.get("S3_PREFIX", "")
ALLOWED = {a.strip().lower() for a in os.environ["ALLOWED_SENDERS"].split(",") if a.strip()}

MAX_LEN = 4900  # LINE text messages cap at 5000 chars; leave a little headroom.

# Lines at/after which we treat the rest of the body as a quoted reply or
# signature and drop it, so those don't leak into the group post.
_CUT_PATTERNS = [
    re.compile(r"^-- $"),                          # standard signature delimiter
    re.compile(r"^-----Original Message-----"),    # Outlook
    re.compile(r"^On .+ wrote:$"),                 # Gmail/Apple
    re.compile(r"^_{5,}$"),                         # some clients' divider
    re.compile(r"^From: .+"),                       # forwarded header block
]


def verdicts_ok(receipt: dict) -> bool:
    """Require DMARC to pass and no spam/virus failure."""
    if receipt.get("dmarcVerdict", {}).get("status") != "PASS":
        return False
    for key in ("spamVerdict", "virusVerdict"):
        if receipt.get(key, {}).get("status") == "FAIL":
            return False
    return True


def sender_address(mail: dict) -> str:
    """The header From address, lowercased (e.g. 'you@yahoo.com')."""
    from_headers = mail.get("commonHeaders", {}).get("from", [])
    raw = from_headers[0] if from_headers else mail.get("source", "")
    return email.utils.parseaddr(raw)[1].lower()


def _strip_html(html: str) -> str:
    html = re.sub(r"(?is)<(script|style).*?</\1>", "", html)
    html = re.sub(r"(?i)<br\s*/?>", "\n", html)
    html = re.sub(r"(?i)</p>", "\n", html)
    text = re.sub(r"(?s)<[^>]+>", "", html)
    return re.sub(r"[ \t]+\n", "\n", text)


def extract_body(raw_bytes: bytes) -> str:
    msg = email.message_from_bytes(raw_bytes, policy=email.policy.default)
    part = msg.get_body(preferencelist=("plain",))
    if part is not None:
        text = part.get_content()
    else:
        part = msg.get_body(preferencelist=("html",))
        text = _strip_html(part.get_content()) if part is not None else ""
    return clean_body(text)


def clean_body(text: str) -> str:
    kept = []
    for line in text.splitlines():
        if any(p.match(line.strip()) for p in _CUT_PATTERNS):
            break
        kept.append(line.rstrip())
    result = "\n".join(kept).strip()
    return result[:MAX_LEN]


def push_to_group(text: str) -> None:
    payload = json.dumps(
        {"to": GROUP_ID, "messages": [{"type": "text", "text": text}]}
    ).encode("utf-8")
    req = urllib.request.Request(
        "https://api.line.me/v2/bot/message/push",
        data=payload,
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {TOKEN}"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            logger.info("Posted to LINE group. HTTP %s", resp.status)
    except urllib.error.HTTPError as exc:
        logger.error("LINE push failed: HTTP %s %s", exc.code, exc.read().decode("utf-8", "replace"))
        raise


def lambda_handler(event, context):
    for record in event.get("Records", []):
        ses = record.get("ses", {})
        receipt = ses.get("receipt", {})
        mail = ses.get("mail", {})
        message_id = mail.get("messageId")

        if not verdicts_ok(receipt):
            logger.warning("Rejected %s: failed authentication verdicts.", message_id)
            continue

        sender = sender_address(mail)
        if sender not in ALLOWED:
            logger.warning("Rejected %s: sender %r not allowlisted.", message_id, sender)
            continue

        raw = s3_client.get_object(Bucket=BUCKET, Key=f"{PREFIX}{message_id}")["Body"].read()
        body = extract_body(raw)
        if not body:
            logger.warning("Nothing to post for %s: empty body after cleanup.", message_id)
            continue

        logger.info("Posting message from %s (%d chars).", sender, len(body))
        push_to_group(body)

    return {"statusCode": 200}
