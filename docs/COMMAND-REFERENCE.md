# VCF 9 IaC — Command Reference

Quick-reference guide for VCF CLI, kubectl, and Docker commands used with the VCF 9 IaC Onboarding Toolkit. Commands are organized by context level and use case.

> **Context matters.** VCF 9 uses three context levels — Global (org), Namespace (supervisor), and Guest Cluster. Most commands only work in the correct context. The Context column tells you which one.

---

## 1. VCF CLI — Context Management

| Command | Description | Context |
|---|---|---|
| `vcf context create <NAME> --endpoint "https://<VCFA>" --type cci --tenant-name <TENANT> --api-token <TOKEN> --set-current` | Create and activate a VCF CLI context | Any |
| `vcf context list` | List all available contexts (org + namespace) | Any |
| `vcf context use <CONTEXT_NAME>` | Switch to a specific context | Any |
| `vcf context use <ORG>:<NAMESPACE>:<PROJECT>` | Switch to a namespace-scoped context (Context Bridge) | Any |
| `vcf context delete <NAME> --yes` | Delete a VCF CLI context | Any |
| `vcf context refresh` | Refresh context list (discover new namespaces) | Any |
| `vcf plugin list` | List installed VCF CLI plugins | Any |
| `vcf plugin install <PLUGIN>` | Install a VCF CLI plugin (e.g., `cluster`, `vm`, `secret`) | Any |
| `vcf plugin sync` | Sync plugins to recommended versions for active context | Namespace |

---

## 2. Global (Org-Level) Context

Commands that run at the organization level — before switching to a namespace context.

### Infrastructure Discovery

| Command | Description |
|---|---|
| `kubectl get regions` | List available regions |
| `kubectl get zones` | List availability zones |
| `kubectl get vpcs` | List NSX VPCs |
| `kubectl get vpcconnectivityprofiles` | List VPC connectivity profiles |
| `kubectl get transitgateways` | List transit gateways |
| `kubectl get ipblocks` | List IP blocks (public + private) |
| `kubectl get projects` | List all projects |
| `kubectl get supervisornamespaces -n <PROJECT>` | List supervisor namespaces in a project |
| `kubectl get svnscls` | List supervisor namespace resource classes |

### Project & Namespace Provisioning

| Command | Description |
|---|---|
| `kubectl create -f sample-create-project-ns.yaml --validate=false` | Create Project + RBAC + Supervisor Namespace |
| `kubectl get project <PROJECT>` | Check if a project exists |
| `kubectl get supervisornamespaces -n <PROJECT>` | Get the generated namespace name (has random suffix) |
| `kubectl delete project <PROJECT>` | Delete a project and all its resources |

### VPC & Networking

| Command | Description |
|---|---|
| `kubectl create -f sample-create-vpc.yaml --validate=false` | Create an NSX VPC |
| `kubectl create -f sample-vpc-attachment.yaml --validate=false` | Attach VPC to a connectivity profile |
| `kubectl get vpcnatrules -n <PROJECT>` | List NAT rules for a project |

---

## 3. Namespace (Supervisor) Context

Commands that run after switching to a namespace-scoped context via the Context Bridge.

### Context Bridge

| Command | Description |
|---|---|
| `vcf context use <ORG>:<NAMESPACE>:<PROJECT>` | Switch to namespace context (unlocks Cluster API) |
| `kubectl get clusters` | Verify Context Bridge — should list clusters (empty if not bridged) |

### VKS Cluster Lifecycle

| Command | Description |
|---|---|
| `kubectl apply -f sample-create-cluster.yaml --validate=false` | Create a VKS cluster |
| `kubectl get clusters` | List VKS clusters in the namespace |
| `kubectl get cluster <CLUSTER> -o yaml` | Get cluster details and status |
| `kubectl get cluster <CLUSTER> -o jsonpath='{.status.phase}'` | Get cluster provisioning phase |
| `vcf cluster kubeconfig get <CLUSTER> --admin --export-file kubeconfig-<CLUSTER>.yaml` | Export admin kubeconfig |
| `kubectl delete cluster <CLUSTER>` | Delete a VKS cluster |

### VM Service

