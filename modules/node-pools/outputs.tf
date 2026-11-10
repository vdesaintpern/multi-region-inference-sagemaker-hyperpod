output "gpu_nodepool_name" {
  description = "Name of the GPU Karpenter NodePool."
  value       = "${var.name_prefix}-gpu"
}

output "system_nodepool_name" {
  description = "Name of the system/CPU Karpenter NodePool."
  value       = "${var.name_prefix}-system"
}
