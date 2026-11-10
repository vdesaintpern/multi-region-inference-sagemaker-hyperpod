# InferenceEndpointConfig custom resources — one per entry in var.models.
#
# The HyperPod Inference Operator watches these CRs and, for each, downloads the model, launches the
# vLLM container on a GPU node, and (when enable_intelligent_routing) stands up the managed Intelligent
# Router (prefix/KV-aware) plus a tiered KV cache (L1 CPU + optional L2 Redis). LiteLLM points at the
# resulting in-cluster router endpoint (see outputs.tf).
#
# Applied with kubectl_manifest (NOT kubernetes_manifest) so the manifest composes with the operator
# add-on install in a single apply without a plan-time CRD lookup.
#
# VERIFY: the apiVersion/kind and the spec schema of InferenceEndpointConfig depend on the installed
# operator version. Confirm every field below against your operator release and the docs:
# https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod-model-deployment-caching-routing.html
# Fields most likely to differ: modelSourceConfig shape, worker.image, invocationEndpoint,
# inferenceGateway/tieredKVCache keys, and how vLLM args are passed.

variable "worker_image" {
  description = "Native vLLM inference container image (HyperPod DLC). Exposes vLLM Prometheus metrics (vllm:*) at :8080/metrics, which the observability add-on scrapes into AMP for KEDA autoscaling."
  type        = string
  default     = "public.ecr.aws/deep-learning-containers/vllm:server-hyperpod-cuda-v1.1"
}

