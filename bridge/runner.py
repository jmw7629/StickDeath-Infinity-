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


class Watchdog:
    """Process watchdog with bounded output, independent leader/pgid lifecycle,
    safe env-parsing, and authoritative failure classification."""

    def __init__(
        self,
        cwd: Path,
        *,
        idle_timeout: float = 0.0,
        hard_timeout: float = 0.0,
        tail_limit: int = 0,
        holdpipe_timeout: float = 0.0,
    ) -> None:
        self.cwd = cwd
        self._cfg_idle = idle_timeout
        self._cfg_hard = hard_timeout
        self._cfg_tail = tail_limit
        self._cfg_holdpipe = holdpipe_timeout

        self._proc: subprocess.Popen[str] | None = None
        self._pgid: int | None = None
        self._stdout_fd: int = -1
        self._stderr_fd: int = -1
        self._stdout_buf = bytearray()
        self._stderr_buf = bytearray()
        self._stdout_eof = False
        self._stderr_eof = False
        self._last_activity = time.monotonic()
        self._start = time.monotonic()
        self._done = False
        self._term_sent = False
        self._kill_sent = False
        self._leader_reaped = False
        self._returncode: int | None = None
        self._timeout_type = ""
        self._classification = ""
        self._total_stdout = 0
        self._total_stderr = 0

    @staticmethod
    def _env_float(env_var: str, default: float, **kw: Any) -> float:
        return _safe_float_env(os.getenv(env_var), default, **kw)

    @staticmethod
    def _env_int(env_var: str, default: int, **kw: Any) -> int:
        return _safe_int_env(os.getenv(env_var), default, **kw)

    def idle_limit(self) -> float:
        return self._env_float("BRIDGE_WATCHDOG_IDLE_TIMEOUT", self._cfg_idle, clamp_min=1.0)

    def hard_limit(self) -> float:
        return self._env_float("BRIDGE_WATCHDOG_HARD_TIMEOUT", self._cfg_hard, clamp_min=5.0)

    def tail_limit(self) -> int:
        val = self._env_int("BRIDGE_WATCHDOG_TAIL_LIMIT", self._cfg_tail, clamp_min=1024,
                            clamp_max=64 * 1024 * 1024)
        return val if val > 0 else 2 * 1024 * 1024

    def holdpipe_limit(self) -> float:
        return self._env_float("BRIDGE_WATCHDOG_HOLDPIPE_TIMEOUT", self._cfg_holdpipe, clamp_min=1.0)

    def _spawn(self, command: list[str], env: dict[str, str]) -> None:
        self._proc = subprocess.Popen(
            command,
            cwd=str(self.cwd),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            start_new_session=True,
        )
        self._stdout_fd = self._proc.stdout.fileno()
        self._stderr_fd = self._proc.stderr.fileno()
        for fd in (self._stdout_fd, self._stderr_fd):
            flags = fcntl.fcntl(fd, fcntl.F_GETFL)
            fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)
        self._pgid = os.getpgid(self._proc.pid)
        self._update_activity()

    def _update_activity(self) -> None:
        self._last_activity = time.monotonic()

    def _read_fd(self, fd: int, buf: bytearray, limit: int, poller: select.poll) -> None:
        chunk_limit = min(limit, 65536)
        while True:
            try:
                data = os.read(fd, chunk_limit)
            except OSError as exc:
                if exc.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                    return
                raise
            if not data:
                poller.unregister(fd)
                if fd == self._stdout_fd:
                    self._stdout_eof = True
                else:
                    self._stderr_eof = True
                return
            n = len(data)
            if fd == self._stdout_fd:
                self._total_stdout += n
            else:
                self._total_stderr += n
            if len(buf) < limit:
                buf.extend(data)
                if len(buf) > limit:
                    del buf[: len(buf) - limit]
            self._update_activity()

    def _drain_pipe(self, fd: int, buf: bytearray, limit: int) -> None:
        chunk_limit = min(limit, 65536)
        while len(buf) < limit:
            try:
                data = os.read(fd, chunk_limit)
            except OSError as exc:
                if exc.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                    return
                raise
            if not data:
                return
            buf.extend(data)
            if fd == self._stdout_fd:
                self._total_stdout += len(data)
            else:
                self._total_stderr += len(data)
            if len(buf) > limit:
                del buf[: len(buf) - limit]
            self._update_activity()

    def _pgid_alive(self) -> bool:
        if self._pgid is None:
            return False
        try:
            os.kill(-self._pgid, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        except OSError:
            return False

    def _reap(self, block: bool = False) -> None:
        if self._proc is None:
            return
        if self._leader_reaped:
            return
        flags = 0 if block else os.WNOHANG
        try:
            pid, status = os.waitpid(self._proc.pid, flags)
        except ChildProcessError:
            self._leader_reaped = True
            if self._returncode is None and self._proc.returncode is not None:
                self._returncode = self._proc.returncode
            return
        if pid == 0:
            if self._proc.poll() is not None:
                self._leader_reaped = True
                if self._returncode is None and self._proc.returncode is not None:
                    self._returncode = self._proc.returncode
            return
        self._leader_reaped = True
        if os.WIFSIGNALED(status):
            self._returncode = -os.WTERMSIG(status)
        elif os.WIFEXITED(status):
            self._returncode = os.WEXITSTATUS(status)
        else:
            self._returncode = None

    def _loop(self, command: list[str], env: dict[str, str]) -> None:
        self._spawn(command, env)
        poller = select.poll()
        if not self._stdout_eof:
            poller.register(self._stdout_fd, select.POLLIN)
        if not self._stderr_eof:
            poller.register(self._stderr_fd, select.POLLIN)
        idle_deadline = self._last_activity + self.idle_limit()
        hard_deadline = self._start + self.hard_limit()

        while not self._done:
            try:
                result = poller.poll(200)
            except (OSError, ValueError):
                break
            for fd, event in result:
                if event & (select.POLLHUP | select.POLLIN):
                    buf = self._stdout_buf if fd == self._stdout_fd else self._stderr_buf
                    if not (self._stdout_eof if fd == self._stdout_fd else self._stderr_eof):
                        self._read_fd(fd, buf, self.tail_limit(), poller)
                if event & select.POLLERR:
                    try:
                        os.read(fd, 1)
                    except OSError:
                        pass
            if self._proc is not None and self._proc.poll() is not None:
                self._update_activity()
            now = time.monotonic()
            if now - self._start >= self.hard_limit():
                self._timeout_type = "hard"
                self._cleanup()
                return
            idle_deadline = max(idle_deadline, self._last_activity + self.idle_limit())
            if now >= idle_deadline:
                self._timeout_type = "idle"
                self._cleanup()
                return
            if self._stdout_eof and self._stderr_eof:
                if self._proc is not None:
                    try:
                        self._proc.wait(timeout=5)
                    except (subprocess.TimeoutExpired, OSError):
                        pass
                    self._reap(block=True)
                    if not self._leader_reaped and self._pgid_alive():
                        self._cleanup()
                return

    def _cleanup(self) -> None:
        if self._proc is None or self._pgid is None:
            return
        if self._stdout_fd >= 0 and not self._stdout_eof:
            try:
                poller = select.poll()
                poller.register(self._stdout_fd, select.POLLIN)
                self._drain_pipe(self._stdout_fd, self._stdout_buf, self.tail_limit())
            except (OSError, ValueError):
                pass
            try:
                poller.unregister(self._stdout_fd)
            except (OSError, ValueError):
                pass
        self._stdout_fd = -1
        if self._stderr_fd >= 0 and not self._stderr_eof:
            try:
                poller = select.poll()
                poller.register(self._stderr_fd, select.POLLIN)
                self._drain_pipe(self._stderr_fd, self._stderr_buf, self.tail_limit())
            except (OSError, ValueError):
                pass
            try:
                poller.unregister(self._stderr_fd)
            except (OSError, ValueError):
                pass
        self._stderr_fd = -1
        if self._pgid_alive():
            self._escalate_pgid()

    def _escalate_pgid(self) -> None:
        if self._proc is None or self._pgid is None:
            return
        if not self._pgid_alive():
            return
        try:
            os.killpg(self._pgid, signal.SIGTERM)
            self._term_sent = True
        except (ProcessLookupError, PermissionError, OSError):
            pass
        try:
            self._proc.wait(timeout=self.holdpipe_limit())
            self._reap(block=False)
            if not self._classification:
                self._classification = "term-sent-leader-exited"
            return
        except (subprocess.TimeoutExpired, ChildProcessError, OSError):
            pass
        if self._pgid_alive():
            self._held_pipe_kill()
            return
        self._reap(block=False)
        if not self._classification:
            self._classification = "term-sent-group-gone"

    def _held_pipe_kill(self) -> None:
        if self._proc is None or self._pgid is None:
            return
        try:
            os.killpg(self._pgid, signal.SIGKILL)
            self._kill_sent = True
        except (ProcessLookupError, PermissionError, OSError):
            pass
        try:
            self._proc.wait(timeout=self.holdpipe_limit())
            self._reap(block=False)
            return
        except (subprocess.TimeoutExpired, ChildProcessError, OSError):
            pass
        self._reap(block=False)
        if self._pgid_alive():
            self._classification = "pgid-still-alive"
            return

    def run(self, command: list[str], env: dict[str, str]) -> dict[str, Any]:
        self._loop(command, env)
        if self._proc is not None:
            if self._proc.poll() is None:
                if self._pgid_alive():
                    self._cleanup()
                else:
                    try:
                        self._proc.wait(timeout=5)
                    except (subprocess.TimeoutExpired, OSError):
                        pass
            self._reap(block=False)
        if self._proc is not None and self._proc.stdout is not None:
            try:
                self._proc.stdout.close()
            except OSError:
                pass
        if self._proc is not None and self._proc.stderr is not None:
            try:
                self._proc.stderr.close()
            except OSError:
                pass
        stdout = bytes(self._stdout_buf).decode("utf-8", errors="replace")
        stderr = bytes(self._stderr_buf).decode("utf-8", errors="replace")
        rc = self._returncode
        if self._leader_reaped and rc is not None and rc < 0:
            term_sig = rc
        else:
            term_sig = None
        success = (
            self._leader_reaped
            and rc is not None
            and rc == 0
            and not self._timeout_type
            and not self._classification
            and not self._term_sent
            and not self._kill_sent
        )
        return {
            "stdout": stdout,
            "stderr": stderr,
            "returncode": rc,
            "term_sent": self._term_sent,
            "kill_sent": self._kill_sent,
            "leader_reaped": self._leader_reaped,
            "timeout_type": self._timeout_type,
            "classification": self._classification,
            "terminal_signal": term_sig,
            "success": success,
            "total_stdout_bytes": self._total_stdout,
            "total_stderr_bytes": self._total_stderr,
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

    idle_timeout = _safe_float_env(os.getenv("BRIDGE_WATCHDOG_IDLE_TIMEOUT"), 14400.0, clamp_min=1.0)
    hard_timeout = _safe_float_env(os.getenv("BRIDGE_WATCHDOG_HARD_TIMEOUT"), 28800.0, clamp_min=5.0)
    tail_limit = _safe_int_env(os.getenv("BRIDGE_WATCHDOG_TAIL_LIMIT"), 2 * 1024 * 1024,
                               clamp_min=1024, clamp_max=64 * 1024 * 1024)
    holdpipe_timeout = _safe_float_env(os.getenv("BRIDGE_WATCHDOG_HOLDPIPE_TIMEOUT"), 10.0, clamp_min=1.0)

    wd = Watchdog(
        worktree,
        idle_timeout=idle_timeout,
        hard_timeout=hard_timeout,
        tail_limit=tail_limit,
        holdpipe_timeout=holdpipe_timeout,
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
    if tmp.exists():
        shutil.rmtree(tmp)
    tmp.mkdir(parents=True)

    def _td() -> Path:
        d = tmp / f"t{id(tmp)}_{time.monotonic_ns()}"
        d.mkdir()
        return d

    def _write_py(path: Path, code: str) -> None:
        path.write_text(code)
        os.chmod(path, 0o755)

    def _t1() -> str | None:
        d = _td()
        sentinel = d / "SENTINEL"
        _write_py(d / "child.py", (
            "import os\n"
            f"f = open('{sentinel}', 'w')\n"
            "f.write(os.getcwd())\n"
            "f.close()\n"
        ))
        wd = Watchdog(d, hard_timeout=10, idle_timeout=5)
        r = wd.run(["python3", str(d / "child.py")], os.environ.copy())
        if r["returncode"] != 0 or not sentinel.exists():
            return "T1: child failed"
        pwd_content = sentinel.read_text()
        if pwd_content != str(d.resolve()):
            return f"T1: pwd mismatch: {pwd_content!r} != {d.resolve()!r}"
        ctrl = Path.cwd()
        if ctrl in d.parents or d == ctrl or d.is_relative_to(ctrl):
            return "T1: worktree is control checkout"
        return None

    def _t2() -> str | None:
        d = _td()
        wd = Watchdog(d, hard_timeout=2, idle_timeout=1)
        r = wd.run(["sleep", "30"], os.environ.copy())
        if r["success"]:
            return "T2: silent child should fail"
        if not r["timeout_type"]:
            return "T2: no timeout_type"
        return None

    def _t3() -> str | None:
        d = _td()
        _write_py(d / "slow.py", (
            "import sys, time\n"
            "for i in range(20):\n"
            "    print(f'line {i}', flush=True)\n"
            "    time.sleep(0.4)\n"
        ))
        wd = Watchdog(d, hard_timeout=15, idle_timeout=4)
        r = wd.run(["python3", str(d / "slow.py")], os.environ.copy())
        if not r["success"]:
            return f"T3: should survive: tt={r['timeout_type']} cls={r['classification']}"
        if r["returncode"] != 0:
            return f"T3: rc={r['returncode']}"
        return None

    def _t4() -> str | None:
        d = _td()
        _write_py(d / "tinyhang.py", (
            "import time, sys\n"
            "print('hi', flush=True)\n"
            "time.sleep(12)\n"
        ))
        wd = Watchdog(d, hard_timeout=15, idle_timeout=3)
        r = wd.run(["python3", str(d / "tinyhang.py")], os.environ.copy())
        if r["success"]:
            return "T4: should timeout after hang"
        if not r["timeout_type"]:
            return "T4: no timeout"
        if "hi" not in r["stdout"]:
            return "T4: missing initial output"
        return None

    def _t5() -> str | None:
        d = _td()
        _write_py(d / "eagain.py", (
            "import os, sys, time, fcntl, errno\n"
            "r, w = os.pipe()\n"
            "flags = fcntl.fcntl(r, fcntl.F_GETFL)\n"
            "fcntl.fcntl(r, fcntl.F_SETFL, flags | os.O_NONBLOCK)\n"
            "os.write(w, b'data1\\n')\n"
            "time.sleep(0.2)\n"
            "os.write(w, b'data2\\n')\n"
            "time.sleep(0.1)\n"
            "os.close(w)\n"
            "buf = bytearray()\n"
            "while True:\n"
            "    try:\n"
            "        d = os.read(r, 1024)\n"
            "        if not d:\n"
            "            break\n"
            "        buf.extend(d)\n"
            "    except OSError as e:\n"
            "        if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK):\n"
            "            break\n"
            "        raise\n"
            "print(f'read={len(buf)}', flush=True)\n"
            "time.sleep(1)\n"
            "print('after_wait', flush=True)\n"
        ))
        wd = Watchdog(d, hard_timeout=10, idle_timeout=5)
        r = wd.run(["python3", str(d / "eagain.py")], os.environ.copy())
        if r["returncode"] != 0:
            return f"T5: rc={r['returncode']}"
        if "after_wait" not in r["stdout"]:
            return "T5: missing output after wait"
        return None

    def _t6() -> str | None:
        d = _td()
        _write_py(d / "big.py", (
            "import sys\n"
            "for i in range(8000):\n"
            "    sys.stdout.write('O' * 200 + '\\n')\n"
            "    sys.stderr.write('E' * 200 + '\\n')\n"
            "sys.stdout.flush()\n"
            "sys.stderr.flush()\n"
        ))
        wd = Watchdog(d, hard_timeout=30, idle_timeout=15, tail_limit=4096)
        r = wd.run(["python3", str(d / "big.py")], os.environ.copy())
        if r["returncode"] != 0:
            return f"T6: rc={r['returncode']}"
        if len(wd._stdout_buf) > 4096:
            return f"T6: stdout_buf={len(wd._stdout_buf)}"
        if len(wd._stderr_buf) > 4096:
            return f"T6: stderr_buf={len(wd._stderr_buf)}"
        if r["total_stdout_bytes"] != 8000 * 201:
            return f"T6: total_stdout={r['total_stdout_bytes']}"
        return None

    def _t7() -> str | None:
        d = _td()
        big = "X" * 100000
        _write_py(d / "burst.py", (
            "import time\n"
            f"print('{big}')\n"
            "time.sleep(0.3)\n"
        ))
        wd = Watchdog(d, hard_timeout=10, idle_timeout=5, tail_limit=4096)
        r = wd.run(["python3", str(d / "burst.py")], os.environ.copy())
        if r["returncode"] != 0:
            return f"T7: rc={r['returncode']}"
        if len(wd._stdout_buf) > 4096:
            return f"T7: stdout_buf={len(wd._stdout_buf)}"
        return None

    def _t8() -> str | None:
        d = _td()
        _write_py(d / "term_ok.py", (
            "import sys, time, os\n"
            "sys.stdout.write('final bytes\\n')\n"
            "sys.stdout.flush()\n"
            "pid = os.fork()\n"
            "if pid == 0:\n"
            "    time.sleep(30)\n"
            "    sys.exit(0)\n"
            "time.sleep(0.1)\n"
            "sys.exit(0)\n"
        ))
        wd = Watchdog(d, hard_timeout=4, idle_timeout=3, holdpipe_timeout=1)
        r = wd.run(["python3", str(d / "term_ok.py")], os.environ.copy())
        if r["success"]:
            return "T8: should not succeed (held pipe)"
        if not r["term_sent"]:
            return "T8: term not sent"
        if r["kill_sent"]:
            return "T8: kill should not be sent (descendant killed by TERM)"
        if r["terminal_signal"] is not None:
            return f"T8: term_sig={r['terminal_signal']}"
        if r["returncode"] != 0:
            return f"T8: rc={r['returncode']}"
        if "final bytes" not in r["stdout"]:
            return "T8: missing final bytes"
        return None

    def _t9() -> str | None:
        d = _td()
        _write_py(d / "ignore_term.py", (
            "import signal, time\n"
            "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "time.sleep(30)\n"
        ))
        wd = Watchdog(d, hard_timeout=6, idle_timeout=5, holdpipe_timeout=1)
        r = wd.run(["python3", str(d / "ignore_term.py")], os.environ.copy())
        if r["success"]:
            return "T9: should not succeed"
        if not r["term_sent"]:
            return "T9: term not sent"
        if not r["kill_sent"]:
            return "T9: kill not sent"
        if r["terminal_signal"] != -9:
            return f"T9: term_sig={r['terminal_signal']}"
        return None

    def _t10() -> str | None:
        d = _td()
        _write_py(d / "leader_exit.py", (
            "import sys, time, os\n"
            "sys.stdout.write('leader_data\\n')\n"
            "sys.stdout.flush()\n"
            "pid = os.fork()\n"
            "if pid == 0:\n"
            "    time.sleep(30)\n"
            "    sys.exit(0)\n"
            "time.sleep(0.1)\n"
            "sys.exit(0)\n"
        ))
        wd = Watchdog(d, hard_timeout=4, idle_timeout=3, holdpipe_timeout=1)
        r = wd.run(["python3", str(d / "leader_exit.py")], os.environ.copy())
        if r["success"]:
            return "T10: should not succeed with held pipe"
        if r["terminal_signal"] is not None:
            return f"T10: term_sig={r['terminal_signal']}"
        if r["returncode"] != 0:
            return f"T10: leader rc={r['returncode']}"
        if "leader_data" not in r["stdout"]:
            return "T10: missing leader_data"
        return None

    def _t11() -> str | None:
        d = _td()
        _write_py(d / "alive.py", (
            "import time, os, sys\n"
            "pid = os.fork()\n"
            "if pid == 0:\n"
            "    time.sleep(60)\n"
            "    sys.exit(0)\n"
            "time.sleep(0.1)\n"
            "sys.exit(0)\n"
        ))
        wd = Watchdog(d, hard_timeout=5, idle_timeout=4, holdpipe_timeout=1)
        r = wd.run(["python3", str(d / "alive.py")], os.environ.copy())
        if r["success"]:
            return "T11: should not succeed"
        if not r["classification"]:
            return "T11: no classification"
        return None

    def _t12() -> str | None:
        d = _td()
        _write_py(d / "unreap.py", (
            "import time, os, signal, sys\n"
            "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "time.sleep(60)\n"
        ))
        wd = Watchdog(d, hard_timeout=5, idle_timeout=4, holdpipe_timeout=1)
        r = wd.run(["python3", str(d / "unreap.py")], os.environ.copy())
        if r["success"]:
            return "T12: should not succeed"
        if not r["kill_sent"]:
            return "T12: kill not sent"
        if r["returncode"] != -9:
            return f"T12: rc={r['returncode']}"
        if not r["leader_reaped"]:
            return "T12: should be reaped after SIGKILL"
        return None

    def _t13() -> str | None:
        d = _td()
        wd = Watchdog(d, hard_timeout=2, idle_timeout=1)
        r = wd.run(["sleep", "30"], os.environ.copy())
        if r["success"]:
            return "T13: timeout should not be success"
        if r["returncode"] == 0 and r["success"]:
            return "T13: rc=0 with timeout should fail"
        return None

    def _t14() -> str | None:
        tests = [
            ("BRIDGE_WATCHDOG_IDLE_TIMEOUT", "abc", 100.0, 100.0),
            ("BRIDGE_WATCHDOG_IDLE_TIMEOUT", "-5", 100.0, 1.0),
            ("BRIDGE_WATCHDOG_IDLE_TIMEOUT", "NaN", 100.0, 100.0),
            ("BRIDGE_WATCHDOG_IDLE_TIMEOUT", "inf", 100.0, 100.0),
            ("BRIDGE_WATCHDOG_IDLE_TIMEOUT", "0", 100.0, 1.0),
            ("BRIDGE_WATCHDOG_HARD_TIMEOUT", "999999999999", 100.0, 999999999999.0),
            ("BRIDGE_WATCHDOG_HARD_TIMEOUT", "NaN", 100.0, 100.0),
            ("BRIDGE_WATCHDOG_HARD_TIMEOUT", "abc", 100.0, 100.0),
            ("BRIDGE_WATCHDOG_TAIL_LIMIT", "xyz", 1024, 1024),
            ("BRIDGE_WATCHDOG_TAIL_LIMIT", "0", 1024, 1024),
            ("BRIDGE_WATCHDOG_TAIL_LIMIT", "-100", 1024, 1024),
        ]
        for var, val, default, expected in tests:
            os.environ[var] = val
            try:
                if "TAIL" in var:
                    got = _safe_int_env(val, int(default), clamp_min=1024, clamp_max=64*1024*1024)
                else:
                    got = _safe_float_env(val, default, clamp_min=1.0)
                if got != expected:
                    return f"T14: {var}={val}: got {got}, expected {expected}"
            finally:
                os.environ.pop(var, None)
        return None

    def _t15() -> str | None:
        d = _td()
        wd = Watchdog(d, hard_timeout=2, idle_timeout=1)
        r1 = wd.run(["sleep", "30"], os.environ.copy())
        if r1["success"]:
            return "T15: first should fail"
        wd2 = Watchdog(d, hard_timeout=2, idle_timeout=1)
        r2 = wd2.run(["python3", "-c", "print('ok')"], os.environ.copy())
        if r2["returncode"] != 0:
            return f"T15: second rc={r2['returncode']}"
        if "ok" not in r2["stdout"]:
            return "T15: second missing output"
        return None

    def _t16() -> str | None:
        d = _td()
        _write_py(d / "diag.py", (
            "import sys, time\n"
            "for i in range(1000):\n"
            "    sys.stdout.write('X' * 500 + '\\n')\n"
            "sys.stdout.flush()\n"
            "time.sleep(0.1)\n"
        ))
        wd = Watchdog(d, hard_timeout=10, idle_timeout=5, tail_limit=2048)
        r = wd.run(["python3", str(d / "diag.py")], os.environ.copy())
        combined = r["stdout"] + r["stderr"]
        if len(combined) > 8000:
            return "T16: diagnostics too large"
        if not combined.strip():
            return "T16: no diagnostics"
        return None

    test_fns = [
        ("T1: worktree isolation", _t1),
        ("T2: silent timeout", _t2),
        ("T3: sparse stdout survives", _t3),
        ("T4: tiny data then hang", _t4),
        ("T5: EAGAIN does not unregister", _t5),
        ("T6: multi-megabyte bounded", _t6),
        ("T7: single burst bounded", _t7),
        ("T8: TERM-handled leader", _t8),
        ("T9: TERM-ignoring leader", _t9),
        ("T10: held-pipe topology", _t10),
        ("T11: PGID-still-alive", _t11),
        ("T12: unreaped seam", _t12),
        ("T13: watchdog failure rejected", _t13),
        ("T14: safe env parsing", _t14),
        ("T15: queue liveness", _t15),
        ("T16: diagnostics bounded", _t16),
    ]
    for name, fn in test_fns:
        try:
            err = fn()
        except Exception as exc:
            err = f"{name}: exception {exc}"
        if err:
            failures.append(err)

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
