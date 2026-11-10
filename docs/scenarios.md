# Scenarios: how they work and how to write one

A scenario is a story with a script. It starts in a fixed situation: a world, a crew, buildings, craft and supplies, placed in their own save slot (`scn`). It then plays out as a list of steps. Each step's goals are read off the real game world. Along the way the scenario fires dialogue, cutscenes and scripted events. At the end the player gets a medal and a debrief.

You can write one without touching the game's code. A scenario is a Lua table in one file. Anything it references (blueprints, craft, pictures) sits in a folder beside it.

- Code: `scripts/scenario.lua` (the rulebook, pure) and `scripts/scenario_run.lua` (the scene half, on the ScenarioLib node).
- Design: work/scenarios/PLAN.md.
- Tests: `tests/smoke_scenarios.lua`, `tools/perf/scnprobe.sh`.

## 1. Where scenarios live

| Where | Who | Notes |
|---|---|---|
| `scenarios/<id>.lua` or `scenarios/<id>/scenario.lua` | shipped with the game | |
| `user://scenarios/<id>/scenario.lua` | a player's own, or a mod | The game's data folder: `save/user/scenarios/` in the editor, the player's data folder in a build. |

- **Paths.** Every file path inside a scenario is relative to the `scenarios` folder that holds it, so write `"<id>/shell.bp.txt"`. The same file works whether it is shipped or dropped into `user://scenarios/`.
- **The menu list.** The SCENARIOS panel lists every scenario it finds, except files whose names start with `_`:
  - `_template.lua` is the annotated template to copy.
  - `_probe.lua` and `_story/` are the framework's own tests. `_story/` is also a small worked example of the story features.

## 2. Rules

1. **A scenario file is data.** It is a Lua table literal, `return { … }`. The game *reads* it with its own parser (`scenario.parseData`) and never *runs* it.
   - The engine's Luau has no `loadstring`, and a mod must not run code.
   - So a scenario file can hold strings, numbers, `true`/`false`/`nil`, nested tables, `name =` and `["key"] =` fields, comments and long strings.
   - It cannot hold names, sums or functions. `math.pi` or `2 * 60` is an error that names the file and line. Write `120`.
   - Only the beat kinds in §5 and the goal kinds in §4 are accepted.
   - Anything else is refused with an error that names the file and the field, e.g. `scenarios/x.lua: steps[3].goals[1].kind: unknown kind 'roms'`.
2. **Never a world point.** The planet moves metres every tick (docs/positions-and-frames.md). Places are refs and siting rules:
   - **Refs:** `crew:<name>`, `mark:<name>`, `struct:<name>`, `craft:<name>`, `body:home|moon|<name>`, and `base` (the spaceport).
   - **Siting rules:** `base`, `near_base` (`dist` metres out), `far_flat_lit`, `far_flat`, and `"lat:12.5,lon:-40"`.
   - **Offsets** are `{ right, up, front }` metres in the ground frame of the point. Front is toward the world's north pole and up is the ground normal. An offset with `up = 0` is set down on the ground.
3. **Goal truth is read live; step completion is latched.** A step is done the moment every goal reads true, and it stays done (`scn.done`).
4. **Ops' voice:** short, dry, first names, no exclamation marks.

## 3. The table

Copy `scenarios/_template.lua`; every field is annotated there. The main ones:

```lua
return {
  id = "night_shift", title = "Night Shift", v = 1, order = 20, minutes = 15,
  teaches = { "reactor", "repair" }, blurb = "…", brief = { "line", "line" },   -- the menu card and the BRIEFING panel
  world = { seed = 48213, scale = 4, home = "alien", homeSeed = 7715, air = "none",     -- or "any"
            time = { at = "night", hold = true } },                                   -- §5.8
  cast = { hale = { name = "Dr. Hale", tag = "PLANT CHIEF", color = { 1, 0.8, 0.5 }, crew = "Hale", portrait = "auto" },   -- §5.6
           ops = { name = "Kessel Ops", tag = "OPS", radio = true, delay = 540 } },                                          -- §5.7
  vars = { trust = 0 },
  meters = { … }, models = { … },          -- §4.2: variables that follow the world, as data
  failure = "checkpoint",                  -- §4.3: a fail goes back to the last checkpoint ("end": a hard fail)
  hooks = "scn_night_shift_hooks",          -- optional, shipped scenarios only (§6)
  start = { … },                            -- §3.1
  sequences = { intro = { … } },            -- named beat lists: dialogue, cutscenes (§5)
  events = { … },                           -- triggers (§5.3)
  on_start = { { run = "intro" } },
  steps = { … },                            -- §4
  fail = { { kind = "crew_dead", any = true, text = "…" } },
  score = { par = 900, budget = { funds = 9000 }, medals = { gold = { time = 1.0 }, silver = { time = 1.6 }, bronze = "done" } },
  after = "freeplay", freeplay = { contracts = true },
  debrief = { gold = "…", silver = "…", bronze = "…", fail = "…" },
}
```

