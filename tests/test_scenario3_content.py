"""Content-presence unit tests for VCF 9 Scenario 3 — ArgoCD Consumption Model."""

import os
import re

import pytest
import yaml


# ===================================================================
# File paths
# ===================================================================

DEPLOY_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "scenario3", "scenario3-argocd-deploy.sh"
)
TEARDOWN_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "scenario3", "scenario3-argocd-teardown.sh"
)
DEPLOY_README_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "scenario3", "README-deploy.md"
)
TEARDOWN_README_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "scenario3", "README-teardown.md"
)
GITLAB_OPERATOR_VALUES_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "scenario3", "gitlab-operator-values.yaml"
)
GITLAB_RUNNER_VALUES_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "scenario3", "gitlab-runner-values.yaml"
)
ARGOCD_APP_MANIFEST_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "scenario3", "argocd-microservices-demo.yaml"
)
HARBOR_VALUES_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "scenario3", "harbor-values.yaml"
)
ARGOCD_VALUES_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "scenario3", "argocd-values.yaml"
)
WILDCARD_CNF_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "scenario3", "wildcard.cnf"
)


# ===================================================================
# 1. Script file existence tests
# Validates: Requirements 1.1, 1.2
# ===================================================================


class TestScriptFileExists:
    """Script files exist at the expected locations."""

    def test_deploy_script_exists(self):
        assert os.path.isfile(DEPLOY_PATH), (
            "Deploy script not found at examples/scenario3/scenario3-argocd-deploy.sh"
        )

    def test_teardown_script_exists(self):
        assert os.path.isfile(TEARDOWN_PATH), (
            "Teardown script not found at examples/scenario3/scenario3-argocd-teardown.sh"
        )


# ===================================================================
# 2. Shebang and strict mode tests
# Validates: Requirements 1.3, 1.4
# ===================================================================


class TestShebangAndStrictMode:
    """Scripts start with bash shebang and enable strict mode."""

    def test_deploy_first_line_is_bash_shebang(self, scenario3_deploy_text):
        first_line = scenario3_deploy_text.splitlines()[0]
        assert first_line == "#!/bin/bash", (
            f"Expected '#!/bin/bash' as first line, got '{first_line}'"
        )

    def test_deploy_set_euo_pipefail(self, scenario3_deploy_text):
        assert "set -euo pipefail" in scenario3_deploy_text, (
            "Deploy script does not contain 'set -euo pipefail'"
        )

    def test_teardown_first_line_is_bash_shebang(self, scenario3_teardown_text):
        first_line = scenario3_teardown_text.splitlines()[0]
        assert first_line == "#!/bin/bash", (
            f"Expected '#!/bin/bash' as first line, got '{first_line}'"
        )

    def test_teardown_set_euo_pipefail(self, scenario3_teardown_text):
        assert "set -euo pipefail" in scenario3_teardown_text, (
            "Teardown script does not contain 'set -euo pipefail'"
        )


# ===================================================================
# 3. Variable block completeness tests
# Validates: Requirement 2.1, 14.1, 14.2, 14.9
# ===================================================================


class TestVariableBlockCompleteness:
    """Variable block includes all required variables.
    Validates: Requirement 2.1, 14.1, 14.2, 14.9"""

    REQUIRED_VARIABLES = [
        "CLUSTER_NAME",
        "GITLAB_RUNNER_TOKEN",
        "HELM_CHARTS_REPO_URL",
    ]

    def test_all_required_variables_defined(self, scenario3_deploy_text):
        for var in self.REQUIRED_VARIABLES:
            pattern = rf'^{var}='
            assert re.search(pattern, scenario3_deploy_text, re.MULTILINE), (
                f"Required variable '{var}' not defined in deploy script"
            )

    def test_old_required_variables_removed(self, scenario3_deploy_text):
        """Old variables that are no longer needed should not appear as assignments."""
        old_vars = [
            "HARBOR_CA_CERT",
            "GITLAB_WILDCARD_CERT",
            "GITLAB_WILDCARD_KEY",
            "HARBOR_IP",
            "GITLAB_IP",
        ]
        for var in old_vars:
            pattern = rf'^{var}='
            assert not re.search(pattern, scenario3_deploy_text, re.MULTILINE), (
                f"Old variable '{var}' should be removed from deploy script"
            )


# ===================================================================
# 4. Variable defaults tests (including new variables)
# Validates: Requirement 2.2, 14.2
# ===================================================================


class TestVariableDefaults:
    """Variables with sensible defaults use the ${VAR:-default} pattern.
    Validates: Requirement 2.2, 14.2"""

    VARIABLES_WITH_DEFAULTS = [
        "KUBECONFIG_FILE",
        "DOMAIN",
        "HARBOR_VERSION",
        "ARGOCD_VERSION",
        "HARBOR_ADMIN_PASSWORD",
        "HARBOR_SECRET_KEY",
        "HARBOR_DB_PASSWORD",
        "CERT_DIR",
        "CONTOUR_INGRESS_NAMESPACE",
        "HARBOR_NAMESPACE",
        "HARBOR_VALUES_FILE",
        "ARGOCD_VALUES_FILE",
        "GITLAB_OPERATOR_VERSION",
        "GITLAB_RUNNER_VERSION",
        "GITLAB_NAMESPACE",
        "GITLAB_RUNNER_NAMESPACE",
        "ARGOCD_NAMESPACE",
        "APP_NAMESPACE",
        "GITLAB_OPERATOR_VALUES_FILE",
        "GITLAB_RUNNER_VALUES_FILE",
        "ARGOCD_APP_MANIFEST",
        "PACKAGE_TIMEOUT",
        "POLL_INTERVAL",
        "PACKAGE_NAMESPACE",
        "PACKAGE_REPO_NAME",
        "PACKAGE_REPO_URL",
    ]

    def test_default_variables_use_default_pattern(self, scenario3_deploy_text):
        for var in self.VARIABLES_WITH_DEFAULTS:
            pattern = rf'^{var}="\$\{{{var}:-.+\}}"'
            assert re.search(pattern, scenario3_deploy_text, re.MULTILINE), (
                f"Variable '{var}' does not use the ${{VAR:-default}} pattern with a non-empty default"
            )


