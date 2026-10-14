#!/bin/zsh
# StickDeath Infinity — Mac clean-up review (owner-run, archive-not-delete).
#
# Purpose: find StickDeath build leftovers, old clones and stale artifacts on this Mac,
# show them with sizes, and (only with --archive) MOVE them into a dated archive folder
# in your home directory. Nothing is ever deleted by this script; you empty the archive
# yourself once you are sure. The script never touches:
#   • the clone you pass with --keep (default: the directory you run it from if it is a
#     StickDeath checkout),
#   • ReferenceCorpus / sd-infinity-preview folders (private research and design
#     reference material; see AGENTS.md and docs/WEBSITE_HOSTING.md),
#   • anything outside your home directory,
#   • Xcode itself, simulators runtimes, or non-StickDeath projects.
#
# Usage:
#   zsh scripts/owner/mac_stickdeath_cleanup.sh                 # dry run: list candidates and sizes
#   zsh scripts/owner/mac_stickdeath_cleanup.sh --keep ~/Dev/StickDeath-Infinity-
#   zsh scripts/owner/mac_stickdeath_cleanup.sh --archive       # move candidates to ~/StickDeath-Archive-YYYYMMDD
#
# Candidate classes (each is labelled in the report):
#   derived    ~/Library/Developer/Xcode/DerivedData/StickDeathInfinity-*  (rebuilt by Xcode on demand)
#   archives   ~/Library/Developer/Xcode/Archives/**/StickDeath*.xcarchive (keep any you shipped to TestFlight)
#   results    *.xcresult bundles whose path contains StickDeath (test evidence already in CI artifacts)
#   clones     other git checkouts whose origin is jmw7629/StickDeath-Infinity- (not the --keep one)
#   downloads  ~/Downloads and ~/Desktop items named *StickDeath*, *stickdeath*, sdi-android-debug*, native-studio-*
#   tmp        $TMPDIR/sdi-* and ~/tmp/sdi-* scratch folders
set -euo pipefail
ARCHIVE=0; KEEP=""
while [ $# -gt 0 ]; do case "$1" in --archive) ARCHIVE=1;; --keep) KEEP="$2"; shift;; -h|--help) sed -n '2,30p' "$0"; exit 0;; *) echo "unknown option $1"; exit 2;; esac; shift; done
if [ -z "$KEEP" ] && git -C "$PWD" rev-parse --show-toplevel >/dev/null 2>&1; then KEEP="$(git -C "$PWD" rev-parse --show-toplevel)"; fi
KEEP="${KEEP:A}"
HOME_DIR="${HOME:A}"
STAMP="$(date +%Y%m%d)"; DEST="$HOME_DIR/StickDeath-Archive-$STAMP"
typeset -a CANDS; typeset -a KINDS
add() { local kind="$1" p="$2"; p="${p:A}"; [ -e "$p" ] || return 0
  case "$p" in "$HOME_DIR"/*) ;; *) return 0;; esac
  [ -n "$KEEP" ] && case "$p" in "$KEEP"|"$KEEP"/*) return 0;; esac
  case "$p" in *ReferenceCorpus*|*sd-infinity-preview*|*StickDeath-Archive-*) return 0;; esac
  for e in "${CANDS[@]:-}"; do [ "$e" = "$p" ] && return 0; done
  CANDS+=("$p"); KINDS+=("$kind"); }
setopt NULL_GLOB
for d in "$HOME_DIR"/Library/Developer/Xcode/DerivedData/StickDeathInfinity-*; do add derived "$d"; done
for d in "$HOME_DIR"/Library/Developer/Xcode/Archives/*/StickDeath*.xcarchive; do add archives "$d"; done
while IFS= read -r d; do add results "$d"; done < <(find "$HOME_DIR" -maxdepth 6 -type d -name '*.xcresult' -ipath '*stickdeath*' -not -path '*/Library/Mobile Documents/*' 2>/dev/null)
while IFS= read -r g; do repo="${g%/.git}"; url="$(git -C "$repo" config --get remote.origin.url 2>/dev/null || true)"; case "$url" in *jmw7629/StickDeath-Infinity-*) add clones "$repo";; esac; done < <(find "$HOME_DIR" -maxdepth 5 -type d -name .git -not -path '*/Library/*' 2>/dev/null)
for base in "$HOME_DIR/Downloads" "$HOME_DIR/Desktop"; do for p in "$base"/*StickDeath* "$base"/*stickdeath* "$base"/sdi-android-debug* "$base"/native-studio-* "$base"/native-auth-* "$base"/native-shard-receipt-*; do add downloads "$p"; done; done
for p in "${TMPDIR:-/tmp}"/sdi-* "$HOME_DIR"/tmp/sdi-*; do add tmp "$p"; done
if [ ${#CANDS[@]} -eq 0 ]; then echo "No StickDeath clean-up candidates found under $HOME_DIR (keeping: ${KEEP:-none})."; exit 0; fi
echo "StickDeath clean-up review — $(date)  (keeping: ${KEEP:-none})"; echo
total=0
for i in {1..${#CANDS[@]}}; do p="${CANDS[$i]}"; k="${KINDS[$i]}"; kb=$(du -sk "$p" 2>/dev/null | cut -f1); total=$((total + kb)); printf '%-10s %8.1f MB  %s\n' "$k" "$((kb))e-3" "$p"; done
printf '\nTotal: %.1f GB in %d items\n' "$((total))e-6" ${#CANDS[@]}
if [ $ARCHIVE -eq 0 ]; then echo; echo "Dry run. Re-run with --archive to MOVE these into $DEST (nothing is deleted)."; exit 0; fi
mkdir -p "$DEST"; echo; echo "Archiving into $DEST"
for i in {1..${#CANDS[@]}}; do p="${CANDS[$i]}"; rel="${p#$HOME_DIR/}"; mkdir -p "$DEST/$(dirname "$rel")"; mv "$p" "$DEST/$rel" && echo "moved  $rel"; done
echo; echo "Done. Review $DEST; empty it yourself when you are sure (Finder → Move to Trash → Empty)."
