#!/usr/bin/env bash
# One-time setup: Python venv for the helper, plus the model files (~806 MB) in helper/model.
set -euo pipefail
cd "$(dirname "$0")/../helper"

# The revision vendor/fluid_speech_mlx.py was taken from; bump both together.
MODEL_REVISION=aeb1d4e43487586b15d86c0a1dd4511e1cf6b7a0

python3 -m venv .venv
.venv/bin/pip install --quiet --upgrade pip
.venv/bin/pip install --quiet -r requirements.txt

HF_HUB_DISABLE_TELEMETRY=1 .venv/bin/hf download FluidVoice-Labs/fluid-speech-pro-mlx \
  config.json model.8bit.safetensors clean-mode.safetensors \
  --revision "$MODEL_REVISION" --local-dir model

echo "Helper ready. Next: make build"
