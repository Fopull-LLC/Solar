# Where the sounds come from

| folder | what | source | licence |
|---|---|---|---|
| `kenney/interface`, `kenney/ui`, `kenney/impact`, `kenney/sci-fi` | footsteps, impacts (jump, landing, mining, wood, the helmet ring). The interface and sci-fi packs are no longer played (2026-10-26: their tonal bleeps and the force-field loop are what made driving beep) | Kenney asset packs (kenney.nl) — the licence file ships in each folder | CC0 |
| `foley/` | real recordings, cut, cleaned and levelled by `tools/build_sfx.py` (table below): switches, relays, pneumatics, servos, the rover's motor and tyres, pyro bangs, clunks, an impact wrench, a welding arc, a ledger printer, the Quindar tones, radio crackle, the SLS launch roar; `wind_roar` and `bore_hum` are synthesised there | BigSoundBank.com (Joseph Sardin) and NASA | CC0 (BigSoundBank); public domain (NASA) |
| `water/` | `surf_loop` (a seamless loop, mono: a 3D source at the shore), `splash_1..3` | real recordings, cut and levelled by `tools/build_weather_audio.py` (table below) | CC0 (freesound.org) |
| `ambience/` | `wind_low`, `wind_gust` (seamless loops) | synthesized by `tools/gen_soundscape_audio.py` | the project's own |
| `ambience/` | `underwater` (a seamless loop) | a real recording, `tools/build_weather_audio.py` (table below) | CC0 (freesound.org) |
| `music/` | `drift`, `far_shore`, `low_orbit` (calm pad pieces, faded both ends) | synthesized by `tools/gen_soundscape_audio.py` | the project's own |
| `sfx/` | `swim_stroke_1..4`, `bubbles_1..3`, `vessel_lost` | synthesized by `tools/gen_soundscape_audio.py` | the project's own |
| `sfx/` | `surveyor_charge`, `surveyor_ready` (a seamless loop), `surveyor_fire`, `surveyor_hit`, `crew_hit` — the TL-5 Surveyor plasma rifle and the crew's HIT warning | synthesized by `tools/gen_weapon_audio.py` | the project's own |
| `weather/` | `rain_light`, `rain_heavy`, `hail` (seamless loops), `thunder_1..3` | real recordings, cut and levelled by `tools/build_weather_audio.py` (table below) | CC0 (freesound.org) |
| `weather/` | `dust` (a seamless loop) | synthesized by `tools/gen_weather_audio.py` (every CC0 "sandstorm" found was itself a synthetic mix) | the project's own |
| `foley/` | `laser_hiss`, `laser_crackle`, `laser_rumble` (seamless loops): the Terrain Laser's bite | real recordings, cut and levelled by `tools/build_grit_audio.py` (table below) | CC0 (freesound.org) |
| `ambience/` | `cave_tone` (seamless loop), `cave_drip_1..6`: underground.lua | real recordings in caves, cut and levelled by `tools/build_cave_audio.py` (table below) | CC0 (freesound.org) |
| `ambience/` | `cave_creak_1..3`, `cave_groan_1..2` (mono: 3D sources on the rock): underground.lua | real recordings, `tools/build_grit_audio.py` (table below) | CC0 (freesound.org) |
| `ambience/` | `cave_vent`, `cave_rumble`, `cave_water_far` (seamless loops), `cave_ice_crack_1..3` (mono): the cave kinds, underground.lua | real recordings, `tools/build_cave_audio.py` (the kinds' table below) | CC0 (freesound.org) |
| `sfx/` | `breath_calm`, `breath_heavy`, `suit_hum` (seamless loops): the suit, soundscape.lua | real recordings, `tools/build_grit_audio.py` (table below) | CC0 (freesound.org) |

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

## audio/ambience — the cave, from real caves

Ty, 2026-11-10: the synthesised drip "sounds like a really resonant water drop … very synthesized;
I'd rather you find real sound effects". Both sources are CC0 1.0 (the licence was read on each
sound's page, 2026-11-10). The originals need a freesound login; `tools/build_cave_audio.py` cuts
from their HQ previews (the curl lines are in its docstring). Rebuild with
`python3 tools/build_cave_audio.py <folder> --stats`.

| file(s) | source | licence | what it was |
|---|---|---|---|
| `cave_drip_1..6` (mono one-shots, played as 3D sources where each drop lands) | "Drops in the small cave" by Selector, https://freesound.org/people/Selector/sounds/402929/ — drops at 14.6, 17.5, 20.9, 22.3, 74.3 and 110.7 s | CC0 1.0 | water dripping in the Ledyanaya cave near Staritsa, Russia (Zoom H6, XYH-6, 48 kHz) |
| `cave_tone` (30 s loop) | "INT Cave Room tone.wav", https://freesound.org/people/deleted_user_2104797/sounds/164785/ — 40–74 s, 35 Hz–7 kHz | CC0 1.0 | the room tone of a cave in Kent, England (mono, directional) |

Levels (`--stats`, ffmpeg `ebur128`): the drops peak −3.7 to −5.2 dBFS (the script sets each
drop's level and the engine's distance falloff does the rest); `cave_tone` −35 LUFS, peak
−12.7 dBFS (the synthesised one was −33 LUFS, −16 dBFS). Seen and not used: "Many drops of water
in a big cave" (nomadas, #609161, CC0) — real, but its drops sit 15 dB over a busy floor, too
close together to cut one clean; "Water Dripping in Cave" (#177958) and "Water Dripping (Large
Echo)" (#162116) are effected or made in a DAW.

### The cave kinds (worlds W4, 2026-11-10)

Ty: "make more scary feeling and unique caves." Each kind (scripts/cave_kinds.lua) has its own
bed or one-shots, all real recordings, CC0 1.0 (the licence was read on each sound's page,
2026-11-10). Same tool, same HQ previews (curl lines in its docstring). A rebuild rewrites the
older files' bytes too (Vorbis stamps a random stream serial), with the same sound.

| file(s) | source | licence | processing | used by |
|---|---|---|---|---|
| `cave_vent` (13 s loop) | "Bubbling Mud with Steam" by ProductionNow, https://freesound.org/people/ProductionNow/sounds/352904/ — the Artist Paintpots, Yellowstone: steam hissing from the ground and spitting mud holes, 0–14.5 s | CC0 1.0 | 60 Hz–9 kHz, 1.5 s crossfade, −30.9 LUFS, peak −6.8 dBFS | sulfur vents |
| `cave_rumble` (28 s loop) | "Rocket Launch Rumble (Geofon recording)" by felix.blume, https://freesound.org/people/felix.blume/sounds/613617/ — the ground through a geophone, 70–100 s (laser_rumble uses 14–27 s) | CC0 1.0 | 20–160 Hz, 2 s crossfade, −32 LUFS | lava tubes |
| `cave_water_far` (18 s loop) | "Water Flowing into Underground Sinkhole" by hinchinbrook, https://freesound.org/people/hinchinbrook/sounds/552485/ — a stream running into a sinkhole, with the chamber's bass, 2–22 s | CC0 1.0 | 40 Hz–6 kHz, 2 s crossfade, −33 LUFS | deep chasms |
| `cave_ice_crack_1..2` (mono) | "Ice cracking_northern87" by northern87, https://freesound.org/people/northern87/sounds/369982/ — cracks at 9.18 and 32.81 s (Oktava MK-012) | CC0 1.0 | above 150 Hz, peak −3.8 dBFS | ice caves (3D, in the walls) |
| `cave_ice_crack_3` (mono) | "ice_cracking_01.flac" by Mooe, https://freesound.org/people/Mooe/sounds/169897/ — a run of cracks at 8.30 s (Zoom H2N) | CC0 1.0 | above 150 Hz, peak −3.0 dBFS | ice caves |

The collapse sink's wind is `wind_low` (above). Seen and not used: "Hot Bubbling Mud" (Breviceps
#456806, CC0: mud alone, no steam), "Mud Volcano Field - Salton Sea" (RTB45 #415608, CC0: good,
but 4 minutes for a 13 s bed), "Small cave river flow" (Duasun #462661, CC0: too near and bright
for "far below"); the lava-tube recordings found (Thurston, Ape Cave, Golden Dome) are CC BY or
BY-NC, and the ice-cave walk (#530747) is CC BY with tourists in it.

## The laser, the cave's creaks and groans, the suit, the weather and the sea, from real recordings

Ty, 2026-11-10: "I'd rather you try and find real sound effects instead of synthesizing ones,
especially more complex ones." Everything `tools/gen_grit_audio.py` made (deleted), the rain, hail
and thunder of `tools/gen_weather_audio.py` and the sea of `tools/gen_surf_audio.py` (deleted) are
cut from field recordings, and so is the sea heard from inside it (`gen_soundscape_audio.py`
no longer writes `underwater`). All are CC0 1.0: the licence was read on each sound's page on
2026-11-10. The originals need a freesound login, so the scripts cut from the HQ previews (the
same recordings, 128 kb/s MP3; the curl lines are in each script's docstring). Rebuild with
`python3 tools/build_grit_audio.py <folder> --stats` and `python3 tools/build_weather_audio.py
<folder> --stats`. Every file keeps its name and its integrated loudness (ffmpeg `ebur128`), so
the game's gains are unchanged; the numbers before and after are in the table.

| file(s) | source | licence | processing | loudness before → after |
|---|---|---|---|---|
| `foley/laser_hiss` (12 s loop) | "Plasma Cutter 01" by C-V, https://freesound.org/people/C-V/sounds/733483/ — a plasma cutter cutting sheet metal, 30–43 s | CC0 1.0 | 300 Hz–8 kHz, 1 s crossfade | −23.8 → −23.8 LUFS |
| `foley/laser_crackle` (12 s loop) | "welder sparks good detail2 long straight weld" by kyles, https://freesound.org/people/kyles/sounds/453690/ — 8.5–21.5 s | CC0 1.0 | 700 Hz–9 kHz | −25.0 → −25.0 LUFS |
| `foley/laser_rumble` (12 s loop) | "Rocket Launch Rumble (Geofon recording)" by felix.blume, https://freesound.org/people/felix.blume/sounds/613617/ — the ground 20 km from Cape Canaveral through a geophone, 14–27 s; with "STONEMILL1" by Nordliecht, https://freesound.org/people/Nordliecht/sounds/850191/ — a granite saw, 10–23 s | CC0 1.0 | geophone 22–160 Hz (its slow fade evened), saw 200–900 Hz at half its level | −28.0 → −28.0 LUFS |
| `ambience/cave_creak_1..3` (mono) | "R22-45-Big Wood Creaks" by craigsmith, https://freesound.org/people/craigsmith/sounds/481892/ — single creaks at 84.25, 38.35, 48.15 s | CC0 1.0 | 250 Hz–3.5 kHz, played at 0.70 / 0.62 / 0.72× (a bigger beam) | −23.7 → −23.7 LUFS |
| `ambience/cave_groan_1` (mono) | "rumbling_ice" by aerror, https://freesound.org/people/aerror/sounds/847807/ — lake ice rumbling, 33.9–37.7 s; grit from "Gravel Impacts and Falls" by lolamadeus, https://freesound.org/people/lolamadeus/sounds/179341/ (3.4–4.9 s) | CC0 1.0 | ice 20–700 Hz with a swell envelope, the trickle above 900 Hz after it | −24.6 → −24.5 LUFS |
| `ambience/cave_groan_2` (mono) | the geophone above, 41–45.2 s; grit from the gravel (8.05–9.05 s) | CC0 1.0 | 20–220 Hz, the same | −24.5 → −24.5 LUFS |
| `sfx/breath_calm` (12.4 s loop) | "Mask breathing 1" by Diramus, https://freesound.org/people/Diramus/sounds/426297/ — breathing through an ABC respirator mask, 3.58–15.97 s (two breaths) | CC0 1.0 | 90 Hz–6 kHz, the seam in a pause | −29.1 → −29.1 LUFS |
| `sfx/breath_heavy` (9.7 s loop) | "Mask Breathing Sound" by Kodack, https://freesound.org/people/Kodack/sounds/256519/ — breathing in a heavy mask (Sony HDR-PJ260V, edited by the author), 3.0–12.72 s (three breaths) | CC0 1.0 | above 90 Hz, the seam in a pause | −27.2 → −27.2 LUFS |
| `sfx/suit_hum` (10 s loop) | "Quiet Computer Fan" by EagleStealthTeam, https://freesound.org/people/EagleStealthTeam/sounds/165530/ — 2–13 s | CC0 1.0 | 60 Hz–6 kHz | −34.6 → −34.6 LUFS, peak −12 dBFS |
| `weather/rain_light` (30 s loop) | "Rain light 2 (rural)" by jmbphilmes, https://freesound.org/people/jmbphilmes/sounds/200273/ — mono, open land in Brazil | CC0 1.0 | left 2–34 s, right 48–80 s (wide, uncorrelated stereo), above 80 Hz | −28.1 → −28.1 LUFS |
| `weather/rain_heavy` (30 s loop) | "Rain heavy 2 (rural)" by jmbphilmes, https://freesound.org/people/jmbphilmes/sounds/200272/ | CC0 1.0 | left 1–33 s, right 10–42 s (the thunderclap at 44 s left out) | −24.2 → −24.2 LUFS |
| `weather/hail` (30 s loop) | "hail in the city.wav" by misternormmedia, https://freesound.org/people/misternormmedia/sounds/685618/ — hail on a balcony's rails and concrete, 6–38 s | CC0 1.0 | above 80 Hz | −26.0 → −26.0 LUFS |
| `weather/thunder_1..3` | "THREE MIGHTY THUNDERS IN ROW" by Nimlos, https://freesound.org/people/Nimlos/sounds/522025/ — the strikes at 28, 61 and 96 s | CC0 1.0 | 10 s each from 0.5 s before the crack, 2.5 s fade, peak −1.5 dBFS | −18.9 / −23.0 / −17.2 → −22.7 / −23.0 / −21.2 LUFS (a real strike's peak is higher over its body; the peak limit sets 1 and 3) |
| `water/surf_loop` (26 s loop, mono) | "Ocean_coast_04_092025_0659AM" by YevgVerh, https://freesound.org/people/YevgVerh/sounds/827530/ — light waves on the Outer Banks, 38.45–64.60 s | CC0 1.0 | above 40 Hz, seam in a lull | −19.0 → −19.0 LUFS |
| `ambience/underwater` (16.9 s loop) | "Sea waves underwater, back and forth, close to the rocks with water bubbles" by felix.blume, https://freesound.org/people/felix.blume/sounds/705058/ — Ilo harbour, Peru, 4.60–21.48 s | CC0 1.0 | above 20 Hz, seam in a lull | −29.0 → −28.9 LUFS |
| `water/splash_1..3` (mono) | "Rocks Thrown in Water" by Kraftaggregat, https://freesound.org/people/Kraftaggregat/sounds/737644/ — splashes at 0.03, 4.85, 7.72 s | CC0 1.0 | 1.6 s each, above 60 Hz, peak −1 dBFS | −19.1 / −20.7 / −20.3 → −22.5 / −20.6 / −20.3 LUFS |

Seen and not used: plasma cutter #395890 (jokallset; fine, but the C-V cut is longer and
steadier); "Plasma cutting torch" #211949 (re-processed from a video); arc welders #256915,
#438496 (more buzz than crackle), "MIG Welding" #264827 (synthesised in LMMS); granite saw used
alone for the rumble (too high: it is the grind on top); wood creaks #397620 (clipped), #590171,
#450381 (a shutter: thin); "Rocks Crumbling from room or cave" #155934 (beads and plastic with
reverb); gas masks #435825, #718626, #571004 (valve clicks, or one breath); "heavy breathing
while running" #456037 (outdoors, wind, no mask); fans #234916 (a narrow chuff), #396963 (speed
changes); "Underwater recording of aquatic movement, bubbles and drops" #384218 (felix.blume, the
right sounds for the swim strokes and bubbles, but the loud parts clip on the hydrophone);
"SandstormMix" #565015 and every other CC0 sandstorm (synthetic mixes, as their pages
say).

## audio/incoming/

Drop sounds found by hand here (see audio/incoming/README.md for the list the game wants).

- `foley/engine_four.ogg`, `foley/engine_two.ogg` — the gas engines' running
  loops (a four-stroke and a two-stroke single at 3000 rpm), synthesised by
  `tools/gen_engine_audio.py`; no recorded source.
