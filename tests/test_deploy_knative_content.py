"""Content-presence unit tests for VCF 9 Deploy Knative — Serverless Asset Tracker with DSM PostgreSQL."""

import os
import re


# ===================================================================
# File existence tests
# Validates: Requirements 9.1, 10.1, 11.1, 12.1
# ===================================================================


class TestFileExistence:
    """Deploy script, teardown script, workflow, and API server files exist."""

    BASE = os.path.join(os.path.dirname(__file__), "..")

    def test_deploy_script_exists(self):
        assert os.path.isfile(
            os.path.join(self.BASE, "examples", "deploy-knative", "deploy-knative.sh")
        )

    def test_teardown_script_exists(self):
        assert os.path.isfile(
            os.path.join(self.BASE, "examples", "deploy-knative", "teardown-knative.sh")
        )

    def test_workflow_exists(self):
        assert os.path.isfile(
            os.path.join(self.BASE, ".github", "workflows", "deploy-knative.yml")
        )

    def test_api_server_js_exists(self):
        assert os.path.isfile(
            os.path.join(self.BASE, "examples", "deploy-knative", "api", "server.js")
        )

    def test_api_dockerfile_exists(self):
        assert os.path.isfile(
            os.path.join(self.BASE, "examples", "deploy-knative", "api", "Dockerfile")
        )

    def test_api_package_json_exists(self):
        assert os.path.isfile(
            os.path.join(self.BASE, "examples", "deploy-knative", "api", "package.json")
        )


# ===================================================================
# Deploy script — shebang and strict mode
# Validates: Requirements 9.1, 9.6, 13.3
# ===================================================================


class TestDeployScriptShebangAndStrictMode:
    """Deploy script starts with bash shebang and enables strict mode."""

    def test_first_line_is_bash_shebang(self, knative_deploy_text):
        first_line = knative_deploy_text.splitlines()[0]
        assert first_line == "#!/bin/bash", (
            f"Expected '#!/bin/bash' as first line, got '{first_line}'"
        )

    def test_set_euo_pipefail(self, knative_deploy_text):
        assert "set -euo pipefail" in knative_deploy_text


# ===================================================================
# Deploy script — variable block completeness
# Validates: Requirements 1.7, 7.2, 9.2, 9.9, 13.6
# ===================================================================


class TestDeployVariableBlock:
    """Variable block includes all required configurable variables."""

    REQUIRED_VARIABLES = [
        "CLUSTER_NAME",
        "KUBECONFIG_FILE",
        "KNATIVE_SERVING_VERSION",
        "NET_CONTOUR_VERSION",
        "KNATIVE_NAMESPACE",
        "DEMO_NAMESPACE",
        "CONTAINER_REGISTRY",
        "IMAGE_TAG",
        "AUDIT_IMAGE",
        "SCALE_TO_ZERO_GRACE_PERIOD",
        "KNATIVE_TIMEOUT",
        "POD_TIMEOUT",
        "LB_TIMEOUT",
        "POLL_INTERVAL",
        "VCF_API_TOKEN",
        "VCFA_ENDPOINT",
        "TENANT_NAME",
        "CONTEXT_NAME",
        "SUPERVISOR_NAMESPACE",
        "PROJECT_NAME",
        "DSM_CLUSTER_NAME",
        "ADMIN_PASSWORD_SECRET_NAME",
        "ADMIN_PASSWORD",
        "API_IMAGE",
        "API_PORT",
        "DSM_TIMEOUT",
    ]

    def test_all_required_variables_defined(self, knative_deploy_text):
        for var in self.REQUIRED_VARIABLES:
            pattern = rf'^{var}='
            assert re.search(pattern, knative_deploy_text, re.MULTILINE), (
                f"Required variable '{var}' not defined in deploy script"
            )

    def test_variables_use_default_pattern(self, knative_deploy_text):
        """Variables with defaults use the VAR="${VAR:-default}" pattern."""
        vars_with_defaults = [
            "KNATIVE_SERVING_VERSION",
            "NET_CONTOUR_VERSION",
            "KNATIVE_NAMESPACE",
            "DEMO_NAMESPACE",
            "CONTAINER_REGISTRY",
            "IMAGE_TAG",
            "SCALE_TO_ZERO_GRACE_PERIOD",
            "KNATIVE_TIMEOUT",
            "POD_TIMEOUT",
            "LB_TIMEOUT",
            "POLL_INTERVAL",
            "DSM_CLUSTER_NAME",
            "ADMIN_PASSWORD_SECRET_NAME",
            "API_PORT",
            "DSM_TIMEOUT",
        ]
        for var in vars_with_defaults:
            pattern = rf'\$\{{{var}:-[^}}]+\}}'
            assert re.search(pattern, knative_deploy_text), (
                f"Variable '{var}' does not use ${{VAR:-default}} pattern"
            )


