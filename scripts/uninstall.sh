#!/bin/zsh
# Removes VoiceQuestion: the login item, the hooks and the app.
# Settings and logs stay unless --purge is given.
#
#   --settings FILE   also remove the hook from another Claude Code settings file (repeatable)
#   --purge           also delete the settings, the logs and the microphone permission
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${VQ_APP_DEST:-$HOME/Applications/VoiceQuestion.app}"
LABEL="com.cloneisjun.voicequestion"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

purge=0
hook_arguments=(--settings "$HOME/.claude/settings.json" --codex)
while (( $# )); do
  case "$1" in
    --purge) purge=1 ;;
    --settings) hook_arguments+=(--settings "$2"); shift ;;
    -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
  shift
done

# Any copy of the binary can take the hooks out again.
for candidate in "$DEST/Contents/MacOS/VoiceQuestion" "$ROOT/build/VoiceQuestion.app/Contents/MacOS/VoiceQuestion"; do
  if [[ -x "$candidate" ]]; then
    "$candidate" hooks uninstall "${hook_arguments[@]}"
    break
  fi
done

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null
rm -f "$AGENT"
pkill -f "$DEST/Contents/MacOS/VoiceQuestion" 2>/dev/null
rm -rf "$DEST"
echo "removed $DEST"

if (( purge )); then
  rm -rf "$HOME/Library/Application Support/VoiceQuestion" "$HOME/Library/Logs/VoiceQuestion"
  tccutil reset Microphone com.cloneisjun.VoiceQuestion >/dev/null 2>&1
  echo "removed settings, logs and the microphone permission"
fi
