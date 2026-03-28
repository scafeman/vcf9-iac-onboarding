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
    """All 8 phases exist with sequential numbering."""

    def test_all_eight_phases_present(self, guide_text):
        for i in range(1, 9):
            assert f"## Phase {i}:" in guide_text, (
                f"Phase {i} header missing from guide"
            )

    def test_phases_appear_in_order(self, guide_text):
        positions = []
        for i in range(1, 9):
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


# ===================================================================
# Task 9.2 — Guide corrections and sample manifest content tests
# Validates: Requirements 2.1, 3.1, 3.5, 4.3, 5.1, 6.1, 7.1,
#            8.2, 9.1, 10.1, 11.1, 12.1, 13.1, 13.2, 14.1,
#            15.1, 15.2, 16.1, 16.2
# ===================================================================


class TestPhase3VPCManifestCorrections:
    """Phase 3 contains corrected VPC manifest with privateIPs and regionName,
    and does NOT contain deprecated fields in VPC manifests.
    Validates: Requirement 2.1"""

    def test_phase3_vpc_has_privateIPs(self, guide_text):
        section = _phase_section(guide_text, 3)
        assert "privateIPs" in section, (
            "Phase 3 VPC manifest missing 'privateIPs' field"
        )

    def test_phase3_vpc_has_regionName(self, guide_text):
        section = _phase_section(guide_text, 3)
        assert "regionName" in section, (
            "Phase 3 VPC manifest missing 'regionName' field"
        )

    def test_phase3_vpc_no_defaultGatewayPath(self, guide_text):
        section = _phase_section(guide_text, 3)
        # Only check VPC YAML blocks for deprecated fields
        vpc_blocks = [b for b in re.findall(
            r"```yaml\s*\n(.*?)```", section, re.DOTALL
        ) if "kind: VPC\n" in b]
        for block in vpc_blocks:
            assert "defaultGatewayPath" not in block, (
                "Phase 3 VPC manifest still contains deprecated 'defaultGatewayPath'"
            )

    def test_phase3_vpc_no_defaultSubnetSize(self, guide_text):
        section = _phase_section(guide_text, 3)
        vpc_blocks = [b for b in re.findall(
            r"```yaml\s*\n(.*?)```", section, re.DOTALL
        ) if "kind: VPC\n" in b]
        for block in vpc_blocks:
            assert "defaultSubnetSize" not in block, (
                "Phase 3 VPC manifest still contains deprecated 'defaultSubnetSize'"
            )

    def test_phase3_vpc_no_shortID(self, guide_text):
        section = _phase_section(guide_text, 3)
        vpc_blocks = [b for b in re.findall(
            r"```yaml\s*\n(.*?)```", section, re.DOTALL
        ) if "kind: VPC\n" in b]
        for block in vpc_blocks:
            assert "shortID" not in block, (
                "Phase 3 VPC manifest still contains deprecated 'shortID'"
            )

    def test_phase3_vpc_no_privateCIDRs(self, guide_text):
        section = _phase_section(guide_text, 3)
        vpc_blocks = [b for b in re.findall(
            r"```yaml\s*\n(.*?)```", section, re.DOTALL
        ) if "kind: VPC\n" in b]
        for block in vpc_blocks:
            assert "privateCIDRs" not in block, (
                "Phase 3 VPC manifest still contains deprecated 'privateCIDRs'"
            )


class TestPhase3NoTransitGatewayCreation:
    """Phase 3 no longer contains Transit Gateway creation steps.
    Validates: Requirements 3.1, 3.5"""

    def test_phase3_no_kind_transitgateway_in_yaml(self, guide_text):
        section = _phase_section(guide_text, 3)
        yaml_blocks = re.findall(r"```yaml\s*\n(.*?)```", section, re.DOTALL)
        for block in yaml_blocks:
            for doc in yaml.safe_load_all(block):
                if isinstance(doc, dict) and "kind" in doc:
                    assert doc["kind"] != "TransitGateway", (
                        "Phase 3 still contains a 'kind: TransitGateway' manifest"
                    )

    def test_phase3_no_create_transit_gateway_heading(self, guide_text):
        section = _phase_section(guide_text, 3)
        assert "Create a Transit Gateway" not in section, (
            "Phase 3 still contains a 'Create a Transit Gateway' heading"
        )


