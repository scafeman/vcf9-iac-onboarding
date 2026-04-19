# VCF 9 IaC Onboarding Guide

## Introduction

This guide walks DevOps engineers through the complete Infrastructure-as-Code (IaC) workflow for migrating container workloads from AWS EKS to VMware Cloud Foundation (VCF) 9 with vSphere Kubernetes Service (VKS). It covers the full lifecycle from environment initialization through VKS cluster deployment and functional validation.

> **Companion documents:** Working sample manifests are in the [`examples/`](examples/) folder — see the [Examples README](examples/README.md) for deployment order and details. For a pass/fail validation checklist, see the [AWS EKS to VCF VKS Migration Checklist](AWS-EKS-to-VCF-VKS-Migration-Checklist.md).

---

## Phase 1: Environment Initialization

Before provisioning any VCF 9 infrastructure, you must initialize a VCF CLI context that points to your VCF Automation (VCFA) endpoint and targets the correct tenant. This context configures `kubectl` to communicate with VCFA's CCI APIs for all subsequent operations.

### Prerequisites

> **Authentication Required:** VCF CLI authentication must be completed before any `kubectl` operations can succeed. Generate an API token from the VCFA portal and ensure your fleet certificate is configured. Without valid authentication credentials, all `kubectl` commands against VCFA will fail with `401 Unauthorized` or TLS verification errors.

### Step 1: Create a VCF CLI Context

Run the following command to create a named context that maps your CLI session to a specific VCFA endpoint and tenant:

```bash
# Create a new VCF CLI context targeting the VCFA endpoint
# - endpoint: the VCFA hostname or IP (port 443)
# - type: "cci" for Cloud Consumption Interface operations
# - tenant-name: the SSO tenant/organization configured in VCFA
vcf context create \
  --endpoint <VCFA_ENDPOINT> \
  --type cci \
  --tenant-name <TENANT_NAME> \
  <CONTEXT_NAME>
```

Replace the placeholders with your environment-specific values:

| Placeholder | Description | Example |
|---|---|---|
| `<VCFA_ENDPOINT>` | VCFA hostname or IP address | `vcfa01.example.com` |
| `<CONTEXT_NAME>` | A local name for this CLI context | `my-project-dev` |
| `<TENANT_NAME>` | SSO tenant/organization name in VCFA | `org-mycompany-01` |

### Step 2: Set the Active Context

After creating the context, set it as the active context so that all subsequent `kubectl` commands target this VCFA environment:

```bash
# Set the newly created context as active
# This configures kubectl to route commands to the VCFA endpoint
vcf context use <CONTEXT_NAME>
```

Once the context is active, you can verify connectivity by running a simple `kubectl` command such as `kubectl get namespaces`.

### Troubleshooting: Unreachable VCFA Endpoint

If `vcf context create` fails with a connection timeout or connection refused error, the VCFA endpoint is not reachable from your workstation.

**Expected error:**
```
Error: unable to connect to server: dial tcp <VCFA_ENDPOINT>:443: connect: connection timed out
```

**Remediation steps:**

1. Verify network connectivity to the VCFA endpoint: `ping <VCFA_ENDPOINT>` or `curl -v https://<VCFA_ENDPOINT>`
2. Confirm DNS resolution returns the correct IP address: `nslookup <VCFA_ENDPOINT>`
3. Check that firewall rules allow outbound traffic on port 443 to the VCFA endpoint
4. Verify the endpoint URL is correct — it should be the VCFA appliance hostname, not the vCenter or ESXi host

---

## Phase 2: Topology Discovery and Environment Introspection

Before provisioning any infrastructure resources, you must discover the topology of your VCFA environment. This phase identifies the valid values for regions, zones, resource classes, and VPCs that you will use as parameters in all subsequent provisioning manifests. Skipping this phase will result in validation errors when creating Supervisor Namespaces and VKS clusters.

> **Prerequisite:** Complete Phase 1 (Environment Initialization) before running these commands. Your VCF CLI context must be active and authenticated.

### Step 1: Verify Available API Groups

Start by confirming which API groups are registered in your VCFA environment. This tells you which CCI, VKS, NSX VPC, and Topology APIs are available:

```bash
# List all API resources available in the VCFA environment
# Look for the CCI, Topology, NSX VPC, and Cluster API groups
kubectl api-resources
```

Key API groups to verify in the output:

| API Group | Description |
|---|---|
| `topology.cci.vmware.com` | Region and Zone topology resources |
| `infrastructure.cci.vmware.com` | Supervisor Namespace classes and configurations |
| `project.cci.vmware.com` | Project management resources |
| `authorization.cci.vmware.com` | RBAC and role binding resources |
| `vpc.nsx.vmware.com` | NSX VPC networking resources |
| `cluster.x-k8s.io` | Cluster API resources (visible only after Context Bridge) |

If any expected API group is missing, contact your VCFA administrator to verify the platform version and enabled services.

### Step 2: Discover Available Regions

Query the available Region resources to identify valid `regionName` values for Supervisor Namespace creation:

```bash
# List all regions registered in the VCFA topology
# API: topology.cci.vmware.com/v1alpha2, Kind: Region
# The NAME column provides valid values for the regionName field
# in SupervisorNamespace manifests
kubectl get regions
```

Note the `NAME` value from the output — you will use this as the `<REGION_NAME>` placeholder in Phase 3 and Phase 4.

### Step 3: Discover Available Zones

Query the available Zone resources to identify valid zone names for namespace placement within a region:

```bash
# List all availability zones within the VCFA topology
# API: topology.cci.vmware.com/v1alpha1, Kind: Zone
# Zones represent vSphere clusters or fault domains within a region
kubectl get zones
```

Note the `NAME` value(s) from the output — you will use these as the `<ZONE_NAME>` placeholder in the SupervisorNamespace manifest.

### Step 4: Discover Supervisor Namespace Classes

Query the available SupervisorNamespaceClass resources to identify valid resource class tiers (e.g., `xxlarge`) that determine CPU and memory allocations:

```bash
# List all Supervisor Namespace classes (resource tiers)
# API: infrastructure.cci.vmware.com/v1alpha2, Kind: SupervisorNamespaceClass
# The NAME column provides valid values for the className field
# in SupervisorNamespace manifests
kubectl get svnscls
```

Note the `NAME` value from the output — you will use this as the `<RESOURCE_CLASS>` placeholder in Phase 4.

### Step 5: Discover Available VPCs

Query the available NSX VPC resources to identify valid VPC names for network placement:

```bash
# List all NSX VPCs available in the environment
# API: vpc.nsx.vmware.com/v1alpha1, Kind: VPC
# The NAME column provides valid values for the vpcName field
# in SupervisorNamespace manifests
kubectl get vpcs
```

Note the `NAME` value from the output — you will use this as the `<VPC_NAME>` placeholder in Phase 3 and Phase 4.

### Discovery Summary

After completing this phase, you should have values for the following placeholders:

| Placeholder | Source Command | Used In |
|---|---|---|
| `<REGION_NAME>` | `kubectl get regions` | SupervisorNamespace `spec.regionName` |
| `<ZONE_NAME>` | `kubectl get zones` | SupervisorNamespace `spec.initialClassConfigOverrides.zones[].name` |
| `<RESOURCE_CLASS>` | `kubectl get svnscls` | SupervisorNamespace `spec.className` |
| `<VPC_NAME>` | `kubectl get vpcs` | SupervisorNamespace `spec.vpcName` |

These values are environment-specific and will differ across VCFA deployments. Record them before proceeding to Phase 3.
---

## Phase 3: VPC and Network Provisioning

With topology values in hand from Phase 2, you can now provision the NSX VPC networking layer. This phase establishes network isolation and connectivity policies — the VCF 9 equivalent of configuring an AWS VPC with subnets, route tables, and NAT gateways. The VPC must be created before the Project and Supervisor Namespace in Phase 4, because the namespace manifest references the VPC by name.

> **Prerequisite:** Complete Phase 2 (Topology Discovery) and have valid values for `<REGION_NAME>` and `<VPC_NAME>` before proceeding.

> **Already have a VPC?** If your tenant already has a VPC provisioned (e.g., a default VPC discovered in Phase 2 via `kubectl get vpcs`), you can skip this phase entirely and proceed to Phase 4. Use your existing VPC name in the `vpcName` field of the SupervisorNamespace manifest.

### Understanding the NSX VPC and Supervisor Namespace Relationship

The NSX VPC (`vpc.nsx.vmware.com/v1alpha1`) provides the network isolation boundary for your workloads. When you create the Supervisor Namespace in Phase 4, you will specify a `vpcName` field in the manifest — this is the link between compute (Supervisor Namespace) and networking (NSX VPC).

The `spec.vpcName` field in the SupervisorNamespace resource references an NSX VPC by name. All workloads running in that namespace inherit the VPC's network policies, IP address allocations, and connectivity rules.

### Step 1: Query Available IP Blocks

Before creating a VPC, check the available IP address ranges allocated for VPC networking. IPBlock resources define the CIDR ranges that NSX uses to assign addresses to VPCs and subnets:

```bash
# List all IP blocks available for VPC networking
# API: vpc.nsx.vmware.com/v1alpha1, Kind: IPBlock
# The output shows CIDR ranges and allocation status
kubectl get ipblocks
```

Note the available CIDR ranges — you will reference these when configuring `privateIPs` in the VPC manifest.

### Step 2: Inspect VPC Connectivity Profiles

VPCConnectivityProfile resources define the default connectivity policies applied to VPCs, including external connectivity settings and service gateway configurations:

```bash
# List VPC connectivity profiles to understand default policies
# API: vpc.nsx.vmware.com/v1alpha1, Kind: VPCConnectivityProfile
# These profiles control how VPCs connect to external networks
kubectl get vpcconnectivityprofiles
```

