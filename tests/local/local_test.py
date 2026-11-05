"""Run the `local` playbook against localhost."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from python.runfiles import Runfiles


class LocalTest(unittest.TestCase):
    """Test roles from other packages, their python deps, and built outputs."""

    def test_playbook(self) -> None:
        """The playbook installs the built artifacts and its asserts pass."""
        runfiles = Runfiles.Create()
        assert runfiles, "Failed to locate runfiles."
        playbook = runfiles.Rlocation(os.environ["PLAYBOOK"])
        assert playbook and Path(playbook).exists(), os.environ["PLAYBOOK"]

        tmp = Path(tempfile.mkdtemp(dir=os.environ.get("TEST_TMPDIR")))
        release_dir = tmp / "release"
        env = dict(os.environ)
        env.update(
            {
                "HOME": str(tmp),
                "ANSIBLE_NOCOLOR": "1",
                "RELEASE_DIR": str(release_dir),
            }
        )

        proc = subprocess.run(
            [playbook],
            cwd=tmp,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            encoding="utf-8",
            check=False,
        )
        self.assertEqual(0, proc.returncode, proc.stdout)
        self.assertIn("failed=0", proc.stdout)
        self.assertEqual(
            "hello, bazel\n", (release_dir / "artifact.txt").read_text(encoding="utf-8")
        )
        self.assertEqual(
            "built by bazel\n",
            (release_dir / "build_info.txt").read_text(encoding="utf-8"),
        )


if __name__ == "__main__":
    unittest.main()
