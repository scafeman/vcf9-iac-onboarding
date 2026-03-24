"""Shared fixtures for VCF 9 IaC Onboarding Guide tests."""

import os
import re
import pytest
import yaml

GUIDE_PATH = os.path.join(os.path.dirname(__file__), "..", "vcf9-iac-onboarding-guide.md")

# Pattern matches fenced YAML code blocks: ```yaml ... ```
_YAML_BLOCK_RE = re.compile(r"```yaml\s*\n(.*?)```", re.DOTALL)


def _extract_yaml_blocks(markdown_text: str) -> list[str]:
    """Extract all fenced YAML code blocks from markdown text."""
    return [m.group(1) for m in _YAML_BLOCK_RE.finditer(markdown_text)]


@pytest.fixture(scope="session")
def guide_text() -> str:
    """Return the full text of the onboarding guide."""
    with open(GUIDE_PATH, encoding="utf-8") as f:
        return f.read()


@pytest.fixture(scope="session")
def yaml_blocks(guide_text: str) -> list[str]:
    """Return a list of raw YAML strings extracted from the guide."""
    return _extract_yaml_blocks(guide_text)


# ---------------------------------------------------------------------------
# Scenario Script Fixtures
# ---------------------------------------------------------------------------

SCRIPT_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "scenario1", "scenario1-full-stack-deploy.sh"
)

# Matches heredoc blocks: cat <<EOF ... EOF  or  cat <<'EOF' ... EOF
_HEREDOC_RE = re.compile(
    r"cat\s+<<'?EOF'?\s*.*?\n(.*?\n)EOF\b", re.DOTALL
)

# Matches lines containing kubectl create or kubectl apply commands
_KUBECTL_CMD_RE = re.compile(r"^.*kubectl\s+(?:create|apply)\b.*$", re.MULTILINE)

# Matches phase section headers like:
#   # Phase 1: VCF CLI Context Creation
#   # Phase 2b + 3: Context Refresh & Bridge
#   # Phase 5b: Wait for Worker Nodes to Become Ready
_PHASE_HEADER_RE = re.compile(
    r"^#+ Phase (\d+\w?(?:\s*\+\s*\d+)?):\s*(.+)$", re.MULTILINE
)


def _extract_heredocs(script_text: str) -> list[str]:
    """Extract the content of every heredoc block from the script."""
    return [m.group(1) for m in _HEREDOC_RE.finditer(script_text)]


def _extract_kubectl_commands(script_text: str) -> list[str]:
    """Extract all kubectl create / kubectl apply command lines."""
    return [m.group(0).strip() for m in _KUBECTL_CMD_RE.finditer(script_text)]


def _extract_phases(script_text: str) -> dict[int, str]:
    """Extract phase sections keyed by phase number.

    Each value is the full text from the phase header to the next phase header
    (or end of file).

    Compound headers like "Phase 2b + 3" are indexed by every integer that
    appears in the label (e.g. both 2 and 3).  Sub-phase headers like
    "Phase 5b" are indexed by the leading integer (5).
    """
    headers = list(_PHASE_HEADER_RE.finditer(script_text))
    phases: dict[int, str] = {}
    for i, hdr in enumerate(headers):
        start = hdr.start()
        end = headers[i + 1].start() if i + 1 < len(headers) else len(script_text)
        section_text = script_text[start:end]
        # Extract all integers from the phase label (e.g. "2b + 3" → [2, 3])
        phase_nums = [int(n) for n in re.findall(r"\d+", hdr.group(1))]
        for num in phase_nums:
            # Only store if not already present (first occurrence wins for
            # primary phases; compound headers fill in gaps like phase 3).
            if num not in phases:
                phases[num] = section_text
    return phases


@pytest.fixture(scope="session")
def script_text() -> str:
    """Return the full text of the scenario script."""
    with open(SCRIPT_PATH, encoding="utf-8") as f:
        return f.read()


@pytest.fixture(scope="session")
def script_heredocs(script_text: str) -> list[str]:
    """Return a list of heredoc block contents extracted from the script."""
    return _extract_heredocs(script_text)


@pytest.fixture(scope="session")
def script_kubectl_commands(script_text: str) -> list[str]:
    """Return all kubectl create/apply command lines from the script."""
    return _extract_kubectl_commands(script_text)


@pytest.fixture(scope="session")
def script_phases(script_text: str) -> dict[int, str]:
    """Return phase sections keyed by phase number."""
    return _extract_phases(script_text)


# ---------------------------------------------------------------------------
# Scenario 2 Fixtures
# ---------------------------------------------------------------------------

SCENARIO2_DEPLOY_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "scenario2", "scenario2-vks-metrics-deploy.sh"
)

SCENARIO2_TEARDOWN_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "scenario2", "scenario2-vks-metrics-teardown.sh"
)

TELEGRAF_VALUES_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "scenario2", "telegraf-values.yaml"
)


@pytest.fixture(scope="session")
def scenario2_deploy_text() -> str:
    """Return the full text of the Scenario 2 deploy script."""
    with open(SCENARIO2_DEPLOY_PATH, encoding="utf-8") as f:
        return f.read()


