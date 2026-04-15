"""Bug condition exploration tests for node-level DNS resolution fix.

These tests parse deploy-cluster.sh and sslip-helpers.sh to assert that the
expected fix exists. They are EXPECTED TO FAIL on unfixed code — failure
confirms the bug exists (no Phase 5j, no deploy_node_dns_daemonset, no DaemonSet).

**Validates: Requirements 1.1, 1.2, 1.3, 1.4, 2.1, 2.2, 2.3, 2.4**
"""

import os
import re
import pytest

PROJECT_ROOT = os.path.join(os.path.dirname(__file__), "..")

SSLIP_HELPERS_PATH = os.path.join(
    PROJECT_ROOT, "examples", "shared", "sslip-helpers.sh"
)


@pytest.fixture(scope="module")
def sslip_helpers_text() -> str:
    """Return the full text of sslip-helpers.sh."""
    with open(SSLIP_HELPERS_PATH, encoding="utf-8") as f:
        return f.read()


# ============================================================================
# Test 1a: deploy-cluster.sh contains Phase 5j deploying node-dns-patcher
# ============================================================================

class TestPhase5jExists:
    """Test 1a: Assert that deploy-cluster.sh contains a Phase 5j that deploys
    a node-dns-patcher DaemonSet to kube-system when USE_SSLIP_DNS=true.

    **Validates: Requirements 2.1, 2.2, 2.3, 2.4**

    On unfixed code, this FAILS because deploy-cluster.sh has no Phase 5j.
    The script goes directly from Phase 5i (ClusterIssuers) to Phase 6
    (Functional Validation) with no node DNS patching step.
    """

    def test_phase_5j_header_exists(self, script_text: str):
        """deploy-cluster.sh must contain a Phase 5j section header."""
        assert re.search(r"Phase 5j", script_text), (
            "deploy-cluster.sh does not contain a 'Phase 5j' section. "
            "There is no node DNS patcher deployment phase — this is the bug."
        )

    def test_phase_5j_deploys_node_dns_patcher(self, script_text: str):
        """Phase 5j must call deploy_node_dns_daemonset to create the DaemonSet."""
        assert "deploy_node_dns_daemonset" in script_text, (
            "deploy-cluster.sh does not call 'deploy_node_dns_daemonset'. "
            "No DaemonSet is deployed for node DNS patching — this is the bug."
        )

    def test_phase_5j_guarded_by_use_sslip_dns(self, script_text: str):
        """Phase 5j must be guarded by USE_SSLIP_DNS == true."""
        # Find Phase 5j section and verify it has the USE_SSLIP_DNS guard
        phase_5j_match = re.search(r"Phase 5j", script_text)
        assert phase_5j_match, "Phase 5j not found"

        # Get text after Phase 5j header
        after_5j = script_text[phase_5j_match.start():]
        # The guard should appear within the first ~20 lines of the phase
        guard_section = after_5j[:500]
        assert 'USE_SSLIP_DNS' in guard_section, (
            "Phase 5j is not guarded by USE_SSLIP_DNS check. "
            "The DaemonSet deployment should only run when USE_SSLIP_DNS=true."
        )


# ============================================================================
# Test 1b: sslip-helpers.sh contains deploy_node_dns_daemonset function
# ============================================================================

class TestDeployNodeDnsDaemonsetFunction:
    """Test 1b: Assert that sslip-helpers.sh contains a deploy_node_dns_daemonset
    function that creates a DaemonSet manifest with the correct configuration.

    **Validates: Requirements 2.1, 2.2, 2.3, 2.4**

    On unfixed code, this FAILS because sslip-helpers.sh only has 6 functions
    (construct_sslip_hostname, check_cert_manager_available, check_cluster_issuer_ready,
    create_cluster_issuer, create_ingress_with_tls, wait_for_certificate) and does
    not contain deploy_node_dns_daemonset.
    """

    def test_function_exists(self, sslip_helpers_text: str):
        """sslip-helpers.sh must define a deploy_node_dns_daemonset function."""
        assert "deploy_node_dns_daemonset" in sslip_helpers_text, (
            "sslip-helpers.sh does not contain 'deploy_node_dns_daemonset' function. "
            "No helper exists for deploying the node DNS patcher DaemonSet — this is the bug."
        )

    def test_function_is_a_shell_function(self, sslip_helpers_text: str):
        """deploy_node_dns_daemonset must be defined as a proper shell function."""
        assert re.search(
            r"deploy_node_dns_daemonset\s*\(\)", sslip_helpers_text
        ), (
            "deploy_node_dns_daemonset is not defined as a shell function in sslip-helpers.sh."
        )


# ============================================================================
# Test 1c: DaemonSet manifest includes public DNS nameservers
# ============================================================================

