"""Greedy decoding with the vocabulary boost. parakeet-mlx only applies a booster in beam search, which measured about
twice as slow, so this is its TDT greedy loop with the boost added.

Copied from parakeet-mlx 0.7.0's `ParakeetTDT.decode_greedy` (pinned in requirements.txt), minus the per-step entropy
"confidence" the app never reads. With no vocabulary it produces the stock loop's text word for word.
"""
import mlx.core as mx
import mlx.nn as nn
import numpy as np
from parakeet_mlx import tokenizer
from parakeet_mlx.alignment import AlignedToken, sentences_to_result, tokens_to_sentences
from parakeet_mlx.parakeet import DecodingConfig

from boost_table import BoostTable

SENTENCE = DecodingConfig().sentence


class BoostRows:
    """A table's rows as MLX arrays, converted on first use by the thread that transcribes. It's built on the
    vocabulary thread, which must create no MLX arrays: MLX streams belong to a thread, and using an array from another
    one fails with "There is no Stream(gpu, …) in current thread"."""

    def __init__(self, table: BoostTable):
        self.table = table
        self._rows: dict = {}

    def __call__(self, state) -> mx.array:
        row = self._rows.get(state)
        if row is None:
            # The blank token takes no bonus.
            row = self._rows[state] = mx.array(np.append(self.table.row(state), np.float32(0)))
        return row


def warm_up_boost(model) -> None:
    """Compiles the boosted step's kernels at startup; otherwise the first dictation after the vocabulary loads pays
    about 150 ms for it."""
    width = len(model.vocabulary) + 1
    mx.eval(nn.log_softmax(mx.zeros(width, dtype=mx.float32)) + mx.zeros(width, dtype=mx.float32))


def encode(model, mel: mx.array):
    """The encoder half of `FluidSpeechTDT.generate`: NeMo's layout has one padded frame, which the lengths exclude."""
    if mel.ndim == 2:
        mel = mel[None]
    lengths = None
    if mel.shape[1] > 1 and bool(mx.all(mel[:, -1, :] == 0)):
        lengths = mx.full((mel.shape[0],), mel.shape[1] - 1, dtype=mx.int64)
    features, lengths = model.encoder(mel, lengths)
    mx.eval(features, lengths)
    return features, int(lengths[0])


def decode_greedy(model, features: mx.array, length: int, rows: BoostRows | None = None) -> list[AlignedToken]:
    feature = features[0:1]
    vocab_size = len(model.vocabulary)
    blank = vocab_size
    last_token, hidden = None, None
    state = rows.table.start if rows is not None else None
    tokens: list[AlignedToken] = []
    step, new_symbols = 0, 0
    while step < length:
        decoder_out, (h, c) = model.decoder(mx.array([[last_token]]) if last_token is not None else None, hidden)
        decoder_out = decoder_out.astype(feature.dtype)
        joint = model.joint(feature[:, step : step + 1], decoder_out)[0, 0, 0]
        logits = joint[: vocab_size + 1]
        if rows is not None:
            # The bonus is in log-probability units; softmax ignores shifts, so this keeps the plain argmax otherwise.
            logits = nn.log_softmax(logits.astype(mx.float32)) + rows(state)
        token = int(mx.argmax(logits))
        decision = int(mx.argmax(joint[vocab_size + 1 :]))
        duration = model.durations[decision]
        if token != blank:
            tokens.append(
                AlignedToken(
                    token,
                    start=step * model.time_ratio,
                    duration=duration * model.time_ratio,
                    confidence=1.0,
                    text=tokenizer.decode([token], model.vocabulary),
                )
            )
            last_token, hidden = token, (h.astype(feature.dtype), c.astype(feature.dtype))
            if rows is not None:
                state = rows.table.advance(state, token)
        step += duration
        # The stock loop's guard against emitting forever without moving forward in time.
        new_symbols = 0 if duration else new_symbols + 1
        if not duration and model.max_symbols is not None and new_symbols >= model.max_symbols:
            step, new_symbols = step + 1, 0
    return tokens


def text(tokens: list[AlignedToken]) -> str:
    return sentences_to_result(tokens_to_sentences(tokens, SENTENCE)).text.strip()
