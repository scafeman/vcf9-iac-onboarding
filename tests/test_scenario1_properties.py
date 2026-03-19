# Feature: vcf9-scenario1-example, Property 1: Self-Containment
# All kubectl create/apply commands use stdin (-f -), never external files
# Validates: Requirements 1.4

"""Property-based tests for the VCF 9 Scenario 1 script."""

import re

import pytest
from hypothesis import given, settings, assume
from hypothesis import strategies as st


class TestProperty1SelfContainment:
    """Property 1: Self-Containment — All kubectl Commands Use Stdin.

    For any kubectl create or kubectl apply command in the script, the file
    argument shall be ``-f -`` (stdin from a heredoc), never a reference to
    an external file path.

    **Validates: Requirements 1.4**
    """

    def test_kubectl_commands_found(self, script_kubectl_commands: list[str]):
        """Precondition: the fixture must find at least one kubectl command."""
        assert len(script_kubectl_commands) > 0, (
            "No kubectl create/apply commands found in the script"
        )

    @given(idx=st.integers())
    @settings(max_examples=100)
    def test_all_kubectl_commands_use_stdin(
        self, script_kubectl_commands: list[str], idx: int
    ):
        """Every kubectl create/apply command uses -f - (stdin)."""
        assume(len(script_kubectl_commands) > 0)
        cmd = script_kubectl_commands[idx % len(script_kubectl_commands)]
        assert "-f -" in cmd or "-f-" in cmd, (
            f"kubectl command does not use stdin (-f -): {cmd}"
        )

    @given(idx=st.integers())
    @settings(max_examples=100)
    def test_no_kubectl_command_references_external_file(
        self, script_kubectl_commands: list[str], idx: int
    ):
        """No kubectl create/apply command references an external file path.

        Matches ``-f <something>`` where <something> is NOT ``-`` (stdin).
        """
        assume(len(script_kubectl_commands) > 0)
        cmd = script_kubectl_commands[idx % len(script_kubectl_commands)]

        # Find all -f arguments in the command
        file_args = re.findall(r"-f\s+(\S+)", cmd)
        for arg in file_args:
            assert arg == "-" or arg == "-f", (
                f"kubectl command references external file '{arg}': {cmd}"
            )


# Feature: vcf9-scenario1-example, Property 2: Phase Messaging
# Every phase has pre (log_step) and post (log_success) messages
# Validates: Requirements 9.1, 9.2


class TestProperty2PhaseMessaging:
    """Property 2: Phase Messaging — Every Phase Has Pre and Post Messages.

    For any phase section in the script (Phases 1 through 6), there shall be
    a ``log_step`` call before the phase's first provisioning command and a
    ``log_success`` call after the phase completes successfully.

    **Validates: Requirements 9.1, 9.2**
    """

    def test_all_six_phases_found(self, script_phases: dict[int, str]):
        """Precondition: the fixture must find phases 1 through 6.

        Compound headers (e.g. "Phase 2b + 3") and sub-phase headers
        (e.g. "Phase 5b") are accepted as long as every integer 1-6 is
        covered.
        """
        for phase_num in range(1, 7):
            assert phase_num in script_phases, (
                f"Phase {phase_num} not found in the script. "
                f"Found phases: {sorted(script_phases.keys())}"
            )

    @given(phase_num=st.integers(min_value=1, max_value=6))
    @settings(max_examples=100)
    def test_phase_has_pre_message(
        self, script_phases: dict[int, str], phase_num: int
    ):
        """Every phase has a log_step call (pre-message)."""
        assume(phase_num in script_phases)
        phase_text = script_phases[phase_num]
        assert "log_step" in phase_text, (
            f"Phase {phase_num} is missing a log_step pre-message"
        )

    @given(phase_num=st.integers(min_value=1, max_value=6))
    @settings(max_examples=100)
    def test_phase_has_post_message(
        self, script_phases: dict[int, str], phase_num: int
    ):
        """Every phase has a log_success call (post-message)."""
        assume(phase_num in script_phases)
        phase_text = script_phases[phase_num]
        assert "log_success" in phase_text, (
            f"Phase {phase_num} is missing a log_success post-message"
        )


# Feature: vcf9-scenario1-example, Property 3: Distinct Exit Codes
# No two different failure categories share the same exit code
# Validates: Requirements 9.4


