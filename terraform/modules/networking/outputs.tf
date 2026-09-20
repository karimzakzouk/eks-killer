output "vpc_id" {
  value       = aws_vpc.this.id
  description = "VPC ID of the eks-killer flat network."
}

output "subnet_id" {
  value       = aws_subnet.this[0].id
  description = "Back-compat: first (or only) public subnet ID. Prefer subnet_ids[] if az_count > 1."
}

output "subnet_ids" {
  value       = aws_subnet.this[*].id
  description = "List of all public subnet IDs, one per AZ. Length = az_count."
}

output "cluster_sg_id" {
  value       = aws_security_group.cluster.id
  description = "Security group ID applied to master and worker ENIs (full intra-SG trust)."
}

output "master_eip_public_ip" {
  value       = aws_eip.master.public_ip
  description = "Stable public IPv4 of the control plane — kubectl endpoint."
}

output "master_eip_allocation_id" {
  value       = aws_eip.master.id
  description = "Allocation ID used by handoff.sh to re-associate the EIP between masters during failover."
}

output "availability_zones" {
  value       = [for i in range(min(var.az_count, length(data.aws_availability_zones.available.names))) : data.aws_availability_zones.available.names[i]]
  description = "List of AZs spanned by subnet_ids[]. Length = az_count."
}

output "availability_zone" {
  value       = data.aws_availability_zones.available.names[0]
  description = "Back-compat: first (or only) AZ — use availability_zones[] when az_count > 1."
}