# ===================================================================
# 5. validate_variables and check_prerequisites tests
# Validates: Requirements 2.3, 3.3, 3.4
# ===================================================================


class TestValidateVariablesAndPrerequisites:
    """validate_variables and check_prerequisites exist and are called.
    Validates: Requirements 2.3, 3.3, 3.4"""

    def test_validate_variables_function_exists(self, scenario3_deploy_text):
        assert re.search(r"^validate_variables\s*\(\)", scenario3_deploy_text, re.MULTILINE), (
            "validate_variables function not found in deploy script"
        )

    def test_check_prerequisites_function_exists(self, scenario3_deploy_text):
        assert re.search(r"^check_prerequisites\s*\(\)", scenario3_deploy_text, re.MULTILINE), (
            "check_prerequisites function not found in deploy script"
        )

    def test_validate_variables_called_before_provisioning(self, scenario3_deploy_text):
        call_match = re.search(r"^validate_variables\s*$", scenario3_deploy_text, re.MULTILINE)
        assert call_match, "validate_variables is never called as a standalone command"
        call_pos = call_match.start()
        prov_match = re.search(r"kubectl\s+get\s+namespaces", scenario3_deploy_text)
        assert prov_match, "No kubectl get namespaces found"
        assert call_pos < prov_match.start(), (
            "validate_variables is called after the first provisioning command"
        )

    def test_check_prerequisites_called_before_provisioning(self, scenario3_deploy_text):
        call_match = re.search(r"^check_prerequisites\s*$", scenario3_deploy_text, re.MULTILINE)
        assert call_match, "check_prerequisites is never called as a standalone command"
        call_pos = call_match.start()
        prov_match = re.search(r"kubectl\s+get\s+namespaces", scenario3_deploy_text)
        assert prov_match, "No kubectl get namespaces found"
        assert call_pos < prov_match.start(), (
            "check_prerequisites is called after the first provisioning command"
        )

    def test_check_prerequisites_verifies_kubectl(self, scenario3_deploy_text):
        assert "kubectl" in scenario3_deploy_text, "check_prerequisites missing kubectl check"

    def test_check_prerequisites_verifies_helm(self, scenario3_deploy_text):
        assert "helm" in scenario3_deploy_text, "check_prerequisites missing helm check"

    def test_check_prerequisites_verifies_openssl(self, scenario3_deploy_text):
        assert "openssl" in scenario3_deploy_text, "check_prerequisites missing openssl check"


# ===================================================================
# 6. Kubeconfig setup tests (Phase 1)
# Validates: Requirements 10.1
# ===================================================================


class TestKubeconfigSetup:
    """Phase 1 contains kubeconfig setup and connectivity check.
    Validates: Requirements 10.1"""

    def test_export_kubeconfig_present(self, scenario3_deploy_text):
        assert re.search(r"export\s+KUBECONFIG=", scenario3_deploy_text), (
            "Deploy script missing 'export KUBECONFIG' command"
        )

    def test_kubectl_get_namespaces_connectivity_check(self, scenario3_deploy_text):
        assert re.search(r"kubectl\s+get\s+namespaces", scenario3_deploy_text), (
            "Deploy script missing 'kubectl get namespaces' connectivity check"
        )

    def test_exit_code_2_for_kubeconfig_failures(self, scenario3_deploy_text):
        assert "exit 2" in scenario3_deploy_text, (
            "Deploy script missing 'exit 2' for kubeconfig failures"
        )

    def test_kubeconfig_file_existence_check(self, scenario3_deploy_text):
        assert re.search(r'-f.*KUBECONFIG_FILE', scenario3_deploy_text), (
            "Deploy script missing kubeconfig file existence check"
        )


# ===================================================================
# 7. DOMAIN variable and derived hostname tests
# Validates: Requirements 1.1, 1.2, 1.3, 1.4, 14.1
# ===================================================================


class TestDomainAndDerivedHostnames:
    """DOMAIN variable and derived hostname assignments.
    Validates: Requirements 1.1, 1.2, 1.3, 1.4, 14.1"""

    def test_domain_variable_defined(self, scenario3_deploy_text):
        pattern = r'^DOMAIN="\$\{DOMAIN:-'
        assert re.search(pattern, scenario3_deploy_text, re.MULTILINE), (
            "Deploy script missing DOMAIN variable with default"
        )

    def test_harbor_hostname_derived_from_domain(self, scenario3_deploy_text):
        assert 'HARBOR_HOSTNAME="harbor.${DOMAIN}"' in scenario3_deploy_text, (
            "Deploy script missing HARBOR_HOSTNAME derived from DOMAIN"
        )

    def test_gitlab_hostname_derived_from_domain(self, scenario3_deploy_text):
        assert 'GITLAB_HOSTNAME="gitlab.${DOMAIN}"' in scenario3_deploy_text, (
            "Deploy script missing GITLAB_HOSTNAME derived from DOMAIN"
        )

    def test_argocd_hostname_derived_from_domain(self, scenario3_deploy_text):
        assert 'ARGOCD_HOSTNAME="argocd.${DOMAIN}"' in scenario3_deploy_text, (
            "Deploy script missing ARGOCD_HOSTNAME derived from DOMAIN"
        )


# ===================================================================
# 8. Self-signed certificate generation tests (Phase 2)
# Validates: Requirements 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 14.3
# ===================================================================


class TestCertificateGeneration:
    """Phase 2 generates self-signed certificates via openssl.
    Validates: Requirements 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 14.3"""

    def test_openssl_req_command(self, scenario3_deploy_text):
        assert re.search(r"openssl\s+req", scenario3_deploy_text), (
            "Deploy script missing 'openssl req' command for certificate generation"
        )

    def test_openssl_x509_command(self, scenario3_deploy_text):
        assert re.search(r"openssl\s+x509", scenario3_deploy_text), (
            "Deploy script missing 'openssl x509' command for certificate signing"
        )

    def test_cert_dir_referenced(self, scenario3_deploy_text):
        assert "CERT_DIR" in scenario3_deploy_text, (
            "Deploy script missing CERT_DIR reference"
        )

    def test_fullchain_cert_created(self, scenario3_deploy_text):
        assert "fullchain.crt" in scenario3_deploy_text, (
            "Deploy script missing fullchain.crt creation"
        )

    def test_wildcard_cnf_referenced(self, scenario3_deploy_text):
        assert "wildcard.cnf" in scenario3_deploy_text, (
            "Deploy script missing wildcard.cnf reference"
        )

    def test_exit_code_3_for_cert_failures(self, scenario3_deploy_text):
        assert "exit 3" in scenario3_deploy_text, (
            "Deploy script missing 'exit 3' for certificate generation failures"
        )

    def test_ca_cert_existence_check(self, scenario3_deploy_text):
        assert re.search(r'ca\.crt', scenario3_deploy_text), (
            "Deploy script missing CA cert existence check"
        )


