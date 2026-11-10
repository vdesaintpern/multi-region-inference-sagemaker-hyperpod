variable "name_prefix" {
  description = "Prefix applied to resource names and tags."
  type        = string
}

variable "tags" {
  description = "Common tags applied to every resource."
  type        = map(string)
  default     = {}
}

# ------- Requester side: the PRIMARY region's VPC (where the central LiteLLM runs) -------

variable "requester_vpc_id" {
  description = "Primary (requester) VPC id."
  type        = string
}

variable "requester_cidr" {
  description = "Primary (requester) VPC CIDR. The peer region routes this CIDR back through the peering connection."
  type        = string
}

variable "requester_route_table_ids" {
  description = "Primary VPC private route table ids that need a route to the peer CIDR."
  type        = list(string)
}

# ------- Accepter side: the REMOTE region's VPC (a HyperPod serving cluster) -------

variable "peer_vpc_id" {
  description = "Remote (accepter) VPC id."
  type        = string
}

variable "peer_region" {
  description = "Remote (accepter) region (e.g. us-east-2)."
  type        = string
}

variable "peer_cidr" {
  description = "Remote (accepter) VPC CIDR. The primary routes this CIDR through the peering connection."
  type        = string
}

variable "peer_route_table_ids" {
  description = "Remote VPC private route table ids that need a route back to the primary CIDR."
  type        = list(string)
}
