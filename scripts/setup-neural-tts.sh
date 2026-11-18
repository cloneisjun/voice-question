#!/bin/zsh
# Optional online voice runtime. Does not change your selected engine or start a microphone.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENV="$HOME/Library/Application Support/VoiceQuestion/tts-venv"
PYTHON="${VQ_PYTHON:-python3}"
if [[ ! -x "$VENV/bin/python3" ]]; then
  "$PYTHON" -m venv "$VENV"
fi
"$VENV/bin/python3" -m pip install -r "$ROOT/scripts/requirements-neural-tts.txt"
"$VENV/bin/python3" -c 'import edge_tts; print("edge-tts " + edge_tts.__version__)'
cat <<'EOF'

Online neural voices are installed. The selected engine has not changed.
Enable them in the menu: Question voice → Neural voice · Microsoft online
Or: vq tts use edge
This sends question text to Microsoft and needs an internet connection.
The third-party edge-tts client uses the Edge service; it is not an official Azure SDK.
To return to offline voices: vq tts use system
EOF
