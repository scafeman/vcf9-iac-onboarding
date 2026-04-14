"""Preservation property tests for DSM PostgresCluster shared dependency fix.

These tests verify existing correct behaviors BEFORE implementing the fix.
They MUST PASS on unfixed code — they confirm baseline behavior to preserve.

**Validates: Requirements 3.1, 3.2, 3.3, 3.4, 3.5, 3.6**
"""

import os
import re
import pytest

PROJECT_ROOT = os.path.join(os.path.dirname(__file__), "..")

TEARDOWN_WORKFLOW_PATH = os.path.join(
    PROJECT_ROOT, ".github", "workflows", "teardown.yml"
)
TEARDOWN_HA_VM_APP_PATH = os.path.join(
    PROJECT_ROOT, "examples", "deploy-ha-vm-app", "teardown-ha-vm-app.sh"
)
TEARDOWN_MANAGED_DB_APP_PATH = os.path.join(
    PROJECT_ROOT, "examples", "deploy-managed-db-app", "teardown-managed-db-app.sh"
)
TEARDOWN_KNATIVE_PATH = os.path.join(
    PROJECT_ROOT, "examples", "deploy-knative", "teardown-knative.sh"
)


@pytest.fixture(scope="module")
def teardown_workflow_text() -> str:
    with open(TEARDOWN_WORKFLOW_PATH, encoding="utf-8") as f:
        return f.read()


@pytest.fixture(scope="module")
def teardown_ha_vm_app_text() -> str:
    with open(TEARDOWN_HA_VM_APP_PATH, encoding="utf-8") as f:
        return f.read()


@pytest.fixture(scope="module")
def teardown_managed_db_app_text() -> str:
    with open(TEARDOWN_MANAGED_DB_APP_PATH, encoding="utf-8") as f:
        return f.read()


@pytest.fixture(scope="module")
def teardown_knative_text() -> str:
    with open(TEARDOWN_KNATIVE_PATH, encoding="utf-8") as f:
        return f.read()


def _extract_phase_block(text: str, phase_header_pattern: str, next_phase_pattern: str) -> str:
    """Extract a phase block from a shell script between two phase header patterns."""
    start_match = re.search(phase_header_pattern, text, re.DOTALL)
    if not start_match:
        return ""
    remaining = text[start_match.start():]
    end_match = re.search(next_phase_pattern, remaining[1:], re.DOTALL)
    if end_match:
        return remaining[:end_match.start() + 1]
    return remaining


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
# Test 2a: teardown-ha-vm-app.sh Phases 1-4 contain no DSM dependency logic
# ============================================================================

class TestHaVmAppPhases1To4NoDSMLogic:
    """Test 2a: Verify teardown-ha-vm-app.sh Phases 1-4 (VM and service
    deletion) contain no DSM dependency logic — completely unaffected by
    our changes.

    **Validates: Requirements 3.1, 3.3**
    """

    def test_phase1_no_dsm_dependency_logic(self, teardown_ha_vm_app_text: str):
        """Phase 1 (Delete Web Tier VirtualMachineService) has no DSM logic."""
        phase1 = _extract_phase_block(
            teardown_ha_vm_app_text,
            r'# Phase 1:.*?Delete Web Tier',
            r'# Phase 2:',
        )
        assert phase1, "Could not find Phase 1 block"
        assert "DSM_DEPS" not in phase1, "Phase 1 should not contain DSM_DEPS"
        assert "postgrescluster" not in phase1.lower(), "Phase 1 should not reference postgrescluster"

    def test_phase2_no_dsm_dependency_logic(self, teardown_ha_vm_app_text: str):
        """Phase 2 (Delete Web Tier VMs) has no DSM logic."""
        phase2 = _extract_phase_block(
            teardown_ha_vm_app_text,
            r'# Phase 2:.*?Delete Web Tier VM',
            r'# Phase 3:',
        )
        assert phase2, "Could not find Phase 2 block"
        assert "DSM_DEPS" not in phase2, "Phase 2 should not contain DSM_DEPS"
        assert "postgrescluster" not in phase2.lower(), "Phase 2 should not reference postgrescluster"

    def test_phase3_no_dsm_dependency_logic(self, teardown_ha_vm_app_text: str):
        """Phase 3 (Delete API Tier VirtualMachineService) has no DSM logic."""
        phase3 = _extract_phase_block(
            teardown_ha_vm_app_text,
            r'# Phase 3:.*?Delete API Tier VirtualMachineService',
            r'# Phase 4:',
        )
        assert phase3, "Could not find Phase 3 block"
        assert "DSM_DEPS" not in phase3, "Phase 3 should not contain DSM_DEPS"
        assert "postgrescluster" not in phase3.lower(), "Phase 3 should not reference postgrescluster"

    def test_phase4_no_dsm_dependency_logic(self, teardown_ha_vm_app_text: str):
        """Phase 4 (Delete API Tier VMs) has no DSM logic."""
        phase4 = _extract_phase_block(
            teardown_ha_vm_app_text,
            r'# Phase 4:.*?Delete API Tier VM',
            r'# Phase 5:',
        )
        assert phase4, "Could not find Phase 4 block"
        assert "DSM_DEPS" not in phase4, "Phase 4 should not contain DSM_DEPS"
        assert "postgrescluster" not in phase4.lower(), "Phase 4 should not reference postgrescluster"


