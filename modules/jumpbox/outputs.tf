output "instance_id" {
  description = "EC2 instance id of the jumpbox (the SSM --target)."
  value       = aws_instance.this.id
}

output "security_group_id" {
  description = "Security group id of the jumpbox (reference it from a target SG if the target restricts inbound by SG)."
  value       = aws_security_group.this.id
}

output "private_ip" {
  description = "Private IP of the jumpbox."
  value       = aws_instance.this.private_ip
}

output "availability_zone" {
  description = "AZ the jumpbox landed in."
  value       = aws_instance.this.availability_zone
}
