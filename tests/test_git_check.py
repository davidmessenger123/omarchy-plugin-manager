import contextlib
import io
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import git_check


class GitCheckTests(unittest.TestCase):
    def run_check(self, path):
        return subprocess.run(
            [sys.executable, "git_check.py", path],
            capture_output=True,
            text=True,
            timeout=5,
        )

    def test_rejects_unsafe_directories(self):
        with tempfile.TemporaryDirectory() as directory:
            for path in (".", "/", os.path.join(directory, "missing"), directory + "/x;rm"):
                result = self.run_check(path)
                self.assertNotEqual(result.returncode, 0)

    def test_rejects_non_https_and_untrusted_remote_urls(self):
        self.assertEqual(
            git_check.trusted_https_remote("https://github.com/owner/repository.git"),
            "https://github.com/owner/repository.git",
        )
        for value in (
            "file:///tmp/repository",
            "ssh://git@github.com/owner/repository.git",
            "http://github.com/owner/repository.git",
            "https://127.0.0.1/owner/repository.git",
            "https://github.com/owner/../repository.git",
        ):
            with self.subTest(value=value):
                with self.assertRaises(git_check.GitConfigError):
                    git_check.trusted_https_remote(value)

    def test_rejects_repository_config_includes_and_hooks(self):
        with tempfile.TemporaryDirectory() as directory:
            os.mkdir(os.path.join(directory, ".git"))
            config = os.path.join(directory, ".git", "config")
            with open(config, "w", encoding="utf-8") as handle:
                handle.write("[include]\n\tpath = /tmp/other\n")
            with self.assertRaises(git_check.GitConfigError):
                git_check.origin_url(directory)
            with open(config, "w", encoding="utf-8") as handle:
                handle.write("[core]\n\thooksPath = /tmp/hook\n[remote \"origin\"]\n\turl = https://github.com/o/r\n")
            with self.assertRaises(git_check.GitConfigError):
                git_check.origin_url(directory)

    def test_accepts_standard_non_bare_repository_config(self):
        with tempfile.TemporaryDirectory() as directory:
            os.mkdir(os.path.join(directory, ".git"))
            config = os.path.join(directory, ".git", "config")
            with open(config, "w", encoding="utf-8") as handle:
                handle.write(
                    "[core]\n"
                    "\trepositoryformatversion = 0\n"
                    "\tfilemode = true\n"
                    "\tbare = false\n"
                    "\tlogallrefupdates = true\n"
                    "[remote \"origin\"]\n"
                    "\turl = https://github.com/owner/repository.git\n"
                    "\tfetch = +refs/heads/*:refs/remotes/origin/*\n"
                    "[branch \"main\"]\n"
                    "\tremote = origin\n"
                    "\tmerge = refs/heads/main\n"
                )
            self.assertEqual(
                git_check.origin_url(directory),
                "https://github.com/owner/repository.git",
            )
            with open(config, "w", encoding="utf-8") as handle:
                handle.write("[core]\n\tbare = true\n")
            with self.assertRaises(git_check.GitConfigError):
                git_check.origin_url(directory)

    def test_fetch_uses_validated_url_instead_of_repository_remote_name(self):
        with tempfile.TemporaryDirectory() as directory:
            calls = []
            values = [
                (0, b""),
                (0, b"a" * 40 + b"\n"),
                (0, b"abcdef0\n"),
                (0, b"a" * 40 + b"\n"),
                (1, b""),
            ]
            def fake_run(path, args, timeout):
                calls.append(args)
                return values[len(calls) - 1]
            with mock.patch.object(git_check, "valid_directory", return_value=directory), \
                 mock.patch.object(git_check, "origin_url", return_value="https://github.com/o/r.git"), \
                 mock.patch.object(git_check, "run_git", side_effect=fake_run), \
                 mock.patch.object(sys, "argv", ["git_check.py", directory]), \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(git_check.main(), 0)
            self.assertIn("https://github.com/o/r.git", calls[0])
            self.assertNotIn("origin", calls[0])

    def test_remote_is_canonical_and_rejects_encoded_traversal(self):
        self.assertEqual(
            git_check.trusted_https_remote("https://API.GITHUB.COM:443/owner/repository.git"),
            "https://api.github.com/owner/repository.git",
        )
        for value in (
            "https://github.com/owner/%2e%2e/repository.git",
            "https://github.com/owner/repository.git?redirect=1",
            "https://github.com/owner",
        ):
            with self.subTest(value=value):
                with self.assertRaises(git_check.GitConfigError):
                    git_check.trusted_https_remote(value)

    def test_system_git_resolver_does_not_use_path_lookup(self):
        path = git_check.trusted_git_path()
        self.assertTrue(path and os.path.isabs(path))
        self.assertEqual(path, os.path.realpath(path))
        environment = git_check._safe_environment()
        self.assertEqual(environment["PATH"], git_check.SYSTEM_PATH)
        self.assertEqual(environment["GIT_CONFIG_NOSYSTEM"], "1")
        self.assertEqual(environment["GIT_CONFIG_GLOBAL"], os.devnull)


if __name__ == "__main__":
    unittest.main()