# ============================================================================
# Test 2b: teardown-managed-db-app.sh Phase 1 contains no DSM dependency logic
# ============================================================================

class TestManagedDbAppPhase1NoDSMLogic:
    """Test 2b: Verify teardown-managed-db-app.sh Phase 1 (namespace deletion)
    contains no DSM dependency logic — completely unaffected.

    **Validates: Requirements 3.1, 3.4**
    """

    def test_phase1_no_dsm_dependency_logic(self, teardown_managed_db_app_text: str):
        """Phase 1 (Delete Application Namespace) has no DSM logic."""
        phase1 = _extract_phase_block(
            teardown_managed_db_app_text,
            r'# Phase 1:.*?Delete Application Namespace',
            r'# Phase 2:',
        )
        assert phase1, "Could not find Phase 1 block"
        assert "DSM_DEPS" not in phase1, "Phase 1 should not contain DSM_DEPS"
        assert "postgrescluster" not in phase1.lower(), "Phase 1 should not reference postgrescluster"


# ============================================================================
# Test 2c: All teardown scripts use ${VAR:-default} pattern for DSM vars
# ============================================================================

class TestDefaultVariablePatterns:
    """Test 2c: Verify all teardown scripts use ${VAR:-default} pattern for
    DSM_CLUSTER_NAME and ADMIN_PASSWORD_SECRET_NAME.

    **Validates: Requirements 3.1, 3.2, 3.3, 3.4, 3.5**
    """

    def test_ha_vm_app_dsm_cluster_name_default(self, teardown_ha_vm_app_text: str):
        assert re.search(
            r'DSM_CLUSTER_NAME="\$\{DSM_CLUSTER_NAME:-[^}]+\}"',
            teardown_ha_vm_app_text,
        ), "teardown-ha-vm-app.sh should use ${DSM_CLUSTER_NAME:-default} pattern"

    def test_ha_vm_app_admin_password_default(self, teardown_ha_vm_app_text: str):
        assert re.search(
            r'ADMIN_PASSWORD_SECRET_NAME="\$\{ADMIN_PASSWORD_SECRET_NAME:-[^}]+\}"',
            teardown_ha_vm_app_text,
        ), "teardown-ha-vm-app.sh should use ${ADMIN_PASSWORD_SECRET_NAME:-default} pattern"

    def test_managed_db_app_dsm_cluster_name_default(self, teardown_managed_db_app_text: str):
        assert re.search(
            r'DSM_CLUSTER_NAME="\$\{DSM_CLUSTER_NAME:-[^}]+\}"',
            teardown_managed_db_app_text,
        ), "teardown-managed-db-app.sh should use ${DSM_CLUSTER_NAME:-default} pattern"

    def test_managed_db_app_admin_password_default(self, teardown_managed_db_app_text: str):
        assert re.search(
            r'ADMIN_PASSWORD_SECRET_NAME="\$\{ADMIN_PASSWORD_SECRET_NAME:-[^}]+\}"',
            teardown_managed_db_app_text,
        ), "teardown-managed-db-app.sh should use ${ADMIN_PASSWORD_SECRET_NAME:-default} pattern"

    def test_knative_dsm_cluster_name_default(self, teardown_knative_text: str):
        assert re.search(
            r'DSM_CLUSTER_NAME="\$\{DSM_CLUSTER_NAME:-[^}]+\}"',
            teardown_knative_text,
        ), "teardown-knative.sh should use ${DSM_CLUSTER_NAME:-default} pattern"

    def test_knative_admin_password_default(self, teardown_knative_text: str):
        assert re.search(
            r'ADMIN_PASSWORD_SECRET_NAME="\$\{ADMIN_PASSWORD_SECRET_NAME:-[^}]+\}"',
            teardown_knative_text,
        ), "teardown-knative.sh should use ${ADMIN_PASSWORD_SECRET_NAME:-default} pattern"


# ============================================================================
# Test 2d: teardown-managed-db-app.sh has finalizer-stripping fallback
# ============================================================================

