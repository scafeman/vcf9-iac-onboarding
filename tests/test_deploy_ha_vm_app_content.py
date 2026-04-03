"""Content-presence unit tests for VCF 9 Deploy HA VM App — High-Availability Three-Tier Application."""

import os
import re


# ===================================================================
# File existence tests
# Validates: Requirements 9.1, 10.1, 11.1
# ===================================================================


class TestFileExistence:
    """Deploy script, teardown script, and workflow exist at expected paths."""

    BASE = os.path.join(os.path.dirname(__file__), "..")

    def test_deploy_script_exists(self):
        assert os.path.isfile(
            os.path.join(self.BASE, "examples", "deploy-ha-vm-app", "deploy-ha-vm-app.sh")
        )

    def test_teardown_script_exists(self):
        assert os.path.isfile(
            os.path.join(self.BASE, "examples", "deploy-ha-vm-app", "teardown-ha-vm-app.sh")
        )

    def test_workflow_exists(self):
        assert os.path.isfile(
            os.path.join(self.BASE, ".github", "workflows", "deploy-ha-vm-app.yml")
        )


# ===================================================================
# Deploy script — shebang and strict mode
# Validates: Requirements 9.1, 9.6
# ===================================================================


class TestDeployScriptShebangAndStrictMode:
    """Deploy script starts with bash shebang and enables strict mode."""

    def test_first_line_is_bash_shebang(self, ha_vm_app_deploy_text):
        first_line = ha_vm_app_deploy_text.splitlines()[0]
        assert first_line == "#!/bin/bash", (
            f"Expected '#!/bin/bash' as first line, got '{first_line}'"
        )

    def test_set_euo_pipefail(self, ha_vm_app_deploy_text):
        assert "set -euo pipefail" in ha_vm_app_deploy_text


# ===================================================================
# Deploy script — variable block completeness
# Validates: Requirements 9.4
# ===================================================================


class TestDeployVariableBlock:
    """Variable block includes all required variables."""

    REQUIRED_VARIABLES = [
        "CLUSTER_NAME",
        "KUBECONFIG_FILE",
        "VCF_API_TOKEN",
        "VCFA_ENDPOINT",
        "TENANT_NAME",
        "CONTEXT_NAME",
        "SUPERVISOR_NAMESPACE",
        "PROJECT_NAME",
        "VM_CLASS",
        "VM_IMAGE",
        "STORAGE_CLASS",
        "DSM_CLUSTER_NAME",
        "DSM_INFRA_POLICY",
        "DSM_VM_CLASS",
        "DSM_STORAGE_POLICY",
        "DSM_STORAGE_SPACE",
        "POSTGRES_VERSION",
        "POSTGRES_REPLICAS",
        "POSTGRES_DB",
        "ADMIN_PASSWORD_SECRET_NAME",
        "ADMIN_PASSWORD",
        "API_PORT",
        "FRONTEND_PORT",
        "CONTAINER_REGISTRY",
        "IMAGE_TAG",
        "VM_TIMEOUT",
        "DSM_TIMEOUT",
        "LB_TIMEOUT",
        "POLL_INTERVAL",
    ]

    def test_all_required_variables_defined(self, ha_vm_app_deploy_text):
        for var in self.REQUIRED_VARIABLES:
            pattern = rf'^{var}='
            assert re.search(pattern, ha_vm_app_deploy_text, re.MULTILINE), (
                f"Required variable '{var}' not defined in deploy script"
            )


# ===================================================================
# Deploy script — helper functions
# Validates: Requirements 9.6
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

    def test_all_helper_functions_defined(self, ha_vm_app_deploy_text):
        for func in self.REQUIRED_FUNCTIONS:
            pattern = rf'^{func}\(\)'
            assert re.search(pattern, ha_vm_app_deploy_text, re.MULTILINE), (
                f"Helper function '{func}' not defined in deploy script"
            )


# ===================================================================
# Deploy script — VirtualMachine manifests
# Validates: Requirements 1.1, 2.1
# ===================================================================


class TestDeployVirtualMachineManifests:
    """Deploy script contains VirtualMachine manifests for all four VMs."""

    def test_web_vm_01_present(self, ha_vm_app_deploy_text):
        assert "web-vm-01" in ha_vm_app_deploy_text

    def test_web_vm_02_present(self, ha_vm_app_deploy_text):
        assert "web-vm-02" in ha_vm_app_deploy_text

    def test_api_vm_01_present(self, ha_vm_app_deploy_text):
        assert "api-vm-01" in ha_vm_app_deploy_text

    def test_api_vm_02_present(self, ha_vm_app_deploy_text):
        assert "api-vm-02" in ha_vm_app_deploy_text


