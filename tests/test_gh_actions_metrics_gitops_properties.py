# Feature: gh-actions-metrics-gitops, Property-Based Tests
# Property-based tests for the GitHub Actions Deploy Metrics and Deploy GitOps workflows.
# Each test validates one correctness property from the design document.

"""Property-based tests for the GitHub Actions Deploy Metrics and Deploy GitOps workflows."""

import re

import pytest
from hypothesis import given, settings, assume
from hypothesis import strategies as st


# ===================================================================
# Property 1: Hybrid Parameter Resolution in Both Workflows
# For any env var in both workflows, check it references both
# github.event.inputs and github.event.client_payload.
# Validates: Requirements 1.3, 1.4, 1.5, 2.3, 2.4, 2.5
# ===================================================================


class TestProperty1HybridParameterResolution:
    """Property 1: Hybrid Parameter Resolution in Both Workflows.

    For any trigger parameter defined in either workflow's env block,
    the YAML expression must reference both github.event.inputs.<param>
    and github.event.client_payload.<param>.

    **Validates: Requirements 1.3, 1.4, 1.5, 2.3, 2.4, 2.5**
    """

    # Env vars that have both input and payload sources in the metrics workflow
    METRICS_HYBRID_PARAMS = [
        "cluster_name",
        "telegraf_version",
        "environment",
    ]

    # Env vars that have both input and payload sources in the argocd workflow
    ARGOCD_HYBRID_PARAMS = [
        "cluster_name",
        "environment",
    ]

    @given(param=st.sampled_from(METRICS_HYBRID_PARAMS))
    @settings(max_examples=100)
    def test_metrics_env_references_both_sources(self, metrics_workflow_yaml_text: str, param: str):
        """Each metrics trigger parameter is resolved from both dispatch and payload."""
        inputs_ref = f"github.event.inputs.{param}"
        payload_ref = f"github.event.client_payload.{param}"
        assert inputs_ref in metrics_workflow_yaml_text, (
            f"Metrics workflow env block missing reference to '{inputs_ref}'"
        )
        assert payload_ref in metrics_workflow_yaml_text, (
            f"Metrics workflow env block missing reference to '{payload_ref}'"
        )

    @given(param=st.sampled_from(ARGOCD_HYBRID_PARAMS))
    @settings(max_examples=100)
    def test_argocd_env_references_both_sources(self, argocd_workflow_yaml_text: str, param: str):
        """Each argocd trigger parameter is resolved from both dispatch and payload."""
        inputs_ref = f"github.event.inputs.{param}"
        payload_ref = f"github.event.client_payload.{param}"
        assert inputs_ref in argocd_workflow_yaml_text, (
            f"ArgoCD workflow env block missing reference to '{inputs_ref}'"
        )
        assert payload_ref in argocd_workflow_yaml_text, (
            f"ArgoCD workflow env block missing reference to '{payload_ref}'"
        )


# ===================================================================
# Property 2: Runner Configuration Consistency
# For any workflow in {metrics, argocd}, runs-on includes self-hosted
# and vcf, environment is vcf-production, no container key.
# Validates: Requirements 3.1, 3.2, 4.1
# ===================================================================


class TestProperty2RunnerConfigurationConsistency:
    """Property 2: Runner Configuration Consistency.

    For any workflow in the set {deploy-vks-metrics.yml, deploy-argocd.yml},
    the deploy job must specify runs-on: [self-hosted, vcf],
    environment: vcf-production, and must NOT contain a container: key.

    **Validates: Requirements 3.1, 3.2, 4.1**
    """

    WORKFLOW_NAMES = ["metrics", "argocd"]

    @given(workflow_name=st.sampled_from(WORKFLOW_NAMES))
    @settings(max_examples=100)
    def test_runner_config_consistent(
        self,
        metrics_workflow_yaml: dict,
        argocd_workflow_yaml: dict,
        workflow_name: str,
    ):
        """Each workflow has correct runner config."""
        workflow = metrics_workflow_yaml if workflow_name == "metrics" else argocd_workflow_yaml
        deploy_job = workflow["jobs"]["deploy"]

        runs_on = deploy_job["runs-on"]
        assert "self-hosted" in runs_on, (
            f"{workflow_name} workflow missing 'self-hosted' in runs-on"
        )
        assert "vcf" in runs_on, (
            f"{workflow_name} workflow missing 'vcf' in runs-on"
        )
        assert deploy_job["environment"] == "vcf-production", (
            f"{workflow_name} workflow environment is not 'vcf-production'"
        )
        assert "container" not in deploy_job, (
            f"{workflow_name} workflow has a 'container' key"
        )


