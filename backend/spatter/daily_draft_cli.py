"""Explicit one-shot invocation of the private Spatter daily draft worker."""
from __future__ import annotations

import json
import os
from pathlib import Path
import signal
import stat
import sys
from typing import Mapping, Sequence

from .draft_preview import (ENV_DIRECTORY, ENV_KEY_FILE, ENV_ORIGIN, ENV_OWNER, ENV_QUOTA,
                            ENV_RETENTION, DraftPreviewStore, read_private_draft_secret)
from .draft_rpc_transport import RPC_WALL_SECONDS
from .draft_worker import run_daily_draft_once, validate_draft_backend, validate_draft_https_origin
from .renderer_cli import (ENV_CLI, ENV_FPS, ENV_HEIGHT, ENV_OUTPUT, ENV_TIMEOUT, ENV_WIDTH,
                           renderer_from_env)

ENV_BACKEND = "SDI_BACKEND_URL"
ENV_SERVICE_KEY_FILE = "SDI_BACKEND_SERVICE_KEY_FILE"
_RENDER_SETTINGS = (ENV_CLI, ENV_OUTPUT, ENV_TIMEOUT, ENV_FPS, ENV_WIDTH, ENV_HEIGHT,
                    ENV_DIRECTORY, ENV_KEY_FILE, ENV_ORIGIN, ENV_OWNER, ENV_QUOTA, ENV_RETENTION)
MAX_PASS_SECONDS = 16 * 60
_USAGE = "Usage: python3 -m backend.spatter.daily_draft_cli --run-once"
_OUTCOMES = {"review_pending": 0, "not_claimed": 3, "failed": 1, "refused": 1}


class _PassDeadline(BaseException):
    """Abort the one-shot worker without a retry or an additional failure RPC."""


def _required(environment: Mapping[str, str], key: str) -> str:
    value = environment.get(key, "")
    if not value or value != value.strip():
        raise ValueError("Missing or invalid private draft setting.")
    return value


def _private_directory(environment: Mapping[str, str], key: str) -> None:
    path = Path(_required(environment, key))
    if not path.is_absolute():
        raise ValueError("Private draft directories must be absolute.")
    info = path.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077
            or not os.access(path, os.R_OK | os.W_OK | os.X_OK)):
        raise ValueError("A private worker-owned draft directory is required.")


def _configured(environment: Mapping[str, str]):
    backend = _required(environment, ENV_BACKEND)
    intake_origin = validate_draft_https_origin(_required(environment, ENV_ORIGIN))
    key = read_private_draft_secret(_required(environment, ENV_SERVICE_KEY_FILE), minimum=11, maximum=512)
    # Permit one line ending from a text editor, not other whitespace or extra lines.
    secret = key.decode("ascii").removesuffix("\n").removesuffix("\r")
    validate_draft_backend(backend, secret)
    _private_directory(environment, ENV_OUTPUT)
    _private_directory(environment, ENV_DIRECTORY)
    settings = {key: environment[key] for key in _RENDER_SETTINGS if key in environment}
    settings[ENV_ORIGIN] = intake_origin
    renderer = renderer_from_env(settings)
    if (renderer is None or not isinstance(renderer.publish_preview, DraftPreviewStore)
            or renderer.timeout <= RPC_WALL_SECONDS):
        raise ValueError("The bounded native renderer and owner preview store are required.")
    return backend, secret, renderer


def _report(state: str, code: int) -> int:
    # Never serialize RunOutcome.as_dict(), RPC reasons, paths, URLs, or exceptions.
    print(json.dumps({"state": state}, separators=(",", ":")))
    return code


def main(argv: Sequence[str] | None = None, environment: Mapping[str, str] | None = None) -> int:
    args = tuple(sys.argv[1:] if argv is None else argv)
    if args == ("--help",):
        print(_USAGE)
        return 0
    if args != ("--run-once",):
        return _report("invalid_invocation", 2)
    try:
        try:
            backend, secret, renderer = _configured(os.environ if environment is None else environment)
        except Exception:
            return _report("invalid_configuration", 2)
        outcome = run_daily_draft_once(backend_url=backend, server_secret_key=secret, renderer=renderer)
        if outcome.state in _OUTCOMES:
            return _report(outcome.state, _OUTCOMES[outcome.state])
        return _report("unconfirmed", 1)
    except _PassDeadline:
        return _report("timed_out", 1)
    except KeyboardInterrupt:
        return _report("interrupted", 130)
    except Exception:
        return _report("unconfirmed", 1)


def _deadline(_signum, _frame):
    raise _PassDeadline()


def _command() -> int:
    # The worker bounds rendering and individual RPCs. The operator pass also
    # bounds local setup/retention waits, without scheduling any retry.
    signal.signal(signal.SIGALRM, _deadline)
    signal.setitimer(signal.ITIMER_REAL, MAX_PASS_SECONDS)
    try:
        return main()
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)


if __name__ == "__main__":
    raise SystemExit(_command())
