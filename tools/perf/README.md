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

## motoprobe.sh + motoprobe_modes.lua — bikes, cars on struts, landing gear, the builder's snap

    WORK=$SCRATCH/moto LOCK=$SCRATCH/engine.lock tools/perf/motoprobe.sh <engine> [modes]

docs/auto-engineering.md. One WORK dir per chain of runs: two chains queued on
the same WORK share its scratch project and the second overwrites the first's
scene params. Modes:

| mode | what |
|---|---|
| bike, bikegyro, car, car_rigid, trike, motoshop | the auto parts' first probes (a ride, the bump field, the parts in the builder) |
| bikelab | the probe bike built several ways (`bikev`: 0 the probe bike, 1 saddle backwards, 2 a strut instead of the fork, 3 the battery on top of the head, 4 built facing +Z, 5 built facing −X, 6 a Probe Core and a gyro, no rider): stand, W for 6 s (`forward`: metres toward the front the PLAYER sees, the fork's side), S (`reverse`); `slalom=n` runs of four gates at ~8 m/s with a U-turn and a stop; `park=1` stops, steps off and watches it 12 s unridden; `hill=g` sculpts a ramp of grade g (14 m long, measured: mean and steepest 3 m) and climbs it. A/B switches: `aerooff`, `norake`, `tinyrider` (the rider's capsule shrunk), `ghostall` (re-ignorePair every tick). One `MP RESULT bikelab<v> <test>` line a test |
| jetgear | the 27-part jet with its gear placed every way (`gearv`: 0 stock, 1 turned 90° on the leg, 2 turned 180°, 3 mains splayed 25° and the nose 90°, 4 Rover Wheel M on the belly and flanks, 5 one main 90°, the other 180°): stand, take-off roll (fine per-tick log from 25 m/s), a hop to ~6 m, an idle descent onto the runway (the bounce above the touchdown height), the roll-out, then a taxi at 7 m/s turning 30° each way. Max vertical acceleration, pitch and roll rates and side slip a phase |
| snapbuild | the probe bike and a strut car built IN THE BUILDER through its own query (`builder.attachQuery` → `builder_attach.best`), grid 5 cm on, each part aimed a few cm off its spot with the cursor far from every node: every joint's offset (`MP SNAP`), 1280×720 pictures |

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

## stageprobe.sh + stageprobe_modes.lua — multi-stage and multi-type craft

    WORK=$SCRATCH/stage LOCK=$SCRATCH/engine.lock tools/perf/stageprobe.sh <engine> [stagejet stage3 stagelander stagevab]

The 2026-10-26 playtest: "the stage menu is totally broken", and a jet on a
rocket's radial decoupler that left its cockpit (and the controls) on the rocket.
`stagejet`: the player's own craft (`crafts/rocketjet.json`, copied into the
scratch project as `user://probe_rocketjet.json`): a rocket with a nose cone and a
jet on a radial decoupler, the crew in the jet's cockpit. The stack cannot climb
off the ground on its own (TWR 1.09, the jet 1.25 m off the rocket's axis: it
topples and shatters ~3 s after release, on HEAD too), so the probe starts it
`airstart` (500) m up with both engines burning and fires the decoupler `sepat`
(2) s later. The jet must keep its cockpit, crew, controls and the camera, the
rocket fall as debris, the jet fly on its own engine (an attitude hold dives it
for speed and levels it), and the revert put the whole craft back on the pad.
`stage3`: Skipper | probe core | Anvil | Sputter, pod, chute, built from the engine
up: three SPACEs; the spent first stage has a probe core so it leaves as a craft,
and `[ ]` switches to it and back. `stagelander`: a lander with two radial
boosters, the chutes put into the boosters' stage in the VAB: one SPACE drops both
boosters and opens the chutes (one HUD card). `stagevab`: the STAGE tab at
1280×720 (the player's craft; the three-stage rocket by default, two stages
swapped, the chutes moved into stage 1 with a row hovered, two undos). One
`SP PASS|FAIL <check>` line a check and `SP RESULT <mode>`; pictures in
`$WORK/proj/save/user/stageshots/`. `PATCHES=` a reverse diff of
vessel_controller.lua shows the old split: the cockpit stays on the rocket.

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

