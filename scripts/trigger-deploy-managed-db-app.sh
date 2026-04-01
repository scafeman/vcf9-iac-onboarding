#!/usr/bin/env bash
set -euo pipefail

# Companion trigger script for the deploy-managed-db-app GitHub Actions workflow.
# Sends a repository_dispatch event via the GitHub REST API.
#
# Required: --repo, --token, --cluster-name
# Optional: all Managed DB App parameters (DSM config, DB credentials, etc.)
#           — if not provided, the workflow falls back to GitHub secrets or defaults.
#
# NOTE: Make this file executable with: chmod +x scripts/trigger-deploy-managed-db-app.sh

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Trigger the deploy-managed-db-app GitHub Actions workflow via repository_dispatch.

Required:
  --repo                       GitHub repository (OWNER/REPO)
  --token                      GitHub PAT with repo scope
  --cluster-name               VKS cluster name

Optional (override workflow defaults):
  --supervisor-namespace       Supervisor namespace for DSM provisioning
  --project-name               VCF project name
  --dsm-infra-policy           DSM infrastructure policy name
  --dsm-vm-class               VM class for DSM instances (default: medium)
  --dsm-storage-policy         vSphere storage policy name for DSM
  --dsm-storage-space          Storage allocation for DSM (default: 20Gi)
  --postgres-version           PostgreSQL version
  --postgres-db                PostgreSQL database name (default: assetdb)
  --admin-password             Admin password for the PostgresCluster
  --app-namespace              Kubernetes namespace for API + Frontend (default: managed-db-app)
  --container-registry         Container registry prefix (default: scafeman)
  --image-tag                  Container image tag (default: latest)
  --vcfa-endpoint              VCF Automation endpoint
  --tenant-name                VCF tenant name

Example:
  $(basename "$0") \\
    --repo myorg/vcf9-iac \\
    --token ghp_xxxxxxxxxxxx \\
    --cluster-name my-project-01-clus-01 \\
    --supervisor-namespace my-project-ns \\
    --dsm-infra-policy my-dsm-policy \\
    --dsm-storage-policy nfs
EOF
}

# --- Defaults ---
REPO=""
TOKEN=""
CLUSTER_NAME=""
SUPERVISOR_NAMESPACE=""
PROJECT_NAME=""
DSM_INFRA_POLICY=""
DSM_VM_CLASS=""
DSM_STORAGE_POLICY=""
DSM_STORAGE_SPACE=""
POSTGRES_VERSION=""
POSTGRES_DB=""
ADMIN_PASSWORD=""
APP_NAMESPACE=""
CONTAINER_REGISTRY=""
IMAGE_TAG=""
VCFA_ENDPOINT=""
TENANT_NAME=""

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)                       REPO="$2"; shift 2 ;;
    --token)                      TOKEN="$2"; shift 2 ;;
    --cluster-name)               CLUSTER_NAME="$2"; shift 2 ;;
    --supervisor-namespace)       SUPERVISOR_NAMESPACE="$2"; shift 2 ;;
    --project-name)               PROJECT_NAME="$2"; shift 2 ;;
    --dsm-infra-policy)           DSM_INFRA_POLICY="$2"; shift 2 ;;
    --dsm-vm-class)               DSM_VM_CLASS="$2"; shift 2 ;;
    --dsm-storage-policy)         DSM_STORAGE_POLICY="$2"; shift 2 ;;
    --dsm-storage-space)          DSM_STORAGE_SPACE="$2"; shift 2 ;;
    --postgres-version)           POSTGRES_VERSION="$2"; shift 2 ;;
    --postgres-db)                POSTGRES_DB="$2"; shift 2 ;;
    --admin-password)             ADMIN_PASSWORD="$2"; shift 2 ;;
    --app-namespace)              APP_NAMESPACE="$2"; shift 2 ;;
    --container-registry)         CONTAINER_REGISTRY="$2"; shift 2 ;;
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

add_field "supervisor_namespace"     "$SUPERVISOR_NAMESPACE"
add_field "project_name"             "$PROJECT_NAME"
add_field "dsm_infra_policy"         "$DSM_INFRA_POLICY"
add_field "dsm_vm_class"             "$DSM_VM_CLASS"
add_field "dsm_storage_policy"       "$DSM_STORAGE_POLICY"
add_field "dsm_storage_space"        "$DSM_STORAGE_SPACE"
add_field "postgres_version"         "$POSTGRES_VERSION"
add_field "postgres_db"              "$POSTGRES_DB"
add_field "admin_password"           "$ADMIN_PASSWORD"
add_field "app_namespace"            "$APP_NAMESPACE"
add_field "container_registry"       "$CONTAINER_REGISTRY"
add_field "image_tag"                "$IMAGE_TAG"
add_field "vcfa_endpoint"            "$VCFA_ENDPOINT"
add_field "tenant_name"              "$TENANT_NAME"

# --- Send repository_dispatch event ---
DISPATCH_BODY=$(jq -n --argjson payload "$PAYLOAD" '{
  "event_type": "deploy-managed-db-app",
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