@pytest.fixture(scope="session")
def scenario2_teardown_text() -> str:
    """Return the full text of the Scenario 2 teardown script."""
    with open(SCENARIO2_TEARDOWN_PATH, encoding="utf-8") as f:
        return f.read()


@pytest.fixture(scope="session")
def scenario2_deploy_phases(scenario2_deploy_text: str) -> dict[int, str]:
    """Return phase sections from the deploy script keyed by phase number."""
    return _extract_phases(scenario2_deploy_text)


@pytest.fixture(scope="session")
def telegraf_values_text() -> str:
    """Return the raw text of the Telegraf values YAML file."""
    with open(TELEGRAF_VALUES_PATH, encoding="utf-8") as f:
        return f.read()


@pytest.fixture(scope="session")
def telegraf_values_parsed(telegraf_values_text: str):
    """Return the parsed YAML object from the Telegraf values file."""
    return yaml.safe_load(telegraf_values_text)


# ---------------------------------------------------------------------------
# Scenario 3 Fixtures
# ---------------------------------------------------------------------------

SCENARIO3_DEPLOY_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "scenario3", "scenario3-argocd-deploy.sh"
)

SCENARIO3_TEARDOWN_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "scenario3", "scenario3-argocd-teardown.sh"
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

CONTOUR_VALUES_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "scenario3", "contour-values.yaml"
)

HARBOR_VALUES_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "scenario3", "harbor-values.yaml"
)

ARGOCD_VALUES_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "scenario3", "argocd-values.yaml"
)


@pytest.fixture(scope="session")
def scenario3_deploy_text() -> str:
    """Return the full text of the Scenario 3 deploy script."""
    with open(SCENARIO3_DEPLOY_PATH, encoding="utf-8") as f:
        return f.read()


@pytest.fixture(scope="session")
def scenario3_teardown_text() -> str:
    """Return the full text of the Scenario 3 teardown script."""
    with open(SCENARIO3_TEARDOWN_PATH, encoding="utf-8") as f:
        return f.read()


@pytest.fixture(scope="session")
def scenario3_deploy_phases(scenario3_deploy_text: str) -> dict[int, str]:
    """Return phase sections from the Scenario 3 deploy script keyed by phase number."""
    return _extract_phases(scenario3_deploy_text)


@pytest.fixture(scope="session")
def gitlab_operator_values_text() -> str:
    """Return the raw text of the GitLab Operator values YAML file."""
    with open(GITLAB_OPERATOR_VALUES_PATH, encoding="utf-8") as f:
        return f.read()


@pytest.fixture(scope="session")
def gitlab_operator_values_parsed(gitlab_operator_values_text: str):
    """Return the parsed YAML object from the GitLab Operator values file."""
    return yaml.safe_load(gitlab_operator_values_text)


@pytest.fixture(scope="session")
def gitlab_runner_values_text() -> str:
    """Return the raw text of the GitLab Runner values YAML file."""
    with open(GITLAB_RUNNER_VALUES_PATH, encoding="utf-8") as f:
        return f.read()


@pytest.fixture(scope="session")
def gitlab_runner_values_parsed(gitlab_runner_values_text: str):
    """Return the parsed YAML object from the GitLab Runner values file."""
    return yaml.safe_load(gitlab_runner_values_text)


@pytest.fixture(scope="session")
def argocd_app_manifest_text() -> str:
    """Return the raw text of the ArgoCD Application manifest."""
    with open(ARGOCD_APP_MANIFEST_PATH, encoding="utf-8") as f:
        return f.read()


@pytest.fixture(scope="session")
def argocd_app_manifest_parsed(argocd_app_manifest_text: str):
    """Return the parsed YAML object from the ArgoCD Application manifest."""
    return yaml.safe_load(argocd_app_manifest_text)


@pytest.fixture(scope="session")
def contour_values_text() -> str:
    """Return the raw text of the Contour values YAML file."""
    with open(CONTOUR_VALUES_PATH, encoding="utf-8") as f:
        return f.read()


@pytest.fixture(scope="session")
def contour_values_parsed(contour_values_text: str):
    """Return the parsed YAML object from the Contour values file."""
    return yaml.safe_load(contour_values_text)


@pytest.fixture(scope="session")
def harbor_values_text() -> str:
    """Return the raw text of the Harbor values YAML file."""
    with open(HARBOR_VALUES_PATH, encoding="utf-8") as f:
        return f.read()


@pytest.fixture(scope="session")
def harbor_values_parsed(harbor_values_text: str):
    """Return the parsed YAML object from the Harbor values file."""
    return yaml.safe_load(harbor_values_text)


@pytest.fixture(scope="session")
def argocd_values_text() -> str:
    """Return the raw text of the ArgoCD values YAML file."""
    with open(ARGOCD_VALUES_PATH, encoding="utf-8") as f:
        return f.read()


@pytest.fixture(scope="session")
def argocd_values_parsed(argocd_values_text: str):
    """Return the parsed YAML object from the ArgoCD values file."""
    return yaml.safe_load(argocd_values_text)
