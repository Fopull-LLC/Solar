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
| `ambience/` | `cave_crack`, `cave_tick_1..3`, `cave_trickle`, `cave_rockfall_1..2`, `cave_slab_hit_1..2`, `cave_gas_whump` (mono one-shots: 3D sources on the rock): the cave hazards, cave_hazards.lua | real recordings, `tools/build_hazard_audio.py` (the hazards' table below) | CC0 (freesound.org) |
| (reused) | a loaded Build Kit piece (kit_load.lua, progression W2): over 0.7 of its capacity a timber piece creaks with `ambience/cave_creak_1..3` (craigsmith's "Big Wood Creaks", a real timber, played at 0.62–0.74×) and a steel one groans with `ambience/cave_groan_1..2`; while it gives, `kenney/impact/impactWood_light_000/002/004` tick as splinters; it breaks with `kenney/impact/impactWood_heavy_001/003` and a creak at 0.5× | the recordings above (no new files) | CC0 |
| `sfx/` | `breath_calm`, `breath_heavy`, `suit_hum` (seamless loops): the suit, soundscape.lua | real recordings, `tools/build_grit_audio.py` (table below) | CC0 (freesound.org) |
| `foley/` | `leak_hiss` (a seamless mono loop: a 3D source on a craft part with a hole, cabin_air.lua, G1) | a real recording, cut by hand with ffmpeg (section below) | CC0 (freesound.org) |
| `plant/` | `alarm_klaxon`, `alarm_buzzer`, `pump_motor`, `pump_whine`, `turbine_whine`, `transformer_hum`, `steam_leak`, `bearing_rattle`, `fan_loop`, `crusher_loop`, `furnace_roar`, `vent_roar` (seamless mono loops), `relief_valve`, `airlock_chime` (mono one-shots): airlocks, alarms and machinery, 3D sources in the base | real recordings, cut and levelled by `tools/build_plant_audio.py` (section below) | CC0 (freesound.org) |
| `impact/` | impacts by material pair and weight (`metal_light/dull/rock/metal/heavy`, `crash`, `soil_light/heavy`, `rock_light/soil`, `glass_knock/break`, `plastic`, `tyre`, `suit_fall`), failures (`part_break`, `scrape`, `explode`, `zap`, `fire_flare`, `breach`, `visor_crack`), footsteps by surface (`step_grit/soil/sand/snow/metal`), loops `fire_loop`, `arc_loop`: scripts/sfx.lua's banks | real recordings, cut and levelled by `tools/build_impact_audio.py` (section at the end) | CC0 (freesound.org) |

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

### The cave hazards (worlds W5, 2026-11-10)

A rockfall is telegraphed by a crack at the roof, grit pattering down through 1.5 s of dust, then
the slabs; an unstable roof ticks before it goes; a methane pocket lit by the laser goes off with a
whump (scripts/cave_hazards.lua). All real recordings, CC0 1.0 (the licence read on each sound's
page, 2026-11-10), cut by `tools/build_hazard_audio.py` from the HQ previews (curl lines in its
docstring). Mono 44.1 kHz, peaks set per cut; checked by numbers (`--stats`), never played aloud.

| file(s) | source | licence | processing | used by |
|---|---|---|---|---|
| `cave_crack` (2.2 s) | "stone falls and breaks low pitch.aiff" by SoundCollectah, https://freesound.org/people/SoundCollectah/sounds/109360/ — a stone landing and breaking into pieces, 0–2.2 s | CC0 1.0 | above 60 Hz, peak −2.9 dBFS; played at 0.78–0.88× (a bigger slab letting go) | the rockfall's warning, at the roof |
| `cave_tick_1..3` | "RockCrack03" by falcospizaetus, https://freesound.org/people/falcospizaetus/sounds/489905/ — cracks appearing in a rock, at 0.84, 1.72 and 2.02 s | CC0 1.0 | above 600 Hz (the room's hum off), peak −7 dBFS | an unstable roof, every 3–8 s |
| `cave_trickle` (3 s) | "20120808_064004 Cathedral Mountain rock slide, slow blocky chunks.wav" by betchkal, https://freesound.org/people/betchkal/sounds/500638/ — a small slide in Denali, separate pops, 7.5–10.5 s | CC0 1.0 | above 150 Hz, peak −4.9 dBFS | grit sifting down with the dust |
| `cave_rockfall_1..2` | "rockfall2a.wav" by AlanCat, https://freesound.org/people/AlanCat/sounds/389303/ — rocks falling down a cliff and a cascade after (Olympus LS-14), 0.5–4.5 and 6.9–10.5 s | CC0 1.0 | above 40 Hz, peak −2.4 dBFS | the slabs coming down |
| `cave_slab_hit_1..2` | "RockFall1b.wav" by AlanCat, https://freesound.org/people/AlanCat/sounds/381645/ — small boulders crashing and rolling down a short slope, 0.25–2.25 and 20.0–21.8 s | CC0 1.0 | above 40 Hz, peak −2.4 dBFS | a slab landing, or hitting the crew |
| `cave_gas_whump` (0.7 s) | "gasExplosion.wav" by Zabuhailo, https://freesound.org/people/Zabuhailo/sounds/145400/ — an old gas stove's accumulated gas going off | CC0 1.0 | above 30 Hz, peak −2.5 dBFS; played at 0.62× under `foley/explosion_far` | firedamp lit by the laser |

Seen and not used: "Cracking Earthquake" (uagadugu #222521, CC0: a processed mix), "breaking_concrete"
(zatar #755522, CC0: itself a mix of other sounds), "Rock destroy" (Bertsz #524312: a game effect).

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

## audio/foley/leak_hiss — a hull leak (cabin_air.lua, G1, 2026-11-10)

| file | source | licence | processing | loudness |
|---|---|---|---|---|
| `foley/leak_hiss` (6.5 s mono loop) | "FOL-gas-leak-02.wav" by henrikcederblad, https://freesound.org/people/henrikcederblad/sounds/615667/ — a foley recording of gas leaking, steady, 44.1 kHz (the author relicensed it CC0; the licence was read on the page, 2026-11-10) | CC0 1.0 | the HQ preview (`https://cdn.freesound.org/previews/615/615667_1819746-hq.mp3`), mono, 180 Hz–10 kHz, 0.4–7.4 s, the last 0.5 s crossfaded into the first (qsin), +9.7 dB | −33.7 → −24.1 LUFS, peak −10.6 dBFS; half-second RMS −23.6 to −24.5 dB through the seam |

Rebuild: `ffmpeg -i fs_615667.mp3 -filter_complex "[0:a]aresample=44100,pan=mono|c0=0.5*c0+0.5*c1,highpass=f=180,lowpass=f=10000,atrim=0.4:7.4,asetpts=PTS-STARTPTS,asplit=2[a][b];[a]atrim=0.5:7.0,asetpts=PTS-STARTPTS[body];[b]atrim=0:0.5,asetpts=PTS-STARTPTS[head];[body][head]acrossfade=d=0.5:c1=qsin:c2=qsin[o]" -map "[o]" leak_raw.wav`, then `ffmpeg -i leak_raw.wav -af volume=9.7dB -c:a libvorbis -q:a 5 leak_hiss.ogg`.
Seen and not used: "MrM_Gas_Steam_Escape.wav" #182359 (an air duster, CC0: bursts, not a steady leak); "Air Hiss" #367125 (2 s); "R17-35-Steam or Compressed Air" #479292 (an optical-track transfer with its noise); "Compressed Gas Leak SFX" on OpenGameArt (synthesised white noise).

## audio/plant — airlocks, alarms and machinery (2026-11-11)

All mono 44.1 kHz Ogg Vorbis q5 (3D sources in the base), cut from the HQ previews
(`https://cdn.freesound.org/previews/…-hq.mp3`; the curl lines are in the docstring of
`tools/build_plant_audio.py`). Every licence is CC0 1.0, read on the sound's own page on
2026-11-11, and every description was read to make sure it is a recording of the real thing.
Channels are averaged to mono (the quarry's M/S pair sums to its mid). Loops: the crossfade's
worth after the loop's end is faded into its head (equal power); "seam" is the half-second RMS
just before / across / just after the loop point, with the loop's own range of half-second RMS
in brackets. Loudness is the mono cut before levelling → the file (ffmpeg `ebur128=peak=true`);
every true peak is under −1 dBFS (−6.1 dBFS at most), so no file was held below its target.

| file | source | what it was | licence | processing | loudness |
|---|---|---|---|---|---|
| `plant/alarm_klaxon` (4.4 s loop) | "Submarine submersion alarm_mono_wave.wav" by Guialgarve, https://freesound.org/people/Guialgarve/sounds/480898/ | the dive alarm of an old Brazilian submarine, recorded aboard | CC0 1.0 | 150 Hz–9 kHz, 7.90–12.30 s (one 3 s blast and the gap after it), 0.2 s crossfade inside the gap; seam −54.9/−56.3/−55.9 dB (the gap's floor) | −15.2 → −20.0 LUFS, true peak −9.1 dBFS |
| `plant/alarm_buzzer` (4 s loop) | "G20-24-Fire Alarm.wav" by craigsmith, https://freesound.org/people/craigsmith/sounds/438239/ | a fire alarm bell, long steady mechanical ringing with a slight buzz | CC0 1.0 | 300 Hz–12 kHz, 8–12 s, 0.5 s crossfade; seam −24.0/−24.1/−24.1 dB (−24.1 to −22.0) | −29.5 → −20.0 LUFS, −10.0 dBFS |
| `plant/pump_motor` (10 s loop) | "20121228 kijjaz - Swimming Pool Pump 02.flac" by kijjaz, https://freesound.org/people/kijjaz/sounds/172603/ | a swimming pool's electric water pump running (Zoom H1) | CC0 1.0 | 60 Hz–9 kHz, 1–11 s, 1 s crossfade; seam −24.3/−24.0/−24.0 dB (−24.7 to −23.1) | −15.3 → −24.0 LUFS, −9.7 dBFS |
| `plant/pump_whine` (10 s loop) | "motor turbine loud mono.flac" by kyles, https://freesound.org/people/kyles/sounds/637714/ | an electric motor-driven turbine (a blower), a steady whine at 1.0 kHz over a 236 Hz body | CC0 1.0 | 80 Hz–10 kHz, 0.5–10.5 s (before the whine steps up to 1.36 kHz at 13 s), 1 s crossfade; seam −25.1/−25.6/−25.0 dB (−26.1 to −23.3) | −9.8 → −24.0 LUFS, −13.5 dBFS |
| `plant/turbine_whine` (10 s loop) | "S28-19 Engine room; high whine from turbines.wav" by craigsmith, https://freesound.org/people/craigsmith/sounds/675727/ | a ship's engine room, the turbines' high whine with the room's body under it | CC0 1.0 | 50 Hz–10 kHz, 3–13 s, 1 s crossfade; seam −25.1/−24.9/−24.9 dB (−25.6 to −24.2) | −24.0 → −24.0 LUFS, −11.6 dBFS |
| `plant/transformer_hum` (10 s loop) | "hum electric transformer in large room2.flac" by kyles, https://freesound.org/people/kyles/sounds/453445/ | an electrical transformer humming in a large room (60 Hz mains: lines at 360 and 720 Hz) | CC0 1.0 | 50 Hz–6 kHz, 6–16 s, 1 s crossfade; seam −23.5/−23.7/−23.8 dB (−23.9 to −23.2) | −22.2 → −24.0 LUFS, −11.2 dBFS |
| `plant/steam_leak` (7 s loop) | "d_s478_idlesteamhiss.wav" by relwin, https://freesound.org/people/relwin/sounds/686057/ | steam locomotive 478 idling; from 23 s a valve stands open and steam roars out steadily | CC0 1.0 | 300 Hz–15 kHz, 24–31 s (after the whistle; peaks there −0.9 dBFS, unclipped), 1 s crossfade; seam −27.6/−27.3/−27.4 dB (−27.6 to −27.0) | −7.9 → −24.0 LUFS, −13.9 dBFS |
| `plant/bearing_rattle` (8 s loop) | "MACHFan_industrial_fan_defect_bearing_rough_noise_Olympus_LS-P4.wav" by DBS_Sounds, https://freesound.org/people/DBS_Sounds/sounds/613157/ | an industrial fan with a broken bearing, a rough grinding run | CC0 1.0 | 50 Hz–10 kHz, 4–12 s, 1 s crossfade; seam −24.1/−23.8/−23.6 dB (−24.3 to −23.6) | −16.8 → −24.0 LUFS, −11.3 dBFS |
| `plant/fan_loop` (10 s loop) | "Noisy Fan.wav" by Beethovenboy, https://freesound.org/people/Beethovenboy/sounds/384335/ | a large industrial fan in a powder-coating warehouse (blade tone 247 Hz) | CC0 1.0 | 40 Hz–8 kHz, 3–13 s, 1 s crossfade; seam −23.3/−23.1/−23.3 dB (−24.0 to −22.5) | −23.1 → −24.0 LUFS, −9.8 dBFS |
| `plant/crusher_loop` (12 s loop) | "quarry_close_up.aif" by f_ilippo, https://freesound.org/people/f_ilippo/sounds/59244/ | the machine breaking rocks into gravel and sand at a quarry on the Sava near Belgrade (Schoeps M/S, recorded for the film "Tranzit") | CC0 1.0 | 35 Hz–10 kHz, 2–14 s, 1 s crossfade; seam −23.9/−23.6/−23.3 dB (−24.9 to −22.9) | −19.9 → −24.0 LUFS, −10.2 dBFS |
| `plant/furnace_roar` (10 s loop) | "Gas Forge" by SoundDesigner0101, https://freesound.org/people/SoundDesigner0101/sounds/765947/ | a gas forge burning | CC0 1.0 | 40 Hz–10 kHz, 3–13 s, 1 s crossfade; seam −22.3/−22.3/−23.5 dB (−24.6 to −22.3) | −22.1 → −24.0 LUFS, −11.3 dBFS |
| `plant/vent_roar` (7 s loop) | "air compressor hose" by mycompasstv, https://freesound.org/people/mycompasstv/sounds/708043/ | air rushing out of an industrial compressor's jackhammer hose, the hose whistling near 790 Hz | CC0 1.0 | 120 Hz–14 kHz, 0.8–7.8 s (the full-bore release, before it is throttled at 10 s), 1 s crossfade; seam −26.3/−26.3/−26.2 dB (−27.3 to −25.9) | −13.6 → −24.0 LUFS, −12.5 dBFS |
| `plant/relief_valve` (4 s one-shot) | "steam_safety_valve.wav" by Engineer_815, https://freesound.org/people/Engineer_815/sounds/493558/ | the safety valve of an industrial 1000 hp boiler lifting at high pressure (Samsung S9) | CC0 1.0 | 120 Hz–14 kHz, 1.35–5.35 s (the lift and the blow), 10 ms in, 0.6 s fade out | −14.1 → −20.0 LUFS, −6.1 dBFS |
| `plant/airlock_chime` (1.9 s one-shot) | "service bell ring" by AlaskaRobotics, https://freesound.org/people/AlaskaRobotics/sounds/221515/ | one sustained ring of a metal service bell (Marantz PMD660, Roland DR-20) | CC0 1.0 | 200 Hz–14 kHz, 0.15–2.05 s (the strike and its ring), 2 ms in, 0.5 s fade out | −20.6 → −20.0 LUFS, −6.7 dBFS |

Rebuild: fetch the previews into one folder, then `python3 tools/build_plant_audio.py <folder> --stats`
(`--source` also prints each cut's loudness before levelling).

Seen and not used: klaxons — "Klaxon off axis long.wav" #514983 (jameswrowles, a real HEK E/75
hooter, but one unbroken tone, not a repeating alarm), "General Fusion industrial workshop factory
warning alarm" #450130 (kyles; voices over it), "G45-15-Hornlike Sub Alarm" #438717 (quiet, interior
noise), "dive.wav" #156672 (4.5 s), "Red Alert Klaxon Re-Creation" #125714 (a processed square
wave), "16 bit Klaxon / Alarm Synth Loop" #808538, "Industrial Alarm" #558242, "Alarm No. 2" #345814
and the BeepBox alarms #686859–686861 (all synthesised, as their pages say); bells — "Bell better
mic off axis2" #323238 (an under-dome bell, fine, but the fire bell is steadier), "Buzzer_Alarm.wav"
#524909 (clips); pumps — "motor water pump steady" #637715 (clipped), "Pump_engine.wav" #342414
(mostly water hiss), "pump steady" #568860 (a 100 Hz drone only), "Under Pump Room Nuclear Power
Plant" #362246 (a 75 Hz rumble, no whine), "pumps industrial in large room" #453508,
"electric_air_compressor_close_mono" #338970 (a piston chug), "dry_scroll_pump" #477409; turbines —
"motor industrial turbine large fan blades" #453476 (a low fan); transformers — "transformer-hum.aif"
#125168 (clipped hard), "EDF_Electrical_substation" #547900 (clean 100 Hz lines but 45 dB down);
steam — "R19-40-Steam Hiss" #479297 (fades after 4 s), "NYC steam radiator hiss" #265013 (thin),
"Train_steam_exhaust" #699758 and "d_s478_blowboiler" #686055 (both clip), "Compressed Air Pressure
Release Valve Loop (Synthetic)" #861613 (synthesised); bearings — "Faulty Extractor Fan" #828636 (a
100 Hz hum more than a rattle); fans — "Industrial fan 4" #319414, "room tone large industrial
ventilation fan" #453546; crushers — "stonemachine.wav" #243355 (a real stone crusher, but clipped
throughout); furnaces — "Furnace.WAV" #173991 (a gas bronze furnace, mostly its bellows' 100 Hz),
"oil gas furnace heater" #637734; vents — "DEFLATING TYRE" #457443 (thin, all above 8 kHz), "Fire
Extinguisher Spraying" #750166 (AI-generated, as its page says); chimes — "SILENCYO_DESKBELL" #148844
(room noise before the strike), "220516 desk bell rings" #717564. BigSoundBank's search page
refused the automated fetch, so nothing came from there this time.

## audio/impact — impacts, failures and footsteps (2026-11-12)

Ty, 2026-11-12: "impacts and damage sound odd because the same sound effect gets reused and doesn't
fit the context ... when something goes wrong it plays something like a can-drop sound." scripts/sfx.lua
picks a bank by what met what, the energy and the event (`impact`, `fail`, `step`); these are the banks.
Every source is a field or foley recording, CC0 1.0: the licence was read on each sound's page on
2026-11-12 (every page links creativecommons.org/publicdomain/zero/1.0/). The originals need a login,
so `tools/build_impact_audio.py` cuts from the HQ previews (the same recordings, 128 kb/s; the curl
line and the user ids are in its docstring). Mono 44.1 kHz Ogg Vorbis. The takes of a bank are set
to one level (loudest 50 ms RMS at the bank's peak − 9 dB, the peak held under it); checked by
numbers (`--stats`), never played aloud. Rebuild: `python3 tools/build_impact_audio.py <folder> --stats`.

| file(s) | source (freesound.org/s/<id>) | what it was | processing |
|---|---|---|---|
| `metal_light_1..2` | #669693 "deep knocks on metal" by vestibule-door | knuckle-deep knocks on a metal door | 0.42 s, above 50 Hz |
| `metal_light_3` | #640204 "Heavy Metal Thud on Ground" by 7of9Designs | a metal object thudding onto the ground | 0.55 s |
| `metal_light_4` | #489924 "MetalImpactAgainstRock07" by falcospizaetus | a small metal piece struck against rock | 0.25 s, above 80 Hz |
| `metal_dull_1..5` | #568816 "200822 Metallic thud, boom, dull, mono PEC" by TRP | dull heavy metal thuds and booms (takes at 7.3, 11.1, 18.2, 19.7, 24.4 s) | 1.5 s, above 35 Hz |
| `metal_dull_6` | #637988 "wheelbarrow put down on concrete floor metal hits impacts thuds" by kyles | a steel wheelbarrow set down hard (7.1 s) | 1.0 s |
| `metal_rock_1..3` | #675461 "S10-14 Heavy metal objets crashing on stone floor; 3 takes" by craigsmith | heavy metal objects crashing on a stone floor | 1.0 s each take |
| `metal_metal_1` | #859154 "Loud Bang Crashing Metal Chunk Dropped in Metal Dumpster" by qubodup | a metal chunk dropped into a steel dumpster | 1.0 s |
| `metal_metal_2..3` | #587442 "Dropping sheet metal" by SamsterBirdies | a sheet of steel dropped on concrete (2.9, 5.1 s) | 1.6 s |
| `metal_metal_4` | #109358 "rock lands on metal.aiff" by SoundCollectah | a rock landing on a metal sheet | 1.0 s |
| `metal_heavy_1..4`, `crash_3` | #587443 "Scrap metal dropping / crashing" by SamsterBirdies | a pile of scrap metal dropped onto concrete (6 takes) | 2.0–2.2 s |
| `crash_1`, `crash_2` | #703247 "Big falling debris (crash)", #703248 "Fall debris (crash)" by xkeril | tiles, stone and metal crashing onto concrete at a building site | 2.6 s |
| `part_break_1..5` | #451665 "school bus truck destroy crush smash ... metal bend wreck crunch with forklift" by kyles | a school bus wrecked by a forklift: metal bending, tearing and crunching (1.4, 7.6, 16.5, 49.2, 60.4 s; the low, bending crunches, not the window breaks) | 1.4 s, above 50 Hz |
| `scrape_1..5` | #383794 "Metal Scraping on Concrete" by deleted_user_7146007 | a metal piece dragged over concrete | 1.1 s, above 80 Hz |
| `explode_1` | #251401 "Dynamite explosion in the mountain" by felix.blume | a mining charge in the Bolivian mountains, the valley's echo after | 4.5 s, above 25 Hz; played at 0.9–1.1× under `foley/pyro_bang` |
| `soil_light_1..4` | #392008 "HEAVY BAG DROP DIRT.wav" by burbujafilms | a heavy bag dropped on dirt | 0.6 s |
| `soil_heavy_1..2` | #584891 "big log on dirt throwing.wav" by KrystianPawlowski | a big log thrown down on dirt | 0.9 s |
| `soil_heavy_3`, `suit_fall_1` | #504626 "BODY FALL - V HVY - DIRT" by leonelmail | a body falling heavily on dirt | 1.2 s |
| `rock_soil_1..4` | #369981 "Stone dropping to ground_northern87" by northern87 | stones dropped on the ground | 0.8 s |
| `rock_light_1..6` | #179365 "Small Rock and Stone Hits.wav" by lolamadeus | small rocks knocked together and dropped | 0.35 s, above 80 Hz |
| `glass_knock_1` | #418194 "Hard Glass Impact" by deleted_user_3656686 | a hard knock on glass | 0.45 s, above 120 Hz |
| `glass_break_1` | #212698 "Breaking a glass bottle" by dasebr | a bottle breaking | 1.0 s, above 150 Hz |
| `glass_break_2`, `visor_crack_1` | #806423 "Car windshield crack" by Sanderboah | a windscreen cracking | 1.3 s / 0.7 s (above 300 Hz) |
| `plastic_1..2` | #272065 "Thrown Object" by Bexhillcollege | a cassette and its case thrown at a wall | 0.25 s |
| `plastic_3..4` | #133978 "Item Falling (Plastic).mp3" by EchoCinematics | a plastic item falling | 0.5 s |
| `plastic_5` | #401773 "Plastic cup dropping" by oztrum | a plastic cup dropped | 0.5 s |
| `tyre_1..3` | #267921 "tire_thump.wav" by ChemiCatz | a tyre thumped on the ground | 0.7 s |
| `tyre_4..5` | #674021 "230104-013_normalized_tire_hit.wav" by mmmtoop | a tyre hit | 0.3 s |
| `zap_1..5`, `arc_loop` | #776446 "ELECArc_Electric arc hum and buzz" by pryanic | an electric arc buzzing; cuts where it strikes (77.5, 170.6 s), where it dies (75.2, 166.0 s) and a short burst (40 s); the loop from 120–124 s | above 200 Hz; the loop 0.5 s crossfade |
| `fire_flare`, `fire_loop` | #563765 "Fire Auto - car on fire" by florianreichelt | a car burning in Frankfurt | the flare 0–3 s (0.25 s in); the loop 2–14 s, 1.5 s crossfade |
| `breach_1..2` | #568816 (above) at 11.1 and 19.7 s, with #138477 "Air Burst" by JustInvoke under it at −3 dB | a hull plate going and a burst of air | 1.8 / 1.4 s |
| `step_grit_1..6` | #384082 "Foot_Step_grit_Sand.wav" by savataivanov | slow steps on grit | 0.36 s |
| `step_soil_1..6` | #352870 "Footsteps Dirt Gravel" by PotatokingXII | steps on dirt and fine gravel | 0.36 s |
| `step_sand_1..6` | #249933 "walking slow, walking fast and running on sand" by launemax | slow steps on sand | 0.40 s |
| `step_snow_1..6` | #453168 "footsteps in fresh snow" by florianreichelt | steps in fresh snow | 0.40 s |
| `step_metal_1..6` | #698697 "Footsteps on Metal" by IENBA | single boot steps on metal stairs | 0.45 s |

Reused, not new: wood impacts and wood, grass and concrete steps are Kenney's (`kenney/impact`, CC0);
`rock_heavy` is the cave's `cave_slab_hit_1..2`; the breach's and the suit's hiss are `foley/hiss_short`
and `hiss_cylinder`; a breaker's clack and a SCRAM's contactor are `foley/latch_clunk` and `clamp_clunk`.

Seen and not used: "Car accident. Real. Interior." #449062 (softwalls: real, but clipped hard), "Impact
on metal" #726486 (a −20 dB noise floor), "Metal & concrete.wav" #166118 (one long rumble), "Amp short
circuit 1.wav" #205879 (the amp's hum under every pop), "Electric zap.wav" #512471 (0.2 s of noise),
"Welding_Electric Sparks.wav" #396240 (welding, not a fault), "Cracking, snapping, and clanging (metal
can)" #518731 (a can: the very sound being replaced), "Scraping Stone" #321488 (an axe on a slab,
thin), "Metal Pipe Scraped on Concrete" #104361 (one scrape, mostly room), "footsteps on dirt" #264469
(sneakers, all above 5 kHz), "Footsteps On Metal" #834029 (light shoes on a thin plate: too small for
a suit's boot), "Gravel road walk" #274832 (steps overlap), "fire crackles" #563766 (a campfire).
