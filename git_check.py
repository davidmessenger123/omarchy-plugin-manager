#!/usr/bin/env python3
import ipaddress
import json
import os
import re
import selectors
import signal
import stat
import subprocess
import sys
import time
from urllib.parse import unquote, urlsplit

MAX_OUTPUT = 8192
MAX_CONFIG_BYTES = 256 * 1024
FETCH_TIMEOUT = 12.0
COMMAND_TIMEOUT = 4.0
SYSTEM_BINDIRS = ("/usr/local/bin", "/usr/bin", "/bin")
SYSTEM_PATH = ":".join(SYSTEM_BINDIRS)
HEX_RE = re.compile(r"^[0-9a-f]{40,64}$")
GIT_DIR_RE = re.compile(r"^gitdir:\s*(.+?)\s*$", re.IGNORECASE)
UNSAFE_KEYS = {
    "hookspath", "sshcommand", "askpass", "fsmonitor", "pager", "editor",
    "alternaterefscommand", "attributesfile", "worktree", "gitproxy",
}
UNSAFE_SECTIONS = {"filter", "merge", "diff", "mergetool", "submodule"}
ISOLATED_CONFIG = (
    "core.hooksPath=/dev/null",
    "core.fsmonitor=false",
    "core.sshCommand=",
    "core.askPass=",
    "credential.helper=",
    "http.proxy=",
    "http.followRedirects=false",
    "protocol.file.allow=never",
    "protocol.ssh.allow=never",
    "protocol.git.allow=never",
    "protocol.ext.allow=never",
    "protocol.https.allow=always",
    "uploadpack.allowFilter=never",
    "fetch.writeCommitGraph=false",
)


class GitConfigError(Exception):
    pass


def _system_executable(name):
    for directory in SYSTEM_BINDIRS:
        candidate = os.path.join(directory, name)
        try:
            resolved = os.path.realpath(candidate)
            info = os.stat(resolved)
        except OSError:
            continue
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0
                or stat.S_IMODE(info.st_mode) & 0o022):
            continue
        if not (resolved.startswith("/usr/") or resolved.startswith("/bin/")):
            continue
        return resolved
    return None


def trusted_git_path():
    return _system_executable("git")


def _directory_is_safe(path, final=True):
    try:
        absolute = os.path.abspath(path)
        if absolute != path or not os.path.isabs(path):
            return False
        current = "/"
        parts = absolute.split(os.sep)[1:]
        for index, component in enumerate(parts):
            current = os.path.join(current, component)
            info = os.lstat(current)
            mode = stat.S_IMODE(info.st_mode)
            if not stat.S_ISDIR(info.st_mode) or info.st_uid not in (0, os.geteuid()):
                return False
            if mode & 0o022 and not (info.st_uid == 0 and mode & 0o1000):
                return False
            if not final and index == len(parts) - 1:
                return False
        return True
    except OSError:
        return False


def valid_directory(value):
    if not isinstance(value, str) or not value or len(value) > 4096:
        return None
    if "\x00" in value or any(ord(ch) < 32 or ord(ch) == 127 for ch in value):
        return None
    if not os.path.isabs(value) or os.path.islink(value):
        return None
    path = os.path.realpath(value)
    if path == "/" or path != value or not os.path.isdir(path) or not _directory_is_safe(path):
        return None
    return path


