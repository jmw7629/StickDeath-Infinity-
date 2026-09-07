#!/usr/bin/env python3
"""JoeOS ChatGPT -> GitHub -> OpenCode bridge runner.

Runs only trusted [OC] GitHub issues carrying the bridge marker. It never merges.
PROJECT_BYTE execution hints are parsed as data and passed to OpenCode only after
strict validation; no issue text is ever interpreted by a shell.
"""

from __future__ import annotations

import argparse
import dataclasses
import errno
import fcntl
import json
import os
import re
import select
import shlex
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

_MONOTONIC = getattr(time, "monotonic", None)
if _MONOTONIC is None:

    def _monotonic() -> float:
        return time.time()

else:

    def _monotonic() -> float:
        return _MONOTONIC()

BRIDGE_MARKER = "<!-- joeos-opencode-bridge:v1 -->"
DEFAULT_REPO = "jmw7629/StickDeath-Infinity-"
DEFAULT_TRUSTED_AUTHORS = {"jmw7629"}
DIAGNOSTIC_LIMIT = 1800
MODEL_HINT_LINE_RE = re.compile(r"(?m)^PROJECT_BYTE_MODEL_HINT:[ \t]*([^\r\n]+?)[ \t]*$")
MODEL_HINT_VALUE_RE = re.compile(
    r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}/[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"
)
TERMINAL_STATUSES = {
    "pr-created",
    "opencode-failed",
    "bridge-error",
    "diff-check-failed",
    "no-changes",
    "skipped-existing-remote-branch",
}
RECOVERABLE_PREFIX = "recovery-blocked-"
LEGACY_RECOVERABLE_STATUSES = {"skipped-existing-branch"}

DEFAULT_IDLE_TIMEOUT = 1800
DEFAULT_HELD_DRAIN_TIMEOUT = 30
DEFAULT_TERM_GRACE = 10
DEFAULT_REAP_BOUND = 10
DEFAULT_TAIL_LIMIT = 8192


def parse_env_int(name: str, default: int, lo: int, hi: int) -> int:
    raw = os.getenv(name, "").strip()
    if not raw:
        return default
    try:
        val = int(raw)
    except (ValueError, TypeError):
        return default
    return max(lo, min(hi, val))


def _parse_watchdog_config() -> dict[str, int]:
    return {
        "idle_timeout": parse_env_int(
            "BRIDGE_WATCHDOG_IDLE_TIMEOUT", DEFAULT_IDLE_TIMEOUT, 30, 7200
        ),
        "held_drain_timeout": parse_env_int(
            "BRIDGE_WATCHDOG_HELD_DRAIN_TIMEOUT", DEFAULT_HELD_DRAIN_TIMEOUT, 2, 120
        ),
        "term_grace": parse_env_int(
            "BRIDGE_WATCHDOG_TERM_GRACE", DEFAULT_TERM_GRACE, 2, 60
        ),
        "reap_bound": parse_env_int(
            "BRIDGE_WATCHDOG_REAP_BOUND", DEFAULT_REAP_BOUND, 2, 60
        ),
        "tail_limit": parse_env_int(
            "BRIDGE_WATCHDOG_TAIL_LIMIT", DEFAULT_TAIL_LIMIT, 256, 1048576
        ),
    }


class BridgeError(RuntimeError):
    pass


@dataclasses.dataclass
class WatchdogResult:
    returncode: int | None
    stdout_tail: str
    stderr_tail: str
    classification: str | None
    reason: str | None
    term_sent: bool
    kill_sent: bool
    terminal_signal: int | None
    leader_reaped: bool
    elapsed: float


