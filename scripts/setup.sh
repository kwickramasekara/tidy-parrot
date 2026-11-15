#!/usr/bin/env bash
# One-time setup: Python venv for the helper, plus the model files (~806 MB) in helper/model.
set -euo pipefail
cd "$(dirname "$0")/../helper"

# The revision vendor/fluid_speech_mlx.py was taken from; bump both together.
MODEL_REVISION=aeb1d4e43487586b15d86c0a1dd4511e1cf6b7a0

# The pinned packages need 3.10+, and macOS's own /usr/bin/python3 is 3.9, which pip rejects with a confusing error.
PYTHON="${PYTHON:-python3}"
require_python() {
  local python=$1 label=$2 fix=$3
  if ! "$python" -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null; then
    echo "$label is $("$python" --version 2>/dev/null || echo "missing"); Tidy Parrot needs Python 3.10 or later." >&2
    echo "$fix" >&2
    exit 1
  fi
}

require_python "$PYTHON" "$PYTHON" \
  "Install a newer Python (python.org or Homebrew), then run: PYTHON=/path/to/python3.12 make setup"
"$PYTHON" -m venv .venv
# venv keeps an existing environment's Python, so a venv left by an earlier run on an old Python stays broken.
require_python .venv/bin/python "helper/.venv" "Remove it with: rm -rf helper/.venv, then run make setup again"
.venv/bin/pip install --quiet --upgrade pip
.venv/bin/pip install --quiet -r requirements.txt

HF_HUB_DISABLE_TELEMETRY=1 .venv/bin/hf download FluidVoice-Labs/fluid-speech-pro-mlx \
  config.json model.8bit.safetensors clean-mode.safetensors \
  --revision "$MODEL_REVISION" --local-dir model

echo "Helper ready. Next: make build"
