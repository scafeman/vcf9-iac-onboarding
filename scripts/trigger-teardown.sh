#!/usr/bin/env bash
set -euo pipefail

# Companion trigger script for the teardown GitHub Actions workflow.
# Sends a repository_dispatch event via the GitHub REST API.
#
# Required: --repo, --token, --cluster-name
# Optional: --teardown-gitops, --teardown-metrics, --teardown-cluster (default true),
#           --domain, --kubeconfig-path, --vcfa-endpoint, --tenant-name
#
# NOTE: Make this file executable with: chmod +x scripts/trigger-teardown.sh

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Trigger the teardown GitHub Actions workflow via repository_dispatch.

Required:
  --repo              GitHub repository (OWNER/REPO)
  --token             GitHub PAT with repo scope
  --cluster-name      VKS cluster name to tear down

Optional (override workflow defaults):
  --teardown-gitops   Tear down GitOps stack (default: true)
  --teardown-metrics  Tear down Metrics stack (default: true)
  --teardown-cluster  Tear down VKS cluster and project (default: true)
  --domain            Domain suffix for hostnames
  --kubeconfig-path   Path to kubeconfig file
  --vcfa-endpoint     VCFA hostname (no https://)
  --tenant-name       SSO tenant/organization

Example:
  $(basename "$0") \\
    --repo myorg/vcf9-iac \\
    --token ghp_xxxxxxxxxxxx \\
    --cluster-name my-project-01-clus-01

  $(basename "$0") \\
    --repo myorg/vcf9-iac \\
    --token ghp_xxxxxxxxxxxx \\
    --cluster-name my-project-01-clus-01 \\
    --teardown-gitops false \\
    --teardown-cluster false
EOF
}

# --- Defaults ---
REPO=""
TOKEN=""
CLUSTER_NAME=""
TEARDOWN_GITOPS=""
TEARDOWN_METRICS=""
TEARDOWN_CLUSTER=""
DOMAIN=""
KUBECONFIG_PATH=""
VCFA_ENDPOINT=""
TENANT_NAME=""

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)              REPO="$2"; shift 2 ;;
    --token)             TOKEN="$2"; shift 2 ;;
    --cluster-name)      CLUSTER_NAME="$2"; shift 2 ;;
    --teardown-gitops)   TEARDOWN_GITOPS="$2"; shift 2 ;;
    --teardown-metrics)  TEARDOWN_METRICS="$2"; shift 2 ;;
    --teardown-cluster)  TEARDOWN_CLUSTER="$2"; shift 2 ;;
    --domain)            DOMAIN="$2"; shift 2 ;;
    --kubeconfig-path)   KUBECONFIG_PATH="$2"; shift 2 ;;
    --vcfa-endpoint)     VCFA_ENDPOINT="$2"; shift 2 ;;
    --tenant-name)       TENANT_NAME="$2"; shift 2 ;;
    -h|--help)           usage; exit 0 ;;
    *)
      echo "Error: Unknown argument: $1" >&2
      usage >&2
      exit 1 ;;
  esac
done

# --- Validate required arguments ---
MISSING=()
[[ -z "$REPO" ]]         && MISSING+=("--repo")
[[ -z "$TOKEN" ]]        && MISSING+=("--token")
[[ -z "$CLUSTER_NAME" ]] && MISSING+=("--cluster-name")

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "Error: Missing required arguments: ${MISSING[*]}" >&2
  usage >&2
  exit 1
fi

# --- Build client_payload JSON ---
# Start with required fields, then add optional fields only if provided
PAYLOAD=$(cat <<EOF
{
  "cluster_name": "${CLUSTER_NAME}"
}
EOF
)

# Add optional fields using jq (only if non-empty)
add_field() {
  local key="$1" value="$2"
  if [[ -n "$value" ]]; then
    PAYLOAD=$(echo "$PAYLOAD" | jq --arg k "$key" --arg v "$value" '. + {($k): $v}')
  fi
}

add_field "teardown_gitops"  "$TEARDOWN_GITOPS"
add_field "teardown_metrics" "$TEARDOWN_METRICS"
add_field "teardown_cluster" "$TEARDOWN_CLUSTER"
add_field "domain"           "$DOMAIN"
add_field "kubeconfig_path"  "$KUBECONFIG_PATH"
add_field "vcfa_endpoint"    "$VCFA_ENDPOINT"
add_field "tenant_name"      "$TENANT_NAME"

# --- Send repository_dispatch event ---
DISPATCH_BODY=$(jq -n --argjson payload "$PAYLOAD" '{
  "event_type": "teardown",
  "client_payload": $payload
}')

HTTP_RESPONSE=$(mktemp)
HTTP_STATUS=$(curl -s -o "$HTTP_RESPONSE" -w "%{http_code}" \
  -X POST \
  -H "Authorization: token ${TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  -H "Content-Type: application/json" \
  "https://api.github.com/repos/${REPO}/dispatches" \
  -d "$DISPATCH_BODY")

if [[ "$HTTP_STATUS" != "204" ]]; then
  echo "Error: GitHub API returned HTTP ${HTTP_STATUS}" >&2
  cat "$HTTP_RESPONSE" >&2
  rm -f "$HTTP_RESPONSE"
  exit 2
fi

rm -f "$HTTP_RESPONSE"
echo "Workflow dispatched successfully."
echo "Parameters sent:"
echo "$PAYLOAD" | jq .
echo ""
echo "Monitor the run at: https://github.com/${REPO}/actions"
