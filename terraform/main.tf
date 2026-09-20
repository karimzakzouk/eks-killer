# ═══════════════════════════════════════════════════════════════════════════
# eks-killer — Root Terraform Composition Layer
# ═══════════════════════════════════════════════════════════════════════════
# Modules do the work. This file:
#   1. Resolves derived values (auto SSH key, auto public-IP CIDR, region).
#   2. Reads the shell / python scripts from ../scripts/ once, at the root,
#      because their relative paths only resolve here.
#   3. Builds userdata templates (templatefile) with all substitutions.
#   4. Wires modules together (networking → iam → compute → fis).
#   5. Defines the cluster_ready null_resource gating + cleanup hooks.

# ── Derived values: SSH key (auto-gen or user-provided) ──────────────────────

resource "tls_private_key" "eks_killer" {
  count     = var.key_name == "" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "eks_killer" {
  count      = var.key_name == "" ? 1 : 0
  key_name   = "eks-killer-key"
  public_key = tls_private_key.eks_killer[0].public_key_openssh
}

resource "local_sensitive_file" "eks_killer_pem" {
  count           = var.key_name == "" ? 1 : 0
  filename        = "${abspath(path.root)}/eks-killer.pem"
  content         = tls_private_key.eks_killer[0].private_key_pem
  file_permission = "0600"
}

locals {
  effective_key_name = var.key_name == "" ? aws_key_pair.eks_killer[0].key_name : var.key_name

  effective_key_path = var.key_path != "" ? var.key_path : (var.key_name == "" ? "${abspath(path.root)}/eks-killer.pem" : "${abspath(path.root)}/${var.key_name}.pem")
}

# ── Derived values: allowed_ssh_cidr (auto-detect via ipify.org) ─────────────

data "http" "my_public_ip" {
  count = var.allowed_ssh_cidr == "" ? 1 : 0
  url   = "https://api.ipify.org?format=text"

  request_headers = {
    Accept = "text/plain"
  }

  lifecycle {
    postcondition {
      condition     = can(regex("^\\s*([0-9]{1,3}\\.){3}[0-9]{1,3}\\s*$", self.response_body))
      error_message = <<EOT
Could not auto-detect your public IPv4 address from https://api.ipify.org.
Got: ${chomp(self.response_body)}

Workaround: set allowed_ssh_cidr explicitly:
  terraform apply -var="allowed_ssh_cidr=$(curl -s https://api.ipify.org)/32"
Or to allow everywhere (discouraged):
  terraform apply -var="allowed_ssh_cidr=0.0.0.0/0"
EOT
    }
  }
}

locals {
  effective_allowed_cidr = var.allowed_ssh_cidr != "" ? var.allowed_ssh_cidr : "${trimspace(data.http.my_public_ip[0].response_body)}/32"
}

# ── Region lookup (needed for scripts inside userdata) ───────────────────────

data "aws_region" "current" {}

locals {
  region = data.aws_region.current.name
}

# ── Modules ──────────────────────────────────────────────────────────────────

module "networking" {
  source = "./modules/networking"

  vpc_cidr         = var.vpc_cidr
  subnet_cidr      = var.subnet_cidr
  subnet_cidrs     = var.subnet_cidrs
  az_count         = var.az_count
  allowed_ssh_cidr = local.effective_allowed_cidr
}

module "iam" {
  source = "./modules/iam"

  enable_fis_role = var.enable_fis_spot_killer
}

data "external" "master_userdata" {
  program = ["python3", "${path.module}/../scripts/compress-userdata.py", "master"]
  query = {
    handoff_port      = var.handoff_port
    kubernetes_version = var.kubernetes_version
    aws_region        = local.region
    eip_allocation_id = module.networking.master_eip_allocation_id
    eip_public_ip     = module.networking.master_eip_public_ip
    pod_cidr          = var.pod_cidr
  }
}

data "external" "worker_userdata" {
  program = ["python3", "${path.module}/../scripts/compress-userdata.py", "worker"]
  query = {
    handoff_port      = var.handoff_port
    kubernetes_version = var.kubernetes_version
    aws_region        = local.region
    eip_allocation_id = module.networking.master_eip_allocation_id
    eip_public_ip     = module.networking.master_eip_public_ip
    pod_cidr          = var.pod_cidr
  }
}

module "compute" {
  source = "./modules/compute"

  cpu_arch              = var.cpu_arch
  master_instance_type  = var.master_instance_type
  worker_instance_type  = var.worker_instance_type
  key_name              = local.effective_key_name
  subnet_id             = module.networking.subnet_id
  subnet_ids            = module.networking.subnet_ids
  security_group_ids    = [module.networking.cluster_sg_id]
  instance_profile_arn  = module.iam.node_instance_profile_arn
  master_count          = var.master_count
  worker_count          = var.worker_count
  master_spot_max_price = var.master_spot_max_price
  worker_spot_max_price = var.worker_spot_max_price
  root_volume_size_gb   = var.root_volume_size_gb

  master_userdata = data.external.master_userdata.result.userdata

  worker_userdata = data.external.worker_userdata.result.userdata
}

module "fis" {
  count  = var.enable_fis_spot_killer ? 1 : 0
  source = "./modules/fis"

  fis_role_arn = module.iam.fis_role_arn
}

# ── Readiness gates: only show outputs once the cluster is actually usable ───

resource "null_resource" "cluster_ready" {
  triggers = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["/bin/bash", "-c"]
    command     = <<EOT
set -euo pipefail
MASTER_PUBLIC_IP="${module.networking.master_eip_public_ip}"
KEY="${local.effective_key_path}"
echo "== Waiting for SSH on $${MASTER_PUBLIC_IP}:22 =="
for i in $(seq 1 60); do
  if nc -z -w 3 "$${MASTER_PUBLIC_IP}" 22 2>/dev/null; then
    echo "SSH reachable after ~$${i} tries."
    break
  fi
  sleep 5
done
echo "== Waiting for cloud-init status =="
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes \
    -i "$${KEY}" ubuntu@$${MASTER_PUBLIC_IP} -- \
  'for i in $(seq 1 240); do cloud-init status --wait 2>/dev/null && break || sleep 5; done'
echo "== Waiting for kube-apiserver :6443 =="
for i in $(seq 1 120); do
  if nc -z -w 3 "$${MASTER_PUBLIC_IP}" 6443 2>/dev/null; then
    echo "API server reachable after ~$${i} tries."
    break
  fi
  sleep 5
done
echo "== eks-killer cluster ready =="
EOT
  }

  depends_on = [module.compute]
}

