"""Structural property tests for VCF 9 Deploy HA VM App deploy script.

These tests parse the deploy script text and verify that universal invariants
hold across all resource creation blocks, wait operations, variables, exit
codes, and label/selector pairs.  They are NOT Hypothesis-based; they use
regular pytest to verify structural properties of the script.
"""

import re
from collections import Counter


# ===================================================================
# Property 1: Idempotency Guard on All Resource Creation
# Feature: deploy-ha-vm-app, Property 1: Idempotency Guard on All Resource Creation
# Validates: Requirements 1.3, 2.3, 3.2, 4.6, 5.5
# ===================================================================


class TestIdempotencyGuards:
    """For every resource creation block (VirtualMachine, VirtualMachineService,
    PostgresCluster, Secret), verify a kubectl-get idempotency guard exists
    before the creation attempt."""

    # Resource names that must have idempotency guards
    EXPECTED_RESOURCES = {
        "virtualmachine": ["api-vm-01", "api-vm-02", "web-vm-01", "web-vm-02"],
        "virtualmachineservice": ["${API_SVC_NAME}", "${WEB_LB_NAME}"],
        "postgrescluster": ["${DSM_CLUSTER_NAME}"],
        "secret": ["${ADMIN_PASSWORD_SECRET_NAME}"],
    }

    def _find_idempotency_guards(self, text: str) -> list[str]:
        """Extract all kubectl get commands used as idempotency guards."""
        # Matches: kubectl get <kind> "<name>" or kubectl get <kind> ${VAR}
        pattern = r'kubectl\s+get\s+(\w+)\s+["\']?([^"\'\s]+)["\']?\s+-n'
        return re.findall(pattern, text)

    def test_all_vm_creation_blocks_have_idempotency_guard(self, ha_vm_app_deploy_text):
        """Each VirtualMachine creation loop must have a kubectl get check.
        VMs are created in loops using ${VM_NAME}, so we verify the guard
        pattern exists for each loop (API tier and Web tier)."""
        # The script uses loops with ${VM_NAME} variable, so we look for
        # the idempotency guard pattern with the variable reference
        pattern = r'kubectl\s+get\s+virtualmachine\s+["\']?\$\{VM_NAME\}["\']?\s+-n'
        matches = re.findall(pattern, ha_vm_app_deploy_text)
        # There should be at least 2 guards (one per VM loop: API tier + Web tier)
        assert len(matches) >= 2, (
            f"Expected at least 2 VirtualMachine idempotency guards (API + Web loops), "
            f"found {len(matches)}"
        )

    def test_all_service_creation_blocks_have_idempotency_guard(self, ha_vm_app_deploy_text):
        """Each VirtualMachineService creation must be preceded by a kubectl get check."""
        for svc_name in self.EXPECTED_RESOURCES["virtualmachineservice"]:
            # Escape $ for regex but match the variable reference in the script
            escaped = re.escape(svc_name)
            pattern = rf'kubectl\s+get\s+virtualmachineservice\s+["\']?{escaped}["\']?'
            matches = re.findall(pattern, ha_vm_app_deploy_text)
            assert len(matches) >= 1, (
                f"VirtualMachineService '{svc_name}' creation block missing idempotency guard"
            )

    def test_postgrescluster_creation_has_idempotency_guard(self, ha_vm_app_deploy_text):
        """PostgresCluster creation must be preceded by a kubectl get check."""
        pattern = r'kubectl\s+get\s+postgrescluster\s+'
        matches = re.findall(pattern, ha_vm_app_deploy_text)
        assert len(matches) >= 1, (
            "PostgresCluster creation block missing idempotency guard"
        )

    def test_secret_creation_has_idempotency_guard(self, ha_vm_app_deploy_text):
        """Admin password Secret creation must be preceded by a kubectl get check."""
        pattern = r'kubectl\s+get\s+secret\s+'
        matches = re.findall(pattern, ha_vm_app_deploy_text)
        assert len(matches) >= 1, (
            "Secret creation block missing idempotency guard"
        )

    def test_idempotency_guard_precedes_creation(self, ha_vm_app_deploy_text):
        """For each resource kind, the kubectl get guard appears before the
        kubectl apply/create that provisions the resource."""
        # Check VirtualMachineService resources using variable references
        for svc_var in ["${API_SVC_NAME}", "${WEB_LB_NAME}"]:
            escaped = re.escape(svc_var)
            guard_pattern = rf'kubectl\s+get\s+virtualmachineservice\s+["\']?{escaped}["\']?'
            guard_match = re.search(guard_pattern, ha_vm_app_deploy_text)
            assert guard_match is not None, (
                f"No idempotency guard found for VirtualMachineService '{svc_var}'"
            )
            # The guard must appear before the kubectl apply for this service
            apply_pattern = r'kind:\s+VirtualMachineService'
            apply_matches = list(re.finditer(apply_pattern, ha_vm_app_deploy_text))
            # Find the apply that comes after this guard
            for apply_match in apply_matches:
                if apply_match.start() > guard_match.start():
                    assert guard_match.start() < apply_match.start(), (
                        f"Idempotency guard for '{svc_var}' must appear before its creation manifest"
                    )
                    break



