output "redis_host" {
  description = "Primary endpoint hostname of the L2 KV cache Redis."
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "redis_port" {
  description = "Redis port."
  value       = 6379
}

output "security_group_id" {
  description = "Security group guarding the L2 KV cache Redis."
  value       = aws_security_group.this.id
}
