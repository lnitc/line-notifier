# =============================================================================
# Inbound feature: a verified email -> push message to the LINE group.
#
#   You (allowlisted, DMARC-passing) email  line-****@<inbound_subdomain>
#        -> MX routes to SES  -> receipt rule stores the raw mail in S3
#        -> invokes the inbound Lambda       -> Lambda posts the body to LINE.
# =============================================================================

locals {
  inbound_address       = "${var.inbound_local_part}@${var.inbound_subdomain}"
  inbound_function_name = "${var.function_name}-inbound"
  inbound_s3_prefix     = "inbound/"
}

# --- Receiving domain identity (verify ownership of the subdomain) -----------
resource "aws_ses_domain_identity" "inbound" {
  domain = var.inbound_subdomain
}

# --- S3 bucket that SES drops raw incoming email into ------------------------
resource "aws_s3_bucket" "inbound" {
  bucket = "${var.function_name}-inbound-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "inbound" {
  bucket                  = aws_s3_bucket.inbound.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Raw emails are transient; delete them automatically after a few days.
resource "aws_s3_bucket_lifecycle_configuration" "inbound" {
  bucket = aws_s3_bucket.inbound.id
  rule {
    id     = "expire-received-email"
    status = "Enabled"
    filter {}
    expiration {
      days = var.inbound_retention_days
    }
  }
}

# Let SES (from this account only) write objects into the bucket.
resource "aws_s3_bucket_policy" "inbound" {
  bucket = aws_s3_bucket.inbound.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowSESPuts"
      Effect    = "Allow"
      Principal = { Service = "ses.amazonaws.com" }
      Action    = "s3:PutObject"
      Resource  = "${aws_s3_bucket.inbound.arn}/*"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
}

# --- Inbound Lambda ----------------------------------------------------------
data "archive_file" "inbound_zip" {
  type        = "zip"
  source_file = "${path.module}/src/inbound_fn.py"
  output_path = "${path.module}/build/inbound_fn.zip"
}

resource "aws_cloudwatch_log_group" "inbound_logs" {
  name              = "/aws/lambda/${local.inbound_function_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role" "inbound_role" {
  name = "${local.inbound_function_name}-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "inbound_policy" {
  name = "${local.inbound_function_name}-policy"
  role = aws_iam_role.inbound_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.inbound_logs.arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.inbound.arn}/${local.inbound_s3_prefix}*"
      }
    ]
  })
}

resource "aws_lambda_function" "inbound" {
  filename         = data.archive_file.inbound_zip.output_path
  source_code_hash = data.archive_file.inbound_zip.output_base64sha256
  function_name    = local.inbound_function_name
  role             = aws_iam_role.inbound_role.arn
  handler          = "inbound_fn.lambda_handler"
  runtime          = "python3.12"
  timeout          = 15

  environment {
    variables = {
      LINE_CHANNEL_ACCESS_TOKEN = var.line_channel_access_token
      LINE_GROUP_ID             = var.line_group_id
      S3_BUCKET                 = aws_s3_bucket.inbound.id
      S3_PREFIX                 = local.inbound_s3_prefix
      ALLOWED_SENDERS           = join(",", var.allowed_senders)
    }
  }

  depends_on = [aws_cloudwatch_log_group.inbound_logs]
}

# Allow SES to invoke the inbound Lambda (required before the rule is created).
resource "aws_lambda_permission" "ses_invoke" {
  statement_id   = "AllowSESInvoke"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.inbound.function_name
  principal      = "ses.amazonaws.com"
  source_account = data.aws_caller_identity.current.account_id
}

# --- SES receipt rule set ----------------------------------------------------
# NOTE: only ONE receipt rule set can be active per account/region. If you
# already have one, adopt it instead of activating this one.
resource "aws_ses_receipt_rule_set" "main" {
  rule_set_name = "${var.function_name}-rules"
}

resource "aws_ses_active_receipt_rule_set" "main" {
  rule_set_name = aws_ses_receipt_rule_set.main.rule_set_name
}

resource "aws_ses_receipt_rule" "inbound" {
  name          = local.inbound_function_name
  rule_set_name = aws_ses_receipt_rule_set.main.rule_set_name
  recipients    = [local.inbound_address]
  enabled       = true
  scan_enabled  = true # produces the spam/virus/DMARC verdicts we gate on

  s3_action {
    bucket_name       = aws_s3_bucket.inbound.id
    object_key_prefix = local.inbound_s3_prefix
    position          = 1
  }

  lambda_action {
    function_arn    = aws_lambda_function.inbound.arn
    invocation_type = "Event"
    position        = 2
  }

  depends_on = [
    aws_lambda_permission.ses_invoke,
    aws_s3_bucket_policy.inbound,
  ]
}

# --- Outputs: DNS to add, and the secret address ----------------------------
output "inbound_mx_record" {
  description = "MX record that routes the subdomain's mail to SES"
  value = {
    name     = var.inbound_subdomain
    type     = "MX"
    value    = "inbound-smtp.${var.aws_region}.amazonaws.com"
    priority = 10
  }
}

output "inbound_verification_txt" {
  description = "TXT record proving you own the receiving subdomain"
  value = {
    name  = "_amazonses.${var.inbound_subdomain}"
    type  = "TXT"
    value = aws_ses_domain_identity.inbound.verification_token
  }
}

output "inbound_email_address" {
  description = "Secret address to email (from an allowlisted, DMARC-passing account) to post to the group. Read with: terraform output -raw inbound_email_address"
  value       = local.inbound_address
  sensitive   = true
}
