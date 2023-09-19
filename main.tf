terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.16"
    }
  }

  required_version = ">= 1.2.0"
}

# Region
provider "aws" {
  profile = "default"
  region = var.aws_region
}

# availability zone
locals {
  availability_zones = ["${var.aws_region}a", "${var.aws_region}b"]
}

# VPC
resource "aws_vpc" "vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "${var.environment}-vpc"
    Environment = var.environment
  }
}

# Public subnet
resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.vpc.id
  count                   = length(var.public_subnets_cidr)
  cidr_block              = element(var.public_subnets_cidr, count.index)
  availability_zone       = element(local.availability_zones, count.index)
  map_public_ip_on_launch = true

  tags = {
    Name        = "${var.environment}-${element(local.availability_zones, count.index)}-public-subnet"
    Environment = "${var.environment}"
  }
}

# Private Subnet
resource "aws_subnet" "private_subnet" {
  vpc_id                  = aws_vpc.vpc.id
  count                   = length(var.private_subnets_cidr)
  cidr_block              = element(var.private_subnets_cidr, count.index)
  availability_zone       = element(local.availability_zones, count.index)
  map_public_ip_on_launch = false

  tags = {
    Name        = "${var.environment}-${element(local.availability_zones, count.index)}-private-subnet"
    Environment = "${var.environment}"
  }
}

# Internet gateway
resource "aws_internet_gateway" "ig" {
  vpc_id = aws_vpc.vpc.id
  tags = {
    "Name"        = "${var.environment}-igw"
    "Environment" = var.environment
  }
}

# Elastic-IP (eip) for NAT
resource "aws_eip" "nat_eip" {
  vpc        = true
  depends_on = [aws_internet_gateway.ig]
}

# NAT Gateway
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = element(aws_subnet.public_subnet.*.id, 0)
  tags = {
    Name        = "${var.environment}-nat-gateway"
    Environment = "${var.environment}"
  }
}

# Routing tables to route traffic for Public Subnet
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.vpc.id

  tags = {
    Name        = "${var.environment}-public-route-table"
    Environment = "${var.environment}"
  }
}

# Routing tables to route traffic for Private Subnet
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.vpc.id
  tags = {
    Name        = "${var.environment}-private-route-table"
    Environment = "${var.environment}"
  }
}

# Route for Internet Gateway
resource "aws_route" "public_internet_gateway" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.ig.id
}

# Route for NAT Gateway
resource "aws_route" "private_internet_gateway" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_nat_gateway.nat.id
}

# Route table associations for Public subnet
resource "aws_route_table_association" "public" {
  count          = length(var.public_subnets_cidr)
  subnet_id      = element(aws_subnet.public_subnet.*.id, count.index)
  route_table_id = aws_route_table.public.id
}

# Route table associations for Private subnet
resource "aws_route_table_association" "private" {
  count          = length(var.private_subnets_cidr)
  subnet_id      = element(aws_subnet.private_subnet.*.id, count.index)
  route_table_id = aws_route_table.private.id
}

# Security group for Public access
resource "aws_security_group" "wordpress-access" {
  vpc_id = aws_vpc.vpc.id

  egress {
      from_port   = 0
      to_port     = 0
      protocol    = -1
      cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "wordpress-access"
  }
}

# Security group for Private access
resource "aws_security_group" "private-access" {
  vpc_id = aws_vpc.vpc.id

  egress {
      from_port   = 0
      to_port     = 0
      protocol    = -1
      cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
      from_port   = 0
      to_port     = 0
      protocol    = "tcp"
      cidr_blocks = ["10.0.0.0/16"]
  }
  tags = {
    Name = "private-access"
  }
}

# Launch Template for instance wordpress
resource "aws_launch_template" "wordpress-lc" {
  name_prefix            = "wordpress-lc"
  description            = "Wordpress Launch Template"
  image_id               = "ami-0dea4c77aa6baff5a"
  instance_type          = "t3.micro"
  vpc_security_group_ids = ["${aws_security_group.wordpress-access.id}", "${aws_security_group.private-access.id}"]
  key_name               = aws_key_pair.key-pair.id

  connection {
      user = "ubuntu"
      private_key = "${file("${var.private_key_path}")}"
  }
}

# Auto Scaling Group for instance wordpress
resource "aws_autoscaling_group" "wordpress-asg" {
  name_prefix = "wordpress-asg"

  launch_template {
   id      = aws_launch_template.wordpress-lc.id
   version = "$Latest"
  }

  min_size             = 2
  max_size             = 4
  desired_capacity     = 2
  vpc_zone_identifier  = [aws_subnet.public_subnet[1].id]
}

# Auto Scaling Group for instance wordpress
resource "aws_instance" "database" {
  ami                    = "ami-0dea4c77aa6baff5a"
  instance_type          = "t3.micro"
  subnet_id              = element(aws_subnet.private_subnet.*.id, 0)
  vpc_security_group_ids = ["${aws_security_group.private-access.id}"]
  key_name               = aws_key_pair.key-pair.id

  connection {
      user = "ubuntu"
      private_key = "${file("${var.private_key_path}")}"
  }
}

# Key pair access key
resource "aws_key_pair" "key-pair" {
    key_name   = "${var.environment}-key"
    public_key = "${file(var.public_key_path)}"
}
