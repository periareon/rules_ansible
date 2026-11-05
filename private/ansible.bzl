"""Ansible rules"""

load("@rules_venv//python:py_info.bzl", "PyInfo")
load("@rules_venv//python/venv:defs.bzl", "py_venv_common")
load(
    "//private/utils:utils.bzl",
    "ansible_script_main_finder_aspect",
    "generate_process_wrapper",
    "get_process_wrapper_attr",
)
load(":role.bzl", "AnsibleRoleInfo")

AnsiblePlaybookInfo = provider(
    doc = "Infomation describing components of an Ansible playbook.",
    fields = {
        "config": "File: The ansible config file",
        "data": "depset[File]: Additional runtime files of the playbook",
        "deps": "list[Target]: Python dependencies made available to Ansible on the controller, roles included",
        "hosts": "File: The hosts file for the current inventory",
        "inventory": "depset[File]: The sources of all inventory files",
        "playbook": "File: The root of the playbook",
        "role_anchors": "list[tuple]: `(name, anchor, depth)` of every `ansible_role`, see `AnsibleRoleInfo.roles`",
        "roles": "depset[File]: The sources of all roles for the playbook",
    },
)

def _rlocationpath(file, workspace_name):
    if file.short_path.startswith("../"):
        return file.short_path[len("../"):]

    return "{}/{}".format(workspace_name, file.short_path)

def _collect_roles(ctx):
    """Gather roles given as files and as `ansible_role` targets.

    Args:
        ctx (ctx): The rule's context object.

    Returns:
        struct: With `srcs` (depset[File]) of all roles, `files` (depset[File]) of their
            runtime payload which is not linted, `anchors` (list[tuple]) of every
            `ansible_role` and `deps` (list[Target]) of their python dependencies.
    """
    files = []
    infos = []
    for target in ctx.attr.roles:
        if AnsibleRoleInfo in target:
            infos.append(target[AnsibleRoleInfo])
        else:
            files.extend(target.files.to_list())

    anchors = []
    seen = {}
    for name, anchor, depth in depset(transitive = [info.roles for info in infos]).to_list():
        if name in seen:
            fail("{} depends on two different roles named `{}`: {} and {}".format(
                ctx.label,
                name,
                seen[name].owner,
                anchor.owner,
            ))
        seen[name] = anchor
        anchors.append((name, anchor, depth))

    return struct(
        srcs = depset(files, transitive = [info.transitive_srcs for info in infos]),
        files = depset(transitive = [info.transitive_files for info in infos]),
        anchors = anchors,
        deps = depset(ctx.attr.deps, transitive = [info.transitive_deps for info in infos]).to_list(),
    )

def _ansible_playbook_impl(ctx):
    venv_toolchain = py_venv_common.get_toolchain(ctx)
    roles = _collect_roles(ctx)

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
        # `ansible_role` targets are found through `ANSIBLE_ROLES_PATH`, which the
        # launcher derives from these files at runtime.
        "ANSIBLE_BZL_ROLES": json.encode([
            {"depth": depth, "file": _rlocationpath(anchor, ctx.workspace_name)}
            for _, anchor, depth in roles.anchors
        ]),
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

    data = [playbook, config, hosts] + ctx.files.inventory + ctx.files.vault + ctx.files.data

    script_info = get_process_wrapper_attr(ctx, "_launcher")

    wrapper = generate_process_wrapper(
        ctx = ctx,
        script_info = script_info,
        runfiles = ctx.runfiles(
            files = data,
            transitive_files = depset(transitive = [roles.srcs, roles.files, venv_toolchain.all_files]),
        ),
        main = entrypoint,
        deps = roles.deps,
    )

    return [
        AnsiblePlaybookInfo(
            config = config,
            data = depset(ctx.files.data, transitive = [roles.files]),
            deps = roles.deps,
            playbook = playbook,
            hosts = hosts,
            inventory = depset(ctx.files.inventory + [hosts]),
            role_anchors = roles.anchors,
            roles = roles.srcs,
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
        "data": attr.label_list(
            doc = (
                "Additional files available at runtime. Files keep their repository layout, so a " +
                "file in the playbook's package is reachable as `{{ playbook_dir }}/<path>`."
            ),
            allow_files = True,
        ),
        "deps": attr.label_list(
            doc = (
                "Python dependencies made available to Ansible on the controller, alongside " +
                "`ansible` itself. Required by anything that runs in the controller's interpreter: " +
                "inventory, lookup, filter and connection plugins, and modules run with " +
                "`connection: local` or `delegate_to: localhost`. Also available to `ansible-lint`."
            ),
            providers = [PyInfo],
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
            doc = (
                "The roles required by the playbook, as `ansible_role` targets or as files of roles " +
                "in the playbook's `roles/` directory, e.g. `glob([\"roles/**/*.yaml\"])`. " +
                "`ansible_role` targets are found by name wherever they live."
            ),
            allow_files = True,
            providers = [[AnsibleRoleInfo], []],
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
