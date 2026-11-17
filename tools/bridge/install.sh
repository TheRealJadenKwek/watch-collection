#!/bin/bash
# The Watch Collection bridge's LaunchAgent (docs/icloud-plan.md section 11 P5).
#
#   install.sh [options] [binary [argument ...]]   write it to ~/Library/LaunchAgents and load it into gui/<uid>
#   install.sh [--label <label>] remove            unload it and delete the plist
#
# Options, for a rehearsal (the defaults are the real bridge's):
#   --label <label>    its own label, plist and log (~/Library/Logs/<label without com.jaden.>.log)
#   --watch <folder>   the WatchPaths folder instead of the real hub's data folder
#
# The binary defaults to the installed app. A rehearsal points it at a debug build and adds that run's own arguments
# (for example -WCDataRoot <folder> -WCRole mac -WCHub <throwaway hub>), which go after -WCBridge 1. Installing again
# replaces the one already loaded.
set -euo pipefail

DEFAULT_LABEL="com.jaden.watch-collection-bridge"
LABEL="$DEFAULT_LABEL"
WATCH=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --label) LABEL="${2:?--label needs a value}"; shift 2 ;;
        --watch) WATCH="${2:?--watch needs a value}"; shift 2 ;;
        *) break ;;
    esac
done
HERE="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$HERE/$DEFAULT_LABEL.plist"
AGENTS="$HOME/Library/LaunchAgents"
TARGET="$AGENTS/$LABEL.plist"
LOG="$HOME/Library/Logs/${LABEL#com.jaden.}.log"
DOMAIN="gui/$(id -u)"
DEFAULT_BINARY="/Applications/Watch Collection.app/Contents/MacOS/Watch Collection"

unload() {
    # Not loaded is fine.
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
}

if [[ "${1:-}" == "remove" ]]; then
    unload
    rm -f "$TARGET"
    echo "Removed $LABEL."
    exit 0
fi

BINARY="${1:-$DEFAULT_BINARY}"
if [[ $# -gt 0 ]]; then shift; fi
if [[ ! -x "$BINARY" ]]; then
    echo "No executable at $BINARY" >&2
    exit 1
fi

mkdir -p "$AGENTS" "$(dirname "$LOG")"
STAGED="$(mktemp "${TMPDIR:-/tmp}/$LABEL.XXXXXX")"
trap 'rm -f "$STAGED"' EXIT
cp "$TEMPLATE" "$STAGED"
plutil -replace Label -string "$LABEL" "$STAGED"
if [[ -n "$WATCH" ]]; then
    plutil -replace WatchPaths -array "$STAGED"
    plutil -insert WatchPaths -string "$WATCH" -append "$STAGED"
fi
plutil -replace ProgramArguments -array "$STAGED"
for argument in "$BINARY" -WCBridge 1 "$@"; do
    plutil -insert ProgramArguments -string "$argument" -append "$STAGED"
done
plutil -replace StandardOutPath -string "$LOG" "$STAGED"
plutil -replace StandardErrorPath -string "$LOG" "$STAGED"
plutil -lint -s "$STAGED"

unload
cp "$STAGED" "$TARGET"
chmod 644 "$TARGET"
launchctl bootstrap "$DOMAIN" "$TARGET"
echo "Loaded $LABEL: $BINARY -WCBridge 1${*:+ $*}"
echo "Log: $LOG"
