variable "name_prefix" {
  description = "Prefix applied to CR names."
  type        = string
}

variable "gpu_instance_group_name" {
  description = "Name of the HyperPod GPU instance group the GPU NodePool references."
  type        = string
  default     = "gpu"
}

variable "gpu_instance_type" {
  description = "GPU instance type Karpenter provisions for the inference NodePool."
  type        = string
  default     = "ml.g5.2xlarge"
}

variable "gpu_node_limit" {
  description = "Max GPUs Karpenter may provision in the GPU NodePool (bounded by SageMaker cluster-usage quota). Must be >= a model's autoscaling max_replicas or replica scale-out is blocked at the NodePool. NOTE: physically adding nodes beyond the warm baseline also requires the HyperPod group's gpu_instance_count."
  type        = number
  default     = 3
}

variable "system_instance_types" {
  description = "Instance types for the system/CPU NodePool (LiteLLM + controllers)."
  type        = list(string)
  default     = ["m5.large", "m5.xlarge"]
}

variable "system_node_limit" {
  description = "Max CPU nodes Karpenter may provision for the system NodePool."
  type        = number
  default     = 5
}