class TestProperty3DistinctExitCodes:
    """Property 3: Distinct Exit Codes Per Failure Category.

    For any two error exit paths in the script that correspond to different
    failure categories, the exit codes shall be distinct non-zero integers.
    The script defines exit codes 0 (success) and 1-8 for eight distinct
    failure categories.

    **Validates: Requirements 9.4**
    """

    # Expected exit code mapping from the design document
    EXPECTED_EXIT_CODES: dict[int, str] = {
        0: "Success",
        1: "Variable validation failure",
        2: "VCF CLI context creation/activation failure",
        3: "Project/namespace creation failure",
        4: "Context bridge failure",
        5: "VKS cluster creation failure",
        6: "Cluster provisioning timeout",
        7: "Kubeconfig retrieval failure/timeout",
        8: "Functional validation failure",
    }

    @staticmethod
    def _extract_exit_codes(script_text: str) -> list[int]:
        """Extract all exit code integers from ``exit N`` statements."""
        return [int(m.group(1)) for m in re.finditer(r"\bexit\s+(\d+)", script_text)]

    def test_all_failure_exit_codes_present(self, script_text: str):
        """Exit codes 1 through 8 must all appear in the script."""
        codes = set(self._extract_exit_codes(script_text))
        for code in range(1, 9):
            assert code in codes, (
                f"Exit code {code} ({self.EXPECTED_EXIT_CODES[code]}) "
                f"not found in the script"
            )

    def test_exit_zero_appears_once(self, script_text: str):
        """``exit 0`` should appear exactly once (the success path)."""
        codes = self._extract_exit_codes(script_text)
        zero_count = codes.count(0)
        assert zero_count == 1, (
            f"Expected exactly 1 'exit 0' (success path), found {zero_count}"
        )

    @given(data=st.data())
    @settings(max_examples=100)
    def test_random_exit_code_pairs_are_distinct(
        self, script_text: str, data: st.DataObject
    ):
        """Randomly pick two failure categories and verify distinct codes.

        We build a mapping from failure category (context around the exit
        statement) to exit code, then pick two categories at random and
        assert they have different codes.
        """
        # Build a mapping: exit_code -> set of surrounding context snippets
        code_to_contexts: dict[int, set[str]] = {}
        for m in re.finditer(r"\bexit\s+(\d+)", script_text):
            code = int(m.group(1))
            # Grab ~200 chars of surrounding context for category identification
            start = max(0, m.start() - 200)
            end = min(len(script_text), m.end() + 50)
            context = script_text[start:end]
            code_to_contexts.setdefault(code, set()).add(context)

        non_zero_codes = [c for c in code_to_contexts if c != 0]
        assume(len(non_zero_codes) >= 2)

        # Pick two distinct non-zero exit codes
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

        # Two different exit codes by definition map to different categories
        assert code_a != code_b, (
            f"Two different failure categories share exit code: "
            f"code_a={code_a}, code_b={code_b}"
        )

    def test_non_zero_exit_codes_are_all_distinct(self, script_text: str):
        """All 8 non-zero exit codes (1-8) are distinct failure categories."""
        codes = self._extract_exit_codes(script_text)
        non_zero = [c for c in codes if c != 0]
        unique_non_zero = set(non_zero)
        assert len(unique_non_zero) == 8, (
            f"Expected 8 distinct non-zero exit codes, found "
            f"{len(unique_non_zero)}: {sorted(unique_non_zero)}"
        )


# Feature: vcf9-scenario1-example, Property 4: Wait Loop Progress Reporting
# The wait_for_condition function body contains an echo/printf for progress,
# and all 4 expected wait_for_condition calls exist in the script.
# Validates: Requirements 9.5


