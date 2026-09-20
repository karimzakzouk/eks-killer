output "master_launch_template_id" {
  value       = aws_launch_template.master.id
  description = "ID of the master launch template (handoff.sh discovers it by Name tag, but this is handy for cross-references)."
}

output "master_asg_name" {
  value       = aws_autoscaling_group.master.name
  description = "Master auto-scaling group name — monitor-live-failover.py uses this to track new instances during failover."
}

output "worker_asg_name" {
  value       = aws_autoscaling_group.worker.name
  description = "Worker auto-scaling group name."
}

output "ami_id" {
  value       = data.aws_ami.ubuntu.id
  description = "Resolved Canonical Ubuntu Minimal 22.04 AMI ID for the configured architecture."
}

output "worker_launch_template_id" {
  value       = aws_launch_template.worker.id
  description = "ID of the worker launch template."
}
