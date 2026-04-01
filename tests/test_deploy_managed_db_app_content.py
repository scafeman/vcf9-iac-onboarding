"""Content-presence unit tests for VCF 9 Deploy Managed DB App — Infrastructure Asset Tracker."""

import os
import re


# ===================================================================
# File existence tests
# Validates: Requirements 6.1, 7.1, 8.1, 8.2, 9.1, 10.1, 11.1
# ===================================================================


class TestFileExistence:
    """All seven deliverables exist at their expected paths."""

    BASE = os.path.join(os.path.dirname(__file__), "..")

    def test_deploy_script_exists(self):
        assert os.path.isfile(
            os.path.join(self.BASE, "examples", "deploy-managed-db-app", "deploy-managed-db-app.sh")
        )

    def test_teardown_script_exists(self):
        assert os.path.isfile(
            os.path.join(self.BASE, "examples", "deploy-managed-db-app", "teardown-managed-db-app.sh")
        )

    def test_workflow_exists(self):
        assert os.path.isfile(
            os.path.join(self.BASE, ".github", "workflows", "deploy-managed-db-app.yml")
        )

    def test_trigger_script_exists(self):
        assert os.path.isfile(
            os.path.join(self.BASE, "scripts", "trigger-deploy-managed-db-app.sh")
        )

    def test_readme_deploy_exists(self):
        assert os.path.isfile(
            os.path.join(self.BASE, "examples", "deploy-managed-db-app", "README-deploy.md")
        )

    def test_readme_teardown_exists(self):
        assert os.path.isfile(
            os.path.join(self.BASE, "examples", "deploy-managed-db-app", "README-teardown.md")
        )

    def test_sample_manifest_exists(self):
        assert os.path.isfile(
            os.path.join(self.BASE, "examples", "sample-create-postgres-cluster.yaml")
        )


# ===================================================================
# Deploy script — shebang and strict mode
# Validates: Requirements 6.1, 6.6
# ===================================================================


class TestDeployScriptShebangAndStrictMode:
    """Deploy script starts with bash shebang and enables strict mode."""

    def test_first_line_is_bash_shebang(self, managed_db_deploy_text):
        first_line = managed_db_deploy_text.splitlines()[0]
        assert first_line == "#!/bin/bash", (
            f"Expected '#!/bin/bash' as first line, got '{first_line}'"
        )

    def test_set_euo_pipefail(self, managed_db_deploy_text):
        assert "set -euo pipefail" in managed_db_deploy_text


# ===================================================================
# Deploy script — variable block completeness (all DSM vars)
# Validates: Requirements 6.2
# ===================================================================


class TestDeployVariableBlock:
    """Variable block includes all required DSM and shared variables."""

    REQUIRED_VARIABLES = [
        "CLUSTER_NAME",
        "KUBECONFIG_FILE",
        "VCF_API_TOKEN",
        "VCFA_ENDPOINT",
        "TENANT_NAME",
        "CONTEXT_NAME",
        "SUPERVISOR_NAMESPACE",
        "PROJECT_NAME",
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
        "DSM_MAINTENANCE_WINDOW_DAY",
        "DSM_MAINTENANCE_WINDOW_TIME",
        "DSM_MAINTENANCE_WINDOW_DURATION",
        "DSM_SHARED_MEMORY",
        "APP_NAMESPACE",
        "CONTAINER_REGISTRY",
        "IMAGE_TAG",
        "API_PORT",
        "FRONTEND_PORT",
        "DSM_TIMEOUT",
        "POD_TIMEOUT",
        "LB_TIMEOUT",
        "POLL_INTERVAL",
    ]

    def test_all_required_variables_defined(self, managed_db_deploy_text):
        for var in self.REQUIRED_VARIABLES:
            pattern = rf'^{var}='
            assert re.search(pattern, managed_db_deploy_text, re.MULTILINE), (
                f"Required variable '{var}' not defined in deploy script"
            )


# ===================================================================
# Deploy script — 5 phase headers
# Validates: Requirements 6.5
# ===================================================================


