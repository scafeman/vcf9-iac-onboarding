"""Preservation property tests for vault-injector webhook fix.

These tests verify existing correct behaviors BEFORE implementing the fix.
They MUST PASS on unfixed code — they confirm baseline behavior to preserve.

**Validates: Requirements 3.1, 3.2, 3.3, 3.4, 3.5**
"""

import os
import re
import pytest

PROJECT_ROOT = os.path.join(os.path.dirname(__file__), "..")

TEARDOWN_SECRETS_DEMO_SCRIPT = os.path.join(
    PROJECT_ROOT, "examples", "deploy-secrets-demo", "teardown-secrets-demo.sh"
)
TEARDOWN_MANAGED_DB_APP_SCRIPT = os.path.join(
    PROJECT_ROOT, "examples", "deploy-managed-db-app", "teardown-managed-db-app.sh"
)
DEPLOY_SECRETS_DEMO_WORKFLOW = os.path.join(
    PROJECT_ROOT, ".github", "workflows", "deploy-secrets-demo.yml"
)
DEPLOY_MANAGED_DB_APP_WORKFLOW = os.path.join(
    PROJECT_ROOT, ".github", "workflows", "deploy-managed-db-app.yml"
)
TEARDOWN_WORKFLOW = os.path.join(
    PROJECT_ROOT, ".github", "workflows", "teardown.yml"
)


@pytest.fixture(scope="module")
def teardown_secrets_demo_text() -> str:
    with open(TEARDOWN_SECRETS_DEMO_SCRIPT, encoding="utf-8") as f:
        return f.read()


@pytest.fixture(scope="module")
def teardown_managed_db_app_text() -> str:
    with open(TEARDOWN_MANAGED_DB_APP_SCRIPT, encoding="utf-8") as f:
        return f.read()


@pytest.fixture(scope="module")
def deploy_secrets_demo_text() -> str:
    with open(DEPLOY_SECRETS_DEMO_WORKFLOW, encoding="utf-8") as f:
        return f.read()


@pytest.fixture(scope="module")
def deploy_managed_db_app_text() -> str:
    with open(DEPLOY_MANAGED_DB_APP_WORKFLOW, encoding="utf-8") as f:
        return f.read()


@pytest.fixture(scope="module")
def teardown_workflow_text() -> str:
    with open(TEARDOWN_WORKFLOW, encoding="utf-8") as f:
        return f.read()


def _extract_step_run_block(workflow_text: str, step_name: str) -> str:
    """Extract the 'run:' block content for a named step in a GitHub Actions workflow."""
    pattern = rf'-\s+name:\s+{re.escape(step_name)}\s*\n'
    match = re.search(pattern, workflow_text)
    if not match:
        return ""
    remaining = workflow_text[match.end():]
    run_match = re.search(r'run:\s*\|\s*\n', remaining)
    if not run_match:
        return ""
    block_start = run_match.end()
    block_text = remaining[block_start:]
    first_line_match = re.match(r'( +)', block_text)
    if not first_line_match:
        return ""
    indent = first_line_match.group(1)
    lines = []
    for line in block_text.split('\n'):
        if line == '' or line.startswith(indent):
            lines.append(line)
        else:
            break
    return '\n'.join(lines)


# ============================================================================
# Test 2a: teardown-secrets-demo.sh does NOT delete cluster-scoped resources
# ============================================================================

class TestPreserveTeardownSecretsDemoScript:
    """Test 2a: The individual teardown-secrets-demo.sh script must NOT contain
    commands that delete cluster-scoped vault resources. It has a NOTE comment
    explaining this is intentional.

    **Validates: Requirements 3.2**
    """

    def test_no_clusterrole_deletion(self, teardown_secrets_demo_text: str):
        assert "kubectl delete clusterrole vault-injector-clusterrole" not in teardown_secrets_demo_text

    def test_no_clusterrolebinding_deletion(self, teardown_secrets_demo_text: str):
        assert "kubectl delete clusterrolebinding vault-injector-binding" not in teardown_secrets_demo_text

    def test_no_webhook_config_deletion(self, teardown_secrets_demo_text: str):
        assert "kubectl delete mutatingwebhookconfiguration vault-agent-injector-cfg" not in teardown_secrets_demo_text

    def test_has_note_about_cluster_scoped_resources(self, teardown_secrets_demo_text: str):
        """The script must contain the NOTE comment explaining why cluster-scoped
        resources are not deleted."""
        assert "NOTE" in teardown_secrets_demo_text
        assert "cluster-scoped" in teardown_secrets_demo_text.lower() or \
               "ClusterRole" in teardown_secrets_demo_text


# ============================================================================
# Test 2b: teardown-managed-db-app.sh checks secrets-demo before vault delete
# ============================================================================

class TestPreserveTeardownManagedDbAppScript:
    """Test 2b: The individual teardown-managed-db-app.sh script must check for
    secrets-demo namespace existence before deleting the vault-injector package.

    **Validates: Requirements 3.3**
    """

    def test_checks_secrets_demo_namespace(self, teardown_managed_db_app_text: str):
        """The script must contain a check for secrets-demo namespace."""
        assert "kubectl get ns secrets-demo" in teardown_managed_db_app_text

    def test_skips_vault_injector_when_secrets_demo_exists(self, teardown_managed_db_app_text: str):
        """The script must skip vault-injector deletion when secrets-demo exists."""
        # The check must appear before the vault-injector deletion logic
        ns_check_pos = teardown_managed_db_app_text.find("kubectl get ns secrets-demo")
        vault_delete_pos = teardown_managed_db_app_text.find("vault-injector package deleted")
        assert ns_check_pos >= 0, "secrets-demo namespace check not found"
        assert vault_delete_pos >= 0, "vault-injector deletion logic not found"
        # The namespace check should come before the deletion
        assert ns_check_pos < vault_delete_pos


