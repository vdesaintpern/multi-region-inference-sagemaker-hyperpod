# Dedicated ElastiCache Redis for the HyperPod inference L2 KV cache (LMCache remote backend).
#
# Separate from the LiteLLM rate-limit Redis on purpose:
#   - The LMCache L2 URL is injected into the InferenceEndpointConfig as a plain `redis://host:port`
#     (the operator renders LMCACHE_REMOTE_URL from kvCacheSpec.l2CacheSpec.l2CacheLocalUrl).
#   - IN-TRANSIT ENCRYPTION IS DELIBERATELY OFF. The HyperPod inference operator's l2CacheLocalUrl
#     accepts ONLY the redis / redis-sentinel / valkey URL schemes (verified against the
#     InferenceEndpointConfig CRD; a `rediss://` URL is rejected with "invalid cache URL scheme"), and
#     the l2CacheSpec exposes no separate TLS toggle. An ElastiCache group with transit encryption
#     requires TLS clients, so enabling it makes the operator unable to build the deployment spec and no
#     serving pod is ever created. The cache is therefore locked down at the NETWORK layer instead:
#     in-VPC only, security group restricted to the HyperPod node security groups. See the checkov:skip
#     on the replication group below.
#   - Encryption AT REST uses a customer-managed KMS key (compatible with the operator; no client change).
#   - KV cache is a performance tier, not durable state: on loss, LMCache recomputes. A single node is
#     fine; no automatic failover.

resource "aws_kms_key" "this" {
  description             = "${var.name_prefix} L2 KV cache Redis at-rest encryption key."
  enable_key_rotation     = true
  deletion_window_in_days = 7
  tags                    = merge(var.tags, { Name = "${var.name_prefix}-kv-l2-redis-kms" })
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.name_prefix}-kv-l2-redis"
  target_key_id = aws_kms_key.this.key_id
}

resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.name_prefix}-kv-l2-redis"
  subnet_ids = var.private_subnet_ids
  tags       = merge(var.tags, { Name = "${var.name_prefix}-kv-l2-redis" })
}

resource "aws_security_group" "this" {
  name_prefix = "${var.name_prefix}-kv-l2-redis-"
  description = "Allow Redis (6379) from the HyperPod node security groups only (LMCache L2 KV cache)."
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name_prefix}-kv-l2-redis" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "from_nodes" {
  for_each                     = toset(var.allowed_security_group_ids)
  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = each.value
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
  description                  = "Redis from HyperPod node security group."
  tags                         = merge(var.tags, { Name = "${var.name_prefix}-kv-l2-redis-sg" })
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = "${var.name_prefix}-kv-l2-redis"
  description          = "HyperPod inference L2 KV cache (LMCache remote backend)."

  engine             = "redis"
  node_type          = var.node_type
  port               = 6379
  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.this.id]

  num_cache_clusters         = 1
  automatic_failover_enabled = false
  multi_az_enabled           = false

  # KV-cache bytes only; LRU-evict under memory pressure rather than OOM.
  parameter_group_name = "default.redis7"

  # checkov:skip=CKV_AWS_30: In-transit encryption is unsupported here -- the HyperPod inference operator
  #   only accepts redis/redis-sentinel/valkey schemes for l2CacheLocalUrl (rejects rediss) and offers no
  #   TLS toggle, so a transit-encrypted group breaks deployment-spec generation. Mitigated at the network
  #   layer: in-VPC only, SG restricted to the HyperPod node security groups. See the header comment.
  # checkov:skip=CKV_AWS_31: Same operator limitation -- no AUTH token can be supplied because the plaintext
  #   redis:// URL the operator requires cannot carry credentials the client would use over TLS.
  at_rest_encryption_enabled = true
  kms_key_id                 = aws_kms_key.this.arn
  transit_encryption_enabled = false
  apply_immediately          = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-kv-l2-redis" })
}
