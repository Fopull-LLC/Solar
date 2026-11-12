# Sound shopping list (for Ty)

These are the sounds the 2026-11-12 pass could not find as CC0 recordings good enough to ship. The
pass found the impacts, the failures and the footsteps; see `docs/sound-design.md` for what changed,
and `audio/SOURCES.md` for every source.

**How to hand them over:** drop each file in `audio/incoming/` as `.wav` or `.flac` (any rate, any
channels). Name it after its slot below, and put a `.txt` beside it with the page URL and the licence.
I cut, level and wire them in.

- **Licence.** Only CC0 or public domain goes in git (the repo is public).
- **Royalty-free packs** (Sonniss GDC bundles, paid libraries) are fine to use but stay local and out
  of git. Put them in `audio/incoming/local/`, which is git-ignored, and say so in the `.txt`.
- **Where to look.** freesound.org filtered to CC0:
  `https://freesound.org/search/?q=<terms>&f=license:%22Creative+Commons+0%22` (downloads need a free
  login). Also the Sonniss "GameAudioGDC" bundles (https://sonniss.com/gameaudiogdc, royalty-free,
  many GB, local only), BigSoundBank (CC0) and NASA audio (public domain).

## Most wanted: the remaining misfits in the game today

| slot | what it should sound like | search terms (freesound CC0 first, then Sonniss) | replaces |
|---|---|---|---|
| `decouple_1..3` | a pyrotechnic bolt or separation nut firing: a sharp metallic crack with a short ring, no gunshot boom | "pyrotechnic bolt", "explosive bolt", "separation nut", "metal slam large", "shipping container door slam" | staging and decouplers (now a bird-scaring gas gun) |
| `booster_sep_1..2` | the same, heavier and further off: a thud and a clank | "heavy metal slam distant", "steel door slam exterior" | booster separation (the gun, far away) |
| `chute_deploy` | a mortar's thump, then a canopy snapping full | "parachute deploy", "parachute opening", "sail snap", "tarp snap wind" | the parachute (now a brake-release hiss) |
| `gear_hydraulic` | a hydraulic ram: pump whine, the ram moving, a clunk at the end of its stroke | "hydraulic actuator", "excavator hydraulics", "hydraulic press", "tail lift truck" | landing gear (now a car-window motor) |
| `explosion_close_1..3` | a real close explosion, outdoors: a fuel tank or a gas cylinder going up | "explosion close real", "propane tank explosion", "gas cylinder explosion", "car explosion" (Sonniss has several) | explosive parts. Now a distant dynamite blast plus the bird-scarer bang; every CC0 "explosion" I checked was synthesised or a firework |
| `body_hit_1..4` | a real body blow: a heavy padded impact on a person, no voice | "punch body heavy", "body hit thud", "tackle impact", "sandbag punch" | `sfx/crew_hit` (synthesised): crew struck by a bolt or debris |
| `hull_burst_1..2` | a pressure vessel or tyre bursting: a sharp bang, then a rush of air | "tire blowout", "tyre burst", "pressure vessel burst", "air tank burst" | the breach's front edge (now a dull metal boom with a short air burst under it) |
| `metal_tear_1..4` | sheet metal tearing slowly or a bolt shearing: a screech and a snap | "metal tear", "sheet metal rip", "bolt shear", "metal stress creak snap" | adds a second source to `part_break` (one wreck recording today) |
| `flare_ignite` | a road flare struck and lighting: a scratch, a fizz, a steady hiss | "road flare ignite", "flare strike", "fusee" | a cave flare lit (now a switch at 0.6×) |
| `suit_alarm` | a real master-alarm tone from a cockpit or an industrial panel, two or three pulses, recorded through a speaker (not synthesised) | "cockpit master caution", "aircraft warning tone", "industrial panel alarm beep" | the crew's alarm, chime and alarm loop (synthesised) |
| `reentry_roar` | wind or flame roar at very high speed: a jet's afterburner pass, or wind in a car at 200 km/h with the window open | "jet flyby afterburner", "wind roar car window open highway", "rocket sled" | re-entry (now synthesised wind) |
| `boot_slide_1..2` | a boot sliding on gravel for about half a second | "slide gravel foot", "skid gravel shoe" | the slide (now a soft thud) |
| `backpack_buckle` | a heavy backpack's buckle clicking shut, or velcro | "backpack buckle", "velcro rip short", "bag zipper heavy" | the bag closing (now a metal plate tap) |

## Already asked, still missing (audio/incoming/README.md)

`suit_breath_1..4` (a closed-helmet regulator), `rover_drive_1..2` (an electric off-road vehicle on
board), `regolith_step_1..6` (now covered by the grit steps; a heavier boot is still welcome),
`pack_open`/`pack_close`, `rcs_puff_1..3` (cold-gas bursts), `capcom_loop` (mission-control
background).

## Nice to have: more takes for banks that have only one or two

| bank | has | wanted | search terms |
|---|---|---|---|
| `explode` | 1 (dynamite, distant) | 3 to 4 more | see `explosion_close` above |
| `suit_fall` | 1 real body fall | 3 more: a person in heavy gear falling on dirt and rock | "body fall gravel", "body fall dirt heavy gear" |
| `metal_rock` | 3 (one session) | 3 more: a steel frame or vehicle hitting rock | "metal hit rock", "car hits rock", "skid plate rock" |
| `glass_break` | 2 | 2 more: a thick pane or a visor | "window break thick", "safety glass break", "plexiglass crack" |
| `step_metal` | 6, one stair | 6 on a flat steel deck in heavy boots | "boots metal deck", "footsteps ship deck steel" |
| `step_snow` | 6 (a noisy recording) | 6 clean takes | "snow footsteps close", "snow crunch boots" |
| `zap` | 5, from one arc | 3 from a real short circuit (a fault, not a welder) | "short circuit spark", "breaker arc flash", "power line arc" |