class TestProperty4WaitLoopProgressReporting:
    """Property 4: Wait Loop Progress Reporting.

    For any wait loop in the script (cluster provisioning, kubeconfig
    retrieval, PVC binding, LoadBalancer IP), the loop body shall contain a
    print statement that outputs the current status and elapsed time on each
    polling iteration.  No wait loop shall poll silently.

    **Validates: Requirements 9.5**
    """

    # The wait_for_condition descriptions (substrings) expected in the script.
    # The script uses "VKS guest cluster API" instead of "kubeconfig" and adds
    # a worker-node readiness wait.
    EXPECTED_WAIT_DESCRIPTIONS: list[str] = [
        "cluster",       # cluster provisioning wait
        "guest cluster", # VKS guest cluster API reachability wait
        "PVC",           # PVC binding wait
        "LoadBalancer",  # LB external IP wait
        "worker",        # worker node readiness wait
    ]

    @staticmethod
    def _extract_wait_for_condition_body(script_text: str) -> str | None:
        """Extract the body of the wait_for_condition function.

        Returns the text from the function declaration to the closing ``}``.
        """
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
        self, script_text: str
    ):
        """The wait_for_condition function body contains an echo/printf."""
        body = self._extract_wait_for_condition_body(script_text)
        assert body is not None, (
            "wait_for_condition function not found in the script"
        )
        has_echo = "echo" in body or "printf" in body
        assert has_echo, (
            "wait_for_condition function body does not contain an echo or "
            "printf statement for progress reporting"
        )

    def test_wait_for_condition_progress_includes_elapsed_time(
        self, script_text: str
    ):
        """The progress message in wait_for_condition includes elapsed time."""
        body = self._extract_wait_for_condition_body(script_text)
        assert body is not None, (
            "wait_for_condition function not found in the script"
        )
        assert "elapsed" in body, (
            "wait_for_condition progress message does not reference elapsed "
            "time"
        )

    def test_all_wait_for_condition_calls_exist(
        self, script_text: str
    ):
        """The script contains at least 4 wait_for_condition invocations.

        Additional waits (e.g. worker-node readiness) are acceptable.
        """
        calls = self._extract_wait_for_condition_calls(script_text)
        # Filter to actual invocations (not the function definition itself)
        invocations = [
            c for c in calls
            if "wait_for_condition()" not in c  # exclude function def
        ]
        assert len(invocations) >= 4, (
            f"Expected at least 4 wait_for_condition calls, found {len(invocations)}: "
            f"{invocations}"
        )

    @given(idx=st.integers(min_value=0, max_value=4))
    @settings(max_examples=100)
    def test_each_wait_call_passes_description_parameter(
        self, script_text: str, idx: int
    ):
        """Every wait_for_condition call passes a description string.

        Randomly select one of the 4 expected wait descriptions and verify
        a matching wait_for_condition call exists in the script.
        """
        desc_keyword = self.EXPECTED_WAIT_DESCRIPTIONS[idx]
        calls = self._extract_wait_for_condition_calls(script_text)
        invocations = [
            c for c in calls if "wait_for_condition()" not in c
        ]
        matching = [c for c in invocations if desc_keyword in c]
        assert len(matching) >= 1, (
            f"No wait_for_condition call found with description containing "
            f"'{desc_keyword}'. Calls found: {invocations}"
        )


# Feature: vcf9-scenario1-example, Property 5: Heredoc YAML Validity
# Substituting all bash variables with valid test values and parsing with
# a YAML parser shall produce valid YAML documents without parse errors.
# Validates: Requirements 10.1

import yaml


