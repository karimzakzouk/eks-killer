resource "aws_fis_experiment_template" "spot_killer" {
  description = "Official AWS Fault Injection Simulator spot-interruption experiment — sends the real 2-minute IMDS notice to eks-killer masters."
  role_arn    = var.fis_role_arn

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

  tags = merge(var.tags, {
    Name    = "eks-killer-spot-killer"
    Project = "eks-killer"
  })
}
