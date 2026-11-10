# Regional VPC for the HyperPod global inference sample.
#
# Layout when create_vpc = true:
#   - Public subnets  (one per AZ): host NAT gateways for private-subnet egress.
#   - Private subnets (one per AZ): EKS nodes, HyperPod instance groups, the internal ALB,
#     LiteLLM, Aurora, and ElastiCache. No public IPs.
#
# EKS-orchestrated HyperPod REQUIRES a VpcConfig and it is IMMUTABLE after cluster creation, so the
# subnet/AZ topology here is effectively permanent for the life of the cluster.

data "aws_availability_zones" "available" {
  count = var.create_vpc ? 1 : 0
  state = "available"
}

locals {
  azs = var.create_vpc ? slice(data.aws_availability_zones.available[0].names, 0, var.az_count) : []

  # /20 private + /24 public subnets carved from the VPC CIDR.
  private_cidrs = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  public_cidrs  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i + 200)]
}

# --------------------------------------------------------------------------------------------------
# Created VPC (create_vpc = true)
# --------------------------------------------------------------------------------------------------

resource "aws_vpc" "this" {
  count                = var.create_vpc ? 1 : 0
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(var.tags, { Name = "${var.name_prefix}-vpc" })
}

resource "aws_internet_gateway" "this" {
  count  = var.create_vpc ? 1 : 0
  vpc_id = aws_vpc.this[0].id
  tags   = merge(var.tags, { Name = "${var.name_prefix}-igw" })
}

resource "aws_subnet" "public" {
  count                   = var.create_vpc ? var.az_count : 0
  vpc_id                  = aws_vpc.this[0].id
  cidr_block              = local.public_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false
  tags = merge(var.tags, {
    Name                     = "${var.name_prefix}-public-${local.azs[count.index]}"
    "kubernetes.io/role/elb" = "1"
  })
}

resource "aws_subnet" "private" {
  count             = var.create_vpc ? var.az_count : 0
  vpc_id            = aws_vpc.this[0].id
  cidr_block        = local.private_cidrs[count.index]
  availability_zone = local.azs[count.index]
  tags = merge(var.tags, {
    Name                              = "${var.name_prefix}-private-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb" = "1"
  })
}

# One NAT gateway per AZ for private egress (HuggingFace weight pulls, container image pulls).
resource "aws_eip" "nat" {
  count  = var.create_vpc ? var.az_count : 0
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.name_prefix}-nat-${local.azs[count.index]}" })
}

resource "aws_nat_gateway" "this" {
  count         = var.create_vpc ? var.az_count : 0
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = merge(var.tags, { Name = "${var.name_prefix}-nat-${local.azs[count.index]}" })
  depends_on    = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  count  = var.create_vpc ? 1 : 0
  vpc_id = aws_vpc.this[0].id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this[0].id
  }
  tags = merge(var.tags, { Name = "${var.name_prefix}-rt-public" })
}

resource "aws_route_table_association" "public" {
  count          = var.create_vpc ? var.az_count : 0
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_route_table" "private" {
  count  = var.create_vpc ? var.az_count : 0
  vpc_id = aws_vpc.this[0].id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[count.index].id
  }
  tags = merge(var.tags, { Name = "${var.name_prefix}-rt-private-${local.azs[count.index]}" })
}

resource "aws_route_table_association" "private" {
  count          = var.create_vpc ? var.az_count : 0
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# --------------------------------------------------------------------------------------------------
# Resolved network references (works for both created and BYO VPC)
# --------------------------------------------------------------------------------------------------

locals {
  vpc_id             = var.create_vpc ? aws_vpc.this[0].id : var.byo_vpc_id
  private_subnet_ids = var.create_vpc ? aws_subnet.private[*].id : var.byo_private_subnet_ids
  public_subnet_ids  = var.create_vpc ? aws_subnet.public[*].id : var.byo_public_subnet_ids
}

data "aws_vpc" "resolved" {
  id = local.vpc_id
}

# --------------------------------------------------------------------------------------------------
# Gateway VPC endpoints (S3) + Interface endpoints (ECR, STS, Logs) to keep AWS traffic off NAT.
# --------------------------------------------------------------------------------------------------

resource "aws_security_group" "vpce" {
  name_prefix = "${var.name_prefix}-vpce-"
  description = "Allow HTTPS from within the VPC to interface VPC endpoints."
  vpc_id      = local.vpc_id
  tags        = merge(var.tags, { Name = "${var.name_prefix}-vpce" })

  ingress {
    description = "HTTPS from the VPC CIDR only."
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.resolved.cidr_block]
  }

  egress {
    description = "Return traffic within the VPC."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [data.aws_vpc.resolved.cidr_block]
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = local.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = var.create_vpc ? aws_route_table.private[*].id : []
  tags              = merge(var.tags, { Name = "${var.name_prefix}-vpce-s3" })
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = toset(["ecr.api", "ecr.dkr", "sts", "logs"])
  vpc_id              = local.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.private_subnet_ids
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true
  tags                = merge(var.tags, { Name = "${var.name_prefix}-vpce-${each.value}" })
}

data "aws_region" "current" {}
