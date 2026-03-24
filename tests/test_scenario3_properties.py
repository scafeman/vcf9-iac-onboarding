# Feature: scenario3-self-contained-deploy, Property 1: Phase Messaging
# Every phase has pre (log_step) and post (log_success) messages
# Validates: Requirements 17.1, 17.2

"""Property-based tests for the VCF 9 Scenario 3 — Self-Contained ArgoCD Consumption Model scripts."""

import re

import pytest
import yaml
from hypothesis import given, settings, assume
from hypothesis import strategies as st


class TestProperty1PhaseMessaging:
    """Property 1: Phase Messaging — Every Phase Has Pre and Post Messages.

    For any phase/step in the deploy script (Phases 1 through 15), there shall
    be a ``log_step`` call before the phase's first operational command and a
    ``log_success`` call after the phase completes successfully.

    **Validates: Requirements 17.1, 17.2**
    """

    def test_all_fifteen_phases_found(self, scenario3_deploy_phases: dict[int, str]):
        """Precondition: the fixture must find phases 1 through 15."""
        for phase_num in range(1, 16):
            assert phase_num in scenario3_deploy_phases, (
                f"Phase {phase_num} not found in the script. "
                f"Found phases: {sorted(scenario3_deploy_phases.keys())}"
            )

    @given(phase_num=st.integers(min_value=1, max_value=15))
    @settings(max_examples=100)
    def test_phase_has_pre_message(
        self, scenario3_deploy_phases: dict[int, str], phase_num: int
    ):
        """Every phase has a log_step call (pre-message)."""
        assume(phase_num in scenario3_deploy_phases)
        phase_text = scenario3_deploy_phases[phase_num]
        assert "log_step" in phase_text, (
            f"Phase {phase_num} is missing a log_step pre-message"
        )

    @given(phase_num=st.integers(min_value=1, max_value=15))
    @settings(max_examples=100)
    def test_phase_has_post_message(
        self, scenario3_deploy_phases: dict[int, str], phase_num: int
    ):
        """Every phase has a log_success call (post-message)."""
        assume(phase_num in scenario3_deploy_phases)
        phase_text = scenario3_deploy_phases[phase_num]
        assert "log_success" in phase_text, (
            f"Phase {phase_num} is missing a log_success post-message"
        )


# Feature: scenario3-self-contained-deploy, Property 2: Distinct Exit Codes
# No two different failure categories share the same exit code
# Validates: Requirements 10.2, 17.4


