"""Ansible rules"""

load("@rules_venv//python/venv:defs.bzl", "py_venv_common")
load(
    "//private/utils:utils.bzl",
    "ansible_script_main_finder_aspect",
    "generate_process_wrapper",
    "get_process_wrapper_attr",
)

AnsiblePlaybookInfo = provider(
    doc = "Infomation describing components of an Ansible playbook.",
    fields = {
        "hosts": "File: The hosts file for the current inventory",
        "inventory": "depset[File]: The sources of all inventory files",
        "playbook": "File: The root of the playbook",
        "roles": "depset[File]: The sources of all roles for the playbook",
    },
)

def _rlocationpath(file, workspace_name):
    if file.short_path.startswith("../"):
        return file.short_path[len("../"):]

    return "{}/{}".format(workspace_name, file.short_path)

def _ansible_playbook_impl(ctx):
    venv_toolchain = py_venv_common.get_toolchain(ctx)

    # Playbooks run straight out of runfiles. Source files keep their repo
    # layout there, so roles, `group_vars`, `host_vars` and anything else
    # sitting next to the playbook or inventory is found by Ansible exactly
    # as it would be in a checkout. No staging copies are made.
    playbook = ctx.file.playbook
    hosts = ctx.file.hosts
    config = ctx.file.config

    # The launcher is configured through a generated entrypoint rather than
    # `RunEnvironmentInfo` so the executable is self contained. It behaves the
    # same under `bazel run`, when executed from another target's runfiles,
    # or when published as a binary or zipapp.
    settings = {
        "ANSIBLE_BZL_CONFIG": _rlocationpath(config, ctx.workspace_name),
        "ANSIBLE_BZL_INVENTORY_HOSTS": _rlocationpath(hosts, ctx.workspace_name),
        "ANSIBLE_BZL_LAUNCHER_NAME": ctx.label.name,
        "ANSIBLE_BZL_PACKAGE": ctx.label.package,
        "ANSIBLE_BZL_PLAYBOOK": _rlocationpath(playbook, ctx.workspace_name),
    }

    entrypoint = ctx.actions.declare_file("{}.ansible_launcher.py".format(ctx.label.name))
    ctx.actions.write(
        output = entrypoint,
        content = "\n".join(
            [
                '"""Generated entrypoint for the `{}` Ansible playbook."""'.format(ctx.label),
                "",
                "import os",
                "",
            ] + [
                "os.environ[{}] = {}".format(json.encode(key), json.encode(value))
                for key, value in settings.items()
            ] + [
                "",
                "from private.ansible_launcher import main  # noqa: E402",
                "",
                'if __name__ == "__main__":',
                "    main()",
                "",
            ],
        ),
    )

    data = [playbook, config, hosts] + ctx.files.inventory + ctx.files.roles + ctx.files.vault

    script_info = get_process_wrapper_attr(ctx, "_launcher")

    wrapper = generate_process_wrapper(
        ctx = ctx,
        script_info = script_info,
        runfiles = ctx.runfiles(files = data, transitive_files = venv_toolchain.all_files),
        main = entrypoint,
    )

    return [
        AnsiblePlaybookInfo(
            playbook = playbook,
            hosts = hosts,
            inventory = depset(ctx.files.inventory + [hosts]),
            roles = depset(ctx.files.roles),
        ),
        DefaultInfo(
            files = depset([wrapper.executable]),
            runfiles = wrapper.runfiles,
            executable = wrapper.executable,
        ),
        wrapper.py_info,
        wrapper.executable_info,
    ]

ansible_playbook = rule(
    implementation = _ansible_playbook_impl,
    doc = "A rule for running [Ansible playbooks](https://docs.ansible.com/ansible/latest/user_guide/playbooks_intro.html)",
    attrs = {
        "config": attr.label(
            doc = "The path to an Ansible config file.",
            default = Label("//ansible:config"),
            allow_single_file = True,
        ),
        "hosts": attr.label(
            doc = "Ansible hosts file",
            allow_single_file = True,
            mandatory = True,
        ),
        "inventory": attr.label_list(
            doc = "Ansible inventory files",
            allow_files = True,
        ),
        "playbook": attr.label(
            doc = "The ansible playbook yaml file.",
            allow_single_file = True,
            mandatory = True,
        ),
        "roles": attr.label_list(
            doc = "The source files for all ansible roles required by the playbook.",
            allow_files = True,
        ),
        "vault": attr.label_list(
            doc = (
                "Vault encrypted files required by the playbook. These are never decrypted on disk. " +
                "Ansible decrypts them in memory at runtime using the vault password file located by " +
                "the launcher (a `.vault_pass` file next to the playbook, its parent package, or the " +
                "workspace root) or one passed explicitly via `--vault-password-file`."
            ),
            allow_files = True,
        ),
        "_launcher": attr.label(
            doc = "The process wrapper for launching `ansible-playbook`",
            cfg = "target",
            executable = True,
            aspects = [ansible_script_main_finder_aspect],
            default = Label("//private:ansible_launcher"),
        ),
    } | py_venv_common.create_venv_attrs(),
    executable = True,
    toolchains = [
        py_venv_common.TOOLCHAIN_TYPE,
    ],
)
