#!/bin/bash
###############################################################################
# sslip-helpers.sh — Shared Helper Library for sslip.io DNS & Let's Encrypt TLS
#
# Provides reusable functions for constructing sslip.io hostnames, managing
# cert-manager ClusterIssuers, creating Kubernetes Ingress resources with
# optional TLS, and waiting for certificate readiness.
#
# Usage:
#   source "$(dirname "$0")/../shared/sslip-helpers.sh"
#
# All functions are idempotent and follow existing script conventions:
#   - ${VAR:-default} pattern for configurable values
#   - kubectl apply for create-or-update semantics
#   - Existence checks before creation
#   - Graceful degradation when cert-manager is unavailable
#
# Functions:
#   construct_sslip_hostname <prefix> <ip>
#   check_cert_manager_available
#   check_cluster_issuer_ready <issuer_name>
#   create_cluster_issuer <name> <acme_server> <email>
#   create_ingress_with_tls <name> <namespace> <hostname> <service_name> <service_port> [tls_enabled] [issuer_name]
#   wait_for_certificate <secret_name> <namespace> [timeout]
###############################################################################

###############################################################################
# construct_sslip_hostname — Build an sslip.io hostname from prefix and IP
#
# Arguments:
#   $1 - prefix   : Hostname prefix (e.g., "dashboard", "grafana", "test")
#   $2 - ip       : IPv4 address from the LoadBalancer (e.g., "74.205.11.92")
#
# Output:
#   Prints "<prefix>.<ip>.sslip.io" to stdout
#
# Example:
#   HOSTNAME=$(construct_sslip_hostname "dashboard" "74.205.11.92")
#   # → "dashboard.74.205.11.92.sslip.io"
###############################################################################
construct_sslip_hostname() {
  local prefix="$1"
  local ip="$2"
  echo "${prefix}.${ip}.sslip.io"
}

###############################################################################
# check_cert_manager_available — Test whether cert-manager CRDs are installed
#
# Returns:
#   0 if cert-manager CRDs (certificates.cert-manager.io) are present
#   1 otherwise
#
# Example:
#   if check_cert_manager_available; then
#     echo "cert-manager is available"
#   fi
###############################################################################
check_cert_manager_available() {
  kubectl get crd certificates.cert-manager.io >/dev/null 2>&1
}

