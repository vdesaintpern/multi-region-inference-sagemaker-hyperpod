variable "name_prefix" {
  description = "Prefix applied to all resource names and tags."
  type        = string
}

variable "tags" {
  description = "Common tags applied to every resource."
  type        = map(string)
  default     = {}
}

variable "hyperpod_cli_ref" {
  description = "Git tag/ref of aws/sagemaker-hyperpod-cli to clone for the HyperPod dependency Helm chart. Pinned to a release tag so the dependency set is reproducible; bump deliberately after validating the new chart."
  type        = string
  default     = "v3.13.0"
}

variable "vpc_id" {
  description = "VPC in which to create the EKS + HyperPod cluster."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs (>= 2 AZs) for the EKS control plane, nodes, and HyperPod."
  type        = list(string)
}

variable "gpu_subnet_id" {
  description = "Single private subnet for the HyperPod GPU instance group (EFA cannot cross AZs)."
  type        = string
}

variable "kubernetes_version" {
  description = "EKS control plane version."
  type        = string
  default     = "1.31"
}

variable "system_node_instance_type" {
  description = "EC2 instance type for the EKS managed node group (CPU/system + bootstrap tier: controllers, deps chart, CoreDNS, LiteLLM)."
  type        = string
  default     = "m5.xlarge"
}

variable "system_node_desired_size" {
  description = "Desired size of the system managed node group (>= 2 recommended to host controllers + LiteLLM replicas)."
  type        = number
  default     = 2
}

variable "system_node_disk_gb" {
  description = "Root EBS volume (GiB) for the system node group. The GPU nodes are tainted, so CPU pods (incl. the HyperPod Intelligent Router, a multi-GB vLLM-based image) land here; the default 20Gi fills up and triggers disk-pressure eviction loops, so size it generously."
  type        = number
  default     = 100
}

variable "gpu_instance_type" {
  description = "SageMaker HyperPod GPU instance type for inference (e.g. ml.g5.2xlarge). Retained for reference; the instance group uses gpu_instance_types (flexible) for capacity fallback."
  type        = string
  default     = "ml.g5.2xlarge"
}

variable "gpu_instance_types" {
  description = "Ordered list of GPU instance types for the FLEXIBLE HyperPod instance group. Karpenter provisions the type the model pod pins, from this set. All should fit the model (single A10G here)."
  type        = list(string)
  # g5.xlarge first: it has by far the deepest on-demand pool (verified via Baywatch). g5.8xlarge is
  # deliberately excluded -- it has ~zero on-demand capacity in every region checked. The model's
  # instance_type MUST be one of these (the operator hard-pins the serving pod to that single type).
  default = ["ml.g5.xlarge", "ml.g5.2xlarge", "ml.g5.4xlarge"]
}

variable "gpu_instance_count" {
  description = "Warm baseline count of GPU nodes in the HyperPod instance group (>= 1 keeps the endpoint ready)."
  type        = number
  default     = 1
}

variable "cluster_admin_principal_arns" {
  description = "IAM principal ARNs granted cluster-admin via EKS access entries (e.g. the operator's role)."
  type        = list(string)
  default     = []
}