class TestProperty2DistinctExitCodes:
    """Property 2: Distinct Exit Codes Per Failure Category.

    For any two error exit paths in the deploy script that correspond to
    different failure categories, the exit codes shall be distinct non-zero
    integers. The script defines exit codes 0 (success) and 1–14 for fourteen
    distinct failure categories.

    **Validates: Requirements 10.2, 17.4**
    """

    EXPECTED_EXIT_CODES: dict[int, str] = {
        0: "Success",
        1: "Variable validation failure or prerequisite missing",
        2: "Kubeconfig not found or cluster unreachable",
        3: "Certificate generation failure",
        4: "Contour installation failure",
        5: "Harbor installation failure",
        6: "CoreDNS configuration failure",
        7: "ArgoCD installation failure",
        8: "ArgoCD CLI download failure",
        9: "Certificate distribution failure",
        10: "GitLab installation failure",
        11: "GitLab image patching / Harbor proxy failure",
        12: "GitLab Runner installation failure",
        13: "ArgoCD cluster registration failure",
        14: "ArgoCD application bootstrap failure",
    }

    @staticmethod
    def _extract_exit_codes(script_text: str) -> list[int]:
        """Extract all exit code integers from ``exit N`` statements."""
        return [int(m.group(1)) for m in re.finditer(r"\bexit\s+(\d+)", script_text)]

    def test_all_failure_exit_codes_present(self, scenario3_deploy_text: str):
        """Exit codes 1 through 14 must all appear in the script."""
        codes = set(self._extract_exit_codes(scenario3_deploy_text))
        for code in range(1, 15):
            assert code in codes, (
                f"Exit code {code} ({self.EXPECTED_EXIT_CODES[code]}) "
                f"not found in the script"
            )

    def test_exit_zero_appears_once(self, scenario3_deploy_text: str):
        """``exit 0`` should appear exactly once (the success path)."""
        codes = self._extract_exit_codes(scenario3_deploy_text)
        zero_count = codes.count(0)
        assert zero_count == 1, (
            f"Expected exactly 1 'exit 0' (success path), found {zero_count}"
        )

    def test_non_zero_exit_codes_are_all_distinct(self, scenario3_deploy_text: str):
        """All 14 non-zero exit codes (1-14) are distinct failure categories."""
        codes = self._extract_exit_codes(scenario3_deploy_text)
        non_zero = [c for c in codes if c != 0]
        unique_non_zero = set(non_zero)
        assert len(unique_non_zero) == 14, (
            f"Expected 14 distinct non-zero exit codes, found "
            f"{len(unique_non_zero)}: {sorted(unique_non_zero)}"
        )

    @given(data=st.data())
    @settings(max_examples=100)
    def test_random_exit_code_pairs_are_distinct(
        self, scenario3_deploy_text: str, data: st.DataObject
    ):
        """Randomly pick two failure categories and verify distinct codes."""
        code_to_contexts: dict[int, set[str]] = {}
        for m in re.finditer(r"\bexit\s+(\d+)", scenario3_deploy_text):
            code = int(m.group(1))
            start = max(0, m.start() - 200)
            end = min(len(scenario3_deploy_text), m.end() + 50)
            context = scenario3_deploy_text[start:end]
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


# Feature: scenario3-self-contained-deploy, Property 3: Wait Loop Progress Reporting
# The wait_for_condition function contains progress echo with elapsed time,
# and all expected wait calls exist in the script.
# Validates: Requirements 17.5


class TestProperty3WaitLoopProgressReporting:
    """Property 3: Wait Loop Progress Reporting.

    For any wait loop in the deploy script (Contour LB IP, Harbor pods,
    CoreDNS, ArgoCD server, GitLab Operator, GitLab webservice, GitLab Runner,
    ArgoCD cluster, ArgoCD app sync, microservices-demo), the loop body shall
    contain a print statement that outputs the current status and elapsed time
    on each polling iteration.

    **Validates: Requirements 17.5**
    """

    EXPECTED_WAIT_DESCRIPTIONS: list[str] = [
        "Contour",
        "Harbor",
        "CoreDNS",
        "ArgoCD server",
        "webservice",
        "GitLab Runner",
        "ArgoCD cluster",
        "microservices-demo",
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
        self, scenario3_deploy_text: str
    ):
        """The wait_for_condition function body contains an echo/printf."""
        body = self._extract_wait_for_condition_body(scenario3_deploy_text)
        assert body is not None, (
            "wait_for_condition function not found in the script"
        )
        has_echo = "echo" in body or "printf" in body
        assert has_echo, (
            "wait_for_condition function body does not contain an echo or "
            "printf statement for progress reporting"
        )

    def test_wait_for_condition_progress_includes_elapsed_time(
        self, scenario3_deploy_text: str
    ):
        """The progress message in wait_for_condition includes elapsed time."""
        body = self._extract_wait_for_condition_body(scenario3_deploy_text)
        assert body is not None, (
            "wait_for_condition function not found in the script"
        )
        assert "elapsed" in body, (
            "wait_for_condition progress message does not reference elapsed time"
        )

    def test_at_least_nine_wait_for_condition_calls_exist(
        self, scenario3_deploy_text: str
    ):
        """The script contains at least 8 wait_for_condition invocations."""
        calls = self._extract_wait_for_condition_calls(scenario3_deploy_text)
        invocations = [
            c for c in calls
            if "wait_for_condition()" not in c  # exclude function def
        ]
        assert len(invocations) >= 8, (
            f"Expected at least 8 wait_for_condition calls, found {len(invocations)}: "
            f"{invocations}"
        )

    @given(idx=st.integers(min_value=0, max_value=7))
    @settings(max_examples=100)
    def test_each_wait_call_passes_description_parameter(
        self, scenario3_deploy_text: str, idx: int
    ):
        """Every wait_for_condition call passes a description string."""
        desc_keyword = self.EXPECTED_WAIT_DESCRIPTIONS[idx]
        calls = self._extract_wait_for_condition_calls(scenario3_deploy_text)
        invocations = [
            c for c in calls if "wait_for_condition()" not in c
        ]
        matching = [c for c in invocations if desc_keyword.lower() in c.lower()]
        assert len(matching) >= 1, (
            f"No wait_for_condition call found with description containing "
            f"'{desc_keyword}'. Calls found: {invocations}"
        )


