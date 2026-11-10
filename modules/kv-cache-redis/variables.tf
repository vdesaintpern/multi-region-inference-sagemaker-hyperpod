variable "name_prefix" {
  description = "Prefix applied to resource names."
  type        = string
}

variable "vpc_id" {
  description = "VPC the Redis cluster is created in."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for the ElastiCache subnet group."
  type        = list(string)
}

variable "allowed_security_group_ids" {
  description = "Security groups allowed to reach Redis on 6379 (the HyperPod node security groups)."
  type        = list(string)
}

variable "node_type" {
  description = "ElastiCache node type for the L2 KV cache."
  type        = string
  default     = "cache.t4g.medium"
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
