"""Protocol tests that run without the model:  cd helper && .venv/bin/python -m unittest discover -s tests -t ."""
import io
import json
import struct
import unittest

import numpy as np

from wire_protocol import read_clip, serve


def frame(samples) -> bytes:
    data = np.asarray(samples, dtype="<f4").tobytes()
    return struct.pack("<I", len(data)) + data


def run_serve(stdin_bytes: bytes, transcribe):
    out, logs = io.StringIO(), []
    serve(io.BytesIO(stdin_bytes), out, transcribe, logs.append)
    return [json.loads(line) for line in out.getvalue().splitlines()], logs


class ReadClipTests(unittest.TestCase):
    def test_round_trips_samples(self):
        clip = read_clip(io.BytesIO(frame([0.5, -1.0, 0.25])))
        np.testing.assert_array_equal(clip, np.array([0.5, -1.0, 0.25], dtype=np.float32))

    def test_empty_clip_is_an_empty_array_not_eof(self):
        clip = read_clip(io.BytesIO(frame([])))
        self.assertIsNotNone(clip)
        self.assertEqual(clip.size, 0)

    def test_eof_before_header(self):
        self.assertIsNone(read_clip(io.BytesIO(b"")))

    def test_truncated_header_or_payload_is_eof(self):
        self.assertIsNone(read_clip(io.BytesIO(b"\x08\x00")))
        self.assertIsNone(read_clip(io.BytesIO(frame([1.0, 2.0])[:-1])))


class ServeTests(unittest.TestCase):
    def test_one_reply_per_clip_in_order(self):
        replies, _ = run_serve(frame([0.0] * 3) + frame([0.0] * 5), lambda s: f"{s.size} samples")
        self.assertEqual([r["text"] for r in replies], ["3 samples", "5 samples"])
        self.assertTrue(all(isinstance(r["ms"], int) for r in replies))

    def test_error_reply_keeps_serving(self):
        def flaky(samples):
            if samples.size == 1:
                raise RuntimeError("boom")
            return "ok"

        replies, logs = run_serve(frame([0.0]) + frame([0.0, 0.0]), flaky)
        self.assertEqual(replies, [{"error": "boom"}, {"text": "ok", "ms": replies[1]["ms"]}])
        self.assertTrue(any("boom" in line for line in logs))

    def test_exits_cleanly_when_stdin_closes(self):
        replies, logs = run_serve(b"", lambda s: "unused")
        self.assertEqual(replies, [])
        self.assertEqual(logs[-1], "stdin closed, exiting")


if __name__ == "__main__":
    unittest.main()
