# audio/incoming — sounds found by hand, waiting to be wired in

Drop files here as `.wav`, `.flac` or `.ogg` (any rate or channel count; `tools/build_sfx.py`
cuts, levels and converts them). Name each one after its slot below, for example
`suit_breath_1.wav`, and put the page you got it from and its licence in a `.txt` beside it.
Only CC0, public-domain or royalty-free sounds that allow redistribution inside a game.

Where to look:
- freesound.org, filtered to CC0: `https://freesound.org/search/?q=<terms>&f=license:%22Creative+Commons+0%22`
  (downloading needs a free account, so these have to come by hand).
- Sonniss "GameAudioGDC" bundles, royalty-free and many GB: https://sonniss.com/gameaudiogdc
- NASA audio is public domain: https://www.nasa.gov/audio-and-ringtones/ and the NASA collections on
  archive.org (Apollo flight loops, mission-control chatter).

| slot | what it should sound like | search terms | how the game uses it |
|---|---|---|---|
| `suit_breath_1..4` | the crew breathing inside a closed helmet: a slow inhale through a demand regulator, a hiss, an exhale. Dry, close, without voice | "scuba regulator breathing", "gas mask breathing", "spacesuit breathing" | a quiet loop while the helmet is on, faster after a sprint or a jump |
| `rover_drive_1..2` | an electric off-road vehicle under load: a gearbox whine rising with speed, the tyres grinding on gravel or dry dirt, recorded on board, steady for at least 5 s | "electric ATV onboard", "golf cart gravel", "electric utility vehicle drive" | replaces `rover_motor` and `rover_gravel` (now a car-window motor and a mountain bike on gravel) |
| `regolith_step_1..6` | single slow boot steps on dry grit or crushed rock | "footstep gravel single", "boots crunch dry dirt" | the crew's footsteps off the base (now Kenney's concrete steps) |
| `pack_open`, `pack_close` | a heavy backpack's buckle, zip or velcro | "velcro rip", "backpack buckle", "zipper heavy" | the suit pack (the inventory) opening and closing |
| `chute_deploy` | a mortar's thump followed by a canopy snapping full | "parachute deploy", "sail snap", "tarp flap wind" | the parachute opening |
| `gear_hydraulic` | a hydraulic actuator: pump whine, a moving ram, the clunk at the end of its stroke | "hydraulic actuator", "excavator hydraulics", "hydraulic press" | landing gear up and down, the VAB crane |
| `decouple_heavy` | a big metal bang with a short ring: a pyrotechnic bolt, a shipping container door slammed | "pyrotechnic bolt", "metal slam large", "container door slam" | staging and decouplers (now a bird-scaring gun) |
| `rcs_puff_1..3` | short cold-gas bursts: an air gun, a tyre inflator, a pneumatic nailer without the nail | "air blow gun", "compressed air burst short" | attitude thrusters (not voiced yet) |
| `capcom_loop` | mission-control background: radio squelch, distant voices, Quindar tones; no clear words | NASA Apollo "flight director loop", "mission control ambience" | the Tracking Station and the ops board, very low |