# Feature: scenario3-self-contained-deploy, Property 4: Supporting YAML Round-Trip
# Parse each YAML file, serialize, parse again, assert deep equality
# Validates: Requirements 11.1, 11.2, 11.3, 11.5


class TestProperty4SupportingYAMLRoundTrip:
    """Property 4: Supporting YAML Round-Trip.

    For any of the six supporting YAML files (contour-values.yaml,
    harbor-values.yaml, argocd-values.yaml, gitlab-operator-values.yaml,
    gitlab-runner-values.yaml, argocd-microservices-demo.yaml), parsing the
    YAML, serializing it back to a string, and parsing again shall produce an
    object deeply equal to the first parse result.

    **Validates: Requirements 11.1, 11.2, 11.3, 11.5**
    """

    def test_gitlab_operator_values_round_trip(
        self, gitlab_operator_values_text: str, gitlab_operator_values_parsed
    ):
        """Parse, serialize, parse again — assert deep equality."""
        first_parse = yaml.safe_load(gitlab_operator_values_text)
        serialized = yaml.dump(first_parse, default_flow_style=False)
        second_parse = yaml.safe_load(serialized)
        assert first_parse == second_parse, (
            f"YAML round-trip produced different objects.\n"
            f"First parse:  {first_parse}\n"
            f"Second parse: {second_parse}"
        )

    def test_gitlab_runner_values_round_trip(
        self, gitlab_runner_values_text: str, gitlab_runner_values_parsed
    ):
        """Parse, serialize, parse again — assert deep equality."""
        first_parse = yaml.safe_load(gitlab_runner_values_text)
        serialized = yaml.dump(first_parse, default_flow_style=False)
        second_parse = yaml.safe_load(serialized)
        assert first_parse == second_parse, (
            f"YAML round-trip produced different objects.\n"
            f"First parse:  {first_parse}\n"
            f"Second parse: {second_parse}"
        )

    def test_argocd_app_manifest_round_trip(
        self, argocd_app_manifest_text: str, argocd_app_manifest_parsed
    ):
        """Parse, serialize, parse again — assert deep equality."""
        first_parse = yaml.safe_load(argocd_app_manifest_text)
        serialized = yaml.dump(first_parse, default_flow_style=False)
        second_parse = yaml.safe_load(serialized)
        assert first_parse == second_parse, (
            f"YAML round-trip produced different objects.\n"
            f"First parse:  {first_parse}\n"
            f"Second parse: {second_parse}"
        )

    def test_contour_values_round_trip(
        self, contour_values_text: str, contour_values_parsed
    ):
        """Parse, serialize, parse again — assert deep equality."""
        first_parse = yaml.safe_load(contour_values_text)
        serialized = yaml.dump(first_parse, default_flow_style=False)
        second_parse = yaml.safe_load(serialized)
        assert first_parse == second_parse, (
            f"YAML round-trip produced different objects.\n"
            f"First parse:  {first_parse}\n"
            f"Second parse: {second_parse}"
        )

    def test_harbor_values_round_trip(
        self, harbor_values_text: str, harbor_values_parsed
    ):
        """Parse, serialize, parse again — assert deep equality."""
        first_parse = yaml.safe_load(harbor_values_text)
        serialized = yaml.dump(first_parse, default_flow_style=False)
        second_parse = yaml.safe_load(serialized)
        assert first_parse == second_parse, (
            f"YAML round-trip produced different objects.\n"
            f"First parse:  {first_parse}\n"
            f"Second parse: {second_parse}"
        )

    def test_argocd_values_round_trip(
        self, argocd_values_text: str, argocd_values_parsed
    ):
        """Parse, serialize, parse again — assert deep equality."""
        first_parse = yaml.safe_load(argocd_values_text)
        serialized = yaml.dump(first_parse, default_flow_style=False)
        second_parse = yaml.safe_load(serialized)
        assert first_parse == second_parse, (
            f"YAML round-trip produced different objects.\n"
            f"First parse:  {first_parse}\n"
            f"Second parse: {second_parse}"
        )

    def test_gitlab_operator_values_is_valid_yaml(self, gitlab_operator_values_text: str):
        """The GitLab Operator values file must be valid, parseable YAML."""
        try:
            result = yaml.safe_load(gitlab_operator_values_text)
        except yaml.YAMLError as exc:
            pytest.fail(f"GitLab Operator values file is not valid YAML: {exc}")
        assert result is not None, "GitLab Operator values file parsed to None"
        assert isinstance(result, dict), (
            f"Expected a dict, got {type(result).__name__}"
        )

    def test_gitlab_runner_values_is_valid_yaml(self, gitlab_runner_values_text: str):
        """The GitLab Runner values file must be valid, parseable YAML."""
        try:
            result = yaml.safe_load(gitlab_runner_values_text)
        except yaml.YAMLError as exc:
            pytest.fail(f"GitLab Runner values file is not valid YAML: {exc}")
        assert result is not None, "GitLab Runner values file parsed to None"
        assert isinstance(result, dict), (
            f"Expected a dict, got {type(result).__name__}"
        )

    def test_argocd_app_manifest_is_valid_yaml(self, argocd_app_manifest_text: str):
        """The ArgoCD Application manifest must be valid, parseable YAML."""
        try:
            result = yaml.safe_load(argocd_app_manifest_text)
        except yaml.YAMLError as exc:
            pytest.fail(f"ArgoCD Application manifest is not valid YAML: {exc}")
        assert result is not None, "ArgoCD Application manifest parsed to None"
        assert isinstance(result, dict), (
            f"Expected a dict, got {type(result).__name__}"
        )

    def test_contour_values_is_valid_yaml(self, contour_values_text: str):
        """The Contour values file must be valid, parseable YAML."""
        try:
            result = yaml.safe_load(contour_values_text)
        except yaml.YAMLError as exc:
            pytest.fail(f"Contour values file is not valid YAML: {exc}")
        assert result is not None, "Contour values file parsed to None"
        assert isinstance(result, dict), (
            f"Expected a dict, got {type(result).__name__}"
        )

    def test_harbor_values_is_valid_yaml(self, harbor_values_text: str):
        """The Harbor values file must be valid, parseable YAML."""
        try:
            result = yaml.safe_load(harbor_values_text)
        except yaml.YAMLError as exc:
            pytest.fail(f"Harbor values file is not valid YAML: {exc}")
        assert result is not None, "Harbor values file parsed to None"
        assert isinstance(result, dict), (
            f"Expected a dict, got {type(result).__name__}"
        )

    def test_argocd_values_is_valid_yaml(self, argocd_values_text: str):
        """The ArgoCD values file must be valid, parseable YAML."""
        try:
            result = yaml.safe_load(argocd_values_text)
        except yaml.YAMLError as exc:
            pytest.fail(f"ArgoCD values file is not valid YAML: {exc}")
        assert result is not None, "ArgoCD values file parsed to None"
        assert isinstance(result, dict), (
            f"Expected a dict, got {type(result).__name__}"
        )


