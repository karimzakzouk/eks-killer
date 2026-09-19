output "master_eip" {
  value       = aws_eip.master.public_ip
  description = "Stable public IP for the control plane. kubectl always points here."
}

output "master_asg_name" {
  value = aws_autoscaling_group.master.name
}

output "cluster_sg_id" {
  value = aws_security_group.cluster.id
}

output "worker_asg_name" {
  value = aws_autoscaling_group.worker.name
}

output "kubeconfig_fetch_hint" {
  value       = "ssh -i ${var.key_name}.pem ubuntu@${aws_eip.master.public_ip} 'sudo cat /etc/kubernetes/admin.conf' > ~/.kube/eks-killer.conf && chmod 600 ~/.kube/eks-killer.conf"
  description = "Copy-paste this to point your laptop kubectl at the cluster (then: KUBECONFIG=~/.kube/eks-killer.conf kubectl get nodes)."
}

output "kubeconfig_set" {
  value       = "export KUBECONFIG=~/.kube/eks-killer.conf"
  description = "Run after fetching the kubeconfig to point your shell at the cluster."
}

output "spot_killer_experiment_id" {
  value       = aws_fis_experiment_template.spot_killer.id
  description = "AWS FIS experiment template ID for triggering genuine AWS Spot interruption."
}
