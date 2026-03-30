"""Content-presence unit tests for the Teardown VCF Stacks workflow."""

import re


# ===================================================================
# TestWorkflowStructure — workflow YAML structure and triggers
# Validates: Requirements 1.1, 1.2, 1.3, 1.4, 1.5, 2.1, 2.2, 2.3
# ===================================================================


class TestWorkflowStructure:
    """Teardown workflow YAML parses correctly and has expected triggers and runner config."""

    def test_workflow_yaml_parses(self, teardown_workflow_yaml):
        assert isinstance(teardown_workflow_yaml, dict), "Workflow YAML did not parse as a dict"

    def test_expected_top_level_keys(self, teardown_workflow_yaml):
        expected = {"name", True, "jobs"}
        actual = set(teardown_workflow_yaml.keys())
        for key in expected:
            assert key in actual, f"Missing top-level key: {key}"

    def test_workflow_dispatch_trigger_present(self, teardown_workflow_yaml):
        triggers = teardown_workflow_yaml.get("on") or teardown_workflow_yaml.get(True)
        assert "workflow_dispatch" in triggers

    def test_repository_dispatch_has_teardown_type(self, teardown_workflow_yaml):
        triggers = teardown_workflow_yaml.get("on") or teardown_workflow_yaml.get(True)
        types = triggers["repository_dispatch"]["types"]
        assert "teardown" in types

    def test_workflow_dispatch_has_five_inputs(self, teardown_workflow_yaml):
        triggers = teardown_workflow_yaml.get("on") or teardown_workflow_yaml.get(True)
        inputs = triggers["workflow_dispatch"]["inputs"]
        expected = {"cluster_name", "teardown_gitops", "teardown_metrics", "teardown_cluster", "teardown_hybrid_app"}
        assert set(inputs.keys()) == expected

    def test_cluster_name_input_is_required(self, teardown_workflow_yaml):
        triggers = teardown_workflow_yaml.get("on") or teardown_workflow_yaml.get(True)
        cluster_input = triggers["workflow_dispatch"]["inputs"]["cluster_name"]
        assert cluster_input.get("required") is True

    def test_runs_on_includes_self_hosted_and_vcf(self, teardown_workflow_yaml):
        runs_on = teardown_workflow_yaml["jobs"]["teardown"]["runs-on"]
        assert "self-hosted" in runs_on
        assert "vcf" in runs_on

    def test_environment_vcf_production(self, teardown_workflow_yaml):
        env = teardown_workflow_yaml["jobs"]["teardown"]["environment"]
        assert env == "vcf-production"


# ===================================================================
# TestWorkflowSecrets — secret references
# Validates: Requirements 2.4
# ===================================================================


class TestWorkflowSecrets:
    """All required secrets are referenced via ${{ secrets.NAME }}."""

    REQUIRED_SECRETS = [
        "VCF_API_TOKEN",
        "VCFA_ENDPOINT",
        "TENANT_NAME",
    ]

    def test_all_required_secrets_referenced(self, teardown_workflow_yaml_text):
        for secret in self.REQUIRED_SECRETS:
            pattern = rf"secrets\.{secret}"
            assert re.search(pattern, teardown_workflow_yaml_text), (
                f"Secret '{secret}' not referenced via secrets.{secret} syntax"
            )


# ===================================================================
# TestWorkflowSteps — expected step names and content
# Validates: Requirements 4.1, 4.2, 4.3, 4.4, 4.5, 5.1–5.7, 6.1–6.7,
#            7.1–7.4, 9.1, 9.2
# ===================================================================


