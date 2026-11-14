"""Needs the model, so `make test` skips it (its name doesn't start with test_); `make integration` runs it.

decoding.py copies parakeet-mlx's greedy loop to add the boost. With no vocabulary it must still give the stock
decoder's text, so a future edit to the copy can't quietly change everyone's dictation.
"""
import os
import sys
import unittest
from pathlib import Path

HELPER = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HELPER / "vendor"))

import mlx.core as mx  # noqa: E402
import numpy as np  # noqa: E402
from fluid_speech_mlx import load, log_mel  # noqa: E402
from parakeet_mlx.audio import load_audio  # noqa: E402

import decoding  # noqa: E402
from wire_protocol import SAMPLE_RATE  # noqa: E402

WAV = os.environ.get("TP_INTEGRATION_WAV")


@unittest.skipUnless(WAV, "set TP_INTEGRATION_WAV, as make integration does")
class StockParityTests(unittest.TestCase):
    def test_no_vocabulary_matches_the_stock_decoder(self):
        model = load(str(HELPER / "model"), bits=8, clean_mode=True)
        samples = np.array(load_audio(Path(WAV), SAMPLE_RATE, mx.float32))
        mel = log_mel(mx.array(samples), model.preprocessor_config)
        stock = model.generate(mel)[0].text.strip()
        features, length = decoding.encode(model, mel)
        self.assertTrue(stock)
        self.assertEqual(decoding.text(decoding.decode_greedy(model, features, length)), stock)


if __name__ == "__main__":
    unittest.main()