| Command | Description |
|---|---|
| `kubectl get virtualmachineclasses` | List available VM classes |
| `kubectl get virtualmachineimages` | List available VM images |
| `kubectl get virtualmachines -n <NAMESPACE>` | List VMs in the namespace |
| `kubectl get virtualmachine <VM> -n <NS> -o jsonpath='{.status.powerState}'` | Get VM power state |
| `kubectl get virtualmachine <VM> -n <NS> -o jsonpath='{.status.network.primaryIP4}'` | Get VM IP address |
| `kubectl get virtualmachineservice -n <NAMESPACE>` | List VM services (LoadBalancers) |
| `kubectl get subnetsets -n <NAMESPACE>` | List available NSX SubnetSets |
| `kubectl apply -f sample-create-vm.yaml` | Create a VirtualMachine |
| `kubectl delete virtualmachine <VM> -n <NS>` | Delete a VirtualMachine |

### DSM (Database Service Manager)

| Command | Description |
|---|---|
| `kubectl get postgrescluster -n <NAMESPACE>` | List DSM PostgresClusters |
| `kubectl get postgrescluster <NAME> -n <NS> -o yaml` | Get PostgresCluster full status |
| `kubectl get postgrescluster <NAME> -n <NS> -o jsonpath='{.status.connection}'` | Extract connection details (host, port, dbname) |
| `kubectl get postgrescluster <NAME> -n <NS> -o jsonpath='{.status.connection.host}'` | Get DSM PostgreSQL host IP |
| `kubectl get postgrescluster <NAME> -n <NS> -o jsonpath='{.status.conditions}'` | Get provisioning conditions |
| `kubectl get secret pg-<CLUSTER_NAME> -n <NS> -o jsonpath='{.data.password}' \| base64 -d` | Get DSM-created admin password |
| `kubectl describe postgrescluster <NAME> -n <NS>` | Get events and detailed status |

### Secret Store

| Command | Description |
|---|---|
| `vcf plugin install secret` | Install the secret CLI plugin |
| `vcf secret list` | List KeyValueSecrets in current namespace |
| `vcf secret create -f <FILE>` | Create a KeyValueSecret from YAML |
| `vcf secret delete <NAME>` | Delete a KeyValueSecret |
| `kubectl get serviceaccount internal-app` | Check if vault ServiceAccount exists |
| `kubectl get secret internal-app-token -o jsonpath='{.data.token}'` | Get the vault auth token (base64) |

### Storage & Networking

| Command | Description |
|---|---|
| `kubectl get storageclasses` | List Kubernetes storage classes available in the namespace |
| `kubectl get subnetsets` | List NSX SubnetSets |

> **Note:** `kubectl get storagepolicies` requires cluster-admin access and is not available to project-level users. Use `kubectl get storageclasses` on the guest cluster instead, or check available storage policies via the VCFA UI (Infrastructure → Storage Policies).

---

## 4. Guest Cluster Context

Commands that run against the VKS guest cluster after exporting the admin kubeconfig.

### Kubeconfig Setup

| Command | Description |
|---|---|
| `export KUBECONFIG=./kubeconfig-<CLUSTER>.yaml` | Set kubeconfig for the guest cluster |
| `kubectl config use-context <CLUSTER>-admin@<CLUSTER>` | Switch to the admin context |
| `kubectl config get-contexts` | List available contexts in the kubeconfig |
| `kubectl get namespaces` | Verify guest cluster connectivity |
| `kubectl get nodes -o wide` | List worker nodes with IPs and status |

### Workload Management

| Command | Description |
|---|---|
| `kubectl get pods -n <NAMESPACE> -o wide` | List pods with node placement |
| `kubectl get pods -n <NS> -l app=<LABEL>` | List pods by label selector |
| `kubectl get deployments -n <NAMESPACE>` | List deployments |
| `kubectl get svc -n <NAMESPACE>` | List services (ClusterIP + LoadBalancer) |
| `kubectl get svc <SVC> -n <NS> -o jsonpath='{.status.loadBalancer.ingress[0].ip}'` | Get LoadBalancer external IP |
| `kubectl logs -l app=<LABEL> -n <NS> --tail=50` | Tail pod logs by label |
| `kubectl logs <POD> -c <CONTAINER> -n <NS>` | Logs from a specific container (e.g., vault-agent) |
| `kubectl describe pod <POD> -n <NS>` | Get pod events and status details |
| `kubectl exec -it <POD> -n <NS> -- <CMD>` | Exec into a running pod |
| `kubectl rollout restart deployment/<NAME> -n <NS>` | Restart a deployment (force new pod) |
| `kubectl rollout status deployment/<NAME> -n <NS>` | Watch rollout progress |

