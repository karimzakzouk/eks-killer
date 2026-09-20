# ── Region & Networking ──────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the eks-killer VPC (1 subnet, 1 AZ — deliberately flat)."
  type        = string
  default     = "10.42.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR block for the single eks-killer public subnet inside the VPC."
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
  description = "CIDR used by Calico for pod overlay networking (not routable inside the VPC)."
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

variable "root_volume_size_gb" {
  description = "EBS gp3 root volume size in GB for every instance (masters + workers). 3000 IOPS / 125 MB/s, delete-on-terminate."
  type        = number
  default     = 20
}

# ── Spot Price Ceilings (cost guardrails — these matter) ─────────────────────

variable "master_spot_max_price" {
  description = <<EOF
Max hourly price in USD the master ASG will bid for a spot. Leave empty string
"" (default) to let AWS bid up to the on-demand ceiling (not recommended).
Set a ceiling of ~40% of on-demand (~$0.006/hr for t4g.small) so that if spot
ever spikes above it, hot-potato handoff fires cleanly instead of you silently
paying 7× on-demand all month.
EOF
  type        = string
  default     = ""
}

variable "worker_spot_max_price" {
  description = "Max hourly spot bid for worker ASG. Same semantics as master_spot_max_price — empty string uses on-demand ceiling."
  type        = string
  default     = ""
}

# ── SSH Access & Keys ────────────────────────────────────────────────────────

variable "key_name" {
  description = <<EOF
Name of an *existing* EC2 Key Pair in your target region. If left as empty string
"" (default), eks-killer auto-generates a brand new RSA-4096 keypair, registers
it in AWS as "eks-killer-key", and writes the private key PEM to
terraform/eks-killer.pem (chmod 0600).
EOF
  type        = string
  default     = ""
}

variable "key_path" {
  description = <<EOF
Local path to the SSH private key matching var.key_name. Default when empty:
* If key_name="" (auto-gen):  terraform/eks-killer.pem
* If key_name is set:         terraform/<key_name>.pem
EOF
  type        = string
  default     = ""
}

variable "allowed_ssh_cidr" {
  description = <<EOF
CIDR allowed to reach TCP/22 (SSH) and TCP/6443 (Kubernetes API server).
Default when empty string "" = auto-detect your current public IP at
terraform apply time via https://ifconfig.me and pin it as a /32. Use
0.0.0.0/0 ONLY if you understand the security trade-offs and have compensating
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

# ── Experiment / Debug Switches ──────────────────────────────────────────────

variable "enable_fis_spot_killer" {
  description = "Whether to create the AWS FIS spot-killer experiment template + FIS IAM role. Turn off to reduce IAM surface if you never trigger failover tests."
  type        = bool
  default     = true
}
