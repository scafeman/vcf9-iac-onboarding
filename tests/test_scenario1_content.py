"""Content-presence unit tests for VCF 9 Scenario 1 — Full Stack Deploy Script."""

import os
import re


SCRIPT_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "scenario1", "scenario1-full-stack-deploy.sh"
)


# ===================================================================
# Task 12.1 — Script structure tests
# Validates: Requirements 1.1, 1.2, 1.3, 2.2, 2.3, 2.5, 2.6
# ===================================================================


class TestScriptFileExists:
    """Script file exists at the expected location.
    Validates: Requirement 1.1"""

    def test_script_file_exists(self):
        assert os.path.isfile(SCRIPT_PATH), (
            "Script not found at examples/scenario1/scenario1-full-stack-deploy.sh"
        )


class TestScriptShebangAndStrictMode:
    """Script starts with bash shebang and enables strict mode.
    Validates: Requirements 1.2, 1.3"""

    def test_first_line_is_bash_shebang(self, script_text):
        first_line = script_text.splitlines()[0]
        assert first_line == "#!/bin/bash", (
            f"Expected '#!/bin/bash' as first line, got '{first_line}'"
        )

    def test_set_euo_pipefail(self, script_text):
        assert "set -euo pipefail" in script_text, (
            "Script does not contain 'set -euo pipefail'"
        )


class TestVariableBlockContainsAllRequired:
    """Variable block includes all required variables from Req 2.2 and 2.3.
    Validates: Requirements 2.2, 2.3"""

    REQUIRED_VARIABLES = [
        "VCFA_ENDPOINT",
        "TENANT_NAME",
        "CONTEXT_NAME",
        "PROJECT_NAME",
        "PROJECT_DESCRIPTION",
        "USER_IDENTITY",
        "NAMESPACE_PREFIX",
        "NAMESPACE_DESCRIPTION",
        "REGION_NAME",
        "ZONE_NAME",
        "VPC_NAME",
        "TRANSIT_GATEWAY_NAME",
        "CONNECTIVITY_PROFILE_NAME",
        "RESOURCE_CLASS",
        "CPU_LIMIT",
        "MEMORY_LIMIT",
        "CLUSTER_NAME",
        "K8S_VERSION",
        "CONTENT_LIBRARY_ID",
        "SERVICES_CIDR",
        "PODS_CIDR",
        "VM_CLASS",
        "STORAGE_CLASS",
        "MIN_NODES",
        "MAX_NODES",
    ]

    def test_all_required_variables_defined(self, script_text):
        for var in self.REQUIRED_VARIABLES:
            # Match variable assignment: VAR_NAME= (possibly with ${...} on the right)
            pattern = rf'^{var}='
            assert re.search(pattern, script_text, re.MULTILINE), (
                f"Required variable '{var}' not defined in script"
            )


class TestVariableDefaults:
    """Variables with sensible defaults use the ${VAR:-default} pattern.
    Validates: Requirement 2.5"""

    # Variables that the design specifies should have defaults
    VARIABLES_WITH_DEFAULTS = [
        "PROJECT_DESCRIPTION",
        "NAMESPACE_DESCRIPTION",
        "REGION_NAME",
        "VPC_NAME",
        "TRANSIT_GATEWAY_NAME",
        "CONNECTIVITY_PROFILE_NAME",
        "RESOURCE_CLASS",
        "CPU_LIMIT",
        "MEMORY_LIMIT",
        "K8S_VERSION",
        "SERVICES_CIDR",
        "PODS_CIDR",
        "VM_CLASS",
        "STORAGE_CLASS",
        "MIN_NODES",
        "MAX_NODES",
    ]

    def test_default_variables_use_default_pattern(self, script_text):
        for var in self.VARIABLES_WITH_DEFAULTS:
            # Match: VAR="${VAR:-some_default}" where some_default is non-empty
            pattern = rf'^{var}="\$\{{{var}:-[^"}}]+\}}"'
            assert re.search(pattern, script_text, re.MULTILINE), (
                f"Variable '{var}' does not use the ${{VAR:-default}} pattern with a non-empty default"
            )