```bash
# Inspect a specific profile for detailed connectivity settings
kubectl get vpcconnectivityprofile <PROFILE_NAME> -o yaml
```

Review the connectivity profile to understand what external access policies are pre-configured before creating your VPC.

### Step 3: Create the VPC

Save the following YAML manifest to a file (e.g., `vpc.yaml`). This creates an NSX VPC with a private IP range and region assignment:

```yaml
# -----------------------------------------------------------
# VPC Resource
# Creates an NSX Virtual Private Cloud for network isolation.
# The VPC defines the private address space and the region
# where the VPC is provisioned.
# API: vpc.nsx.vmware.com/v1alpha1
# -----------------------------------------------------------
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: VPC
metadata:
  # Unique VPC name within the project namespace
  name: <VPC_NAME>
spec:
  # Private IP CIDR blocks allocated to this VPC
  # Must fall within an available IPBlock range (see Step 1)
  privateIPs:
  - "<CIDR>"
  # Region where the VPC is provisioned
  regionName: <REGION_NAME>
  # Enable the NSX load balancer endpoint for this VPC.
  # Required for Supervisor Namespaces that deploy workloads
  # with LoadBalancer Services.
  loadBalancerVPCEndpoint:
    enabled: true
```

Apply the VPC manifest:

```bash
# Create the NSX VPC resource
# --validate=false is required for NSX custom resources
kubectl create -f vpc.yaml --validate=false
```

### Step 4: Associate VPC with a VPC Connectivity Profile

A VPCAttachment associates your VPC with a VPC Connectivity Profile, which defines the connectivity policies for external access, IP block assignments, and Transit Gateway routing. This replaces the need to create a Transit Gateway directly — the connectivity profile manages that relationship for you.

Save the following YAML manifest to a file (e.g., `vpc-attachment.yaml`):

```yaml
# -----------------------------------------------------------
# VPCAttachment Resource
# Associates a VPC with a VPC Connectivity Profile that
# defines external connectivity policies, IP block
# assignments, and Transit Gateway routing.
# API: vpc.nsx.vmware.com/v1alpha1
# -----------------------------------------------------------
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: VPCAttachment
metadata:
  # The name MUST follow the pattern <vpcName>:<attachmentName>.
  # The prefix before the colon must match the VPC name in spec.vpcName.
  name: <VPC_NAME>:<ATTACHMENT_NAME>
spec:
  # Region where the VPC and connectivity profile reside
  regionName: <REGION_NAME>
  # Name of the VPC Connectivity Profile to associate with
  # (see Step 2 for discovering available profiles)
  vpcConnectivityProfileName: <CONNECTIVITY_PROFILE_NAME>
  # Name of the VPC to attach (from Step 3)
  vpcName: <VPC_NAME>
```

Replace the placeholders with your environment-specific values:

| Placeholder | Description | Example |
|---|---|---|
| `<ATTACHMENT_NAME>` | Suffix for this VPC attachment (after the colon) | `my-vpc-attachment` |
| `<REGION_NAME>` | Region from Phase 2 topology discovery | `us-west-1` |
| `<CONNECTIVITY_PROFILE_NAME>` | VPC Connectivity Profile name from Step 2 | `default-connectivity-profile` |
| `<VPC_NAME>` | VPC name from Step 3 | `my-project-vpc` |

Apply the VPCAttachment manifest:

```bash
# Associate the VPC with a VPC Connectivity Profile
kubectl create -f vpc-attachment.yaml --validate=false
```

> **Note:** If you need to associate a provider-provisioned public IP block and a self-created Private-Transit IP block with the Transit Gateway, you can create a new VPC Connectivity Profile rather than using an existing one. See `kubectl get vpcconnectivityprofiles` (Step 2) to inspect available profiles, or create a custom VPCConnectivityProfile resource that references the desired IP blocks and Transit Gateway.

### Step 5: Configure NAT Rules (Optional — Advanced)

> **Note:** A default outbound NAT (SNAT) is automatically created when a VPC is created, unless explicitly disabled during VPC creation. You do not need to create SNAT rules manually unless you require custom outbound translation beyond the default.

> **Note:** Resources deployed with External IP blocks receive public IPs automatically. DNATs are not always needed for those resources — only configure DNAT rules when you need to expose internal workloads that do not already have public IPs.

This step is optional. Most deployments do not require custom NAT rules. Only proceed if your networking design requires explicit SNAT or DNAT configuration beyond the defaults.

VPCNATRule resources define Network Address Translation rules for VPC traffic. Use SNAT for outbound traffic (workloads reaching external networks) and DNAT for inbound traffic (external clients reaching workloads):

**SNAT Rule — Outbound traffic:**

```yaml
# -----------------------------------------------------------
# VPCNATRule Resource — SNAT (Source NAT)
# Translates outbound traffic from internal workloads to an
# external IP address. Use this when workloads need to reach
# external services or the internet.
# API: vpc.nsx.vmware.com/v1alpha1
# -----------------------------------------------------------
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: VPCNATRule
metadata:
  # Descriptive name for the SNAT rule
  name: <SNAT_RULE_NAME>
  # Must match the Project name from Phase 4
  namespace: <PROJECT_NAME>
spec:
  # SNAT = Source NAT for outbound traffic translation
  action: SNAT
  # External IP address that outbound traffic is translated to
  translatedNetwork: "<EXTERNAL_IP>"
  # Internal CIDR range whose traffic will be translated
  sourceNetwork: "<INTERNAL_CIDR>"
```

**DNAT Rule — Inbound traffic:**

```yaml
# -----------------------------------------------------------
# VPCNATRule Resource — DNAT (Destination NAT)
# Translates inbound traffic from an external IP to an
# internal workload address. Use this when external clients
# need to reach services inside the VPC.
# API: vpc.nsx.vmware.com/v1alpha1
# -----------------------------------------------------------
apiVersion: vpc.nsx.vmware.com/v1alpha1
kind: VPCNATRule
metadata:
  # Descriptive name for the DNAT rule
  name: <DNAT_RULE_NAME>
  # Must match the Project name from Phase 4
  namespace: <PROJECT_NAME>
spec:
  # DNAT = Destination NAT for inbound traffic translation
  action: DNAT
  # Internal IP address that inbound traffic is forwarded to
  translatedNetwork: "<INTERNAL_IP>"
  # External IP/CIDR that triggers the translation
  sourceNetwork: "<EXTERNAL_CIDR>"
```

Apply the NAT rules:

```bash
# Create SNAT rule for outbound connectivity
kubectl create -f snat-rule.yaml --validate=false

# Create DNAT rule for inbound connectivity
kubectl create -f dnat-rule.yaml --validate=false
```

### Verify Network Resources

After creating all network resources, verify their status:

```bash
# Verify VPC creation
kubectl get vpcs -n <PROJECT_NAME>

# Verify VPC Attachment
kubectl get vpcattachments -n <PROJECT_NAME>

# Verify NAT rules
kubectl get vpcnatrules -n <PROJECT_NAME>
```

### Troubleshooting: IP Address Exhaustion

If VPC creation fails or subnets cannot be allocated, the IP address pool may be exhausted. NSX tracks IP usage through dedicated status resources.

**Expected symptoms:**
- VPC creation fails with an IP allocation error
- New subnets within the VPC cannot be provisioned
- Workload pods fail to receive IP addresses

**Remediation steps:**

1. Check IP block usage to identify exhausted ranges:

```bash
# View IP block allocation details (CIDR ranges, sizes, and status)
kubectl get ipblocks -o wide

# For detailed allocation status of a specific IP block:
kubectl describe ipblock <IPBLOCK_NAME>
```

2. If IP blocks are exhausted:
   - Request additional IPBlock resources from your NSX administrator
   - Consider reducing `defaultSubnetSize` in the VPC spec to allocate smaller subnets
   - Review and reclaim unused VPCs or subnets that are no longer needed

3. If the VPC has available capacity but pods still lack IPs, check the subnet allocation within the VPC and verify that the `privateIPs` range is large enough for your workload count


---

## Phase 4: Project and Namespace Provisioning

With the VPC and networking layer established in Phase 3, you can now create the foundational VCF 9 resources: a Project for governance and RBAC, a ProjectRoleBinding for user access, and a Supervisor Namespace for compute and network isolation. The Supervisor Namespace references the VPC by name, which is why VPC provisioning must be completed first.

> **Prerequisite:** Complete Phase 2 (Topology Discovery) and Phase 3 (VPC and Network Provisioning). Have valid values for `<REGION_NAME>`, `<ZONE_NAME>`, `<RESOURCE_CLASS>`, and `<VPC_NAME>` before proceeding.

### Step 1: Create the Project, RBAC Binding, and Supervisor Namespace

Save the following multi-document YAML manifest to a file (e.g., `project-namespace.yaml`). It creates all three resources in a single apply:

