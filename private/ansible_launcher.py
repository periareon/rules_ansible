"""The ansible-playbook launcher."""

import json
import logging
import os
import subprocess
import sys
from pathlib import Path
from typing import List, Optional

from python.runfiles import Runfiles

ENV_ANSIBLE_BZL_PLAYBOOK = "ANSIBLE_BZL_PLAYBOOK"
ENV_ANSIBLE_BZL_PACKAGE = "ANSIBLE_BZL_PACKAGE"
ENV_ANSIBLE_BZL_CONFIG = "ANSIBLE_BZL_CONFIG"
ENV_ANSIBLE_BZL_LAUNCHER_NAME = "ANSIBLE_BZL_LAUNCHER_NAME"
ENV_ANSIBLE_BZL_INVENTORY_HOSTS = "ANSIBLE_BZL_INVENTORY_HOSTS"
ENV_ANSIBLE_BZL_ROLES = "ANSIBLE_BZL_ROLES"

RUNFILES: Optional[Runfiles] = None


def _create_runfiles() -> Optional[Runfiles]:
    """Create the runfiles lookup, preferring the runfiles directory.

    A manifest resolves source files into the checkout, where files generated
    by Bazel are absent. In a runfiles directory a role's generated files sit
    next to its sources, so one is used whenever it exists: the directory the
    venv rendered from its runfiles collection, or the one Bazel built.

    Returns:
        The runfiles object, if runfiles could be located.
    """
    for var in ("RULES_VENV_RUNFILES_DIR", "RUNFILES_DIR"):
        runfiles_dir = os.getenv(var)
        if runfiles_dir and os.path.isdir(runfiles_dir):
            return Runfiles.CreateDirectoryBased(runfiles_dir)
    return Runfiles.Create()


def _rlocation(rlocationpath: str) -> Path:
    """Look up a runfile and ensure the file exists

    Args:
        rlocationpath: The runfile key

    Returns:
        The requested runifle as an absolute path.
    """
    if not RUNFILES:
        raise EnvironmentError("Failed to locate runfiles")
    runfile = RUNFILES.Rlocation(rlocationpath, os.getenv("TEST_WORKSPACE"))
    if not runfile:
        raise FileNotFoundError(f"Failed to find runfile: {rlocationpath}")
    path = Path(runfile).absolute()
    if not path.exists():
        raise FileNotFoundError(f"Runfile does not exist: ({rlocationpath}) {path}")
    return path


def _env(name: str) -> str:
    """Read a required environment variable set by the generated entrypoint.

    Args:
        name: The name of the variable.

    Returns:
        The value.
    """
    env = os.getenv(name)
    if env is None:
        raise EnvironmentError("{} is not set".format(name))
    return env


def get_playbook() -> Path:
    """Get the path of the playbook to run.

    Returns:
        The path to the playbook to run
    """
    return _rlocation(_env(ENV_ANSIBLE_BZL_PLAYBOOK))


def get_inventory_hosts() -> Path:
    """Get the path to the inventory `hosts` file.

    Returns:
        The path to `hosts`.
    """
    return _rlocation(_env(ENV_ANSIBLE_BZL_INVENTORY_HOSTS))


def get_ansible_config() -> Path:
    """Get the path to the ansible.cfg file given to the `ansible_playbook` rule.

    Returns:
        The path to the ansible config
    """
    return _rlocation(_env(ENV_ANSIBLE_BZL_CONFIG))


def get_ansible_package() -> str:
    """Return the package name of the `ansible_playbook` target

    Returns:
        The Bazel package name of the current target.
    """
    return _env(ENV_ANSIBLE_BZL_PACKAGE)


def get_roles_path() -> List[Path]:
    """Get the directories containing the `ansible_role` targets of the playbook.

    Each role is described by one of its files and the number of path
    components from that file up to the directory containing the role, so the
    directory resolves wherever the file does.

    Returns:
        The directories to put on `ANSIBLE_ROLES_PATH`.
    """
    roles_path: List[Path] = []
    for role in json.loads(_env(ENV_ANSIBLE_BZL_ROLES)):
        directory = _rlocation(role["file"]).parents[role["depth"] - 1]
        if directory not in roles_path:
            roles_path.append(directory)
    return roles_path


def get_ansible_bin() -> Path:
    """Locate the ansible-playbook binary

    Returns:
        A python entrypoint.
    """
    path = Path(__file__).absolute().parent / "scripts/ansible_playbook.py"
    if not path.exists():
        raise FileNotFoundError(path)

    return path