class TestDaemonSetPublicDns:
    """Test 1c: Assert that the DaemonSet manifest (within deploy_node_dns_daemonset)
    includes nameserver 8.8.8.8 and nameserver 1.1.1.1 in its container script.

    **Validates: Requirements 2.3, 2.4**

    On unfixed code, this FAILS because the function does not exist, so there
    is no DaemonSet manifest with public DNS servers.
    """

    def test_daemonset_has_google_dns(self, sslip_helpers_text: str):
        """The DaemonSet manifest must include nameserver 8.8.8.8."""
        assert "8.8.8.8" in sslip_helpers_text, (
            "sslip-helpers.sh does not reference '8.8.8.8'. "
            "No public DNS server (Google) is configured for node DNS — this is the bug."
        )

    def test_daemonset_has_cloudflare_dns(self, sslip_helpers_text: str):
        """The DaemonSet manifest must include nameserver 1.1.1.1."""
        assert "1.1.1.1" in sslip_helpers_text, (
            "sslip-helpers.sh does not reference '1.1.1.1'. "
            "No public DNS server (Cloudflare) is configured for node DNS — this is the bug."
        )


# ============================================================================
# Test 1d: DaemonSet uses hostNetwork, mounts host /etc, and has tolerations
# ============================================================================

class TestDaemonSetNodeAccess:
    """Test 1d: Assert that the DaemonSet uses hostNetwork: true, mounts the
    host /etc directory, and has tolerations to run on all nodes.

    **Validates: Requirements 2.1, 2.4**

    On unfixed code, this FAILS because the function and DaemonSet manifest
    do not exist.
    """

    def test_daemonset_has_host_network(self, sslip_helpers_text: str):
        """The DaemonSet must use hostNetwork: true for node-level DNS access."""
        assert "hostNetwork: true" in sslip_helpers_text, (
            "sslip-helpers.sh does not contain 'hostNetwork: true'. "
            "The DaemonSet cannot access node-level networking — this is the bug."
        )

    def test_daemonset_mounts_host_etc(self, sslip_helpers_text: str):
        """The DaemonSet must mount the host /etc directory."""
        # Check for hostPath mount of /etc
        has_host_etc = (
            "hostPath" in sslip_helpers_text
            and re.search(r'path:\s*/etc\b', sslip_helpers_text)
        )
        assert has_host_etc, (
            "sslip-helpers.sh does not mount host /etc directory. "
            "The DaemonSet cannot patch /etc/resolv.conf — this is the bug."
        )

    def test_daemonset_has_tolerations(self, sslip_helpers_text: str):
        """The DaemonSet must have tolerations to run on all nodes."""
        assert "tolerations" in sslip_helpers_text, (
            "sslip-helpers.sh does not contain 'tolerations'. "
            "The DaemonSet may not run on all nodes (e.g., control plane) — this is the bug."
        )


# ============================================================================
# Test 1e: DaemonSet container script runs in a loop to handle reboots
# ============================================================================

class TestDaemonSetLoop:
    """Test 1e: Assert that the DaemonSet container script runs in a loop
    with a sleep interval to handle node reboots that regenerate /etc/resolv.conf.

    **Validates: Requirements 2.1, 2.4**

    On unfixed code, this FAILS because the function and DaemonSet manifest
    do not exist, so there is no loop to re-apply DNS patches after reboots.
    """

    def test_daemonset_has_loop(self, sslip_helpers_text: str):
        """The DaemonSet container script must run in a while loop."""
        assert "while true" in sslip_helpers_text, (
            "sslip-helpers.sh does not contain 'while true' loop. "
            "The DaemonSet cannot re-apply DNS patches after node reboots — this is the bug."
        )

    def test_daemonset_has_sleep_in_loop(self, sslip_helpers_text: str):
        """The DaemonSet container script must sleep between loop iterations.

        Note: sslip-helpers.sh already has sleep commands in wait_for_certificate,
        so we check specifically for a sleep inside a 'while true' loop context
        (the DaemonSet polling pattern).
        """
        # Find the deploy_node_dns_daemonset function and check for sleep within it
        func_match = re.search(r"deploy_node_dns_daemonset\s*\(\)", sslip_helpers_text)
        assert func_match, (
            "deploy_node_dns_daemonset function not found — cannot check for sleep loop."
        )
        func_body = sslip_helpers_text[func_match.start():]
        # The function body should contain both 'while true' and 'sleep'
        assert "while true" in func_body and re.search(r"sleep\s+\d+", func_body), (
            "deploy_node_dns_daemonset does not contain a 'while true' loop with 'sleep'. "
            "The DaemonSet loop has no polling interval — this is the bug."
        )