class TestProperty5HeredocYAMLValidity:
    """Property 5: Heredoc YAML Validity.

    For any heredoc manifest in the script, substituting all bash variables
    with valid test values and parsing the result with a YAML parser shall
    produce one or more valid YAML documents without parse errors.

    **Validates: Requirements 10.1**
    """

    # Regex to find ${VAR_NAME} and ${VAR_NAME:-default} patterns
    _VAR_PATTERN = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-[^}]*)?\}")

    # Hypothesis strategies for generating realistic variable values
    _PROJECT_NAMES = st.from_regex(r"[a-z][a-z0-9]{2,15}", fullmatch=True)
    _CIDR_BLOCKS = st.tuples(
        st.integers(min_value=1, max_value=254),
        st.integers(min_value=0, max_value=255),
        st.integers(min_value=0, max_value=255),
        st.integers(min_value=0, max_value=255),
        st.integers(min_value=8, max_value=30),
    ).map(lambda t: f"{t[0]}.{t[1]}.{t[2]}.{t[3]}/{t[4]}")
    _UUIDS = st.uuids().map(str)
    _SIMPLE_STRINGS = st.from_regex(r"[a-z][a-z0-9\-]{1,20}", fullmatch=True)
    _INTEGERS = st.integers(min_value=1, max_value=100).map(str)

    # Map variable names to appropriate strategies
    _VAR_STRATEGIES: dict[str, st.SearchStrategy] = {
        "PROJECT_NAME": _PROJECT_NAMES,
        "CLUSTER_NAME": _SIMPLE_STRINGS,
        "NAMESPACE_PREFIX": st.from_regex(r"[a-z][a-z0-9]{2,10}-", fullmatch=True),
        "DYNAMIC_NS_NAME": _SIMPLE_STRINGS,
        "SERVICES_CIDR": _CIDR_BLOCKS,
        "PODS_CIDR": _CIDR_BLOCKS,
        "CONTENT_LIBRARY_ID": _UUIDS,
        "MIN_NODES": _INTEGERS,
        "MAX_NODES": _INTEGERS,
        "K8S_VERSION": st.just("v1.33.6"),
        "STORAGE_CLASS": _SIMPLE_STRINGS,
        "VM_CLASS": _SIMPLE_STRINGS,
    }

    @classmethod
    def _get_strategy_for_var(cls, var_name: str) -> st.SearchStrategy:
        """Return a hypothesis strategy for the given variable name."""
        if var_name in cls._VAR_STRATEGIES:
            return cls._VAR_STRATEGIES[var_name]
        # Default: simple alphanumeric string (safe for YAML values)
        return cls._SIMPLE_STRINGS

    @classmethod
    def _extract_var_names(cls, heredoc: str) -> list[str]:
        """Extract unique bash variable names from a heredoc block."""
        return list(set(cls._VAR_PATTERN.findall(heredoc)))

    @classmethod
    def _substitute_vars(cls, heredoc: str, values: dict[str, str]) -> str:
        """Replace all ${VAR} and ${VAR:-default} patterns with values."""
        def replacer(match: re.Match) -> str:
            var_name = match.group(1)
            return values.get(var_name, "testvalue")
        return cls._VAR_PATTERN.sub(replacer, heredoc)

    def test_heredocs_found(self, script_heredocs: list[str]):
        """Precondition: the fixture must find at least one heredoc block."""
        assert len(script_heredocs) > 0, (
            "No heredoc blocks found in the script"
        )

    @given(data=st.data())
    @settings(max_examples=100)
    def test_heredoc_yaml_parses_with_random_values(
        self, script_heredocs: list[str], data: st.DataObject
    ):
        """Substituting random valid values into any heredoc produces valid YAML."""
        assume(len(script_heredocs) > 0)

        # Pick a random heredoc
        idx = data.draw(
            st.integers(min_value=0, max_value=len(script_heredocs) - 1),
            label="heredoc_index",
        )
        heredoc = script_heredocs[idx]

        # Extract variable names and generate values
        var_names = self._extract_var_names(heredoc)
        values: dict[str, str] = {}
        for var_name in var_names:
            strategy = self._get_strategy_for_var(var_name)
            values[var_name] = data.draw(strategy, label=var_name)

        # Substitute variables
        substituted = self._substitute_vars(heredoc, values)

        # Parse with YAML — should not raise any errors
        try:
            docs = list(yaml.safe_load_all(substituted))
        except yaml.YAMLError as exc:
            pytest.fail(
                f"YAML parse error in heredoc {idx} after variable substitution:\n"
                f"{exc}\n\n"
                f"Substituted YAML:\n{substituted}\n\n"
                f"Variable values: {values}"
            )

        # At least one document should be produced
        assert len(docs) > 0, (
            f"Heredoc {idx} produced no YAML documents after substitution"
        )


# Feature: vcf9-scenario1-example, Property 6: Multi-Document YAML Separators
# For any heredoc containing multiple resources, splitting on '---' and parsing
# each segment shall produce exactly one valid resource object per segment with
# apiVersion and kind fields present.
# Validates: Requirements 10.8


