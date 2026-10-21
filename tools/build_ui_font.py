#!/usr/bin/env python3
"""Build Solar's four UI faces in fonts/ — the "flight hardware" type kit.

    fonts/SolarUI.ttf       Barlow Semi Condensed Medium   running text (`ui_font`)
    fonts/SolarLabel.ttf    Barlow Semi Condensed SemiBold printed labels, keys, headings
    fonts/SolarMono.ttf     Share Tech Mono                instrument readouts (CRT numerals)
    fonts/SolarStencil.ttf  Saira Stencil One              the title and the big placards

Why these: Barlow is a DIN-like grotesk drawn after California highway and
aviation signage, so it reads as a flight manual rather than a web page, and
the semi-condensed cut keeps every string NARROWER than the Roboto it replaces
(nothing that fitted before overflows now). Share Tech Mono is a squared,
terminal-era monospace: every digit the same width, so a readout that ticks
from 99 to 100 does not shuffle, and it looks like a CRT character generator
rather than a code editor. Saira Stencil One is spray-through-a-stencil type,
the way hardware is actually marked; it is only ever used large.

The engine has no per-glyph fallback, so each face gets the symbols the HUD
prints (arrows, ✓ ✕ ▸ ● ⚠, Greek Δ) copied in from DejaVu where it lacks them.
DejaVu is 2048 units per em and these faces are 1000, so the outlines are
redrawn through a scaling pen; in the mono face every borrowed glyph is
centred on the face's own advance so columns still line up.

Sources are fetched from the google/fonts repository at a pinned commit and
checked against their SHA-256, so the build is reproducible:

    python3 tools/build_ui_font.py            # fetch (cached) + build all four
    python3 tools/build_ui_font.py --offline  # only use the cache

DejaVu comes from the system (/usr/share/fonts/TTF). Licences are in
fonts/README.md: the four bases are SIL OFL 1.1 (Share Tech Mono reserves the
name "Share", hence "Solar Mono"); DejaVu is the Bitstream Vera licence, which
allows modification provided the result is not named Bitstream, Vera or DejaVu.
"""
import hashlib
import sys
import urllib.request
from pathlib import Path

from fontTools.pens.recordingPen import DecomposingRecordingPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import TTFont

ROOT = Path(__file__).resolve().parent.parent
CACHE = Path.home() / ".cache" / "solar-fonts"
GF = "https://raw.githubusercontent.com/google/fonts/47d54ca1ebb14fd864695f1d39dc734f39017c33/ofl/"
# name → (path under ofl/, sha256 of the file at that commit)
SOURCES = {
    "BarlowSemiCondensed-Medium.ttf": ("barlowsemicondensed/BarlowSemiCondensed-Medium.ttf",
        "4998b693a190b76f2b11315844345a8546c1e2e6a320905507a9eed04edf8b48"),
    "BarlowSemiCondensed-SemiBold.ttf": ("barlowsemicondensed/BarlowSemiCondensed-SemiBold.ttf",
        "bd299f4bc5b44d30be8d42e9bad3a5df7d66af1cd55d0ed72a8b8916360a1424"),
    "ShareTechMono-Regular.ttf": ("sharetechmono/ShareTechMono-Regular.ttf",
        "9ceab1f87414829af259c0f537573ae03ef7dd3147c0b27a36a1a0beb6732677"),
    "SairaStencilOne-Regular.ttf": ("sairastencilone/SairaStencilOne-Regular.ttf",
        "781496fdaf8e04cf6741b31025f6b4ba84f66021b097a8e0d85cbea2180cf223"),
}
DEJAVU = Path("/usr/share/fonts/TTF/DejaVuSans.ttf")
DEJAVU_BOLD = Path("/usr/share/fonts/TTF/DejaVuSans-Bold.ttf")
DEJAVU_MONO = Path("/usr/share/fonts/TTF/DejaVuSansMono.ttf")