```yaml
# -----------------------------------------------------------
# Resource 1: Project
# Creates a logical governance boundary in VCFA for resource
# ownership, RBAC, and namespace scoping.
# API: project.cci.vmware.com/v1alpha2
# -----------------------------------------------------------
apiVersion: project.cci.vmware.com/v1alpha2
kind: Project
metadata:
  # Unique project name — must not conflict with existing projects
  name: <PROJECT_NAME>
spec:
  # Human-readable description of the project's purpose
  description: "<PROJECT_DESCRIPTION>"
---
# -----------------------------------------------------------
# Resource 2: ProjectRoleBinding
# Grants a user admin access to the project. The metadata.name
# follows the convention cci:user:<username>.
# API: authorization.cci.vmware.com/v1alpha1
# -----------------------------------------------------------
apiVersion: authorization.cci.vmware.com/v1alpha1
kind: ProjectRoleBinding
metadata:
  # Naming convention: cci:user:<sso-username>
  name: "cci:user:<USER_IDENTITY>"
  # Must match the Project name created above
  namespace: <PROJECT_NAME>
roleRef:
  apiGroup: authorization.cci.vmware.com
  kind: ProjectRole
  # Role options: admin, edit, or view
  name: admin
subjects:
- kind: User
  # SSO user identity to grant access to
  name: <USER_IDENTITY>
---
# -----------------------------------------------------------
# Resource 3: SupervisorNamespace
# Provisions a vSphere Supervisor Namespace with compute,
# storage, and network resources scoped to the project.
# Uses generateName so VCF appends a 5-character random suffix
# to produce the final namespace name (Dynamic_Namespace_Name).
# API: infrastructure.cci.vmware.com/v1alpha2
# -----------------------------------------------------------
apiVersion: infrastructure.cci.vmware.com/v1alpha2
kind: SupervisorNamespace
metadata:
  # generateName prefix — VCF appends a random 5-char suffix
  # Example: "myproject-ns-" becomes "myproject-ns-frywy"
  generateName: <NAMESPACE_PREFIX>
  # Parent project that owns this namespace
  namespace: <PROJECT_NAME>
spec:
  # Human-readable description of the namespace
  description: "<NAMESPACE_DESCRIPTION>"
  # Region from Phase 2 topology discovery (kubectl get regions)
  regionName: "<REGION_NAME>"
  # Supervisor Namespace class from Phase 2 (kubectl get svnscls)
  className: "<RESOURCE_CLASS>"
  # NSX VPC for network placement — use the VPC created in Phase 3 or an existing VPC from Phase 2 (kubectl get vpcs)
  vpcName: "<VPC_NAME>"
  # Zone-specific resource limits and reservations
  initialClassConfigOverrides:
    zones:
    - # Availability zone from Phase 2 (kubectl get zones)
      name: "<ZONE_NAME>"
      # CPU limit in millicores (e.g., "100000M" = 100 vCPUs)
      cpuLimit: "<CPU_LIMIT>"
      cpuReservation: "0M"
      # Memory limit (e.g., "102400Mi" = 100 GiB)
      memoryLimit: "<MEM_LIMIT>"
      memoryReservation: "0Mi"
```

### Step 2: Apply the Manifest

Use `kubectl create` with the `--validate=false` flag. CCI custom resources use server-side schemas that are not available locally, so client-side validation must be bypassed:

```bash
# Create the Project, ProjectRoleBinding, and SupervisorNamespace
# --validate=false is required because CCI custom resource schemas
# are not available for local kubectl validation
kubectl create -f project-namespace.yaml --validate=false
```

### Understanding `generateName` and Dynamic Namespace Names

The SupervisorNamespace manifest uses `generateName` instead of `name` in its metadata. When VCF processes this resource, it appends a random 5-character alphanumeric suffix to the prefix you provide.

For example, if you set `generateName: myproject-ns-`, the resulting namespace name will be something like `myproject-ns-frywy`. This dynamically generated name (the Dynamic Namespace Name) is what you will need in Phase 5 (Context Bridge) to switch into the namespace-scoped context.

To retrieve the generated name after creation:

```bash
# List Supervisor Namespaces in the project to find the generated name
kubectl get supervisornamespaces -n <PROJECT_NAME>
```

The `NAME` column in the output shows the full Dynamic Namespace Name including the random suffix.

### Troubleshooting: Project Naming Conflict

If `kubectl create` returns an `AlreadyExists` error for the Project resource, another project with the same name already exists in the VCFA environment.

**Expected error:**
```
Error from server (AlreadyExists): projects.project.cci.vmware.com "<PROJECT_NAME>" already exists
```

**Remediation steps:**

1. List existing projects to confirm the conflict: `kubectl get projects`
2. Choose a unique project name that does not collide with any existing project
3. Update the `metadata.name` in the Project manifest and the `metadata.namespace` in both the ProjectRoleBinding and SupervisorNamespace manifests to match the new name
4. Re-run the `kubectl create` command


---

## Phase 5: Context Bridge Execution

The Context Bridge is the critical step that separates VCF 9 from other Kubernetes platforms. After provisioning your Project, Namespace, and VPC resources in the previous phases, you are still operating in a **global (org-level) context**. From this scope, the VCF CLI and `kubectl` can manage CCI resources like Projects, Namespaces, VPCs, and topology — but **Cluster API resources are completely invisible**.

To deploy VKS clusters, you must switch to a **namespace-scoped context** that targets the specific Supervisor Namespace you created in Phase 4. This context switch — the Context Bridge — makes the `cluster.x-k8s.io` API group visible and allows you to create and manage VKS cluster resources.

> **This phase is mandatory.** You cannot skip the Context Bridge and proceed directly to VKS cluster deployment. Without it, `kubectl` cannot see or interact with Cluster API resources.

> **Prerequisite:** Complete Phase 3 (VPC and Network Provisioning) and Phase 4 (Project and Namespace Provisioning). You need your `<CONTEXT_NAME>`, `<PROJECT_NAME>`, and the Dynamic Namespace Name generated in Phase 4.

### Step 1: Identify the Dynamic Namespace Name

The Supervisor Namespace you created in Phase 4 used `generateName`, which means VCF appended a random 5-character suffix to your prefix. You need the exact generated name to complete the Context Bridge. Retrieve it directly with `kubectl`:

```bash
# List Supervisor Namespaces in the project to find the generated name
# The NAME column shows the full Dynamic Namespace Name including the suffix
kubectl get supervisornamespaces -n <PROJECT_NAME>
```

Example output:

```
NAME                             STATUS    REGION         CLASS    VPC                        AGE
sample-vcf-project-01-ns-z8d9t   Created   region-us1-a   medium   region-us1-a-default-vpc   91s
```

The `NAME` value (e.g., `sample-vcf-project-01-ns-z8d9t`) is your `<GENERATED_NS_NAME>` — record this for the next step.

### Step 2: Re-register the CLI Context to Discover the New Namespace

After creating a new Supervisor Namespace, the VCF CLI's local context cache does not automatically discover it. The `vcf context refresh` command will NOT work for this — it only checks token validity and skips namespace re-enumeration when the token is still active.

The reliable method is to **delete and recreate the context**, which forces a full login and namespace enumeration:

```bash
# Delete the existing context (this removes all cached namespace contexts)
vcf context delete <CONTEXT_NAME> --yes

# Recreate the context — this performs a full login and discovers all namespaces
# including the newly created Supervisor Namespace
vcf context create <CONTEXT_NAME> \
  --endpoint https://<VCFA_ENDPOINT> \
  --type cci \
  --tenant-name <TENANT_NAME> \
  --api-token <API_TOKEN> \
  --set-current
```

In the output, verify that the three-part context name for your new namespace appears in the list (e.g., `vcf-samples-test:sample-vcf-project-01-ns-z8d9t:sample-vcf-project-01`).

> **Why not `vcf context refresh`?** When the API token is still valid, `vcf context refresh` reports "Token is still active. Skipped the token refresh" and does not re-enumerate namespaces. Attempting `vcf context use` with a three-part name that hasn't been discovered will fail with "context not found". The delete + recreate approach is the only reliable method to pick up newly created namespaces.

### Step 3: Switch to Namespace-Scoped Context

Use the `vcf context use` command with the three-part format to switch from global scope to namespace scope. This is the actual Context Bridge:

```bash
# Switch to namespace-scoped context using the three-part format:
#   <CONTEXT_NAME>      — the CLI context created above
#   <GENERATED_NS_NAME> — the dynamic namespace name from Step 1
#   <PROJECT_NAME>      — the project name from Phase 4
# This makes Cluster API resources (cluster.x-k8s.io) visible
vcf context use <CONTEXT_NAME>:<GENERATED_NS_NAME>:<PROJECT_NAME>
```

After running this command, your `kubectl` session is scoped to the Supervisor Namespace. You can now see and manage Cluster API resources that were previously invisible.

### Verify the Context Bridge

Confirm that the Context Bridge was successful by checking for Cluster API resources:

```bash
# Verify that Cluster API resources are now visible
# This command should return a valid (possibly empty) table
# rather than an error about unknown resource types
kubectl get clusters
```

If the command returns an empty table (e.g., `No resources found in <GENERATED_NS_NAME> namespace.`), the Context Bridge is working correctly — you simply haven't deployed a cluster yet. You are now ready to proceed to Phase 6.

### Troubleshooting: VKS Deployment Without Context Bridge

If you attempt to deploy a VKS cluster without completing the Context Bridge, `kubectl` will not recognize Cluster API resources because they are not visible from the global context scope.

**Expected errors:**

```
error: the server doesn't have a resource type "clusters"
```

or:

```
No resources found
```

When running `kubectl get clusters` or `kubectl apply -f cluster.yaml`, the global context does not expose the `cluster.x-k8s.io` API group. The Cluster API is only registered within the Supervisor Namespace scope.

**Remediation steps:**

1. Verify your current context scope — if you see CCI resources (Projects, Namespaces) but not Cluster resources, you are still in global scope
2. Run `kubectl get supervisornamespaces -n <PROJECT_NAME>` to get the exact generated namespace name
3. Delete and recreate the context to force namespace re-enumeration: `vcf context delete <CONTEXT_NAME> --yes` then `vcf context create <CONTEXT_NAME> --endpoint ... --type cci --tenant-name ... --api-token ... --set-current`
4. Run `vcf context use <CONTEXT_NAME>:<GENERATED_NS_NAME>:<PROJECT_NAME>` to switch to namespace scope
5. Retry the cluster operation — `kubectl get clusters` should now return a valid response


