# Feature: gh-actions-vks-deploy, Property-Based Tests
# Property-based tests for the GitHub Actions VKS Deploy workflow.
# Each test validates one correctness property from the design document.

"""Property-based tests for the GitHub Actions VKS Deploy workflow."""

import re

import pytest
from hypothesis import given, settings, assume
from hypothesis import strategies as st


# ===================================================================
# Property 1: Unified Parameter Resolution
# For any trigger parameter, the workflow env block references both
# github.event.inputs.<param> and github.event.client_payload.<param>.
# Validates: Requirements 1.1, 1.3, 1.4
# ===================================================================


class TestProperty1UnifiedParameterResolution:
    """Property 1: Unified Parameter Resolution.

    For any trigger parameter name from the set (project_name, cluster_name,
    namespace_prefix, environment), the workflow YAML environment variable
    mapping must reference both github.event.inputs.<param> and
    github.event.client_payload.<param>.

    **Validates: Requirements 1.1, 1.3, 1.4**
    """

    TRIGGER_PARAMS = ["project_name", "cluster_name", "namespace_prefix", "environment"]

    @given(param=st.sampled_from(TRIGGER_PARAMS))
    @settings(max_examples=100)
    def test_env_references_both_input_sources(self, workflow_yaml_text: str, param: str):
        """Each trigger parameter is resolved from both dispatch and payload."""
        inputs_ref = f"github.event.inputs.{param}"
        payload_ref = f"github.event.client_payload.{param}"
        assert inputs_ref in workflow_yaml_text, (
            f"Workflow env block missing reference to '{inputs_ref}'"
        )
        assert payload_ref in workflow_yaml_text, (
            f"Workflow env block missing reference to '{payload_ref}'"
        )


# ===================================================================
# Property 2: Secrets Never Appear as Plaintext
# For any sensitive variable, it is referenced via secrets.<NAME> syntax.
# Validates: Requirements 1.5
# ===================================================================


class TestProperty2SecretsNeverPlaintext:
    """Property 2: Secrets Never Appear as Plaintext.

    For any sensitive variable name from the required set, every reference
    in the workflow YAML must use the ${{ secrets.<NAME> }} expression syntax.

    **Validates: Requirements 1.5**
    """

    SENSITIVE_VARS = [
        "VCF_API_TOKEN", "VCFA_ENDPOINT", "TENANT_NAME",
        "USER_IDENTITY", "CONTENT_LIBRARY_ID", "ZONE_NAME",
    ]

    @given(secret=st.sampled_from(SENSITIVE_VARS))
    @settings(max_examples=100)
    def test_secret_referenced_via_secrets_syntax(self, workflow_yaml_text: str, secret: str):
        """Each sensitive variable is referenced via ${{ secrets.<NAME> }}."""
        pattern = rf"secrets\.{secret}"
        assert re.search(pattern, workflow_yaml_text), (
            f"Secret '{secret}' not referenced via secrets.{secret} syntax"
        )


# ===================================================================
# Property 3: No Deploy Script Reference
# For any line in the workflow YAML, it shall not contain a reference
# to scenario1-full-stack-deploy.sh.
# Validates: Requirements 3.2
# ===================================================================


class TestProperty3NoDeployScriptReference:
    """Property 3: No Deploy Script Reference.

    For any line in the workflow YAML file, that line shall not contain
    a reference to scenario1-full-stack-deploy.sh.

    **Validates: Requirements 3.2**
    """

    @given(data=st.data())
    @settings(max_examples=100)
    def test_no_line_references_deploy_script(self, workflow_yaml_text: str, data: st.DataObject):
        """No random line from the workflow references the deploy script."""
        lines = [l for l in workflow_yaml_text.splitlines() if l.strip()]
        assume(len(lines) > 0)
        line = data.draw(st.sampled_from(lines))
        assert "scenario1-full-stack-deploy.sh" not in line, (
            f"Workflow line references deploy script: {line}"
        )


# ===================================================================
# Property 4: All Provisioning Phases Have Named Steps
# For any required provisioning phase name, a matching step exists.
# Validates: Requirements 3.3, 4.1, 5.1, 5.3, 6.1, 7.1, 7.3, 8.1,
#            8.2, 8.3, 9.1, 9.2, 9.3, 9.4
# ===================================================================


