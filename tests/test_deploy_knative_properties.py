"""Structural property tests for VCF 9 Deploy Knative deploy script.

These tests parse the deploy script, teardown script, and workflow YAML to
verify that universal invariants hold across all phases, exit codes, variables,
teardown ordering, and workflow correspondence.  They are NOT Hypothesis-based;
they use regular pytest to verify structural properties of the scripts.
"""

import re
from collections import Counter


# ===================================================================
# Property 1: Phase Messaging — Every Phase Has Pre and Post Messages
# Feature: deploy-knative, Property 1: Phase Messaging
# Validates: Requirements 9.5, 14.2
# ===================================================================


class TestPhaseMessaging:
    """For phases 1-9 in the deploy script, verify each phase has a
    log_step call within that phase's section."""

    EXPECTED_PHASES = list(range(1, 10))  # Phases 1 through 9

    def _find_log_step_phases(self, text: str) -> set[int]:
        """Extract all phase numbers referenced in log_step calls."""
        # Matches: log_step 1 "..." or log_step 2 "..."
        pattern = r'log_step\s+(\d+)\s+'
        return {int(m.group(1)) for m in re.finditer(pattern, text)}

    def test_log_step_calls_exist(self, knative_deploy_text):
        """The deploy script must contain at least one log_step call."""
        phases = self._find_log_step_phases(knative_deploy_text)
        assert len(phases) >= 1, "No log_step calls found in deploy script"

    def test_all_phases_have_log_step(self, knative_deploy_text):
        """Every phase 1-9 must have a corresponding log_step call."""
        found_phases = self._find_log_step_phases(knative_deploy_text)
        for phase in self.EXPECTED_PHASES:
            assert phase in found_phases, (
                f"Phase {phase} is missing a log_step call. "
                f"Found log_step calls for phases: {sorted(found_phases)}"
            )

    def test_phases_cover_exactly_1_through_9(self, knative_deploy_text):
        """The set of log_step phase numbers should cover 1-9."""
        found_phases = self._find_log_step_phases(knative_deploy_text)
        expected = set(self.EXPECTED_PHASES)
        assert expected.issubset(found_phases), (
            f"Missing phases: {expected - found_phases}. Found: {sorted(found_phases)}"
        )



# ===================================================================
# Property 2: Distinct Exit Codes Per Failure Category
# Feature: deploy-knative, Property 2: Distinct Exit Codes
# Validates: Requirements 9.8, 14.4
# ===================================================================


class TestDistinctExitCodes:
    """Verify exit codes 1-7 are all distinct and present in the deploy
    script, and that exit 0 appears for success."""

    def _extract_exit_codes(self, text: str) -> list[int]:
        """Extract all exit codes from the script."""
        return [int(m.group(1)) for m in re.finditer(r'\bexit\s+(\d+)', text)]

    def test_nonzero_exit_codes_exist(self, knative_deploy_text):
        """The script must contain at least one non-zero exit code."""
        codes = [c for c in self._extract_exit_codes(knative_deploy_text) if c != 0]
        assert len(codes) > 0, "No non-zero exit codes found in deploy script"

    def test_exit_codes_cover_all_failure_categories(self, knative_deploy_text):
        """Exit codes 1-7 must all be present, covering all failure categories."""
        codes = set(self._extract_exit_codes(knative_deploy_text))
        expected = {1, 2, 3, 4, 5, 6, 7}
        assert expected.issubset(codes), (
            f"Missing exit codes for failure categories: {expected - codes}. "
            f"Found: {sorted(codes)}"
        )

    def test_exit_codes_1_through_7_are_distinct(self, knative_deploy_text):
        """Exit codes 1-7 must all be distinct values (no two failure
        categories share the same code)."""
        codes = set(self._extract_exit_codes(knative_deploy_text))
        expected = {1, 2, 3, 4, 5, 6, 7}
        # All 7 distinct codes must be present
        assert expected.issubset(codes), (
            f"Expected all distinct exit codes 1-7, found: {sorted(codes)}"
        )

    def test_exit_zero_present(self, knative_deploy_text):
        """The script must contain exit 0 for success."""
        codes = self._extract_exit_codes(knative_deploy_text)
        assert 0 in codes, "exit 0 not found in deploy script"

    def test_final_exit_is_zero(self, knative_deploy_text):
        """The script must end with exit 0 for success."""
        exits = list(re.finditer(r'\bexit\s+(\d+)', knative_deploy_text))
        assert exits, "No exit statements found"
        last_exit_code = int(exits[-1].group(1))
        assert last_exit_code == 0, (
            f"Last exit code should be 0 (success), got {last_exit_code}"
        )


