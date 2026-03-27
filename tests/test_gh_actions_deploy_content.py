"""Content-presence unit tests for the GitHub Actions VKS Deploy workflow."""

import re


# ===================================================================
# TestWorkflowStructure — workflow YAML structure and triggers
# Validates: Requirements 1.1, 1.2, 1.3, 2.1, 3.1, 3.7
# ===================================================================


class TestWorkflowStructure:
    """Workflow YAML parses correctly and has expected triggers and runner config."""

    def test_workflow_yaml_parses(self, workflow_yaml):
        assert isinstance(workflow_yaml, dict), "Workflow YAML did not parse as a dict"

    def test_workflow_dispatch_has_four_inputs(self, workflow_yaml):
        # PyYAML parses the YAML key `on` as boolean True
        triggers = workflow_yaml.get("on") or workflow_yaml.get(True)
        inputs = triggers["workflow_dispatch"]["inputs"]
        assert len(inputs) == 4, (
            f"Expected 4 workflow_dispatch inputs, got {len(inputs)}"
        )

    def test_workflow_dispatch_input_names(self, workflow_yaml):
        triggers = workflow_yaml.get("on") or workflow_yaml.get(True)
        inputs = triggers["workflow_dispatch"]["inputs"]
        expected = {"project_name", "cluster_name", "namespace_prefix", "environment"}
        assert set(inputs.keys()) == expected

    def test_repository_dispatch_has_deploy_vks(self, workflow_yaml):
        triggers = workflow_yaml.get("on") or workflow_yaml.get(True)
        types = triggers["repository_dispatch"]["types"]
        assert "deploy-vks" in types

    def test_runs_on_includes_self_hosted_and_vcf(self, workflow_yaml):
        runs_on = workflow_yaml["jobs"]["deploy"]["runs-on"]
        assert "self-hosted" in runs_on
        assert "vcf" in runs_on

    def test_no_container_directive(self, workflow_yaml):
        """deploy-vks.yml runs directly on the self-hosted runner — no container: directive."""
        assert "container" not in workflow_yaml["jobs"]["deploy"], (
            "deploy-vks.yml should not have a container: directive"
        )


# ===================================================================
# TestWorkflowSecrets — all 6 required secrets referenced correctly
# Validates: Requirements 1.5
# ===================================================================


class TestWorkflowSecrets:
    """All required secrets are referenced via ${{ secrets.NAME }}."""

    REQUIRED_SECRETS = [
        "VCF_API_TOKEN",
        "VCFA_ENDPOINT",
        "TENANT_NAME",
        "USER_IDENTITY",
        "CONTENT_LIBRARY_ID",
        "ZONE_NAME",
    ]

    def test_all_required_secrets_referenced(self, workflow_yaml_text):
        for secret in self.REQUIRED_SECRETS:
            pattern = rf"secrets\.{secret}"
            assert re.search(pattern, workflow_yaml_text), (
                f"Secret '{secret}' not referenced via secrets.{secret} syntax"
            )

    def test_no_plaintext_sensitive_values(self, workflow_yaml_text):
        """No line should contain a plaintext API token or endpoint value."""
        # Check that secrets are only referenced through expressions, not hardcoded
        for secret in self.REQUIRED_SECRETS:
            # Find all lines that assign this secret name
            for line in workflow_yaml_text.splitlines():
                if f"{secret}:" in line and "secrets." not in line and "#" not in line.split(secret)[0]:
                    # Allow lines that are just env var names or comments
                    if "github.event" not in line and "${{" not in line:
                        stripped = line.strip()
                        # Skip lines that are just the variable name in a list
                        if not stripped.startswith("-") and not stripped.startswith("#"):
                            assert False, (
                                f"Secret '{secret}' appears to have a plaintext value: {line.strip()}"
                            )


# ===================================================================
# TestWorkflowNoScriptWrapper — no reference to scenario1 deploy script
# Validates: Requirements 3.2
# ===================================================================