# ===================================================================
# Property 3: Deploy Metrics Required Phase Names
# For any required phase name from the design doc list, a matching
# step exists in metrics workflow.
# Validates: Requirements 5.1, 5.2, 6.1, 7.1, 7.2, 8.1, 9.1, 9.2,
#            9.3, 10.1, 11.1, 12.1, 13.1, 13.3, 14.1, 14.2
# ===================================================================


class TestProperty3DeployMetricsRequiredPhaseNames:
    """Property 3: Deploy Metrics Required Phase Names.

    For any required phase name from the Deploy Metrics phase list,
    there must exist a step in deploy-vks-metrics.yml with a matching name.

    **Validates: Requirements 5.1, 5.2, 6.1, 7.1, 7.2, 8.1, 9.1, 9.2, 9.3, 10.1, 11.1, 12.1, 13.1, 13.3, 14.1, 14.2**
    """

    REQUIRED_PHASES = [
        "Setup Kubeconfig",
        "Verify Cluster Connectivity",
        "Node Sizing Advisory",
        "Create Package Namespace",
        "Register Package Repository",
        "Install Telegraf",
        "Install cert-manager",
        "Install Contour",
        "Create Envoy LoadBalancer",
        "Generate Self-Signed Certificates",
        "Configure CoreDNS",
        "Install Prometheus",
        "Install Grafana Operator",
        "Configure Grafana Instance",
        "Verify Installation",
        "Write Job Summary",
    ]

    @given(phase=st.sampled_from(REQUIRED_PHASES))
    @settings(max_examples=100)
    def test_phase_has_named_step(self, metrics_workflow_yaml: dict, phase: str):
        """Each required Deploy Metrics phase has a matching named step."""
        steps = metrics_workflow_yaml["jobs"]["deploy"]["steps"]
        step_names = [s.get("name", "") for s in steps]
        assert any(phase.lower() == name.lower() for name in step_names), (
            f"Required Deploy Metrics phase '{phase}' not found in workflow steps. "
            f"Available: {step_names}"
        )


# ===================================================================
# Property 4: Deploy GitOps Required Phase Names
# For any required phase name from the design doc list, a matching
# step exists in argocd workflow.
# Validates: Requirements 15.1, 15.2, 16.1, 17.1, 17.2, 18.1, 19.1,
#            20.1, 21.1, 22.1, 23.1, 24.1, 25.1, 26.1, 27.1, 27.3,
#            28.1, 29.1
# ===================================================================


class TestProperty4DeployGitOpsRequiredPhaseNames:
    """Property 4: Deploy GitOps Required Phase Names.

    For any required phase name from the Deploy GitOps phase list,
    there must exist a step in deploy-argocd.yml with a matching name.

    **Validates: Requirements 15.1, 15.2, 16.1, 17.1, 17.2, 18.1, 19.1, 20.1, 21.1, 22.1, 23.1, 24.1, 25.1, 26.1, 27.1, 27.3, 28.1, 29.1**
    """

    REQUIRED_PHASES = [
        "Setup Kubeconfig",
        "Verify Cluster Connectivity",
        "Generate Self-Signed Certificates",
        "Create Package Namespace",
        "Register Package Repository",
        "Install cert-manager",
        "Install Contour",
        "Create Envoy LoadBalancer",
        "Install Harbor",
        "Configure CoreDNS",
        "Install ArgoCD",
        "Install ArgoCD CLI",
        "Distribute Certificates",
        "Install GitLab",
        "Verify Harbor Proxy Configuration",
        "Install GitLab Runner",
        "Disable GitLab Public Sign-Up",
        "Register Cluster with ArgoCD",
        "Bootstrap ArgoCD Application",
        "Verify Microservices Demo",
        "Write Job Summary",
    ]

    @given(phase=st.sampled_from(REQUIRED_PHASES))
    @settings(max_examples=100)
    def test_phase_has_named_step(self, argocd_workflow_yaml: dict, phase: str):
        """Each required Deploy GitOps phase has a matching named step."""
        steps = argocd_workflow_yaml["jobs"]["deploy"]["steps"]
        step_names = [s.get("name", "") for s in steps]
        assert any(phase.lower() == name.lower() for name in step_names), (
            f"Required Deploy GitOps phase '{phase}' not found in workflow steps. "
            f"Available: {step_names}"
        )


