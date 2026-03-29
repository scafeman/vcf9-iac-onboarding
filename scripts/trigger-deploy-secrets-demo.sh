#!/usr/bin/env bash
set -euo pipefail

# Companion trigger script for the deploy-secrets-demo GitHub Actions workflow.
# Sends a repository_dispatch event via the GitHub REST API.
#
# Required: --repo, --token, --cluster-name
# Optional: all secrets demo parameters (environment, domain, credentials, etc.)
#           — if not provided, the workflow falls back to GitHub secrets or defaults.
#
# NOTE: Make this file executable with: chmod +x scripts/trigger-deploy-secrets-demo.sh

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Trigger the deploy-secrets-demo GitHub Actions workflow via repository_dispatch.

Required:
  --repo                       GitHub repository (OWNER/REPO)
  --token                      GitHub PAT with repo scope
  --cluster-name               VKS cluster name

Optional (override workflow defaults):
  --environment                Environment label (default: demo)
  --domain                     Domain suffix (default: lab.local)
  --secret-store-ip            External IP of the VCF Secret Store service
  --supervisor-namespace       Supervisor namespace for secret paths
  --redis-password             Redis authentication password
  --postgres-user              PostgreSQL username (default: secretsadmin)
  --postgres-password          PostgreSQL password
  --postgres-db                PostgreSQL database name (default: secretsdb)
  --namespace                  Kubernetes namespace (default: secrets-demo)
  --container-registry         Container registry for dashboard image (default: scafeman)
  --image-name                 Dashboard image name (default: secrets-dashboard)
  --image-tag                  Dashboard image tag (default: latest)
  --vcfa-endpoint              VCF Automation endpoint
  --tenant-name                VCF tenant name

Example:
  $(basename "$0") \\
    --repo myorg/vcf9-iac \\
    --token ghp_xxxxxxxxxxxx \\
    --cluster-name my-project-01-clus-01 \\
    --secret-store-ip 10.0.0.50 \\
    --supervisor-namespace my-project-ns
EOF
}

# --- Defaults ---
REPO=""
TOKEN=""
CLUSTER_NAME=""
ENVIRONMENT=""
DOMAIN=""
SECRET_STORE_IP=""
SUPERVISOR_NAMESPACE=""
REDIS_PASSWORD=""
POSTGRES_USER=""
POSTGRES_PASSWORD=""
POSTGRES_DB=""
NAMESPACE=""
CONTAINER_REGISTRY=""
IMAGE_NAME=""
IMAGE_TAG=""
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
    --secret-store-ip)            SECRET_STORE_IP="$2"; shift 2 ;;
    --supervisor-namespace)       SUPERVISOR_NAMESPACE="$2"; shift 2 ;;
    --redis-password)             REDIS_PASSWORD="$2"; shift 2 ;;
    --postgres-user)              POSTGRES_USER="$2"; shift 2 ;;
    --postgres-password)          POSTGRES_PASSWORD="$2"; shift 2 ;;
    --postgres-db)                POSTGRES_DB="$2"; shift 2 ;;
    --namespace)                  NAMESPACE="$2"; shift 2 ;;
    --container-registry)         CONTAINER_REGISTRY="$2"; shift 2 ;;
    --image-name)                 IMAGE_NAME="$2"; shift 2 ;;
    --image-tag)                  IMAGE_TAG="$2"; shift 2 ;;
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
add_field "secret_store_ip"          "$SECRET_STORE_IP"
add_field "supervisor_namespace"     "$SUPERVISOR_NAMESPACE"
add_field "redis_password"           "$REDIS_PASSWORD"
add_field "postgres_user"            "$POSTGRES_USER"
add_field "postgres_password"        "$POSTGRES_PASSWORD"
add_field "postgres_db"              "$POSTGRES_DB"
add_field "namespace"                "$NAMESPACE"
add_field "container_registry"       "$CONTAINER_REGISTRY"
add_field "image_name"               "$IMAGE_NAME"
add_field "image_tag"                "$IMAGE_TAG"
add_field "vcfa_endpoint"            "$VCFA_ENDPOINT"
add_field "tenant_name"              "$TENANT_NAME"

# --- Send repository_dispatch event ---
DISPATCH_BODY=$(jq -n --argjson payload "$PAYLOAD" '{
  "event_type": "deploy-secrets-demo",
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
