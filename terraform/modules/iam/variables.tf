variable "tags" {
  description = "Common tags to apply to every IAM resource."
  type        = map(string)
  default     = {}
}

variable "node_role_name" {
  description = "Name of the shared IAM role attached to every master + worker EC2 instance."
  type        = string
  default     = "eks-killer-node-role"
}

variable "fis_role_name" {
  description = "Name of the IAM role used by AWS Fault Injection Simulator to inject spot interruptions."
  type        = string
  default     = "eks-killer-fis-role"
}

variable "enable_fis_role" {
  description = "Whether to create the FIS spot-killer role + policy at all. Skip if you never run FIS experiments to reduce IAM surface."
  type        = bool
  default     = true
}
