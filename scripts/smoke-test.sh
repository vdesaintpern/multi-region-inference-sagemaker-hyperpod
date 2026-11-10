#!/usr/bin/env bash
#
# smoke-test.sh — read-only end-to-end verification of the HyperPod inference sample.
#
# Verifies that the CloudFront-fronted LiteLLM inference endpoint behaves correctly:
#   * a valid developer key can call the OpenAI-compatible chat endpoint,
#   * unauthenticated and bad-key requests are rejected,
#   * management/UI paths are NOT exposed through CloudFront, and
#   * (optionally) the in-cluster inference resources look healthy.
#
# It performs NO writes and NO mutations. Nothing here is destructive.
#
# Configuration (env vars, or the matching CLI flags below):
#   CLOUDFRONT_DOMAIN   Required. The CloudFront distribution domain, e.g. d123.cloudfront.net
#                       (no scheme, no trailing slash). NEVER hardcoded here.
#   DEV_KEY             The developer API key (LiteLLM virtual key). Either pass it directly,
#                       or pass DEV_KEY_SECRET_ARN to fetch it from AWS Secrets Manager.
#   DEV_KEY_SECRET_ARN  Optional. Secrets Manager secret ARN/name holding the dev key.
#   MODEL_ALIAS         Model alias to exercise. Default: qwen2.5-7b-awq
#   NAMESPACE           Kubernetes namespace for the LiteLLM/inference workload. Default: litellm
#
# CLI flags (override env vars):
#   --domain <d> --key <k> --secret-arn <arn> --model <alias> --namespace <ns>
#
# Exit code: 0 if all checks behaved as expected; non-zero if the positive check fails
# or any negative check unexpectedly returns 200 (i.e. a real security/availability regression).
#
# Usage:
#   CLOUDFRONT_DOMAIN=d123.cloudfront.net DEV_KEY=sk-... ./smoke-test.sh
#   ./smoke-test.sh --domain d123.cloudfront.net --secret-arn arn:aws:secretsmanager:...:secret:dev-key

set -euo pipefail

# --------------------------------------------------------------------------------------------------
# Defaults and argument parsing
# --------------------------------------------------------------------------------------------------

CLOUDFRONT_DOMAIN="${CLOUDFRONT_DOMAIN:-}"
DEV_KEY="${DEV_KEY:-}"
DEV_KEY_SECRET_ARN="${DEV_KEY_SECRET_ARN:-}"
MODEL_ALIAS="${MODEL_ALIAS:-qwen2.5-7b-awq}"
NAMESPACE="${NAMESPACE:-litellm}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)     CLOUDFRONT_DOMAIN="$2"; shift 2 ;;
    --key)        DEV_KEY="$2"; shift 2 ;;
    --secret-arn) DEV_KEY_SECRET_ARN="$2"; shift 2 ;;
    --model)      MODEL_ALIAS="$2"; shift 2 ;;
    --namespace)  NAMESPACE="$2"; shift 2 ;;
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

# --------------------------------------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------------------------------------

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  PASS: $*"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "  FAIL: $*" >&2
}

info() {
  echo "  INFO: $*"
}

header() {
  echo ""
  echo "== $* =="
}

# --------------------------------------------------------------------------------------------------
# Preconditions
# --------------------------------------------------------------------------------------------------

if [[ -z "${CLOUDFRONT_DOMAIN}" ]]; then
  echo "ERROR: CLOUDFRONT_DOMAIN is required (env var or --domain). Aborting." >&2
  exit 2
fi

# Strip any accidental scheme/trailing slash so the base URL is well-formed.
CLOUDFRONT_DOMAIN="${CLOUDFRONT_DOMAIN#http://}"
CLOUDFRONT_DOMAIN="${CLOUDFRONT_DOMAIN#https://}"
CLOUDFRONT_DOMAIN="${CLOUDFRONT_DOMAIN%/}"
BASE_URL="https://${CLOUDFRONT_DOMAIN}"

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl is required but not installed. Aborting." >&2
  exit 2
fi

# Resolve the developer key from Secrets Manager if only the ARN was supplied.
if [[ -z "${DEV_KEY}" && -n "${DEV_KEY_SECRET_ARN}" ]]; then
  if ! command -v aws >/dev/null 2>&1; then
    echo "ERROR: DEV_KEY_SECRET_ARN was set but the AWS CLI is not installed. Aborting." >&2
    exit 2
  fi
  info "Fetching developer key from Secrets Manager: ${DEV_KEY_SECRET_ARN}"
  # SecretString may be a raw string or JSON. Try the common {"DEV_KEY":"..."} / {"api_key":"..."}
  # shapes, then fall back to the raw string.
  SECRET_JSON="$(aws secretsmanager get-secret-value \
    --secret-id "${DEV_KEY_SECRET_ARN}" \
    --query SecretString --output text)"
  if command -v jq >/dev/null 2>&1 && echo "${SECRET_JSON}" | jq -e . >/dev/null 2>&1; then
    DEV_KEY="$(echo "${SECRET_JSON}" | jq -r '.DEV_KEY // .dev_key // .api_key // .key // empty')"
    [[ -z "${DEV_KEY}" ]] && DEV_KEY="${SECRET_JSON}"
  else
    DEV_KEY="${SECRET_JSON}"
  fi
