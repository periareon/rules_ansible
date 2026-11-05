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

    args = ctx.actions.args()

    inputs = depset(
        [playbook_info.playbook, ctx.file._lint_config, playbook_info.config],
        transitive = [playbook_info.inventory, playbook_info.roles],
    )

    output = ctx.actions.declare_file(target.label.name + ".ansible_lint_check")

    args.add("--output", output)
    args.add("--package", target.label.package)
    args.add("--playbook", playbook_info.playbook)
    args.add("--config_file", playbook_info.config)
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

def _rlocationpath(file, workspace_name):
    if file.short_path.startswith("../"):
        return file.short_path[len("../"):]

    return "{}/{}".format(workspace_name, file.short_path)

def _ansible_lint_test_impl(ctx):
    venv_toolchain = py_venv_common.get_toolchain(ctx)
    playbook_info = ctx.attr.playbook[AnsiblePlaybookInfo]

    args = []
    args.extend(["--playbook", _rlocationpath(playbook_info.playbook, ctx.workspace_name)])
    args.extend(["--package", ctx.attr.playbook.label.package])
    args.extend(["--config_file", _rlocationpath(playbook_info.config, ctx.workspace_name)])
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
        files = [args_file, playbook_info.playbook, playbook_info.hosts, ctx.file.config, playbook_info.config],
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
        RunEnvironmentInfo(
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
            mandatory = True,
        ),
        "_process_wrapper": attr.label(
            doc = "A process wrapper for running `ansible-lint`.",
            cfg = "target",
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