class TestWorkflowNoScriptWrapper:
    """Workflow does not reference the scenario1 deploy script."""

    def test_no_scenario1_script_reference(self, workflow_yaml_text):
        assert "scenario1-full-stack-deploy.sh" not in workflow_yaml_text, (
            "Workflow references scenario1-full-stack-deploy.sh — it should implement logic inline"
        )


# ===================================================================
# TestWorkflowStepNames — all 17 required step names exist
# Validates: Requirements 3.3, 4.1, 5.1, 5.3, 6.1, 7.1, 7.3, 8.1,
#            8.2, 8.3, 9.1, 9.2, 9.3, 9.4, 8.5, 10.1, 10.2
# ===================================================================


class TestWorkflowStepNames:
    """All required step names exist in the workflow."""

    REQUIRED_STEP_NAMES = [
        "Validate Inputs",
        "Create VCF CLI Context",
        "Create Project and Namespace",
        "Get Dynamic Namespace Name",
        "Execute Context Bridge",
        "Deploy VKS Cluster",
        "Wait for Cluster Provisioning",
        "Retrieve Kubeconfig",
        "Wait for Guest Cluster API",
        "Wait for Worker Nodes Ready",
        "Deploy Functional Test Workload",
        "Wait for PVC Bound",
        "Wait for LoadBalancer IP",
        "HTTP Connectivity Test",
        "Write Job Summary",
        "Write Failure Summary",
    ]

    def test_all_required_step_names_present(self, workflow_yaml):
        steps = workflow_yaml["jobs"]["deploy"]["steps"]
        step_names = [s.get("name", "") for s in steps]
        for required in self.REQUIRED_STEP_NAMES:
            assert any(required.lower() == name.lower() for name in step_names), (
                f"Required step '{required}' not found in workflow steps"
            )

    def test_step_count_at_least_16(self, workflow_yaml):
        steps = workflow_yaml["jobs"]["deploy"]["steps"]
        assert len(steps) >= 16, (
            f"Expected at least 16 steps, got {len(steps)}"
        )


# ===================================================================
# TestWorkflowStepContent — key commands exist in the right steps
# Validates: Requirements 4.1, 4.2, 5.1, 5.4, 6.1, 7.1, 8.1, 9.4, 10.2
# ===================================================================


class TestWorkflowStepContent:
    """Key commands and patterns exist in the correct workflow steps."""

    @staticmethod
    def _get_step_by_name(workflow_yaml, name):
        """Return the step dict matching the given name (case-insensitive)."""
        for step in workflow_yaml["jobs"]["deploy"]["steps"]:
            if step.get("name", "").lower() == name.lower():
                return step
        raise AssertionError(f"Step '{name}' not found")

    def test_context_create_command(self, workflow_yaml):
        step = self._get_step_by_name(workflow_yaml, "Create VCF CLI Context")
        assert "vcf context create" in step.get("run", "")

    def test_kubectl_create_validate_false(self, workflow_yaml):
        step = self._get_step_by_name(workflow_yaml, "Create Project and Namespace")
        run_block = step.get("run", "")
        assert "kubectl create" in run_block
        assert "--validate=false" in run_block

    def test_github_output_usage(self, workflow_yaml_text):
        assert "GITHUB_OUTPUT" in workflow_yaml_text

    def test_github_env_usage(self, workflow_yaml_text):
        assert "GITHUB_ENV" in workflow_yaml_text

    def test_kubectl_get_clusters_in_context_bridge(self, workflow_yaml):
        step = self._get_step_by_name(workflow_yaml, "Execute Context Bridge")
        assert "kubectl get clusters" in step.get("run", "")

    def test_kubectl_apply_insecure_skip_tls(self, workflow_yaml):
        step = self._get_step_by_name(workflow_yaml, "Deploy VKS Cluster")
        run_block = step.get("run", "")
        assert "kubectl apply" in run_block
        assert "--insecure-skip-tls-verify" in run_block

    def test_vcf_cluster_kubeconfig_get(self, workflow_yaml):
        step = self._get_step_by_name(workflow_yaml, "Retrieve Kubeconfig")
        assert "vcf cluster kubeconfig get" in step.get("run", "")

    def test_curl_in_http_test(self, workflow_yaml):
        step = self._get_step_by_name(workflow_yaml, "HTTP Connectivity Test")
        assert "curl" in step.get("run", "")

    def test_failure_condition_on_failure_summary(self, workflow_yaml):
        step = self._get_step_by_name(workflow_yaml, "Write Failure Summary")
        condition = step.get("if", "")
        assert "failure()" in condition