### VKS Standard Packages

| Command | Description |
|---|---|
| `vcf package repository list -n tkg-packages` | List registered package repositories |
| `vcf package repository add <NAME> --url <OCI_URL> -n tkg-packages` | Register a package repository |
| `vcf package available list -n tkg-packages` | List available packages |
| `vcf package installed list -n tkg-packages` | List installed packages |
| `vcf package install <NAME> -p <PACKAGE> --version <VER> --values-file <FILE> -n tkg-packages` | Install a package |
| `vcf package installed delete <NAME> -n tkg-packages --yes` | Uninstall a package |
| `kubectl get packageinstall -n tkg-packages` | List package installs (Carvel) |
| `kubectl get app -n tkg-packages` | List kapp-controller apps |

### PVC & Storage

| Command | Description |
|---|---|
| `kubectl get pvc -n <NAMESPACE>` | List PersistentVolumeClaims |
| `kubectl get pv` | List PersistentVolumes |
| `kubectl get storageclasses` | List storage classes on the guest cluster |

---

## 5. Docker & Container Operations

Commands for managing the dev container and building/pushing images.

### Dev Container

| Command | Description |
|---|---|
| `docker compose up -d --build` | Build and start the dev container + runner |
| `docker compose up -d --force-recreate vcf-dev` | Recreate dev container (picks up .env changes) |
| `docker exec vcf9-dev bash` | Shell into the dev container |
| `docker exec vcf9-dev bash examples/<SCRIPT>.sh` | Run a deploy/teardown script |
| `docker exec vcf9-dev kubectl get pods -A` | Run kubectl from the dev container |
| `docker exec vcf9-dev vcf context list` | Run VCF CLI from the dev container |

### Container Images

| Command | Description |
|---|---|
| `docker build -t <REGISTRY>/<IMAGE>:<TAG> <PATH>` | Build a container image |
| `docker push <REGISTRY>/<IMAGE>:<TAG>` | Push to container registry |
| `echo "<TOKEN>" \| docker login -u <USER> --password-stdin` | Login to DockerHub |
| `docker images \| grep <IMAGE>` | List local images |

---

## 6. Vault & Secret Store Operations

Commands for managing vault-injector and debugging vault-agent sidecars.

### Vault-Injector Status

| Command | Description |
|---|---|
| `vcf package installed list -n tkg-packages \| grep vault` | Check if vault-injector is installed |
| `kubectl get pods -n tkg-packages -l app.kubernetes.io/name=vault-injector` | Check vault-injector pod status |
| `kubectl get mutatingwebhookconfiguration vault-agent-injector-cfg` | Verify webhook is registered |

### Vault-Agent Debugging

| Command | Description |
|---|---|
| `kubectl get pods -n <NS> -l app=<LABEL>` | Check pod container count (2/2 = sidecar injected) |
| `kubectl logs <POD> -c vault-agent-init -n <NS>` | Check vault-agent init container logs |
| `kubectl logs <POD> -c vault-agent -n <NS>` | Check vault-agent sidecar logs |
| `kubectl exec <POD> -c vault-agent -n <NS> -- cat /vault/secrets/<FILE>` | Read vault-mounted secrets file |
| `kubectl describe pod <POD> -n <NS> \| grep -A5 vault` | Check vault annotations on pod |

---

## 7. Troubleshooting

Common debugging commands for stuck resources, failed deployments, and connectivity issues.

### Pod Debugging

| Command | Description |
|---|---|
| `kubectl get pods -n <NS> -o wide` | Pod status with node placement |
| `kubectl describe pod <POD> -n <NS>` | Events, conditions, container status |
| `kubectl logs <POD> -n <NS> --tail=50` | Recent pod logs |
| `kubectl logs <POD> -n <NS> --previous` | Logs from previous crashed container |
| `kubectl get events -n <NS> --sort-by='.lastTimestamp'` | Recent events sorted by time |

### Stuck Namespace Cleanup

