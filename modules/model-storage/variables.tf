variable "name_prefix" {
  description = "Prefix applied to all resource names and tags (e.g. sample-hpinf-use1)."
  type        = string
}

variable "tags" {
  description = "Common tags applied to every resource."
  type        = map(string)
  default     = {}
}