class TestManagedDbAppFinalizerFallback:
    """Test 2d: Verify teardown-managed-db-app.sh still contains the
    finalizer-stripping fallback for PostgresCluster
    (kubectl patch postgrescluster ... finalizers).

    **Validates: Requirements 3.4**
    """

    def test_finalizer_stripping_exists(self, teardown_managed_db_app_text: str):
        """The script must contain kubectl patch postgrescluster with finalizers null."""
        assert re.search(
            r'kubectl patch postgrescluster.*finalizers.*null',
            teardown_managed_db_app_text,
            re.DOTALL,
        ), (
            "teardown-managed-db-app.sh should contain finalizer-stripping fallback: "
            "kubectl patch postgrescluster ... finalizers null"
        )

    def test_finalizer_stripping_uses_merge_patch(self, teardown_managed_db_app_text: str):
        """The finalizer strip should use --type merge."""
        assert re.search(
            r'kubectl patch postgrescluster.*--type merge.*finalizers',
            teardown_managed_db_app_text,
            re.DOTALL,
        ), "Finalizer stripping should use --type merge patch"


# ============================================================================
# Test 2e: "already absent" or "does not exist" logging for PostgresCluster
# ============================================================================

class TestAlreadyAbsentLogging:
    """Test 2e: Verify 'already absent' or 'does not exist' logging pattern
    exists for PostgresCluster in all teardown paths.

    **Validates: Requirements 3.6**
    """

    def test_ha_vm_app_already_absent_logging(self, teardown_ha_vm_app_text: str):
        """teardown-ha-vm-app.sh has already-absent logging for PostgresCluster."""
        # Find the Phase 5 DSM section
        phase5_text = teardown_ha_vm_app_text[
            teardown_ha_vm_app_text.find("# Phase 5"):
        ]
        has_absent_pattern = (
            "already absent" in phase5_text.lower()
            or "does not exist" in phase5_text.lower()
        )
        assert has_absent_pattern, (
            "teardown-ha-vm-app.sh Phase 5 should have 'already absent' or "
            "'does not exist' logging for PostgresCluster"
        )

    def test_managed_db_app_already_absent_logging(self, teardown_managed_db_app_text: str):
        """teardown-managed-db-app.sh has already-absent logging for PostgresCluster."""
        # Find the Phase 2 DSM section
        phase2_text = teardown_managed_db_app_text[
            teardown_managed_db_app_text.find("# Phase 2"):
        ]
        has_absent_pattern = (
            "already absent" in phase2_text.lower()
            or "does not exist" in phase2_text.lower()
        )
        assert has_absent_pattern, (
            "teardown-managed-db-app.sh Phase 2 should have 'already absent' or "
            "'does not exist' logging for PostgresCluster"
        )

    def test_knative_already_absent_logging(self, teardown_knative_text: str):
        """teardown-knative.sh has already-absent logging for PostgresCluster."""
        # Find the Phase 2 DSM section
        phase2_text = teardown_knative_text[
            teardown_knative_text.find("# Phase 2"):
        ]
        has_absent_pattern = (
            "already absent" in phase2_text.lower()
            or "does not exist" in phase2_text.lower()
        )
        assert has_absent_pattern, (
            "teardown-knative.sh Phase 2 should have 'already absent' or "
            "'does not exist' logging for PostgresCluster"
        )

    def test_workflow_already_absent_logging(self, teardown_workflow_text: str):
        """teardown.yml DSM step has already-absent logging for PostgresCluster."""
        step_text = _extract_step_run_block(
            teardown_workflow_text, "Delete DSM PostgresCluster"
        )
        assert step_text, "Could not find 'Delete DSM PostgresCluster' step"
        has_absent_pattern = (
            "does not exist" in step_text.lower()
            or "already absent" in step_text.lower()
            or "skipping" in step_text.lower()
        )
        assert has_absent_pattern, (
            "teardown.yml 'Delete DSM PostgresCluster' step should have "
            "'does not exist' or 'skipping' logging"
        )


# ============================================================================
# Test 2f: teardown.yml Phase Groups other than G are unaffected
# ============================================================================

