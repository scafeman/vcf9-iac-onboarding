"""Content-presence unit tests for VCF 9 Deploy Bastion VM — SSH Jump Host."""

import os
import re


# ===================================================================
# File existence tests
# Validates: Requirements 1.1, 5.1, 7.1, 8.1, 6.1, 6.2
# ===================================================================


class TestFileExistence:
    """All six deliverables exist at their expected paths."""

    BASE = os.path.join(os.path.dirname(__file__), "..")

    def test_deploy_script_exists(self):
        assert os.path.isfile(
            os.path.join(self.BASE, "examples", "deploy-bastion-vm", "deploy-bastion-vm.sh")
        )

    def test_teardown_script_exists(self):
        assert os.path.isfile(
            os.path.join(self.BASE, "examples", "deploy-bastion-vm", "teardown-bastion-vm.sh")
        )

    def test_workflow_exists(self):
        assert os.path.isfile(
            os.path.join(self.BASE, ".github", "workflows", "deploy-bastion-vm.yml")
        )

    def test_trigger_script_exists(self):
        assert os.path.isfile(
            os.path.join(self.BASE, "scripts", "trigger-deploy-bastion-vm.sh")
        )

    def test_readme_deploy_exists(self):
        assert os.path.isfile(
            os.path.join(self.BASE, "examples", "deploy-bastion-vm", "README-deploy.md")
        )

    def test_readme_teardown_exists(self):
        assert os.path.isfile(
            os.path.join(self.BASE, "examples", "deploy-bastion-vm", "README-teardown.md")
        )


# ===================================================================
# Deploy script — shebang and strict mode
# Validates: Requirements 1.1, 4.1
# ===================================================================


class TestDeployScriptShebangAndStrictMode:
    """Deploy script starts with bash shebang and enables strict mode."""

    def test_first_line_is_bash_shebang(self, bastion_deploy_text):
        first_line = bastion_deploy_text.splitlines()[0]
        assert first_line == "#!/bin/bash", (
            f"Expected '#!/bin/bash' as first line, got '{first_line}'"
        )

    def test_set_euo_pipefail(self, bastion_deploy_text):
        assert "set -euo pipefail" in bastion_deploy_text


# ===================================================================
# Deploy script — variable block completeness
# Validates: Requirements 4.2
# ===================================================================


class TestDeployVariableBlock:
    """Variable block includes all 15 required variables."""

    REQUIRED_VARIABLES = [
        "VCF_API_TOKEN",
        "VCFA_ENDPOINT",
        "TENANT_NAME",
        "CONTEXT_NAME",
        "SUPERVISOR_NAMESPACE",
        "BASTION_EXTERNAL_IP",
        "BASTION_SNAT_IP",
        "ALLOWED_SSH_SOURCES",
        "VM_CLASS",
        "VM_IMAGE",
        "VM_NAME",
        "STORAGE_CLASS",
        "VM_TIMEOUT",
        "SSH_TIMEOUT",
        "POLL_INTERVAL",
    ]

    def test_all_required_variables_defined(self, bastion_deploy_text):
        for var in self.REQUIRED_VARIABLES:
            pattern = rf'^{var}='
            assert re.search(pattern, bastion_deploy_text, re.MULTILINE), (
                f"Required variable '{var}' not defined in deploy script"
            )


# ===================================================================
# Deploy script — cloud-init content
# Validates: Requirements 1.2, 1.3, 1.4
# ===================================================================


class TestCloudInitContent:
    """Cloud-init contains rackadmin user, openssh-server, and disabled password auth."""

    def test_rackadmin_user(self, bastion_deploy_text):
        assert "rackadmin" in bastion_deploy_text

    def test_openssh_server_package(self, bastion_deploy_text):
        assert "openssh-server" in bastion_deploy_text

    def test_password_authentication_disabled(self, bastion_deploy_text):
        assert "PasswordAuthentication no" in bastion_deploy_text


# ===================================================================
# Deploy script — VirtualMachine apiVersion
# Validates: Requirements 1.1, 1.5
# ===================================================================