## soakprobe.sh + soakprobe_modes.lua + soaktable.py — does a long session get slower?

    WORK=$SCRATCH/soak LOCK=$SCRATCH/engine.lock SECS=840 TMO=960 tools/perf/soakprobe.sh <engine> [segments]

Mixed play in a loop, one `floptle play` per segment (SECS of loop each; the
first makes a fresh save in slot 14, the rest CONTINUE it; the slot is deleted
at the end unless KEEPSAVE=1). A cycle: the crew put down on new ground (a
bearing that turns 137° a cycle, 250–570 m out), a walk and laser digs, the
inventory, ops board and map, time warp on foot, a crew switch, then either a
flight (the starter rocket from the VAB, burned `soak_fly` s, reverted to the
builder, out of the VAB on foot) or, every `soak_rover` (2) cycles, the 6-part
rover driven `soak_drive` (14) s and reverted the same way (`soak_park=1`
leaves it parked instead, so the fleet grows); a save (`soak_save`); every
`soak_menu` (3) cycles the pause menu's MAIN MENU and CONTINUE again in the
same process. Every `soak_every` (60) s a `SOAK wNN` line (frame p50/p95/p99/
max, per-script ms, buckets, engine counts, terrain memory) and a census: script
instances, the node tree under every root found (by root, with rigidbodies),
Lua memory before and after a full collect, the meshes and textures scripts
made and have not freed (the probe wraps mesh.build/free, assets.textureFrom*/
release and camera.captureTexture: the engine keeps them until freed or Stop
and has no count of them), by the script that made them, and every script's
global-state size and what grew most (Luau has no debug.getupvalue, so a
script's `local` tables are out of reach). `SOAKJSON` rows go to
`$WORK/results/<TAG>/soak.jsonl`; `soaktable.py` tabulates them and fits each
script's ms/frame slope. results/soak_2026-11-03.md.

**The route soak** (`ROUTE=1`, 2026-11-06: the 11-05b "a few minutes of walking
and it is unbearable" report) is one long play on a NEW save: the crew put down
250–570 m out and WALKED (W + Shift, the view turned away from the base with a
slow ±30° wander; stuck 12 s → put down elsewhere) for `WALK` (360) s, the
6-part rover driven away from the base for `DRIVE` (180) s, a last walk of
`WALK2` (90) s. `HOMEW=alien` (+ `HOMESEED`) starts on an alien home world;
`WEATHER=rain` (any `weather.force` kind) holds a weather, unset it runs free
(perfbench's boot forces clear: a player's does not). Every `EVERY` (10) s an
`RT wNN` line and a SOAKJSON row: the window's frame p50/p95/p99/max, frames
over 33 ms, the hitches (>= 50 ms) with the buckets, parts and scripts they
spent, the engine counts that can grow (nodes, props, decals, particles,
effects, lights, voices, draws, chunks, fieldChunks/fieldEdited/fieldStandIns,
meshesPending/InFlight, textureBytes, scriptMeshes/Textures), Lua memory, the
scripts' ms/frame, perf.gpu passes, the weather, and each script's ALLOCATION
rate (perf.scriptMemory's rises summed frame by frame: the garbage it makes,
KB/s). The census (a full collect) only at the start and the end. `pb_frames`
3 (perfbench reads 3 frames of perf.frames a frame, not 8: at 8 the probe
itself made 7.8 MB/s of garbage). `rttable.py` prints the windows, the first
third against the last, and the whole run's hitch buckets/parts/scripts and
allocators.

    WORK=$SCRATCH/soak LOCK=.../engine2.lock ROUTE=1 [HOMEW=alien] [WEATHER=storm] tools/perf/soakprobe.sh <engine>

## seaprobe.sh + seaprobe_modes.lua — the sea's Water Volume and stale node handles

    WORK=$SCRATCH/sea LOCK=$SCRATCH/engine.lock [PATCHES=x.patch] tools/perf/seaprobe.sh <engine>

Mode `sea` (fresh save): first the engine card 0552 repro (a node destroyed, 200
made until one takes its id: the old handle must read `valid` false, `name` nil
and never reach the new node; `SH RESULT`), then the crew on the deepest sea a
scan finds, the free camera 3 m under and 2 m over (`water.at`, the underwater
look), and the 6-part rover dropped in (its height over the sea each second:
Solar floats craft itself). Count the engine's `≈ … density` warnings in the log.
Pictures in `$WORK/proj/save/user/seashots/`. results/rc38.md: density 0 (0551).

## exportshot.sh + exportshot.lua — pictures from an exported build's player

    WORK=$SCRATCH/xshot LOCK=$SCRATCH/engine.lock tools/perf/exportshot.sh <build dir> [Solar]

Plays a copy of the build's `assets/` with the build's own binary (a project
path; `XDG_DATA_HOME` in scratch, so no player data is touched) on a COPY of the
player's save, twice: with the build's `.floptle/textures.ron` and without it.
Three 1280×720 pictures each in `$WORK/png-with|without`. (card 0550)

rainprobe.lua also has a part `compute` (`RAIN_ONLY=compute`): the GPU rain
rings prototype (rain_fx `computeRipples`) on/off, pictures and `perf.gpu`.

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

## vfxprobe.sh + vfxprobe_modes.lua — the vehicle feedback effects

    WORK=$SCRATCH/vfx LOCK=$SCRATCH/engine.lock tools/perf/vfxprobe.sh <engine> [vfxjet vfxrover vfxrocket vfxdamage]

The playtest's "very little feedback when the jet is working", hot engines,
reentry, damage and tyre marks (scripts/vehicle_fx.lua, docs/vfx-feedback.md).
`vfxjet`: the 27-part jet cold on the runway, spooled to 35 %, the take-off roll
at full throttle (side, rear and close nozzle pictures), low flight, the cut and
the nozzle cooling. `vfxrover`: the 6-part rover shoved sideways at speed on the
runway (rubber, smoke), out onto loose ground (tread prints, dust), a hard stop,
a slide, then a drift sequence (a picture every 0.5 s). `vfxrocket`: the starter
rocket's burn and cut (bell heat, ignition, shimmer), then teleported into the air
falling fast (`ralt` × the air's height, default 0.35; `rspeed` m/s, default 150, about 1.6× orbital speed on the home world; `rangle`° down, default 25; reentry
plasma, wake, hull glow, a sequence every 0.5 s, the afterglow). `vfxdamage`: the
rover worn to 15–30 % (shorting sparks, smoke). Each phase is a perfbench scenario
(`PB RESULT`: scripts, particles, effects, decals, GPU passes); `VFX STATS` lines
are vehicle_fx.stats() with the engine's counts, `VFX WHEELS` each tyre's slip and
surface. Pictures (1280×720): `$WORK/proj/save/user/vfxshots/`.

## fxdrift.sh + fxdrift_modes.lua — do effects stay with the moving ground?

    WORK=$SCRATCH/fxdrift LOCK=$SCRATCH/engine.lock tools/perf/fxdrift.sh <engine> [fxjet fxrocket fxgame fxpuff]

The home world moves ~240 m/s on its rails; an effect that does not ride it
streaks off along the orbit. Cameras are fixed to the ground (planet-relative,
placed from drawn poses), so anything that moves in a picture moved over the
ground. `fxgame`: the A/B emitter test — slow World puffs from an FxJet copy
under the craft's root (A, red ball) and one under the planet's node (B, green
ball), at 1x and under time warp (`fdwarp`, default 20: the rails run 20x, so a
frame an effect did not ride would be 80 m), a yellow line along the way a
particle left in the star's frame would go; then the jet spooling up seen from
the game's own camera. `fxjet`: A/B soot columns with the jet parked, the roll
past a camera 60 m ahead, flight from a chase and a fixed camera (A's soot
trails behind). `fxrocket`: the same on the pad, lift-off and the climb.
`fxpuff`: one-shots fired with a velocity through the game's paths
(vfx.explode/separate, the tailpipe puff as vessel_controller fires it) next to
the same with none, and a bike's exhaust: a point moving at `fdv` m/s (15)
firing tailpipe puffs, stopping dead after 1.2 s. Engines do not run on the
clamps (`jets 0`, the flame not playing), so the parked cases use the A/B
copies. Pictures: `$WORK/proj/save/user/vfxshots/fd*`.

## rain.sh + rainprobe.lua — the weather's haze, rain on the ground, the depth of field

    WORK=$SCRATCH/rainfx LOCK=/mnt/disks/3tb/.floptle-shared/engine.lock tools/perf/rain.sh <engine> [TAG]

One silent play on a COPY of the player's save (deleted after). `RAIN_ONLY` picks
parts: `info` (the world's radius, air, sea, the lowest ground nearby), `wx`
(clear / overcast / rain / storm from over the pad and over a valley, Medium and
High, plus the valley in morning mist: `weather.force`, `weather.forceMist`,
`atmosphere.snapWeather`, `rain_fx.setWet`), `splash` (heavy rain close up on open
ground, on the pad, round the crew; each with rain_fx off for comparison), `dof`
(the crew on foot, the old HEAD depth of field forced against the new one, plus
the focus band), `gpu` (perf.gpu and perf.scriptMs in heavy rain with rain_fx on
and off interleaved, and clear weather with the old and new DOF), `rover` (a
rover rolled out through the builder scene: DOF old/new). `OLD=1` runs the
weather, atmosphere, graphics and sun_flare scripts and the system scene as
committed (git HEAD), for before/after. Pictures are 1280×720 by default
(`RAIN_PARAMS='("w", 1920.0), ("h", 1080.0)'` for full size) in
`$WORK/rain/<TAG>/png`; `RX STATE` lines give the weather, the haze and DOF
values, `RX ROOF` whether the camera is under a roof (the rain is off there),
`RX GPU` the passes and the scripts' ms.

## econ_sim.lua — the economy, played by three scripted players (pure Lua)

    luajit tools/perf/econ_sim.lua <before-root> <after-root>     # ECON_LOG=1 for the timelines

Loads a tree's real company, missions, materials, inventory, research and part
registries into a stubbed world (a canyon home and a barren moon) and plays: A a
new player's first 30 minutes, B a Trusted company crashing three orbiters from
$15,000, B2 a young company crashing three High Road rockets from $5,000 (back by
ground work alone, and with the High Road flown), C a rover player who never
flies. Prices, rewards, the recovery and freight rates and the advance come from
the tree, so `git show HEAD:scripts/<f>.lua` copies give a before/after on the
same player model. `tests/smoke_economy.lua` holds the working tree to targets.

## econshot.sh — the economy panels in the real game, at 1280×720

    WORK=$SCRATCH/econ LOCK=/mnt/disks/3tb/.floptle-shared/engine.lock tools/perf/econshot.sh <engine> board|depot|catalog [after-s] [fresh]

`econprobe.lua`: the Ops Board with ground work on it (one selected), the depot
with pack, warehouse and freight goods, the builder's catalogue prices. Slot 13
in the scratch project; delete `$WORK/proj/save` and `$WORK/proj/saves` after.

## crewprobe.sh + crewprobe_modes.lua — the multi-crew slice 2 spine

    WORK=$SCRATCH/ws1 LOCK=/mnt/disks/3tb/.floptle-shared/engine.lock tools/perf/crewprobe.sh <engine> [modes]

docs/crew-and-items.md §2–4. It builds a snapshot of the tree under `$WORK/solar`.
`HEADFILES="scenes/system.ron …"` takes files from git HEAD instead of the working
tree, which keeps another agent's half-done scene edits out of the run. A
planet_walker patch goes in `PATCHES`. `CP PASS|FAIL` lines report each check,
and `CP RESULT <mode>` gives the verdict. Pictures (1280×720) land in
`$WORK/proj/save/user/crewshots/`.

| mode | what |
|---|---|
| crewpod | A new save has three starters. A Pod Mk2 rocket rolls out with all three aboard (`shipyard.crew`), and the probe checks seats, the commander, two dolls and `aboard()`. Then it: switches to #2 at their seat; EVAs #3 (out at the hatch, under 0.3 m/s against the craft); checks the `[ ]` list; quick-swaps ×6; Shift-EVAs a member (a CrewBody, you keep flying); takes control of them on foot; re-boards with F and "Board". |
| crewrover | A rover with two Command Seats: the avatar in one, a doll riding the other, posed by command_seat. |
| crewsplit | pod \| decoupler \| pod with a member in each, 400 m up. SPACE splits it. Each piece keeps its crew and control stays with the active member. `switchTo` flies the other piece as its member, and `` ` `` comes back. |
| crewdeath | A 5 m drop (alive, injured). A 40 m drop: the fall chip passes 12 m/s before the death. Then the probe checks the memorial, remains, crate, caption, the 2 s hold and the handoff to a member at base. Killing everyone hires the free newbie. With death off, the same 40 m drop rescues. |
| crewmigrate | `USERSAVE=1`: on a copy of the player's save, three members; #1, their pack and the avatar are untouched. |

## rifleshots.sh + rifleprobe.lua — the TL-5 Surveyor plasma rifle

    WORK=$SCRATCH/rifle LOCK=/mnt/disks/3tb/.floptle-shared/engine.lock tools/perf/rifleshots.sh <engine> [TAG]

scripts/surveyor.lua on a new save (slot 16, deleted afterwards). The rifle is
bought at the BUY counter (price and full cell checked), a lander rolls out and
the crew shoots its pod from 30 m (hp drop, scorch; with a
`vessel_controller.hitPart` patch in `PATCHES`, a fourth bolt breaks it). Then
it finds a clear 150 m line (on a small world the ground curves 0.9 m under a
150 m chord, so the probe searches, sunniest first, and looks again once the
plants' colliders have streamed in) and shoots member #2 as a CrewBody: twice
at 150 m (hip, then scope), once at 30 m (dead: cause, memorial, caption).
After that it fires a "hostile" bolt at the avatar (the HIT and HP chips),
shoots #3 twice with death off (rescued), and checks the cell's drain and
recharge and the indoors block in the hangar. It prints the cost (`fire`/`hit` ms,
`perf.scriptMs`, GPU passes with three bolts in flight). `RFL RESULT` lines;
pictures (1280×720: holding, charging, the scope, bolts in flight, impacts,
the HUD) in `$WORK/rifleshots/<TAG>/png`.

## covprobe.sh + covprobe.lua — sustained relay coverage (the sky goals)

    WORK=$SCRATCH/cov LOCK=$SCRATCH/engine.lock tools/perf/covprobe.sh <engine> all|map [seconds]

A fresh save (slot 15); a relay satellite (probe core, 3 batteries, Relay Dish)
rolled out of the VAB, its fleet record put on a circular orbit 2.4 radii out
over the ground station, the scene reloaded; then one relay, then three (two
more records on the same orbit, `fleetRescan`), each watched under ×50 warp
for 2.2 windows and the three again at ×1000. `COV T` lines every 2 s: the
snapshot (`sky`) beside the sustained share, held/window, satellites and the
biggest gap; `COV SATS` lines: each relay's radius, angle round the orbit from
the base's zenith, link and charge. `COV RESULT` lines: orbit, velcheck (comms'
conic for the relay against where it is ~10 min of game later), one_relay
(the snapshot spikes, nothing is held), three, three_held, heavy_warp, saved.
`map` plays in a window with the orbit map open and writes `cov_one.png` and
`cov_three.png` (camera.capture) to `$OUT`. The slot is deleted afterwards.

## fdnprobe.sh + fdnprobe.lua — the base buildings' footings

    WORK=$SCRATCH LOCK=$SCRATCH/engine.lock tools/perf/fdnprobe.sh <engine> <TAG>
    FP_PARAMS='("alien", 1.0), ("homeseed", 55555.0)'   # an alien home world

A new save (Earth-like, or Alien with its home seed). Once the base stands,
one `FP LOT` line per facility: the ground under its lot box's edge and a ring
2 m inside, measured along the building's own up as model y (0 = the model's
ground plane; the slabs' bottoms are at -0.6), the sphere the grade aims at
there, and the grade's residual (ground - sphere). Then (`shots=1`) a picture
from `eyeh` (1.0) m over the ground, `out` (3.0) m out from two opposite
corners of every lot, at the corner's foot (`only=FacDepot` for one).
Pictures in `$WORK/fdnprobe/<TAG>/png`; the probe's slot 15 is deleted.

2026-11-03 (0.117.1-dev.1415): the grade holds +0.03..+0.25 m over the sphere
on both an Earth-like (R 892) and an alien home (R 687); the gaps under the
buildings were the sphere falling away from their flat floors (VAB corners
-0.98 / -1.19 m under a 0.6 m slab). Fixed by the footings
(tools/base_foundations.py -> base_facilities FOUNDATIONS).

## ruinprobe.sh + ruinprobe_modes.lua — abandoned bases (expansion X8)

    WORK=$SCRATCH/ruins LOCK=$SCRATCH/engine.lock PATCHES=funds.patch tools/perf/ruinprobe.sh <engine> [ruins]

docs/base-building.md §26. A home-world site moved to flat lit ground on the
far side and the crew walked in (700 m nothing, 500 m stamped and paced in,
300 m found); the five kinds stamped and pictured from two sides; the frame
A/B (`RESULT [r_noruin]`, `[r_stream]`, `[r_ruin]`: the power hall 30 m from
the same camera); 1.2 km off (untouched: unstamped; touched: no nodes); a
scanner's swath and a telescope; the station's ruin entry, card and marker;
a crate, the core, the claim, restore, repair; the claimed base's card.
`RN PASS|FAIL` and `RN RESULT`; pictures in `save/user/ruinshots/`.

## laserprobe.sh + laserprobe_modes.lua — lasers from components (expansion X9)

    WORK=$SCRATCH/laser LOCK=$SCRATCH/engine.lock PATCHES=funds.patch tools/perf/laserprobe.sh <engine> [laser] [turret]

docs/base-building.md §27. `laser`: a 10-bank laser (lens, Jacket Radiator)
and a 1-stage laser on a grid of 30 Isotope Skids and five Battery Banks;
charging measured at 50 kW a bank; pulses through the targeting feature
("Laser target here") at steel, concrete (two), glass and regocrete walls
40 m out, each hp against damage.lua's prediction; the stage's share; a 1 m
pit in the ground after 3 GJ on one spot (and the engine's own dig as a control); a CW burn; a logic fire; the cinematic rule at X11 scale
(invoked directly); costs and GPU with the beam on and off. `turret`: a
derelict rocket and a craft with a Laser Turret set down 20–30 m out; the
turret charges from its batteries, tracks the derelict's tank, breaks it, and
fires AUTO at the pod; a kit laser on the wreck. `LZ PASS|FAIL`, `LZ RESULT`;
pictures in `save/user/lasershots/`.

## chopprobe.sh + chopprobe_modes.lua + camprobe_modes.lua — the Build Kit's frame time, the outdoor builder camera

    WORK=$SCRATCH/chop LOCK=$SCRATCH/engine.lock PATCHES=funds.patch tools/perf/chopprobe.sh <engine> [chop chopab cam]

Playtest 11-10 (docs/base-building.md §28). `chop`: 10 s on foot, the kit
opened with a Pad Plate's ghost, the plate placed by a click, a 40-piece base
beside it (each piece's ghost aimed for 0.4 s, then `placeAt`), then the kit
open and shut. Every frame over `chopms` (25) ms is a `CHOP SLOW` line with
its buckets, parts, scripts and hottest lines; each placement a `CHOP PLACE`
line (its worst frame); `CHOP WINDOW` / `RESULT [c*]` per stretch. `chopab`:
the open kit one thing at a time (shut, icons being taken, open idle, the
column folded, a part in hand, in hand folded, the preview camera off).
`cam`: three Base Hubs (flat, a raised hill's flank, a dug pit's rim), the
full builder opened at each and its camera driven low round the hub, into
the hill, zoomed hard, panned, HOME: `CAMP` lines (the camera's clearance
from the terrain, the pivot's, its roll against the local up), pictures in
`save/user/buildshots/{flat,slope,cliff}_*.png`. Under load (another engine,
load average 40+) every stretch shows 0.3-3.5 s `untimed` stalls, the shut
kit's too: compare runs made back to back.

## gritprobe.sh + gritprobe_modes.lua — the gritty pass: the dig, caves, alien air, fog banks

    WORK=$SCRATCH/grit LOCK=/mnt/disks/3tb/.floptle-shared/engine2.lock tools/perf/gritprobe.sh <engine> [gritdig gritcave gritsky gritfog gritdigshot]

Fresh save, High (`BENCH_STRS='("gfx", "Medium")'` for another level), spliced
after vfxprobe_modes.lua (its freecam). `gritdig`: the Terrain Laser on open,
dry ground, first person and from the side, the cut cooling, then at night,
and `GR AB` (idle / firing alternated at one fixed camera: GPU, scripts,
particle sim). `gritdigshot`: fixed cameras on the bite (close, mid, cooling,
first person), day and dusk. `gritcave`: a tunnel and chamber carved ~25 m
down with terrain.dig, the views in, the helmet lamps and torch, the lamp's
shadows off (engine card draft: point-light shadows in terrain caves).
`gritsky`: the home world's air record swapped for each atmo.lua template and
for no air, day and night. `gritfog`: `weather.forceMist` seen from a hill and
from the low ground, day and night. `GR` lines; pictures in
`$WORK/shots/<TAG>` (`SHOTS=`). Results of the 2026-11-10 pass:
/mnt/disks/3tb/.floptle-shared/solar/work/grit/NOTES.md.


## renderfix.sh + renderfix.lua + rf_frames.py — fog, light flicker, headlights, floating rocks

    WORK=$SCRATCH tools/perf/renderfix.sh <engine> <mode> [TAG]

Ty's 2026-11-12 render issues on a NEW Career save. Modes: `fog` (the spawn
clear, in forced mist, mist at dusk and at night, four headings each, the
Light component's fog fields as `RF LIGHT` lines, a census of every lit lamp at
night), `fogsweep` (strs `sweep` = "fogLight=0.75,0.4,0.2,0": one atmosphere
param swept in day and dusk mist), `flick` (the rover driven in mist with its
lights on, EVERY frame the Light component compared with the last: `RF LW` on a
>15 % change, `HITCH` on a long frame, lightsDropped counted; `DUMP=1` dumps the
window's frames between `DUMP ON/OFF` and rf_frames.py lists one-frame flashes;
params `night` (star elevation to warp to, 1.0 = stay in the day), `shadowmap=0`,
`secs`), `lights` (the rover parked at night, lamps off/on/in mist, four camera
angles), `rocks` (floating scatter rocks and rock nodes round the spawn and three
spots out on the land, with mineral_field's audit counters), `catch` (a slab held
over a stone while it is re-rolled, then taken away). Pictures in
`$WORK/rf/<TAG>/shots/`. PATCHES= applies diffs to the copied tree (a reverse
diff gives a before run). Results 2026-11-12: renderfix report to main.