# ===================================================================
# Deploy script — VirtualMachineService manifests
# Validates: Requirements 4.1, 5.1
# ===================================================================


class TestDeployVirtualMachineServiceManifests:
    """Deploy script contains VirtualMachineService manifests for ha-web-lb and ha-api-internal."""

    def test_ha_web_lb_present(self, ha_vm_app_deploy_text):
        assert "ha-web-lb" in ha_vm_app_deploy_text

    def test_ha_web_lb_is_load_balancer(self, ha_vm_app_deploy_text):
        assert "type: LoadBalancer" in ha_vm_app_deploy_text

    def test_ha_api_internal_present(self, ha_vm_app_deploy_text):
        assert "ha-api-internal" in ha_vm_app_deploy_text

    def test_ha_api_internal_is_load_balancer(self, ha_vm_app_deploy_text):
        # API service must be LoadBalancer (not ClusterIP) so web VMs can reach it via routable IP
        assert ha_vm_app_deploy_text.count("type: LoadBalancer") >= 2, (
            "Deploy script should have at least 2 LoadBalancer services (web LB + API LB)"
        )


# ===================================================================
# Deploy script — PostgresCluster manifest
# Validates: Requirements 3.1, 3.2
# ===================================================================


class TestDeployPostgresClusterManifest:
    """Deploy script contains PostgresCluster CRD manifest with DSM pattern."""

    def test_postgres_cluster_api_version(self, ha_vm_app_deploy_text):
        assert "databases.dataservices.vmware.com/v1alpha1" in ha_vm_app_deploy_text

    def test_postgres_cluster_kind(self, ha_vm_app_deploy_text):
        assert "kind: PostgresCluster" in ha_vm_app_deploy_text


# ===================================================================
# Deploy script — cloud-init content
# Validates: Requirements 1.2, 2.2
# ===================================================================


class TestDeployCloudInit:
    """Cloud-init content installs nodejs and npm for web and API VMs."""

    def test_nodejs_in_cloud_init(self, ha_vm_app_deploy_text):
        assert "nodejs" in ha_vm_app_deploy_text

    def test_npm_install_in_cloud_init(self, ha_vm_app_deploy_text):
        assert "npm install" in ha_vm_app_deploy_text


# ===================================================================
# Deploy script — label selectors
# Validates: Requirements 1.6, 2.6, 4.2, 5.2
# ===================================================================


class TestDeployLabelSelectors:
    """Deploy script uses correct app labels for web and API tiers."""

    def test_ha_web_label(self, ha_vm_app_deploy_text):
        assert "app: ${WEB_APP_LABEL}" in ha_vm_app_deploy_text or "app: ha-web" in ha_vm_app_deploy_text

    def test_ha_api_label(self, ha_vm_app_deploy_text):
        assert "app: ${API_APP_LABEL}" in ha_vm_app_deploy_text or "app: ha-api" in ha_vm_app_deploy_text


# ===================================================================
# Deploy script — port mappings
# Validates: Requirements 4.3, 5.3
# ===================================================================


class TestDeployPortMappings:
    """Deploy script maps port 80 → FRONTEND_PORT and API_PORT → API_PORT."""

    def test_web_lb_port_80(self, ha_vm_app_deploy_text):
        assert "port: 80" in ha_vm_app_deploy_text

    def test_web_lb_target_frontend_port(self, ha_vm_app_deploy_text):
        assert "targetPort: ${FRONTEND_PORT}" in ha_vm_app_deploy_text

    def test_api_port_mapping(self, ha_vm_app_deploy_text):
        assert "port: ${API_PORT}" in ha_vm_app_deploy_text

    def test_api_target_port_mapping(self, ha_vm_app_deploy_text):
        assert "targetPort: ${API_PORT}" in ha_vm_app_deploy_text


# ===================================================================
# Deploy script — connectivity verification
# Validates: Requirements 8.1, 8.2
# ===================================================================


class TestDeployConnectivityVerification:
    """Deploy script verifies connectivity to frontend and API healthz."""

    def test_curl_to_frontend(self, ha_vm_app_deploy_text):
        assert re.search(r'curl.*\$\{?WEB_LB_IP\}?', ha_vm_app_deploy_text), (
            "Deploy script should curl to the Web LB IP for frontend verification"
        )

    def test_curl_to_api_healthz(self, ha_vm_app_deploy_text):
        assert "healthz" in ha_vm_app_deploy_text, (
            "Deploy script should verify API healthz endpoint"
        )


