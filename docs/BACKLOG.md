# Feature Backlog

Future enhancements and ideas for the VCF 9 IaC Onboarding Toolkit.

## Planned Features

### 1. GitOps CI/CD Pipeline Integration
- **Spec:** `.kiro/specs/gitops-cicd-pipeline/`
- **Status:** ✅ Complete — merged in PR #11
- **Summary:** Wire Harbor, GitLab, ArgoCD, and GitLab Runner into a functioning end-to-end CI/CD pipeline. One-file demo: edit `demo-config.yaml` in GitLab UI → CI builds → pushes to Harbor → ArgoCD syncs → visible change on Online Boutique.

### 2. Ansible-Based VM Configuration Management
- **Status:** Idea
- **Summary:** Replace cloud-init `runcmd` blocks in the HA VM App and Hybrid App with Ansible playbooks for software installation, repo cloning, and app deployment. Cloud-init handles OS-level bootstrap (SSH keys, basic packages), Ansible handles app-level configuration.
- **Benefits:**
  - Faster iteration — change a playbook and re-run without rebuilding the VM
  - Better error handling and reporting
  - Idempotent — run multiple times safely
  - Separation of concerns (OS bootstrap vs app deployment)
  - Reusable roles (same Node.js role for web and API tiers)
- **AWS Equivalent:** EC2 User Data (cloud-init) + Ansible/SSM for configuration management
- **Patterns affected:** deploy-ha-vm-app, deploy-hybrid-app

### 3. Knative Let's Encrypt TLS (net-certmanager)
- **Status:** Idea
- **Summary:** Add Let's Encrypt TLS to Knative Service routes via the `net-certmanager` controller. Currently the audit function endpoint uses HTTP only.
- **Patterns affected:** deploy-knative

### 4. HA VM App Let's Encrypt TLS (Caddy reverse proxy)
- **Status:** Idea
- **Summary:** Install Caddy as a reverse proxy on web-tier VMs with built-in Let's Encrypt auto-provisioning for sslip.io hostnames. Currently the HA VM App uses HTTP only (DNS alias, no TLS).
- **Patterns affected:** deploy-ha-vm-app

### 5. Knative Vault-Injected DSM Credentials
- **Status:** Idea
- **Summary:** Replace plaintext PostgreSQL credentials in the Knative API server and audit function with vault-injected secrets via VCF Secret Store. Same pattern as deploy-managed-db-app. The API server Deployment is straightforward; the Knative Service (audit function) requires testing vault-agent sidecar compatibility with Knative's pod lifecycle (scale-to-zero, revision management).
- **AWS Equivalent:** Lambda environment variables → Secrets Manager SDK calls
- **Patterns affected:** deploy-knative

### 6. Pre-Flight Prerequisites Check Script
- **Status:** Idea
- **Summary:** Create a `scripts/preflight-check.sh` script that validates VCF 9 connectivity and resource availability before starting the 18-minute cluster deployment. Checks would include: VCFA endpoint reachability, API token validity, content library existence, zone availability, VPC connectivity, sufficient compute capacity, and package repository accessibility. Saves time by catching misconfigurations in 30 seconds instead of failing 10 minutes into a deployment.
- **AWS Equivalent:** `aws sts get-caller-identity` + `aws eks describe-cluster` pre-checks
- **Patterns affected:** deploy-cluster (primary), all downstream patterns (inherited)
