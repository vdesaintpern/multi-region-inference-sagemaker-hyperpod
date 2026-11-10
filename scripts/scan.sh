#!/usr/bin/env bash
# Run the security scanners required for a Public Content Security Review (PCSR) before publishing
# this sample. Attach the outputs to the review ticket. See the repo README "Security" section.
#
# Scanners: Checkov + cfn-guard (Terraform IaC), detect-secrets (secrets), Trivy (container images/FS).
# This is a convenience wrapper; the authoritative gate is the AWS review process (Slingshot/Holmes).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${REPO_ROOT}/.scan-results"
mkdir -p "${OUT}"
cd "${REPO_ROOT}"

echo "== detect-secrets =="
if command -v detect-secrets >/dev/null 2>&1; then
  detect-secrets scan --baseline .config/.secrets.baseline || true
  echo "  (review .config/.secrets.baseline for any new findings)"
else
  echo "  SKIP: detect-secrets not installed (pip install detect-secrets==1.5.0)"
fi

echo "== Checkov (Terraform) =="
if command -v checkov >/dev/null 2>&1; then
  checkov -d . --config-file .config/.checkov.yaml -o cli -o sarif --output-file-path "console,${OUT}/checkov.sarif" || true
else
  echo "  SKIP: checkov not installed (pip install checkov==3.2.334)"
fi

echo "== Trivy (filesystem / IaC + secrets) =="
if command -v trivy >/dev/null 2>&1; then
  trivy fs --scanners misconfig,secret,vuln --format sarif --output "${OUT}/trivy.sarif" . || true
else
  echo "  SKIP: trivy not installed (https://aquasecurity.github.io/trivy)"
fi

echo "== cfn-guard note =="
echo "  This sample is Terraform, not CloudFormation, EXCEPT the HyperPod cluster (a CFN-wrapped stack"
echo "  in modules/eks-hyperpod). Checkov/Trivy cover the Terraform; run cfn-guard against the rendered"
echo "  CFN template if you extract it."

echo "Done. SARIF + baselines under ${OUT}/ and .config/"
