import os
import subprocess
import tempfile
import unittest
from unittest import mock

import git_update


class GitUpdateTests(unittest.TestCase):
    def test_update_helper_runs_under_isolated_python(self):
        helper = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "git_update.py"))
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                ["/usr/bin/python3", "-I", helper, "all"],
                cwd=directory,
                env={"HOME": directory},
                capture_output=True,
                text=True,
                timeout=5,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("ModuleNotFoundError", result.stderr)

    def test_update_fetches_validated_url_without_origin_name(self):
        calls = []
        values = [
            (0, b""),
            (0, b"a" * 40 + b"\n"),
            (0, b"b" * 40 + b"\n"),
            (0, b""),
            (0, b""),
            (0, b""),
            (0, b"b" * 40 + b"\n"),
        ]
        def fake_run(path, args, timeout=git_update.COMMAND_TIMEOUT):
            calls.append(args)
            return values[len(calls) - 1]
        with mock.patch.object(git_update, "valid_path", return_value="/tmp/plugin"), \
             mock.patch.object(git_update.git_check, "origin_url", return_value="https://github.com/o/r.git"), \
             mock.patch.object(git_update, "run_git", side_effect=fake_run), \
             mock.patch.object(git_update, "validate_plugin", return_value=True):
            self.assertEqual(git_update.update_one("/tmp/plugin"), 0)
        self.assertIn("https://github.com/o/r.git", calls[0])
        self.assertNotIn("origin", calls[0])
        self.assertTrue(any("merge" in call for call in calls))

    def test_failed_validation_rolls_back_and_verifies_old_commit(self):
        calls = []
        values = [
            (0, b""),
            (0, b"a" * 40 + b"\n"),
            (0, b"b" * 40 + b"\n"),
            (0, b""),
            (0, b""),
            (0, b""),
            (0, b"b" * 40 + b"\n"),
            (0, b""),
            (0, b"a" * 40 + b"\n"),
        ]
        def fake_run(path, args, timeout=git_update.COMMAND_TIMEOUT):
            calls.append(args)
            return values[len(calls) - 1]
        with mock.patch.object(git_update, "valid_path", return_value="/tmp/plugin"), \
             mock.patch.object(git_update.git_check, "origin_url", return_value="https://github.com/o/r.git"), \
             mock.patch.object(git_update, "run_git", side_effect=fake_run), \
             mock.patch.object(git_update, "validate_plugin", return_value=False):
            self.assertEqual(git_update.update_one("/tmp/plugin"), 5)
        self.assertTrue(any(call[:2] == ["reset", "--hard"] for call in calls))
        self.assertEqual(calls[-1][:2], ["rev-parse", "HEAD"])

    def test_update_rejects_invalid_remote_before_git(self):
        with mock.patch.object(git_update, "valid_path", return_value="/tmp/plugin"), \
             mock.patch.object(git_update.git_check, "origin_url", side_effect=git_update.git_check.GitConfigError("bad")), \
             mock.patch.object(git_update, "run_git") as run:
            self.assertEqual(git_update.update_one("/tmp/plugin"), 4)
            run.assert_not_called()

    def test_all_plugin_discovery_is_bounded_and_skips_non_git(self):
        with tempfile.TemporaryDirectory() as directory:
            os.mkdir(os.path.join(directory, "one"))
            os.mkdir(os.path.join(directory, "two"))
            os.mkdir(os.path.join(directory, "two", ".git"))
            with mock.patch.object(git_update, "MAX_PLUGINS", 1):
                paths = git_update.plugin_directories(directory)
            self.assertEqual(len(paths), 1)
            self.assertTrue(os.path.exists(os.path.join(paths[0], ".git")))


if __name__ == "__main__":
    unittest.main()
