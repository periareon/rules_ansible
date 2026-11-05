"""Rules for linting ansible playbooks"""

load("@rules_venv//python/venv:defs.bzl", "py_venv_common")
load(
    "//private/utils:utils.bzl",
    "ansible_script_main_finder_aspect",
    "generate_process_wrapper",
    "get_process_wrapper_attr",
)
load(":ansible.bzl", "AnsiblePlaybookInfo")

def _ansible_lint_aspect_impl(target, ctx):
    if AnsiblePlaybookInfo not in target:
        return []

    playbook_info = target[AnsiblePlaybookInfo]

    config = ctx.rule.file.config

    args = ctx.actions.args()

    inputs = depset(
        [playbook_info.playbook, ctx.file._lint_config, config],
        transitive = [playbook_info.inventory, playbook_info.roles],
    )

    output = ctx.actions.declare_file(target.label.name + ".ansible_lint_check")

    args.add("--output", output)
    args.add("--package", target.label.package)
    args.add("--playbook", target[AnsiblePlaybookInfo].playbook)
    args.add("--config_file", config)
    args.add("--lint_config_file", ctx.file._lint_config)
    args.add("--")
    args.add("--show-relpath")
    args.add("--offline")

    ctx.actions.run(
        executable = ctx.executable._process_wrapper,
        inputs = inputs,
        outputs = [output],
        arguments = [args],
        mnemonic = "AnsibleLint",
        progress_message = "Ansible linting {}".format(target.label),
    )

    return [OutputGroupInfo(
        ansible_lint_checks = depset([output]),
    )]

ansible_lint_aspect = aspect(
    implementation = _ansible_lint_aspect_impl,
    doc = "An aspect for linting ansible targets.",
    attrs = {
        "_lint_config": attr.label(
            doc = "The ansible-lint config file to use",
            default = Label("//ansible:lint_config"),
            allow_single_file = True,
        ),
        "_process_wrapper": attr.label(
            doc = "A process wrapper for running `ansible-lint`.",
            cfg = "exec",
            executable = True,
            default = Label("//private:ansible_lint_process_wrapper"),
        ),
    },
)

_AnsibleConfigFinderInfo = provider(
    doc = "A provider which identifies a target ansible config file.",
    fields = {
        "config": "File: The config file.",
    },
)

def _ansible_config_finder_aspect_impl(target, ctx):
    if _AnsibleConfigFinderInfo in target:
        return []

    return _AnsibleConfigFinderInfo(
        config = ctx.rule.file.config,
    )

_ansible_config_finder_aspect = aspect(
    doc = "An aspect for locating a playbooks config file",
    implementation = _ansible_config_finder_aspect_impl,
)

def _rlocationpath(file, workspace_name):
    if file.short_path.startswith("../"):
        return file.short_path[len("../"):]

    return "{}/{}".format(workspace_name, file.short_path)

def _ansible_lint_test_impl(ctx):
    venv_toolchain = py_venv_common.get_toolchain(ctx)
    playbook_info = ctx.attr.playbook[AnsiblePlaybookInfo]
    config = ctx.attr.playbook[_AnsibleConfigFinderInfo].config

    args = []
    args.extend(["--playbook", _rlocationpath(playbook_info.playbook, ctx.workspace_name)])
    args.extend(["--package", ctx.attr.playbook.label.package])
    args.extend(["--config_file", _rlocationpath(config, ctx.workspace_name)])
    args.extend(["--lint_config_file", _rlocationpath(ctx.file.config, ctx.workspace_name)])
    args.append("--")
    args.append("--show-relpath")
    args.append("--offline")

    args_file = ctx.actions.declare_file("{}.args_file.txt".format(ctx.label.name))
    ctx.actions.write(
        output = args_file,
        content = "\n".join(args),
    )

    runfiles = ctx.runfiles(
        files = [args_file, playbook_info.playbook, playbook_info.hosts, ctx.file.config, config],
        transitive_files = depset(transitive = [playbook_info.inventory, playbook_info.roles, venv_toolchain.all_files]),
    )

    script_info = get_process_wrapper_attr(ctx, "_process_wrapper")

    wrapper = generate_process_wrapper(
        ctx = ctx,
        script_info = script_info,
        runfiles = runfiles,
    )

    return [
        DefaultInfo(
            files = depset([wrapper.executable]),
            runfiles = wrapper.runfiles,
            executable = wrapper.executable,
        ),
        testing.TestEnvironment(
            environment = {
                "ANSIBLE_LINT_ARGS_FILE": _rlocationpath(args_file, ctx.workspace_name),
            },
        ),
    ]

ansible_lint_test = rule(
    implementation = _ansible_lint_test_impl,
    doc = "A test rule for running `ansible-lint` on an Ansible playbook.",
    attrs = {
        "config": attr.label(
            doc = "The ansible-lint config file to use",
            default = Label("//ansible:lint_config"),
            allow_single_file = True,
        ),
        "playbook": attr.label(
            doc = "The `ansible_playbook` target to lint.",
            providers = [AnsiblePlaybookInfo],
            aspects = [_ansible_config_finder_aspect],
            mandatory = True,
        ),
        "_process_wrapper": attr.label(
            doc = "A process wrapper for running `ansible-lint`.",
            cfg = "exec",
            executable = True,
            aspects = [ansible_script_main_finder_aspect],
            default = Label("//private:ansible_lint_process_wrapper"),
        ),
    } | py_venv_common.create_venv_attrs(),
    test = True,
    toolchains = [
        py_venv_common.TOOLCHAIN_TYPE,
    ],
)