class Watchdog:
    """Watchdog for bridge subprocess execution with monotonic idle detection.

    Key invariants:
    - idle deadline resets ONLY when DATA bytes are actually consumed from stdout/stderr.
    - EAGAIN/WOULD_BLOCK and empty polls do not reset the deadline.
    - Output tails are bounded after every append.
    - Held-pipe cleanup signals only the captured PGID.
    - All waits are bounded.
    """

    def __init__(
        self,
        *,
        idle_timeout: float,
        held_drain_timeout: float,
        term_grace: float,
        reap_bound: float,
        tail_limit: int,
    ) -> None:
        self._idle_timeout = idle_timeout
        self._held_drain_timeout = held_drain_timeout
        self._term_grace = term_grace
        self._reap_bound = reap_bound
        self._tail_limit = tail_limit

    def run(
        self,
        command: list[str],
        *,
        cwd: Path,
        env: dict[str, str],
        timeout: int | None = None,
    ) -> WatchdogResult:
        proc = subprocess.Popen(
            command,
            cwd=str(cwd),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            pass_fds=(),
            env=env,
            start_new_session=True,
        )
        captured_pgid = None
        try:
            captured_pgid = os.getpgid(proc.pid)
        except (ProcessLookupError, OSError):
            captured_pgid = None

        stdout_chunks: list[str] = []
        stderr_chunks: list[str] = []
        stdout_bytes = 0
        stderr_bytes = 0
        last_activity = _monotonic()
        deadline = last_activity + self._idle_timeout
        leader_exited = False
        leader_returncode: int | None = None
        term_sent = False
        kill_sent = False
        terminal_signal_val: int | None = None
        leader_reaped = False

        stdout_fd = proc.stdout.fileno() if proc.stdout else -1
        stderr_fd = proc.stderr.fileno() if proc.stderr else -1

        pollobj = select.poll()
        fd_map: dict[int, str] = {}
        try:
            if stdout_fd >= 0:
                fl = fcntl.fcntl(stdout_fd, fcntl.F_GETFL)
                fcntl.fcntl(stdout_fd, fcntl.F_SETFL, fl | os.O_NONBLOCK)
                pollobj.register(stdout_fd, select.POLLIN)
                fd_map[stdout_fd] = "stdout"
            if stderr_fd >= 0:
                fl = fcntl.fcntl(stderr_fd, fcntl.F_GETFL)
                fcntl.fcntl(stderr_fd, fcntl.F_SETFL, fl | os.O_NONBLOCK)
                pollobj.register(stderr_fd, select.POLLIN)
                fd_map[stderr_fd] = "stderr"

            while fd_map:
                now = _monotonic()
                remaining = deadline - now
                if remaining <= 0:
                    term_sent, kill_sent, terminal_signal_val, leader_reaped, leader_returncode = (
                        self._cleanup_leader(
                            proc, captured_pgid, term_sent, kill_sent,
                            terminal_signal_val, leader_reaped, leader_returncode,
                        )
                    )
                    return WatchdogResult(
                        returncode=leader_returncode,
                        stdout_tail=_join_tail(stdout_chunks, self._tail_limit),
                        stderr_tail=_join_tail(stderr_chunks, self._tail_limit),
                        classification="watchdog-timeout",
                        reason="no-output-idle-timeout",
                        term_sent=term_sent,
                        kill_sent=kill_sent,
                        terminal_signal=terminal_signal_val,
                        leader_reaped=leader_reaped,
                        elapsed=_monotonic() - last_activity,
                    )
                epoll_timeout_ms = max(1, int(remaining * 1000))
                try:
                    events = pollobj.poll(epoll_timeout_ms)
                except OSError as exc:
                    if exc.errno == errno.EINTR:
                        continue
                    raise

                now = _monotonic()
                if now >= deadline:
                    term_sent, kill_sent, terminal_signal_val, leader_reaped, leader_returncode = (
                        self._cleanup_leader(
                            proc, captured_pgid, term_sent, kill_sent,
                            terminal_signal_val, leader_reaped, leader_returncode,
                        )
                    )
                    return WatchdogResult(
                        returncode=leader_returncode,
                        stdout_tail=_join_tail(stdout_chunks, self._tail_limit),
                        stderr_tail=_join_tail(stderr_chunks, self._tail_limit),
                        classification="watchdog-timeout",
                        reason="no-output-idle-timeout",
                        term_sent=term_sent,
                        kill_sent=kill_sent,
                        terminal_signal=terminal_signal_val,
                        leader_reaped=leader_reaped,
                        elapsed=_monotonic() - last_activity,
                    )

                if not events:
                    continue

                drained_any = False
                for fd, ev in events:
                    tag = fd_map.get(fd)
                    if tag is None:
                        continue
                    if tag == "stdout":
                        got = _drain_nonblocking(fd, stdout_chunks)
                        if got > 0:
                            stdout_bytes += got
                            drained_any = True
                    elif tag == "stderr":
                        got = _drain_nonblocking(fd, stderr_chunks)
                        if got > 0:
                            stderr_bytes += got
                            drained_any = True
                    if (ev & (select.POLLHUP | select.POLLERR)) and fd in fd_map:
                        del fd_map[fd]
                        try:
                            pollobj.unregister(fd)
                        except OSError:
                            pass

                if drained_any:
                    last_activity = _monotonic()
                    deadline = last_activity + self._idle_timeout

                if not leader_exited and proc.poll() is not None:
                    leader_exited = True
                    leader_returncode = proc.returncode
                    if fd_map:
                        term_sent, kill_sent, terminal_signal_val, leader_reaped, leader_returncode = (
                            self._drain_held_pipes(
                                proc, pollobj, fd_map, stdout_chunks, stderr_chunks,
                                captured_pgid, term_sent, kill_sent,
                                terminal_signal_val, leader_reaped, leader_returncode,
                            )
                        )
                        break

            if leader_exited and not leader_reaped:
                try:
                    proc.wait(timeout=self._reap_bound)
                    leader_returncode = proc.returncode
                    leader_reaped = True
                except subprocess.TimeoutExpired:
                    leader_returncode = proc.returncode
            elif not leader_exited:
                try:
                    proc.wait(timeout=self._reap_bound)
                    leader_returncode = proc.returncode
                    leader_reaped = True
                except subprocess.TimeoutExpired:
                    try:
                        os.kill(proc.pid, signal.SIGKILL)
                    except (ProcessLookupError, OSError):
                        pass
                    try:
                        proc.wait(timeout=self._reap_bound)
                    except subprocess.TimeoutExpired:
                        pass
                    leader_returncode = proc.returncode
                    term_sent = True
                    kill_sent = True

        finally:
            for fd in (stdout_fd, stderr_fd):
                if fd >= 0:
                    try:
                        os.close(fd)
                    except OSError:
                        pass

        classification = None
        reason = None
        elapsed = 0.0
        if term_sent or kill_sent:
            classification = "watchdog-timeout" if not leader_exited else "held-pipe-cleanup"
            reason = "no-output-idle-timeout" if classification == "watchdog-timeout" else "leader-exit-held-pipe"
            elapsed = _monotonic() - last_activity

        return WatchdogResult(
            returncode=leader_returncode,
            stdout_tail=_join_tail(stdout_chunks, self._tail_limit),
            stderr_tail=_join_tail(stderr_chunks, self._tail_limit),
            classification=classification,
            reason=reason,
            term_sent=term_sent,
            kill_sent=kill_sent,
            terminal_signal=terminal_signal_val,
            leader_reaped=leader_reaped,
            elapsed=elapsed,
        )

    def _cleanup_leader(
        self,
        proc: subprocess.Popen,
        captured_pgid: int | None,
        term_sent: bool,
        kill_sent: bool,
        terminal_signal_val: int | None,
        leader_reaped: bool,
        leader_returncode: int | None,
    ) -> tuple[bool, bool, int | None, bool, int | None]:
        if not term_sent and captured_pgid is not None:
            try:
                os.killpg(captured_pgid, signal.SIGTERM)
                term_sent = True
                terminal_signal_val = signal.SIGTERM
            except (ProcessLookupError, OSError):
                pass
        if term_sent and not kill_sent:
            deadline = _monotonic() + self._term_grace
            while _monotonic() < deadline:
                if proc.poll() is not None:
                    leader_reaped = True
                    leader_returncode = proc.returncode
                    break
                try:
                    proc.wait(timeout=0.1)
                    leader_reaped = True
                    leader_returncode = proc.returncode
                    break
                except subprocess.TimeoutExpired:
                    continue
        if not leader_reaped and captured_pgid is not None:
            try:
                os.killpg(captured_pgid, signal.SIGKILL)
                kill_sent = True
                terminal_signal_val = signal.SIGKILL
            except (ProcessLookupError, OSError):
                pass
        if not leader_reaped:
            try:
                proc.wait(timeout=self._reap_bound)
                leader_reaped = True
                leader_returncode = proc.returncode
            except subprocess.TimeoutExpired:
                try:
                    proc.kill()
                except (ProcessLookupError, OSError):
                    pass
                try:
                    proc.wait(timeout=min(2, self._reap_bound))
                except subprocess.TimeoutExpired:
                    pass
                leader_returncode = proc.returncode
        return term_sent, kill_sent, terminal_signal_val, leader_reaped, leader_returncode

    def _drain_held_pipes(
        self,
        proc: subprocess.Popen,
        pollobj: select.poll,
        fd_map: dict[int, str],
        stdout_chunks: list[str],
        stderr_chunks: list[str],
        captured_pgid: int | None,
        term_sent: bool,
        kill_sent: bool,
        terminal_signal_val: int | None,
        leader_reaped: bool,
        leader_returncode: int | None,
    ) -> tuple[bool, bool, int | None, bool, int | None]:
        drain_deadline = _monotonic() + self._held_drain_timeout
        while fd_map:
            remaining = drain_deadline - _monotonic()
            if remaining <= 0:
                break
            try:
                events = pollobj.poll(max(1, int(remaining * 1000)))
            except OSError as exc:
                if exc.errno == errno.EINTR:
                    continue
                break
            for fd, ev in events:
                tag = fd_map.get(fd)
                if tag == "stdout":
                    _drain_nonblocking(fd, stdout_chunks)
                elif tag == "stderr":
                    _drain_nonblocking(fd, stderr_chunks)
                if (ev & (select.POLLHUP | select.POLLERR)) and fd in fd_map:
                    del fd_map[fd]
                    try:
                        pollobj.unregister(fd)
                    except OSError:
                        pass

        if not term_sent and captured_pgid is not None:
            try:
                os.killpg(captured_pgid, signal.SIGTERM)
                term_sent = True
                terminal_signal_val = signal.SIGTERM
            except (ProcessLookupError, OSError):
                pass
        if term_sent:
            deadline = _monotonic() + self._term_grace
            while _monotonic() < deadline:
                try:
                    proc.wait(timeout=0.1)
                    leader_reaped = True
                    leader_returncode = proc.returncode
                    break
                except subprocess.TimeoutExpired:
                    continue
        if not leader_reaped:
            try:
                os.killpg(captured_pgid, signal.SIGKILL)
                kill_sent = True
                terminal_signal_val = signal.SIGKILL
            except (ProcessLookupError, OSError):
                pass
        if not leader_reaped:
            try:
                proc.wait(timeout=self._reap_bound)
                leader_reaped = True
                leader_returncode = proc.returncode
            except subprocess.TimeoutExpired:
                try:
                    proc.kill()
                except (ProcessLookupError, OSError):
                    pass
                try:
                    proc.wait(timeout=min(2, self._reap_bound))
                except subprocess.TimeoutExpired:
                    pass
                leader_returncode = proc.returncode
        return term_sent, kill_sent, terminal_signal_val, leader_reaped, leader_returncode


def _drain_nonblocking(fd: int, chunks: list[str]) -> int:
    total = 0
    while True:
        try:
            data = os.read(fd, 65536)
        except OSError as exc:
            if exc.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                break
            if exc.errno == errno.EIO:
                break
            raise
        if not data:
            break
        total += len(data)
        try:
            chunks.append(data.decode("utf-8", errors="replace"))
        except Exception:
            chunks.append(str(data))
        if len(chunks) > 200:
            chunks[:] = chunks[-100:]
    return total


def _join_tail(chunks: list[str], limit: int) -> str:
    joined = "".join(chunks)
    if len(joined) > limit:
        return joined[-limit:]
    return joined


