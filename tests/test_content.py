"""Content-presence unit tests for VCF 9 IaC Onboarding Guide."""

import re

import yaml


# ---------------------------------------------------------------------------
# Helper: extract text for a specific phase section
# ---------------------------------------------------------------------------

def _phase_section(guide_text: str, phase_num: int) -> str:
    """Return the text of a single phase section (from its header to the next
    phase header or end of file)."""
    pattern = rf"(## Phase {phase_num}:.*?)(?=## Phase \d+:|## Appendix|\Z)"
    match = re.search(pattern, guide_text, re.DOTALL)
    assert match, f"Phase {phase_num} section not found"
    return match.group(1)


# ===================================================================
# Task 13.1 — Phase structure and CLI commands
# Validates: Requirements 1.1, 1.2, 2.1, 2.2, 2.3, 2.4, 5.2, 5.3, 6.6
# ===================================================================


class TestPhaseStructure:
    """All 7 phases exist with sequential numbering."""

    def test_all_seven_phases_present(self, guide_text):
        for i in range(1, 8):
            assert f"## Phase {i}:" in guide_text, (
                f"Phase {i} header missing from guide"
            )

    def test_phases_appear_in_order(self, guide_text):
        positions = []
        for i in range(1, 8):
            pos = guide_text.index(f"## Phase {i}:")
            positions.append(pos)
        assert positions == sorted(positions), "Phases are not in sequential order"


class TestPhase1CLICommands:
    """Phase 1 contains required VCF CLI commands.
    Validates: Requirements 1.1, 1.2"""

    def test_vcf_context_create_in_phase1(self, guide_text):
        section = _phase_section(guide_text, 1)
        assert "vcf context create" in section

    def test_vcf_context_use_in_phase1(self, guide_text):
        section = _phase_section(guide_text, 1)
        assert "vcf context use" in section


class TestPhase2CLICommands:
    """Phase 2 contains topology discovery kubectl commands.
    Validates: Requirements 2.1, 2.2, 2.3, 2.4"""

    def test_kubectl_get_regions(self, guide_text):
        section = _phase_section(guide_text, 2)
        assert "kubectl get regions" in section

    def test_kubectl_get_zones(self, guide_text):
        section = _phase_section(guide_text, 2)
        assert "kubectl get zones" in section

    def test_kubectl_get_svnscls(self, guide_text):
        section = _phase_section(guide_text, 2)
        assert "kubectl get svnscls" in section

    def test_kubectl_get_vpcs(self, guide_text):
        section = _phase_section(guide_text, 2)
        assert "kubectl get vpcs" in section


class TestPhase5CLICommands:
    """Phase 5 contains context refresh command.
    Validates: Requirements 5.2, 5.3"""

    def test_vcf_context_refresh_in_phase5(self, guide_text):
        section = _phase_section(guide_text, 5)
        assert "vcf context refresh" in section


class TestPhase6CLICommands:
    """Phase 6 contains kubectl apply command.
    Validates: Requirement 6.6"""

    def test_kubectl_apply_in_phase6(self, guide_text):
        section = _phase_section(guide_text, 6)
        assert "kubectl apply" in section


# ===================================================================
# Task 13.2 — Manifest presence and reference sections
# Validates: Requirements 3.1, 3.2, 3.3, 4.1, 4.2, 4.3, 4.4,
#            6.1, 7.1, 7.2, 7.3, 7.6, 8.1, 9.2, 9.5
# ===================================================================


class TestManifestKindsPresent:
    """Every required YAML manifest kind appears in the guide's YAML blocks.
    Validates: Requirements 3.1, 3.2, 3.3, 4.1, 4.2, 4.3, 4.4,
               6.1, 7.1, 7.2, 7.3, 7.6"""

    REQUIRED_KINDS = [
        "Project",
        "ProjectRoleBinding",
        "SupervisorNamespace",
        "VPC",
        "TransitGateway",
        "VPCAttachment",
        "VPCNATRule",
        "Cluster",
        "PersistentVolumeClaim",
        "Deployment",
        "Service",
        "VksCredentialRequest",
    ]

    @staticmethod
    def _all_kinds(yaml_blocks):
        """Parse all YAML blocks and collect every 'kind' value."""
        kinds = set()
        for block in yaml_blocks:
            for doc in yaml.safe_load_all(block):
                if isinstance(doc, dict) and "kind" in doc:
                    kinds.add(doc["kind"])
        return kinds

    def test_all_required_kinds_present(self, yaml_blocks):
        found_kinds = self._all_kinds(yaml_blocks)
        for kind in self.REQUIRED_KINDS:
            assert kind in found_kinds, (
                f"YAML manifest kind '{kind}' not found in guide YAML blocks"
            )


class TestEKSMappingTable:
    """EKS-to-VKS mapping table contains all specified AWS constructs.
    Validates: Requirement 8.1"""

    AWS_CONSTRUCTS = [
        "EKS Cluster",
        "VPC",
        "Subnets",
        "IAM Roles",
        "EBS CSI",
        "ALB",
        "NLB",
        "Node Groups",
        "Transit Gateway",
        "NAT Gateway",
        "Security Groups",
    ]

    def test_all_aws_constructs_in_mapping(self, guide_text):
        # Extract the Appendix A section
        pattern = r"(## Appendix A:.*?)(?=## Appendix B|\Z)"
        match = re.search(pattern, guide_text, re.DOTALL)
        assert match, "Appendix A (EKS-to-VKS Migration Mapping) not found"
        section = match.group(1)
        for construct in self.AWS_CONSTRUCTS:
            assert construct in section, (
                f"AWS construct '{construct}' not found in EKS-to-VKS mapping"
            )


class TestParameterReferenceTable:
    """Parameter reference table exists (Appendix B).
    Validates: Requirement 9.2"""

    def test_appendix_b_exists(self, guide_text):
        assert "## Appendix B:" in guide_text or "## Appendix B " in guide_text, (
            "Appendix B (Parameter Reference) section not found"
        )

    def test_parameter_table_has_placeholder_syntax(self, guide_text):
        pattern = r"(## Appendix B.*?)(?=## Appendix C|\Z)"
        match = re.search(pattern, guide_text, re.DOTALL)
        assert match, "Appendix B section not found"
        section = match.group(1)
        # The table should contain at least one <PLACEHOLDER> entry
        assert "<" in section and ">" in section, (
            "Parameter reference table does not contain placeholder variables"
        )


class TestAPIGroupReference:
    """API group reference section exists (Appendix C).
    Validates: Requirement 9.5"""

    def test_appendix_c_exists(self, guide_text):
        assert "## Appendix C:" in guide_text or "## Appendix C " in guide_text, (
            "Appendix C (API Group Reference) section not found"
        )