class TestValidateVariablesBeforeProvisioning:
    """validate_variables function exists and is called before first provisioning command.
    Validates: Requirement 2.6"""

    def test_validate_variables_function_exists(self, script_text):
        assert "validate_variables" in script_text, (
            "validate_variables function/block not found in script"
        )

    def test_validate_variables_called_before_provisioning(self, script_text):
        # Find the position of the validate_variables call (not the function def)
        # The call is a standalone line: validate_variables
        call_match = re.search(r"^validate_variables\s*$", script_text, re.MULTILINE)
        assert call_match, "validate_variables is never called as a standalone command"

        call_pos = call_match.start()

        # First provisioning command is either vcf context create or kubectl create/apply
        prov_patterns = [
            r"vcf context create",
            r"kubectl\s+create",
            r"kubectl\s+apply",
        ]
        first_prov_pos = len(script_text)
        for pat in prov_patterns:
            m = re.search(pat, script_text)
            if m and m.start() < first_prov_pos:
                first_prov_pos = m.start()

        assert call_pos < first_prov_pos, (
            "validate_variables is called after the first provisioning command"
        )


# ===================================================================
# Task 12.2 — Phase 1 and Phase 2 content tests
# Validates: Requirements 3.1, 3.2, 4.1, 4.2, 4.3, 4.5, 11.1
# ===================================================================


class TestPhase1ContextCreation:
    """Phase 1 contains VCF CLI context creation and activation commands.
    Validates: Requirements 3.1, 3.2"""

    def test_vcf_context_create_with_endpoint_flag(self, script_phases):
        phase1 = script_phases[1]
        assert "--endpoint" in phase1, (
            "Phase 1 missing --endpoint flag on vcf context create"
        )

    def test_vcf_context_create_with_type_cci_flag(self, script_phases):
        phase1 = script_phases[1]
        assert "--type cci" in phase1, (
            "Phase 1 missing --type cci flag on vcf context create"
        )

    def test_vcf_context_create_with_tenant_flag(self, script_phases):
        phase1 = script_phases[1]
        assert "--tenant" in phase1, (
            "Phase 1 missing --tenant flag on vcf context create"
        )

    def test_vcf_context_create_command(self, script_phases):
        """Full vcf context create command with all required flags (Req 3.1).

        The script places the context name as the first positional argument
        (``vcf context create "$NAME" --endpoint ...``), so the flags may
        appear after the name rather than immediately after ``create``.
        """
        phase1 = script_phases[1]
        has_create = re.search(r"vcf\s+context\s+create\b", phase1)
        has_endpoint = "--endpoint" in phase1
        has_type_cci = "--type cci" in phase1 or "--type=cci" in phase1
        has_tenant = "--tenant" in phase1
        assert has_create and has_endpoint and has_type_cci and has_tenant, (
            "Phase 1 missing complete vcf context create command with "
            "--endpoint, --type cci, --tenant"
        )

    def test_vcf_context_use_command(self, script_phases):
        """Context is activated — either via --set-current flag or vcf context use (Req 3.2)."""
        phase1 = script_phases[1]
        has_set_current = "--set-current" in phase1
        has_context_use = re.search(r"vcf\s+context\s+use\b", phase1)
        assert has_set_current or has_context_use, (
            "Phase 1 missing context activation (--set-current flag or vcf context use command)"
        )


class TestPhase2ProjectNamespaceProvisioning:
    """Phase 2 contains Project, RBAC, Namespace heredoc and dynamic name retrieval.
    Validates: Requirements 4.1, 4.2, 4.3, 4.5, 11.1"""

    def test_heredoc_contains_project_kind(self, script_phases):
        """Heredoc contains Project kind (Req 4.1)."""
        phase2 = script_phases[2]
        assert "kind: Project" in phase2, (
            "Phase 2 heredoc missing 'kind: Project'"
        )

    def test_heredoc_contains_project_role_binding_kind(self, script_phases):
        """Heredoc contains ProjectRoleBinding kind (Req 4.1)."""
        phase2 = script_phases[2]
        assert "kind: ProjectRoleBinding" in phase2, (
            "Phase 2 heredoc missing 'kind: ProjectRoleBinding'"
        )

    def test_heredoc_contains_supervisor_namespace_kind(self, script_phases):
        """Heredoc contains SupervisorNamespace kind (Req 4.1)."""
        phase2 = script_phases[2]
        assert "kind: SupervisorNamespace" in phase2, (
            "Phase 2 heredoc missing 'kind: SupervisorNamespace'"
        )

    def test_kubectl_create_with_validate_false(self, script_phases):
        """kubectl create uses --validate=false (Req 4.2)."""
        phase2 = script_phases[2]
        assert re.search(r"kubectl\s+create\s+--validate=false", phase2), (
            "Phase 2 missing kubectl create with --validate=false"
        )

    def test_supervisor_namespace_uses_generate_name(self, script_phases):
        """SupervisorNamespace uses generateName (Req 4.3)."""
        phase2 = script_phases[2]
        assert "generateName:" in phase2, (
            "Phase 2 SupervisorNamespace missing generateName field"
        )

    def test_kubectl_get_supervisornamespaces_for_dynamic_name(self, script_phases):
        """kubectl get supervisornamespaces retrieves dynamic name (Req 4.5)."""
        phase2 = script_phases[2]
        assert re.search(r"kubectl\s+get\s+supervisornamespaces", phase2), (
            "Phase 2 missing kubectl get supervisornamespaces for dynamic name retrieval"
        )

    def test_idempotency_check_for_project_existence(self, script_phases):
        """Idempotency check: kubectl get project before create (Req 11.1)."""
        phase2 = script_phases[2]
        # The idempotency check should appear before the kubectl create command
        get_match = re.search(r"kubectl\s+get\s+project\b", phase2)
        create_match = re.search(r"kubectl\s+create\s+--validate=false", phase2)
        assert get_match, (
            "Phase 2 missing idempotency check (kubectl get project)"
        )
        assert create_match, (
            "Phase 2 missing kubectl create command"
        )
        assert get_match.start() < create_match.start(), (
            "Idempotency check (kubectl get project) should appear before kubectl create"
        )