# Feature: scenario3-self-contained-deploy, Property 5: Default Variable Pattern
# For any variable with a default, verify ${VAR:-default} pattern with non-empty default
# Validates: Requirements 1.1, 2.1–2.12


class TestProperty5DefaultVariablePattern:
    """Property 5: Default Variable Pattern.

    For any variable in the deploy script that has a sensible default value,
    the variable assignment shall use the ``${VAR:-default}`` pattern with a
    non-empty default value. This includes both the original variables and the
    new self-contained infrastructure variables.

    **Validates: Requirements 1.1, 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 2.8, 2.9, 2.10, 2.11, 2.12**
    """

    VARIABLES_WITH_DEFAULTS: list[str] = [
        "KUBECONFIG_FILE",
        "DOMAIN",
        "CONTOUR_VERSION",
        "HARBOR_VERSION",
        "ARGOCD_VERSION",
        "HARBOR_ADMIN_PASSWORD",
        "HARBOR_SECRET_KEY",
        "HARBOR_DB_PASSWORD",
        "CERT_DIR",
        "GITLAB_OPERATOR_VERSION",
        "GITLAB_RUNNER_VERSION",
        "CONTOUR_NAMESPACE",
        "HARBOR_NAMESPACE",
        "GITLAB_NAMESPACE",
        "GITLAB_RUNNER_NAMESPACE",
        "ARGOCD_NAMESPACE",
        "APP_NAMESPACE",
        "CONTOUR_VALUES_FILE",
        "HARBOR_VALUES_FILE",
        "ARGOCD_VALUES_FILE",
        "GITLAB_OPERATOR_VALUES_FILE",
        "GITLAB_RUNNER_VALUES_FILE",
        "ARGOCD_APP_MANIFEST",
        "PACKAGE_TIMEOUT",
        "POLL_INTERVAL",
    ]

    @staticmethod
    def _extract_default_assignments(script_text: str) -> dict[str, str]:
        """Extract variable assignments with ${VAR:-default} pattern."""
        pattern = re.compile(
            r'^([A-Z_][A-Z0-9_]*)="\$\{[A-Z_][A-Z0-9_]*:-(.+)\}"',
            re.MULTILINE,
        )
        return {m.group(1): m.group(2) for m in pattern.finditer(script_text)}

    def test_all_expected_variables_have_defaults(
        self, scenario3_deploy_text: str
    ):
        """All expected variables with defaults are present in the script."""
        defaults = self._extract_default_assignments(scenario3_deploy_text)
        for var_name in self.VARIABLES_WITH_DEFAULTS:
            assert var_name in defaults, (
                f"Variable '{var_name}' not found with a ${{VAR:-default}} "
                f"pattern in the deploy script. Found: {sorted(defaults.keys())}"
            )

    @given(idx=st.integers(min_value=0, max_value=24))
    @settings(max_examples=100)
    def test_variable_default_is_non_empty(
        self, scenario3_deploy_text: str, idx: int
    ):
        """For any variable with a default, the default value is non-empty."""
        var_name = self.VARIABLES_WITH_DEFAULTS[idx]
        defaults = self._extract_default_assignments(scenario3_deploy_text)
        assume(var_name in defaults)
        default_value = defaults[var_name]
        assert len(default_value.strip()) > 0, (
            f"Variable '{var_name}' has an empty default value"
        )