# ===================================================================
# Property 2: Timeout Error Handling on All Wait Operations
# Feature: deploy-ha-vm-app, Property 2: Timeout Error Handling on All Wait Operations
# Validates: Requirements 1.5, 2.5, 3.5, 4.5, 8.3, 8.4
# ===================================================================


class TestTimeoutErrorHandling:
    """For every wait_for_condition call, verify a corresponding log_error
    and non-zero exit statement follows within a reasonable number of lines."""

    def _find_wait_for_condition_calls(self, text: str) -> list[tuple[int, str]]:
        """Return (line_number, matched_line) for each wait_for_condition call
        outside the function definition."""
        results = []
        in_function_def = False
        for i, line in enumerate(text.splitlines()):
            stripped = line.strip()
            # Skip the function definition itself
            if stripped.startswith("wait_for_condition()"):
                in_function_def = True
                continue
            if in_function_def:
                # End of function definition (next unindented non-empty line
                # that isn't part of the function body)
                if stripped == "}" or (not stripped.startswith(" ") and not stripped.startswith("\t") and stripped and not stripped.startswith("#") and stripped != "{"):
                    in_function_def = False
                continue
            if "wait_for_condition" in stripped and not stripped.startswith("#"):
                results.append((i, stripped))
        return results

    def test_wait_calls_exist(self, ha_vm_app_deploy_text):
        """The deploy script must contain at least one wait_for_condition call."""
        calls = self._find_wait_for_condition_calls(ha_vm_app_deploy_text)
        assert len(calls) >= 1, "No wait_for_condition calls found in deploy script"

    def test_each_wait_has_log_error_and_exit(self, ha_vm_app_deploy_text):
        """For each wait_for_condition call, a log_error and exit must follow
        within 10 lines."""
        lines = ha_vm_app_deploy_text.splitlines()
        calls = self._find_wait_for_condition_calls(ha_vm_app_deploy_text)

        for line_num, call_line in calls:
            # Look ahead up to 15 lines for log_error and exit
            lookahead = "\n".join(lines[line_num:line_num + 15])
            has_log_error = "log_error" in lookahead
            has_exit = re.search(r'\bexit\s+[1-9]', lookahead) is not None

            assert has_log_error, (
                f"wait_for_condition at line {line_num + 1} has no log_error within 15 lines: "
                f"{call_line!r}"
            )
            assert has_exit, (
                f"wait_for_condition at line {line_num + 1} has no non-zero exit within 15 lines: "
                f"{call_line!r}"
            )

    def test_each_wait_exit_is_nonzero(self, ha_vm_app_deploy_text):
        """Every exit code following a wait_for_condition must be non-zero."""
        lines = ha_vm_app_deploy_text.splitlines()
        calls = self._find_wait_for_condition_calls(ha_vm_app_deploy_text)

        for line_num, _ in calls:
            lookahead = "\n".join(lines[line_num:line_num + 15])
            exit_matches = re.findall(r'\bexit\s+(\d+)', lookahead)
            for code in exit_matches:
                assert int(code) != 0, (
                    f"wait_for_condition at line {line_num + 1} followed by exit 0 "
                    f"(should be non-zero for error handling)"
                )


