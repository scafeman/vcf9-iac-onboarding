"""Content-presence unit tests for VCF 9 Scenario 2 — VKS Metrics Observability."""

import os
import re


# ===================================================================
# File paths
# ===================================================================

DEPLOY_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "scenario2", "scenario2-vks-metrics-deploy.sh"
)
TEARDOWN_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "scenario2", "scenario2-vks-metrics-teardown.sh"
)
TELEGRAF_VALUES_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "scenario2", "telegraf-values.yaml"
)
DEPLOY_README_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "scenario2", "README-deploy.md"
)
TEARDOWN_README_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "scenario2", "README-teardown.md"
)


# ===================================================================
# 1. Script file existence tests
# Validates: Requirements 1.1, 1.2
# ===================================================================


class TestScriptFileExists:
    """Script files exist at the expected locations."""

    def test_deploy_script_exists(self):
        assert os.path.isfile(DEPLOY_PATH), (
            "Deploy script not found at examples/scenario2/scenario2-vks-metrics-deploy.sh"
        )

    def test_teardown_script_exists(self):
        assert os.path.isfile(TEARDOWN_PATH), (
            "Teardown script not found at examples/scenario2/scenario2-vks-metrics-teardown.sh"
        )


# ===================================================================
# 2. Shebang and strict mode tests
# Validates: Requirements 1.3, 1.4
# ===================================================================


class TestShebangAndStrictMode:
    """Scripts start with bash shebang and enable strict mode."""

    def test_deploy_first_line_is_bash_shebang(self, scenario2_deploy_text):
        first_line = scenario2_deploy_text.splitlines()[0]
        assert first_line == "#!/bin/bash", (
            f"Expected '#!/bin/bash' as first line, got '{first_line}'"
        )

    def test_deploy_set_euo_pipefail(self, scenario2_deploy_text):
        assert "set -euo pipefail" in scenario2_deploy_text, (
            "Deploy script does not contain 'set -euo pipefail'"
        )

    def test_teardown_first_line_is_bash_shebang(self, scenario2_teardown_text):
        first_line = scenario2_teardown_text.splitlines()[0]
        assert first_line == "#!/bin/bash", (
            f"Expected '#!/bin/bash' as first line, got '{first_line}'"
        )

    def test_teardown_set_euo_pipefail(self, scenario2_teardown_text):
        assert "set -euo pipefail" in scenario2_teardown_text, (
            "Teardown script does not contain 'set -euo pipefail'"
        )


# ===================================================================
# 3. Variable block completeness tests
# Validates: Requirement 2.1
# ===================================================================


class TestVariableBlockCompleteness:
    """Variable block includes all required variables.
    Validates: Requirement 2.1"""

    REQUIRED_VARIABLES = [
        "CLUSTER_NAME",
        "KUBECONFIG_FILE",
        "PACKAGE_NAMESPACE",
        "PACKAGE_REPO_NAME",
        "PACKAGE_REPO_URL",
        "TELEGRAF_VERSION",
        "TELEGRAF_VALUES_FILE",
        "PROMETHEUS_VALUES_FILE",
        "STORAGE_CLASS",
        "NODE_CPU_THRESHOLD",
        "GRAFANA_NAMESPACE",
        "GRAFANA_INSTANCE_FILE",
        "GRAFANA_DATASOURCE_FILE",
        "GRAFANA_DASHBOARDS_FILE",
        "PACKAGE_TIMEOUT",
        "POLL_INTERVAL",
    ]

    def test_all_required_variables_defined(self, scenario2_deploy_text):
        for var in self.REQUIRED_VARIABLES:
            pattern = rf'^{var}='
            assert re.search(pattern, scenario2_deploy_text, re.MULTILINE), (
                f"Required variable '{var}' not defined in deploy script"
            )


# ===================================================================
# 4. Variable defaults tests
# Validates: Requirement 2.2
# ===================================================================


