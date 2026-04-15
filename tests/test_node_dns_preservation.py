"""Preservation property tests for sslip.io node-level DNS resolution bugfix.

These tests verify existing correct behaviors BEFORE implementing the fix.
They MUST PASS on unfixed code — they confirm baseline behavior to preserve.

Observation-first methodology: each test asserts a behavior observed on the
current (unfixed) codebase that must remain unchanged after the fix.

**Validates: Requirements 3.1, 3.2, 3.3, 3.4, 3.5**
"""

import re
import pytest


# ============================================================================
# Test 2a: Phase 4 manifest has no DNS variables
# ============================================================================

class TestPhase4ManifestNoDnsVariables:
    """The Phase 4 cluster manifest 'variables' section contains only vmClass,
    storageClass, and volumes — no DNS/nameserver/resolv configuration.

    The builtin-generic-v3.4.0 topology class does not support DNS variables,
    so the manifest must remain unchanged.

    **Validates: Requirements 3.5**
    """

    def test_variables_section_has_vmclass(self, script_text: str):
        """The variables section must contain vmClass."""
        assert "- name: vmClass" in script_text

    def test_variables_section_has_storageclass(self, script_text: str):
        """The variables section must contain storageClass."""
        assert "- name: storageClass" in script_text

    def test_variables_section_has_volumes(self, script_text: str):
        """The variables section must contain volumes."""
        assert "- name: volumes" in script_text

    def test_no_dns_variable(self, script_text: str):
        """The variables section must NOT contain any DNS-related variable."""
        # Extract the heredoc containing the cluster manifest (between cat <<EOF and EOF)
        heredoc_match = re.search(
            r"cat\s+<<EOF.*?apiVersion:\s+cluster\.x-k8s\.io.*?EOF",
            script_text,
            re.DOTALL,
        )
        assert heredoc_match, "Could not find Phase 4 cluster manifest heredoc"
        manifest_text = heredoc_match.group(0)

        # Extract just the variables section
        variables_start = manifest_text.find("variables:")
        assert variables_start >= 0, "No variables section found in manifest"
        variables_section = manifest_text[variables_start:]

        # Verify no DNS-related variable names appear
        dns_keywords = ["dns", "nameserver", "resolv", "nodeDNS", "dnsServers"]
        for keyword in dns_keywords:
            assert keyword.lower() not in variables_section.lower(), (
                f"Found unexpected DNS-related keyword '{keyword}' in variables section"
            )

    def test_only_three_top_level_variable_names(self, script_text: str):
        """The variables section must contain exactly 3 top-level variables.

        The regex matches '    - name:' at exactly 4-space indent (top-level
        variables in the YAML topology spec), excluding nested names like
        volume entries inside the 'volumes' value.
        """
        heredoc_match = re.search(
            r"cat\s+<<EOF.*?apiVersion:\s+cluster\.x-k8s\.io.*?EOF",
            script_text,
            re.DOTALL,
        )
        assert heredoc_match, "Could not find Phase 4 cluster manifest heredoc"
        manifest_text = heredoc_match.group(0)

        variables_start = manifest_text.find("variables:")
        variables_section = manifest_text[variables_start:]

        # Match only top-level variable entries (4-space indent: "    - name:")
        variable_names = re.findall(r"^    - name:\s+(\S+)", variables_section, re.MULTILINE)
        assert variable_names == ["vmClass", "storageClass", "volumes"], (
            f"Expected exactly [vmClass, storageClass, volumes], got {variable_names}"
        )


# ============================================================================
# Test 2b: All 6 existing sslip-helpers functions preserved
# ============================================================================

class TestSslipHelpersFunctionsPreserved:
    """The sslip-helpers.sh shared library must contain all 6 original functions.

    **Validates: Requirements 3.2**
    """

    EXPECTED_FUNCTIONS = [
        "construct_sslip_hostname",
        "check_cert_manager_available",
        "check_cluster_issuer_ready",
        "create_cluster_issuer",
        "create_ingress_with_tls",
        "wait_for_certificate",
    ]

    @pytest.mark.parametrize("func_name", EXPECTED_FUNCTIONS)
    def test_function_exists(self, sslip_helpers_text: str, func_name: str):
        """Each expected function must be defined in sslip-helpers.sh."""
        pattern = rf"^{func_name}\(\)\s*\{{" 
        assert re.search(pattern, sslip_helpers_text, re.MULTILINE), (
            f"Function '{func_name}' not found in sslip-helpers.sh"
        )

    def test_function_count_at_least_six(self, sslip_helpers_text: str):
        """There must be at least 6 function definitions."""
        functions = re.findall(r"^\w+\(\)\s*\{", sslip_helpers_text, re.MULTILINE)
        assert len(functions) >= 6, (
            f"Expected at least 6 functions, found {len(functions)}: {functions}"
        )


# ============================================================================
# Test 2c: Phase 5h CoreDNS sslip.io forwarding rule present
# ============================================================================