# ===================================================================
# Property 3: Default Variable Pattern
# Feature: deploy-knative, Property 3: Default Variable Pattern
# Validates: Requirements 9.2
# ===================================================================


class TestDefaultVariablePattern:
    """For variables with defaults, verify they use the ${VAR:-default}
    pattern with a non-empty default value."""

    # Variables that must have non-empty defaults per the design doc
    VARIABLES_WITH_DEFAULTS = [
        "KNATIVE_SERVING_VERSION",
        "NET_CONTOUR_VERSION",
        "KNATIVE_NAMESPACE",
        "DEMO_NAMESPACE",
        "CONTAINER_REGISTRY",
        "IMAGE_TAG",
        "SCALE_TO_ZERO_GRACE_PERIOD",
        "KNATIVE_TIMEOUT",
        "POD_TIMEOUT",
        "LB_TIMEOUT",
        "POLL_INTERVAL",
    ]

    def _extract_default_assignments(self, text: str) -> dict[str, str]:
        """Extract VAR="${VAR:-default}" assignments and return {var: default}."""
        pattern = r'^(\w+)="\$\{\1:-([^}]+)\}"'
        return {m.group(1): m.group(2) for m in re.finditer(pattern, text, re.MULTILINE)}

    def test_variables_with_defaults_exist(self, knative_deploy_text):
        """At least one variable with a default must be found."""
        assignments = self._extract_default_assignments(knative_deploy_text)
        assert len(assignments) > 0, "No VAR=\"${VAR:-default}\" assignments found"

    def test_each_expected_variable_has_default_pattern(self, knative_deploy_text):
        """Each variable in the expected list must use ${VAR:-default} pattern."""
        assignments = self._extract_default_assignments(knative_deploy_text)
        for var in self.VARIABLES_WITH_DEFAULTS:
            assert var in assignments, (
                f"Variable '{var}' missing ${{{var}:-default}} pattern. "
                f"Found variables: {sorted(assignments.keys())}"
            )

    def test_defaults_are_non_empty(self, knative_deploy_text):
        """Each variable's default value must be non-empty."""
        assignments = self._extract_default_assignments(knative_deploy_text)
        for var in self.VARIABLES_WITH_DEFAULTS:
            if var in assignments:
                assert assignments[var].strip() != "", (
                    f"Variable '{var}' has an empty default value"
                )


# ===================================================================
# Property 4: Variable Declaration Completeness
# Feature: deploy-knative, Property 4: Variable Declaration Completeness
# Validates: Requirements 9.4, 14.3
# ===================================================================