### 3.1 The start state

Everything in `start` is staged once, behind the loading curtain, through the game's own systems. No save key is written by hand.

| field | does |
|---|---|
| `funds`, `rp`, `research = { techId… }` | The balance (career money rules: `game.mode = "scenario"`), research points, and unlocked tech (research.lua TECH ids). |
| `safety` | `rescue`, `death` or `invincible`. |
| `contracts = false`, `programme = false` | The Ops Board and the programme stand down until freeplay. |
| `crew = { { name, role, control, where = { body, site, dist, offset }, post = ref, pack = { {item}, {part, n}, {mat, kg} } } }` | The starters are renamed and given these roles, and more are hired free. The `control = true` member is the player, placed at the site. `post` sets a member down at a mark once the buildings exist: crew at their stations. |
| `marks = { name = { at = ref, offset } }` | Named points that steps and beats refer to. A mark may sit on a crew spot or on a structure. |
| `structures = { { bp = "<id>/x.bp.txt", name, at, offset, yaw, air = true, powered = true } }` | A SOLBP1 blueprint code, from the Build Kit's BLUEPRINTS tab or Shift+F12, built as a structure. `air = true`: every sealed room starts at 1 atm. `powered = true`: its grid's batteries start full. |
| `crates = { { at, offset, parts = { ["wall.steel"] = 6 }, items = { repairkit = 1 }, name } }` | A "Supply drop" crate of crated parts that an Engineer builds from. |
| `flags`, `survey` | A flag planted (deployables), survey layers credited. |
| `craft = { { file = "<id>/lander.json", name, where = { pad } \| { runway } \| { orbit = { body = "moon", alt, e, inc } } \| { ground = ref, offset }, control = false } }` | VAB launch-format JSON. `orbit` makes a station or a drone; `ground` makes a landed craft. |
| `plants = { { struct, fuel = { item, n }, power, days, scramFor, standby, hold, protection, turbine, fill = { { uid \| part, kg } } } }` | A reactor plant in a staged structure, with a past: every fuel channel loaded, then `days` at `power` run through the plant's own catch-up (so the xenon, the decay heat and the trend are real), a SCRAM held `scramFor` s, a start-up to `standby` held `hold` s; then the protection and the turbine set, and tanks of its fluid networks filled. Graveyard Shift's plant: twenty days at 60 %, parked at 2 % with the trips bypassed. |
| `wires = { { struct, from = { uid \| part, pin }, to = { uid \| part, pin } } }` | Signal Cables laid between two pins (logic_net), so a base's alarms and interlocks are live from the start: a console's `tripped` to an Alarm Beacon's `IN`. Blueprint pieces keep their order, so a piece's uid is its line in the blueprint. |

## 4. Steps and goals

```lua
{ id = "cool", text = "Bring the primary under 560 K and hold it.",
  goals = { { kind = "reactor", struct = "Plant", temp_below = 560, hold = 30 } },
  mark = "mark:console", hint = "The console's TRENDS page.", hint2 = "Open the makeup valve.",
  run = "cool_brief",                 -- a sequence when the step opens
  teach = { overlay = "NUCLEAR", catalogue = "PUMP" },
  on_enter = { … }, on_done = { … }, checkpoint = true, optional = false, parallel = "jobs" }
```

- Steps run in order. `optional` steps count toward nothing and block nothing. Steps that share a `parallel` group are open together.
- Every goal can take `hold = secs` (it must stay true that long) and `label` (the text on the objective card).
- Each goal shows a reading on the card and in the Ctrl+F10 overlay, for example "p 0.71 of 0.95".

