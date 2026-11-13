"""Drive the helper over its stdin/stdout protocol the way the Swift app does.

    python smoke_test.py clip1.wav [clip2.wav ...]
"""
import json
import struct
import subprocess
import sys
import time
from pathlib import Path

import mlx.core as mx
import numpy as np
from parakeet_mlx.audio import load_audio

HERE = Path(__file__).resolve().parent


def send(proc, samples: np.ndarray):
    data = samples.astype("<f4").tobytes()
    start = time.perf_counter()
    proc.stdin.write(struct.pack("<I", len(data)) + data)
    proc.stdin.flush()
    reply = json.loads(proc.stdout.readline())
    reply["roundtrip_ms"] = round((time.perf_counter() - start) * 1000)
    return reply


def main():
    proc = subprocess.Popen(
        [sys.executable, str(HERE / "tidy_parrot_helper.py")], stdin=subprocess.PIPE, stdout=subprocess.PIPE
    )
    print("ready:", proc.stdout.readline().decode().strip())

    clips = [np.array(load_audio(Path(p), 16_000, mx.float32)) for p in sys.argv[1:]]
    for round_ in range(2):
        for path, samples in zip(sys.argv[1:], clips):
            print(f"round {round_ + 1}  {Path(path).name}  {len(samples) / 16_000:.1f}s:", send(proc, samples))

    print("empty clip:", send(proc, np.zeros(0, dtype=np.float32)))
    print("tiny clip:", send(proc, np.zeros(100, dtype=np.float32)))
    print("2s silence:", send(proc, np.zeros(32_000, dtype=np.float32)))

    proc.stdin.close()
    print("exit code after stdin closed:", proc.wait(timeout=10))


if __name__ == "__main__":
    main()