| Command | Description |
|---|---|
| `kubectl get ns <NS> -o json \| jq '.spec.finalizers = []' \| kubectl replace --raw "/api/v1/namespaces/<NS>/finalize" -f -` | Force-remove namespace finalizer |
| `kubectl patch <RESOURCE> <NAME> -n <NS> --type merge -p '{"metadata":{"finalizers":null}}'` | Strip finalizers from a stuck resource |

### Stuck Package Cleanup

| Command | Description |
|---|---|
| `kubectl patch packageinstall <NAME> -n tkg-packages --type merge -p '{"metadata":{"finalizers":null}}'` | Strip finalizer from stuck package |
| `kubectl patch app <NAME> -n tkg-packages --type merge -p '{"metadata":{"finalizers":null}}'` | Strip finalizer from stuck kapp app |
| `kubectl delete packageinstall <NAME> -n tkg-packages --ignore-not-found` | Delete package install |
| `kubectl delete app <NAME> -n tkg-packages --ignore-not-found` | Delete kapp app |

### DSM Troubleshooting

| Command | Description |
|---|---|
| `kubectl get postgrescluster <NAME> -n <NS> -o yaml` | Full PostgresCluster status and conditions |
| `kubectl describe postgrescluster <NAME> -n <NS>` | Events and detailed status |
| `kubectl get secrets -n <NS> \| grep -E "pg-\|admin"` | List DSM-related secrets |
| `kubectl delete secret <NAME> -n <NS> --ignore-not-found` | Clean up orphaned secrets |

### Connectivity Testing

| Command | Description |
|---|---|
| `curl -s -o /dev/null -w "%{http_code}" http://<IP>` | HTTP status check |
| `curl -v http://<IP>/api/healthz` | Verbose API health check |
| `kubectl exec -it <POD> -n <NS> -- nc -zv <HOST> <PORT>` | TCP connectivity test from a pod |
| `kubectl exec -it <POD> -n <NS> -- nslookup <SERVICE>` | DNS resolution test from a pod |

---

## 8. GitHub Actions Runner

Commands for managing the self-hosted runner.

| Command | Description |
|---|---|
| `docker compose up -d` | Start the runner container |
| `docker compose restart gh-actions-runner` | Restart the runner |
| `docker compose logs gh-actions-runner --tail=50` | View runner logs |
| `docker compose down` | Stop all containers (dev + runner) |

### Workflow Dispatch via curl

```bash
curl -X POST \
  -H "Authorization: token <GITHUB_PAT>" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/<OWNER>/<REPO>/dispatches" \
  -d '{"event_type": "<EVENT_TYPE>", "client_payload": { ... }}'
```

Event types: `deploy-vks`, `deploy-vks-metrics`, `deploy-argocd`, `deploy-hybrid-app`, `deploy-bastion-vm`, `deploy-managed-db-app`, `deploy-secrets-demo`, `teardown`

---

## AWS to VCF Command Mapping

Quick reference for teams migrating from AWS CLI to VCF CLI.

| AWS CLI | VCF CLI / kubectl | Notes |
|---|---|---|
| `aws eks update-kubeconfig` | `vcf cluster kubeconfig get <CLUSTER> --admin` | Exports kubeconfig file |
| `aws eks list-clusters` | `kubectl get clusters` | Requires namespace context |
| `aws eks describe-cluster` | `kubectl get cluster <NAME> -o yaml` | Full cluster status |
| `aws rds describe-db-instances` | `kubectl get postgrescluster -n <NS>` | DSM managed databases |
| `aws rds create-db-instance` | `kubectl apply -f postgres-cluster.yaml` | Declarative via CRD |
| `aws ec2 describe-instances` | `kubectl get virtualmachines -n <NS>` | VM Service VMs |
| `aws ec2 run-instances` | `kubectl apply -f sample-create-vm.yaml` | Declarative via CRD |
| `aws elbv2 describe-load-balancers` | `kubectl get svc -A --field-selector spec.type=LoadBalancer` | NSX LoadBalancers |
| `aws secretsmanager list-secrets` | `vcf secret list` | VCF Secret Store |
| `aws secretsmanager create-secret` | `vcf secret create -f <FILE>` | KeyValueSecret CRD |
| `aws iam list-roles` | `kubectl get projectrolebindings -n <PROJECT>` | CCI RBAC |
