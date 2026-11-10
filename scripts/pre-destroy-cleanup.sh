#!/usr/bin/env bash
#
# pre-destroy-cleanup.sh — remove Kubernetes-managed load balancers BEFORE `terraform destroy`.
#
# WHY THIS EXISTS
# ---------------
# The AWS Load Balancer Controller creates ALBs (and their ENIs, target groups, security groups)
# OUT-OF-BAND in response to Ingress/Service objects in the cluster. Terraform does not manage those
# ALBs and does not know about the ENIs they attach to your subnets. If you run `terraform destroy`
# while those objects still exist, the VPC/subnet/security-group destroy will BLOCK (DependencyViolation:
# network interfaces still in use) until the controller tears the ALBs down.
#
# This script deletes the Kubernetes objects first and then WAITS until the controller has actually
# removed the ALBs (polling the ELBv2 API), so the subsequent Terraform destroy has a clean VPC.
#
# It is intentionally conservative: it targets only the sample's inference CRs and the litellm
# Ingress/Service, and uses --ignore-not-found so it is safe to re-run.
#
# NOTE ON Lambda@Edge: this sample does NOT use Lambda@Edge (edge logic uses CloudFront Functions /
# origin config only). So there is no Lambda@Edge replica to wait on — replica deletion can lag for
# 30-60+ minutes when it IS used, but that does not apply here.
#
# Configuration (env vars, or the matching flags):
#   CLUSTER_NAME   Required. The EKS/HyperPod cluster name.
#   REGION         Required. The AWS region the cluster lives in.
#   NAMESPACE      Optional. Namespace of the litellm Ingress/Service. Default: litellm
#   TIMEOUT_SECS   Optional. Max seconds to wait for ALBs to disappear. Default: 600
#
# Flags: --cluster <name> --region <region> --namespace <ns> --timeout <secs>
#
# Usage:
#   CLUSTER_NAME=my-hp-cluster REGION=us-east-1 ./pre-destroy-cleanup.sh
#   ./pre-destroy-cleanup.sh --cluster my-hp-cluster --region us-east-1

set -euo pipefail

# --------------------------------------------------------------------------------------------------
# Defaults and argument parsing
# --------------------------------------------------------------------------------------------------

CLUSTER_NAME="${CLUSTER_NAME:-}"
REGION="${REGION:-}"
NAMESPACE="${NAMESPACE:-litellm}"
TIMEOUT_SECS="${TIMEOUT_SECS:-600}"
POLL_INTERVAL_SECS=15

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster)   CLUSTER_NAME="$2"; shift 2 ;;
    --region)    REGION="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --timeout)   TIMEOUT_SECS="$2"; shift 2 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "${CLUSTER_NAME}" || -z "${REGION}" ]]; then
  echo "ERROR: CLUSTER_NAME and REGION are required (env vars or --cluster/--region)." >&2
  exit 2
fi

for bin in aws kubectl; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "ERROR: '${bin}' is required but not installed. Aborting." >&2
    exit 2
  fi
done

echo "pre-destroy cleanup"
echo "  Cluster  : ${CLUSTER_NAME}"
echo "  Region   : ${REGION}"
echo "  Namespace: ${NAMESPACE}"
echo "  Timeout  : ${TIMEOUT_SECS}s"

# --------------------------------------------------------------------------------------------------
# 1. Point kubectl at the cluster.
# --------------------------------------------------------------------------------------------------

echo ""
echo "== Updating kubeconfig =="
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${REGION}"

# --------------------------------------------------------------------------------------------------
# 2. Delete the sample's InferenceEndpointConfig CRs in every namespace.
#    These may own Services/Ingress that front the model, so remove them first.
# --------------------------------------------------------------------------------------------------

echo ""
echo "== Deleting InferenceEndpointConfig resources (all namespaces) =="
if kubectl get crd inferenceendpointconfigs.inference.sagemaker.aws.amazon.com >/dev/null 2>&1 \
  || kubectl get inferenceendpointconfig -A >/dev/null 2>&1; then
  kubectl delete inferenceendpointconfig --all --all-namespaces --ignore-not-found --wait=true
else
  echo "  (InferenceEndpointConfig CRD not present — nothing to delete)"
fi

# --------------------------------------------------------------------------------------------------
# 3. Delete the ALB Ingress(es) and any LoadBalancer Service in the namespace. Deleting the Ingress
#    triggers the AWS Load Balancer Controller to tear down the ALB it provisioned; deleting a
#    LoadBalancer-type Service tears down its NLB/CLB. --ignore-not-found keeps this idempotent.
#
#    NOTE: the LiteLLM chart names the Ingress "<name_prefix>-litellm" (e.g. sample-hpinf-use2-litellm),
#    NOT a fixed "litellm", so we DISCOVER and delete every Ingress in the namespace rather than
#    hardcoding a name (a hardcoded name silently matches nothing and leaves the ALB — and the VPC
#    destroy — blocked).
# --------------------------------------------------------------------------------------------------

