variable "fis_role_arn" {
  description = "ARN of the IAM role the FIS experiment assumes to inject spot interruptions (from iam module)."
  type        = string

  validation {
    condition     = length(var.fis_role_arn) > 0
    error_message = "fis_role_arn is required. Pass `iam.fis_role_arn` from the iam module when enable_fis_role=true."
  }
}

variable "tags" {
  description = "Common tags applied to the FIS experiment template."
  type        = map(string)
  default     = {}
}