class TestProperty4AllProvisioningPhasesNamed:
    """Property 4: All Provisioning Phases Have Named Steps.

    For any required provisioning phase name from the set of 13 phases,
    there must exist a step in the workflow YAML with a matching name.

    **Validates: Requirements 3.3, 4.1, 5.1, 5.3, 6.1, 7.1, 7.3, 8.1, 8.2, 8.3, 9.1, 9.2, 9.3, 9.4**
    """

    REQUIRED_PHASES = [
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
    ]

    @given(phase=st.sampled_from(REQUIRED_PHASES))
    @settings(max_examples=100)
    def test_phase_has_named_step(self, workflow_yaml: dict, phase: str):
        """Each required provisioning phase has a matching named step."""
        steps = workflow_yaml["jobs"]["deploy"]["steps"]
        step_names = [s.get("name", "") for s in steps]
        assert any(phase.lower() == name.lower() for name in step_names), (
            f"Required provisioning phase '{phase}' not found in workflow steps. "
            f"Available: {step_names}"
        )


# ===================================================================
# Property 5: Error Messages Exclude API Token
# For any step with error handling, the error message text doesn't
# contain VCF_API_TOKEN or $VCF_API_TOKEN.
# Validates: Requirements 4.3
# ===================================================================


class TestProperty5ErrorMessagesExcludeToken:
    """Property 5: Error Messages Exclude API Token.

    For any error-handling block in the workflow steps that contains
    echo "::error::", the error message text shall never include the
    API token variable.

    **Validates: Requirements 4.3**
    """

    @staticmethod
    def _extract_error_steps(workflow_yaml: dict) -> list[str]:
        """Extract run blocks from steps that contain ::error:: messages."""
        error_blocks = []
        for step in workflow_yaml["jobs"]["deploy"]["steps"]:
            run_block = step.get("run", "")
            if "::error::" in run_block:
                # Extract just the error message lines
                for line in run_block.splitlines():
                    if "::error::" in line:
                        error_blocks.append(line)
        return error_blocks

    @given(data=st.data())
    @settings(max_examples=100)
    def test_error_message_excludes_api_token(self, workflow_yaml: dict, data: st.DataObject):
        """No error message line contains VCF_API_TOKEN reference."""
        error_lines = self._extract_error_steps(workflow_yaml)
        assume(len(error_lines) > 0)
        line = data.draw(st.sampled_from(error_lines))
        assert "VCF_API_TOKEN" not in line, (
            f"Error message contains API token reference: {line}"
        )
        assert "$VCF_API_TOKEN" not in line, (
            f"Error message contains API token variable: {line}"
        )


# ===================================================================
# Property 6: Polling Configuration Matches Specified Defaults
# For any polling step, timeout and interval match the design spec.
# Validates: Requirements 6.3, 7.3, 8.2, 8.3, 9.2, 9.3
# ===================================================================


class TestProperty6PollingConfigurationDefaults:
    """Property 6: Polling Configuration Matches Specified Defaults.

    For any polling or retry loop in the workflow steps, the timeout and
    interval values shall match the specified defaults from the design.

    **Validates: Requirements 6.3, 7.3, 8.2, 8.3, 9.2, 9.3**
    """

    # Mapping: step name -> (expected_timeout, expected_interval)
    POLLING_STEPS = {
        "Execute Context Bridge": (120, 10),
        "Wait for Cluster Provisioning": (1800, 15),
        "Wait for Guest Cluster API": (300, 10),
        "Wait for Worker Nodes Ready": (600, 15),
        "Wait for PVC Bound": (300, 15),
        "Wait for LoadBalancer IP": (300, 15),
    }

    @staticmethod
    def _get_step_run(workflow_yaml: dict, name: str) -> str:
        """Return the run block for a step by name (case-insensitive)."""
        for step in workflow_yaml["jobs"]["deploy"]["steps"]:
            if step.get("name", "").lower() == name.lower():
                return step.get("run", "")
        return ""

    @given(step_name=st.sampled_from(list(POLLING_STEPS.keys())))
    @settings(max_examples=100)
    def test_polling_timeout_and_interval(self, workflow_yaml: dict, step_name: str):
        """Each polling step has the correct timeout and interval values."""
        expected_timeout, expected_interval = self.POLLING_STEPS[step_name]
        run_block = self._get_step_run(workflow_yaml, step_name)
        assert run_block, f"Step '{step_name}' not found or has no run block"

        # Check TIMEOUT=<value>
        timeout_match = re.search(r"TIMEOUT=(\d+)", run_block)
        assert timeout_match, (
            f"Step '{step_name}' missing TIMEOUT assignment"
        )
        assert int(timeout_match.group(1)) == expected_timeout, (
            f"Step '{step_name}' TIMEOUT={timeout_match.group(1)}, "
            f"expected {expected_timeout}"
        )

        # Check INTERVAL=<value>
        interval_match = re.search(r"INTERVAL=(\d+)", run_block)
        assert interval_match, (
            f"Step '{step_name}' missing INTERVAL assignment"
        )
        assert int(interval_match.group(1)) == expected_interval, (
            f"Step '{step_name}' INTERVAL={interval_match.group(1)}, "
            f"expected {expected_interval}"
        )