---

## Phase 6: VKS Cluster Deployment

With the Context Bridge completed in Phase 5, your `kubectl` session is now scoped to the Supervisor Namespace and the `cluster.x-k8s.io` API group is visible. You can now deploy a VKS (vSphere Kubernetes Service) cluster using a declarative Cluster API manifest — the VCF 9 equivalent of provisioning an EKS cluster on AWS.

> **Prerequisite:** Complete Phase 5 (Context Bridge Execution). You must be in a namespace-scoped context targeting your `<GENERATED_NS_NAME>`. If `kubectl get clusters` returns an error about unknown resource types, go back to Phase 5 and complete the Context Bridge.

### Step 1: Prepare the VKS Cluster Manifest

Save the following YAML manifest to a file (e.g., `vks-cluster.yaml`). This creates a VKS cluster with a single control plane node and an autoscaling worker node pool:

> **Important:** Update the `metadata.namespace` field to match the exact `<GENERATED_NS_NAME>` from Phase 5 (Context Bridge). This is the Dynamic Namespace Name that VCF generated with the random 5-character suffix (e.g., `myproject-ns-frywy`). The cluster must be created in this namespace — using any other namespace will fail.

```yaml
# -----------------------------------------------------------
# VKS Cluster Resource
# Deploys a managed Kubernetes cluster via the Cluster API.
# VKS uses a topology-based approach where the cluster class
# defines the infrastructure blueprint and you customize it
# with variables and overrides.
# API: cluster.x-k8s.io/v1beta1
# -----------------------------------------------------------
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  # Unique cluster name within the Supervisor Namespace
  name: <CLUSTER_NAME>
  # MUST be the Dynamic_Namespace_Name from Phase 5 Context Bridge
  # This is the generateName result with the 5-char suffix
  # (e.g., "myproject-ns-frywy") — NOT the prefix you specified
  namespace: <GENERATED_NS_NAME>
spec:
  # -----------------------------------------------------------
  # Cluster Network Configuration
  # Defines the internal IP address ranges for Kubernetes
  # services and pods. These CIDRs must not overlap with your
  # VPC private CIDRs or each other.
  # -----------------------------------------------------------
  clusterNetwork:
    services:
      # CIDR block for Kubernetes ClusterIP services
      # Default: 10.96.0.0/12 provides ~1M service IPs
      cidrBlocks:
      - "<SERVICES_CIDR>"
    pods:
      # CIDR block for pod networking
      # Must be large enough for all pods across all nodes
      cidrBlocks:
      - "<PODS_CIDR>"
    # Kubernetes DNS domain — standard default is cluster.local
    serviceDomain: cluster.local
  # -----------------------------------------------------------
  # Topology Configuration
  # Defines the cluster blueprint (class), Kubernetes version,
  # control plane settings, and worker node pools.
  # -----------------------------------------------------------
  topology:
    # VKS built-in cluster class — defines the infrastructure
    # blueprint including VM templates, networking, and storage
    class: builtin-generic-v3.4.0
    # Namespace where the cluster class is published
    # This is a system namespace managed by VKS
    classNamespace: vmware-system-vks-public
    # Target Kubernetes version for the cluster
    # Must match an available vSphere Kubernetes Release (TKR)
    # Check available versions: kubectl get tkr
    version: <K8S_VERSION>
    # -----------------------------------------------------------
    # Control Plane Configuration
    # Defines the control plane node count and OS image settings.
    # VKS manages the control plane lifecycle automatically.
    # -----------------------------------------------------------
    controlPlane:
      metadata:
        annotations:
          # OS image resolution annotation — tells VKS how to
          # find the VM template for control plane nodes
          # os-name: the OS distribution (e.g., photon)
          # content-library: vSphere content library ID containing
          # the OS image templates
          run.tanzu.vmware.com/resolve-os-image: "os-name=photon, content-library=<CONTENT_LIBRARY_ID>"
      # Number of control plane replicas (1 for dev, 3 for HA)
      replicas: 1
    # -----------------------------------------------------------
    # Worker Node Configuration
    # Defines machine deployment pools with autoscaler settings.
    # Each pool can have different VM classes and scaling limits.
    # -----------------------------------------------------------
    workers:
      machineDeployments:
      - class: node-pool
        # Name for this worker node pool
        name: node-pool-01
        metadata:
          annotations:
            # OS image resolution — same as control plane
            run.tanzu.vmware.com/resolve-os-image: "os-name=photon, content-library=<CONTENT_LIBRARY_ID>"
            # Cluster autoscaler annotations — control automatic
            # scaling of worker nodes based on resource demand
            # max-size: upper bound on node count for this pool
            cluster.x-k8s.io/cluster-api-autoscaler-node-group-max-size: "<MAX_NODES>"
            # min-size: lower bound on node count for this pool
            cluster.x-k8s.io/cluster-api-autoscaler-node-group-min-size: "<MIN_NODES>"
    # -----------------------------------------------------------
    # Cluster Variables
    # Override default values from the cluster class.
    # vmClass controls the VM size, storageClass controls
    # persistent volume provisioning.
    # -----------------------------------------------------------
    variables:
    - name: vmClass
      # VM class for worker nodes — determines CPU and memory
      # allocation per node (e.g., "best-effort-large")
      value: <VM_CLASS>
    - name: storageClass
      # Storage class for persistent volumes on the cluster
      # (e.g., "nfs" for NFS-backed storage)
      value: <STORAGE_CLASS>
    - name: volumes
      # Additional disks attached to worker node VMs.
      # A dedicated containerd volume prevents disk-pressure
      # evictions when running image-heavy workloads such as
      # GitLab, Harbor, and ArgoCD.
      value:
      - name: containerd-data
        capacity: 100Gi
        mountPath: /var/lib/containerd
        storageClass: <STORAGE_CLASS>
```

Replace the placeholders with your environment-specific values:

| Placeholder | Description | Example |
|---|---|---|
| `<CLUSTER_NAME>` | Unique name for the VKS cluster | `myproject-clus-01` |
| `<GENERATED_NS_NAME>` | Dynamic Namespace Name from Phase 5 | `myproject-ns-frywy` |
| `<SERVICES_CIDR>` | CIDR block for Kubernetes services | `10.96.0.0/12` |
| `<PODS_CIDR>` | CIDR block for pod networking | `192.168.156.0/20` |
| `<K8S_VERSION>` | Target Kubernetes version | `v1.33.6+vmware.1-fips` |
| `<CONTENT_LIBRARY_ID>` | vSphere content library ID for OS images | (UUID from vSphere) |
| `<MAX_NODES>` | Autoscaler maximum node count | `10` |
| `<MIN_NODES>` | Autoscaler minimum node count | `3` |
| `<VM_CLASS>` | VM class for worker nodes | `best-effort-large` |
| `<STORAGE_CLASS>` | Storage class for persistent volumes | `nfs` |

#### How to Obtain the Content Library ID

The `<CONTENT_LIBRARY_ID>` is a vSphere-level resource identifier that points to the content library containing vSphere Kubernetes node OS images. The ID is typically a UUID-like string (e.g., `cl-32ee3681364c701d0`). You can find it using either of the following methods:

**Method 1: kubectl CLI**

There are two types of content libraries. Project-scoped content libraries are visible with `kubectl get contentlibraries`, and cluster-scoped content libraries (typically the Kubernetes Service Content Library containing OS images) are visible with `kubectl get clustercontentlibraries`. Check both:

```bash
# List project-scoped content libraries (Local libraries)
kubectl get contentlibraries

# List cluster-scoped content libraries (Subscribed libraries with OS images)
# The Kubernetes Service Content Library typically appears here
kubectl get clustercontentlibraries
```

Example output:

```
# kubectl get contentlibraries
NAME                   VSPHERENAME            TYPE    WRITABLE   ALLOWIMPORT   STORAGETYPE   AGE
cl-97acf13b5e2909643   local-content-lib-01   Local   false      false         Datastore     35m

# kubectl get clustercontentlibraries
NAME                   VSPHERENAME                          TYPE         STORAGETYPE   AGE
cl-32ee3681364c701d0   Kubernetes Service Content Library   Subscribed   Datastore     13d
```

The `NAME` column contains the Content Library ID. For VKS cluster creation, use the ID from the library that contains the vSphere Kubernetes node OS images — this is typically the **Subscribed** library listed by `kubectl get clustercontentlibraries` (e.g., `cl-32ee3681364c701d0`).

**Method 2: VCFA Portal (UI)**

1. Log in to the VCFA portal at `https://<VCFA_ENDPOINT>`
2. Navigate to **Build & Deploy** → **Services** → **Virtual Machine Image**
3. Click the **Content Libraries** tab (next to "Virtual Machine Images")
4. The table shows both Local and Subscribed libraries — click the library that contains the vSphere Kubernetes node OS images (e.g., "Kubernetes Service Content Library", Type: Subscribed)
5. Click the **VIEW YAML** link next to the library name
6. In the YAML view, find the `metadata.name` field (line 13) — this is the Content Library ID (e.g., `cl-32ee3681364c701d0`)

> **Note:** The Content Library ID is not visible in the browser URL. You must use the VIEW YAML link to find it.

### Step 2: Apply the VKS Cluster Manifest

Use `kubectl apply` with both `--validate=false` and `--insecure-skip-tls-verify` flags. The Cluster API custom resource schemas are not available for local validation, and the Supervisor API server may use a certificate that is not in your local trust store:

```bash
# Deploy the VKS cluster
# --validate=false: bypass local schema validation for Cluster API CRDs
# --insecure-skip-tls-verify: skip TLS certificate verification for
#   the Supervisor API server (required in many VCFA environments)
kubectl apply -f vks-cluster.yaml --validate=false --insecure-skip-tls-verify
```