locals {
  models_manifests = {
    for key, m in var.models : key => {
      # Use v1 (stable storage version). It supports instanceTypes (ordered list) and does not require
      # the single instanceType; v1alpha1 lacks instanceTypes and requires instanceType.
      apiVersion = "inference.sagemaker.aws.amazon.com/v1"
      kind       = "InferenceEndpointConfig"
      metadata = {
        name      = "${var.name_prefix}-${key}"
        namespace = var.namespace
      }
      # Optional nested blocks use `cond ? {...} : null` (type-consistent) rather than object-vs-{}
      # ternaries, which Terraform cannot unify. yamlencode emits absent optionals as null.
      spec = {
        modelName    = m.served_model_name
        endpointName = "${var.name_prefix}-${key}"
        # instanceType (single) and instanceTypes (ordered list) are mutually exclusive. When a list is
        # given, the operator deploys on the first AVAILABLE type -- so replicas spread across types,
        # which is how you scale past a per-type "for cluster usage" quota of 1. Exactly one is non-null;
        # yamlencode emits the other as null (treated as unset).
        instanceType  = try(length(m.instance_types), 0) > 0 ? null : m.instance_type
        instanceTypes = try(length(m.instance_types), 0) > 0 ? m.instance_types : null
        # The `kvaware` intelligent-routing strategy ONLY supports the /completions API; it rejects
        # /v1/chat/completions (AWS docs). All other strategies (prefixaware/session/roundrobin) and the
        # plain gateway work with the chat API, so default to chat and switch only for kvaware. Keep
        # LiteLLM's model prefix in sync (text-completion-openai) when using kvaware.
        invocationEndpoint = m.routing_strategy == "kvaware" ? "v1/completions" : "v1/chat/completions"

        # vLLM's health endpoint is /health (NOT /ping, which is the DJL-LMI contract).
        loadBalancer = {
          healthCheckPath  = "/health"
          routingAlgorithm = "least_outstanding_requests"
        }

        # Point the operator's OpenTelemetry sidecar at vLLM's Prometheus endpoint (defaults, set
        # explicitly). This is what makes vllm:num_requests_waiting / kv_cache_usage_perc /
        # prefix_cache_* flow into AMP so the KEDA prometheusTrigger below can read them.
        metrics = {
          enabled      = true
          modelMetrics = { port = 8080, path = "/metrics" }
        }

        # Model source: JumpStart id, or S3 (used for huggingface-staged and custom weights).
        modelSourceConfig = {
          modelSourceType = m.source_type == "jumpstart" ? "jumpstart" : "s3"
          jumpStartConfig = m.source_type == "jumpstart" ? { modelId = m.model_id } : null
          s3Storage = m.source_type == "jumpstart" ? null : {
            bucketName = var.s3_bucket_name
            region     = var.s3_bucket_region
          }
          modelLocation = m.source_type == "jumpstart" ? null : coalesce(m.s3_uri, "models/${coalesce(m.model_id, m.served_model_name)}")
        }

        worker = {
          image = var.worker_image
          # The image ENTRYPOINT is `python3 -m vllm.entrypoints.openai.api_server "$@"`. We override
          # with a wrapper that (1) waits for the S3-CSI model mount, (2) stages the weights to a plain
          # local dir, then (3) launches vLLM with --model. Two image-specific reasons:
          #   - The operator mounts the model via mountpoint-s3 + kubelet subPath; copying to a local
          #     dir avoids FUSE stat quirks during vLLM startup.
          #   - This build ignores the positional model_tag (would load its default model from HF and
          #     fail offline), so the model MUST be passed via --model.
          # command runs `bash -lc "<script>" hpvllm`. When intelligentRoutingSpec/kvCacheSpec are set,
          # the operator APPENDS vLLM flags (e.g. `--kv-transfer-config '{...LMCacheConnectorV1...}'`) to
          # the container args. Under `bash -c cmd name arg...` those land in $1+, so the script's
          # `exec ... "$@"` forwards them to vLLM. The trailing "hpvllm" is the $0 placeholder; WITHOUT it
          # (and the "$@" below) the operator-injected LMCache connector flag is silently dropped and
          # LMCache never initializes (no error, L2 cache stays empty). See LESSONS-LEARNED (2026-10-06).
          command = ["/bin/bash", "-lc"]
          args = [
            <<-SCRIPT
            set -e
            echo "waiting for model mount (config.json) ..."
            for i in $(seq 1 100); do [ -f /opt/ml/model/config.json ] && break; sleep 3; done
            [ -f /opt/ml/model/config.json ] || { echo "ERROR: model mount never appeared"; exit 1; }
            echo "staging model to /model-local ..."
            mkdir -p /model-local && cp -r /opt/ml/model/. /model-local/ && sync
            echo "launching vLLM"
            exec python3 -m vllm.entrypoints.openai.api_server ${join(" ", concat(
            [
              "--model", "/model-local",
              "--served-model-name", m.served_model_name,
              "--host", "0.0.0.0", "--port", "8080",
              "--tensor-parallel-size", tostring(m.tensor_parallel_size),
              "--gpu-memory-utilization", "0.90",
            ],
            m.max_model_len == null ? [] : ["--max-model-len", tostring(m.max_model_len)],
      ))} "$@"
            SCRIPT
      ,
      "hpvllm",
    ]
    # vLLM reads the staged local model; keep it fully offline so it never reaches out to HF.
    environmentVariables = [
      { name = "HF_HUB_OFFLINE", value = "1" },
      { name = "TRANSFORMERS_OFFLINE", value = "1" },
    ]
    modelInvocationPort = {
      containerPort = 8080
    }
    modelVolumeMount = {
      name      = "model-weights"
      mountPath = "/opt/ml/model"
    }
    resources = {
      limits = {
        "nvidia.com/gpu" = m.tensor_parallel_size
      }
      requests = {
        "nvidia.com/gpu" = m.tensor_parallel_size
      }
    }
  }

  # Managed Intelligent Router (intelligentRoutingSpec) vs the plain Inference Gateway
  # (inferenceGateway) are MUTUALLY EXCLUSIVE -- the CRD enforces a CEL rule that both .enabled flags
  # cannot be set together. When enable_intelligent_routing is true we render intelligentRoutingSpec
  # with the model's routing_strategy (prefixaware keeps the OpenAI chat API; kvaware needs
  # /completions, handled by invocationEndpoint above) and force inferenceGateway to null.
  intelligentRoutingSpec = var.enable_intelligent_routing ? {
    enabled         = true
    routingStrategy = m.routing_strategy
  } : null

  inferenceGateway = (!var.enable_intelligent_routing && var.enable_inference_gateway) ? {
    enabled = true
  } : null

  # Tiered KV cache: L1 = node CPU memory; L2 = a shared Redis so KV blocks survive a replica loss and
  # can be reused across replicas. Rendered when intelligent routing is on; L2 enabled only when
  # enable_l2_cache is set. TWO operator constraints shape this:
  #   1. l2CacheLocalUrl MUST be a cluster-local Service DNS name ending in .svc -- the operator REJECTS a
  #      raw ElastiCache hostname ("must be a cluster-local Service DNS name ending in .svc"). So we point
  #      the CR at an in-cluster ExternalName Service (kubectl_manifest.l2_redis_alias below) whose .svc DNS
  #      CNAMEs to the ElastiCache endpoint. See LESSONS-LEARNED (2026-10-07).
  #   2. The operator injects LMCACHE_REMOTE_SERDE=cachegen, which is broken for remote backends (LMCache
  #      issue #2787 -> every remote put fails, L2 stays empty). kvCacheSpec exposes no serde field, so
  #      terraform_data.lmcache_serde (below) patches the Deployment env to naive. See LESSONS-LEARNED (2026-10-06).
  kvCacheSpec = var.enable_intelligent_routing ? {
    enableL1Cache = true
    enableL2Cache = var.enable_l2_cache
    # Plain redis:// to the in-cluster .svc alias (operator constraint #1). The operator accepts only
    # redis/redis-sentinel/valkey schemes and exposes no TLS toggle, so transit encryption is not used
    # on this cache (see modules/kv-cache-redis header); it is network-locked instead.
    l2CacheSpec = !var.enable_l2_cache ? null : {
      l2CacheBackend  = "redis"
      l2CacheLocalUrl = "redis://${var.l2_cache_service_name}.${var.namespace}.svc.cluster.local:${var.l2_cache_redis_port}"
    }
  } : null

  # Replica autoscaling. The operator turns this into a KEDA ScaledObject (-> HPA). Rendered
  # only when the model declares autoscaling AND an AMP endpoint is available to query. One
  # serving pod pins the whole GPU, so each extra replica is an extra GPU node that Karpenter
  # provisions -- keep maxReplicaCount within the instance type's cluster-usage quota.
  autoScalingSpec = (m.autoscaling == null || var.amp_server_address == null) ? null : {
    minReplicaCount = m.autoscaling.min_replicas
    maxReplicaCount = m.autoscaling.max_replicas
    prometheusTrigger = {
      serverAddress = var.amp_server_address
      query         = m.autoscaling.prometheus_query
      targetValue   = m.autoscaling.target_value
      metricType    = "Average"
    }
  }
}
}
}
}

