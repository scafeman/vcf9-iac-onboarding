# Feature: workflow-secrets-hardening, Unit Tests
# Unit tests for the workflow secrets hardening changes.

"""Unit tests for the workflow secrets hardening changes."""

import pytest


class TestScenario1Hardening:
    """Tests for Scenario 1 (deploy-vks.yml) hardening changes."""

    def test_scenario1_no_upload_artifact_step(self, workflow_yaml_text: str):
        """upload-artifact action should not be present in deploy-vks.yml."""
        assert "upload-artifact" not in workflow_yaml_text, (
            "deploy-vks.yml still contains an upload-artifact reference"
        )

    def test_scenario1_summary_has_vcf_retrieval_command(self, workflow_yaml: dict):
        """Write Job Summary step should contain vcf cluster kubeconfig get command."""
        for step in workflow_yaml["jobs"]["deploy"]["steps"]:
            if step.get("name", "").lower() == "write job summary":
                run_block = step.get("run", "")
                assert "vcf cluster kubeconfig get" in run_block, (
                    "Write Job Summary step missing 'vcf cluster kubeconfig get' retrieval command"
                )
                return
        pytest.fail("'Write Job Summary' step not found in deploy-vks.yml")

    def test_scenario1_summary_no_artifact_reference(self, workflow_yaml: dict):
        """Write Job Summary step should not contain 'Uploaded as artifact'."""
        for step in workflow_yaml["jobs"]["deploy"]["steps"]:
            if step.get("name", "").lower() == "write job summary":
                run_block = step.get("run", "")
                assert "Uploaded as artifact" not in run_block, (
                    "Write Job Summary step still contains 'Uploaded as artifact' reference"
                )
                return
        pytest.fail("'Write Job Summary' step not found in deploy-vks.yml")


class TestScenario2Hardening:
    """Tests for Scenario 2 (deploy-vks-metrics.yml) hardening changes."""

    def test_scenario2_summary_no_grafana_password(self, metrics_workflow_yaml: dict):
        """Write Job Summary step should not contain GRAFANA_ADMIN_PASSWORD."""
        for step in metrics_workflow_yaml["jobs"]["deploy"]["steps"]:
            if step.get("name", "").lower() == "write job summary":
                run_block = step.get("run", "")
                assert "GRAFANA_ADMIN_PASSWORD" not in run_block, (
                    "Metrics Write Job Summary step still contains GRAFANA_ADMIN_PASSWORD"
                )
                return
        pytest.fail("'Write Job Summary' step not found in metrics workflow")

    def test_scenario2_has_add_mask(self, metrics_workflow_yaml_text: str):
        """deploy-vks-metrics.yml should contain ::add-mask:: calls."""
        assert "::add-mask::" in metrics_workflow_yaml_text, (
            "deploy-vks-metrics.yml missing ::add-mask:: call"
        )


class TestScenario3Hardening:
    """Tests for Scenario 3 (deploy-argocd.yml) hardening changes."""

    def test_scenario3_summary_no_harbor_password(self, argocd_workflow_yaml: dict):
        """Write Job Summary step should not contain HARBOR_ADMIN_PASSWORD."""
        for step in argocd_workflow_yaml["jobs"]["deploy"]["steps"]:
            if step.get("name", "").lower() == "write job summary":
                run_block = step.get("run", "")
                assert "HARBOR_ADMIN_PASSWORD" not in run_block, (
                    "ArgoCD Write Job Summary step still contains HARBOR_ADMIN_PASSWORD"
                )
                return
        pytest.fail("'Write Job Summary' step not found in argocd workflow")

    def test_scenario3_summary_no_argocd_password(self, argocd_workflow_yaml: dict):
        """Write Job Summary step should not contain ARGOCD_PASSWORD."""
        for step in argocd_workflow_yaml["jobs"]["deploy"]["steps"]:
            if step.get("name", "").lower() == "write job summary":
                run_block = step.get("run", "")
                assert "ARGOCD_PASSWORD" not in run_block, (
                    "ArgoCD Write Job Summary step still contains ARGOCD_PASSWORD"
                )
                return
        pytest.fail("'Write Job Summary' step not found in argocd workflow")

    def test_scenario3_summary_no_gitlab_password(self, argocd_workflow_yaml: dict):
        """Write Job Summary step should not contain GITLAB_ROOT_PASSWORD."""
        for step in argocd_workflow_yaml["jobs"]["deploy"]["steps"]:
            if step.get("name", "").lower() == "write job summary":
                run_block = step.get("run", "")
                assert "GITLAB_ROOT_PASSWORD" not in run_block, (
                    "ArgoCD Write Job Summary step still contains GITLAB_ROOT_PASSWORD"
                )
                return
        pytest.fail("'Write Job Summary' step not found in argocd workflow")

    def test_scenario3_has_add_mask(self, argocd_workflow_yaml_text: str):
        """deploy-argocd.yml should contain ::add-mask:: calls."""
        assert "::add-mask::" in argocd_workflow_yaml_text, (
            "deploy-argocd.yml missing ::add-mask:: call"
        )


class TestReadmeHardening:
    """Tests for README credential retrieval documentation."""

    def test_readme_has_credential_retrieval_section(self, workflow_readme_text: str):
        """README should contain a Credential Retrieval section."""
        assert "Credential Retrieval" in workflow_readme_text, (
            "README missing 'Credential Retrieval' section"
        )