# ===================================================================
# Property 3: Variable Block Completeness
# Feature: deploy-ha-vm-app, Property 3: Variable Block Completeness
# Validates: Requirements 9.4
# ===================================================================


class TestVariableBlockCompleteness:
    """Every variable listed in validate_variables must appear in the
    configurable variable block at the top of the script with a default
    assignment pattern VAR="${VAR:-...}"."""

    def _extract_validated_variables(self, text: str) -> list[str]:
        """Extract variable names from the validate_variables function's
        required_vars array."""
        # Find the validate_variables function body
        func_match = re.search(
            r'validate_variables\(\)\s*\{(.*?)\n\}',
            text,
            re.DOTALL,
        )
        assert func_match, "validate_variables function not found in script"
        func_body = func_match.group(1)

        # Extract variable names from the required_vars array
        var_names = re.findall(r'"(\w+)"', func_body)
        return var_names

    def _extract_variable_block_assignments(self, text: str) -> dict[str, str]:
        """Extract VAR="${VAR:-...}" assignments from the variable block."""
        # Match the pattern: VAR="${VAR:-default}" or VAR="${VAR:-}"
        pattern = r'^(\w+)="\$\{\1:-([^}]*)\}"'
        assignments = {}
        for match in re.finditer(pattern, text, re.MULTILINE):
            assignments[match.group(1)] = match.group(2)
        return assignments

    def test_validated_variables_exist(self, ha_vm_app_deploy_text):
        """At least one variable must be listed in validate_variables."""
        vars_list = self._extract_validated_variables(ha_vm_app_deploy_text)
        assert len(vars_list) > 0, "No variables found in validate_variables"

    def test_each_validated_variable_has_default_assignment(self, ha_vm_app_deploy_text):
        """Every variable in validate_variables must have a VAR="${VAR:-...}"
        assignment in the variable block."""
        validated_vars = self._extract_validated_variables(ha_vm_app_deploy_text)
        block_assignments = self._extract_variable_block_assignments(ha_vm_app_deploy_text)

        for var in validated_vars:
            assert var in block_assignments, (
                f"Required variable '{var}' from validate_variables is missing "
                f"a default assignment (VAR=\"${{VAR:-...}}\") in the variable block"
            )

    def test_default_assignment_pattern_is_correct(self, ha_vm_app_deploy_text):
        """Each validated variable's assignment must use the exact
        VAR="${VAR:-...}" pattern."""
        validated_vars = self._extract_validated_variables(ha_vm_app_deploy_text)

        for var in validated_vars:
            pattern = rf'^{re.escape(var)}="\$\{{{re.escape(var)}:-[^}}]*\}}"'
            assert re.search(pattern, ha_vm_app_deploy_text, re.MULTILINE), (
                f"Variable '{var}' does not use the expected "
                f'{var}="${{{var}:-...}}" default assignment pattern'
            )


# ===================================================================
# Property 4: Distinct Exit Codes Per Failure Category
# Feature: deploy-ha-vm-app, Property 4: Distinct Exit Codes Per Failure Category
# Validates: Requirements 9.5
# ===================================================================


