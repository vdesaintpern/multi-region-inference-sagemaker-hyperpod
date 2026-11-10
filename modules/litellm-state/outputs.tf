output "cluster_writer_endpoint" {
  description = "Writer (primary instance) endpoint of the regional Aurora cluster."
  value       = aws_rds_cluster.this.endpoint
}

output "cluster_reader_endpoint" {
  description = "Reader endpoint of the regional Aurora cluster."
  value       = aws_rds_cluster.this.reader_endpoint
}

output "db_secret_arn" {
  description = "ARN of the Secrets Manager secret holding Aurora master credentials."
  value       = aws_secretsmanager_secret.db.arn
}

output "redis_primary_endpoint" {
  description = "Primary endpoint address of the ElastiCache Redis replication group."
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "redis_port" {
  description = "Port the ElastiCache Redis replication group listens on."
  value       = aws_elasticache_replication_group.this.port
}

output "redis_auth_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the Redis AUTH token (transit encryption is enabled)."
  value       = aws_secretsmanager_secret.redis_auth.arn
}

output "db_security_group_id" {
  description = "Security group ID protecting the Aurora cluster (5432)."
  value       = aws_security_group.db.id
}

output "redis_security_group_id" {
  description = "Security group ID protecting the ElastiCache Redis replication group (6379)."
  value       = aws_security_group.redis.id
}
