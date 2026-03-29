"""Content-presence unit tests for VCF 9 Deploy VM App — Infrastructure Asset Tracker."""

import os
import re


SCRIPT_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "deploy-vm-app", "deploy-vm-app.sh"
)


# ===================================================================
# Deploy script structure tests
# Validates: Requirements 1.1, 1.2, 1.7
# ===================================================================


class TestDeployScriptFileExists:
    """Script file exists at the expected location.
    Validates: Requirement 1.1"""

    def test_script_file_exists(self):
        assert os.path.isfile(SCRIPT_PATH), (
            "Script not found at examples/deploy-vm-app/deploy-vm-app.sh"
        )


class TestDeployScriptShebangAndStrictMode:
    """Script starts with bash shebang and enables strict mode.
    Validates: Requirements 1.1, 1.2"""

    def test_first_line_is_bash_shebang(self, vm_app_deploy_text):
        first_line = vm_app_deploy_text.splitlines()[0]
        assert first_line == "#!/bin/bash", (
            f"Expected '#!/bin/bash' as first line, got '{first_line}'"
        )

    def test_set_euo_pipefail(self, vm_app_deploy_text):
        assert "set -euo pipefail" in vm_app_deploy_text, (
            "Script does not contain 'set -euo pipefail'"
        )


class TestVariableBlockContainsAllRequired:
    """Variable block includes all required variables.
    Validates: Requirements 1.2, 1.7"""

    REQUIRED_VARIABLES = [
        "CLUSTER_NAME",
        "SUPERVISOR_NAMESPACE",
        "PROJECT_NAME",
        "VM_CLASS",
        "VM_IMAGE",
        "VM_CONTENT_LIBRARY_ID",
        "POSTGRES_USER",
        "POSTGRES_PASSWORD",
        "POSTGRES_DB",
        "VM_NAME",
        "APP_NAMESPACE",
        "CONTAINER_REGISTRY",
        "IMAGE_TAG",
        "API_PORT",
        "FRONTEND_PORT",
        "VM_TIMEOUT",
        "POD_TIMEOUT",
        "LB_TIMEOUT",
        "POLL_INTERVAL",
    ]

    def test_all_required_variables_defined(self, vm_app_deploy_text):
        for var in self.REQUIRED_VARIABLES:
            pattern = rf'^{var}='
            assert re.search(pattern, vm_app_deploy_text, re.MULTILINE), (
                f"Required variable '{var}' not defined in script"
            )


# ===================================================================
# Deployment phases present
# Validates: Requirements 1.1, 11.1
# ===================================================================


class TestAllDeploymentPhasesPresent:
    """All 5 deployment phases are present in the deploy script.
    Validates: Requirements 1.1, 11.1"""

    def test_phase_1_vm_provisioning(self, vm_app_deploy_text):
        assert re.search(r"Phase 1.*Provision.*PostgreSQL.*VM", vm_app_deploy_text, re.IGNORECASE), (
            "Phase 1 (VM provisioning) marker not found in deploy script"
        )

    def test_phase_2_image_build(self, vm_app_deploy_text):
        assert re.search(r"Phase 2.*Build.*Push.*Container.*Image", vm_app_deploy_text, re.IGNORECASE), (
            "Phase 2 (image build/push) marker not found in deploy script"
        )

    def test_phase_3_api_deploy(self, vm_app_deploy_text):
        assert re.search(r"Phase 3.*Deploy.*API", vm_app_deploy_text, re.IGNORECASE), (
            "Phase 3 (API deploy) marker not found in deploy script"
        )

    def test_phase_4_frontend_deploy(self, vm_app_deploy_text):
        assert re.search(r"Phase 4.*Deploy.*Frontend", vm_app_deploy_text, re.IGNORECASE), (
            "Phase 4 (Frontend deploy) marker not found in deploy script"
        )

    def test_phase_5_connectivity_verification(self, vm_app_deploy_text):
        assert re.search(r"Phase 5.*Connectivity.*Verification", vm_app_deploy_text, re.IGNORECASE), (
            "Phase 5 (connectivity verification) marker not found in deploy script"
        )


# ===================================================================
# VirtualMachine manifest content
# Validates: Requirements 1.1, 1.2, 1.3, 11.6
# ===================================================================


class TestVirtualMachineManifest:
    """VirtualMachine manifest contains correct apiVersion and kind.
    Validates: Requirements 1.1, 1.2, 11.6"""

    def test_vm_api_version(self, vm_app_deploy_text):
        assert "vmoperator.vmware.com/v1alpha3" in vm_app_deploy_text, (
            "Deploy script missing VirtualMachine apiVersion 'vmoperator.vmware.com/v1alpha3'"
        )

    def test_vm_kind(self, vm_app_deploy_text):
        assert "kind: VirtualMachine" in vm_app_deploy_text, (
            "Deploy script missing 'kind: VirtualMachine'"
        )


class TestCloudInitPostgreSQLConfig:
    """Cloud-init references PostgreSQL 16, pg_hba.conf, postgresql.conf.
    Validates: Requirement 1.3"""

    def test_cloud_init_postgresql_16(self, vm_app_deploy_text):
        assert "postgresql-16" in vm_app_deploy_text, (
            "Deploy script cloud-init missing 'postgresql-16' reference"
        )

    def test_cloud_init_pg_hba_conf(self, vm_app_deploy_text):
        assert "pg_hba.conf" in vm_app_deploy_text, (
            "Deploy script cloud-init missing 'pg_hba.conf' reference"
        )

    def test_cloud_init_postgresql_conf(self, vm_app_deploy_text):
        assert "postgresql.conf" in vm_app_deploy_text, (
            "Deploy script cloud-init missing 'postgresql.conf' reference"
        )


