#!/usr/bin/env python3
"""JoeOS ChatGPT -> GitHub -> OpenCode bridge runner.

Runs only trusted [OC] GitHub issues carrying the bridge marker. It never merges.
PROJECT_BYTE execution hints are parsed as data and passed to OpenCode only after
strict validation; no issue text is ever interpreted by a shell.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import selectors
import selectors as _selectors_mod
import shlex
import shutil
import signal
import subprocess
import sys
import time
import uuid
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

# Subprocess watcher constants.
READ_CHUNK = int(os.getenv("BRIDGE_READ_CHUNK", "4096"))
RING_BUFFER_BYTES = int(os.getenv("BRIDGE_RING_BUFFER_BYTES", str(512 * 1024)))
IDLE_TIMEOUT = int(os.getenv("BRIDGE_IDLE_TIMEOUT", "300"))
TERM_GRACE = int(os.getenv("BRIDGE_TERM_GRACE", "5"))
DRAIN_GRACE = int(os.getenv("BRIDGE_DRAIN_GRACE", "10"))


def _nonblocking_read(fd: int, limit: int = READ_CHUNK) -> bytes:
    """Read at most *limit* bytes from a non-blocking fd.

    Returns the bytes read, or ``b""`` on EOF / no-data-available.
    Raises ``BlockingIOError`` on EAGAIN/EWOULDBLOCK.
    Never blocks.
    """
    return os.read(fd, limit)


def _process_pipe_data(
    fd: int,
    ring: list[bytes],
    output: list[bytes],
    limit: int,
) -> tuple[list[bytes], list[bytes], bool]:
    """Ingest bytes from *fd* into bounded ring + running output buffers.

    Returns ``(ring, output, has_data)`` where *has_data* is ``True`` when at
    least one byte was consumed.  Returns ``has_data=False`` on EAGAIN or EOF.
    Both ring and output are bounded to *limit* bytes (tail retention).
    """
    try:
        chunk = os.read(fd, READ_CHUNK)
    except BlockingIOError:
        return ring, output, False
    except OSError:
        return ring, output, False
    if not chunk:
        return ring, output, False
    ring.append(chunk)
    total = sum(len(p) for p in ring)
    while total > limit:
        total -= len(ring[0])
        ring.pop(0)
    output.append(chunk)
    total_out = sum(len(p) for p in output)
    while total_out > limit:
        total_out -= len(output[0])
        output.pop(0)
    return ring, output, True


def _drain_pipes(
    stdout_ring: list[bytes],
    stdout_out: list[bytes],
    stderr_ring: list[bytes],
    stderr_out: list[bytes],
    stdout_fd: int,
    stderr_fd: int,
    deadline: float,
) -> tuple[str, str, float]:
    """Bounded drain of remaining pipe data after process termination.

    Uses the same non-blocking read primitive as the main loop.  Returns
    ``(stdout_text, stderr_text, drain_time)``.
    """
    stdout_ring = list(stdout_ring)
    stdout_out = list(stdout_out)
    stderr_ring = list(stderr_ring)
    stderr_out = list(stderr_out)
    fd_bufs: dict[int, tuple[list[bytes], list[bytes]]] = {
        stdout_fd: (stdout_ring, stdout_out),
        stderr_fd: (stderr_ring, stderr_out),
    }
    start = time.monotonic()
    while fd_bufs and time.monotonic() < deadline:
        for fd in list(fd_bufs.keys()):
            ring, out = fd_bufs[fd]
            try:
                data = os.read(fd, READ_CHUNK)
            except BlockingIOError:
                continue
            except OSError:
                del fd_bufs[fd]
                continue
            if not data:
                del fd_bufs[fd]
                continue
            ring.append(data)
            out.append(data)
    return (
        b"".join(stdout_out).decode("utf-8", errors="replace"),
        b"".join(stderr_out).decode("utf-8", errors="replace"),
        time.monotonic() - start,
    )


class SubprocessWatcher:
    """Selector-driven, non-blocking streaming loop with idle watchdog.

    Uses ``selectors`` + ``os.read()`` (never ``BufferedReader.read()``) so that
    ingestion never blocks waiting for additional bytes after selector readiness.
    Maintains bounded per-stream ring buffers and enforces idle / drain deadlines.
    """

    def __init__(
        self,
        cmd: list[str],
        *,
        cwd: str | None = None,
        env: dict[str, str] | None = None,
        idle_timeout: int = IDLE_TIMEOUT,
        term_grace: int = TERM_GRACE,
        drain_grace: int = DRAIN_GRACE,
        output_limit: int = RING_BUFFER_BYTES,
    ) -> None:
        self.cmd = cmd
        self.cwd = cwd
        self.env = env or os.environ.copy()
        self.idle_timeout = max(idle_timeout, 1)
        self.term_grace = max(term_grace, 1)
        self.drain_grace = max(drain_grace, 1)
        self.output_limit = max(output_limit, READ_CHUNK)

    def run(self) -> tuple[str, str, int, float]:
        """Execute the command and return ``(stdout, stderr, returncode, elapsed)``."""
        start = time.monotonic()

        proc = subprocess.Popen(
            self.cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=self.cwd,
            env=self.env,
            start_new_session=True,
        )

        assert proc.stdout is not None
        assert proc.stderr is not None

        stdout_fd = proc.stdout.fileno()
        stderr_fd = proc.stderr.fileno()

        for fd in (stdout_fd, stderr_fd):
            flags = fcntl.fcntl(fd, fcntl.F_GETFL)
            fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)

        stdout_ring: list[bytes] = []
        stdout_out: list[bytes] = []
        stderr_ring: list[bytes] = []
        stderr_out: list[bytes] = []

        sel = selectors.DefaultSelector()
        sel.register(stdout_fd, selectors.EVENT_READ)
        sel.register(stderr_fd, selectors.EVENT_READ)

        active_fds: set[int] = {stdout_fd, stderr_fd}
        last_activity = time.monotonic()

        while True:
            elapsed_wall = time.monotonic() - start
            if proc.poll() is not None and not active_fds:
                break
            if time.monotonic() - last_activity > self.idle_timeout and proc.poll() is None:
                print(
                    f"[watchdog] idle {self.idle_timeout}s exceeded, terminating",
                    file=sys.stderr,
                )
                self._force_kill(proc)
                break
            if not active_fds:
                break

            timeout = max(0.1, self.idle_timeout - (time.monotonic() - last_activity))
            events = sel.select(timeout=timeout)
            if not events:
                continue

            for key, _mask in events:
                fd = key.fd
                ring, out = (
                    (stdout_ring, stdout_out) if fd == stdout_fd
                    else (stderr_ring, stderr_out)
                )
                ring, out, got_data = _process_pipe_data(fd, ring, out, self.output_limit)
                if fd == stdout_fd:
                    stdout_ring, stdout_out = ring, out
                else:
                    stderr_ring, stderr_out = ring, out
                if got_data:
                    last_activity = time.monotonic()
                else:
                    # Could be EAGAIN or EOF.  Probe distinguishes them:
                    # EAGAIN raises BlockingIOError; EOF returns b"".
                    try:
                        probe = os.read(fd, 1)
                    except (BlockingIOError, OSError):
                        probe = b"x"  # EAGAIN — keep fd registered
                    if not probe:
                        sel.unregister(fd)
                        active_fds.discard(fd)
                    else:
                        ring.append(probe)
                        total = sum(len(p) for p in ring)
                        while total > self.output_limit:
                            total -= len(ring[0])
                            ring.pop(0)
                        out.append(probe)
                        last_activity = time.monotonic()
                        if fd == stdout_fd:
                            stdout_ring, stdout_out = ring, out
                        else:
                            stderr_ring, stderr_out = ring, out

        sel.close()

        pipe_fds: list[int] = []
        if proc.poll() is None:
            pipe_fds = [fd for fd in (stdout_fd, stderr_fd) if fd in active_fds]
            if pipe_fds:
                deadline = time.monotonic() + self.drain_grace
                stdout_text, stderr_text, _drain_t = _drain_pipes(
                    stdout_ring, stdout_out,
                    stderr_ring, stderr_out,
                    stdout_fd, stderr_fd,
                    deadline,
                )
                self._force_kill(proc)
                proc.wait()
                elapsed = time.monotonic() - start
                return stdout_text, stderr_text, proc.returncode if proc.returncode is not None else -1, elapsed

        stdout_text, stderr_text, _drain_t = _drain_pipes(
            stdout_ring, stdout_out,
            stderr_ring, stderr_out,
            stdout_fd, stderr_fd,
            time.monotonic() + self.drain_grace,
        )

        self._force_kill(proc)
        proc.wait()
        elapsed = time.monotonic() - start
        return stdout_text, stderr_text, proc.returncode if proc.returncode is not None else -1, elapsed

    def _force_kill(self, proc: subprocess.Popen[int]) -> None:
        """Escalate TERM -> KILL within the bridge-owned process group."""
        if proc.poll() is not None:
            return
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
        except (ProcessLookupError, PermissionError, OSError):
            pass
        try:
            proc.wait(timeout=self.term_grace)
            return
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except (ProcessLookupError, PermissionError, OSError):
            pass
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass


def run_with_watchdog(
    cmd: list[str],
    *,
    cwd: str | None = None,
    env: dict[str, str] | None = None,
    idle_timeout: int = IDLE_TIMEOUT,
    term_grace: int = TERM_GRACE,
    drain_grace: int = DRAIN_GRACE,
    output_limit: int = RING_BUFFER_BYTES,
) -> subprocess.CompletedProcess[str]:
    """Run *cmd* with non-blocking streaming and an idle watchdog.

    Returns a ``CompletedProcess`` compatible result.
    """
    watcher = SubprocessWatcher(
        cmd,
        cwd=cwd,
        env=env,
        idle_timeout=idle_timeout,
        term_grace=term_grace,
        drain_grace=drain_grace,
        output_limit=output_limit,
    )
    stdout_text, stderr_text, returncode, elapsed = watcher.run()
    return subprocess.CompletedProcess(
        args=cmd,
        returncode=returncode,
        stdout=stdout_text,
        stderr=stderr_text,
    )


class BridgeError(RuntimeError):
    pass


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

    proc = run_with_watchdog(command, cwd=str(worktree), env=env)
    log_path.write_text(
        f"OpenCode version: {opencode_version}\n"
        f"Model source: {model_source}\n"
        f"Model: {model or '(OpenCode default)'}\n"
        f"$ {shlex.join(command[:-1])} <PROMPT>\n\n"
        f"exit={proc.returncode}\n\nSTDOUT\n{proc.stdout or ''}\n\n"
        f"STDERR\n{proc.stderr or ''}\n"
    )
    os.chmod(log_path, 0o600)

    if proc.returncode != 0:
        classification = classify_opencode_failure(proc.stdout or "", proc.stderr or "")
        excerpt = diagnostic_excerpt(proc.stdout or "", proc.stderr or "")
        state["processed"][str(number)] = {
            "status": "opencode-failed",
            "classification": classification,
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
            f"OpenCode exited with code `{proc.returncode}`. No PR was created.\n\n"
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
    passed = 0
    failed = 0

    def check(condition: bool, name: str) -> None:
        nonlocal passed, failed
        if condition:
            passed += 1
        else:
            failed += 1
            print(f"bridge self-test: FAILED — {name}", file=sys.stderr)

    # ── Existing unit tests ──────────────────────────────────────────────

    sample = (
        "Authorization: Bearer abcdefghijklmnop\n"
        "OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwxyz\n"
        "token ghp_abcdefghijklmnopqrstuvwxyz123456\n"
        "-----BEGIN PRIVATE KEY-----\nsecret\n-----END PRIVATE KEY-----\n"
    )
    cleaned = sanitize_text(sample)
    forbidden = ("abcdefghijklmnop", "sk-abcdefghijklmnopqrstuvwxyz", "ghp_", "\nsecret\n")
    check(
        not any(value in cleaned for value in forbidden),
        "redaction",
    )

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
        check(got == expected, f"classifier {text!r}")

    model_cases = [
        ("PROJECT_BYTE_MODEL_HINT: openai/gpt-5.6-sol", "openai/gpt-5.6-sol"),
        ("PROJECT_BYTE_MODEL_HINT: ollama/qwen3-coder:30b", "ollama/qwen3-coder:30b"),
        ("PROJECT_BYTE_MODEL_HINT: openai/gpt; rm -rf /", ""),
        ("PROJECT_BYTE_MODEL_HINT: https://example.com/model", ""),
        ("PROJECT_BYTE_MODEL_HINT: openai/gpt 5", ""),
    ]
    for body, expected in model_cases:
        got = project_byte_model_hint(body)
        check(got == expected, f"model hint {body!r}")

    check(
        choose_model("PROJECT_BYTE_MODEL_HINT: openai/gpt-5.6-sol", "env/model")
        == ("openai/gpt-5.6-sol", "project-byte"),
        "PROJECT_BYTE model precedence",
    )
    check(
        choose_model("", "env/model") == ("env/model", "environment"),
        "environment model fallback",
    )

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
        check(got == expected, f"recovery {expected}")

    check("skipped-existing-branch" in LEGACY_RECOVERABLE_STATUSES, "legacy recovery migration")

    malicious = project_byte_model_hint("PROJECT_BYTE_MODEL_HINT: openai/gpt$(touch /tmp/pwned)")
    check(not malicious, "shell-like model hint rejected")

    # ── Subprocess watcher integration tests ─────────────────────────────

    # Test 1: Silent child times out and returns within deterministic bound.
    t0 = time.monotonic()
    r = run_with_watchdog(
        ["python3", "-c", "import time; time.sleep(120)"],
        idle_timeout=2, term_grace=1, drain_grace=1,
    )
    elapsed = time.monotonic() - t0
    check(r.returncode != 0, "test1: silent child exit code")
    check(elapsed < 15, f"test1: elapsed {elapsed:.1f}s > 15s")

    # Test 2: Sparse stdout progress resets idle timeout.
    t0 = time.monotonic()
    r = run_with_watchdog(
        [
            "python3", "-c",
            "import time,sys\n"
            "for i in range(12):\n"
            "  sys.stdout.write('x'); sys.stdout.flush()\n"
            "  time.sleep(1)\n",
        ],
        idle_timeout=3, term_grace=1, drain_grace=1,
    )
    elapsed = time.monotonic() - t0
    check(r.returncode == 0, "test2: sparse stdout exit code")
    check(elapsed >= 9, f"test2: elapsed {elapsed:.1f}s < 9s (child killed early)")

    # Test 3: Sparse stderr progress resets idle timeout.
    t0 = time.monotonic()
    r = run_with_watchdog(
        [
            "python3", "-c",
            "import time,sys\n"
            "for i in range(12):\n"
            "  sys.stderr.write('y'); sys.stderr.flush()\n"
            "  time.sleep(1)\n",
        ],
        idle_timeout=3, term_grace=1, drain_grace=1,
    )
    elapsed = time.monotonic() - t0
    check(r.returncode == 0, "test3: sparse stderr exit code")
    check(elapsed >= 9, f"test3: elapsed {elapsed:.1f}s < 9s (child killed early)")

    # Test 4: Tiny-write-then-hang is terminated by idle timeout.
    t0 = time.monotonic()
    r = run_with_watchdog(
        [
            "python3", "-c",
            "import time,sys\n"
            "sys.stdout.write('a'); sys.stdout.flush()\n"
            "time.sleep(120)\n",
        ],
        idle_timeout=3, term_grace=1, drain_grace=1,
    )
    elapsed = time.monotonic() - t0
    check(r.returncode != 0, "test4: tiny-write-hang exit code")
    check(elapsed < 15, f"test4: elapsed {elapsed:.1f}s > 15s")
    check("a" in (r.stdout or ""), "test4: tiny-write captured")

    # Test 5: Multi-megabyte output is consumed without deadlock and bounded.
    r = run_with_watchdog(
        [
            "python3", "-c",
            "import sys; sys.stdout.write('M' * (1024*1024)); "
            "sys.stderr.write('E' * (1024*1024)); "
            "sys.stdout.flush(); sys.stderr.flush()",
        ],
        idle_timeout=30, term_grace=1, drain_grace=1,
        output_limit=256 * 1024,
    )
    check(r.returncode == 0, "test5: large output exit code")
    out_len = len(r.stdout or "")
    err_len = len(r.stderr or "")
    check(out_len <= 256 * 1024 + READ_CHUNK, f"test5: stdout {out_len} > bound")
    check(err_len <= 256 * 1024 + READ_CHUNK, f"test5: stderr {err_len} > bound")

    # Test 6: TERM-ignoring child escalates to KILL.
    t0 = time.monotonic()
    r = run_with_watchdog(
        [
            "python3", "-c",
            "import signal,time\n"
            "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "time.sleep(120)\n",
        ],
        idle_timeout=2, term_grace=2, drain_grace=1,
    )
    elapsed = time.monotonic() - t0
    check(r.returncode != 0, "test6: TERM-ignoring exit code")
    check(elapsed < 15, f"test6: elapsed {elapsed:.1f}s > 15s")

    # Test 7: Unrelated process survives timeout handling.
    marker = str(uuid.uuid4())
    sleeper = subprocess.Popen(
        ["python3", "-c", f"import time; open('/tmp/{marker}', 'w').write('ok'); time.sleep(300)"],
        start_new_session=True,
    )
    time.sleep(0.3)
    t0 = time.monotonic()
    r = run_with_watchdog(
        ["python3", "-c", "import time; time.sleep(120)"],
        idle_timeout=2, term_grace=1, drain_grace=1,
    )
    elapsed = time.monotonic() - t0
    alive = sleeper.poll() is None
    check(alive, "test7: unrelated process killed")
    check(elapsed < 15, f"test7: elapsed {elapsed:.1f}s > 15s")
    try:
        os.killpg(os.getpgid(sleeper.pid), signal.SIGTERM)
    except (ProcessLookupError, OSError):
        pass
    try:
        sleeper.wait(timeout=3)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(sleeper.pid), signal.SIGKILL)
        except (ProcessLookupError, OSError):
            pass
        try:
            sleeper.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass
    try:
        os.unlink(f"/tmp/{marker}")
    except OSError:
        pass

    # Test 8: Held-pipe descendant — bounded drain returns within bound.
    t0 = time.monotonic()
    r = run_with_watchdog(
        [
            "python3", "-c",
            "import os,time\n"
            "pid = os.fork()\n"
            "if pid == 0:\n"
            "  time.sleep(300)\n"
            "else:\n"
            "  time.sleep(120)\n",
        ],
        idle_timeout=2, term_grace=1, drain_grace=3,
    )
    elapsed = time.monotonic() - t0
    check(elapsed < 15, f"test8: elapsed {elapsed:.1f}s > 15s")

    # Test 9: Queue processing continues after timeout.
    r1 = run_with_watchdog(
        ["python3", "-c", "import time; time.sleep(120)"],
        idle_timeout=1, term_grace=1, drain_grace=1,
    )
    check(r1.returncode != 0, "test9a: first timeout")
    r2 = run_with_watchdog(
        ["python3", "-c", "import sys; sys.stdout.write('ok'); sys.stdout.flush()"],
        idle_timeout=10, term_grace=1, drain_grace=1,
    )
    check(r2.returncode == 0, "test9b: second after timeout")
    check("ok" in (r2.stdout or ""), "test9b: output after timeout")

    # Test 10: Diagnostics bounded and sanitized.
    r = run_with_watchdog(
        [
            "python3", "-c",
            "import sys\n"
            "for _ in range(20000):\n"
            "  sys.stdout.write('A' * 200)\n"
            "sys.stdout.flush()",
        ],
        idle_timeout=30, term_grace=1, drain_grace=1,
        output_limit=8192,
    )
    out = r.stdout or ""
    check(len(out) <= 8192 + READ_CHUNK, f"test10: output {len(out)} > bound")
    check("AAAAAA" in out, "test10: truncated output contains data")

    # ── Summary ──────────────────────────────────────────────────────────

    if failed:
        print(
            f"bridge self-test: {failed} FAILED, {passed} passed",
            file=sys.stderr,
        )
        return 1
    print(f"bridge self-test: PASS ({passed} tests)")
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
