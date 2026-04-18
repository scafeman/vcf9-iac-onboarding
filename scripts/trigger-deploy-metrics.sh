#!/usr/bin/env bash
set -euo pipefail

# Companion trigger script for the deploy-vks-metrics GitHub Actions workflow.
# Sends a repository_dispatch event via the GitHub REST API.
#
# Required: --repo, --token, --cluster-name, --telegraf-version
# Optional: all metrics stack parameters (environment, domain, etc.)
#           — if not provided, the workflow falls back to GitHub secrets or defaults.
#
# NOTE: Make this file executable with: chmod +x scripts/trigger-deploy-metrics.sh

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Trigger the deploy-vks-metrics GitHub Actions workflow via repository_dispatch.

Required:
  --repo                    GitHub repository (OWNER/REPO)
  --token                   GitHub PAT with repo scope
  --cluster-name            VKS cluster name

Optional (override workflow defaults):
  --telegraf-version        Telegraf package version (default: 1.37.1+vmware.1-vks.1)
  --environment             Environment label (default: demo)
  --domain                  Domain suffix (default: lab.local)
  --kubeconfig-path         Path to kubeconfig file
  --package-namespace       Package namespace (default: tkg-packages)
  --package-repo-url        VKS standard packages OCI repository URL
  --telegraf-values-file    Telegraf Helm values file path
  --prometheus-values-file  Prometheus Helm values file path
  --storage-class           Storage class for PVCs
  --grafana-admin-password  Grafana admin password
  --package-timeout         Package reconciliation timeout in seconds
  --vcfa-endpoint           VCF Automation endpoint
  --tenant-name             VCF tenant name

Example:
  $(basename "$0") \\
    --repo myorg/vcf9-iac \\
    --token ghp_xxxxxxxxxxxx \\
    --cluster-name my-project-01-clus-01 \\
    --telegraf-version 1.4.3 \\
    --environment demo \\
    --domain lab.local
EOF
}

# --- Defaults ---
REPO=""
TOKEN=""
CLUSTER_NAME=""
TELEGRAF_VERSION=""
ENVIRONMENT=""
DOMAIN=""
KUBECONFIG_PATH=""
PACKAGE_NAMESPACE=""
PACKAGE_REPO_URL=""
TELEGRAF_VALUES_FILE=""
PROMETHEUS_VALUES_FILE=""
STORAGE_CLASS=""
GRAFANA_ADMIN_PASSWORD=""
PACKAGE_TIMEOUT=""
VCFA_ENDPOINT=""
TENANT_NAME=""

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)                    REPO="$2"; shift 2 ;;
    --token)                   TOKEN="$2"; shift 2 ;;
    --cluster-name)            CLUSTER_NAME="$2"; shift 2 ;;
    --telegraf-version)        TELEGRAF_VERSION="$2"; shift 2 ;;
    --environment)             ENVIRONMENT="$2"; shift 2 ;;
    --domain)                  DOMAIN="$2"; shift 2 ;;
    --kubeconfig-path)         KUBECONFIG_PATH="$2"; shift 2 ;;
    --package-namespace)       PACKAGE_NAMESPACE="$2"; shift 2 ;;
    --package-repo-url)        PACKAGE_REPO_URL="$2"; shift 2 ;;
    --telegraf-values-file)    TELEGRAF_VALUES_FILE="$2"; shift 2 ;;
    --prometheus-values-file)  PROMETHEUS_VALUES_FILE="$2"; shift 2 ;;
    --storage-class)           STORAGE_CLASS="$2"; shift 2 ;;
    --grafana-admin-password)  GRAFANA_ADMIN_PASSWORD="$2"; shift 2 ;;
    --package-timeout)         PACKAGE_TIMEOUT="$2"; shift 2 ;;
    --vcfa-endpoint)           VCFA_ENDPOINT="$2"; shift 2 ;;
    --tenant-name)             TENANT_NAME="$2"; shift 2 ;;
    -h|--help)                 usage; exit 0 ;;
    *)
      echo "Error: Unknown argument: $1" >&2
      usage >&2
      exit 1 ;;
  esac
done

# --- Validate required arguments ---
MISSING=()
[[ -z "$REPO" ]]             && MISSING+=("--repo")
[[ -z "$TOKEN" ]]            && MISSING+=("--token")
[[ -z "$CLUSTER_NAME" ]]     && MISSING+=("--cluster-name")

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

add_field "telegraf_version"        "$TELEGRAF_VERSION"
add_field "environment"            "$ENVIRONMENT"
add_field "domain"                 "$DOMAIN"
add_field "kubeconfig_path"        "$KUBECONFIG_PATH"
add_field "package_namespace"      "$PACKAGE_NAMESPACE"
add_field "package_repo_url"       "$PACKAGE_REPO_URL"
add_field "telegraf_values_file"   "$TELEGRAF_VALUES_FILE"
add_field "prometheus_values_file" "$PROMETHEUS_VALUES_FILE"
add_field "storage_class"          "$STORAGE_CLASS"
add_field "grafana_admin_password" "$GRAFANA_ADMIN_PASSWORD"
add_field "package_timeout"        "$PACKAGE_TIMEOUT"
add_field "vcfa_endpoint"          "$VCFA_ENDPOINT"
add_field "tenant_name"            "$TENANT_NAME"

# --- Send repository_dispatch event ---
DISPATCH_BODY=$(jq -n --argjson payload "$PAYLOAD" '{
  "event_type": "deploy-vks-metrics",
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