# ===================================================================
# Property 7: Job Summary Contains All Required Fields
# The "Write Job Summary" step references cluster name, namespace,
# kubeconfig artifact, and external IP.
# Validates: Requirements 10.1
# ===================================================================


class TestProperty7JobSummaryRequiredFields:
    """Property 7: Job Summary Contains All Required Fields.

    For any required field from the set (cluster name, namespace, kubeconfig
    artifact, external IP), the Write Job Summary step must reference it.

    **Validates: Requirements 10.1**
    """

    # Each tuple: (field_description, substring_to_find_in_step)
    REQUIRED_FIELDS = [
        ("cluster name", "CLUSTER_NAME"),
        ("namespace", "DYNAMIC_NS_NAME"),
        ("kubeconfig artifact", "kubeconfig"),
        ("external IP", "external_ip"),
    ]

    @given(field=st.sampled_from(REQUIRED_FIELDS))
    @settings(max_examples=100)
    def test_job_summary_contains_field(self, workflow_yaml: dict, field: tuple):
        """The Write Job Summary step references each required field."""
        field_desc, substring = field
        for step in workflow_yaml["jobs"]["deploy"]["steps"]:
            if step.get("name", "").lower() == "write job summary":
                run_block = step.get("run", "")
                assert substring.lower() in run_block.lower(), (
                    f"Write Job Summary step missing reference to {field_desc} "
                    f"(expected '{substring}' in run block)"
                )
                return
        pytest.fail("'Write Job Summary' step not found in workflow")


# ===================================================================
# Property 8: All Workflow Steps Have Descriptive Names
# For any step in the workflow, the name field is present and non-empty.
# Validates: Requirements 10.3
# ===================================================================


class TestProperty8AllStepsHaveNames:
    """Property 8: All Workflow Steps Have Descriptive Names.

    For any step in the workflow YAML, the name field must be present
    and non-empty.

    **Validates: Requirements 10.3**
    """

    @given(data=st.data())
    @settings(max_examples=100)
    def test_step_has_non_empty_name(self, workflow_yaml: dict, data: st.DataObject):
        """Every workflow step has a non-empty name field."""
        steps = workflow_yaml["jobs"]["deploy"]["steps"]
        assume(len(steps) > 0)
        step = data.draw(st.sampled_from(steps))
        name = step.get("name", "")
        assert name and name.strip(), (
            f"Workflow step missing or empty 'name' field: {step}"
        )


# ===================================================================
# Property 9: Trigger Script Validates Required Arguments
# For any required argument, it appears in the trigger script.
# Validates: Requirements 11.1, 11.3
# ===================================================================


class TestProperty9TriggerScriptValidatesArgs:
    """Property 9: Trigger Script Validates Required Arguments.

    For any required argument from the set (--repo, --token, --project-name,
    --cluster-name, --namespace-prefix), it must appear in the trigger script.

    **Validates: Requirements 11.1, 11.3**
    """

    REQUIRED_ARGS = [
        "--repo",
        "--token",
        "--project-name",
        "--cluster-name",
        "--namespace-prefix",
    ]

    @given(arg=st.sampled_from(REQUIRED_ARGS))
    @settings(max_examples=100)
    def test_required_arg_in_trigger_script(self, trigger_script_text: str, arg: str):
        """Each required argument appears in the trigger script."""
        assert arg in trigger_script_text, (
            f"Trigger script does not reference required argument '{arg}'"
        )


# ===================================================================
# Property 10: README Documents All Workflow Secrets
# For any secret referenced in the workflow via secrets.<NAME>,
# it appears in the README.
# Validates: Requirements 12.1
# ===================================================================