class TestPhase3NATOptional:
    """Phase 3 NAT section is marked as optional.
    Validates: Requirement 4.3"""

    def test_phase3_nat_heading_contains_optional(self, guide_text):
        section = _phase_section(guide_text, 3)
        # Look for a heading that mentions NAT and Optional
        nat_headings = re.findall(r"^###.*NAT.*$", section, re.MULTILINE)
        has_optional = any("Optional" in h for h in nat_headings)
        assert has_optional, (
            "Phase 3 NAT section heading does not contain 'Optional'"
        )


class TestPhase3TroubleshootingNoIpblockusages:
    """Phase 3 troubleshooting no longer references kubectl get ipblockusages.
    Validates: Requirement 5.1"""

    def test_phase3_no_ipblockusages(self, guide_text):
        section = _phase_section(guide_text, 3)
        assert "ipblockusages" not in section, (
            "Phase 3 troubleshooting still references 'kubectl get ipblockusages'"
        )


class TestPhase6ContentLibraryID:
    """Phase 6 contains Content Library ID instructions.
    Validates: Requirement 6.1"""

    def test_phase6_has_content_library_id(self, guide_text):
        section = _phase_section(guide_text, 6)
        has_content_library = (
            "Content Library ID" in section
            or "Content Library" in section
            or "contentlibraries" in section
        )
        assert has_content_library, (
            "Phase 6 does not contain Content Library ID instructions"
        )


class TestPhase7KubeconfigCLIFirst:
    """Phase 7 contains vcf cluster kubeconfig get as first option.
    Validates: Requirement 7.1"""

    def test_phase7_kubeconfig_get_before_portal(self, guide_text):
        section = _phase_section(guide_text, 7)
        cli_pos = section.find("vcf cluster kubeconfig get")
        portal_pos = section.find("VCFA Portal")
        assert cli_pos != -1, (
            "Phase 7 does not contain 'vcf cluster kubeconfig get'"
        )
        assert portal_pos != -1, (
            "Phase 7 does not contain 'VCFA Portal' option"
        )
        assert cli_pos < portal_pos, (
            "'vcf cluster kubeconfig get' does not appear before 'VCFA Portal'"
        )


class TestPhase7KubectlGetSvc:
    """Phase 7 contains kubectl get svc verification method.
    Validates: Requirement 8.2"""

    def test_phase7_has_kubectl_get_svc(self, guide_text):
        section = _phase_section(guide_text, 7)
        assert "kubectl get svc" in section, (
            "Phase 7 does not contain 'kubectl get svc' verification method"
        )


class TestClusterScaling:
    """Guide contains cluster scaling section with vcf cluster scale command.
    Validates: Requirement 9.1"""

    def test_guide_has_cluster_scaling_section(self, guide_text):
        assert "## Phase 8:" in guide_text, (
            "Guide does not contain Phase 8 (Cluster Scaling) section"
        )

    def test_scaling_section_has_vcf_cluster_scale(self, guide_text):
        section = _phase_section(guide_text, 8)
        assert "vcf cluster scale" in section, (
            "Cluster scaling section does not contain 'vcf cluster scale' command"
        )


class TestSampleManifestFilesExist:
    """All 7 expected sample manifest files exist in examples/.
    Validates: Requirements 10.1, 11.1, 12.1, 13.1, 14.1, 15.1, 16.1"""

    EXPECTED_FILES = [
        "sample-create-cluster.yaml",
        "sample-create-project-ns.yaml",
        "sample-create-vpc.yaml",
        "sample-nat-rules.yaml",
        "sample-vks-functional-test.yaml",
        "sample-vpc-attachment.yaml",
        "sample-vpc-connectivity-profile.yaml",
    ]

    def test_all_expected_sample_manifests_exist(self, sample_manifest_filenames):
        for filename in self.EXPECTED_FILES:
            assert filename in sample_manifest_filenames, (
                f"Expected sample manifest '{filename}' not found in examples/"
            )


