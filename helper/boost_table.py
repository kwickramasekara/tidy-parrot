"""The vocabulary boost as a lookup table: for each booster state, one score bonus per token.

parakeet-mlx's `boost.tabulate` builds a row by stepping all 8192 tokens through the booster (~27 ms per state) and
throws the rows away after every clip. This builds the same rows far faster and keeps them.

From a state whose trie nodes can't continue a token's first character, the token behaves exactly as it would from
the empty state with the same word flag, except for two state-dependent terms: the state's potential (subtracted) and
the weight of words the state completes at a boundary (added). So a row is a vector precomputed once plus two
scalars, and only tokens whose first character continues one of the state's nodes are stepped exactly.

Relies on the state layout of parakeet-mlx 0.7.0's `boost.words` (frozenset of trie nodes, after-word flag), which is
why parakeet-mlx is pinned. tests/test_boost_table.py checks it against the stock builder.
"""
import unicodedata

import numpy as np
from parakeet_mlx import boost


def is_word_char(ch: str) -> bool:
    # boost.words()'s own test: letters, marks and numbers, excluding wide CJK.
    return unicodedata.category(ch)[0] in "LMN" and unicodedata.east_asian_width(ch) not in "WFH"


class BoostTable:
    def __init__(self, weights: dict[str, float], vocabulary: list[str]):
        self.chars = boost.words(weights)  # per character
        self.machine = boost.lift(self.chars, vocabulary)  # per token, what the decoder steps
        self.size = len(vocabulary)
        self.empty = {aw: (frozenset(), aw) for aw in (False, True)}
        texts = [token.replace("▁", " ") for token in vocabulary]
        first = [t[0] if t else "" for t in texts]
        self.by_first: dict[str, list[int]] = {}
        for i, ch in enumerate(first):
            self.by_first.setdefault(ch, []).append(i)
        # Every token's bonus and next state from each empty state, computed once.
        self.base, self.next_empty = {}, {}
        for aw, state in self.empty.items():
            steps = [boost.advance(self.machine, state, t) for t in range(self.size)]
            self.base[aw] = np.array([d for _, d in steps], dtype=np.float32)
            self.next_empty[aw] = [s for s, _ in steps]
        word_first = np.array([bool(c) and is_word_char(c) for c in first])
        # A word the state has completed is paid out when the token starts at a word boundary.
        self.boundary = {False: np.ones(self.size, dtype=bool), True: ~word_first}
        self.rows: dict[tuple, np.ndarray] = {}

    @property
    def start(self):
        return self.machine.start

    def advance(self, state, token: int):
        return boost.advance(self.machine, state, token)[0]

    def _continuing(self, state) -> list[int]:
        """Tokens whose first character extends one of the state's trie nodes; only these need exact stepping."""
        _, aw = state
        out: list[int] = []
        for ch, tokens in self.by_first.items():
            if not ch or self.chars.step(state, ch)[0][0] != self.chars.step(self.empty[aw], ch)[0][0]:
                out.extend(tokens)
        return out

    def row(self, state) -> np.ndarray:
        r = self.rows.get(state)
        if r is None:
            nodes, aw = state
            r = self.base[aw] - self.chars.potential(state) + self.chars.at_end(state) * self.boundary[aw]
            if nodes:
                r = r.copy()
                for t in self._continuing(state):
                    r[t] = boost.advance(self.machine, state, t)[1]
            self.rows[state] = r
        return r

    def _next_states(self, state) -> set:
        nodes, aw = state
        out = set(self.next_empty[aw])  # tokens that drop the state's nodes land where the empty state sends them
        if nodes:
            out.update(boost.advance(self.machine, state, t)[0] for t in self._continuing(state))
        return out

    def build_all(self) -> int:
        """Every state reachable from the start, so no dictation ever has to compute a row. Returns the count."""
        todo, seen = [self.start], {self.start}
        while todo:
            state = todo.pop()
            self.row(state)
            for nxt in self._next_states(state):
                if nxt not in seen:
                    seen.add(nxt)
                    todo.append(nxt)
        return len(seen)
