output "node_instance_profile_arn" {
  value       = aws_iam_instance_profile.node.arn
  description = "ARN of the shared EC2 instance profile — attach this to launch templates so instances can call AWS APIs for handoff."
}

output "node_instance_profile_name" {
  value       = aws_iam_instance_profile.node.name
  description = "Name of the shared node instance profile."
}

output "node_role_arn" {
  value       = aws_iam_role.node.arn
  description = "ARN of the shared node role (useful for iam:PassRole scoping)."
}

output "fis_role_arn" {
  value       = var.enable_fis_role ? aws_iam_role.fis[0].arn : null
  description = "ARN of the AWS FIS experiment role, or null when enable_fis_role is false."
}
