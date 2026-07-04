terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# --- 1. IAM Role & Policies ---
resource "aws_iam_role" "lambda_exec_role" {
  name = "line_webhook_lambda_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "line_webhook_lambda_policy"
  role = aws_iam_role.lambda_exec_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "ses:SendEmail",
          "ses:SendRawEmail"
        ]
        Resource = "*" # Restrict this to specific SES identities in production
      }
    ]
  })
}

# --- 2. Package the Python Code ---
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/src/lambda_function.py"
  output_path = "${path.module}/lambda_function.zip"
}

# --- 3. Lambda Function ---
resource "aws_lambda_function" "line_webhook" {
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  function_name    = "line-webhook-forwarder"
  role             = aws_iam_role.lambda_exec_role.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.12"
  timeout          = 10

  environment {
    variables = {
      LINE_CHANNEL_SECRET = var.line_channel_secret
      SES_SENDER_EMAIL    = var.ses_sender_email
      SES_RECIPIENT_EMAIL = var.ses_recipient_email
    }
  }
}

# --- 4. Lambda Function URL (Public Webhook Endpoint) ---
resource "aws_lambda_function_url" "webhook_url" {
  function_name      = aws_lambda_function.line_webhook.function_name
  authorization_type = "NONE" # LINE sends public POST requests; security is handled via signature verification inside the code
}

# --- 5. Outputs ---
output "webhook_url" {
  description = "The URL to paste into the LINE Developers Console"
  value       = aws_lambda_function_url.webhook_url.function_url
}