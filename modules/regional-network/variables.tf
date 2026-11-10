variable "name_prefix" {
  description = "Prefix applied to all resource names and tags (e.g. sample-hpinf-use1)."
  type        = string
}

variable "create_vpc" {
  description = "If true, create a new VPC. If false, bring your own via byo_* inputs."
  type        = bool
  default     = true
}

variable "vpc_cidr" {
  description = "IPv4 CIDR for the created VPC. Ignored when create_vpc = false."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of Availability Zones to spread subnets across. EKS and the internal ALB require >= 2."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2
    error_message = "az_count must be >= 2 (EKS control plane and the internal ALB both require at least two AZs)."
  }
}

# ------- Bring-your-own-VPC inputs (used only when create_vpc = false) -------

variable "byo_vpc_id" {
  description = "Existing VPC ID to use when create_vpc = false."
  type        = string
  default     = null
}

variable "byo_private_subnet_ids" {
  description = "Existing private subnet IDs (>= 2 AZs) when create_vpc = false. Workloads, ALB, and HyperPod run here."
  type        = list(string)
  default     = []
}

variable "byo_public_subnet_ids" {
  description = "Existing public subnet IDs (for NAT / egress) when create_vpc = false. May be empty if egress is handled elsewhere."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Common tags applied to every resource."
  type        = map(string)
  default     = {}
}