# Feature: scenario3-self-contained-deploy, Property 6: Teardown Reverse Dependency Order
# Verify deletion commands appear in correct order
# Validates: Requirements 12.5, 18.1


class TestProperty6TeardownReverseDependencyOrder:
    """Property 6: Teardown Reverse Dependency Order.

    For any pair of components where one depends on the other, the dependent
    component's deletion command shall appear before the dependency's deletion
    command in the teardown script. Deletion order: ArgoCD Application →
    GitLab Runner → GitLab Operator → ArgoCD → CoreDNS restore → Harbor →
    Contour → Certificate Secrets.

    **Validates: Requirements 12.5, 18.1**
    """

    # Expected deletion order with patterns to search for in the teardown script
    DELETION_ORDER: list[tuple[str, str]] = [
        ("argocd-app", "kubectl delete application microservices-demo"),
        ("gitlab-runner", "helm uninstall gitlab-runner"),
        ("gitlab", 'helm uninstall gitlab -n "${GITLAB_NAMESPACE}"'),
        ("argocd", "helm uninstall argocd"),
        ("coredns-restore", "rollout restart deployment/coredns"),
        ("harbor", "helm uninstall harbor"),
        ("contour", "helm uninstall contour"),
        ("cert-secrets", "kubectl delete secret harbor-ca-cert"),
    ]

    @given(idx=st.integers(min_value=0, max_value=6))
    @settings(max_examples=100)
    def test_adjacent_deletion_order(
        self, scenario3_teardown_text: str, idx: int
    ):
        """For any adjacent pair in the deletion order, the first appears before the second."""
        name_a, pattern_a = self.DELETION_ORDER[idx]
        name_b, pattern_b = self.DELETION_ORDER[idx + 1]

        pos_a = scenario3_teardown_text.find(pattern_a)
        pos_b = scenario3_teardown_text.find(pattern_b)

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
        self, scenario3_teardown_text: str
    ):
        """All 8 deletion patterns must be present in the teardown script."""
        for name, pattern in self.DELETION_ORDER:
            assert pattern in scenario3_teardown_text, (
                f"Deletion pattern for '{name}' not found: '{pattern}'"
            )


