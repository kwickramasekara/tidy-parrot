"""Snap transcribed spans to the vocabulary's spelling: "Pencil Wrench" -> "Pencilwrench", "next JS" -> "Next.js".

A span of up to four words matches a term when both reduce to the same lowercase letters and digits, so users list
each term once and never its misspellings. Terms that are everyday English words are skipped, so "we need to react
quickly" keeps its lowercase "react"; the decoder's boost still favours them. Sound-alikes ("post hoc" for "PostHog")
can't be fixed here: they reduce to different letters.
"""
import re
from collections.abc import Iterable
from functools import cache
from pathlib import Path

SYSTEM_WORDS = Path("/usr/share/dict/words")
# The system list is Webster's 1934, so newer words and inflections are missing.
EXTRA_COMMON_WORDS = frozenset({
    "apollo", "biome", "bootstrap", "bun", "chromatic", "cursor", "cypress", "drizzle", "electron", "ember",
    "emotion", "expo", "express", "fallow", "husky", "jest", "lighthouse", "linear", "neon", "parcel", "prettier",
    "puppeteer", "react", "remix", "rollup", "sanity", "slack", "solid", "storybook", "suspense", "tailwind", "yarn",
})
WORD = re.compile(r"[A-Za-z0-9]+(?:[.\-/][A-Za-z0-9]+)*")  # keeps "Next.js" and "date-fns" whole
MAX_WORDS = 4
JOINERS = (" ", "-")

Table = dict[str, str]


@cache
def common_words() -> frozenset[str]:
    try:
        system = {w for w in SYSTEM_WORDS.read_text(errors="ignore").split() if w.islower()}
    except OSError:
        system = set()
    return frozenset(system) | EXTRA_COMMON_WORDS


def key(text: str) -> str:
    return re.sub(r"[^a-z0-9]", "", text.lower())


def build(terms: Iterable[str], common: frozenset[str] | None = None) -> Table:
    """Key -> term. Keys shared by two spellings ("React" and "react") are dropped rather than guessed."""
    common = common_words() if common is None else common
    table: dict[str, str | None] = {}
    for term in terms:
        k = key(term)
        if not k or k in common:
            continue
        table[k] = None if k in table and table[k] != term else term
    return {k: v for k, v in table.items() if v is not None}


def snap(text: str, table: Table) -> str:
    if not table:
        return text
    words = list(WORD.finditer(text))
    out, pos, i = [], 0, 0
    while i < len(words):
        # Longest span first, so "React Native" wins over "React".
        for n in range(min(MAX_WORDS, len(words) - i), 0, -1):
            span = words[i : i + n]
            if any(text[a.end() : b.start()] not in JOINERS for a, b in zip(span, span[1:])):
                continue
            term = table.get(key(text[span[0].start() : span[-1].end()]))
            if term:
                out.append(text[pos : span[0].start()] + term)
                pos, i = span[-1].end(), i + n
                break
        else:
            i += 1
    return "".join(out) + text[pos:]