class TestWorkflowNonGPhaseGroupsUnaffected:
    """Test 2f: Verify teardown.yml Phase Groups other than G (A-F, H app-only,
    I app-only, C) are unaffected — they don't contain PostgresCluster
    deletion logic.

    **Validates: Requirements 3.1, 3.2**
    """

    @pytest.mark.parametrize("step_name", [
        "Delete ArgoCD Application",
        "Delete GitLab Runner",
        "Delete GitLab",
        "Delete ArgoCD",
        "Delete Harbor",
        "Delete Certificate Secrets and Files",
    ])
    def test_phase_group_a_no_postgrescluster(self, teardown_workflow_text: str, step_name: str):
        """Phase Group A (GitOps) steps don't contain PostgresCluster deletion."""
        step_text = _extract_step_run_block(teardown_workflow_text, step_name)
        if step_text:
            assert "postgrescluster" not in step_text.lower(), (
                f"Phase Group A step '{step_name}' should not contain postgrescluster logic"
            )

    @pytest.mark.parametrize("step_name", [
        "Delete Grafana",
        "Remove Metrics CoreDNS Entry",
    ])
    def test_phase_group_b_no_postgrescluster(self, teardown_workflow_text: str, step_name: str):
        """Phase Group B (Metrics) steps don't contain PostgresCluster deletion."""
        step_text = _extract_step_run_block(teardown_workflow_text, step_name)
        if step_text:
            assert "postgrescluster" not in step_text.lower(), (
                f"Phase Group B step '{step_name}' should not contain postgrescluster logic"
            )

    def test_phase_group_d_no_postgrescluster(self, teardown_workflow_text: str):
        """Phase Group D (Hybrid App) steps don't contain PostgresCluster deletion."""
        for step_name in ["Delete Hybrid App Namespace", "Delete PostgreSQL VM"]:
            step_text = _extract_step_run_block(teardown_workflow_text, step_name)
            if step_text:
                assert "postgrescluster" not in step_text.lower(), (
                    f"Phase Group D step '{step_name}' should not contain postgrescluster logic"
                )

    def test_phase_group_e_no_postgrescluster(self, teardown_workflow_text: str):
        """Phase Group E (Secrets Demo) steps don't contain PostgresCluster deletion."""
        for step_name in [
            "Delete Secrets Demo Vault-Injector Package",
            "Delete Secrets Demo Namespace",
            "Delete Secrets Demo Supervisor Resources",
        ]:
            step_text = _extract_step_run_block(teardown_workflow_text, step_name)
            if step_text:
                assert "postgrescluster" not in step_text.lower(), (
                    f"Phase Group E step '{step_name}' should not contain postgrescluster logic"
                )

    def test_phase_group_f_no_postgrescluster(self, teardown_workflow_text: str):
        """Phase Group F (Bastion VM) steps don't contain PostgresCluster deletion."""
        step_text = _extract_step_run_block(teardown_workflow_text, "Delete Bastion VM Resources")
        if step_text:
            assert "postgrescluster" not in step_text.lower(), (
                "Phase Group F step should not contain postgrescluster logic"
            )

    def test_phase_group_c_no_postgrescluster(self, teardown_workflow_text: str):
        """Phase Group C (Cluster) steps don't contain PostgresCluster deletion."""
        for step_name in [
            "Delete Guest Cluster Workloads",
            "Delete VKS Cluster",
            "Delete Supervisor Namespace and Project",
            "Context and Kubeconfig Cleanup",
        ]:
            step_text = _extract_step_run_block(teardown_workflow_text, step_name)
            if step_text:
                assert "postgrescluster" not in step_text.lower(), (
                    f"Phase Group C step '{step_name}' should not contain postgrescluster logic"
                )


# ============================================================================
# Test 2g: teardown-managed-db-app.sh has ha-web-lb VirtualMachineService check
# ============================================================================

class TestManagedDbAppHaWebLbCheck:
    """Test 2g: Verify teardown-managed-db-app.sh has the existing ha-web-lb
    VirtualMachineService check (this correct behavior must be preserved).

    **Validates: Requirements 3.4**
    """

    def test_ha_web_lb_check_exists(self, teardown_managed_db_app_text: str):
        """The script must check for ha-web-lb VirtualMachineService."""
        assert "ha-web-lb" in teardown_managed_db_app_text, (
            "teardown-managed-db-app.sh should contain ha-web-lb check"
        )

    def test_ha_web_lb_check_uses_kubectl_get(self, teardown_managed_db_app_text: str):
        """The ha-web-lb check should use kubectl get virtualmachineservice."""
        assert re.search(
            r'kubectl get virtualmachineservice ha-web-lb',
            teardown_managed_db_app_text,
        ), (
            "teardown-managed-db-app.sh should check ha-web-lb via "
            "kubectl get virtualmachineservice"
        )

    def test_ha_web_lb_check_sets_dsm_deps(self, teardown_managed_db_app_text: str):
        """The ha-web-lb check should set DSM_DEPS=1 when found."""
        # Find the ha-web-lb check and verify it sets DSM_DEPS=1
        ha_web_lb_pos = teardown_managed_db_app_text.find("ha-web-lb")
        assert ha_web_lb_pos >= 0
        # Look for DSM_DEPS=1 near the ha-web-lb check
        nearby_text = teardown_managed_db_app_text[ha_web_lb_pos:ha_web_lb_pos + 300]
        assert "DSM_DEPS=1" in nearby_text, (
            "ha-web-lb check should set DSM_DEPS=1 when the service exists"
        )
