# JoeOS ChatGPT ↔ OpenCode Bridge

This repository uses GitHub as the durable control plane between ChatGPT and the user's local OpenCode installation.

```text
ChatGPT → trusted [OC] GitHub issue → VPS bridge runner → local OpenCode
        ← issue/PR status          ← branch + PR
```

OpenCode executes locally, so its existing provider authentication and local model configuration remain on the VPS. The bridge does not expose a remote shell and never auto-merges.

## Accepted task format

A task runs only when all of these are true:

1. issue author is in `BRIDGE_TRUSTED_AUTHORS` (default `jmw7629`);
2. title starts with `[OC]`;
3. issue body contains `<!-- joeos-opencode-bridge:v1 -->`.

The runner ignores issue comments. A revision should be a new `[OC]` issue.

## Per-task behavior

The runner verifies a clean control checkout, fetches `origin/main`, creates an isolated worktree and `oc/issue-...` branch, calls `opencode run`, stores the detailed execution log locally, requires `git diff --check`, pushes the branch, opens a PR to `main`, and comments the PR URL on the source issue.

Nothing is merged automatically.

## VPS activation

Use the same non-root user account that already runs OpenCode.

The bridge must use a **non-Snap OpenCode binary**. The systemd service intentionally keeps `NoNewPrivileges=true`; Snap's `snap-confine` requires Linux file capabilities that conflict with that hardened service context. Do not remove the bridge hardening just to make the Snap package run.

If `command -v opencode` begins with `/snap/`, install the official OpenCode build first:

```bash
curl -fsSL https://opencode.ai/install | bash
exec "$SHELL" -l
command -v opencode
opencode --version
opencode auth list
```

`command -v opencode` must not begin with `/snap/` before bridge installation.

Then activate the bridge:

```bash
cd /path/to/StickDeath-Infinity-
git checkout main
git pull --ff-only

git --version
gh --version
python3 --version
opencode --version

gh auth status
opencode auth list
opencode models

chmod +x bridge/install.sh bridge/uninstall.sh
./bridge/install.sh
```

If GitHub CLI is not authenticated, run `gh auth login`. If OpenCode has no provider, open OpenCode and use `/connect` first.

Check the service with:

```bash
systemctl --user status stickdeath-opencode-bridge
journalctl --user -u stickdeath-opencode-bridge -f
```

The default poll interval is 60 seconds.

## Configuration

The installer creates:

`~/.config/joeos-opencode-bridge/stickdeath.env`

On every install/reinstall, `OPENCODE_BIN` is refreshed to the currently selected non-Snap `opencode` binary. This avoids leaving the service pinned to an obsolete `/snap/bin/opencode` path after migration.

By default no model is forced. OpenCode uses its existing local configuration. To pin a model, first obtain the exact ID from `opencode models`, then set `OPENCODE_MODEL=provider/model-id` in that environment file.

An already-running loopback-only OpenCode server can optionally be reused by setting `OPENCODE_ATTACH_URL=http://127.0.0.1:4096`.

## Security boundaries

- Never run the bridge as root.
- Keep `NoNewPrivileges=true` in the systemd service.
- Only allow explicitly trusted issue authors.
- No comment-triggered execution.
- No direct pushes to `main` from OpenCode.
- No automatic PR merges.
- No raw shell endpoint is exposed to ChatGPT.
- OpenCode OAuth/provider credentials stay on the VPS.
- Detailed model logs stay local with restrictive file permissions.
- Reference SWFs, original audio, extracted artwork, and other corpus assets must remain outside this public repository.

The repository should be made private before sensitive design material or corpus metadata is added.

## ChatGPT workflow

Once the VPS service is active, ChatGPT can create a structured `[OC]` issue, inspect the resulting PR and test evidence directly through GitHub, and issue a follow-up task when changes are required. The repository owner retains merge authority.
