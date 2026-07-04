variable "aws_region" {
  description = "The AWS region to deploy resources in"
  type        = string
  default     = "ap-northeast-1"
}

variable "line_channel_secret" {
  description = "The Channel Secret from the LINE Developers Console"
  type        = string
  sensitive   = true
}

variable "ses_sender_email" {
  description = "The verified SES email address used to send the notifications"
  type        = string
}

variable "ses_recipient_email" {
  description = "The email address that will receive the notifications"
  type        = string
}