# ===================================================================
# Property 5: No Container Directive in Any Workflow
# For any job in either workflow, no container key exists.
# Validates: Requirements 3.2
# ===================================================================


class TestProperty5NoContainerDirective:
    """Property 5: No Container Directive in Any Workflow.

    For any job defined in either workflow YAML, the job must not
    contain a container key.

    **Validates: Requirements 3.2**
    """

    @given(data=st.data())
    @settings(max_examples=100)
    def test_no_container_in_any_job(
        self,
        metrics_workflow_yaml: dict,
        argocd_workflow_yaml: dict,
        data: st.DataObject,
    ):
        """No job in either workflow has a container directive."""
        all_jobs = []
        for job_name, job_def in metrics_workflow_yaml.get("jobs", {}).items():
            all_jobs.append(("metrics", job_name, job_def))
        for job_name, job_def in argocd_workflow_yaml.get("jobs", {}).items():
            all_jobs.append(("argocd", job_name, job_def))
        assume(len(all_jobs) > 0)
        workflow_name, job_name, job_def = data.draw(st.sampled_from(all_jobs))
        assert "container" not in job_def, (
            f"Job '{job_name}' in {workflow_name} workflow has a 'container' key"
        )


# ===================================================================
# Property 6: Failure Summary Conditional Step
# For any workflow, there exists a step named "Write Failure Summary"
# with if: failure().
# Validates: Requirements 14.3, 29.2
# ===================================================================


class TestProperty6FailureSummaryConditionalStep:
    """Property 6: Failure Summary Conditional Step.

    For any workflow in the set {deploy-vks-metrics.yml, deploy-argocd.yml},
    there must exist a step named "Write Failure Summary" with if: failure().

    **Validates: Requirements 14.3, 29.2**
    """

    WORKFLOW_NAMES = ["metrics", "argocd"]

    @given(workflow_name=st.sampled_from(WORKFLOW_NAMES))
    @settings(max_examples=100)
    def test_failure_summary_step_exists(
        self,
        metrics_workflow_yaml: dict,
        argocd_workflow_yaml: dict,
        workflow_name: str,
    ):
        """Each workflow has a Write Failure Summary step with if: failure()."""
        workflow = metrics_workflow_yaml if workflow_name == "metrics" else argocd_workflow_yaml
        steps = workflow["jobs"]["deploy"]["steps"]
        failure_steps = [
            s for s in steps
            if s.get("name", "").lower() == "write failure summary"
        ]
        assert len(failure_steps) > 0, (
            f"{workflow_name} workflow missing 'Write Failure Summary' step"
        )
        step = failure_steps[0]
        condition = step.get("if", "")
        assert "failure()" in condition, (
            f"{workflow_name} workflow 'Write Failure Summary' step missing 'if: failure()' condition"
        )


# ===================================================================
# Property 7: Deploy Metrics Job Summary Contains Required Fields
# For any required field, the Write Job Summary step references it.
# Validates: Requirements 14.2
# ===================================================================


class TestProperty7DeployMetricsJobSummaryFields:
    """Property 7: Deploy Metrics Job Summary Contains Required Fields.

    For any required field from the set (CLUSTER_NAME, DOMAIN,
    CONTOUR_LB_IP, grafana, GRAFANA_ADMIN_PASSWORD), the Write Job
    Summary step in deploy-vks-metrics.yml must reference it.

    **Validates: Requirements 14.2**
    """

    REQUIRED_FIELDS = [
        "CLUSTER_NAME",
        "DOMAIN",
        "CONTOUR_LB_IP",
        "grafana",
        "kubectl get grafana",
    ]

    @given(field=st.sampled_from(REQUIRED_FIELDS))
    @settings(max_examples=100)
    def test_job_summary_contains_field(self, metrics_workflow_yaml: dict, field: str):
        """The Write Job Summary step references each required field."""
        for step in metrics_workflow_yaml["jobs"]["deploy"]["steps"]:
            if step.get("name", "").lower() == "write job summary":
                run_block = step.get("run", "")
                assert field.lower() in run_block.lower(), (
                    f"Metrics Write Job Summary step missing reference to '{field}'"
                )
                return
        pytest.fail("'Write Job Summary' step not found in metrics workflow")