# ===================================================================
# Task 12.3 — Phase 3, Phase 4, Phase 5, and Phase 6 content tests
# Validates: Requirements 5.1, 5.2, 6.1, 6.4, 6.5, 6.6, 7.1, 7.5,
#            7.6, 8.1, 8.2, 8.6, 11.2
# ===================================================================


class TestPhase3ContextBridge:
    """Phase 3 contains context bridge switch and Cluster API verification.
    Validates: Requirements 5.1, 5.2"""

    def test_vcf_context_use_three_part_format(self, script_phases):
        """vcf context use with three-part CONTEXT:NS:PROJECT format (Req 5.1).

        The script may use a variable (e.g. ``${NS_CONTEXT}``) that holds the
        three-part colon-separated value rather than inlining it directly.
        """
        phase3 = script_phases[3]
        # Direct literal: vcf context use "ctx:ns:proj"
        has_literal = re.search(
            r'vcf\s+context\s+use\s+"[^"]*:[^"]*:[^"]*"', phase3
        )
        # Variable holding the three-part format, e.g. NS_CONTEXT="${CTX}:${NS}:${PROJ}"
        has_var_def = re.search(r'=.*\$\{[^}]+\}:\$\{[^}]+\}:\$\{[^}]+\}', phase3)
        has_context_use = re.search(r'vcf\s+context\s+use\b', phase3)
        assert has_literal or (has_var_def and has_context_use), (
            "Phase 3 missing vcf context use with three-part colon-separated format"
        )

    def test_kubectl_get_clusters_verification(self, script_phases):
        """kubectl get clusters to verify Cluster API access (Req 5.2)."""
        phase3 = script_phases[3]
        assert re.search(r"kubectl\s+get\s+clusters\b", phase3), (
            "Phase 3 missing kubectl get clusters verification"
        )


class TestPhase4VKSClusterDeployment:
    """Phase 4 contains VKS cluster heredoc, apply command, and idempotency check.
    Validates: Requirements 6.1, 6.4, 6.5, 6.6, 11.2"""

    def test_cluster_topology_class(self, script_phases):
        """Cluster heredoc uses builtin-generic-v3.4.0 topology class (Req 6.1)."""
        phase4 = script_phases[4]
        assert "builtin-generic-v3.4.0" in phase4, (
            "Phase 4 Cluster heredoc missing topology class 'builtin-generic-v3.4.0'"
        )

    def test_cluster_class_namespace(self, script_phases):
        """Cluster heredoc uses vmware-system-vks-public classNamespace (Req 6.1)."""
        phase4 = script_phases[4]
        assert "vmware-system-vks-public" in phase4, (
            "Phase 4 Cluster heredoc missing classNamespace 'vmware-system-vks-public'"
        )

    def test_kubectl_apply_validate_false_insecure(self, script_phases):
        """kubectl apply with --validate=false and --insecure-skip-tls-verify (Req 6.6)."""
        phase4 = script_phases[4]
        assert re.search(
            r"kubectl\s+apply\s+--validate=false\s+--insecure-skip-tls-verify", phase4
        ), "Phase 4 missing kubectl apply with --validate=false --insecure-skip-tls-verify"

    def test_autoscaler_max_size_annotation(self, script_phases):
        """Autoscaler max-size annotation present (Req 6.4)."""
        phase4 = script_phases[4]
        assert "cluster-api-autoscaler-node-group-max-size" in phase4, (
            "Phase 4 missing autoscaler max-size annotation"
        )

    def test_autoscaler_min_size_annotation(self, script_phases):
        """Autoscaler min-size annotation present (Req 6.4)."""
        phase4 = script_phases[4]
        assert "cluster-api-autoscaler-node-group-min-size" in phase4, (
            "Phase 4 missing autoscaler min-size annotation"
        )

    def test_resolve_os_image_annotation(self, script_phases):
        """resolve-os-image annotation present (Req 6.5)."""
        phase4 = script_phases[4]
        assert "resolve-os-image" in phase4, (
            "Phase 4 missing resolve-os-image annotation"
        )

    def test_idempotency_check_cluster_existence(self, script_phases):
        """Idempotency check: kubectl get cluster before apply (Req 11.2)."""
        phase4 = script_phases[4]
        get_match = re.search(r"kubectl\s+get\s+cluster\b", phase4)
        apply_match = re.search(r"kubectl\s+apply\s+--validate=false", phase4)
        assert get_match, (
            "Phase 4 missing idempotency check (kubectl get cluster)"
        )
        assert apply_match, (
            "Phase 4 missing kubectl apply command"
        )
        assert get_match.start() < apply_match.start(), (
            "Idempotency check (kubectl get cluster) should appear before kubectl apply"
        )


