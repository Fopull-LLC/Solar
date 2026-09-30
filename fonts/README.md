# fonts

`SolarUI.ttf` is the game's UI font (`ui_font` in `project.ron`): Roboto
Regular with the arrows, geometric shapes, check marks and dingbats that Roboto
lacks copied in from DejaVu Sans. Without it every ☰ ✓ ✕ ▸ ● ⚠ → drew as an
empty box. Rebuild it with `python3 tools/build_ui_font.py`.

Roboto is licensed under the Apache License 2.0. DejaVu Sans glyphs are under
the Bitstream Vera Fonts licence (with public-domain DejaVu changes), which
permits modification and redistribution provided the result is not named
"Bitstream", "Vera" or "DejaVu"; the merged font is named "Solar UI".

`NotoSansMono-Medium.ttf` is the flight instruments' number face (the `mono`
font token in `ui/solar.tokens.ron`): every digit is the same width, so a
readout that ticks from 99 to 100 does not shuffle the numbers beside it.
Copied unmodified from Noto Sans Mono. It is licensed under the SIL Open Font
License 1.1 (https://scripts.sil.org/OFL, also quoted in the font's own name
table), which permits bundling it with software, modified or not.
