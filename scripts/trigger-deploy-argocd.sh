#!/usr/bin/env bash
set -euo pipefail

# Companion trigger script for the deploy-argocd GitHub Actions workflow.
# Sends a repository_dispatch event via the GitHub REST API.
#
# Required: --repo, --token, --cluster-name
# Optional: all ArgoCD stack parameters (environment, domain, versions, etc.)
#           — if not provided, the workflow falls back to GitHub secrets or defaults.
#
# NOTE: Make this file executable with: chmod +x scripts/trigger-deploy-argocd.sh

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Trigger the deploy-argocd GitHub Actions workflow via repository_dispatch.

Required:
  --repo                       GitHub repository (OWNER/REPO)
  --token                      GitHub PAT with repo scope
  --cluster-name               VKS cluster name

Optional (override workflow defaults):
  --environment                Environment label (default: demo)
  --domain                     Domain suffix (default: lab.local)
  --kubeconfig-path            Path to kubeconfig file
  --harbor-version             Harbor Helm chart version
  --argocd-version             ArgoCD Helm chart version
  --gitlab-operator-version    GitLab Operator Helm chart version
  --gitlab-runner-version      GitLab Runner Helm chart version
  --harbor-admin-password      Harbor admin password
  --package-timeout            Package reconciliation timeout in seconds
  --vcfa-endpoint              VCF Automation endpoint
  --tenant-name                VCF tenant name

Example:
  $(basename "$0") \\
    --repo myorg/vcf9-iac \\
    --token ghp_xxxxxxxxxxxx \\
    --cluster-name my-project-01-clus-01 \\
    --environment demo \\
    --domain lab.local
EOF
}

# --- Defaults ---
REPO=""
TOKEN=""
CLUSTER_NAME=""
ENVIRONMENT=""
DOMAIN=""
KUBECONFIG_PATH=""
HARBOR_VERSION=""
ARGOCD_VERSION=""
GITLAB_OPERATOR_VERSION=""
GITLAB_RUNNER_VERSION=""
HARBOR_ADMIN_PASSWORD=""
PACKAGE_TIMEOUT=""
VCFA_ENDPOINT=""
TENANT_NAME=""

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)                       REPO="$2"; shift 2 ;;
    --token)                      TOKEN="$2"; shift 2 ;;
    --cluster-name)               CLUSTER_NAME="$2"; shift 2 ;;
    --environment)                ENVIRONMENT="$2"; shift 2 ;;
    --domain)                     DOMAIN="$2"; shift 2 ;;
    --kubeconfig-path)            KUBECONFIG_PATH="$2"; shift 2 ;;
    --harbor-version)             HARBOR_VERSION="$2"; shift 2 ;;
    --argocd-version)             ARGOCD_VERSION="$2"; shift 2 ;;
    --gitlab-operator-version)    GITLAB_OPERATOR_VERSION="$2"; shift 2 ;;
    --gitlab-runner-version)      GITLAB_RUNNER_VERSION="$2"; shift 2 ;;
    --harbor-admin-password)      HARBOR_ADMIN_PASSWORD="$2"; shift 2 ;;
    --package-timeout)            PACKAGE_TIMEOUT="$2"; shift 2 ;;
    --vcfa-endpoint)              VCFA_ENDPOINT="$2"; shift 2 ;;
    --tenant-name)                TENANT_NAME="$2"; shift 2 ;;
    -h|--help)                    usage; exit 0 ;;
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

add_field "environment"              "$ENVIRONMENT"
add_field "domain"                   "$DOMAIN"
add_field "kubeconfig_path"          "$KUBECONFIG_PATH"
add_field "harbor_version"           "$HARBOR_VERSION"
add_field "argocd_version"           "$ARGOCD_VERSION"
add_field "gitlab_operator_version"  "$GITLAB_OPERATOR_VERSION"
add_field "gitlab_runner_version"    "$GITLAB_RUNNER_VERSION"
add_field "harbor_admin_password"    "$HARBOR_ADMIN_PASSWORD"
add_field "package_timeout"          "$PACKAGE_TIMEOUT"
add_field "vcfa_endpoint"            "$VCFA_ENDPOINT"
add_field "tenant_name"              "$TENANT_NAME"

# --- Send repository_dispatch event ---
DISPATCH_BODY=$(jq -n --argjson payload "$PAYLOAD" '{
  "event_type": "deploy-argocd",
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
