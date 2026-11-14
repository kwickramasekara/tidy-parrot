"""Tidy Parrot transcription helper: keeps Fluid Speech Pro (MLX) loaded and transcribes clips sent over stdin.

The Swift app is the only client; the protocol is in wire_protocol.py. Logs go to stderr, which the app appends to
~/Library/Logs/TidyParrot.log, so stdout stays a clean JSON-lines channel.

Test without the app:  python tidy_parrot_helper.py --file audio.wav [--vocabulary vocabulary.txt]
"""
import sys

# Before any other import: anything a library prints goes to the log instead of corrupting the protocol channel.
PROTOCOL_OUT = sys.stdout
sys.stdout = sys.stderr

import argparse  # noqa: E402
import time  # noqa: E402
from dataclasses import dataclass  # noqa: E402
from pathlib import Path  # noqa: E402

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "vendor"))

import mlx.core as mx  # noqa: E402
import numpy as np  # noqa: E402
from fluid_speech_mlx import load, log_mel  # noqa: E402

import decoding  # noqa: E402
import snap  # noqa: E402
import vocabulary as vocab  # noqa: E402
from boost_table import BoostTable  # noqa: E402
from wire_protocol import SAMPLE_RATE, serve, write_reply  # noqa: E402

# Pinned local copy from scripts/setup.sh, matching the revision vendor/fluid_speech_mlx.py came from.
# No network at runtime.
MODEL_DIR = HERE / "model"
DEFAULT_VOCABULARY = HERE / "default_vocabulary.txt"
# Tuned on synthetic front-end dictation: higher boosted more terms but started rewriting ordinary words.
BOOST_WEIGHT = 6.0


def log(msg: str) -> None:
    print(f"[helper] {msg}", file=sys.stderr, flush=True)


def reply(obj: dict) -> None:
    write_reply(PROTOCOL_OUT, obj)


@dataclass(frozen=True)
class Built:
    """Everything one vocabulary needs at transcription time."""

    rows: decoding.BoostRows
    snap_table: snap.Table


def build(model, terms: list[str]) -> Built:
    start = time.perf_counter()
    table = BoostTable({term: BOOST_WEIGHT for term in terms}, model.vocabulary)
    states = table.build_all()
    log(f"boost table: {states} states in {round((time.perf_counter() - start) * 1000)} ms")
    return Built(rows=decoding.BoostRows(table), snap_table=snap.build(terms))


def transcribe(model, samples: np.ndarray, vocabulary: vocab.Vocabulary | None) -> str:
    if samples.size < model.preprocessor_config.hop_length:
        return ""
    active = vocabulary.active if vocabulary is not None else None  # one reference per clip: a rebuild can't change it
    built = active.built if active is not None else None
    # Same path as model.transcribe() but from memory, so no temp file or ffmpeg per clip.
    mel = log_mel(mx.array(samples, dtype=mx.float32), model.preprocessor_config)
    try:
        features, length = decoding.encode(model, mel)
        text = decoding.text(decoding.decode_greedy(model, features, length, built.rows if built is not None else None))
        return snap.snap(text, built.snap_table) if built is not None else text
    finally:
        # MLX keeps freed GPU buffers cached up to roughly the GPU working set, and each clip length needs new sizes,
        # so the idle helper grew by GBs over a session. Clearing per clip measured no slower.
        mx.clear_cache()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--verbatim", action="store_true", help="keep fillers and repeated words (clean mode off)")
    parser.add_argument("--vocabulary", type=Path, help="terms to favour and respell, one per line (the app passes it)")
    parser.add_argument("--file", help="transcribe this file and exit, for testing")
    args = parser.parse_args()
    clean_mode = not args.verbatim

    if not MODEL_DIR.is_dir():
        reply({"error": f"model not found at {MODEL_DIR}; run make setup"})
        sys.exit(1)

    # Before the model loads, so Edit Vocabulary finds the file as soon as the app starts.
    if args.vocabulary:
        try:
            if vocab.seed(args.vocabulary, DEFAULT_VOCABULARY):
                log("vocabulary created with the default terms")
        except OSError as e:  # without the file the vocabulary is just off; dictation must still start
            log(f"couldn't create the vocabulary file ({type(e).__name__})")

    start = time.perf_counter()
    model = load(str(MODEL_DIR), bits=8, clean_mode=clean_mode)
    # Warm up so the first real clip doesn't pay for kernel compilation.
    transcribe(model, np.zeros(SAMPLE_RATE, dtype=np.float32), None)
    if args.vocabulary:
        decoding.warm_up_boost(model)
    load_ms = round((time.perf_counter() - start) * 1000)
    log(f"model loaded in {load_ms} ms (clean_mode={clean_mode})")

    vocabulary = vocab.Vocabulary(args.vocabulary, lambda terms: build(model, terms), log) if args.vocabulary else None

    if args.file:
        from parakeet_mlx.audio import load_audio

        if vocabulary is not None:
            vocabulary.reload()
        samples = np.array(load_audio(Path(args.file), SAMPLE_RATE, mx.float32))
        start = time.perf_counter()
        text = transcribe(model, samples, vocabulary)
        reply({"text": text, "ms": round((time.perf_counter() - start) * 1000)})
        return

    ready = {"ready": True, "load_ms": load_ms, "clean_mode": clean_mode}
    if vocabulary is not None:
        # Built in the background: dictation works meanwhile, without the vocabulary for the first second or two.
        vocab.start(vocabulary, log)
        ready["vocabulary"] = vocabulary.status()
    reply(ready)
    serve(sys.stdin.buffer, PROTOCOL_OUT, lambda samples: transcribe(model, samples, vocabulary), log,
          vocabulary.status if vocabulary is not None else None)


if __name__ == "__main__":
    main()
