# Where the sounds come from

| folder | what | source | licence |
|---|---|---|---|
| `kenney/interface`, `kenney/ui`, `kenney/impact`, `kenney/sci-fi` | footsteps, impacts (jump, landing, mining, wood, the helmet ring). The interface and sci-fi packs are no longer played (2026-10-26: their tonal bleeps and the force-field loop are what made driving beep) | Kenney asset packs (kenney.nl) — the licence file ships in each folder | CC0 |
| `foley/` | real recordings, cut, cleaned and levelled by `tools/build_sfx.py` (table below): switches, relays, pneumatics, servos, the rover's motor and tyres, pyro bangs, clunks, an impact wrench, a welding arc, a ledger printer, the Quindar tones, radio crackle, the SLS launch roar; `wind_roar` and `bore_hum` are synthesised there | BigSoundBank.com (Joseph Sardin) and NASA | CC0 (BigSoundBank); public domain (NASA) |
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

## audio/foley — what each file is cut from

All BigSoundBank sounds are CC0 1.0 ("Free and royalty-free", https://bigsoundbank.com/licenses.html);
the page for sound #NNNN is reached from https://bigsoundbank.com/search?q=NNNN and the file is
`https://bigsoundbank.com/UPLOAD/flac/NNNN.flac` (or `/UPLOAD/ogg/NNNN.ogg`). Save each as
`bsb_NNNN.flac|.ogg` in one folder and run `python3 tools/build_sfx.py <folder> --stats` to rebuild.

| file(s) | source | what it was |
|---|---|---|
| `rover_motor` (loop) | BSB #1504 | Kia Carnival electric window motor, steady run |
| `rover_gravel` (loop) | BSB #1284 | mountain bike rolling on a gravel road, on board |
| `rover_bump` | BSB #3061 | very large industrial switch, pitched down |
| `clamp_clunk`, `latch_clunk` | BSB #3061, #3062 | very large industrial switch |
| `steel_drop` | BSB #1774 | sheet steel bar falling on a path |
| `pyro_bang`, `pyro_far` | BSB #1808, #1807 | agricultural bird-scaring gun at 10 m and 150 m |
| `explosion_far` | BSB #1023 | the same gun, far away |
| `hiss_short` | BSB #1490 | pneumatic brake released |
| `hiss_seal`, `hiss_cylinder` | BSB #1491, #1493 | small pneumatic cylinder |
| `servo_run`, `servo_short` | BSB #1502, #1505 | electric car window opening / closing |
| `weld_arc` (loop) | BSB #0950 | MIG welding, long weld |
| `bore_hum` (loop) | `weld_arc` + a synthesised 100 Hz transformer buzz | |
| `ratchet_1..5` | BSB #0964 | impact wrench |
| `switch_1..5` | BSB #0321 | switch clicks |
| `toggle_on`, `toggle_off` | BSB #0036 | desk lamp switch |
| `rocker_on`, `rocker_off` | BSB #0025 | electronic switch |
| `relay_tick` | BSB #2191 | thermostat click |
| `key_strike` | BSB #2842 | Hermes Precisa 305 typewriter key |
| `ticket_print`, `ticket_short` | BSB #3264 | Olivetti Logos calculator printing a ticket |
| `buzz_denied` | BSB #3442 | electric door strike buzzing |
| `quindar_in`, `quindar_out` | BSB #2380, #2381 | aerospace communication beep, 2,527 Hz / 2,460 Hz (Quindar tones) |
| `radio_crackle`, `radio_squelch` | BSB #2514, #2511 | interference between two wireless audio systems |
| `rocket_roar` (loop), `rocket_ignite` | NASA, "Artemis II Live Launch Coverage – Pad Camera Site 4" (KSC-20260401-AU-LMM01-0001), public domain: https://commons.wikimedia.org/wiki/File:Artemis_II_Live_Launch_Coverage_-_Pad_Camera_Site_4_(KSC-20260401-AU-LMM01-0001-Artemis_II_Live_Launch_Coverage_Pad_Camera_Site_4).wav | SLS ignition (7–11.5 s) and full thrust (12–17.6 s) |
| `wind_roar` (loop) | synthesised in `tools/build_sfx.py` | |

Levels (`--stats`): one-shots peak ≤ −1.2 dBFS with the loud part's RMS at most −14 dBFS (the
Kenney clips they replaced sat at −10 to −19); loops RMS −18 dBFS (gravel −23, the arc −28: their
crackle sets the peak), `bore_hum` −16. Loops are crossfaded tail-into-head (equal power), and
their 100 ms envelope varies 0.4–3.7 dB — none of them pulses.

## audio/incoming/

Drop sounds found by hand here (see audio/incoming/README.md for the list the game wants).
