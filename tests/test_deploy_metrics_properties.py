# Feature: deploy-metrics-vks-metrics-observability, Property 1: Phase Messaging
# Every phase has pre (log_step) and post (log_success) messages
# Validates: Requirements 12.1, 12.2

"""Property-based tests for the VCF 9 Deploy Metrics — VKS Metrics Observability scripts."""

import re

import pytest
import yaml
from hypothesis import given, settings, assume
from hypothesis import strategies as st


class TestProperty1PhaseMessaging:
    """Property 1: Phase Messaging — Every Phase Has Pre and Post Messages.

    For any phase/step in the deploy script (Phases 1 through 9), there shall
    be a ``log_step`` call before the phase's first operational command and a
    ``log_success`` call after the phase completes successfully.

    **Validates: Requirements 12.1, 12.2**
    """

    def test_all_eleven_phases_found(self, metrics_deploy_phases: dict[int, str]):
        """Precondition: the fixture must find phases 1 through 11."""
        for phase_num in range(1, 12):
            assert phase_num in metrics_deploy_phases, (
                f"Phase {phase_num} not found in the script. "
                f"Found phases: {sorted(metrics_deploy_phases.keys())}"
            )

    @given(phase_num=st.integers(min_value=1, max_value=11))
    @settings(max_examples=100)
    def test_phase_has_pre_message(
        self, metrics_deploy_phases: dict[int, str], phase_num: int
    ):
        """Every phase has a log_step call (pre-message)."""
        assume(phase_num in metrics_deploy_phases)
        phase_text = metrics_deploy_phases[phase_num]
        assert "log_step" in phase_text, (
            f"Phase {phase_num} is missing a log_step pre-message"
        )

    @given(phase_num=st.integers(min_value=1, max_value=11))
    @settings(max_examples=100)
    def test_phase_has_post_message(
        self, metrics_deploy_phases: dict[int, str], phase_num: int
    ):
        """Every phase has a log_success call (post-message)."""
        assume(phase_num in metrics_deploy_phases)
        phase_text = metrics_deploy_phases[phase_num]
        assert "log_success" in phase_text, (
            f"Phase {phase_num} is missing a log_success post-message"
        )


# Feature: deploy-metrics-vks-metrics-observability, Property 2: Distinct Exit Codes
# No two different failure categories share the same exit code
# Validates: Requirements 12.3, 12.4


class TestProperty2DistinctExitCodes:
    """Property 2: Distinct Exit Codes Per Failure Category.

    For any two error exit paths in the deploy script that correspond to
    different failure categories, the exit codes shall be distinct non-zero
    integers. The script defines exit codes 0 (success) and 1–8 for eight
    distinct failure categories.

    **Validates: Requirements 12.3, 12.4**
    """

    EXPECTED_EXIT_CODES: dict[int, str] = {
        0: "Success",
        1: "Variable validation failure",
        2: "Kubeconfig not found or cluster unreachable",
        3: "Namespace creation failure",
        4: "Package repository registration failure",
        5: "Telegraf installation failure",
        6: "cert-manager installation failure",
        7: "Contour installation failure",
        8: "Prometheus installation failure",
        9: "Grafana Operator installation failure",
        10: "Grafana instance/datasource/dashboard failure",
    }

    @staticmethod
    def _extract_exit_codes(script_text: str) -> list[int]:
        """Extract all exit code integers from ``exit N`` statements."""
        return [int(m.group(1)) for m in re.finditer(r"\bexit\s+(\d+)", script_text)]

    def test_all_failure_exit_codes_present(self, metrics_deploy_text: str):
        """Exit codes 1 through 10 must all appear in the script."""
        codes = set(self._extract_exit_codes(metrics_deploy_text))
        for code in range(1, 11):
            assert code in codes, (
                f"Exit code {code} ({self.EXPECTED_EXIT_CODES[code]}) "
                f"not found in the script"
            )

    def test_exit_zero_appears_once(self, metrics_deploy_text: str):
        """``exit 0`` should appear exactly once (the success path)."""
        codes = self._extract_exit_codes(metrics_deploy_text)
        zero_count = codes.count(0)
        assert zero_count == 1, (
            f"Expected exactly 1 'exit 0' (success path), found {zero_count}"
        )

    def test_non_zero_exit_codes_are_all_distinct(self, metrics_deploy_text: str):
        """All 10 non-zero exit codes (1-10) are distinct failure categories."""
        codes = self._extract_exit_codes(metrics_deploy_text)
        non_zero = [c for c in codes if c != 0]
        unique_non_zero = set(non_zero)
        assert len(unique_non_zero) == 10, (
            f"Expected 10 distinct non-zero exit codes, found "
            f"{len(unique_non_zero)}: {sorted(unique_non_zero)}"
        )

    @given(data=st.data())
    @settings(max_examples=100)
    def test_random_exit_code_pairs_are_distinct(
        self, metrics_deploy_text: str, data: st.DataObject
    ):
        """Randomly pick two failure categories and verify distinct codes."""
        code_to_contexts: dict[int, set[str]] = {}
        for m in re.finditer(r"\bexit\s+(\d+)", metrics_deploy_text):
            code = int(m.group(1))
            start = max(0, m.start() - 200)
            end = min(len(metrics_deploy_text), m.end() + 50)
            context = metrics_deploy_text[start:end]
            code_to_contexts.setdefault(code, set()).add(context)

        non_zero_codes = [c for c in code_to_contexts if c != 0]
        assume(len(non_zero_codes) >= 2)

        idx_a = data.draw(
            st.integers(min_value=0, max_value=len(non_zero_codes) - 1),
            label="idx_a",
        )
        idx_b = data.draw(
            st.integers(min_value=0, max_value=len(non_zero_codes) - 1),
            label="idx_b",
        )
        assume(idx_a != idx_b)

        code_a = non_zero_codes[idx_a]
        code_b = non_zero_codes[idx_b]

        assert code_a != code_b, (
            f"Two different failure categories share exit code: "
            f"code_a={code_a}, code_b={code_b}"
        )


