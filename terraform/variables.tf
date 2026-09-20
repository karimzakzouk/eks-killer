# ── Region & Networking ──────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the eks-killer VPC (1 subnet, 1 AZ — deliberately flat)"
  type        = string
  default     = "10.42.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR block for the single eks-killer subnet inside the VPC"
  type        = string
  default     = "10.42.1.0/24"
}

# ── Cluster Mode & Sizing ────────────────────────────────────────────────────

variable "master_count" {
  description = <<EOF
Control-plane size: 1 = single-spot hot-potato self-healing (default, cheapest,
what eks-killer was designed for). 3 = stacked-etcd raft-quorum HA (adds
endpoint cost and disables hot-potato code paths). 2 is forbidden because
2-node etcd has no fault tolerance — loss of any one node locks writes forever.
EOF
  type        = number
  default     = 1
  validation {
    condition     = contains([1, 3], var.master_count)
    error_message = "master_count must be 1 (hot-potato spot HA, default) or 3 (etcd raft HA). 2 masters is always the wrong choice."
  }
}

variable "worker_count" {
  description = <<EOF
Dedicated worker nodes (0 is valid — when 0, master is schedulable for pods
and handoff always takes the cold ASG-launch slow path). Setting to 1 or more
enables the worker-promotion fast path (~10-30s handoff, beats 120s spot timer
every time) for ~$3/month more per worker.
EOF
  type        = number
  default     = 0
}

variable "pod_cidr" {
  description = "CIDR used by Calico for pod overlay networking (not routable inside the VPC)"
  type        = string
  default     = "192.168.0.0/16"
}

# ── Instances & AMI ──────────────────────────────────────────────────────────

variable "cpu_arch" {
  description = "CPU architecture for the Ubuntu AMI. arm64 = Graviton (cheapest per vCPU by far). amd64 = standard x86. MUST match instance family."
  type        = string
  default     = "arm64"
  validation {
    condition     = contains(["arm64", "amd64"], var.cpu_arch)
    error_message = "cpu_arch must be \"arm64\" (Graviton, default) or \"amd64\" (x86)."
  }
}

variable "master_instance_type" {
  description = "EC2 instance type for control-plane master(s). Minimum 2 vCPU / 2 GB RAM for kubeadm preflight — t4g.small is the minimum reliable size."
  type        = string
  default     = "t4g.small"
}

variable "worker_instance_type" {
  description = "EC2 instance type for worker ASG (when worker_count > 0). t4g.small is minimum schedulable size for a non-trivial pod workload."
  type        = string
  default     = "t4g.small"
}

variable "kubernetes_version" {
  description = "Kubernetes minor series to install via the apt repo, e.g. \"1.30\". Full patch version is resolved at install time via dl.k8s.io stable-<series>.txt."
  type        = string
  default     = "1.30"
}

# ── Spot Price Ceilings (cost guardrails — these matter) ─────────────────────
#
# NOTE: The *actual default* safe spot ceilings (~40% of on-demand, ~25% above
# historical spot median) live in main.tf's locals block and are applied at
# the launch-template call site. Leaving these vars at empty string "" picks
# up the safe default — override only if you know what you're doing.

variable "master_spot_max_price" {
  description = <<EOF
Max hourly price in USD the master ASG will bid for a spot. Leave empty string
"" (default) for a built-in safe ceiling of ~40% of on-demand (~$0.006/hr for
t4g.small). If spot ever spikes ABOVE this, AWS terminates the instance
(hot-potato handoff fires cleanly) instead of silently billing you 7× the
price for a month.
EOF
  type        = string
  default     = ""
}

variable "worker_spot_max_price" {
  description = "Max hourly spot bid for worker ASG. Same semantics as master_spot_max_price — empty string uses the built-in ~40%-of-on-demand safe default."
  type        = string
  default     = ""
}

# ── SSH Access & Keys ────────────────────────────────────────────────────────

variable "key_name" {
  description = "Name of an *existing* EC2 Key Pair in your target region — used for SSH fallback / debug."
  type        = string
  default     = "key-pair"
}

variable "key_path" {
  description = "Local path to the SSH private key matching key_name. Defaults to <terraform-dir>/<key_name>.pem when empty (convention used by the built-in readiness-gate null_resource)."
  type        = string
  default     = ""
}

# NOTE: allowed_ssh_cidr has a runtime auto-detect default applied in main.tf's
# locals block via http data source. This file declares it blank; the actual
# working default is "your public IP at apply time /32". See main.tf locals.
variable "allowed_ssh_cidr" {
  description = <<EOF
CIDR allowed to reach TCP/22 (SSH) and TCP/6443 (Kubernetes API server).
Default when set to empty string "" = auto-detect your current public IP at
terraform apply time via https://ifconfig.me and pin it as a /32. Use
0.0.0.0/0 ONLY if you understand the security trade-offs and have other
controls (SSM Sessions Manager-only, strong key rotation, etc).
EOF
  type        = string
  default     = ""
}

# ── Internal Handoff (Usually Don't Touch) ───────────────────────────────────

variable "handoff_port" {
  description = <<EOF
Internal TCP port used exclusively for the hot-potato failover bundle
transfer. Only traffic originating from inside the eks-killer cluster SG
reaches this port (no ingress from allowed_ssh_cidr). Change only if you
have a conflicting workload listening on 7777 inside the VPC.
EOF
  type        = number
  default     = 7777
}
