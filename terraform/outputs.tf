output "master_ip" {
  value       = module.networking.master_eip_public_ip
  description = "Stable public IPv4 of the control plane. Connect: ssh -i <key> ubuntu@<master_ip>"
}

output "kubectl_cmd" {
  value       = <<EOT
scp -o StrictHostKeyChecking=no -i '${local.effective_key_path}' ubuntu@${module.networking.master_eip_public_ip}:/etc/kubernetes/admin.conf ~/.kube/eks-killer-admin.conf
export KUBECONFIG=~/.kube/eks-killer-admin.conf
EOT
  description = "Commands to copy the admin kubeconfig off the new master and export KUBECONFIG to point at it."
}

output "ssh_cmd" {
  value       = "ssh -o StrictHostKeyChecking=no -i '${local.effective_key_path}' ubuntu@${module.networking.master_eip_public_ip}"
  description = "One-liner to SSH into the current master node."
}

output "key_name" {
  value       = local.effective_key_name
  description = "EC2 Key Pair name used by every eks-killer instance — either user-supplied or the auto-generated one named 'eks-killer-key'."
}

output "key_path" {
  value       = local.effective_key_path
  description = "Local filesystem path to the SSH private key. Auto-generated keys are written to terraform/eks-killer.pem with 0600 perms."
  sensitive   = false
}

output "allowed_ssh_cidr" {
  value       = local.effective_allowed_cidr
  description = "Effective CIDR allowed in the cluster SG for SSH (22) and kube-apiserver (6443) — either user-supplied or auto-detected from ifconfig.me as /32."
}

output "fis_experiment_template_id" {
  value       = var.enable_fis_spot_killer ? module.fis[0].experiment_template_id : null
  description = "AWS FIS experiment template ID — trigger with ./scripts/kill-spot.sh to inject a real 2-minute spot notice into all master instances."
}

output "worker_asg_name" {
  value       = module.compute.worker_asg_name
  description = "Worker auto-scaling group name (for external monitoring / ASG manipulation)."
}

output "master_asg_name" {
  value       = module.compute.master_asg_name
  description = "Master auto-scaling group name."
}

output "vpc_id" {
  value       = module.networking.vpc_id
  description = "eks-killer VPC ID."
}

output "region" {
  value       = local.region
  description = "AWS region the stack was deployed into."
}
