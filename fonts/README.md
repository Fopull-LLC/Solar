# fonts

Solar's type kit ("flight hardware", see `docs/ui-style.md`). Four faces, all
built by `python3 tools/build_ui_font.py`, which fetches the sources from the
google/fonts repository at a pinned commit, checks their SHA-256, and copies in
the symbols the HUD prints (arrows, ✓ ✕ ▸ ● ⚠, Greek Δ) from DejaVu, because a
face that lacks a glyph would otherwise draw it from a different font.

| File | Built from | Token | Used for |
|---|---|---|---|
| `SolarUI.ttf` | Barlow Semi Condensed Medium | `ui` (and `ui_font` in `project.ron`) | running text |
| `SolarLabel.ttf` | Barlow Semi Condensed SemiBold | `label` | printed capitals, keys, numbers on plates, headings |
| `SolarMono.ttf` | Share Tech Mono | `mono` | numbers on a CRT display only |
| `SolarStencil.ttf` | Saira Stencil One | `stencil` | the title, panel names, warning placards, signage |

Licences:

- **Barlow Semi Condensed** — Copyright 2017 The Barlow Project Authors
  (https://github.com/jpt/barlow). SIL Open Font License 1.1.
- **Share Tech Mono** — Copyright (c) 2012 Carrois Type Design, Ralph du
  Carrois, with Reserved Font Name "Share". SIL Open Font License 1.1. The
  modified font is therefore named "Solar Mono", not "Share…".
- **Saira Stencil One** — Copyright 2019 The Saira Stencil Project Authors
  (https://github.com/Omnibus-Type/Saira). SIL Open Font License 1.1.
- **DejaVu Sans / Sans Bold / Sans Mono** (the borrowed symbols) — Bitstream
  Vera Fonts licence with public-domain DejaVu changes, which permits
  modification and redistribution provided the result is not named
  "Bitstream", "Vera" or "DejaVu".

The OFL (https://openfontlicense.org) permits bundling, modifying and
redistributing the fonts with software, provided they are not sold on their own
and modified versions do not use a Reserved Font Name. Each built font keeps
the original copyright and licence strings in its name table.

`NotoSansMono-Medium.ttf` was the previous `mono` face (Noto Sans Mono, SIL OFL
1.1). Nothing refers to it any more; it can be deleted.
