terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      # >= 6.28.0 is required: it auto-creates BOTH the lambda:InvokeFunctionUrl
      # and lambda:InvokeFunction resource-policy grants that a public
      # (authorization_type = NONE) Function URL needs since AWS's Oct-2025 change.
      # Older versions create only InvokeFunctionUrl, so the URL returns 403.
      version = "~> 6.28"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

# --- 1. SES sender identity (domain + Easy DKIM) -----------------------------
# The sender must be a DOMAIN you own, not a @gmail/@yahoo address: mailbox
# providers publish a strict DMARC policy for their own domains and will reject
# mail that claims to be "From" them but is DKIM-signed by amazonses.com.
# Verifying your own domain with Easy DKIM makes SES sign as your domain, so
# DMARC aligns and mail is delivered. Add the DNS records from the outputs.
resource "aws_ses_domain_identity" "sender" {
  domain = var.ses_sender_domain
}

resource "aws_ses_domain_dkim" "sender" {
  domain = aws_ses_domain_identity.sender.domain
}

# --- 1b. SES recipient identity ----------------------------------------------
# While the account is in the SES sandbox, the recipient must also be verified.
# This sends a one-click verification e-mail to the recipient address.
resource "aws_ses_email_identity" "recipient" {
  email = var.ses_recipient_email
}

# --- 2. IAM Role & Policies --------------------------------------------------
resource "aws_iam_role" "lambda_exec_role" {
  name = "${var.function_name}-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "${var.function_name}-policy"
  role = aws_iam_role.lambda_exec_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.lambda_logs.arn}:*"
      },
      {
        Effect = "Allow"
        Action = [
          "ses:SendEmail",
          "ses:SendRawEmail"
        ]
        # Scope by the From address rather than by identity ARN: in the SES
        # sandbox, resource-ARN scoping also evaluates the recipient identity,
        # which breaks legitimate sends. The ses:FromAddress condition restricts
        # sending to our sender only, regardless of recipient.
        Resource = "*"
        Condition = {
          StringEquals = {
            "ses:FromAddress" = var.ses_sender_email
          }
        }
      }
    ]
  })
}

# --- 3. Package the Python code ---------------------------------------------
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/src/lambda_fn.py"
  output_path = "${path.module}/build/lambda_fn.zip"
}

# --- 4. CloudWatch log group (managed so retention is enforced) --------------
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = var.log_retention_days
}

# --- 5. Lambda function ------------------------------------------------------
resource "aws_lambda_function" "line_webhook" {
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  function_name    = var.function_name
  role             = aws_iam_role.lambda_exec_role.arn
  handler          = "lambda_fn.lambda_handler"
  runtime          = "python3.12"
  timeout          = 10

  environment {
    variables = {
      LINE_CHANNEL_SECRET       = var.line_channel_secret
      LINE_CHANNEL_ACCESS_TOKEN = var.line_channel_access_token
      SES_SENDER_EMAIL          = var.ses_sender_email
      SES_RECIPIENT_EMAIL       = var.ses_recipient_email
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda_logs]
}

# --- 6. Lambda Function URL (public webhook endpoint) ------------------------
resource "aws_lambda_function_url" "webhook_url" {
  function_name      = aws_lambda_function.line_webhook.function_name
  authorization_type = "NONE" # LINE posts publicly; authenticity is enforced by X-Line-Signature verification in code.
  # With provider >= 6.28 this resource automatically creates the required
  # public lambda:InvokeFunctionUrl + lambda:InvokeFunction resource-policy grants.
}

# --- 7. Outputs --------------------------------------------------------------
output "webhook_url" {
  description = "Paste this into the LINE Developers Console (Messaging API > Webhook URL)"
  value       = aws_lambda_function_url.webhook_url.function_url
}

# Add these records at your DNS provider to verify the domain and enable DKIM.
# SES will show the domain as "Verified" once they propagate (minutes to hours).
output "ses_domain_verification_txt" {
  description = "TXT record proving you own the sender domain"
  value = {
    name  = "_amazonses.${var.ses_sender_domain}"
    type  = "TXT"
    value = aws_ses_domain_identity.sender.verification_token
  }
}

output "ses_dkim_cname_records" {
  description = "Three CNAME records that let SES DKIM-sign as your domain (this is what makes DMARC pass)"
  value = [for token in aws_ses_domain_dkim.sender.dkim_tokens : {
    name  = "${token}._domainkey.${var.ses_sender_domain}"
    type  = "CNAME"
    value = "${token}.dkim.amazonses.com"
  }]
}