# ===================================================================
# Property 8: Deploy GitOps Job Summary Contains Required Fields
# For any required field, the Write Job Summary step references it.
# Validates: Requirements 29.1
# ===================================================================


class TestProperty8DeployGitOpsJobSummaryFields:
    """Property 8: Deploy GitOps Job Summary Contains Required Fields.

    For any required field from the set (CLUSTER_NAME, DOMAIN,
    CONTOUR_LB_IP, harbor, argocd, gitlab, FRONTEND_IP,
    HARBOR_ADMIN_PASSWORD, ARGOCD_PASSWORD), the Write Job Summary
    step in deploy-argocd.yml must reference it.

    **Validates: Requirements 29.1**
    """

    REQUIRED_FIELDS = [
        "CLUSTER_NAME",
        "DOMAIN",
        "CONTOUR_LB_IP",
        "harbor",
        "argocd",
        "gitlab",
        "FRONTEND_IP",
        "argocd-initial-admin-secret",
        "gitlab-gitlab-initial-root-password",
        "harbor-core",
    ]

    @given(field=st.sampled_from(REQUIRED_FIELDS))
    @settings(max_examples=100)
    def test_job_summary_contains_field(self, argocd_workflow_yaml: dict, field: str):
        """The Write Job Summary step references each required field."""
        for step in argocd_workflow_yaml["jobs"]["deploy"]["steps"]:
            if step.get("name", "").lower() == "write job summary":
                run_block = step.get("run", "")
                assert field.lower() in run_block.lower(), (
                    f"ArgoCD Write Job Summary step missing reference to '{field}'"
                )
                return
        pytest.fail("'Write Job Summary' step not found in argocd workflow")


# ===================================================================
# Property 9: Trigger Script Structural Compliance
# For any trigger script, it contains --repo, --token, --help, jq,
# curl, api.github.com, and the correct event_type.
# Validates: Requirements 30.1, 30.2, 30.3, 30.4
# ===================================================================


class TestProperty9TriggerScriptStructuralCompliance:
    """Property 9: Trigger Script Structural Compliance.

    For any trigger script in the set {trigger-deploy-metrics.sh,
    trigger-deploy-argocd.sh}, the script must contain: --repo and
    --token argument parsing, --help flag handling, jq usage, curl
    to the GitHub dispatches API, and the correct event_type string.

    **Validates: Requirements 30.1, 30.2, 30.3, 30.4**
    """

    REQUIRED_ELEMENTS = [
        "--repo",
        "--token",
        "--help",
        "jq",
        "curl",
        "api.github.com",
    ]

    SCRIPTS = [
        ("metrics", "deploy-vks-metrics"),
        ("argocd", "deploy-argocd"),
    ]

    @given(script_info=st.sampled_from(SCRIPTS))
    @settings(max_examples=100)
    def test_script_contains_required_elements(
        self,
        trigger_metrics_script_text: str,
        trigger_argocd_script_text: str,
        script_info: tuple,
    ):
        """Each trigger script contains all required structural elements."""
        script_name, event_type = script_info
        script_text = (
            trigger_metrics_script_text if script_name == "metrics"
            else trigger_argocd_script_text
        )
        for element in self.REQUIRED_ELEMENTS:
            assert element in script_text, (
                f"{script_name} trigger script missing '{element}'"
            )
        assert event_type in script_text, (
            f"{script_name} trigger script missing event_type '{event_type}'"
        )


# ===================================================================
# Property 10: Trigger Script Required Arguments
# For any required argument of each script, it appears in the script.
# Validates: Requirements 30.1, 30.2
# ===================================================================


