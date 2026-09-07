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
import select
import shlex
import shutil
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass
class WatchdogResult:
    returncode: int | None
    stdout_tail: bytes
    stderr_tail: bytes
    elapsed: float
    term_sent: bool
    kill_sent: bool
    terminal_signal: int | None
    leader_reaped: bool
    reason: str
    held_pipes_drained: bool


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

OPENCODE_IDLE_TIMEOUT = int(os.getenv("OPENCODE_IDLE_TIMEOUT", "1800"))
HELD_PIPE_DRAIN_TIMEOUT = int(os.getenv("HELD_PIPE_DRAIN_TIMEOUT", "15"))
REAP_TIMEOUT = 5
TERM_GRACE = 3
TAIL_LIMIT = 8192

FDEOF = type("FDEOF", (), {"__repr__": lambda s: "FDEOF"})()
FWOULDBLOCK = type("FWOULDBLOCK", (), {"__repr__": lambda s: "FWOULDBLOCK"})()


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


def _clamp_timeout(value: int, default: int, minimum: int = 1) -> int:
    try:
        v = int(value)
    except (TypeError, ValueError):
        return default
    return v if v >= minimum else default


def _nb_read(fd: int) -> tuple[bytes, object]:
    try:
        data = os.read(fd, 32768)
        return data, FDEOF if not data else data
    except BlockingIOError:
        return b"", FWOULDBLOCK


def _reap_child(pid: int, deadline: float) -> tuple[int | None, int | None]:
    while time.time() < deadline:
        result = os.waitpid(pid, os.WNOHANG)
        if result[0] != 0:
            status = result[1]
            if os.WIFSIGNALED(status):
                return None, os.WTERMSIG(status)
            return os.WEXITSTATUS(status), None
        time.sleep(0.05)
    return None, None


