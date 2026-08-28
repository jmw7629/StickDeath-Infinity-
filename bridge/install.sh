#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -eq 0 ]]; then
  echo "Do not install the bridge as root. Run it as your normal OpenCode user." >&2
  exit 1
fi

for cmd in git gh python3 opencode systemctl; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Missing required command: ${cmd}" >&2
    exit 1
  fi
done

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${ROOT}" ]]; then
  echo "Run this script from inside the StickDeath-Infinity repository." >&2
  exit 1
fi

REPO="${BRIDGE_REPO:-jmw7629/StickDeath-Infinity-}"
REMOTE="$(git -C "${ROOT}" remote get-url origin 2>/dev/null || true)"
if [[ "${REMOTE}" != *"jmw7629/StickDeath-Infinity-"* ]]; then
  echo "Unexpected origin: ${REMOTE}" >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "GitHub CLI is not authenticated. Run: gh auth login" >&2
  exit 1
fi

if ! opencode auth list; then
  echo "OpenCode authentication is not ready. Open OpenCode and use /connect." >&2
  exit 1
fi

CONFIG_DIR="${HOME}/.config/joeos-opencode-bridge"
ENV_FILE="${CONFIG_DIR}/stickdeath.env"
SERVICE_DIR="${HOME}/.config/systemd/user"
SERVICE_FILE="${SERVICE_DIR}/stickdeath-opencode-bridge.service"

mkdir -p "${CONFIG_DIR}" "${SERVICE_DIR}"
chmod 700 "${CONFIG_DIR}"

if [[ ! -f "${ENV_FILE}" ]]; then
  cat > "${ENV_FILE}" <<EOF
BRIDGE_REPO=${REPO}
BRIDGE_ROOT=${ROOT}
BRIDGE_TRUSTED_AUTHORS=jmw7629
BRIDGE_POLL_SECONDS=60
# Optional: pin exact values returned by 'opencode models' / your config.
# OPENCODE_MODEL=provider/model-id
# OPENCODE_AGENT=build
# Optional local-only OpenCode server attachment.
# OPENCODE_ATTACH_URL=http://127.0.0.1:4096
EOF
  chmod 600 "${ENV_FILE}"
fi

cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=JoeOS ChatGPT to OpenCode bridge for StickDeath Infinity
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${ROOT}
EnvironmentFile=-${ENV_FILE}
ExecStart=/usr/bin/env python3 ${ROOT}/bridge/runner.py
Restart=on-failure
RestartSec=10
NoNewPrivileges=true
UMask=0077

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now stickdeath-opencode-bridge.service
systemctl --user --no-pager --full status stickdeath-opencode-bridge.service || true

echo
echo "Bridge installed."
echo "Logs: journalctl --user -u stickdeath-opencode-bridge -f"
echo "Config: ${ENV_FILE}"
echo "The bridge never auto-merges and accepts only trusted [OC] issues with the v1 marker."