class TestVariableDefaults:
    """Variables with sensible defaults use the ${VAR:-default} pattern.
    Validates: Requirement 2.2"""

    VARIABLES_WITH_DEFAULTS = [
        "KUBECONFIG_FILE",
        "PACKAGE_NAMESPACE",
        "PACKAGE_REPO_NAME",
        "PACKAGE_REPO_URL",
        "TELEGRAF_VALUES_FILE",
        "STORAGE_CLASS",
        "NODE_CPU_THRESHOLD",
        "GRAFANA_NAMESPACE",
        "GRAFANA_INSTANCE_FILE",
        "GRAFANA_DATASOURCE_FILE",
        "GRAFANA_DASHBOARDS_FILE",
        "PACKAGE_TIMEOUT",
        "POLL_INTERVAL",
    ]

    def test_default_variables_use_default_pattern(self, scenario2_deploy_text):
        for var in self.VARIABLES_WITH_DEFAULTS:
            # Match: VAR="${VAR:-some_default}" where some_default is non-empty.
            # The default value may contain nested ${...} references (e.g. KUBECONFIG_FILE),
            # so we use .+ to match any non-empty default.
            pattern = rf'^{var}="\$\{{{var}:-.+\}}"'
            assert re.search(pattern, scenario2_deploy_text, re.MULTILINE), (
                f"Variable '{var}' does not use the ${{VAR:-default}} pattern with a non-empty default"
            )


# ===================================================================
# 5. validate_variables tests
# Validates: Requirement 2.4
# ===================================================================


class TestValidateVariables:
    """validate_variables function exists and is called before first provisioning command.
    Validates: Requirement 2.4"""

    def test_validate_variables_function_exists(self, scenario2_deploy_text):
        assert "validate_variables" in scenario2_deploy_text, (
            "validate_variables function/block not found in deploy script"
        )

    def test_validate_variables_called_before_provisioning(self, scenario2_deploy_text):
        call_match = re.search(r"^validate_variables\s*$", scenario2_deploy_text, re.MULTILINE)
        assert call_match, "validate_variables is never called as a standalone command"

        call_pos = call_match.start()

        # First provisioning command is kubectl or vcf
        prov_patterns = [
            r"kubectl\s+create",
            r"kubectl\s+apply",
            r"kubectl\s+get\s+namespaces",
            r"vcf\s+package",
        ]
        first_prov_pos = len(scenario2_deploy_text)
        for pat in prov_patterns:
            m = re.search(pat, scenario2_deploy_text)
            if m and m.start() < first_prov_pos:
                first_prov_pos = m.start()

        assert call_pos < first_prov_pos, (
            "validate_variables is called after the first provisioning command"
        )


# ===================================================================
# 6. Kubeconfig setup tests (Phase 1)
# Validates: Requirements 3.1, 3.2, 3.3, 3.4
# ===================================================================


class TestKubeconfigSetup:
    """Phase 1 contains kubeconfig setup and connectivity check.
    Validates: Requirements 3.1, 3.2"""

    def test_export_kubeconfig_present(self, scenario2_deploy_text):
        assert re.search(r"export\s+KUBECONFIG=", scenario2_deploy_text), (
            "Deploy script missing 'export KUBECONFIG' command"
        )

    def test_kubectl_get_namespaces_connectivity_check(self, scenario2_deploy_text):
        assert re.search(r"kubectl\s+get\s+namespaces", scenario2_deploy_text), (
            "Deploy script missing 'kubectl get namespaces' connectivity check"
        )

    def test_exit_code_2_for_kubeconfig_failures(self, scenario2_deploy_text):
        assert "exit 2" in scenario2_deploy_text, (
            "Deploy script missing 'exit 2' for kubeconfig failures"
        )


# ===================================================================
# 7. Node sizing advisory tests (Phase 2)
# Validates: Requirement 14.1, 14.2, 14.3
# ===================================================================


class TestNodeSizingAdvisory:
    """Phase 2 contains node sizing advisory.
    Validates: Requirements 14.1, 14.2, 14.3"""

    def test_kubectl_get_nodes_present(self, scenario2_deploy_text):
        assert re.search(r"kubectl\s+get\s+nodes", scenario2_deploy_text), (
            "Deploy script missing 'kubectl get nodes' for resource query"
        )

    def test_best_effort_large_recommendation(self, scenario2_deploy_text):
        assert "best-effort-large" in scenario2_deploy_text, (
            "Deploy script missing 'best-effort-large' recommendation"
        )

    def test_node_cpu_threshold_referenced(self, scenario2_deploy_text):
        assert "NODE_CPU_THRESHOLD" in scenario2_deploy_text, (
            "Deploy script missing NODE_CPU_THRESHOLD reference"
        )


