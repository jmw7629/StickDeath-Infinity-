#!/usr/bin/env python3
"""JoeOS ChatGPT -> GitHub -> OpenCode bridge runner.

Runs only trusted [OC] GitHub issues carrying the bridge marker. It never merges.
PROJECT_BYTE execution hints are parsed as data and passed to OpenCode only after
strict validation; no issue text is ever interpreted by a shell.
"""

from __future__ import annotations

import argparse
import errno
import fcntl
import json
import math
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


def _safe_float_env(raw: str | None, default: float, *, clamp_min: float = 0.0,
                    clamp_max: float | None = None) -> float:
    if raw is None:
        return default
    raw = raw.strip()
    if not raw:
        return default
    try:
        value = float(raw)
    except (ValueError, OverflowError):
        return default
    if math.isnan(value) or math.isinf(value):
        return default
    value = max(clamp_min, value)
    if clamp_max is not None:
        value = min(clamp_max, value)
    return value


def _safe_int_env(raw: str | None, default: int, *, clamp_min: int = 1,
                  clamp_max: int | None = None) -> int:
    if raw is None:
        return default
    raw = raw.strip()
    if not raw:
        return default
    try:
        fval = float(raw)
    except (ValueError, OverflowError):
        return default
    if math.isnan(fval) or math.isinf(fval):
        return default
    value = int(fval)
    value = max(clamp_min, value)
    if clamp_max is not None:
        value = min(clamp_max, value)
    return value


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


class TailBuffer:
    """Newest-N-byte tail with a hard retained-memory bound."""

    def __init__(self, limit: int) -> None:
        self.limit = max(1, int(limit))
        self.data = bytearray()
        self.total_bytes = 0
        self.max_retained = 0

    def append(self, chunk: bytes) -> None:
        if not chunk:
            return
        self.total_bytes += len(chunk)
        if len(chunk) >= self.limit:
            self.data[:] = chunk[-self.limit:]
        else:
            overflow = len(self.data) + len(chunk) - self.limit
            if overflow > 0:
                del self.data[:overflow]
            self.data.extend(chunk)
        self.max_retained = max(self.max_retained, len(self.data))

    def text(self) -> str:
        return bytes(self.data).decode("utf-8", errors="replace")