### Step 3: Monitor Cluster Provisioning

VKS cluster provisioning takes several minutes as VCF creates the control plane VM, bootstraps Kubernetes, and provisions worker node VMs. Use the following commands to monitor progress:

**Check cluster status:**

```bash
# List all clusters in the current namespace
# STATUS column shows provisioning progress
# PHASE column transitions: Provisioning → Provisioned
kubectl get clusters -w
```

**Watch VM provisioning in real time:**

```bash
# Watch VirtualMachine resources as they are created and powered on
# You should see control plane and worker VMs appear and transition
# through phases: Creating → Powered On → Running
# Press Ctrl+C to stop watching
kubectl get virtualmachines -w
```

The cluster is ready when `kubectl get clusters` shows the `PHASE` as `Provisioned` and all VirtualMachines are in the `Running` state. At that point, you can proceed to Phase 7 to download the kubeconfig and run functional validation workloads.


---

## Phase 7: Functional Validation

With the VKS cluster provisioned in Phase 6, you need to validate that storage provisioning, pod scheduling, and network ingress are all operational before migrating production workloads. This phase deploys a lightweight test workload that exercises each of these capabilities and confirms the cluster is production-ready.

> **Prerequisite:** Complete Phase 6 (VKS Cluster Deployment). The cluster must be in `Provisioned` state with all VirtualMachines running. You also need the VKS cluster kubeconfig to target the guest cluster (not the Supervisor).

### Step 1: Obtain the VKS Cluster Kubeconfig

Before deploying workloads to the VKS cluster, you need a kubeconfig that targets the guest cluster's API server. There are three methods to obtain it, listed from simplest to most advanced.

**Option A: VCF CLI (Simplest)**

The fastest way to retrieve a VKS cluster kubeconfig is with the VCF CLI. The `--export-file` flag saves the kubeconfig to a standalone file that works on any OS.

**Windows (PowerShell):**

```powershell
# Download the admin kubeconfig to a file
vcf cluster kubeconfig get <CLUSTER_NAME> --admin --export-file "$env:USERPROFILE\kubeconfig-<CLUSTER_NAME>.yaml"

# Set the KUBECONFIG environment variable for this session
$env:KUBECONFIG = "$env:USERPROFILE\kubeconfig-<CLUSTER_NAME>.yaml"
```

**Linux / macOS (Bash):**

```bash
# Download the admin kubeconfig to a file
vcf cluster kubeconfig get <CLUSTER_NAME> --admin --export-file ~/kubeconfig-<CLUSTER_NAME>.yaml

# Set the KUBECONFIG environment variable for this session
export KUBECONFIG=~/kubeconfig-<CLUSTER_NAME>.yaml
```

> **Note:** The `--admin` flag provides admin-level credentials. Omit it for standard user credentials. Without `--export-file`, the command merges the context into your default `~/.kube/config` file instead of creating a standalone file.

Verify connectivity to the VKS guest cluster:

```bash
# Confirm kubectl is targeting the VKS guest cluster
# You should see the guest cluster's system namespaces (kube-system, etc.)
kubectl get namespaces
```

**Option B: Download from the VCFA Portal (UI)**

1. Log in to the VCFA portal at `https://<VCFA_ENDPOINT>`
2. Navigate to your Project and locate the VKS cluster under the Kubernetes Clusters section
3. Click the cluster name and select **Download Kubeconfig** from the actions menu
4. Save the kubeconfig file to your workstation

Set the `KUBECONFIG` environment variable to point to the downloaded file:

**Windows (PowerShell):**

```powershell
$env:KUBECONFIG = "C:\Users\<USERNAME>\Downloads\<CLUSTER_NAME>-kubeconfig.yaml"
```

**Linux / macOS (Bash):**

```bash
export KUBECONFIG=~/Downloads/<CLUSTER_NAME>-kubeconfig.yaml
```

Verify connectivity to the VKS guest cluster:

```bash
# Confirm kubectl is targeting the VKS guest cluster
# You should see the guest cluster's system namespaces (kube-system, etc.)
kubectl get namespaces
```

**Option C: Programmatic Kubeconfig via VksCredentialRequest**

As an alternative to the portal UI, you can programmatically retrieve the kubeconfig by creating a VksCredentialRequest resource. This is useful for CI/CD pipelines and automation workflows where portal access is not practical.

> **Note:** This command must be run from the **Supervisor namespace-scoped context** (the Context Bridge context from Phase 5), not from the VKS guest cluster context.

```yaml
# -----------------------------------------------------------
# VksCredentialRequest Resource
# Programmatically retrieves kubeconfig credentials for a VKS
# cluster without using the VCFA portal UI. The resulting
# credential is stored in the resource's status field.
# API: infrastructure.cci.vmware.com/v1alpha1
# -----------------------------------------------------------
apiVersion: infrastructure.cci.vmware.com/v1alpha1
kind: VksCredentialRequest
metadata:
  # Convention: <cluster-name>-creds
  name: <CLUSTER_NAME>-creds
  # Must be the Dynamic_Namespace_Name from Phase 5
  namespace: <GENERATED_NS_NAME>
spec:
  # Name of the VKS cluster to retrieve credentials for
  clusterName: <CLUSTER_NAME>
```

Apply the VksCredentialRequest from the Supervisor context:

```bash
# Create the credential request (run from Supervisor context, not guest cluster)
kubectl create -f vks-cred-request.yaml --validate=false
```

After the request is processed, retrieve the kubeconfig from the resource's status:

```bash
# Extract the kubeconfig from the VksCredentialRequest status
kubectl get vkscredentialrequest <CLUSTER_NAME>-creds \
  -n <GENERATED_NS_NAME> -o jsonpath='{.status.kubeconfig}' > <KUBECONFIG_PATH>

# Set the KUBECONFIG environment variable
export KUBECONFIG=<KUBECONFIG_PATH>
```

### Step 2: Deploy Test Workloads

Save the following multi-document YAML manifest to a file (e.g., `functional-test.yaml`). It creates three resources that validate storage, compute, and networking on the VKS cluster:

```yaml
# -----------------------------------------------------------
# Resource 1: PersistentVolumeClaim
# Validates dynamic volume provisioning on the VKS cluster.
# Requests a 1Gi volume using the NFS storage class to confirm
# the CSI driver and storage backend are operational.
# API: v1
# -----------------------------------------------------------
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  # Test PVC name — can be any unique name in the namespace
  name: vks-test-pvc
spec:
  # ReadWriteOnce — volume can be mounted read-write by a single node
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      # Request a small 1Gi volume for validation purposes
      storage: 1Gi
  # Storage class for dynamic provisioning
  # Must match an available storage class on the VKS cluster
  # (e.g., "nfs" for NFS-backed storage)
  storageClassName: <STORAGE_CLASS>
---
# -----------------------------------------------------------
# Resource 2: Deployment
# Validates pod scheduling with security best practices.
# Runs an nginx-unprivileged container with a hardened security
# context: non-root user, seccomp profile, and all Linux
# capabilities dropped. This confirms the cluster enforces
# Pod Security Standards correctly.
#
# Note: The deploy-cluster.sh script uses a custom image
# (scafeman/vks-test-app:latest) with HTML content instead.
# This sample uses the upstream nginx-unprivileged image for
# standalone use without a custom registry.
# API: apps/v1
# -----------------------------------------------------------
apiVersion: apps/v1
kind: Deployment
metadata:
  # Test deployment name
  name: vks-test-app
spec:
  # Single replica is sufficient for validation
  replicas: 1
  selector:
    matchLabels:
      app: vks-test-app
  template:
    metadata:
      labels:
        app: vks-test-app
    spec:
      # -----------------------------------------------------------
      # Pod-level security context
      # Enforces security best practices at the pod level
      # -----------------------------------------------------------
      securityContext:
        # Seccomp profile restricts system calls the container can make
        # RuntimeDefault uses the container runtime's default profile
        seccompProfile:
          type: RuntimeDefault
        # Prevent any container from running as root (UID 0)
        runAsNonRoot: true
        # Run all containers as UID 101 (nginx user in unprivileged image)
        runAsUser: 101
        # Set filesystem group to 101 for volume mount permissions
        fsGroup: 101
      containers:
      - name: nginx
        # nginx-unprivileged listens on port 8080 instead of 80
        # and does not require root privileges to start
        image: nginxinc/nginx-unprivileged:latest
        # -----------------------------------------------------------
        # Container-level security context
        # Further restricts the container's privileges
        # -----------------------------------------------------------
        securityContext:
          # Prevent privilege escalation via setuid/setgid binaries
          allowPrivilegeEscalation: false
          capabilities:
            # Drop ALL Linux capabilities — the container runs with
            # no special kernel privileges
            drop:
            - ALL
        ports:
          # nginx-unprivileged serves HTTP on port 8080
        - containerPort: 8080
---
# -----------------------------------------------------------
# Resource 3: LoadBalancer Service
# Validates NSX-based network ingress by requesting an external
# IP address. NSX provisions a load balancer that routes
# external traffic on port 80 to the nginx container on 8080.
# API: v1
# -----------------------------------------------------------
apiVersion: v1
kind: Service
metadata:
  # Test LoadBalancer service name
  name: vks-test-lb
spec:
  # LoadBalancer type requests an external IP from NSX
  type: LoadBalancer
  ports:
    # External port 80 maps to container targetPort 8080
  - port: 80
    targetPort: 8080
  # Route traffic to pods matching the test deployment labels
  selector:
    app: vks-test-app
```

Apply the test workloads:

```bash
# Deploy the PVC, Deployment, and LoadBalancer Service
kubectl apply -f functional-test.yaml
```

