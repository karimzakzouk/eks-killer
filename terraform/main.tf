# ── Compute local defaults & resolve runtime values ──────────────────────────

# Auto-detect the user's current public IPv4 address so SSH + k8s API are
# reachable without hardcoding a random CIDR. Fallback: 127.0.0.1/32 (which
# breaks nothing since it's only from localhost) if the lookup fails.
data "http" "my_public_ip" {
  url = "https://ifconfig.me/ip"

  request_headers = {
    Accept = "text/plain"
  }

  lifecycle {
    precondition {
      condition     = can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}$", chomp(self.response_body)))
      error_message = "Auto-detection of your public IP via ifconfig.me returned a non-IPv4 body: ${self.response_body}. Set var.allowed_ssh_cidr explicitly to bypass auto-detection."
    }
  }
}

locals {
  # Effective allowed CIDR for SSH + kube-apiserver. Prefer user override;
  # otherwise use auto-detected public IP pinned to /32.
  effective_allowed_cidr = var.allowed_ssh_cidr != "" ? var.allowed_ssh_cidr : "${chomp(data.http.my_public_ip.response_body)}/32"

  # Safe default spot ceilings — ~40% of on-demand for t4g.small in us-east-1,
  # ~25% above historical spot median. If market spikes above this, handoff
  # fires and cluster self-heals on a cheaper capacity pool instead of you
  # silently paying 7× on-demand all month. Applied ONLY when user leaves the
  # corresponding *_spot_max_price var at its empty-string default.
  default_master_spot_max = "0.006"
  default_worker_spot_max = "0.006"

  effective_master_spot_max = var.master_spot_max_price != "" ? var.master_spot_max_price : local.default_master_spot_max
  effective_worker_spot_max = var.worker_spot_max_price != "" ? var.worker_spot_max_price : local.default_worker_spot_max

  # 1-master mode needs ASG max=2 for the hot-potato headroom (handoff sets
  # desired=2 temporarily to get a candidate replacement). master_count=3 HA
  # mode disables hot-potato and uses exact-count raft members, so max must
  # equal desired.
  master_asg_max_size = var.master_count == 1 ? 2 : var.master_count

  # AWS region the provider is deployed into (used inside userdata templates
  # for aws ec2 associate-address + describe calls)
  region = data.aws_region.current.name
}

data "aws_region" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu-minimal/images/hvm-ssd/ubuntu-jammy-22.04-${var.cpu_arch}-minimal-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "eks-killer-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "eks-killer-igw" }
}

resource "aws_subnet" "this" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "eks-killer-subnet" }
}

resource "aws_route_table" "this" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "eks-killer-rt" }
}

resource "aws_route_table_association" "this" {
  subnet_id      = aws_subnet.this.id
  route_table_id = aws_route_table.this.id
}

# ---------------------------------------------------------------------------
# Security group - one flat SG, everything inside it trusts everything else
# ---------------------------------------------------------------------------

resource "aws_security_group" "cluster" {
  name        = "eks-killer-cluster-sg"
  description = "Single-node-master kubeadm cluster on spot"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.effective_allowed_cidr]
  }

  ingress {
    description = "k8s API server"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [local.effective_allowed_cidr]
  }

  # Everything within the SG trusts everything else in the SG:
  # etcd (2379/2380), kubelet (10250), NodePorts, handoff port, CNI overlay, etc.
  ingress {
    description = "All traffic within the cluster SG"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "eks-killer-cluster-sg" }
}

# ---------------------------------------------------------------------------
# Elastic IP - the one stable address for the control plane, re-associated
# on every master failover
# ---------------------------------------------------------------------------

resource "aws_eip" "master" {
  domain = "vpc"
  tags   = { Name = "eks-killer-master-eip" }
}

# ---------------------------------------------------------------------------
# IAM - shared role for master and workers. Broad-ish for a POC; tighten
# resource ARNs before you'd call this production.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "node" {
  name = "eks-killer-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "node" {
  name = "eks-killer-node-policy"
  role = aws_iam_role.node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EC2Control"
        Effect = "Allow"
        Action = [
          "ec2:RunInstances",
          "ec2:TerminateInstances",
          "ec2:CreateTags",
          "ec2:DescribeInstances",
          "ec2:DescribeAddresses",
          "ec2:AssociateAddress",
          "ec2:DescribeSpotInstanceRequests",
          "ec2:DescribeInstanceStatus",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeLaunchTemplateVersions",
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:SetDesiredCapacity",
          "autoscaling:AttachInstances",
          "autoscaling:DetachInstances",
          "autoscaling:TerminateInstanceInAutoScalingGroup"
        ]
        Resource = "*"
      },
      {
        Sid      = "PassSelf"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.node.arn
      },
    ]
  })
}

