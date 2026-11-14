"""BoostTable must give exactly the rows parakeet-mlx's own tabulate() gives, for every state the decoder can reach.

Uses a small made-up token list, so it needs no model:  cd helper && .venv/bin/python -m unittest discover -s tests -t .
"""
import string
import unittest

import numpy as np
from parakeet_mlx import boost

from boost_table import BoostTable

TERMS = {"React": 6.0, "React Native": 6.0, "Next.js": 6.0, "PostHog": 6.0, "ast-grep": 6.0, "Fallow": 6.0,
         "i18next": 6.0, "C#": 6.0}
# Word starts ("▁…"), word pieces, and every single character, like a real BPE vocabulary.
PIECES = ["▁React", "▁Re", "act", "▁Native", "▁Next", ".", "js", "▁Post", "Hog", "▁post", "hog", "▁ast", "-", "grep",
          "▁Fall", "ow", "▁fallow", "▁i", "18", "next", "▁the", "▁quick", "ly", "▁C", "#", "▁", "'s", ",", "?"]
VOCABULARY = list(dict.fromkeys(PIECES + [f"▁{c}" for c in string.ascii_letters] + list(string.printable.strip())))


class BoostTableTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.table = BoostTable(TERMS, VOCABULARY)
        cls.states = cls.table.build_all()
        # staticmethod: the lru_cache wrapper would otherwise bind like a method.
        cls.stock = staticmethod(boost.tabulate(boost.lift(boost.words(TERMS), VOCABULARY), len(VOCABULARY)))

    def test_every_reachable_state_matches_the_stock_builder(self):
        self.assertGreater(self.states, 20)
        self.assertEqual(len(self.table.rows), self.states)
        for state, row in self.table.rows.items():
            with self.subTest(state=state):
                np.testing.assert_allclose(row, np.array(self.stock(state)), rtol=0, atol=1e-5)

    def test_build_all_covers_every_state_a_token_sequence_can_reach(self):
        state = self.table.start
        for piece in ["▁React", "▁Native", "▁Next", ".", "js", "▁Post", "Hog", "▁ast", "-", "grep", "▁C", "#"]:
            state = self.table.advance(state, VOCABULARY.index(piece))
            self.assertIn(state, self.table.rows)

    def test_continuing_a_term_scores_higher_than_leaving_it(self):
        state = self.table.advance(self.table.start, VOCABULARY.index("▁Post"))
        row = self.table.row(state)
        self.assertGreater(row[VOCABULARY.index("Hog")], row[VOCABULARY.index("hog")])

    def test_no_terms_means_no_bonus(self):
        table = BoostTable({}, VOCABULARY)
        self.assertEqual(table.build_all(), 2)  # the start state and the after-a-word state
        for row in table.rows.values():
            self.assertFalse(row.any())


if __name__ == "__main__":
    unittest.main()