class TestPhase5KubeconfigRetrieval:
    """Phase 5 contains VksCredentialRequest heredoc, KUBECONFIG export, and verification.
    Validates: Requirements 7.1, 7.5, 7.6"""

    def test_kubeconfig_retrieval_command(self, script_phases):
        """Kubeconfig retrieval via VksCredentialRequest heredoc or vcf cluster kubeconfig CLI (Req 7.1)."""
        phase5 = script_phases[5]
        has_vks_cred = "kind: VksCredentialRequest" in phase5
        has_cli_get = re.search(r"vcf\s+cluster\s+kubeconfig\s+get", phase5)
        assert has_vks_cred or has_cli_get, (
            "Phase 5 missing kubeconfig retrieval (VksCredentialRequest heredoc or vcf cluster kubeconfig get)"
        )

    def test_export_kubeconfig(self, script_phases):
        """export KUBECONFIG command present (Req 7.5)."""
        phase5 = script_phases[5]
        assert re.search(r"export\s+KUBECONFIG=", phase5), (
            "Phase 5 missing 'export KUBECONFIG' command"
        )

    def test_kubectl_get_namespaces_verification(self, script_phases):
        """kubectl get namespaces to verify guest cluster connectivity (Req 7.6)."""
        phase5 = script_phases[5]
        assert re.search(r"kubectl\s+get\s+namespaces\b", phase5), (
            "Phase 5 missing kubectl get namespaces verification"
        )


class TestPhase6FunctionalValidation:
    """Phase 6 contains functional test heredoc with PVC, Deployment, Service,
    hardened security context, and curl HTTP test.
    Validates: Requirements 8.1, 8.2, 8.6"""

    def test_heredoc_contains_pvc(self, script_phases):
        """Heredoc contains PersistentVolumeClaim kind (Req 8.1)."""
        phase6 = script_phases[6]
        assert "kind: PersistentVolumeClaim" in phase6, (
            "Phase 6 heredoc missing 'kind: PersistentVolumeClaim'"
        )

    def test_heredoc_contains_deployment(self, script_phases):
        """Heredoc contains Deployment kind (Req 8.1)."""
        phase6 = script_phases[6]
        assert "kind: Deployment" in phase6, (
            "Phase 6 heredoc missing 'kind: Deployment'"
        )

    def test_heredoc_contains_service(self, script_phases):
        """Heredoc contains Service kind (Req 8.1)."""
        phase6 = script_phases[6]
        assert "kind: Service" in phase6, (
            "Phase 6 heredoc missing 'kind: Service'"
        )

    def test_security_seccomp_profile(self, script_phases):
        """Security context includes seccompProfile (Req 8.2)."""
        phase6 = script_phases[6]
        assert "seccompProfile" in phase6, (
            "Phase 6 missing seccompProfile in security context"
        )

    def test_security_run_as_non_root(self, script_phases):
        """Security context includes runAsNonRoot: true (Req 8.2)."""
        phase6 = script_phases[6]
        assert "runAsNonRoot: true" in phase6, (
            "Phase 6 missing runAsNonRoot: true in security context"
        )

    def test_security_run_as_user_101(self, script_phases):
        """Security context includes runAsUser: 101 (Req 8.2)."""
        phase6 = script_phases[6]
        assert "runAsUser: 101" in phase6, (
            "Phase 6 missing runAsUser: 101 in security context"
        )

    def test_security_fs_group_101(self, script_phases):
        """Security context includes fsGroup: 101 (Req 8.2)."""
        phase6 = script_phases[6]
        assert "fsGroup: 101" in phase6, (
            "Phase 6 missing fsGroup: 101 in security context"
        )

    def test_security_allow_privilege_escalation_false(self, script_phases):
        """Security context includes allowPrivilegeEscalation: false (Req 8.2)."""
        phase6 = script_phases[6]
        assert "allowPrivilegeEscalation: false" in phase6, (
            "Phase 6 missing allowPrivilegeEscalation: false in security context"
        )

    def test_security_drop_all_capabilities(self, script_phases):
        """Security context drops ALL capabilities (Req 8.2)."""
        phase6 = script_phases[6]
        assert re.search(r"drop:\s*\n\s*-\s*ALL", phase6), (
            "Phase 6 missing 'drop: ALL' capabilities in security context"
        )

    def test_curl_http_test(self, script_phases):
        """curl command for HTTP connectivity test (Req 8.6)."""
        phase6 = script_phases[6]
        assert re.search(r"curl\s+", phase6), (
            "Phase 6 missing curl command for HTTP test"
        )