class TestProperty10ReadmeDocumentsSecrets:
    """Property 10: README Documents All Workflow Secrets.

    For any secret name referenced in the workflow YAML via secrets.<NAME>,
    that secret name must appear in the companion README file.

    **Validates: Requirements 12.1**
    """

    @staticmethod
    def _extract_secrets(workflow_yaml_text: str) -> list[str]:
        """Extract all secret names referenced via secrets.<NAME>."""
        return list(set(re.findall(r"secrets\.([A-Z_]+)", workflow_yaml_text)))

    @given(data=st.data())
    @settings(max_examples=100)
    def test_secret_documented_in_readme(
        self, workflow_yaml_text: str, workflow_readme_text: str, data: st.DataObject
    ):
        """Each workflow secret is documented in the README."""
        secrets_list = self._extract_secrets(workflow_yaml_text)
        assume(len(secrets_list) > 0)
        secret = data.draw(st.sampled_from(secrets_list))
        assert secret in workflow_readme_text, (
            f"Secret '{secret}' referenced in workflow but not documented in README"
        )


# ===================================================================
# Property 11: Runner Container Service in Docker Compose
# For any required config key, it exists in the gh-actions-runner service.
# Validates: Requirements 2.4, 2.5, 13.1, 13.2, 13.4
# ===================================================================


class TestProperty11RunnerContainerService:
    """Property 11: Runner Container Service in Docker Compose.

    For any required runner service configuration key from the set
    (image, container_name, environment, volumes), the gh-actions-runner
    service in docker-compose.yml must include that key.

    **Validates: Requirements 2.4, 2.5, 13.1, 13.2, 13.4**
    """

    REQUIRED_KEYS = ["image", "container_name", "environment", "volumes"]

    @given(key=st.sampled_from(REQUIRED_KEYS))
    @settings(max_examples=100)
    def test_runner_service_has_required_key(self, docker_compose_yaml: dict, key: str):
        """The gh-actions-runner service has each required config key."""
        runner = docker_compose_yaml["services"]["gh-actions-runner"]
        assert key in runner, (
            f"gh-actions-runner service missing required key '{key}'. "
            f"Available keys: {list(runner.keys())}"
        )

    def test_docker_socket_mount(self, docker_compose_yaml: dict):
        """The volumes list includes the Docker socket mount."""
        runner = docker_compose_yaml["services"]["gh-actions-runner"]
        volumes = runner.get("volumes", [])
        assert "/var/run/docker.sock:/var/run/docker.sock" in volumes, (
            f"Docker socket mount not found in runner volumes: {volumes}"
        )

    def test_required_env_vars(self, docker_compose_yaml: dict):
        """The environment list includes RUNNER_TOKEN, REPO_URL, RUNNER_NAME, and LABELS."""
        runner = docker_compose_yaml["services"]["gh-actions-runner"]
        env = runner.get("environment", [])
        if isinstance(env, list):
            env_str = " ".join(env)
        else:
            env_str = " ".join(f"{k}={v}" for k, v in env.items())
        for var in ["RUNNER_TOKEN", "REPO_URL", "RUNNER_NAME", "LABELS"]:
            assert var in env_str, (
                f"Runner service missing environment variable '{var}'"
            )


# ===================================================================
# Property 12: Workflow Uses Runner Labels and Container Directive
# Verify runs-on includes self-hosted and vcf, and container.image
# references vcf9-dev.
# Validates: Requirements 2.1, 3.1, 3.7
# ===================================================================


class TestProperty12RunnerLabelsAndContainer:
    """Property 12: Workflow Uses Runner Labels and Container Directive.

    The deploy job's runs-on field must include both self-hosted and vcf
    labels, and the container.image field must reference vcf9-dev.

    **Validates: Requirements 2.1, 3.1, 3.7**
    """

    REQUIRED_LABELS = ["self-hosted", "vcf"]

    @given(label=st.sampled_from(REQUIRED_LABELS))
    @settings(max_examples=100)
    def test_runs_on_includes_label(self, workflow_yaml: dict, label: str):
        """The deploy job runs-on includes each required label."""
        runs_on = workflow_yaml["jobs"]["deploy"]["runs-on"]
        assert label in runs_on, (
            f"Deploy job runs-on missing label '{label}'. Current: {runs_on}"
        )

    def test_container_image_references_vcf9_dev(self, workflow_yaml: dict):
        """The deploy job container image references vcf9-dev."""
        container = workflow_yaml["jobs"]["deploy"]["container"]
        image = container["image"] if isinstance(container, dict) else container
        assert "vcf9-dev" in image, (
            f"Deploy job container image does not reference vcf9-dev: {image}"
        )
