# Standalone root for the reusable SSM jumpbox. Deliberately NOT wired into the regional stack:
# init with its own backend key and apply/destroy on demand.
#
#   terraform init -backend-config=backend.hcl
#   terraform apply
#   terraform destroy   # when you are done tunneling

module "jumpbox" {
  source = "../../modules/jumpbox"

  name_prefix   = var.name_prefix
  vpc_id        = var.vpc_id
  subnet_id     = var.subnet_id
  instance_type = var.instance_type
  tags          = var.tags
}

output "instance_id" {
  description = "SSM --target for start-session."
  value       = module.jumpbox.instance_id
}

output "security_group_id" {
  value = module.jumpbox.security_group_id
}

output "private_ip" {
  value = module.jumpbox.private_ip
}
