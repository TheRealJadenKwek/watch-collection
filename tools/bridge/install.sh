#!/bin/bash
# The Watch Collection bridge's LaunchAgent (docs/icloud-plan.md section 11 P5).
#
#   install.sh [options] [binary [argument ...]]   write it to ~/Library/LaunchAgents and load it into gui/<uid>
#   install.sh [--label <label>] remove            unload it and delete the plist
#
# Options, for a rehearsal (the defaults are the real bridge's):
#   --label <label>    its own label, plist and log (~/Library/Logs/<label without com.jaden.>.log)
#   --watch <folder>   the WatchPaths folder instead of the real hub's data folder
#   --dry-run          check the binary and print the plist it would install; nothing is written or loaded
#
# The binary defaults to the installed app. A rehearsal points it at a debug build and adds that run's own arguments
# (for example -WCDataRoot <folder> -WCRole mac -WCHub <throwaway hub>), which go after -WCBridge 1. Installing again
# replaces the one already loaded.
#
# A binary without the bridge is refused: a build from before it ignores -WCBridge and would open its whole window
# from launchd every minute. The check looks for the marker Entry carries (ios/Mac/MacApp.swift) in the file, and
# never runs it. To roll back to such a build, run "install.sh remove" first (docs/icloud-plan.md section 9).
set -euo pipefail

MARKER="WCBridgeEntry-v1"
DEFAULT_LABEL="com.jaden.watch-collection-bridge"
LABEL="$DEFAULT_LABEL"
WATCH=""
DRY_RUN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --label) LABEL="${2:?--label needs a value}"; shift 2 ;;
        --watch) WATCH="${2:?--watch needs a value}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
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

# The marker in the binary, or for a Debug build in <binary>.debug.dylib beside it, where Xcode puts the app's code
# behind a small stub.
has_bridge() {
    grep -aqF "$MARKER" "$1" && return 0
    [[ -f "$1.debug.dylib" ]] && grep -aqF "$MARKER" "$1.debug.dylib"
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
if ! has_bridge "$BINARY"; then
    echo "Refused: $BINARY has no bridge ($MARKER is not in it). A build from before the bridge would open its" >&2
    echo "whole window from launchd. Install the new build first. Nothing was written or loaded." >&2
    exit 1
fi

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

if [[ "$DRY_RUN" == 1 ]]; then
    echo "Dry run: $BINARY has the bridge. Would write $TARGET and load it into $DOMAIN:"
    cat "$STAGED"
    echo "Nothing was written or loaded."
    exit 0
fi

mkdir -p "$AGENTS" "$(dirname "$LOG")"
unload
cp "$STAGED" "$TARGET"
chmod 644 "$TARGET"
launchctl bootstrap "$DOMAIN" "$TARGET"
echo "Loaded $LABEL: $BINARY -WCBridge 1${*:+ $*}"
echo "Log: $LOG"