class TestNATRulesManifestContent:
    """NAT rules manifest contains both SNAT and DNAT examples.
    Validates: Requirements 13.1, 13.2"""

    def test_nat_rules_has_snat(self, sample_manifest_content):
        content = sample_manifest_content["sample-nat-rules.yaml"]
        docs = list(yaml.safe_load_all(content))
        actions = [
            d["spec"]["action"]
            for d in docs
            if isinstance(d, dict) and d.get("spec", {}).get("action")
        ]
        assert "SNAT" in actions, (
            "NAT rules manifest does not contain an SNAT example"
        )

    def test_nat_rules_has_dnat(self, sample_manifest_content):
        content = sample_manifest_content["sample-nat-rules.yaml"]
        docs = list(yaml.safe_load_all(content))
        actions = [
            d["spec"]["action"]
            for d in docs
            if isinstance(d, dict) and d.get("spec", {}).get("action")
        ]
        assert "DNAT" in actions, (
            "NAT rules manifest does not contain a DNAT example"
        )


class TestFunctionalTestManifestContent:
    """Functional test manifest contains PVC, Deployment, and Service kinds.
    Validates: Requirements 15.1, 15.2"""

    def test_functional_test_has_pvc(self, sample_manifest_content):
        content = sample_manifest_content["sample-vks-functional-test.yaml"]
        docs = list(yaml.safe_load_all(content))
        kinds = [d["kind"] for d in docs if isinstance(d, dict) and "kind" in d]
        assert "PersistentVolumeClaim" in kinds, (
            "Functional test manifest missing PersistentVolumeClaim"
        )

    def test_functional_test_has_deployment(self, sample_manifest_content):
        content = sample_manifest_content["sample-vks-functional-test.yaml"]
        docs = list(yaml.safe_load_all(content))
        kinds = [d["kind"] for d in docs if isinstance(d, dict) and "kind" in d]
        assert "Deployment" in kinds, (
            "Functional test manifest missing Deployment"
        )

    def test_functional_test_has_service(self, sample_manifest_content):
        content = sample_manifest_content["sample-vks-functional-test.yaml"]
        docs = list(yaml.safe_load_all(content))
        kinds = [d["kind"] for d in docs if isinstance(d, dict) and "kind" in d]
        assert "Service" in kinds, (
            "Functional test manifest missing Service"
        )


class TestProjectNamespaceManifestContent:
    """Project/namespace manifest contains Project, ProjectRoleBinding,
    and SupervisorNamespace kinds.
    Validates: Requirements 16.1, 16.2"""

    def test_project_ns_has_project(self, sample_manifest_content):
        content = sample_manifest_content["sample-create-project-ns.yaml"]
        docs = list(yaml.safe_load_all(content))
        kinds = [d["kind"] for d in docs if isinstance(d, dict) and "kind" in d]
        assert "Project" in kinds, (
            "Project/namespace manifest missing Project kind"
        )

    def test_project_ns_has_projectrolebinding(self, sample_manifest_content):
        content = sample_manifest_content["sample-create-project-ns.yaml"]
        docs = list(yaml.safe_load_all(content))
        kinds = [d["kind"] for d in docs if isinstance(d, dict) and "kind" in d]
        assert "ProjectRoleBinding" in kinds, (
            "Project/namespace manifest missing ProjectRoleBinding kind"
        )

    def test_project_ns_has_supervisornamespace(self, sample_manifest_content):
        content = sample_manifest_content["sample-create-project-ns.yaml"]
        docs = list(yaml.safe_load_all(content))
        kinds = [d["kind"] for d in docs if isinstance(d, dict) and "kind" in d]
        assert "SupervisorNamespace" in kinds, (
            "Project/namespace manifest missing SupervisorNamespace kind"
        )