resource "null_resource" "vpc_instance_cleaner" {
  triggers = {
    subnet_id = module.networking.subnet_id
    master_sg = module.networking.cluster_sg_id
    region    = local.region
  }
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<EOT
REGION="${self.triggers.region}"
SUBNET="${self.triggers.subnet_id}"
IDS=$(aws ec2 describe-instances --region "$REGION" \
  --filters Name=subnet-id,Values="$SUBNET" Name=instance-state-name,Values=running,pending,stopped,stopping \
  --query 'Reservations[*].Instances[*].InstanceId' --output text 2>/dev/null || true)
if [ -n "$IDS" ]; then
  echo "Pre-destroy: terminating remaining EC2 in eks-killer subnet before VPC/SG deletion:"
  echo "$IDS" | tr '\t' '\n' | while read -r id; do [ -n "$id" ] && echo " - $id"; done
  aws ec2 terminate-instances --region "$REGION" --instance-ids $(echo "$IDS") >/dev/null 2>&1 || true
  echo "Waiting up to 90s for termination…"
  for i in $(seq 1 30); do
    ALIVE=$(aws ec2 describe-instances --region "$REGION" \
      --filters Name=subnet-id,Values="$SUBNET" Name=instance-state-name,Values=running,pending,stopped,stopping,shutting-down \
      --query 'Reservations[*].Instances[*].InstanceId' --output text 2>/dev/null || true)
    [ -z "$ALIVE" ] && break
    sleep 3
  done
fi
EOT
  }
}