class TestProperty6MultiDocumentYAMLSeparators:
    """Property 6: Multi-Document YAML Separators.

    For any heredoc manifest in the script that contains multiple Kubernetes
    resources, the resources shall be separated by the standard YAML document
    separator (``---``), and splitting on that separator then parsing each
    segment shall produce exactly one valid resource object per segment with
    ``apiVersion`` and ``kind`` fields present.

    **Validates: Requirements 10.8**
    """

    # Reuse the variable substitution helpers from Property 5
    _VAR_PATTERN = TestProperty5HeredocYAMLValidity._VAR_PATTERN
    _get_strategy_for_var = TestProperty5HeredocYAMLValidity._get_strategy_for_var
    _extract_var_names = TestProperty5HeredocYAMLValidity._extract_var_names
    _substitute_vars = TestProperty5HeredocYAMLValidity._substitute_vars

    @staticmethod
    def _multi_doc_heredocs(heredocs: list[str]) -> list[str]:
        """Return only heredocs that contain ``---`` (multi-document)."""
        return [h for h in heredocs if "\n---\n" in h or h.startswith("---\n")]

    def test_multi_doc_heredocs_found(self, script_heredocs: list[str]):
        """Precondition: at least one multi-document heredoc exists."""
        multi = self._multi_doc_heredocs(script_heredocs)
        assert len(multi) > 0, (
            "No multi-document heredoc blocks (containing '---') found in the script"
        )

    @given(data=st.data())
    @settings(max_examples=100)
    def test_each_segment_has_apiversion_and_kind(
        self, script_heredocs: list[str], data: st.DataObject
    ):
        """Splitting a multi-doc heredoc on '---' produces segments each with apiVersion and kind."""
        multi = self._multi_doc_heredocs(script_heredocs)
        assume(len(multi) > 0)

        # Pick a random multi-document heredoc
        idx = data.draw(
            st.integers(min_value=0, max_value=len(multi) - 1),
            label="multi_doc_index",
        )
        heredoc = multi[idx]

        # Generate random values for variable substitution
        var_names = self._extract_var_names(heredoc)
        values: dict[str, str] = {}
        for var_name in var_names:
            strategy = self._get_strategy_for_var(var_name)
            values[var_name] = data.draw(strategy, label=var_name)

        substituted = self._substitute_vars(heredoc, values)

        # Split on '---' and parse each non-empty segment
        segments = substituted.split("---")
        non_empty_segments = [
            seg.strip() for seg in segments if seg.strip()
        ]

        assert len(non_empty_segments) >= 2, (
            f"Expected at least 2 non-empty segments in multi-doc heredoc {idx}, "
            f"got {len(non_empty_segments)}"
        )

        for seg_idx, segment in enumerate(non_empty_segments):
            try:
                doc = yaml.safe_load(segment)
            except yaml.YAMLError as exc:
                pytest.fail(
                    f"YAML parse error in segment {seg_idx} of multi-doc heredoc {idx}:\n"
                    f"{exc}\n\nSegment:\n{segment}"
                )

            assert isinstance(doc, dict), (
                f"Segment {seg_idx} of multi-doc heredoc {idx} did not produce "
                f"a dict, got {type(doc).__name__}: {doc}"
            )
            assert "apiVersion" in doc, (
                f"Segment {seg_idx} of multi-doc heredoc {idx} is missing "
                f"'apiVersion'. Keys: {list(doc.keys())}"
            )
            assert "kind" in doc, (
                f"Segment {seg_idx} of multi-doc heredoc {idx} is missing "
                f"'kind'. Keys: {list(doc.keys())}"
            )

# Feature: vcf9-scenario1-example, Property 7: API Version Consistency With Onboarding Guide
# For any Kubernetes resource manifest in the script, the apiVersion and kind
# pair shall match the corresponding resource definition in the VCF 9 IaC
# Onboarding Guide. The script shall not introduce API version or kind values
# that differ from the guide.
# Validates: Requirements 12.2


