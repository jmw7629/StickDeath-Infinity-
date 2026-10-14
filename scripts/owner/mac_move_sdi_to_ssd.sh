#!/bin/zsh
# StickDeath Infinity — move the active clone to an external SSD (owner-run, verified copy).
#
# What it does:
#   1. Refuses to run while Xcode or a simulator is open, or when the SSD is not APFS
#      (exFAT/FAT lose file modes, symlinks and case rules that git and Xcode rely on).
#   2. Copies the clone with `ditto` (preserves metadata), then verifies: `git fsck`, the same
#      HEAD, the same `git status`, and an identical file count. The original is NEVER deleted:
#      it is renamed to <name>.moved-YYYYMMDD so the clean-up script can archive it later.
#   3. Prints the next steps (open the new path in Xcode; DerivedData rebuilds itself).
#
# Usage:
#   zsh scripts/owner/mac_move_sdi_to_ssd.sh /Volumes/<SSD name>/Dev          # dry run (checks + plan)
#   zsh scripts/owner/mac_move_sdi_to_ssd.sh /Volumes/<SSD name>/Dev --go     # perform the verified copy
# Run it from inside the clone you want to move. Nothing outside that clone is touched.
set -euo pipefail
DEST_PARENT="${1:-}"; GO=0; [ "${2:-}" = "--go" ] && GO=1
[ -n "$DEST_PARENT" ] || { sed -n '2,20p' "$0"; exit 2; }
SRC="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$SRC" ] || { echo "Run this from inside the StickDeath clone."; exit 2; }
NAME="$(basename "$SRC")"; DEST="$DEST_PARENT/$NAME"
echo "Source: $SRC"; echo "Target: $DEST"; echo
# --- checks ---------------------------------------------------------------------------------
fail=0
if pgrep -x Xcode >/dev/null || pgrep -x Simulator >/dev/null; then echo "✗ Quit Xcode and the Simulator first."; fail=1; else echo "✓ Xcode and Simulator are closed"; fi
VOL="$(df "$DEST_PARENT" 2>/dev/null | tail -1 | awk '{print $NF}')" || VOL=""
[ -d "$DEST_PARENT" ] || { echo "✗ $DEST_PARENT does not exist (plug in the SSD, create the folder)."; fail=1; }
if [ -n "$VOL" ]; then FS="$(diskutil info "$VOL" 2>/dev/null | awk -F': *' '/File System Personality/{print $2}')"; case "$FS" in *APFS*|*"Mac OS Extended"*) echo "✓ $VOL is $FS";; *) echo "✗ $VOL is '$FS'. Reformat the SSD as APFS (Disk Utility) before moving a git clone there."; fail=1;; esac; fi
[ -e "$DEST" ] && { echo "✗ $DEST already exists."; fail=1; }
NEED=$(du -sk "$SRC" | cut -f1); FREE=$(df -k "$DEST_PARENT" 2>/dev/null | tail -1 | awk '{print $4}'); [ -n "$FREE" ] && { [ "$FREE" -gt $((NEED * 2)) ] && echo "✓ Space: need $((NEED/1024)) MB, free $((FREE/1024)) MB" || { echo "✗ Not enough free space on the SSD (need about $((NEED*2/1024)) MB)."; fail=1; }; }
DIRTY="$(git -C "$SRC" status --porcelain | wc -l | tr -d ' ')"; echo "ℹ Uncommitted changes in the clone: $DIRTY (they are copied as-is; nothing is committed or discarded)"
WT="$(git -C "$SRC" worktree list | wc -l | tr -d ' ')"; [ "$WT" -gt 1 ] && echo "ℹ $((WT-1)) linked worktree(s) inside the clone move with it (paths are re-registered below)."
[ $fail -eq 0 ] || { echo; echo "Fix the ✗ items and run again."; exit 1; }
[ $GO -eq 1 ] || { echo; echo "Dry run only. Add --go to perform the verified copy."; exit 0; }
# --- copy ------------------------------------------------------------------------------------
echo; echo "Copying with ditto (this keeps permissions, symlinks and extended attributes)…"
ditto "$SRC" "$DEST"
echo "Verifying…"
git -C "$DEST" fsck --no-progress >/dev/null && echo "✓ git fsck clean at the new location"
[ "$(git -C "$SRC" rev-parse HEAD)" = "$(git -C "$DEST" rev-parse HEAD)" ] && echo "✓ same HEAD" || { echo "✗ HEAD differs; original left untouched at $SRC"; exit 1; }
[ "$(git -C "$SRC" status --porcelain | sort)" = "$(git -C "$DEST" status --porcelain | sort)" ] && echo "✓ same working-tree status" || { echo "✗ status differs; original left untouched at $SRC"; exit 1; }
A=$(find "$SRC" -type f | wc -l | tr -d ' '); B=$(find "$DEST" -type f | wc -l | tr -d ' '); [ "$A" = "$B" ] && echo "✓ same file count ($A)" || { echo "✗ file count differs ($A vs $B); original left untouched"; exit 1; }
git -C "$DEST" worktree repair >/dev/null 2>&1 && echo "✓ worktree paths repaired"
mv "$SRC" "$SRC.moved-$(date +%Y%m%d)"
echo; echo "Done. The active clone is now: $DEST"
echo "The old copy was renamed to $SRC.moved-$(date +%Y%m%d); archive it later with scripts/owner/mac_stickdeath_cleanup.sh."
echo "Next: open $DEST/StickDeathInfinity.xcodeproj in Xcode (DerivedData rebuilds on the first build), and cd there in Terminal."