class TestCoreDnsSslipForwardingPreserved:
    """The CoreDNS patching with sslip.io forwarding to 8.8.8.8 and 1.1.1.1
    must be present in deploy-cluster.sh (within Phase 5h).

    **Validates: Requirements 3.2, 3.4**
    """

    def test_coredns_sslip_forwarding_block(self, script_text: str):
        """The script must contain the sslip.io:53 forwarding block."""
        assert "sslip.io:53" in script_text

    def test_coredns_forwards_to_google_dns(self, script_text: str):
        """The forwarding rule must include 8.8.8.8."""
        assert "forward . 8.8.8.8 1.1.1.1" in script_text

    def test_coredns_idempotency_check(self, script_text: str):
        """The script must check if sslip.io forwarding already exists."""
        assert "grep -q 'sslip.io'" in script_text

    def test_coredns_restart_after_patch(self, script_text: str):
        """The script must restart CoreDNS after patching."""
        assert "kubectl rollout restart deployment/coredns -n kube-system" in script_text

    def test_coredns_patch_log_message(self, script_text: str):
        """The script must log the CoreDNS patch success."""
        assert "CoreDNS patched with sslip.io forwarding rule" in script_text


# ============================================================================
# Test 2d: USE_SSLIP_DNS guard uses == "true" comparison
# ============================================================================

class TestUseSslipDnsGuardPattern:
    """All USE_SSLIP_DNS guards in deploy-cluster.sh must use string comparison
    with == "true" (not truthy evaluation).

    **Validates: Requirements 3.1**
    """

    def test_guard_uses_string_comparison(self, script_text: str):
        """Every USE_SSLIP_DNS conditional must use == "true" comparison."""
        # Find all lines that test USE_SSLIP_DNS in conditionals
        guards = re.findall(
            r'.*USE_SSLIP_DNS.*==.*', script_text
        )
        assert len(guards) > 0, "No USE_SSLIP_DNS guards found"
        for guard in guards:
            assert '"true"' in guard, (
                f"Guard does not use '== \"true\"' comparison: {guard.strip()}"
            )

    def test_default_value_is_true(self, script_text: str):
        """USE_SSLIP_DNS defaults to 'true' in the variable block."""
        assert 'USE_SSLIP_DNS="${USE_SSLIP_DNS:-true}"' in script_text


# ============================================================================
# Test 2e: Teardown scripts have proper sslip.io cleanup
# ============================================================================

class TestTeardownSslipCleanup:
    """teardown-cluster.sh must have sslip.io resource cleanup including
    Ingress, Certificate, and ClusterIssuer deletion.

    **Validates: Requirements 3.1, 3.3**
    """

    def test_sslip_ingress_deletion(self, teardown_cluster_text: str):
        """The teardown script must delete the sslip.io Ingress."""
        assert "kubectl delete ingress vks-test-sslip-ingress" in teardown_cluster_text

    def test_sslip_certificate_deletion(self, teardown_cluster_text: str):
        """The teardown script must delete the sslip.io Certificate."""
        assert "kubectl delete certificate vks-test-sslip-ingress-tls" in teardown_cluster_text

    def test_clusterissuer_prod_deletion(self, teardown_cluster_text: str):
        """The teardown script must delete the letsencrypt-prod ClusterIssuer."""
        assert "kubectl delete clusterissuer letsencrypt-prod" in teardown_cluster_text

    def test_clusterissuer_staging_deletion(self, teardown_cluster_text: str):
        """The teardown script must delete the letsencrypt-staging ClusterIssuer."""
        assert "kubectl delete clusterissuer letsencrypt-staging" in teardown_cluster_text

    def test_sslip_deps_check(self, teardown_cluster_text: str):
        """The teardown script must check for sslip.io dependencies before
        removing cert-manager/Contour packages."""
        assert "SSLIP_DEPS" in teardown_cluster_text

    def test_ignore_not_found_pattern(self, teardown_cluster_text: str):
        """sslip.io resource deletions must use --ignore-not-found."""
        # Find all sslip-related delete commands
        sslip_deletes = [
            line.strip()
            for line in teardown_cluster_text.splitlines()
            if "sslip" in line.lower() and "kubectl delete" in line
        ]
        assert len(sslip_deletes) > 0, "No sslip.io kubectl delete commands found"
        for cmd in sslip_deletes:
            assert "--ignore-not-found" in cmd, (
                f"sslip.io delete command missing --ignore-not-found: {cmd}"
            )

    def test_phase_1b_sslip_infrastructure(self, teardown_cluster_text: str):
        """Phase 1b must handle ClusterIssuers and sslip.io infrastructure."""
        assert "Phase 1b" in teardown_cluster_text or "1b" in teardown_cluster_text
        assert "sslip.io infrastructure" in teardown_cluster_text

    def test_sources_sslip_helpers(self, teardown_cluster_text: str):
        """The teardown script must source sslip-helpers.sh."""
        assert "sslip-helpers.sh" in teardown_cluster_text
