"""Bug condition exploration tests for vault-injector webhook fix.

These tests parse the workflow YAML files and assert structural correctness.
They are EXPECTED TO FAIL on unfixed code — failure confirms the bugs exist.

**Validates: Requirements 1.1, 1.2, 1.3, 2.1, 2.2, 2.3, 2.4**
"""

import os
import re
import pytest

PROJECT_ROOT = os.path.join(os.path.dirname(__file__), "..")

TEARDOWN_WORKFLOW_PATH = os.path.join(
    PROJECT_ROOT, ".github", "workflows", "teardown.yml"
)
DEPLOY_SECRETS_DEMO_PATH = os.path.join(
    PROJECT_ROOT, ".github", "workflows", "deploy-secrets-demo.yml"
)
DEPLOY_MANAGED_DB_APP_PATH = os.path.join(
    PROJECT_ROOT, ".github", "workflows", "deploy-managed-db-app.yml"
)


@pytest.fixture(scope="module")
def teardown_workflow_text() -> str:
    with open(TEARDOWN_WORKFLOW_PATH, encoding="utf-8") as f:
        return f.read()


@pytest.fixture(scope="module")
def deploy_secrets_demo_text() -> str:
    with open(DEPLOY_SECRETS_DEMO_PATH, encoding="utf-8") as f:
        return f.read()


@pytest.fixture(scope="module")
def deploy_managed_db_app_text() -> str:
    with open(DEPLOY_MANAGED_DB_APP_PATH, encoding="utf-8") as f:
        return f.read()


def _extract_step_run_block(workflow_text: str, step_name: str) -> str:
    """Extract the 'run:' block content for a named step in a GitHub Actions workflow."""
    # Find the step by name
    pattern = rf'-\s+name:\s+{re.escape(step_name)}\s*\n'
    match = re.search(pattern, workflow_text)
    if not match:
        return ""

    # Find the 'run: |' block after the step name
    remaining = workflow_text[match.end():]
    run_match = re.search(r'run:\s*\|\s*\n', remaining)
    if not run_match:
        return ""

    # Extract indented block content
    block_start = run_match.end()
    block_text = remaining[block_start:]

    # Determine the indentation of the first line of the run block
    first_line_match = re.match(r'( +)', block_text)
    if not first_line_match:
        return ""
    indent = first_line_match.group(1)

    lines = []
    for line in block_text.split('\n'):
        # A line belongs to the block if it's empty or starts with at least the same indent
        if line == '' or line.startswith(indent):
            lines.append(line)
        else:
            break

    return '\n'.join(lines)


# ============================================================================
# Test 1a: teardown.yml — cluster-scoped resource deletion must be conditional
# ============================================================================

class TestTeardownConditionalDeletion:
    """Test 1a: Assert that cluster-scoped vault resource deletion in teardown.yml
    is wrapped in a conditional guard checking managed-db-app namespace existence.

    **Validates: Requirements 1.1, 2.1**

    On unfixed code, this FAILS because the deletion is unconditional.
    """

    def test_cluster_scoped_deletion_has_conditional_guard(self, teardown_workflow_text: str):
        """The three kubectl delete commands for cluster-scoped vault resources
        must be wrapped in a conditional that checks whether managed-db-app
        namespace still exists or TEARDOWN_MANAGED_DB_APP is true."""
        step_text = _extract_step_run_block(teardown_workflow_text, "Delete Secrets Demo Namespace")
        assert step_text, "Could not find 'Delete Secrets Demo Namespace' step"

        # Verify the cluster-scoped deletion commands exist in this step
        assert "kubectl delete clusterrole vault-injector-clusterrole" in step_text
        assert "kubectl delete clusterrolebinding vault-injector-binding" in step_text
        assert "kubectl delete mutatingwebhookconfiguration vault-agent-injector-cfg" in step_text

        # Assert there is a conditional guard before the deletion commands
        # The guard should check TEARDOWN_MANAGED_DB_APP or managed-db-app namespace
        has_managed_db_check = (
            "managed-db-app" in step_text
            and ("TEARDOWN_MANAGED_DB_APP" in step_text or "kubectl get ns managed-db-app" in step_text)
        )
        assert has_managed_db_check, (
            "Cluster-scoped vault resource deletion in 'Delete Secrets Demo Namespace' step "
            "is NOT wrapped in a conditional guard checking managed-db-app namespace. "
            "The deletion is unconditional — this is the bug."
        )


# ============================================================================
# Test 1b: deploy-secrets-demo.yml — webhook wait must have explicit exit 1
# ============================================================================

class TestDeploySecretsDemoWebhookFailure:
    """Test 1b: Assert that after the webhook wait loop in deploy-secrets-demo.yml,
    there is an explicit exit 1 failure when the webhook is not registered.

    **Validates: Requirements 1.2, 2.2, 2.4**

    On unfixed code, this FAILS because the loop silently falls through.
    """

    def test_webhook_wait_has_explicit_failure(self, deploy_secrets_demo_text: str):
        """After the webhook wait loop, there must be an explicit exit 1 if
        the webhook is not registered."""
        step_text = _extract_step_run_block(
            deploy_secrets_demo_text, "Create Namespace, Copy Token, Deploy Vault-Injector"
        )
        assert step_text, "Could not find vault-injector deployment step"

        # Find the webhook wait loop
        assert "vault-agent-injector-cfg" in step_text, "Webhook wait loop not found"

        # Find the section after the webhook wait loop (after the 'done' that closes it)
        # Look for the pattern: while loop waiting for webhook -> done -> should have exit 1
        webhook_loop_pattern = re.search(
            r'while.*\$ELAPSED.*300.*do.*vault-agent-injector-cfg.*done',
            step_text,
            re.DOTALL,
        )
        assert webhook_loop_pattern, "Could not find webhook wait loop structure"

        # Get text after the webhook wait loop's 'done'
        after_loop = step_text[webhook_loop_pattern.end():]

        # There should be an explicit exit 1 after the loop for webhook failure
        has_exit_1 = "exit 1" in after_loop
        assert has_exit_1, (
            "No explicit 'exit 1' found after the webhook wait loop in "
            "deploy-secrets-demo.yml. The loop silently falls through — this is the bug."
        )


