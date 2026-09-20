variable "vpc_cidr" {
  description = "CIDR block for the eks-killer VPC (az_count subnets across N AZs — deliberately flat, no NAT)"
  type        = string
}

variable "subnet_cidrs" {
  description = "List of CIDR blocks for eks-killer subnets, one per AZ. Length MUST equal az_count. Defaults: az_count=1 → [var.subnet_cidr compat]; az_count=3 → 3 /24s inside var.vpc_cidr."
  type        = list(string)
  default     = []
}

variable "subnet_cidr" {
  description = "DEPRECATED (kept for back-compat when subnet_cidrs is empty): CIDR block for a single eks-killer subnet inside the VPC. Use subnet_cidrs[] + az_count instead."
  type        = string
  default     = ""
}

variable "az_count" {
  description = "Number of Availability Zones to span. 1 = default (old behaviour, single subnet, zero cross-AZ cost). 3 = span 3 AZs (subnet CIDRs auto-calculated unless subnet_cidrs is explicit). Max value = number of AZs in the region."
  type        = number
  default     = 1

  validation {
    condition     = contains([1, 2, 3], var.az_count)
    error_message = "az_count must be 1 (default), 2, or 3. Higher values waste IP space and are not useful for a single-master design."
  }
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