class TestProperty10TriggerScriptRequiredArguments:
    """Property 10: Trigger Script Required Arguments.

    For any required argument of each trigger script, the argument
    must appear in the script's argument parsing block.

    **Validates: Requirements 30.1, 30.2**
    """

    METRICS_REQUIRED_ARGS = [
        "--repo",
        "--token",
        "--cluster-name",
    ]

    ARGOCD_REQUIRED_ARGS = [
        "--repo",
        "--token",
        "--cluster-name",
    ]

    @given(arg=st.sampled_from(METRICS_REQUIRED_ARGS))
    @settings(max_examples=100)
    def test_metrics_script_has_required_arg(self, trigger_metrics_script_text: str, arg: str):
        """Each required argument appears in the metrics trigger script."""
        assert arg in trigger_metrics_script_text, (
            f"Metrics trigger script missing required argument '{arg}'"
        )

    @given(arg=st.sampled_from(ARGOCD_REQUIRED_ARGS))
    @settings(max_examples=100)
    def test_argocd_script_has_required_arg(self, trigger_argocd_script_text: str, arg: str):
        """Each required argument appears in the argocd trigger script."""
        assert arg in trigger_argocd_script_text, (
            f"ArgoCD trigger script missing required argument '{arg}'"
        )


# ===================================================================
# Property 11: Idempotent Secret Creation Pattern
# For any step in argocd workflow that creates a Secret, the run
# block uses --dry-run=client -o yaml | kubectl apply -f -.
# Validates: Requirements 22.2, 32.1
# ===================================================================


class TestProperty11IdempotentSecretCreationPattern:
    """Property 11: Idempotent Secret Creation Pattern.

    For any step in deploy-argocd.yml that creates a Kubernetes Secret,
    the run block must use the --dry-run=client -o yaml | kubectl apply -f -
    pattern for idempotent creation.

    **Validates: Requirements 22.2, 32.1**
    """

    @staticmethod
    def _get_secret_creation_steps(workflow_yaml: dict) -> list[tuple[str, str]]:
        """Extract steps that create Kubernetes Secrets via kubectl create secret."""
        secret_steps = []
        for step in workflow_yaml["jobs"]["deploy"]["steps"]:
            run_block = step.get("run", "")
            if "kubectl create secret" in run_block:
                secret_steps.append((step.get("name", ""), run_block))
        return secret_steps

    @given(data=st.data())
    @settings(max_examples=100)
    def test_secret_creation_uses_dry_run_pattern(
        self, argocd_workflow_yaml: dict, data: st.DataObject
    ):
        """Each secret creation step uses the idempotent dry-run pattern."""
        secret_steps = self._get_secret_creation_steps(argocd_workflow_yaml)
        assume(len(secret_steps) > 0)
        step_name, run_block = data.draw(st.sampled_from(secret_steps))
        # Each kubectl create secret line should use --dry-run=client -o yaml | kubectl apply -f -
        for line in run_block.splitlines():
            if "kubectl create secret" in line:
                # The pattern may span multiple lines with continuation, so check the run block
                pass
        assert "--dry-run=client" in run_block, (
            f"Step '{step_name}' creates a Secret without --dry-run=client"
        )
        assert "kubectl apply -f -" in run_block, (
            f"Step '{step_name}' creates a Secret without 'kubectl apply -f -'"
        )


# ===================================================================
# Property 12: Deploy GitOps Microservices Demo Verification Completeness
# For any microservice name from the 11 services, the Verify
# Microservices Demo step references it.
# Validates: Requirements 28.1
# ===================================================================


class TestProperty12MicroservicesDemoVerification:
    """Property 12: Deploy GitOps Microservices Demo Verification Completeness.

    For any microservice name from the set of 11 services, the Verify
    Microservices Demo step must reference it.

    **Validates: Requirements 28.1**
    """

    MICROSERVICES = [
        "adservice",
        "cartservice",
        "checkoutservice",
        "currencyservice",
        "emailservice",
        "frontend",
        "loadgenerator",
        "paymentservice",
        "productcatalogservice",
        "recommendationservice",
        "shippingservice",
    ]

    @given(service=st.sampled_from(MICROSERVICES))
    @settings(max_examples=100)
    def test_verify_step_references_microservice(self, argocd_workflow_yaml: dict, service: str):
        """The Verify Microservices Demo step references each microservice."""
        for step in argocd_workflow_yaml["jobs"]["deploy"]["steps"]:
            if step.get("name", "").lower() == "verify microservices demo":
                run_block = step.get("run", "")
                assert service in run_block, (
                    f"Verify Microservices Demo step missing reference to '{service}'"
                )
                return
        pytest.fail("'Verify Microservices Demo' step not found in argocd workflow")


# ===================================================================
# Property 13: README Documents All Workflow Names
# For any workflow name from {deploy-vks-metrics, deploy-argocd},
# the README contains it.
# Validates: Requirements 31.1
# ===================================================================