# ===================================================================
# 8. Namespace creation tests (Phase 3)
# Validates: Requirements 4.1, 4.2
# ===================================================================


class TestNamespaceCreation:
    """Phase 3 contains namespace creation with idempotency.
    Validates: Requirements 4.1, 4.2"""

    def test_kubectl_create_ns_present(self, scenario2_deploy_text):
        assert re.search(r"kubectl\s+create\s+ns", scenario2_deploy_text), (
            "Deploy script missing 'kubectl create ns'"
        )

    def test_idempotency_check_before_create(self, scenario2_deploy_text):
        get_match = re.search(r"kubectl\s+get\s+ns", scenario2_deploy_text)
        create_match = re.search(r"kubectl\s+create\s+ns", scenario2_deploy_text)
        assert get_match, "Deploy script missing idempotency check (kubectl get ns)"
        assert create_match, "Deploy script missing kubectl create ns command"
        assert get_match.start() < create_match.start(), (
            "Idempotency check (kubectl get ns) should appear before kubectl create ns"
        )


# ===================================================================
# 9. Repository registration tests (Phase 4)
# Validates: Requirements 5.1, 5.2
# ===================================================================


class TestRepositoryRegistration:
    """Phase 4 contains package repository registration.
    Validates: Requirements 5.1, 5.2"""

    def test_vcf_package_repository_add_present(self, scenario2_deploy_text):
        assert re.search(r"vcf\s+package\s+repository\s+add", scenario2_deploy_text), (
            "Deploy script missing 'vcf package repository add'"
        )

    def test_wait_for_condition_repo_reconciliation(self, scenario2_deploy_text):
        assert "wait_for_condition" in scenario2_deploy_text, (
            "Deploy script missing wait_for_condition call for repo reconciliation"
        )


# ===================================================================
# 10. Package install command tests
# Validates: Requirements 6.1, 7.1, 8.1, 9.1
# ===================================================================


class TestPackageInstallCommands:
    """Package install commands use correct package names and flags.
    Validates: Requirements 6.1, 7.1, 8.1, 9.1"""

    def test_telegraf_install_with_package_name(self, scenario2_deploy_text):
        assert re.search(
            r"vcf\s+package\s+install\s+telegraf", scenario2_deploy_text
        ), "Deploy script missing 'vcf package install telegraf'"
        assert "telegraf.kubernetes.vmware.com" in scenario2_deploy_text, (
            "Deploy script missing --package-name telegraf.kubernetes.vmware.com"
        )

    def test_certmanager_install_with_package_name(self, scenario2_deploy_text):
        assert re.search(
            r"vcf\s+package\s+install\s+cert-manager", scenario2_deploy_text
        ), "Deploy script missing 'vcf package install cert-manager'"
        assert "cert-manager.kubernetes.vmware.com" in scenario2_deploy_text, (
            "Deploy script missing --package-name cert-manager.kubernetes.vmware.com"
        )

    def test_contour_install_with_package_name(self, scenario2_deploy_text):
        assert re.search(
            r"vcf\s+package\s+install\s+contour", scenario2_deploy_text
        ), "Deploy script missing 'vcf package install contour'"
        assert "contour.kubernetes.vmware.com" in scenario2_deploy_text, (
            "Deploy script missing --package-name contour.kubernetes.vmware.com"
        )

    def test_prometheus_install_with_package_name(self, scenario2_deploy_text):
        assert re.search(
            r"vcf\s+package\s+install\s+prometheus", scenario2_deploy_text
        ), "Deploy script missing 'vcf package install prometheus'"
        assert "prometheus.kubernetes.vmware.com" in scenario2_deploy_text, (
            "Deploy script missing --package-name prometheus.kubernetes.vmware.com"
        )

    def test_telegraf_install_has_values_file(self, scenario2_deploy_text):
        assert "--values-file" in scenario2_deploy_text, (
            "Deploy script missing --values-file flag on Telegraf install"
        )

    def test_prometheus_install_has_storage_class(self, scenario2_deploy_text):
        assert "PROMETHEUS_VALUES_FILE" in scenario2_deploy_text, (
            "Deploy script missing PROMETHEUS_VALUES_FILE reference for Prometheus install"
        )


