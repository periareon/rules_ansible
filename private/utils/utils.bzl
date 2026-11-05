"""Ansible rule utilities"""

load("@rules_venv//python:py_info.bzl", "PyInfo")
load("@rules_venv//python/venv:defs.bzl", "py_venv_common")

AnsibleScriptInfo = provider(
    doc = "A provider encompassing additional metadata about a Ansible python script.",
    fields = {
        "main": "File: The path to the `main` source of a Ansible script.",
    },
)

def _ansible_script_main_finder_aspect_impl(target, ctx):
    if PyInfo not in target:
        return []

    main = getattr(ctx.rule.file, "main")
    srcs = getattr(ctx.rule.files, "srcs")
    if main:
        if main not in srcs:
            fail("`main` was not found in `srcs`. Please add `{}` to `srcs` for {}".format(
                main.path,
                ctx.label,
            ))
        return [AnsibleScriptInfo(
            main = main,
        )]

    if len(srcs) == 1:
        main = srcs[0]
    else:
        for src in srcs:
            basename = src.basename[:-len(".py")]
            if basename == target.label.name:
                main = src

                # Accept the first candidate as `main`
                break

    if not main:
        fail("Failed to find `main` for {}".format(
            target.label,
        ))

    return [AnsibleScriptInfo(
        main = main,
    )]

ansible_script_main_finder_aspect = aspect(
    doc = "An aspect accompanying Ansible rules to locate `main` for the `script` attribute.",
    implementation = _ansible_script_main_finder_aspect_impl,
)

def get_process_wrapper_attr(ctx, attr_name):
    """_summary_

    Args:
        ctx (_type_): _description_
        attr_name (_type_): _description_

    Returns:
        _type_: _description_
    """
    target = getattr(ctx.attr, attr_name)

    if AnsibleScriptInfo in target:
        return struct(
            main = target[AnsibleScriptInfo].main,
            target = target,
        )

    files = getattr(ctx.files, attr_name)
    if len(files) != 1:
        fail("in script attribute of {rule} rule {export_label}: '{script_label}' must produce a single file".format(
            rule = ctx.rule.name,
            export_label = ctx.label,
            script_label = target.label,
        ))

    return struct(
        main = files[0],
        target = None,
    )

def generate_process_wrapper(
        *,
        ctx,
        script_info,
        runfiles,
        main = None):
    """Create an executable which runs a python script within a venv.

    Args:
        ctx (ctx): The rule's context object.
        script_info (struct): The value returned by `get_process_wrapper_attr`.
        runfiles (Runfiles): Additional runfiles to associate with the executable.
        main (File, optional): An entrypoint to use in place of `script_info.main`. The
            script's own `main` is still a source of the executable so the entrypoint
            can import it.

    Returns:
        struct: A struct with the following fields:
            - `executable` (File): The generated executable.
            - `runfiles` (Runfiles): The runfiles of the executable.
            - `py_info` (PyInfo): The `PyInfo` provider of the executable.
            - `executable_info` (PyExecutableInfo): The provider consumers such as
              `py_venv_zipapp` use to repackage the executable.
    """
    venv_toolchain = py_venv_common.get_toolchain(ctx, cfg = "exec")

    srcs = [script_info.main]
    if main:
        srcs.append(main)
    else:
        main = script_info.main

    dep_info = py_venv_common.create_dep_info(
        ctx = ctx,
        deps = [script_info.target],
    )

    py_info = py_venv_common.create_py_info(
        ctx = ctx,
        imports = [],
        srcs = srcs,
        dep_info = dep_info,
    )

    all_runfiles = dep_info.runfiles
    if runfiles:
        all_runfiles = all_runfiles.merge(runfiles)

    executable, runfiles = py_venv_common.create_venv_entrypoint(
        ctx = ctx,
        venv_toolchain = venv_toolchain,
        py_info = py_info,
        main = main,
        runfiles = all_runfiles,
        use_runfiles_in_entrypoint = True,
        force_runfiles = False,
    )

    executable_info = py_venv_common.create_py_executable_info(
        ctx = ctx,
        venv_toolchain = venv_toolchain,
        py_info = py_info,
        main = main,
        runfiles = all_runfiles,
    )

    return struct(
        executable = executable,
        runfiles = runfiles,
        py_info = py_info,
        executable_info = executable_info,
    )
