# In-cluster endpoint URLs the LiteLLM proxy targets, one per model. Plaintext HTTP on port 443.
# LiteLLM (openai provider) appends "/chat/completions" to api_base, so the base ends in "/v1".
#
# Two different fronting Services depending on routing mode:
#   - Intelligent routing ON: the managed Intelligent Router owns a Service
#     "<endpoint-name>-<namespace>-routing-service" in the OPERATOR namespace (hyperpod-inference-system).
#     Traffic MUST go here to be prefix/KV-aware routed. (The plain "<endpoint-name>-routing-service" in
#     the model namespace is an L4 ClusterIP straight to the pods and BYPASSES the router.)
#   - Intelligent routing OFF: the operator fronts the endpoint with "<endpoint-name>-routing-service"
#     in the model namespace.
output "endpoint_urls" {
  description = "Map of model key -> in-cluster OpenAI-compatible base URL for LiteLLM to target."
  value = {
    for key, m in var.models :
    key => var.enable_intelligent_routing ? "http://${var.name_prefix}-${key}-${var.namespace}-routing-service.hyperpod-inference-system.svc.cluster.local:443/v1" : "http://${var.name_prefix}-${key}-routing-service.${var.namespace}.svc.cluster.local:443/v1"
  }
}

output "endpoint_names" {
  description = "Map of model key -> InferenceEndpointConfig name."
  value       = { for key, m in var.models : key => "${var.name_prefix}-${key}" }
}
