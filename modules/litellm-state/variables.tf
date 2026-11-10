variable "name_prefix" {
  description = "Prefix applied to all resource names and tags (e.g. sample-litellm-use1)."
  type        = string
}

variable "tags" {
  description = "Common tags applied to every resource."
  type        = map(string)
  default     = {}
}

variable "vpc_id" {
  description = "VPC ID that hosts the Aurora and ElastiCache resources."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs (>= 2 AZs) for the Aurora DB subnet group and the ElastiCache subnet group. No public access."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "private_subnet_ids must contain at least two subnets in different AZs."
  }
}

variable "allowed_security_group_ids" {
  description = "Source security group IDs allowed to reach Aurora (5432) and Redis (6379), e.g. the LiteLLM pods' security group."
  type        = list(string)
  default     = []
}

variable "allowed_cidr_blocks" {
  description = "Source CIDR blocks allowed to reach Aurora (5432) and Redis (6379), e.g. the VPC CIDR. Never 0.0.0.0/0."
  type        = list(string)
  default     = []
}

variable "db_name" {
  description = "Initial database name created on the Aurora cluster (LiteLLM's schema)."
  type        = string
  default     = "litellm"
}

variable "master_username" {
  description = "Aurora master username created on the cluster."
  type        = string
  default     = "litellm_admin"
}

variable "engine_version" {
  description = "Aurora PostgreSQL engine version (Serverless v2). Verify with: aws rds describe-db-engine-versions --engine aurora-postgresql."
  type        = string
  default     = "16.8"
}

variable "deletion_protection" {
  description = "Enable deletion protection on the Aurora cluster. Default false so the sample can be torn down."
  type        = bool
  default     = false
}

variable "backup_retention_period" {
  description = "Number of days to retain automated Aurora backups (>= 7)."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_period >= 7
    error_message = "backup_retention_period must be >= 7 days."
  }
}

variable "serverless_min_capacity" {
  description = "Aurora Serverless v2 minimum capacity in ACUs."
  type        = number
  default     = 0.5
}

variable "serverless_max_capacity" {
  description = "Aurora Serverless v2 maximum capacity in ACUs."
  type        = number
  default     = 4
}

variable "redis_node_type" {
  description = "ElastiCache node type for the Redis replication group."
  type        = string
  default     = "cache.t4g.micro"
}

variable "redis_automatic_failover" {
  description = "Enable automatic failover for the Redis replication group. When true, at least two nodes are provisioned."
  type        = bool
  default     = false
}
