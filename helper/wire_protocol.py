"""The stdin/stdout protocol between the Swift app and this helper. No model or MLX imports, so it's testable alone.

  stdout, once at start: {"ready": true, "load_ms": ..., "clean_mode": ...}   or {"error": "..."} then exit
  stdin, per clip:       4-byte little-endian length N, then N bytes of float32 mono PCM at 16 kHz
  stdout, per clip:      {"text": "...", "ms": ...}                           or {"error": "..."}

The Swift side lives in app/Sources/TidyParrotCore/Transcription/HelperProtocol.swift; change both together.
"""
import json
import struct
import time
from typing import BinaryIO, Callable, Optional, TextIO

import numpy as np

SAMPLE_RATE = 16_000
HEADER = struct.Struct("<I")

Transcribe = Callable[[np.ndarray], str]
Log = Callable[[str], None]


def read_exact(stream: BinaryIO, n: int) -> Optional[bytes]:
    """Returns None if the stream ends first."""
    buf = bytearray()
    while len(buf) < n:
        chunk = stream.read(n - len(buf))
        if not chunk:
            return None
        buf.extend(chunk)
    return bytes(buf)


def read_clip(stream: BinaryIO) -> Optional[np.ndarray]:
    """Next clip as float32 samples, or None when the app has closed stdin."""
    header = read_exact(stream, HEADER.size)
    if header is None:
        return None
    payload = read_exact(stream, HEADER.unpack(header)[0])
    if payload is None:
        return None
    return np.frombuffer(payload, dtype="<f4")


def write_reply(out: TextIO, obj: dict) -> None:
    out.write(json.dumps(obj) + "\n")
    out.flush()


def serve(stdin: BinaryIO, out: TextIO, transcribe: Transcribe, log: Log) -> None:
    """Answers clips one at a time until stdin closes (the app quit or crashed)."""
    while (samples := read_clip(stdin)) is not None:
        try:
            start = time.perf_counter()
            text = transcribe(samples)
            ms = round((time.perf_counter() - start) * 1000)
            log(f"{samples.size / SAMPLE_RATE:.1f}s audio -> {ms} ms")
            write_reply(out, {"text": text, "ms": ms})
        except Exception as e:  # keep serving; one bad clip shouldn't kill the helper
            log(f"error: {e!r}")
            write_reply(out, {"error": str(e)})
    log("stdin closed, exiting")