| kind | fields |
|---|---|
| at | who, at, r |
| in_room | who, struct, room = any \| largest \| airlock \| n |
| helmet | who, off |
| rooms | struct, sealed |
| airlock | struct, count |
| airlock_cycled | struct, n |
| room_air | struct, room, p, o2, co2 (max), breathable |
| grid | struct |
| struct_has | struct (or at + r), part (id prefix), count |
| flag_on | body |
| reactor | struct, power_above, power_below, temp_below, temp_above, flow_above, scrammed, melted, net_above |
| piece_ok | struct, part \| uid: the piece is not knocked |
| var | name, eq \| ne \| lt \| gt \| lte \| gte \| is |
| choice_made | name |
| step_done | step |
| hook | fn: your hooks' `goals[fn]` |
| power_read | struct, battery_above \| battery_below (share of the store), need_above \| need_below (kW drawn), supply_above \| supply_below (kW made), powered, breaker = part \| uid with state = closed \| open \| tripped |
| part_hp | craft, part (id prefix) \| uid, above \| below: a craft part's health, 1 whole … 0 broken |
| piece_state | struct, part \| uid, on (a pump or machine running), knocked, field = "<state key>" with eq \| ne \| lt \| gt \| lte \| gte \| is |
| *(fail list)* room_unbreathable | struct, room = largest \| airlock \| n, secs: the room has been unbreathable that long |
| *(fail list)* crew_dead | who \| any |
| *(fail list)* suit_air | who, below |
| *(fail list)* craft_lost | craft |
| *(fail list)* timer | secs, from = start \| step \| step:<id> |
| missions kinds | altitude, speed, orbit, soi, land, flag, dock, drive, home, recover, deliver, sample… (as contracts) |

Every goal returns met and a reading, and every one can be an event's `when`, a meter's `when` or a model's `when` / `active`.

### 4.1 Steps for a story

- `act = "Act 3 · PL-7"`: the words a setback card goes back to (§4.3). Without it the step's text is used.
- `checkpoint = true`: a return point. When the step opens, the story's state is snapshotted (the variables, the events already fired, the objective texts, the model crossings, the clock so far).
- `stage = { … }`: a start-like table staged on top of `start` when the run comes back to this checkpoint. Graveyard Shift's act 3 stages the plant back at 60 % with the turbine on line (`plants = { { struct, standby = 0.6, hold = 600, turbine = true } }`).

### 4.2 Meters and models: what hooks used to do, as data

A **meter** is a variable that follows a published reading. It is sampled with the goals (4 Hz, the agency clock).

```lua
meters = {
  { var = "kwh", read = "reactor.genKW", struct = "Kerne Station", mode = "integrate", scale = 0.000278 },   -- kW·s → kWh
  { var = "dose_msv", read = "dose.msv", who = "Halloran", delta = true, round = 0.1 },                      -- from the first reading
  { var = "peak_k", read = "reactor.fuelK", struct = "Kerne Station", mode = "peak", when = { kind = "var", name = "loca", is = true } },
  { var = "batt", read = "grid.battery", struct = "Tarrant Flats" },
}
```

