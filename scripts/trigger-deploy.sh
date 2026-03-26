#!/usr/bin/env bash
set -euo pipefail

# Companion trigger script for the deploy-vks GitHub Actions workflow.
# Sends a repository_dispatch event via the GitHub REST API.
#
# Usage:
#   ./scripts/trigger-deploy.sh \
#     --repo OWNER/REPO \
#     --token GITHUB_TOKEN \
#     --project-name my-project \
#     --cluster-name my-cluster \
#     --namespace-prefix my-project-ns-
#
# NOTE: Make this file executable with: chmod +x scripts/trigger-deploy.sh

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Trigger the deploy-vks GitHub Actions workflow via repository_dispatch.

Required arguments:
  --repo              GitHub repository in OWNER/REPO format
  --token             GitHub personal access token (with repo scope)
  --project-name      VCF Project name
  --cluster-name      VKS cluster name
  --namespace-prefix  Supervisor Namespace prefix

Example:
  $(basename "$0") \\
    --repo myorg/vcf9-iac \\
    --token ghp_xxxxxxxxxxxx \\
    --project-name my-dev-project-01 \\
    --cluster-name my-dev-project-01-clus-01 \\
    --namespace-prefix my-dev-project-01-ns-
EOF
}

REPO=""
TOKEN=""
PROJECT_NAME=""
CLUSTER_NAME=""
NAMESPACE_PREFIX=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO="$2"; shift 2 ;;
    --token)
      TOKEN="$2"; shift 2 ;;
    --project-name)
      PROJECT_NAME="$2"; shift 2 ;;
    --cluster-name)
      CLUSTER_NAME="$2"; shift 2 ;;
    --namespace-prefix)
      NAMESPACE_PREFIX="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
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
[[ -z "$PROJECT_NAME" ]]     && MISSING+=("--project-name")
[[ -z "$CLUSTER_NAME" ]]     && MISSING+=("--cluster-name")
[[ -z "$NAMESPACE_PREFIX" ]] && MISSING+=("--namespace-prefix")

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "Error: Missing required arguments: ${MISSING[*]}" >&2
  usage >&2
  exit 1
fi

# --- Send repository_dispatch event ---
HTTP_RESPONSE=$(mktemp)
HTTP_STATUS=$(curl -s -o "$HTTP_RESPONSE" -w "%{http_code}" \
  -X POST \
  -H "Authorization: token ${TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  -H "Content-Type: application/json" \
  "https://api.github.com/repos/${REPO}/dispatches" \
  -d "{
    \"event_type\": \"deploy-vks\",
    \"client_payload\": {
      \"project_name\": \"${PROJECT_NAME}\",
      \"cluster_name\": \"${CLUSTER_NAME}\",
      \"namespace_prefix\": \"${NAMESPACE_PREFIX}\"
    }
  }")

if [[ "$HTTP_STATUS" != "204" ]]; then
  echo "Error: GitHub API returned HTTP ${HTTP_STATUS}" >&2
  cat "$HTTP_RESPONSE" >&2
  rm -f "$HTTP_RESPONSE"
  exit 2
fi

rm -f "$HTTP_RESPONSE"
echo "Workflow dispatched successfully."
echo "Monitor the run at: https://github.com/${REPO}/actions"
