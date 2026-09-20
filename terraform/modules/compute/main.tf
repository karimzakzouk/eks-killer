locals {
  master_asg_max_size = var.master_count == 1 ? 2 : var.master_count

  effective_master_spot_max = var.master_spot_max_price != "" ? var.master_spot_max_price : null
  effective_worker_spot_max = var.worker_spot_max_price != "" ? var.worker_spot_max_price : null

  # Subnets for ASG vpc_zone_identifier: prefer explicit subnet_ids[], else fall back to single subnet_id
  effective_subnet_ids = length(var.subnet_ids) > 0 ? var.subnet_ids : (
    var.subnet_id != "" ? [var.subnet_id] : []
  )
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

resource "aws_launch_template" "master" {
  name_prefix   = "eks-killer-master-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = var.master_instance_type
  key_name      = var.key_name

  tags = merge(var.tags, {
    Name = "eks-killer-master-lt"
  })

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = var.root_volume_size_gb
      volume_type           = "gp3"
      iops                  = 3000
      throughput            = 125
      delete_on_termination = true
    }
  }

  iam_instance_profile {
    arn = var.instance_profile_arn
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = var.security_group_ids
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
    http_tokens = "required" # IMDSv2 only — watcher scripts use IMDSv2 token flow exclusively
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name    = "eks-killer-master"
      Role    = "master"
      Project = "eks-killer"
    })
  }

  # EC2/cloud-init auto-detects gzip-compressed user data (via its magic bytes)
  # and decompresses it before running it, so no decode wrapper is needed here.
  # base64gzip() keeps this comfortably under the 16384-byte raw user_data limit
  # (an xz-compressed blob re-embedded as base64 *text* in a shell wrapper, as
  # this used to do, inflates ~33% past the limit even though the underlying
  # compressed payload was small).
  user_data = base64gzip(var.master_userdata)

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "master" {
  name_prefix         = "eks-killer-master-"
  desired_capacity    = var.master_count
  min_size            = var.master_count
  max_size            = local.master_asg_max_size
  vpc_zone_identifier = local.effective_subnet_ids

  launch_template {
    id      = aws_launch_template.master.id
    version = "$Latest"
  }

  # capacity_rebalance stays OFF: handoff needs the old master alive to stream the
  # etcd snapshot; AWS rebalance terminates on its own schedule which can race.

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

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_launch_template" "worker" {
  name_prefix   = "eks-killer-worker-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = var.worker_instance_type
  key_name      = var.key_name

  tags = merge(var.tags, {
    Name = "eks-killer-worker-lt"
  })

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = var.root_volume_size_gb
      volume_type           = "gp3"
      iops                  = 3000
      throughput            = 125
      delete_on_termination = true
    }
  }

  iam_instance_profile {
    arn = var.instance_profile_arn
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = var.security_group_ids
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
    http_tokens = "required"
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name = "eks-killer-worker"
      Role = "worker"
    })
  }

  # See the comment on aws_launch_template.master.user_data above.
  user_data = base64gzip(var.worker_userdata)

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "worker" {
  name_prefix         = "eks-killer-worker-"
  desired_capacity    = var.worker_count
  min_size            = var.worker_count
  max_size            = var.worker_count + 2 # surge-replace headroom during worker-promotion backfill
  vpc_zone_identifier = local.effective_subnet_ids

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

  lifecycle {
    create_before_destroy = true
  }
}
