"""Vocabulary file tests:  cd helper && .venv/bin/python -m unittest discover -s tests -t ."""
import os
import tempfile
import threading
import time
import unittest
from pathlib import Path

import vocabulary as vocab
from vocabulary import Vocabulary, VocabularyError, parse, read, seed


def wait_until(condition, timeout=10.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(0.02)
    return False


class ParseTests(unittest.TestCase):
    def test_skips_comments_and_blanks_trims_and_drops_duplicates(self):
        text = "# header\n\n  React  \nNext.js\n   # indented comment\nReact\nC#\n"
        self.assertEqual(parse(text), ["React", "Next.js", "C#"])

    def test_a_line_with_no_letters_or_digits_names_its_line_only(self):
        with self.assertRaises(VocabularyError) as raised:
            parse("React\n\n---\n")
        self.assertEqual(str(raised.exception), "line 3 has no letters or digits")

    def test_empty_text_is_no_terms(self):
        self.assertEqual(parse(""), [])
        self.assertEqual(parse("# only comments\n\n"), [])


class FileTests(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())

    def test_missing_file_is_an_empty_vocabulary(self):
        self.assertEqual(read(self.dir / "vocabulary.txt"), ([], b""))

    def test_non_utf8_is_rejected(self):
        path = self.dir / "vocabulary.txt"
        path.write_bytes(b"React\n\xff\xfe\n")
        with self.assertRaises(VocabularyError):
            read(path)

    def test_unreadable_file_is_rejected(self):
        path = self.dir / "vocabulary.txt"
        path.mkdir()  # reading a directory fails with an OSError other than FileNotFoundError
        with self.assertRaises(VocabularyError):
            read(path)

    def test_seeds_on_first_launch_only(self):
        default = self.dir / "default.txt"
        default.write_text("React\n")
        path = self.dir / "app" / "vocabulary.txt"
        self.assertTrue(seed(path, default))
        self.assertEqual(path.read_text(), "React\n")

        path.unlink()  # the user turned it off
        self.assertFalse(seed(path, default))
        self.assertFalse(path.exists())


class VocabularyTests(unittest.TestCase):
    def setUp(self):
        self.path = Path(tempfile.mkdtemp()) / "vocabulary.txt"
        self.builds: list[list[str]] = []
        self.logs: list[str] = []

    def make(self, build=None):
        def default_build(terms):
            self.builds.append(terms)
            return f"built {terms}"

        return Vocabulary(self.path, build or default_build, self.logs.append, clock=lambda: 1000.0)

    def test_status_before_the_first_load(self):
        self.assertEqual(self.make().status(), {"terms": 0, "loaded_at": None, "error": None})

    def test_loads_and_reports(self):
        self.path.write_text("React\nNext.js\n")
        v = self.make()
        self.assertTrue(v.reload())
        self.assertEqual(v.active.terms, ("React", "Next.js"))
        self.assertEqual(v.active.built, "built ['React', 'Next.js']")
        self.assertEqual(v.status(), {"terms": 2, "loaded_at": 1000.0, "error": None})

    def test_missing_or_empty_file_turns_it_off_without_building(self):
        v = self.make()
        self.assertTrue(v.reload())
        self.assertIsNone(v.active.built)
        self.assertEqual(v.status()["terms"], 0)
        self.assertEqual(self.builds, [])

    def test_unchanged_content_doesnt_rebuild(self):
        self.path.write_text("React\n")
        v = self.make()
        v.reload()
        self.assertFalse(v.reload())
        self.assertEqual(len(self.builds), 1)

    def test_bad_file_keeps_the_last_good_one_until_fixed(self):
        self.path.write_text("React\n")
        v = self.make()
        v.reload()
        good = v.active

        self.path.write_text("React\n!!!\n")
        self.assertFalse(v.reload())
        self.assertIs(v.active, good)
        self.assertEqual(v.status(), {"terms": 1, "loaded_at": 1000.0, "error": "line 2 has no letters or digits"})

        # Undoing the bad edit restores the same content: no rebuild, and the problem clears.
        self.path.write_text("React\n")
        self.assertFalse(v.reload())
        self.assertIsNone(v.error)
        self.assertEqual(len(self.builds), 1)

    def test_a_failing_build_keeps_the_last_good_one(self):
        self.path.write_text("React\n")
        v = self.make()
        v.reload()
        good = v.active

        def broken(terms):
            raise RuntimeError("bug")

        v._build = broken
        self.path.write_text("React\nVue\n")
        self.assertFalse(v.reload())
        self.assertIs(v.active, good)
        self.assertIsNotNone(v.error)

    def test_readers_see_the_old_vocabulary_until_the_new_one_is_complete(self):
        self.path.write_text("React\n")
        release = threading.Event()

        def slow_build(terms):
            if terms == ["Vue"]:
                release.wait(5)
            return tuple(terms)

        v = self.make(slow_build)
        v.reload()
        old = v.active
        self.path.write_text("Vue\n")
        thread = threading.Thread(target=v.reload)
        thread.start()
        time.sleep(0.1)  # showing the swap hasn't happened yet
        self.assertIs(v.active, old)
        release.set()
        thread.join()
        self.assertEqual(v.active.built, ("Vue",))

    def test_logs_counts_and_timings_never_terms(self):
        self.path.write_text("Pencilwrench\n")
        v = self.make()
        v.reload()
        self.path.write_text("Pencilwrench\n???\n")
        v.reload()
        self.assertTrue(self.logs)
        self.assertFalse(any("Pencilwrench" in line for line in self.logs))


class WatchTests(unittest.TestCase):
    """Real FSEvents, with the save patterns editors use. Each save must rebuild exactly once."""

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.path = self.dir / "vocabulary.txt"
        self.path.write_text("React\n")
        self.builds = 0

        def build(terms):
            self.builds += 1
            return terms

        self.v = Vocabulary(self.path, build, lambda _: None)
        self.v.reload()
        self.stop = threading.Event()
        self.thread = threading.Thread(target=vocab.watch, args=(self.v, self.stop, lambda _: None),
                                       kwargs={"debounce_ms": 300})
        self.thread.start()
        time.sleep(0.5)  # let FSEvents start watching

    def tearDown(self):
        self.stop.set()
        self.thread.join(5)

    def assert_one_rebuild(self, expected_terms):
        self.assertTrue(wait_until(lambda: self.builds == 2), f"builds: {self.builds}")
        time.sleep(1.0)  # showing no second rebuild follows
        self.assertEqual(self.builds, 2)
        self.assertEqual(self.v.active.terms, expected_terms)

    def test_in_place_write(self):  # e.g. VS Code
        self.path.write_text("React\nVue\n")
        self.assert_one_rebuild(("React", "Vue"))

    def test_atomic_rename_over_the_file(self):  # e.g. TextEdit
        tmp = self.dir / ".vocabulary.txt.tmp"
        tmp.write_text("React\nSvelte\n")
        os.replace(tmp, self.path)
        self.assert_one_rebuild(("React", "Svelte"))

    def test_backup_rename_then_new_file(self):  # e.g. vim's default
        backup = self.dir / "vocabulary.txt~"
        os.rename(self.path, backup)
        self.path.write_text("React\nAstro\n")
        backup.unlink()
        self.assert_one_rebuild(("React", "Astro"))

    def test_other_files_in_the_folder_are_ignored(self):
        (self.dir / ".vocabulary.txt.swp").write_text("x")
        (self.dir / "notes.txt").write_text("x")
        time.sleep(1.0)  # showing nothing rebuilds
        self.assertEqual(self.builds, 1)


if __name__ == "__main__":
    unittest.main()
