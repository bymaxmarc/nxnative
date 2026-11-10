"""Every symbol the host takes over with HLE_FORCE appears once.

The loader dies at startup on a duplicate ("duplicate entry in the forced takeover list"), but the host's unit
tests link the handlers under their own C names and never build that list, so two handlers for one symbol (as
when an upstream merge brought nn::hid's Home button protection next to the host's own) pass every test and only
abort the game at boot. This test reads the sources instead.
"""
import collections
import pathlib
import re
import unittest

HOST = pathlib.Path(__file__).resolve().parents[2] / "host"
FORCE = re.compile(r'\bHLE_FORCE(?:_BIG)?\(\s*"([^"]+)"')
SOURCE_SUFFIXES = {".c", ".h", ".m", ".inc"}


def forced_symbols(root):
    """(symbol, 'file:line') for each HLE_FORCE / HLE_FORCE_BIG use under root, tests and the macro itself excluded."""
    for path in sorted(root.rglob("*")):
        if path.suffix not in SOURCE_SUFFIXES or "tests" in path.relative_to(root).parts:
            continue
        for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
            if line.lstrip().startswith("#define"):
                continue
            for match in FORCE.finditer(line):
                yield match.group(1), f"{path.relative_to(root)}:{number}"


class ForcedTakeoverUnique(unittest.TestCase):
    def test_sources_found(self):
        self.assertGreater(sum(1 for _ in forced_symbols(HOST)), 100, "no HLE_FORCE uses found: the pattern or the path is wrong")

    def test_each_symbol_forced_once(self):
        places = collections.defaultdict(list)
        for symbol, where in forced_symbols(HOST):
            places[symbol].append(where)
        duplicates = {symbol: where for symbol, where in places.items() if len(where) > 1}
        self.assertEqual(duplicates, {}, "symbols taken over more than once (the loader aborts at boot): "
                         + "; ".join(f"{s} at {', '.join(w)}" for s, w in sorted(duplicates.items())))


if __name__ == "__main__":
    unittest.main()
