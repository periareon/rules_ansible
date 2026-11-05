"""Ansible role rules"""

load("@rules_venv//python:py_info.bzl", "PyInfo")

AnsibleRoleInfo = provider(
    doc = "Information about an Ansible role and the roles it depends on.",
    fields = {
        "name": "str: The name of the role, as referenced by playbooks.",
        "roles": (
            "depset[tuple]: This role and every role it depends on. Each entry is " +
            "`(name, anchor, depth)`: the role name, a file of the role and the number of " +
            "path components from that file up to the directory containing the role. The " +
            "directories are what is put on `ANSIBLE_ROLES_PATH` at runtime."
        ),
        "srcs": "depset[File]: The sources of this role.",
        "transitive_deps": "depset[Target]: Python dependencies of this role and the roles it depends on.",
        "transitive_files": (
            "depset[File]: Runtime payload of this role and every role it depends on: artifacts " +
            "placed under `files/` and `data`. Not inputs to linting."
        ),
        "transitive_srcs": "depset[File]: The sources of this role and every role it depends on.",
    },
)

def _package_relative_path(file, package):
    """Compute the path of a file relative to its package.

    Args:
        file (File): The file.
        package (str): The package the file belongs to.

    Returns:
        str: The relative path.
    """
    path = file.short_path

    # External files are `../<repo>/<package>/<path>`
    if path.startswith("../"):
        path = path[len("../"):]
        path = path[path.index("/") + 1:]

    if package:
        prefix = package + "/"
        if not path.startswith(prefix):
            fail("{} is not within package `{}`".format(file.short_path, package))
        path = path[len(prefix):]

    return path

def role_anchor(name, package, srcs):
    """Describe how to locate a role's parent directory from one of its files.

    A source file is preferred so the directory also resolves when runfiles
    are provided as a manifest, where source files point into the checkout.

    Args:
        name (str): The role name.
        package (str): The package of the role.
        srcs (list[File]): The files of the role.

    Returns:
        tuple: `(name, anchor, depth)`, see `AnsibleRoleInfo.roles`.
    """
    anchor = srcs[0]
    for src in srcs:
        if src.is_source:
            anchor = src
            break

    depth = len(_package_relative_path(anchor, package).split("/")) + 1

    return (name, anchor, depth)

def _place_files(ctx):
    """Place Bazel-built artifacts under the role's `files/` directory.

    Args:
        ctx (ctx): The rule's context object.

    Returns:
        list[File]: The placed artifacts.
    """
    outputs = []
    for target, path in ctx.attr.files.items():
        if not path or path.startswith("/") or ".." in path.split("/"):
            fail("`files` of {}: `{}` must be a relative path below `files/`".format(ctx.label, path))

        srcs = target.files.to_list()
        if len(srcs) != 1:
            fail("`files` of {}: {} must provide exactly one file, got {}".format(
                ctx.label,
                target.label,
                len(srcs),
            ))

        output = ctx.actions.declare_file("files/" + path)
        ctx.actions.symlink(
            output = output,
            target_file = srcs[0],
            progress_message = "Placing %{output} for " + str(ctx.label),
        )
        outputs.append(output)

    return outputs

def _ansible_role_impl(ctx):
    name = ctx.label.name
    package = ctx.label.package
    directory = package.split("/")[-1]
    if directory != name:
        fail((
            "`ansible_role` {} must be named after the directory of the role, `{}`. " +
            "Ansible resolves roles by directory name."
        ).format(ctx.label, directory or "<root>"))

    srcs = ctx.files.srcs
    if not srcs:
        fail("`srcs` of {} is empty".format(ctx.label))

    for src in srcs:
        if src.owner.package != package or src.owner.workspace_name != ctx.label.workspace_name:
            fail((
                "{} is not part of the role package `{}` of {}. Role files, generated " +
                "ones included, must belong to the role's package. Use `data` for files " +
                "from elsewhere."
            ).format(src.owner, package, ctx.label))

    role_deps = [dep[AnsibleRoleInfo] for dep in ctx.attr.roles]

    transitive_srcs = depset(
        srcs,
        transitive = [dep.transitive_srcs for dep in role_deps],
    )
    transitive_files = depset(
        _place_files(ctx) + ctx.files.data,
        transitive = [dep.transitive_files for dep in role_deps],
    )

    return [
        AnsibleRoleInfo(
            name = name,
            roles = depset(
                [role_anchor(name, package, srcs)],
                transitive = [dep.roles for dep in role_deps],
            ),
            srcs = depset(srcs),
            transitive_deps = depset(
                ctx.attr.deps,
                transitive = [dep.transitive_deps for dep in role_deps],
            ),
            transitive_files = transitive_files,
            transitive_srcs = transitive_srcs,
        ),
        DefaultInfo(
            files = depset(srcs),
            runfiles = ctx.runfiles(transitive_files = depset(transitive = [transitive_srcs, transitive_files])),
        ),
    ]

ansible_role = rule(
    implementation = _ansible_role_impl,
    doc = """\
An [Ansible role](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_reuse_roles.html).

The rule is defined in the role's own package and named after it, e.g. `//infra/roles/common:common`,
matching how Ansible resolves roles by directory name. Playbooks that list the role in `roles` find it
by name wherever it lives: the directory containing the role is added to `ANSIBLE_ROLES_PATH` when the
playbook runs and when it is linted. The role's python `deps` and the roles it depends on follow it
into every playbook that uses it.

Artifacts built by Bazel are placed under the role's `files/` directory with `files`, where `copy`,
`template`, `unarchive` and friends find them by their usual relative names.

```python
load("@rules_ansible//ansible:defs.bzl", "ansible_role")

ansible_role(
    name = "deploy",
    srcs = glob([
        "handlers/*.yaml",
        "tasks/*.yaml",
        "templates/*.j2",
    ]),
    files = {
        "//app:release": "app.tar.gz",
    },
    roles = ["//infra/roles/common"],
)
```
""",
    attrs = {
        "data": attr.label_list(
            doc = "Files made available at runtime which are not part of the role's directory.",
            allow_files = True,
        ),
        "deps": attr.label_list(
            doc = (
                "Python dependencies made available to Ansible on the controller for any playbook " +
                "using this role. See `ansible_playbook.deps`."
            ),
            providers = [PyInfo],
        ),
        "files": attr.label_keyed_string_dict(
            doc = (
                "Artifacts built by Bazel to place under the role's `files/` directory, mapping a " +
                "target producing a single file to its path below `files/`. They are available to " +
                "the role at runtime like any of its files but are not inputs to linting."
            ),
            allow_files = True,
        ),
        "roles": attr.label_list(
            doc = "Other `ansible_role` targets this role depends on, e.g. through `meta/main.yaml`.",
            providers = [AnsibleRoleInfo],
        ),
        "srcs": attr.label_list(
            doc = (
                "The sources of the role: tasks, handlers, vars, defaults, meta, templates and plugins, " +
                "e.g. `glob([\"tasks/*.yaml\", \"templates/*.j2\"])`. All files must be within the " +
                "role's package. Built artifacts go in `files`."
            ),
            allow_files = True,
            mandatory = True,
        ),
    },
)
