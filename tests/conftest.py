"""Shared fixtures for VCF 9 IaC Onboarding Guide tests."""

import glob
import os
import re
import pytest
import yaml

GUIDE_PATH = os.path.join(os.path.dirname(__file__), "..", "vcf9-iac-onboarding-guide.md")

# Root of the project (one level up from tests/)
PROJECT_ROOT = os.path.join(os.path.dirname(__file__), "..")

# Directory containing sample manifests
EXAMPLES_DIR = os.path.join(PROJECT_ROOT, "examples")

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
# Sample Manifest Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def sample_manifest_paths() -> list[str]:
    """Return a sorted list of all sample-*.yaml file paths from examples/."""
    pattern = os.path.join(EXAMPLES_DIR, "sample-*.yaml")
    return sorted(glob.glob(pattern))


@pytest.fixture(scope="session")
def sample_manifest_filenames(sample_manifest_paths: list[str]) -> list[str]:
    """Return a sorted list of sample manifest filenames for parameterized tests."""
    return [os.path.basename(p) for p in sample_manifest_paths]


@pytest.fixture(scope="session")
def sample_manifest_content() -> dict[str, str]:
    """Return a dict mapping sample manifest filename to its raw content."""
    pattern = os.path.join(EXAMPLES_DIR, "sample-*.yaml")
    contents: dict[str, str] = {}
    for path in sorted(glob.glob(pattern)):
        filename = os.path.basename(path)
        with open(path, encoding="utf-8") as f:
            contents[filename] = f.read()
    return contents


# ---------------------------------------------------------------------------
# Deploy Cluster Script Fixtures
# ---------------------------------------------------------------------------

SCRIPT_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "deploy-cluster", "deploy-cluster.sh"
)

# Matches heredoc blocks: cat <<EOF ... EOF  or  cat <<'EOF' ... EOF
_HEREDOC_RE = re.compile(
    r"cat\s+<<'?EOF'?\s*.*?\n(.*?\n)EOF\b", re.DOTALL
)

# Matches lines containing kubectl create or kubectl apply commands that use manifests
# Excludes imperative commands like 'kubectl create ns', 'kubectl create secret', etc.
_KUBECTL_CMD_RE = re.compile(
    r"^.*kubectl\s+(?:create|apply)\b(?!\s+(?:ns|namespace|secret)\b).*$", re.MULTILINE
)

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
    """Return the full text of the deploy cluster script."""
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
# Deploy Metrics Fixtures
# ---------------------------------------------------------------------------

METRICS_DEPLOY_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "deploy-metrics", "deploy-metrics.sh"
)

METRICS_TEARDOWN_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "deploy-metrics", "teardown-metrics.sh"
)

TELEGRAF_VALUES_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "deploy-metrics", "telegraf-values.yaml"
)


@pytest.fixture(scope="session")
def metrics_deploy_text() -> str:
    """Return the full text of the Deploy Metrics deploy script."""
    with open(METRICS_DEPLOY_PATH, encoding="utf-8") as f:
        return f.read()


@pytest.fixture(scope="session")
def metrics_teardown_text() -> str:
    """Return the full text of the Deploy Metrics teardown script."""
    with open(METRICS_TEARDOWN_PATH, encoding="utf-8") as f:
        return f.read()


@pytest.fixture(scope="session")
def metrics_deploy_phases(metrics_deploy_text: str) -> dict[int, str]:
    """Return phase sections from the deploy script keyed by phase number."""
    return _extract_phases(metrics_deploy_text)


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
# Deploy GitOps Fixtures
# ---------------------------------------------------------------------------

GITOPS_DEPLOY_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "deploy-gitops", "deploy-gitops.sh"
)

GITOPS_TEARDOWN_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "deploy-gitops", "teardown-gitops.sh"
)

GITLAB_OPERATOR_VALUES_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "deploy-gitops", "gitlab-operator-values.yaml"
)

GITLAB_RUNNER_VALUES_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "deploy-gitops", "gitlab-runner-values.yaml"
)

ARGOCD_APP_MANIFEST_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "deploy-gitops", "argocd-microservices-demo.yaml"
)

CONTOUR_VALUES_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "deploy-gitops", "contour-values.yaml"
)

HARBOR_VALUES_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "deploy-gitops", "harbor-values.yaml"
)

ARGOCD_VALUES_PATH = os.path.join(
    os.path.dirname(__file__), "..", "examples", "deploy-gitops", "argocd-values.yaml"
)


@pytest.fixture(scope="session")
def gitops_deploy_text() -> str:
    """Return the full text of the Deploy GitOps deploy script."""
    with open(GITOPS_DEPLOY_PATH, encoding="utf-8") as f:
        return f.read()


@pytest.fixture(scope="session")
def gitops_teardown_text() -> str:
    """Return the full text of the Deploy GitOps teardown script."""
    with open(GITOPS_TEARDOWN_PATH, encoding="utf-8") as f:
        return f.read()


@pytest.fixture(scope="session")
def gitops_deploy_phases(gitops_deploy_text: str) -> dict[int, str]:
    """Return phase sections from the Deploy GitOps deploy script keyed by phase number."""
    return _extract_phases(gitops_deploy_text)


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


# ---------------------------------------------------------------------------
# GitHub Actions VKS Deploy Workflow Fixtures
# ---------------------------------------------------------------------------