resource "kubectl_manifest" "endpoint" {
  for_each  = local.models_manifests
  yaml_body = yamlencode(each.value)

  # The L2 cache alias Service must exist so the operator-built worker can resolve the .svc DNS to
  # ElastiCache. Create it first when L2 is enabled.
  depends_on = [kubectl_manifest.l2_redis_alias]
}

# ExternalName Service that gives the ElastiCache L2 endpoint an in-cluster .svc DNS name, because the
# operator rejects a raw external host in l2CacheLocalUrl (see kvCacheSpec comment / LESSONS-LEARNED
# 2026-10-07). DNS "<l2_cache_service_name>.<namespace>.svc.cluster.local" CNAMEs to l2_cache_redis_host;
# the redis client (LMCache) then connects to ElastiCache. count gates on the plan-time-known
# enable_l2_cache (NOT l2_cache_redis_host, which is known only after the ElastiCache is created).
resource "kubectl_manifest" "l2_redis_alias" {
  count = var.enable_l2_cache ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = var.l2_cache_service_name
      namespace = var.namespace
    }
    spec = {
      type         = "ExternalName"
      externalName = var.l2_cache_redis_host
    }
  })
}

# Durable fix for the LMCache cachegen remote-serde bug (LMCache issue #2787): the operator injects
# LMCACHE_REMOTE_SERDE=cachegen, which fails every remote (Redis) put so the L2 cache stays empty.
# kvCacheSpec has no serde field, and worker.environmentVariables cannot override it (the operator
# appends its LMCACHE_* env AFTER the worker env, and for duplicate keys the last one wins). So we patch
# the operator-rendered Deployment in place after it exists, setting LMCACHE_REMOTE_SERDE=naive. Only
# needed when L2 (remote Redis) is enabled. Requires kubectl + aws CLI on the apply host (same
# prerequisite as terraform_data.hyperpod_deps). Verified fix: Redis then populates with zero put errors.
resource "terraform_data" "lmcache_serde" {
  for_each = {
    for key, m in var.models : key => m
    if var.enable_intelligent_routing && var.enable_l2_cache
  }

  # Re-run whenever the endpoint manifest changes: a CR recreate rebuilds the Deployment with cachegen.
  triggers_replace = [kubectl_manifest.endpoint[each.key].yaml_body]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      aws eks update-kubeconfig --name "${var.cluster_name}" --region "${var.region}"
      dep="${var.name_prefix}-${each.key}"
      echo "waiting for operator to create Deployment $dep ..."
      for i in $(seq 1 120); do kubectl -n "${var.namespace}" get deploy "$dep" >/dev/null 2>&1 && break; sleep 5; done
      # Container name == Deployment name (endpointName). Override the operator-injected serde in place.
      kubectl -n "${var.namespace}" set env "deploy/$dep" -c "$dep" LMCACHE_REMOTE_SERDE=naive
      kubectl -n "${var.namespace}" rollout status "deploy/$dep" --timeout=900s
    EOT
  }

  depends_on = [kubectl_manifest.endpoint]
}