### Step 3: Verify Test Results

Run the following commands to confirm each component is working correctly.

**Verify PVC binding:**

```bash
# Check that the PVC transitions from Pending to Bound
# STATUS should show "Bound" once the storage class provisions the volume
kubectl get pvc
```

The `STATUS` column should show `Bound`. If it remains in `Pending`, see the troubleshooting section below.

**Verify LoadBalancer external IP:**

```bash
# Watch the Service until an external IP is assigned by NSX
# The EXTERNAL-IP column will transition from <pending> to an IP address
# Press Ctrl+C once the IP appears
kubectl get svc -w
```

Wait until the `EXTERNAL-IP` column shows an IP address instead of `<pending>`.

**Test HTTP connectivity:**

```bash
# Send an HTTP request to the LoadBalancer external IP
# You should receive the default nginx welcome page (HTTP 200)
# Replace <EXTERNAL_IP> with the IP from the previous command
curl http://<EXTERNAL_IP>
```

A successful response (the nginx welcome page HTML) confirms that storage provisioning, pod scheduling, security context enforcement, and NSX load balancer ingress are all operational. The VKS cluster is production-ready.

### Troubleshooting: PVC Stuck in Pending State

If the PVC remains in `Pending` status and does not transition to `Bound`, the storage class may be misconfigured or the CSI driver may not be operational.

**Expected symptom:**

```
NAME           STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   AGE
vks-test-pvc   Pending                                      nfs            5m
```

**Remediation steps:**

1. Verify the storage class exists on the VKS cluster:

```bash
# List available storage classes — confirm your <STORAGE_CLASS> is present
kubectl get sc
```

2. If the storage class is missing, check that the CSI driver pods are running:

```bash
# Check CSI driver pods in the vmware-system-csi namespace
kubectl get pods -n vmware-system-csi
```

3. Describe the PVC to see the specific provisioning error:

```bash
# View detailed PVC status and events for error messages
kubectl describe pvc vks-test-pvc
```

4. Common causes:
   - The `storageClassName` in the PVC does not match any available storage class — update the manifest with a valid class name from `kubectl get sc`
   - The NFS provisioner is not deployed or is unhealthy — check CSI driver pod logs
   - The underlying storage backend (NFS server, vSAN) is unreachable — verify network connectivity from the cluster nodes

### Troubleshooting: LoadBalancer Service Has No External IP

If the Service remains in `<pending>` state for the `EXTERNAL-IP` and does not receive an IP address, NSX load balancer provisioning may have failed.

**Expected symptom:**

```
NAME          TYPE           CLUSTER-IP     EXTERNAL-IP   PORT(S)        AGE
vks-test-lb   LoadBalancer   10.96.45.123   <pending>     80:31234/TCP   10m
```

**Remediation steps:**

1. **Primary check — verify the Service directly from the VKS guest cluster context:**

```bash
# List Services and check the EXTERNAL-IP column
# This is the most reliable way to confirm LoadBalancer functionality
# The EXTERNAL-IP column should show an IP address (not <pending>)
kubectl get svc
```

This is the primary verification method. If the `EXTERNAL-IP` column shows an assigned IP address, the LoadBalancer is working correctly regardless of what other commands report.

2. **(Advanced) Check NSX native LoadBalancer resources from the Supervisor context:**

> **Note:** The command `kubectl get loadbalancers -A` queries NSX native LoadBalancer resources (`vpc.nsx.vmware.com/v1alpha1`) at the Supervisor level. This command is only available from the Supervisor context (not the VKS guest cluster context) and **may return empty results** in a test cluster — this does not necessarily indicate a problem. NSX provisions load balancers transparently when a `Service` of type `LoadBalancer` is created, and the native resources may not be visible from the guest cluster. Use `kubectl get svc` (step 1 above) as the authoritative check.

```bash
# (Supervisor context only) List NSX native LoadBalancer resources
# Switch to the Supervisor context from Phase 5 if needed
# Empty results are normal in many VKS guest cluster environments
kubectl get loadbalancers -A
```

3. Verify the NSX Edge cluster has available capacity for new load balancers — contact your NSX administrator if the Edge cluster is at capacity

4. Check that the VPC NAT rules and connectivity profiles allow external traffic — review the VPCNATRule and VPCConnectivityProfile resources from Phase 3

5. Describe the Service to see events and error messages:

```bash
# View detailed Service status and events
kubectl describe svc vks-test-lb
```

6. Common causes:
   - NSX Edge cluster has no available capacity for new load balancers — request capacity expansion from the NSX administrator
   - VPC connectivity profile does not allow external IP allocation — verify the VPCConnectivityProfile permits LoadBalancer services
   - Firewall rules block traffic to the allocated external IP — check NSX distributed firewall rules and any upstream firewalls


---

## Phase 8: Cluster Scaling

As workload demands change, you can scale your VKS cluster up or down using the VCF CLI. Scaling adjusts the number of control plane and/or worker nodes without redeploying the cluster.

### When to Scale

- **Scale up** when you observe increased workload demand, resource pressure (CPU/memory), or need additional fault tolerance for the control plane.
- **Scale down** when workloads have been reduced and you want to reclaim infrastructure resources. Ensure remaining nodes have sufficient capacity before scaling down.

### Scale the Cluster

Use the `vcf cluster scale` command to adjust node counts:

```bash
vcf cluster scale <CLUSTER_NAME> -c <CONTROL_PLANE_COUNT> -w <WORKER_COUNT>
```

| Parameter | Description |
|---|---|
| `<CLUSTER_NAME>` | Name of the VKS cluster to scale |
| `-c <CONTROL_PLANE_COUNT>` | New total number of control plane nodes (e.g., `3`) |
| `-w <WORKER_COUNT>` | New total number of worker nodes (e.g., `5`) |

> **Note:** Control plane nodes should use odd numbers (1, 3, 5) to maintain etcd quorum. Scaling the control plane is less common than scaling workers.

### Verify the Scaling Operation

After issuing the scale command, monitor the cluster until the new nodes are ready:

```bash
# Check overall cluster status — PHASE should return to "Provisioned"
kubectl get clusters

# Verify the expected number of VMs are running
kubectl get virtualmachines
```

The scaling operation is complete when the cluster phase returns to `Provisioned` and the virtual machine count matches your requested node totals.

---

## Appendix A: EKS-to-VKS Migration Mapping

This reference maps AWS EKS constructs to their VCF 9 / VKS equivalents. Use it as a translation guide when planning your migration from EKS to VKS — each row shows the AWS concept you are familiar with, the corresponding VCF 9 resource, and notes on key differences.

### Concept Mapping Table

| AWS EKS Construct | VCF 9 / VKS Equivalent | Notes |
|---|---|---|
| EKS Cluster | VKS Cluster (`cluster.x-k8s.io/v1beta1`) | EKS is a fully managed control plane; VKS deploys clusters via Cluster API on a vSphere Supervisor. Topology class `builtin-generic-v3.4.0` replaces EKS cluster configuration. |
| VPC | NSX VPC (`vpc.nsx.vmware.com/v1alpha1`) | AWS VPC is a software-defined network in a region; NSX VPC provides network isolation within a VCF project. NSX VPCs are linked to Supervisor Namespaces via the `vpcName` field. |
| Subnets | Zones (`topology.cci.vmware.com/v1alpha1`) | AWS subnets map to availability zones within a VPC; VCF Zones represent vSphere clusters or fault domains within a Region. Placement is specified in the SupervisorNamespace manifest. |
| IAM Roles / Policies | ProjectRoleBinding (`authorization.cci.vmware.com/v1alpha1`) | AWS IAM uses policies attached to roles and users; VCF uses CCI ProjectRoleBinding resources that bind SSO users to ProjectRoles (admin, edit, view) within a Project scope. |
| EBS CSI Driver | vSphere CSI / NFS | AWS uses the EBS CSI driver for block storage; VKS uses the vSphere CSI driver for vSAN/VMFS and NFS provisioners for file storage. Storage classes are configured per cluster. |
| ALB / NLB | NSX LoadBalancer (`vpc.nsx.vmware.com/v1alpha1`) | AWS Application and Network Load Balancers are managed services; VKS uses NSX-provisioned load balancers that are automatically created when a `Service` of type `LoadBalancer` is deployed. |
| Node Groups (Managed) | Machine Deployments (`cluster.x-k8s.io/v1beta1`) | EKS managed node groups auto-manage EC2 instances; VKS uses Cluster API MachineDeployments defined in the cluster topology with autoscaler annotations for scaling. |
| Transit Gateway | TransitGateway (`vpc.nsx.vmware.com/v1alpha1`) | AWS Transit Gateway connects VPCs and on-premises networks; NSX TransitGateway serves the same role, connecting VPCs via VPCAttachment resources. |
| NAT Gateway | VPCNATRule (`vpc.nsx.vmware.com/v1alpha1`) | AWS NAT Gateway provides managed outbound internet access; NSX VPCNATRule defines SNAT (outbound) and DNAT (inbound) rules explicitly per VPC. |
| Security Groups | VPCConnectivityProfile (`vpc.nsx.vmware.com/v1alpha1`) | AWS Security Groups are stateful firewall rules per ENI; NSX VPCConnectivityProfile defines connectivity policies at the VPC level, controlling external access and service gateway settings. |
| RDS (PostgreSQL) | DSM PostgresCluster (`databases.dataservices.vmware.com/v1alpha1`) | AWS RDS is a fully managed database service; VCF Data Services Manager (DSM) provisions managed PostgreSQL instances via the PostgresCluster CRD. See `examples/deploy-managed-db-app/`. |
| Secrets Manager | VCF Secret Store + vault-injector | AWS Secrets Manager stores and rotates secrets; VCF Secret Store uses KeyValueSecrets injected into pods via vault-agent sidecars. See `examples/deploy-secrets-demo/` and `examples/deploy-managed-db-app/`. |
| EC2 Instances | VM Service (`vmoperator.vmware.com/v1alpha3`) | AWS EC2 provides on-demand VMs; VCF VM Service provisions VirtualMachines via CRD with cloud-init bootstrap. See `examples/deploy-hybrid-app/` and `examples/deploy-bastion-vm/`. |
| ECR | Harbor (self-hosted on VKS) | AWS ECR is a managed container registry; Harbor is deployed as a Helm chart on VKS. See `examples/deploy-gitops/`. |
| CloudWatch | Telegraf + Prometheus + Grafana | AWS CloudWatch provides integrated monitoring; VKS uses VKS standard packages for metrics collection and Helm for Grafana. See `examples/deploy-metrics/`. |
| CodePipeline / CodeBuild | GitLab CI + ArgoCD | AWS CI/CD services; VKS uses GitLab and ArgoCD deployed via Helm. See `examples/deploy-gitops/`. |

