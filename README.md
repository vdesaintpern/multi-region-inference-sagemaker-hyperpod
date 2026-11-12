# Serve open-weight LLMs across multiple AWS Regions with Amazon SageMaker HyperPod 

Terraform sample accompanying the blog post of the same name. It deploys a multi-region inference platform
on Amazon SageMaker HyperPod, fronted by a single **central LiteLLM** model gateway that load-balances each
model across **one HyperPod cluster per region**. HyperPod is kept fully private; the entry point is a private
internal ALB (public exposure is left to the reader).

The gateway routing is **affinity-first**: LiteLLM **session affinity** pins each conversation to the region
that served its first request (so that region's KV/prefix cache stays warm), and the routing strategy
(default `least-busy`) only places **new** sessions and spills them when a region is saturated or down. The
central LiteLLM reaches each region's models over **cross-region VPC peering** (a star: primary to each
region; regions never talk to each other).

> [!WARNING]
> **Sample / non-production code.** This project demonstrates a reference architecture. It is **not
> production-ready** and must not be deployed to production without additional security testing and
> hardening. Deploying it creates continuously-running GPU capacity that **incurs real cost** (see
> below).

## What it builds

- **Entry point** (primary region only): an **internal ALB** (`scheme=internal`, no public IP) created by a
  Kubernetes Ingress, fronting the central LiteLLM proxy. TLS is a reader-supplied **ACM** cert or a
  generated **self-signed** cert. A regional **AWS WAFv2** WebACL default-blocks, allows `/v1/*` across the
  private network, and allows all paths (incl. `/ui`) only from the primary VPC CIDR + any extra admin CIDRs.
  Everything is private; add public exposure yourself. Test with the built-in **SSM bastion**.
- **Central gateway**: one **LiteLLM** proxy (in-cluster on the primary EKS cluster) — OpenAI-compatible API,
  virtual keys, per-team budgets + cost tracking, rate limits. For each model it registers **one deployment
  per region**; session affinity + `routing_strategy` choose the region. State in a **single regional Aurora
  PostgreSQL** cluster + **ElastiCache Redis** (rate-limit counters and the session-affinity pins). This
  state Redis has in-transit encryption **required**, so LiteLLM must connect over TLS
  (`router_settings.cache_kwargs.ssl = true`); without it, affinity pins never persist and conversations
  bounce between regions.
- **Per-region serving**: each region runs its own EKS + SageMaker HyperPod cluster with the Inference
  Operator running **vLLM** and the managed Intelligent Router doing **prefix/KV-aware** routing within the
  region. Nodes come from HyperPod instance groups scaled by HyperPod-managed Karpenter.
- **Per-region model exposure**: each model is fronted by its own **internal ALB** (`scheme=internal`, path
  `/`), reachable from the primary over VPC peering. Each region **ingests its own weights** (no cross-region
  replication) and publishes its model ALB DNS + VPC details to the primary region's SSM for discovery.
