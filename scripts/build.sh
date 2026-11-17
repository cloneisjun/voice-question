#!/bin/zsh
# Builds build/VoiceQuestion.app (release, signed ad hoc unless CODESIGN_IDENTITY is set).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release 2>&1 | grep -v "ld: warning" | tail -3
BIN="$(swift build -c release --show-bin-path)/VoiceQuestion"
[[ -x "$BIN" ]] || { echo "build failed: $BIN is missing" >&2; exit 1; }

APP="build/VoiceQuestion.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/VoiceQuestion"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# An ad-hoc signature changes with every build, so macOS asks for the microphone again after
# a rebuild. Set CODESIGN_IDENTITY to a real identity to keep the grant.
codesign --force --sign "${CODESIGN_IDENTITY:--}" --identifier com.cloneisjun.VoiceQuestion "$APP" 2>&1 | grep -v "replacing existing signature" || true
codesign --verify --strict "$APP"
echo "built $PWD/$APP ($("$APP/Contents/MacOS/VoiceQuestion" --version))"
