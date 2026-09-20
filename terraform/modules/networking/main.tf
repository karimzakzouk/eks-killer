data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, {
    Name = "eks-killer-vpc"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "eks-killer-igw"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_subnet" "this" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name = "eks-killer-subnet"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route_table" "this" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(var.tags, {
    Name = "eks-killer-rt"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route_table_association" "this" {
  subnet_id      = aws_subnet.this.id
  route_table_id = aws_route_table.this.id
}

resource "aws_security_group" "cluster" {
  name        = "eks-killer-cluster-sg"
  description = "Single-node-master kubeadm cluster on spot - full intra-SG trust, restricted SSH plus API from allowed_cidr"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "SSH from allowed CIDR"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  ingress {
    description = "Kubernetes API server (kube-apiserver) from allowed CIDR"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  ingress {
    description = "All protocols / all ports - intra-cluster SG self-rule (etcd, kubelet, handoff, CNI, NodePorts, etc)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    description = "Unrestricted outbound (apt, image pulls, AWS API, IMDS)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "eks-killer-cluster-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_eip" "master" {
  domain = "vpc"

  tags = merge(var.tags, {
    Name = "eks-killer-master-eip"
  })

  lifecycle {
    create_before_destroy = true
  }
}
