#!/usr/bin/env python3
"""Build fonts/SolarUI.ttf — Roboto Regular with the symbols the game draws.

The engine's embedded UI font is Roboto, and Roboto has no arrows, no geometric
shapes, no check marks and no dingbats. Every ☰ ✓ ✕ ▸ ● ⚠ → the HUD printed came
out as an empty box. The engine has no per-glyph fallback, so the fix is one
font that has both: Roboto's letters (unchanged, so every string keeps its
look and its measured width) plus DejaVu Sans's outlines for the symbol blocks
Roboto leaves empty. Both are 2048 units per em, so outlines copy across
without rescaling.

project.ron names the result as `ui_font`, which is what an element that names
no font of its own draws with.

    python3 tools/build_ui_font.py [ROBOTO.ttf] [DEJAVU.ttf]

Licences: Roboto is Apache-2.0; DejaVu Sans is the Bitstream Vera licence plus
public-domain changes, which allows modification provided the result is not
named Bitstream, Vera or DejaVu — hence "Solar UI". See fonts/README.md.
"""
import sys
from pathlib import Path

from fontTools.ttLib import TTFont

ROOT = Path(__file__).resolve().parent.parent
ROBOTO = Path(sys.argv[1]) if len(sys.argv) > 1 else \
    ROOT.parent / "Floptle/crates/floptle-render/fonts/Roboto-Regular.ttf"
DEJAVU = Path(sys.argv[2]) if len(sys.argv) > 2 else Path("/usr/share/fonts/TTF/DejaVuSans.ttf")
OUT = ROOT / "fonts" / "SolarUI.ttf"

# The Unicode blocks a HUD reaches for. Only codepoints Roboto lacks are taken,
# so nothing Roboto already draws changes.
BLOCKS = [
    (0x2190, 0x21FF),  # arrows
    (0x2200, 0x22FF),  # mathematical operators
    (0x2300, 0x23FF),  # miscellaneous technical (⌂ ⌫ ⏎)
    (0x2500, 0x257F),  # box drawing
    (0x2580, 0x259F),  # block elements
    (0x25A0, 0x25FF),  # geometric shapes (▲ ▸ ● ◆ ▪)
    (0x2600, 0x26FF),  # miscellaneous symbols (☰ ⚠ ⚙ ★)
    (0x2700, 0x27BF),  # dingbats (✓ ✕ ✦)
    (0x2B00, 0x2BFF),  # miscellaneous symbols and arrows
]


def main():
    base = TTFont(str(ROBOTO))
    donor = TTFont(str(DEJAVU))
    assert base["head"].unitsPerEm == donor["head"].unitsPerEm, "units per em differ"

    bcmap = base.getBestCmap()
    dcmap = donor.getBestCmap()
    bglyf, dglyf = base["glyf"], donor["glyf"]
    bhmtx, dhmtx = base["hmtx"], donor["hmtx"]

    wanted = {cp: dcmap[cp] for lo, hi in BLOCKS for cp in range(lo, hi + 1)
              if cp in dcmap and cp not in bcmap}

    renamed = {}

    def take(dname):
        """Copy one donor glyph (and any composite components) into the base."""
        if dname in renamed:
            return renamed[dname]
        new = "sui." + dname
        renamed[dname] = new
        g = dglyf[dname]
        if g.isComposite():
            for comp in g.components:
                comp.glyphName = take(comp.glyphName)
        bglyf[new] = g  # appends `new` to the font's glyph order as well
        bhmtx[new] = dhmtx[dname]
        return new

    added = {cp: take(name) for cp, name in wanted.items()}
    order = base.getGlyphOrder()
    assert len(order) == len(set(order)) == len(bglyf.glyphs), "glyph order out of step"

    for table in base["cmap"].tables:
        if table.isUnicode():
            for cp, name in added.items():
                if table.format == 4 and cp > 0xFFFF:
                    continue
                table.cmap[cp] = name

    # Names: this is a derivative and must not claim to be either parent.
    for rec in base["name"].names:
        if rec.nameID in (1, 16):
            rec.string = "Solar UI"
        elif rec.nameID == 3:
            rec.string = "Solar UI Regular; built by tools/build_ui_font.py"
        elif rec.nameID in (4, 18):
            rec.string = "Solar UI Regular"
        elif rec.nameID == 6:
            rec.string = "SolarUI-Regular"
    base["maxp"].numGlyphs = len(order)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    base.save(str(OUT))
    print(f"wrote {OUT.relative_to(ROOT)}: {len(added)} symbols added to Roboto "
          f"({len(order)} glyphs)")


if __name__ == "__main__":
    main()
