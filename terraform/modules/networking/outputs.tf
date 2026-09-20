output "vpc_id" {
  value       = aws_vpc.this.id
  description = "VPC ID of the eks-killer flat network."
}

output "subnet_id" {
  value       = aws_subnet.this.id
  description = "Single public subnet ID where all instances launch."
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

output "availability_zone" {
  value       = data.aws_availability_zones.available.names[0]
  description = "AZ the single subnet is pinned to (eks-killer runs in one AZ by design — not HA at infrastructure level)."
}
