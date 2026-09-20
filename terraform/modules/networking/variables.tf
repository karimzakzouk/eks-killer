variable "vpc_cidr" {
  description = "CIDR block for the eks-killer VPC (1 subnet, 1 AZ — deliberately flat)"
  type        = string
}

variable "subnet_cidr" {
  description = "CIDR block for the single eks-killer subnet inside the VPC"
  type        = string
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to reach TCP/22 (SSH) and TCP/6443 (Kubernetes API server)."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.allowed_ssh_cidr))
    error_message = "allowed_ssh_cidr must be a valid CIDR notation (e.g. 1.2.3.4/32 or 0.0.0.0/0)."
  }
}

variable "tags" {
  description = "Common tags to apply to every taggable networking resource."
  type        = map(string)
  default     = {}
}