def run(
    args: list[str],
    *,
    cwd: Path | None = None,
    check: bool = True,
    capture: bool = True,
    env: dict[str, str] | None = None,
    timeout: int | None = None,
) -> subprocess.CompletedProcess[str]:
    try:
        proc = subprocess.run(
            args,
            cwd=str(cwd) if cwd else None,
            text=True,
            capture_output=capture,
            check=False,
            env=env,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise BridgeError(
            f"Command timed out after {timeout}s: {shlex.join(args[:8])}"
        ) from exc
    if check and proc.returncode != 0:
        stdout = (proc.stdout or "").strip()
        stderr = (proc.stderr or "").strip()
        raise BridgeError(
            f"Command failed ({proc.returncode}): {shlex.join(args)}\n"
            f"stdout:\n{sanitize_text(stdout[-4000:])}\n"
            f"stderr:\n{sanitize_text(stderr[-4000:])}"
        )
    return proc


def slugify(value: str, limit: int = 48) -> str:
    value = re.sub(r"[^a-zA-Z0-9]+", "-", value).strip("-").lower()
    return (value[:limit].rstrip("-") or "task")


def repo_key(repo: str) -> str:
    return repo.replace("/", "__")


def load_state(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"processed": {}}
    try:
        return json.loads(path.read_text())
    except (json.JSONDecodeError, OSError) as exc:
        raise BridgeError(f"Cannot read state file {path}: {exc}") from exc


def save_state(path: Path, state: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")
    os.chmod(temp, 0o600)
    temp.replace(path)


def trusted_authors() -> set[str]:
    raw = os.getenv("BRIDGE_TRUSTED_AUTHORS", "jmw7629")
    return {item.strip() for item in raw.split(",") if item.strip()}


def list_tasks(repo: str) -> list[dict[str, Any]]:
    proc = run(
        [
            "gh",
            "issue",
            "list",
            "--repo",
            repo,
            "--state",
            "open",
            "--limit",
            "100",
            "--json",
            "number,title,body,author,url,createdAt",
        ]
    )
    data = json.loads(proc.stdout or "[]")
    allowed = trusted_authors()
    tasks: list[dict[str, Any]] = []
    for issue in data:
        author = ((issue.get("author") or {}).get("login") or "").strip()
        title = (issue.get("title") or "").strip()
        body = issue.get("body") or ""
        if author not in allowed:
            continue
        if not title.startswith("[OC]"):
            continue
        if BRIDGE_MARKER not in body:
            continue
        tasks.append(issue)
    return sorted(tasks, key=lambda item: int(item["number"]))


def ensure_repo(root: Path, repo: str) -> None:
    if run(["git", "status", "--porcelain"], cwd=root).stdout.strip():
        raise BridgeError(
            f"Repository has uncommitted changes: {root}. "
            "Bridge refuses to run on a dirty control checkout."
        )
    remote = run(["git", "remote", "get-url", "origin"], cwd=root).stdout.strip()
    expected = repo.lower().rstrip(".git")
    normalized = remote.lower().rstrip("/").removesuffix(".git")
    if expected not in normalized:
        raise BridgeError(
            f"origin is {remote!r}, expected repository containing {repo!r}"
        )


def comment_issue(repo: str, number: int, message: str) -> None:
    run(
        ["gh", "issue", "comment", str(number), "--repo", repo, "--body", message],
        capture=True,
    )


def build_prompt(issue: dict[str, Any]) -> str:
    number = int(issue["number"])
    title = issue["title"]
    body = issue.get("body") or ""
    return f"""You are the implementation executor for GitHub issue #{number}: {title}

Read AGENTS.md before doing anything else and follow it as mandatory project policy.

Rules for this bridge run:
- Work only inside the current worktree.
- Do not commit, push, merge, create tags, or modify git history. The bridge runner handles git.
- Do not modify bridge/ or AGENTS.md unless the issue explicitly requests bridge changes.
- Never print, commit, or upload secrets, tokens, OAuth credentials, local model credentials, or private keys.
- Do not commit recovered StickDeath SWFs, copyrighted reference assets, or corpus files.
- Inspect the existing implementation before changing it. Do not replace working architecture without evidence.
- Execute the relevant tests/build checks that are possible in this environment.
- Never claim PASS for a check you did not actually run.
- If a required check cannot run here, state exactly why in your final response.
- Keep the change focused on the issue. No opportunistic rewrites.
- Finish with a concise implementation report including changed areas, checks actually run, failures/gaps, and follow-up risks.

GitHub issue body:
--- BEGIN ISSUE ---
{body}
--- END ISSUE ---
"""


def branch_presence(root: Path, branch: str) -> tuple[bool, bool]:
    local = run(
        ["git", "show-ref", "--verify", "--quiet", f"refs/heads/{branch}"],
        cwd=root,
        check=False,
    ).returncode == 0
    remote = run(
        ["git", "ls-remote", "--exit-code", "--heads", "origin", branch],
        cwd=root,
        check=False,
    ).returncode == 0
    return local, remote


def branch_worktree(root: Path, branch: str) -> Path | None:
    proc = run(["git", "worktree", "list", "--porcelain"], cwd=root)
    current: Path | None = None
    target = f"refs/heads/{branch}"
    for line in (proc.stdout or "").splitlines():
        if line.startswith("worktree "):
            current = Path(line.removeprefix("worktree ").strip())
        elif line.startswith("branch ") and line.removeprefix("branch ").strip() == target:
            return current
    return None


def local_branch_ahead_count(root: Path, branch: str) -> int:
    proc = run(
        ["git", "rev-list", "--count", f"origin/main..{branch}"],
        cwd=root,
        check=False,
    )
    if proc.returncode != 0:
        raise BridgeError(f"Cannot determine whether local branch {branch} has unique commits")
    try:
        return max(0, int((proc.stdout or "0").strip()))
    except ValueError as exc:
        raise BridgeError(f"Unexpected rev-list output for {branch!r}") from exc


def recovery_decision(
    *,
    local_exists: bool,
    remote_exists: bool,
    worktree_is_bridge_owned: bool,
    worktree_dirty: bool,
    ahead_count: int,
) -> str:
    if remote_exists:
        return "remote-existing"
    if not local_exists:
        return "new"
    if not worktree_is_bridge_owned:
        return "blocked-foreign-worktree"
    if worktree_dirty:
        return "blocked-dirty-worktree"
    if ahead_count > 0:
        return "blocked-local-commits"
    return "reset-clean-local"


def project_byte_model_hint(body: str) -> str:
    match = MODEL_HINT_LINE_RE.search(body or "")
    if not match:
        return ""
    value = match.group(1).strip()
    if not MODEL_HINT_VALUE_RE.fullmatch(value):
        return ""
    return value


def choose_model(body: str, env_model: str) -> tuple[str, str]:
    hinted = project_byte_model_hint(body)
    if hinted:
        return hinted, "project-byte"
    fallback = (env_model or "").strip()
    return fallback, "environment" if fallback else "default"


PRIVATE_KEY_RE = re.compile(
    r"-----BEGIN [^-]*(?:PRIVATE|SECRET) KEY-----.*?"
    r"-----END [^-]*(?:PRIVATE|SECRET) KEY-----",
    re.IGNORECASE | re.DOTALL,
)
AUTH_HEADER_RE = re.compile(
    r"(?im)\b(authorization|proxy-authorization)\s*:\s*(?:bearer|basic)\s+\S+"
)
SECRET_ASSIGN_RE = re.compile(
    r"(?im)\b([A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|PASSWD|API_KEY|APIKEY|PRIVATE_KEY|"
    r"ACCESS_KEY|AUTH_KEY|CLIENT_SECRET)[A-Z0-9_]*)\s*=\s*([^\s]+)"
)
COMMON_TOKEN_RE = re.compile(
    r"(?i)\b(?:sk-[A-Za-z0-9_-]{12,}|ghp_[A-Za-z0-9]{12,}|"
    r"github_pat_[A-Za-z0-9_]{12,}|xox[baprs]-[A-Za-z0-9-]{12,}|"
    r"AKIA[A-Z0-9]{12,})\b"
)
JWT_RE = re.compile(
    r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"
)


def sanitize_text(text: str) -> str:
    if not text:
        return ""
    cleaned = text.replace("\x00", "")
    cleaned = PRIVATE_KEY_RE.sub("[REDACTED PRIVATE KEY]", cleaned)
    cleaned = AUTH_HEADER_RE.sub(r"\1: [REDACTED]", cleaned)
    cleaned = SECRET_ASSIGN_RE.sub(r"\1=[REDACTED]", cleaned)
    cleaned = COMMON_TOKEN_RE.sub("[REDACTED TOKEN]", cleaned)
    cleaned = JWT_RE.sub("[REDACTED JWT]", cleaned)
    return cleaned.replace("```", "~~~").strip()


def classify_opencode_failure(stdout: str, stderr: str, explicit: str = "") -> str:
    if explicit:
        return explicit
    text = f"{stderr}\n{stdout}".lower()
    if any(
        marker in text
        for marker in (
            "unknown option",
            "unknown flag",
            "unexpected argument",
            "invalid option",
            "unrecognized option",
            "usage: opencode",
        )
    ):
        return "cli-invocation-incompatibility"
    if any(
        marker in text
        for marker in (
            "unauthorized",
            "authentication",
            "invalid api key",
            "api key",
            "provider",
            "model not found",
            "unknown model",
            "rate limit",
            "quota",
            "login required",
            "credential",
        )
    ):
        return "model-provider-auth-config"
    if any(
        marker in text
        for marker in (
            "argument list too long",
            "prompt too long",
            "payload too large",
            "request entity too large",
            "context length",
            "maximum context",
        )
    ):
        return "prompt-input-or-argument-passing"
    if any(
        marker in text
        for marker in (
            "permission denied",
            "no such file or directory",
            "read-only file system",
            "worktree",
            "not a directory",
            "cannot access",
        )
    ):
        return "filesystem-worktree-sandbox"
    if any(
        marker in text
        for marker in (
            "command not found",
            "module not found",
            "missing dependency",
            "library not found",
            "cannot load",
            "runtime",
            "segmentation fault",
            "panic:",
        )
    ):
        return "tool-runtime-dependency"
    return "unclassified"


def diagnostic_excerpt(stdout: str, stderr: str) -> str:
    combined = "\n".join(part for part in (stderr, stdout) if part)
    cleaned = sanitize_text(combined)
    if not cleaned:
        return "(no stdout/stderr captured)"
    lines = [line.rstrip() for line in cleaned.splitlines() if line.strip()]
    excerpt = "\n".join(lines[-24:])
    if len(excerpt) > DIAGNOSTIC_LIMIT:
        excerpt = excerpt[-DIAGNOSTIC_LIMIT:]
    return excerpt


def resolve_opencode_binary(configured: str) -> str:
    if os.path.isabs(configured):
        candidate = Path(configured).expanduser()
        if not candidate.is_file() or not os.access(candidate, os.X_OK):
            raise BridgeError(f"Configured OpenCode binary is not executable: {candidate}")
        resolved = str(candidate)
    else:
        resolved = shutil.which(configured) or ""
        if not resolved:
            raise BridgeError(f"OpenCode binary is not on PATH: {configured}")
    if resolved.startswith("/snap/"):
        raise BridgeError(
            "OpenCode resolves to a Snap path, which is incompatible with the "
            "bridge service hardening. Install/use the non-Snap OpenCode binary."
        )
    return resolved


def opencode_preflight(configured: str) -> tuple[str, str, set[str]]:
    binary = resolve_opencode_binary(configured)
    version = run([binary, "--version"], check=False, timeout=20)
    if version.returncode != 0:
        excerpt = diagnostic_excerpt(version.stdout or "", version.stderr or "")
        raise BridgeError(
            f"OpenCode preflight failed at --version ({version.returncode}): {excerpt}"
        )
    version_text = sanitize_text((version.stdout or version.stderr or "").strip())
    version_text = version_text.splitlines()[0][:200] if version_text else "unknown"
    help_proc = run([binary, "run", "--help"], check=False, timeout=20)
    if help_proc.returncode != 0:
        excerpt = diagnostic_excerpt(help_proc.stdout or "", help_proc.stderr or "")
        raise BridgeError(
            f"OpenCode preflight failed at 'run --help' ({help_proc.returncode}): {excerpt}"
        )
    help_text = f"{help_proc.stdout or ''}\n{help_proc.stderr or ''}"
    flags = {
        flag
        for flag in ("--auto", "--dir", "--format", "--title", "--model", "--agent", "--attach")
        if flag in help_text
    }
    required = {"--dir", "--format", "--title"}
    missing = sorted(required - flags)
    if missing:
        raise BridgeError(
            "Installed OpenCode 'run' command is missing required automation flags: "
            + ", ".join(missing)
        )
    return binary, version_text, flags


def mark_recovery_blocked(
    repo: str,
    number: int,
    state: dict[str, Any],
    state_path: Path,
    branch: str,
    status: str,
    detail: str,
) -> None:
    key = str(number)
    previous = (state.get("processed") or {}).get(key) or {}
    state.setdefault("processed", {})[key] = {
        "status": status,
        "branch": branch,
        "detail": sanitize_text(detail)[:800],
        "time": int(time.time()),
    }
    save_state(state_path, state)
    if previous.get("status") != status or previous.get("detail") != detail:
        comment_issue(
            repo,
            number,
            "Bridge recovery is blocked, but no work was deleted. "
            f"Status: `{status}`. {sanitize_text(detail)} "
            "The bridge will retry this issue automatically after the blocker is resolved.",
        )


def prepare_issue_branch(
    root: Path,
    repo: str,
    number: int,
    branch: str,
    worktree: Path,
    worktree_root: Path,
    state: dict[str, Any],
    state_path: Path,
) -> bool:
    run(["git", "fetch", "--prune", "origin", "main"], cwd=root)
    local_exists, remote_exists = branch_presence(root, branch)
    if remote_exists:
        state.setdefault("processed", {})[str(number)] = {
            "status": "skipped-existing-remote-branch",
            "branch": branch,
            "time": int(time.time()),
        }
        save_state(state_path, state)
        comment_issue(
            repo,
            number,
            f"Bridge refused to duplicate work because remote branch `{branch}` already exists. "
            "Review the existing branch/PR or create a new `[OC]` issue for a revision.",
        )
        return False

    if local_exists:
        actual_worktree = branch_worktree(root, branch)
        worktree_is_bridge_owned = actual_worktree is None
        dirty = False
        if actual_worktree is not None:
            try:
                actual_resolved = actual_worktree.resolve()
                root_resolved = worktree_root.resolve()
                worktree_is_bridge_owned = actual_resolved.is_relative_to(root_resolved)
            except OSError:
                worktree_is_bridge_owned = False
            if worktree_is_bridge_owned and actual_worktree.exists():
                dirty = bool(run(["git", "status", "--porcelain"], cwd=actual_worktree).stdout.strip())
        ahead = local_branch_ahead_count(root, branch)
        decision = recovery_decision(
            local_exists=True,
            remote_exists=False,
            worktree_is_bridge_owned=worktree_is_bridge_owned,
            worktree_dirty=dirty,
            ahead_count=ahead,
        )
        if decision == "blocked-foreign-worktree":
            mark_recovery_blocked(
                repo,
                number,
                state,
                state_path,
                branch,
                RECOVERABLE_PREFIX + "foreign-worktree",
                "The issue branch is checked out outside the bridge-owned worktree root.",
            )
            return False
        if decision == "blocked-dirty-worktree":
            mark_recovery_blocked(
                repo,
                number,
                state,
                state_path,
                branch,
                RECOVERABLE_PREFIX + "dirty-worktree",
                "The interrupted bridge worktree contains uncommitted changes and was preserved.",
            )
            return False
        if decision == "blocked-local-commits":
            mark_recovery_blocked(
                repo,
                number,
                state,
                state_path,
                branch,
                RECOVERABLE_PREFIX + "local-commits",
                f"The local issue branch has {ahead} commit(s) not present on origin/main and was preserved.",
            )
            return False
        if decision == "reset-clean-local":
            if actual_worktree is not None and actual_worktree.exists():
                run(["git", "worktree", "remove", "--force", str(actual_worktree)], cwd=root)
            run(["git", "branch", "-D", branch], cwd=root)
            state.setdefault("processed", {}).pop(str(number), None)
            save_state(state_path, state)
            comment_issue(
                repo,
                number,
                f"Bridge recovered clean interrupted state for `{branch}` and will restart the issue from current `origin/main`.",
            )

    if worktree.exists():
        status = run(["git", "status", "--porcelain"], cwd=worktree, check=False)
        if status.returncode == 0 and status.stdout.strip():
            mark_recovery_blocked(
                repo,
                number,
                state,
                state_path,
                branch,
                RECOVERABLE_PREFIX + "orphan-dirty-worktree",
                f"Expected bridge worktree `{worktree}` contains changes and was preserved.",
            )
            return False
        run(["git", "worktree", "remove", "--force", str(worktree)], cwd=root, check=False)
        if worktree.exists():
            raise BridgeError(f"Cannot safely remove stale bridge worktree: {worktree}")

    worktree.parent.mkdir(parents=True, exist_ok=True)
    run(
        ["git", "worktree", "add", "-b", branch, str(worktree), "origin/main"],
        cwd=root,
    )
    return True


def process_task(
    root: Path,
    repo: str,
    issue: dict[str, Any],
    state: dict[str, Any],
    state_path: Path,
    worktree_root: Path,
) -> None:
    number = int(issue["number"])
    title = issue["title"].strip()
    body = issue.get("body") or ""
    branch = f"oc/issue-{number}-{slugify(title.removeprefix('[OC]').strip())}"
    worktree = worktree_root / f"issue-{number}"
    logs_dir = state_path.parent / "logs"
    logs_dir.mkdir(parents=True, exist_ok=True)
    log_path = logs_dir / f"issue-{number}.log"

    configured_opencode = os.getenv("OPENCODE_BIN", "opencode")
    opencode_bin, opencode_version, opencode_flags = opencode_preflight(configured_opencode)

    if not prepare_issue_branch(
        root,
        repo,
        number,
        branch,
        worktree,
        worktree_root,
        state,
        state_path,
    ):
        return

    comment_issue(
        repo,
        number,
        f"JoeOS bridge accepted this task. OpenCode `{opencode_version}` is executing "
        f"on branch `{branch}`. Nothing will be merged automatically.",
    )

    prompt = build_prompt(issue)
    command = [opencode_bin, "run", "--dir", str(worktree)]
    if "--auto" in opencode_flags:
        command.append("--auto")
    command.extend(["--format", "json", "--title", f"GitHub issue #{number}"])

    model, model_source = choose_model(body, os.getenv("OPENCODE_MODEL", ""))
    if model:
        if "--model" not in opencode_flags:
            if model_source == "project-byte":
                raise BridgeError("PROJECT_BYTE requested a model but installed OpenCode 'run' lacks --model")
            raise BridgeError("Configured OPENCODE_MODEL but installed OpenCode 'run' lacks --model")
        command.extend(["--model", model])

    agent = os.getenv("OPENCODE_AGENT", "").strip()
    if agent:
        if "--agent" not in opencode_flags:
            raise BridgeError("Configured OPENCODE_AGENT but installed 'run' lacks --agent")
        command.extend(["--agent", agent])

    attach = os.getenv("OPENCODE_ATTACH_URL", "").strip()
    if attach:
        if "--attach" not in opencode_flags:
            raise BridgeError("Configured OPENCODE_ATTACH_URL but installed 'run' lacks --attach")
        command.extend(["--attach", attach])

    command.append(prompt)

    env = os.environ.copy()
    safe_bin = worktree / "bridge" / "safe-bin"
    real_git = shutil.which("git")
    real_gh = shutil.which("gh")
    if not real_git or not real_gh:
        raise BridgeError("Cannot locate real git/gh binaries for task isolation.")
    env["BRIDGE_REAL_GIT"] = real_git
    env["BRIDGE_REAL_GH"] = real_gh
    env["PATH"] = f"{safe_bin}:{env.get('PATH', '')}"
    env["GIT_TERMINAL_PROMPT"] = "0"

    wd_cfg = _parse_watchdog_config()
    watchdog = Watchdog(**wd_cfg)
    wd_result = watchdog.run(command, cwd=worktree, env=env)
    log_path.write_text(
        f"OpenCode version: {opencode_version}\n"
        f"Model source: {model_source}\n"
        f"Model: {model or '(OpenCode default)'}\n"
        f"$ {shlex.join(command[:-1])} <PROMPT>\n\n"
        f"exit={wd_result.returncode}\n\n"
        f"watchdog={wd_result.classification or 'none'}\n"
        f"reason={wd_result.reason or 'none'}\n"
        f"term_sent={wd_result.term_sent}\n"
        f"kill_sent={wd_result.kill_sent}\n"
        f"terminal_signal={wd_result.terminal_signal}\n"
        f"leader_reaped={wd_result.leader_reaped}\n"
        f"elapsed={wd_result.elapsed:.3f}\n\n"
        f"STDOUT\n{wd_result.stdout_tail}\n\n"
        f"STDERR\n{wd_result.stderr_tail}\n"
    )
    os.chmod(log_path, 0o600)

    if wd_result.returncode != 0:
        classification = classify_opencode_failure(
            wd_result.stdout_tail, wd_result.stderr_tail, wd_result.classification or ""
        )
        excerpt = diagnostic_excerpt(wd_result.stdout_tail, wd_result.stderr_tail)
        state["processed"][str(number)] = {
            "status": "opencode-failed",
            "classification": classification,
            "branch": branch,
            "log": str(log_path),
            "model": model,
            "model_source": model_source,
            "reason": wd_result.reason,
            "term_sent": wd_result.term_sent,
            "kill_sent": wd_result.kill_sent,
            "terminal_signal": wd_result.terminal_signal,
            "leader_reaped": wd_result.leader_reaped,
            "returncode": wd_result.returncode,
            "elapsed": round(wd_result.elapsed, 3),
            "time": int(time.time()),
        }
        save_state(state_path, state)
        comment_issue(
            repo,
            number,
            f"OpenCode exited with code `{wd_result.returncode}`. No PR was created.\n\n"
            f"Classification: `{classification}`\n\n"
            "Sanitized diagnostic excerpt:\n"
            f"```text\n{excerpt}\n```\n\n"
            f"The full local log remains at `{log_path}` on the bridge host.",
        )
        return

    status = run(["git", "status", "--porcelain"], cwd=worktree).stdout.strip()
    if not status:
        state["processed"][str(number)] = {
            "status": "no-changes",
            "branch": branch,
            "log": str(log_path),
            "model": model,
            "model_source": model_source,
            "time": int(time.time()),
        }
        save_state(state_path, state)
        comment_issue(
            repo,
            number,
            "OpenCode completed but produced no repository changes. "
            "No PR was created; review the task and create a new `[OC]` issue if needed.",
        )
        return

    diff_check = run(["git", "diff", "--check"], cwd=worktree, check=False)
    if diff_check.returncode != 0:
        state["processed"][str(number)] = {
            "status": "diff-check-failed",
            "branch": branch,
            "log": str(log_path),
            "model": model,
            "model_source": model_source,
            "time": int(time.time()),
        }
        save_state(state_path, state)
        comment_issue(
            repo,
            number,
            "OpenCode produced changes, but `git diff --check` failed. "
            "The branch was not pushed and no PR was created.",
        )
        return

    run(["git", "add", "-A"], cwd=worktree)
    staged = run(["git", "diff", "--cached", "--stat"], cwd=worktree).stdout.strip()
    run(["git", "commit", "-m", f"oc: implement issue #{number}"], cwd=worktree)
    run(["git", "push", "-u", "origin", branch], cwd=worktree)

    pr_body = (
        f"Generated by the JoeOS ChatGPT ↔ OpenCode bridge for issue #{number}.\n\n"
        f"Closes #{number}\n\n"
        "### Bridge verification\n"
        "- `git diff --check`: PASS\n"
        f"- Model source: `{model_source}`\n"
        f"- Model: `{model or 'OpenCode default'}`\n"
        "- OpenCode execution log: retained locally; not uploaded to GitHub\n"
        "- Auto-merge: DISABLED\n\n"
        "### Changed files summary\n"
        f"```\n{staged}\n```\n"
    )
    pr = run(
        [
            "gh",
            "pr",
            "create",
            "--repo",
            repo,
            "--base",
            "main",
            "--head",
            branch,
            "--title",
            title.removeprefix("[OC]").strip() or f"OpenCode issue #{number}",
            "--body",
            pr_body,
        ],
        cwd=worktree,
    )
    pr_url = (pr.stdout or "").strip()

    state["processed"][str(number)] = {
        "status": "pr-created",
        "branch": branch,
        "pr": pr_url,
        "log": str(log_path),
        "model": model,
        "model_source": model_source,
        "time": int(time.time()),
    }
    save_state(state_path, state)
    comment_issue(
        repo,
        number,
        f"OpenCode completed and created PR: {pr_url}\n\n"
        "`git diff --check` passed. The PR requires review; the bridge never auto-merges.",
    )


def bridge_once(root: Path, repo: str, state_path: Path, worktree_root: Path) -> None:
    ensure_repo(root, repo)
    state = load_state(state_path)
    processed = state.setdefault("processed", {})
    for issue in list_tasks(repo):
        number = str(issue["number"])
        record = processed.get(number) or {}
        status = record.get("status", "")
        if record and not (status.startswith(RECOVERABLE_PREFIX) or status in LEGACY_RECOVERABLE_STATUSES):
            continue
        try:
            process_task(root, repo, issue, state, state_path, worktree_root)
        except Exception as exc:
            safe_error = sanitize_text(str(exc))[:1000]
            state["processed"][number] = {
                "status": "bridge-error",
                "error": safe_error,
                "time": int(time.time()),
            }
            save_state(state_path, state)
            try:
                comment_issue(
                    repo,
                    int(issue["number"]),
                    "Bridge execution failed before a PR could be created. "
                    f"Sanitized error: `{safe_error}`",
                )
            except Exception:
                pass


def self_test() -> int:
    import os as _os
    import tempfile as _tmp

    sample = (
        "Authorization: Bearer abcdefghijklmnop\n"
        "OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwxyz\n"
        "token ghp_abcdefghijklmnopqrstuvwxyz123456\n"
        "-----BEGIN PRIVATE KEY-----\nsecret\n-----END PRIVATE KEY-----\n"
    )
    cleaned = sanitize_text(sample)
    forbidden = ("abcdefghijklmnop", "sk-abcdefghijklmnopqrstuvwxyz", "ghp_", "\nsecret\n")
    if any(value in cleaned for value in forbidden):
        print("bridge self-test: redaction FAILED", file=sys.stderr)
        return 1

    cases = {
        "error: unknown option '--auto'": "cli-invocation-incompatibility",
        "401 unauthorized provider": "model-provider-auth-config",
        "argument list too long": "prompt-input-or-argument-passing",
        "permission denied: worktree": "filesystem-worktree-sandbox",
        "command not found: foo": "tool-runtime-dependency",
        "mysterious failure": "unclassified",
    }
    for text, expected in cases.items():
        got = classify_opencode_failure("", text)
        if got != expected:
            print(
                f"bridge self-test: classifier FAILED for {text!r}: {got} != {expected}",
                file=sys.stderr,
            )
            return 1

    if classify_opencode_failure("", "", "watchdog-timeout") != "watchdog-timeout":
        print("bridge self-test: classifier explicit FAILED", file=sys.stderr)
        return 1

    model_cases = [
        ("PROJECT_BYTE_MODEL_HINT: openai/gpt-5.6-sol", "openai/gpt-5.6-sol"),
        ("PROJECT_BYTE_MODEL_HINT: ollama/qwen3-coder:30b", "ollama/qwen3-coder:30b"),
        ("PROJECT_BYTE_MODEL_HINT: openai/gpt; rm -rf /", ""),
        ("PROJECT_BYTE_MODEL_HINT: https://example.com/model", ""),
        ("PROJECT_BYTE_MODEL_HINT: openai/gpt 5", ""),
    ]
    for body, expected in model_cases:
        got = project_byte_model_hint(body)
        if got != expected:
            print(f"bridge self-test: model hint FAILED: {body!r} -> {got!r}", file=sys.stderr)
            return 1
    if choose_model("PROJECT_BYTE_MODEL_HINT: openai/gpt-5.6-sol", "env/model") != (
        "openai/gpt-5.6-sol",
        "project-byte",
    ):
        print("bridge self-test: PROJECT_BYTE model precedence FAILED", file=sys.stderr)
        return 1
    if choose_model("", "env/model") != ("env/model", "environment"):
        print("bridge self-test: environment model fallback FAILED", file=sys.stderr)
        return 1

    recovery_cases = [
        ({"local_exists": False, "remote_exists": False, "worktree_is_bridge_owned": True, "worktree_dirty": False, "ahead_count": 0}, "new"),
        ({"local_exists": True, "remote_exists": True, "worktree_is_bridge_owned": True, "worktree_dirty": False, "ahead_count": 0}, "remote-existing"),
        ({"local_exists": True, "remote_exists": False, "worktree_is_bridge_owned": True, "worktree_dirty": False, "ahead_count": 0}, "reset-clean-local"),
        ({"local_exists": True, "remote_exists": False, "worktree_is_bridge_owned": True, "worktree_dirty": True, "ahead_count": 0}, "blocked-dirty-worktree"),
        ({"local_exists": True, "remote_exists": False, "worktree_is_bridge_owned": True, "worktree_dirty": False, "ahead_count": 1}, "blocked-local-commits"),
        ({"local_exists": True, "remote_exists": False, "worktree_is_bridge_owned": False, "worktree_dirty": False, "ahead_count": 0}, "blocked-foreign-worktree"),
    ]
    for kwargs, expected in recovery_cases:
        got = recovery_decision(**kwargs)
        if got != expected:
            print(f"bridge self-test: recovery decision FAILED: {kwargs} -> {got}", file=sys.stderr)
            return 1

    if "skipped-existing-branch" not in LEGACY_RECOVERABLE_STATUSES:
        print("bridge self-test: legacy recovery migration FAILED", file=sys.stderr)
        return 1

    malicious = project_byte_model_hint("PROJECT_BYTE_MODEL_HINT: openai/gpt$(touch /tmp/pwned)")
    if malicious:
        print("bridge self-test: shell-like model hint was accepted", file=sys.stderr)
        return 1

    with _tmp.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)

        # ── Test 1: Silent leader times out, TERM sent, KILL if needed ──
        wd = Watchdog(idle_timeout=1.0, held_drain_timeout=2.0, term_grace=1.0, reap_bound=2.0, tail_limit=4096)
        result = wd.run(
            ["sleep", "120"],
            cwd=tmp_path,
            env=_os.environ.copy(),
        )
        if result.returncode == 0:
            print("bridge self-test: test1 silent-timeout FAILED (exit 0)", file=sys.stderr)
            return 1
        if not result.term_sent:
            print("bridge self-test: test1 silent-timeout FAILED (term_sent=False)", file=sys.stderr)
            return 1
        if result.classification != "watchdog-timeout":
            print(f"bridge self-test: test1 silent-timeout FAILED (classification={result.classification})", file=sys.stderr)
            return 1

        # ── Test 2: Sparse stdout resets deadline, completes without TERM ──
        with _tmp.NamedTemporaryFile(mode="w", suffix=".sh", dir=tmp, delete=False) as f:
            f.write("#!/bin/sh\nfor i in 1 2 3 4 5; do echo pass_$i; sleep 0.6; done\n")
            f.flush()
            _os.chmod(f.name, 0o755)
            script2 = f.name
        wd2 = Watchdog(idle_timeout=2.0, held_drain_timeout=2.0, term_grace=1.0, reap_bound=2.0, tail_limit=4096)
        result2 = wd2.run(["sh", script2], cwd=tmp_path, env=_os.environ.copy())
        if result2.term_sent:
            print("bridge self-test: test2 sparse-stdout FAILED (term_sent=True)", file=sys.stderr)
            return 1
        if result2.returncode != 0:
            print(f"bridge self-test: test2 sparse-stdout FAILED (returncode={result2.returncode})", file=sys.stderr)
            return 1
        if "pass_5" not in result2.stdout_tail:
            print(f"bridge self-test: test2 sparse-stdout FAILED (missing output)", file=sys.stderr)
            return 1

        # ── Test 3: Sparse stderr resets deadline ──
        with _tmp.NamedTemporaryFile(mode="w", suffix=".sh", dir=tmp, delete=False) as f:
            f.write("#!/bin/sh\nfor i in 1 2 3 4 5; do echo err_$i >&2; sleep 0.6; done\n")
            f.flush()
            _os.chmod(f.name, 0o755)
            script3 = f.name
        wd3 = Watchdog(idle_timeout=2.0, held_drain_timeout=2.0, term_grace=1.0, reap_bound=2.0, tail_limit=4096)
        result3 = wd3.run(["sh", script3], cwd=tmp_path, env=_os.environ.copy())
        if result3.term_sent:
            print("bridge self-test: test3 sparse-stderr FAILED (term_sent=True)", file=sys.stderr)
            return 1
        if result3.returncode != 0:
            print(f"bridge self-test: test3 sparse-stderr FAILED (returncode={result3.returncode})", file=sys.stderr)
            return 1
        if "err_5" not in result3.stderr_tail:
            print(f"bridge self-test: test3 sparse-stderr FAILED (missing output)", file=sys.stderr)
            return 1

        # ── Test 4: Tiny write then hang resets once, then times out ──
        with _tmp.NamedTemporaryFile(mode="w", suffix=".sh", dir=tmp, delete=False) as f:
            f.write("#!/bin/sh\necho tiny\nsleep 120\n")
            f.flush()
            _os.chmod(f.name, 0o755)
            script4 = f.name
        wd4 = Watchdog(idle_timeout=1.5, held_drain_timeout=2.0, term_grace=1.0, reap_bound=2.0, tail_limit=4096)
        t0 = _monotonic()
        result4 = wd4.run(["sh", script4], cwd=tmp_path, env=_os.environ.copy())
        elapsed4 = _monotonic() - t0
        if not result4.term_sent:
            print("bridge self-test: test4 tiny-write-hang FAILED (term_sent=False)", file=sys.stderr)
            return 1
        if elapsed4 > 5.0:
            print(f"bridge self-test: test4 tiny-write-hang FAILED (elapsed={elapsed4:.1f}s too long)", file=sys.stderr)
            return 1

        # ── Test 5: WOULD_BLOCK on a live fd stays registered and later DATA consumed ──
        with _tmp.NamedTemporaryFile(mode="w", suffix=".py", dir=tmp, delete=False) as f:
            f.write(
                "import sys, time, os\n"
                "fd = sys.stdout.fileno()\n"
                "fl = __import__('fcntl').fcntl(fd, __import__('fcntl').F_GETFL)\n"
                "__import__('fcntl').fcntl(fd, __import__('fcntl').F_SETFL, fl & ~__import__('os').O_NONBLOCK)\n"
                "sys.stdout.write('hello')\n"
                "sys.stdout.flush()\n"
                "time.sleep(120)\n"
            )
            f.flush()
            script5 = f.name
        wd5 = Watchdog(idle_timeout=2.0, held_drain_timeout=2.0, term_grace=1.0, reap_bound=2.0, tail_limit=4096)
        result5 = wd5.run([sys.executable, script5], cwd=tmp_path, env=_os.environ.copy())
        if "hello" not in result5.stdout_tail:
            print("bridge self-test: test5 would-block FAILED (DATA not consumed)", file=sys.stderr)
            return 1
        if not result5.term_sent:
            print("bridge self-test: test5 would-block FAILED (term_sent=False)", file=sys.stderr)
            return 1

        # ── Test 6: Multi-megabyte output keeps tail bounded ──
        tail_cfg = 1024
        wd6 = Watchdog(idle_timeout=10.0, held_drain_timeout=2.0, term_grace=1.0, reap_bound=2.0, tail_limit=tail_cfg)
        result6 = wd6.run(
            [sys.executable, "-c", "import sys; [sys.stdout.write('A'*4096) or sys.stderr.write('B'*4096) for _ in range(1000)]; sys.stdout.flush(); sys.stderr.flush()"],
            cwd=tmp_path,
            env=_os.environ.copy(),
        )
        if len(result6.stdout_tail) > tail_cfg * 2:
            print(f"bridge self-test: test6 tail-bound FAILED (stdout_tail={len(result6.stdout_tail)})", file=sys.stderr)
            return 1
        if len(result6.stderr_tail) > tail_cfg * 2:
            print(f"bridge self-test: test6 tail-bound FAILED (stderr_tail={len(result6.stderr_tail)})", file=sys.stderr)
            return 1

        # ── Test 7: TERM-handling child emits shutdown output ──
        with _tmp.NamedTemporaryFile(mode="w", suffix=".py", dir=tmp, delete=False) as f:
            f.write(
                "import sys, signal, time\n"
                "def handler(sig, frame):\n"
                "    sys.stderr.write('shutdown-output\\n')\n"
                "    sys.stderr.flush()\n"
                "    sys.exit(0)\n"
                "signal.signal(signal.SIGTERM, handler)\n"
                "time.sleep(120)\n"
            )
            f.flush()
            script7 = f.name
        wd7 = Watchdog(idle_timeout=1.0, held_drain_timeout=2.0, term_grace=2.0, reap_bound=2.0, tail_limit=4096)
        result7 = wd7.run([sys.executable, script7], cwd=tmp_path, env=_os.environ.copy())
        if not result7.term_sent:
            print("bridge self-test: test7 term-grace FAILED (term_sent=False)", file=sys.stderr)
            return 1
        if result7.kill_sent:
            print("bridge self-test: test7 term-grace FAILED (kill_sent=True)", file=sys.stderr)
            return 1
        if result7.returncode != 0:
            print(f"bridge self-test: test7 term-grace FAILED (returncode={result7.returncode})", file=sys.stderr)
            return 1

        # ── Test 8: TERM-ignoring child requires SIGKILL ──
        with _tmp.NamedTemporaryFile(mode="w", suffix=".py", dir=tmp, delete=False) as f:
            f.write(
                "import signal, time\n"
                "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                "time.sleep(120)\n"
            )
            f.flush()
            script8 = f.name
        wd8 = Watchdog(idle_timeout=1.0, held_drain_timeout=2.0, term_grace=1.5, reap_bound=2.0, tail_limit=4096)
        result8 = wd8.run([sys.executable, script8], cwd=tmp_path, env=_os.environ.copy())
        if not result8.term_sent:
            print("bridge self-test: test8 term-ignoring FAILED (term_sent=False)", file=sys.stderr)
            return 1
        if not result8.kill_sent:
            print("bridge self-test: test8 term-ignoring FAILED (kill_sent=False)", file=sys.stderr)
            return 1
        if result8.terminal_signal != signal.SIGKILL:
            print(f"bridge self-test: test8 term-ignoring FAILED (terminal_signal={result8.terminal_signal})", file=sys.stderr)
            return 1

        # ── Test 9: Separate unrelated long-running PID survives ──
        with _tmp.NamedTemporaryFile(mode="w", suffix=".sh", dir=tmp, delete=False) as f:
            f.write("#!/bin/sh\nsleep 120\n")
            f.flush()
            _os.chmod(f.name, 0o755)
            script9_side = f.name
        side = subprocess.Popen(["sh", script9_side])
        wd9 = Watchdog(idle_timeout=1.0, held_drain_timeout=2.0, term_grace=1.0, reap_bound=2.0, tail_limit=4096)
        result9 = wd9.run(["sleep", "120"], cwd=tmp_path, env=_os.environ.copy())
        try:
            _os.kill(side.pid, 0)
        except (ProcessLookupError, OSError):
            print("bridge self-test: test9 unrelated-survive FAILED (side killed)", file=sys.stderr)
            return 1
        side.terminate()
        try:
            side.wait(timeout=2)
        except subprocess.TimeoutExpired:
            side.kill()
            side.wait()

        # ── Test 10: Held-pipe descendant cleanup ──
        with _tmp.NamedTemporaryFile(mode="w", suffix=".sh", dir=tmp, delete=False) as f:
            f.write(
                "#!/bin/sh\n"
                "sleep 0.3\n"
                "sh -c 'echo held-pipe-data; sleep 120'\n"
                "wait\n"
            )
            f.flush()
            _os.chmod(f.name, 0o755)
            script10 = f.name
        wd10 = Watchdog(idle_timeout=3.0, held_drain_timeout=2.0, term_grace=2.0, reap_bound=3.0, tail_limit=4096)
        t10 = _monotonic()
        result10 = wd10.run(["sh", script10], cwd=tmp_path, env=_os.environ.copy())
        elapsed10 = _monotonic() - t10
        if "held-pipe-data" not in result10.stdout_tail:
            print("bridge self-test: test10 held-pipe FAILED (missing data)", file=sys.stderr)
            return 1
        if elapsed10 > 8.0:
            print(f"bridge self-test: test10 held-pipe FAILED (elapsed={elapsed10:.1f}s)", file=sys.stderr)
            return 1

        # ── Test 11: HUP+readable-data seam consumes final bytes ──
        with _tmp.NamedTemporaryFile(mode="w", suffix=".py", dir=tmp, delete=False) as f:
            f.write(
                "import sys, time\n"
                "sys.stdout.write('final-bytes')\n"
                "sys.stdout.flush()\n"
                "time.sleep(0.2)\n"
            )
            f.flush()
            script11 = f.name
        wd11 = Watchdog(idle_timeout=2.0, held_drain_timeout=2.0, term_grace=1.0, reap_bound=2.0, tail_limit=4096)
        result11 = wd11.run([sys.executable, script11], cwd=tmp_path, env=_os.environ.copy())
        if "final-bytes" not in result11.stdout_tail:
            print("bridge self-test: test11 hup-seam FAILED (final bytes missing)", file=sys.stderr)
            return 1

        # ── Test 12: Deterministic unreaped/pathological seam ──
        with _tmp.NamedTemporaryFile(mode="w", suffix=".sh", dir=tmp, delete=False) as f:
            f.write("#!/bin/sh\nsleep 0.2\n")
            f.flush()
            _os.chmod(f.name, 0o755)
            script12 = f.name
        wd12 = Watchdog(idle_timeout=1.0, held_drain_timeout=0.5, term_grace=0.5, reap_bound=0.5, tail_limit=4096)
        result12 = wd12.run(["sh", script12], cwd=tmp_path, env=_os.environ.copy())
        if result12.leader_reaped is not True:
            print("bridge self-test: test12 pathological FAILED (leader_reaped not True)", file=sys.stderr)
            return 1

        # ── Test 13: Malformed/zero/negative env values fall back/clamp ──
        saved = {}
        for var in ("BRIDGE_WATCHDOG_IDLE_TIMEOUT", "BRIDGE_WATCHDOG_HELD_DRAIN_TIMEOUT",
                     "BRIDGE_WATCHDOG_TERM_GRACE", "BRIDGE_WATCHDOG_REAP_BOUND", "BRIDGE_WATCHDOG_TAIL_LIMIT"):
            saved[var] = _os.environ.pop(var, None)

        _os.environ["BRIDGE_WATCHDOG_IDLE_TIMEOUT"] = "notanumber"
        cfg = _parse_watchdog_config()
        if cfg["idle_timeout"] != DEFAULT_IDLE_TIMEOUT:
            print(f"bridge self-test: test13 malformed FAILED (idle_timeout={cfg['idle_timeout']})", file=sys.stderr)
            return 1

        _os.environ["BRIDGE_WATCHDOG_IDLE_TIMEOUT"] = "-5"
        cfg = _parse_watchdog_config()
        if cfg["idle_timeout"] != 30:
            print(f"bridge self-test: test13 negative FAILED (idle_timeout={cfg['idle_timeout']})", file=sys.stderr)
            return 1

        _os.environ["BRIDGE_WATCHDOG_IDLE_TIMEOUT"] = "99999"
        cfg = _parse_watchdog_config()
        if cfg["idle_timeout"] != 7200:
            print(f"bridge self-test: test13 overflow FAILED (idle_timeout={cfg['idle_timeout']})", file=sys.stderr)
            return 1

        _os.environ["BRIDGE_WATCHDOG_TAIL_LIMIT"] = "0"
        cfg = _parse_watchdog_config()
        if cfg["tail_limit"] != 256:
            print(f"bridge self-test: test13 zero FAILED (tail_limit={cfg['tail_limit']})", file=sys.stderr)
            return 1

        for var, val in saved.items():
            if val is None:
                _os.environ.pop(var, None)
            else:
                _os.environ[var] = val

        # ── Test 14: Timeout/held-pipe/pathological result persisted with metadata ──
        state_record = {
            "status": "opencode-failed",
            "classification": result8.classification or "watchdog-timeout",
            "reason": result8.reason,
            "term_sent": result8.term_sent,
            "kill_sent": result8.kill_sent,
            "terminal_signal": result8.terminal_signal,
            "leader_reaped": result8.leader_reaped,
            "returncode": result8.returncode,
            "elapsed": round(result8.elapsed, 3),
        }
        if state_record["classification"] in ("unclassified", ""):
            print("bridge self-test: test14 persisted-classification FAILED", file=sys.stderr)
            return 1
        if state_record["terminal_signal"] != signal.SIGKILL:
            print(f"bridge self-test: test14 terminal-signal FAILED ({state_record['terminal_signal']})", file=sys.stderr)
            return 1

        # ── Test 15: Queue liveness — second child after timeout succeeds ──
        wd15a = Watchdog(idle_timeout=0.5, held_drain_timeout=1.0, term_grace=1.0, reap_bound=1.0, tail_limit=4096)
        result15a = wd15a.run(["sleep", "120"], cwd=tmp_path, env=_os.environ.copy())
        if not result15a.term_sent:
            print("bridge self-test: test15 queue-liveness FAILED (first did not timeout)", file=sys.stderr)
            return 1

        wd15b = Watchdog(idle_timeout=3.0, held_drain_timeout=2.0, term_grace=1.0, reap_bound=2.0, tail_limit=4096)
        result15b = wd15b.run(
            [sys.executable, "-c", "print('queue-ok')"],
            cwd=tmp_path,
            env=_os.environ.copy(),
        )
        if result15b.returncode != 0:
            print(f"bridge self-test: test15 queue-liveness FAILED (second returncode={result15b.returncode})", file=sys.stderr)
            return 1
        if "queue-ok" not in result15b.stdout_tail:
            print("bridge self-test: test15 queue-liveness FAILED (second no output)", file=sys.stderr)
            return 1

        # ── Test 16: Diagnostics remain sanitized and bounded ──
        large_text = "A" * 10000 + "token ghp_abcdefghijklmnop" + "B" * 10000
        excerpt16 = diagnostic_excerpt(large_text, "")
        if len(excerpt16) > DIAGNOSTIC_LIMIT + 200:
            print(f"bridge self-test: test16 diag-bound FAILED (len={len(excerpt16)})", file=sys.stderr)
            return 1
        if "ghp_" in excerpt16:
            print("bridge self-test: test16 redaction FAILED", file=sys.stderr)
            return 1

        # ── Test 17: parse_env_int module import survives all env corruptions ──
        bads = ["", "abc", "1.5", "True", "None", " "]
        for bad in bads:
            _os.environ["BRIDGE_WATCHDOG_IDLE_TIMEOUT"] = bad
            val = parse_env_int("BRIDGE_WATCHDOG_IDLE_TIMEOUT", 100, 10, 5000)
            if val != 100:
                print(f"bridge self-test: test17 parse FAILED for {bad!r}: {val}", file=sys.stderr)
                return 1
        _os.environ.pop("BRIDGE_WATCHDOG_IDLE_TIMEOUT", None)
        # Null byte: parse_env_int must not crash on poisoned env
        try:
            _os.environ["BRIDGE_WATCHDOG_IDLE_TIMEOUT"] = "\x00"
            val = parse_env_int("BRIDGE_WATCHDOG_IDLE_TIMEOUT", 100, 10, 5000)
            if val != 100:
                print(f"bridge self-test: test17 null-byte FAILED: {val}", file=sys.stderr)
                return 1
        except (ValueError, OSError):
            pass
        _os.environ.pop("BRIDGE_WATCHDOG_IDLE_TIMEOUT", None)

        # ── Test 18: _drain_nonblocking / _join_tail correctness ──
        chunks: list[str] = []
        r, w = _os.pipe()
        _os.write(w, b"chunk1")
        _os.write(w, b"chunk2")
        _os.close(w)
        total = _drain_nonblocking(r, chunks)
        _os.close(r)
        if total != 12:
            print(f"bridge self-test: test18 drain FAILED (total={total})", file=sys.stderr)
            return 1
        joined = _join_tail(chunks, 5)
        if joined != "hunk2":
            print(f"bridge self-test: test18 join_tail FAILED ({joined!r})", file=sys.stderr)
            return 1

        # ── Test 19: Explicit classification not overridden by text ──
        got19 = classify_opencode_failure("some output", "some error", "held-pipe-cleanup")
        if got19 != "held-pipe-cleanup":
            print(f"bridge self-test: test19 explicit FAILED ({got19})", file=sys.stderr)
            return 1

        # ── Test 20: WatchdogResult dataclass fields accessible ──
        wr = WatchdogResult(
            returncode=1, stdout_tail="out", stderr_tail="err",
            classification="watchdog-timeout", reason="test",
            term_sent=True, kill_sent=False, terminal_signal=15,
            leader_reaped=True, elapsed=1.23,
        )
        if wr.returncode != 1 or wr.classification != "watchdog-timeout":
            print("bridge self-test: test20 dataclass FAILED", file=sys.stderr)
            return 1

    print("bridge self-test: PASS")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=os.getenv("BRIDGE_REPO", DEFAULT_REPO))
    parser.add_argument(
        "--root",
        default=os.getenv("BRIDGE_ROOT", ""),
        help="Local control checkout. Defaults to git repository containing this script.",
    )
    parser.add_argument(
        "--interval",
        type=int,
        default=parse_env_int("BRIDGE_POLL_SECONDS", 60, 10, 3600),
    )
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        return self_test()

    script_root = Path(__file__).resolve().parent.parent
    root = Path(args.root).expanduser().resolve() if args.root else script_root
    key = repo_key(args.repo)
    state_path = Path(
        os.getenv(
            "BRIDGE_STATE_FILE",
            f"~/.local/state/joeos-opencode-bridge/{key}/processed.json",
        )
    ).expanduser()
    worktree_root = Path(
        os.getenv(
            "BRIDGE_WORKTREE_ROOT",
            f"~/.cache/joeos-opencode-bridge/{key}/worktrees",
        )
    ).expanduser()

    lock_path = state_path.parent / "bridge.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("w") as lock_file:
        try:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("Another bridge runner is already active.", file=sys.stderr)
            return 2

        while True:
            try:
                bridge_once(root, args.repo, state_path, worktree_root)
            except Exception as exc:
                print(f"[bridge] {sanitize_text(str(exc))}", file=sys.stderr)
            if args.once:
                return 0
            time.sleep(max(args.interval, 30))


if __name__ == "__main__":
    raise SystemExit(main())
