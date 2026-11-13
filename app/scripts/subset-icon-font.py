#!/usr/bin/env python3
"""Regenerate the bundled icon subset with fonttools==4.60.1; input is upstream TTF."""
import hashlib
from pathlib import Path
import sys

from fontTools import __version__, subset
from fontTools.ttLib import TTFont

SOURCE_SHA256 = "fe471e538392f51910faab985fa8e192a39dd3426125edd15b71b3680df0e749"
OUTPUT = Path(__file__).resolve().parents[1] / "assets/fonts/SymbolsNerdFontMono-Regular.ttf"
GLYPHS = {0xF0140}


def main():
    if __version__ != "4.60.1":
        raise SystemExit("Regeneration requires fonttools==4.60.1")
    source = Path(sys.argv[1])
    if hashlib.sha256(source.read_bytes()).hexdigest() != SOURCE_SHA256:
        raise SystemExit("Input must be the exact Nerd Fonts v3.5.1 Symbols Mono font")
    font = TTFont(source, recalcTimestamp=False)
    options = subset.Options()
    options.recalc_timestamp = False
    options.name_IDs = [0, 1, 2, 3, 4, 5, 6, 13, 14, 16, 17]
    subsetter = subset.Subsetter(options=options)
    subsetter.populate(unicodes=GLYPHS)
    subsetter.subset(font)
    names = {1: "Magpie Symbols", 3: "MagpieSymbols-Regular",
             4: "Magpie Symbols Regular", 6: "MagpieSymbols-Regular", 16: "Magpie Symbols"}
    for record in font["name"].names:
        if record.nameID in names:
            record.string = names[record.nameID].encode(record.getEncoding())
    font.save(OUTPUT)


if __name__ == "__main__":
    main()
