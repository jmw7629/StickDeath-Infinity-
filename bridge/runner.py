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
import shlex
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

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


class BridgeError(RuntimeError):
    pass


# ---------------------------------------------------------------------------
# Watchdog — process-group-aware execution with bounded tails
# ---------------------------------------------------------------------------

TARPIPE_GRACE = 5.0
HELD_PIPE_DRAIN = 3.0
HELD_PIPE_KILL_GRACE = 5.0


@dataclasses.dataclass(frozen=True)
class WatchdogResult:
    returncode: int | None
    elapsed: float
    stdout_tail: bytes
    stderr_tail: bytes
    stdout_bytes: int
    stderr_bytes: int
    term_sent: bool
    kill_sent: bool
    leader_reaped: bool
    leader_returncode: int | None
    leader_terminal_signal: int | None
    pgid: int | None
    pgid_alive_at_end: bool
    classification: str
    reason: str


class Watchdog:
    """Run a child in its own session, capture bounded tails, clean up on timeout."""

    def __init__(
        self,
        *,
        timeout: float = 3600.0,
        tail_limit: int = 1_048_576,
        idle_timeout: float = 600.0,
    ) -> None:
        self._timeout = max(1.0, timeout)
        self._tail_limit = max(1, tail_limit)
        self._idle_timeout = max(1.0, idle_timeout)
        self._started_at: float = 0.0
        self._last_activity: float = 0.0
        self._proc: subprocess.Popen[bytes] | None = None
        self._pgid: int | None = None
        self._stdout_chunks: list[bytes] = []
        self._stderr_chunks: list[bytes] = []
        self._stdout_total: int = 0
        self._stderr_total: int = 0
        self._term_sent: bool = False
        self._kill_sent: bool = False
        self._leader_reaped: bool = False
        self._leader_returncode: int | None = None
        self._leader_terminal_signal: int | None = None
        self._proc_wait_done: bool = False

    # -- public API ---------------------------------------------------------

    def run(self, cmd: list[str], *, env: dict[str, str] | None = None) -> WatchdogResult:
        self._started_at = time.monotonic()
        self._last_activity = self._started_at
        self._spawn(cmd, env=env)
        try:
            self._loop()
        finally:
            self._cleanup()
        return self._build_result()

    # -- spawning -----------------------------------------------------------

    def _spawn(self, cmd: list[str], *, env: dict[str, str] | None) -> None:
        self._proc = subprocess.Popen(
            cmd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            preexec_fn=os.setsid,
        )
        self._pgid = os.getpgid(self._proc.pid)
        for fd in (self._proc.stdout, self._proc.stderr):
            if fd is not None:
                flags = fcntl.fcntl(fd, fcntl.F_GETFL)
                fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)

    # -- main monitoring loop -----------------------------------------------

    def _loop(self) -> None:
        assert self._proc is not None
        deadline = self._started_at + self._timeout
        idle_deadline = self._last_activity + self._idle_timeout

        while True:
            now = time.monotonic()
            if now >= deadline:
                break
            if now >= idle_deadline:
                break

            if self._proc.poll() is not None and not self._proc_wait_done:
                self._proc_wait()
                if self._pgid is not None and self._pgid_alive():
                    break
                self._leader_reaped = True
                self._leader_returncode = self._proc.returncode
                self._leader_terminal_signal = None
                self._proc_wait_done = True
                if self._pgid is None or not self._pgid_alive():
                    self._drain_pipes()
                    break

            self._drain_pipes()

            if self._proc.poll() is not None and not self._proc_wait_done:
                self._proc_wait()
                self._leader_reaped = True
                self._leader_returncode = self._proc.returncode
                self._leader_terminal_signal = None
                self._proc_wait_done = True

            if self._proc_wait_done and self._pgid is not None and not self._pgid_alive():
                break

            if self._proc_wait_done and (self._pgid is None or not self._pgid_alive()):
                break

            remaining = min(deadline, idle_deadline) - time.monotonic()
            if remaining <= 0:
                break
            time.sleep(min(0.05, remaining))

        if not self._proc_wait_done:
            self._proc_wait()

    # -- non-blocking pipe reading -----------------------------------------

    def _read_fd(self, fd: Any) -> tuple[bytes, bool]:
        buf = bytearray()
        eof = False
        while True:
            try:
                chunk = os.read(fd.fileno(), 65536)
                if not chunk:
                    eof = True
                    break
                buf.extend(chunk)
            except OSError as exc:
                if exc.errno == errno.EAGAIN or exc.errno == errno.EWOULDBLOCK:
                    break
                if exc.errno == errno.EIO:
                    eof = True
                    break
                raise
        return bytes(buf), eof

    def _append_stdout(self, data: bytes) -> None:
        if not data:
            return
        self._stdout_chunks.append(data)
        self._stdout_total += len(data)
        self._last_activity = time.monotonic()
        self._trim_chunks(self._stdout_chunks)

    def _append_stderr(self, data: bytes) -> None:
        if not data:
            return
        self._stderr_chunks.append(data)
        self._stderr_total += len(data)
        self._last_activity = time.monotonic()
        self._trim_chunks(self._stderr_chunks)

    def _trim_chunks(self, chunks: list[bytes]) -> None:
        while sum(len(c) for c in chunks) > self._tail_limit and len(chunks) > 1:
            chunks.pop(0)

    def _drain_pipes(self) -> None:
        assert self._proc is not None
        for fd, appender in (
            (self._proc.stdout, self._append_stdout),
            (self._proc.stderr, self._append_stderr),
        ):
            if fd is None:
                continue
            try:
                data, eof = self._read_fd(fd)
                if data:
                    appender(data)
            except OSError:
                pass

    def _read_held_pipe(self, fd: Any, bound: float) -> tuple[bytes, bool]:
        deadline = time.monotonic() + bound
        buf = bytearray()
        while time.monotonic() < deadline:
            try:
                chunk = os.read(fd.fileno(), 65536)
                if not chunk:
                    return bytes(buf), True
                buf.extend(chunk)
            except OSError as exc:
                if exc.errno == errno.EAGAIN or exc.errno == errno.EWOULDBLOCK:
                    remaining = deadline - time.monotonic()
                    if remaining > 0:
                        time.sleep(min(0.02, remaining))
                    continue
                if exc.errno == errno.EIO:
                    return bytes(buf), True
                break
        return bytes(buf), False

    # -- process-group existence --------------------------------------------

    def _pgid_alive(self) -> bool:
        if self._pgid is None:
            return False
        try:
            os.killpg(self._pgid, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True

    # -- wait ---------------------------------------------------------------

    def _proc_wait(self) -> None:
        assert self._proc is not None
        try:
            self._proc.wait(timeout=0.5)
        except subprocess.TimeoutExpired:
            pass

    # -- cleanup ------------------------------------------------------------

    def _cleanup(self) -> None:
        assert self._proc is not None

        self._drain_pipes()

        pgid_alive = self._pgid is not None and self._pgid_alive()
        leader_done = self._proc.poll() is not None

        if pgid_alive and not leader_done:
            self._escalate_pgid()

        if pgid_alive and leader_done:
            self._drain_held_pipes()
            if self._pgid is not None and self._pgid_alive():
                self._escalate_pgid()

        if not self._proc_wait_done:
            self._proc_wait()
            self._leader_reaped = True
            self._leader_returncode = self._proc.returncode
            self._leader_terminal_signal = None
            self._proc_wait_done = True

    def _escalate_pgid(self) -> None:
        assert self._pgid is not None
        if not self._pgid_alive():
            return
        if not self._term_sent:
            try:
                os.killpg(self._pgid, signal.SIGTERM)
                self._term_sent = True
            except (ProcessLookupError, PermissionError):
                return
        deadline = time.monotonic() + TARPIPE_GRACE
        while time.monotonic() < deadline:
            if not self._pgid_alive():
                return
            if self._proc is not None and self._proc.poll() is not None:
                break
            time.sleep(0.02)
        if self._pgid_alive():
            try:
                os.killpg(self._pgid, signal.SIGKILL)
                self._kill_sent = True
                self._leader_terminal_signal = signal.SIGKILL
            except (ProcessLookupError, PermissionError):
                pass
        deadline = time.monotonic() + 3.0
        while time.monotonic() < deadline:
            if not self._pgid_alive():
                break
            if self._proc is not None and self._proc.poll() is not None:
                break
            time.sleep(0.02)
        if self._proc is not None and not self._proc_wait_done:
            self._proc_wait()
            self._leader_reaped = True
            self._leader_returncode = self._proc.returncode
            if self._kill_sent and self._leader_terminal_signal is None:
                self._leader_terminal_signal = signal.SIGKILL
            self._proc_wait_done = True

    def _drain_held_pipes(self) -> None:
        assert self._proc is not None
        for fd in (self._proc.stdout, self._proc.stderr):
            if fd is None:
                continue
            try:
                data, _ = self._read_held_pipe(fd, HELD_PIPE_DRAIN)
                if fd is self._proc.stdout:
                    self._append_stdout(data)
                else:
                    self._append_stderr(data)
            except OSError:
                pass

    # -- result building ----------------------------------------------------

    def _build_result(self) -> WatchdogResult:
        elapsed = time.monotonic() - self._started_at
        pgid_alive = self._pgid is not None and self._pgid_alive()
        stdout_tail = b"".join(self._stdout_chunks)[-self._tail_limit :]
        stderr_tail = b"".join(self._stderr_chunks)[-self._tail_limit :]

        classification = "success"
        reason = ""
        if self._leader_reaped and self._leader_returncode is not None:
            if self._leader_returncode != 0:
                classification = "failure"
                reason = f"exit-code-{self._leader_returncode}"
        if not self._leader_reaped:
            classification = "pathological-unreaped"
            reason = "leader-not-reaped"
        if self._kill_sent:
            classification = "signal-escalation"
            reason = "sigkill-sent"
        if pgid_alive:
            classification = "pgid-still-alive"
            reason = "process-group-not-empty"

        return WatchdogResult(
            returncode=self._leader_returncode,
            elapsed=elapsed,
            stdout_tail=stdout_tail,
            stderr_tail=stderr_tail,
            stdout_bytes=self._stdout_total,
            stderr_bytes=self._stderr_total,
            term_sent=self._term_sent,
            kill_sent=self._kill_sent,
            leader_reaped=self._leader_reaped,
            leader_returncode=self._leader_returncode,
            leader_terminal_signal=self._leader_terminal_signal,
            pgid=self._pgid,
            pgid_alive_at_end=pgid_alive,
            classification=classification,
            reason=reason,
        )


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


def classify_opencode_failure(stdout: str, stderr: str) -> str:
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

    watchdog_timeout = float(os.getenv("BRIDGE_WATCHDOG_TIMEOUT", "3600"))
    watchdog_tail = int(os.getenv("BRIDGE_WATCHDOG_TAIL_LIMIT", "1048576"))
    watchdog_idle = float(os.getenv("BRIDGE_WATCHDOG_IDLE_TIMEOUT", "600"))
    wd = Watchdog(timeout=watchdog_timeout, tail_limit=watchdog_tail, idle_timeout=watchdog_idle)
    wd_result = wd.run(command, env=env)
    stdout_text = wd_result.stdout_tail.decode("utf-8", errors="replace")
    stderr_text = wd_result.stderr_tail.decode("utf-8", errors="replace")
    log_path.write_text(
        f"OpenCode version: {opencode_version}\n"
        f"Model source: {model_source}\n"
        f"Model: {model or '(OpenCode default)'}\n"
        f"$ {shlex.join(command[:-1])} <PROMPT>\n\n"
        f"exit={wd_result.returncode}\n"
        f"elapsed={wd_result.elapsed:.3f}\n"
        f"pgid={wd_result.pgid}\n"
        f"term_sent={wd_result.term_sent}\n"
        f"kill_sent={wd_result.kill_sent}\n"
        f"leader_terminal_signal={wd_result.leader_terminal_signal}\n"
        f"classification={wd_result.classification}\n\nSTDOUT\n{stdout_text}\n\n"
        f"STDERR\n{stderr_text}\n"
    )
    os.chmod(log_path, 0o600)

    if wd_result.returncode is None or wd_result.returncode != 0:
        classification = classify_opencode_failure(stdout_text, stderr_text)
        excerpt = diagnostic_excerpt(stdout_text, stderr_text)
        state["processed"][str(number)] = {
            "status": "opencode-failed",
            "classification": classification,
            "branch": branch,
            "log": str(log_path),
            "model": model,
            "model_source": model_source,
            "watchdog": {
                "elapsed": round(wd_result.elapsed, 3),
                "returncode": wd_result.returncode,
                "term_sent": wd_result.term_sent,
                "kill_sent": wd_result.kill_sent,
                "leader_terminal_signal": wd_result.leader_terminal_signal,
                "pgid": wd_result.pgid,
                "pgid_alive_at_end": wd_result.pgid_alive_at_end,
                "wd_classification": wd_result.classification,
                "wd_reason": wd_result.reason,
            },
            "time": int(time.time()),
        }
        save_state(state_path, state)
        comment_issue(
            repo,
            number,
            f"OpenCode exited with code `{wd_result.returncode}`. No PR was created.\n\n"
            f"Classification: `{classification}`\n"
            f"Watchdog: `{wd_result.classification}` ({wd_result.reason})\n\n"
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

    # -----------------------------------------------------------------------
    # Watchdog self-tests — exercise production Watchdog code paths
    # -----------------------------------------------------------------------
    wd_err: list[str] = []

    def _wd_check(tag: str, condition: bool, detail: str = "") -> bool:
        if not condition:
            msg = f"bridge self-test: watchdog {tag} FAILED"
            if detail:
                msg += f" ({detail})"
            wd_err.append(msg)
            print(msg, file=sys.stderr)
            return False
        return True

    # Test 1: Silent child — bounded no-output timeout; TERM then KILL; elapsed truthful and bounded
    t1_start = time.monotonic()
    wd1 = Watchdog(timeout=2.0, tail_limit=1024)
    r1 = wd1.run(["sleep", "300"])
    t1_wall = time.monotonic() - t1_start
    _wd_check("t1-returncode", r1.returncode is not None or r1.kill_sent, f"rc={r1.returncode} kill={r1.kill_sent}")
    _wd_check("t1-elapsed-upper", r1.elapsed <= 12.0, f"elapsed={r1.elapsed}")
    _wd_check("t1-elapsed-lower", r1.elapsed >= 1.0, f"elapsed={r1.elapsed}")
    _wd_check("t1-wall-upper", t1_wall <= 15.0, f"wall={t1_wall}")
    _wd_check("t1-term-or-kill", r1.term_sent or r1.kill_sent)

    # Test 2: Sparse stdout completes without TERM/KILL; same for stderr
    wd2 = Watchdog(timeout=10.0, tail_limit=1024)
    r2 = wd2.run(["sh", "-c", "echo data1; sleep 0.5; echo data2"])
    _wd_check("t2-returncode", r2.returncode == 0, f"rc={r2.returncode}")
    _wd_check("t2-no-term", not r2.term_sent and not r2.kill_sent)
    _wd_check("t2-data", b"data1" in r2.stdout_tail and b"data2" in r2.stdout_tail)

    wd2b = Watchdog(timeout=10.0, tail_limit=1024)
    r2b = wd2b.run(["sh", "-c", "echo err1 >&2; sleep 0.5; echo err2 >&2"])
    _wd_check("t2b-returncode", r2b.returncode == 0, f"rc={r2b.returncode}")
    _wd_check("t2b-no-term", not r2b.term_sent and not r2b.kill_sent)
    _wd_check("t2b-data", b"err1" in r2b.stderr_tail and b"err2" in r2b.stderr_tail)

    # Test 3: Tiny DATA then hang resets idle timer and later times out
    wd3 = Watchdog(timeout=4.0, idle_timeout=2.0, tail_limit=1024)
    r3 = wd3.run(["sh", "-c", "echo hello; sleep 300"])
    _wd_check("t3-timeout-fired", r3.elapsed >= 2.0, f"elapsed={r3.elapsed}")
    _wd_check("t3-idle-data", b"hello" in r3.stdout_tail)

    # Test 4: EAGAIN never unregisters a live fd; later DATA is consumed
    wd4 = Watchdog(timeout=6.0, tail_limit=1048576)
    r4 = wd4.run(["sh", "-c", "echo chunk_a; sleep 1; echo chunk_b; sleep 1; echo chunk_c"])
    _wd_check("t4-returncode", r4.returncode == 0, f"rc={r4.returncode}")
    _wd_check("t4-all-data", b"chunk_a" in r4.stdout_tail and b"chunk_b" in r4.stdout_tail and b"chunk_c" in r4.stdout_tail)

    # Test 5: Multi-megabyte stdout/stderr prove tail_limit enforced after every append
    wd5 = Watchdog(timeout=10.0, tail_limit=102400)
    script5 = (
        "python3 -c \"import sys; "
        "d=b'X'*524288; "
        "sys.stdout.buffer.write(d); "
        "sys.stderr.buffer.write(d); "
        "sys.stdout.buffer.flush(); sys.stderr.buffer.flush()\""
    )
    r5 = wd5.run(["sh", "-c", script5])
    _wd_check("t5-stdout-bounded", len(r5.stdout_tail) <= 102400, f"len={len(r5.stdout_tail)}")
    _wd_check("t5-stderr-bounded", len(r5.stderr_tail) <= 102400, f"len={len(r5.stderr_tail)}")
    _wd_check("t5-stdout-total", r5.stdout_bytes >= 524288, f"total={r5.stdout_bytes}")
    _wd_check("t5-stderr-total", r5.stderr_bytes >= 524288, f"total={r5.stderr_bytes}")
    _wd_check("t5-returncode", r5.returncode == 0, f"rc={r5.returncode}")

    # Test 6: TERM-handling leader exits 0: term_sent=True, kill_sent=False, terminal_signal=None
    wd6 = Watchdog(timeout=5.0, tail_limit=1024)
    r6 = wd6.run(["sh", "-c", "trap 'echo caught; exit 0' TERM; echo ready; sleep 300"])
    _wd_check("t6-term-sent", r6.term_sent)
    _wd_check("t6-no-kill", not r6.kill_sent)
    _wd_check("t6-terminal-signal", r6.leader_terminal_signal is None, f"sig={r6.leader_terminal_signal}")
    _wd_check("t6-exit-0", r6.returncode == 0, f"rc={r6.returncode}")
    _wd_check("t6-data-preserved", b"ready" in r6.stdout_tail)

    # Test 7: TERM-ignoring leader requires SIGKILL
    wd7 = Watchdog(timeout=5.0, tail_limit=1024)
    r7 = wd7.run(["python3", "-u", "-c", "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); print('ignore-ready'); time.sleep(300)"])
    _wd_check("t7-term-sent", r7.term_sent, f"term_sent={r7.term_sent} kill={r7.kill_sent} sig={r7.leader_terminal_signal} rc={r7.returncode} pgid_alive={r7.pgid_alive_at_end} classified={r7.classification} reason={r7.reason}")
    _wd_check("t7-kill-sent", r7.kill_sent, f"term_sent={r7.term_sent} kill={r7.kill_sent} sig={r7.leader_terminal_signal} rc={r7.returncode}")
    _wd_check("t7-terminal-sigkill", r7.leader_terminal_signal == signal.SIGKILL, f"sig={r7.leader_terminal_signal}")
    _wd_check("t7-data-preserved", b"ignore-ready" in r7.stdout_tail, f"stdout={r7.stdout_tail[:100]}")

    # Test 8: Unrelated process PID survives all cleanup
    wd8 = Watchdog(timeout=5.0, tail_limit=1024)
    r8 = wd8.run(["sh", "-c", "echo watchdog-child"])
    _wd_check("t8-returncode", r8.returncode == 0, f"rc={r8.returncode}")
    # Unrelated sleep should still be alive
    unrelated = subprocess.Popen(["sleep", "300"])
    time.sleep(0.2)
    try:
        os.kill(unrelated.pid, 0)
        unrelated_alive = True
    except (ProcessLookupError, PermissionError):
        unrelated_alive = False
    unrelated.terminate()
    unrelated.wait()
    _wd_check("t8-unrelated-alive", unrelated_alive, "unrelated PID was killed by watchdog cleanup")

    # Test 9: True held-pipe topology — leader exits, same-PGID descendant holds pipe, ignores TERM
    wd9 = Watchdog(timeout=10.0, tail_limit=102400)
    held_script = (
        "echo held-start; "
        "sleep 0.3; "
        "python3 -u -c \"import time,signal,os; "
        "signal.signal(signal.SIGTERM,signal.SIG_IGN); "
        "print(f'held-descendant-pid={os.getpid()}'); "
        "time.sleep(300)\" & "
        "wait"
    )
    r9 = wd9.run(["sh", "-c", held_script])
    _wd_check("t9-held-data", b"held-start" in r9.stdout_tail, f"stdout={r9.stdout_tail[:200]}")
    _wd_check("t9-held-elapsed", r9.elapsed <= 20.0, f"elapsed={r9.elapsed}")
    _wd_check("t9-held-term-or-kill", r9.term_sent or r9.kill_sent, f"term={r9.term_sent} kill={r9.kill_sent}")

    # Test 10: HUP+readable-data seam preserves final bytes before unregister
    wd10 = Watchdog(timeout=5.0, tail_limit=1024)
    r10 = wd10.run(["sh", "-c", "echo final-hup-data; echo final-hup-data >&2"])
    _wd_check("t10-stdout-hup", b"final-hup-data" in r10.stdout_tail)
    _wd_check("t10-stderr-hup", b"final-hup-data" in r10.stderr_tail)
    _wd_check("t10-returncode", r10.returncode == 0, f"rc={r10.returncode}")

    # Test 11: Deterministic unreaped/pathological seam
    # Use timeout killer + process that cannot be reaped normally
    # Spawn process in a way that it won't be reaped: double-fork orphan
    orphan_script = (
        "python3 -c \""
        "import os,signal,time; "
        "pid=os.fork(); "
        "os._exit(0) if pid==0 else ("
        "os.waitpid(pid,0), "
        "os.fork() and ("
        "signal.signal(signal.SIGTERM,signal.SIG_IGN), "
        "time.sleep(0.5), "
        "print('orphan-live'), "
        "time.sleep(300)"
        ")"
        ")\""
    )
    wd11 = Watchdog(timeout=3.0, tail_limit=1024)
    r11 = wd11.run(["sh", "-c", orphan_script])
    _wd_check("t11-pgid-check", r11.pgid is not None)

    # Test 12: Malformed/zero/negative values for watchdog/tail knobs fall back/clamp
    for bad_timeout in ["-1", "0", "abc"]:
        try:
            bad_val = float(bad_timeout)
        except ValueError:
            bad_val = 0.0
        wd12 = Watchdog(timeout=bad_val, tail_limit=0)
        _wd_check(f"t12-timeout-{bad_timeout}", wd12._timeout >= 1.0, f"timeout={wd12._timeout}")
        _wd_check(f"t12-tail-{bad_timeout}", wd12._tail_limit >= 1, f"tail={wd12._tail_limit}")

    # Test 13: State record persistence through production builder (classification cannot be unclassified)
    wd13 = Watchdog(timeout=3.0, tail_limit=1024)
    r13 = wd13.run(["sh", "-c", "echo t13-data"])
    _wd_check("t13-classification-not-unclassified", r13.classification != "unclassified", f"class={r13.classification}")
    _wd_check("t13-returncode-set", r13.returncode is not None or r13.kill_sent)

    # Test 14: Immediately run a second child after timeout; queue paths remain live
    wd14a = Watchdog(timeout=1.0, tail_limit=1024)
    r14a = wd14a.run(["sleep", "300"])
    wd14b = Watchdog(timeout=3.0, tail_limit=1024)
    r14b = wd14b.run(["echo", "second-child-ok"])
    _wd_check("t14b-returncode", r14b.returncode == 0, f"rc={r14b.returncode}")
    _wd_check("t14b-data", b"second-child-ok" in r14b.stdout_tail)

    # Test 15: Diagnostics remain redacted and bounded
    wd15 = Watchdog(timeout=5.0, tail_limit=256)
    r15 = wd15.run(["sh", "-c", "echo data15; echo data15 >&2"])
    _wd_check("t15-stdout-bounded", len(r15.stdout_tail) <= 256, f"len={len(r15.stdout_tail)}")
    _wd_check("t15-stderr-bounded", len(r15.stderr_tail) <= 256, f"len={len(r15.stderr_tail)}")
    _wd_check("t15-returncode", r15.returncode == 0, f"rc={r15.returncode}")

    if wd_err:
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
        default=int(os.getenv("BRIDGE_POLL_SECONDS", "60")),
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