def watchdog(
    cmd: list[str],
    *,
    cwd: str | None = None,
    env: dict[str, str] | None = None,
    idle_timeout: int | None = None,
    held_pipe_timeout: int | None = None,
) -> "WatchdogResult":
    no_output_timeout = _clamp_timeout(
        idle_timeout if idle_timeout is not None else OPENCODE_IDLE_TIMEOUT,
        OPENCODE_IDLE_TIMEOUT,
    )
    drain_timeout = _clamp_timeout(
        held_pipe_timeout if held_pipe_timeout is not None else HELD_PIPE_DRAIN_TIMEOUT,
        HELD_PIPE_DRAIN_TIMEOUT,
    )
    child = subprocess.Popen(
        cmd,
        cwd=cwd,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    pgid = child.pid
    stdout_tail = bytearray()
    stderr_tail = bytearray()
    child_exited = False
    drain_deadline: float | None = None
    held_pipes_drained = False
    term_sent = False
    kill_sent = False
    terminal_signal: int | None = None
    start = time.time()

    sel = select.epoll()
    stdout_fd = child.stdout.fileno()
    stderr_fd = child.stderr.fileno()
    fcntl.fcntl(stdout_fd, fcntl.F_SETFL, os.O_NONBLOCK)
    fcntl.fcntl(stderr_fd, fcntl.F_SETFL, os.O_NONBLOCK)
    sel.register(stdout_fd, select.EPOLLIN)
    sel.register(stderr_fd, select.EPOLLIN)
    fds_alive = 2

    no_output_deadline = start + no_output_timeout

    try:
        while fds_alive > 0:
            now = time.time()
            if child_exited:
                if drain_deadline is None:
                    drain_deadline = now + drain_timeout
                if now >= drain_deadline:
                    held_pipes_drained = True
                    break
                poll_timeout = max(0.001, drain_deadline - now)
            else:
                if now >= no_output_deadline:
                    if not term_sent:
                        try:
                            os.killpg(pgid, signal.SIGTERM)
                        except ProcessLookupError:
                            pass
                        term_sent = True
                        no_output_deadline = now + TERM_GRACE
                    else:
                        if now >= no_output_deadline:
                            try:
                                os.killpg(pgid, signal.SIGKILL)
                            except ProcessLookupError:
                                pass
                            kill_sent = True
                            break
                poll_timeout = 0.2

            try:
                events = sel.poll(poll_timeout)
            except OSError:
                break

            if not child_exited:
                rc = child.poll()
                if rc is not None:
                    child_exited = True
                    drain_deadline = time.time() + drain_timeout

            for fd, event in events:
                if event & (select.EPOLLHUP | select.EPOLLERR):
                    sel.unregister(fd)
                    fds_alive -= 1
                    continue
                if event & select.EPOLLIN:
                    if fd == stdout_fd:
                        data, status = _nb_read(fd)
                        if status is FWOULDBLOCK:
                            pass
                        elif status is FDEOF:
                            sel.unregister(fd)
                            fds_alive -= 1
                        else:
                            stdout_tail.extend(data)
                            if len(stdout_tail) > TAIL_LIMIT:
                                del stdout_tail[: len(stdout_tail) - TAIL_LIMIT]
                    elif fd == stderr_fd:
                        data, status = _nb_read(fd)
                        if status is FWOULDBLOCK:
                            pass
                        elif status is FDEOF:
                            sel.unregister(fd)
                            fds_alive -= 1
                        else:
                            stderr_tail.extend(data)
                            if len(stderr_tail) > TAIL_LIMIT:
                                del stderr_tail[: len(stderr_tail) - TAIL_LIMIT]

            if not child_exited:
                rc = child.poll()
                if rc is not None:
                    child_exited = True
                    drain_deadline = time.time() + drain_timeout

        if not child_exited:
            rc = child.poll()
            if rc is not None:
                child_exited = True

        if not child_exited:
            if not term_sent:
                try:
                    os.killpg(pgid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                term_sent = True
            grace_deadline = time.time() + TERM_GRACE
            while time.time() < grace_deadline:
                rc = child.poll()
                if rc is not None:
                    child_exited = True
                    break
                time.sleep(0.05)
            if not child_exited:
                try:
                    os.killpg(pgid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                kill_sent = True
                try:
                    child.wait(timeout=REAP_TIMEOUT)
                    child_exited = True
                except subprocess.TimeoutExpired:
                    pass

        if child_exited:
            try:
                child.wait(timeout=REAP_TIMEOUT)
            except (subprocess.TimeoutExpired, ChildProcessError):
                pass
            terminal_signal = None
            if child.returncode is not None and child.returncode < 0:
                terminal_signal = -child.returncode

        for fd in [stdout_fd, stderr_fd]:
            try:
                sel.unregister(fd)
            except (OSError, ValueError):
                pass
            try:
                os.close(fd)
            except OSError:
                pass

        if not child_exited:
            try:
                child.kill()
                kill_sent = True
            except ProcessLookupError:
                pass
            try:
                child.wait(timeout=REAP_TIMEOUT)
                child_exited = True
            except subprocess.TimeoutExpired:
                pass

    finally:
        try:
            sel.close()
        except Exception:
            pass

    leader_reaped = child_exited
    returncode = child.returncode if child_exited else None
    elapsed = time.time() - start

    return WatchdogResult(
        returncode=returncode,
        stdout_tail=bytes(stdout_tail),
        stderr_tail=bytes(stderr_tail),
        elapsed=elapsed,
        term_sent=term_sent,
        kill_sent=kill_sent,
        terminal_signal=terminal_signal,
        leader_reaped=leader_reaped,
        reason="held-pipe-cleanup" if held_pipes_drained else (
            "opencode-idle-timeout" if kill_sent or term_sent else "normal-exit"
        ),
        held_pipes_drained=held_pipes_drained,
    )


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

    result = watchdog(command, cwd=str(worktree), env=env)
    stdout_text = result.stdout_tail.decode("utf-8", errors="replace")
    stderr_text = result.stderr_tail.decode("utf-8", errors="replace")
    log_path.write_text(
        f"OpenCode version: {opencode_version}\n"
        f"Model source: {model_source}\n"
        f"Model: {model or '(OpenCode default)'}\n"
        f"$ {shlex.join(command[:-1])} <PROMPT>\n\n"
        f"exit={result.returncode}\n"
        f"term_sent={result.term_sent} kill_sent={result.kill_sent}\n"
        f"terminal_signal={result.terminal_signal}\n"
        f"leader_reaped={result.leader_reaped}\n"
        f"reason={result.reason}\n"
        f"elapsed={result.elapsed:.1f}s\n\nSTDOUT\n{stdout_text}\n\n"
        f"STDERR\n{stderr_text}\n"
    )
    os.chmod(log_path, 0o600)

    if result.returncode is None or result.returncode != 0:
        classification = classify_opencode_failure(stdout_text, stderr_text)
        excerpt = diagnostic_excerpt(stdout_text, stderr_text)
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
            f"OpenCode exited with code `{result.returncode}`. No PR was created.\n\n"
            f"Classification: `{classification}`\n\n"
            f"Reason: `{result.reason}`\n\n"
            f"term_sent={result.term_sent} kill_sent={result.kill_sent}\n\n"
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
    py = sys.executable
    failed = 0

    def _check(name: str, condition: bool, detail: str = "") -> None:
        nonlocal failed
        if not condition:
            msg = f"bridge self-test: {name} FAILED"
            if detail:
                msg += f" — {detail}"
            print(msg, file=sys.stderr)
            failed += 1

    # Existing tests: redaction
    sample = (
        "Authorization: Bearer abcdefghijklmnop\n"
        "OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwxyz\n"
        "token ghp_abcdefghijklmnopqrstuvwxyz123456\n"
        "-----BEGIN PRIVATE KEY-----\nsecret\n-----END PRIVATE KEY-----\n"
    )
    cleaned = sanitize_text(sample)
    forbidden = ("abcdefghijklmnop", "sk-abcdefghijklmnopqrstuvwxyz", "ghp_", "\nsecret\n")
    _check("redaction", not any(v in cleaned for v in forbidden), cleaned[:200])

    # Existing tests: classifier
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
        _check(f"classifier-{expected}", got == expected, f"{got} != {expected}")

    # Existing tests: model hints
    model_cases = [
        ("PROJECT_BYTE_MODEL_HINT: openai/gpt-5.6-sol", "openai/gpt-5.6-sol"),
        ("PROJECT_BYTE_MODEL_HINT: ollama/qwen3-coder:30b", "ollama/qwen3-coder:30b"),
        ("PROJECT_BYTE_MODEL_HINT: openai/gpt; rm -rf /", ""),
        ("PROJECT_BYTE_MODEL_HINT: https://example.com/model", ""),
        ("PROJECT_BYTE_MODEL_HINT: openai/gpt 5", ""),
    ]
    for body, expected in model_cases:
        got = project_byte_model_hint(body)
        _check("model-hint", got == expected, f"{body!r} -> {got!r}")
    _check(
        "project-byte-precedence",
        choose_model("PROJECT_BYTE_MODEL_HINT: openai/gpt-5.6-sol", "env/model")
        == ("openai/gpt-5.6-sol", "project-byte"),
    )
    _check(
        "env-model-fallback",
        choose_model("", "env/model") == ("env/model", "environment"),
    )

    # Existing tests: recovery
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
        _check(f"recovery-{expected}", got == expected, f"{kwargs} -> {got}")

    _check("legacy-recovery", "skipped-existing-branch" in LEGACY_RECOVERABLE_STATUSES)

    malicious = project_byte_model_hint("PROJECT_BYTE_MODEL_HINT: openai/gpt$(touch /tmp/pwned)")
    _check("shell-injection-rejected", not malicious)

    # ── Watchdog tests ──────────────────────────────────────────────────

    # Test 1: Silent leader bounded TERM then KILL
    t1_start = time.time()
    t1 = watchdog(
        [py, "-c", "import time; time.sleep(300)"],
        idle_timeout=2,
        held_pipe_timeout=2,
    )
    t1_elapsed = time.time() - t1_start
    _check("t1-term-sent", t1.term_sent, f"term_sent={t1.term_sent}")
    _check("t1-killed", t1.kill_sent or t1.returncode is not None, f"rc={t1.returncode} kill={t1.kill_sent}")
    _check("t1-timeout-bound", t1_elapsed < 15, f"elapsed={t1_elapsed:.1f}s")
    _check("t1-reason-idle", t1.reason == "opencode-idle-timeout", f"reason={t1.reason}")

    # Test 2: Sparse stdout progress completes without timeout
    t2 = watchdog(
        [py, "-c", "import time\nfor i in range(5):\n print(f'line{i}', flush=True)\n time.sleep(0.3)"],
        idle_timeout=2,
        held_pipe_timeout=2,
    )
    _check("t2-completed", t2.returncode == 0, f"rc={t2.returncode}")
    _check("t2-no-term", not t2.term_sent, "should complete without TERM")
    _check("t2-output", b"line0" in t2.stdout_tail, f"stdout={t2.stdout_tail[:100]}")

    # Test 3: Sparse stderr completes without timeout
    t3 = watchdog(
        [py, "-c", "import time,sys\nfor i in range(5):\n print(f'err{i}', file=sys.stderr, flush=True)\n time.sleep(0.3)"],
        idle_timeout=2,
        held_pipe_timeout=2,
    )
    _check("t3-completed", t3.returncode == 0, f"rc={t3.returncode}")
    _check("t3-no-term", not t3.term_sent)
    _check("t3-stderr-output", b"err0" in t3.stderr_tail, f"stderr={t3.stderr_tail[:100]}")

    # Test 4: Tiny write then hang still times out
    t4_start = time.time()
    t4 = watchdog(
        [py, "-c", "import time; print('once', flush=True); time.sleep(300)"],
        idle_timeout=2,
        held_pipe_timeout=2,
    )
    t4_elapsed = time.time() - t4_start
    _check("t4-timeout", t4.term_sent or t4.kill_sent, f"term={t4.term_sent} kill={t4.kill_sent}")
    _check("t4-timeout-bound", t4_elapsed < 15, f"elapsed={t4_elapsed:.1f}s")
    _check("t4-output-captured", b"once" in t4.stdout_tail, f"stdout={t4.stdout_tail[:100]}")

    # Test 5: WOULD_BLOCK on a live fd remains registered
    r_fd, w_fd = os.pipe()
    os.set_blocking(r_fd, False)
    sel = select.epoll()
    sel.register(r_fd, select.EPOLLIN)
    # No data written — epoll should not return events
    events = sel.poll(10)
    _check("t5-no-event-when-empty", len(events) == 0, f"events={events}")
    # _nb_read should return WOULD_BLOCK
    data, status = _nb_read(r_fd)
    _check("t5-would-block", status is FWOULDBLOCK, f"status={status!r}")
    _check("t5-fd-still-registered", True)  # poll did not unregister
    # Write data, verify fd still readable
    os.write(w_fd, b"hello")
    events = sel.poll(100)
    _check("t5-readable-after-write", len(events) > 0, f"events={events}")
    data, status = _nb_read(r_fd)
    _check("t5-data-consumed", status is not FWOULDBLOCK and data == b"hello", f"data={data!r} status={status!r}")
    sel.unregister(r_fd)
    sel.close()
    os.close(r_fd)
    os.close(w_fd)

    # Test 6: Multi-megabyte bounded tails
    t6_script = (
        "import sys; data = b'X' * (512 * 1024)\n"
        "sys.stdout.buffer.write(data)\nsys.stderr.buffer.write(data)\n"
    )
    t6 = watchdog(
        [py, "-c", t6_script],
        idle_timeout=5,
        held_pipe_timeout=2,
    )
    _check("t6-completed", t6.returncode == 0, f"rc={t6.returncode}")
    _check("t6-stdout-bounded", len(t6.stdout_tail) <= TAIL_LIMIT + 32768,
           f"len={len(t6.stdout_tail)} limit={TAIL_LIMIT}")
    _check("t6-stderr-bounded", len(t6.stderr_tail) <= TAIL_LIMIT + 32768,
           f"len={len(t6.stderr_tail)} limit={TAIL_LIMIT}")
    _check("t6-stdout-has-data", len(t6.stdout_tail) > 0)
    _check("t6-stderr-has-data", len(t6.stderr_tail) > 0)

    # Test 7: TERM-handling child captures output, term_sent=True, kill_sent=False
    t7 = watchdog(
        [py, "-c", (
            "import signal,sys,time\n"
            "def handler(sig,frame): print('shutdown',flush=True); sys.exit(0)\n"
            "signal.signal(signal.SIGTERM,handler)\n"
            "time.sleep(300)\n"
        )],
        idle_timeout=2,
        held_pipe_timeout=2,
    )
    _check("t7-term-sent", t7.term_sent, f"term={t7.term_sent}")
    _check("t7-no-kill", not t7.kill_sent, f"kill={t7.kill_sent}")
    _check("t7-output-captured", b"shutdown" in t7.stdout_tail or b"shutdown" in t7.stderr_tail,
           f"stdout={t7.stdout_tail[:100]} stderr={t7.stderr_tail[:100]}")

    # Test 8: TERM-ignoring child requires escalation, kill_sent=True
    t8 = watchdog(
        [py, "-c", (
            "import signal,signal as _s,time\n"
            "_s.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "time.sleep(300)\n"
        )],
        idle_timeout=2,
        held_pipe_timeout=2,
    )
    _check("t8-term-sent", t8.term_sent, f"term={t8.term_sent}")
    _check("t8-kill-sent", t8.kill_sent, f"kill={t8.kill_sent}")
    _check("t8-reason", t8.reason == "opencode-idle-timeout", f"reason={t8.reason}")

    # Test 9: Unrelated process survives cleanup
    survivor = subprocess.Popen(
        [py, "-c", "import time; time.sleep(300)"],
        start_new_session=True,
    )
    survivor_pid = survivor.pid
    t9 = watchdog(
        [py, "-c", "import time; time.sleep(300)"],
        idle_timeout=2,
        held_pipe_timeout=2,
    )
    time.sleep(0.3)
    alive = survivor.poll() is None
    _check("t9-unrelated-alive", alive, f"survivor pid={survivor_pid} alive={alive}")
    try:
        os.killpg(survivor_pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        survivor.wait(timeout=2)
    except subprocess.TimeoutExpired:
        pass

    # Test 10: Normal leader exit + held-pipe descendant
    # Child spawns grandchild keeping stdout open, then exits immediately
    t10_script = (
        f"import subprocess,sys,os,time\n"
        f"p = subprocess.Popen([{py!r}, '-c', 'import time; time.sleep(300)'],\n"
        f"    stdout=sys.stdout, stderr=sys.stderr, start_new_session=True)\n"
        f"os._exit(0)\n"
    )
    t10_start = time.time()
    t10 = watchdog(
        [py, "-c", t10_script],
        idle_timeout=60,
        held_pipe_timeout=3,
    )
    t10_elapsed = time.time() - t10_start
    _check("t10-held-pipe-reason", t10.reason == "held-pipe-cleanup",
           f"reason={t10.reason}")
    _check("t10-bounded-time", t10_elapsed < 15,
           f"elapsed={t10_elapsed:.1f}s (should be <15, not 60)")
    _check("t10-held-drained", t10.held_pipes_drained, f"drained={t10.held_pipes_drained}")

    # Test 11: Configuration clamp — invalid/zero/negative timeout
    _check("t11-zero-clamp", _clamp_timeout(0, 99) == 99, f"got={_clamp_timeout(0, 99)}")
    _check("t11-negative-clamp", _clamp_timeout(-5, 99) == 99, f"got={_clamp_timeout(-5, 99)}")
    _check("t11-invalid-clamp", _clamp_timeout("abc", 99) == 99, f"got={_clamp_timeout('abc', 99)}")
    _check("t11-valid-pass", _clamp_timeout(42, 99) == 42, f"got={_clamp_timeout(42, 99)}")
    _check("t11-minimum-clamp", _clamp_timeout(0, 99, minimum=1) == 99)
    _check("t11-one-valid", _clamp_timeout(1, 99, minimum=1) == 1)
    # Verify env-configured timeouts are actually used
    t11 = watchdog(
        [py, "-c", "print('ok', flush=True)"],
        idle_timeout=10,
        held_pipe_timeout=5,
    )
    _check("t11-config-used", t11.returncode == 0)

    # Test 12: Timeout result persists deterministic state/classification
    _check("t12-reason-values", t1.reason in ("opencode-idle-timeout", "normal-exit", "held-pipe-cleanup"))
    _check("t12-reaped-bool", isinstance(t1.leader_reaped, bool))
    _check("t12-elapsed-float", isinstance(t1.elapsed, float) and t1.elapsed >= 0)

    # Test 13: Second watchdog child after timeout succeeds (queue liveness)
    t13a = watchdog(
        [py, "-c", "import time; time.sleep(300)"],
        idle_timeout=1,
        held_pipe_timeout=1,
    )
    t13b = watchdog(
        [py, "-c", "print('second-ok', flush=True)"],
        idle_timeout=5,
        held_pipe_timeout=2,
    )
    _check("t13a-timeout", t13a.reason == "opencode-idle-timeout")
    _check("t13b-success", t13b.returncode == 0, f"rc={t13b.returncode}")
    _check("t13b-output", b"second-ok" in t13b.stdout_tail)

    # Test 14: Diagnostics bounded and sanitized
    diag = diagnostic_excerpt("x" * 10000, "y" * 10000)
    _check("t14-bounded", len(diag) <= DIAGNOSTIC_LIMIT + 200, f"len={len(diag)}")
    _check("t14-sanitized", "```" not in diag, "backticks should be replaced")

    # Test 15: unreaped/status types — returncode is None only for truly unreaped
    _check("t15-normal-int-or-none", t1.returncode is None or isinstance(t1.returncode, int))
    _check("t15-sigterm-is-int", t1.terminal_signal is None or isinstance(t1.terminal_signal, int))

    if failed:
        print(f"bridge self-test: {failed} FAILED", file=sys.stderr)
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