# The Unicode blocks a HUD reaches for. Only codepoints the base lacks are
# taken, so nothing the base already draws changes.
BLOCKS = [
    (0x0370, 0x03FF),  # Greek (Δv, μ)
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

BUILDS = [
    # out, base, donor, family, mono
    ("SolarUI.ttf", "BarlowSemiCondensed-Medium.ttf", DEJAVU, "Solar UI", False),
    ("SolarLabel.ttf", "BarlowSemiCondensed-SemiBold.ttf", DEJAVU_BOLD, "Solar Label", False),
    ("SolarMono.ttf", "ShareTechMono-Regular.ttf", DEJAVU_MONO, "Solar Mono", True),
    ("SolarStencil.ttf", "SairaStencilOne-Regular.ttf", DEJAVU_BOLD, "Solar Stencil", False),
]


def fetch(name, offline):
    path = CACHE / name
    if not path.exists():
        if offline:
            sys.exit(f"missing {path} (run without --offline to fetch it)")
        CACHE.mkdir(parents=True, exist_ok=True)
        url = GF + SOURCES[name][0]
        print("fetch", url)
        with urllib.request.urlopen(url, timeout=60) as r:
            path.write_bytes(r.read())
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    want = SOURCES[name][1]
    if digest != want:
        sys.exit(f"{path}: sha256 {digest}, expected {want} — delete it and fetch again")
    return path


def merge(base_path, donor_path, family, mono):
    base = TTFont(str(base_path), recalcTimestamp=False)  # byte-identical rebuilds
    donor = TTFont(str(donor_path))
    k = base["head"].unitsPerEm / donor["head"].unitsPerEm
    bcmap = base.getBestCmap()
    dcmap = donor.getBestCmap()
    dglyphs = donor.getGlyphSet()
    bglyf, bhmtx = base["glyf"], base["hmtx"]
    mono_adv = bhmtx["zero"][0] if mono else None

    wanted = {cp: dcmap[cp] for lo, hi in BLOCKS for cp in range(lo, hi + 1)
              if cp in dcmap and cp not in bcmap}
    made = {}
    for cp, dname in sorted(wanted.items()):
        if dname in made:
            continue
        adv = dglyphs[dname].width * k
        dx = 0.0
        if mono:
            dx = (mono_adv - adv) / 2
            adv = mono_adv
        rec = DecomposingRecordingPen(dglyphs)  # composites become plain outlines
        dglyphs[dname].draw(rec)
        pen = TTGlyphPen(None)
        rec.replay(TransformPen(pen, (k, 0, 0, k, dx, 0)))
        g = pen.glyph()
        new = "sol." + dname
        bglyf[new] = g
        g.recalcBounds(bglyf)
        bhmtx[new] = (int(round(adv)), int(round(g.xMin)) if hasattr(g, "xMin") else 0)
        made[dname] = new
    for table in base["cmap"].tables:
        if table.isUnicode():
            for cp, dname in wanted.items():
                if cp <= 0xFFFF or table.format in (12, 13):
                    table.cmap[cp] = made[dname]
    base["maxp"].numGlyphs = len(base.getGlyphOrder())

    # A new name: the OFL bars a modified font from a Reserved Font Name.
    style = "Regular"
    for rec in base["name"].names:
        if rec.nameID in (1, 16):
            rec.string = family
        elif rec.nameID in (2, 17):
            rec.string = style
        elif rec.nameID == 4:
            rec.string = family
        elif rec.nameID == 6:
            rec.string = family.replace(" ", "") + "-" + style
        elif rec.nameID == 3:
            rec.string = family + "; built by tools/build_ui_font.py"
    return base, len(wanted)


def main():
    offline = "--offline" in sys.argv
    for out, src, donor, family, mono in BUILDS:
        font, n = merge(fetch(src, offline), donor, family, mono)
        dest = ROOT / "fonts" / out
        font.save(str(dest))
        print(f"{dest.relative_to(ROOT)}: {src} + {n} symbols from {donor.name}")


if __name__ == "__main__":
    main()
