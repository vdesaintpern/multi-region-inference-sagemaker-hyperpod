variable "name_prefix" {
  description = "Prefix applied to all resource names and tags."
  type        = string
}

variable "vpc_id" {
  description = "VPC the jumpbox is launched into."
  type        = string
}

variable "subnet_id" {
  description = "PRIVATE subnet for the jumpbox. Must have outbound reachability to the SSM service (NAT gateway or SSM/EC2messages/SSMmessages VPC endpoints) so the SSM agent can register."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type. A nano/micro is plenty for an SSM tunnel host."
  type        = string
  default     = "t3.micro"
}

variable "ami_ssm_parameter" {
  description = "SSM public parameter resolving to the AMI id. Default is the latest Amazon Linux 2023 x86_64 (SSM agent preinstalled)."
  type        = string
  default     = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