# ===================================================================
# 11. Dependency ordering tests
# Validates: Requirements 7.2, 8.2, 9.2
# ===================================================================


class TestDependencyOrdering:
    """Package installs appear in correct dependency order.
    Validates: Requirements 7.2, 8.2, 9.2"""

    def test_telegraf_after_repo_registration(self, scenario2_deploy_text):
        repo_match = re.search(r"vcf\s+package\s+repository\s+add", scenario2_deploy_text)
        telegraf_match = re.search(r"vcf\s+package\s+install\s+telegraf", scenario2_deploy_text)
        assert repo_match and telegraf_match, (
            "Missing repo registration or Telegraf install"
        )
        assert repo_match.start() < telegraf_match.start(), (
            "Telegraf install should appear after repo registration"
        )

    def test_certmanager_after_repo_registration(self, scenario2_deploy_text):
        repo_match = re.search(r"vcf\s+package\s+repository\s+add", scenario2_deploy_text)
        cm_match = re.search(r"vcf\s+package\s+install\s+cert-manager", scenario2_deploy_text)
        assert repo_match and cm_match, (
            "Missing repo registration or cert-manager install"
        )
        assert repo_match.start() < cm_match.start(), (
            "cert-manager install should appear after repo registration"
        )

    def test_contour_after_certmanager(self, scenario2_deploy_text):
        cm_match = re.search(r"vcf\s+package\s+install\s+cert-manager", scenario2_deploy_text)
        contour_match = re.search(r"vcf\s+package\s+install\s+contour", scenario2_deploy_text)
        assert cm_match and contour_match, (
            "Missing cert-manager or Contour install"
        )
        assert cm_match.start() < contour_match.start(), (
            "Contour install should appear after cert-manager"
        )

    def test_prometheus_after_contour(self, scenario2_deploy_text):
        contour_match = re.search(r"vcf\s+package\s+install\s+contour", scenario2_deploy_text)
        prom_match = re.search(r"vcf\s+package\s+install\s+prometheus", scenario2_deploy_text)
        assert contour_match and prom_match, (
            "Missing Contour or Prometheus install"
        )
        assert contour_match.start() < prom_match.start(), (
            "Prometheus install should appear after Contour"
        )


# ===================================================================
# 12. Verification phase tests
# Validates: Requirements 10.1, 10.2, 10.3
# ===================================================================


class TestVerificationPhase:
    """Verification phase checks installed packages and pod status.
    Validates: Requirements 10.1, 10.2, 10.3"""

    def test_vcf_package_installed_list_present(self, scenario2_deploy_text):
        assert re.search(
            r"vcf\s+package\s+installed\s+list", scenario2_deploy_text
        ), "Deploy script missing 'vcf package installed list'"

    def test_telegraf_pod_check_present(self, scenario2_deploy_text):
        # Check for kubectl get pods with telegraf reference
        assert re.search(
            r"kubectl\s+get\s+pods.*telegraf", scenario2_deploy_text
        ), "Deploy script missing Telegraf pod check"

    def test_prometheus_pod_check_present(self, scenario2_deploy_text):
        assert re.search(
            r"kubectl\s+get\s+pods.*prometheus", scenario2_deploy_text
        ), "Deploy script missing Prometheus pod check"


# ===================================================================
# 13. Exit code tests
# Validates: Requirement 12.4
# ===================================================================


class TestExitCodes:
    """Deploy script contains all required exit codes.
    Validates: Requirement 12.4"""

    def test_exit_codes_1_through_10_present(self, scenario2_deploy_text):
        for code in range(1, 11):
            assert f"exit {code}" in scenario2_deploy_text, (
                f"Deploy script missing 'exit {code}'"
            )

    def test_exit_0_present(self, scenario2_deploy_text):
        assert "exit 0" in scenario2_deploy_text, (
            "Deploy script missing 'exit 0' (success)"
        )


# ===================================================================
# 14. Summary banner tests
# Validates: Requirement 12.6
# ===================================================================


