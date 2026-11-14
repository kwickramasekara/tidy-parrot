"""Snap tests:  cd helper && .venv/bin/python -m unittest discover -s tests -t ."""
import unittest

from snap import build, key, snap

TERMS = ["Pencilwrench", "Next.js", "useEffect", "Jira", "React", "React Native", "PostHog", "date-fns", "Fallow",
         "Claude", "ast-grep", "Datadog", "C#"]
COMMON = frozenset({"react", "fallow", "the"})


def fix(text):
    return snap(text, build(TERMS, common=COMMON))


class SnapTests(unittest.TestCase):
    def test_respells_split_and_miscased_terms(self):
        cases = [
            ("Open a ticket in JIRA under the Pencil Wrench project.",
             "Open a ticket in Jira under the Pencilwrench project."),
            ("The next JS app router.", "The Next.js app router."),
            ("The use effect runs twice.", "The useEffect runs twice."),
            ("Format dates with date FNS.", "Format dates with date-fns."),
            ("Check the data dog dashboard.", "Check the Datadog dashboard."),
            ("Ask claude to run AST grep.", "Ask Claude to run ast-grep."),
            ("Run ast grep, then Post-Hog.", "Run ast-grep, then PostHog."),
        ]
        for heard, expected in cases:
            with self.subTest(heard):
                self.assertEqual(fix(heard), expected)

    def test_leaves_traps_alone(self):
        # Common words stay as said, and sound-alikes reduce to different letters.
        for text in ["We need to react quickly.", "Leave the field fallow for a year.",
                     "We did a post hoc analysis.", "The cloud bill went up.", "Feed the dog, then check the data."]:
            with self.subTest(text):
                self.assertEqual(fix(text), text)

    def test_only_joins_words_separated_by_a_space_or_hyphen(self):
        self.assertEqual(fix("Pencil, wrench."), "Pencil, wrench.")
        self.assertEqual(fix("Check the data. Dog walking next."), "Check the data. Dog walking next.")

    def test_longest_match_wins(self):
        # "React" is common here, but "React Native" isn't, so the longer span is still snapped.
        self.assertEqual(fix("Ship it with react native."), "Ship it with React Native.")

    def test_terms_without_a_usable_key_are_skipped(self):
        table = build(["C#", "!!"], common=frozenset())
        self.assertEqual(table, {"c": "C#"})
        self.assertNotIn("", build(["!!"], common=frozenset()))

    def test_ambiguous_spellings_are_dropped(self):
        self.assertEqual(build(["PostHog", "Posthog"], common=frozenset()), {})

    def test_empty_table_is_a_no_op(self):
        self.assertEqual(snap("Pencil Wrench", {}), "Pencil Wrench")

    def test_key_keeps_only_lowercase_letters_and_digits(self):
        self.assertEqual(key("Next.js"), "nextjs")
        self.assertEqual(key("i18next"), "i18next")


if __name__ == "__main__":
    unittest.main()
