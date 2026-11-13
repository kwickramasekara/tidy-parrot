"""Tidy Parrot transcription helper: keeps Fluid Speech Pro (MLX) loaded and transcribes clips sent over stdin.

The Swift app is the only client; the protocol is in wire_protocol.py. Logs go to stderr, which the app appends to
~/Library/Logs/TidyParrot.log, so stdout stays a clean JSON-lines channel.

Test without the app:  python tidy_parrot_helper.py --file audio.wav
"""
import sys

# Before any other import: anything a library prints goes to the log instead of corrupting the protocol channel.
PROTOCOL_OUT = sys.stdout
sys.stdout = sys.stderr

import argparse  # noqa: E402
import time  # noqa: E402
from pathlib import Path  # noqa: E402

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "vendor"))

import mlx.core as mx  # noqa: E402
import numpy as np  # noqa: E402
from fluid_speech_mlx import load, log_mel  # noqa: E402

from wire_protocol import SAMPLE_RATE, serve, write_reply  # noqa: E402

# Pinned local copy from scripts/setup.sh, matching the revision vendor/fluid_speech_mlx.py came from.
# No network at runtime.
MODEL_DIR = HERE / "model"


def log(msg: str) -> None:
    print(f"[helper] {msg}", file=sys.stderr, flush=True)


def reply(obj: dict) -> None:
    write_reply(PROTOCOL_OUT, obj)


def transcribe(model, samples: np.ndarray) -> str:
    # Same path as model.transcribe() but from memory, so no temp file or ffmpeg per clip.
    if samples.size < model.preprocessor_config.hop_length:
        return ""
    mel = log_mel(mx.array(samples, dtype=mx.float32), model.preprocessor_config)
    return model.generate(mel)[0].text.strip()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--verbatim", action="store_true", help="keep fillers and repeated words (clean mode off)")
    parser.add_argument("--file", help="transcribe this file and exit, for testing")
    args = parser.parse_args()
    clean_mode = not args.verbatim

    if not MODEL_DIR.is_dir():
        reply({"error": f"model not found at {MODEL_DIR}; run make setup"})
        sys.exit(1)

    start = time.perf_counter()
    model = load(str(MODEL_DIR), bits=8, clean_mode=clean_mode)
    # Warm up so the first real clip doesn't pay for kernel compilation.
    transcribe(model, np.zeros(SAMPLE_RATE, dtype=np.float32))
    load_ms = round((time.perf_counter() - start) * 1000)
    log(f"model loaded in {load_ms} ms (clean_mode={clean_mode})")

    if args.file:
        start = time.perf_counter()
        text = model.transcribe(args.file).text.strip()
        reply({"text": text, "ms": round((time.perf_counter() - start) * 1000)})
        return

    reply({"ready": True, "load_ms": load_ms, "clean_mode": clean_mode})
    serve(sys.stdin.buffer, PROTOCOL_OUT, lambda samples: transcribe(model, samples), log)


if __name__ == "__main__":
    main()
