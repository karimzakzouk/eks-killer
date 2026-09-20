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

# ── Derived values: allowed_ssh_cidr (auto-detect via ifconfig.me) ───────────

data "http" "my_public_ip" {
  count = var.allowed_ssh_cidr == "" ? 1 : 0
  url   = "https://ifconfig.me"

  request_headers = {
    Accept = "text/plain"
  }
}

locals {
  effective_allowed_cidr = var.allowed_ssh_cidr != "" ? var.allowed_ssh_cidr : "${chomp(data.http.my_public_ip[0].response_body)}/32"
}

# ── Scripts: read once at root level so relative paths resolve once ──────────

locals {
  scripts_dir = abspath("${path.module}/../scripts")

  script_common          = file("${local.scripts_dir}/shared/common.sh")
  script_receiver_worker = file("${local.scripts_dir}/shared/receiver-worker.sh")
  script_receiver_master = file("${local.scripts_dir}/shared/receiver-master.sh")
  script_handoff         = file("${local.scripts_dir}/shared/handoff.sh")
  script_pyreceiver      = file("${local.scripts_dir}/shared/pyreceiver.py")
  script_snapshot_loop   = file("${local.scripts_dir}/shared/snapshot-loop.sh")
  script_watcher_master  = file("${local.scripts_dir}/shared/watcher-master.sh")
  script_watcher_worker  = file("${local.scripts_dir}/shared/watcher-worker.sh")
  svc_receiver           = file("${local.scripts_dir}/shared/systemd/receiver.service")
  svc_snapshot           = file("${local.scripts_dir}/shared/systemd/snapshot-loop.service")
  svc_watcher_master     = file("${local.scripts_dir}/shared/systemd/watcher-master.service")
  svc_watcher_worker     = file("${local.scripts_dir}/shared/systemd/watcher-worker.service")
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
  allowed_ssh_cidr = local.effective_allowed_cidr
}

module "iam" {
  source = "./modules/iam"

  enable_fis_role = var.enable_fis_spot_killer
}

module "compute" {
  source = "./modules/compute"

  cpu_arch              = var.cpu_arch
  master_instance_type  = var.master_instance_type
  worker_instance_type  = var.worker_instance_type
  key_name              = local.effective_key_name
  subnet_id             = module.networking.subnet_id
  security_group_ids    = [module.networking.cluster_sg_id]
  instance_profile_arn  = module.iam.node_instance_profile_arn
  master_count          = var.master_count
  worker_count          = var.worker_count
  master_spot_max_price = var.master_spot_max_price
  worker_spot_max_price = var.worker_spot_max_price
  root_volume_size_gb   = var.root_volume_size_gb

  master_userdata = templatefile("${path.module}/../scripts/master/bootstrap-master.sh.tpl", {
    pyreceiver_py                  = local.script_pyreceiver
    handoff_port                   = var.handoff_port
    common_sh                      = local.script_common
    snapshot_loop_sh               = local.script_snapshot_loop
    watcher_master_sh              = local.script_watcher_master
    watcher_worker_sh              = local.script_watcher_worker
    handoff_sh                     = local.script_handoff
    receiver_master_sh             = local.script_receiver_master
    systemd_snapshot_loop_service  = local.svc_snapshot
    systemd_watcher_master_service = local.svc_watcher_master
    systemd_watcher_worker_service = local.svc_watcher_worker
    systemd_receiver_service       = local.svc_receiver
    systemd_eip_lo_service = templatefile("${local.scripts_dir}/shared/systemd/eip-lo.service.tpl", {
      eip_public_ip = module.networking.master_eip_public_ip
    })
    kubernetes_version = var.kubernetes_version
    aws_region         = local.region
    eip_allocation_id  = module.networking.master_eip_allocation_id
    eip_public_ip      = module.networking.master_eip_public_ip
    pod_cidr           = var.pod_cidr
  })

  worker_userdata = templatefile("${path.module}/../scripts/worker/bootstrap-worker.sh.tpl", {
    pyreceiver_py                  = local.script_pyreceiver
    handoff_port                   = var.handoff_port
    common_sh                      = local.script_common
    snapshot_loop_sh               = local.script_snapshot_loop
    watcher_master_sh              = local.script_watcher_master
    watcher_worker_sh              = local.script_watcher_worker
    handoff_sh                     = local.script_handoff
    receiver_worker_sh             = local.script_receiver_worker
    systemd_snapshot_loop_service  = local.svc_snapshot
    systemd_watcher_master_service = local.svc_watcher_master
    systemd_watcher_worker_service = local.svc_watcher_worker
    systemd_receiver_service       = local.svc_receiver
    kubernetes_version             = var.kubernetes_version
    aws_region                     = local.region
  })
}

module "fis" {
  count  = var.enable_fis_spot_killer && module.iam.fis_role_arn != null ? 1 : 0
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
