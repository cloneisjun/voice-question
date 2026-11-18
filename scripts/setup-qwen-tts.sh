#!/bin/zsh
# Download the optional local voice once. Does not select an engine or open a microphone.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VQ_DATA="$HOME/Library/Application Support/VoiceQuestion"
PYTHON="${VQ_PYTHON:-python3.11}"
[[ "$(uname -m)" == arm64 ]] || { echo "Qwen MLX requires Apple Silicon." >&2; exit 1; }
"$PYTHON" -c 'import sys; assert sys.version_info >= (3, 11), "Python 3.11+ required"'
if [[ ! -x "$VQ_DATA/qwen-venv/bin/python3" ]]; then
  "$PYTHON" -m venv "$VQ_DATA/qwen-venv"
fi
"$VQ_DATA/qwen-venv/bin/python3" -m pip install -r "$ROOT/scripts/requirements-qwen-tts.txt"
"$VQ_DATA/qwen-venv/bin/python3" - "$VQ_DATA/qwen-model" <<'PY'
import sys
from huggingface_hub import snapshot_download
snapshot_download("mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit",
                  local_dir=sys.argv[1], ignore_patterns=["*.md", ".gitattributes"])
print("Local Qwen model ready. Select it with: vq tts use qwen")
PY