# ===================================================================
# 9. Contour installation tests (Phase 3)
# Validates: Requirements 5.1, 5.2, 5.3, 5.4, 5.5, 14.4
# ===================================================================


class TestContourInstallation:
    """Phase 3 installs Contour via VKS package (shared with Scenario 2).
    Validates: Requirements 5.1, 5.2, 5.3, 5.4, 5.5, 14.4"""

    def test_vcf_package_install_contour(self, scenario3_deploy_text):
        assert re.search(r"vcf\s+package\s+install\s+contour", scenario3_deploy_text), (
            "Deploy script missing 'vcf package install contour'"
        )

    def test_vcf_package_install_cert_manager(self, scenario3_deploy_text):
        assert re.search(r"vcf\s+package\s+install\s+cert-manager", scenario3_deploy_text), (
            "Deploy script missing 'vcf package install cert-manager'"
        )

    def test_envoy_lb_service_creation(self, scenario3_deploy_text):
        assert re.search(r"envoy-lb", scenario3_deploy_text), (
            "Deploy script missing envoy-lb LoadBalancer service"
        )

    def test_contour_lb_ip_auto_detection(self, scenario3_deploy_text):
        assert re.search(r"kubectl\s+get\s+svc.*envoy-lb", scenario3_deploy_text), (
            "Deploy script missing envoy-lb LB IP auto-detection"
        )

    def test_contour_lb_ip_variable(self, scenario3_deploy_text):
        assert "CONTOUR_LB_IP" in scenario3_deploy_text, (
            "Deploy script missing CONTOUR_LB_IP variable"
        )

    def test_exit_code_4_for_contour_failures(self, scenario3_deploy_text):
        assert "exit 4" in scenario3_deploy_text, (
            "Deploy script missing 'exit 4' for Contour installation failures"
        )

    def test_package_namespace_setup(self, scenario3_deploy_text):
        assert "PACKAGE_NAMESPACE" in scenario3_deploy_text, (
            "Deploy script missing PACKAGE_NAMESPACE for VKS package repository"
        )

    def test_package_repo_setup(self, scenario3_deploy_text):
        assert re.search(r"vcf\s+package\s+repository\s+add", scenario3_deploy_text), (
            "Deploy script missing 'vcf package repository add' for VKS package repository"
        )


# ===================================================================
# 10. Harbor installation tests (Phase 4)
# Validates: Requirements 6.1, 6.2, 6.3, 6.4, 6.5, 14.4
# ===================================================================


class TestHarborInstallation:
    """Phase 4 installs Harbor via Helm.
    Validates: Requirements 6.1, 6.2, 6.3, 6.4, 6.5, 14.4"""

    def test_helm_upgrade_install_harbor(self, scenario3_deploy_text):
        assert re.search(r"helm\s+upgrade\s+--install\s+harbor\s+harbor/harbor", scenario3_deploy_text), (
            "Deploy script missing 'helm upgrade --install harbor harbor/harbor'"
        )

    def test_harbor_version_flag(self, scenario3_deploy_text):
        assert re.search(r"--version.*HARBOR_VERSION", scenario3_deploy_text), (
            "Deploy script missing --version flag for Harbor"
        )

    def test_harbor_values_file_flag(self, scenario3_deploy_text):
        assert re.search(r"--values.*harbor-values\.yaml", scenario3_deploy_text), (
            "Deploy script missing --values flag for Harbor"
        )

    def test_harbor_tls_secret_creation(self, scenario3_deploy_text):
        assert re.search(r"kubectl\s+create\s+secret\s+tls\s+harbor-tls", scenario3_deploy_text), (
            "Deploy script missing Harbor TLS secret creation"
        )

    def test_exit_code_5_for_harbor_failures(self, scenario3_deploy_text):
        assert "exit 5" in scenario3_deploy_text, (
            "Deploy script missing 'exit 5' for Harbor installation failures"
        )


# ===================================================================
# 11. CoreDNS configuration tests (Phase 5)
# Validates: Requirements 9.1, 9.2, 9.3
# ===================================================================


class TestCoreDNSConfiguration:
    """Phase 5 configures CoreDNS with static host entries.
    Validates: Requirements 9.1, 9.2, 9.3"""

    def test_coredns_configmap_patch(self, scenario3_deploy_text):
        assert re.search(r"kubectl\s+patch\s+configmap\s+coredns", scenario3_deploy_text), (
            "Deploy script missing CoreDNS ConfigMap patch"
        )

    def test_coredns_rollout_restart(self, scenario3_deploy_text):
        assert re.search(r"kubectl\s+rollout\s+restart\s+deployment/coredns", scenario3_deploy_text), (
            "Deploy script missing CoreDNS rollout restart"
        )

    def test_exit_code_6_for_coredns_failures(self, scenario3_deploy_text):
        assert "exit 6" in scenario3_deploy_text, (
            "Deploy script missing 'exit 6' for CoreDNS failures"
        )

    def test_coredns_wait_loop(self, scenario3_deploy_text):
        assert re.search(r"wait_for_condition.*CoreDNS", scenario3_deploy_text, re.IGNORECASE), (
            "Deploy script missing wait_for_condition call for CoreDNS"
        )


# ===================================================================
# 12. ArgoCD installation tests (Phase 6)
# Validates: Requirements 7.1, 7.2, 7.3, 7.4, 7.5, 14.4, 14.6
# ===================================================================