class TestAllDeploymentPhasesPresent:
    """All 5 deployment phases are present in the deploy script."""

    def test_phase_1_dsm_provisioning(self, managed_db_deploy_text):
        assert re.search(r"Phase 1.*DSM.*PostgresCluster", managed_db_deploy_text, re.IGNORECASE), (
            "Phase 1 (DSM PostgresCluster provisioning) marker not found"
        )

    def test_phase_2_image_build(self, managed_db_deploy_text):
        assert re.search(r"Phase 2.*Build.*Push.*Container.*Image", managed_db_deploy_text, re.IGNORECASE), (
            "Phase 2 (image build/push) marker not found"
        )

    def test_phase_3_api_deploy(self, managed_db_deploy_text):
        assert re.search(r"Phase 3.*Deploy.*API", managed_db_deploy_text, re.IGNORECASE), (
            "Phase 3 (API deploy) marker not found"
        )

    def test_phase_4_frontend_deploy(self, managed_db_deploy_text):
        assert re.search(r"Phase 4.*Deploy.*Frontend", managed_db_deploy_text, re.IGNORECASE), (
            "Phase 4 (Frontend deploy) marker not found"
        )

    def test_phase_5_connectivity(self, managed_db_deploy_text):
        assert re.search(r"Phase 5.*Connectivity.*Verification", managed_db_deploy_text, re.IGNORECASE), (
            "Phase 5 (connectivity verification) marker not found"
        )


# ===================================================================
# Deploy script — exit codes 0–6
# Validates: Requirements 6.7
# ===================================================================


class TestDeployExitCodes:
    """Deploy script defines exit codes 0 through 6."""

    def test_exit_0_present(self, managed_db_deploy_text):
        assert re.search(r"\bexit\s+0\b", managed_db_deploy_text), "exit 0 not found"

    def test_exit_1_present(self, managed_db_deploy_text):
        assert re.search(r"\bexit\s+1\b", managed_db_deploy_text), "exit 1 not found"

    def test_exit_2_present(self, managed_db_deploy_text):
        assert re.search(r"\bexit\s+2\b", managed_db_deploy_text), "exit 2 not found"

    def test_exit_3_present(self, managed_db_deploy_text):
        assert re.search(r"\bexit\s+3\b", managed_db_deploy_text), "exit 3 not found"

    def test_exit_4_present(self, managed_db_deploy_text):
        assert re.search(r"\bexit\s+4\b", managed_db_deploy_text), "exit 4 not found"

    def test_exit_5_present(self, managed_db_deploy_text):
        assert re.search(r"\bexit\s+5\b", managed_db_deploy_text), "exit 5 not found"

    def test_exit_6_present(self, managed_db_deploy_text):
        assert re.search(r"\bexit\s+6\b", managed_db_deploy_text), "exit 6 not found"


# ===================================================================
# Deploy script — PostgresCluster apiVersion and DSM labels
# Validates: Requirements 1.2, 1.3
# ===================================================================


class TestPostgresClusterManifest:
    """Deploy script contains correct PostgresCluster apiVersion and DSM labels."""

    def test_postgres_cluster_api_version(self, managed_db_deploy_text):
        assert "databases.dataservices.vmware.com/v1alpha1" in managed_db_deploy_text

    def test_postgres_cluster_kind(self, managed_db_deploy_text):
        assert "kind: PostgresCluster" in managed_db_deploy_text

    DSM_LABELS = [
        "dsm.vmware.com/infra-policy",
        "dsm.vmware.com/vm-class",
        "dsm.vmware.com/admin-password-name",
        "dsm.vmware.com/consumption-namespace",
    ]

    def test_all_dsm_labels_present(self, managed_db_deploy_text):
        for label in self.DSM_LABELS:
            assert label in managed_db_deploy_text, (
                f"DSM label '{label}' not found in deploy script"
            )


# ===================================================================
# Deploy script — PostgresCluster spec fields
# Validates: Requirements 1.4
# ===================================================================


class TestPostgresClusterSpecFields:
    """Deploy script PostgresCluster manifest includes all required spec fields."""

    SPEC_FIELDS = [
        "adminUsername",
        "adminPasswordRef",
        "databaseName",
        "infrastructurePolicy",
        "version",
        "replicas",
        "vmClass",
        "storagePolicyName",
        "storageSpace",
        "maintenanceWindow",
        "requestedSharedMemorySize",
        "blockDatabaseConnections",
    ]

    def test_all_spec_fields_present(self, managed_db_deploy_text):
        for field in self.SPEC_FIELDS:
            assert field in managed_db_deploy_text, (
                f"Spec field '{field}' not found in deploy script"
            )