class TestVirtualMachineManifest:
    """VirtualMachine manifest uses correct apiVersion."""

    def test_vm_api_version(self, bastion_deploy_text):
        assert "vmoperator.vmware.com/v1alpha3" in bastion_deploy_text

    def test_vm_kind(self, bastion_deploy_text):
        assert "kind: VirtualMachine" in bastion_deploy_text


# ===================================================================
# Deploy script — NAT rule action fields
# Validates: Requirements 2.1, 2.2, 2.3, 2.4
# ===================================================================


class TestNATRuleActions:
    """DNAT and SNAT action fields are present in the deploy script."""

    def test_dnat_action(self, bastion_deploy_text):
        assert "action: DNAT" in bastion_deploy_text

    def test_snat_action(self, bastion_deploy_text):
        assert "action: SNAT" in bastion_deploy_text


# ===================================================================
# Deploy script — SecurityPolicy manifest
# Validates: Requirements 3.1, 3.2
# ===================================================================


class TestSecurityPolicyManifest:
    """SecurityPolicy uses correct apiVersion."""

    def test_security_policy_api_version(self, bastion_deploy_text):
        assert "crd.nsx.vmware.com/v1alpha1" in bastion_deploy_text

    def test_security_policy_kind(self, bastion_deploy_text):
        assert "kind: SecurityPolicy" in bastion_deploy_text


# ===================================================================
# Deploy script — idempotency checks
# Validates: Requirements 1.6, 2.5, 3.5
# ===================================================================


class TestDeployIdempotencyChecks:
    """Deploy script contains idempotency checks for key resources."""

    def test_vm_idempotency_check(self, bastion_deploy_text):
        assert "kubectl get virtualmachine" in bastion_deploy_text

    def test_nat_rule_idempotency_check(self, bastion_deploy_text):
        assert "kubectl get vpcnatrule" in bastion_deploy_text

    def test_security_policy_idempotency_check(self, bastion_deploy_text):
        assert "kubectl get securitypolicy" in bastion_deploy_text


# ===================================================================
# Teardown script — shebang, strict mode, deletion order, --ignore-not-found
# Validates: Requirements 5.1, 5.2, 5.3
# ===================================================================


class TestTeardownScriptShebangAndStrictMode:
    """Teardown script starts with bash shebang and enables strict mode."""

    def test_first_line_is_bash_shebang(self, bastion_teardown_text):
        first_line = bastion_teardown_text.splitlines()[0]
        assert first_line == "#!/bin/bash", (
            f"Expected '#!/bin/bash' as first line, got '{first_line}'"
        )

    def test_set_euo_pipefail(self, bastion_teardown_text):
        assert "set -euo pipefail" in bastion_teardown_text


class TestTeardownDeletionOrder:
    """Teardown deletes securitypolicy before vpcnatrule before virtualmachine before secret."""

    def test_securitypolicy_before_vpcnatrule(self, bastion_teardown_text):
        sp_pos = bastion_teardown_text.index("delete securitypolicy")
        nat_pos = bastion_teardown_text.index("delete vpcnatrule")
        assert sp_pos < nat_pos, "SecurityPolicy must be deleted before VPCNATRule"

    def test_vpcnatrule_before_virtualmachine(self, bastion_teardown_text):
        # Find the last vpcnatrule delete (SNAT)
        nat_positions = [m.start() for m in re.finditer(r"delete vpcnatrule", bastion_teardown_text)]
        vm_pos = bastion_teardown_text.index("delete virtualmachine")
        assert max(nat_positions) < vm_pos, "VPCNATRule must be deleted before VirtualMachine"

    def test_virtualmachine_before_secret(self, bastion_teardown_text):
        vm_pos = bastion_teardown_text.index("delete virtualmachine")
        secret_pos = bastion_teardown_text.index("delete secret")
        assert vm_pos < secret_pos, "VirtualMachine must be deleted before Secret"