- **Observability**: per-region Amazon Managed Prometheus (`enable_observability`). A central Amazon Managed
  Grafana is an **opt-in** add-on (`enable_grafana`, default off) — see [Observability](#observability) for
  the IAM Identity Center requirement and why it is off by default.

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the full diagram and request flow.

## Cost estimation

GPU nodes run 24/7 and each region adds one. Rough on-demand order-of-magnitude (verify current pricing):

| Item (per region) | Approx. |
|---|---|
| 1x `ml.g5.4xlarge` HyperPod GPU node (warm) | ~$2/hr |
| 1x `ml.m5.2xlarge` HyperPod system node | ~$0.5/hr |
| NAT gateways, AMP, misc | ~$0.3/hr |
| **Per region subtotal** | **~$2.5–3/hr** |
| Central (primary only): Aurora Serverless v2 + ElastiCache + entry ALB | ~$0.3–0.6/hr |
| **Two regions total** | **~$6–8/hr (~$150–190/day)** |

Cross-region VPC peering has no hourly charge — you pay only inter-region data transfer on spill traffic.
Tear it down when idle. For a cheaper trial, deploy just the primary region (set `regions = ["us-east-1"]`
in the platform root).

## Prerequisites

- Terraform >= 1.6, `kubectl`, `helm`, AWS CLI v2, `jq`.
- **GPU service quota** for `ml.g5.4xlarge for cluster usage` (NOT endpoint/training) >= 1 in **each**
  region. Check with `aws service-quotas list-service-quotas --service-code sagemaker` and raise via Service
  Quotas before applying. The default regions `us-east-1` + `us-east-2` are used as defaults.
- Credentials for the target account; confirm the account is non-production.
- No public hosted zone is required (the entry ALB is private). Supply your own ACM cert ARN if you do not
  want the generated self-signed cert.

### Deployer IAM policy

The principal that runs `terraform apply`/`destroy` for all three roots needs the permissions in
[`policy.json`](./policy.json) (repo root). It is least-privilege rather than `AdministratorAccess`:
scoped by service and action, with the IAM role, instance-profile and OIDC-provider write actions and
`iam:PassRole` restricted to the stack's own `sample-hpinf-*` roles and the stack's services, and the
S3 / Secrets Manager / DynamoDB statements scoped to the `sample-hpinf-*` name prefix. It was derived
from the AWS CloudTrail record of a full two-region deploy of this sample (plus the create/delete/tag
companions for every resource type the Terraform manages) and covers both apply and destroy. Attach it
to a dedicated deployment role/user.

> **`sample-hpinf-` is an example prefix.** It is the `name_prefix` applied to every S3 bucket, IAM
> role, DynamoDB table and Secrets Manager secret the stack creates, and is baked into the ARN patterns
> in `policy.json`. **Set your own unique `name_prefix` before deploying** (and update the `sample-hpinf-*`
> ARN prefixes and the KMS `aws:ResourceTag/Name` condition in `policy.json` to match) so that the bucket
> names this stack creates cannot be pre-registered under the predictable `sample-hpinf-*` pattern by
> another account.

Optional hardening for stricter environments: narrow the `sample-hpinf-*` ARNs to the exact resource
names your account uses, and attach a permissions boundary to the deployment role so roles it creates
cannot themselves be granted broader access.

## Structure

Two root types, applied per the order below:

- `environments/00-bootstrap` — one-time remote-state backend.
- `environments/region` — applied **once per region** (including the primary). Builds VPC + EKS/HyperPod +
  serving + per-model internal ALBs, and publishes discovery to the **primary** region's SSM under
  `/hpinf/regions/<region>/`. Uses a per-region var file (`us-east-1.tfvars`, `us-east-2.tfvars`) and a
  per-region state key.
- `environments/platform` — applied **once**, in the primary region, **after** all region roots. Reads
  `var.regions` + the SSM discovery + the primary region root's remote state, then builds the single
  Aurora + Redis, the central LiteLLM, the entry ALB + WAF + cert, the optional bastion, and the
  cross-region VPC peering.

## Apply order

```bash
# 0) One-time: create the remote-state backend, then wire it into the other roots (see 00-bootstrap/README.md).
cd environments/00-bootstrap && terraform init && terraform apply

# 1) Primary region (us-east-1). Per-region state key + var file.
cd ../region
terraform init -reconfigure -backend-config=backend.hcl -backend-config="key=region-us-east-1/terraform.tfstate"
# Bring up the network AND the cluster first (see providers.tf note), then the full apply.
terraform apply -target=module.network -target=module.cluster -var-file=us-east-1.tfvars
terraform apply -var-file=us-east-1.tfvars

# 2) Added region (us-east-2). Re-init with ITS state key, apply with ITS var file.
terraform init -reconfigure -backend-config=backend.hcl -backend-config="key=region-us-east-2/terraform.tfstate"
terraform apply -target=module.network -target=module.cluster -var-file=us-east-2.tfvars
terraform apply -var-file=us-east-2.tfvars

# 3) Platform (primary region). Auto-discovers every region from SSM; builds the central LiteLLM,
#    entry ALB, and the cross-region peering. Set state_bucket/state_region in terraform.tfvars first.
cd ../platform
terraform init -reconfigure -backend-config=backend.hcl -backend-config="key=platform/terraform.tfstate"
terraform apply
```

On a fresh cluster the `InferenceEndpointConfig` / node-pool CRs may need a second `terraform apply` of the
region root (the operator CRDs register during the same apply). On a fresh cluster, deploy the region root
with `enable_observability = false` first (so a GPU node comes up), then flip it to `true` and re-apply.

## Adding a model

The `models` catalog is the single source of truth and must be **identical** across every region var file and
the platform root (the platform only needs `served_model_name` + `litellm_alias` per key). Add the entry to
each region's var file and re-apply that region root, then add it to `environments/platform/terraform.tfvars`
and re-apply the platform root. See [`MODEL_MANAGEMENT.md`](MODEL_MANAGEMENT.md).

## Adding a region

There is one primary region and any number of added regions. To add one (e.g. `eu-west-1`):

1. **Deploy its region root.** Create `environments/region/eu-west-1.tfvars` from `us-east-2.tfvars`: set
   `region`, `name_prefix`, a **non-overlapping** `vpc_cidr` (e.g. `10.30.0.0/16`), `primary_region =
   "us-east-1"`, and `client_cidrs = ["10.10.0.0/16"]` (the primary VPC, so the central LiteLLM can reach its
   model ALBs over peering). Init with a unique state key (`region-eu-west-1/terraform.tfstate`) and apply.
   It publishes its discovery to the primary's SSM — no ARN pasting.
2. **Wire it into the platform root.** Append `"eu-west-1"` to `var.regions`; add an `aws` provider alias for
   it in `environments/platform/providers.tf`; copy the `module "peering_use2"` block in `main.tf` to a
   `module "peering_euw1"` (point `aws.peer` at the new alias, `peer_region = "eu-west-1"`, and the
   `local.regions["eu-west-1"]` lookups).
3. **Re-apply the platform root.** It discovers the new region from SSM, adds its LiteLLM deployment, and
   builds the peering + routes. Done.

## Testing

```bash
# Launch the bastion: set enable_bastion = true in environments/platform/terraform.tfvars, then apply.
cd environments/platform && terraform apply
ALB=$(terraform output -raw entry_alb_hostname)
BASTION=$(terraform output -raw bastion_instance_id)
DEVKEY_ARN=$(terraform output -raw dev_key_secret_arn)

# Port-forward through the bastion to the private entry ALB.
aws ssm start-session --target "$BASTION" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$ALB\"],\"portNumber\":[\"443\"],\"localPortNumber\":[\"8443\"]}"

# In another shell (-k because the sample cert is self-signed). Fetch the dev key from Secrets Manager via
# the aws-secrets-manager workflow (do not print it); use it as the Bearer token.
curl -k https://localhost:8443/v1/models -H "Authorization: Bearer <dev-key>"           # 200
curl -k -o /dev/null -w '%{http_code}\n' https://localhost:8443/v1/models               # no key -> 401
```

### Client contract for affinity

To pin a conversation to its cache-warm region, a client sends the **same session id on every turn** —
either the `x-litellm-session-id` **header** or `metadata.session_id` in the request body (equivalent;
`x-litellm-trace-id` also works). The first turn is placed by `least-busy`; every subsequent turn with
that id is routed back to the same region. Omitting the id makes each request a "new session" that
`least-busy` may place anywhere. Affinity pins are shared across LiteLLM replicas via the state Redis,
so this only works while that Redis is reachable (see the TLS note under *Central gateway*).

Affinity check: send two `/v1/chat/completions` with the same `x-litellm-session-id` — both land on the
same region (cache stays warm); distinct session ids spread by `least-busy`.

## Observability

Each region creates an Amazon Managed Prometheus workspace (`enable_observability`) and publishes its ARN to
SSM. A **central Amazon Managed Grafana** across those workspaces is available via `modules/observability-global`
and the `enable_grafana` flag (default **off**). It provisions Grafana datasources through a `grafana` provider
bootstrapped from a service-account token the module itself outputs (a two-apply cycle:
`terraform apply -target=module.observability_global`, then a full apply).

Grafana with `AWS_SSO` authentication requires **AWS IAM Identity Center**. Note that Identity Center is
**Region-scoped**: a workspace using `AWS_SSO` must reach an Identity Center instance, and an *account
instance* of Identity Center cannot be called cross-Region. So create the Grafana workspace in the **same
Region as your Identity Center instance** (or use an organization instance). This sample defaults
`enable_grafana = false` to avoid coupling the stack to a specific Identity Center Region; the per-region AMP
workspaces are fully functional on their own. Turn it on once your Identity Center Region is settled.

## Teardown

Destroy in reverse: **platform first** (removes the peering + central gateway), then each region root.

```bash
# Remove K8s-managed ALBs first so VPC destroy is not blocked.
./scripts/pre-destroy-cleanup.sh   # per region (pass CLUSTER_NAME/REGION)

cd environments/platform && terraform destroy

cd ../region
terraform init -reconfigure -backend-config=backend.hcl -backend-config="key=region-us-east-2/terraform.tfstate"
terraform destroy -var-file=us-east-2.tfvars
terraform init -reconfigure -backend-config=backend.hcl -backend-config="key=region-us-east-1/terraform.tfstate"
terraform destroy -var-file=us-east-1.tfvars

cd ../00-bootstrap && terraform destroy
```

## License

MIT-0. See [LICENSE](LICENSE).
