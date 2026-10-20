# Where the sounds come from

| folder | what | source | licence |
|---|---|---|---|
| `kenney/interface`, `kenney/ui`, `kenney/impact`, `kenney/sci-fi` | UI clicks, panel open/close, confirmations, footsteps, impacts (jump/landing), engines | Kenney asset packs (kenney.nl) — the licence file ships in each folder | CC0 |
| `water/` | surf loop, splashes | synthesized by `tools/gen_surf_audio.py` | the project's own |
| `ambience/` | `wind_low`, `wind_gust`, `underwater` (seamless loops) | synthesized by `tools/gen_soundscape_audio.py` | the project's own |
| `music/` | `drift`, `far_shore`, `low_orbit` (calm pad pieces, faded both ends) | synthesized by `tools/gen_soundscape_audio.py` | the project's own |
| `sfx/` | `swim_stroke_1..4`, `bubbles_1..3`, `vessel_lost` | synthesized by `tools/gen_soundscape_audio.py` | the project's own |
| `weather/` | `rain_light`, `rain_heavy`, `hail`, `dust` (seamless loops), `thunder_1..3` | synthesized by `tools/gen_weather_audio.py` | the project's own |

Levels (from `python3 tools/gen_soundscape_audio.py --stats`, confirmed with ffmpeg's
`ebur128`): music ≈ −24 LUFS with peaks near −12 dBFS; ambience −25 to −29 LUFS
before the Ambient bus's −9 dB; the vessel-lost sting −15 LUFS, peak −1.9 dBFS;
nothing peaks above −1 dBFS. Check new sounds the same way — by numbers, not by
playing them through speakers.

Considered and not used: the user's own **Fofighter Sample Kit** music
(`Floptle/packages/fofighter-kit`, CC0) — a fight theme, a menu loop and two
story cues written for a gothic fighting game, not calm space music. The music
in `Floptle-jam-release/assets/audio/music` and the Unity projects has no
recorded licence or author, so it was left alone.