# ===================================================================
# Deploy script — idempotency check
# Validates: Requirements 1.5
# ===================================================================


class TestDeployIdempotencyCheck:
    """Deploy script contains idempotency check for PostgresCluster."""

    def test_postgrescluster_idempotency_check(self, managed_db_deploy_text):
        assert "kubectl get postgrescluster" in managed_db_deploy_text, (
            "Idempotency check for PostgresCluster not found"
        )


# ===================================================================
# Teardown script — shebang, strict mode, 3-phase order, --ignore-not-found
# Validates: Requirements 7.1, 7.2, 7.3, 7.7
# ===================================================================


class TestTeardownScriptShebangAndStrictMode:
    """Teardown script starts with bash shebang and enables strict mode."""

    def test_first_line_is_bash_shebang(self, managed_db_teardown_text):
        first_line = managed_db_teardown_text.splitlines()[0]
        assert first_line == "#!/bin/bash", (
            f"Expected '#!/bin/bash' as first line, got '{first_line}'"
        )

    def test_set_euo_pipefail(self, managed_db_teardown_text):
        assert "set -euo pipefail" in managed_db_teardown_text


class TestTeardownDeletionOrder:
    """Teardown deletes namespace before postgrescluster before admin-password secret."""

    def test_namespace_before_postgrescluster(self, managed_db_teardown_text):
        ns_pos = managed_db_teardown_text.index("delete ns")
        pg_pos = managed_db_teardown_text.index("delete postgrescluster")
        assert ns_pos < pg_pos, "Namespace must be deleted before PostgresCluster"

    def test_postgrescluster_before_secret(self, managed_db_teardown_text):
        pg_pos = managed_db_teardown_text.index("delete postgrescluster")
        secret_pos = managed_db_teardown_text.index("delete secret")
        assert pg_pos < secret_pos, "PostgresCluster must be deleted before admin password Secret"


class TestTeardownIgnoreNotFound:
    """All kubectl delete commands use --ignore-not-found."""

    def test_all_deletes_use_ignore_not_found(self, managed_db_teardown_text):
        delete_lines = [
            line.strip()
            for line in managed_db_teardown_text.splitlines()
            if re.search(r"kubectl\s+delete\b", line)
        ]
        assert len(delete_lines) > 0, "No kubectl delete commands found"
        for line in delete_lines:
            assert "--ignore-not-found" in line, (
                f"kubectl delete missing --ignore-not-found: {line}"
            )


# ===================================================================
# Sample manifest — apiVersion, kind, DSM labels, spec fields
# Validates: Requirements 11.1, 11.2, 11.3, 11.4, 11.5
# ===================================================================


class TestSampleManifestContent:
    """Sample PostgresCluster manifest has correct structure and content."""

    def test_api_version(self, managed_db_sample_manifest_text):
        assert "databases.dataservices.vmware.com/v1alpha1" in managed_db_sample_manifest_text

    def test_kind(self, managed_db_sample_manifest_text):
        assert "kind: PostgresCluster" in managed_db_sample_manifest_text

    DSM_LABELS = [
        "dsm.vmware.com/infra-policy",
        "dsm.vmware.com/vm-class",
        "dsm.vmware.com/admin-password-name",
        "dsm.vmware.com/consumption-namespace",
    ]

    def test_all_dsm_labels_present(self, managed_db_sample_manifest_text):
        for label in self.DSM_LABELS:
            assert label in managed_db_sample_manifest_text, (
                f"DSM label '{label}' not found in sample manifest"
            )

    SPEC_FIELDS = [
        "adminUsername",
        "adminPasswordRef",
        "databaseName",
        "infrastructurePolicy",
        "version",
        "replicas",
        "vmClass",
        "storagePolicyName",
        "storageSpace",
        "maintenanceWindow",
        "requestedSharedMemorySize",
        "blockDatabaseConnections",
    ]

    def test_all_spec_fields_present(self, managed_db_sample_manifest_text):
        for field in self.SPEC_FIELDS:
            assert field in managed_db_sample_manifest_text, (
                f"Spec field '{field}' not found in sample manifest"
            )


