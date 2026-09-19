variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  type    = string
  default = "10.42.0.0/16"
}

variable "subnet_cidr" {
  type    = string
  default = "10.42.1.0/24"
}

variable "key_name" {
  description = "Existing EC2 key pair name for SSH access"
  type        = string
  default     = "key-pair"
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to SSH and hit the k8s API (your IP/32 recommended)"
  type        = string
  default     = "197.47.170.40/32"
}

variable "master_instance_type" {
  type    = string
  default = "t4g.small"
}

variable "cpu_arch" {
  description = "CPU architecture for the Ubuntu AMI: arm64 (Graviton, cheapest) or amd64 (x86). Must match the instance family."
  type        = string
  default     = "arm64"
}

variable "worker_instance_type" {
  type    = string
  default = "t4g.small"
}

variable "key_path" {
  description = "Local path to the SSH private key matching key_name. Defaults to <key_name>.pem in the terraform directory."
  type        = string
  default     = ""
}

variable "worker_count" {
  description = "Number of worker nodes to run (0 is valid; master falls back to full-relaunch handoff when 0)"
  type        = number
  default     = 0
}

variable "master_spot_max_price" {
  description = "Max spot price for the master (empty string = up to on-demand price)"
  type        = string
  default     = ""
}

variable "worker_spot_max_price" {
  type    = string
  default = ""
}

variable "handoff_port" {
  type    = number
  default = 7777
}

variable "pod_cidr" {
  description = "CIDR used by the CNI (Calico) for pod networking"
  type        = string
  default     = "192.168.0.0/16"
}

variable "kubernetes_version" {
  description = "Kubernetes package version stream (apt repo), e.g. 1.30"
  type        = string
  default     = "1.30"
}
