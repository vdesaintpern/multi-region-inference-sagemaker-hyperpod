variable "region" {
  description = "AWS region (same region as the stack you want to tunnel into)."
  type        = string
}

variable "name_prefix" {
  description = "Prefix applied to all resource names and tags."
  type        = string
}

variable "vpc_id" {
  description = "VPC to launch the jumpbox into."
  type        = string
}

variable "subnet_id" {
  description = "PRIVATE subnet for the jumpbox (must reach SSM via NAT or SSM VPC endpoints)."
  type        = string
}

variable "instance_type" {
  description = "Jumpbox instance type."
  type        = string
  default     = "t3.micro"
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