def get_working_directory() -> Path:
    """Get the directory the playbook was invoked from.

    Under `bazel run` the process is started inside the runfiles tree and the
    directory `bazel` was invoked from is passed as `BUILD_WORKING_DIRECTORY`.
    Anywhere else, such as a published binary or zipapp, the current directory
    is already the one the user invoked from. Ansible is run from this
    directory so its own working directory conventions hold, relative paths
    given on the command line resolve against it, and it is the root of the
    vault password file lookup.

    Returns:
        The working directory.
    """
    env = os.getenv("BUILD_WORKING_DIRECTORY")
    if env:
        return Path(env)
    return Path.cwd()


def find_vault_key(working_dir: Path) -> Optional[Path]:
    """Locate the vault password file

    The file is `.vault_pass`, or `.vault_pass/<environment>` for inventories
    laid out as `inventories/<environment>/hosts`. It is looked for in the
    playbook's package below the working directory (for invocations from a
    workspace root), then in the working directory and each directory above
    it. Under `bazel run` the package and the workspace root are checked as
    well regardless of where `bazel` was invoked from.

    Args:
        working_dir: The directory the playbook was invoked from.

    Returns:
        The path to the vault password file if found.
    """
    # Ansible's own mechanism takes precedence.
    if "ANSIBLE_VAULT_PASSWORD_FILE" in os.environ:
        return None

    hosts_file = get_inventory_hosts()
    if hosts_file.parent.parent.name == "inventories":
        vault_pass_file = Path(".vault_pass") / hosts_file.parent.name
    else:
        vault_pass_file = Path(".vault_pass")

    package = get_ansible_package()
    candidates = [working_dir / package, working_dir, *working_dir.parents]

    workspace = os.getenv("BUILD_WORKSPACE_DIRECTORY")
    if workspace:
        candidates.extend([Path(workspace) / package, Path(workspace)])

    for directory in candidates:
        vault_key = directory / vault_pass_file
        if vault_key.is_file():
            return vault_key.absolute()

    return None


def run_ansible(
    playbook: Path,
    working_dir: Path,
    vault_password_file: Optional[Path] = None,
) -> subprocess.CompletedProcess:
    """Run ansible-playbook

    Args:
        playbook: The path to the playbook to run.
        working_dir: The directory to run ansible from.
        vault_password_file: The vault password file to use. E.g. `/ansible/.vault-pass/<inventory>`

    Returns:
        The completed process.
    """
    ansible = get_ansible_bin()

    inventory = get_inventory_hosts()

    command = [
        sys.executable,
        "-B",  # don't write .pyc files on import; also PYTHONDONTWRITEBYTECODE=x
        "-s",  # don't add user site directory to sys.path; also PYTHONNOUSERSITE
        "-P",  # safe paths (available in Python 3.11)
        str(ansible),
        str(playbook),
        f"--inventory={inventory}",
    ]

    if vault_password_file:
        command.append(
            f"--vault-password-file={vault_password_file}",
        )

    command.extend(sys.argv[1:])

    env = dict(os.environ)
    cfg = get_ansible_config()
    if cfg and "ANSIBLE_CONFIG" not in env:
        env.update({"ANSIBLE_CONFIG": str(cfg)})

    # Roles from `ansible_role` targets are found by name through the roles path.
    roles_path = [str(path) for path in get_roles_path()]
    if roles_path:
        if env.get("ANSIBLE_ROLES_PATH"):
            roles_path.append(env["ANSIBLE_ROLES_PATH"])
        env["ANSIBLE_ROLES_PATH"] = os.pathsep.join(roles_path)

    logging.debug("Running subcommand: %s", " ".join(command))
    return subprocess.run(command, cwd=working_dir, env=env, check=False)


def main() -> None:
    """The main entrypoint of the script."""
    if "RULES_ANSIBLE_DEBUG" in os.environ:
        logging.basicConfig(level=logging.DEBUG)

    global RUNFILES
    RUNFILES = _create_runfiles()

    working_dir = get_working_directory()
    playbook = get_playbook()

    # Vault encrypted files are decrypted in memory by Ansible itself. Nothing
    # is ever written to disk, the launcher only locates the password file.
    vault_key = find_vault_key(working_dir)

    result = run_ansible(
        playbook=playbook,
        working_dir=working_dir,
        vault_password_file=vault_key,
    )

    sys.exit(result.returncode)


if __name__ == "__main__":
    main()
