"""Protocol tests that run without the model:  cd helper && .venv/bin/python -m unittest discover -s tests -t ."""
import io
import json
import struct
import unittest

import numpy as np

from wire_protocol import read_payload, serve, write_reply


def frame(samples) -> bytes:
    data = np.asarray(samples, dtype="<f4").tobytes()
    return struct.pack("<I", len(data)) + data


def run_serve(stdin_bytes: bytes, transcribe, vocabulary=None):
    out, logs = io.StringIO(), []
    serve(io.BytesIO(stdin_bytes), out, transcribe, logs.append, vocabulary)
    return [json.loads(line) for line in out.getvalue().splitlines()], logs


class ReadPayloadTests(unittest.TestCase):
    def test_returns_exactly_the_framed_bytes(self):
        stream = io.BytesIO(frame([0.5, -1.0]) + frame([0.25]))
        self.assertEqual(read_payload(stream), np.array([0.5, -1.0], dtype="<f4").tobytes())
        self.assertEqual(read_payload(stream), np.array([0.25], dtype="<f4").tobytes())

    def test_empty_clip_is_empty_bytes_not_eof(self):
        self.assertEqual(read_payload(io.BytesIO(frame([]))), b"")

    def test_eof_before_header(self):
        self.assertIsNone(read_payload(io.BytesIO(b"")))

    def test_truncated_header_or_payload_is_eof(self):
        self.assertIsNone(read_payload(io.BytesIO(b"\x08\x00")))
        self.assertIsNone(read_payload(io.BytesIO(frame([1.0, 2.0])[:-1])))


class WriteReplyTests(unittest.TestCase):
    def test_one_json_object_per_line(self):
        out = io.StringIO()
        write_reply(out, {"text": 'say "hi"\nthere', "ms": 3})
        self.assertEqual(out.getvalue().count("\n"), 1)
        self.assertEqual(json.loads(out.getvalue()), {"text": 'say "hi"\nthere', "ms": 3})


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

    def test_malformed_payload_gets_an_error_and_serving_continues(self):
        bad = struct.pack("<I", 3) + b"abc"  # not a whole number of float32s
        replies, _ = run_serve(bad + frame([0.0, 0.0]), lambda s: f"{s.size} samples")
        self.assertIn("error", replies[0])
        self.assertEqual(replies[1]["text"], "2 samples")

    def test_transcripts_carry_the_vocabulary_status_when_given(self):
        statuses = iter([{"terms": 0, "loaded_at": None, "error": None}, {"terms": 3, "loaded_at": 1.5, "error": None}])
        replies, _ = run_serve(frame([0.0]) + frame([0.0]), lambda s: "ok", lambda: next(statuses))
        self.assertEqual([r["vocabulary"]["terms"] for r in replies], [0, 3])

    def test_no_vocabulary_field_without_a_vocabulary(self):
        replies, _ = run_serve(frame([0.0]), lambda s: "ok")
        self.assertNotIn("vocabulary", replies[0])

    def test_error_replies_stay_bare(self):
        def boom(samples):
            raise RuntimeError("boom")

        replies, _ = run_serve(frame([0.0]), boom, lambda: {"terms": 1, "loaded_at": 1.0, "error": None})
        self.assertEqual(replies, [{"error": "boom"}])

    def test_exits_cleanly_when_stdin_closes(self):
        replies, logs = run_serve(b"", lambda s: "unused")
        self.assertEqual(replies, [])
        self.assertEqual(logs[-1], "stdin closed, exiting")


if __name__ == "__main__":
    unittest.main()
