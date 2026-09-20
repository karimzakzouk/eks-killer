variable "cpu_arch" {
  description = "CPU architecture for the Canonical Ubuntu Minimal AMI. Must match instance family (arm64 = Graviton, amd64 = x86)."
  type        = string

  validation {
    condition     = contains(["arm64", "amd64"], var.cpu_arch)
    error_message = "cpu_arch must be \"arm64\" (Graviton, default) or \"amd64\" (x86)."
  }
}

variable "master_instance_type" {
  description = "EC2 instance type for control-plane master(s). Minimum t4g.small — kubeadm preflight requires >= 2 vCPU / 2 GB RAM."
  type        = string
}

variable "worker_instance_type" {
  description = "EC2 instance type for worker ASG nodes (when var.worker_count > 0)."
  type        = string
}

variable "key_name" {
  description = "Name of an EC2 Key Pair already in this region, attached to every instance for SSH/SSM fallback."
  type        = string
}

variable "subnet_id" {
  description = "DEPRECATED: use subnet_ids[] for multi-AZ support. Single subnet ID — ignored if subnet_ids[] is non-empty."
  type        = string
  default     = ""
}

variable "subnet_ids" {
  description = "List of public subnet IDs to launch instances across (one per AZ). ASG's vpc_zone_identifier = this list."
  type        = list(string)
  default     = []
}

variable "security_group_ids" {
  description = "List of security group IDs applied to every master and worker instance ENI."
  type        = list(string)
}

variable "instance_profile_arn" {
  description = "ARN of the shared IAM instance profile (from iam module)."
  type        = string
}

variable "master_userdata" {
  description = "Compressed userdata script for master instances (xz+base64 from external data source)."
  type        = string
}

variable "worker_userdata" {
  description = "Compressed userdata script for worker instances (xz+base64 from external data source)."
  type        = string
}

variable "master_count" {
  description = "Number of control-plane masters. 1 = hot-potato spot HA (eks-killer default). 3 = etcd raft HA mode. 2 is forbidden because 2-node etcd has zero fault tolerance."
  type        = number

  validation {
    condition     = contains([1, 3], var.master_count)
    error_message = "master_count must be 1 or 3. 2 is never the right number for an etcd cluster."
  }
}

variable "worker_count" {
  description = "Number of dedicated worker nodes. 0 is valid — master becomes schedulable and handoff always takes cold-launch slow path."
  type        = number
  default     = 0
}

variable "master_spot_max_price" {
  description = "Maximum hourly spot bid in USD for master instances. Empty string uses AWS default (up to on-demand). Recommended: set a ceiling ~40% of on-demand to avoid silent 7× bill spikes."
  type        = string
  default     = ""
}

variable "worker_spot_max_price" {
  description = "Maximum hourly spot bid in USD for worker instances. Same semantics as master_spot_max_price."
  type        = string
  default     = ""
}

variable "root_volume_size_gb" {
  description = "EBS root volume size in GB for every instance. gp3, 3000 IOPS, 125 MB/s throughput, delete-on-terminate."
  type        = number
  default     = 20
}

variable "tags" {
  description = "Base tags merged with role-specific tags on every taggable compute resource."
  type        = map(string)
  default     = {}
}