# ===================================================================
# Task 12.4 — API version content tests
# Validates: Requirements 10.2, 10.3, 10.4, 10.5, 10.6, 10.7
# ===================================================================


class TestAPIVersions:
    """All Kubernetes manifests use the correct API versions.
    Validates: Requirements 10.2, 10.3, 10.4, 10.5, 10.6, 10.7"""

    def test_project_api_version(self, script_text):
        """Project uses project.cci.vmware.com/v1alpha2 (Req 10.2)."""
        assert "apiVersion: project.cci.vmware.com/v1alpha2" in script_text, (
            "Script missing Project apiVersion 'project.cci.vmware.com/v1alpha2'"
        )

    def test_project_role_binding_api_version(self, script_text):
        """ProjectRoleBinding uses authorization.cci.vmware.com/v1alpha1 (Req 10.3)."""
        assert "apiVersion: authorization.cci.vmware.com/v1alpha1" in script_text, (
            "Script missing ProjectRoleBinding apiVersion 'authorization.cci.vmware.com/v1alpha1'"
        )

    def test_supervisor_namespace_api_version(self, script_text):
        """SupervisorNamespace uses infrastructure.cci.vmware.com/v1alpha2 (Req 10.4)."""
        assert "apiVersion: infrastructure.cci.vmware.com/v1alpha2" in script_text, (
            "Script missing SupervisorNamespace apiVersion 'infrastructure.cci.vmware.com/v1alpha2'"
        )

    def test_cluster_api_version(self, script_text):
        """Cluster uses cluster.x-k8s.io/v1beta1 (Req 10.5)."""
        assert "apiVersion: cluster.x-k8s.io/v1beta1" in script_text, (
            "Script missing Cluster apiVersion 'cluster.x-k8s.io/v1beta1'"
        )

    def test_vks_credential_request_api_version(self, script_text):
        """VksCredentialRequest uses infrastructure.cci.vmware.com/v1alpha1 (Req 10.6).

        If the script uses the VCF CLI (``vcf cluster kubeconfig get``) instead
        of a VksCredentialRequest manifest, this API version is not required.
        """
        has_api_version = "apiVersion: infrastructure.cci.vmware.com/v1alpha1" in script_text
        uses_cli = re.search(r"vcf\s+cluster\s+kubeconfig\s+get", script_text)
        assert has_api_version or uses_cli, (
            "Script missing VksCredentialRequest apiVersion "
            "'infrastructure.cci.vmware.com/v1alpha1' and does not use "
            "vcf cluster kubeconfig get CLI alternative"
        )

    def test_pvc_api_version_v1(self, script_text):
        """PersistentVolumeClaim uses v1 (Req 10.7)."""
        # Match "apiVersion: v1" followed eventually by "kind: PersistentVolumeClaim"
        # within the same heredoc section
        assert re.search(
            r"apiVersion:\s*v1\s*\n\s*kind:\s*PersistentVolumeClaim", script_text
        ), "Script missing PVC with apiVersion 'v1'"

    def test_service_api_version_v1(self, script_text):
        """Service uses v1 (Req 10.7)."""
        assert re.search(
            r"apiVersion:\s*v1\s*\n\s*kind:\s*Service", script_text
        ), "Script missing Service with apiVersion 'v1'"

    def test_deployment_api_version_apps_v1(self, script_text):
        """Deployment uses apps/v1 (Req 10.7)."""
        assert re.search(
            r"apiVersion:\s*apps/v1\s*\n\s*kind:\s*Deployment", script_text
        ), "Script missing Deployment with apiVersion 'apps/v1'"