class TestVariableDeclarationCompleteness:
    """Every variable in validate_variables required_vars array has a
    corresponding VAR= declaration in the variable block."""

    def _extract_validated_variables(self, text: str) -> list[str]:
        """Extract variable names from the validate_variables function's
        required_vars array."""
        func_match = re.search(
            r'validate_variables\(\)\s*\{(.*?)\n\}',
            text,
            re.DOTALL,
        )
        assert func_match, "validate_variables function not found in script"
        func_body = func_match.group(1)
        return re.findall(r'"(\w+)"', func_body)

    def _extract_variable_block_assignments(self, text: str) -> dict[str, str]:
        """Extract VAR="${VAR:-...}" or VAR="${VAR:-}" assignments.
        Handles nested ${...} references in default values."""
        pattern = r'^(\w+)="\$\{\1:-(.*)\}"'
        results = {}
        for m in re.finditer(pattern, text, re.MULTILINE):
            results[m.group(1)] = m.group(2)
        return results

    def test_validated_variables_exist(self, knative_deploy_text):
        """At least one variable must be listed in validate_variables."""
        vars_list = self._extract_validated_variables(knative_deploy_text)
        assert len(vars_list) > 0, "No variables found in validate_variables"

    def test_each_validated_variable_has_declaration(self, knative_deploy_text):
        """Every variable in validate_variables must have a VAR= declaration
        in the variable block."""
        validated_vars = self._extract_validated_variables(knative_deploy_text)
        block_assignments = self._extract_variable_block_assignments(knative_deploy_text)

        for var in validated_vars:
            assert var in block_assignments, (
                f"Required variable '{var}' from validate_variables is missing "
                f"a declaration (VAR=\"${{VAR:-...}}\") in the variable block"
            )

    def test_declaration_pattern_is_correct(self, knative_deploy_text):
        """Each validated variable's assignment must use the exact
        VAR="${VAR:-...}" pattern."""
        validated_vars = self._extract_validated_variables(knative_deploy_text)

        for var in validated_vars:
            # Use a greedy pattern to handle nested ${...} in defaults
            pattern = rf'^{re.escape(var)}="\$\{{{re.escape(var)}:-.*\}}"'
            assert re.search(pattern, knative_deploy_text, re.MULTILINE), (
                f"Variable '{var}' does not use the expected "
                f'{var}="${{{var}:-...}}" default assignment pattern'
            )



# ===================================================================
# Property 5: Teardown Reverse Dependency Order
# Feature: deploy-knative, Property 5: Teardown Reverse Dependency Order
# Validates: Requirements 10.2, 14.5
# ===================================================================


class TestTeardownReverseDependencyOrder:
    """Verify the teardown script deletes in order: knative-demo namespace
    resources before net-contour, net-contour before knative-serving,
    knative-serving before CRDs."""

    # Ordered markers — each must appear before the next in the teardown script
    ORDERED_MARKERS = [
        ("knative-demo resources", r'asset-audit'),
        ("net-contour resources", r'net-contour'),
        ("knative-serving core", r'knative-serving.*core|serving-core|Knative Core'),
        ("knative CRDs", r'serving-crds|Knative CRDs|Knative Serving CRDs'),
    ]

    def _find_first_position(self, text: str, pattern: str) -> int:
        """Find the position of the first match for a pattern."""
        match = re.search(pattern, text, re.IGNORECASE)
        return match.start() if match else -1

    def test_all_teardown_markers_present(self, knative_teardown_text):
        """All expected teardown resource markers must be present."""
        for name, pattern in self.ORDERED_MARKERS:
            pos = self._find_first_position(knative_teardown_text, pattern)
            assert pos >= 0, (
                f"Teardown marker for '{name}' (pattern: {pattern}) not found"
            )

    def test_teardown_order_is_correct(self, knative_teardown_text):
        """Resources must be deleted in reverse dependency order:
        knative-demo → net-contour → knative-serving → CRDs."""
        positions = []
        for name, pattern in self.ORDERED_MARKERS:
            pos = self._find_first_position(knative_teardown_text, pattern)
            assert pos >= 0, f"Teardown marker for '{name}' not found"
            positions.append((name, pos))

        for i in range(len(positions) - 1):
            curr_name, curr_pos = positions[i]
            next_name, next_pos = positions[i + 1]
            assert curr_pos < next_pos, (
                f"Teardown order violation: '{curr_name}' (pos {curr_pos}) "
                f"must appear before '{next_name}' (pos {next_pos})"
            )


# ===================================================================
# Property 6: Teardown Idempotency
# Feature: deploy-knative, Property 6: Teardown Idempotency
# Validates: Requirements 10.3
# ===================================================================