WORKFLOW_YAML_PATH = os.path.join(
    PROJECT_ROOT, ".github", "workflows", "deploy-vks.yml"
)

TRIGGER_SCRIPT_PATH = os.path.join(
    PROJECT_ROOT, "scripts", "trigger-deploy.sh"
)

WORKFLOW_README_PATH = os.path.join(
    PROJECT_ROOT, ".github", "workflows", "README.md"
)

DOCKER_COMPOSE_PATH = os.path.join(
    PROJECT_ROOT, "docker-compose.yml"
)


@pytest.fixture(scope="session")
def workflow_yaml_text() -> str:
    """Return the raw text of .github/workflows/deploy-vks.yml."""
    with open(WORKFLOW_YAML_PATH, encoding="utf-8") as f:
        return f.read()


@pytest.fixture(scope="session")
def workflow_yaml(workflow_yaml_text: str) -> dict:
    """Return the parsed YAML dict of the workflow file."""
    return yaml.safe_load(workflow_yaml_text)


@pytest.fixture(scope="session")
def trigger_script_text() -> str:
    """Return the raw text of scripts/trigger-deploy.sh."""
    with open(TRIGGER_SCRIPT_PATH, encoding="utf-8") as f:
        return f.read()


@pytest.fixture(scope="session")
def workflow_readme_text() -> str:
    """Return the raw text of .github/workflows/README.md."""
    with open(WORKFLOW_README_PATH, encoding="utf-8") as f:
        return f.read()


@pytest.fixture(scope="session")
def docker_compose_yaml() -> dict:
    """Return the parsed YAML dict of docker-compose.yml."""
    with open(DOCKER_COMPOSE_PATH, encoding="utf-8") as f:
        return yaml.safe_load(f.read())


# ---------------------------------------------------------------------------
# GitHub Actions Deploy Metrics and Deploy GitOps Workflow Fixtures
# ---------------------------------------------------------------------------

METRICS_WORKFLOW_YAML_PATH = os.path.join(
    PROJECT_ROOT, ".github", "workflows", "deploy-vks-metrics.yml"
)

ARGOCD_WORKFLOW_YAML_PATH = os.path.join(
    PROJECT_ROOT, ".github", "workflows", "deploy-argocd.yml"
)

TRIGGER_METRICS_SCRIPT_PATH = os.path.join(
    PROJECT_ROOT, "scripts", "trigger-deploy-metrics.sh"
)

TRIGGER_ARGOCD_SCRIPT_PATH = os.path.join(
    PROJECT_ROOT, "scripts", "trigger-deploy-argocd.sh"
)


@pytest.fixture(scope="session")
def metrics_workflow_yaml_text() -> str:
    """Return the raw text of .github/workflows/deploy-vks-metrics.yml."""
    with open(METRICS_WORKFLOW_YAML_PATH, encoding="utf-8") as f:
        return f.read()


@pytest.fixture(scope="session")
def metrics_workflow_yaml(metrics_workflow_yaml_text: str) -> dict:
    """Return the parsed YAML dict of deploy-vks-metrics.yml."""
    return yaml.safe_load(metrics_workflow_yaml_text)


@pytest.fixture(scope="session")
def argocd_workflow_yaml_text() -> str:
    """Return the raw text of .github/workflows/deploy-argocd.yml."""
    with open(ARGOCD_WORKFLOW_YAML_PATH, encoding="utf-8") as f:
        return f.read()


@pytest.fixture(scope="session")
def argocd_workflow_yaml(argocd_workflow_yaml_text: str) -> dict:
    """Return the parsed YAML dict of deploy-argocd.yml."""
    return yaml.safe_load(argocd_workflow_yaml_text)


@pytest.fixture(scope="session")
def trigger_metrics_script_text() -> str:
    """Return the raw text of scripts/trigger-deploy-metrics.sh."""
    with open(TRIGGER_METRICS_SCRIPT_PATH, encoding="utf-8") as f:
        return f.read()


@pytest.fixture(scope="session")
def trigger_argocd_script_text() -> str:
    """Return the raw text of scripts/trigger-deploy-argocd.sh."""
    with open(TRIGGER_ARGOCD_SCRIPT_PATH, encoding="utf-8") as f:
        return f.read()


# ---------------------------------------------------------------------------
# Teardown Workflow Fixtures
# ---------------------------------------------------------------------------

TEARDOWN_WORKFLOW_YAML_PATH = os.path.join(
    PROJECT_ROOT, ".github", "workflows", "teardown.yml"
)

TRIGGER_TEARDOWN_SCRIPT_PATH = os.path.join(
    PROJECT_ROOT, "scripts", "trigger-teardown.sh"
)


@pytest.fixture(scope="session")
def teardown_workflow_yaml_text() -> str:
    """Return the raw text of .github/workflows/teardown.yml."""
    with open(TEARDOWN_WORKFLOW_YAML_PATH, encoding="utf-8") as f:
        return f.read()


@pytest.fixture(scope="session")
def teardown_workflow_yaml(teardown_workflow_yaml_text: str) -> dict:
    """Return the parsed YAML dict of the teardown workflow file."""
    return yaml.safe_load(teardown_workflow_yaml_text)


@pytest.fixture(scope="session")
def trigger_teardown_script_text() -> str:
    """Return the raw text of scripts/trigger-teardown.sh."""
    with open(TRIGGER_TEARDOWN_SCRIPT_PATH, encoding="utf-8") as f:
        return f.read()