# ===================================================================
# Deploy script — helper functions
# Validates: Requirements 9.3, 13.4
# ===================================================================


class TestDeployHelperFunctions:
    """Deploy script defines all required helper functions."""

    REQUIRED_FUNCTIONS = [
        "log_step",
        "log_success",
        "log_warn",
        "log_error",
        "validate_variables",
        "wait_for_condition",
    ]

    def test_all_helper_functions_defined(self, knative_deploy_text):
        for func in self.REQUIRED_FUNCTIONS:
            pattern = rf'^{func}\(\)'
            assert re.search(pattern, knative_deploy_text, re.MULTILINE), (
                f"Helper function '{func}' not defined in deploy script"
            )


# ===================================================================
# Deploy script — Knative URLs
# Validates: Requirements 1.1, 2.1, 3.1, 13.5
# ===================================================================


class TestDeployKnativeURLs:
    """Deploy script contains the correct Knative manifest URLs."""

    def test_serving_crds_url(self, knative_deploy_text):
        assert "serving-crds.yaml" in knative_deploy_text

    def test_serving_core_url(self, knative_deploy_text):
        assert "serving-core.yaml" in knative_deploy_text

    def test_net_contour_url(self, knative_deploy_text):
        assert "net-contour.yaml" in knative_deploy_text


# ===================================================================
# Deploy script — ingress configuration
# Validates: Requirements 4.1, 4.2
# ===================================================================


class TestDeployIngressConfiguration:
    """Deploy script configures Knative ingress with Contour."""

    def test_contour_ingress_class(self, knative_deploy_text):
        assert "contour.ingress.networking.knative.dev" in knative_deploy_text

    def test_external_domain_tls_disabled(self, knative_deploy_text):
        assert "external-domain-tls" in knative_deploy_text


# ===================================================================
# Deploy script — DNS configuration
# Validates: Requirements 5.1, 5.2
# ===================================================================


class TestDeployDNSConfiguration:
    """Deploy script configures sslip.io DNS."""

    def test_sslip_io_reference(self, knative_deploy_text):
        assert "sslip.io" in knative_deploy_text

    def test_config_domain_reference(self, knative_deploy_text):
        assert "config-domain" in knative_deploy_text


# ===================================================================
# Deploy script — DSM provisioning commands
# Validates: Requirements 1.1, 11.2
# ===================================================================


class TestDeployDSMProvisioning:
    """Deploy script contains DSM PostgresCluster provisioning commands."""

    def test_dsm_api_group(self, knative_deploy_text):
        assert "databases.dataservices.vmware.com" in knative_deploy_text

    def test_postgrescluster_kind(self, knative_deploy_text):
        assert "kind: PostgresCluster" in knative_deploy_text

    def test_vcf_context_create(self, knative_deploy_text):
        assert "vcf context create" in knative_deploy_text


# ===================================================================
# Deploy script — RBAC definitions
# Validates: Requirements 6.1, 6.2, 6.3, 11.3
# ===================================================================


class TestDeployRBACDefinitions:
    """Deploy script contains RBAC resource definitions."""

    def test_service_account(self, knative_deploy_text):
        assert "kind: ServiceAccount" in knative_deploy_text

    def test_role(self, knative_deploy_text):
        assert "kind: Role" in knative_deploy_text

    def test_role_binding(self, knative_deploy_text):
        assert "kind: RoleBinding" in knative_deploy_text

    def test_dashboard_sa_name(self, knative_deploy_text):
        assert "knative-dashboard-sa" in knative_deploy_text


# ===================================================================
# Deploy script — API server Deployment and Service
# Validates: Requirements 2.1, 11.4
# ===================================================================


class TestDeployAPIServer:
    """Deploy script contains API server Deployment and Service definitions."""

    def test_api_server_deployment(self, knative_deploy_text):
        assert "knative-api-server" in knative_deploy_text

    def test_api_server_cluster_ip(self, knative_deploy_text):
        assert "type: ClusterIP" in knative_deploy_text

    def test_api_image_reference(self, knative_deploy_text):
        assert "API_IMAGE" in knative_deploy_text