# ===================================================================
# TestTriggerScript — trigger script content checks
# Validates: Requirements 11.1, 11.2, 11.3, 11.4, 11.5
# ===================================================================


class TestTriggerScript:
    """Trigger script contains required content."""

    def test_contains_deploy_vks_event_type(self, trigger_script_text):
        assert "deploy-vks" in trigger_script_text

    def test_contains_github_api_url(self, trigger_script_text):
        assert "api.github.com" in trigger_script_text

    def test_prints_actions_url(self, trigger_script_text):
        # The script should print a URL pointing to the Actions tab
        assert "actions" in trigger_script_text.lower()
        assert "github.com" in trigger_script_text

    def test_validates_required_args(self, trigger_script_text):
        """Script checks for missing required arguments."""
        required_args = ["--repo", "--token", "--project-name", "--cluster-name", "--namespace-prefix"]
        for arg in required_args:
            assert arg in trigger_script_text, (
                f"Trigger script does not reference required argument '{arg}'"
            )


# ===================================================================
# TestWorkflowReadme — README content checks
# Validates: Requirements 12.1, 12.2, 12.3, 12.4
# ===================================================================


class TestWorkflowReadme:
    """Workflow README contains required documentation."""

    REQUIRED_SECRET_NAMES = [
        "VCF_API_TOKEN",
        "VCFA_ENDPOINT",
        "TENANT_NAME",
        "USER_IDENTITY",
        "CONTENT_LIBRARY_ID",
        "ZONE_NAME",
    ]

    def test_readme_contains_all_secret_names(self, workflow_readme_text):
        for secret in self.REQUIRED_SECRET_NAMES:
            assert secret in workflow_readme_text, (
                f"README does not document secret '{secret}'"
            )

    def test_readme_contains_self_hosted(self, workflow_readme_text):
        assert "self-hosted" in workflow_readme_text.lower(), (
            "README does not mention self-hosted runner"
        )

    def test_readme_contains_troubleshooting(self, workflow_readme_text):
        assert "troubleshooting" in workflow_readme_text.lower(), (
            "README does not contain a troubleshooting section"
        )


# ===================================================================
# TestDockerComposeRunner — docker-compose runner service checks
# Validates: Requirements 2.4, 2.5, 13.1, 13.2, 13.3, 13.4, 13.5
# ===================================================================


class TestDockerComposeRunner:
    """Docker-compose gh-actions-runner service is properly configured."""

    def test_gh_actions_runner_service_exists(self, docker_compose_yaml):
        assert "gh-actions-runner" in docker_compose_yaml.get("services", {}), (
            "docker-compose.yml does not contain 'gh-actions-runner' service"
        )

    def test_docker_socket_mount(self, docker_compose_yaml):
        runner = docker_compose_yaml["services"]["gh-actions-runner"]
        volumes = runner.get("volumes", [])
        socket_mount = "/var/run/docker.sock:/var/run/docker.sock"
        assert socket_mount in volumes, (
            f"Runner service missing Docker socket mount: {socket_mount}"
        )

    def test_runner_token_env_var(self, docker_compose_yaml):
        runner = docker_compose_yaml["services"]["gh-actions-runner"]
        env = runner.get("environment", [])
        # Environment can be a list of strings or a dict
        if isinstance(env, list):
            env_str = " ".join(env)
        else:
            env_str = " ".join(f"{k}={v}" for k, v in env.items())
        assert "RUNNER_TOKEN" in env_str, (
            "Runner service missing RUNNER_TOKEN environment variable"
        )