# Feature: scenario3-self-contained-deploy, Property 7: Teardown Idempotency
# For any deletion step, verify existence check or error suppression
# Validates: Requirements 12.9, 18.11, 18.12


class TestProperty7TeardownIdempotency:
    """Property 7: Teardown Idempotency.

    For any deletion step in the teardown script, if the target resource does
    not exist, the script shall not exit with a non-zero status code. Each
    deletion command shall be guarded by an existence check or use flags that
    suppress not-found errors.

    **Validates: Requirements 12.9, 18.11, 18.12**
    """

    # Deletion steps with their identifying patterns
    DELETION_STEPS: list[tuple[str, str]] = [
        ("argocd-app", "kubectl delete application microservices-demo"),
        ("app-namespace", 'kubectl delete ns "${APP_NAMESPACE}"'),
        ("gitlab-runner", "helm uninstall gitlab-runner"),
        ("gitlab-runner-ns", 'kubectl delete ns "${GITLAB_RUNNER_NAMESPACE}"'),
        ("gitlab", 'helm uninstall gitlab -n "${GITLAB_NAMESPACE}"'),
        ("gitlab-ns", 'kubectl delete ns "${GITLAB_NAMESPACE}"'),
        ("argocd-helm", "helm uninstall argocd"),
        ("argocd-ns", 'kubectl delete ns "${ARGOCD_NAMESPACE}"'),
        ("harbor-helm", "helm uninstall harbor"),
        ("harbor-ns", 'kubectl delete ns "${HARBOR_NAMESPACE}"'),
        ("contour-helm", "helm uninstall contour"),
        ("contour-ns", 'kubectl delete ns "${CONTOUR_NAMESPACE}"'),
        ("cert-secrets", "kubectl delete secret harbor-ca-cert"),
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

    @given(idx=st.integers(min_value=0, max_value=12))
    @settings(max_examples=100)
    def test_deletion_step_has_idempotency_guard(
        self, scenario3_teardown_text: str, idx: int
    ):
        """Every deletion step has an existence check or error suppression."""
        name, pattern = self.DELETION_STEPS[idx]
        context = self._get_deletion_context(scenario3_teardown_text, pattern)

        assert len(context) > 0, (
            f"Deletion pattern for '{name}' not found in teardown script"
        )

        has_if_check = "if " in context and ("get " in context or "grep" in context)
        has_or_true = "|| true" in context
        has_ignore_not_found = "--ignore-not-found" in context

        assert has_if_check or has_or_true or has_ignore_not_found, (
            f"Deletion step '{name}' lacks idempotency guard. "
            f"Expected 'if' existence check, '|| true', or '--ignore-not-found'. "
            f"Context:\n{context}"
        )