class TestSummaryBanner:
    """Deploy script contains summary banner.
    Validates: Requirement 12.6"""

    def test_scenario_2_in_deploy(self, scenario2_deploy_text):
        assert "Scenario 2" in scenario2_deploy_text, (
            "Deploy script missing 'Scenario 2' in summary banner"
        )

    def test_deployment_complete_in_deploy(self, scenario2_deploy_text):
        assert "Deployment Complete" in scenario2_deploy_text, (
            "Deploy script missing 'Deployment Complete' in summary banner"
        )


# ===================================================================
# 15. Teardown ordering tests
# Validates: Requirement 11.1
# ===================================================================


class TestTeardownOrdering:
    """Teardown script deletes packages in reverse dependency order.
    Validates: Requirement 11.1"""

    def test_prometheus_before_contour(self, scenario2_teardown_text):
        prom_match = re.search(r"delete_package\s+prometheus", scenario2_teardown_text)
        contour_match = re.search(r"delete_package\s+contour", scenario2_teardown_text)
        assert prom_match and contour_match, "Missing Prometheus or Contour delete"
        assert prom_match.start() < contour_match.start(), (
            "Prometheus delete should appear before Contour delete"
        )

    def test_contour_before_certmanager(self, scenario2_teardown_text):
        contour_match = re.search(r"delete_package\s+contour", scenario2_teardown_text)
        cm_match = re.search(r"delete_package\s+cert-manager", scenario2_teardown_text)
        assert contour_match and cm_match, "Missing Contour or cert-manager delete"
        assert contour_match.start() < cm_match.start(), (
            "Contour delete should appear before cert-manager delete"
        )

    def test_certmanager_before_telegraf(self, scenario2_teardown_text):
        cm_match = re.search(r"delete_package\s+cert-manager", scenario2_teardown_text)
        telegraf_match = re.search(r"delete_package\s+telegraf", scenario2_teardown_text)
        assert cm_match and telegraf_match, "Missing cert-manager or Telegraf delete"
        assert cm_match.start() < telegraf_match.start(), (
            "cert-manager delete should appear before Telegraf delete"
        )

    def test_telegraf_before_repo_delete(self, scenario2_teardown_text):
        telegraf_match = re.search(r"delete_package\s+telegraf", scenario2_teardown_text)
        repo_match = re.search(r"kubectl\s+delete\s+packagerepository", scenario2_teardown_text)
        assert telegraf_match and repo_match, "Missing Telegraf delete or repo delete"
        assert telegraf_match.start() < repo_match.start(), (
            "Telegraf delete should appear before repo delete"
        )

    def test_repo_before_namespace_delete(self, scenario2_teardown_text):
        repo_match = re.search(r"kubectl\s+delete\s+packagerepository", scenario2_teardown_text)
        ns_match = re.search(r'kubectl\s+delete\s+ns\s+"\$\{PACKAGE_NAMESPACE\}"', scenario2_teardown_text)
        assert repo_match and ns_match, "Missing repo delete or namespace delete"
        assert repo_match.start() < ns_match.start(), (
            "Repo delete should appear before namespace delete"
        )

    def test_grafana_before_prometheus(self, scenario2_teardown_text):
        grafana_match = re.search(r"helm\s+uninstall\s+grafana-operator", scenario2_teardown_text)
        prom_match = re.search(r"delete_package\s+prometheus", scenario2_teardown_text)
        assert grafana_match and prom_match, "Missing Grafana uninstall or Prometheus delete"
        assert grafana_match.start() < prom_match.start(), (
            "Grafana uninstall should appear before Prometheus delete"
        )


# ===================================================================
# 16. Teardown --yes flags tests
# Validates: Requirement 11.5
# ===================================================================


