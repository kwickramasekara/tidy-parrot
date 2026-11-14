"""The user's vocabulary file: reading it, rebuilding when it changes, and handing transcription a consistent copy.

The file is one term per line; blank lines and lines starting with # are ignored. The app owns the path and passes it
with --vocabulary. No MLX here: the expensive part is an injected `build` function, so this is testable alone.

Logs counts and timings only, never terms.
"""
import hashlib
import shutil
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Generic, TypeVar

Log = Callable[[str], None]
Built = TypeVar("Built")
# How long to wait before watching again after the folder vanished or the watcher failed.
RETRY_SECONDS = 5.0


class VocabularyError(Exception):
    """The file can't be used; the last good vocabulary stays in effect."""


def parse(text: str) -> list[str]:
    """Terms in file order, duplicates dropped. Raises on a line that can't be a term."""
    terms: dict[str, None] = {}
    for number, line in enumerate(text.splitlines(), start=1):
        term = line.strip()
        if not term or term.startswith("#"):
            continue
        if not any(ch.isalnum() for ch in term):
            # Line number only: the message reaches the menu and the log.
            raise VocabularyError(f"line {number} has no letters or digits")
        terms[term] = None
    return list(terms)


def read(path: Path) -> tuple[list[str], bytes]:
    """Terms and the raw bytes they came from. A missing file is an empty vocabulary, which turns the feature off."""
    try:
        data = path.read_bytes()
    except FileNotFoundError:
        return [], b""
    except OSError as e:
        raise VocabularyError(f"can't read the file ({e.strerror or type(e).__name__})") from e
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as e:
        raise VocabularyError("the file isn't UTF-8 text") from e
    return parse(text), data


def seed(path: Path, default: Path) -> bool:
    """Creates the file from `default` on first launch, told apart by the folder not existing yet. A file the user
    deleted from an existing folder stays deleted: that's how they turn the vocabulary off. Raises OSError if the
    folder or file can't be written."""
    try:
        path.parent.mkdir(parents=True)  # creating it is the test, so the app creating it meanwhile can't race this
    except FileExistsError:
        return False
    try:
        shutil.copyfile(default, path)
    except OSError:
        # An empty folder would mark first launch as done, so the default list would never be created.
        path.unlink(missing_ok=True)
        path.parent.rmdir()
        raise
    return True


@dataclass(frozen=True)
class Active(Generic[Built]):
    """One consistent vocabulary. Transcription takes a reference once per clip, so a rebuild never shows it half a
    dictionary and never makes it wait."""

    terms: tuple[str, ...]
    built: Built | None  # None when there are no terms
    loaded_at: float


@dataclass(frozen=True)
class State(Generic[Built]):
    """What's in effect and what went wrong, swapped as one reference so a status never pairs one load's terms with
    another's error."""

    active: Active[Built] | None = None  # None until the first load finishes
    error: str | None = None


class Vocabulary(Generic[Built]):
    def __init__(self, path: Path, build: Callable[[list[str]], Built], log: Log, clock=time.time):
        self.path = path
        self._build = build
        self._log = log
        self._clock = clock
        self._lock = threading.Lock()  # one reload at a time; readers never take it
        self._digest: bytes | None = None
        self.state: State[Built] = State()

    @property
    def active(self) -> Active[Built] | None:
        return self.state.active

    def reload(self) -> bool:
        """Reads the file and swaps in a fresh build. False when nothing changed or the file couldn't be used."""
        with self._lock:
            active = self.state.active
            try:
                terms, data = read(self.path)
            except VocabularyError as e:
                return self._reject(str(e), str(e))
            digest = hashlib.sha256(data).digest()
            if digest == self._digest and active is not None:
                self.state = State(active)
                return False
            start = time.perf_counter()
            try:
                built = self._build(terms) if terms else None
            except Exception as e:  # a bug here mustn't take dictation down with it
                return self._reject("couldn't build the vocabulary; see the log", type(e).__name__)
            self.state = State(Active(terms=tuple(terms), built=built, loaded_at=self._clock()))
            self._digest = digest
            ms = round((time.perf_counter() - start) * 1000)
            self._log(f"vocabulary loaded: {len(terms)} terms in {ms} ms")
            return True

    def _reject(self, error: str, reason: str) -> bool:
        active = self.state.active
        self.state = State(active, error)
        self._log(f"vocabulary not applied ({reason}); keeping {len(active.terms) if active else 0} terms")
        return False

    def status(self) -> dict[str, Any]:
        """What the app shows: terms in effect, when they were loaded (None while the first load runs), any problem."""
        state = self.state
        return {
            "terms": len(state.active.terms) if state.active else 0,
            "loaded_at": state.active.loaded_at if state.active else None,
            "error": state.error,
        }


def is_vocabulary_change(path: Path) -> Callable[[Any, str], bool]:
    # Editors save atomically (write a temp file, rename it over the original), so the folder is watched and changes
    # are filtered to the file's name; a watch on the file itself would follow the replaced inode and go quiet.
    name = path.name
    return lambda _change, changed: Path(changed).name == name


def watch(vocabulary: Vocabulary, stop: threading.Event, log: Log, debounce_ms: int = 1_600) -> None:
    """Reloads on every change until `stop` is set. Uses FSEvents through watchfiles, so it costs nothing at idle.
    One save can arrive as several events, or several batches; the content check in `reload` makes that one rebuild."""
    from watchfiles import watch as watch_paths

    folder = vocabulary.path.parent
    while not stop.is_set():
        try:
            # FSEvents doesn't replay what happened before the watch began, such as a save during the first build or
            # during a retry. The first timeout tick comes once the watch is live, so reloading then catches those; the
            # content check makes it free when nothing changed.
            caught_up = False
            # debug=False: watchfiles' debug output goes to the real stdout, which is the protocol channel.
            # rust_timeout: how often it wakes to check `stop` when nothing changes.
            for changes in watch_paths(folder, watch_filter=is_vocabulary_change(vocabulary.path), recursive=False,
                                       stop_event=stop, debug=False, debounce=debounce_ms, rust_timeout=1_000,
                                       yield_on_timeout=True):
                if changes or not caught_up:
                    vocabulary.reload()
                    caught_up = True
        except FileNotFoundError:
            # The folder was removed. Treat that like a deleted file, and pick it up again if it comes back.
            vocabulary.reload()
            stop.wait(RETRY_SECONDS)
        except Exception as e:
            log(f"vocabulary watch failed ({type(e).__name__}); retrying")
            stop.wait(RETRY_SECONDS)


def keep_loaded(vocabulary: Vocabulary, stop: threading.Event, log: Log, debounce_ms: int = 1_600) -> None:
    """Loads now, then reloads on every change until `stop` is set."""
    vocabulary.reload()
    watch(vocabulary, stop, log, debounce_ms)


def start(vocabulary: Vocabulary, log: Log) -> None:
    """Keeps the vocabulary loaded in the background for as long as the helper runs."""
    threading.Thread(target=keep_loaded, args=(vocabulary, threading.Event(), log), name="vocabulary",
                     daemon=True).start()