# ============================================================================
# Test 2c: deploy-secrets-demo.yml has VAULT_INSTALLED fast-path
# ============================================================================

class TestPreserveDeploySecretsDemoFastPath:
    """Test 2c: The deploy-secrets-demo.yml workflow must contain the
    VAULT_INSTALLED=true fast-path that skips reinstallation when the pod
    is already running and webhook is registered.

    **Validates: Requirements 3.1, 3.5**
    """

    def test_has_vault_installed_variable(self, deploy_secrets_demo_text: str):
        assert "VAULT_INSTALLED=false" in deploy_secrets_demo_text or \
               "VAULT_INSTALLED=true" in deploy_secrets_demo_text

    def test_has_fast_path_skip(self, deploy_secrets_demo_text: str):
        """When VAULT_INSTALLED is true, the workflow skips reinstallation."""
        assert 'VAULT_INSTALLED" != "true"' in deploy_secrets_demo_text or \
               "VAULT_INSTALLED\" != \"true\"" in deploy_secrets_demo_text or \
               'VAULT_INSTALLED=true' in deploy_secrets_demo_text

    def test_checks_pod_running_before_skip(self, deploy_secrets_demo_text: str):
        """The fast-path checks if the vault-injector pod is running."""
        assert "vault-injector" in deploy_secrets_demo_text
        assert "Running" in deploy_secrets_demo_text

    def test_checks_webhook_before_skip(self, deploy_secrets_demo_text: str):
        """The fast-path checks if the webhook is registered."""
        assert "vault-agent-injector-cfg" in deploy_secrets_demo_text


# ============================================================================
# Test 2d: deploy-managed-db-app.yml has equivalent fast-path
# ============================================================================

class TestPreserveDeployManagedDbAppFastPath:
    """Test 2d: The deploy-managed-db-app.yml workflow must contain the
    equivalent fast-path for skipping reinstallation when vault-injector
    is already installed and running.

    **Validates: Requirements 3.1, 3.5**
    """

    def test_has_vault_installed_variable(self, deploy_managed_db_app_text: str):
        assert "VAULT_INSTALLED=false" in deploy_managed_db_app_text

    def test_has_fast_path_skip(self, deploy_managed_db_app_text: str):
        """When VAULT_INSTALLED is true, the workflow skips reinstallation."""
        assert 'VAULT_INSTALLED" != "true"' in deploy_managed_db_app_text or \
               "VAULT_INSTALLED\" != \"true\"" in deploy_managed_db_app_text

    def test_checks_pod_running_before_skip(self, deploy_managed_db_app_text: str):
        """The fast-path checks if the vault-injector pod is running."""
        assert "vault-injector" in deploy_managed_db_app_text
        assert "Running" in deploy_managed_db_app_text

    def test_checks_webhook_before_skip(self, deploy_managed_db_app_text: str):
        """The fast-path checks if the webhook is registered."""
        assert "vault-agent-injector-cfg" in deploy_managed_db_app_text


# ============================================================================
# Test 2e: teardown.yml vault-injector package deletion has managed-db-app check
# ============================================================================

class TestPreserveTeardownWorkflowVaultDependencyCheck:
    """Test 2e: The teardown.yml vault-injector package deletion step
    (before the namespace deletion step) must contain the managed-db-app
    dependency check. This existing correct behavior must be preserved.

    **Validates: Requirements 3.4**
    """

    def test_vault_package_step_has_managed_db_check(self, teardown_workflow_text: str):
        """The 'Delete Secrets Demo Vault-Injector Package' step must check
        for managed-db-app namespace before deleting."""
        step_text = _extract_step_run_block(
            teardown_workflow_text, "Delete Secrets Demo Vault-Injector Package"
        )
        assert step_text, "Could not find 'Delete Secrets Demo Vault-Injector Package' step"
        assert "managed-db-app" in step_text
        assert "TEARDOWN_MANAGED_DB_APP" in step_text or "kubectl get ns managed-db-app" in step_text

    def test_vault_package_step_before_namespace_step(self, teardown_workflow_text: str):
        """The vault-injector package deletion step must appear before the
        namespace deletion step in the workflow."""
        pkg_pos = teardown_workflow_text.find("Delete Secrets Demo Vault-Injector Package")
        ns_pos = teardown_workflow_text.find("Delete Secrets Demo Namespace")
        assert pkg_pos >= 0, "Vault-injector package deletion step not found"
        assert ns_pos >= 0, "Namespace deletion step not found"
        assert pkg_pos < ns_pos, (
            "Vault-injector package deletion must come before namespace deletion"
        )

    def test_vault_package_step_skips_when_deps_exist(self, teardown_workflow_text: str):
        """The step must skip deletion when managed-db-app namespace exists
        and is not being torn down."""
        step_text = _extract_step_run_block(
            teardown_workflow_text, "Delete Secrets Demo Vault-Injector Package"
        )
        assert step_text, "Could not find step"
        # Must have the VAULT_DEPS pattern or equivalent conditional
        assert "VAULT_DEPS" in step_text or "managed-db-app" in step_text