# ===================================================================
# Deploy script — audit function
# Validates: Requirements 6.1, 6.4, 13.9
# ===================================================================


class TestDeployAuditFunction:
    """Deploy script deploys the asset-audit Knative Service."""

    def test_asset_audit_knative_service(self, knative_deploy_text):
        assert "asset-audit" in knative_deploy_text

    def test_knative_service_kind(self, knative_deploy_text):
        assert "kind: Service" in knative_deploy_text

    def test_serving_knative_dev_api(self, knative_deploy_text):
        assert "serving.knative.dev/v1" in knative_deploy_text


# ===================================================================
# Audit function — PostgreSQL connection logic
# Validates: Requirements 3.2, 4.2, 11.5, 11.9
# ===================================================================


class TestAuditFunctionPostgres:
    """Audit function source contains PostgreSQL connection logic."""

    BASE = os.path.join(os.path.dirname(__file__), "..")

    def _read_audit_server(self):
        path = os.path.join(self.BASE, "examples", "deploy-knative", "audit-function", "server.js")
        with open(path, encoding="utf-8") as f:
            return f.read()

    def test_pg_pool_reference(self):
        text = self._read_audit_server()
        assert "Pool" in text, "Audit function should use pg Pool for database connection"

    def test_postgres_ssl_in_deploy(self, knative_deploy_text):
        """Deploy script sets POSTGRES_SSL to true for audit function."""
        assert 'POSTGRES_SSL' in knative_deploy_text
        assert '"true"' in knative_deploy_text


# ===================================================================
# Deploy script — exit codes 1-9
# Validates: Requirements 7.3, 9.8, 13.3
# ===================================================================


class TestDeployExitCodes:
    """Deploy script defines distinct exit codes 1-9."""

    def test_exit_code_1(self, knative_deploy_text):
        assert re.search(r'exit 1\b', knative_deploy_text)

    def test_exit_code_2(self, knative_deploy_text):
        assert re.search(r'exit 2\b', knative_deploy_text)

    def test_exit_code_3(self, knative_deploy_text):
        assert re.search(r'exit 3\b', knative_deploy_text)

    def test_exit_code_4(self, knative_deploy_text):
        assert re.search(r'exit 4\b', knative_deploy_text)

    def test_exit_code_5(self, knative_deploy_text):
        assert re.search(r'exit 5\b', knative_deploy_text)

    def test_exit_code_6(self, knative_deploy_text):
        assert re.search(r'exit 6\b', knative_deploy_text)

    def test_exit_code_7(self, knative_deploy_text):
        assert re.search(r'exit 7\b', knative_deploy_text)

    def test_exit_code_8(self, knative_deploy_text):
        assert re.search(r'exit 8\b', knative_deploy_text)

    def test_exit_code_9(self, knative_deploy_text):
        assert re.search(r'exit 9\b', knative_deploy_text)


# ===================================================================
# Teardown script — shebang, strict mode, --ignore-not-found, DSM deletion
# Validates: Requirements 8.1, 8.2, 8.3, 10.1, 10.3, 10.7, 11.6, 13.7
# ===================================================================


class TestTeardownScript:
    """Teardown script has correct shebang, strict mode, idempotency, and DSM deletion."""

    def test_first_line_is_bash_shebang(self, knative_teardown_text):
        first_line = knative_teardown_text.splitlines()[0]
        assert first_line == "#!/bin/bash", (
            f"Expected '#!/bin/bash' as first line, got '{first_line}'"
        )

    def test_set_euo_pipefail(self, knative_teardown_text):
        assert "set -euo pipefail" in knative_teardown_text

    def test_ignore_not_found(self, knative_teardown_text):
        assert "--ignore-not-found" in knative_teardown_text

    def test_dsm_postgrescluster_deletion(self, knative_teardown_text):
        """Teardown script contains DSM PostgresCluster deletion commands."""
        assert "delete postgrescluster" in knative_teardown_text

    def test_dsm_secret_deletion(self, knative_teardown_text):
        """Teardown script deletes admin password secret."""
        assert "ADMIN_PASSWORD_SECRET_NAME" in knative_teardown_text

    def test_dsm_variables_in_teardown(self, knative_teardown_text):
        """Teardown script includes DSM/VCF CLI variables."""
        assert "VCF_API_TOKEN" in knative_teardown_text
        assert "VCFA_ENDPOINT" in knative_teardown_text
        assert "SUPERVISOR_NAMESPACE" in knative_teardown_text
        assert "DSM_CLUSTER_NAME" in knative_teardown_text