| field | does |
|---|---|
| read | `reactor.<field>` (struct; the console's numbers: power, fuelK, primaryK, flow, genKW, netKW, inventory…), `grid.supply \| need \| stored \| battery` (struct), `dose.msv` (who), `suit.o2` (who), `room.p \| o2 \| co2` (struct, room), `part.hp` (craft, part \| uid), `piece.<field>` (struct, part \| uid; true/false read as 1/0), `var.<name>` |
| mode | `sample` (the default: the reading), `integrate` (a sum over time), `peak`, `min` |
| scale, delta, round | a factor; count from the first reading; round to this step |
| when | a goal: the meter only runs while it reads true |

A **model** is a number with its own law, for what the game does not simulate. It runs while `active` reads true (always, without it). It climbs while `when` reads true, by `rate · (1 + accel · (v − base))` a second. Otherwise it settles toward `rest` with time constant `tau`, or falls by `fall` a second, or stays. `at` fires beats once as it crosses a value (`down = true` for a crossing downward; `once = false` every time).

```lua
models = {
  { var = "hut_c", start = 18, rate = -0.4, rest = 18, tau = 20, min = -10, round = 0.1,
    when = { kind = "piece_state", struct = "Story Hut", part = "lightFitting", knocked = true },
    at = { { value = 12, down = true, beats = { { say = { who = "hale", text = "It's getting cold in there, Dele." } } } } } },
}
```

Graveyard Shift's pump bearing, which its hooks keep, is the same thing written as a model (see the comment in `scenarios/graveyard_shift/scenario.lua`). Meters and models write ordinary variables, so score rows, medals, branches and events read them.

### 4.3 Failing: setbacks and checkpoints

Ty, 2026-11-10: "you can fail but it just goes back to your last checkpoint."

- By default (`failure = "checkpoint"`), a fail is a **setback**, not the end. That covers a death, a melted core and any fail kind.
- A card shows what happened and where you go back to ("BACK TO ACT 3 · PL-7"). Then the run is restored to the last checkpoint reached, or to the start if none was reached:
  - the world is staged again from `start`, plus the checkpoint step's `stage` table;
  - the steps before the checkpoint are latched;
  - the story's state comes back from the snapshot;
  - the opening is not played again.
- The debrief comes only at the real end. Its score shows a **Setbacks** row when there were any.
- `failure = "end"` keeps the hard fail (a challenge scenario: `_probe` uses it). The run ends with the fail debrief.
- The restore lives in one function, `scenario_run.checkpoint_restore`. Today it restages from data. When engine card 0681 lands (`save.copySlot`, `save.slots`, `terrain.copySaveDir`), it will copy the checkpoint's slot and terrain back instead.

## 5. Dialogue, cutscenes, events

### 5.1 Beats

A beat is a table with one key. Beats run in order from a queue. A line of dialogue, a choice, a shot or a wait holds the queue until it is done.

| beat | shape |
|---|---|
| say | `{ who, text, secs, wait = true, with, delay }`. `who` is a cast key, a crew name, or `ops`. `with` puts a listener beside the speaker, dimmed on the right of the plate. `delay` overrides the cast's (§5.7). |
| ops | `"text"` |
| choice | `{ who, prompt, options = { { text, var = {…}, run = seq, step = id, beats = {…} } }, default, timeout }` |
| run | `"sequence"`: runs a named sequence inline. |
| cutscene | `true`: the first beat of a sequence makes the sequence a cutscene. |
| shot | `{ orbit = ref, dist, height, turn, secs }`, or a dolly `{ from = ref, to = ref, look = ref, offset, secs }`, or `{ look = ref, secs }`. `wait = false` runs on while the shot plays. |
| caption | `{ title, sub, secs }` |
| wait | `secs` |
| var | `{ name = v }` |
| add | `{ name = n }` |
| branch | `{ var, eq…, run \| beats, ["else"] \| elseBeats }` |
| goto | `"stepId"` |
| objective | `{ step, text }` |
| knock | `{ struct, part \| uid }`: a fault. The piece leans and reads knocked (a Repair Kit fixes it), and a reactor pump or life machine stops. |
| state | `{ struct, part, st = {…} }` |
| power | `{ struct, part, on }` |
| spawn | `{ structure \| crate \| flag \| craft \| crew = … }` |
| remove | `"struct:Name"` |
| walk | `{ who, to = ref, offset, secs, speed = 1.4 }`. The member's body walks there along the ground (§5.5); `secs` is the time-out after which they are set down there. |
| face | `{ who, emotion, weight = 1, secs = 6 }`: an expression held on their face. neutral, focus, happy, excited, relief, delight, worried, scared, panic, pain, strain, tired, bored (and alarmed, smile, calm, grim). |
| look | `{ who, at = ref \| false }`: their head and eyes turn to the ref, re-read every frame; `false` lets go. |
| light | `{ ambient = 0.4 \| false, fog = 0.6 \| false, time = "dusk" \| degrees \| false, secs }`: §5.8. |
| weather | `{ kind, secs, k = 1 }`: the sky eased into that weather over `secs` (clear, overcast, rain, storm, thunderstorm, hail, snow, blizzard, dust, duststorm, ash, ashstorm); `kind = false` hands it back to the world. |
| breaker | `{ struct, part \| uid, closed = true \| false, trip = true }`: base_power's breaker, as a hand would throw it. |
| wear | `{ craft, part \| uid, hp }`: a craft part worn to `hp` (never below 0.05; the damage model breaks things). |
| music | `"audio/music/<file>.ogg"`: that piece now, the ambient music held off. `false`: silence. |
| warp | `n`: ask for time warp ×n (warp_chip's rules). |
| give | `{ who, item \| part \| mat, n \| kg }` |
| funds | `±n` |
| unlock | `"tech"` |
| mark | `{ name, at, offset, show }` |
| sound | `"audio/…"` |
| alarm | `true` \| `false` |
| hook | `"fn"` |
| fail | `"why"` |
| done | `true` |

### 5.2 Cutscenes

A sequence that starts with `{ cutscene = true }` plays as a cutscene:

- The player's keys are held (`game_manager.inputOwner = "scenario"`, and the walker is steered to a standstill). The interface is hidden and letterbox bars go up.
- Dialogue and captions show on top.
- Holding **Esc** for 1 s skips the cutscene. Lines, shots, waits and sounds are dropped. Everything that changes the world (knock, var, spawn, walk, give, goto, light, weather, breaker, wear, music and so on) still happens, at once. A walk lands at its mark.
- Every shot is re-aimed every frame from refs read against that frame's planet. A camera orbiting a hut stays on the hut while the world moves under it.
- A shot keeps clear of what it frames.
  - The camera stays at least 1.1 m from the point it looks at.
  - A ray over the outer half of the line, from that point out to the camera (ten times a second), pulls the camera in front of a person anywhere on it, or of a wall or part the camera is in or within 1.5 m of.
  - A building the shot looks into from outside is not "in the way".
  - The pull is instant and the let-go is eased.
- Outside cutscenes, a `shot` or `camera` beat waits until the craft you fly is on the ground.

### 5.3 Events

```lua
events = {
  { id = "trip", when = { kind = "timer", secs = 240, from = "step:power" }, run = "pump_fails" },
  { when = { kind = "reactor", struct = "Plant", temp_above = 600 }, once = false, cooldown = 30, beats = { { alarm = true } } },
  { when = { kind = "var", name = "trust", lt = 0 }, after = "power", beats = { { say = { who = "hale", text = "Easy." } } } },
}
```

- `when` takes any goal kind. Events are checked four times a second with the goals.
- `once` defaults to true. `after` and `during` gate an event on a step.

### 5.4 The UI

- With no UI listening, scenario_run draws its own subtitle box, choice list (keys 1–4), letterbox and alarm border.
- The game's Ops strip and panels replace those through `listen("say" | "choice" | "cutscene" | "alarm" | "phase" | "setback", fn)` and read `scenario_run.state()`. See the API in work/scn_fwa/API.md.
- A line carries `with` (the listener: name, tag, portrait), `radio` and `garbled` for the plate (scenario_stage.lua).
- The plate follows the runner. The runner's line is the one shown: a new line replaces the one up, and a line the runner has finished closes.
  - Typing runs on the wall clock, so a choice that pauses the world still types.
  - Outside a cutscene a plain line leaves the mouse to the camera. Only a choice takes the pointer, and only a cutscene takes the camera.

### 5.5 Walking

- A `walk` steers the member's body (crew_body.lua `steerTo`).
- Each frame the runner reads the ref and hands the body the target body-relative, so the walk follows a mark on a moving planet (docs/positions-and-frames.md).
- The body walks along the ground at `speed` on the walk clip, facing the way it goes. A ray down each tick sets the feet, so it climbs onto a floor.
- The record is written once, where it stops.
- A member with no body in range, or who has not arrived by `secs`, is set down at the mark. So is everyone whose cutscene is skipped.

### 5.6 Portraits

Ty, 2026-11-10: "captured since every human should be random."

- `portrait = "auto"` on a cast member with `crew = <name>` photographs that member's own face once the scenario is staged. It is the face the generator gave them in this playthrough.
  - The camera is re-placed from their body every frame until the picture answers (camera.captureTexture).
  - It takes one member at a time and costs a one-off hitch, not a per-frame cost.
- `look = <seed>` pins a face for an author who needs one (crew_faces.lookFor). The default is random.
- `expression = "tired"` is the face they wear for the picture.
- The fallback is `scenarios/<id>/<key>.png`, baked by `tools/perf/portraitbooth.sh <engine> <id>` with the same rig. It is used for anyone who never spawns (a voice off the roster, the dead: give them a `look` seed and the booth borrows a body for the shot) and before the live picture is taken.
- `portrait = "<id>/x.png"` is still a plain picture.

### 5.7 Radio

- `radio = true`: the speaker is heard over the set. The plate shows their picture under a phosphor wash with RADIO in the corner, and the radio crackles under the line.
- `delay = secs`: each of their lines is heard that many game seconds after its beat (light-time: Ops at nine minutes is `delay = 540`). The queue does not wait for it, a delayed line never cuts into a cutscene, and a reload keeps the lines still in flight.
- `link = "craft:<name>" | "crew:<name>"`: when that craft, or the craft that member rides, has no comms path, every third word is lost ("—") and a squelch ends the line. The plate says LINK LOST.

### 5.8 Time of day and light

- `world.time = { at = "night" | "dusk" | "dawn" | "morning" | "noon" | "afternoon" | "evening" | <degrees>, hold = true }` holds the key light at that elevation over the player's site for the whole run. It is turned toward the real star's azimuth, in the star's colour and strength.
- A `light = { time = "dawn", secs = 60 }` beat moves the held sun: a sunrise in a cutscene. `time = false` gives the world its own sun back.
- Why it is done this way: Solar's Lighting node is in Stars mode, where the engine lights the ground from the star bodies every frame and ignores the node's direction (floptle-editor shading.rs). So a hold puts the node on its directional sun until the scenario ends or the hold is released. The direction is re-asserted with the goals, and every frame only while an ease runs.
  - Scripts that read the real star still see the real star: solar panels, temperature, the weather.
  - atmosphere.lua's haze colour follows the held sun (`sunUpOverride`).
  - Engine card draft E-SC4 asks for a key-light override that keeps Stars mode.
- `light.ambient = 0.4` dims the world's ambient to that share (an interior, a dark scene) through underground.lua's one multiplier. `false` restores it.
- `light.fog = 0.6` holds a fog bank (weather.forceMist). `false` lets it go.
- Freeplay hands the light, fog, weather and music back to the world.

## 6. Hooks (shipped scenarios only)

When data is not enough, a game scenario may name hooks: `hooks = "scn_<id>_hooks"`. That is a script kind:

- the script is `scripts/scn_<id>_hooks.lua`;
- it sits on a prefab of the same name (`prefabs/scn_<id>_hooks.prefab.ron`), or the prefab named by `hooksPrefab`;
- scenario_run spawns the prefab and calls the script's globals through findScript;
- under luajit, `scenario.load` loads the script from disk.

Every hook gets a small `api` and should use nothing else: `say`, `run`, `beat`, `var`, `setVar`, `done`, `goto`, `fail`, `finish`, `pos` (body-relative), `dist`, `now`, `log`.

It may also READ (copies, never handles): `reactor(struct)` (the console's numbers: power, fuelK, primaryK, flow, inventory, damage, protection, setpoint, mode, scrammed, melted, turbine, genKW, netKW, coreKW, breaks…), `piece(struct, part | uid)` (the piece's part state, `knocked`, and a reactor pump's `pumpOn`) and `dose(who)` (the share of a lethal dose taken). A `tick(api, t)` global runs with the goals, 4 Hz on the agency clock: meters, peaks and models of things the systems don't simulate (Graveyard Shift's pump bearing) live there.

More for game scenarios (all data):
- the `reactor` beat: `{ struct, scram, reset, startup = set, setpoint, protection, turbine, cooldown }`;
- `knock = { …, label, secs }`: the repair row's words and time; a knocked piece of any structure (not only a ruin's) gets a Repair-Kit row while a scenario runs;
- the `core_melted` fail kind: `{ kind = "core_melted", struct, text }`;
- the siting rule `far_flat_dark`: flat ground with the sun down (a world's day is its year: the light still moves);
- `score.rows = { { label, var, fmt, par, lte | gte } }` and medal criteria `vars = { name = { lte | gte | is } }`: the debrief and the medal read the run's variables.

A player's scenario under `user://` cannot carry hooks. It is refused with a reason, because mods are data only. Everything a mod needs is in the beats, the goals, the meters and the models (§4.2): Graveyard Shift's meters (energy, dose, the peak) and its bearing can all be written as data. Reach for a hook only for what a goal, a meter or a model cannot say.

```lua
-- scripts/scn_reactor_hooks.lua
function on_step(api, id) end
function on_done(api, id) end
goals = { cooled = function(g, api) return api.var("t") > 3, "reading" end }   -- { kind = "hook", fn = "cooled" }
function surge(api) api.setVar("surged", true); api.run("surge_scene") end      -- { hook = "surge" }
```

`scenarios/_story` uses `scripts/scn_story_hooks.lua` and `prefabs/scn_story_hooks.prefab.ron`.

## 7. A worked example: a fault, a choice, a fix

This is `scenarios/_story/` in short. It has a hut on the home world, a site chief who is not on the roster, a light that fails three minutes in, and a choice that changes the ending.

```lua
cast = { hale = { name = "Dr. Hale", tag = "SITE CHIEF" }, okafor = { name = "Dele Okafor", tag = "ENGINEER", crew = "Okafor" } },
vars = { trust = 0 },
start = { crew = { { name = "Okafor", role = "engineer", control = true, where = { site = "near_base", dist = 140 } } },
          marks = { hut = { at = "crew:Okafor", offset = { -10, 0, 8 } }, door = { at = "struct:Story Hut", offset = { 1, 0, 5 } } },
          structures = { { bp = "_story/hut.bp.txt", name = "Story Hut", at = "mark:hut", air = true } } },
sequences = {
  intro = { { cutscene = true },
            { shot = { orbit = "struct:Story Hut", dist = 22, turn = 50, secs = 4, wait = false } },
            { say = { who = "hale", text = "That light has failed three nights running." } } },
  ask   = { { choice = { who = "hale", prompt = "Now, or after the shift?",
                         options = { { text = "Now.", var = { trust = 1 } }, { text = "After.", var = { trust = -1 }, step = "late" } } } } },
  fault = { { cutscene = true }, { alarm = true }, { knock = { struct = "Story Hut", part = "lightFitting" } },
            { say = { who = "hale", text = "And there it goes again." } }, { alarm = false } },
},
events = { { when = { kind = "timer", secs = 180, from = "step:walk" }, run = "fault" } },
on_start = { { run = "intro" }, { run = "ask" } },
steps = {
  { id = "walk", text = "Walk to the hut's door.", mark = "mark:door", goals = { { kind = "at", who = "crew:Okafor", at = "mark:door", r = 4 } } },
  { id = "fix", text = "Repair the light.", goals = { { kind = "piece_ok", struct = "Story Hut", part = "lightFitting" } }, on_done = { { done = true } } },
  { id = "late", text = "The shift is over.", goals = { { kind = "var", name = "trust", lt = 0 } } },
},
```

## 8. Checking your scenario

1. Run `luajit solar/tests/smoke_scenarios.lua` from the folder that holds `solar/`. It loads and validates every scenario: kinds, fields, refs, part ids, research ids, blueprint codes, craft files, sequences, events and hooks.
2. Bake its portraits: `tools/perf/portraitbooth.sh <engine> <id>` writes `scenarios/<id>/<key>.png` for every `portrait = "auto"` cast member (the fallback pictures, §5.6).
3. Play it in the engine. `tools/perf/scnprobe.sh <engine> <id>` starts it exactly as PLAY does, stages it, and plays its solution. The solution is `scenarios/<id>/solve.lua` defining `SOLVE(SP)`, or the generic solver, which completes each step with F11. The probe takes pictures (`save/user/scnshots/`) and reports the runner's cost.
4. While playing:
   - **F11** completes the current step.
   - **Ctrl+F10** shows every goal's live reading.
   - **Shift+F12** dumps the world (crew, funds, research, structures as blueprint codes) as a `start` table to `user://scenarios/dump_<n>.lua`. Build a base in sandbox, dump it, and paste the dump into your scenario.

## 9. Save keys and cost

- **Slot.** The slot `scn` holds `g_scenario` and the world keys, plus the runner's `scn.*` keys: `done`, `vars`, `marks`, `structs`, `crew`, `spots`, `t0`, `outcome`, `medal` and the rest. Careers (`slot1..3`) are never touched.
- **Profile.** The profile (best medal, best time, plays) lives in `user://scenarios/profile.json`, outside every slot.
- **Story keys (FW-C).** `scn.dl` (lines still in flight), `scn.m0` (meters' first readings), `scn.mat` (model crossings), `scn.cpSnap` (the checkpoint snapshot), `scn.setbacks`, `scn.t0off`.
- **Cost.** Outside slot `scn` the runner does one boolean test a frame. In a scenario it evaluates goals four times a second; the per-frame work is the beat queue and, during a cutscene, the shot function, which planet_camera calls. The scenario probe measures the cost.
  - The story pack adds nothing per frame outside a cutscene except two comparisons (delayed lines, a light ease). Meters, models, the weather ramp and the held sun run with the goals at 4 Hz.
  - A walking body costs one ray down per physics tick while it walks.
  - The portraits are a one-off: one camera and one capture per cast member, after staging.
  - _story's intro cutscene (an orbit shot, a walk, a look) measured 0.06 ms a frame of scenario_run on .1480.