> **Deployment Patterns:** This guide covers VKS cluster provisioning (Phases 1–8). For application deployment patterns (managed databases, secret store integration, VM workloads, observability, GitOps), see the [Examples README](examples/README.md) and individual deployment READMEs in the `examples/` folder.

### Architectural Differences

**EKS: Fully Managed Control Plane**

In AWS EKS, the Kubernetes control plane is a fully managed service. AWS provisions, patches, and scales the API server, etcd, and controller manager. You never see or manage control plane nodes — they are abstracted behind the EKS service endpoint. Cluster creation is a single API call (`eksctl create cluster` or `aws eks create-cluster`) and the control plane is available within minutes.

**VKS: Supervisor-Managed Control Plane**

In VCF 9, VKS clusters are deployed through the Cluster API on a vSphere Supervisor. The Supervisor is a Kubernetes-enabled vSphere cluster that acts as a management layer. When you apply a `Cluster` manifest, the Supervisor provisions actual VirtualMachine resources for both the control plane and worker nodes. You can observe these VMs being created with `kubectl get virtualmachines -w`.

Key differences:

- **Visibility**: EKS hides the control plane entirely. VKS exposes control plane VMs as observable resources — you can see their provisioning status, resource consumption, and lifecycle events.
- **Lifecycle management**: EKS handles control plane upgrades transparently. VKS upgrades are triggered by updating the `version` field in the Cluster manifest, and the Supervisor orchestrates a rolling replacement of control plane VMs.
- **Resource allocation**: EKS control plane resources scale automatically. VKS control plane nodes use a fixed VM class — you choose the size at cluster creation time via the topology configuration.
- **Multi-tenancy model**: EKS uses AWS accounts and IAM for isolation. VKS uses the three-layer hierarchy of Project → Supervisor Namespace → VKS Namespace, with CCI RBAC controlling access at each layer.
- **API visibility constraint**: EKS cluster APIs are always available once authenticated. VKS Cluster API resources are only visible after completing the Context Bridge (switching from global to namespace-scoped context) — a pattern with no EKS equivalent.

### RBAC Differences

**AWS IAM-Based RBAC**

EKS integrates with AWS Identity and Access Management (IAM) for authentication and authorization. Access to the EKS cluster is controlled through:

- **IAM Roles and Policies**: Define permissions for AWS API actions (e.g., `eks:CreateCluster`, `eks:DescribeCluster`).
- **aws-auth ConfigMap**: Maps IAM roles/users to Kubernetes RBAC groups inside the cluster.
- **OIDC Provider**: EKS clusters can federate with IAM via OIDC for pod-level identity (IRSA — IAM Roles for Service Accounts).

The IAM model is hierarchical: AWS account → IAM policies → Kubernetes RBAC. Authentication happens at the AWS API layer before reaching the Kubernetes API server.

**CCI ProjectRoleBinding-Based RBAC**

VCF 9 uses the Cloud Consumption Interface (CCI) authorization model, which operates at the VCFA platform level:

- **ProjectRoleBinding**: Binds an SSO user identity to a ProjectRole (admin, edit, or view) within a specific Project scope. This is the primary access control mechanism.
- **ProjectRole**: Predefined roles that map to sets of permissions on CCI resources (Projects, Namespaces, Clusters).
- **SSO Integration**: Authentication is handled by the vSphere SSO provider configured in VCFA, not by a cloud IAM service.

Key differences:

| Aspect | AWS EKS (IAM) | VCF 9 (CCI RBAC) |
|---|---|---|
| Identity provider | AWS IAM / OIDC | vSphere SSO |
| Access binding | IAM Roles + aws-auth ConfigMap | ProjectRoleBinding resource |
| Scope | AWS account → cluster | Project → Namespace → Cluster |
| Role granularity | Custom IAM policies with fine-grained actions | Predefined ProjectRoles: admin, edit, view |
| Pod identity | IRSA (IAM Roles for Service Accounts) | Not applicable at the CCI layer |
| Provisioning method | AWS CLI / CloudFormation / Terraform | `kubectl create` with CCI YAML manifests |

### Networking Differences

**AWS VPC Networking**

AWS VPC networking is built on a layered model of managed components:

- **VPC**: The top-level network isolation boundary with a CIDR block.
- **Subnets**: Subdivisions of the VPC CIDR, placed in specific Availability Zones. Public subnets have routes to an Internet Gateway; private subnets route through a NAT Gateway.
- **Route Tables**: Define routing rules for each subnet — where traffic is directed (local, IGW, NAT GW, Transit Gateway, VPC Peering).
- **Internet Gateway (IGW)**: Provides direct internet access for resources in public subnets.
- **NAT Gateway**: Provides outbound internet access for resources in private subnets without exposing them to inbound traffic.
- **Transit Gateway**: Connects multiple VPCs and on-premises networks through a central hub.
- **Security Groups**: Stateful firewall rules attached to ENIs (Elastic Network Interfaces) that control inbound and outbound traffic per resource.

**NSX VPC Networking**

VCF 9 uses NSX for all networking, with a different set of primitives:

- **VPC** (`vpc.nsx.vmware.com/v1alpha1`): Network isolation boundary within a VCF project. Defines private CIDRs and connects to a Tier-0 gateway for external routing.
- **TransitGateway** (`vpc.nsx.vmware.com/v1alpha1`): Central routing hub that connects VPCs to each other or to external networks — analogous to AWS Transit Gateway.
- **VPCAttachment** (`vpc.nsx.vmware.com/v1alpha1`): Connects a VPC to a TransitGateway. This is the explicit link that enables cross-VPC routing — in AWS, this is a Transit Gateway Attachment.
- **VPCNATRule** (`vpc.nsx.vmware.com/v1alpha1`): Defines SNAT (outbound) and DNAT (inbound) NAT rules. Replaces the AWS NAT Gateway (for outbound) and can also handle inbound translation that AWS typically does via ALB/NLB target groups.
- **IPBlock** (`vpc.nsx.vmware.com/v1alpha1`): Defines CIDR ranges available for IP allocation within VPC networking. Analogous to AWS VPC CIDR blocks but managed as separate NSX resources.
- **VPCConnectivityProfile** (`vpc.nsx.vmware.com/v1alpha1`): Defines connectivity policies for a VPC, including external access settings and service gateway configuration. Covers some of the same ground as AWS Security Groups and route table configurations.

Key differences:

| Aspect | AWS VPC | NSX VPC |
|---|---|---|
| Network isolation | VPC with CIDR block | NSX VPC with `privateIPs` and Tier-0 gateway |
| Subnet model | Explicit subnets in Availability Zones | Implicit — Zones are used for compute placement, not subnet definition |
| Routing | Route Tables per subnet | TransitGateway + VPCAttachment for cross-VPC; Tier-0 gateway for external |
| Internet access | Internet Gateway (public) + NAT Gateway (private) | VPCNATRule with SNAT action for outbound; DNAT for inbound |
| Cross-VPC connectivity | Transit Gateway + TGW Attachments | TransitGateway + VPCAttachment resources |
| Firewall rules | Security Groups (per ENI, stateful) | VPCConnectivityProfile (per VPC, policy-based) + NSX Distributed Firewall |
| IP management | VPC CIDR + subnet allocation | IPBlock resources define available ranges; VPC references them via `privateIPs` |
| Load balancing | ALB / NLB (managed services) | NSX LoadBalancer (auto-provisioned for `Service` type `LoadBalancer`) |
| Provisioning method | AWS CLI / CloudFormation / Terraform | `kubectl create` with NSX VPC YAML manifests |


---

## Appendix B: Parameter Reference

This table documents all 22 `<PLACEHOLDER>` variables used throughout the guide. Replace each placeholder with your environment-specific value before applying any manifest or running any command.