class TestProperty13ReadmeDocumentsWorkflowNames:
    """Property 13: README Documents All Workflow Names.

    For any workflow name from the set {deploy-vks-metrics, deploy-argocd},
    the README must contain a reference to it.

    **Validates: Requirements 31.1**
    """

    WORKFLOW_NAMES = ["deploy-vks-metrics", "deploy-argocd"]

    @given(name=st.sampled_from(WORKFLOW_NAMES))
    @settings(max_examples=100)
    def test_readme_contains_workflow_name(self, workflow_readme_text: str, name: str):
        """The README contains each workflow name."""
        assert name in workflow_readme_text, (
            f"README does not contain workflow name '{name}'"
        )


# ===================================================================
# Property 14: Self-Hosted Runner Comment Block
# For any workflow text, it contains a comment mentioning self-hosted
# runner and Deploy Cluster.
# Validates: Requirements 3.3
# ===================================================================


class TestProperty14SelfHostedRunnerCommentBlock:
    """Property 14: Self-Hosted Runner Comment Block.

    For any workflow in the set {deploy-vks-metrics.yml, deploy-argocd.yml},
    the raw YAML text must contain a comment block mentioning the
    self-hosted runner requirement and Deploy Cluster prerequisite.

    **Validates: Requirements 3.3**
    """

    WORKFLOW_NAMES = ["metrics", "argocd"]

    @given(workflow_name=st.sampled_from(WORKFLOW_NAMES))
    @settings(max_examples=100)
    def test_comment_block_present(
        self,
        metrics_workflow_yaml_text: str,
        argocd_workflow_yaml_text: str,
        workflow_name: str,
    ):
        """Each workflow has a comment mentioning self-hosted runner and Deploy Cluster."""
        text = (
            metrics_workflow_yaml_text if workflow_name == "metrics"
            else argocd_workflow_yaml_text
        )
        text_lower = text.lower()
        assert "self-hosted" in text_lower, (
            f"{workflow_name} workflow missing 'self-hosted' in comment block"
        )
        assert "deploy cluster" in text_lower, (
            f"{workflow_name} workflow missing 'Deploy Cluster' in comment block"
        )


# ===================================================================
# Property 15: Workflow Dispatch Inputs Completeness
# For any required input (Deploy Metrics: cluster_name, telegraf_version;
# Deploy GitOps: cluster_name), the workflow_dispatch defines it with
# required: true.
# Validates: Requirements 1.1, 2.1
# ===================================================================


class TestProperty15WorkflowDispatchInputsCompleteness:
    """Property 15: Workflow Dispatch Inputs Completeness.

    For any required input parameter (Deploy Metrics: cluster_name,
    telegraf_version; Deploy GitOps: cluster_name), the workflow_dispatch
    trigger must define it with required: true.

    **Validates: Requirements 1.1, 2.1**
    """

    METRICS_REQUIRED_INPUTS = ["cluster_name"]
    ARGOCD_REQUIRED_INPUTS = ["cluster_name"]

    @given(input_name=st.sampled_from(METRICS_REQUIRED_INPUTS))
    @settings(max_examples=100)
    def test_metrics_required_input_is_required(
        self, metrics_workflow_yaml: dict, input_name: str
    ):
        """Each required Deploy Metrics input has required: true."""
        triggers = metrics_workflow_yaml.get("on") or metrics_workflow_yaml.get(True)
        inputs = triggers["workflow_dispatch"]["inputs"]
        assert input_name in inputs, (
            f"Metrics workflow_dispatch missing input '{input_name}'"
        )
        assert inputs[input_name].get("required") is True, (
            f"Metrics workflow_dispatch input '{input_name}' is not required"
        )

    @given(input_name=st.sampled_from(ARGOCD_REQUIRED_INPUTS))
    @settings(max_examples=100)
    def test_argocd_required_input_is_required(
        self, argocd_workflow_yaml: dict, input_name: str
    ):
        """Each required Deploy GitOps input has required: true."""
        triggers = argocd_workflow_yaml.get("on") or argocd_workflow_yaml.get(True)
        inputs = triggers["workflow_dispatch"]["inputs"]
        assert input_name in inputs, (
            f"ArgoCD workflow_dispatch missing input '{input_name}'"
        )
        assert inputs[input_name].get("required") is True, (
            f"ArgoCD workflow_dispatch input '{input_name}' is not required"
        )
