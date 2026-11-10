# Managing models (add / update / remove)

This project serves one or more LLMs on SageMaker HyperPod (EKS) in **each region**, behind a single central
LiteLLM proxy. The set of models is **declarative**: you edit the catalog, run Terraform, and the stack
creates everything needed to ingest, serve, autoscale, intelligently route, and expose each model.

Because the design is multi-region with a central gateway, the catalog lives in **two places that must stay
identical**:

- Each region's var file (`environments/region/<region>.tfvars`) — the full catalog that drives ingestion +
  serving in that region.
- The platform root (`environments/platform/terraform.tfvars`) — only `served_model_name` + `litellm_alias`
  per key, so the central LiteLLM can register one deployment per region under each alias.

---

## 1. The catalog is the single source of truth (keep it identical per region)

The per-region type is declared in `environments/region/variables.tf`. Each entry fans out to **three**
things:

| Entry produces | Resource | Where |
|---|---|---|
| Weight ingestion (non-JumpStart only) | a `batch/v1` Job that stages weights into **that region's** S3 bucket | `modules/model-ingestion` (via `environments/region`) |
| Serving endpoint | an `InferenceEndpointConfig` CR the HyperPod operator reconciles into a vLLM Deployment + managed router | `modules/inference-endpoints` (via `environments/region`) |
| Per-model internal ALB | an Ingress fronting the model's routing-service (`http://<alb>/v1`) for the central LiteLLM to reach | `modules/regional-stack` (via `environments/region`) |

The central LiteLLM `model_list` entries (one deployment per region, keyed by `litellm_alias`) are built in
`environments/platform` from the discovered per-region model ALBs.

### Field schema (per-region var file)

```hcl
my-model-key = {                                   # map key: free-form id, used in resource names
  source_type       = "huggingface"               # "jumpstart" | "huggingface" | "s3"
  model_id          = "Org/Model-Name"             # HF repo id (huggingface) or JumpStart id
  s3_uri            = null                          # s3://... (only for source_type = "s3")
  served_model_name = "my-model"                   # vLLM --served-model-name; LiteLLM forwards as openai/<name>
  litellm_alias     = "my-model"                   # the name clients send to LiteLLM
  instance_types    = ["ml.g5.4xlarge", "ml.g5.8xlarge"]  # ordered; replicas spread across these
  instance_type     = "ml.g5.4xlarge"             # fallback when instance_types is unset
  tensor_parallel_size = 1                          # GPUs per pod (>1 shards the model)
  routing_strategy  = "prefixaware"                # prefixaware|session|roundrobin keep the chat API; kvaware needs /completions
  max_model_len     = 8192                          # cap context to fit the KV cache on the GPU
  autoscaling = {                                   # optional; needs observability (AMP) enabled
    min_replicas     = 1
    max_replicas     = 2
    prometheus_query = "sum(vllm:num_requests_waiting)"
    target_value     = 10
  }
}
```

The platform root's `models` entry for the same key is just:

```hcl
my-model-key = {
  served_model_name = "my-model"
  litellm_alias     = "my-model"
}
```

---

## 2. Add a model

1. **Edit every region var file** (`environments/region/us-east-1.tfvars`, `us-east-2.tfvars`, ...) — add the
   same entry to each `models` map.
