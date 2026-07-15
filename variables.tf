variable "aws_region" {
  description = "The AWS region to deploy resources in (supply via TF_VAR_aws_region or terraform.tfvars)"
  type        = string
  # No default on purpose: keeps the region out of the committed source.
}

variable "line_channel_secret" {
  description = "The Channel Secret from the LINE Developers Console"
  type        = string
  sensitive   = true
}

variable "line_channel_access_token" {
  description = "Optional long-lived Channel Access Token. If set, the sender's display name is resolved and included in notifications."
  type        = string
  sensitive   = true
  default     = ""
}

variable "ses_sender_domain" {
  description = "A domain you own, used as the SES sender identity (e.g. example.com). Must NOT be gmail.com/yahoo.com etc."
  type        = string
}

variable "ses_sender_email" {
  description = "The From address for notifications. Must be an address at ses_sender_domain (e.g. line-notifier@example.com)."
  type        = string

  validation {
    condition     = endswith(var.ses_sender_email, "@${var.ses_sender_domain}")
    error_message = "ses_sender_email must be an address at ses_sender_domain (e.g. line-notifier@${var.ses_sender_domain})."
  }
}

variable "ses_recipient_email" {
  description = "The email address that will receive the notifications"
  type        = string
}

variable "function_name" {
  description = "Name of the Lambda function"
  type        = string
  default     = "line-notifier"
}

variable "log_retention_days" {
  description = "How many days to keep CloudWatch logs for the function"
  type        = number
  default     = 14
}

# --- Inbound feature: email -> LINE group push -------------------------------

variable "inbound_subdomain" {
  description = "Subdomain that receives trigger emails via SES. Its MX must point at SES; keep it separate from your main mail domain."
  type        = string
}

variable "inbound_local_part" {
  description = "Secret local-part of the trigger address (e.g. line-abc123 -> line-abc123@<inbound_subdomain>). Acts as a shared secret; keep it out of source."
  type        = string
  sensitive   = true
}

variable "allowed_senders" {
  description = "Lowercased From addresses permitted to post to the group. Mail must also pass DMARC."
  type        = list(string)
}

variable "line_group_id" {
  description = "The LINE group ID that inbound emails are posted to (from the webhook payload of a message in that group)."
  type        = string
  sensitive   = true
}

variable "inbound_retention_days" {
  description = "How many days to keep raw received emails in S3 before automatic deletion."
  type        = number
  default     = 7
}