class TestTeardownNonInteractive:
    """Teardown script deletes all resources non-interactively.
    Validates: Requirement 11.5"""

    def test_delete_package_helper_strips_finalizers(self, scenario2_teardown_text):
        # The delete_package helper strips finalizers before deleting
        assert re.search(
            r'kubectl\s+patch\s+packageinstall.*finalizers', scenario2_teardown_text, re.DOTALL
        ), "delete_package helper missing finalizer stripping for PackageInstall"
        assert re.search(
            r'kubectl\s+patch\s+app.*finalizers', scenario2_teardown_text, re.DOTALL
        ), "delete_package helper missing finalizer stripping for App"

    def test_all_four_packages_use_delete_package(self, scenario2_teardown_text):
        # Verify all 4 packages are deleted via the delete_package helper
        for pkg in ["prometheus", "contour", "cert-manager", "telegraf"]:
            assert re.search(rf"delete_package\s+{re.escape(pkg)}", scenario2_teardown_text), (
                f"Package '{pkg}' not deleted via delete_package helper"
            )

    def test_delete_package_helper_uses_ignore_not_found(self, scenario2_teardown_text):
        # The delete_package helper uses --ignore-not-found on kubectl delete
        assert re.search(
            r'kubectl\s+delete\s+packageinstall.*--ignore-not-found', scenario2_teardown_text
        ), "delete_package helper missing --ignore-not-found on kubectl delete"

    def test_repo_delete_strips_finalizers(self, scenario2_teardown_text):
        assert re.search(
            r'kubectl\s+patch\s+packagerepository.*finalizers', scenario2_teardown_text, re.DOTALL
        ), "Repository delete missing finalizer stripping"


# ===================================================================
# 17. README file existence tests
# Validates: Requirements 13.1, 13.2
# ===================================================================


class TestREADMEFileExists:
    """README files exist at the expected locations.
    Validates: Requirements 13.1, 13.2"""

    def test_deploy_readme_exists(self):
        assert os.path.isfile(DEPLOY_README_PATH), (
            "Deploy README not found at examples/scenario2/README-deploy.md"
        )

    def test_teardown_readme_exists(self):
        assert os.path.isfile(TEARDOWN_README_PATH), (
            "Teardown README not found at examples/scenario2/README-teardown.md"
        )


# ===================================================================
# 18. README content tests
# Validates: Requirements 13.3, 13.4, 13.5
# ===================================================================


class TestREADMEContent:
    """README files contain required content.
    Validates: Requirements 13.3, 13.4, 13.5"""

    def test_deploy_readme_contains_scenario1_prerequisite(self):
        with open(DEPLOY_README_PATH, encoding="utf-8") as f:
            text = f.read()
        assert "Scenario 1" in text, (
            "Deploy README missing Scenario 1 prerequisite reference"
        )

    def test_deploy_readme_contains_dependency_order(self):
        with open(DEPLOY_README_PATH, encoding="utf-8") as f:
            text = f.read()
        # Check for dependency order info — should mention the chain
        has_dependency = (
            "dependency" in text.lower()
            or "order" in text.lower()
        )
        assert has_dependency, (
            "Deploy README missing dependency order information"
        )

    def test_deploy_readme_contains_node_sizing_advisory(self):
        with open(DEPLOY_README_PATH, encoding="utf-8") as f:
            text = f.read()
        assert "node sizing" in text.lower() or "best-effort-large" in text, (
            "Deploy README missing node sizing advisory"
        )

    def test_teardown_readme_contains_idempotency_info(self):
        with open(TEARDOWN_README_PATH, encoding="utf-8") as f:
            text = f.read()
        assert "idempoten" in text.lower(), (
            "Teardown README missing idempotency information"
        )


# ===================================================================
# 19. Telegraf values file tests
# Validates: Requirements 6.4, 6.5, 15.1
# ===================================================================


class TestTelegrafValuesFile:
    """Telegraf values file exists and contains required configuration.
    Validates: Requirements 6.4, 6.5, 15.1"""

    def test_telegraf_values_file_exists(self):
        assert os.path.isfile(TELEGRAF_VALUES_PATH), (
            "Telegraf values file not found at examples/scenario2/telegraf-values.yaml"
        )

    def test_contains_namespace_key(self, telegraf_values_parsed):
        assert "namespace" in telegraf_values_parsed, (
            "Telegraf values missing 'namespace' key"
        )

    def test_contains_agent_key(self, telegraf_values_parsed):
        assert "agent" in telegraf_values_parsed, (
            "Telegraf values missing 'agent' key"
        )

    def test_contains_interval_setting(self, telegraf_values_text):
        assert "interval" in telegraf_values_text, (
            "Telegraf values missing 'interval' setting"
        )

    def test_contains_output_plugins(self, telegraf_values_parsed):
        assert "outputPlugins" in telegraf_values_parsed, (
            "Telegraf values missing 'outputPlugins' key"
        )

    def test_contains_create_namespace_key(self, telegraf_values_parsed):
        assert "createNamespace" in telegraf_values_parsed, (
            "Telegraf values missing 'createNamespace' key"
        )