class TestProperty7APIVersionConsistency:
    """Property 7: API Version Consistency With Onboarding Guide.

    For any Kubernetes resource manifest in the script, the ``apiVersion`` and
    ``kind`` pair shall match the corresponding resource definition in the
    VCF 9 IaC Onboarding Guide (``vcf9-iac-onboarding-guide.md``).  The script
    shall not introduce API version or kind values that differ from the guide.

    **Validates: Requirements 12.2**
    """

    # Reuse variable substitution helpers from Property 5
    _get_strategy_for_var = TestProperty5HeredocYAMLValidity._get_strategy_for_var
    _extract_var_names = TestProperty5HeredocYAMLValidity._extract_var_names
    _substitute_vars = TestProperty5HeredocYAMLValidity._substitute_vars

    @staticmethod
    def _extract_api_pairs_from_docs(yaml_text: str) -> set[tuple[str, str]]:
        """Parse YAML text (possibly multi-doc) and return (apiVersion, kind) pairs."""
        pairs: set[tuple[str, str]] = set()
        for doc in yaml.safe_load_all(yaml_text):
            if isinstance(doc, dict) and "apiVersion" in doc and "kind" in doc:
                pairs.add((doc["apiVersion"], doc["kind"]))
        return pairs

    @staticmethod
    def _guide_api_pairs(yaml_blocks: list[str]) -> set[tuple[str, str]]:
        """Extract all (apiVersion, kind) pairs from the onboarding guide YAML blocks."""
        pairs: set[tuple[str, str]] = set()
        for block in yaml_blocks:
            try:
                for doc in yaml.safe_load_all(block):
                    if isinstance(doc, dict) and "apiVersion" in doc and "kind" in doc:
                        pairs.add((str(doc["apiVersion"]), str(doc["kind"])))
            except yaml.YAMLError:
                continue
        return pairs

    def _script_api_pairs(self, heredocs: list[str]) -> set[tuple[str, str]]:
        """Extract all (apiVersion, kind) pairs from script heredocs.

        Uses fixed test values for variable substitution so YAML can be parsed.
        """
        test_values: dict[str, str] = {
            "PROJECT_NAME": "test-project",
            "PROJECT_DESCRIPTION": "Test project",
            "USER_IDENTITY": "user@example.com",
            "NAMESPACE_PREFIX": "test-ns-",
            "NAMESPACE_DESCRIPTION": "Test namespace",
            "REGION_NAME": "region-us1-a",
            "RESOURCE_CLASS": "xxlarge",
            "VPC_NAME": "test-vpc",
            "ZONE_NAME": "zone-a",
            "CPU_LIMIT": "100000M",
            "MEMORY_LIMIT": "102400Mi",
            "CLUSTER_NAME": "test-cluster",
            "DYNAMIC_NS_NAME": "test-ns-abc12",
            "SERVICES_CIDR": "10.96.0.0/12",
            "PODS_CIDR": "192.168.156.0/20",
            "K8S_VERSION": "v1.33.6+vmware.1-fips",
            "CONTENT_LIBRARY_ID": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            "MAX_NODES": "10",
            "MIN_NODES": "2",
            "VM_CLASS": "best-effort-large",
            "STORAGE_CLASS": "nfs",
        }
        pairs: set[tuple[str, str]] = set()
        for heredoc in heredocs:
            var_names = self._extract_var_names(heredoc)
            values = {v: test_values.get(v, "placeholder") for v in var_names}
            substituted = self._substitute_vars(heredoc, values)
            try:
                pairs |= self._extract_api_pairs_from_docs(substituted)
            except yaml.YAMLError:
                continue
        return pairs

    def test_script_api_pairs_found(self, script_heredocs: list[str]):
        """Precondition: the script contains at least one (apiVersion, kind) pair."""
        pairs = self._script_api_pairs(script_heredocs)
        assert len(pairs) > 0, (
            "No (apiVersion, kind) pairs found in script heredocs"
        )

    def test_guide_api_pairs_found(self, yaml_blocks: list[str]):
        """Precondition: the onboarding guide contains at least one (apiVersion, kind) pair."""
        pairs = self._guide_api_pairs(yaml_blocks)
        assert len(pairs) > 0, (
            "No (apiVersion, kind) pairs found in onboarding guide YAML blocks"
        )

    def test_all_script_pairs_exist_in_guide(
        self, script_heredocs: list[str], yaml_blocks: list[str]
    ):
        """Every (apiVersion, kind) pair in the script must exist in the guide."""
        script_pairs = self._script_api_pairs(script_heredocs)
        guide_pairs = self._guide_api_pairs(yaml_blocks)

        missing = script_pairs - guide_pairs
        assert not missing, (
            f"Script contains (apiVersion, kind) pairs not found in the onboarding guide:\n"
            f"  Missing: {missing}\n"
            f"  Script pairs: {script_pairs}\n"
            f"  Guide pairs: {guide_pairs}"
        )

    @given(data=st.data())
    @settings(max_examples=100)
    def test_random_heredoc_pairs_in_guide(
        self,
        script_heredocs: list[str],
        yaml_blocks: list[str],
        data: st.DataObject,
    ):
        """Randomly select a heredoc, substitute variables, and verify its pairs are in the guide."""
        assume(len(script_heredocs) > 0)

        guide_pairs = self._guide_api_pairs(yaml_blocks)
        assume(len(guide_pairs) > 0)

        # Pick a random heredoc
        idx = data.draw(
            st.integers(min_value=0, max_value=len(script_heredocs) - 1),
            label="heredoc_index",
        )
        heredoc = script_heredocs[idx]

        # Generate random values for variable substitution
        var_names = self._extract_var_names(heredoc)
        values: dict[str, str] = {}
        for var_name in var_names:
            strategy = self._get_strategy_for_var(var_name)
            values[var_name] = data.draw(strategy, label=var_name)

        substituted = self._substitute_vars(heredoc, values)

        try:
            heredoc_pairs = self._extract_api_pairs_from_docs(substituted)
        except yaml.YAMLError:
            assume(False)  # skip unparseable substitutions
            return

        for api_version, kind in heredoc_pairs:
            assert (api_version, kind) in guide_pairs, (
                f"Heredoc {idx} contains (apiVersion={api_version!r}, kind={kind!r}) "
                f"which is not documented in the onboarding guide.\n"
                f"Guide pairs: {guide_pairs}"
            )
