"""# rules_ansible
"""

load(
    "//private:ansible.bzl",
    _ansible_playbook = "ansible_playbook",
)
load(
    "//private:lint.bzl",
    _ansible_lint_aspect = "ansible_lint_aspect",
    _ansible_lint_test = "ansible_lint_test",
)
load(
    ":toolchain.bzl",
    _ansible_toolchain = "ansible_toolchain",
)

ansible_lint_aspect = _ansible_lint_aspect
ansible_lint_test = _ansible_lint_test
ansible_playbook = _ansible_playbook
ansible_toolchain = _ansible_toolchain
