#!/bin/zsh
# Runs the unit tests.
set -euo pipefail
cd "$(dirname "$0")/.."

# With the Command Line Tools alone (no Xcode) the Swift Testing macro plugin is not always
# found, so point the compiler at it.
PLUGINS=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
if [[ -d "$PLUGINS" && ! -d /Applications/Xcode.app ]]; then
  swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@" 2>&1 | grep -v "ld: warning"
else
  swift test "$@" 2>&1 | grep -v "ld: warning"
fi