# ===================================================================
# Workflow content
# Validates: Requirements 9.1, 9.2, 9.3, 9.5, 12.2, 12.3, 13.8
# ===================================================================


class TestWorkflowContent:
    """GitHub Actions workflow has correct triggers, runner, event type, and DSM params."""

    def test_workflow_dispatch_trigger(self, knative_workflow_yaml_text):
        assert "workflow_dispatch" in knative_workflow_yaml_text

    def test_repository_dispatch_trigger(self, knative_workflow_yaml_text):
        assert "repository_dispatch" in knative_workflow_yaml_text

    def test_self_hosted_vcf_runner(self, knative_workflow_yaml_text):
        assert "[self-hosted, vcf]" in knative_workflow_yaml_text

    def test_deploy_knative_event_type(self, knative_workflow_yaml_text):
        assert "deploy-knative" in knative_workflow_yaml_text

    def test_dsm_infra_policy_parameter(self, knative_workflow_yaml_text):
        assert "DSM_INFRA_POLICY" in knative_workflow_yaml_text

    def test_dsm_storage_policy_parameter(self, knative_workflow_yaml_text):
        assert "DSM_STORAGE_POLICY" in knative_workflow_yaml_text

    def test_admin_password_secret(self, knative_workflow_yaml_text):
        assert "ADMIN_PASSWORD" in knative_workflow_yaml_text

    def test_vcf_api_token_secret(self, knative_workflow_yaml_text):
        assert "VCF_API_TOKEN" in knative_workflow_yaml_text

    def test_supervisor_namespace_parameter(self, knative_workflow_yaml_text):
        assert "SUPERVISOR_NAMESPACE" in knative_workflow_yaml_text

    def test_project_name_parameter(self, knative_workflow_yaml_text):
        assert "PROJECT_NAME" in knative_workflow_yaml_text


# ===================================================================
# README content
# Validates: Requirements 10.1, 10.2, 11.3, 11.4, 11.11
# ===================================================================


class TestREADMEContent:
    """README files contain expected section headings and DSM content."""

    BASE = os.path.join(os.path.dirname(__file__), "..")

    def _read_readme_deploy(self):
        path = os.path.join(self.BASE, "examples", "deploy-knative", "README-deploy.md")
        with open(path, encoding="utf-8") as f:
            return f.read()

    def _read_readme_teardown(self):
        path = os.path.join(self.BASE, "examples", "deploy-knative", "README-teardown.md")
        with open(path, encoding="utf-8") as f:
            return f.read()

    def test_deploy_readme_overview(self):
        assert "## Overview" in self._read_readme_deploy()

    def test_deploy_readme_aws_mapping(self):
        text = self._read_readme_deploy()
        assert "AWS" in text

    def test_deploy_readme_rds_to_dsm_mapping(self):
        text = self._read_readme_deploy()
        assert "RDS" in text or "DSM" in text

    def test_deploy_readme_prerequisites(self):
        assert "## Prerequisites" in self._read_readme_deploy()

    def test_deploy_readme_dsm_prerequisite(self):
        text = self._read_readme_deploy()
        assert "DSM" in text or "infrastructure policy" in text

    def test_deploy_readme_exit_codes(self):
        assert "## Exit Codes" in self._read_readme_deploy()

    def test_deploy_readme_troubleshooting(self):
        assert "## Troubleshooting" in self._read_readme_deploy()

    def test_deploy_readme_phase_7(self):
        text = self._read_readme_deploy()
        assert "Phase 7" in text

    def test_deploy_readme_phase_11(self):
        text = self._read_readme_deploy()
        assert "Phase 11" in text

    def test_teardown_readme_overview(self):
        assert "## Overview" in self._read_readme_teardown()

    def test_teardown_readme_idempotency(self):
        assert "## Idempotency" in self._read_readme_teardown()

    def test_teardown_readme_dsm_phase(self):
        text = self._read_readme_teardown()
        assert "DSM" in text or "PostgresCluster" in text
