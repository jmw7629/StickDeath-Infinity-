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

OPENCODE_BIN_PATH="$(command -v opencode)"
if [[ "${OPENCODE_BIN_PATH}" == /snap/* ]]; then
  cat >&2 <<'EOF'
OpenCode is currently resolving to a Snap binary.
The bridge intentionally runs with systemd NoNewPrivileges=true, while snap-confine
requires Linux file capabilities that are unavailable in that hardened context.

Do not weaken the bridge service. Install the official non-Snap OpenCode build:

  curl -fsSL https://opencode.ai/install | bash

Then start a fresh login shell and verify:

  command -v opencode
  opencode --version
  opencode auth list

`command -v opencode` must NOT begin with /snap/ before rerunning bridge/install.sh.
EOF
  exit 1
fi

echo "[1/7] Checking GitHub CLI authentication..."
if ! gh auth status >/dev/null 2>&1; then
  echo "GitHub CLI is not authenticated. Run: gh auth login" >&2
  exit 1
fi

echo "[2/7] Configuring Git to use GitHub CLI credentials..."
gh auth setup-git

echo "[3/7] Checking OpenCode authentication..."
if ! "${OPENCODE_BIN_PATH}" auth list; then
  echo "OpenCode authentication is not ready. Open OpenCode and use /connect." >&2
  exit 1
fi

echo "[4/7] Checking OpenCode automation flags..."
OC_HELP="$("${OPENCODE_BIN_PATH}" run --help 2>&1 || true)"
for flag in --dir --auto --format; do
  if ! grep -q -- "${flag}" <<<"${OC_HELP}"; then
    echo "Your OpenCode build does not expose required flag ${flag}." >&2
    echo "Upgrade OpenCode before installing the bridge." >&2
    exit 1
  fi
done

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
OPENCODE_BIN=${OPENCODE_BIN_PATH}
# Optional: pin exact values returned by 'opencode models' / your config.
# OPENCODE_MODEL=provider/model-id
# OPENCODE_AGENT=build
# Optional local-only OpenCode server attachment.
# OPENCODE_ATTACH_URL=http://127.0.0.1:4096
EOF
  chmod 600 "${ENV_FILE}"
elif grep -q '^OPENCODE_BIN=' "${ENV_FILE}"; then
  sed -i "s|^OPENCODE_BIN=.*|OPENCODE_BIN=${OPENCODE_BIN_PATH}|" "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"
else
  printf '\nOPENCODE_BIN=%s\n' "${OPENCODE_BIN_PATH}" >> "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"
fi

echo "[5/7] Checking Git commit identity..."
if [[ -z "$(git -C "${ROOT}" config user.name 2>/dev/null || true)" ]]; then
  git -C "${ROOT}" config user.name "JoeOS OpenCode Bridge"
fi
if [[ -z "$(git -C "${ROOT}" config user.email 2>/dev/null || true)" ]]; then
  git -C "${ROOT}" config user.email "jmw7629@users.noreply.github.com"
fi

echo "[6/7] Writing and enabling user service..."
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
systemctl --user restart stickdeath-opencode-bridge.service

echo "[7/7] Bridge status..."
systemctl --user --no-pager --full status stickdeath-opencode-bridge.service || true

echo
echo "Bridge installed."
echo "OpenCode binary: ${OPENCODE_BIN_PATH}"
echo "Logs: journalctl --user -u stickdeath-opencode-bridge -f"
echo "Config: ${ENV_FILE}"
echo "The bridge never auto-merges and accepts only trusted [OC] issues with the v1 marker."
