#!/usr/bin/env bash
set -euo pipefail

SERVICE="${HOME}/.config/systemd/user/stickdeath-opencode-bridge.service"
systemctl --user disable --now stickdeath-opencode-bridge.service 2>/dev/null || true
rm -f "${SERVICE}"
systemctl --user daemon-reload

echo "Bridge service removed."
echo "Local state/logs preserved under ~/.local/state/joeos-opencode-bridge/"
echo "Local worktrees/cache preserved under ~/.cache/joeos-opencode-bridge/"
