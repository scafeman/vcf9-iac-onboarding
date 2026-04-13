# Feature Backlog

Future enhancements and ideas for the VCF 9 IaC Onboarding Toolkit.

## Planned Features

### 1. GitOps CI/CD Pipeline Integration
- **Spec:** `.kiro/specs/gitops-cicd-pipeline/`
- **Status:** Spec complete (requirements, design, tasks) — ready for implementation
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
