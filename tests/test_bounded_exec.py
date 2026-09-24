import os
import subprocess
import sys
import unittest
from unittest import mock


class BoundedExecTests(unittest.TestCase):
    def test_no_newline_output_is_capped(self):
        result = subprocess.run(
            [
                sys.executable,
                os.path.join(os.path.dirname(__file__), "..", "bounded_exec.py"),
                "run",
                "--max-output",
                "32",
                "--timeout",
                "5",
                "--",
                sys.executable,
                "-c",
                "import sys; sys.stdout.write('x' * 1000)",
            ],
            capture_output=True,
            text=True,
            timeout=5,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertLessEqual(len(result.stdout), 32)

    def test_child_environment_preserves_omarchy_runtime_path(self):
        import bounded_exec
        with mock.patch.dict(os.environ, {"OMARCHY_PATH": "/tmp/untrusted"}, clear=False):
            environment = bounded_exec.child_environment()
        self.assertEqual(environment["OMARCHY_PATH"], "/usr/share/omarchy")

        import bounded_exec
        with mock.patch.dict(os.environ, {"PATH": "/tmp"}):
            self.assertIsNone(bounded_exec.resolve_executable("definitely-not-a-system-command"))


if __name__ == "__main__":
    unittest.main()