class TestWorkflowSteps:
    """All required step names exist and key content is present."""

    REQUIRED_STEP_NAMES = [
        "Checkout Repository",
        "Setup Kubeconfig",
        "Warn Orphaned Stacks",
        "Delete ArgoCD Application",
        "Delete GitLab Runner",
        "Delete GitLab",
        "Delete ArgoCD",
        "Restore CoreDNS (GitOps)",
        "Delete Harbor",
        "Delete Certificate Secrets and Files",
        "Delete Grafana",
        "Remove Metrics CoreDNS Entry",
        "Delete VKS Packages",
        "Delete Package Repository",
        "Delete Package Namespace",
        "Clean Up Cluster-Scoped Resources",
        "Delete Guest Cluster Workloads",
        "Delete VKS Cluster",
        "Delete Supervisor Namespace and Project",
        "Context and Kubeconfig Cleanup",
        "Write Job Summary",
        "Write Failure Summary",
    ]

    @staticmethod
    def _get_steps(workflow_yaml):
        return workflow_yaml["jobs"]["teardown"]["steps"]

    @staticmethod
    def _get_step_by_name(workflow_yaml, name):
        for step in workflow_yaml["jobs"]["teardown"]["steps"]:
            if step.get("name", "").lower() == name.lower():
                return step
        raise AssertionError(f"Step '{name}' not found")

    def test_all_required_step_names_present(self, teardown_workflow_yaml):
        steps = self._get_steps(teardown_workflow_yaml)
        step_names = [s.get("name", "") for s in steps]
        for required in self.REQUIRED_STEP_NAMES:
            assert any(required.lower() == name.lower() for name in step_names), (
                f"Required step '{required}' not found in workflow steps"
            )

    def test_gitops_steps_have_conditional(self, teardown_workflow_yaml):
        gitops_steps = [
            "Delete ArgoCD Application",
            "Delete GitLab Runner",
            "Delete GitLab",
            "Delete ArgoCD",
            "Restore CoreDNS (GitOps)",
            "Delete Harbor",
            "Delete Certificate Secrets and Files",
        ]
        for name in gitops_steps:
            step = self._get_step_by_name(teardown_workflow_yaml, name)
            condition = step.get("if", "")
            assert "TEARDOWN_GITOPS" in condition or "teardown_gitops" in condition, (
                f"GitOps step '{name}' missing teardown_gitops conditional"
            )

    def test_metrics_steps_have_conditional(self, teardown_workflow_yaml):
        metrics_steps = [
            "Delete Grafana",
            "Remove Metrics CoreDNS Entry",
            "Delete VKS Packages",
            "Delete Package Repository",
            "Delete Package Namespace",
            "Clean Up Cluster-Scoped Resources",
        ]
        for name in metrics_steps:
            step = self._get_step_by_name(teardown_workflow_yaml, name)
            condition = step.get("if", "")
            assert "TEARDOWN_METRICS" in condition or "teardown_metrics" in condition, (
                f"Metrics step '{name}' missing teardown_metrics conditional"
            )

    def test_cluster_steps_have_conditional(self, teardown_workflow_yaml):
        cluster_steps = [
            "Delete Guest Cluster Workloads",
            "Delete VKS Cluster",
            "Delete Supervisor Namespace and Project",
            "Context and Kubeconfig Cleanup",
        ]
        for name in cluster_steps:
            step = self._get_step_by_name(teardown_workflow_yaml, name)
            condition = step.get("if", "")
            assert "TEARDOWN_CLUSTER" in condition or "teardown_cluster" in condition, (
                f"Cluster step '{name}' missing teardown_cluster conditional"
            )

    def test_orphan_warning_step_has_warning_annotation(self, teardown_workflow_yaml):
        step = self._get_step_by_name(teardown_workflow_yaml, "Warn Orphaned Stacks")
        assert "::warning::" in step.get("run", "")

    def test_job_summary_writes_to_github_step_summary(self, teardown_workflow_yaml):
        step = self._get_step_by_name(teardown_workflow_yaml, "Write Job Summary")
        assert "GITHUB_STEP_SUMMARY" in step.get("run", "")

    def test_failure_summary_has_failure_condition(self, teardown_workflow_yaml):
        step = self._get_step_by_name(teardown_workflow_yaml, "Write Failure Summary")
        condition = step.get("if", "")
        assert "failure()" in condition


# ===================================================================
# TestTriggerScript — trigger script content checks
# Validates: Requirements 10.1, 10.2, 10.3, 10.4, 10.5, 10.6
# ===================================================================


class TestTriggerScript:
    """Trigger script contains required content."""

    def test_contains_teardown_event_type(self, trigger_teardown_script_text):
        assert "teardown" in trigger_teardown_script_text

    def test_contains_github_api_url(self, trigger_teardown_script_text):
        assert "api.github.com" in trigger_teardown_script_text

    def test_validates_required_args(self, trigger_teardown_script_text):
        required_args = ["--repo", "--token", "--cluster-name"]
        for arg in required_args:
            assert arg in trigger_teardown_script_text, (
                f"Trigger script does not reference required argument '{arg}'"
            )

    def test_contains_usage_message(self, trigger_teardown_script_text):
        assert "usage" in trigger_teardown_script_text.lower()

    def test_contains_optional_boolean_args(self, trigger_teardown_script_text):
        optional_args = ["--teardown-gitops", "--teardown-metrics", "--teardown-cluster"]
        for arg in optional_args:
            assert arg in trigger_teardown_script_text, (
                f"Trigger script does not reference optional argument '{arg}'"
            )

    def test_contains_curl(self, trigger_teardown_script_text):
        assert "curl" in trigger_teardown_script_text

    def test_contains_jq(self, trigger_teardown_script_text):
        assert "jq" in trigger_teardown_script_text

    def test_prints_actions_url(self, trigger_teardown_script_text):
        assert "actions" in trigger_teardown_script_text.lower()
        assert "github.com" in trigger_teardown_script_text


# ===================================================================
# TestReadmeDocumentation — README teardown section checks
# Validates: Requirements 11.1, 11.2, 11.3, 11.4, 11.5
# ===================================================================


class TestReadmeDocumentation:
    """Workflow README contains required teardown documentation."""

    def test_readme_contains_teardown_section(self, workflow_readme_text):
        assert "Teardown" in workflow_readme_text

    def test_readme_contains_teardown_parameter_table(self, workflow_readme_text):
        assert "teardown_gitops" in workflow_readme_text
        assert "teardown_metrics" in workflow_readme_text
        assert "teardown_cluster" in workflow_readme_text

    def test_readme_contains_triggering_instructions(self, workflow_readme_text):
        assert "trigger-teardown.sh" in workflow_readme_text

    def test_readme_contains_curl_example(self, workflow_readme_text):
        # Check for the teardown curl example
        assert "teardown" in workflow_readme_text.lower()
        assert "dispatches" in workflow_readme_text

    def test_readme_contains_teardown_workflow_steps_table(self, workflow_readme_text):
        assert "Delete ArgoCD Application" in workflow_readme_text
        assert "Delete Grafana" in workflow_readme_text
        assert "Delete VKS Cluster" in workflow_readme_text

    def test_readme_contains_teardown_troubleshooting(self, workflow_readme_text):
        # Check for teardown-specific troubleshooting content
        assert "Namespace stuck in Terminating" in workflow_readme_text or \
               "Orphaned resources" in workflow_readme_text