# ===================================================================
# Workflow — name, triggers, runner, step names
# Validates: Requirements 9.1, 9.2, 9.3, 9.4
# ===================================================================


class TestWorkflowContent:
    """GitHub Actions workflow has correct name, triggers, runner, and steps."""

    def test_workflow_name(self, managed_db_workflow_yaml):
        assert managed_db_workflow_yaml["name"] == "Deploy Managed DB App"

    def test_workflow_dispatch_trigger(self, managed_db_workflow_yaml_text):
        assert "workflow_dispatch" in managed_db_workflow_yaml_text

    def test_repository_dispatch_trigger(self, managed_db_workflow_yaml_text):
        assert "repository_dispatch" in managed_db_workflow_yaml_text

    def test_deploy_managed_db_app_event_type(self, managed_db_workflow_yaml_text):
        assert "deploy-managed-db-app" in managed_db_workflow_yaml_text

    def test_self_hosted_vcf_runner(self, managed_db_workflow_yaml_text):
        assert "[self-hosted, vcf]" in managed_db_workflow_yaml_text

    REQUIRED_STEP_NAMES = [
        "Checkout Repository",
        "Validate Inputs",
        "Provision PostgresCluster",
        "Deploy API Service",
        "Deploy Frontend Service",
    ]

    def test_all_required_step_names(self, managed_db_workflow_yaml_text):
        for step_name in self.REQUIRED_STEP_NAMES:
            assert step_name in managed_db_workflow_yaml_text, (
                f"Workflow missing step name '{step_name}'"
            )


# ===================================================================
# Trigger script — event_type and required args
# Validates: Requirements 10.1, 10.2, 10.4, 10.5
# ===================================================================


class TestTriggerScriptContent:
    """Trigger script has correct event_type and required arguments."""

    def test_event_type(self, managed_db_trigger_script_text):
        assert "deploy-managed-db-app" in managed_db_trigger_script_text

    def test_required_arg_repo(self, managed_db_trigger_script_text):
        assert "--repo" in managed_db_trigger_script_text

    def test_required_arg_token(self, managed_db_trigger_script_text):
        assert "--token" in managed_db_trigger_script_text

    def test_required_arg_cluster_name(self, managed_db_trigger_script_text):
        assert "--cluster-name" in managed_db_trigger_script_text

    def test_validates_required_args(self, managed_db_trigger_script_text):
        assert re.search(r"Missing.*required", managed_db_trigger_script_text, re.IGNORECASE), (
            "Trigger script missing required argument validation"
        )


# ===================================================================
# README-deploy.md — all required sections including AWS to VCF Mapping
# Validates: Requirements 8.1, 8.3, 8.4
# ===================================================================


class TestReadmeDeploySections:
    """README-deploy.md contains all required sections."""

    REQUIRED_SECTIONS = [
        "Overview",
        "Prerequisites",
        "What the Script Does",
        "AWS to VCF Mapping",
        "Required Environment Variables",
        "How to Trigger",
        "Expected Output",
        "Typical Timing",
        "Exit Codes",
        "Troubleshooting",
    ]

    def test_all_required_sections(self, managed_db_readme_deploy_text):
        for section in self.REQUIRED_SECTIONS:
            assert re.search(rf"^#+\s+.*{re.escape(section)}", managed_db_readme_deploy_text, re.MULTILINE), (
                f"README-deploy.md missing section '{section}'"
            )


# ===================================================================
# README-teardown.md — all required sections
# Validates: Requirements 8.2, 8.5
# ===================================================================


class TestReadmeTeardownSections:
    """README-teardown.md contains all required sections."""

    REQUIRED_SECTIONS = [
        "Overview",
        "What the Script Does",
        "Prerequisites",
        "Required Environment Variables",
        "How to Trigger",
        "Expected Output",
        "Typical Timing",
        "Idempotency",
    ]

    def test_all_required_sections(self, managed_db_readme_teardown_text):
        for section in self.REQUIRED_SECTIONS:
            assert re.search(rf"^#+\s+.*{re.escape(section)}", managed_db_readme_teardown_text, re.MULTILINE), (
                f"README-teardown.md missing section '{section}'"
            )