class TestTeardownIdempotency:
    """Every kubectl delete command in the teardown script has
    --ignore-not-found, an existence check, or || true."""

    def _extract_kubectl_delete_lines(self, text: str) -> list[tuple[int, str]]:
        """Extract (line_number, line_text) for all kubectl delete commands."""
        results = []
        for i, line in enumerate(text.splitlines()):
            stripped = line.strip()
            if re.search(r'kubectl\s+delete\b', stripped) and not stripped.startswith('#'):
                results.append((i + 1, stripped))
        return results

    def _is_guarded(self, line: str, line_num: int, text: str) -> bool:
        """Check if a kubectl delete line is guarded by --ignore-not-found,
        || true, or is inside an existence check (if block)."""
        if '--ignore-not-found' in line:
            return True
        if '|| true' in line:
            return True
        # Check if the line is inside an if/then block (existence check)
        lines = text.splitlines()
        # Look back up to 10 lines for an if/then guard
        start = max(0, line_num - 11)
        context_before = '\n'.join(lines[start:line_num - 1])
        if re.search(r'if\s+kubectl\s+get\b', context_before):
            return True
        return False

    def test_kubectl_delete_commands_exist(self, knative_teardown_text):
        """The teardown script must contain kubectl delete commands."""
        deletes = self._extract_kubectl_delete_lines(knative_teardown_text)
        assert len(deletes) > 0, "No kubectl delete commands found in teardown script"

    def test_all_deletes_are_guarded(self, knative_teardown_text):
        """Every kubectl delete command must be guarded for idempotency."""
        deletes = self._extract_kubectl_delete_lines(knative_teardown_text)
        unguarded = []
        for line_num, line in deletes:
            if not self._is_guarded(line, line_num, knative_teardown_text):
                unguarded.append((line_num, line))

        assert len(unguarded) == 0, (
            f"Found {len(unguarded)} unguarded kubectl delete command(s):\n"
            + "\n".join(f"  Line {ln}: {l}" for ln, l in unguarded)
        )


# ===================================================================
# Property 7: Workflow-Phase Correspondence
# Feature: deploy-knative, Property 7: Workflow-Phase Correspondence
# Validates: Requirements 12.6, 14.6
# ===================================================================


class TestWorkflowPhaseCorrespondence:
    """The workflow has named steps that correspond to the deploy script
    phases 1-9."""

    # Mapping of deploy script phase numbers to expected workflow step
    # name keywords (case-insensitive substring match)
    PHASE_TO_STEP_KEYWORDS = {
        1: ["kubeconfig", "setup kubeconfig"],
        2: ["crd", "knative crd"],
        3: ["core", "knative core"],
        4: ["contour", "net-contour"],
        5: ["ingress", "configure ingress"],
        6: ["dns", "configure dns"],
        7: ["audit", "audit function"],
        8: ["dashboard", "deploy dashboard"],
        9: ["verif", "verify"],
    }

    def _extract_workflow_step_names(self, text: str) -> list[str]:
        """Extract all step names from the workflow YAML text."""
        # Match: - name: <step name>
        pattern = r'^\s*-\s+name:\s+(.+)$'
        return [m.group(1).strip() for m in re.finditer(pattern, text, re.MULTILINE)]

    def test_workflow_has_steps(self, knative_workflow_yaml_text):
        """The workflow must contain named steps."""
        steps = self._extract_workflow_step_names(knative_workflow_yaml_text)
        assert len(steps) > 0, "No named steps found in workflow YAML"

    def test_each_phase_has_corresponding_step(self, knative_workflow_yaml_text):
        """Every deploy script phase (1-9) must have a corresponding named
        step in the workflow."""
        step_names = self._extract_workflow_step_names(knative_workflow_yaml_text)
        step_names_lower = [s.lower() for s in step_names]

        for phase, keywords in self.PHASE_TO_STEP_KEYWORDS.items():
            found = False
            for keyword in keywords:
                for step_name in step_names_lower:
                    if keyword.lower() in step_name:
                        found = True
                        break
                if found:
                    break
            assert found, (
                f"Phase {phase} has no corresponding workflow step. "
                f"Looked for keywords {keywords} in steps: {step_names}"
            )