resource "aws_iam_instance_profile" "node" {
  name = "eks-killer-node-profile"
  role = aws_iam_role.node.name
}

# ---------------------------------------------------------------------------
# Master - a single spot instance launched directly (not in an ASG, since
# there is only ever one and its replacement is orchestrated by hand-off.sh,
# not by AWS's own replacement logic).
# ---------------------------------------------------------------------------

locals {
  scripts_dir = "${path.module}/../scripts"
  shared_dir  = "${local.scripts_dir}/shared"
  systemd_dir = "${local.shared_dir}/systemd"

  pyreceiver_py                  = file("${local.shared_dir}/pyreceiver.py")
  common_sh                      = file("${local.shared_dir}/common.sh")
  snapshot_loop_sh               = file("${local.shared_dir}/snapshot-loop.sh")
  watcher_master_sh              = file("${local.shared_dir}/watcher-master.sh")
  watcher_worker_sh              = file("${local.shared_dir}/watcher-worker.sh")
  handoff_sh                     = file("${local.shared_dir}/handoff.sh")
  receiver_master_sh             = file("${local.shared_dir}/receiver-master.sh")
  receiver_worker_sh             = file("${local.shared_dir}/receiver-worker.sh")
  systemd_snapshot_loop_service  = file("${local.systemd_dir}/snapshot-loop.service")
  systemd_watcher_master_service = file("${local.systemd_dir}/watcher-master.service")
  systemd_watcher_worker_service = file("${local.systemd_dir}/watcher-worker.service")
  systemd_receiver_service       = file("${local.systemd_dir}/receiver.service")
  systemd_eip_lo_service = templatefile("${local.systemd_dir}/eip-lo.service.tpl", {
    eip_public_ip = aws_eip.master.public_ip
  })

  master_userdata = templatefile("${local.scripts_dir}/master/bootstrap-master.sh.tpl", {
    eip_allocation_id  = aws_eip.master.id
    eip_public_ip      = aws_eip.master.public_ip
    handoff_port       = var.handoff_port
    pod_cidr           = var.pod_cidr
    kubernetes_version = var.kubernetes_version
    aws_region         = local.region

    pyreceiver_py                  = local.pyreceiver_py
    common_sh                      = local.common_sh
    snapshot_loop_sh               = local.snapshot_loop_sh
    watcher_master_sh              = local.watcher_master_sh
    watcher_worker_sh              = local.watcher_worker_sh
    handoff_sh                     = local.handoff_sh
    receiver_master_sh             = local.receiver_master_sh
    systemd_snapshot_loop_service  = local.systemd_snapshot_loop_service
    systemd_watcher_master_service = local.systemd_watcher_master_service
    systemd_watcher_worker_service = local.systemd_watcher_worker_service
    systemd_receiver_service       = local.systemd_receiver_service
    systemd_eip_lo_service         = local.systemd_eip_lo_service
  })

  worker_userdata = templatefile("${local.scripts_dir}/worker/bootstrap-worker.sh.tpl", {
    handoff_port       = var.handoff_port
    kubernetes_version = var.kubernetes_version
    aws_region         = local.region

    pyreceiver_py                  = local.pyreceiver_py
    common_sh                      = local.common_sh
    snapshot_loop_sh               = local.snapshot_loop_sh
    watcher_master_sh              = local.watcher_master_sh
    watcher_worker_sh              = local.watcher_worker_sh
    handoff_sh                     = local.handoff_sh
    receiver_worker_sh             = local.receiver_worker_sh
    systemd_snapshot_loop_service  = local.systemd_snapshot_loop_service
    systemd_watcher_master_service = local.systemd_watcher_master_service
    systemd_watcher_worker_service = local.systemd_watcher_worker_service
    systemd_receiver_service       = local.systemd_receiver_service
  })
}