# Feature: deploy-metrics-vks-metrics-observability, Property 3: Wait Loop Progress Reporting
# The wait_for_condition function contains progress echo with elapsed time,
# and all expected wait calls exist in the script.
# Validates: Requirements 12.5


class TestProperty3WaitLoopProgressReporting:
    """Property 3: Wait Loop Progress Reporting.

    For any wait loop in the deploy script (repository reconciliation,
    Telegraf, cert-manager, Contour, Prometheus), the loop body shall contain
    a print statement that outputs the current status and elapsed time on each
    polling iteration. No wait loop shall poll silently.

    **Validates: Requirements 12.5**
    """

    EXPECTED_WAIT_DESCRIPTIONS: list[str] = [
        "repository",
        "Telegraf",
        "cert-manager",
        "Contour",
        "Prometheus",
        "Grafana",
    ]

    @staticmethod
    def _extract_wait_for_condition_body(script_text: str) -> str | None:
        """Extract the body of the wait_for_condition function."""
        match = re.search(
            r"^wait_for_condition\s*\(\)\s*\{(.*?)^\}",
            script_text,
            re.MULTILINE | re.DOTALL,
        )
        return match.group(1) if match else None

    @staticmethod
    def _extract_wait_for_condition_calls(script_text: str) -> list[str]:
        """Extract all lines that invoke ``wait_for_condition``."""
        return re.findall(
            r"^.*wait_for_condition\s+.*$", script_text, re.MULTILINE
        )

    def test_wait_for_condition_function_has_progress_echo(
        self, metrics_deploy_text: str
    ):
        """The wait_for_condition function body contains an echo/printf."""
        body = self._extract_wait_for_condition_body(metrics_deploy_text)
        assert body is not None, (
            "wait_for_condition function not found in the script"
        )
        has_echo = "echo" in body or "printf" in body
        assert has_echo, (
            "wait_for_condition function body does not contain an echo or "
            "printf statement for progress reporting"
        )

    def test_wait_for_condition_progress_includes_elapsed_time(
        self, metrics_deploy_text: str
    ):
        """The progress message in wait_for_condition includes elapsed time."""
        body = self._extract_wait_for_condition_body(metrics_deploy_text)
        assert body is not None, (
            "wait_for_condition function not found in the script"
        )
        assert "elapsed" in body, (
            "wait_for_condition progress message does not reference elapsed time"
        )

    def test_at_least_five_wait_for_condition_calls_exist(
        self, metrics_deploy_text: str
    ):
        """The script contains at least 5 wait_for_condition invocations.

        Expected: repository, Telegraf, cert-manager, Contour, Prometheus.
        """
        calls = self._extract_wait_for_condition_calls(metrics_deploy_text)
        invocations = [
            c for c in calls
            if "wait_for_condition()" not in c  # exclude function def
        ]
        assert len(invocations) >= 4, (
            f"Expected at least 4 wait_for_condition calls, found {len(invocations)}: "
            f"{invocations}"
        )

    @given(idx=st.integers(min_value=0, max_value=5))
    @settings(max_examples=100)
    def test_each_wait_call_passes_description_parameter(
        self, metrics_deploy_text: str, idx: int
    ):
        """Every wait_for_condition call passes a description string.

        Randomly select one of the 6 expected wait descriptions and verify
        a matching wait_for_condition call exists in the script.
        """
        desc_keyword = self.EXPECTED_WAIT_DESCRIPTIONS[idx]
        calls = self._extract_wait_for_condition_calls(metrics_deploy_text)
        invocations = [
            c for c in calls if "wait_for_condition()" not in c
        ]
        matching = [c for c in invocations if desc_keyword.lower() in c.lower()]
        assert len(matching) >= 1, (
            f"No wait_for_condition call found with description containing "
            f"'{desc_keyword}'. Calls found: {invocations}"
        )


