import json
import os
import hmac
import hashlib
import base64
import boto3
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ses_client = boto3.client('ses')

def verify_signature(body: str, signature: str, channel_secret: str) -> bool:
    """Verifies that the webhook was sent by the LINE Platform."""
    hash_val = hmac.new(
        channel_secret.encode('utf-8'),
        body.encode('utf-8'),
        hashlib.sha256
    ).digest()
    expected_signature = base64.b64encode(hash_val).decode('utf-8')
    return hmac.compare_digest(signature, expected_signature)

def send_email(subject: str, body_text: str):
    """Sends an email using Amazon SES."""
    sender = os.environ['SES_SENDER_EMAIL']
    recipient = os.environ['SES_RECIPIENT_EMAIL']
    
    try:
        response = ses_client.send_email(
            Source=sender,
            Destination={'ToAddresses': [recipient]},
            Message={
                'Subject': {'Data': subject},
                'Body': {'Text': {'Data': body_text}}
            }
        )
        logger.info(f"Email sent! Message ID: {response['MessageId']}")
    except Exception as e:
        logger.error(f"Error sending email: {str(e)}")

def lambda_handler(event, context):
    logger.info(f"Received event: {json.dumps(event)}")
    
    # 1. Extract headers and body
    headers = event.get('headers', {})
    body = event.get('body', '')
    
    # LINE headers are usually lowercased by AWS API Gateway/Function URLs
    signature = headers.get('x-line-signature')
    channel_secret = os.environ.get('LINE_CHANNEL_SECRET')
    
    if not signature or not body:
        logger.warning("Missing signature or body.")
        return {'statusCode': 400, 'body': 'Bad Request'}

    # 2. Verify the webhook signature
    if not verify_signature(body, signature, channel_secret):
        logger.error("Invalid LINE signature.")
        return {'statusCode': 403, 'body': 'Invalid signature'}
    
    # 3. Parse the events
    try:
        payload = json.loads(body)
        events = payload.get('events', [])
        
        for line_event in events:
            # We only care about message events
            if line_event.get('type') == 'message':
                source_type = line_event.get('source', {}).get('type')
                message_type = line_event.get('message', {}).get('type')
                
                # Further filter to text messages if desired
                if message_type == 'text':
                    text = line_event['message'].get('text', '')
                    group_id = line_event.get('source', {}).get('groupId', 'N/A')
                    user_id = line_event.get('source', {}).get('userId', 'N/A')
                    
                    subject = f"New LINE Message from {source_type}"
                    email_body = f"Source Type: {source_type}\nGroup ID: {group_id}\nUser ID: {user_id}\n\nMessage:\n{text}"
                    
                    send_email(subject, email_body)
                    
        return {'statusCode': 200, 'body': 'OK'}

    except Exception as e:
        logger.error(f"Error processing webhook: {str(e)}")
        return {'statusCode': 500, 'body': 'Internal Server Error'}