2. **Re-apply each region root** (per region, with its state key + var file):
   ```bash
   cd environments/region
   terraform init -reconfigure -backend-config=backend.hcl -backend-config="key=region-us-east-1/terraform.tfstate"
   terraform apply -var-file=us-east-1.tfvars
   # repeat for each region with its own key + var file
   ```
   Expect per region: `module.platform.kubectl_manifest.ingestion_job["<key>"]` (if non-JumpStart), the
   endpoint CR, and `kubernetes_ingress_v1.model["<key>"]` (the new model's internal ALB).
3. **Add the key to the platform catalog** (`environments/platform/terraform.tfvars`, `served_model_name` +
   `litellm_alias`) and **re-apply the platform root** — it discovers the new per-region model ALBs from SSM
   and registers one LiteLLM deployment per region under the alias.

Clients then call `"model": "my-model"`. There is no separate "download" step — `terraform apply` is the
trigger.

### What happens on a region apply
- The **ingestion Job** runs in namespace `model-ingestion` and `hf download` + `aws s3 sync`s the weights
  into **that region's** bucket. Each region ingests independently (no cross-region replication). JumpStart
  models skip this.
- The operator sees the new CR, issues a TLS cert, creates the **managed router** + the **vLLM Deployment**,
  and Karpenter provisions a GPU node from zero. The pod stages weights from the local S3 bucket and starts
  vLLM.
- A new per-model **internal ALB** is created and its DNS is published to the primary region's SSM.
- The `lmcache_serde` resource patches `LMCACHE_REMOTE_SERDE=naive` on the Deployment (see Gotcha G3).

---

## 3. Trigger / re-trigger ingestion

`terraform apply` creates the Job the first time. A Job is run-once; to re-download (failed run, or refreshed
weights), re-apply the relevant region root with a replace:

```bash
cd environments/region
terraform apply -var-file=us-east-1.tfvars \
  -replace='module.platform.kubectl_manifest.ingestion_job["<key>"]'
```

Watch it:
```bash
kubectl -n model-ingestion get jobs
kubectl -n model-ingestion logs -f job/<name_prefix>-<key>-model-ingestion
```

---

## 4. Validate

```bash
export PATH=/usr/local/bin:$PATH
# endpoint pod healthy (in the target region's cluster context)
kubectl -n default get deploy <name_prefix>-<key>
# serve through the managed intelligent router (in-cluster)
kubectl -n default run t --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  -sS -X POST \
  "http://<name_prefix>-<key>-<namespace>-routing-service.hyperpod-inference-system.svc.cluster.local:443/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"<served_model_name>","messages":[{"role":"user","content":"Say OK"}],"max_tokens":5}'
```

Through the central LiteLLM (needs a virtual key), clients call the `litellm_alias`. Confirm the alias has one
deployment per region: the platform output `deployment_summary` lists the regions each alias load-balances
across.

---

## 5. Remove a model

Delete the entry from every region var file and re-apply each region root (the operator removes the
Deployment/router/pods, the ingestion Job, and the per-model ALB; the GPU node drains to zero via Karpenter).
Then delete the key from the platform catalog and re-apply the platform root (drops the LiteLLM deployments).
Staged weights remain in each region's S3 bucket (delete manually if desired).

---

## 6. Troubleshooting

**G1. `served_model_name` vs `litellm_alias`.** vLLM serves `served_model_name`; LiteLLM exposes
`litellm_alias` and forwards as `openai/<served_model_name>`. A mismatch is a silent 404 at request time.
Clients always call `litellm_alias`.

**G2. `instance_types` must be a subset of the region's `gpu_instance_types`.** The operator pins the serving
pod to those types via nodeAffinity, so Karpenter can only place it on a listed type. Listing a type the
HyperPod group isn't allowed to launch leaves the pod `Pending` forever.

**G3. L2 Redis must be an in-cluster `.svc` DNS name — NOT a raw ElastiCache endpoint.** The operator
validates `kvCacheSpec.l2CacheSpec.l2CacheLocalUrl` and **rejects** any external host
(`"must be a cluster-local Service DNS name ending in .svc"`), failing with `DeploymentSetupFailed` and never
building the Deployment. This project fronts the dedicated ElastiCache (`modules/kv-cache-redis`) with a
Kubernetes **ExternalName Service** (`kv-l2-redis.<ns>.svc.cluster.local` → CNAME → ElastiCache) and points
the CR at that `.svc` name (`modules/inference-endpoints/main.tf`, `kubectl_manifest.l2_redis_alias`). All
models in a namespace share that one alias.

**G4. The `naive` serde patch forces a SECOND cold start per model.** The operator injects
`LMCACHE_REMOTE_SERDE=cachegen`, which is broken for remote Redis (LMCache #2787 — every remote put fails, L2
stays empty). `kvCacheSpec` has no serde field, so `terraform_data.lmcache_serde` patches the Deployment env
to `naive` *after* the operator builds it — which triggers a rolling update (a second pod cold start). On a
fresh node the vLLM image pull alone is ~7 min, so the provisioner's `rollout status --timeout=900s` can time
out and the apply reports an error **even though the model converges fine**. If that happens, re-run.
`terraform apply` once the pod is Ready; it reconciles cleanly.

**G5. Terraform's local-exec uses bare `kubectl`/`aws` from `PATH`.** If a broken shim precedes the real
binary (e.g. Rancher Desktop's `~/.rd/bin/kubectl`), the serde provisioner's wait-loop silently fails for its
full 600s then errors. Always run Terraform with `PATH=/usr/local/bin:$PATH`. 

**G6. GPU "for cluster usage" quota is shared across ALL models' replicas, per region.** Each serving pod is
one whole GPU = one node. With two models at `min_replicas = 1` you hold two nodes at idle in that region;
during a rolling update the surge needs a temporary extra node. Keep the **sum** of `max_replicas` across
models within the `ml.g5.*xlarge for cluster usage` quota **in each region**, or scale-ups/rollouts will get
stuck `Pending`.

**G7. Ingestion is asynchronous.** `apply` creates the Job and returns; the download runs in-cluster. The
serving pod waits ~300s for the model mount, so a large model can time out the first pod attempt while the
sync is still running — let the Job finish and the pod recovers.

**G8. HF gating.** Gated repos (many Llama/Mistral releases) need the HF token *and* accepted terms on your
HF account, or `hf download` 401s. Ungated AWQ repos avoid this.

**G9. Memory sizing by quantization.** Same parameter count, very different footprint: a 7B AWQ (~5 GB) fits
an A10G easily; 7B FP16 (~15 GB) needs more headroom — tune `gpu-memory-utilization` / `max_model_len` /
instance type accordingly.

**G10. `routing_strategy` ↔ API shape.** `prefixaware`/`session`/`roundrobin` keep the OpenAI
`/v1/chat/completions` API. `kvaware` requires the `/completions` API (the module switches
`invocationEndpoint` automatically, and you must set the matching LiteLLM provider prefix).

**G11. Always `plan` before applying to a live stack.** If live state has drifted, a plan can surface
unrelated changes (or destroys). Read every create/replace/destroy line; use `-target`/`-replace` to scope
changes to just your model when needed.

---

## 7. Multi-region note

Regions are **independent**: each region ingests its own weights into its own S3 bucket (there is no
cross-region replication) and exposes each model on its own internal ALB. Keep the `models` catalog identical
across every region var file so each region serves the same aliases and the central LiteLLM can register one
deployment per region under each alias. The `kv-cache-redis` ElastiCache + ExternalName pattern (G3) applies
per region.