# ===================================================================
# API Deployment content
# Validates: Requirements 2.4, 2.6
# ===================================================================


class TestAPIDeploymentContent:
    """API Deployment contains readiness probe targeting /healthz.
    Validates: Requirements 2.4, 2.6"""

    def test_readiness_probe_healthz(self, vm_app_deploy_text):
        assert "readinessProbe" in vm_app_deploy_text, (
            "Deploy script missing 'readinessProbe' in API Deployment"
        )
        assert "/healthz" in vm_app_deploy_text, (
            "Deploy script missing '/healthz' path in readiness probe"
        )


# ===================================================================
# Frontend Service content
# Validates: Requirements 3.9
# ===================================================================


class TestFrontendServiceContent:
    """Frontend Service contains LoadBalancer type, port 80, targetPort.
    Validates: Requirement 3.9"""

    def test_frontend_service_type_loadbalancer(self, vm_app_deploy_text):
        assert "type: LoadBalancer" in vm_app_deploy_text, (
            "Deploy script missing 'type: LoadBalancer' in Frontend Service"
        )

    def test_frontend_service_port_80(self, vm_app_deploy_text):
        assert re.search(r"port:\s*80", vm_app_deploy_text), (
            "Deploy script missing 'port: 80' in Frontend Service"
        )

    def test_frontend_service_target_port(self, vm_app_deploy_text):
        assert re.search(r"targetPort:", vm_app_deploy_text), (
            "Deploy script missing 'targetPort' in Frontend Service"
        )


# ===================================================================
# Teardown script content
# Validates: Requirements 7.1, 7.2
# ===================================================================


class TestTeardownScriptContent:
    """Teardown script contains delete commands and --ignore-not-found.
    Validates: Requirements 7.1, 7.2"""

    def test_teardown_contains_delete_commands(self, vm_app_teardown_text):
        assert re.search(r"kubectl\s+delete", vm_app_teardown_text), (
            "Teardown script missing kubectl delete commands"
        )

    def test_teardown_uses_ignore_not_found(self, vm_app_teardown_text):
        assert "--ignore-not-found" in vm_app_teardown_text, (
            "Teardown script missing '--ignore-not-found' pattern"
        )


# ===================================================================
# GitHub Actions workflow content
# Validates: Requirements 8.1, 8.2, 8.3, 8.5, 11.5
# ===================================================================


class TestWorkflowContent:
    """GitHub Actions workflow contains required triggers, runner, and environment.
    Validates: Requirements 8.1, 8.2, 8.3, 8.5, 11.5"""

    def test_workflow_dispatch_trigger(self, vm_app_workflow_yaml_text):
        assert "workflow_dispatch" in vm_app_workflow_yaml_text, (
            "Workflow missing 'workflow_dispatch' trigger"
        )

    def test_repository_dispatch_trigger(self, vm_app_workflow_yaml_text):
        assert "repository_dispatch" in vm_app_workflow_yaml_text, (
            "Workflow missing 'repository_dispatch' trigger"
        )

    def test_deploy_vm_app_event_type(self, vm_app_workflow_yaml_text):
        assert "deploy-vm-app" in vm_app_workflow_yaml_text, (
            "Workflow missing 'deploy-vm-app' event type"
        )

    def test_self_hosted_vcf_runner(self, vm_app_workflow_yaml_text):
        assert "[self-hosted, vcf]" in vm_app_workflow_yaml_text, (
            "Workflow missing '[self-hosted, vcf]' runner labels"
        )

    def test_vcf_production_environment(self, vm_app_workflow_yaml_text):
        assert "vcf-production" in vm_app_workflow_yaml_text, (
            "Workflow missing 'vcf-production' environment"
        )

    def test_workflow_calls_deploy_script(self, vm_app_workflow_yaml_text):
        assert "bash examples/deploy-vm-app/deploy-vm-app.sh" in vm_app_workflow_yaml_text or \
            "Deploy API Service" in vm_app_workflow_yaml_text, (
            "Workflow missing deploy steps (either script call or inline steps)"
        )


# ===================================================================
# Trigger script content
# Validates: Requirements 9.1, 9.2, 9.3
# ===================================================================


class TestTriggerScriptContent:
    """Trigger script contains deploy-vm-app event type and required argument validation.
    Validates: Requirements 9.1, 9.2, 9.3"""

    def test_trigger_event_type(self, vm_app_trigger_script_text):
        assert "deploy-vm-app" in vm_app_trigger_script_text, (
            "Trigger script missing 'deploy-vm-app' event type"
        )

    def test_trigger_required_arg_repo(self, vm_app_trigger_script_text):
        assert "--repo" in vm_app_trigger_script_text, (
            "Trigger script missing '--repo' argument"
        )

    def test_trigger_required_arg_token(self, vm_app_trigger_script_text):
        assert "--token" in vm_app_trigger_script_text, (
            "Trigger script missing '--token' argument"
        )

    def test_trigger_required_arg_cluster_name(self, vm_app_trigger_script_text):
        assert "--cluster-name" in vm_app_trigger_script_text, (
            "Trigger script missing '--cluster-name' argument"
        )

    def test_trigger_validates_required_args(self, vm_app_trigger_script_text):
        """Trigger script validates that required arguments are provided."""
        assert re.search(r"Missing.*required", vm_app_trigger_script_text, re.IGNORECASE), (
            "Trigger script missing required argument validation"
        )