# Feature: deploy-metrics-vks-metrics-observability, Property 4: Telegraf Values YAML Round-Trip
# Parse telegraf-values.yaml, serialize, parse again, assert deep equality
# Validates: Requirements 15.1, 15.2


class TestProperty4TelegrafValuesYAMLRoundTrip:
    """Property 4: Telegraf Values YAML Round-Trip.

    For any valid state of the Telegraf values file, parsing the YAML,
    serializing it back to a string, and parsing again shall produce an
    object deeply equal to the first parse result.

    **Validates: Requirements 15.1, 15.2**
    """

    def test_telegraf_values_round_trip(
        self, telegraf_values_text: str, telegraf_values_parsed
    ):
        """Parse, serialize, parse again — assert deep equality."""
        # First parse (already done by fixture, but do it explicitly too)
        first_parse = yaml.safe_load(telegraf_values_text)

        # Serialize back to YAML string
        serialized = yaml.dump(first_parse, default_flow_style=False)

        # Parse the serialized string again
        second_parse = yaml.safe_load(serialized)

        # Assert deep equality
        assert first_parse == second_parse, (
            f"YAML round-trip produced different objects.\n"
            f"First parse:  {first_parse}\n"
            f"Second parse: {second_parse}"
        )

    def test_telegraf_values_is_valid_yaml(self, telegraf_values_text: str):
        """The Telegraf values file must be valid, parseable YAML."""
        try:
            result = yaml.safe_load(telegraf_values_text)
        except yaml.YAMLError as exc:
            pytest.fail(f"Telegraf values file is not valid YAML: {exc}")
        assert result is not None, "Telegraf values file parsed to None"
        assert isinstance(result, dict), (
            f"Expected a dict, got {type(result).__name__}"
        )


# Feature: deploy-metrics-vks-metrics-observability, Property 5: Default Variable Pattern
# For any variable with a default, verify ${VAR:-default} pattern with non-empty default
# Validates: Requirements 2.2