class TestArgoCDInstallation:
    """Phase 6 installs ArgoCD via Helm.
    Validates: Requirements 7.1, 7.2, 7.3, 7.4, 7.5, 14.4, 14.6"""

    def test_helm_upgrade_install_argocd(self, scenario3_deploy_text):
        assert re.search(r"helm\s+upgrade\s+--install\s+argocd\s+argo/argo-cd", scenario3_deploy_text), (
            "Deploy script missing 'helm upgrade --install argocd argo/argo-cd'"
        )

    def test_argocd_version_flag(self, scenario3_deploy_text):
        assert re.search(r"--version.*ARGOCD_VERSION", scenario3_deploy_text), (
            "Deploy script missing --version flag for ArgoCD"
        )

    def test_argocd_values_file_flag(self, scenario3_deploy_text):
        assert re.search(r"--values.*argocd-values\.yaml", scenario3_deploy_text), (
            "Deploy script missing --values flag for ArgoCD"
        )

    def test_argocd_password_from_k8s_secret(self, scenario3_deploy_text):
        assert "argocd-initial-admin-secret" in scenario3_deploy_text, (
            "Deploy script missing ArgoCD initial admin secret retrieval"
        )

    def test_argocd_password_base64_decode(self, scenario3_deploy_text):
        assert re.search(r"base64\s+-d", scenario3_deploy_text), (
            "Deploy script missing base64 decode for ArgoCD password"
        )

    def test_exit_code_7_for_argocd_failures(self, scenario3_deploy_text):
        assert "exit 7" in scenario3_deploy_text, (
            "Deploy script missing 'exit 7' for ArgoCD installation failures"
        )


# ===================================================================
# 13. ArgoCD CLI installation tests (Phase 7)
# Validates: Requirements 8.1, 8.2, 8.3, 8.4, 14.7
# ===================================================================


class TestArgoCDCLIInstallation:
    """Phase 7 auto-downloads ArgoCD CLI.
    Validates: Requirements 8.1, 8.2, 8.3, 8.4, 14.7"""

    def test_argocd_cli_download(self, scenario3_deploy_text):
        assert re.search(r"curl.*argocd-linux-amd64", scenario3_deploy_text), (
            "Deploy script missing ArgoCD CLI download via curl"
        )

    def test_argocd_cli_install_path(self, scenario3_deploy_text):
        assert "/tmp/argocd" in scenario3_deploy_text, (
            "Deploy script missing /tmp/argocd install path"
        )

    def test_exit_code_8_for_cli_failures(self, scenario3_deploy_text):
        assert "exit 8" in scenario3_deploy_text, (
            "Deploy script missing 'exit 8' for ArgoCD CLI download failures"
        )

    def test_argocd_cli_path_check(self, scenario3_deploy_text):
        assert re.search(r"command\s+-v\s+argocd", scenario3_deploy_text), (
            "Deploy script missing 'command -v argocd' check"
        )


# ===================================================================
# 14. Certificate distribution tests (Phase 8)
# Validates: Requirements 10.1
# ===================================================================


class TestCertificateDistribution:
    """Phase 8 distributes certificates to application namespaces.
    Validates: Requirements 10.1"""

    def test_harbor_ca_secret_creation(self, scenario3_deploy_text):
        assert re.search(r"kubectl\s+create\s+secret\s+generic\s+harbor-ca-cert", scenario3_deploy_text), (
            "Deploy script missing Harbor CA secret creation"
        )

    def test_gitlab_wildcard_tls_secret_creation(self, scenario3_deploy_text):
        assert re.search(r"kubectl\s+create\s+secret\s+tls\s+gitlab-wildcard-tls", scenario3_deploy_text), (
            "Deploy script missing GitLab wildcard TLS secret creation"
        )

    def test_exit_code_9_for_cert_distribution_failures(self, scenario3_deploy_text):
        assert "exit 9" in scenario3_deploy_text, (
            "Deploy script missing 'exit 9' for certificate distribution failures"
        )

    def test_idempotent_secret_creation(self, scenario3_deploy_text):
        assert "--dry-run=client" in scenario3_deploy_text, (
            "Deploy script missing --dry-run=client for idempotent secret creation"
        )

    def test_podsecurity_labels(self, scenario3_deploy_text):
        assert "pod-security.kubernetes.io/enforce=privileged" in scenario3_deploy_text, (
            "Deploy script missing PodSecurity labels"
        )


# ===================================================================
# 15. GitLab installation tests (Phase 9)
# Validates: Requirements 10.1
# ===================================================================


class TestGitLabOperatorInstallation:
    """Phase 9 installs GitLab via Helm.
    Validates: Requirements 10.1"""

    def test_helm_upgrade_install_gitlab_operator(self, scenario3_deploy_text):
        assert re.search(r"helm\s+upgrade\s+--install\s+gitlab\s+gitlab/gitlab", scenario3_deploy_text), (
            "Deploy script missing 'helm upgrade --install gitlab gitlab/gitlab'"
        )

    def test_gitlab_operator_version_flag(self, scenario3_deploy_text):
        assert re.search(r"--version.*GITLAB_OPERATOR_VERSION", scenario3_deploy_text), (
            "Deploy script missing --version flag for GitLab"
        )

    def test_gitlab_operator_values_file_flag(self, scenario3_deploy_text):
        assert re.search(r"--values.*gitlab-operator-values\.yaml", scenario3_deploy_text), (
            "Deploy script missing --values flag for GitLab"
        )

    def test_wait_for_gitlab_webservice_pod(self, scenario3_deploy_text):
        assert re.search(r"wait_for_condition.*webservice", scenario3_deploy_text, re.IGNORECASE), (
            "Deploy script missing wait_for_condition for GitLab webservice pod"
        )

    def test_exit_code_10_for_gitlab_operator_failures(self, scenario3_deploy_text):
        assert "exit 10" in scenario3_deploy_text, (
            "Deploy script missing 'exit 10' for GitLab failures"
        )


# ===================================================================
# 16. Harbor proxy patching tests (Phase 10)
# Validates: Requirements 10.1
# ===================================================================


class TestHarborProxyPatching:
    """Phase 10 verifies Harbor proxy configuration.
    Validates: Requirements 10.1"""

    def test_harbor_proxy_check(self, scenario3_deploy_text):
        assert re.search(r'grep.*proxy/', scenario3_deploy_text), (
            "Deploy script missing Harbor proxy configuration check"
        )

    def test_exit_code_11_for_harbor_proxy_failures(self, scenario3_deploy_text):
        assert "exit 11" in scenario3_deploy_text, (
            "Deploy script missing 'exit 11' for Harbor proxy failures"
        )

    def test_dockerhub_rate_limit_warning(self, scenario3_deploy_text):
        assert re.search(r"DockerHub.*rate.limit", scenario3_deploy_text, re.IGNORECASE), (
            "Deploy script missing DockerHub rate limit warning"
        )


