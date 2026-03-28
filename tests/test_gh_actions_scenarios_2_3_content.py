# Feature: gh-actions-scenarios-2-3, Content Tests
# Unit tests for the GitHub Actions Scenarios 2 & 3 workflows.

"""Content-presence unit tests for the GitHub Actions Scenarios 2 & 3 workflows."""

import re


# ===================================================================
# TestMetricsWorkflowStructure — Scenario 2 YAML structure and triggers
# Validates: Requirements 1.1, 1.2, 1.3, 3.1, 3.2, 4.1
# ===================================================================


class TestMetricsWorkflowStructure:
    """Scenario 2 workflow YAML parses correctly and has expected triggers and runner config."""

    def test_workflow_yaml_parses(self, metrics_workflow_yaml):
        assert isinstance(metrics_workflow_yaml, dict), "Metrics workflow YAML did not parse as a dict"

    def test_workflow_dispatch_has_three_inputs(self, metrics_workflow_yaml):
        triggers = metrics_workflow_yaml.get("on") or metrics_workflow_yaml.get(True)
        inputs = triggers["workflow_dispatch"]["inputs"]
        expected = {"cluster_name", "telegraf_version", "environment"}
        assert set(inputs.keys()) == expected

    def test_repository_dispatch_has_deploy_vks_metrics(self, metrics_workflow_yaml):
        triggers = metrics_workflow_yaml.get("on") or metrics_workflow_yaml.get(True)
        types = triggers["repository_dispatch"]["types"]
        assert "deploy-vks-metrics" in types

    def test_runs_on_includes_self_hosted_and_vcf(self, metrics_workflow_yaml):
        runs_on = metrics_workflow_yaml["jobs"]["deploy"]["runs-on"]
        assert "self-hosted" in runs_on
        assert "vcf" in runs_on

    def test_no_container_directive(self, metrics_workflow_yaml):
        assert "container" not in metrics_workflow_yaml["jobs"]["deploy"]

    def test_environment_vcf_production(self, metrics_workflow_yaml):
        env = metrics_workflow_yaml["jobs"]["deploy"]["environment"]
        assert env == "vcf-production"

    def test_environment_input_defaults_to_demo(self, metrics_workflow_yaml):
        triggers = metrics_workflow_yaml.get("on") or metrics_workflow_yaml.get(True)
        env_input = triggers["workflow_dispatch"]["inputs"]["environment"]
        assert env_input.get("default") == "demo"


# ===================================================================
# TestArgocdWorkflowStructure — Scenario 3 YAML structure and triggers
# Validates: Requirements 2.1, 2.2, 2.3, 3.1, 3.2, 4.1
# ===================================================================


class TestArgocdWorkflowStructure:
    """Scenario 3 workflow YAML parses correctly and has expected triggers and runner config."""

    def test_workflow_yaml_parses(self, argocd_workflow_yaml):
        assert isinstance(argocd_workflow_yaml, dict), "ArgoCD workflow YAML did not parse as a dict"

    def test_workflow_dispatch_has_two_inputs(self, argocd_workflow_yaml):
        triggers = argocd_workflow_yaml.get("on") or argocd_workflow_yaml.get(True)
        inputs = triggers["workflow_dispatch"]["inputs"]
        expected = {"cluster_name", "environment"}
        assert set(inputs.keys()) == expected

    def test_repository_dispatch_has_deploy_argocd(self, argocd_workflow_yaml):
        triggers = argocd_workflow_yaml.get("on") or argocd_workflow_yaml.get(True)
        types = triggers["repository_dispatch"]["types"]
        assert "deploy-argocd" in types

    def test_runs_on_includes_self_hosted_and_vcf(self, argocd_workflow_yaml):
        runs_on = argocd_workflow_yaml["jobs"]["deploy"]["runs-on"]
        assert "self-hosted" in runs_on
        assert "vcf" in runs_on

    def test_no_container_directive(self, argocd_workflow_yaml):
        assert "container" not in argocd_workflow_yaml["jobs"]["deploy"]

    def test_environment_vcf_production(self, argocd_workflow_yaml):
        env = argocd_workflow_yaml["jobs"]["deploy"]["environment"]
        assert env == "vcf-production"

    def test_environment_input_defaults_to_demo(self, argocd_workflow_yaml):
        triggers = argocd_workflow_yaml.get("on") or argocd_workflow_yaml.get(True)
        env_input = triggers["workflow_dispatch"]["inputs"]["environment"]
        assert env_input.get("default") == "demo"


# ===================================================================
# TestMetricsStepContent — key commands in Scenario 2 steps
# Validates: Requirements 6.1, 9.3, 11.1
# ===================================================================


class TestMetricsStepContent:
    """Key commands and patterns exist in the correct Scenario 2 workflow steps."""

    @staticmethod
    def _get_step_by_name(workflow_yaml, name):
        for step in workflow_yaml["jobs"]["deploy"]["steps"]:
            if step.get("name", "").lower() == name.lower():
                return step
        raise AssertionError(f"Step '{name}' not found")

    def test_node_sizing_advisory_contains_warning(self, metrics_workflow_yaml):
        step = self._get_step_by_name(metrics_workflow_yaml, "Node Sizing Advisory")
        assert "::warning::" in step.get("run", "")

    def test_coredns_contains_rollout_restart(self, metrics_workflow_yaml):
        step = self._get_step_by_name(metrics_workflow_yaml, "Configure CoreDNS")
        assert "rollout restart" in step.get("run", "")

    def test_contour_lb_ip_written_to_github_env(self, metrics_workflow_yaml):
        step = self._get_step_by_name(metrics_workflow_yaml, "Create Envoy LoadBalancer")
        run_block = step.get("run", "")
        assert "CONTOUR_LB_IP" in run_block
        assert "GITHUB_ENV" in run_block