class TestTeardownIgnoreNotFound:
    """All kubectl delete commands use --ignore-not-found."""

    def test_all_deletes_use_ignore_not_found(self, bastion_teardown_text):
        delete_lines = [
            line.strip()
            for line in bastion_teardown_text.splitlines()
            if re.search(r"kubectl\s+delete\b", line)
        ]
        assert len(delete_lines) > 0, "No kubectl delete commands found"
        for line in delete_lines:
            assert "--ignore-not-found" in line, (
                f"kubectl delete missing --ignore-not-found: {line}"
            )


# ===================================================================
# Workflow YAML — name, triggers, runner, step names
# Validates: Requirements 7.1, 7.2, 7.3, 7.4
# ===================================================================


class TestWorkflowContent:
    """GitHub Actions workflow has correct name, triggers, runner, and steps."""

    def test_workflow_name(self, bastion_workflow_yaml):
        assert bastion_workflow_yaml["name"] == "Deploy Bastion VM"

    def test_workflow_dispatch_trigger(self, bastion_workflow_yaml_text):
        assert "workflow_dispatch" in bastion_workflow_yaml_text

    def test_repository_dispatch_trigger(self, bastion_workflow_yaml_text):
        assert "repository_dispatch" in bastion_workflow_yaml_text

    def test_self_hosted_vcf_runner(self, bastion_workflow_yaml_text):
        assert "[self-hosted, vcf]" in bastion_workflow_yaml_text

    REQUIRED_STEP_NAMES = [
        "Checkout Repository",
        "Validate Inputs",
        "Create VCF CLI Context",
        "Provision Bastion VM",
        "Create NAT Rules",
        "Create Security Policy",
        "SSH Connectivity Verification",
    ]

    def test_all_required_step_names(self, bastion_workflow_yaml_text):
        for step_name in self.REQUIRED_STEP_NAMES:
            assert step_name in bastion_workflow_yaml_text, (
                f"Workflow missing step name '{step_name}'"
            )


# ===================================================================
# Trigger script — event_type and required args
# Validates: Requirements 8.1, 8.2, 8.4
# ===================================================================


class TestTriggerScriptContent:
    """Trigger script has correct event_type and required arguments."""

    def test_event_type(self, bastion_trigger_script_text):
        assert "deploy-bastion-vm" in bastion_trigger_script_text

    def test_required_arg_repo(self, bastion_trigger_script_text):
        assert "--repo" in bastion_trigger_script_text

    def test_required_arg_token(self, bastion_trigger_script_text):
        assert "--token" in bastion_trigger_script_text

    def test_required_arg_supervisor_namespace(self, bastion_trigger_script_text):
        assert "--supervisor-namespace" in bastion_trigger_script_text


# ===================================================================
# README-deploy.md — required sections
# Validates: Requirements 6.1, 6.3
# ===================================================================


class TestReadmeDeploySections:
    """README-deploy.md contains all required sections."""

    REQUIRED_SECTIONS = [
        "Overview",
        "Prerequisites",
        "What the Script Does",
        "Required Environment Variables",
        "How to Trigger",
        "Expected Output",
        "Typical Timing",
        "Exit Codes",
        "Troubleshooting",
    ]

    def test_all_required_sections(self, bastion_readme_deploy_text):
        for section in self.REQUIRED_SECTIONS:
            assert re.search(rf"^#+\s+.*{re.escape(section)}", bastion_readme_deploy_text, re.MULTILINE), (
                f"README-deploy.md missing section '{section}'"
            )


# ===================================================================
# README-teardown.md — required sections
# Validates: Requirements 6.2, 6.4
# ===================================================================


class TestReadmeTeardownSections:
    """README-teardown.md contains all required sections."""

    REQUIRED_SECTIONS = [
        "Overview",
        "What the Script Does",
        "Prerequisites",
        "Required Environment Variables",
        "How to Trigger",
        "Expected Output",
        "Typical Timing",
        "Idempotency",
    ]

    def test_all_required_sections(self, bastion_readme_teardown_text):
        for section in self.REQUIRED_SECTIONS:
            assert re.search(rf"^#+\s+.*{re.escape(section)}", bastion_readme_teardown_text, re.MULTILINE), (
                f"README-teardown.md missing section '{section}'"
            )
