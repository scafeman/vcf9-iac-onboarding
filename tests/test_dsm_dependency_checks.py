"""Bug condition exploration tests for DSM PostgresCluster shared dependency fix.

These tests parse the teardown files and assert structural correctness for
DSM PostgresCluster dependency checks. They are EXPECTED TO FAIL on unfixed
code — failure confirms the bugs exist.

**Validates: Requirements 1.1, 1.2, 1.3, 1.4, 1.5**
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
# Test 1a: teardown.yml Phase G — DSM PostgresCluster step must have
#          dependency check BEFORE kubectl delete postgrescluster
# ============================================================================

class TestWorkflowPhaseGDependencyCheck:
    """Test 1a: Assert that the 'Delete DSM PostgresCluster' step in
    teardown.yml contains a dependency check for ha-web-lb or knative-demo
    BEFORE any kubectl delete postgrescluster command.

    **Validates: Requirements 1.1, 1.2**

    On unfixed code, this FAILS because there is no dependency check.
    """

    def test_dsm_step_has_dependency_check_before_delete(self, teardown_workflow_text: str):
        step_text = _extract_step_run_block(
            teardown_workflow_text, "Delete DSM PostgresCluster"
        )
        assert step_text, "Could not find 'Delete DSM PostgresCluster' step"

        # The step must contain a dependency check for ha-web-lb or knative-demo
        # BEFORE the kubectl delete postgrescluster command
        delete_pos = step_text.find("kubectl delete postgrescluster")
        assert delete_pos >= 0, "kubectl delete postgrescluster command not found in step"

        # Check for dependency check references before the delete command
        text_before_delete = step_text[:delete_pos]

        has_ha_web_lb_check = "ha-web-lb" in text_before_delete
        has_knative_demo_check = "knative-demo" in text_before_delete
        has_any_dep_check = has_ha_web_lb_check or has_knative_demo_check

        assert has_any_dep_check, (
            "The 'Delete DSM PostgresCluster' step in teardown.yml has NO dependency "
            "check for ha-web-lb or knative-demo BEFORE kubectl delete postgrescluster. "
            "The deletion is unconditional — this is the bug."
        )


# ============================================================================
# Test 1b: teardown-ha-vm-app.sh — dependency check must NOT be gated on
#          kubeconfig file existence
# ============================================================================

class TestHaVmAppDependencyCheckNotGated:
    """Test 1b: Assert that the DSM PostgresCluster dependency check in
    teardown-ha-vm-app.sh is NOT gated on kubeconfig file existence.

    **Validates: Requirements 1.3, 1.4**

    On unfixed code, this FAILS because the check IS gated on
    [[ -f "${KUBECONFIG_FILE}" ]].
    """

    def test_dependency_check_not_gated_on_kubeconfig(self, teardown_ha_vm_app_text: str):
        # Find the DSM PostgresCluster deletion section (Phase 5)
        phase5_match = re.search(
            r'# Phase 5.*?Delete DSM PostgresCluster',
            teardown_ha_vm_app_text,
            re.DOTALL,
        )
        assert phase5_match, "Could not find Phase 5 DSM PostgresCluster section"

        phase5_text = teardown_ha_vm_app_text[phase5_match.start():]

        # Find the DSM_DEPS check block — look for where DSM_DEPS is set to 0
        dsm_deps_start = phase5_text.find("DSM_DEPS=0")
        assert dsm_deps_start >= 0, "DSM_DEPS=0 not found in Phase 5"

        # Get the text between DSM_DEPS=0 and the actual deletion command
        delete_pos = phase5_text.find("kubectl delete postgrescluster", dsm_deps_start)
        if delete_pos < 0:
            delete_pos = phase5_text.find('kubectl get postgrescluster', dsm_deps_start)
        assert delete_pos >= 0, "PostgresCluster command not found after DSM_DEPS=0"

        check_block = phase5_text[dsm_deps_start:delete_pos]

        # The dependency check block should NOT be wrapped in a kubeconfig file check
        kubeconfig_gate = re.search(
            r'\[\[\s+-f\s+.*KUBECONFIG_FILE.*\]\]',
            check_block,
        )

        assert kubeconfig_gate is None, (
            "The DSM dependency check in teardown-ha-vm-app.sh Phase 5 IS gated on "
            'kubeconfig file existence ([[ -f "${KUBECONFIG_FILE}" ]]). '
            "The check should work regardless of kubeconfig existence — this is the bug."
        )


# ============================================================================
# Test 1c: teardown-managed-db-app.sh — knative-demo namespace check must
#          handle kubectl failure (unreachable cluster)
# ============================================================================

class TestManagedDbAppUnreachableClusterHandling:
    """Test 1c: Assert that the knative-demo namespace check in
    teardown-managed-db-app.sh has error handling that sets DSM_DEPS
    when kubectl fails (unreachable cluster handling).

    **Validates: Requirements 1.5**

    On unfixed code, this FAILS because kubectl failure silently leaves
    DSM_DEPS=0.
    """

    def test_knative_demo_check_has_error_handling(self, teardown_managed_db_app_text: str):
        # Find the Phase 2 DSM PostgresCluster deletion section
        phase2_match = re.search(
            r'# Phase 2.*?Delete PostgresCluster',
            teardown_managed_db_app_text,
            re.DOTALL,
        )
        assert phase2_match, "Could not find Phase 2 PostgresCluster section"

        phase2_text = teardown_managed_db_app_text[phase2_match.start():]

        # Find the DSM_DEPS check block
        dsm_deps_start = phase2_text.find("DSM_DEPS=0")
        assert dsm_deps_start >= 0, "DSM_DEPS=0 not found in Phase 2"

        # Get the text from DSM_DEPS=0 to the actual deletion decision
        dsm_deps_check_match = re.search(
            r'if \[\[ "\$\{DSM_DEPS\}" -eq 0 \]\]',
            phase2_text[dsm_deps_start:],
        )
        assert dsm_deps_check_match, "DSM_DEPS check condition not found"

        check_block = phase2_text[dsm_deps_start:dsm_deps_start + dsm_deps_check_match.start()]

        # The knative-demo check should have error handling:
        # Either an || clause that sets DSM_DEPS=1 on failure,
        # or a reachability probe before the check
        has_error_handling = (
            # Pattern: kubectl fails -> set DSM_DEPS=1
            ("DSM_DEPS=1" in check_block and "||" in check_block)
            or
            # Pattern: reachability probe before knative-demo check
            ("kubectl get ns default" in check_block or "kubectl cluster-info" in check_block)
            or
            # Pattern: if ! kubectl ... then DSM_DEPS=1
            re.search(r'if\s+!\s+kubectl.*knative-demo.*DSM_DEPS=1', check_block, re.DOTALL) is not None
        )

        assert has_error_handling, (
            "The knative-demo namespace check in teardown-managed-db-app.sh Phase 2 "
            "has NO error handling for kubectl failure. If the guest cluster is "
            "unreachable, kubectl fails silently and DSM_DEPS stays 0, leading to "
            "unconditional PostgresCluster deletion — this is the bug."
        )


# ============================================================================
# Test 1d: teardown-knative.sh — VCF CLI context creation must occur BEFORE
#          the ha-web-lb VirtualMachineService check
# ============================================================================

class TestKnativeContextOrdering:
    """Test 1d: Assert that VCF CLI context creation occurs BEFORE the
    ha-web-lb VirtualMachineService check in teardown-knative.sh.

    **Validates: Requirements 1.5**

    On unfixed code, this FAILS because the ha-web-lb check runs before
    VCF CLI context creation.
    """

    def test_vcf_context_created_before_ha_web_lb_check(self, teardown_knative_text: str):
        # Find the Phase 2 DSM section
        phase2_match = re.search(
            r'# Phase 2.*?Delete DSM PostgresCluster',
            teardown_knative_text,
            re.DOTALL,
        )
        assert phase2_match, "Could not find Phase 2 DSM PostgresCluster section"

        phase2_text = teardown_knative_text[phase2_match.start():]

        # Find the ha-web-lb check position
        ha_web_lb_pos = phase2_text.find("ha-web-lb")
        assert ha_web_lb_pos >= 0, "ha-web-lb check not found in Phase 2"

        # Find the VCF CLI context creation position
        vcf_context_create_pos = phase2_text.find("vcf context create")

        assert vcf_context_create_pos >= 0, (
            "VCF CLI context creation not found in Phase 2"
        )

        # VCF context creation must come BEFORE the ha-web-lb check
        assert vcf_context_create_pos < ha_web_lb_pos, (
            "VCF CLI context creation occurs AFTER the ha-web-lb check in "
            "teardown-knative.sh Phase 2. The ha-web-lb VirtualMachineService "
            "check runs before the supervisor context is established, so it "
            "targets the wrong context — this is the bug."
        )