| Parameter | Description | Example Value | Used In Phase(s) |
|---|---|---|---|
| `<CONTEXT_NAME>` | VCF CLI context name — a local identifier for your CLI session targeting a specific VCFA endpoint and tenant | `my-project-dev` | Phase 1, Phase 5 |
| `<VCFA_ENDPOINT>` | VCFA hostname or IP address — the VCF Automation endpoint your CLI connects to on port 443 | `vcfa01.example.com` | Phase 1 |
| `<TENANT_NAME>` | SSO tenant/organization name — the identity tenant configured in VCFA for your organization | `org-mycompany-01` | Phase 1 |
| `<PROJECT_NAME>` | CCI Project name — unique identifier for the governance boundary that owns namespaces and RBAC bindings | `myproject-dev-01` | Phase 4, Phase 5 |
| `<USER_IDENTITY>` | SSO user identity — the username to grant access to the project via ProjectRoleBinding | `devops-user-1` | Phase 4 |
| `<REGION_NAME>` | Region name from topology discovery — identifies the geographic or logical deployment region in VCFA | `region-us1-a` | Phase 2, Phase 3, Phase 4 |
| `<ZONE_NAME>` | Zone name from topology discovery — identifies the availability zone (vSphere cluster or fault domain) within a region | `zone-dc1-cl01` | Phase 2, Phase 4 |
| `<VPC_NAME>` | NSX VPC name — identifies the Virtual Private Cloud for network isolation and IP management | `region-us1-a-default-vpc` | Phase 2, Phase 3, Phase 4 |
| `<RESOURCE_CLASS>` | Supervisor Namespace class — determines CPU and memory resource tier for the namespace (from `kubectl get svnscls`) | `xxlarge` | Phase 2, Phase 4 |
| `<NAMESPACE_PREFIX>` | Prefix for `generateName` — VCF appends a random 5-character suffix to produce the Dynamic Namespace Name | `myproject-ns-` | Phase 4 |
| `<GENERATED_NS_NAME>` | Dynamic Namespace Name — the VCF-generated namespace identifier including the random 5-character suffix | `myproject-ns-a1b2c` | Phase 5, Phase 6, Phase 7 |
| `<CLUSTER_NAME>` | VKS cluster name — unique identifier for the managed Kubernetes cluster within the Supervisor Namespace | `myproject-clus-01` | Phase 6, Phase 7 |
| `<K8S_VERSION>` | Kubernetes version — the target vSphere Kubernetes Release version for the VKS cluster | `v1.33.6+vmware.1-fips` | Phase 6 |
| `<CONTENT_LIBRARY_ID>` | vSphere content library ID — UUID of the content library containing OS image templates for cluster node VMs | *(UUID from vSphere)* | Phase 6 |
| `<SERVICES_CIDR>` | Service network CIDR — IP address range for Kubernetes ClusterIP services; must not overlap with pod or VPC CIDRs | `10.96.0.0/12` | Phase 6 |
| `<PODS_CIDR>` | Pod network CIDR — IP address range for pod networking; must be large enough for all pods across all nodes | `192.168.156.0/20` | Phase 6 |
| `<VM_CLASS>` | VM class for worker nodes — determines CPU and memory allocation per worker node VM | `best-effort-large` | Phase 6 |
| `<STORAGE_CLASS>` | Storage class name — the Kubernetes storage class used for persistent volume provisioning on the VKS cluster | `nfs` | Phase 6, Phase 7 |
| `<MIN_NODES>` | Autoscaler minimum node count — lower bound for the cluster autoscaler on the worker node pool | `3` | Phase 6 |
| `<MAX_NODES>` | Autoscaler maximum node count — upper bound for the cluster autoscaler on the worker node pool | `10` | Phase 6 |
| `<IP_BLOCK_CIDR>` | IP block CIDR for VPC networking — defines the address range available for VPC subnet allocation from NSX IPBlock resources | `10.0.0.0/16` | Phase 3 |
| `<KUBECONFIG_PATH>` | Path to downloaded VKS kubeconfig file — local filesystem path where the guest cluster kubeconfig is saved | `~/kubeconfigs/myproject-clus-01.yaml` | Phase 7 |


---

## Appendix C: API Group Reference

This section documents all CCI, Cluster API, NSX VPC, and Topology API groups used throughout the guide. Use this reference to verify API compatibility with your VCFA version — run `kubectl api-resources` to confirm each group is registered in your environment.

| API Group | Version | Resource Kind(s) | Description | Used In Phase(s) |
|---|---|---|---|---|
| `project.cci.vmware.com` | `v1alpha2` | Project | Governance boundary for resource ownership and RBAC scoping within VCFA | Phase 4 |
| `authorization.cci.vmware.com` | `v1alpha1` | ProjectRoleBinding, ProjectRole | RBAC bindings that grant SSO users access to a Project with a predefined role (admin, edit, view) | Phase 4 |
| `infrastructure.cci.vmware.com` | `v1alpha2` | SupervisorNamespace, SupervisorNamespaceClass, SupervisorNamespaceClassConfig | Supervisor Namespace lifecycle management, resource class definitions, and class configuration overrides | Phase 2, Phase 4 |
| `infrastructure.cci.vmware.com` | `v1alpha1` | VksCredentialRequest, ResourceMetricsRequest, BootstrapConfiguration | Programmatic kubeconfig retrieval for VKS clusters, resource metrics queries, and bootstrap configuration | Phase 7 |
| `topology.cci.vmware.com` | `v1alpha2` | Region | Geographic or logical deployment regions within the VCFA topology | Phase 2 |
| `topology.cci.vmware.com` | `v1alpha1` | Zone | Availability zones (vSphere clusters or fault domains) within a Region | Phase 2 |
| `vpc.nsx.vmware.com` | `v1alpha1` | VPC, TransitGateway, VPCAttachment, VPCNATRule, VPCConnectivityProfile, IPBlock, LoadBalancer | NSX networking resources for VPC isolation, cross-VPC routing, NAT rules, connectivity policies, IP management, and load balancing | Phase 2, Phase 4, Phase 7 |
| `cluster.x-k8s.io` | `v1beta1` | Cluster | Cluster API resource for deploying and managing VKS Kubernetes clusters on a vSphere Supervisor | Phase 6 |

---

## Appendix D: Troubleshooting Guide

This section consolidates all error scenarios documented throughout the guide into a single quick-reference table. For detailed remediation steps, refer to the troubleshooting subsection within the corresponding phase.

| Phase | Error Scenario | Expected Symptom | Remediation |
|---|---|---|---|
| 1 — Environment Initialization | Unreachable VCFA endpoint | `vcf context create` fails with connection timeout or connection refused | Verify network connectivity, DNS resolution, and firewall rules for port 443 to the VCFA endpoint |
| 1 — Environment Initialization | Invalid tenant name | Context creates successfully but `kubectl` commands return 401/403 Unauthorized | Confirm the tenant name matches the SSO organization configured in VCFA |
| 1 — Environment Initialization | Missing API token | First `kubectl` command fails with authentication error | Generate an API token from the VCFA portal before using the VCF CLI |
| 1 — Environment Initialization | Missing fleet certificate | TLS verification fails on CLI or `kubectl` commands | Download the fleet certificate (`restbaseuri.1`) from the provider interface and configure it locally |
| 3 — VPC & Network Provisioning | IP address exhaustion | VPC creation fails or subnets/pods cannot receive IP addresses | Check `kubectl get ipblocks -o wide` to identify exhausted IP blocks; request additional IPBlock resources from your NSX administrator |
| 3 — VPC & Network Provisioning | Transit Gateway connectivity failure | VPCAttachment remains in a pending state | Verify the Tier-0 gateway path is correct and check NSX Edge cluster health |
| 4 — Project & Namespace Provisioning | Project naming conflict | `kubectl create` returns `AlreadyExists` error | List existing projects with `kubectl get projects` and choose a unique name |
| 4 — Project & Namespace Provisioning | Invalid region, zone, or class | SupervisorNamespace creation fails with a validation error | Re-run Phase 2 topology discovery commands to verify valid values for `regionName`, `className`, and zone `name` |
| 4 — Project & Namespace Provisioning | Missing `--validate=false` flag | `kubectl` rejects CCI custom resource fields with schema validation errors | Add `--validate=false` to the `kubectl create` command to bypass local schema validation |
| 5 — Context Bridge | Stale CLI cache | `vcf context list` does not show the newly created namespace | `vcf context refresh` does not re-enumerate namespaces when the token is still valid. Delete and recreate the context: `vcf context delete <CONTEXT> --yes` then `vcf context create <CONTEXT> --endpoint ... --type cci --tenant-name ... --api-token ... --set-current` |
| 5 — Context Bridge | Incorrect context format | `vcf context use` fails to switch scope | Use the exact three-part format: `<CONTEXT_NAME>:<GENERATED_NS_NAME>:<PROJECT_NAME>` |
| 5 — Context Bridge | Cluster API not visible | `kubectl get clusters` returns "server doesn't have a resource type" or "No resources found" | Confirm the Context Bridge is complete; re-run `vcf context use` with the namespace-scoped three-part format |
| 6 — VKS Cluster Deployment | Wrong namespace in manifest | Cluster created in wrong scope or rejected by the API server | Update `metadata.namespace` in the Cluster manifest to match the exact `<GENERATED_NS_NAME>` from Phase 5 |
| 6 — VKS Cluster Deployment | Invalid Kubernetes version | Cluster provisioning fails with a version error | Check available vSphere Kubernetes Releases with `kubectl get tkr` and update `spec.topology.version` |
| 6 — VKS Cluster Deployment | VM provisioning stalls | VirtualMachines stuck in `Creating` state indefinitely | Check vSphere resource availability, content library sync status, and storage capacity on the target cluster |
| 7 — Functional Validation | PVC stuck in Pending | PersistentVolumeClaim does not bind to a volume | Verify the storage class exists with `kubectl get sc` and check CSI driver pods in the `vmware-system-csi` namespace |
| 7 — Functional Validation | LoadBalancer no external IP | Service stays in `<pending>` state for the external IP | Verify with `kubectl get svc` (primary method) to check the EXTERNAL-IP column; if still pending, check NSX Edge cluster capacity. The command `kubectl get loadbalancers -A` queries NSX native resources at the Supervisor level and may return empty results in a VKS guest cluster context — this is normal |
| 7 — Functional Validation | HTTP connectivity failure | `curl` to the LoadBalancer external IP times out | Verify the pod is running, NSX VPC NAT rules are configured correctly, and no firewall rules block ingress traffic |