def _read_regular(path, limit):
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    try:
        fd = os.open(path, flags)
    except OSError:
        return None
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) & 0o022
                or info.st_size > limit):
            return None
        data = bytearray()
        while len(data) <= limit:
            chunk = os.read(fd, min(65536, limit + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
        if len(data) > limit:
            return None
        return bytes(data)
    finally:
        os.close(fd)


def git_directory(path):
    dotgit = os.path.join(path, ".git")
    try:
        info = os.lstat(dotgit)
    except OSError as error:
        raise GitConfigError("missing git directory") from error
    if stat.S_ISDIR(info.st_mode):
        if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o022:
            raise GitConfigError("unsafe git directory")
        return dotgit
    if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) & 0o022:
        raise GitConfigError("unsafe git directory pointer")
    raw = _read_regular(dotgit, 4096)
    if raw is None:
        raise GitConfigError("unreadable git directory pointer")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise GitConfigError("invalid git directory pointer") from error
    match = GIT_DIR_RE.match(text)
    if not match:
        raise GitConfigError("invalid git directory pointer")
    target = match.group(1)
    if not os.path.isabs(target):
        target = os.path.join(path, target)
    if os.path.islink(target):
        raise GitConfigError("symlinked git directory")
    target = os.path.realpath(target)
    repository_root = os.path.realpath(path)
    if target != repository_root and not target.startswith(repository_root + os.sep):
        raise GitConfigError("git directory is outside repository")
    try:
        target_info = os.stat(target)
    except OSError as error:
        raise GitConfigError("missing git directory") from error
    if not stat.S_ISDIR(target_info.st_mode) or target_info.st_uid != os.geteuid() or stat.S_IMODE(target_info.st_mode) & 0o022:
        raise GitConfigError("unsafe git directory")
    return target


def _decode_value(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        try:
            result = json.loads(value)
        except (TypeError, ValueError) as error:
            raise GitConfigError("invalid quoted Git config") from error
        if not isinstance(result, str):
            raise GitConfigError("invalid Git config value")
        return result
    if len(value) >= 2 and value[0] == "'" and value[-1] == "'":
        return value[1:-1]
    return value


def _parse_header(header):
    header = header.strip()
    if not header:
        return "", ""
    match = re.fullmatch(r'([^"\s]+)(?:\s+"((?:[^"\\]|\\.)*)")?', header)
    if not match:
        raise GitConfigError("invalid Git config section")
    return match.group(1).lower(), match.group(2) or ""


def _validate_config_section(section, subsection, key):
    if section in ("include", "includeif", "url", "http", "credential") or section in UNSAFE_SECTIONS:
        raise GitConfigError("repository-controlled Git configuration is not allowed")
    if section == "core" and key in UNSAFE_KEYS:
        raise GitConfigError("repository-controlled Git configuration is not allowed")
    if section == "remote":
        if subsection.lower() != "origin" or key not in ("url", "fetch"):
            raise GitConfigError("repository-controlled Git remote configuration is not allowed")
    if section == "extensions" and key == "worktreeconfig":
        raise GitConfigError("repository-controlled Git configuration is not allowed")
    return


def origin_url(path):
    try:
        gitdir = git_directory(path)
    except GitConfigError:
        raise
    config_path = os.path.join(gitdir, "config")
    try:
        config_info = os.lstat(config_path)
    except OSError as error:
        raise GitConfigError("missing repository config") from error
    if (not stat.S_ISREG(config_info.st_mode) or config_info.st_uid != os.geteuid()
            or config_info.st_nlink != 1 or stat.S_IMODE(config_info.st_mode) & 0o022):
        raise GitConfigError("unsafe repository config")
    raw = _read_regular(config_path, MAX_CONFIG_BYTES)
    if raw is None:
        raise GitConfigError("unreadable repository config")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise GitConfigError("invalid repository config") from error
    section = ""
    subsection = ""
    urls = []
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or stripped.startswith(";"):
            continue
        if line[:1].isspace() and "=" not in stripped:
            raise GitConfigError("invalid repository config continuation")
        if stripped.endswith("\\"):
            raise GitConfigError("repository config continuations are not allowed")
        if stripped.startswith("["):
            if not stripped.endswith("]"):
                raise GitConfigError("invalid repository config")
            section, subsection = _parse_header(stripped[1:-1])
            continue
        if "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        key = key.strip().lower()
        if not re.fullmatch(r"[A-Za-z0-9-]+", key):
            continue
        _validate_config_section(section, subsection, key)
        if section == "core" and key == "bare" and _decode_value(value).lower() != "false":
            raise GitConfigError("repository-controlled Git configuration is not allowed")
        if section == "remote" and subsection.lower() == "origin" and key == "url":
            urls.append(_decode_value(value))
    if len(urls) != 1:
        raise GitConfigError("origin must have exactly one URL")
    return trusted_https_remote(urls[0])


def trusted_https_remote(value):
    if not isinstance(value, str) or not value or len(value) > 4096:
        raise GitConfigError("remote URL is invalid")
    if value != value.strip() or any(ord(ch) < 33 or ord(ch) == 127 for ch in value):
        raise GitConfigError("remote URL is invalid")
    if "\\" in value:
        raise GitConfigError("remote URL is invalid")
    try:
        parts = urlsplit(value)
        host = parts.hostname
        port = parts.port
    except (TypeError, ValueError) as error:
        raise GitConfigError("remote URL is invalid") from error
    if parts.scheme.lower() != "https" or not host or parts.username is not None:
        raise GitConfigError("remote URL must use HTTPS")
    if parts.password is not None or parts.query or parts.fragment or "@" in parts.netloc:
        raise GitConfigError("remote URL is invalid")
    if port is not None and (port < 1 or port > 65535):
        raise GitConfigError("remote URL is invalid")
    host = host.rstrip(".").lower()
    if not host or host == "localhost" or host.endswith(".localhost") or host.endswith(".local"):
        raise GitConfigError("remote host is not trusted")
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        address = None
    if address is not None:
        raise GitConfigError("remote host is not trusted")
    try:
        ascii_host = host.encode("idna").decode("ascii")
    except UnicodeError as error:
        raise GitConfigError("remote host is invalid") from error
    labels = ascii_host.split(".")
    if len(ascii_host) > 253 or any(
            not label or len(label) > 63 or not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?", label)
            for label in labels):
        raise GitConfigError("remote host is invalid")
    decoded_path = unquote(parts.path)
    if (not parts.path.startswith("/") or len(parts.path) > 2048
            or any(ord(char) < 32 or ord(char) == 127 for char in decoded_path)
            or "\\" in decoded_path):
        raise GitConfigError("remote URL is invalid")
    path_parts = decoded_path.split("/")
    if len([part for part in path_parts if part]) < 2 or any(part in (".", "..") for part in path_parts):
        raise GitConfigError("remote URL is invalid")
    canonical = "https://" + ascii_host
    if port is not None and port != 443:
        canonical += ":" + str(port)
    return canonical + parts.path


def _safe_environment():
    return {
        "PATH": SYSTEM_PATH,
        "HOME": "/nonexistent",
        "LANG": "C",
        "LC_ALL": "C",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_CONFIG_SYSTEM": os.devnull,
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_ASKPASS": "/bin/false",
        "GIT_SSH_COMMAND": "/bin/false",
        "GIT_OPTIONAL_LOCKS": "0",
    }


def _kill_group(process):
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except OSError:
        try:
            process.kill()
        except OSError:
            pass


def run_git(path, args, timeout, git_path=None):
    if valid_directory(path) != path:
        return 1, b""
    try:
        git_directory(path)
    except GitConfigError:
        return 1, b""
    if not isinstance(args, (list, tuple)) or not args or len(args) > 64 or any(
            not isinstance(value, str) or "\x00" in value or "\r" in value or "\n" in value
            for value in args):
        return 1, b""
    executable = trusted_git_path()
    if git_path is not None:
        candidate = os.path.realpath(git_path)
        if not executable or candidate != executable:
            return 1, b""
    if not executable:
        return 1, b""
    command = [executable, "--no-optional-locks", "--no-advice"]
    for value in ISOLATED_CONFIG:
        command.extend(("-c", value))
    command.extend(("-C", path))
    command.extend(args)
    try:
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            env=_safe_environment(),
            close_fds=True,
        )
    except OSError:
        return 1, b""
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    output = bytearray()
    deadline = time.monotonic() + timeout
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                _kill_group(process)
                process.wait()
                return 124, bytes(output[:MAX_OUTPUT])
            for key, _ in selector.select(min(0.25, remaining)):
                chunk = os.read(key.fileobj.fileno(), 4096)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                if len(output) < MAX_OUTPUT:
                    output.extend(chunk[:MAX_OUTPUT - len(output)])
                if len(output) >= MAX_OUTPUT:
                    _kill_group(process)
                    process.wait()
                    return 125, bytes(output)
            if process.poll() is not None and not selector.get_map():
                break
    finally:
        selector.close()
        try:
            process.stdout.close()
        except OSError:
            pass
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        _kill_group(process)
        process.wait()
    return process.returncode, bytes(output[:MAX_OUTPUT])


def main():
    if len(sys.argv) != 2:
        return 2
    path = valid_directory(sys.argv[1])
    if path is None:
        return 2
    try:
        remote = origin_url(path)
    except GitConfigError:
        return 4
    try:
        code, _ = run_git(path, ["fetch", "--quiet", "--no-tags", "--no-recurse-submodules", remote, "HEAD"], FETCH_TIMEOUT)
        if code != 0:
            return 4
        try:
            if origin_url(path) != remote:
                return 4
        except GitConfigError:
            return 4
        code, full_bytes = run_git(path, ["rev-parse", "HEAD"], COMMAND_TIMEOUT)
        full = full_bytes.decode("ascii", "ignore").strip()
        if code != 0 or not HEX_RE.fullmatch(full):
            return 3
        code, short_bytes = run_git(path, ["rev-parse", "--short=7", "HEAD"], COMMAND_TIMEOUT)
        short = short_bytes.decode("ascii", "ignore").strip()
        if code != 0 or not re.fullmatch(r"[0-9a-f]{7,64}", short):
            return 3
        code, fetched_bytes = run_git(path, ["rev-parse", "FETCH_HEAD"], COMMAND_TIMEOUT)
        fetched = fetched_bytes.decode("ascii", "ignore").strip()
        if code != 0 or not HEX_RE.fullmatch(fetched):
            return 4
        if fetched == full:
            sys.stdout.write(short + "\nUP-TO-DATE\n")
            return 0
        code, _ = run_git(path, ["merge-base", "--is-ancestor", "HEAD", "FETCH_HEAD"], COMMAND_TIMEOUT)
        if code == 1:
            sys.stdout.write(short + "\nDIVERGED\nunpublished commits\n")
            return 0
        if code != 0:
            return 3
        code, status_bytes = run_git(path, ["status", "--porcelain", "--untracked-files=normal"], COMMAND_TIMEOUT)
        if code != 0:
            return 3
        if status_bytes.strip():
            sys.stdout.write(short + "\nDIRTY\nlocal changes\n")
            return 0
        sys.stdout.write(short + "\nSTALE\n")
        return 0
    except (OSError, UnicodeError, ValueError, GitConfigError):
        return 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception:
        raise SystemExit(1)
