#!/bin/zsh
# Regenerates Resources/AppIcon.icns from docs/assets/logo.svg.
# Only needed after the logo changes; the .icns is checked in and build.sh just copies it.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift scripts/make-icon.swift docs/assets/logo.svg "$WORK/AppIcon.iconset"
iconutil --convert icns --output Resources/AppIcon.icns "$WORK/AppIcon.iconset"
echo "wrote $PWD/Resources/AppIcon.icns"