# ===================================================================
# TestArgocdStepContent — key commands in Scenario 3 steps
# Validates: Requirements 16.1, 19.1, 20.4, 20.5
# ===================================================================


class TestArgocdStepContent:
    """Key commands and patterns exist in the correct Scenario 3 workflow steps."""

    @staticmethod
    def _get_step_by_name(workflow_yaml, name):
        for step in workflow_yaml["jobs"]["deploy"]["steps"]:
            if step.get("name", "").lower() == name.lower():
                return step
        raise AssertionError(f"Step '{name}' not found")

    def test_argocd_password_from_initial_admin_secret(self, argocd_workflow_yaml):
        step = self._get_step_by_name(argocd_workflow_yaml, "Install ArgoCD")
        assert "argocd-initial-admin-secret" in step.get("run", "")

    def test_cert_generation_references_wildcard_cnf(self, argocd_workflow_yaml):
        step = self._get_step_by_name(argocd_workflow_yaml, "Generate Self-Signed Certificates")
        assert "examples/deploy-gitops/wildcard.cnf" in step.get("run", "")

    def test_coredns_contains_rollout_restart(self, argocd_workflow_yaml):
        step = self._get_step_by_name(argocd_workflow_yaml, "Configure CoreDNS")
        assert "rollout restart" in step.get("run", "")

    def test_contour_lb_ip_written_to_github_env(self, argocd_workflow_yaml):
        step = self._get_step_by_name(argocd_workflow_yaml, "Create Envoy LoadBalancer")
        run_block = step.get("run", "")
        assert "CONTOUR_LB_IP" in run_block
        assert "GITHUB_ENV" in run_block


# ===================================================================
# TestWorkflowReadme — README content checks
# Validates: Requirements 31.1, 31.2, 31.4, 31.5
# ===================================================================


class TestWorkflowReadme:
    """Workflow README contains required documentation for Scenarios 2 & 3."""

    def test_readme_contains_troubleshooting(self, workflow_readme_text):
        assert "troubleshooting" in workflow_readme_text.lower()

    def test_readme_contains_dependency_documentation(self, workflow_readme_text):
        text_lower = workflow_readme_text.lower()
        assert "scenario 1" in text_lower
        assert "scenario 2" in text_lower
        assert "scenario 3" in text_lower

    def test_readme_contains_deploy_vks_metrics_table(self, workflow_readme_text):
        assert "deploy-vks-metrics" in workflow_readme_text

    def test_readme_contains_deploy_argocd_table(self, workflow_readme_text):
        assert "deploy-argocd" in workflow_readme_text


# ===================================================================
# TestTriggerScripts — trigger script content checks
# Validates: Requirements 30.1, 30.2, 30.3, 30.4
# ===================================================================


class TestTriggerMetricsScript:
    """Trigger script for Scenario 2 contains required content."""

    def test_contains_deploy_vks_metrics_event_type(self, trigger_metrics_script_text):
        assert "deploy-vks-metrics" in trigger_metrics_script_text

    def test_contains_repo_arg(self, trigger_metrics_script_text):
        assert "--repo" in trigger_metrics_script_text

    def test_contains_token_arg(self, trigger_metrics_script_text):
        assert "--token" in trigger_metrics_script_text

    def test_contains_cluster_name_arg(self, trigger_metrics_script_text):
        assert "--cluster-name" in trigger_metrics_script_text

    def test_contains_help_flag(self, trigger_metrics_script_text):
        assert "--help" in trigger_metrics_script_text

    def test_contains_jq(self, trigger_metrics_script_text):
        assert "jq" in trigger_metrics_script_text

    def test_contains_curl(self, trigger_metrics_script_text):
        assert "curl" in trigger_metrics_script_text

    def test_contains_github_api_url(self, trigger_metrics_script_text):
        assert "api.github.com" in trigger_metrics_script_text


class TestTriggerArgocdScript:
    """Trigger script for Scenario 3 contains required content."""

    def test_contains_deploy_argocd_event_type(self, trigger_argocd_script_text):
        assert "deploy-argocd" in trigger_argocd_script_text

    def test_contains_repo_arg(self, trigger_argocd_script_text):
        assert "--repo" in trigger_argocd_script_text

    def test_contains_token_arg(self, trigger_argocd_script_text):
        assert "--token" in trigger_argocd_script_text

    def test_contains_cluster_name_arg(self, trigger_argocd_script_text):
        assert "--cluster-name" in trigger_argocd_script_text

    def test_contains_help_flag(self, trigger_argocd_script_text):
        assert "--help" in trigger_argocd_script_text

    def test_contains_jq(self, trigger_argocd_script_text):
        assert "jq" in trigger_argocd_script_text

    def test_contains_curl(self, trigger_argocd_script_text):
        assert "curl" in trigger_argocd_script_text

    def test_contains_github_api_url(self, trigger_argocd_script_text):
        assert "api.github.com" in trigger_argocd_script_text
