#!/usr/bin/env python3
import importlib.util
import os
import stat
import subprocess
import sys


def _load_git_check():
    module_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "git_check.py")
    spec = importlib.util.spec_from_file_location("git_check", module_path)
    if spec is None or spec.loader is None:
        raise ImportError("unable to load git_check")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


git_check = _load_git_check()

MAX_PLUGINS = 256
VALIDATE_PATH = "/usr/bin/omarchy-plugin-validate"
FETCH_TIMEOUT = 20.0
COMMAND_TIMEOUT = 8.0


def valid_id(value):
    return (isinstance(value, str) and bool(value) and len(value) <= 128
            and value[0].isascii() and value[0].isalnum()
            and value not in (".", "..", "constructor", "prototype", "__proto__")
            and all(char.isascii() and (char.isalnum() or char in "._-") for char in value))


def valid_path(value):
    return git_check.valid_directory(value)


def run_git(path, args, timeout=COMMAND_TIMEOUT):
    return git_check.run_git(path, args, timeout)


def _trusted_validator():
    try:
        resolved = os.path.realpath(VALIDATE_PATH)
        info = os.stat(resolved)
    except OSError:
        return None
    if (not os.path.isabs(resolved) or not stat.S_ISREG(info.st_mode)
            or info.st_uid != 0 or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) & 0o022
            or not os.access(resolved, os.X_OK)):
        return None
    return resolved


def validate_plugin(path):
    validator = _trusted_validator()
    if validator is None:
        return False
    try:
        process = subprocess.Popen(
            [validator, path],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            close_fds=True,
            env={
                "PATH": git_check.SYSTEM_PATH,
                "HOME": "/nonexistent",
                "LANG": "C",
                "LC_ALL": "C",
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_GLOBAL": os.devnull,
                "GIT_CONFIG_SYSTEM": os.devnull,
                "GIT_TERMINAL_PROMPT": "0",
            },
        )
    except OSError:
        return False
    try:
        process.wait(timeout=15)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, 9)
        except OSError:
            pass
        process.wait()
        return False
    return process.returncode == 0


def update_one(path):
    path = valid_path(path)
    if path is None:
        return 2
    try:
        remote = git_check.origin_url(path)
    except git_check.GitConfigError:
        return 4
    code, _ = run_git(path, ["fetch", "--quiet", "--no-tags", "--no-recurse-submodules", remote, "HEAD"], FETCH_TIMEOUT)
    if code != 0:
        return 4
    try:
        if git_check.origin_url(path) != remote:
            return 4
    except git_check.GitConfigError:
        return 4
    code, full_bytes = run_git(path, ["rev-parse", "HEAD"])
    full = full_bytes.decode("ascii", "ignore").strip()
    if code != 0 or not git_check.HEX_RE.fullmatch(full):
        return 3
    code, fetched_bytes = run_git(path, ["rev-parse", "FETCH_HEAD"])
    fetched = fetched_bytes.decode("ascii", "ignore").strip()
    if code != 0 or not git_check.HEX_RE.fullmatch(fetched):
        return 4
    if full == fetched:
        return 0
    code, _ = run_git(path, ["merge-base", "--is-ancestor", "HEAD", "FETCH_HEAD"])
    if code != 0:
        return 3
    code, status_bytes = run_git(path, ["status", "--porcelain", "--untracked-files=normal"])
    if code != 0 or status_bytes.strip():
        return 3
    try:
        if git_check.origin_url(path) != remote:
            return 4
    except git_check.GitConfigError:
        return 4
    code, _ = run_git(path, ["merge", "--ff-only", "--no-edit", "FETCH_HEAD"])
    if code != 0:
        return 3
    code, merged_bytes = run_git(path, ["rev-parse", "HEAD"])
    merged = merged_bytes.decode("ascii", "ignore").strip()
    try:
        origin_stable = git_check.origin_url(path) == remote
    except git_check.GitConfigError:
        origin_stable = False
    path_stable = valid_path(path) == path
    if code != 0 or merged != fetched or not origin_stable or not path_stable or not validate_plugin(path):
        code, _ = run_git(path, ["reset", "--hard", full])
        if code != 0:
            return 6
        code, current_bytes = run_git(path, ["rev-parse", "HEAD"])
        current = current_bytes.decode("ascii", "ignore").strip()
        if code != 0 or current != full:
            return 6
        return 5
    return 0


def plugin_directories(root):
    root = os.path.abspath(root)
    if git_check.valid_directory(root) != root:
        return []
    result = []
    try:
        entries = list(os.scandir(root))
    except OSError:
        return []
    for entry in entries:
        if len(result) >= MAX_PLUGINS:
            break
        if not entry.is_dir(follow_symlinks=False) or not valid_id(entry.name):
            continue
        path = git_check.valid_directory(entry.path)
        if path is None:
            continue
        try:
            git_check.git_directory(path)
        except git_check.GitConfigError:
            continue
        result.append(path)
    return result


def update_all(root):
    failed = False
    for path in plugin_directories(root):
        if update_one(path) != 0:
            failed = True
    if failed:
        return 1
    return 0


def main(argv=None):
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) == 1 and args[0] == "all":
        home = os.environ.get("HOME", "")
        if not home or len(home) > 4096 or not os.path.isabs(home):
            return 2
        return update_all(os.path.join(home, ".config", "omarchy", "plugins"))
    if len(args) != 1:
        return 2
    return update_one(args[0])


if __name__ == "__main__":
    raise SystemExit(main())
