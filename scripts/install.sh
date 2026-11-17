#!/bin/zsh
# Installs VoiceQuestion for the current user:
#   ~/Applications/VoiceQuestion.app, a login item (LaunchAgent) and the Claude Code hook.
#
#   --no-hooks        leave ~/.claude/settings.json alone
#   --settings FILE   also add the hook to another Claude Code settings file (repeatable)
#   --codex-hook      also add the experimental Codex hook to ~/.codex/hooks.json
#   --no-login-item   do not start at login (just open the app now)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${VQ_APP_DEST:-$HOME/Applications/VoiceQuestion.app}"
LABEL="com.cloneisjun.voicequestion"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

hooks=1
login_item=1
hook_arguments=()
while (( $# )); do
  case "$1" in
    --no-hooks) hooks=0 ;;
    --no-login-item) login_item=0 ;;
    --codex-hook) hook_arguments+=(--codex) ;;
    --settings) hook_arguments+=(--settings "$2"); shift ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
  shift
done

"$ROOT/scripts/build.sh"

# Stop the copy that is running, if any.
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
pkill -f "$DEST/Contents/MacOS/VoiceQuestion" 2>/dev/null || true
for _ in {1..20}; do
  launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1 || break
  sleep 0.25
done

mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
ditto "$ROOT/build/VoiceQuestion.app" "$DEST"
BIN="$DEST/Contents/MacOS/VoiceQuestion"
echo "installed $DEST"

if (( login_item )); then
  mkdir -p "$(dirname "$AGENT")"
  cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$BIN</string>
	</array>
	<key>AssociatedBundleIdentifiers</key>
	<string>com.cloneisjun.VoiceQuestion</string>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>ProcessType</key>
	<string>Interactive</string>
</dict>
</plist>
EOF
  launchctl bootstrap "gui/$UID" "$AGENT"
  echo "login item $AGENT"
else
  rm -f "$AGENT"
  open -g "$DEST"
fi

if (( hooks )); then
  # An explicit --settings replaces the default file, so name the default as well.
  if (( ${hook_arguments[(I)--settings]} )); then
    hook_arguments=(--settings "$HOME/.claude/settings.json" "${hook_arguments[@]}")
  fi
  "$BIN" hooks install "${hook_arguments[@]}"
fi

for _ in {1..20}; do
  "$BIN" status >/dev/null 2>&1 && break
  sleep 0.25
done

cat <<EOF

VoiceQuestion이 메뉴 막대에서 실행 중입니다 (파형 아이콘).
  1. 마이크 권한을 묻는 창이 뜨면 '허용'을 누르세요. (말이 끝난 것을 감지하는 데만 씁니다)
  2. 메뉴 막대 아이콘 → '테스트 질문 실행', 또는:  '$BIN' test
  3. 상태 점검:  '$BIN' doctor
끄기: 메뉴 막대 아이콘 → '일시 중지' / 제거: $ROOT/scripts/uninstall.sh
EOF
"$BIN" doctor || true