resource "aws_launch_template" "master" {
  name_prefix   = "eks-killer-master-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = var.master_instance_type
  key_name      = var.key_name

  # Tagged so handoff.sh can look this template up by name at runtime via
  # the CLI - it never hardcodes the launch template ID.
  tags = { Name = "eks-killer-master-lt" }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      iops                  = 3000
      throughput            = 125
      delete_on_termination = true
    }
  }

  iam_instance_profile {
    arn = aws_iam_instance_profile.node.arn
  }

  network_interfaces {
    associate_public_ip_address = true
    subnet_id                   = aws_subnet.this.id
    security_groups             = [aws_security_group.cluster.id]
  }

  instance_market_options {
    market_type = "spot"
    spot_options {
      max_price                      = local.effective_master_spot_max
      spot_instance_type             = "one-time"
      instance_interruption_behavior = "terminate"
    }
  }

  metadata_options {
    http_tokens = "required" # IMDSv2 - the watcher scripts use IMDSv2 tokens
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name    = "eks-killer-master"
      Role    = "master"
      Project = "eks-killer"
    }
  }

  user_data = base64gzip(local.master_userdata)
}

resource "aws_autoscaling_group" "master" {
  name_prefix         = "eks-killer-master-"
  desired_capacity    = var.master_count
  min_size            = var.master_count
  max_size            = local.master_asg_max_size
  vpc_zone_identifier = [aws_subnet.this.id]

  launch_template {
    id      = aws_launch_template.master.id
    version = "$Latest"
  }

  # capacity_rebalance must stay off: handoff.sh needs the old master alive
  # to stream its etcd bundle, and rebalancing terminates at-risk instances
  # on its own schedule.

  tag {
    key                 = "Name"
    value               = "eks-killer-master"
    propagate_at_launch = true
  }
  tag {
    key                 = "Role"
    value               = "master"
    propagate_at_launch = true
  }
  tag {
    key                 = "Project"
    value               = "eks-killer"
    propagate_at_launch = true
  }
}

# ---------------------------------------------------------------------------
# Workers - a spot-backed Auto Scaling Group. ASG handles "always keep N
# running" for us; workers only need to cordon/drain themselves on
# interruption, AWS + the ASG take care of the replacement.
# ---------------------------------------------------------------------------

resource "aws_launch_template" "worker" {
  name_prefix   = "eks-killer-worker-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = var.worker_instance_type
  key_name      = var.key_name

  tags = { Name = "eks-killer-worker-lt" }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      iops                  = 3000
      throughput            = 125
      delete_on_termination = true
    }
  }

  iam_instance_profile {
    arn = aws_iam_instance_profile.node.arn
  }

  network_interfaces {
    associate_public_ip_address = true
    subnet_id                   = aws_subnet.this.id
    security_groups             = [aws_security_group.cluster.id]
  }

  instance_market_options {
    market_type = "spot"
    spot_options {
      max_price                      = local.effective_worker_spot_max
      spot_instance_type             = "one-time"
      instance_interruption_behavior = "terminate"
    }
  }

  metadata_options {
    http_tokens = "required"
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "eks-killer-worker"
      Role = "worker"
    }
  }

  user_data = base64gzip(local.worker_userdata)
}

resource "aws_autoscaling_group" "worker" {
  name_prefix         = "eks-killer-worker-"
  desired_capacity    = var.worker_count
  min_size            = var.worker_count
  max_size            = var.worker_count + 2 # headroom for surge-replace during promotion backfill
  vpc_zone_identifier = [aws_subnet.this.id]

  launch_template {
    id      = aws_launch_template.worker.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "eks-killer-worker"
    propagate_at_launch = true
  }
  tag {
    key                 = "Role"
    value               = "worker"
    propagate_at_launch = true
  }

  depends_on = [aws_autoscaling_group.master]
}

# ---------------------------------------------------------------------------
# Readiness gate - apply does not finish until the master is actually
# kubectl-ready (admin.conf exists, apiserver answers, master node Ready).
# If userdata/kubeadm fails, this fails the apply instead of silently
# handing you a dead EIP. Re-runs whenever the master instance is replaced.
# ---------------------------------------------------------------------------

locals {
  key_path = var.key_path != "" ? var.key_path : "${path.module}/${var.key_name}.pem"
}

