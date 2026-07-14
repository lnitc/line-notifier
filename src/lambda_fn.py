import base64
import hashlib
import hmac
import json
import logging
import os
import urllib.request

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ses_client = boto3.client("ses")

# Read config once per cold start. Missing required values raise KeyError,
# which surfaces the misconfiguration immediately instead of silently failing.
CHANNEL_SECRET = os.environ["LINE_CHANNEL_SECRET"].encode("utf-8")
SENDER = os.environ["SES_SENDER_EMAIL"]
RECIPIENT = os.environ["SES_RECIPIENT_EMAIL"]
ACCESS_TOKEN = os.environ.get("LINE_CHANNEL_ACCESS_TOKEN", "")


def verify_signature(body_bytes: bytes, signature: str) -> bool:
    """Verify the X-Line-Signature header against the raw request body."""
    digest = hmac.new(CHANNEL_SECRET, body_bytes, hashlib.sha256).digest()
    expected = base64.b64encode(digest).decode("utf-8")
    return hmac.compare_digest(expected, signature or "")


def describe_message(message: dict) -> str:
    """Human-readable summary of a message event of any type."""
    mtype = message.get("type")
    if mtype == "text":
        return message.get("text", "")
    # stickers, images, video, audio, location, file, etc.
    return f"[{mtype} message]"


def resolve_display_name(source: dict) -> str | None:
    """Best-effort lookup of the sender's display name via the LINE API.

    Requires LINE_CHANNEL_ACCESS_TOKEN. Returns None on any failure so a
    notification is still sent.
    """
    if not ACCESS_TOKEN:
        return None

    user_id = source.get("userId")
    if not user_id:
        return None

    stype = source.get("type")
    if stype == "group" and source.get("groupId"):
        url = f"https://api.line.me/v2/bot/group/{source['groupId']}/member/{user_id}"
    elif stype == "room" and source.get("roomId"):
        url = f"https://api.line.me/v2/bot/room/{source['roomId']}/member/{user_id}"
    else:
        url = f"https://api.line.me/v2/bot/profile/{user_id}"

    req = urllib.request.Request(
        url, headers={"Authorization": f"Bearer {ACCESS_TOKEN}"}
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return json.loads(resp.read()).get("displayName")
    except Exception as exc:  # noqa: BLE001 - never let this break notification
        logger.warning("Could not resolve display name: %s", exc)
        return None


def send_email(subject: str, body_text: str) -> None:
    try:
        response = ses_client.send_email(
            Source=SENDER,
            Destination={"ToAddresses": [RECIPIENT]},
            Message={
                # Charset must be explicit: SES defaults to 7-bit ASCII, which
                # mangles non-ASCII display names and message text (Japanese,
                # Cyrillic, emoji) — especially in the Subject.
                "Subject": {"Data": subject, "Charset": "UTF-8"},
                "Body": {"Text": {"Data": body_text, "Charset": "UTF-8"}},
            },
        )
        logger.info("Email sent. Message ID: %s", response["MessageId"])
    except Exception as exc:  # noqa: BLE001
        logger.error("Error sending email: %s", exc)


def notify(line_event: dict) -> None:
    source = line_event.get("source", {})
    source_type = source.get("type", "unknown")
    text = describe_message(line_event.get("message", {}))
    name = resolve_display_name(source)
    who = name or source.get("userId", "unknown user")

    subject = f"LINE: new message from {who}"
    body = (
        f"From:   {who}\n"
        f"Where:  {source_type} chat\n"
        f"GroupID: {source.get('groupId', 'N/A')}\n"
        f"UserID:  {source.get('userId', 'N/A')}\n\n"
        f"{text}"
    )
    send_email(subject, body)


def lambda_handler(event, context):
    # 1. Recover the raw body exactly as LINE signed it.
    raw = event.get("body") or ""
    body_bytes = base64.b64decode(raw) if event.get("isBase64Encoded") else raw.encode("utf-8")

    # 2. Case-insensitive header lookup (Function URLs lowercase header names).
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    signature = headers.get("x-line-signature")

    if not signature or not body_bytes:
        logger.warning("Missing signature or body.")
        return {"statusCode": 400, "body": "Bad Request"}

    # 3. Authenticate the request.
    if not verify_signature(body_bytes, signature):
        logger.error("Invalid LINE signature.")
        return {"statusCode": 403, "body": "Invalid signature"}

    # 4. Process events. Always return 200 once authenticated so LINE does not
    #    retry; the console's "Verify" button sends an empty events list.
    try:
        events = json.loads(body_bytes).get("events", [])
        for line_event in events:
            if line_event.get("type") == "message":
                notify(line_event)
    except Exception as exc:  # noqa: BLE001
        logger.error("Error processing webhook: %s", exc)

    return {"statusCode": 200, "body": "OK"}