# ===================================================================
# 20. Node sizing advisory log_warn tests
# Validates: Requirement 14.2, 14.3
# ===================================================================


class TestNodeSizingAdvisoryLogWarn:
    """Deploy script contains log_warn with sizing recommendation.
    Validates: Requirements 14.2, 14.3"""

    def test_log_warn_with_sizing_recommendation(self, scenario2_deploy_text):
        # Find log_warn calls that mention sizing / best-effort-large
        warn_calls = re.findall(r"log_warn\s+\".*?\"", scenario2_deploy_text)
        has_sizing_warn = any(
            "best-effort-large" in call for call in warn_calls
        )
        assert has_sizing_warn, (
            "Deploy script missing log_warn with 'best-effort-large' sizing recommendation"
        )


# ===================================================================
# 21. Grafana manifest file existence tests
# Validates: Grafana integration
# ===================================================================

GRAFANA_INSTANCE_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "scenario2", "grafana-instance.yaml"
)
GRAFANA_DATASOURCE_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "scenario2", "grafana-datasource-prometheus.yaml"
)
GRAFANA_DASHBOARDS_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "scenario2", "grafana-dashboards-k8s.yaml"
)


class TestGrafanaManifestFiles:
    """Grafana manifest files exist at expected locations."""

    def test_grafana_instance_file_exists(self):
        assert os.path.isfile(GRAFANA_INSTANCE_PATH), (
            "Grafana instance manifest not found at examples/scenario2/grafana-instance.yaml"
        )

    def test_grafana_datasource_file_exists(self):
        assert os.path.isfile(GRAFANA_DATASOURCE_PATH), (
            "Grafana datasource manifest not found at examples/scenario2/grafana-datasource-prometheus.yaml"
        )

    def test_grafana_dashboards_file_exists(self):
        assert os.path.isfile(GRAFANA_DASHBOARDS_PATH), (
            "Grafana dashboards manifest not found at examples/scenario2/grafana-dashboards-k8s.yaml"
        )


# ===================================================================
# 22. Grafana deploy content tests
# Validates: Grafana phases in deploy script
# ===================================================================


class TestGrafanaDeployContent:
    """Deploy script contains Grafana installation phases."""

    def test_helm_install_grafana_operator(self, scenario2_deploy_text):
        assert re.search(r"helm\s+.*grafana-operator", scenario2_deploy_text), (
            "Deploy script missing Helm install for Grafana Operator"
        )

    def test_kubectl_apply_grafana_instance(self, scenario2_deploy_text):
        assert re.search(r"kubectl\s+apply\s+-f.*GRAFANA_INSTANCE", scenario2_deploy_text), (
            "Deploy script missing kubectl apply for Grafana instance"
        )

    def test_kubectl_apply_grafana_datasource(self, scenario2_deploy_text):
        assert re.search(r"kubectl\s+apply\s+-f.*GRAFANA_DATASOURCE_FILE", scenario2_deploy_text), (
            "Deploy script missing kubectl apply for Grafana datasource"
        )

    def test_kubectl_apply_grafana_dashboards(self, scenario2_deploy_text):
        assert re.search(r"kubectl\s+apply\s+-f.*GRAFANA_DASHBOARDS_FILE", scenario2_deploy_text), (
            "Deploy script missing kubectl apply for Grafana dashboards"
        )

    def test_grafana_pod_check_in_verification(self, scenario2_deploy_text):
        assert re.search(r"kubectl\s+get\s+pods.*GRAFANA_NAMESPACE", scenario2_deploy_text), (
            "Deploy script missing Grafana pod check in verification phase"
        )

    def test_grafana_after_prometheus(self, scenario2_deploy_text):
        prom_match = re.search(r"vcf\s+package\s+install\s+prometheus", scenario2_deploy_text)
        grafana_match = re.search(r"helm\s+.*grafana-operator", scenario2_deploy_text)
        assert prom_match and grafana_match, "Missing Prometheus install or Grafana install"
        assert prom_match.start() < grafana_match.start(), (
            "Grafana install should appear after Prometheus install"
        )
