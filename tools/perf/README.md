# tools/perf — Solar's frame benchmark, stutter probes and gameplay smoke

Everything that measures Solar on a real engine lives here, in the repo, because
the session scratchpad is tmpfs and is wiped on every reboot (twice in October
2026, taking the probes and every result with it). Results go in `results/<rc>.md`.

## bench.sh — one `floptle play` per mode, silent, under the shared engine lock

    WORK=$SCRATCH/perf LOCK=$SCRATCH/engine.lock tools/perf/bench.sh <engine> [modes]

`<engine>` is a version under `~/.local/share/floptle/versions` or a binary path.
It builds a scratch project (assets symlinked; scripts, scenes, prefabs and
project.ron copied; `perfbench.lua` as the entry scene's script), runs each mode
as its own play, and writes `$WORK/results/<TAG>/{<mode>.log,bench.jsonl,table.md}`
plus `<mode>.uptime` (the machine's load before and after: always quote it).
XWayland and vsync Off by default (KWin paces a native Wayland window at 20 fps
while the screen is locked; see card 0528).

Modes (`perfbench.lua`, strs `mode`):

| mode | save | what |
|---|---|---|
| base | fresh | load, 30 s on foot, 20 laser bites on a meadow and on rock, the orbit map |
| rocket | fresh | the two-stage Skipper→Anvil from the pad to orbit, throttle changes, the map |
| plane | fresh | the 27-part jet: take-off roll (with the 0526 **BURST** capture, and a **LIFT** table of every frame from 0.5 to `liftagl` (12) m up) and low flight |
| rover | fresh | a 6-part rover driven from the runway past 110 m |
| builder | fresh | the in-VAB builder at 300/1,000/3,000 parts, then a ~1,000-part launch and its settling (`loads=1` lets it break up; `onlycraft=1` skips straight to the launch; `E SETTLE` lines give the physics split and the root's wake readout each second) |
| builder `vabidle=1` | fresh | the VAB as a player sits in it (idle empty, 40 parts idle, a part in hand), every script running there with its node (`VAB SCRIPT` lines), then the lean VAB A/B/A (`build_host.setLean`: `g_idle_40_full` / `g_idle_40_lean2`) and zoomed right out (`g_far`, `g_far_full`) |
| vabshots | fresh | 1920×1080 pictures (`save/user/vabshots/` in the scratch project) of the builder's 2026-10-26 playtest fixes: the tile icons, a hovered card's spinning preview, a part in hand over the panel and in the view (latched card, cursor chip, HOLDING line), the MOVE tool (hover, carried, ESC back) |
| vabicons | fresh | the tile icons kept across VAB entries: enter, wait for every icon (`VICONS first entry`), leave, enter again (`VICONS second entry` after 0.5 s) and a picture of the panel |
| foot | player's | stand 20 s, walk 40 s at the spawn |
| meadow | player's | 220 m out to the grassiest spot, stand 8 s, walk 40 s (the turf-wash relay, 0525) |
| digmeadow | player's | 100 laser bites on that meadow |
| park | either | a 6-wheel rover rolled out, released, brakes on: time to `node.asleep`, the wake reason, physics ms/frame (0527/0531); `dump=1` adds, after 10 s braked, every tyre's joint/rigidbody, the chassis mass and g, a PropCrate and PropCan by the base, and 120 ticks of planet-frame displacement (mm) with `asleep`/`wake`, one `DUMP R`/`DUMP P` line a tick; rc27 also prints each tyre joint's anchor/otherAnchor/axis against Solar's seat; then W (brakes released) and a stop-and-sleep-again watch; `park_sas=0` / `park_eva=1` / `park_r2=0` take Solar's per-tick touches away; `trace=1` (on with `dump=1`) counts every force/torque/impulse/velocity write Solar's scripts make on it, by call site and magnitude (`TRACE` lines per window, `calls` on each `DUMP R` tick) — see results/sleep_rc27.md |
| bigpark | either | the 1,002-part finned spine released on the pad with no throttle: sleep and physics before/after (0509/0531); `forcesleep=1` puts it to sleep at 10 s and prints the waker; `big_sas=0` / `big_eva=1` turn the SAS off / put the crew out first; `trace=1` as in park; `e_secs=N` prints what it stands on and, every frame for N s, the physics split (static/sweeps/sleep/joints), perf.bodies and the wake readout (`E BIG`); `big_throttle=1` then opens the throttle: frames to wake and the thrust |
| gameplay | either | the gameplay smoke: starter rocket (engine cut at `starter_cut` m) to apex + revert to launch (refused on a save where the flight earns a milestone), in-VAB rover rollout + 100 m drive, two-stage to orbit (circ burn at `circthr`), jet take-off, 1,002-part rollout and release. One `RESULT SMOKE <step>: PASS/FAIL` line a step |
| quick | either | 15 s idle with the 0528 pacing readout (`app.refreshRate`, `perf.pacing`); `cap=1` then caps at the refresh |
| gpu | either | every GPU pass the engine times (`perf.gpu`), with the picture size, render scale and graphics level, at one spot: strs `where` = `base` (stand at the base), `walk` (teleported to the grassiest spot `gpu_walk` m out, a 12 s walk recorded, then stand), `rover` (the 6-part rover driven `gpu_out` m, then stopped) or `spawn` (USERSAVE=1, the player's spawn); strs `toggles` = a comma list of looks applied one at a time for `gpusecs` each (contact0/1, fogvol0, fogsteps8/12, foglight0, fognoise0, shadows0, shadowmap0, shadowdist100/150/336, shadowsoft0, ssr0, post0, bloom0, flora0, farbodies0, sea0, base0, hangar0, interior0, pad0, flood0, others0, lights0, scale05/075/09), the untouched look measured between every two so a drifting scene cannot pass for a toggle — one `GPU [scenario]` line and one `GPU DELTA [toggle]` line each; strs `res` = `1920x1080` (+ `fullscreen=1`, `monitor=n`) and `gfx` = Low/Medium/High/Ultra set the picture and the level. `gputable.py bench.jsonl` tabulates it |

`USERSAVE=1` copies `save/slot1.ron`, `save/settings.ron` and `saves/slot1` into
the scratch project before every mode and boots from that copy as the menu's
CONTINUE would (slot 1, nothing written). Solar's own save folders are never
written. `BENCH_PARAMS='("sleepsecs", 30.0), ("loads", 1.0)'` passes probe params.

Every scenario prints `PB RESULT [...]` lines (frame stats, the engine's own
buckets/parts/bodies per frame, the fields: `fieldChunks`/`fieldEdited`/
`fieldStandIns`, decalRelay) and one `BENCHJSON` row; `table.py` tabulates them.
On the player's save the probe also prints `GROUND96`: 96 ground radii round the
base summed, at the reveal and after the scenario — the same number on two
engines means the same ground.

## wheelprobe.sh + wheelprobe_modes.lua — wheels after getting off and back on

    WORK=$SCRATCH/wheels LOCK=$SCRATCH/engine.lock tools/perf/wheelprobe.sh <engine> [wheels planewheels]

The 2026-10-26 playtest's "wheels face the wrong direction when getting off and
back on". `wheels`: the 4-wheel rover driven past 95 m from the base, the crew
out MID-TURN and back in, a straight drive; parked, the crew out until the
chassis sleeps, back in, drive and turn; two quick off/on mid-turn. `planewheels`:
the jet taxiing with the rudder held (the nose gear steers), the crew out
mid-turn, back in, turn the other way. Every half second a `WP` line gives each
wheel's DRAWN yaw against the chassis (its TyreMesh's axle), the joint's steer
and the ball body's yaw; a drawn yaw off the joint's by more than 3°, or a mesh
that turns with its ball, is a `FAIL`. One `WP RESULT <tag>: PASS/FAIL` line.
Pictures in `$WORK/proj/save/user/wheelshots/`. Cause and fix: node handles are
bare slot numbers, so a cached TyreMesh handle from before the get-off read
`valid` again for another node (vessel_controller r2TyreVisuals).

## ctrlprobe.sh + ctrlprobe_modes.lua — a craft's control mode (Auto, Rover, Aircraft, Rocket)

    WORK=$SCRATCH/ctrl LOCK=$SCRATCH/engine.lock tools/perf/ctrlprobe.sh <engine> [ctrlrover ctrljet ctrljetwheels ctrlrevert]

The 2026-10-26 playtest's "landing gear as a rover wheel" and "rover wheels as a
plane's gear" (scripts/craft_mode.lua: the craft's mode, not the wheel's part type,
says what the wheels do). `ctrlrover`: the stock rover with a Landing Gear S at its
nose reads Auto: Rover, drives out past 95 m, drives and turns, folds the gear (on
its other four tyres), drives and turns both ways, puts the gear down (its tyre
back), Aircraft and Rocket forced (W no longer drives), Auto again; Rocket chosen,
the fleet saved and the world loaded again (the restored rover still says Rocket).
`ctrljet`: the 27-part jet reads Aircraft; Rover forced drives it on its gear with
the throttle shut and steers it; Aircraft holds it again. `ctrljetwheels`: the jet
with its gears swapped for rover wheels reads Aircraft and takes off. `ctrlrevert`:
in the VAB, the builder says Auto: Rover, Aircraft chosen (undo/redo, saved to the
library and opened again), rolled out as Aircraft, reverted to launch, still
Aircraft. One `CP PASS|FAIL <check>` line a check, `CP RESULT <mode>`; 1280×720
pictures in `$WORK/proj/save/user/ctrlshots/`. TMO defaults to 360 s a mode.

## staleprobe.sh + staleprobe_modes.lua — a handle kept from a node that is gone

    WORK=$SCRATCH/stale LOCK=$SCRATCH/engine.lock tools/perf/staleprobe.sh <engine>

Engine card 0552: a script's node handle is the engine's bare slot number, and
a destroyed node's slot is handed to the next node spawned, so an old handle
reads `valid` again and names the new node. `stale` (fresh save): four rocks
are knocked loose by `tool_belt.knockLoose` (what the laser's mining does),
every chunk is destroyed as a
stow or the depot would (still in tool_belt's list), 60 marker nodes are made
(`SP ... freed slot(s) handed to markers`: the ids that came back), and the
eight more are knocked loose, evicting every old entry. A marker made in a
stowed chunk's slot must survive: `SP RESULT: PASS / FAIL / INCONCLUSIVE`
(none of the freed slots came back). `PATCHES=` a reverse diff of the fix shows
the old eviction destroying the markers.

## demo.sh + demo_probe.lua — a whole player session, for a pre-playtest pass

    WORK=$SCRATCH/qa LOCK=$SCRATCH/engine.lock tools/perf/demo.sh <engine> [TAG]

One silent `floptle play`. A NEW save made from the main menu's new-save panel
(the agency typed in, CREATE), the time from CREATE to the reveal; the first
view (objectives card, crew record, pack, belt); the right-click suit menu with
the helmet off and on; First Steps (a plant cut with the laser's E, ore dug);
a flag and a beacon bought, held and set down; the VAB with the stock starter
(Pod, Parachute, FT-S, Sputter) built in place and LAUNCHed — **the first
launch's wait**, LAUNCH to the crew in the pod on the pad; a climb, the map,
a revert to launch, out of the pod; the Tracking Station, the map, the pause
menu. `USERSAVE=1` loads a COPY of the player's save as CONTINUE does and checks
the crew migration (member #1 owns the old pack), the agency prompt, the fleet
and beacons. Params (`DEMO_PARAMS`): `rush=1` goes straight from the reveal to
the VAB and launches (the player who runs for the rocket), `walk=1` walks there
with W instead of being placed, `seed=N` types a fixed galaxy seed (4242 is the
item probe's world, whose base faces the way its planet moves). One `DEMO …
RESULT` line a check, a `HITCH` line for every frame over 100 ms after the
reveal with the step it fell in, 1920×1080 pictures with the UI in
`$WORK/demo/<TAG>/png`. The probe's saves are deleted afterwards.

**Orbit (2026-10-26):** the gameplay smoke's `orbit` step "always failed"
because the probe read the craft's velocity by differencing its position
against the planet's, two reads that can come from different ticks while the
planet moves ~240 m/s: the MECO apoapsis was overstated and the circularisation
started while falling, then drove the craft to escape. `body_state` now reads
the craft's own velocity and `space.elements`, as the flight HUD does, and tops
the apoapsis back up when the deep air takes it off during the coast: the
Skipper → Anvil two-stage makes orbit (apo 3,527 m, peri 853 m on Naolol). The
stock starter is a hop by design (builder.lua HOP_MULT), not an orbiter.

## gpushot.sh — a picture of one look, for before/after

    tools/perf/gpushot.sh <engine> <look> [after-seconds]      (WHERE=walk for the meadow, USERSAVE=1 for the player's spawn)

The gpu mode on a fresh save (or the player's), holding one look (`look`, or a
toggle such as `fogsteps12`) for `floptle shot --after` to photograph at SIZE
(default 1920x1052, the XWayland play window). Pictures land in `$WORK/shots`.

## shot.sh — a picture of the tools' marks

    tools/perf/shot.sh <engine> <case> [after-seconds]

Cases: 1 the gravity gun aimed at a plant, 2 the plant being pulled (tether), 3 a
scattered rock aimed at, 4 a loose prop held on the tether. The probe (mode
`shot`) stands the crew before the target, faces it and drives the tool belt's
`sim` hook; `floptle shot --after N` plays that long on the fixed clock and
draws the game's camera to `$WORK/shots/<ver>-case<N>.png`.

## flora.sh + floraprobe.lua — how the plants read at eye height

    WORK=$SCRATCH/foliage LOCK=/mnt/disks/3tb/.floptle-shared/engine.lock tools/perf/flora.sh <engine> [TAG]
    FLORA_PARAMS='("levels", 23.0), ("res", 1080.0), ("heads", 1.0)'   PATCHES="x.patch"

A copy of the player's save (deleted after), the astronaut moved to the densest
forest ~`forest` m (300) from the base, a free camera at eye height, `heads`
headings per graphics level in `levels` (digits, 1-4 = Low..Ultra), a picture
each (1280x720, `res=1080` for 1920x1080) and the GPU per pass (`GPU` lines).
`PATCHES` A/B a change on the scratch copy only.

**What it found (2026-10-26, rc37): the dotted canopies were the scatter LOD
cross-dissolve.** The engine dissolves the two bands on complementary 4x4
screen doors; different meshes do not fill each other in, so every plant in a
fade window drew as a dot grid. The window was a quarter of the reach (16.5 m
for a tree, three windows: a third of its drawn distance). A/B with the fade
off: solid crowns. Fix: `flora_gen.fadeBands` windows are 3 % of the reach,
1.5-4 m (GPU unchanged: High 15.5 -> 14.8 ms, Medium 7.4 -> 7.5 ms, one spot).
Leaf alpha mips were ruled out (per-leaf coverage at cutoff 0.5 holds within a
few % down to 16 px), as were ditherAlpha/nearFade (no flora material sets
them). Left for the engine: cutout before the dissolve, a noise pattern, 3D AA.

## look.sh + lookprobe.lua — what the ground looks like over the base

    WORK=$SCRATCH/ground LOCK=$SCRATCH/engine.lock tools/perf/look.sh <engine> [TAG]

One silent `floptle play` (or `EDITOR=1`: `floptle <proj> --auto-play`, the way
the player plays) on a COPY of the player's save (`save/slot1.ron`,
`save/settings.ron`, `saves/slot1`; `NOSETTINGS=1` leaves the settings out),
deleted again after the run. A free camera over the astronaut's spot; pictures
in `$WORK/look/<TAG>/png`, numbers as `LP` lines in `run.log`. Params through
`LOOK_PARAMS='("camr", 779.0), ("weather", 1.0)'`:

| param | what |
|---|---|
| alt / camr | camera height over the ground under the astronaut, or an absolute radius (779 = 6 m over the pad plateau on Zorosia: the same spot every run) |
| pitch, head, off | look down (deg), heading in quarter turns, metres along the ground from the astronaut |
| weather | 1 = forced rain |
| secs, every | how long to watch and how often to photograph |
| gfx, fog | 1-4 = Low..Ultra; 0/1 = fog off/on (both from the second picture on) |
| seq=1 | a toggle series, one picture each: sun0 (the home star's light, the Lighting node and ambient all off: what is lit goes black), starmark/unlitmark (every unlit material magenta), planetmat, plights0 (every point light), farlod0, farbodies0, body0 (the planet node hidden), atmo0, clouds0, atmoscript0, key0 |
| seq=2 / 3 | a red material on the planet node / the planet's air off |

Every run also prints the home body's radius and occluder radius, the fog, the
field vs collider ray hits under four screen points (`RAY`), every node with a
Material of its own (`MATNODE`, grouped by name).

**What it found (2026-10-25, rc27): flat, unlit ground.** On most loads the
whole home world drew in one saturated colour that ignored the sun (sand
255,235,148 or teal 196,255,255; black plants beside bright ground at dusk, the
ground unchanged with every light off). Fog, air, weather, graphics level,
settings, editor-vs-player, point lights and far bodies were all ruled out by
A/B. Cause: an engine bug. A terrain node destroyed during Play stays in the
engine's terrain table, component lookups match a node by slot (not slot +
generation), and the engine shades every terrain with the Material of the first
terrain in that table that has one — so the stale entry reads the Material of
whatever node next took its slot (Solar's star Ummi: sand; a blue core or a
rare plant's orb: teal). Solar destroys the scene's baked system on every load
(13 nodes), so which node fills which slot was a race. Fixed in the engine in
rc29 (card 0537); Solar's slot-keeper workaround was removed when it moved to
rc30 (results/rc29.md: 5 of 5 loads lit without it). Minimal engine repro: two terrain nodes A
and B in a scene, generate both, destroy A in Play, create a sphere with
`setMaterial{unlit=true, color={1,0,1}, emissive={1,0,1}}` anywhere: B draws
flat magenta.

## Rules that cost time when broken

- Never write `base.*` or `g_played` as false in a probe save (it reads as an old
  scale-1 world). `boot()` makes a new save exactly as the new-save panel does.
- Rover and drive probes start on the runway, 90 m+ from the pad: the pad deck
  and the facility walls wedge rovers.
- Compare engines only in pairs taken at similar load; the Hub repainted at
  80–99 % CPU under a running game before rc25.
- Delete probe saves (bench.sh removes its own slot 13 and the slot-1 copy).

## gfx.sh + gfxprobe.lua — the lens look (bloom, sun flare, far blur) and the far-ground grain

    WORK=$SCRATCH/gfx LOCK=$SCRATCH/engine.lock NOSETTINGS=1 tools/perf/gfx.sh <engine> [TAG]

One silent `floptle play` on a COPY of the player's save (1920×1052 window). Each
scene is shot with the old look (bloom 1.0/0.25, no flare, no far blur, sharpness
0.4) and the new one: a far vista at Medium and High (plus the grain diagnosis:
AO off, fog dither off, sharpening off, scale 1, bloom off, the DoF focus band),
the sun at 25°, the sun low and behind the ground, dusk, orbit and eclipse, and
the gravity gun and laser working. `perf.gpu` per pass at the vista, with old and
new interleaved, then each effect alone (`GX GPU` lines). `PATCHES=` applies
diffs to the scratch copy only. Results are in `results/gfx_look.md`.

