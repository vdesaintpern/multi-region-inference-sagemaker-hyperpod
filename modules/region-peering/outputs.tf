output "peering_connection_id" {
  description = "Id of the cross-region VPC peering connection (primary <-> peer region)."
  value       = aws_vpc_peering_connection.this.id
}
