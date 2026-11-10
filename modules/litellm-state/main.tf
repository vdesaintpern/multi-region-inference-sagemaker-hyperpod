# State backend for the central LiteLLM proxy (single region).
#
#   - Aurora PostgreSQL (Serverless v2): LiteLLM's single source of truth for virtual keys, teams,
#     budgets, and spend. One regional writer cluster in the primary region (where the one central
#     LiteLLM runs). No global database / no cross-region replication - the gateway is single-region.
#   - Regional ElastiCache Redis: rate-limit counters and optional KV L2 cache.
#
# Secure by default: KMS encryption at rest, TLS/transit encryption on Redis, no public access,
# no 0.0.0.0/0 ingress, and generated master/auth credentials stored in Secrets Manager.

# --------------------------------------------------------------------------------------------------
# KMS key (encryption at rest for Aurora, ElastiCache, and Secrets Manager)
# --------------------------------------------------------------------------------------------------

resource "aws_kms_key" "this" {
  description             = "${var.name_prefix} LiteLLM state encryption key (Aurora, ElastiCache, Secrets Manager)."
  enable_key_rotation     = true
  deletion_window_in_days = 7
  tags                    = merge(var.tags, { Name = "${var.name_prefix}-litellm-kms" })
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.name_prefix}-litellm-state"
  target_key_id = aws_kms_key.this.key_id
}

# --------------------------------------------------------------------------------------------------
# Aurora master credentials -> Secrets Manager (single-region secret)
# --------------------------------------------------------------------------------------------------

resource "random_password" "db" {
  # RDS master passwords cannot contain '/', '@', '"', or spaces.
  length = 32
  # URL-safe specials only: the LiteLLM chart builds the DATABASE_URL by string-substituting the
  # password without URL-encoding, so characters like []{}%@:/# would corrupt the DSN.
  special          = true
  override_special = "-_"
}

resource "aws_secretsmanager_secret" "db" {
  name        = "${var.name_prefix}-litellm-db"
  description = "Aurora master credentials for the LiteLLM state database."
  kms_key_id  = aws_kms_key.this.arn
  # Free the fixed name immediately on destroy so a redeploy does not collide with a recovery-window secret.
  recovery_window_in_days = 0
  tags                    = merge(var.tags, { Name = "${var.name_prefix}-litellm-db" })
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = var.master_username
    password = random_password.db.result
    dbname   = var.db_name
    port     = 5432
  })
}

# --------------------------------------------------------------------------------------------------
# Aurora networking (DB subnet group + security group)
# --------------------------------------------------------------------------------------------------

resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-litellm-db"
  subnet_ids = var.private_subnet_ids
  tags       = merge(var.tags, { Name = "${var.name_prefix}-litellm-db" })
}

