#!/usr/bin/env python3
import os
import selectors
import signal
import stat
import subprocess
import sys
import time

SYSTEM_BINDIRS = ("/usr/local/bin", "/usr/share/omarchy/bin", "/usr/bin", "/bin")
SYSTEM_PATH = ":".join(SYSTEM_BINDIRS)
DEFAULT_MAX_OUTPUT = 2 * 1024 * 1024
DEFAULT_TIMEOUT = 15.0
READ_SIZE = 65536
_ACTIVE_PROCESS = None


def _terminate(signum, frame):
    if _ACTIVE_PROCESS is not None:
        kill_group(_ACTIVE_PROCESS)
    os._exit(128 + signum)


def resolve_executable(value):
    if not isinstance(value, str) or not value or len(value) > 4096:
        return None
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        return None
    candidates = [value] if os.path.isabs(value) else [os.path.join(item, value) for item in SYSTEM_BINDIRS]
    for candidate in candidates:
        try:
            resolved = os.path.realpath(candidate)
            info = os.stat(resolved)
        except OSError:
            continue
        if (stat.S_ISREG(info.st_mode) and info.st_uid == 0
                and not stat.S_IMODE(info.st_mode) & 0o022
                and os.access(resolved, os.X_OK)):
            return resolved
    return None


def child_environment():
    env = {
        "PATH": SYSTEM_PATH,
        "LANG": "C",
        "LC_ALL": "C",
        "OMARCHY_PATH": "/usr/share/omarchy",
    }
    for name in ("HOME", "USER", "LOGNAME", "XDG_RUNTIME_DIR"):
        value = os.environ.get(name, "")
        if value and len(value) <= 4096 and "\x00" not in value and "\r" not in value and "\n" not in value:
            if name == "HOME" and not os.path.isabs(value):
                continue
            env[name] = value
    return env


def kill_group(process):
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except OSError:
        try:
            process.kill()
        except OSError:
            pass


def parse_args(argv):
    if not argv or argv[0] != "run":
        raise ValueError("run mode is required")
    maximum = DEFAULT_MAX_OUTPUT
    timeout = DEFAULT_TIMEOUT
    index = 1
    while index < len(argv) and argv[index] != "--":
        option = argv[index]
        if option not in ("--max-output", "--timeout") or index + 1 >= len(argv):
            raise ValueError("invalid option")
        value = argv[index + 1]
        index += 2
        try:
            if option == "--timeout":
                timeout = float(value)
            else:
                maximum = int(value)
        except ValueError as error:
            raise ValueError("invalid option value") from error
    if index >= len(argv) or argv[index] != "--" or not argv[index + 1:]:
        raise ValueError("command is required")
    if maximum < 1 or maximum > 16 * 1024 * 1024 or timeout < 1 or timeout > 120:
        raise ValueError("invalid limit")
    return maximum, timeout, list(argv[index + 1:])


def run(command, maximum, timeout):
    global _ACTIVE_PROCESS
    if not isinstance(command, (list, tuple)) or not command or len(command) > 32:
        raise ValueError("invalid command")
    executable = resolve_executable(command[0])
    if executable is None:
        raise ValueError("executable is not trusted")
    values = [executable]
    total = 0
    for value in command[1:]:
        if not isinstance(value, str) or len(value) > 1024 * 1024 or any(ord(char) < 32 or ord(char) == 127 for char in value):
            raise ValueError("invalid argument")
        total += len(value)
        if total > 1024 * 1024:
            raise ValueError("command is too large")
        values.append(value)
    try:
        process = subprocess.Popen(
            values,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            close_fds=True,
            env=child_environment(),
            bufsize=0,
        )
    except OSError as error:
        raise RuntimeError(str(error)) from error
    _ACTIVE_PROCESS = process
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    output = bytearray()
    deadline = time.monotonic() + timeout
    status = 0
    try:
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                status = 124
                kill_group(process)
                process.wait()
                break
            for key, _ in selector.select(min(0.25, remaining)):
                chunk = os.read(key.fileobj.fileno(), min(READ_SIZE, maximum + 1 - len(output)))
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                output.extend(chunk)
                if len(output) > maximum:
                    status = 125
                    kill_group(process)
                    process.wait()
                    break
            if status:
                break
    except Exception:
        status = 1
        kill_group(process)
        try:
            process.wait(timeout=1)
        except (OSError, subprocess.TimeoutExpired):
            pass
    finally:
        selector.close()
        try:
            process.stdout.close()
        except OSError:
            pass
        _ACTIVE_PROCESS = None
    if status:
        return status, bytes(output[:maximum])
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        kill_group(process)
        process.wait()
    _ACTIVE_PROCESS = None
    return process.returncode, bytes(output)


def main(argv=None):
    try:
        signal.signal(signal.SIGTERM, _terminate)
        signal.signal(signal.SIGINT, _terminate)
        maximum, timeout, command = parse_args(list(sys.argv[1:] if argv is None else argv))
        code, output = run(command, maximum, timeout)
        if output and not output.endswith(b"\n") and len(output) < maximum:
            output += b"\n"
        try:
            sys.stdout.buffer.write(output)
            sys.stdout.buffer.flush()
        except AttributeError:
            sys.stdout.write(output.decode("utf-8", "replace"))
            sys.stdout.flush()
        return code
    except (OSError, RuntimeError, ValueError) as error:
        try:
            sys.stderr.write(str(error)[:512] + "\n")
        except OSError:
            pass
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
