# Cross-region VPC peering, star topology: the PRIMARY region's VPC (requester) peers with ONE other
# region's VPC (accepter). The central LiteLLM lives in the primary and must reach each region's internal
# model ALB; the regions never talk to each other, so a star of primary<->region peerings (no transitivity)
# is sufficient and cheaper than a Transit Gateway (no hourly/attachment fees). This module is instantiated
# once per non-primary region from the `platform` root, which supplies the two providers:
#   aws       = requester (primary region)
#   aws.peer  = accepter  (the remote region)

resource "aws_vpc_peering_connection" "this" {
  vpc_id      = var.requester_vpc_id
  peer_vpc_id = var.peer_vpc_id
  peer_region = var.peer_region
  auto_accept = false # cross-region peering cannot auto-accept on the requester side

  tags = merge(var.tags, { Name = "${var.name_prefix}-pcx-${var.peer_region}" })
}

resource "aws_vpc_peering_connection_accepter" "peer" {
  provider                  = aws.peer
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
  auto_accept               = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-pcx-${var.peer_region}-accepter" })
}

# Allow private (VPC) DNS names to resolve across the peering connection, from each side.
# Each option block must be applied on the side that owns that role: the requester-side resource sets the
# requester flag, the accepter-side resource (aws.peer) sets the accepter flag. Both depend on the accepter
# so the connection is ACTIVE before options are set.
resource "aws_vpc_peering_connection_options" "requester" {
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id

  requester {
    allow_remote_vpc_dns_resolution = true
  }

  depends_on = [aws_vpc_peering_connection_accepter.peer]
}

resource "aws_vpc_peering_connection_options" "accepter" {
  provider                  = aws.peer
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.peer.id

  accepter {
    allow_remote_vpc_dns_resolution = true
  }

  depends_on = [aws_vpc_peering_connection_accepter.peer]
}

# Primary private route tables -> peer CIDR via the peering connection.
resource "aws_route" "to_peer" {
  for_each = toset(var.requester_route_table_ids)

  route_table_id            = each.value
  destination_cidr_block    = var.peer_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id

  depends_on = [aws_vpc_peering_connection_accepter.peer]
}

# Peer private route tables -> primary CIDR via the peering connection.
resource "aws_route" "from_peer" {
  provider = aws.peer
  for_each = toset(var.peer_route_table_ids)

  route_table_id            = each.value
  destination_cidr_block    = var.requester_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id

  depends_on = [aws_vpc_peering_connection_accepter.peer]
}
