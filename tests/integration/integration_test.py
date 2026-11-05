"""Integration tests which provision docker containers and assert on the results.

The containers are expected to already be running, see `//tests:infra_setup`.
"""

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Dict

from python.runfiles import Runfiles

RECAP_LINE = re.compile(
    r"^(?P<host>\S+)\s+:\s+ok=\d+\s+changed=(?P<changed>\d+)\s+unreachable=(?P<unreachable>\d+)\s+failed=(?P<failed>\d+)",
    re.MULTILINE,
)


def rlocation(env_var: str) -> Path:
    """Locate a runfile named by an environment variable.

    Args:
        env_var: The environment variable holding an rlocationpath.

    Returns:
        The absolute path to the runfile.
    """
    runfiles = Runfiles.Create()
    if not runfiles:
        raise EnvironmentError("Failed to locate runfiles.")
    runfile = runfiles.Rlocation(os.environ[env_var])
    if not runfile:
        raise FileNotFoundError(f"Failed to find runfile: {os.environ[env_var]}")
    path = Path(runfile).absolute()
    if not path.exists():
        raise FileNotFoundError(f"Runfile does not exist: {path}")
    return path


def run_playbook(playbook: Path, working_dir: Path) -> str:
    """Run an `ansible_playbook` executable to completion.

    The executable is run the way a published binary would be, from a plain
    working directory and without any of the `bazel run` environment.

    Args:
        playbook: The path to the executable.
        working_dir: The directory to run from.

    Returns:
        The combined stdout and stderr of the run.
    """
    env = dict(os.environ)
    env.pop("BUILD_WORKING_DIRECTORY", None)
    env.pop("BUILD_WORKSPACE_DIRECTORY", None)
    env.update(
        {
            "HOME": str(working_dir),
            "ANSIBLE_NOCOLOR": "1",
        }
    )

    proc = subprocess.run(
        [str(playbook)],
        cwd=working_dir,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        encoding="utf-8",
        check=False,
    )
    if proc.returncode:
        raise AssertionError(f"{playbook.name} failed:\n{proc.stdout}")
    return proc.stdout


def recap(output: str) -> Dict[str, int]:
    """Parse the number of changed tasks per host from a play recap.

    Args:
        output: The output of `ansible-playbook`.

    Returns:
        A mapping of host name to the number of changed tasks.
    """
    changed = {}
    for match in RECAP_LINE.finditer(output):
        if match.group("failed") != "0" or match.group("unreachable") != "0":
            raise AssertionError(f"Host {match.group('host')} failed:\n{output}")
        changed[match.group("host")] = int(match.group("changed"))
    if not changed:
        raise AssertionError(f"No play recap found:\n{output}")
    return changed


def docker_exec(container: str, *command: str) -> str:
    """Run a command in a container and return its output.

    Args:
        container: The name of the container.
        command: The command to run.

    Returns:
        The combined stdout and stderr of the command.
    """
    return subprocess.run(
        ["docker", "exec", container, *command],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        encoding="utf-8",
        check=True,
    ).stdout


class PlaybookTests(unittest.TestCase):
    """Provision the test containers and assert on the results."""

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(dir=os.environ.get("TEST_TMPDIR")))

    def test_simple(self) -> None:
        """The `simple` playbook installs rust on `web3` and is idempotent."""
        playbook = rlocation("PLAYBOOK_SIMPLE")

        first = recap(run_playbook(playbook, self.tmp))
        self.assertEqual(["web3"], sorted(first))
        self.assertIn("rustc", docker_exec("web3", "rustc", "--version"))

        second = recap(run_playbook(playbook, self.tmp))
        self.assertEqual({"web3": 0}, second, "second run was not idempotent")

    def test_multi_role(self) -> None:
        """The `multi_role` playbook provisions both hosts and is idempotent."""
        playbook = rlocation("PLAYBOOK_MULTI_ROLE")

        first = recap(run_playbook(playbook, self.tmp))
        self.assertEqual(["web2", "web3"], sorted(first))

        # common
        for host in ("web2", "web3"):
            self.assertIn("rulesansible", docker_exec(host, "id", "rulesansible"))

        # web
        self.assertIn("syntax is ok", docker_exec("web3", "nginx", "-t"))

        # db
        self.assertIn("psql", docker_exec("web2", "psql", "--version"))

        second = recap(run_playbook(playbook, self.tmp))
        self.assertEqual({"web2": 0, "web3": 0}, second, "second run was not idempotent")


if __name__ == "__main__":
    unittest.main()