# ===================================================================
# 17. GitLab Runner installation tests (Phase 11)
# Validates: Requirements 10.1
# ===================================================================


class TestGitLabRunnerInstallation:
    """Phase 11 installs GitLab Runner via Helm.
    Validates: Requirements 10.1"""

    def test_helm_upgrade_install_gitlab_runner(self, scenario3_deploy_text):
        assert re.search(r"helm\s+upgrade\s+--install\s+gitlab-runner", scenario3_deploy_text), (
            "Deploy script missing 'helm upgrade --install gitlab-runner'"
        )

    def test_gitlab_runner_version_flag(self, scenario3_deploy_text):
        assert re.search(r"--version.*GITLAB_RUNNER_VERSION", scenario3_deploy_text), (
            "Deploy script missing --version flag for GitLab Runner"
        )

    def test_gitlab_runner_values_file_flag(self, scenario3_deploy_text):
        assert re.search(r"--values.*gitlab-runner-values\.yaml", scenario3_deploy_text), (
            "Deploy script missing --values flag for GitLab Runner"
        )

    def test_wait_for_gitlab_runner_pod(self, scenario3_deploy_text):
        assert re.search(r"wait_for_condition.*GitLab Runner", scenario3_deploy_text), (
            "Deploy script missing wait_for_condition for GitLab Runner pod"
        )

    def test_exit_code_12_for_gitlab_runner_failures(self, scenario3_deploy_text):
        assert "exit 12" in scenario3_deploy_text, (
            "Deploy script missing 'exit 12' for GitLab Runner failures"
        )


# ===================================================================
# 18. ArgoCD cluster registration tests (Phase 12)
# Validates: Requirements 10.1
# ===================================================================


class TestArgoCDClusterRegistration:
    """Phase 12 registers the VKS cluster with ArgoCD.
    Validates: Requirements 10.1"""

    def test_argocd_login(self, scenario3_deploy_text):
        assert re.search(r"argocd\s+login", scenario3_deploy_text), (
            "Deploy script missing 'argocd login'"
        )

    def test_argocd_cluster_add(self, scenario3_deploy_text):
        assert re.search(r"argocd\s+cluster\s+add", scenario3_deploy_text), (
            "Deploy script missing 'argocd cluster add'"
        )

    def test_argocd_cluster_already_registered_check(self, scenario3_deploy_text):
        assert re.search(r"argocd\s+cluster\s+list", scenario3_deploy_text), (
            "Deploy script missing ArgoCD cluster list check for existing registration"
        )

    def test_exit_code_13_for_argocd_registration_failures(self, scenario3_deploy_text):
        assert "exit 13" in scenario3_deploy_text, (
            "Deploy script missing 'exit 13' for ArgoCD registration failures"
        )


# ===================================================================
# 19. ArgoCD application bootstrap tests (Phase 13)
# Validates: Requirements 10.1
# ===================================================================


class TestArgoCDApplicationBootstrap:
    """Phase 13 bootstraps the ArgoCD application.
    Validates: Requirements 10.1"""

    def test_kubectl_apply_argocd_manifest(self, scenario3_deploy_text):
        assert re.search(r"kubectl\s+apply\s+-f.*argocd-microservices-demo\.yaml", scenario3_deploy_text), (
            "Deploy script missing 'kubectl apply -f' for ArgoCD Application manifest"
        )

    def test_argocd_app_already_exists_check(self, scenario3_deploy_text):
        assert re.search(r"argocd\s+app\s+get\s+microservices-demo", scenario3_deploy_text), (
            "Deploy script missing ArgoCD app existence check"
        )

    def test_wait_for_argocd_app_sync(self, scenario3_deploy_text):
        assert re.search(r"wait_for_condition.*microservices-demo.*Synced", scenario3_deploy_text, re.IGNORECASE), (
            "Deploy script missing wait_for_condition for ArgoCD app sync"
        )

    def test_exit_code_14_for_argocd_app_failures(self, scenario3_deploy_text):
        assert "exit 14" in scenario3_deploy_text, (
            "Deploy script missing 'exit 14' for ArgoCD application failures"
        )


# ===================================================================
# 20. Microservices demo verification tests (Phase 14)
# Validates: Requirements 10.1
# ===================================================================