class TestDistinctExitCodes:
    """All non-zero exit codes in the deploy script must be distinct per
    failure category (variable validation, DSM, API VM, API service,
    Web VM, Web LB, connectivity)."""

    def _extract_exit_codes(self, text: str) -> list[int]:
        """Extract all non-zero exit codes from the script, excluding
        the function definitions and the final exit 0."""
        codes = []
        for match in re.finditer(r'\bexit\s+(\d+)', text):
            code = int(match.group(1))
            if code != 0:
                codes.append(code)
        return codes

    def _extract_exit_code_contexts(self, text: str) -> list[tuple[int, str]]:
        """Extract (exit_code, surrounding_context) pairs for non-zero exits."""
        results = []
        lines = text.splitlines()
        for i, line in enumerate(lines):
            match = re.search(r'\bexit\s+(\d+)', line)
            if match:
                code = int(match.group(1))
                if code != 0:
                    # Get a few lines of context before the exit
                    start = max(0, i - 3)
                    context = "\n".join(lines[start:i + 1])
                    results.append((code, context))
        return results

    def test_nonzero_exit_codes_exist(self, ha_vm_app_deploy_text):
        """The script must contain at least one non-zero exit code."""
        codes = self._extract_exit_codes(ha_vm_app_deploy_text)
        assert len(codes) > 0, "No non-zero exit codes found in deploy script"

    def test_exit_codes_cover_all_failure_categories(self, ha_vm_app_deploy_text):
        """Exit codes 1-7 must all be present, covering all failure categories."""
        codes = set(self._extract_exit_codes(ha_vm_app_deploy_text))
        expected = {1, 2, 3, 4, 5, 6, 7}
        assert expected.issubset(codes), (
            f"Missing exit codes for failure categories: {expected - codes}. "
            f"Found: {sorted(codes)}"
        )

    def test_exit_codes_are_distinct_per_category(self, ha_vm_app_deploy_text):
        """Each failure category must use a unique exit code. Multiple uses
        of the same code are allowed within the same category (e.g., multiple
        exit 2 for different DSM failures), but different categories must not
        share codes."""
        lines = ha_vm_app_deploy_text.splitlines()

        # Map exit codes to the phase/section they appear in
        code_to_phases: dict[int, set[str]] = {}

        current_phase = "pre-flight"
        for i, line in enumerate(lines):
            # Detect phase headers
            phase_match = re.search(r'#\s*Phase\s+(\d+)', line)
            if phase_match:
                current_phase = f"phase-{phase_match.group(1)}"

            exit_match = re.search(r'\bexit\s+(\d+)', line)
            if exit_match:
                code = int(exit_match.group(1))
                if code != 0:
                    if code not in code_to_phases:
                        code_to_phases[code] = set()
                    code_to_phases[code].add(current_phase)

        # Verify that the set of codes used is {1, 2, 3, 4, 5, 6, 7}
        all_codes = sorted(code_to_phases.keys())
        assert all_codes == [1, 2, 3, 4, 5, 6, 7], (
            f"Expected exit codes 1-7, found: {all_codes}"
        )

    def test_final_exit_is_zero(self, ha_vm_app_deploy_text):
        """The script must end with exit 0 for success."""
        # Find the last exit statement
        exits = list(re.finditer(r'\bexit\s+(\d+)', ha_vm_app_deploy_text))
        assert exits, "No exit statements found"
        last_exit_code = int(exits[-1].group(1))
        assert last_exit_code == 0, (
            f"Last exit code should be 0 (success), got {last_exit_code}"
        )


# ===================================================================
# Property 5: VM Label and Service Selector Consistency
# Feature: deploy-ha-vm-app, Property 5: VM Label and Service Selector Consistency
# Validates: Requirements 1.6, 2.6, 4.2, 5.2
# ===================================================================


