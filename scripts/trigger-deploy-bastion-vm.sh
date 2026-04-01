#!/usr/bin/env bash
set -euo pipefail

# Companion trigger script for the deploy-bastion-vm GitHub Actions workflow.
# Sends a repository_dispatch event via the GitHub REST API.
#
# Required: --repo, --token, --supervisor-namespace
# Optional: all Bastion VM parameters (external IPs, SSH sources, VM config, etc.)
#           — if not provided, the workflow falls back to GitHub secrets or defaults.
#
# NOTE: Make this file executable with: chmod +x scripts/trigger-deploy-bastion-vm.sh

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Trigger the deploy-bastion-vm GitHub Actions workflow via repository_dispatch.

Required:
  --repo                       GitHub repository (OWNER/REPO)
  --token                      GitHub PAT with repo scope
  --supervisor-namespace       Supervisor namespace for VM provisioning

Optional (override workflow defaults):
  --allowed-ssh-sources        Comma-separated allowed SSH source IPs (default: 136.62.85.50)
  --vm-class                   VM Service compute class (default: best-effort-medium)
  --vm-image                   Content library image name (default: ubuntu-24.04-server-cloudimg-amd64)
  --vm-name                    Name for the VirtualMachine resource (default: bastion-vm)
  --ssh-username               SSH username for the bastion VM (default: rackadmin)
  --ssh-public-key             SSH public key for the bastion VM user
  --boot-disk-size             Boot disk size override (e.g., 50Gi)
  --data-disk-size             Additional data disk size (e.g., 100Gi)
  --vm-network                 NSX SubnetSet name for the VM network (e.g., inside-subnet)
  --vcfa-endpoint              VCF Automation endpoint
  --tenant-name                VCF tenant name

Example:
  $(basename "$0") \\
    --repo myorg/vcf9-iac \\
    --token ghp_xxxxxxxxxxxx \\
    --supervisor-namespace my-project-ns \\
    --ssh-username myuser \\
    --ssh-public-key "ssh-ed25519 AAAA... my-key"
EOF
}

# --- Defaults ---
REPO=""
TOKEN=""
SUPERVISOR_NAMESPACE=""
ALLOWED_SSH_SOURCES=""
VM_CLASS=""
VM_IMAGE=""
VM_NAME=""
SSH_USERNAME=""
SSH_PUBLIC_KEY=""
BOOT_DISK_SIZE=""
DATA_DISK_SIZE=""
VM_NETWORK=""
VCFA_ENDPOINT=""
TENANT_NAME=""

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)                       REPO="$2"; shift 2 ;;
    --token)                      TOKEN="$2"; shift 2 ;;
    --supervisor-namespace)       SUPERVISOR_NAMESPACE="$2"; shift 2 ;;
    --allowed-ssh-sources)        ALLOWED_SSH_SOURCES="$2"; shift 2 ;;
    --vm-class)                   VM_CLASS="$2"; shift 2 ;;
    --vm-image)                   VM_IMAGE="$2"; shift 2 ;;
    --vm-name)                    VM_NAME="$2"; shift 2 ;;
    --ssh-username)               SSH_USERNAME="$2"; shift 2 ;;
    --ssh-public-key)             SSH_PUBLIC_KEY="$2"; shift 2 ;;
    --boot-disk-size)             BOOT_DISK_SIZE="$2"; shift 2 ;;
    --data-disk-size)             DATA_DISK_SIZE="$2"; shift 2 ;;
    --vm-network)                 VM_NETWORK="$2"; shift 2 ;;
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
[[ -z "$REPO" ]]                  && MISSING+=("--repo")
[[ -z "$TOKEN" ]]                 && MISSING+=("--token")
[[ -z "$SUPERVISOR_NAMESPACE" ]]  && MISSING+=("--supervisor-namespace")

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "Error: Missing required arguments: ${MISSING[*]}" >&2
  usage >&2
  exit 1
fi

# --- Build client_payload JSON ---
# Start with required fields, then add optional fields only if provided
PAYLOAD=$(cat <<EOF
{
  "supervisor_namespace": "${SUPERVISOR_NAMESPACE}"
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

add_field "allowed_ssh_sources"    "$ALLOWED_SSH_SOURCES"
add_field "vm_class"               "$VM_CLASS"
add_field "vm_image"               "$VM_IMAGE"
add_field "vm_name"                "$VM_NAME"
add_field "ssh_username"           "$SSH_USERNAME"
add_field "ssh_public_key"         "$SSH_PUBLIC_KEY"
add_field "boot_disk_size"         "$BOOT_DISK_SIZE"
add_field "data_disk_size"         "$DATA_DISK_SIZE"
add_field "vm_network"             "$VM_NETWORK"
add_field "vcfa_endpoint"          "$VCFA_ENDPOINT"
add_field "tenant_name"            "$TENANT_NAME"

# --- Send repository_dispatch event ---
DISPATCH_BODY=$(jq -n --argjson payload "$PAYLOAD" '{
  "event_type": "deploy-bastion-vm",
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