# ============================================================================
# Test 1c: deploy-managed-db-app.yml — webhook wait timeout, restart, failure
# ============================================================================

class TestDeployManagedDbAppWebhookWait:
    """Test 1c: Assert that the webhook wait loop in deploy-managed-db-app.yml
    has (i) 300s timeout, (ii) restart-and-retry mechanism, (iii) explicit exit 1.

    **Validates: Requirements 1.3, 2.3, 2.4**

    On unfixed code, this FAILS because timeout is 120s, no restart, no exit 1.
    """

    def test_webhook_timeout_is_300s(self, deploy_managed_db_app_text: str):
        """The webhook wait loop timeout must be 300s, not 120s."""
        step_text = _extract_step_run_block(deploy_managed_db_app_text, "Deploy API Service")
        assert step_text, "Could not find 'Deploy API Service' step"

        # Find the webhook wait loop
        webhook_loop = re.search(
            r'while.*\$ELAPSED.*?(\d+).*do.*vault-agent-injector-cfg.*?done',
            step_text,
            re.DOTALL,
        )
        assert webhook_loop, "Could not find webhook wait loop"

        timeout_value = int(webhook_loop.group(1))
        assert timeout_value == 300, (
            f"Webhook wait timeout is {timeout_value}s, expected 300s. "
            "The timeout is too low — this is the bug."
        )

    def test_webhook_has_restart_and_retry(self, deploy_managed_db_app_text: str):
        """After the initial webhook wait, there must be a restart-and-retry mechanism."""
        step_text = _extract_step_run_block(deploy_managed_db_app_text, "Deploy API Service")
        assert step_text, "Could not find 'Deploy API Service' step"

        has_restart = "rollout restart" in step_text and "vault-injector" in step_text
        assert has_restart, (
            "No restart-and-retry mechanism found in deploy-managed-db-app.yml "
            "webhook wait section — this is the bug."
        )

    def test_webhook_has_explicit_failure(self, deploy_managed_db_app_text: str):
        """After the webhook wait/retry, there must be an explicit exit 1 on timeout."""
        step_text = _extract_step_run_block(deploy_managed_db_app_text, "Deploy API Service")
        assert step_text, "Could not find 'Deploy API Service' step"

        # Find the webhook wait section and check for exit 1 after it
        webhook_section_start = step_text.find("vault-agent-injector-cfg")
        assert webhook_section_start >= 0, "Webhook wait section not found"

        after_webhook = step_text[webhook_section_start:]
        # Look for exit 1 after the webhook wait logic but before the deployment manifest
        # Skip past any kubectl apply used for webhook config recreation (MutatingWebhookConfiguration)
        # and find the actual deployment manifest (apps/v1 Deployment)
        deploy_manifest_start = after_webhook.find("kind: Deployment")
        if deploy_manifest_start > 0:
            between_webhook_and_deploy = after_webhook[:deploy_manifest_start]
        else:
            between_webhook_and_deploy = after_webhook

        has_exit_1 = "exit 1" in between_webhook_and_deploy
        assert has_exit_1, (
            "No explicit 'exit 1' found after webhook wait in deploy-managed-db-app.yml. "
            "The loop silently falls through — this is the bug."
        )


# ============================================================================
# Test 1d: deploy-secrets-demo.yml — log message timeout mismatch
# ============================================================================

class TestDeploySecretsDemoLogMessage:
    """Test 1d: Assert the webhook wait log message uses the correct timeout
    value matching the actual loop limit.

    **Validates: Requirements 1.2, 2.2**

    On unfixed code, this FAILS because the log says "120s" but loop runs 300s.
    """

    def test_log_message_matches_actual_timeout(self, deploy_secrets_demo_text: str):
        """The webhook wait log message must show the correct timeout value
        that matches the actual loop limit."""
        step_text = _extract_step_run_block(
            deploy_secrets_demo_text, "Create Namespace, Copy Token, Deploy Vault-Injector"
        )
        assert step_text, "Could not find vault-injector deployment step"

        # Find the actual loop limit
        loop_limit_match = re.search(
            r'while.*\$ELAPSED.*?-lt\s+(\d+).*vault-agent-injector-cfg',
            step_text,
            re.DOTALL,
        )
        assert loop_limit_match, "Could not find webhook wait loop limit"
        actual_limit = loop_limit_match.group(1)

        # Find the log message timeout value
        log_match = re.search(
            r'Waiting for vault-injector webhook.*?\$\{ELAPSED\}s/(\d+)s\)',
            step_text,
        )
        assert log_match, "Could not find webhook wait log message"
        log_timeout = log_match.group(1)

        assert log_timeout == actual_limit, (
            f"Log message says '{log_timeout}s' but actual loop limit is {actual_limit}s. "
            "The timeout values are mismatched — this is the bug."
        )
