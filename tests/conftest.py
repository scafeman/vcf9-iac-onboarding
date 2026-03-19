"""Shared fixtures for VCF 9 IaC Onboarding Guide tests."""

import os
import re
import pytest

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
    os.path.dirname(__file__), "..", "examples", "scenario1-full-stack-deploy.sh"
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