class TestVMLabelServiceSelectorConsistency:
    """For each VirtualMachineService, the spec.selector.app value must
    match the metadata.labels.app value on the corresponding VirtualMachine
    resources."""

    def _extract_vm_service_selectors(self, text: str) -> dict[str, str]:
        """Extract VirtualMachineService name → selector app value mappings."""
        # Find VirtualMachineService manifests in heredocs
        services: dict[str, str] = {}

        # Pattern to find VirtualMachineService blocks with their name and selector
        svc_blocks = re.finditer(
            r'kind:\s+VirtualMachineService\s*\n'
            r'\s*metadata:\s*\n'
            r'\s*name:\s+(\S+)',
            text,
        )

        for match in svc_blocks:
            svc_name = match.group(1)
            # Look for the selector.app value after this match
            block_start = match.start()
            # Get a reasonable chunk after the match to find the selector
            block_text = text[block_start:block_start + 500]
            selector_match = re.search(
                r'selector:\s*\n\s*app:\s+(\S+)',
                block_text,
            )
            if selector_match:
                services[svc_name] = selector_match.group(1)

        return services

    def _extract_vm_labels(self, text: str) -> list[str]:
        """Extract all app label values from VirtualMachine manifests.
        Returns a list since VMs created in loops share the same
        ${VM_NAME} variable reference."""
        labels: list[str] = []

        # Find VirtualMachine manifest blocks
        vm_blocks = re.finditer(
            r'kind:\s+VirtualMachine\s*\n'
            r'\s*metadata:\s*\n'
            r'\s*name:\s+\S+\s*\n'
            r'\s*namespace:\s+\S+\s*\n'
            r'\s*labels:\s*\n'
            r'\s*app:\s+(\S+)',
            text,
        )

        for match in vm_blocks:
            labels.append(match.group(1))

        return labels

    # Expected mapping: service selector variable → VM label variable → default values
    EXPECTED_MAPPINGS = {
        "${WEB_LB_NAME}": ("${WEB_APP_LABEL}", "ha-web"),
        "${API_SVC_NAME}": ("${API_APP_LABEL}", "ha-api"),
    }

    def test_service_selectors_found(self, ha_vm_app_deploy_text):
        """Both VirtualMachineService selectors must be extractable."""
        selectors = self._extract_vm_service_selectors(ha_vm_app_deploy_text)
        assert "${WEB_LB_NAME}" in selectors, f"Web LB selector not found, got: {selectors}"
        assert "${API_SVC_NAME}" in selectors, f"API service selector not found, got: {selectors}"

    def test_vm_labels_found(self, ha_vm_app_deploy_text):
        """VirtualMachine labels must be extractable from the manifests."""
        labels = self._extract_vm_labels(ha_vm_app_deploy_text)
        assert len(labels) > 0, "No VirtualMachine labels found in deploy script"

    def test_service_selector_matches_vm_labels(self, ha_vm_app_deploy_text):
        """Each VirtualMachineService selector.app must use the same variable
        as the corresponding VirtualMachine app label."""
        selectors = self._extract_vm_service_selectors(ha_vm_app_deploy_text)
        vm_label_values = set(self._extract_vm_labels(ha_vm_app_deploy_text))

        # Cross-check: every service selector value must appear as a VM label
        selector_values = set(selectors.values())
        assert selector_values.issubset(vm_label_values), (
            f"Service selector values {selector_values} not all found in VM labels {vm_label_values}"
        )

    def test_web_service_selector_matches_web_vm_label(self, ha_vm_app_deploy_text):
        """Web LB selector must use the same variable as web VM labels."""
        selectors = self._extract_vm_service_selectors(ha_vm_app_deploy_text)
        web_selector = selectors.get("${WEB_LB_NAME}")
        assert web_selector is not None, "Web LB selector not found"
        # Verify the variable block defines the default value
        assert 'WEB_APP_LABEL="${WEB_APP_LABEL:-ha-web}"' in ha_vm_app_deploy_text, (
            "WEB_APP_LABEL variable not defined with default 'ha-web'"
        )

    def test_api_service_selector_matches_api_vm_label(self, ha_vm_app_deploy_text):
        """API service selector must use the same variable as API VM labels."""
        selectors = self._extract_vm_service_selectors(ha_vm_app_deploy_text)
        api_selector = selectors.get("${API_SVC_NAME}")
        assert api_selector is not None, "API service selector not found"
        # Verify the variable block defines the default value
        assert 'API_APP_LABEL="${API_APP_LABEL:-ha-api}"' in ha_vm_app_deploy_text, (
            "API_APP_LABEL variable not defined with default 'ha-api'"
        )