resource "null_resource" "cluster_ready" {
  depends_on = [aws_autoscaling_group.master, aws_autoscaling_group.worker]

  triggers = {
    asg_name = aws_autoscaling_group.master.name
  }

  connection {
    type        = "ssh"
    user        = "ubuntu"
    host        = aws_eip.master.public_ip
    private_key = file(local.key_path)
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '[eks-killer] waiting for kubeadm to produce admin.conf (up to ~20 min on first boot)...'",
      "for i in $(seq 1 100); do sudo test -f /etc/kubernetes/admin.conf && break; sleep 12; done",
      "sudo test -f /etc/kubernetes/admin.conf || { echo '[eks-killer] FATAL: admin.conf never appeared'; tail -n 30 /var/log/eks-killer-userdata.log; exit 1; }",
      "echo '[eks-killer] waiting for apiserver /readyz...'",
      "for i in $(seq 1 60); do sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get --raw='/readyz' >/dev/null 2>&1 && break; sleep 12; done",
      "sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get --raw='/readyz' >/dev/null || { echo '[eks-killer] FATAL: apiserver never became ready'; tail -n 30 /var/log/eks-killer.log; exit 1; }",
      "echo '[eks-killer] waiting for master node to report Ready...'",
      "for i in $(seq 1 30); do sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf wait --for=condition=Ready node --all --timeout=12s >/dev/null 2>&1 && break; sleep 12; done",
      "sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes -o wide"
    ]
  }
}

# ---------------------------------------------------------------------------
# Pre-destroy hook: sweeps any instances in the VPC before deleting subnets/VPC
# ---------------------------------------------------------------------------
resource "null_resource" "vpc_instance_cleaner" {
  triggers = {
    vpc_id     = aws_vpc.this.id
    aws_region = local.region
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      INSTANCES=$(aws ec2 describe-instances --region "${self.triggers.aws_region}" \
        --filters "Name=vpc-id,Values=${self.triggers.vpc_id}" "Name=instance-state-name,Values=running,pending" \
        --query "Reservations[].Instances[].InstanceId" --output text 2>/dev/null || true)
      if [ -n "$INSTANCES" ] && [ "$INSTANCES" != "None" ]; then
        echo "[eks-killer] cleaning up active instances before VPC destroy: $INSTANCES"
        aws ec2 terminate-instances --region "${self.triggers.aws_region}" --instance-ids $INSTANCES >/dev/null 2>&1 || true
        aws ec2 wait instance-terminated --region "${self.triggers.aws_region}" --instance-ids $INSTANCES >/dev/null 2>&1 || true
      fi
    EOT
  }
}

# ---------------------------------------------------------------------------
# AWS FIS Spot Killer - official AWS Fault Injection Simulator experiment
# to send a real 2-minute Spot interruption warning to the master instance.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "fis" {
  name = "eks-killer-fis-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "fis.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "fis" {
  name = "eks-killer-fis-policy"
  role = aws_iam_role.fis.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EC2FaultInjection"
        Effect = "Allow"
        Action = [
          "ec2:RebootInstances",
          "ec2:StopInstances",
          "ec2:StartInstances",
          "ec2:TerminateInstances",
          "ec2:DescribeInstances",
          "ec2:SendSpotInstanceInterruptions"
        ]
        Resource = "*"
      },
      {
        Sid      = "TaggingAccess"
        Effect   = "Allow"
        Action   = "tag:GetResources"
        Resource = "*"
      }
    ]
  })
}

resource "aws_fis_experiment_template" "spot_killer" {
  description = "Simulate official AWS Spot instance interruption on eks-killer master"
  role_arn    = aws_iam_role.fis.arn

  stop_condition {
    source = "none"
  }

  action {
    name      = "spotInterruption"
    action_id = "aws:ec2:send-spot-instance-interruptions"

    parameter {
      key   = "durationBeforeInterruption"
      value = "PT2M"
    }

    target {
      key   = "SpotInstances"
      value = "MasterSpotInstance"
    }
  }

  target {
    name           = "MasterSpotInstance"
    resource_type  = "aws:ec2:spot-instance"
    selection_mode = "ALL"

    resource_tag {
      key   = "Project"
      value = "eks-killer"
    }

    resource_tag {
      key   = "Role"
      value = "master"
    }
  }

  tags = {
    Name    = "eks-killer-spot-killer"
    Project = "eks-killer"
  }
}

