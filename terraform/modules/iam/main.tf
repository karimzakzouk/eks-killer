resource "aws_iam_role" "node" {
  name = var.node_role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = merge(var.tags, {
    Name = var.node_role_name
  })
}

resource "aws_iam_role_policy" "node" {
  name = "${var.node_role_name}-policy"
  role = aws_iam_role.node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EC2AndAutoscalingControl"
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
        Sid      = "PassSelfRoleOnly"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.node.arn
      },
    ]
  })
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.node_role_name}-profile"
  role = aws_iam_role.node.name
}

resource "aws_iam_role" "fis" {
  count = var.enable_fis_role ? 1 : 0
  name  = var.fis_role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "fis.amazonaws.com" }
    }]
  })

  tags = merge(var.tags, {
    Name = var.fis_role_name
  })
}

resource "aws_iam_role_policy" "fis" {
  count = var.enable_fis_role ? 1 : 0
  name  = "${var.fis_role_name}-policy"
  role  = aws_iam_role.fis[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EC2FaultInjectionActions"
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
        Sid      = "ResourceGroupTaggingLookup"
        Effect   = "Allow"
        Action   = "tag:GetResources"
        Resource = "*"
      },
    ]
  })
}
