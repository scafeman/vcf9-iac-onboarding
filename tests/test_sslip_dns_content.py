"""Content-presence unit tests for sslip.io DNS and Let's Encrypt TLS integration."""

import os

import pytest


BASE = os.path.join(os.path.dirname(__file__), "..")

SSLIP_HELPERS_PATH = os.path.join(BASE, "examples", "shared", "sslip-helpers.sh")


def _read(relpath: str) -> str:
    """Read a file relative to the repo root."""
    with open(os.path.join(BASE, relpath), encoding="utf-8") as f:
        return f.read()


# ===================================================================
# 1. TestSslipHelpersExists — shared helper script
# ===================================================================


class TestSslipHelpersExists:
    """Verify examples/shared/sslip-helpers.sh exists and contains required functions."""

    def test_sslip_helpers_file_exists(self):
        assert os.path.isfile(SSLIP_HELPERS_PATH), (
            "sslip-helpers.sh not found at examples/shared/sslip-helpers.sh"
        )

    REQUIRED_FUNCTIONS = [
        "construct_sslip_hostname",
        "check_cert_manager_available",
        "check_cluster_issuer_ready",
        "create_cluster_issuer",
        "create_ingress_with_tls",
        "wait_for_certificate",
    ]

    @pytest.mark.parametrize("func_name", REQUIRED_FUNCTIONS)
    def test_contains_required_function(self, func_name):
        text = _read("examples/shared/sslip-helpers.sh")
        assert func_name in text, (
            f"sslip-helpers.sh missing required function '{func_name}'"
        )


# ===================================================================
# 2. TestDeployClusterSslipIntegration — deploy-cluster.sh specifics
# ===================================================================


class TestDeployClusterSslipIntegration:
    """Verify deploy-cluster.sh contains sslip.io / TLS integration points."""

    SCRIPT = "examples/deploy-cluster/deploy-cluster.sh"

    def test_cert_manager_installation_phase(self):
        text = _read(self.SCRIPT)
        assert "cert-manager.kubernetes.vmware.com" in text, (
            "deploy-cluster.sh missing cert-manager installation phase"
        )

    def test_contour_installation_phase(self):
        text = _read(self.SCRIPT)
        assert "contour.kubernetes.vmware.com" in text, (
            "deploy-cluster.sh missing Contour installation phase"
        )

    def test_cluster_issuer_creation(self):
        text = _read(self.SCRIPT)
        assert "create_cluster_issuer" in text, (
            "deploy-cluster.sh missing create_cluster_issuer call"
        )

    def test_use_sslip_dns_variable(self):
        text = _read(self.SCRIPT)
        assert "USE_SSLIP_DNS" in text, (
            "deploy-cluster.sh missing USE_SSLIP_DNS variable"
        )

    def test_sources_sslip_helpers(self):
        text = _read(self.SCRIPT)
        assert "sslip-helpers.sh" in text, (
            "deploy-cluster.sh does not source sslip-helpers.sh"
        )


# ===================================================================
# 3. TestDeployScriptsSourceSslipHelpers — all deploy scripts source helper
# ===================================================================


DEPLOY_SCRIPTS = [
    "examples/deploy-cluster/deploy-cluster.sh",
    "examples/deploy-hybrid-app/deploy-hybrid-app.sh",
    "examples/deploy-managed-db-app/deploy-managed-db-app.sh",
    "examples/deploy-secrets-demo/deploy-secrets-demo.sh",
    "examples/deploy-knative/deploy-knative.sh",
    "examples/deploy-metrics/deploy-metrics.sh",
    "examples/deploy-gitops/deploy-gitops.sh",
    "examples/deploy-ha-vm-app/deploy-ha-vm-app.sh",
]


class TestDeployScriptsSourceSslipHelpers:
    """Verify each deploy script sources sslip-helpers.sh."""

    @pytest.mark.parametrize("script", DEPLOY_SCRIPTS)
    def test_sources_sslip_helpers(self, script):
        text = _read(script)
        assert "sslip-helpers.sh" in text, (
            f"{script} does not source sslip-helpers.sh"
        )


# ===================================================================
# 4. TestDeployScriptsContainUseSslipDns — USE_SSLIP_DNS in deploy scripts
# ===================================================================


class TestDeployScriptsContainUseSslipDns:
    """Verify each deploy script contains the USE_SSLIP_DNS variable."""

    @pytest.mark.parametrize("script", DEPLOY_SCRIPTS)
    def test_contains_use_sslip_dns(self, script):
        text = _read(script)
        assert "USE_SSLIP_DNS" in text, (
            f"{script} missing USE_SSLIP_DNS variable"
        )


# ===================================================================
# 5. TestTeardownScriptsContainSslipCleanup — teardown cleanup
# ===================================================================


TEARDOWN_SCRIPTS_CLEANUP = [
    ("examples/deploy-cluster/teardown-cluster.sh", ["sslip-ingress", "ClusterIssuer"]),
    ("examples/deploy-hybrid-app/teardown-hybrid-app.sh", ["sslip-ingress"]),
    ("examples/deploy-managed-db-app/teardown-managed-db-app.sh", ["sslip-ingress"]),
    ("examples/deploy-secrets-demo/teardown-secrets-demo.sh", ["sslip-ingress"]),
    ("examples/deploy-knative/teardown-knative.sh", ["sslip-ingress"]),
    ("examples/deploy-metrics/teardown-metrics.sh", ["grafana-ingress-tls"]),
    ("examples/deploy-gitops/teardown-gitops.sh", ["certificate"]),
]


class TestTeardownScriptsContainSslipCleanup:
    """Verify teardown scripts contain sslip.io Ingress/Certificate cleanup."""

    @pytest.mark.parametrize("script,patterns", TEARDOWN_SCRIPTS_CLEANUP)
    def test_teardown_contains_cleanup_patterns(self, script, patterns):
        text = _read(script)
        for pattern in patterns:
            assert pattern in text, (
                f"{script} missing cleanup pattern '{pattern}'"
            )


# ===================================================================
# 6. TestWorkflowsContainSslipVariables — workflow files
# ===================================================================


WORKFLOW_SSLIP_FILES = [
    ".github/workflows/deploy-vks.yml",
    ".github/workflows/deploy-hybrid-app.yml",
    ".github/workflows/deploy-managed-db-app.yml",
    ".github/workflows/deploy-secrets-demo.yml",
    ".github/workflows/deploy-knative.yml",
    ".github/workflows/deploy-vks-metrics.yml",
    ".github/workflows/deploy-argocd.yml",
    ".github/workflows/deploy-ha-vm-app.yml",
    ".github/workflows/teardown.yml",
]


class TestWorkflowsContainSslipVariables:
    """Verify workflow files contain USE_SSLIP_DNS."""

    @pytest.mark.parametrize("workflow", WORKFLOW_SSLIP_FILES)
    def test_workflow_contains_use_sslip_dns(self, workflow):
        text = _read(workflow)
        assert "USE_SSLIP_DNS" in text, (
            f"{workflow} missing USE_SSLIP_DNS"
        )

    def test_deploy_vks_workflow_contains_letsencrypt_email(self):
        text = _read(".github/workflows/deploy-vks.yml")
        assert "LETSENCRYPT_EMAIL" in text, (
            ".github/workflows/deploy-vks.yml missing LETSENCRYPT_EMAIL"
        )