echo ""
echo "== Deleting Ingress(es) and LoadBalancer Service(s) in namespace ${NAMESPACE} =="
INGRESSES="$(kubectl get ingress -n "${NAMESPACE}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
if [[ -n "${INGRESSES}" ]]; then
  echo "${INGRESSES}" | while read -r ing; do
    [[ -n "${ing}" ]] && echo "  deleting ingress ${ing}" \
      && kubectl delete ingress "${ing}" -n "${NAMESPACE}" --ignore-not-found --wait=true || true
  done
else
  echo "  (no Ingress objects in ${NAMESPACE})"
fi
# Sweep any LoadBalancer-type Services in the namespace (these create NLBs/CLBs directly).
LB_SVCS="$(kubectl get svc -n "${NAMESPACE}" \
  -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
if [[ -n "${LB_SVCS}" ]]; then
  echo "  LoadBalancer Services found; deleting:"
  echo "${LB_SVCS}" | while read -r svc; do
    [[ -n "${svc}" ]] && kubectl delete service "${svc}" -n "${NAMESPACE}" --ignore-not-found || true
  done
fi

# --------------------------------------------------------------------------------------------------
# 4. Poll ELBv2 until no load balancer remains tagged for this cluster.
#    The AWS Load Balancer Controller tags every LB it creates with:
#        elbv2.k8s.aws/cluster = <CLUSTER_NAME>
#    We enumerate all LBs, then use describe-tags to find any still carrying that tag.
# --------------------------------------------------------------------------------------------------

echo ""
echo "== Waiting for cluster-tagged load balancers to be removed (timeout ${TIMEOUT_SECS}s) =="

cluster_tagged_lb_count() {
  # List all LB ARNs in the region. Empty result => 0.
  local arns
  arns="$(aws elbv2 describe-load-balancers --region "${REGION}" \
    --query 'LoadBalancers[].LoadBalancerArn' --output text 2>/dev/null || true)"
  if [[ -z "${arns}" || "${arns}" == "None" ]]; then
    echo 0
    return
  fi

  # describe-tags accepts up to 20 ARNs per call; batch to be safe.
  local count=0
  local batch=()
  # shellcheck disable=SC2206
  local all=(${arns})
  local i
  for ((i = 0; i < ${#all[@]}; i += 20)); do
    batch=("${all[@]:i:20}")
    local matches
    matches="$(aws elbv2 describe-tags --region "${REGION}" \
      --resource-arns "${batch[@]}" \
      --query "length(TagDescriptions[?Tags[?Key=='elbv2.k8s.aws/cluster' && Value=='${CLUSTER_NAME}']])" \
      --output text 2>/dev/null || echo 0)"
    [[ "${matches}" =~ ^[0-9]+$ ]] && count=$((count + matches))
  done
  echo "${count}"
}

DEADLINE=$(( $(date +%s) + TIMEOUT_SECS ))
while true; do
  REMAINING="$(cluster_tagged_lb_count)"
  if [[ "${REMAINING}" -eq 0 ]]; then
    echo "  OK: no load balancers tagged for cluster ${CLUSTER_NAME} remain."
    break
  fi
  NOW="$(date +%s)"
  if [[ "${NOW}" -ge "${DEADLINE}" ]]; then
    echo "  TIMEOUT: ${REMAINING} load balancer(s) still tagged for ${CLUSTER_NAME} after ${TIMEOUT_SECS}s." >&2
    echo "  Inspect and remove them before running 'terraform destroy', or the VPC destroy will block:" >&2
    echo "    aws elbv2 describe-load-balancers --region ${REGION}" >&2
    exit 1
  fi
  echo "  ${REMAINING} load balancer(s) still present; waiting ${POLL_INTERVAL_SECS}s..."
  sleep "${POLL_INTERVAL_SECS}"
done

# --------------------------------------------------------------------------------------------------
# Guidance
# --------------------------------------------------------------------------------------------------

cat <<'GUIDANCE'

Cleanup complete. Kubernetes-managed load balancers have been removed.

terraform destroy order (reverse of apply):

    platform  ->  region (each added)...  ->  region (primary)  ->  00-bootstrap

Run `terraform destroy` in each stack directory in that order.

Note: this sample does NOT use Lambda@Edge, so there is no replica-deletion wait
(CloudFront replicas of an edge function can otherwise take 30-60+ minutes to delete).
GUIDANCE
