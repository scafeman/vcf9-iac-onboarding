"""Property-based tests for VCF 9 IaC Onboarding Guide YAML manifests."""

import yaml
import pytest
from hypothesis import given, settings
from hypothesis import strategies as st


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _parse_all_documents(raw_yaml: str) -> list[dict]:
    """Parse a YAML block (possibly multi-document) and return a list of
    parsed objects, filtering out ``None`` results that come from empty
    document segments or bare ``---`` separators."""
    docs = list(yaml.safe_load_all(raw_yaml))
    return [d for d in docs if d is not None]


def _k8s_manifests(yaml_blocks: list[str]) -> list[dict]:
    """Return only parsed documents that look like Kubernetes manifests
    (i.e. dicts with both ``apiVersion`` and ``kind`` keys)."""
    manifests: list[dict] = []
    for block in yaml_blocks:
        for doc in _parse_all_documents(block):
            if isinstance(doc, dict) and "apiVersion" in doc and "kind" in doc:
                manifests.append(doc)
    return manifests


# ---------------------------------------------------------------------------
# Property 1: YAML Round-Trip Integrity
# Feature: vcf9-iac-onboarding, Property 1: YAML Round-Trip Integrity
# Validates: Requirements 10.1, 10.2
# ---------------------------------------------------------------------------

def test_yaml_round_trip_integrity(yaml_blocks: list[str]) -> None:
    """For each extracted YAML block, parse → serialize → parse again and
    assert deep equality.  This proves every embedded manifest is
    syntactically valid YAML that survives round-trip serialization."""

    assert yaml_blocks, "No YAML blocks extracted from the guide"

    for idx, block in enumerate(yaml_blocks):
        # First parse
        first_parse = _parse_all_documents(block)
        assert first_parse, f"YAML block {idx} produced no documents on first parse"

        for doc_idx, doc in enumerate(first_parse):
            # Serialize back to YAML string
            serialized = yaml.dump(doc, default_flow_style=False)
            # Second parse
            second_parse = yaml.safe_load(serialized)
            assert doc == second_parse, (
                f"Round-trip mismatch in block {idx}, document {doc_idx}"
            )


# ---------------------------------------------------------------------------
# Property 2: Multi-Document YAML Separator
# Feature: vcf9-iac-onboarding, Property 2: Multi-Document YAML Separator
# Validates: Requirements 10.3
# ---------------------------------------------------------------------------

def test_multi_document_yaml_separator(yaml_blocks: list[str]) -> None:
    """For each YAML block that contains the ``---`` document separator,
    split on the separator, parse each segment individually, and assert
    each segment produces exactly one valid resource object (a dict, not
    None)."""

    multi_doc_blocks = [b for b in yaml_blocks if "\n---\n" in b or b.startswith("---\n")]
    assert multi_doc_blocks, "No multi-document YAML blocks found in the guide"

    for idx, block in enumerate(multi_doc_blocks):
        # Split on the standard YAML document separator
        segments = block.split("\n---\n")

        for seg_idx, segment in enumerate(segments):
            stripped = segment.strip()
            if not stripped:
                continue  # skip empty trailing segments

            parsed = yaml.safe_load(stripped)
            assert parsed is not None, (
                f"Multi-doc block {idx}, segment {seg_idx} parsed to None"
            )
            assert isinstance(parsed, dict), (
                f"Multi-doc block {idx}, segment {seg_idx} is not a dict "
                f"(got {type(parsed).__name__})"
            )


# ---------------------------------------------------------------------------
# Property 3: API Version and Kind Validity
# Feature: vcf9-iac-onboarding, Property 3: API Version and Kind Validity
# Validates: Requirements 10.4, 9.5
# ---------------------------------------------------------------------------

# The documented valid set of (apiVersion, kind) pairs.
VALID_API_PAIRS: set[tuple[str, str]] = {
    ("project.cci.vmware.com/v1alpha2", "Project"),
    ("authorization.cci.vmware.com/v1alpha1", "ProjectRoleBinding"),
    ("infrastructure.cci.vmware.com/v1alpha2", "SupervisorNamespace"),
    ("infrastructure.cci.vmware.com/v1alpha1", "VksCredentialRequest"),
    ("vpc.nsx.vmware.com/v1alpha1", "VPC"),
    ("vpc.nsx.vmware.com/v1alpha1", "TransitGateway"),
    ("vpc.nsx.vmware.com/v1alpha1", "VPCAttachment"),
    ("vpc.nsx.vmware.com/v1alpha1", "VPCNATRule"),
    ("cluster.x-k8s.io/v1beta1", "Cluster"),
    ("v1", "PersistentVolumeClaim"),
    ("v1", "Service"),
    ("apps/v1", "Deployment"),
    ("helm.cattle.io/v1", "HelmChart"),
}


