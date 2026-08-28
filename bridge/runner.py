#!/usr/bin/env python3
"""JoeOS ChatGPT -> GitHub -> OpenCode bridge runner.

Runs only tasks created as GitHub issues by trusted authors. It never merges.
"""
from __future__ import annotations
import argparse, fcntl, json, os, re, shlex, subprocess, sys, time
from pathlib import Path
from typing import Any

BRIDGE_MARKER = "<!-- joeos-opencode-bridge:v1 -->"
DEFAULT_REPO = "jmw7629/StickDeath-Infinity-"

class BridgeError(RuntimeError):
    pass

def run(args: list[str], *, cwd: Path | None = None, check: bool = True, capture: bool = True, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(args, cwd=str(cwd) if cwd else None, text=True, capture_output=capture, check=False, env=env)
    if check and proc.returncode != 0:
        stdout = (proc.stdout or "").strip()
        stderr = (proc.stderr or "").strip()
        raise BridgeError(f"Command failed ({proc.returncode}): {shlex.join(args)}\nstdout:\n{stdout[-4000:]}\nstderr:\n{stderr[-4000:]}")
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
    proc = run(["gh", "issue", "list", "--repo", repo, "--state", "open", "--limit", "100", "--json", "number,title,body,author,url,createdAt"])
    data = json.loads(proc.stdout or "[]")
    allowed = trusted_authors()
    tasks: list[dict[str, Any]] = []
    for issue in data:
        author = ((issue.get("author") or {}).get("login") or "").strip()
        title = (issue.get("title") or "").strip()
        body = issue.get("body") or ""
        if author in allowed and title.startswith("[OC]") and BRIDGE_MARKER in body:
            tasks.append(issue)
    return sorted(tasks, key=lambda item: int(item["number"]))

def ensure_repo(root: Path, repo: str) -> None:
    if run(["git", "status", "--porcelain"], cwd=root).stdout.strip():
        raise BridgeError(f"Repository has uncommitted changes: {root}. Bridge refuses a dirty control checkout.")
    remote = run(["git", "remote", "get-url", "origin"], cwd=root).stdout.strip()
    normalized = remote.lower().rstrip("/").removesuffix(".git")
    if repo.lower() not in normalized:
        raise BridgeError(f"origin is {remote!r}; expected {repo!r}")

def comment_issue(repo: str, number: int, message: str) -> None:
    run(["gh", "issue", "comment", str(number), "--repo", repo, "--body", message])

def build_prompt(issue: dict[str, Any]) -> str:
    number = int(issue["number"])
    title = issue["title"]
    body = issue.get("body") or ""
    return f"""You are the implementation executor for GitHub issue #{number}: {title}\n\nRead AGENTS.md before doing anything else and follow it as mandatory project policy.\n\nBridge rules:\n- Work only inside the current worktree.\n- Do not commit, push, merge, create tags, or rewrite git history. The bridge handles git.\n- Do not modify bridge/ or AGENTS.md unless the issue explicitly requests bridge changes.\n- Never print, commit, or upload secrets, tokens, OAuth credentials, private keys, or local model credentials.\n- Do not commit recovered StickDeath SWFs, original media, or other reference-corpus assets.\n- Inspect the existing implementation before changing it.\n- Execute relevant tests/build checks that are possible here.\n- Never claim PASS for a check you did not actually run.\n- Keep the change focused; no opportunistic rewrites.\n- Finish with a concise report of changed areas, checks actually run, failures/gaps, and remaining risks.\n\n--- BEGIN ISSUE ---\n{body}\n--- END ISSUE ---\n"""

def branch_exists(root: Path, branch: str) -> bool:
    local = run(["git", "show-ref", "--verify", "--quiet", f"refs/heads/{branch}"], cwd=root, check=False)
    if local.returncode == 0:
        return True
    remote = run(["git", "ls-remote", "--exit-code", "--heads", "origin", branch], cwd=root, check=False)
    return remote.returncode == 0

def process_task(root: Path, repo: str, issue: dict[str, Any], state: dict[str, Any], state_path: Path, worktree_root: Path) -> None:
    number = int(issue["number"])
    title = issue["title"].strip()
    branch = f"oc/issue-{number}-{slugify(title.removeprefix('[OC]').strip())}"
    worktree = worktree_root / f"issue-{number}"
    logs_dir = state_path.parent / "logs"
    logs_dir.mkdir(parents=True, exist_ok=True)
    log_path = logs_dir / f"issue-{number}.log"

    if branch_exists(root, branch):
        state["processed"][str(number)] = {"status": "skipped-existing-branch", "branch": branch, "time": int(time.time())}
        save_state(state_path, state)
        comment_issue(repo, number, f"Bridge refused to re-run because branch `{branch}` already exists. Create a new `[OC]` issue for a revision.")
        return

    run(["git", "fetch", "--prune", "origin", "main"], cwd=root)
    if worktree.exists():
        run(["git", "worktree", "remove", "--force", str(worktree)], cwd=root)
    worktree.parent.mkdir(parents=True, exist_ok=True)
    run(["git", "worktree", "add", "-b", branch, str(worktree), "origin/main"], cwd=root)
    comment_issue(repo, number, f"JoeOS bridge accepted this task. OpenCode is executing on branch `{branch}`. Nothing will be merged automatically.")

    command = [os.getenv("OPENCODE_BIN", "opencode"), "run", "--dir", str(worktree), "--auto", "--format", "json", "--title", f"GitHub issue #{number}"]
    model = os.getenv("OPENCODE_MODEL", "").strip()
    if model:
        command.extend(["--model", model])
    agent = os.getenv("OPENCODE_AGENT", "").strip()
    if agent:
        command.extend(["--agent", agent])
    attach = os.getenv("OPENCODE_ATTACH_URL", "").strip()
    if attach:
        command.extend(["--attach", attach])
    command.append(build_prompt(issue))

    proc = run(command, cwd=worktree, check=False, env=os.environ.copy())
    log_path.write_text(f"exit={proc.returncode}\n\nSTDOUT\n{proc.stdout or ''}\n\nSTDERR\n{proc.stderr or ''}\n")
    os.chmod(log_path, 0o600)

    if proc.returncode != 0:
        state["processed"][str(number)] = {"status": "opencode-failed", "branch": branch, "log": str(log_path), "time": int(time.time())}
        save_state(state_path, state)
        comment_issue(repo, number, f"OpenCode exited with code `{proc.returncode}`. No PR was created. Detailed log remains local on the bridge host.")
        return

    status = run(["git", "status", "--porcelain"], cwd=worktree).stdout.strip()
    if not status:
        state["processed"][str(number)] = {"status": "no-changes", "branch": branch, "log": str(log_path), "time": int(time.time())}
        save_state(state_path, state)
        comment_issue(repo, number, "OpenCode completed but produced no repository changes. No PR was created.")
        return

    diff_check = run(["git", "diff", "--check"], cwd=worktree, check=False)
    if diff_check.returncode != 0:
        state["processed"][str(number)] = {"status": "diff-check-failed", "branch": branch, "log": str(log_path), "time": int(time.time())}
        save_state(state_path, state)
        comment_issue(repo, number, "OpenCode produced changes, but `git diff --check` failed. Nothing was pushed.")
        return

    run(["git", "add", "-A"], cwd=worktree)
    staged = run(["git", "diff", "--cached", "--stat"], cwd=worktree).stdout.strip()
    run(["git", "commit", "-m", f"oc: implement issue #{number}"], cwd=worktree)
    run(["git", "push", "-u", "origin", branch], cwd=worktree)
    pr_body = f"Generated by the JoeOS ChatGPT ↔ OpenCode bridge for issue #{number}.\n\nCloses #{number}\n\n### Bridge verification\n- `git diff --check`: PASS\n- Detailed OpenCode log retained locally\n- Auto-merge: DISABLED\n\n### Changed files summary\n```\n{staged}\n```\n"
    pr = run(["gh", "pr", "create", "--repo", repo, "--base", "main", "--head", branch, "--title", title.removeprefix("[OC]").strip() or f"OpenCode issue #{number}", "--body", pr_body], cwd=worktree)
    pr_url = (pr.stdout or "").strip()
    state["processed"][str(number)] = {"status": "pr-created", "branch": branch, "pr": pr_url, "log": str(log_path), "time": int(time.time())}
    save_state(state_path, state)
    comment_issue(repo, number, f"OpenCode completed and created PR: {pr_url}\n\n`git diff --check` passed. The bridge never auto-merges.")

def bridge_once(root: Path, repo: str, state_path: Path, worktree_root: Path) -> None:
    ensure_repo(root, repo)
    state = load_state(state_path)
    processed = state.setdefault("processed", {})
    for issue in list_tasks(repo):
        number = str(issue["number"])
        if number in processed:
            continue
        try:
            process_task(root, repo, issue, state, state_path, worktree_root)
        except Exception as exc:
            state["processed"][number] = {"status": "bridge-error", "error": str(exc), "time": int(time.time())}
            save_state(state_path, state)
            try:
                comment_issue(repo, int(issue["number"]), f"Bridge execution failed before a PR could be created. Error: `{str(exc)[:1000]}`")
            except Exception:
                pass

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=os.getenv("BRIDGE_REPO", DEFAULT_REPO))
    parser.add_argument("--root", default=os.getenv("BRIDGE_ROOT", ""))
    parser.add_argument("--interval", type=int, default=int(os.getenv("BRIDGE_POLL_SECONDS", "60")))
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    script_root = Path(__file__).resolve().parent.parent
    root = Path(args.root).expanduser().resolve() if args.root else script_root
    key = repo_key(args.repo)
    state_path = Path(os.getenv("BRIDGE_STATE_FILE", f"~/.local/state/joeos-opencode-bridge/{key}/processed.json")).expanduser()
    worktree_root = Path(os.getenv("BRIDGE_WORKTREE_ROOT", f"~/.cache/joeos-opencode-bridge/{key}/worktrees")).expanduser()
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
                print(f"[bridge] {exc}", file=sys.stderr)
            if args.once:
                return 0
            time.sleep(max(args.interval, 30))

if __name__ == "__main__":
    raise SystemExit(main())