# ===================================================================
# Deploy script — success summary
# Validates: Requirements 9.7
# ===================================================================


class TestDeploySuccessSummary:
    """Deploy script prints a success summary block."""

    def test_success_summary_present(self, ha_vm_app_deploy_text):
        assert "Deployment Complete" in ha_vm_app_deploy_text


# ===================================================================
# Teardown script — shebang, strict mode, reverse dependency order
# Validates: Requirements 10.1, 10.7
# ===================================================================


class TestTeardownScript:
    """Teardown script has correct shebang, strict mode, and reverse dependency order."""

    def test_first_line_is_bash_shebang(self, ha_vm_app_teardown_text):
        first_line = ha_vm_app_teardown_text.splitlines()[0]
        assert first_line == "#!/bin/bash", (
            f"Expected '#!/bin/bash' as first line, got '{first_line}'"
        )

    def test_set_euo_pipefail(self, ha_vm_app_teardown_text):
        assert "set -euo pipefail" in ha_vm_app_teardown_text

    def test_ha_web_lb_before_web_vm(self, ha_vm_app_teardown_text):
        lb_pos = ha_vm_app_teardown_text.index("ha-web-lb")
        web_vm_positions = [m.start() for m in re.finditer(r"delete virtualmachine.*web-vm", ha_vm_app_teardown_text, re.IGNORECASE)]
        if web_vm_positions:
            assert lb_pos < min(web_vm_positions), (
                "ha-web-lb must be deleted before web VMs"
            )

    def test_web_vm_before_ha_api_internal(self, ha_vm_app_teardown_text):
        # Find the web-vm deletion phase and ha-api-internal deletion phase
        web_vm_positions = [m.start() for m in re.finditer(r"web-vm-0[12]", ha_vm_app_teardown_text)]
        api_svc_positions = [m.start() for m in re.finditer(r"ha-api-internal", ha_vm_app_teardown_text)]
        if web_vm_positions and api_svc_positions:
            assert min(web_vm_positions) < max(api_svc_positions), (
                "web VMs must be deleted before ha-api-internal"
            )

    def test_ha_api_internal_before_api_vm(self, ha_vm_app_teardown_text):
        api_svc_pos = ha_vm_app_teardown_text.index("ha-api-internal")
        api_vm_positions = [m.start() for m in re.finditer(r"delete virtualmachine.*api-vm", ha_vm_app_teardown_text, re.IGNORECASE)]
        if api_vm_positions:
            assert api_svc_pos < min(api_vm_positions), (
                "ha-api-internal must be deleted before api VMs"
            )

    def test_api_vm_before_postgrescluster(self, ha_vm_app_teardown_text):
        api_vm_positions = [m.start() for m in re.finditer(r"api-vm-0[12]", ha_vm_app_teardown_text)]
        pg_positions = [m.start() for m in re.finditer(r"postgrescluster", ha_vm_app_teardown_text, re.IGNORECASE)]
        if api_vm_positions and pg_positions:
            assert min(api_vm_positions) < max(pg_positions), (
                "api VMs must be deleted before PostgresCluster"
            )


# ===================================================================
# Workflow content
# Validates: Requirements 11.1, 11.2, 11.4
# ===================================================================


class TestWorkflowContent:
    """GitHub Actions workflow has correct triggers, runner, and event type."""

    def test_workflow_dispatch_trigger(self, ha_vm_app_workflow_yaml_text):
        assert "workflow_dispatch" in ha_vm_app_workflow_yaml_text

    def test_repository_dispatch_trigger(self, ha_vm_app_workflow_yaml_text):
        assert "repository_dispatch" in ha_vm_app_workflow_yaml_text

    def test_self_hosted_vcf_runner(self, ha_vm_app_workflow_yaml_text):
        assert "[self-hosted, vcf]" in ha_vm_app_workflow_yaml_text

    def test_deploy_ha_vm_app_event_type(self, ha_vm_app_workflow_yaml_text):
        assert "deploy-ha-vm-app" in ha_vm_app_workflow_yaml_text


# ===================================================================
# API server — X-Served-By header
# Validates: Requirements 12.4
# ===================================================================


class TestApiServerXServedBy:
    """API server includes X-Served-By header with os.hostname()."""

    def test_x_served_by_header(self, ha_vm_app_api_server_text):
        assert "X-Served-By" in ha_vm_app_api_server_text

    def test_os_hostname(self, ha_vm_app_api_server_text):
        assert "os.hostname()" in ha_vm_app_api_server_text