###############################################################################
# check_cluster_issuer_ready — Test whether a ClusterIssuer exists and is Ready
#
# Arguments:
#   $1 - issuer_name : Name of the ClusterIssuer (e.g., "letsencrypt-prod")
#
# Returns:
#   0 if the ClusterIssuer exists and has Ready=True condition
#   1 otherwise
#
# Example:
#   if check_cluster_issuer_ready "letsencrypt-prod"; then
#     echo "ClusterIssuer is ready for certificate issuance"
#   fi
###############################################################################
check_cluster_issuer_ready() {
  local issuer_name="$1"
  local status
  status=$(kubectl get clusterissuer "${issuer_name}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  [[ "${status}" == "True" ]]
}

###############################################################################
# create_cluster_issuer — Create a cert-manager ClusterIssuer with HTTP-01
#
# Creates a ClusterIssuer resource that uses the ACME protocol with an
# HTTP-01 challenge solver configured for the Contour ingress class.
# Idempotent: skips creation if the ClusterIssuer already exists.
#
# Arguments:
#   $1 - name        : ClusterIssuer name (e.g., "letsencrypt-prod")
#   $2 - acme_server : ACME directory URL
#                      Production: https://acme-v02.api.letsencrypt.org/directory
#                      Staging:    https://acme-staging-v02.api.letsencrypt.org/directory
#   $3 - email       : ACME account registration email (can be empty)
#
# Returns:
#   0 on success (created or already exists)
#   Non-zero on kubectl apply failure
#
# Example:
#   create_cluster_issuer "letsencrypt-prod" \
#     "https://acme-v02.api.letsencrypt.org/directory" \
#     "admin@example.com"
###############################################################################
create_cluster_issuer() {
  local name="$1"
  local acme_server="$2"
  local email="$3"

  # Idempotency: skip if already exists
  if kubectl get clusterissuer "${name}" >/dev/null 2>&1; then
    echo "✓ ClusterIssuer '${name}' already exists, skipping creation"
    return 0
  fi

  cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${name}
spec:
  acme:
    server: ${acme_server}
    email: "${email}"
    privateKeySecretRef:
      name: ${name}-account-key
    solvers:
      - http01:
          ingress:
            ingressClassName: contour
EOF
}

###############################################################################
# create_ingress_with_tls — Create a Kubernetes Ingress, optionally with TLS
#
# Creates an Ingress resource using the Contour ingress class. When TLS is
# enabled, adds the cert-manager.io/cluster-issuer annotation and a TLS
# section to trigger automatic certificate issuance.
#
# Uses kubectl apply for idempotent create-or-update semantics.
#
# Arguments:
#   $1 - name         : Ingress resource name (e.g., "dashboard-sslip-ingress")
#   $2 - namespace    : Kubernetes namespace for the Ingress
#   $3 - hostname     : sslip.io hostname (e.g., "dashboard.74.205.11.92.sslip.io")
#   $4 - service_name : Backend service name
#   $5 - service_port : Backend service port number
#   $6 - tls_enabled  : "true" to add TLS annotations/section, "false" for HTTP-only
#                        (default: "false")
#   $7 - issuer_name  : ClusterIssuer name for TLS (default: "letsencrypt-prod")
#
# Returns:
#   0 on success
#   Non-zero on kubectl apply failure
#
# Examples:
#   # HTTP-only Ingress (no cert-manager)
#   create_ingress_with_tls "test-sslip-ingress" "default" \
#     "test.74.205.11.92.sslip.io" "vks-test-lb" 80
#
#   # Ingress with TLS certificate
#   create_ingress_with_tls "dashboard-sslip-ingress" "knative-demo" \
#     "dashboard.74.205.11.92.sslip.io" "dashboard-svc" 80 "true" "letsencrypt-prod"
###############################################################################
create_ingress_with_tls() {
  local name="$1"
  local namespace="$2"
  local hostname="$3"
  local service_name="$4"
  local service_port="$5"
  local tls_enabled="${6:-false}"
  local issuer_name="${7:-letsencrypt-prod}"

  local tls_annotation=""
  local tls_section=""

  if [[ "${tls_enabled}" == "true" ]]; then
    tls_annotation="    cert-manager.io/cluster-issuer: \"${issuer_name}\""
    tls_section="  tls:
    - hosts:
        - ${hostname}
      secretName: ${name}-tls"
  fi

  cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${name}
  namespace: ${namespace}
$(if [[ -n "${tls_annotation}" ]]; then echo "  annotations:"; echo "${tls_annotation}"; fi)
spec:
  ingressClassName: contour
$(if [[ -n "${tls_section}" ]]; then echo "${tls_section}"; fi)
  rules:
    - host: ${hostname}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${service_name}
                port:
                  number: ${service_port}
EOF
}

###############################################################################
# wait_for_certificate — Wait for a cert-manager Certificate to be Ready
#
# Polls the Certificate resource associated with the given TLS secret name
# until it reaches Ready=True status or the timeout expires.
#
# Arguments:
#   $1 - secret_name : Name of the TLS Secret (matches Ingress tls.secretName)
#   $2 - namespace   : Kubernetes namespace containing the Certificate
#   $3 - timeout     : Maximum wait time in seconds (default: 300)
#
# Returns:
#   0 if the Certificate reaches Ready status within the timeout
#   1 if the timeout expires
#
# Example:
#   if wait_for_certificate "dashboard-sslip-ingress-tls" "default" 300; then
#     echo "TLS certificate is ready"
#   else
#     echo "Certificate not ready — falling back to HTTP-only"
#   fi
###############################################################################
wait_for_certificate() {
  local secret_name="$1"
  local namespace="$2"
  local timeout="${3:-300}"
  local elapsed=0
  local poll_interval=10
  local retried=false

  while [[ "${elapsed}" -lt "${timeout}" ]]; do
    local status
    status=$(kubectl get certificate "${secret_name}" -n "${namespace}" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    if [[ "${status}" == "True" ]]; then
      echo "✓ Certificate '${secret_name}' is Ready"
      return 0
    fi

    # If cert is stuck in failed state after 60s, delete and let cert-manager recreate
    if [[ "${elapsed}" -ge 60 ]] && [[ "${retried}" == "false" ]]; then
      local issuing_status
      issuing_status=$(kubectl get certificate "${secret_name}" -n "${namespace}" \
        -o jsonpath='{.status.conditions[?(@.type=="Issuing")].reason}' 2>/dev/null || true)
      local failed_attempts
      failed_attempts=$(kubectl get certificate "${secret_name}" -n "${namespace}" \
        -o jsonpath='{.status.failedIssuanceAttempts}' 2>/dev/null || echo "0")
      if [[ "${issuing_status}" == "Failed" ]] || [[ "${failed_attempts:-0}" -gt 0 ]]; then
        echo "  ⚠ Certificate '${secret_name}' has failed issuance — deleting to trigger fresh request"
        kubectl delete certificate "${secret_name}" -n "${namespace}" --ignore-not-found 2>/dev/null || true
        kubectl delete secret "${secret_name}" -n "${namespace}" --ignore-not-found 2>/dev/null || true
        retried=true
        sleep 5
      fi
    fi

    echo "  Waiting for certificate '${secret_name}' to be Ready... (${elapsed}s/${timeout}s elapsed)"
    sleep "${poll_interval}"
    elapsed=$((elapsed + poll_interval))
  done

  echo "  Timeout waiting for certificate '${secret_name}' after ${elapsed}s"
  return 1
}

###############################################################################
# deploy_node_dns_daemonset — Deploy a DaemonSet to patch node /etc/resolv.conf
#
# Deploys a privileged DaemonSet named 'node-dns-patcher' that runs on every
# node (including control plane) and ensures public DNS servers (8.8.8.8 and
# 1.1.1.1) are configured in systemd-resolved alongside the existing corporate
# DNS. This enables the kubelet and containerd to resolve sslip.io hostnames
# for container image pulls.
#
# The DaemonSet container runs a loop that:
#   1. Checks if 8.8.8.8 and 1.1.1.1 are configured in systemd-resolved on eth0
#   2. Adds them via resolvectl if missing (alongside existing corporate DNS)
#   3. Sleeps 60s and repeats (handles node reboots that reset DNS config)
#
# Uses nsenter to access the host's mount/network namespace and resolvectl to
# configure systemd-resolved (required on Photon OS where /etc/resolv.conf is
# a symlink to the systemd-resolved stub file).
#
# Uses kubectl apply for idempotent create-or-update semantics.
#
# Arguments:
#   $1 - namespace : Kubernetes namespace for the DaemonSet (default: "kube-system")
#
# Returns:
#   0 on success
#   Non-zero on kubectl apply failure
#
# Example:
#   deploy_node_dns_daemonset
#   deploy_node_dns_daemonset "custom-namespace"
###############################################################################
deploy_node_dns_daemonset() {
  local namespace="${1:-kube-system}"

  kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-dns-patcher
  namespace: ${namespace}
  labels:
    app: node-dns-patcher
spec:
  selector:
    matchLabels:
      app: node-dns-patcher
  template:
    metadata:
      labels:
        app: node-dns-patcher
    spec:
      hostNetwork: true
      hostPID: true
      tolerations:
        - operator: Exists
      containers:
        - name: dns-patcher
          image: busybox:1.36
          command:
            - /bin/sh
            - -c
            - |
              while true; do
                CHANGED=false
                CURRENT_DNS=\$(nsenter --target 1 --mount --uts --ipc --net -- resolvectl dns eth0 2>/dev/null || echo "")
                for ns in 8.8.8.8 1.1.1.1; do
                  if ! echo "\$CURRENT_DNS" | grep -q "\$ns"; then
                    CHANGED=true
                  fi
                done
                if [ "\$CHANGED" = "true" ]; then
                  nsenter --target 1 --mount --uts --ipc --net -- resolvectl dns eth0 172.20.10.41 8.8.8.8 1.1.1.1 2>/dev/null
                  echo "[\$(date)] Configured systemd-resolved with public DNS servers (8.8.8.8, 1.1.1.1) on eth0"
                fi
                sleep 60
              done
          securityContext:
            privileged: true
EOF
}