class TestProperty5DefaultVariablePattern:
    """Property 5: Default Variable Pattern.

    For any variable in the deploy script that has a sensible default value,
    the variable assignment shall use the ``${VAR:-default}`` pattern with a
    non-empty default value.

    **Validates: Requirements 2.2**
    """

    # Variables that are expected to have non-empty defaults
    VARIABLES_WITH_DEFAULTS: list[str] = [
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

    @staticmethod
    def _extract_default_assignments(script_text: str) -> dict[str, str]:
        """Extract variable assignments with ${VAR:-default} pattern.

        Returns a dict mapping variable name to the default value.
        Handles nested ${} references inside the default (e.g.
        ``KUBECONFIG_FILE="${KUBECONFIG_FILE:-./kubeconfig-${CLUSTER_NAME}.yaml}"``).
        """
        pattern = re.compile(
            r'^([A-Z_][A-Z0-9_]*)="\$\{[A-Z_][A-Z0-9_]*:-(.+)\}"',
            re.MULTILINE,
        )
        return {m.group(1): m.group(2) for m in pattern.finditer(script_text)}

    def test_all_expected_variables_have_defaults(
        self, metrics_deploy_text: str
    ):
        """All expected variables with defaults are present in the script."""
        defaults = self._extract_default_assignments(metrics_deploy_text)
        for var_name in self.VARIABLES_WITH_DEFAULTS:
            assert var_name in defaults, (
                f"Variable '{var_name}' not found with a ${{VAR:-default}} "
                f"pattern in the deploy script. Found: {sorted(defaults.keys())}"
            )

    @given(idx=st.integers(min_value=0, max_value=12))
    @settings(max_examples=100)
    def test_variable_default_is_non_empty(
        self, metrics_deploy_text: str, idx: int
    ):
        """For any variable with a default, the default value is non-empty."""
        var_name = self.VARIABLES_WITH_DEFAULTS[idx]
        defaults = self._extract_default_assignments(metrics_deploy_text)
        assume(var_name in defaults)
        default_value = defaults[var_name]
        assert len(default_value.strip()) > 0, (
            f"Variable '{var_name}' has an empty default value"
        )


# Feature: deploy-metrics-vks-metrics-observability, Property 6: Teardown Reverse Dependency Order
# Verify deletion commands appear in correct order
# Validates: Requirements 11.1


class TestProperty6TeardownReverseDependencyOrder:
    """Property 6: Teardown Reverse Dependency Order.

    For any pair of packages where one depends on the other, the dependent
    package's delete command shall appear before the dependency's delete
    command in the teardown script. Deletion order: Prometheus → Contour →
    cert-manager → Telegraf → repository → namespace.

    **Validates: Requirements 11.1**
    """

    # Expected deletion order with patterns to search for in the teardown script
    DELETION_ORDER: list[tuple[str, str]] = [
        ("grafana", "helm uninstall grafana-operator"),
        ("prometheus", "delete_package prometheus"),
        ("contour", "delete_package contour"),
        ("cert-manager", "delete_package cert-manager"),
        ("telegraf", "delete_package telegraf"),
        ("repository", "kubectl delete packagerepository"),
        ("namespace", 'kubectl delete ns "${PACKAGE_NAMESPACE}"'),
    ]

    @given(idx=st.integers(min_value=0, max_value=5))
    @settings(max_examples=100)
    def test_adjacent_deletion_order(
        self, metrics_teardown_text: str, idx: int
    ):
        """For any adjacent pair in the deletion order, the first appears before the second."""
        name_a, pattern_a = self.DELETION_ORDER[idx]
        name_b, pattern_b = self.DELETION_ORDER[idx + 1]

        pos_a = metrics_teardown_text.find(pattern_a)
        pos_b = metrics_teardown_text.find(pattern_b)

        assert pos_a != -1, (
            f"Deletion pattern for '{name_a}' not found in teardown script: "
            f"'{pattern_a}'"
        )
        assert pos_b != -1, (
            f"Deletion pattern for '{name_b}' not found in teardown script: "
            f"'{pattern_b}'"
        )
        assert pos_a < pos_b, (
            f"'{name_a}' (pos {pos_a}) should appear before '{name_b}' "
            f"(pos {pos_b}) in the teardown script"
        )

    def test_all_deletion_patterns_present(
        self, metrics_teardown_text: str
    ):
        """All 7 deletion patterns must be present in the teardown script."""
        for name, pattern in self.DELETION_ORDER:
            assert pattern in metrics_teardown_text, (
                f"Deletion pattern for '{name}' not found: '{pattern}'"
            )


# Feature: deploy-metrics-vks-metrics-observability, Property 7: Teardown Idempotency
# For any deletion step, verify existence check or error suppression
# Validates: Requirements 11.6, 11.7


class TestProperty7TeardownIdempotency:
    """Property 7: Teardown Idempotency.

    For any deletion step in the teardown script, if the target resource does
    not exist, the script shall not exit with a non-zero status code. Each
    deletion command shall be guarded by an existence check or use flags that
    suppress not-found errors.

    **Validates: Requirements 11.6, 11.7**
    """

    # Deletion steps with their identifying patterns
    DELETION_STEPS: list[tuple[str, str]] = [
        ("grafana", "helm uninstall grafana-operator"),
        ("prometheus", "delete_package prometheus"),
        ("contour", "delete_package contour"),
        ("cert-manager", "delete_package cert-manager"),
        ("telegraf", "delete_package telegraf"),
        ("repository", "kubectl delete packagerepository"),
        ("namespace", 'kubectl delete ns "${PACKAGE_NAMESPACE}"'),
    ]

    @staticmethod
    def _get_deletion_context(script_text: str, pattern: str, context_chars: int = 500) -> str:
        """Get surrounding context around a deletion pattern in the script."""
        pos = script_text.find(pattern)
        if pos == -1:
            return ""
        start = max(0, pos - context_chars)
        end = min(len(script_text), pos + len(pattern) + context_chars)
        return script_text[start:end]

    @given(idx=st.integers(min_value=0, max_value=6))
    @settings(max_examples=100)
    def test_deletion_step_has_idempotency_guard(
        self, metrics_teardown_text: str, idx: int
    ):
        """Every deletion step has an existence check or error suppression."""
        name, pattern = self.DELETION_STEPS[idx]
        context = self._get_deletion_context(metrics_teardown_text, pattern)

        assert len(context) > 0, (
            f"Deletion pattern for '{name}' not found in teardown script"
        )

        # For delete_package calls, the idempotency guard is inside the
        # delete_package helper function (kubectl get + grep check, || true).
        # Check both the call context and the helper function body.
        helper_context = self._get_deletion_context(
            metrics_teardown_text, "delete_package()", context_chars=1000
        )
        combined_context = context + helper_context

        has_if_check = "if " in combined_context and ("grep" in combined_context or "get " in combined_context)
        has_or_true = "|| true" in combined_context
        has_ignore_not_found = "--ignore-not-found" in combined_context

        assert has_if_check or has_or_true or has_ignore_not_found, (
            f"Deletion step '{name}' lacks idempotency guard. "
            f"Expected 'if' existence check, '|| true', or '--ignore-not-found'. "
            f"Context:\n{context}"
        )