def test_api_version_and_kind_validity(yaml_blocks: list[str]) -> None:
    """For each parsed YAML manifest that has both ``apiVersion`` and
    ``kind`` fields, assert the pair exists in the documented valid set."""

    manifests = _k8s_manifests(yaml_blocks)
    assert manifests, "No Kubernetes manifests found in the guide"

    for manifest in manifests:
        pair = (manifest["apiVersion"], manifest["kind"])
        assert pair in VALID_API_PAIRS, (
            f"Undocumented apiVersion/kind pair: {pair}"
        )


# ---------------------------------------------------------------------------
# Property 4: Placeholder Parameterization
# Feature: vcf9-iac-onboarding, Property 4: Placeholder Parameterization
# Validates: Requirements 9.1
# ---------------------------------------------------------------------------

# Strategies that generate realistic-looking environment-specific values.
# None of these should appear literally in any YAML manifest — the guide
# must use <PLACEHOLDER> syntax instead.

_project_names = st.from_regex(r"[a-z]{4,10}-[a-z]{3,6}-\d{2}", fullmatch=True)
_region_names = st.from_regex(r"region-[a-z]{2}\d-[a-z]", fullmatch=True)
_zone_names = st.from_regex(r"zone-dc\d-cl\d{2}", fullmatch=True)
_user_identities = st.from_regex(r"[a-z]{5,10}-user-\d{1,3}", fullmatch=True)
_vpc_names = st.from_regex(r"region-[a-z]{2}\d-[a-z]-default-vpc", fullmatch=True)
_cidrs = st.tuples(
    st.integers(min_value=1, max_value=254),
    st.integers(min_value=0, max_value=254),
    st.integers(min_value=0, max_value=254),
    st.integers(min_value=0, max_value=254),
    st.integers(min_value=8, max_value=28),
).map(lambda t: f"{t[0]}.{t[1]}.{t[2]}.{t[3]}/{t[4]}")
_cluster_names = st.from_regex(r"[a-z]{4,8}-clus-\d{2}", fullmatch=True)
_content_library_ids = st.uuids().map(str)


@given(
    project=_project_names,
    region=_region_names,
    zone=_zone_names,
    user=_user_identities,
    vpc=_vpc_names,
    cidr=_cidrs,
    cluster=_cluster_names,
    lib_id=_content_library_ids,
)
@settings(max_examples=100)
def test_placeholder_parameterization(
    yaml_blocks: list[str],
    project: str,
    region: str,
    zone: str,
    user: str,
    vpc: str,
    cidr: str,
    cluster: str,
    lib_id: str,
) -> None:
    """Generate random environment-specific values and assert none appear
    literally in any YAML manifest.  All such fields should use
    ``<PLACEHOLDER>`` syntax."""

    generated_values = [project, region, zone, user, vpc, cidr, cluster, lib_id]

    for block in yaml_blocks:
        for value in generated_values:
            assert value not in block, (
                f"Generated value {value!r} found literally in a YAML block — "
                "manifests should use <PLACEHOLDER> syntax"
            )


# ---------------------------------------------------------------------------
# Property 5: Inline Comment Coverage
# Feature: vcf9-iac-onboarding, Property 5: Inline Comment Coverage
# Validates: Requirements 9.4
# ---------------------------------------------------------------------------

def test_inline_comment_coverage(yaml_blocks: list[str]) -> None:
    """For each YAML code block, assert at least one line begins with ``#``
    (after optional leading whitespace).  This ensures every manifest
    includes explanatory inline comments."""

    assert yaml_blocks, "No YAML blocks extracted from the guide"

    for idx, block in enumerate(yaml_blocks):
        lines = block.splitlines()
        has_comment = any(line.lstrip().startswith("#") for line in lines)
        assert has_comment, (
            f"YAML block {idx} has no inline comment (line starting with #)"
        )