class TestMicroservicesDemoVerification:
    """Phase 14 verifies all 11 microservices are running.
    Validates: Requirements 10.1"""

    EXPECTED_SERVICES = [
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

    def test_all_11_services_checked(self, scenario3_deploy_text):
        for service in self.EXPECTED_SERVICES:
            assert service in scenario3_deploy_text, (
                f"Deploy script missing check for microservice '{service}'"
            )

    def test_frontend_endpoint_display(self, scenario3_deploy_text):
        assert "port-forward" in scenario3_deploy_text or "ClusterIP" in scenario3_deploy_text, (
            "Deploy script missing frontend endpoint display"
        )


# ===================================================================
# 21. Summary banner tests
# Validates: Requirement 10.1
# ===================================================================


class TestSummaryBanner:
    """Deploy script contains summary banner.
    Validates: Requirement 10.1"""

    def test_scenario_3_in_deploy(self, scenario3_deploy_text):
        assert "Scenario 3" in scenario3_deploy_text, (
            "Deploy script missing 'Scenario 3' in summary banner"
        )

    def test_deployment_complete_in_deploy(self, scenario3_deploy_text):
        assert "Deployment Complete" in scenario3_deploy_text, (
            "Deploy script missing 'Deployment Complete' in summary banner"
        )


# ===================================================================
# 22. Exit code completeness tests (1-14)
# Validates: Requirements 10.2, 14.10
# ===================================================================


class TestExitCodes:
    """Deploy script contains all required exit codes.
    Validates: Requirements 10.2, 14.10"""

    def test_exit_codes_1_through_14_present(self, scenario3_deploy_text):
        for code in range(1, 15):
            assert f"exit {code}" in scenario3_deploy_text, (
                f"Deploy script missing 'exit {code}'"
            )

    def test_exit_0_present(self, scenario3_deploy_text):
        assert "exit 0" in scenario3_deploy_text, (
            "Deploy script missing 'exit 0' (success)"
        )


# ===================================================================
# 23. Phase ordering tests (15 phases in correct order)
# Validates: Requirement 10.1, 14.10
# ===================================================================


class TestPhaseOrdering:
    """Deploy script phases appear in correct order.
    Validates: Requirement 10.1, 14.10"""

    def test_all_fifteen_phases_present(self, scenario3_deploy_phases):
        for phase_num in range(1, 16):
            assert phase_num in scenario3_deploy_phases, (
                f"Phase {phase_num} not found in the script. "
                f"Found phases: {sorted(scenario3_deploy_phases.keys())}"
            )

    def test_phase_1_before_phase_2(self, scenario3_deploy_text):
        p1 = scenario3_deploy_text.find("Phase 1:")
        p2 = scenario3_deploy_text.find("Phase 2:")
        assert p1 < p2, "Phase 1 should appear before Phase 2"

    def test_phase_3_before_phase_4(self, scenario3_deploy_text):
        """Contour (Phase 3) must be installed before Harbor (Phase 4)."""
        p3 = scenario3_deploy_text.find("Phase 3:")
        p4 = scenario3_deploy_text.find("Phase 4:")
        assert p3 < p4, "Phase 3 (Contour) should appear before Phase 4 (Harbor)"

    def test_phase_6_before_phase_7(self, scenario3_deploy_text):
        """ArgoCD (Phase 6) must be installed before CLI (Phase 7)."""
        p6 = scenario3_deploy_text.find("Phase 6:")
        p7 = scenario3_deploy_text.find("Phase 7:")
        assert p6 < p7, "Phase 6 (ArgoCD) should appear before Phase 7 (ArgoCD CLI)"

    def test_phase_9_before_phase_11(self, scenario3_deploy_text):
        """GitLab (Phase 9) must be installed before Runner (Phase 11)."""
        p9 = scenario3_deploy_text.find("Phase 9:")
        p11 = scenario3_deploy_text.find("Phase 11:")
        assert p9 < p11, "Phase 9 (GitLab) should appear before Phase 11 (GitLab Runner)"

    def test_phase_12_before_phase_13(self, scenario3_deploy_text):
        """ArgoCD registration (Phase 12) must happen before app bootstrap (Phase 13)."""
        p12 = scenario3_deploy_text.find("Phase 12:")
        p13 = scenario3_deploy_text.find("Phase 13:")
        assert p12 < p13, "Phase 12 (ArgoCD Registration) should appear before Phase 13 (App Bootstrap)"


# ===================================================================
# 24. Helper function presence tests
# Validates: Requirements 10.1
# ===================================================================


class TestHelperFunctionPresence:
    """Deploy and teardown scripts contain required helper functions.
    Validates: Requirements 10.1"""

    DEPLOY_HELPERS = [
        "log_step",
        "log_success",
        "log_error",
        "log_warn",
        "validate_variables",
        "check_prerequisites",
        "wait_for_condition",
    ]

    TEARDOWN_HELPERS = [
        "log_step",
        "log_success",
        "log_error",
        "log_warn",
        "validate_variables",
    ]

    def test_deploy_has_all_helper_functions(self, scenario3_deploy_text):
        for func in self.DEPLOY_HELPERS:
            assert re.search(rf"^{func}\s*\(\)", scenario3_deploy_text, re.MULTILINE), (
                f"Deploy script missing helper function '{func}'"
            )

    def test_teardown_has_all_helper_functions(self, scenario3_teardown_text):
        for func in self.TEARDOWN_HELPERS:
            assert re.search(rf"^{func}\s*\(\)", scenario3_teardown_text, re.MULTILINE), (
                f"Teardown script missing helper function '{func}'"
            )


# ===================================================================
# 25. Teardown ordering tests (11 phases, updated order)
# Validates: Requirement 12.5, 14.11
# ===================================================================


class TestTeardownOrdering:
    """Teardown script deletes components in reverse dependency order.
    Order: ArgoCD App → Runner → Operator → ArgoCD → CoreDNS → Harbor → Contour → Cert Secrets
    Validates: Requirement 12.5, 14.11"""

    def test_argocd_app_before_runner(self, scenario3_teardown_text):
        app_match = re.search(r"kubectl\s+delete\s+application\s+microservices-demo", scenario3_teardown_text)
        runner_match = re.search(r"helm\s+uninstall\s+gitlab-runner", scenario3_teardown_text)
        assert app_match and runner_match, "Missing ArgoCD app delete or GitLab Runner uninstall"
        assert app_match.start() < runner_match.start(), (
            "ArgoCD Application delete should appear before GitLab Runner uninstall"
        )

    def test_runner_before_operator(self, scenario3_teardown_text):
        runner_match = re.search(r"helm\s+uninstall\s+gitlab-runner", scenario3_teardown_text)
        gitlab_match = re.search(r"helm\s+uninstall\s+gitlab\s", scenario3_teardown_text)
        assert runner_match and gitlab_match, "Missing GitLab Runner or GitLab uninstall"
        assert runner_match.start() < gitlab_match.start(), (
            "GitLab Runner uninstall should appear before GitLab uninstall"
        )

    def test_operator_before_argocd(self, scenario3_teardown_text):
        gitlab_match = re.search(r"helm\s+uninstall\s+gitlab\s", scenario3_teardown_text)
        argocd_match = re.search(r"helm\s+uninstall\s+argocd", scenario3_teardown_text)
        assert gitlab_match and argocd_match, "Missing GitLab or ArgoCD uninstall"
        assert gitlab_match.start() < argocd_match.start(), (
            "GitLab uninstall should appear before ArgoCD uninstall"
        )

    def test_argocd_before_coredns_restore(self, scenario3_teardown_text):
        argocd_match = re.search(r"helm\s+uninstall\s+argocd", scenario3_teardown_text)
        coredns_match = re.search(r"^#{3,}\n# Phase 6: Restore CoreDNS", scenario3_teardown_text, re.MULTILINE)
        assert argocd_match and coredns_match, "Missing ArgoCD uninstall or CoreDNS restore phase"
        assert argocd_match.start() < coredns_match.start(), (
            "ArgoCD uninstall should appear before CoreDNS restore"
        )

    def test_coredns_before_harbor(self, scenario3_teardown_text):
        coredns_match = re.search(r"Restore CoreDNS", scenario3_teardown_text, re.IGNORECASE)
        harbor_match = re.search(r"helm\s+uninstall\s+harbor", scenario3_teardown_text)
        assert coredns_match and harbor_match, "Missing CoreDNS restore or Harbor uninstall"
        assert coredns_match.start() < harbor_match.start(), (
            "CoreDNS restore should appear before Harbor uninstall"
        )

    def test_harbor_before_cert_secrets(self, scenario3_teardown_text):
        harbor_match = re.search(r"helm\s+uninstall\s+harbor", scenario3_teardown_text)
        # Match the actual phase section divider, not the top-of-file comment listing
        cert_match = re.search(r"^#{3,}\n# Phase 8: Delete Certificate Secrets", scenario3_teardown_text, re.MULTILINE)
        assert harbor_match and cert_match, "Missing Harbor uninstall or certificate secrets delete phase"
        assert harbor_match.start() < cert_match.start(), (
            "Harbor uninstall should appear before certificate secrets deletion"
        )


# ===================================================================
# 26. Teardown idempotency tests
# Validates: Requirements 12.8, 12.9
# ===================================================================


class TestTeardownIdempotency:
    """Teardown script handles already-deleted resources gracefully.
    Validates: Requirements 12.8, 12.9"""

    def test_ignore_not_found_present(self, scenario3_teardown_text):
        assert "--ignore-not-found" in scenario3_teardown_text, (
            "Teardown script missing '--ignore-not-found' for idempotent deletion"
        )

    def test_or_true_present(self, scenario3_teardown_text):
        assert "|| true" in scenario3_teardown_text, (
            "Teardown script missing '|| true' for error suppression"
        )

    def test_finalizer_stripping_present(self, scenario3_teardown_text):
        assert re.search(r'kubectl\s+patch.*finalizers.*null', scenario3_teardown_text, re.DOTALL), (
            "Teardown script missing finalizer stripping"
        )

    def test_helm_uninstall_with_error_suppression(self, scenario3_teardown_text):
        helm_lines = [
            line.strip() for line in scenario3_teardown_text.splitlines()
            if re.search(r"^\s*helm\s+uninstall\s+", line)
        ]
        assert len(helm_lines) >= 4, "Expected at least 4 helm uninstall commands"
        for line in helm_lines:
            assert "|| true" in line or "2>/dev/null" in line, (
                f"Helm uninstall missing error suppression: {line}"
            )


# ===================================================================
# 27. Teardown Contour, Harbor, ArgoCD uninstall tests
# Validates: Requirements 12.1, 12.2, 12.3, 14.11
# ===================================================================


class TestTeardownNewPhases:
    """Teardown script includes Harbor, ArgoCD uninstall commands.
    Contour is a shared VKS package (scenario2 teardown handles it).
    Validates: Requirements 12.1, 12.2, 12.3, 14.11"""

    def test_teardown_harbor_uninstall(self, scenario3_teardown_text):
        assert re.search(r"helm\s+uninstall\s+harbor", scenario3_teardown_text), (
            "Teardown script missing 'helm uninstall harbor'"
        )

    def test_teardown_argocd_uninstall(self, scenario3_teardown_text):
        assert re.search(r"helm\s+uninstall\s+argocd", scenario3_teardown_text), (
            "Teardown script missing 'helm uninstall argocd'"
        )

    def test_teardown_contour_ingress_namespace_reference(self, scenario3_teardown_text):
        assert "CONTOUR_INGRESS_NAMESPACE" in scenario3_teardown_text, (
            "Teardown script missing CONTOUR_INGRESS_NAMESPACE reference"
        )

    def test_teardown_harbor_namespace_deletion(self, scenario3_teardown_text):
        assert "HARBOR_NAMESPACE" in scenario3_teardown_text, (
            "Teardown script missing HARBOR_NAMESPACE reference"
        )

    def test_teardown_cert_cleanup(self, scenario3_teardown_text):
        assert "CERT_DIR" in scenario3_teardown_text, (
            "Teardown script missing CERT_DIR reference for certificate cleanup"
        )

    def test_teardown_does_not_uninstall_contour(self, scenario3_teardown_text):
        """Contour is a shared VKS package — scenario3 teardown should NOT uninstall it."""
        assert not re.search(r"helm\s+uninstall\s+contour", scenario3_teardown_text), (
            "Teardown script should NOT uninstall Contour (shared VKS package)"
        )


# ===================================================================
# 28. README file existence and content tests
# Validates: Requirements 13.1, 13.2, 13.3, 13.4, 13.5, 13.6, 13.7, 13.8
# ===================================================================


class TestREADMEFiles:
    """README files exist and contain required content.
    Validates: Requirements 13.1, 13.2, 13.3, 13.4, 13.5, 13.6, 13.7, 13.8"""

    def test_deploy_readme_exists(self):
        assert os.path.isfile(DEPLOY_README_PATH), (
            "Deploy README not found at examples/scenario3/README-deploy.md"
        )

    def test_teardown_readme_exists(self):
        assert os.path.isfile(TEARDOWN_README_PATH), (
            "Teardown README not found at examples/scenario3/README-teardown.md"
        )

    def test_deploy_readme_contains_scenario1_prerequisite(self):
        with open(DEPLOY_README_PATH, encoding="utf-8") as f:
            text = f.read()
        assert "Scenario 1" in text, (
            "Deploy README missing Scenario 1 prerequisite reference"
        )

    def test_deploy_readme_contains_infrastructure_services(self):
        with open(DEPLOY_README_PATH, encoding="utf-8") as f:
            text = f.read()
        assert "ArgoCD" in text and "Harbor" in text and "Contour" in text, (
            "Deploy README missing infrastructure services documentation"
        )

    def test_deploy_readme_contains_certificate_info(self):
        with open(DEPLOY_README_PATH, encoding="utf-8") as f:
            text = f.read()
        assert "certificate" in text.lower() or "cert" in text.lower(), (
            "Deploy README missing certificate requirements documentation"
        )

    def test_deploy_readme_contains_dependency_order(self):
        with open(DEPLOY_README_PATH, encoding="utf-8") as f:
            text = f.read()
        has_dependency = "dependency" in text.lower() or "order" in text.lower() or "phase" in text.lower()
        assert has_dependency, (
            "Deploy README missing dependency order information"
        )

    def test_teardown_readme_contains_idempotency_info(self):
        with open(TEARDOWN_README_PATH, encoding="utf-8") as f:
            text = f.read()
        assert "idempoten" in text.lower(), (
            "Teardown README missing idempotency information"
        )


# ===================================================================
# 29. Supporting YAML file existence and content tests
# Validates: Requirements 11.1, 11.2, 11.3, 11.4, 14.12
# ===================================================================


class TestSupportingYAMLFiles:
    """Supporting YAML files exist and contain required content.
    Validates: Requirements 11.1, 11.2, 11.3, 11.4, 14.12"""

    def test_gitlab_operator_values_exists(self):
        assert os.path.isfile(GITLAB_OPERATOR_VALUES_PATH), (
            "GitLab Operator values not found at examples/scenario3/gitlab-operator-values.yaml"
        )

    def test_gitlab_runner_values_exists(self):
        assert os.path.isfile(GITLAB_RUNNER_VALUES_PATH), (
            "GitLab Runner values not found at examples/scenario3/gitlab-runner-values.yaml"
        )

    def test_argocd_app_manifest_exists(self):
        assert os.path.isfile(ARGOCD_APP_MANIFEST_PATH), (
            "ArgoCD Application manifest not found at examples/scenario3/argocd-microservices-demo.yaml"
        )

    def test_harbor_values_exists(self):
        assert os.path.isfile(HARBOR_VALUES_PATH), (
            "Harbor values not found at examples/scenario3/harbor-values.yaml"
        )

    def test_argocd_values_exists(self):
        assert os.path.isfile(ARGOCD_VALUES_PATH), (
            "ArgoCD values not found at examples/scenario3/argocd-values.yaml"
        )

    def test_wildcard_cnf_exists(self):
        assert os.path.isfile(WILDCARD_CNF_PATH), (
            "Wildcard CNF not found at examples/scenario3/wildcard.cnf"
        )

    def test_harbor_values_is_valid_yaml(self):
        with open(HARBOR_VALUES_PATH, encoding="utf-8") as f:
            text = f.read()
        try:
            result = yaml.safe_load(text)
        except yaml.YAMLError as exc:
            pytest.fail(f"Harbor values file is not valid YAML: {exc}")
        assert result is not None, "Harbor values file parsed to None"
        assert isinstance(result, dict), f"Expected a dict, got {type(result).__name__}"

    def test_argocd_values_is_valid_yaml(self):
        with open(ARGOCD_VALUES_PATH, encoding="utf-8") as f:
            text = f.read()
        try:
            result = yaml.safe_load(text)
        except yaml.YAMLError as exc:
            pytest.fail(f"ArgoCD values file is not valid YAML: {exc}")
        assert result is not None, "ArgoCD values file parsed to None"
        assert isinstance(result, dict), f"Expected a dict, got {type(result).__name__}"

    def test_gitlab_operator_values_has_harbor_ca(self, gitlab_operator_values_parsed):
        certs = gitlab_operator_values_parsed.get("global", {}).get("certificates", {})
        custom_cas = certs.get("customCAs", [])
        secrets = [ca.get("secret") for ca in custom_cas if isinstance(ca, dict)]
        assert "harbor-ca-cert" in secrets, (
            "GitLab Operator values missing Harbor CA certificate reference"
        )

    def test_gitlab_operator_values_has_tls_secret(self, gitlab_operator_values_parsed):
        tls = gitlab_operator_values_parsed.get("global", {}).get("ingress", {}).get("tls", {})
        assert tls.get("secretName") == "gitlab-wildcard-tls", (
            "GitLab Operator values missing gitlab-wildcard-tls secret reference"
        )

    def test_gitlab_runner_values_has_gitlab_url(self, gitlab_runner_values_parsed):
        assert "gitlabUrl" in gitlab_runner_values_parsed, (
            "GitLab Runner values missing 'gitlabUrl' key"
        )

    def test_gitlab_runner_values_has_certs_secret(self, gitlab_runner_values_parsed):
        assert "certsSecretName" in gitlab_runner_values_parsed, (
            "GitLab Runner values missing 'certsSecretName' key"
        )

    def test_argocd_manifest_has_application_kind(self, argocd_app_manifest_parsed):
        assert argocd_app_manifest_parsed.get("kind") == "Application", (
            "ArgoCD manifest missing 'kind: Application'"
        )

    def test_argocd_manifest_has_sync_policy(self, argocd_app_manifest_parsed):
        sync = argocd_app_manifest_parsed.get("spec", {}).get("syncPolicy", {})
        automated = sync.get("automated", {})
        assert automated.get("selfHeal") is True, (
            "ArgoCD manifest missing selfHeal: true in sync policy"
        )
        assert automated.get("prune") is True, (
            "ArgoCD manifest missing prune: true in sync policy"
        )

    def test_argocd_manifest_has_source_and_destination(self, argocd_app_manifest_parsed):
        spec = argocd_app_manifest_parsed.get("spec", {})
        assert "source" in spec, "ArgoCD manifest missing 'source' in spec"
        assert "destination" in spec, "ArgoCD manifest missing 'destination' in spec"

    def test_all_yaml_files_have_inline_comments(self):
        for path, name in [
            (GITLAB_OPERATOR_VALUES_PATH, "GitLab Operator values"),
            (GITLAB_RUNNER_VALUES_PATH, "GitLab Runner values"),
            (ARGOCD_APP_MANIFEST_PATH, "ArgoCD Application manifest"),
            (HARBOR_VALUES_PATH, "Harbor values"),
            (ARGOCD_VALUES_PATH, "ArgoCD values"),
        ]:
            with open(path, encoding="utf-8") as f:
                text = f.read()
            comment_lines = [l for l in text.splitlines() if l.strip().startswith("#")]
            assert len(comment_lines) >= 3, (
                f"{name} file has fewer than 3 comment lines"
            )