fi

# Small, cheap chat completion body (max_tokens kept tiny to minimise cost/latency).
read_chat_body() {
  cat <<JSON
{"model":"${MODEL_ALIAS}","messages":[{"role":"user","content":"ping"}],"max_tokens":1}
JSON
}

# curl wrapper that prints ONLY the HTTP status code, discards the body, and applies timeouts.
# Extra args (headers, method, data) are passed through.
http_status() {
  curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 10 --max-time 60 \
    "$@"
}

echo "HyperPod inference smoke test"
echo "  Endpoint : ${BASE_URL}"
echo "  Model    : ${MODEL_ALIAS}"
echo "  Namespace: ${NAMESPACE}"

# --------------------------------------------------------------------------------------------------
# 1. Positive: valid key -> expect 200
# --------------------------------------------------------------------------------------------------

header "1. Positive: valid developer key on /v1/chat/completions (expect 200)"
if [[ -z "${DEV_KEY}" ]]; then
  fail "No DEV_KEY available (set DEV_KEY or DEV_KEY_SECRET_ARN). Positive check cannot run."
else
  CODE="$(http_status -X POST "${BASE_URL}/v1/chat/completions" \
    -H "Authorization: Bearer ${DEV_KEY}" \
    -H "Content-Type: application/json" \
    -d "$(read_chat_body)")" || CODE="000"
  if [[ "${CODE}" == "200" ]]; then
    pass "authenticated chat completion returned 200"
  else
    fail "authenticated chat completion returned ${CODE} (expected 200)"
  fi
fi

# --------------------------------------------------------------------------------------------------
# 2. Negative: no auth header -> expect 401 or 403 (must NOT be 200)
# --------------------------------------------------------------------------------------------------

header "2. Negative: no Authorization header (expect 401/403)"
CODE="$(http_status -X POST "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "$(read_chat_body)")" || CODE="000"
if [[ "${CODE}" == "401" || "${CODE}" == "403" ]]; then
  pass "unauthenticated request rejected with ${CODE}"
elif [[ "${CODE}" == "200" ]]; then
  fail "unauthenticated request returned 200 — endpoint is NOT enforcing auth!"
else
  info "unauthenticated request returned ${CODE} (expected 401/403; not 200, so no auth bypass)"
fi

# --------------------------------------------------------------------------------------------------
# 3. Negative: bad key -> expect 401 (must NOT be 200)
# --------------------------------------------------------------------------------------------------

header "3. Negative: invalid bearer token (expect 401)"
CODE="$(http_status -X POST "${BASE_URL}/v1/chat/completions" \
  -H "Authorization: Bearer sk-invalid" \
  -H "Content-Type: application/json" \
  -d "$(read_chat_body)")" || CODE="000"
if [[ "${CODE}" == "401" ]]; then
  pass "invalid key rejected with 401"
elif [[ "${CODE}" == "403" ]]; then
  info "invalid key rejected with 403 (acceptable; not a 200 bypass)"
elif [[ "${CODE}" == "200" ]]; then
  fail "invalid key returned 200 — endpoint is NOT validating keys!"
else
  info "invalid key returned ${CODE} (expected 401; not 200, so no auth bypass)"
fi

# --------------------------------------------------------------------------------------------------
# 4. Negative: blocked management/UI paths -> expect 403/404 (not routed through CloudFront)
# --------------------------------------------------------------------------------------------------

header "4. Negative: management/UI paths not exposed (expect 403/404)"
for path in "/ui" "/health"; do
  CODE="$(http_status -X GET "${BASE_URL}${path}")" || CODE="000"
  if [[ "${CODE}" == "403" || "${CODE}" == "404" ]]; then
    pass "GET ${path} not routed (${CODE})"
  elif [[ "${CODE}" == "200" ]]; then
    fail "GET ${path} returned 200 — management/UI path is exposed through CloudFront!"
  else
    info "GET ${path} returned ${CODE} (expected 403/404; not 200, so not exposed)"
  fi
done

# --------------------------------------------------------------------------------------------------
# 5. Optional: in-cluster checks (only if kubectl is configured against the cluster)
# --------------------------------------------------------------------------------------------------

header "5. Cluster checks (kubectl, if configured)"
if command -v kubectl >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1; then
  info "InferenceEndpointConfig resources (all namespaces):"
  kubectl get inferenceendpointconfig -A 2>/dev/null || info "  (no inferenceendpointconfig CRD / resources found)"
  info "Pods in namespace ${NAMESPACE}:"
  kubectl get pods -n "${NAMESPACE}" 2>/dev/null || info "  (namespace ${NAMESPACE} not found or no pods)"
else
  info "kubectl not configured against a cluster — skipping in-cluster checks."
fi

# --------------------------------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------------------------------

header "Summary"
echo "  Passed: ${PASS_COUNT}"
echo "  Failed: ${FAIL_COUNT}"

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  echo "Smoke test FAILED." >&2
  exit 1
fi
echo "Smoke test PASSED."
exit 0