class Watchdog:
    """Bounded OpenCode executor watchdog.

    The leader process runs in its own session/process group. stdout/stderr are
    consumed with nonblocking ``os.read`` into true rolling tail buffers. Leader
    lifecycle, pipe lifecycle, and process-group lifecycle are tracked
    independently so an exited leader cannot strand descendants or the queue.
    """

    POLL_MASK = select.POLLIN | select.POLLHUP | select.POLLERR

    def __init__(
        self,
        cwd: Path,
        *,
        idle_timeout: float,
        tail_limit: int,
        holdpipe_timeout: float,
        final_reap_timeout: float,
        read_chunk: int,
    ) -> None:
        self.cwd = cwd
        self.idle_timeout = max(0.05, float(idle_timeout))
        self.tail_limit = max(1, int(tail_limit))
        self.holdpipe_timeout = max(0.05, float(holdpipe_timeout))
        self.final_reap_timeout = max(0.05, float(final_reap_timeout))
        self.read_chunk = max(1, min(int(read_chunk), self.tail_limit))

        self._proc: subprocess.Popen[bytes] | None = None
        self._pgid: int | None = None
        self._stdout_fd = -1
        self._stderr_fd = -1
        self._stdout_eof = False
        self._stderr_eof = False
        self._stdout_tail = TailBuffer(self.tail_limit)
        self._stderr_tail = TailBuffer(self.tail_limit)
        self._last_activity = time.monotonic()
        self._leader_exit_seen: float | None = None
        self._term_sent = False
        self._kill_sent = False
        self._leader_reaped = False
        self._returncode: int | None = None
        self._timeout_type = ""
        self._classification = ""

    def _spawn(self, command: list[str], env: dict[str, str]) -> None:
        self._proc = subprocess.Popen(
            command,
            cwd=str(self.cwd),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            start_new_session=True,
        )
        assert self._proc.stdout is not None and self._proc.stderr is not None
        self._stdout_fd = self._proc.stdout.fileno()
        self._stderr_fd = self._proc.stderr.fileno()
        for fd in (self._stdout_fd, self._stderr_fd):
            flags = fcntl.fcntl(fd, fcntl.F_GETFL)
            fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)
        self._pgid = os.getpgid(self._proc.pid)
        self._last_activity = time.monotonic()

    def _tail_for_fd(self, fd: int) -> TailBuffer:
        return self._stdout_tail if fd == self._stdout_fd else self._stderr_tail

    def _is_eof(self, fd: int) -> bool:
        return self._stdout_eof if fd == self._stdout_fd else self._stderr_eof

    def _mark_eof(self, fd: int, poller: select.poll | None = None) -> None:
        if fd == self._stdout_fd:
            self._stdout_eof = True
        elif fd == self._stderr_fd:
            self._stderr_eof = True
        if poller is not None:
            try:
                poller.unregister(fd)
            except (KeyError, OSError, ValueError):
                pass

    def _read_fd(self, fd: int, poller: select.poll | None = None) -> str:
        """Consume all currently available bytes without ever blocking.

        Returns DATA when bytes were consumed, EOF on a zero-length read, and
        WOULD_BLOCK on EAGAIN/EWOULDBLOCK. EAGAIN is never treated as EOF.
        """
        if fd < 0 or self._is_eof(fd):
            return "EOF"
        saw_data = False
        while True:
            try:
                chunk = os.read(fd, self.read_chunk)
            except OSError as exc:
                if exc.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                    return "DATA" if saw_data else "WOULD_BLOCK"
                if exc.errno in (errno.EBADF, errno.EINVAL):
                    self._mark_eof(fd, poller)
                    return "EOF"
                raise
            if not chunk:
                self._mark_eof(fd, poller)
                return "DATA" if saw_data else "EOF"
            self._tail_for_fd(fd).append(chunk)
            self._last_activity = time.monotonic()
            saw_data = True

    def _make_poller(self) -> select.poll:
        poller = select.poll()
        for fd in (self._stdout_fd, self._stderr_fd):
            if fd >= 0 and not self._is_eof(fd):
                poller.register(fd, self.POLL_MASK)
        return poller

    def _poll_and_drain(self, poller: select.poll, timeout_ms: int) -> None:
        try:
            events = poller.poll(max(0, timeout_ms))
        except (OSError, ValueError):
            return
        for fd, event in events:
            if event & self.POLL_MASK:
                self._read_fd(fd, poller)

    def _drain_until(self, deadline: float) -> None:
        """Drain readable bytes only until *deadline*, with bounded tails."""
        poller = self._make_poller()
        while time.monotonic() < deadline and not (self._stdout_eof and self._stderr_eof):
            remaining = deadline - time.monotonic()
            self._poll_and_drain(poller, min(50, max(0, int(remaining * 1000))))
            # One nonblocking read per still-open fd covers readiness races/HUP.
            for fd in (self._stdout_fd, self._stderr_fd):
                if fd >= 0 and not self._is_eof(fd):
                    self._read_fd(fd, poller)
            if remaining <= 0.01:
                break

    def _reap_once(self) -> bool:
        if self._proc is None:
            return False
        if self._leader_reaped:
            return True
        rc = self._proc.poll()
        if rc is None:
            return False
        self._leader_reaped = True
        self._returncode = rc
        if self._leader_exit_seen is None:
            self._leader_exit_seen = time.monotonic()
        return True

    def _bounded_reap(self, deadline: float) -> bool:
        while time.monotonic() < deadline:
            if self._reap_once():
                return True
            time.sleep(0.01)
        return self._reap_once()

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
        except OSError:
            return False

    def _wait_group_gone(self, deadline: float) -> bool:
        poller = self._make_poller()
        while time.monotonic() < deadline:
            self._reap_once()
            if not self._pgid_alive():
                self._drain_until(min(deadline, time.monotonic() + 0.1))
                return True
            remaining = deadline - time.monotonic()
            self._poll_and_drain(poller, min(50, max(0, int(remaining * 1000))))
        self._reap_once()
        return not self._pgid_alive()

    def _signal_group(self, sig: int) -> bool:
        if self._pgid is None or not self._pgid_alive():
            return False
        try:
            os.killpg(self._pgid, sig)
        except ProcessLookupError:
            return False
        except (PermissionError, OSError):
            return False
        if sig == signal.SIGTERM:
            self._term_sent = True
        elif sig == signal.SIGKILL:
            self._kill_sent = True
        return True

    def _cleanup_group(self) -> None:
        """Bounded TERM -> KILL -> reap/drain. Never calls unbounded wait()."""
        now = time.monotonic()
        if self._pgid_alive():
            self._signal_group(signal.SIGTERM)
            if not self._wait_group_gone(now + self.holdpipe_timeout):
                self._signal_group(signal.SIGKILL)
                if not self._wait_group_gone(time.monotonic() + self.final_reap_timeout):
                    self._classification = "pgid-still-alive"
        self._bounded_reap(time.monotonic() + self.final_reap_timeout)
        self._drain_until(time.monotonic() + self.final_reap_timeout)
        if not self._leader_reaped and not self._classification:
            self._classification = "leader-unreaped"

    def _close_streams(self) -> None:
        if self._proc is not None:
            for stream in (self._proc.stdout, self._proc.stderr):
                if stream is not None:
                    try:
                        stream.close()
                    except OSError:
                        pass
        self._stdout_fd = -1
        self._stderr_fd = -1

    def run(self, command: list[str], env: dict[str, str]) -> dict[str, Any]:
        self._spawn(command, env)
        poller = self._make_poller()
        try:
            while True:
                self._poll_and_drain(poller, 200)
                self._reap_once()
                now = time.monotonic()

                if not self._leader_reaped and now - self._last_activity >= self.idle_timeout:
                    self._timeout_type = "idle"
                    self._cleanup_group()
                    break

                if self._leader_reaped:
                    assert self._leader_exit_seen is not None
                    if not self._pgid_alive():
                        # The group is gone; give kernel pipe buffers a short bounded drain.
                        self._drain_until(time.monotonic() + min(0.25, self.holdpipe_timeout))
                        if not (self._stdout_eof and self._stderr_eof):
                            self._classification = "pipe-still-open"
                        break
                    # Leader is gone but same-PGID descendants remain. Do not wait on the
                    # normal idle timeout; clean the leaked group after a short grace.
                    if now - self._leader_exit_seen >= self.holdpipe_timeout:
                        self._cleanup_group()
                        break

                if self._stdout_eof and self._stderr_eof and not self._leader_reaped:
                    # EOF is not success by itself. Continue bounded polling until leader
                    # exits or the idle deadline fires.
                    continue
        finally:
            self._reap_once()
            if self._leader_reaped and self._pgid_alive() and not self._classification:
                self._cleanup_group()
            if not self._leader_reaped and not self._classification and not self._timeout_type:
                self._classification = "leader-unreaped"
            self._close_streams()

        rc = self._returncode
        terminal_signal = -rc if self._leader_reaped and rc is not None and rc < 0 else None
        success = (
            self._leader_reaped
            and rc == 0
            and not self._timeout_type
            and not self._classification
        )
        return {
            "stdout": self._stdout_tail.text(),
            "stderr": self._stderr_tail.text(),
            "returncode": rc,
            "term_sent": self._term_sent,
            "kill_sent": self._kill_sent,
            "leader_reaped": self._leader_reaped,
            "timeout_type": self._timeout_type,
            "classification": self._classification,
            "terminal_signal": terminal_signal,
            "success": success,
            "total_stdout_bytes": self._stdout_tail.total_bytes,
            "total_stderr_bytes": self._stderr_tail.total_bytes,
            "max_stdout_retained": self._stdout_tail.max_retained,
            "max_stderr_retained": self._stderr_tail.max_retained,
        }


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

    idle_timeout = _safe_float_env(
        os.getenv("BRIDGE_WATCHDOG_IDLE_TIMEOUT"), 3600.0, clamp_min=10.0, clamp_max=86400.0
    )
    tail_limit = _safe_int_env(
        os.getenv("BRIDGE_WATCHDOG_TAIL_LIMIT"), 2 * 1024 * 1024,
        clamp_min=4096, clamp_max=8 * 1024 * 1024,
    )
    holdpipe_timeout = _safe_float_env(
        os.getenv("BRIDGE_WATCHDOG_HOLDPIPE_TIMEOUT"), 5.0, clamp_min=1.0, clamp_max=60.0
    )
    final_reap_timeout = _safe_float_env(
        os.getenv("BRIDGE_WATCHDOG_FINAL_REAP_TIMEOUT"), 5.0, clamp_min=1.0, clamp_max=30.0
    )
    read_chunk = _safe_int_env(
        os.getenv("BRIDGE_WATCHDOG_READ_CHUNK"), 65536, clamp_min=1024, clamp_max=65536
    )

    wd = Watchdog(
        worktree,
        idle_timeout=idle_timeout,
        tail_limit=tail_limit,
        holdpipe_timeout=holdpipe_timeout,
        final_reap_timeout=final_reap_timeout,
        read_chunk=read_chunk,
    )
    result = wd.run(command, env)

    stdout = result["stdout"]
    stderr = result["stderr"]
    rc = result["returncode"]
    log_path.write_text(
        f"OpenCode version: {opencode_version}\n"
        f"Model source: {model_source}\n"
        f"Model: {model or '(OpenCode default)'}\n"
        f"$ {shlex.join(command[:-1])} <PROMPT>\n\n"
        f"exit={rc}\n"
        f"term_sent={result['term_sent']}\n"
        f"kill_sent={result['kill_sent']}\n"
        f"leader_reaped={result['leader_reaped']}\n"
        f"timeout_type={result['timeout_type']}\n"
        f"classification={result['classification']}\n"
        f"terminal_signal={result['terminal_signal']}\n"
        f"watchdog_success={result['success']}\n\n"
        f"STDOUT\n{stdout}\n\n"
        f"STDERR\n{stderr}\n"
    )
    os.chmod(log_path, 0o600)

    if not result["success"]:
        classification = result["classification"] or classify_opencode_failure(stdout, stderr)
        excerpt = diagnostic_excerpt(stdout, stderr)
        reason_parts = []
        if result["timeout_type"]:
            reason_parts.append(f"timeout={result['timeout_type']}")
        if result["classification"]:
            reason_parts.append(f"classification={result['classification']}")
        if not result["leader_reaped"]:
            reason_parts.append("leader_reaped=False")
        if result["term_sent"]:
            reason_parts.append("term_sent")
        if result["kill_sent"]:
            reason_parts.append("kill_sent")
        reason = "; ".join(reason_parts) or "watchdog-failure"
        state["processed"][str(number)] = {
            "status": "opencode-failed",
            "classification": classification,
            "watchdog_reason": reason,
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
            f"OpenCode exited with code `{rc}`. No PR was created.\n\n"
            f"Watchdog: `{reason}`\n"
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

    test_failures = _run_watchdog_self_tests()
    if test_failures:
        for msg in test_failures:
            print(f"bridge self-test: {msg}", file=sys.stderr)
        return 1

    print("bridge self-test: PASS")
    return 0


def _run_watchdog_self_tests() -> list[str]:
    failures: list[str] = []
    tmp = Path("/tmp/bridge-watchdog-test")
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir(parents=True)

    def td() -> Path:
        d = tmp / f"t_{time.monotonic_ns()}"
        d.mkdir()
        return d

    def write_py(path: Path, code: str) -> None:
        path.write_text(code)
        os.chmod(path, 0o755)

    def wd(d: Path, *, idle: float = 0.5, tail: int = 4096,
           hold: float = 0.25, reap: float = 0.5, chunk: int = 4096) -> Watchdog:
        return Watchdog(
            d,
            idle_timeout=idle,
            tail_limit=tail,
            holdpipe_timeout=hold,
            final_reap_timeout=reap,
            read_chunk=chunk,
        )

    def quick_ok(d: Path) -> str | None:
        r = wd(d, idle=1.0).run([sys.executable, "-c", "print('queue-ok')"], os.environ.copy())
        if not r["success"] or r["returncode"] != 0 or "queue-ok" not in r["stdout"]:
            return f"queue did not recover: {r}"
        return None

    def t1_worktree() -> str | None:
        d = td()
        sentinel = d / "SENTINEL"
        write_py(d / "child.py", "import os, pathlib\npathlib.Path('SENTINEL').write_text(os.getcwd())\n")
        r = wd(d, idle=1.0).run([sys.executable, str(d / "child.py")], os.environ.copy())
        if not r["success"] or sentinel.read_text() != str(d.resolve()):
            return f"worktree isolation failed: {r}"
        return None

    def t2_silent_timeout() -> str | None:
        d = td()
        t0 = time.monotonic()
        r = wd(d, idle=0.35, hold=0.15, reap=0.3).run(["sleep", "30"], os.environ.copy())
        elapsed = time.monotonic() - t0
        if r["success"] or r["timeout_type"] != "idle" or elapsed > 2.5:
            return f"silent timeout not bounded: elapsed={elapsed:.2f} r={r}"
        return quick_ok(d)

    def sparse(stream: str) -> str | None:
        d = td()
        code = (
            "import sys,time\n"
            f"out=sys.{stream}\n"
            "for i in range(8):\n"
            " out.write(f'tick-{i}\\n'); out.flush(); time.sleep(0.2)\n"
        )
        write_py(d / "sparse.py", code)
        t0 = time.monotonic()
        r = wd(d, idle=0.35, hold=0.2).run([sys.executable, str(d / "sparse.py")], os.environ.copy())
        elapsed = time.monotonic() - t0
        text = r["stdout"] if stream == "stdout" else r["stderr"]
        if not r["success"] or elapsed <= 0.35 or "tick-7" not in text:
            return f"sparse {stream} liveness failed: elapsed={elapsed:.2f} r={r}"
        return None

    def t5_tiny_then_hang() -> str | None:
        d = td()
        write_py(d / "tiny.py", "import sys,time\nsys.stdout.write('abc');sys.stdout.flush();time.sleep(30)\n")
        t0 = time.monotonic()
        r = wd(d, idle=0.4, hold=0.15, reap=0.3).run([sys.executable, str(d / "tiny.py")], os.environ.copy())
        if r["success"] or r["timeout_type"] != "idle" or "abc" not in r["stdout"]:
            return f"tiny-then-hang failed: {r}"
        if time.monotonic() - t0 > 2.5:
            return "tiny-then-hang exceeded bound"
        return None

    def t6_eagain() -> str | None:
        d = td()
        rfd, wfd = os.pipe()
        try:
            flags = fcntl.fcntl(rfd, fcntl.F_GETFL)
            fcntl.fcntl(rfd, fcntl.F_SETFL, flags | os.O_NONBLOCK)
            w = wd(d)
            w._stdout_fd = rfd
            w._stderr_fd = -1
            w._stdout_tail = TailBuffer(128)
            w.read_chunk = 64
            poller = select.poll()
            poller.register(rfd, Watchdog.POLL_MASK)
            first = w._read_fd(rfd, poller)
            if first != "WOULD_BLOCK" or w._stdout_eof:
                return f"EAGAIN misclassified: {first} eof={w._stdout_eof}"
            os.write(wfd, b"later-data")
            second = w._read_fd(rfd, poller)
            if second != "DATA" or b"later-data" not in w._stdout_tail.data:
                return f"data after EAGAIN lost: {second} {bytes(w._stdout_tail.data)!r}"
        finally:
            os.close(wfd)
            os.close(rfd)
        return None

    def t7_hup_final_bytes() -> str | None:
        d = td()
        r = wd(d, idle=1.0).run(
            [sys.executable, "-c", "import os; os.write(1,b'FINAL-BYTES')"], os.environ.copy()
        )
        if not r["success"] or "FINAL-BYTES" not in r["stdout"]:
            return f"HUP final bytes lost: {r}"
        return None

    def t8_big_output() -> str | None:
        d = td()
        code = (
            "import os\n"
            "for i in range(12000):\n"
            " os.write(1,(f'O{i:05d}-'+'x'*180+'\\n').encode())\n"
            " os.write(2,(f'E{i:05d}-'+'y'*180+'\\n').encode())\n"
            "os.write(1,b'OUT-LAST-MARKER')\n"
            "os.write(2,b'ERR-LAST-MARKER')\n"
        )
        write_py(d / "big.py", code)
        r = wd(d, idle=2.0, tail=4096, chunk=2048).run([sys.executable, str(d / "big.py")], os.environ.copy())
        if not r["success"]:
            return f"large output failed: {r}"
        if r["max_stdout_retained"] > 4096 or r["max_stderr_retained"] > 4096:
            return f"tail bound exceeded: {r['max_stdout_retained']}/{r['max_stderr_retained']}"
        if "OUT-LAST-MARKER" not in r["stdout"] or "ERR-LAST-MARKER" not in r["stderr"]:
            return "rolling tail did not retain newest bytes"
        if r["total_stdout_bytes"] < 2_000_000 or r["total_stderr_bytes"] < 2_000_000:
            return f"large output not fully consumed: {r['total_stdout_bytes']}/{r['total_stderr_bytes']}"
        return None

    def t9_single_burst() -> str | None:
        d = td()
        r = wd(d, idle=1.0, tail=1024, chunk=1024).run(
            [sys.executable, "-c", "import os;os.write(1,b'A'*200000+b'BURST-END')"], os.environ.copy()
        )
        if not r["success"] or r["max_stdout_retained"] > 1024 or "BURST-END" not in r["stdout"]:
            return f"single burst bound/tail failed: {r}"
        return None

    def t10_term_handler_rc0() -> str | None:
        d = td()
        code = (
            "import os,signal,time,sys\n"
            "def h(sig,frm): os.write(1,b'TERM-FINAL'); sys.exit(0)\n"
            "signal.signal(signal.SIGTERM,h)\n"
            "time.sleep(30)\n"
        )
        write_py(d / "term0.py", code)
        r = wd(d, idle=0.35, hold=0.2, reap=0.4).run([sys.executable, str(d / "term0.py")], os.environ.copy())
        if r["success"] or r["timeout_type"] != "idle" or not r["term_sent"] or r["kill_sent"]:
            return f"TERM handler state wrong: {r}"
        if r["returncode"] != 0 or r["terminal_signal"] is not None or "TERM-FINAL" not in r["stdout"]:
            return f"TERM handler disposition/final bytes wrong: {r}"
        return quick_ok(d)

    def t11_sigkill_signal_truth() -> str | None:
        d = td()
        write_py(d / "ignore.py", "import signal,time\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\ntime.sleep(30)\n")
        r = wd(d, idle=0.35, hold=0.15, reap=0.4).run([sys.executable, str(d / "ignore.py")], os.environ.copy())
        if r["success"] or not r["term_sent"] or not r["kill_sent"]:
            return f"SIGKILL escalation missing: {r}"
        if r["returncode"] != -9 or r["terminal_signal"] != 9:
            return f"leader terminal signal untruthful: {r}"
        return None

    def t12_held_pipe_descendant() -> str | None:
        d = td()
        pidfile = d / "child.pid"
        code = (
            "import os,signal,time,pathlib,sys\n"
            "pid=os.fork()\n"
            "if pid==0:\n"
            " signal.signal(signal.SIGTERM,signal.SIG_IGN)\n"
            f" pathlib.Path({str(pidfile)!r}).write_text(str(os.getpid()))\n"
            " os.write(1,b'child-alive\\n'); time.sleep(30); sys.exit(0)\n"
            "os.write(1,b'leader-exit\\n'); sys.exit(0)\n"
        )
        write_py(d / "held.py", code)
        unrelated = subprocess.Popen(["sleep", "30"], start_new_session=True)
        try:
            t0 = time.monotonic()
            r = wd(d, idle=2.0, hold=0.25, reap=0.5).run([sys.executable, str(d / "held.py")], os.environ.copy())
            elapsed = time.monotonic() - t0
            if r["returncode"] != 0 or r["terminal_signal"] is not None:
                return f"leader disposition changed by descendant kill: {r}"
            if not r["term_sent"] or not r["kill_sent"] or not r["success"] or elapsed > 2.5:
                return f"held-pipe cleanup failed/boundedness: elapsed={elapsed:.2f} r={r}"
            if unrelated.poll() is not None:
                return "unrelated process was killed"
            if not pidfile.exists():
                return "held descendant PID was not recorded"
            child_pid = int(pidfile.read_text())
            deadline = time.monotonic() + 1.0
            while time.monotonic() < deadline:
                try:
                    os.kill(child_pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.02)
            else:
                return f"held descendant still alive: {child_pid}"
            return quick_ok(d)
        finally:
            unrelated.terminate()
            try:
                unrelated.wait(timeout=1)
            except subprocess.TimeoutExpired:
                unrelated.kill()

    def t13_pgid_still_alive_seam() -> str | None:
        class StuckGroupWatchdog(Watchdog):
            def _wait_group_gone(self, deadline: float) -> bool:
                super()._wait_group_gone(min(deadline, time.monotonic() + 0.03))
                return False
            def _pgid_alive(self) -> bool:
                if self._kill_sent:
                    return True
                return super()._pgid_alive()
        d = td()
        w = StuckGroupWatchdog(d, idle_timeout=0.25, tail_limit=1024,
                               holdpipe_timeout=0.1, final_reap_timeout=0.15, read_chunk=1024)
        r = w.run(["sleep", "30"], os.environ.copy())
        if r["success"] or r["classification"] != "pgid-still-alive":
            return f"pgid-still-alive seam not explicit: {r}"
        if quick_ok(d):
            return "queue did not continue after pgid-still-alive seam"
        return None

    def t14_unreaped_seam() -> str | None:
        class UnreapedWatchdog(Watchdog):
            def _reap_once(self) -> bool:
                return False
            def _bounded_reap(self, deadline: float) -> bool:
                return False
            def _pgid_alive(self) -> bool:
                # Deterministic seam: group cleanup reports gone while the leader
                # remains pathologically unreapable. Production must surface that
                # independently instead of fabricating a return code.
                return False
        d = td()
        w = UnreapedWatchdog(d, idle_timeout=0.25, tail_limit=1024,
                             holdpipe_timeout=0.1, final_reap_timeout=0.15, read_chunk=1024)
        r = w.run(["sleep", "30"], os.environ.copy())
        # Production result must preserve the pathological truth.
        if r["success"] or r["leader_reaped"] or r["returncode"] is not None:
            return f"unreaped state was fabricated: {r}"
        if r["classification"] != "leader-unreaped":
            return f"unreaped classification missing: {r}"
        # Test-only cleanup so the seam cannot leak its synthetic child.
        if w._proc is not None:
            try:
                os.killpg(w._pgid, signal.SIGKILL) if w._pgid else None
            except OSError:
                pass
            try:
                w._proc.wait(timeout=1)
            except subprocess.TimeoutExpired:
                pass
        return quick_ok(d)

    def t15_env_clamps() -> str | None:
        float_cases = [
            ("abc", 100.0, 1.0, 200.0, 100.0),
            ("NaN", 100.0, 1.0, 200.0, 100.0),
            ("inf", 100.0, 1.0, 200.0, 100.0),
            ("0", 100.0, 1.0, 200.0, 1.0),
            ("-9", 100.0, 1.0, 200.0, 1.0),
            ("999999", 100.0, 1.0, 200.0, 200.0),
        ]
        for raw, default, lo, hi, expected in float_cases:
            got = _safe_float_env(raw, default, clamp_min=lo, clamp_max=hi)
            if got != expected:
                return f"float clamp {raw!r}: {got} != {expected}"
        int_cases = [
            ("bad", 4096, 1024, 65536, 4096),
            ("0", 4096, 1024, 65536, 1024),
            ("-2", 4096, 1024, 65536, 1024),
            ("9999999", 4096, 1024, 65536, 65536),
        ]
        for raw, default, lo, hi, expected in int_cases:
            got = _safe_int_env(raw, default, clamp_min=lo, clamp_max=hi)
            if got != expected:
                return f"int clamp {raw!r}: {got} != {expected}"
        return None

    def t16_no_unbounded_wait_static() -> str | None:
        source = Path(__file__).read_text()
        block = source[source.index("class Watchdog:"):source.index("\ndef process_task(", source.index("class Watchdog:"))]
        if ".wait(" in block or "waitpid(" in block:
            return "Watchdog contains a potentially blocking wait/waitpid call"
        if "capture_output=True" in block or "communicate(" in block:
            return "Watchdog contains full-output accumulator path"
        return None

    tests = [
        ("worktree isolation", t1_worktree),
        ("silent timeout", t2_silent_timeout),
        ("sparse stdout", lambda: sparse("stdout")),
        ("sparse stderr", lambda: sparse("stderr")),
        ("tiny data then hang", t5_tiny_then_hang),
        ("EAGAIN distinct from EOF", t6_eagain),
        ("HUP final bytes", t7_hup_final_bytes),
        ("multi-megabyte rolling tails", t8_big_output),
        ("oversized single burst", t9_single_burst),
        ("TERM handler rc0 truth", t10_term_handler_rc0),
        ("SIGKILL terminal signal truth", t11_sigkill_signal_truth),
        ("held-pipe descendant cleanup", t12_held_pipe_descendant),
        ("pgid-still-alive seam", t13_pgid_still_alive_seam),
        ("unreaped seam", t14_unreaped_seam),
        ("safe env min/max clamps", t15_env_clamps),
        ("no unbounded wait/static accumulator", t16_no_unbounded_wait_static),
    ]
    for name, fn in tests:
        try:
            err = fn()
        except Exception as exc:
            err = f"exception {type(exc).__name__}: {exc}"
        if err:
            failures.append(f"{name}: {err}")

    shutil.rmtree(tmp, ignore_errors=True)
    return failures


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