resource "aws_security_group" "db" {
  name_prefix = "${var.name_prefix}-litellm-db-"
  description = "Allow PostgreSQL (5432) from approved LiteLLM sources only."
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name_prefix}-litellm-db" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_sg" {
  for_each                     = toset(var.allowed_security_group_ids)
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = each.value
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "PostgreSQL from approved security group."
  tags                         = merge(var.tags, { Name = "${var.name_prefix}-litellm-db-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "db_from_cidr" {
  for_each          = toset(var.allowed_cidr_blocks)
  security_group_id = aws_security_group.db.id
  cidr_ipv4         = each.value
  from_port         = 5432
  to_port           = 5432
  ip_protocol       = "tcp"
  description       = "PostgreSQL from approved CIDR."
  tags              = merge(var.tags, { Name = "${var.name_prefix}-litellm-db-cidr" })
}

# --------------------------------------------------------------------------------------------------
# Aurora PostgreSQL (single regional Serverless v2 writer cluster)
# --------------------------------------------------------------------------------------------------

resource "aws_rds_cluster" "this" {
  cluster_identifier = "${var.name_prefix}-litellm"
  engine             = "aurora-postgresql"
  engine_version     = var.engine_version

  database_name     = var.db_name
  master_username   = var.master_username
  master_password   = random_password.db.result
  apply_immediately = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]

  storage_encrypted                   = true
  kms_key_id                          = aws_kms_key.this.arn
  iam_database_authentication_enabled = true
  deletion_protection                 = var.deletion_protection

  backup_retention_period = var.backup_retention_period
  skip_final_snapshot     = true

  serverlessv2_scaling_configuration {
    min_capacity = var.serverless_min_capacity
    max_capacity = var.serverless_max_capacity
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-litellm" })
}

resource "aws_rds_cluster_instance" "this" {
  identifier                   = "${var.name_prefix}-litellm-writer"
  cluster_identifier           = aws_rds_cluster.this.id
  engine                       = "aurora-postgresql"
  engine_version               = var.engine_version
  instance_class               = "db.serverless"
  db_subnet_group_name         = aws_db_subnet_group.this.name
  performance_insights_enabled = true
  # Reuse the module CMK so Performance Insights data is encrypted with a customer-managed key.
  performance_insights_kms_key_id = aws_kms_key.this.arn
  tags                            = merge(var.tags, { Name = "${var.name_prefix}-litellm-writer" })
}

# --------------------------------------------------------------------------------------------------
# ElastiCache Redis (regional: rate-limit counters + optional KV L2 cache)
# --------------------------------------------------------------------------------------------------

resource "random_password" "redis_auth" {
  # Redis AUTH tokens cannot contain '/', '@', '"', or spaces.
  length           = 32
  special          = true
  override_special = "!&#$^<>-"
}

resource "aws_secretsmanager_secret" "redis_auth" {
  name        = "${var.name_prefix}-litellm-redis-auth"
  description = "ElastiCache Redis AUTH token for the LiteLLM rate-limit / cache store."
  kms_key_id  = aws_kms_key.this.arn
  # Free the fixed name immediately on destroy so a redeploy does not collide with a recovery-window secret.
  recovery_window_in_days = 0
  tags                    = merge(var.tags, { Name = "${var.name_prefix}-litellm-redis-auth" })
}

resource "aws_secretsmanager_secret_version" "redis_auth" {
  secret_id = aws_secretsmanager_secret.redis_auth.id
  secret_string = jsonencode({
    auth_token = random_password.redis_auth.result
    port       = 6379
  })
}

resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.name_prefix}-litellm-redis"
  subnet_ids = var.private_subnet_ids
  tags       = merge(var.tags, { Name = "${var.name_prefix}-litellm-redis" })
}

resource "aws_security_group" "redis" {
  name_prefix = "${var.name_prefix}-litellm-redis-"
  description = "Allow Redis (6379) from approved LiteLLM sources only."
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name_prefix}-litellm-redis" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "redis_from_sg" {
  for_each                     = toset(var.allowed_security_group_ids)
  security_group_id            = aws_security_group.redis.id
  referenced_security_group_id = each.value
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
  description                  = "Redis from approved security group."
  tags                         = merge(var.tags, { Name = "${var.name_prefix}-litellm-redis-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "redis_from_cidr" {
  for_each          = toset(var.allowed_cidr_blocks)
  security_group_id = aws_security_group.redis.id
  cidr_ipv4         = each.value
  from_port         = 6379
  to_port           = 6379
  ip_protocol       = "tcp"
  description       = "Redis from approved CIDR."
  tags              = merge(var.tags, { Name = "${var.name_prefix}-litellm-redis-cidr" })
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = "${var.name_prefix}-litellm-redis"
  description          = "LiteLLM rate-limit counters and optional KV L2 cache."

  engine             = "redis"
  node_type          = var.redis_node_type
  port               = 6379
  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.redis.id]

  num_cache_clusters         = var.redis_automatic_failover ? 2 : 1
  automatic_failover_enabled = var.redis_automatic_failover
  multi_az_enabled           = var.redis_automatic_failover

  at_rest_encryption_enabled = true
  kms_key_id                 = aws_kms_key.this.arn
  transit_encryption_enabled = true
  auth_token                 = random_password.redis_auth.result

  tags = merge(var.tags, { Name = "${var.name_prefix}-litellm-redis" })
}
