-- TOOL BELT — what the astronaut is holding, and what it does to the world.
--
-- THE HOTBAR IS THE PACK. There are no hard-coded slots: the belt is built,
-- every frame, from what `inventory` says the crew is carrying (its GEAR), in
-- a fixed order — the tools first, then anything consumable you have at least
-- one of. A Relay Beacon is on the belt while one is in the pack and gone
-- the moment the last one is planted. Number keys pick by position.
--
--   GRAVITY GUN    the main tool, Half-Life style. Aim at anything loose —
--                  a rock the laser knocked free, debris, a part, a small
--                  craft, a boulder or a crystal in the ground (plucked out
--                  as a body), a cargo can or a crate round the base, a
--                  felled log — hold LMB and it is caught at the point you
--                  aimed at and pulled to a spot in front of you on a spring.
--                  Scroll: nearer / further.  R: throw.  Release: drop.
--                  E while holding: STOW it (a rock as its ore, a log as
--                  timber) if the pack has room. Held into the Commerce
--                  Depot's intake and let go: rocks and logs go into the
--                  warehouse, debris is recycled for a refund. Aimed at a
--                  plant it uproots it (the harvest); at a salvage crate it
--                  pulls the pack's contents out; at a relay beacon, it
--                  pulls the beacon up.
--
-- ── EVERY EFFECT IS PARTICLES ───────────────────────────────────────────────
--
-- No drawn lines. Each beam, mark and hold is a particle effect in vfx/ on a
-- pooled node (prefabs/Fx*), placed every lateUpdate: the dig's beam and its
-- molten bore, the fill's slurry and its deposit, the cut's hair-thin line
-- and the spark fan where it bites, the gravity gun's crackling tether, the
-- idle glow at its claws and the shell round what it holds, the aim mark on
-- the ground and the motes rising through a targeted plant. See THE EFFECTS.
-- What is still drawn is the screen reticle, which is HUD.
--
-- ── THE LOCK ────────────────────────────────────────────────────────────────
--
-- A tool that targets a plant LOCKS: the first plant the beam crosses is the
-- one it works, and it stays the one until the beam has been off the plant's
-- whole body for `lock_grace` seconds — never swapping to a neighbour mid-cut,
-- never resetting its progress because a leaf flickered out of the hit
-- volume. The beam's end eases rather than jumping between the plant and the
-- ground behind it, and the mark on the plant stays up through the grace.
-- (Playtest 2026-10-24: "it flickers a lot weirdly, I can't tell if I'm
-- actually doing it right until it's done".)
--   TERRAIN LASER  hold LMB: DIG cuts rock and streams it into the pack.
--                  Q: switch to FILL, which lays rock back down out of the
--                  pack's own rubble (the spade's raise, with a price).
--                  hold E: CUT — a thin white-hot cutting beam with a short
--                  reach that saws through the plants it crosses (trees come
--                  down) and never touches the ground. See THE CUT.
--   EVERYTHING ELSE in hand (a Repair Kit, a Relay Beacon, a flag) is
--                  scripts/item_hand.lua's: it owns the hand and the belt's
--                  keys (1–9, H for empty hands), deploy mode and the repair
--                  work; this script follows `item_hand.held()`.
--
--   TAB / I  inventory (and, at the Commerce Depot, the buy and sell counters)
--
-- ── AIMING: IT GOES WHERE YOU LOOK ─────────────────────────────────────────
--
-- One ray from the camera — through the cursor while it is free, through the
-- middle of the view while the mouse turns it (see `aim_pixel`) — and the
-- muzzle is only where a beam is drawn FROM. Range is measured from the
-- player, not the camera, so zooming changes nothing. (Casting from the free
-- cursor after a menu shot at the sky; casting from the muzzle slid the hit
-- along every slope; casting from the camera with a camera-measured range
-- shrank the reach as you scrolled out. All three shipped once.)
--
-- ── THE LASER BORES ─────────────────────────────────────────────────────────
--
-- `terrain.dig` subtracts an analytic ball, so a second bite at the same
-- point removes nothing. The cut point is therefore OURS: it lives on the aim
-- ray and eats forward at `bore_speed` while the trigger is held, so the
-- balls union into a tunnel you can walk into. It is held in the PLANET's
-- frame because the planet orbits a star. The ray's hit only decides where a
-- fresh cut starts and proves there is still rock ahead.
--
-- ── EVERY BITE IS CHEAP ─────────────────────────────────────────────────────
--
-- A bite is ~1 ms of terrain work. What made digging hitch for seconds on a
-- meadow (playtest 2026-10-23) was NOT the bite: the engine lays every decal
-- whose ground a dig touches again, outside every perf bucket, and the flora
-- field's ground wash is ~150 decals 29 m across. So before the first bite in
-- a place, the belt asks the flora field to lift its wash there
-- (`flora_field.liftWash`), and the laser lays no burn marks inside a bore
-- it is about to cut away anyway. See `quiet_ground`.
--
-- ── THE GRAVITY GUN IS PHYSICS ──────────────────────────────────────────────
--
-- The catch is a GRAB POINT stored in the held body's own frame, and the pull
-- is a spring-damper force applied AT that point (assembly.forceAt), in
-- fixedUpdate, so an off-centre grab swings and torques the object and a long
-- one tips. The spring's stiffness follows the mass only up to `grav_mref`:
-- light things snap to the aim, heavy ones lag and sag. The whole force is
-- capped by `grav_force` — the gun's power budget — so a craft can be dragged
-- but not lifted, and the strain gauge says how close to the limit you are.
-- Velocities are taken relative to the crew, who ride the same moving planet,
-- so the hold works the same on a world doing 90 m/s round its star.

defaults = {
  --@header Terrain laser
  --@range 4 60 --@units m
  laser_reach = 24.0,      -- from the PLAYER, so zoom never changes it
  -- CUT RADIUS, read against the planet voxel (1.5 units): at 2.4 × 0.85 the
  -- ball is 2.0 units, which surface nets can round-trip.
  --@range 0.2 4 --@units m
  laser_radius = 2.4,
  --@range 0.05 1
  laser_strength = 0.85,   -- × radius = the ball each bite subtracts
  -- Seconds between terrain bites. Yield is paced by time (`yield`), not by
  -- bites, so the pack fills exactly as fast at any rate.
  --@range 0.02 0.5 --@units s
  laser_rate = 0.12,
  --@range 0.2 6 --@units m/s
  bore_speed = 1.8,        -- how fast the cut eats forward into rock
  --@range 0.3 4 --@units m
  regrip = 1.6,            -- aim drift that re-seats the bore somewhere new
  --@range 0 2 --@units s
  spin = 0.35,             -- trigger → full power
  --@range 0.1 3 --@units s
  yield = 1.0,             -- seconds of full-power beam per unit of material
  --@range 0.5 10 --@units s
  focus_time = 3.0,        -- how long on one spot for the full bonus
  --@range 0.2 6 --@units m
  focus_radius = 1.6,      -- how far the beam can wander and keep the bonus
  --@range 2 40 --@units s
  heat_time = 9.0,         -- seconds of unbroken fire to reach full heat
  --@range 0.5 12 --@units s
  cool_time = 4.0,         -- seconds from full heat back to cold, trigger up
  --@header Laser fill
  --@range 0.4 4 --@units m
  fill_radius = 1.5,
  --@range 0.05 1
  fill_strength = 0.7,
  --@range 1 12
  fill_bites = 3,          -- bites of fill one unit of rubble from the pack lays
  --@header Loose rock
  --@range 0 30
  rock_every = 6,          -- units mined per chunk knocked loose (0 = never)
  --@range 0 16
  rocks_max = 6,           -- loose chunks kept in the world; the oldest goes
  --@header Gravity gun
  --@range 4 40 --@units m
  grav_reach = 16.0,
  --@range 1 6 --@units m
  grav_min = 2.2,
  --@range 4 30 --@units m
  grav_max = 12.0,
  -- The power budget, in game units (t·m/s², tonnes are the game's mass):
  -- about 0.53 t held against the home world's pull (playtest 2026-10-27:
  -- "slightly more powerful" — was 4.0, +30 %; the weight still decides).
  --@range 0.5 40
  grav_force = 5.2,
  --@range 2 20 --@units rad/s
  grav_omega = 9.0,        -- how fast a light object snaps to the aim
  --@range 0.2 1.5
  grav_zeta = 0.8,         -- damping ratio of the pull
  --@range 0.02 3 --@units t
  grav_mref = 0.32,        -- stiffness stops growing with mass past this (was 0.25)
  --@range 0 10
  grav_spin_damp = 2.5,    -- how fast a held object's tumble dies
  --@range 2 40 --@units m/s
  grav_throw = 16.0,
  --@range 0.1 20
  grav_throw_max = 3.0,    -- the biggest kick a throw can give (t·m/s)
  --@range 2 20 --@units m
  grav_break = 7.0,        -- dragged this far behind the aim, the grip fails
  --@header Harvest (gravity gun on a plant)
  --@range 1 12 --@units m
  cut_reach = 7.0,         -- from the PLAYER to the plant's base
  --@range 0.3 4 --@units m
  cut_grab = 1.1,          -- how near the aim line has to pass the stem
  --@range 0.2 3
  uproot = 0.8,            -- × the species' cutting work
  --@header Laser cut (hold E)
  --@range 1.5 10 --@units m
  saw_reach = 5.0,         -- from the PLAYER: a cutting torch, not a rifle
  --@range 0.1 2 --@units m
  saw_grab = 0.6,          -- how near the beam has to pass a stem (a tree's crown is wider)
  --@range 0.2 3
  saw = 0.8,               -- × the species' cutting work, at full power and cold
  --@range 0.05 1 --@units s
  lock_grace = 0.25,       -- the beam may leave a locked plant this long and keep it
  --@header Depot intake
  --@range 5 40 --@units m
  intake = 22.0,           -- a held thing let go this near the Commerce Depot's centre is taken in (its apron: the lot is 32 × 18 m)
  --@range 0 5
  scrap_rate = 0.4,        -- $ per kg of debris recycled at the depot
}

-- Published: the HUD, the walker, the camera and the smoke harness read these.
tool = 1                 -- the equipped slot's position on the belt
prompt = ""
progress = 0.0
charge = 0.0     -- laser spin-up, 0..1
heat = 0.0       -- laser heat, 0..1; throttles the cut rate, never stops it
focus = 0.0      -- 0..1 how long the beam has stayed on one spot
aimMat = nil     -- what the crosshair is over, if it's rock (laser)
aimDepth = 0.0
aimDist = nil    -- metres to the aim point (nil = nothing in reach)
aimX, aimY, aimZ = nil, nil, nil
bored = 0.0      -- metres the current bore has eaten into the rock
inUse = false    -- the trigger is held on a tool in hand: the walker faces the aim
atReach = false  -- the bore has run out to arm's length
laserMode = "dig"  -- "dig" | "fill"
cutMode = false    -- the laser is in CUT (E held): it saws plants and never digs
holding = nil    -- { name, mass, strain, kind } while the gravity gun holds something
strain = 0.0     -- 0..1+ how hard the gravity gun is working
wantsScroll = false -- the gravity gun is using the wheel (the camera leaves it alone)
gate = "starting up"
hudText = ""
-- THE RETICLE'S SHAPE, by what is under it (draw_reticle): "none", "dig",
-- "fill", "cut", "grab", "heavy", "hold", "plant", "interact"; and the short
-- line under it naming the target and the key.
reticleKind = "none"
reticleLabel = ""
local function reticle_set(kind, label) reticleKind, reticleLabel = kind, label or "" end
-- The "collected +N" readout: { text, t } drawn under the reticle for a moment.
local collected = nil
local function collected_say(text) collected = { text = text, t = time } end
-- TEST HOOKS (probes and the smoke harness): `sim` overrides the mouse and
-- keys — { btn = { [0]=true }, pressed = { r = true }, scroll = n, aim = {ox,oy,oz,dx,dy,dz} | function → those six }.
sim = nil

-- What each kind of gear does on the belt. The ORDER is the belt's order.
TOOL_ORDER = { "gravgun", "laser", "surveyor", "beacon" }
TOOLDEF = {
  gravgun = { label = "Gravity Gun", prefab = "ToolGravGun", fp_prefab = "ToolGravGunFP",
              hint = "hold LMB to grab (rocks, crates, logs, debris, a beacon)  ·  scroll nearer / further  ·  R throw  ·  E stow what you hold  ·  let go in the depot's intake to deposit or recycle it  ·  aim at a plant to uproot it" },
  laser   = { label = "Terrain Laser", prefab = "ToolLaser", fp_prefab = "ToolLaserFP",
              hint = "hold LMB to dig  ·  Q switches DIG / FILL  ·  hold E: cut plants" },
  -- the TL-5 Surveyor plasma rifle: drawn and held here, fired by scripts/surveyor.lua
  surveyor = { label = "TL-5 Surveyor", prefab = "ToolSurveyor", fp_prefab = "ToolSurveyorFP",
              hint = "hold LMB to charge a bolt, let go to fire  ·  hold RMB: the scope  ·  H holsters" },
  beacon  = { label = "Relay Beacon", consumable = true,
              hint = "LMB set it down where the ghost is teal  ·  right-click a planted one → Pick up" },
}

-- Where the hands hold each model and where its beam leaves, relative to the
-- model's centre (tools/gen_tools.py prints these). `fore` is the other
-- hand's hold. The first-person models carry their own gloved hands and are
-- different meshes, so they have their own centre and their own numbers.
-- `vent` is where a tool sheds heat (the laser's heat haze rises from it).
RIG = {
  gravgun = { grip = { 0.0, -0.058, 0.127 }, muzzle = { 0.0, 0.032, -0.253 }, fore = { 0.0, -0.068, -0.082 }, vent = { 0.0, 0.096, -0.073 } },
  laser   = { grip = { 0.007, -0.052, 0.102 }, muzzle = { 0.007, 0.033, -0.298 }, fore = { 0.007, -0.085, -0.136 }, vent = { 0.007, 0.113, -0.136 } },
  surveyor = { grip = { 0.019, -0.039, 0.217 }, muzzle = { 0.019, 0.046, -0.475 }, fore = { 0.019, -0.06, -0.059 }, vent = { 0.019, 0.08, -0.163 } },
}
RIG_FP = {
  gravgun = { grip = { 0.092, 0.101, -0.042 }, muzzle = { 0.092, 0.191, -0.422 }, vent = { 0.092, 0.255, -0.242 } },
  laser   = { grip = { 0.091, 0.111, 0.049 }, muzzle = { 0.091, 0.196, -0.351 }, vent = { 0.091, 0.276, -0.189 } },
  surveyor = { grip = { 0.054, 0.117, 0.087 }, muzzle = { 0.054, 0.202, -0.605 }, vent = { 0.054, 0.236, -0.293 } },
}
-- THIRD PERSON: how each tool is carried, in the body's frame (metres from the
-- right shoulder joint: in toward the chest, down, forward), at rest (`low`,
-- a relaxed low-ready) and while the trigger is held (`aim`). Every tool is at
-- TRUE SIZE (scale 1): the gravity gun is 0.69 m long, the laser 0.60 m.
-- `pitch` is the low-ready's muzzle-down angle.
HOLD = {
  gravgun = { low = { 0.07, 0.25, 0.30 }, aim = { 0.08, 0.19, 0.33 }, pitch = -0.32,
              rwrist = { 0.02, 0.015, 0.065 }, lwrist = { -0.02, -0.015, 0.07 },
              rfing = { -0.1, -0.4, -0.9 }, lfing = { 0.25, -0.25, -0.93 } },
  laser   = { low = { 0.08, 0.25, 0.27 }, aim = { 0.10, 0.12, 0.24 }, pitch = -0.38,
              rwrist = { 0.02, 0.015, 0.065 }, lwrist = { -0.015, -0.035, 0.08 },
              rfing = { -0.1, -0.4, -0.9 }, lfing = { 0.15, 0.05, -0.98 } },
  -- the rifle (0.94 m): shouldered in the aim (the butt, 0.25 m behind the
  -- grip, in the shoulder's pocket), carried muzzle-down at rest
  surveyor = { low = { 0.07, 0.27, 0.25 }, aim = { 0.11, 0.08, 0.20 }, pitch = -0.5,
              rwrist = { 0.02, 0.015, 0.065 }, lwrist = { -0.015, -0.035, 0.08 },
              rfing = { -0.1, -0.4, -0.9 }, lfing = { 0.15, 0.05, -0.98 } },
}
-- The Laser Tool node (the old rifle, bone-attached to Hand.Right) still
-- carries the laser's particle beam; the tools themselves no longer hang off
-- it (see THE HOLD).
-- FIRST PERSON: where the grip sits in the camera's frame (+x right, +y up,
-- -z ahead), at true size, and the view-model camera's field of view.
local VIEW_AT = { 0.25, -0.205, -0.62 }  -- low right, the gloves in sight on both grips
local VIEW_SCALE = 1.0
-- The view model is toed in so its muzzle points at the crosshair this far
-- out (m), and canted (rad, + = top to the left). It turns about its GRIP,
-- which stays at VIEW_AT. Toed in at 2.5 m and canted a fifth of a turn to
-- the right, the tool shows its left flank (the nameplate, the coil, the
-- claws or the heat sink) and the off hand round its fore-grip, instead of
-- only its back end.
local VIEW_TOE = 2.5
local VIEW_CANT = -0.35
-- A point in the view model's frame turned by its angles (node:setAngles:
-- yaw about Y, then pitch about X, then roll about Z).
local function vm_rot(yw, pt, rl, x, y, z)
  local cr, sr = math.cos(rl), math.sin(rl)
  x, y = x * cr - y * sr, x * sr + y * cr
  local cp, sp = math.cos(pt), math.sin(pt)
  y, z = y * cp - z * sp, y * sp + z * cp
  local cy, sy = math.cos(yw), math.sin(yw)
  return x * cy + z * sy, y, -x * sy + z * cy
end
local VM_FOV = 0.95
-- The render layer the view models live on: "viewmodel" (project.ron), else
-- the project's spare "entity" layer — the bit is the layer's place in
-- project.ron's list, after the implicit Default at 0. tests/smoke_toolgate.lua
-- checks the list still says so.
local VM_LAYERS = { { "viewmodel", 3 }, { "entity", 1 } }

local SFX = {
  hum     = "audio/foley/bore_hum.ogg",
  ore     = "audio/kenney/impact/impactMining_00",   -- + 0..4
  denied  = "audio/foley/buzz_denied.ogg",
  swap    = "audio/foley/switch_2.ogg",
  plant   = "audio/foley/latch_clunk.ogg",
  pickup  = "audio/kenney/impact/impactPlate_light_001.ogg",
  grab    = "audio/foley/hiss_seal.ogg",
  hold    = "audio/foley/rover_motor.ogg",
  drop    = "audio/foley/hiss_short.ogg",
  throw   = "audio/foley/hiss_cylinder.ogg",
  dry     = "audio/foley/relay_tick.ogg",
  fill    = "audio/kenney/impact/impactSoft_heavy_002.ogg",
  mode    = "audio/foley/toggle_on.ogg",
}

local cam
local last_t = -10
local msg, msg_t = "", -10

local cut_progress = 0.0
local hum = nil
local last_hit = nil
local bore = nil             -- { body, x, y, z } — the live cut point, planet frame
local denied_t = -10
local shake_pub = false
local impact_n
local units_mined = 0
local fill_credit = 0

-- Cross-script singletons, resolved once and kept (findScript walks the scene).
local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or not r.valid then r = findScript(kind); refs[kind] = r end
  return r
end

-- The interface's design height: 720 at an interface size of 100%, 847 at
-- 85% (settings.lua `designHeight`, Settings ▸ Display ▸ Interface size).
-- Screen pixels turn into design units through this, never through 720.
function uiDesignH()
  local st = ref("settings")
  return (st and st.designHeight and st.designHeight()) or 720
end

-- Cinematic mode (planet_camera, F4 / F5): the interface is hidden, and the
-- markers this script paints straight onto the screen go with it.
function cinematicUp()
  local pc = ref("planet_camera")
  return pc ~= nil and pc.cinematic == true
end

-- THE FREE CAMERA (planet_camera, F5) has the keyboard and mouse while it
-- flies: W A S D, SPACE, CTRL and SHIFT move the camera, so this script must
-- not also read them. One proxy over `input` (this script's own global; the
-- engine's table is untouched) rather than a test at every key.
if type(input) == "table" then
  local raw, pc, pc_miss = input, nil, -10.0
  local function free()
    if not (pc and pc.valid) then
      local now = time or 0
      if now - pc_miss < 2.0 then return false end
      pc = findScript and findScript("planet_camera") or nil
      if not pc then pc_miss = now return false end
    end
    return pc.freecam == true
  end
  local function key_gate(name)
    return function(...) if free() then return false end return raw[name](...) end
  end
  input = setmetatable({
    key = key_gate("key"), pressed = key_gate("pressed"), released = key_gate("released"),
    button = key_gate("button"), clicked = key_gate("clicked"),
    scroll = function() if free() then return 0 end return raw.scroll() end,
    action = function(...) if free() then return false end return raw.action and raw.action(...) end,
    mouse_delta = function() if free() then return 0, 0 end return raw.mouse_delta() end,
    setMouseLocked = function(on) if free() then return end return raw.setMouseLocked(on) end,
  }, { __index = raw })
end

local function say(s)
  msg, msg_t = s, time
end

local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end

-- ── input, with the test hooks ──────────────────────────────────────────────

local function btn(i)
  if sim and sim.btn and sim.btn[i] ~= nil then return sim.btn[i] == true end
  return input.button(i) == true
end
local function sim_pressed(k)
  if sim and sim.pressed and sim.pressed[k] then sim.pressed[k] = nil return true end
  return false
end
local function pressed(k)
  return sim_pressed(k) or input.pressed(k) == true
end
-- The two letter keys the belt owns, spelt out so the controls card's lint
-- (tests/smoke_pause.lua) can see them read.
local function key_q() return sim_pressed("q") or input.pressed("q") == true end
local function key_r() return sim_pressed("r") or input.pressed("r") == true end
-- E is HELD for the laser's cut (the Interact action, so a pad's west face
-- and a rebind work too). `sim.keys.e` overrides it for probes.
local function key_e()
  if sim and sim.keys and sim.keys.e ~= nil then return sim.keys.e == true end
  return input.key("e") == true or (input.action ~= nil and input.action("Interact") == true)
end
local function scroll()
  local s = (input.scroll and input.scroll()) or 0
  if sim and sim.scroll then s = s + sim.scroll; sim.scroll = nil end
  return s
end

local function play(path, o)
  if audio and audio.play then return audio.play(path, o) end
end

-- ── the belt: built from the pack ───────────────────────────────────────────

-- Old saves picked a slot by number: 1 laser, 2 cutter, 3 spade, 4 beacon.
local OLD_SLOT = { "laser", "gravgun", "laser", "beacon" }

-- The belt as it stands: { { id, label, n, consumable }, ... } in TOOL_ORDER.
function belt()
  -- THE ITEMS' BELT (scripts/item_hand.lua → items.belt): every holdable item
  -- in the pack, tools first. The hand is item_hand's; this script draws and
  -- fires the two tools and follows what it says is in hand.
  local H = ref("item_hand")
  if H and H.belt then return H.belt() end
  local inv = ref("inventory")
  local out = {}
  for _, id in ipairs(TOOL_ORDER) do
    local d = TOOLDEF[id]
    local n = (inv and inv.gearCount) and inv.gearCount("astro", id) or 0
    if n > 0 then out[#out + 1] = { id = id, label = d.label, n = n, consumable = d.consumable == true } end
  end
  return out
end

local equipped = nil   -- the equipped gear id

-- The item in hand: item_hand's (nil = empty hands), else the old belt's.
function toolId()
  local H = ref("item_hand")
  if H and H.held then return H.held() end
  return equipped or "gravgun"
end
-- §5.4's names for it.
function held() return toolId() end
function hold(id)
  local H = ref("item_hand")
  if H and H.hold then return H.hold(id) end
  return false, "no item hand in this scene"
end

local function slot_of(id, b)
  for i, s in ipairs(b) do if s.id == id then return i end end
  return nil
end

-- ── who is driving ──────────────────────────────────────────────────────────
-- Only the on-foot astronaut carries tools, and never while a panel owns the
-- keys. The reason is kept (`gate`) and logged once per change: a silent
-- refusal is a bug report nobody can act on.
local last_why = ""
local GATE_ABOARD = "the crew is aboard a craft, or the world is still loading"
local GATE_MAP = "the orbit map is open"

-- `key` is what is logged on: a reason with a live number in it (how far
-- the camera is) must not log a line every frame it changes.
local function why(reason, key)
  gate = reason
  key = key or reason
  if key ~= last_why then
    last_why = key
    log("tools: " .. reason)
  end
end

local function on_foot(node)
  -- planet_walker.onFoot, not node.visible: the camera hides the body in
  -- first person and whenever a wall pushes the view into the shoulders.
  local pw = ref("planet_walker")
  if not pw then why("no planet_walker in the scene — the belt can't tell who's driving") return false end
  local gm = ref("game_manager")
  if gm and gm.inputOwner == "builder" then why(GATE_ABOARD, "builder") return false end -- the VAB builder has the keys
  if pw.onFoot ~= true then why(GATE_ABOARD) return false end
  if pw.swimming == true then why("swimming") return false end
  local pm = ref("pause_menu")
  if pm and pm.open then why("the game is paused") return false end
  local fm = ref("facility_menu")
  if fm and fm.isOpen and fm.isOpen() then why("a facility panel has the keys") return false end
  local ob = ref("ops_board")
  if ob and ob.isOpen and ob.isOpen() then why("the ops board has the keys") return false end
  local ip = ref("inventory_panel")
  if ip and ip.open then why("the suit pack has the keys") return false end
  -- Held at a job (a repair): the hands are on the hull, not on a tool.
  local H = ref("item_hand")
  if H and H.busy and H.busy() then why("the hands are at the work") return false end
  -- A right-click menu is up (context_menu.lua): its rows take the left
  -- button, which must not also fire the tool through them.
  local cm = ref("context_menu")
  if cm and cm.isOpen and cm.isOpen() then why("a context menu has the pointer") return false end
  -- The map owns the camera (and the camera's screen ray starts thousands of
  -- metres out): no aiming, no rays, no plant queries from there.
  local om = ref("orbit_map")
  if om and om.isOpen and om.isOpen() then why(GATE_MAP) return false end
  why("in hand")
  return true
end

-- ── what the rock is ────────────────────────────────────────────────────────

local function depth_at(body, x, y, z)
  local dx, dy, dz = x - body.x, y - body.y, z - body.z
  local r = len(dx, dy, dz)
  if r < 1e-3 then return 0 end
  local ux, uy, uz = dx / r, dy / r, dz / r
  local top = 120.0
  local hit = raycast(x + ux * top, y + uy * top, z + uz * top, -ux, -uy, -uz, top + 4.0)
  if not hit then return 0 end
  local hr = len(hit.x - body.x, hit.y - body.y, hit.z - body.z)
  return math.max(0, hr - r)
end

-- WHAT IS THIS ROCK? Asked by the reticle to preview a cut and by the beam to
-- resolve one: one function, so the crosshair never promises what the cut
-- doesn't deliver. A smooth per-world noise field, in the planet's own frame,
-- so a seam is a place you can follow.
function survey(x, y, z)
  local mats = ref("materials")
  local cl = ref("climate")
  local body = space.body(space.dominant(x, y, z) or "")
  if not (body and mats) then return nil, 0 end
  local w = cl and cl.worldOf(body.name)
  local depth = depth_at(body, x, y, z)
  local seed = (w and w.seed or 1) % 4096
  local lx, ly, lz = x - body.x, y - body.y, z - body.z
  local n1 = math.noise(lx * 0.035, ly * 0.035, lz * 0.035, seed)
  local n2 = math.noise(lx * 0.19, ly * 0.19, lz * 0.19, seed + 3)
  local mix = (n1 * 0.62 + n2 * 0.38) * 2.5 + 0.5
  local roll = mix - math.floor(mix)
  return mats.pickOre(w and w.kind or "barren", depth, roll), depth, (n2 > 0.45)
end

-- ── aiming ──────────────────────────────────────────────────────────────────

local function aim_pixel()
  local vx, vy, vw, vh = camera.screenRect()
  if not vw or vw <= 0 then return nil end
  if cam and cam.mouseLooking == false and input.mouse then
    local mx, my = input.mouse()
    if mx and mx >= vx and mx <= vx + vw and my >= vy and my <= vy + vh then return mx, my end
  end
  return vx + vw * 0.5, vy + vh * 0.5
end

local function aim_ray(node)
  if sim and sim.aim then
    local a = sim.aim
    -- a function is asked at the moment of use (a probe's aim, worked out
    -- from this frame's positions: a point kept from an earlier frame is
    -- metres off on a planet that moves)
    if type(a) == "function" then a = { a() } end
    if not a[1] then return nil end
    local l = len(a[4], a[5], a[6])
    return a[1], a[2], a[3], a[4] / l, a[5] / l, a[6] / l
  end
  local sx, sy = nil, nil
  if camera and camera.screenToRay and camera.screenRect then sx, sy = aim_pixel() end
  if sx then
    local ox, oy, oz, dx, dy, dz = camera.screenToRay(sx, sy)
    local l = len(dx, dy, dz)
    -- The ACTIVE camera's ray: if that camera is not near the crew (a map, a
    -- tracking view, a cutscene), there is nothing to aim at from here, and
    -- every query below would be thousands of metres long.
    if l > 1e-6 and len(ox - node.x, oy - node.y, oz - node.z) < 60 then
      return ox, oy, oz, dx / l, dy / l, dz / l
    end
    return nil
  end
  if not (cam and cam.cam_x and cam.fwd_x) then return nil end
  return cam.cam_x, cam.cam_y, cam.cam_z, cam.fwd_x, cam.fwd_y, cam.fwd_z
end

-- The first solid along the ray, with the reach measured from the PLAYER.
local function ray_hit(node, ox, oy, oz, dx, dy, dz, reach, ignore)
  local back = len(node.x - ox, node.y - oy, node.z - oz)
  local h = raycast(ox, oy, oz, dx, dy, dz, back + reach, ignore or node)
  if not h then return nil end
  local d = len(h.x - node.x, h.y - node.y, h.z - node.z)
  if d > reach then return nil end
  h.range = d
  return h
end

local function laser_shot(node)
  local ox, oy, oz, dx, dy, dz = aim_ray(node)
  if not ox then return nil end
  return ray_hit(node, ox, oy, oz, dx, dy, dz, params.laser_reach)
end

-- ── planet frame ────────────────────────────────────────────────────────────
-- Planets only translate, so a point held as an offset from its body's centre
-- is exact across the rails' step between update and the picture.

local function to_body(hit)
  local t = {}
  for k, v in pairs(hit) do t[k] = v end
  local name = space.dominant(hit.x, hit.y, hit.z)
  local b = name and space.body(name)
  if b then t.body, t.x, t.y, t.z = name, hit.x - b.x, hit.y - b.y, hit.z - b.z end
  return t
end

local function to_world(t)
  local w = {}
  for k, v in pairs(t) do w[k] = v end
  local b = t.body and space.body(t.body)
  if b then w.x, w.y, w.z = b.x + t.x, b.y + t.y, b.z + t.z end
  return w
end

-- A cached answer's WORLD points, kept up with the planet. `carry_mark`
-- stamps a cache with the world under `at` as it is now; `carry_since` moves
-- each table's x,y,z (and a plant's ax,ay,az) on by how far that world has
-- moved since, and re-stamps. The 0.1 s previews of the gravity gun and the
-- cut were reused with their world points as found, up to six ticks of the
-- planet's travel old: the mark, the aim and the crew's facing pointed metres
-- off the plant (playtest 2026-10-27).
function carry_mark(c, at)
  local name = at and space.dominant(at.x, at.y, at.z)
  local b = name and space.body(name)
  if b then c.cbody, c.cbx, c.cby, c.cbz = name, b.x, b.y, b.z end
  return c
end
function carry_since(c, list)
  local b = c.cbody and space.body(c.cbody)
  if not b then return end
  local dx, dy, dz = b.x - c.cbx, b.y - c.cby, b.z - c.cbz
  if dx == 0 and dy == 0 and dz == 0 then return end
  local seen = {}
  for i = 1, 3 do
    local t = list[i]
    if type(t) == "table" and not seen[t] then
      seen[t] = true
      if type(t.x) == "number" then t.x, t.y, t.z = t.x + dx, t.y + dy, t.z + dz end
      if type(t.ax) == "number" then t.ax, t.ay, t.az = t.ax + dx, t.ay + dy, t.az + dz end
    end
  end
  c.cbx, c.cby, c.cbz = b.x, b.y, b.z
end

-- ── the bore ────────────────────────────────────────────────────────────────

local function bore_world()
  if not bore then return nil end
  local b = bore.body and space.body(bore.body)
  if not b then return bore.x, bore.y, bore.z end
  return b.x + bore.x, b.y + bore.y, b.z + bore.z
end

local function bore_hold(x, y, z)
  local b = space.body(space.dominant(x, y, z) or "")
  if b then bore = { body = b.name, x = x - b.x, y = y - b.y, z = z - b.z }
  else bore = { body = nil, x = x, y = y, z = z } end
end

local function bore_drop()
  bore, bored, atReach = nil, 0.0, false
end

local function bore_step(node, dt, ox, oy, oz, dx, dy, dz, entry)
  if not entry then bore_drop() return nil end
  local t, t0 = nil, nil
  local wx, wy, wz = bore_world()
  if wx then
    t = (wx - ox) * dx + (wy - oy) * dy + (wz - oz) * dz
    local px, py, pz = ox + dx * t, oy + dy * t, oz + dz * t
    local perp = len(wx - px, wy - py, wz - pz)
    if t <= 0 or perp > params.regrip then bore, t = nil, nil end
  end
  if t then
    t0 = t
    t = t + params.bore_speed * dt * charge
  else
    t = len(entry.x - ox, entry.y - oy, entry.z - oz)
  end
  local px, py, pz = ox + dx * t, oy + dy * t, oz + dz * t
  local far = len(px - node.x, py - node.y, pz - node.z)
  atReach = far > params.laser_reach
  if atReach then
    t = math.max(0.0, t - (far - params.laser_reach))
    px, py, pz = ox + dx * t, oy + dy * t, oz + dz * t
  end
  bore_hold(px, py, pz)
  -- Distance travelled, accumulated: an entry point remembered in world space
  -- would be kilometres behind an orbiting planet within seconds.
  bored = t0 and (bored + math.max(0.0, t - t0)) or 0.0
  return px, py, pz
end

-- ── quiet ground: what a terrain edit must not drag along with it ──────────
-- The engine lays again every decal whose ground an edit touches, and packs
-- and uploads that picture's whole batch, outside every perf bucket. Measured
-- in play (rc6, Kail's meadow, 150 flora wash decals): a held click cost
-- 120–980 ms a frame; with the wash lifted, 1–2 ms. The flora field owns its
-- wash, so it is asked to lift it round the cut — once per place, not per
-- bite. (`liftWash` arrives with the flora field's patch; without it this is
-- a no-op and digging on a meadow is slow again.)
-- Re-measured on engine 0.117.0-rc7 (card 0481: a dig re-lays only the marks
-- it reached, budgeted): on Kail's meadow, 21–27 bites at 0.12 s with 43–143
-- washes laid, the dig frames still reached 173–326 ms without the lift (the
-- worst untimed, the turf batch rebuilt whole) against 115–170 ms with it.
-- So the lift stays.
local quiet = { body = nil, x = 0, y = 0, z = 0, t = -10 }
local function quiet_ground(x, y, z)
  local name = space.dominant(x, y, z)
  local b = name and space.body(name)
  if not b then return end
  local lx, ly, lz = x - b.x, y - b.y, z - b.z
  if quiet.body == name and time - quiet.t < 4.0
    and len(lx - quiet.x, ly - quiet.y, lz - quiet.z) < 10.0 then
    quiet.t = time
    return
  end
  quiet.body, quiet.x, quiet.y, quiet.z, quiet.t = name, lx, ly, lz, time
  local ff = ref("flora_field")
  -- 110 m, not the bite's few: the engine records a terrain edit as the
  -- touched 48 m chunks' bounding spheres (43 m), and re-lays every decal
  -- that reaches one — a 29 m wash reaches ~28 m.
  if ff and ff.liftWash then ff.liftWash(x, y, z, 110.0, 8.0) end
end

-- Every bite and every fill tells the fields where the ground moved, so the
-- plants and rocks there are dropped onto the new ground (flora_field
-- groundChanged: folded into one region per place, re-dropped once it is
-- quiet; it tells mineral_field too).
function groundChanged(x, y, z, r)
  local ff = ref("flora_field")
  if ff and ff.groundChanged then ff.groundChanged(x, y, z, r) end
end

-- ── shake and sound helpers ─────────────────────────────────────────────────

local function publish_shake(v)
  if v > 0.002 then
    save.set("cam.shake", math.min(1.0, v))
    shake_pub = true
  elseif shake_pub then
    save.set("cam.shake", 0.0)
    shake_pub = false
  end
end

local function hum_off()
  if hum then hum:stop() hum = nil end
end

local function hum_on(path, vol, pitch)
  if not hum then hum = play(path, { track = "SFX", loop = true, volume = 0.0 }) end
  if hum then
    hum:setVolume(vol)
    hum:setPitch(pitch)
  end
end

-- ── the models: third person in the hands, first person in front of the eye ─
--
-- Two models of each tool. THIRD PERSON, the tool is placed by this script in
-- the body's frame (a child of the AstroModel), at true size, and the arms are
-- put on it — not the other way round: hung off the hand bone, it inherited
-- the armature's ½ scale and stood at 60 % of life size ("in third person the
-- tools look super small"), and it went wherever a clip happened to put the
-- hand. FIRST PERSON, a second model with the crew's gloved hands built in
-- rides the camera on a render layer of its own, filmed by a VIEW-MODEL
-- camera stacked over the main one (docs/camera-stacks.md): it is drawn over
-- an empty depth buffer, so it never pushes into a wall, and it has its own
-- narrower field of view. The main camera leaves that layer out.

local models = { tp = {}, fp = {} }    -- id → node | "spawning"
local hand_n, socketed = nil, false
local view = { sx = 0, sy = 0, vx = 0, vy = 0, kick = 0, kickv = 0, bob = 0, lfx = nil, lfy = nil, lfz = nil, dip = 0 }
recoil = 0.0
local aim_body = nil      -- the aim point in its planet's frame (see `update`)
-- Published for probes: where the third-person right hand is sent (nil while
-- the hold is off).
gripX, gripY, gripZ = nil, nil, nil
-- Tool swaps: the old tool dips out of the hands and the new one comes up.
local swap_t, swap_from = -10.0, nil
local SWAP_SECS = 0.36
-- The tools with models of their own, drawn and held here.
HELD_MODELS = { "gravgun", "laser", "surveyor" }
local vm = { layer = nil, bit = nil, cam = nil, making = false, on = false, main = nil }

local function hand()
  if not (hand_n and hand_n.valid) then hand_n = find("Laser Tool"); socketed = false end
  if hand_n and not socketed then
    -- The hand node is only the particle beam's mount now; its own mesh was
    -- the old stand-in rifle, swapped for a few millimetres of nothing.
    socketed = true
    hand_n.model = "models/tools/socket.glb"
    hand_n.visible = true
  end
  return hand_n
end

-- The view-model layer: the first of VM_LAYERS this project defines.
local function vm_layer(n)
  if vm.layer == false then return false end
  if vm.layer then n.layer = vm.layer return true end
  for _, l in ipairs(VM_LAYERS) do
    if pcall(function() n.layer = l[1] end) then
      vm.layer, vm.bit = l[1], l[2]
      return true
    end
  end
  vm.layer = false
  log("tool_belt: no render layer for the first-person view model (add \"viewmodel\" to project.ron's layers)")
  return false
end

local function model_of(set, id, parent, place)
  local m = models[set][id]
  if m == "spawning" then return nil end
  if m and m.valid then return m end
  local d = TOOLDEF[id]
  local prefab = d and (set == "fp" and d.fp_prefab or d.prefab)
  if not (prefab and parent and spawn) then return nil end
  models[set][id] = "spawning"
  spawn(prefab, parent.worldPos or vec3(parent.x, parent.y, parent.z), function(n)
    models[set][id] = n
    n.visible = false
    n.castShadow = set == "tp"
    if set == "fp" then vm_layer(n) end
    n:setParent(parent, { keepWorld = false })
    place(n, id)
  end)
  return nil
end

local function place_tp(n, id)
  n.scale = 1.0
  n.x, n.y, n.z = 0, 1.0, 0.3
  n:setAngles(0, 0, 0)
end

local function place_fp(n, id)
  local g = RIG_FP[id].grip
  local yw, pt = math.atan(VIEW_AT[1] / VIEW_TOE), math.atan(-VIEW_AT[2] / VIEW_TOE)
  local gx, gy, gz = vm_rot(yw, pt, VIEW_CANT, g[1] * VIEW_SCALE, g[2] * VIEW_SCALE, g[3] * VIEW_SCALE)
  n.scale = VIEW_SCALE
  n.x, n.y, n.z = VIEW_AT[1] - gx, VIEW_AT[2] - gy, VIEW_AT[3] - gz
  n:setAngles(yw, pt, VIEW_CANT)
end

local function cam_node()
  return cam and cam.node and cam.node.valid and cam.node or nil
end

local function first_person()
  return cam ~= nil and cam.firstPerson == true
end

-- THE VIEW-MODEL CAMERA. Made once, a child of the main camera at zero
-- offset; stacked on it (and the layer taken out of it) only while the view
-- models can show, so third person pays for neither the second render nor
-- the main camera's layer test.
local function view_model_cam(cn, on)
  if on and vm.layer == nil then return end            -- no view model spawned yet
  if on and vm.layer == false then on = false end
  if on and not (vm.cam and vm.cam.valid) then
    if not vm.making and createNode then
      vm.making = true
      createNode("ViewModel Cam", cn, function(n)
        n.x, n.y, n.z = 0, 0, 0
        n:setAngles(0, 0, 0)
        n:setCamera { fovY = VM_FOV, active = false, cullMask = 2 ^ vm.bit }
        vm.cam, vm.making = n, false
      end)
    end
    return
  end
  if vm.on == on and vm.main == cn then return end
  -- Everything the main camera may draw: planet_camera's base (the interior
  -- and offstage layers are never the main camera's, docs/crew-and-items.md §3.4).
  local all = 4294967295
  if cam and cam.cullBase then all = cam.cullBase() end
  if vm.main and vm.main.valid and vm.main ~= cn then
    pcall(function() vm.main:setCamera { stack = {}, cullMask = all } end)
  end
  local ok, err = pcall(function()
    if on then cn:setCamera { stack = { "ViewModel Cam" }, cullMask = all - 2 ^ vm.bit }
    else cn:setCamera { stack = {}, cullMask = all } end
  end)
  if ok then vm.on, vm.main = on, cn
  else log("tool_belt: the view-model camera stack failed: " .. tostring(err)) end
end

-- The crew (the Astronaut, which this script normally rides), its animated
-- model (the AstroModel child) and that model's animator.
local astro_n, astro_model, astro_anim = nil, nil, nil
local function crew_model()
  if not (astro_n and astro_n.valid) then astro_n, astro_model, astro_anim = find("Astronaut"), nil, nil end
  if not astro_n then return nil end
  if not (astro_model and astro_model.valid) then
    astro_model, astro_anim = nil, nil
    for _, c in ipairs((astro_n.children and astro_n:children()) or {}) do if c.name == "AstroModel" then astro_model = c end end
  end
  if astro_model and not astro_anim and astro_model.animator then astro_anim = astro_model:animator() end
  return astro_model, astro_anim, astro_n
end

-- For probes: the view model's state in a line.
function viewModelState()
  return string.format("layer %s bit %s cam %s on %s main %s", tostring(vm.layer), tostring(vm.bit),
    tostring(vm.cam and vm.cam.valid), tostring(vm.on), tostring(vm.main and vm.main.name))
end

-- The tool to show: the equipped one, except halfway through a swap, when the
-- one going away is still in the hands.
local function shown_tool(want)
  if swap_from and time - swap_t < SWAP_SECS * 0.5 then return swap_from end
  return want
end
-- 0 → 1 → 0 across a swap: how far the tools have dipped out of the way.
local function swap_dip()
  local k = (time - swap_t) / SWAP_SECS
  if k >= 1 or k < 0 then return 0.0 end
  return math.sin(k * math.pi)
end

-- The view model's angles this frame: the toe-in, the sway, the kick and a
-- swap's dip (show_models places it; muzzle() follows the same turn).
local function vm_angles()
  local dip = swap_dip()
  return math.atan(VIEW_AT[1] / VIEW_TOE) + view.sx * 1.2,
    math.atan(-VIEW_AT[2] / VIEW_TOE) + view.kick * 1.4 + view.sy * 1.0 - dip * 0.7,
    VIEW_CANT - view.sx * 1.5
end

-- Show the equipped tool in the right place (or nothing), and move the first-
-- person model: sway against the look, bob with the walk, kick on recoil.
local function show_models(node, dt, carrying)
  local h = hand()
  local cn = cam_node()
  local want = carrying and shown_tool(toolId()) or nil
  local fp = first_person()
  local am = crew_model()
  -- (the rifle aimed down its scope in first person: the scope's picture,
  -- not the view model)
  local SV = want == "surveyor" and ref("surveyor") or nil
  local scoped_fp = fp and SV ~= nil and (SV.scopeK or 0) > 0.6
  for _, id in ipairs(HELD_MODELS) do
    local tp = am and model_of("tp", id, am, place_tp)
    local fv = cn and model_of("fp", id, cn, place_fp)
    local on = want == id
    if tp and tp.visible ~= (on and not fp) then tp.visible = on and not fp end
    local fon = on and fp and not scoped_fp
    if fv and fv.visible ~= fon then fv.visible = fon end
  end
  if cn then view_model_cam(cn, fp and want ~= nil and not scoped_fp) end
  if not (fp and want and cn) then return end
  local fv = models.fp[want]
  if not (fv and fv ~= "spawning" and fv.valid) then return end
  -- Sway: the model lags the look by a spring, so a flick of the mouse swings
  -- it and it settles back. Small: a suited arm is steady, not a pendulum.
  local fx, fy, fz = cam.fwd_x or 0, cam.fwd_y or 0, cam.fwd_z or 0
  local r = cn:worldRight()
  local u = cn:worldUp()
  if view.lfx then
    local ddx, ddy, ddz = fx - view.lfx, fy - view.lfy, fz - view.lfz
    local yaw_rate = (ddx * r.x + ddy * r.y + ddz * r.z) / math.max(dt, 1e-3)
    local pit_rate = (ddx * u.x + ddy * u.y + ddz * u.z) / math.max(dt, 1e-3)
    view.vx = view.vx - math.max(-6, math.min(6, yaw_rate)) * 0.008
    view.vy = view.vy - math.max(-6, math.min(6, pit_rate)) * 0.008
  end
  view.lfx, view.lfy, view.lfz = fx, fy, fz
  local k, c = 110.0, 17.0
  view.vx = view.vx + (-k * view.sx - c * view.vx) * dt
  view.vy = view.vy + (-k * view.sy - c * view.vy) * dt
  view.sx = math.max(-0.035, math.min(0.035, view.sx + view.vx * dt))
  view.sy = math.max(-0.03, math.min(0.03, view.sy + view.vy * dt))
  -- Bob: a figure-eight with the stride, from the crew's speed over the
  -- ground (the planet's own motion taken out), at the walker's step rate.
  local sp = 0
  local pw = ref("planet_walker")
  if node.vel then
    local v = node.vel
    sp = math.min(9, len(v.x, v.y, v.z))
    if pw and pw.grounded == false then sp = 0 end
  end
  view.bob = view.bob + dt * (sp / 1.6) * math.pi
  local bob = math.min(1, sp / 5)
  local bx = math.sin(view.bob) * 0.006 * bob
  local by = math.abs(math.cos(view.bob)) * 0.008 * bob
  -- Recoil: a damped kick back and up.
  view.kickv = view.kickv + (-160 * view.kick - 18 * view.kickv) * dt + recoil * 9.0
  recoil = 0.0
  view.kick = math.max(-0.02, math.min(0.07, view.kick + view.kickv * dt))
  -- A swap drops the tool out of the bottom of the view and brings the new
  -- one up; a held trigger brings the tool in a touch toward the middle.
  local dip = swap_dip()
  local lean = inUse and 0.012 or 0.0
  -- Toed in toward the crosshair VIEW_TOE out, then the sway's lag and the
  -- kick; turned about the grip, so the hand stays where VIEW_AT puts it.
  local yw, pt, rl = vm_angles()
  local g = RIG_FP[want].grip
  local gx, gy, gz = vm_rot(yw, pt, rl, g[1] * VIEW_SCALE, g[2] * VIEW_SCALE, g[3] * VIEW_SCALE)
  fv.x = VIEW_AT[1] - gx + view.sx + bx - lean
  fv.y = VIEW_AT[2] - gy + view.sy - by + view.kick * 0.2 - dip * 0.22
  fv.z = VIEW_AT[3] - gz + view.kick
  fv:setAngles(yw, pt, rl)
end

-- THE HOLD (third person). The rig's clips carry nothing in their hands, so
-- the tool is placed in the BODY's frame — off the right shoulder as the
-- clips and the lean put it this frame, along the aim while the trigger is
-- held, at a relaxed low-ready otherwise — and both hands are put on its
-- grips (two-bone IK, this frame only), elbows down and out.
--
-- The frame is the MODEL's, never the camera's. The hold used to be built on
-- the camera's forward: walk toward the camera, or stand side-on to it, and
-- the hands were sent behind the back or across the chest, which folded the
-- elbows into the torso ("his elbows are inside his chest"). The body turns
-- to face the aim whenever a tool runs (planet_walker), so the aim's own
-- direction is only ever a few degrees off the body's, and it is clamped.
--
-- In lateUpdate, after planet_walker's (the same node, the script listed
-- first): the shoulders read here carry this frame's lean, and every point is
-- in the world the engine re-poses the rig in.
-- (the mechanisms' springs: see THE MECHANISMS below; the hold reads the kick)
local mech = { claw = 0.0, clawv = 0.0, spin = 0.0, spinv = 0.0, kick = 0.0, kickv = 0.0, pt = -10.0 }
local hold = { dir = nil, w = 0.0, id = nil, a = 0.0 }
local function hold_pose(dt, active)
  local m, an, node = crew_model()
  hold.w = hold.w + ((active and 1 or 0) - hold.w) * (1 - math.exp(-(active and 10 or 14) * dt))
  if not (an and an.reach and m and node and cam and cam.fwd_x) or hold.w < 0.01 then
    if not active then hold.dir = nil end
    gripX = nil
    return
  end
  local id = shown_tool(toolId())
  local hd, rg = HOLD[id], RIG[id]
  local tp = models.tp[id]
  if not (hd and rg) then return end
  local sr = an:boneWorld("Upperarm.Right")
  local sl = an:boneWorld("Upperarm.Left")
  if not (sr and sl) then return end
  local SR = m:toLocal(sr)
  -- The aim in the model's frame (+Z ahead, +Y up, +X the crew's LEFT).
  local o = m:toWorld(vec3(0, 0, 0))
  local function to_model_dir(x, y, z) return m:toLocal(o + vec3(x, y, z)) end
  local want
  local ax, ay, az = aimNow()
  if inUse and ax then
    local ch = (sr + sl) * 0.5
    want = to_model_dir(ax - ch.x, ay - ch.y, az - ch.z)
  else
    -- At rest the muzzle is held low and straight ahead of the body, with a
    -- share of the view's pitch so looking up brings it up a little.
    local f = to_model_dir(cam.fwd_x, cam.fwd_y, cam.fwd_z)
    local fl = math.sqrt(f.x * f.x + f.z * f.z)
    local p = math.atan2(f.y, math.max(fl, 1e-4)) * 0.35 + hd.pitch
    want = vec3(0, math.sin(p), math.cos(p))
  end
  want = want:normalized()
  -- Clamp: never more than 40° off the body's heading, up 65°, down 70°.
  local yaw = math.atan2(want.x, want.z)
  local pit = math.asin(math.clamp(want.y, -1, 1))
  yaw = math.clamp(yaw, -0.7, 0.7)
  pit = math.clamp(pit, -1.2, 1.13)
  -- A swap dips the muzzle toward the ground and back up.
  local dip = swap_dip()
  pit = pit - dip * 0.9
  want = vec3(math.sin(yaw) * math.cos(pit), math.sin(pit), math.cos(yaw) * math.cos(pit))
  if not hold.dir or hold.id ~= id and hold.w < 0.05 then hold.dir = want end
  hold.dir = (hold.dir + (want - hold.dir) * (1 - math.exp(-(inUse and 16 or 9) * dt))):normalized()
  hold.id = id
  local dir = hold.dir
  -- The tool's axes in the model frame: barrel (-Z) along `dir`, its up the
  -- body's up made square to it, its right = dir × up (the model's −X ahead).
  local yu = (vec3(0, 1, 0) - dir * dir.y):normalized()
  local xr = dir:cross(yu)
  -- The grip, off the right shoulder: in, down and forward, the low-ready
  -- easing into the aim as the trigger is held.
  local a = inUse and 1 or 0
  hold.a = hold.a + (a - hold.a) * (1 - math.exp(-10 * dt))
  local lo, ai = hd.low, hd.aim
  local inn = lo[1] + (ai[1] - lo[1]) * hold.a
  local down = lo[2] + (ai[2] - lo[2]) * hold.a + dip * 0.08
  local fwdv = lo[3] + (ai[3] - lo[3]) * hold.a
  local flat = vec3(dir.x, 0, dir.z)
  if flat:length() < 1e-4 then flat = vec3(0, 0, 1) end
  flat = flat:normalized()
  -- Forward along the aim's heading; raised a little as the aim rises.
  local grip = SR + vec3(inn, -down, 0) + flat * fwdv + vec3(0, math.max(0, dir.y) * 0.12, 0) - dir * mech.kick
  local function tool_pt(p) return grip + xr * (p[1] - rg.grip[1]) + yu * (p[2] - rg.grip[2]) - dir * (p[3] - rg.grip[3]) end
  if tp and tp ~= "spawning" and tp.valid then
    local origin = tool_pt({ 0, 0, 0 })
    tp.x, tp.y, tp.z = origin.x, origin.y, origin.z
    local yw, pt, rl = lookRotation(dir, yu)
    tp:setAngles(yw, pt, rl)
  end
  -- The hands: each wrist a little behind and under its hold, in the tool's
  -- frame. World points from here on.
  local function tool_off(base, off) return { base[1] + off[1], base[2] + off[2], base[3] + off[3] } end
  local rw = m:toWorld(tool_pt(tool_off(rg.grip, hd.rwrist)))
  local lw = m:toWorld(tool_pt(tool_off(rg.fore, hd.lwrist)))
  gripX, gripY, gripZ = rw.x, rw.y, rw.z
  local W = function(v) return m:toWorld(v) - o end
  local up_w, right_w, fwd_w = W(vec3(0, 1, 0)), W(vec3(-1, 0, 0)), W(vec3(0, 0, 1))
  -- Elbows down and out: poles beside and below each shoulder, a touch back.
  local w = hold.w
  an:reach("Hand.Right", rw, { pole = sr - up_w * 0.4 + right_w * 0.48 - fwd_w * 0.12, weight = w })
  an:reach("Hand.Left", lw, { pole = sl - up_w * 0.4 - right_w * 0.45 - fwd_w * 0.05, weight = w })
  -- The fingers along the grips (each hand's rest knuckle line, rig space).
  local function fing(f) return W(xr * f[1] + yu * f[2] - dir * f[3]) end
  local rf, lf = fing(hd.rfing):normalized(), fing(hd.lfing):normalized()
  an:lookAt({ "Hand.Right" }, rw + rf, { axis = vec3(-0.996, 0.036, 0.08), limit = 85, weight = 0.85 * w })
  an:lookAt({ "Hand.Left" }, lw + lf, { axis = vec3(0.996, 0.036, 0.08), limit = 85, weight = 0.85 * w })
end

-- THE MECHANISMS. The tools are built with moving parts (tools/gen_tools.py
-- keeps them as nodes of the model, which the engine poses as bones): the
-- gravity gun's three claws open as it reaches for something, close on what
-- it holds and snap open on a punt, which also kicks the gun back in the
-- hands; the laser's knurled focus ring spins with the beam. Only the shown
-- model is posed, and only while something moves: bone writes are held
-- (anim:holdPose), so a tool at rest costs nothing.
--
-- THE ENERGY. The tools' energy parts wear the tool_* surface shaders
-- (shaders/tool_energy, tool_glass, tool_gauge, tool_heat): their bands,
-- breathing and flicker run on the GPU by themselves; this script only says
-- how hard the tool is working, as two uniforms on the shown model —
-- `charge` (the gravity gun's field: idle, reaching, holding under strain,
-- a flash on a punt; a laser's spin-up) and `heat` (a laser's heat sink and
-- gauge, its coolant's colour). One node:setShaderParam fans out to every
-- part wearing a tool_* shader, and it is written only when the value moves
-- by a 64th, so an idle tool costs no writes. Self-contained: energy_tick()
-- reads only the published state (inUse, holding, strain, punt_t, charge,
-- heat) and writes only shader uniforms.
local CLAWS = { "ClawTop", "ClawLeft", "ClawRight" }
local mech_rig = {}       -- set .. id → { node =, an =, ids = {name → index}, tries =, last = {}, heat = }
punt_t = -10.0            -- when the gravity gun last threw (the punt's snap)

local function mech_of(set, id)
  local n = models[set][id]
  if not (n and n ~= "spawning" and n.valid and n.visible) then return nil end
  local k = set .. id
  local r = mech_rig[k]
  if not r or r.node ~= n then
    r = { node = n, an = n.animator and n:animator() or nil, ids = nil, tries = 0, last = {}, u = {} }
    mech_rig[k] = r
  end
  if not r.ids and r.an and r.tries < 60 then
    -- boneIndex answers once the model has posed (and errors on a name the
    -- model lacks): asked for a few frames, then given up on
    r.tries = r.tries + 1
    local ids, any = {}, false
    for _, b in ipairs({ "ClawTop", "ClawLeft", "ClawRight", "Focus" }) do
      local ok, i = pcall(r.an.boneIndex, r.an, b)
      if ok and i then ids[b] = i; any = true end
    end
    if any then r.ids = ids; r.an:holdPose(true) end
  end
  return r
end

-- THE ENERGY: the field's charge, eased toward what the gun is doing, and the
-- punt's flash on top of it (decaying).
local energy = { field = 0.15, flash = 0.0, pt = -10.0 }
local function uniform(r, key, v)
  local q = math.floor(v * 64 + 0.5) / 64
  if r.u[key] == q or r.u[key] == false then return end
  local ok = pcall(r.node.setShaderParam, r.node, key, q)
  r.u[key] = ok and q or false     -- a model without tool_* parts: never again
end
local function energy_tick(r, id, dt)
  if id == "gravgun" then
    local want = 0.15                                      -- idle: a slow breath
    if holding then want = 0.8 + 0.2 * math.min(1, strain or 0)
    elseif inUse then want = 0.62 end                      -- reaching
    energy.field = energy.field + (want - energy.field) * (1 - math.exp(-5 * dt))
    if punt_t > energy.pt then energy.pt = punt_t; energy.flash = 0.6 end
    energy.flash = energy.flash * math.exp(-5 * dt)
    if energy.flash < 0.01 then energy.flash = 0 end
    uniform(r, "charge", energy.field + energy.flash)
  elseif id == "laser" then
    uniform(r, "charge", 0.2 + 0.8 * (charge or 0))
    uniform(r, "heat", heat or 0)
  end
end

local function bone_rot(r, name, yaw, pitch, roll)
  local i = r.ids and r.ids[name]
  if not i then return end
  local l = r.last[name]
  if l and math.abs(l[1] - yaw) + math.abs(l[2] - pitch) + math.abs(l[3] - roll) < 2e-4 then return end
  r.an:setBoneRot(i, yaw, pitch, roll)
  r.last[name] = { yaw, pitch, roll }
end

local function articulate(dt)
  local id = shown_tool(toolId())
  local set = first_person() and "fp" or "tp"
  -- the claws: a damped spring toward what the gun is doing
  local want = 0.0
  if id == "gravgun" then
    if time - punt_t < 0.14 then want = 0.78
    elseif holding then want = -0.09 + 0.015 * math.sin(time * 15) * math.min(1, strain or 0)
    elseif inUse then want = 0.40 + 0.03 * math.sin(time * 23)
    else want = 0.02 end
  end
  if punt_t > mech.pt then
    mech.pt = punt_t
    mech.kickv = mech.kickv + 1.1
    mech.clawv = mech.clawv + 9.0
  end
  mech.clawv = mech.clawv + ((want - mech.claw) * 320 - mech.clawv * 24) * dt
  mech.claw = math.max(-0.2, math.min(0.95, mech.claw + mech.clawv * dt))
  mech.kickv = mech.kickv + (-mech.kick * 300 - mech.kickv * 26) * dt
  mech.kick = math.max(-0.01, math.min(0.06, mech.kick + mech.kickv * dt))
  if id == "gravgun" then
    local r = mech_of(set, "gravgun")
    if r and r.ids then
      for _, b in ipairs(CLAWS) do bone_rot(r, b, 0, mech.claw, 0) end
    end
    if r then energy_tick(r, "gravgun", dt) end
  end
  -- the rifle: its focus ring turns up with the charge, the cell and the
  -- coolant loop glow with it, a flash on the shot
  if id == "surveyor" then
    local SV = ref("surveyor")
    local r = mech_of(set, "surveyor")
    if SV and r then
      local c = SV.charge or 0
      mech.sspin = (mech.sspin or 0) + ((c > 0.01) and (2.0 + 14.0 * c) or 0) * dt
      if c > 0.01 or (SV.flash or 0) > 0.02 then bone_rot(r, "Focus", 0, 0, mech.sspin % (2 * math.pi)) end
      uniform(r, "charge", math.min(1.2, 0.2 + 0.8 * c + 0.6 * (SV.flash or 0)))
      uniform(r, "heat", SV.heat or 0)
    end
  end
  -- the laser: the focus ring spins up with the beam; its energy (above)
  local firing = id == "laser" and inUse
  mech.spinv = mech.spinv + ((firing and (7.0 + 5.0 * heat) or 0.0) - mech.spinv) * (1 - math.exp(-(firing and 3 or 1.5) * dt))
  if id == "laser" then
    local r = mech_of(set, "laser")
    if r then
      if mech.spinv > 0.02 then
        mech.spin = (mech.spin + mech.spinv * dt) % (2 * math.pi)
        bone_rot(r, "Focus", 0, 0, mech.spin)
      end
      energy_tick(r, "laser", dt)
    end
  end
end

-- Where a beam leaves the tool in hand, in the world.
--
-- First person is worked out from the CREW, not from the camera node: this
-- lateUpdate can run before the camera's, and the camera node then still
-- stands where it was before the rails carried the planet on — a metre or
-- two at orbital speed, which put the beam's root out in front of the view.
-- The crew's pose is this frame's (physics wrote it back before any
-- lateUpdate), and the eye is a fixed height over it on the body's up.
--
-- The view model is filmed with its own, narrower field of view, so the beam
-- (drawn by the main camera) starts at the point that the MAIN camera shows
-- where the view-model camera shows the muzzle: the same depth, its offset
-- from the middle of the view scaled by the ratio of the two lenses.
-- `key` names any point RIG / RIG_FP keep ("muzzle", "vent"): tool_at(key).
local function tool_at(key)
  local id = toolId()
  local fp = first_person()
  local rig = RIG_FP[id]
  if fp and rig and rig[key] and cam and cam.fwd_x then
    local a = find("Astronaut")
    local cn = cam_node()
    if a and cn then
      local ux, uy, uz = a.up_x or 0, a.up_y or 1, a.up_z or 0
      local eh = (cam.params and cam.params.eye_height) or 1.6
      local ex, ey, ez = a.x + ux * eh, a.y + uy * eh, a.z + uz * eh
      local fx, fy, fz = cam.fwd_x, cam.fwd_y, cam.fwd_z
      local r, u = cn:worldRight(), cn:worldUp()
      local g, mz = rig.grip, rig[key]
      local yw, pt, rl = vm_angles()
      local ox, oy, oz = vm_rot(yw, pt, rl, (mz[1] - g[1]) * VIEW_SCALE, (mz[2] - g[2]) * VIEW_SCALE,
        (mz[3] - g[3]) * VIEW_SCALE)
      local lx = VIEW_AT[1] + ox + view.sx
      local ly = VIEW_AT[2] + oy + view.sy
      local lz = VIEW_AT[3] + oz + view.kick
      local main_fov = (cam.params and cam.params.fov_y) or 1.15
      local s = (vm.on and math.tan(main_fov * 0.5) / math.tan(VM_FOV * 0.5)) or 1.0
      lx, ly = lx * s, ly * s
      -- camera frame: +x right, +y up, -z forward
      return ex + r.x * lx + u.x * ly - fx * lz, ey + r.y * lx + u.y * ly - fy * lz, ez + r.z * lx + u.z * ly - fz * lz
    end
  end
  local m = models[fp and "fp" or "tp"][id]
  rig = fp and RIG_FP[id] or RIG[id]
  if rig and rig[key] and m and m ~= "spawning" and m.valid and m.toWorld then
    local mz = rig[key]
    local w = m:toWorld(vec3(mz[1], mz[2], mz[3]))
    if w then return w.x, w.y, w.z end
  end
  local a = find("Astronaut")
  if a and cam and cam.fwd_x then
    return a.x + cam.fwd_x * 0.6, a.y + cam.fwd_y * 0.6 + 0.3, a.z + cam.fwd_z * 0.6
  end
  return nil
end
local function muzzle() return tool_at("muzzle") end

-- ── THE EFFECTS: particle systems on pooled nodes ─────────────────────────
-- Every beam, mark and hold is a particle effect (vfx/*.vfx.ron) on a node of
-- its own, spawned once from prefabs/Fx<Name> and kept: top level, so its
-- coordinates are world ones, placed every lateUpdate at the muzzle, the hit
-- or the plant, stood up on a normal, aimed with setBeamEnd and scaled with
-- setIntensity. What was not asked for this frame is stopped (fx_sweep).
beamQuads = 0   -- the old ribbon count; kept at 0 for the probes that read it
local fxn = {}        -- name → node | "spawning"
local fx_want = {}    -- names asked for this frame
local fx_tint = {}    -- name → the tint it was last given
local fx_vol = {}     -- name → the emission volume it was last given
local fx_bow = {}     -- name → true while its beam has a control point of ours
-- Since 0.117.0-rc25 (floptle/0529, 0530) the engine itself can mark ONE
-- scattered prop (scatter.setTint: a rim and a glow on the plant or rock the
-- tool is aimed at, where before only a particle stand-in could show it), bow
-- a beam toward a control point (setBeamControl: the tether's sag) and fit an
-- effect's emission volume without touching its particles (setVolume: one
-- PlantMark for a 0.4 m tuft and a 12 m tree at the same mote size). Older
-- engines keep the particle marks fitted by node scale.
local function engine_at_least(maj, min, pat, rc)
  local v = app and app.version and app.version()
  if type(v) ~= "string" then return false end
  local a, b, c, r = v:match("^(%d+)%.(%d+)%.(%d+)%-rc(%d+)")
  if not a then a, b, c = v:match("^(%d+)%.(%d+)%.(%d+)") end
  if not a then return false end
  local have = { tonumber(a), tonumber(b), tonumber(c), r and tonumber(r) or math.huge }
  local want = { maj, min, pat, rc or math.huge }
  for i = 1, 4 do
    if have[i] ~= want[i] then return have[i] > want[i] end
  end
  return true
end
local RC25 = engine_at_least(0, 117, 0, 25)
INSTANCE_TINT = RC25 and scatter ~= nil and scatter.setTint ~= nil and scatter.clearTints ~= nil
BEAM_BOW = RC25
FX_VOLUME = RC25
-- The prop the tool is on, in the engine's own highlight: teal while aimed,
-- amber as the work goes on (the same ramp as the ring). One at a time; the
-- mark is cleared the frame nothing asks for it (tint_sweep).
local tinted = nil      -- { src, inst } the prop carrying our mark
local tint_want = false
local tint_last = nil   -- the k it was last given (skip a rewrite of the same look)
local function tint_instance(src, inst, k, kind)
  if not (INSTANCE_TINT and src and inst) then return end
  tint_want = true
  if tinted and (tinted.src ~= src or tinted.inst ~= inst) then
    scatter.setTint(tinted.src, tinted.inst, nil)
    tinted, tint_last = nil, nil
  end
  k = math.max(0, math.min(1, k or 0))
  -- the colour turns amber early in the work (by 40 % it reads warm), the
  -- strength keeps climbing to the end
  local kk = math.sqrt(k)
  local r, g, b = 0.25 + 0.75 * kk, 0.9 - 0.3 * kk, 0.8 - 0.65 * kk
  if kind == "plant" then
    -- Foliage is camera-facing cards, so a rim term lights every leaf and
    -- the canopy reads flat teal. A plant gets a faint glow from inside
    -- instead, pulsing slowly, and a slight colour shift toward the target
    -- colour: still a green tree. Rewritten every frame (the pulse); the
    -- engine re-rolls nothing for it.
    local pulse = 1 + 0.3 * math.sin(2 * math.pi * 0.8 * (time or 0))
    local e = (0.04 + 0.06 * k) * pulse
    local tr, tg, tb_ = 0.88 + 0.12 * kk, 1.0 - 0.08 * kk, 1.0 - 0.22 * kk
    scatter.setTint(src, inst, { tint = { tr, tg, tb_ }, emissive = { r, g, b }, emissiveStrength = e, rimStrength = 0 })
    tinted, tint_last = { src = src, inst = inst }, k
    return
  end
  -- a solid mesh (a rock): the rim light works there
  if tinted and tint_last and math.abs(tint_last - k) < 0.02 then return end
  scatter.setTint(src, inst, { rim = { r, g, b }, rimStrength = 0.35 + 0.25 * k, emissive = { r, g, b }, emissiveStrength = 0.03 + 0.07 * k })
  tinted, tint_last = { src = src, inst = inst }, k
end
local function tint_sweep()
  if tinted and not tint_want then
    scatter.clearTints(tinted.src)
    tinted, tint_last = nil, nil
  end
  tint_want = false
end
local function fx_node(name)
  local n = fxn[name]
  if n == "spawning" then return nil end
  if n and n.valid then return n end
  if not spawn then return nil end
  local a = find("Astronaut")
  fxn[name] = "spawning"
  spawn("Fx" .. name, a and vec3(a.x, a.y, a.z) or vec3(0, 0, 0), function(m) fxn[name] = m end)
  return nil
end
-- Place and play one. o: x,y,z (world); ux,uy,uz its +Y and fx,fy,fz a
-- tangent (optional); ex,ey,ez the beam's end; cx,cy,cz the beam's control
-- point (its bow, rc25); scale (and sy, a taller scale up its Y); volume =
-- setVolume (rc25: the emission shape alone, the particles as authored);
-- power = setIntensity; r,g,b = setTint.
local function fx_use(name, o)
  fx_want[name] = true
  local n = fx_node(name)
  if not n then return end
  n.x, n.y, n.z = o.x, o.y, o.z
  if o.ux then
    local tx, ty, tz = o.fx, o.fy, o.fz
    if not tx then
      tx, ty, tz = 1 - o.ux * o.ux, -o.ux * o.uy, -o.ux * o.uz
      if tx * tx + ty * ty + tz * tz < 1e-4 then tx, ty, tz = 0, 0, 1 end
    end
    if n.setUp then n:setUp(vec3(o.ux, o.uy, o.uz), vec3(tx, ty, tz)) end
  end
  if o.scale then
    local sy = o.sy or o.scale
    if n.scale_x ~= o.scale or n.scale_y ~= sy then n.scale_x, n.scale_y, n.scale_z = o.scale, sy, o.scale end
  end
  local ps = n.particles and n:particles()
  if not ps then return end
  if not ps:isPlaying() then ps:play() end
  if o.power and ps.setIntensity then ps:setIntensity(o.power) end
  if o.ex and ps.setBeamEnd then ps:setBeamEnd(o.ex, o.ey, o.ez) end
  if BEAM_BOW and ps.setBeamControl then
    if o.cx then ps:setBeamControl(o.cx, o.cy, o.cz); fx_bow[name] = true
    elseif fx_bow[name] then ps:setBeamControl(); fx_bow[name] = nil end
  end
  if o.volume and FX_VOLUME and ps.setVolume and fx_vol[name] ~= o.volume then
    fx_vol[name] = o.volume
    ps:setVolume(o.volume)
  end
  if o.r and ps.setTint then
    local t = fx_tint[name]
    if not (t and math.abs(t[1] - o.r) < 0.01 and math.abs(t[2] - o.g) < 0.01 and math.abs(t[3] - o.b) < 0.01) then
      fx_tint[name] = { o.r, o.g, o.b }
      ps:setTint(o.r, o.g, o.b)
    end
  end
end
-- Stop what nobody asked for this frame.
local function fx_sweep()
  for name, n in pairs(fxn) do
    if not fx_want[name] and n ~= "spawning" and n.valid then
      local ps = n.particles and n:particles()
      if ps and ps:isPlaying() then ps:stop() end
    end
  end
  fx_want = {}
end
-- The crew's chest: where collected things fly to.
local function chest()
  local a = find("Astronaut")
  if not a then return nil end
  return a.x + (a.up_x or 0) * 1.2, a.y + (a.up_y or 1) * 1.2, a.z + (a.up_z or 0) * 1.2
end
-- Something flying into the pack from (x,y,z), and the readout.
local function collect_fx(x, y, z, text)
  local cx, cy, cz = chest()
  local fx = ref("vfx")
  if cx and fx and fx.collect then fx.collect(x, y, z, cx, cy, cz) end
  if text then collected_say(text) end
end

-- ── aiming ring (laser) ─────────────────────────────────────────────────────

local RING = {
  idle = { 0.55, 0.70, 0.78 },
  ok   = { 0.30, 0.88, 0.76 },
  hot  = { 1.00, 0.78, 0.35 },
  full = { 1.00, 0.45, 0.30 },
  fill = { 0.45, 0.78, 1.00 },
}

-- THE MARK'S SIZE ON SCREEN (playtest 2026-10-27: "the aim circle is too big
-- up close and blocks the view"). A ring the cut radius across, or a plant's
-- spread, is a fair size a few metres off and fills the view at arm's length
-- (the laser's 1.2 m bite at 1.5 m is half the screen). So the ring keeps its
-- size in the world only while its radius on screen stays under RING_CAP of
-- the view's height; nearer, it shrinks to hold that, and dims with it, so
-- the closest marks are the smallest and the faintest. → radius, dim (0..1].
RING_CAP = { laser = 0.05, plant = 0.07, dim = 0.45 }
function ring_on_screen(x, y, z, nx, ny, nz, r, cap)
  if not (camera and camera.worldToScreen and camera.screenRect) or r <= 0 then return r, 1 end
  local sx, sy, _, on = camera.worldToScreen(x, y, z)
  if not (sx and on) then return r, 1 end
  -- two tangents across the mark: its widest look on screen
  local ax, ay, az = 1, 0, 0
  if math.abs(nx) > 0.9 then ax, ay, az = 0, 1, 0 end
  local tx, ty, tz = ny * az - nz * ay, nz * ax - nx * az, nx * ay - ny * ax
  local tl = len(tx, ty, tz)
  if tl < 1e-6 then return r, 1 end
  tx, ty, tz = tx / tl, ty / tl, tz / tl
  local bx, by, bz = ny * tz - nz * ty, nz * tx - nx * tz, nx * ty - ny * tx
  local px = 0
  for _, d in ipairs({ { tx, ty, tz }, { bx, by, bz } }) do
    local qx, qy, _, qon = camera.worldToScreen(x + d[1] * r, y + d[2] * r, z + d[3] * r)
    if qx and qon ~= false then px = math.max(px, len(qx - sx, qy - sy, 0)) end
  end
  local _, _, _, vh = camera.screenRect()
  local lim = (vh or 720) * cap
  if px <= lim or px < 1e-3 then return r, 1 end
  local k = lim / px
  return r * k, math.max(RING_CAP.dim, k)
end

-- The laser's AIM MARK: a thin ring laid on the ground at the bite (the
-- AimMark effect stood up on the surface normal), the cut radius across, in
-- the state's colour. Progress is on the screen reticle's pips.
local function paint_ring(hit, firing, full, radius, fill)
  if not hit then return end
  local c = RING.idle
  if full then c = RING.full
  elseif fill then c = RING.fill
  elseif firing then c = RING.hot
  elseif aimMat then c = RING.ok end
  local nx, ny, nz = hit.nx, hit.ny, hit.nz
  if not nx then nx, ny, nz = 0, 1, 0 end
  local nl = len(nx, ny, nz)
  if nl < 1e-4 then nx, ny, nz, nl = 0, 1, 0, 1 end
  nx, ny, nz = nx / nl, ny / nl, nz / nl
  -- the ring in the texture sits at 0.78 of the half-size: size = r / 0.39
  -- (held under RING_CAP.laser of the view near the crew: ring_on_screen)
  local rr, dim = ring_on_screen(hit.x, hit.y, hit.z, nx, ny, nz, math.max(0.4, radius), RING_CAP.laser)
  fx_use("AimMark", { x = hit.x + nx * 0.06, y = hit.y + ny * 0.06, z = hit.z + nz * 0.06,
                      ux = nx, uy = ny, uz = nz, scale = rr / 0.39,
                      power = (firing and 1.0 or 0.75) * dim, r = c[1], g = c[2], b = c[3] })
end

local function field_normal(x, y, z)
  if not (terrain and terrain.query) then return nil end
  local q = terrain.query(x, y, z)
  if not q or math.abs(q) > 1.0 then return nil end
  local e = 0.4
  local gx = (terrain.query(x + e, y, z) or q) - (terrain.query(x - e, y, z) or q)
  local gy = (terrain.query(x, y + e, z) or q) - (terrain.query(x, y - e, z) or q)
  local gz = (terrain.query(x, y, z + e) or q) - (terrain.query(x, y, z - e) or q)
  local l = len(gx, gy, gz)
  if l < 1e-6 then return nil end
  return gx / l, gy / l, gz / l
end

-- ── what update asks lateUpdate to draw (planet frame) ──────────────────────

local beam_req = nil      -- { h = hit (body frame), p = power, kind = "dig"|"fill"|"grav"|"plant", ... }
local ring_req = nil
local plant_req = nil
local rock_req = nil      -- { src, inst } the scattered rock the gravity gun is aimed at
local beacon_req = nil
local paint_beacon
local ring_s = nil
local reticle_draw = nil

local function show_beam(hit, power, kind, extra)
  if not hit then beam_req = false return end
  beam_req = { h = to_body(hit), p = power, kind = kind or "dig" }
  if extra then for k, v in pairs(extra) do beam_req[k] = v end end
end

local function draw_ring(hit, firing, full, radius, fill)
  ring_req = hit and { h = to_body(hit), firing = firing, full = full, r = radius, fill = fill } or nil
end

-- The laser's particle beam (vfx/MiningBeam) on the Laser Muzzle node. The
-- scene hangs it off the hand socket; it is moved onto the third-person laser
-- model itself, at the barrel tip, once that model exists. Its place is
-- PARENT-LOCAL and set once; only the beam's END is a world point
-- (setBeamEnd). Writing a world coordinate into a parented node's .x/.y/.z is
-- what once threw the beam's origin kilometres into the sky.
local muzzle_n, muzzle_on = nil, nil
local function beam_particles(hit, power)
  if not (muzzle_n and muzzle_n.valid) then muzzle_n = find("Laser Muzzle"); muzzle_on = nil end
  if not muzzle_n then return end
  local tl = models.tp.laser
  if tl and tl ~= "spawning" and tl.valid and muzzle_on ~= tl and muzzle_n.setParent then
    muzzle_on = tl
    muzzle_n:setParent(tl, { keepWorld = false })
    local mz = RIG.laser.muzzle
    muzzle_n.x, muzzle_n.y, muzzle_n.z = mz[1], mz[2], mz[3]
  end
  local ps = muzzle_n:particles()
  if not ps then return end
  if hit then
    if not ps:isPlaying() then ps:play() end
    ps:setIntensity(0.45 + power * 0.75)
    ps:setBeamEnd(hit.x, hit.y, hit.z)
  elseif ps:isPlaying() then
    ps:stop()
  end
end

-- The impact node: particles + a light, moved to the hit. Top-level, so its
-- coordinates are world ones (a parented node's are its parent's).
local function impact(hit, power, kind)
  if not impact_n then impact_n = find("Laser Impact") end
  if not (impact_n and impact_n.valid) then return end
  local ps = impact_n:particles()
  local light = impact_n:getcomponent("PointLight")
  if hit then
    impact_n.x, impact_n.y, impact_n.z = hit.x, hit.y, hit.z
    -- Its particles (MiningImpact) are the dig's; the cut and the fill bring
    -- their own (CutBite, FillDeposit) and take only the light.
    if ps then
      if kind == "dig" then
        if not ps:isPlaying() then ps:play() end
        ps:setIntensity(0.3 + power)
      elseif ps:isPlaying() then ps:stop() end
    end
    if light then
      if kind == "fill" then light.r, light.g, light.b = 0.45, 0.75, 1.0
      elseif kind == "cut" then light.r, light.g, light.b = 1.0, 0.95, 0.85
      else light.r, light.g, light.b = 1.0, 0.62, 0.3 end
      light.intensity = (kind == "cut") and (0.5 + power * 1.5) or (2.0 + power * 7.0)
    end
    if kind == "dig" then
      local fx = ref("vfx")
      -- The effects director's cut: molten core, spalled chips, a light that
      -- whitens with heat. (Its burn decals are left off inside a bore — see
      -- quiet_ground: a mark laid where the next bite lands is re-laid by
      -- the engine on every bite.)
      if fx and fx.laserHit then
        local keep = fx.params and fx.params.scorch
        if bored > 0.3 and fx.params then fx.params.scorch = 0 end
        fx.laserHit(impact_n, hit, power, heat, focus)
        if fx.params and keep ~= nil then fx.params.scorch = keep end
      end
    end
  else
    if ps and ps:isPlaying() then ps:stop() end
    if light then light.intensity = 0.0 end
  end
end

-- ── the laser ───────────────────────────────────────────────────────────────

-- The planet's up at a point, and the pull of gravity there (m/s²).
local function gravity_at(x, y, z)
  local name = space.dominant(x, y, z)
  local b = name and space.body(name)
  if not b then return 0, 0, 1, 0 end
  local dx, dy, dz = x - b.x, y - b.y, z - b.z
  local r = len(dx, dy, dz)
  if r < 1 then return 0, 0, 1, 0 end
  local g = (b.mu or 0) / (r * r)
  return dx / r, dy / r, dz / r, g
end

-- Loose chunks knocked free, oldest first, each { n, name }: kept by its own
-- name ("LooseRock <n>") as well as its handle. A chunk stowed or dropped at
-- the depot is destroyed here without leaving this list, and a script's handle
-- is the engine's bare slot number, handed to the next node spawned: the
-- oldest's handle read `valid` again on some other node, which went in its
-- place (engine card 0552). A chunk goes only if the node still answers to
-- its name.
local rocks = {}
local rock_seq = 0
-- What a loose body IS WORTH, by node: a knocked chunk carries the ore it
-- came out of; a plucked boulder, stone or crystal its kind's ore; a felled
-- log timber. Read when it is stowed (E) or dropped at the depot. Weak keys:
-- a destroyed node takes its record with it.
local worth = setmetatable({}, { __mode = "k" })
local function set_worth(n, mat, units, label)
  if n then worth[n] = { mat = mat, n = units, label = label } end
end
local function worth_of(n)
  if not n then return nil end
  local w = worth[n]
  if w then return w end
  -- the tags the prefabs carry (tools/gen_props.py)
  if n.hasTag then
    if n:hasTag("log") then return { mat = "timber", n = 2, label = "Felled Log" } end
    if n:hasTag("boulder") then return { mat = "iron", n = 3, label = "Boulder" } end
    if n:hasTag("crystal") then return { mat = "crystal", n = 2, label = "Crystal Outcrop" } end
    if n:hasTag("loose_rock") then return { mat = "regolith", n = 1, label = "Loose Rock" } end
  end
  return nil
end
local function knock_loose(x, y, z, nx, ny, nz, mat)
  if params.rocks_max <= 0 or not spawn then return end
  while #rocks >= params.rocks_max do
    local old = table.remove(rocks, 1)
    if old and old ~= "spawning" and old.n.valid and old.n.name == old.name then old.n:destroy() end
  end
  local slot = #rocks + 1
  rocks[slot] = "spawning"
  local px, py, pz = x + nx * 0.9, y + ny * 0.9, z + nz * 0.9
  spawn("LooseRock", vec3(px, py, pz), function(n)
    rock_seq = rock_seq + 1
    local nm = "LooseRock " .. rock_seq
    n.name = nm
    rocks[slot] = { n = n, name = nm }
    local mats = ref("materials")
    set_worth(n, mat or "regolith", 2, ((mats and mat) and mats.label(mat) or "Rock") .. " chunk")
    n:setAngles(math.random() * 6.28, math.random() * 6.28, math.random() * 6.28)
    if assembly and assembly.rebuild then
      assembly.rebuild(n, function(r)
        local inf = assembly.info(r)
        if inf then
          local m = inf.mass or 0.09
          assembly.impulseAt(r, vec3(nx * m * 1.6, ny * m * 1.6, nz * m * 1.6),
            vec3(px + (math.random() - 0.5) * 0.2, py, pz))
        end
      end)
    end
  end)
end

-- For probes: a chunk knocked loose at a point, as the laser's mining does.
function knockLoose(x, y, z, nx, ny, nz, mat) knock_loose(x, y, z, nx, ny, nz, mat) end

local function pop_unit(node, hit)
  local inv, mats = ref("inventory"), ref("materials")
  if not (inv and mats) then return end
  -- SURFACE ROCK FIRST: a boulder where the beam is cutting is what the
  -- player is pointing at (scattered props have no colliders, so the field
  -- is asked by proximity).
  local mf = ref("mineral_field")
  if mf and mf.nearest then
    local rock = mf.nearest(hit.x, hit.y, hit.z)
    if rock then
      local rmat, rtook = mf.breakAt(rock, "astro")
      if rtook and rtook > 0 then
        local fx = ref("vfx")
        if fx then fx.oreBreak(hit.x, hit.y, hit.z, hit.nx, hit.ny, hit.nz)
        else spawnEffect("OreBreak", hit.x, hit.y, hit.z) end
        play(SFX.ore .. tostring(math.floor(math.random() * 5)) .. ".ogg",
          { track = "SFX", volume = 0.7, pitch = 0.75 + math.random() * 0.25 })
        say(string.format("%s ×%d", mats.label(rmat), rtook))
        return
      end
    end
  end
  local mat, depth, rich = survey(hit.x, hit.y, hit.z)
  if not mat then return end
  local took = inv.add("astro", mat, rich and 2 or 1)
  -- STAR GEODES: resonant crystal cut out of the deep rock is a geode find
  -- (missions.geodeFind keeps the count and announces the first).
  if took > 0 and mat == "crystal" then
    local mi = ref("missions")
    if mi and mi.geodeFind then pcall(mi.geodeFind, space.dominant(hit.x, hit.y, hit.z), mat, took, depth or 0) end
  end
  if took <= 0 then
    if time - denied_t > 2.5 then
      denied_t = time
      play(SFX.denied, { track = "UI", volume = 0.5 })
      say("pack full — " .. inv.line("astro"))
    end
    return
  end
  local fx = ref("vfx")
  if fx then fx.oreBreak(hit.x, hit.y, hit.z, hit.nx, hit.ny, hit.nz)
  else spawnEffect("OreBreak", hit.x, hit.y, hit.z) end
  play(SFX.ore .. tostring(math.floor(math.random() * 5)) .. ".ogg",
    { track = "SFX", volume = 0.55, pitch = 0.9 + math.random() * 0.3 })
  say(string.format("%s ×%d", mats.label(mat), took))
  units_mined = units_mined + 1
  if params.rock_every > 0 and units_mined % params.rock_every == 0 and bored < 1.5 then
    -- out of the cut, up off the ground (the planet's up, not the beam's)
    local ux, uy, uz = gravity_at(hit.x, hit.y, hit.z)
    knock_loose(hit.x, hit.y, hit.z, ux, uy, uz, mat)
    collected_say("a chunk broke loose — grab it")
  end
end

local function laser_cool(dt)
  charge = math.max(0.0, charge - dt * 4.0)
  heat = math.max(0.0, heat - dt / math.max(0.5, params.cool_time))
  focus = math.max(0.0, focus - dt * 0.8)
  cut_progress = math.max(0.0, cut_progress - dt * 0.25)
  last_hit = nil
end

local function fire_dig(node, dt, firing)
  local ox, oy, oz, dx, dy, dz = aim_ray(node)
  if not ox then
    bore_drop(); show_beam(nil); hum_off()
    aimDist, aimMat, aimDepth = nil, nil, 0
    return nil
  end
  local entry = ray_hit(node, ox, oy, oz, dx, dy, dz, params.laser_reach + (firing and 3.0 or 0.0))
  if entry and entry.range > params.laser_reach and not bore then entry = nil end
  local hit = entry
  if firing then
    charge = math.min(1.0, charge + dt / math.max(0.01, params.spin))
    local bx, by, bz = bore_step(node, dt, ox, oy, oz, dx, dy, dz, entry)
    if bx then
      hit = { x = bx, y = by, z = bz, nx = -dx, ny = -dy, nz = -dz,
              range = len(bx - node.x, by - node.y, bz - node.z) }
      if bored < 0.35 and entry then hit.nx, hit.ny, hit.nz = entry.nx, entry.ny, entry.nz end
    else
      hit = nil
    end
  else
    bore_drop()
  end
  if hit then
    aimDist = hit.range or len(hit.x - node.x, hit.y - node.y, hit.z - node.z)
    aimMat, aimDepth = survey(hit.x, hit.y, hit.z)
    aimX, aimY, aimZ = hit.x, hit.y, hit.z
  else
    aimDist, aimMat, aimDepth = nil, nil, 0
    aimX, aimY, aimZ = nil, nil, nil
  end
  if firing and hit then
    heat = math.min(1.0, heat + dt / math.max(0.5, params.heat_time))
    local throttle = 1.0 - 0.45 * heat
    if last_hit then
      local d = len(hit.x - last_hit[1], hit.y - last_hit[2], hit.z - last_hit[3])
      if d <= params.focus_radius then
        focus = math.min(1.0, focus + dt / math.max(0.1, params.focus_time))
      else
        focus = 0.0
      end
    end
    last_hit = { hit.x, hit.y, hit.z }
    cut_progress = cut_progress + dt * charge * throttle * (1.0 + 0.6 * focus) / math.max(0.05, params.yield)
    while cut_progress >= 1.0 do
      cut_progress = cut_progress - 1.0
      pop_unit(node, hit)
    end
    if time - last_t >= params.laser_rate then
      last_t = time
      quiet_ground(hit.x, hit.y, hit.z)
      terrain.dig(hit.x, hit.y, hit.z, params.laser_radius,
        params.laser_strength * (0.55 + 0.45 * charge))
      groundChanged(hit.x, hit.y, hit.z, params.laser_radius)
    end
    show_beam(hit, charge, "dig")
    publish_shake(0.05 + charge * 0.09)
    hum_on(SFX.hum, 0.10 + charge * 0.30, 0.72 + charge * 0.36 + focus * 0.10)
    if math.random() < dt * 6 then recoil = recoil + 0.004 end
  else
    laser_cool(dt)
    show_beam(nil)
    publish_shake(0)
    hum_off()
  end
  -- The readout carries the shot: what, how deep, how close the next unit,
  -- and — loudly — a full pack, the one state that makes a laser look broken.
  local inv, mats = ref("inventory"), ref("materials")
  local full = (inv and aimMat and inv.roomFor("astro", aimMat, 1) < 1) or false
  local pack = (inv and inv.line("astro")) or ""
  if not hit then
    prompt = string.format("DIG  ·  no target  ·  nothing within %.0f m of the crosshair  ·  %s",
      params.laser_reach, pack)
  else
    local head = ""
    if atReach then
      head = string.format("%.1f m in  ·  AT ARM'S LENGTH — step into the tunnel to cut deeper", bored)
    elseif aimMat then
      local where = aimDepth >= 1.0 and string.format("%.0f m down", aimDepth)
        or string.format("%.0f m out", aimDist or 0)
      head = string.format("%s  ·  %s  ·  next unit %d%%%s%s",
        mats and mats.label(aimMat) or aimMat, where, math.floor(cut_progress * 100 + 0.5),
        bored > 0.5 and string.format("  bore %.1f m", bored) or "",
        focus > 0.05 and string.format("  focus +%d%%", math.floor(focus * 60 + 0.5)) or "")
    end
    if full then
      prompt = "PACK FULL — " .. pack .. "  ·  sell at the depot" .. (head ~= "" and ("  ·  " .. head) or "")
    else
      prompt = "DIG  ·  " .. (head ~= "" and (head .. "  ·  ") or "") .. pack
    end
  end
  progress = cut_progress
  -- The reticle: the material and where it is, or nothing.
  if hit and aimMat then
    reticle_set(full and "full" or "dig", string.format("%s  ·  %s", mats and mats.label(aimMat) or aimMat,
      aimDepth >= 1.0 and string.format("%.0f m down", aimDepth) or string.format("%.0f m", aimDist or 0)))
  elseif hit then
    reticle_set("dig", atReach and "at arm's length" or "")
  else
    reticle_set("none", "no target")
  end
  return hit, full
end

-- FILL: the spade's raise, paid for in rubble. One unit of the cheapest rock
-- in the pack lays `fill_bites` bites; with none, the canister is empty.
local function fill_rock(inv, mats)
  if not (inv and mats) then return nil end
  local best, bestv = nil, math.huge
  for _, it in ipairs(inv.items("astro")) do
    if mats.class and mats.class(it.mat) == "ore" and (mats.value(it.mat) or 0) < bestv then
      best, bestv = it.mat, mats.value(it.mat) or 0
    end
  end
  return best
end

function fillCredit() return fill_credit end

local function fire_fill(node, dt, firing)
  hum_off()
  local h = laser_shot(node)
  local inv, mats = ref("inventory"), ref("materials")
  aimMat, aimDepth = nil, 0
  if h then aimDist, aimX, aimY, aimZ = h.range, h.x, h.y, h.z else aimDist, aimX, aimY, aimZ = nil, nil, nil, nil end
  local rock = fill_rock(inv, mats)
  local stock = (fill_credit > 0 and fill_credit or 0)
  local stock_txt = rock and string.format("canister: %s ×%d", mats.label(rock), inv.count("astro", rock))
    or (fill_credit > 0 and string.format("canister: %d bites left", fill_credit) or "canister EMPTY — dig some rock first")
  if not h then
    show_beam(nil)
    prompt = string.format("FILL  ·  no ground within %.0f m  ·  %s", params.laser_reach, stock_txt)
    reticle_set("none", "no ground")
    return nil
  end
  local nx, ny, nz = h.nx or 0, h.ny or 1, h.nz or 0
  local px, py, pz = h.x + nx * 0.45, h.y + ny * 0.45, h.z + nz * 0.45
  local near = len(px - node.x, py - node.y, pz - node.z) < params.fill_radius + 0.9
  local bad = nil
  if near then bad = "too close — you would bury yourself"
  elseif not rock and fill_credit <= 0 then bad = "the canister is empty — dig some rock first" end
  prompt = "FILL  ·  " .. (bad or "hold LMB to lay rock") .. "  ·  " .. stock_txt
  reticle_set(bad and "full" or "fill", bad or (fill_credit > 0 and string.format("lay rock  ·  %d bites", fill_credit)
    or (rock and ("lay " .. mats.label(rock)) or "canister empty")))
  if firing and not bad then
    charge = math.min(1.0, charge + dt / math.max(0.01, params.spin))
    if time - last_t >= params.laser_rate then
      last_t = time
      if fill_credit <= 0 then
        if inv.remove("astro", rock, 1) == 1 then fill_credit = fill_credit + params.fill_bites end
      end
      if fill_credit > 0 then
        fill_credit = fill_credit - 1
        quiet_ground(px, py, pz)
        terrain.sculpt(px, py, pz, params.fill_radius, params.fill_strength * (0.5 + 0.5 * charge), "raise")
        groundChanged(px, py, pz, params.fill_radius)
        local fx = ref("vfx")
        if fx and fx.dig then fx.dig(h.x, h.y, h.z, true) end
        if math.random() < 0.35 then play(SFX.fill, { track = "SFX", volume = 0.35, pitch = 0.8 + math.random() * 0.3 }) end
      end
    end
    show_beam(h, charge, "fill", { nx = nx, ny = ny, nz = nz })
    publish_shake(0.03 + charge * 0.04)
    recoil = recoil + dt * 0.05
  else
    if firing and bad and time - denied_t > 1.5 then
      denied_t = time
      play(SFX.denied, { track = "UI", volume = 0.45 })
      say(bad)
    end
    laser_cool(dt)
    show_beam(nil)
    publish_shake(0)
  end
  return h, bad ~= nil
end

-- ── THE CUT (laser, E held) ─────────────────────────────────────────────────
-- A thin, white-hot cutting beam with a short reach (`saw_reach` from the
-- crew), aimed down the same line as the dig. It saws through whatever plant
-- the line crosses — a stem, a trunk, a tree's crown — and never touches the
-- terrain: it stops at the ground. Each plant takes its species' cutting work
-- × `saw`, paced by the laser's own spin-up and heat (the dig's rules: heat
-- slows it, never stops it), and gives exactly what the gravity gun's uproot
-- gives (flora_field.harvest: the same yield, the same pack rules, a rare
-- plant's goal). Trees fall (flora_field.fell).
--
-- CHEAP: the field is asked (nearestPlant, a few scatter queries along the
-- line) at most ten times a second, and not at all while the beam stays on
-- the plant it is cutting — that is one closest-approach sum a frame.
--
-- E is only the cut's while nothing else wants it: at a building's door or a
-- crate to recover, E is theirs (facility_menu / salvage prompting()).
local saw = nil        -- { p, pid, work, need, name, lost, keep }
local saw_look = nil   -- the last field query { t, dx, dy, dz, p }
local saw_end = nil    -- the beam's end, eased, in the planet's frame
local function saw_reset() saw, saw_look, saw_end = nil, nil, nil end

-- Who else E belongs to right now, or nil.
local function e_taken()
  local fm = ref("facility_menu")
  if fm and fm.crateNear and fm.crateNear() then return "E opens the crate" end
  if fm and fm.prompting and fm.prompting() then return "E is the building's door" end
  local sv = ref("salvage")
  if sv and sv.prompting and sv.prompting() then return "E recovers the crate" end
  return nil
end

-- For probes: what the saw is on.
function sawState()
  return saw and string.format("%s %.0f%%", saw.name, 100 * saw.work / saw.need) or "idle"
end

-- Is the aim line still on this plant's body? (the lock's test: its whole
-- girth plus a little slack, anywhere up its axis)
local function on_plant(ff, q, ox, oy, oz, dx, dy, dz, t1, slack)
  local g, t, sa = ff.axisDistance(ox, oy, oz, dx, dy, dz, 0, t1, q.x, q.y, q.z, q.ux, q.uy, q.uz, q.height)
  local gr = (ff.girthOf and q.rec and ff.girthOf(q.rec.sp, q.height, sa, params.saw_grab)) or params.saw_grab
  return g <= gr + (slack or 0.3) and t > 0, t, sa
end

-- The beam's end, eased: it slides between the plant and the ground behind it
-- instead of jumping. Held in the planet's frame.
local function ease_end(x, y, z, dt, rate)
  local b = to_body({ x = x, y = y, z = z })
  local e = saw_end
  if e and e.body == b.body and len(e.x - b.x, e.y - b.y, e.z - b.z) < 4.0 then
    local k = 1 - math.exp(-(rate or 22) * dt)
    e.x, e.y, e.z = e.x + (b.x - e.x) * k, e.y + (b.y - e.y) * k, e.z + (b.z - e.z) * k
  else
    saw_end = b
  end
  local w = to_world(saw_end)
  return w.x, w.y, w.z
end

-- What a harvest gave, as a line: "+2 Timber, +1 Plant Fiber".
local function got_line(got)
  local mats = ref("materials")
  local parts = {}
  for _, g in ipairs(got or {}) do
    parts[#parts + 1] = string.format("+%d %s", g.n, (mats and mats.label(g.mat)) or g.mat)
  end
  return table.concat(parts, ", ")
end

local function fire_cut(node, dt)
  local ox, oy, oz, dx, dy, dz = aim_ray(node)
  aimMat, aimDepth = nil, 0
  if not ox then show_beam(nil) hum_off() saw = nil return end
  local ff = ref("flora_field")
  local back = len(node.x - ox, node.y - oy, node.z - oz)
  -- The beam stops at the ground (or a hull): never past it, never into it.
  local gh = ray_hit(node, ox, oy, oz, dx, dy, dz, params.saw_reach)
  local stop_t = gh and len(gh.x - ox, gh.y - oy, gh.z - oz) or (back + params.saw_reach)
  -- THE LOCK: the plant being cut stays the target while the line crosses its
  -- body, and for `lock_grace` after it leaves; only then is the field asked
  -- again. A locked plant is never swapped for a neighbour.
  local p, held = nil, false
  if saw and ff and ff.axisDistance then
    local q = saw.p
    -- The plant's place is kept in the PLANET's frame: a world point held
    -- across frames is metres off within one on an orbiting world, which is
    -- what broke the old lock every frame it was tested.
    local wr, wa = to_world(saw.rb), to_world(saw.ab)
    q.x, q.y, q.z, q.ax, q.ay, q.az = wr.x, wr.y, wr.z, wa.x, wa.y, wa.z
    local on, t = on_plant(ff, q, ox, oy, oz, dx, dy, dz, stop_t + 1.0, 0.35)
    local near = len(q.x - node.x, q.y - node.y, q.z - node.z) <= params.saw_reach + 1.0
    if on and near then
      p, saw.lost = q, nil
      p.t = t
    else
      saw.lost = saw.lost or time
      if time - saw.lost <= params.lock_grace then
        p, held = q, true
        p.t = math.min(t, stop_t)
      else
        saw = nil
      end
    end
  end
  if not p and ff and ff.nearestPlant then
    local lk = saw_look
    if lk and time - lk.t < 0.1 and dx * lk.dx + dy * lk.dy + dz * lk.dz > 0.9999 then
      carry_since(lk, { lk.p })
      p = lk.p
    else
      p = ff.nearestPlant(ox, oy, oz, dx, dy, dz, params.saw_reach + back, 2.0, params.saw_grab,
        { from = { x = node.x, y = node.y, z = node.z }, reach = params.saw_reach, crown = 4.0 })
      saw_look = carry_mark({ t = time, dx = dx, dy = dy, dz = dz, p = p }, node)
    end
    if p and (p.t or 0) > stop_t + 1.0 then p = nil end   -- behind the ground
  end
  -- Power: the laser's spin-up and heat, as the dig.
  -- (heat builds only while it bites, as the dig's does on rock)
  charge = math.min(1.0, charge + dt / math.max(0.01, params.spin))
  local biting = p ~= nil and not held
  if biting then heat = math.min(1.0, heat + dt / math.max(0.5, params.heat_time))
  else heat = math.max(0.0, heat - dt / math.max(0.5, params.cool_time)) end
  local throttle = 1.0 - 0.45 * heat
  local inv = ref("inventory")
  local pack = (inv and inv.line("astro")) or ""
  local hot = heat > 0.6 and "  ·  HOT — cutting slower" or ""
  local ex, ey, ez
  if p then
    if not saw then
      saw = { p = p, pid = p.pid, work = 0, name = p.rec.sp.name,
              need = math.max(0.3, (p.rec.sp.work or 1) * params.saw),
              rb = to_body({ x = p.x, y = p.y, z = p.z }), ab = to_body({ x = p.ax or p.x, y = p.ay or p.y, z = p.az or p.z }) }
      play(SFX.mode, { track = "SFX", volume = 0.25, pitch = 1.6 })   -- the lock: a click
    end
    if biting then saw.work = saw.work + dt * charge * throttle end
    progress = math.min(1, saw.work / saw.need)
    local t = p.t or len(p.x - ox, p.y - oy, p.z - oz)
    ex, ey, ez = ease_end(ox + dx * t, oy + dy * t, oz + dz * t, dt, 26)
    aimDist, aimX, aimY, aimZ = len(ex - node.x, ey - node.y, ez - node.z), ex, ey, ez
    plant_req = { h = to_body({ x = p.x, y = p.y, z = p.z }), ready = true, height = p.height,
                  ux = p.ux, uy = p.uy, uz = p.uz, sp = p.rec and p.rec.sp, work = progress,
                  src = p.rec and p.rec.src, inst = p.rec and p.rec.inst }
    if biting then
      local fx = ref("vfx")
      if fx and fx.cut and math.random() < dt * 4 then fx.cut(ex, ey, ez) end
      if ff.sawAt then ff.sawAt(p.x, p.y, p.z, 0.45 + 0.55 * progress) end
    end
    prompt = string.format("CUT  ·  %s  %d%%%s  ·  %s", saw.name, math.floor(progress * 100 + 0.5), hot, pack)
    reticle_set("cut", string.format("%s  ·  %d%%", saw.name, math.floor(progress * 100 + 0.5)))
    if saw.work >= saw.need then
      local got, dropped = {}, 0
      if ff and ff.harvest then got, dropped = ff.harvest(p, "astro") end
      local stays = p.rec.rare and #got == 0
      if stays then
        say("PACK FULL — no room for the " .. saw.name .. "; it stays where it is")
        play(SFX.denied, { track = "UI", volume = 0.5 })
      else
        local line = got_line(got)
        say(line ~= "" and ("cut " .. saw.name .. ": " .. line .. (dropped > 0 and "  (pack full)" or ""))
          or "pack full — nothing taken")
        local fell = ff and ff.fell and ff.fell(p, dx, dy, dz)
        local fx = ref("vfx")
        if not fell and fx and fx.harvest then fx.harvest(p.x, p.y, p.z, p.height) end
        -- what it gave flies into the pack, from where the beam bit it
        collect_fx(p.ax or ex, p.ay or ey, p.az or ez, line ~= "" and line or (dropped > 0 and "pack full" or nil))
        play(SFX.pickup, { track = "SFX", volume = 0.5 })
        recoil = recoil + 0.02
      end
      saw, saw_look, progress = nil, nil, 0
    end
  else
    progress = 0
    local t = math.min(stop_t, back + params.saw_reach)
    ex, ey, ez = ease_end(ox + dx * t, oy + dy * t, oz + dz * t, dt, 26)
    aimDist, aimX, aimY, aimZ = len(ex - node.x, ey - node.y, ez - node.z), ex, ey, ez
    prompt = string.format("CUT  ·  no plant on the beam within %.0f m  ·  sweep it through a plant%s  ·  %s",
      params.saw_reach, hot, pack)
    reticle_set("cut", "no plant on the beam")
  end
  show_beam({ x = ex, y = ey, z = ez }, charge, "cut", { onPlant = biting, dx = dx, dy = dy, dz = dz })
  publish_shake(biting and (0.02 + charge * 0.03) or 0.01)
  -- The hum pitches up as it bites, and climbs with the cut.
  hum_on(SFX.hum, 0.08 + charge * 0.2, 1.25 + charge * 0.3 + (biting and (0.15 + 0.3 * progress) or 0))
  if biting and math.random() < dt * 8 then recoil = recoil + 0.003 end
end

-- ── the gravity gun ─────────────────────────────────────────────────────────
--
-- `grab` while something is held:
--   kind "asm"   an assembly (craft, debris, part, loose rock): forces at the grab point
--   kind "body"  a plain rigidbody: velocity pushes, no torque
--   kind "plant" a scattered plant being uprooted (no physics at all)
-- lp = the grab point in the held node's own frame; ox,oy,oz = where the
-- grab point is wanted, as an offset from the crew (so the planet moving
-- under both carries it), refreshed every frame from the aim.

local grab = nil
local grab_try_t = -10
local grab_preview = nil     -- the idle aim's last answer (see fire_grav)
local need_release = false   -- after a throw or an uproot: no new catch until the trigger comes up

-- The thing that moves when a hit node is pulled: the assembly it belongs to,
-- or the body itself. nil for terrain, statics and the crew.
local function dynamic_of(n)
  local k = 0
  local first = n
  while n and n.valid ~= false and k < 10 do
    if assembly and assembly.info then
      local inf = assembly.info(n)
      if inf and inf.mass then return n, "asm", inf end
    end
    n = n.parent
    k = k + 1
  end
  n = first
  if n and n.valid ~= false and n.vel ~= nil then
    local rb = n.getcomponent and n:getcomponent("RigidBody")
    if rb and (rb.kinematic == 0 or rb.kinematic == false) and (rb.mass or 0) > 0 then
      return n, "body", { mass = rb.mass }
    end
  end
  return nil
end

local function name_of(n, kind)
  if not n then return "?" end
  local w = worth_of(n)
  if w and w.label then return w.label end
  if n.hasTag then
    if n:hasTag("can") then return "Supply Crate" end
    if n:hasTag("crate") then return "Cargo Canister" end
    if n:hasTag("cone") then return "Traffic Cone" end
  end
  local vc = n.getScript and n:getScript("vessel_controller")
  if vc and vc.craftName then return vc.craftName end
  local nm = n.name or "object"
  if nm == "Vessel" or nm:sub(1, 6) == "Vessel" then return "Debris" end
  return nm
end

-- Is this a wreck the depot takes back for scrap? Anything the gun can hold
-- that is not worth something in itself (a rock, a log), not one of the
-- base's own props, and not a craft under control.
local function is_debris(n)
  if not n or worth_of(n) then return false end
  if n.hasTag and n:hasTag("prop") then return false end
  local vc = n.getScript and n:getScript("vessel_controller")
  if vc and vc.craftName then return false end
  return true
end

local function mass_txt(m)
  return m >= 1 and string.format("%.1f t", m) or string.format("%.0f kg", m * 1000)
end

-- The Commerce Depot's intake: where it stands (world), looked up seldom.
local depot = { n = nil, t = -10 }
local function depot_pos()
  if not (depot.n and depot.n.valid) and time - depot.t > 2.0 then
    depot.t = time
    depot.n = find("FacDepot")
  end
  local d = depot.n
  if not (d and d.valid) then return nil end
  local w = d.worldPos
  if w then return w.x, w.y, w.z end
  return d.x, d.y, d.z
end
local function in_intake(x, y, z)
  local dx, dy, dz = depot_pos()
  if not dx then return false end
  return len(x - dx, y - dy, z - dz) <= params.intake
end

-- Where the held point is, in the world, now (and the node's pose answer).
local function grab_world(g)
  if not (g and g.node and g.node.valid) then return nil end
  if not g.lp then return g.node.x, g.node.y, g.node.z end
  local w = g.node:toWorld(vec3(g.lp.x, g.lp.y, g.lp.z))
  return w.x, w.y, w.z
end

lastRelease = nil   -- why the gravity gun last let go (probes read it)
lastTry = nil       -- what the trigger last found (probes read it)
tries = nil         -- the first few tries (probes read it)
grabFrames = 0      -- frames something was held (probes read it)
-- `gone`: the thing is being destroyed (stowed, deposited), so no fizzle on it.
local function release(why_, quiet_, gone)
  if grab then lastRelease = why_ or (quiet_ and "quiet") or "trigger up" end
  if grab and grab.kind ~= "plant" then
    local n = grab.node
    if n and n.valid and n.setTint then pcall(n.setTint, n) end   -- the shell off
    if not gone and grab.kind ~= "pending" and spawnEffect then
      local gx, gy, gz = grab_world(grab)
      if gx then spawnEffect("GravFizzle", vec3(gx, gy, gz)) end
    end
    if not quiet_ then play(SFX.drop, { track = "SFX", volume = 0.45, pitch = 0.9 + math.random() * 0.2 }) end
  end
  grab, holding, strain, wantsScroll = nil, nil, 0.0, false
  hum_off()
  if why_ then say(why_) end
end

-- The rocks of the mineral field the gun pulls out of the ground as bodies.
local ROCK_KINDS = { stone = true, boulder = true, crystal = true }
local ROCK_PREFAB = { stone = "LooseRock", boulder = "LooseBoulder", crystal = "LooseCrystal" }
local ROCK_MASS = { stone = 0.09, boulder = 0.9, crystal = 0.16 }
local ROCK_NAME = { stone = "Stone", boulder = "Boulder", crystal = "Crystal Outcrop" }

-- WHAT IS UNDER THE AIM: a body (an assembly or a rigidbody), a planted relay
-- beacon, a salvage crate, a rock of the mineral field, a plant — in that
-- order — or nil and why not.
local function try_grab(node, ox, oy, oz, dx, dy, dz)
  local h = ray_hit(node, ox, oy, oz, dx, dy, dz, params.grav_reach)
  local ht = h and len(h.x - ox, h.y - oy, h.z - oz) or nil
  if h and h.node then
    local n, kind, inf = dynamic_of(h.node)
    if n and n.id ~= node.id then
      if inf.anchored then return nil, "it's clamped down" end
      local lp = n:toLocal(vec3(h.x, h.y, h.z))
      local d = math.max(params.grav_min, math.min(params.grav_max, h.range))
      return { kind = kind, node = n, lp = lp, dist = d, mass = inf.mass or 0.1, name = name_of(n, kind),
               ox = h.x - node.x, oy = h.y - node.y, oz = h.z - node.z, stretch = 0, t0 = time }, nil, h
    end
    -- A planted relay beacon (a static body; its prefab's tag says so).
    local k, m = 0, h.node
    while m and m.valid ~= false and k < 6 do
      if m.hasTag and m:hasTag("RelayBeacon") then
        local net = ref("comms")
        local near = net and net.beaconNear and net.beaconNear(h.x, h.y, h.z, 3.5)
        if near then return { kind = "beacon", beacon = near, name = near.name, t0 = time,
                              x = near.gx, y = near.gy, z = near.gz }, nil, h end
      end
      m = m.parent
      k = k + 1
    end
  end
  -- A salvage crate on the line (no collider: by where it lies).
  local sv = ref("salvage")
  if sv and sv.list then
    for _, e in ipairs(sv.list()) do
      if e.x then
        local wx, wy, wz = e.x - ox, e.y - oy, e.z - oz
        local t = wx * dx + wy * dy + wz * dz
        if t > 0 and (not ht or t < ht + 0.8) and len(wx - dx * t, wy - dy * t, wz - dz * t) < 1.1
          and len(e.x - node.x, e.y - node.y, e.z - node.z) <= params.grav_reach then
          return { kind = "crate", crate = e, name = "Salvage Crate", t0 = time, x = e.x, y = e.y, z = e.z }, nil, h
        end
      end
    end
  end
  -- A rock in the ground the line passes through: a stone, a boulder or a
  -- crystal of the mineral field (scattered, so no collider: the line against
  -- each rock's own ball, the nearest first, then its record for the pluck).
  local mf = ref("mineral_field")
  if mf and mf.rocksNear then
    local best, bt = nil, nil
    for _, rk in ipairs(mf.rocksNear(node.x, node.y, node.z, params.grav_reach)) do
      local wx, wy, wz = rk.x - ox, rk.y - oy, rk.z - oz
      local t = wx * dx + wy * dy + wz * dz
      if t > 0 and (not ht or t < ht + rk.r + 0.5) and (not bt or t < bt)
        and len(wx - dx * t, wy - dy * t, wz - dz * t) <= rk.r + 0.25 then
        best, bt = rk, t
      end
    end
    local rec = best and ((mf.rockRecord and mf.rockRecord(best)) or mf.nearest(best.x, best.y, best.z, 1.0, ROCK_KINDS))
    if rec and rec.kind and ROCK_KINDS[rec.kind.id] then
      local sc = rec.scale or 1
      return { kind = "rock", rock = rec, name = ROCK_NAME[rec.kind.id] or "Rock", mass = (ROCK_MASS[rec.kind.id] or 0.1) * sc,
               t0 = time, x = rec.pos.x, y = rec.pos.y, z = rec.pos.z }, nil, h
    end
  end
  -- No body: a plant? (scattered plants have no colliders)
  local ff = ref("flora_field")
  if ff and ff.nearestPlant then
    local back = len(node.x - ox, node.y - oy, node.z - oz)
    -- The reach is the CREW's (opt.from): only the part of the line near the
    -- crew is searched, whichever camera it starts from.
    local p = ff.nearestPlant(ox, oy, oz, dx, dy, dz, params.cut_reach + back, 2.0, params.cut_grab,
      { from = { x = node.x, y = node.y, z = node.z }, reach = params.cut_reach, crown = 4.0 })
    if p and p.rec and len(p.x - node.x, p.y - node.y, p.z - node.z) <= params.cut_reach then
      -- Only if the line meets the plant before the ground it hits: the aim
      -- must pass through the plant, not through the hill behind it. (Along
      -- the LINE: a tree's trunk collider is the hit when you aim at it.)
      if not h or (p.t or 0) <= len(h.x - ox, h.y - oy, h.z - oz) + 1.0 then
        return { kind = "plant", plant = p, pid = p.pid, work = 0, name = p.rec.sp.name,
                 need = math.max(0.3, (p.rec.sp.work or 1) * params.uproot), t0 = time }, nil, h
      end
    end
  end
  return nil, h and "nothing loose there — it's part of the ground" or "nothing in reach", h
end

-- The shell of light on what is held (the engine's rim tint; a scatter
-- instance has none, which is why a plant gets motes instead).
local function shell_on(n)
  if n and n.valid and n.setTint then pcall(n.setTint, n, { rim = { 0.55, 0.9, 1.0 }, rimStrength = 1.1 }) end
end

-- Pull a rock out of the ground: the field loses the instance, a body of its
-- kind stands up in its place and the gun has it the moment physics does.
local function pluck_rock(node, cand, h)
  local mf = ref("mineral_field")
  local rk = cand.rock
  local kind = mf and mf.pluck and mf.pluck(rk)
  if not (kind and spawn) then return false end
  local ux, uy, uz = gravity_at(rk.pos.x, rk.pos.y, rk.pos.z)
  local sc = rk.scale or 1
  local lift = 0.3 + 0.25 * sc
  local px, py, pz = rk.pos.x + ux * lift, rk.pos.y + uy * lift, rk.pos.z + uz * lift
  local fx = ref("vfx")
  if fx and fx.oreBreak then fx.oreBreak(rk.pos.x, rk.pos.y, rk.pos.z, ux, uy, uz) end
  play(SFX.ore .. tostring(math.floor(math.random() * 5)) .. ".ogg", { track = "SFX", volume = 0.6, pitch = 0.7 + math.random() * 0.2 })
  local mats = ref("materials")
  local label = cand.name
  grab = carry_mark({ kind = "pending", name = label, mass = cand.mass, t0 = time, x = px, y = py, z = pz }, node)
  holding = { name = label, mass = cand.mass, strain = 0, kind = "asm" }
  spawn(ROCK_PREFAB[kind.id] or "LooseRock", vec3(px, py, pz), function(n)
    set_worth(n, kind.mat, kind.yield or 1, label)
    n:setAngles(math.random() * 6.28, (rk.yaw or 0), math.random() * 0.4)
    if kind.id == "stone" and sc ~= 1 then n.scale = math.max(0.7, math.min(1.6, sc)) end
    local function take(r)
      if not (grab and grab.kind == "pending") then return end
      local inf = assembly and assembly.info and assembly.info(n)
      grab = { kind = "asm", node = n, lp = vec3(0, 0, 0), dist = math.max(params.grav_min, math.min(params.grav_max,
                len(px - node.x, py - node.y, pz - node.z))), mass = (inf and inf.mass) or cand.mass, name = label,
               ox = px - node.x, oy = py - node.y, oz = pz - node.z, stretch = 0, t0 = time }
      shell_on(n)
    end
    if assembly and assembly.rebuild then assembly.rebuild(n, take) else take(n) end
  end)
  return true
end

-- E while holding: STOW it, if it is worth something and the pack has room.
local function stow_held(node)
  local n = grab.node
  local w = worth_of(n)
  local inv, mats = ref("inventory"), ref("materials")
  if not w then
    say(is_debris(n) and ("the " .. grab.name .. " won't fit in the pack — drop it at the depot to recycle it")
      or ("the " .. grab.name .. " is the base's — put it back"))
    play(SFX.denied, { track = "UI", volume = 0.45 })
    return
  end
  if not inv then return end
  local took = inv.add("astro", w.mat, w.n)
  if took <= 0 then
    say("PACK FULL — " .. inv.line("astro"))
    play(SFX.denied, { track = "UI", volume = 0.5 })
    return
  end
  local gx, gy, gz = grab_world(grab)
  local line = string.format("+%d %s", took, (mats and mats.label(w.mat)) or w.mat)
  release(nil, true, true)
  if gx then collect_fx(gx, gy, gz, line) end
  say("stowed: " .. line)
  play(SFX.pickup, { track = "SFX", volume = 0.5 })
  if n and n.valid then n:destroy() end
  need_release = true
end

-- Let go inside the depot's intake: rocks and logs go into the warehouse,
-- a wreck is recycled for scrap money. Returns true when it took the thing.
local function intake_take(g)
  local n = g.node
  if not (n and n.valid) then return false end
  local gx, gy, gz = grab_world(g)
  if not (gx and in_intake(gx, gy, gz)) then return false end
  local inv, mats, co = ref("inventory"), ref("materials"), ref("company")
  local w = worth_of(n)
  local line
  if w and inv then
    local took = inv.add("base", w.mat, w.n)
    if took <= 0 then say("the warehouse is full") return false end
    line = string.format("+%d %s → warehouse", took, (mats and mats.label(w.mat)) or w.mat)
  elseif is_debris(n) and co and co.earn then
    local kg = (g.mass or 0.1) * 1000
    local cash = math.max(1, math.floor(kg * params.scrap_rate))
    co.earn(cash, "debris recycled")
    line = string.format("recycled the %s  ·  +%s", g.name, (co.money and co.money(cash)) or ("$" .. cash))
  else
    return false
  end
  local dx, dy, dz = depot_pos()
  local fx = ref("vfx")
  if fx and fx.collect and dx then fx.collect(gx, gy, gz, dx, dy + 3, dz) end
  if fx and fx.oreBreak then fx.oreBreak(gx, gy, gz) end
  collected_say(line)
  say(line)
  play(SFX.pickup, { track = "SFX", volume = 0.5 })
  lastIntake = line
  release(nil, true, true)
  n:destroy()
  return true
end
lastIntake = nil   -- the depot's last take (probes read it)

-- Every frame while the gun is out.
local grav_idle_req = false
local function fire_grav(node, dt, firing)
  local ox, oy, oz, dx, dy, dz = aim_ray(node)
  if not ox then release() show_beam(nil) return end
  local back = len(node.x - ox, node.y - oy, node.z - oz)
  aimMat, aimDepth = nil, 0
  if grab and not firing then
    if grab.kind == "asm" or grab.kind == "body" then intake_take(grab) end
    if grab then release() end
  end
  if not grab then
    wantsScroll = false
    show_beam(nil)
    grav_idle_req = true
    -- What the crosshair is over, before the click. Asked ten times a second
    -- while idle (a plant query walks every flora source in reach), and on
    -- the frame the trigger goes down.
    local cand, why_, h
    local pv = grab_preview
    if not firing and pv and time - pv.t < 0.1 and dx * pv.dx + dy * pv.dy + dz * pv.dz > 0.99995 then
      -- (its world points carried on with the planet since they were found:
      -- a tenth of a second is up to 36 m of a planet's travel)
      carry_since(pv, { pv.h, pv.cand, pv.cand and pv.cand.plant })
      cand, why_, h = pv.cand, pv.why, pv.h
    else
      cand, why_, h = try_grab(node, ox, oy, oz, dx, dy, dz)
      grab_preview = carry_mark({ t = time, cand = cand, why = why_, h = h, dx = dx, dy = dy, dz = dz }, node)
    end
    if h then aimDist, aimX, aimY, aimZ = h.range, h.x, h.y, h.z else aimDist, aimX, aimY, aimZ = nil, nil, nil, nil end
    if cand and cand.kind == "plant" then
      prompt = string.format("GRAVITY GUN  ·  %s  ·  hold LMB to uproot it", cand.name)
      reticle_set("plant", cand.name .. "  ·  hold LMB: uproot")
      plant_req = { h = to_body({ x = cand.plant.x, y = cand.plant.y, z = cand.plant.z }), ready = false,
                    height = cand.plant.height, ux = cand.plant.ux, uy = cand.plant.uy, uz = cand.plant.uz,
                    sp = cand.plant.rec and cand.plant.rec.sp, work = 0,
                    src = cand.plant.rec and cand.plant.rec.src, inst = cand.plant.rec and cand.plant.rec.inst }
    elseif cand and cand.kind == "beacon" then
      prompt = string.format("GRAVITY GUN  ·  %s  ·  hold LMB to pull it up", cand.name)
      reticle_set("grab", cand.name .. "  ·  hold LMB: pull up")
    elseif cand and cand.kind == "crate" then
      prompt = "GRAVITY GUN  ·  Salvage Crate  ·  hold LMB to pull the pack's contents out"
      reticle_set("grab", "Salvage Crate  ·  hold LMB: open")
    elseif cand then
      if cand.kind == "rock" and cand.rock then rock_req = { src = cand.rock.source, inst = cand.rock.id } end
      local _, _, _, g = gravity_at(node.x, node.y, node.z)
      local lift = (cand.mass * g) / math.max(0.01, params.grav_force)
      local verb = cand.kind == "rock" and "pull it out" or "grab"
      prompt = string.format("GRAVITY GUN  ·  %s  ·  %s  ·  %s", cand.name, mass_txt(cand.mass),
        lift > 2.5 and "far too heavy for the gun — it will only strain"
          or (lift > 1 and ("too heavy to lift — you can drag it  ·  hold LMB to " .. verb) or ("hold LMB to " .. verb)))
      reticle_set(lift > 1 and "heavy" or "grab", string.format("%s  ·  %s  ·  hold LMB: %s", cand.name, mass_txt(cand.mass),
        lift > 2.5 and "strain" or (lift > 1 and "drag" or verb)))
    else
      prompt = "GRAVITY GUN  ·  " .. (why_ or "nothing in reach") .. "  ·  aim at something loose and hold LMB"
      reticle_set("none", why_ or "nothing in reach")
    end
    if not firing then need_release = false end
    if firing and not need_release and time - grab_try_t > 0.25 then
      grab_try_t = time
      -- for probes: what the trigger found
      lastTry = { t = time, hit = h and h.node and h.node.name or (h and "ground" or "nothing"), range = h and h.range,
                  cand = cand and cand.kind, name = cand and cand.name, why = why_,
                  ox = ox, oy = oy, oz = oz, dx = dx, dy = dy, dz = dz, cx = node.x, cy = node.y, cz = node.z, fp = first_person() }
      tries = tries or {}
      if #tries < 4 then tries[#tries + 1] = lastTry end
      if cand and cand.kind == "beacon" then
        local inv, net = ref("inventory"), ref("comms")
        if inv and inv.addGear("astro", "beacon", 1) < 1 then
          say("PACK FULL — no room to carry the beacon")
          play(SFX.denied, { track = "UI", volume = 0.5 })
        elseif net then
          net.removeBeacon(cand.beacon.id)
          collect_fx(cand.x, cand.y, cand.z, "+1 Relay Beacon")
          say(cand.name .. " pulled up")
          play(SFX.pickup, { track = "UI", volume = 0.5 })
        end
        need_release = true
      elseif cand and cand.kind == "crate" then
        local sv = ref("salvage")
        local moved, left = 0, 0
        if sv and sv.recover then moved, left = sv.recover(cand.crate.id) end
        if moved <= 0 and left > 0 then
          say(string.format("no room in the pack — %.0f kg still in the crate", left))
          play(SFX.denied, { track = "UI", volume = 0.5 })
        else
          collect_fx(cand.x, cand.y, cand.z, string.format("+%.0f kg recovered", moved))
          say(left > 0 and string.format("%.0f kg back in the pack · %.0f kg won't fit", moved, left)
            or string.format("suit pack recovered · %.0f kg", moved))
          play(SFX.pickup, { track = "SFX", volume = 0.5 })
        end
        need_release = true
      elseif cand and cand.kind == "rock" then
        if not pluck_rock(node, cand, h) then
          play(SFX.dry, { track = "SFX", volume = 0.35, pitch = 1.4 })
          say("it won't come loose")
        end
        recoil = recoil + 0.02
      elseif cand then
        grab = cand
        if cand.kind == "plant" and cand.plant then
          -- The plant's place in the planet's frame NOW, on the frame it was
          -- found: taken on the next frame (as it was), the world point was
          -- a frame of the planet's travel old (1.5-6 m a tick), and the
          -- hold, the beam and the crew's facing all aimed at that.
          local p = cand.plant
          cand.rb = to_body({ x = p.x, y = p.y, z = p.z })
          cand.ab = to_body({ x = p.ax or p.x, y = p.ay or p.y, z = p.az or p.z })
        end
        if cand.kind ~= "plant" then
          holding = { name = cand.name, mass = cand.mass, strain = 0, kind = cand.kind }
          play(SFX.grab, { track = "SFX", volume = 0.55, pitch = 1.1 - math.min(0.4, cand.mass) })
          if h then spawnEffect("Sparks", vec3(h.x, h.y, h.z), { normal = vec3(h.nx or 0, h.ny or 1, h.nz or 0), intensity = 0.4, scale = 0.5 }) end
          shell_on(cand.node)
          recoil = recoil + 0.015
        end
      else
        play(SFX.dry, { track = "SFX", volume = 0.35, pitch = 1.4 })
        recoil = recoil + 0.006
        say(why_ or "nothing to grab")
      end
    end
    return
  end

  -- ── holding ──
  if grab.kind == "pending" then
    -- a plucked rock, its body not up yet: the beam reaches for its place
    if time - grab.t0 > 1.5 then release("it won't come loose", true) show_beam(nil) return end
    carry_since(grab, { grab })     -- (its place rides the planet: carry_mark)
    aimDist, aimX, aimY, aimZ = len(grab.x - node.x, grab.y - node.y, grab.z - node.z), grab.x, grab.y, grab.z
    show_beam({ x = grab.x, y = grab.y, z = grab.z }, 0.6, "pending", { aimx = dx, aimy = dy, aimz = dz })
    hum_on(SFX.hold, 0.15, 0.9)
    prompt = string.format("PULLING the %s loose…", grab.name)
    reticle_set("hold", grab.name)
    return
  end
  if grab.kind == "plant" then
    local p = grab.plant
    -- its place, in the planet's frame (see THE CUT: a world point goes stale)
    if not grab.rb then
      grab.rb = to_body({ x = p.x, y = p.y, z = p.z })
      grab.ab = to_body({ x = p.ax or p.x, y = p.ay or p.y, z = p.az or p.z })
    else
      local wr, wa = to_world(grab.rb), to_world(grab.ab)
      p.x, p.y, p.z, p.ax, p.ay, p.az = wr.x, wr.y, wr.z, wa.x, wa.y, wa.z
    end
    grab.work = grab.work + dt
    progress = math.min(1, grab.work / grab.need)
    aimDist, aimX, aimY, aimZ = len(p.x - node.x, p.y - node.y, p.z - node.z), p.x, p.y, p.z
    local mx = (p.ax or p.x)
    local my = (p.ay or p.y)
    local mz = (p.az or p.z)
    -- the plant quivers as the beam works it loose
    local q = 0.04 * progress
    show_beam({ x = mx + (math.random() - 0.5) * q, y = my + (math.random() - 0.5) * q, z = mz + (math.random() - 0.5) * q },
      0.5 + progress * 0.5, "plant")
    plant_req = { h = to_body({ x = p.x, y = p.y, z = p.z }), ready = true, height = p.height,
                  ux = p.ux, uy = p.uy, uz = p.uz, sp = p.rec and p.rec.sp, work = progress,
                  src = p.rec and p.rec.src, inst = p.rec and p.rec.inst }
    hum_on(SFX.hold, 0.12 + progress * 0.2, 0.8 + progress * 0.7)
    local fx = ref("vfx")
    local ff = ref("flora_field")
    if fx and fx.cut and math.random() < dt * 4 then fx.cut(mx, my, mz) end
    if ff and ff.sawAt then ff.sawAt(p.x, p.y, p.z, 0.4 + 0.6 * progress) end
    local inv = ref("inventory")
    prompt = string.format("UPROOTING %s  %d%%  ·  %s", grab.name, math.floor(progress * 100 + 0.5),
      inv and inv.line("astro") or "")
    reticle_set("plant", string.format("%s  ·  %d%%", grab.name, math.floor(progress * 100 + 0.5)))
    if grab.work >= grab.need then
      local got, dropped = {}, 0
      if ff and ff.harvest then got, dropped = ff.harvest(p, "astro") end
      local line = got_line(got)
      say(line ~= "" and line .. (dropped > 0 and "  (pack full)" or "") or "pack full — nothing taken")
      if fx and fx.harvest then fx.harvest(p.x, p.y, p.z, p.height) end
      collect_fx(mx, my, mz, line ~= "" and line or (dropped > 0 and "pack full" or nil))
      play(SFX.pickup, { track = "SFX", volume = 0.5 })
      recoil = recoil + 0.02
      grab, progress = nil, 0
      hum_off()
      need_release = true       -- don't grab the next plant on the same held click
    end
    return
  end

  if not (grab.node and grab.node.valid) then release("it's gone", true, true) show_beam(nil) return end
  -- Hold distance: the wheel, while the gun has something.
  wantsScroll = true
  local s = scroll()
  if s ~= 0 then grab.dist = math.max(params.grav_min, math.min(params.grav_max, grab.dist + s * 0.8)) end
  -- Where it's wanted: on the aim ray, `dist` from the crew.
  local t = grab.dist + back
  grab.ox = ox + dx * t - node.x
  grab.oy = oy + dy * t - node.y
  grab.oz = oz + dz * t - node.z
  local gx, gy, gz = grab_world(grab)
  if not gx then release() return end
  aimDist, aimX, aimY, aimZ = len(gx - node.x, gy - node.y, gz - node.z), gx, gy, gz
  holding = holding or {}
  holding.name, holding.mass, holding.strain, holding.kind = grab.name, grab.mass, strain, grab.kind
  grabFrames = grabFrames + 1
  -- Too far behind the aim for too long (snagged, or far too heavy): let go.
  if (grab.stretch or 0) > params.grav_break then
    release("lost the grip — " .. grab.name .. " is snagged or too heavy")
    show_beam(nil)
    return
  end
  -- E: stow it (an edge, so the key held into the next frame does nothing).
  local e = key_e() and e_taken() == nil
  if e and not grab.e_was then
    grab.e_was = true
    stow_held(node)
    if not grab then show_beam(nil) return end
  elseif not e and grab then
    grab.e_was = false
  end
  -- Throw.
  if key_r() then
    local inf = grab.kind == "asm" and assembly.info(grab.node)
    local m = (inf and inf.mass) or grab.mass
    local j = math.min(m * params.grav_throw, params.grav_throw_max)
    if grab.kind == "asm" then
      assembly.impulseAt(grab.node, vec3(dx * j, dy * j, dz * j), vec3(gx, gy, gz))
    else
      local v = grab.node.vel
      grab.node.vel = vec3(v.x + dx * j / m, v.y + dy * j / m, v.z + dz * j / m)
    end
    play(SFX.throw, { track = "SFX", volume = 0.6, pitch = 1.0 + math.random() * 0.1 })
    local mx, my, mz = muzzle()
    if spawnEffect then
      if mx then spawnEffect("GravPunt", vec3(mx + dx * 1.1, my + dy * 1.1, mz + dz * 1.1), { normal = vec3(dx, dy, dz) }) end
      local sp = j / math.max(m, 1e-3)
      spawnEffect("GravTrail", vec3(gx, gy, gz), { vel = vec3(dx * sp, dy * sp, dz * sp) })
    end
    recoil = recoil + 0.06
    punt_t = time
    publish_shake(0.12)
    local nm = grab.name
    release(nil, true, true)
    need_release = true
    say(string.format("threw the %s  ·  %.0f m/s", nm, j / math.max(m, 1e-3)))
    show_beam(nil)
    return
  end
  show_beam({ x = gx, y = gy, z = gz }, 0.4 + math.min(1, strain) * 0.6, "grav", { aimx = dx, aimy = dy, aimz = dz })
  hum_on(SFX.hold, 0.10 + math.min(1, strain) * 0.25, 0.7 + math.min(1.2, strain) * 0.5)
  publish_shake(math.min(0.08, strain * 0.05))
  local stxt = strain >= 1.0 and "OVERLOAD — too heavy for the gun"
    or string.format("strain %d%%", math.floor(strain * 100 + 0.5))
  local w = worth_of(grab.node)
  local mats = ref("materials")
  local use = w and string.format("  ·  E stow (+%d %s)", w.n, (mats and mats.label(w.mat)) or w.mat) or ""
  local at = ""
  if in_intake(gx, gy, gz) then
    if w then at = "  ·  IN THE DEPOT'S INTAKE — let go to deposit it"
    elseif is_debris(grab.node) then
      at = string.format("  ·  IN THE DEPOT'S INTAKE — let go to recycle it (+$%d)", math.max(1, math.floor(grab.mass * 1000 * params.scrap_rate)))
    end
  end
  prompt = string.format("HOLDING %s  ·  %s  ·  %s  ·  %.1f m  ·  scroll nearer / further  ·  R throw%s  ·  release to drop%s",
    grab.name, mass_txt(grab.mass), stxt, grab.dist, use, at)
  reticle_set("hold", at ~= "" and (grab.name .. "  ·  release: " .. (w and "deposit" or "recycle"))
    or string.format("%s  ·  %s  ·  R throw%s", grab.name, stxt, w and "  ·  E stow" or ""))
  progress = math.min(1, strain)
end

-- The pull itself, on the physics tick.
function fixedUpdate(node, dt)
  local g = grab
  if not g or g.kind == "plant" then return end
  if not (g.node and g.node.valid) then return end
  local ap = node.tickPos or node.pos
  if not (ap and g.ox) then return end
  local tx, ty, tz = ap.x + g.ox, ap.y + g.oy, ap.z + g.oz
  local avx, avy, avz = 0, 0, 0
  if node.vel then avx, avy, avz = node.vel.x, node.vel.y, node.vel.z end
  local ux, uy, uz, gacc = gravity_at(tx, ty, tz)
  local m, px, py, pz, vx, vy, vz
  local inf
  if g.kind == "asm" then
    inf = assembly.info(g.node)
    if not inf then return end
    m = inf.mass or g.mass
    -- The pose's rotation from the node, its translation physics-fresh: the
    -- node lags the rails inside fixedUpdate, `origin` does not.
    local w = g.node:toWorld(vec3(g.lp.x, g.lp.y, g.lp.z))
    local np = g.node.worldPos
    local o = inf.origin
    if o and np then
      px, py, pz = w.x - np.x + o.x, w.y - np.y + o.y, w.z - np.z + o.z
    else
      px, py, pz = w.x, w.y, w.z
    end
    local v, wv, c = inf.vel, inf.angVel, inf.com
    vx, vy, vz = v and v.x or 0, v and v.y or 0, v and v.z or 0
    if wv and c then
      local rx, ry, rz = px - c.x, py - c.y, pz - c.z
      vx = vx + (wv.y * rz - wv.z * ry)
      vy = vy + (wv.z * rx - wv.x * rz)
      vz = vz + (wv.x * ry - wv.y * rx)
    end
  else
    local rb = g.node:getcomponent("RigidBody")
    m = (rb and rb.mass) or g.mass
    local w = g.node:toWorld(vec3(g.lp.x, g.lp.y, g.lp.z))
    px, py, pz = w.x, w.y, w.z
    local v = g.node.vel
    vx, vy, vz = v.x, v.y, v.z
  end
  m = math.max(m, 1e-3)
  g.mass = m
  -- Spring-damper on the grab point. Stiffness grows with mass only up to
  -- `grav_mref`: light things snap, heavy things lag and sag.
  local me = math.min(m, params.grav_mref)
  local w0 = params.grav_omega
  local k = me * w0 * w0
  local c = 2 * params.grav_zeta * me * w0
  local ex, ey, ez = tx - px, ty - py, tz - pz
  local fx = k * ex - c * (vx - avx) + m * gacc * ux
  local fy = k * ey - c * (vy - avy) + m * gacc * uy
  local fz = k * ez - c * (vz - avz) + m * gacc * uz
  local f = len(fx, fy, fz)
  local cap = params.grav_force
  strain = f / math.max(cap, 1e-6)
  if f > cap then
    local s = cap / f
    fx, fy, fz = fx * s, fy * s, fz * s
  end
  local e = len(ex, ey, ez)
  if e > 2.5 then g.stretch = (g.stretch or 0) + dt * (e / 2.5) else g.stretch = math.max(0, (g.stretch or 0) - dt * 2) end
  if g.kind == "asm" then
    assembly.forceAt(g.node, vec3(fx, fy, fz), vec3(px, py, pz))
    -- Let the tumble die: a torque against the spin, inside the same budget.
    local wv, I = inf.angVel, inf.inertia
    if wv and I and I[1] then
      local d = params.grav_spin_damp
      local tqx = -(I[1].x * wv.x + I[1].y * wv.y + I[1].z * wv.z) * d
      local tqy = -(I[2].x * wv.x + I[2].y * wv.y + I[2].z * wv.z) * d
      local tqz = -(I[3].x * wv.x + I[3].y * wv.y + I[3].z * wv.z) * d
      local tq = len(tqx, tqy, tqz)
      local tcap = cap * 0.5
      if tq > tcap then tqx, tqy, tqz = tqx * tcap / tq, tqy * tcap / tq, tqz * tcap / tq end
      assembly.torque(g.node, vec3(tqx, tqy, tqz))
    end
  else
    local v = g.node.vel
    g.node.vel = vec3(v.x + fx / m * dt, v.y + fy / m * dt, v.z + fz / m * dt)
  end
end

-- ── the relay beacon ────────────────────────────────────────────────────────
-- Planting is a decision about WHERE: the ghost (teal: it can stand; red: too
-- steep, too close to another), the ring of ground a probe can hear it from,
-- and a line to each relay it would link to. Aim at a planted one and Q
-- picks it back up.

local BEACON = { slope = 0.74, spacing = 4.0, grab = 3.5 }
local trig_was = false
local preview = nil
local reach_cache = {}

local function beacon_reach(R)
  local E = ref("electronics")
  if not E then return 0 end
  local k = math.floor(R + 0.5)
  local v = reach_cache[k]
  if not v then
    local C = E.COMMS
    v = E.groundReach(R, C.beacon.mast, C.coverLift, C.coverRx, C.beacon.power)
    reach_cache[k] = v
  end
  return v
end

-- (Planting is item_hand's DEPLOY MODE now, and picking one back up is the
-- right-click menu's "Pick up": Q is the laser's mode key. The gravity gun
-- still pulls a planted beacon up, above.)

local ghosts = {}
local function ghost_node(prefab, x, y, z)
  local g = ghosts[prefab]
  if g == "spawning" then return nil end
  if g and g.valid then return g end
  ghosts[prefab] = "spawning"
  spawn(prefab, vec3(x, y, z), function(n) ghosts[prefab] = n; n.visible = false end)
  return nil
end
local function ghost(show, x, y, z, ux, uy, uz, ok)
  for _, k in ipairs({ "RelayBeaconGhost", "RelayBeaconGhostBad" }) do
    local g = ghosts[k]
    local want = show and ((k == "RelayBeaconGhost") == (ok == true))
    if want then g = ghost_node(k, x, y, z) end
    if g and g ~= "spawning" and g.valid then
      if want then
        local E = ref("electronics")
        local half = ((E and E.COMMS.beacon.height) or 4.2) * 0.5
        local fx, fy, fz = 1 - ux * ux, -ux * uy, -ux * uz
        if fx * fx + fy * fy + fz * fz < 1e-4 then fx, fy, fz = 0, 0, 1 end
        g:setUp(vec3(ux, uy, uz), vec3(fx, fy, fz))
        g.x, g.y, g.z = x + ux * half, y + uy * half, z + uz * half
      end
      if g.visible ~= want then g.visible = want end
    end
  end
end

paint_beacon = function(req)
  if not req then ghost(false) return end
  local b = space.body(req.body or "")
  if not b then ghost(false) return end
  local x, y, z = b.x + req.x, b.y + req.y, b.z + req.z
  local r = len(req.x, req.y, req.z)
  if r < 1e-3 then ghost(false) return end
  local ux, uy, uz = req.x / r, req.y / r, req.z / r
  if req.pick then
    ghost(false)
    fx_use("AimMark", { x = x + ux * 0.08, y = y + uy * 0.08, z = z + uz * 0.08, ux = ux, uy = uy, uz = uz,
                        scale = 1.2 / 0.39, power = 1.0, r = 1.0, g = 0.78, b = 0.35 })
    return
  end
  ghost(true, x, y, z, ux, uy, uz, req.ok)
  local E = ref("electronics")
  local c = req.ok and (req.linked and { 0.30, 0.95, 0.80 } or { 1.0, 0.78, 0.35 }) or { 1.0, 0.38, 0.30 }
  fx_use("AimMark", { x = x + ux * 0.08, y = y + uy * 0.08, z = z + uz * 0.08, ux = ux, uy = uy, uz = uz,
                      scale = 0.6 / 0.39, power = 0.8, r = c[1], g = c[2], b = c[3] })
  -- (the coverage ring and the link lines below are a planning overlay, the
  -- map's kind of drawing, and stay lines)
  local reach = beacon_reach(r)
  if reach > 1 then
    local sx, sy, sz = 1 - ux * ux, -ux * uy, -ux * uz
    local sl = len(sx, sy, sz)
    if sl < 1e-3 then sx, sy, sz, sl = 0, 0, 1, 1 end
    sx, sy, sz = sx / sl, sy / sl, sz / sl
    local tx, ty, tz = uy * sz - uz * sy, uz * sx - ux * sz, ux * sy - uy * sx
    local th = reach / r
    local ct, st = math.cos(th), math.sin(th)
    local rr = r + 1.0
    local pts = {}
    for i = 0, 71 do
      local a = i / 72 * 2 * math.pi
      local ca, sa = math.cos(a), math.sin(a)
      pts[#pts + 1] = b.x + (ux * ct + (sx * ca + tx * sa) * st) * rr
      pts[#pts + 1] = b.y + (uy * ct + (sy * ca + ty * sa) * st) * rr
      pts[#pts + 1] = b.z + (uz * ct + (sz * ca + tz * sa) * st) * rr
    end
    draw.polyline(pts, c[1], c[2], c[3], 0.75, true)
  end
  local m = (E and E.COMMS.beacon.mast) or 2.2
  local ax, ay, az = x + ux * m, y + uy * m, z + uz * m
  for _, l in ipairs(req.links or {}) do
    local lr, lg, lb = 0.4, 0.9, 0.6
    if E and E.strengthColor then lr, lg, lb = E.strengthColor(l.hop or l.strength or 0) end
    draw.line(ax, ay, az, b.x + l.x, b.y + l.y, b.z + l.z, lr, lg, lb, 0.9)
  end
end

-- ── lateUpdate: after the rails, draw what update decided ───────────────────

-- The PLANT MARK: motes rising through the whole plant (PlantMark, the node
-- scaled to the plant's body: its spread across, its height up) and a ring at
-- its foot (AimMark), in the target colour, warming as the work goes on.
local function paint_plant(req)
  local w = to_world(req.h)
  local ux, uy, uz = req.ux or 0, req.uy or 1, req.uz or 0
  local h = math.max(0.4, math.min(12, req.height or 1))
  -- A tree's record is its CROWN instance (the trunk is a twin), so `w` can
  -- stand metres up in the air: the marks belong at its foot. A ray down
  -- finds the ground (the field's signed distance only answers within a
  -- metre of the surface); the trunk's own collider on the way is skipped.
  if raycast and h > 1.0 then
    local hit = raycast(w.x, w.y, w.z, -ux, -uy, -uz, 24)
    if hit and hit.node then
      local hit2 = raycast(hit.x - ux * 0.05, hit.y - uy * 0.05, hit.z - uz * 0.05, -ux, -uy, -uz, 24, hit.node)
      if hit2 then hit = { x = hit2.x, y = hit2.y, z = hit2.z, distance = (hit.distance or 0) + 0.05 + (hit2.distance or 0), node = hit2.node } end
    end
    if hit and (hit.distance or 0) > 0.25 then w = { x = hit.x, y = hit.y, z = hit.z } end
  end
  local ff = ref("flora_field")
  local wide = (ff and ff.girthOf and req.sp) and ff.girthOf(req.sp, h, h * 0.6, 0.3) or (h * 0.3)
  wide = math.max(0.35, math.min(3.5, wide))
  local k = req.work or 0
  local c = req.ready and RING.ok or RING.idle
  local r = c[1] + (RING.hot[1] - c[1]) * k
  local g = c[2] + (RING.hot[2] - c[2]) * k
  local b = c[3] + (RING.hot[3] - c[3]) * k
  if FX_VOLUME then
    -- rc25: the plant itself carries the mark (its rim and glow, below); the
    -- motes rise from its foot, their birth disc fitted to the plant's spread
    -- by emission volume (the cone's 0.5 radius × volume = half the spread),
    -- the same mote count and size on a tuft and a tree. The node stays at
    -- the foot: lifted up the trunk, the scaled birth disc drew as a ring
    -- floating at the crown.
    local v = math.max(0.4, math.min(7, wide))
    fx_use("PlantMark", { x = w.x + ux * 0.05, y = w.y + uy * 0.05, z = w.z + uz * 0.05, ux = ux, uy = uy, uz = uz,
                          volume = v, power = 0.6 + 0.8 * k, r = r, g = g, b = b })
    tint_instance(req.src, req.inst, k, "plant")
  else
    fx_use("PlantMark", { x = w.x + ux * 0.05, y = w.y + uy * 0.05, z = w.z + uz * 0.05, ux = ux, uy = uy, uz = uz,
                          scale = wide, sy = h, power = 0.6 + 0.8 * k, r = r, g = g, b = b })
  end
  local mr, dim = ring_on_screen(w.x, w.y, w.z, ux, uy, uz, math.max(0.5, wide * 0.9), RING_CAP.plant)
  fx_use("AimMark", { x = w.x + ux * 0.06, y = w.y + uy * 0.06, z = w.z + uz * 0.06, ux = ux, uy = uy, uz = uz,
                      scale = mr / 0.39, power = 0.7 * dim, r = r, g = g, b = b })
end
-- The ROCK MARK (rc25): the stone or crystal the gravity gun is aimed at, in
-- the engine's own highlight. Nothing before rc25: a rock had no mark.
local function paint_rock(req) tint_instance(req.src, req.inst, 0, "rock") end

-- THE BEAMS. Each is a particle effect on a pooled node stood at the muzzle
-- and aimed with setBeamEnd (see THE EFFECTS); what meets the far end is a
-- second node there.
local function paint_beam(req, dt)
  local w = to_world(req.h)
  local mx, my, mz = muzzle()
  if not mx then return end
  local p = req.p or 0.5
  if req.kind == "grav" or req.kind == "plant" or req.kind == "pending" then
    -- The tether: blue-white, amber as the strain climbs; green on a plant.
    local s = math.min(1.0, strain)
    local r, g, b = 1 + 0.7 * s, 1 - 0.15 * s, 1 - 0.65 * s
    if req.kind == "plant" then r, g, b = 0.75, 1.0, 0.65 end
    -- the sag (rc25): a slack tether bows down its middle by a seventh of its
    -- length, and pulls straight as the strain climbs
    local cx, cy, cz = nil, nil, nil
    if BEAM_BOW then
      local gx, gy, gz = gravity_at(w.x, w.y, w.z)
      local l = len(w.x - mx, w.y - my, w.z - mz)
      local sag = l * (0.15 - 0.12 * s) + 0.05
      cx, cy, cz = (mx + w.x) * 0.5 - gx * sag, (my + w.y) * 0.5 - gy * sag, (mz + w.z) * 0.5 - gz * sag
    end
    fx_use("GravTether", { x = mx, y = my, z = mz, ex = w.x, ey = w.y, ez = w.z, cx = cx, cy = cy, cz = cz, power = 0.6 + 0.7 * p, r = r, g = g, b = b })
    if req.kind ~= "plant" then
      fx_use("GravHold", { x = w.x, y = w.y, z = w.z, power = 0.7 + 0.6 * s, r = r, g = g, b = b })
    end
  elseif req.kind == "cut" then
    fx_use("CutBeam", { x = mx, y = my, z = mz, ex = w.x, ey = w.y, ez = w.z, power = 0.5 + 0.5 * p })
    if req.onPlant then
      -- the bite: its sparks fan back up the beam toward the gun
      local bx, by, bz = mx - w.x, my - w.y, mz - w.z
      local bl = len(bx, by, bz)
      if bl > 1e-4 then bx, by, bz = bx / bl, by / bl, bz / bl else bx, by, bz = 0, 1, 0 end
      fx_use("CutBite", { x = w.x, y = w.y, z = w.z, ux = bx, uy = by, uz = bz, power = 0.5 + 0.7 * p })
    end
    impact(w, p, "cut")
  elseif req.kind == "fill" then
    fx_use("FillBeam", { x = mx, y = my, z = mz, ex = w.x, ey = w.y, ez = w.z, power = 0.5 + 0.6 * p })
    local nx, ny, nz = req.nx, req.ny, req.nz
    if not nx then nx, ny, nz = gravity_at(w.x, w.y, w.z) end
    fx_use("FillDeposit", { x = w.x + nx * 0.1, y = w.y + ny * 0.1, z = w.z + nz * 0.1, ux = nx, uy = ny, uz = nz,
                            power = 0.4 + 0.8 * p })
    impact(w, p, "fill")
  else
    fx_use("DigBeam", { x = mx, y = my, z = mz, ex = w.x, ey = w.y, ez = w.z, power = 0.45 + heat * 0.3 + p * 0.6 })
    impact(w, p, "dig")
  end
end

local stowed = false
function lateUpdate(node, dt)
  beamQuads = 0
  if reticle_draw then reticle_draw() end
  reticle_draw = nil
  -- Tools away (aboard, the map, a panel): hide what is out once, then cost
  -- nothing — no models, no finds, no beams, frame after frame.
  if gate ~= "in hand" then
    hold.w, gripX = 0.0, nil
    if not stowed then
      stowed = true
      show_models(node, dt, false)
      impact(nil)
      beam_particles(nil)
      paint_beacon(nil)
      fx_sweep()
      tint_sweep()
    end
    beam_req, ring_req, plant_req, rock_req, beacon_req, grav_idle_req = nil, nil, nil, nil, nil, false
    return
  end
  stowed = false
  show_models(node, dt, gate == "in hand")
  hold_pose(dt, not first_person())
  articulate(dt)
  if beam_req then
    paint_beam(beam_req, dt)
    if beam_req.kind == "grav" or beam_req.kind == "plant" or beam_req.kind == "pending" then impact(nil) end
  elseif beam_req == false then
    impact(nil)
  end
  -- (the hand socket's own beam is retired: every beam is a pooled node now)
  beam_particles(nil)
  beam_req = nil
  -- The gun out and idle: the cold glow between its claws.
  if grav_idle_req then
    local mx, my, mz = muzzle()
    if mx then fx_use("GravIdle", { x = mx, y = my, z = mz, power = 1.0 }) end
  end
  grav_idle_req = false
  -- The laser shedding heat: a shimmer and the odd ember off its heat sink,
  -- as strong as it is hot (vfx/LaserVent; nothing below a fifth of the heat).
  if toolId() == "laser" and (heat or 0) > 0.2 then
    local vx, vy, vz = tool_at("vent")
    local _, _, a = crew_model()
    if vx and a then
      fx_use("LaserVent", { x = vx, y = vy, z = vz, ux = a.up_x or 0, uy = a.up_y or 1, uz = a.up_z or 0,
        power = (heat - 0.2) / 0.8 })
    end
  end

  if ring_req then
    local h = ring_req.h
    local w = to_world(h)
    local nx, ny, nz = field_normal(w.x, w.y, w.z)
    if nx then h.nx, h.ny, h.nz = nx, ny, nz end
    local s = ring_s
    local d2 = s and s.body == h.body and ((h.x - s.x) ^ 2 + (h.y - s.y) ^ 2 + (h.z - s.z) ^ 2)
    if d2 and d2 < 1.6 * 1.6 then
      local k = 1 - math.exp(-25 * dt)
      local kn = 1 - math.exp(-12 * dt)
      s.x, s.y, s.z = s.x + (h.x - s.x) * k, s.y + (h.y - s.y) * k, s.z + (h.z - s.z) * k
      local ax, ay, az = s.nx or 0, s.ny or 1, s.nz or 0
      local bx, by, bz = h.nx or ax, h.ny or ay, h.nz or az
      ax, ay, az = ax + (bx - ax) * kn, ay + (by - ay) * kn, az + (bz - az) * kn
      local l = len(ax, ay, az)
      if l > 1e-6 then s.nx, s.ny, s.nz = ax / l, ay / l, az / l end
    else
      ring_s = { body = h.body, x = h.x, y = h.y, z = h.z, nx = h.nx, ny = h.ny, nz = h.nz }
    end
    paint_ring(to_world(ring_s), ring_req.firing, ring_req.full, ring_req.r, ring_req.fill)
  else
    ring_s = nil
  end
  ring_req = nil

  if plant_req then paint_plant(plant_req) end
  plant_req = nil
  if rock_req then paint_rock(rock_req) end
  rock_req = nil

  paint_beacon(beacon_req)
  beacon_req = nil
  fx_sweep()
  tint_sweep()
end

-- ── the driver ──────────────────────────────────────────────────────────────

function start(node)
  cam = ref("planet_camera")
  local inv = ref("inventory")
  if inv and inv.ensureKit then inv.ensureKit("astro") end
  local id = save.get("tool.id")
  if type(id) ~= "string" then
    local old = save.get("tool.equipped")
    id = (type(old) == "number" and OLD_SLOT[old]) or "gravgun"
  end
  equipped = id
  swap_from = nil
  laserMode = save.get("tool.laserMode") == "fill" and "fill" or "dig"
end

local function reset_tool_state(why_)
  progress = 0
  reticleKind, reticleLabel = "none", ""
  cutMode = false
  saw_reset()
  charge, cut_progress, focus = 0.0, 0.0, 0.0
  bore_drop()
  hum_off()
  if grab then release(why_, true) end
end

local function equip(id, b)
  if equipped == id then return end
  -- The tool going away dips out of the hands as the new one comes up.
  swap_from, swap_t = equipped, time
  equipped = id
  save.set("tool.id", id)
  play(SFX.swap, { track = "UI", volume = 0.45 })
  local d = TOOLDEF[id]
  if d then say(d.label .. " — " .. d.hint) end
  reset_tool_state()
  -- A swap never fires on a stale trigger: planting the last beacon put the
  -- gravity gun back in the hand under a still-held click, which pulled the
  -- beacon straight back up.
  need_release = true
  recoil = recoil + 0.03
end

-- What surveyor.lua is lent to aim and fire from the hands (made once a node).
-- (kept on `view`: this chunk is at Lua's 200-local limit)
function surveyor_api(node)
  if view.sv_api and view.sv_api.node == node then return view.sv_api end
  view.sv_api = {
    node = node,
    aim = function() return aim_ray(node) end,
    muzzle = function() return muzzle() end,
    fp = function() return first_person() end,
    kick = function(k) recoil = recoil + k; mech.kickv = mech.kickv + k * 30 end,
    say = function(t) say(t) end,
  }
  return view.sv_api
end
-- Is the view behind the eyes (planet_camera's first person)?
function firstPersonNow() return first_person() end

local function tick(node, dt, carrying)
  if not carrying then
    reset_tool_state("tools stowed: " .. gate)
    show_beam(nil)
    publish_shake(0)
    return
  end
  if not cam then
    cam = ref("planet_camera")
    if not cam then why("no planet_camera — nothing to aim along") return end
  end
  if not (cam.cam_x and cam.fwd_x) then why("the camera has not published a view yet") return end
  local edx, edy, edz = cam.cam_x - node.x, cam.cam_y - node.y, cam.cam_z - node.z
  if (edx * edx + edy * edy + edz * edz) > 4000.0 then
    why(string.format("the camera is %.0f m from the crew — it is following something else "
      .. "(orbit map open?), so a shot would fire from there", len(edx, edy, edz)), "camera far")
    reset_tool_state("camera far")
    show_beam(nil)
    return
  end

  -- The belt, from the pack. The equipped tool has to be on it: plant the
  -- last beacon and the hand goes back to the gravity gun.
  local b = belt()
  local H = ref("item_hand")
  if H and H.held then
    -- the hand is item_hand's (number keys, H, the menus): follow it, with
    -- the swap's dip, and never fire on the click that changed it
    local want = H.held()
    if want ~= equipped then
      swap_from, swap_t = equipped, time
      equipped = want
      reset_tool_state()
      need_release = true
      recoil = recoil + 0.03
      local d = want and TOOLDEF[want]
      if d then say(d.label .. " — " .. d.hint) end
    end
  else
    for i, s in ipairs(b) do
      if pressed(tostring(i)) then equip(s.id, b) end
    end
    if not slot_of(toolId(), b) then
      local fallback = (b[1] and b[1].id) or "gravgun"
      if equipped ~= fallback then equip(fallback, b) end
    end
  end
  tool = slot_of(toolId(), b) or 0

  local id = toolId()
  local firing = btn(0)
  inUse = firing
  -- "No new catch until the trigger comes up" ends when it comes up, whatever
  -- is in hand: a release missed while another tool (or none) was out left
  -- the gravity gun refusing every plant until it was clicked twice.
  if not firing then need_release = false end
  if id ~= "gravgun" and grab then release("tool changed", true) end
  if id ~= "gravgun" then wantsScroll = false end
  if id ~= "laser" and cutMode then cutMode = false; saw_reset() end
  if id == "laser" then
    -- CUT while E is held (and E isn't a door's or a crate's right now).
    local want_cut = key_e() and e_taken() == nil
    if want_cut ~= cutMode then
      cutMode = want_cut
      saw_reset()
      bore_drop()
      if cutMode then
        play(SFX.mode, { track = "UI", volume = 0.4, pitch = 1.3 })
        recoil = recoil + 0.01
      end
    end
  end
  if id == "laser" and cutMode then
    inUse = true
    fire_cut(node, dt)
  elseif id == "laser" then
    if key_q() then
      laserMode = laserMode == "dig" and "fill" or "dig"
      save.set("tool.laserMode", laserMode)
      play(SFX.mode, { track = "UI", volume = 0.45 })
      say(laserMode == "fill" and "FILL — the laser lays rock from the canister" or "DIG — the laser cuts rock")
      bore_drop()
      recoil = recoil + 0.02
    end
    if laserMode == "fill" then
      local h, bad = fire_fill(node, dt, firing)
      draw_ring(h, firing and not bad, bad, params.fill_radius, true)
    else
      local hit, full = fire_dig(node, dt, firing)
      draw_ring(hit, firing, full, params.laser_radius * params.laser_strength, false)
    end
    -- The cut is one key away and says so while the beam is idle.
    if not firing and prompt ~= "" and e_taken() == nil then prompt = prompt .. "  ·  hold E: cut plants" end
  elseif id == "gravgun" then
    if not grab then hum_off() end
    fire_grav(node, dt, firing)
  elseif id == "surveyor" then
    -- the TL-5 Surveyor: scripts/surveyor.lua charges, scopes and fires it;
    -- this script holds it (the walker faces the aim while it is busy)
    hum_off()
    show_beam(nil)
    aimMat = nil
    local SV = ref("surveyor")
    if SV and SV.tick then
      local busy, kind, label, px, py, pz = SV.tick(node, dt, firing and not need_release, btn(1), surveyor_api(node))
      inUse = busy == true
      reticle_set(kind or "none", label)
      if px then aimX, aimY, aimZ = px, py, pz else aimX, aimY, aimZ = nil, nil, nil end
    else
      inUse = false
    end
  else
    -- anything else in hand (a kit, a beacon, a flag) or empty hands: the
    -- item's own script works it (item_hand: deploy mode, the repair verb)
    hum_off()
    show_beam(nil)
    aimMat = nil
    inUse = false
  end
end

-- ── the hotbar ──────────────────────────────────────────────────────────────

function tool_label(s)
  if s.consumable then return string.format("%s ×%d", s.label, s.n) end
  if s.id == "surveyor" then
    local SV = ref("surveyor")
    local c = SV and SV.cell
    if c and s.id == toolId() then return string.format("%s  ·  CELL %d%%", s.label, math.floor(c + 0.5)) end
    return s.label
  end
  if s.id == "laser" then
    if cutMode and s.id == toolId() then return s.label .. "  ·  CUT" end
    return s.label .. (laserMode == "fill" and "  ·  FILL" or "  ·  DIG")
  end
  return s.label
end

local function hint_line()
  local d = TOOLDEF[toolId() or ""]
  local H = ref("item_hand")
  if not d and H then
    local recent = time - msg_t < 3.0 and msg ~= ""
    local p = (H.prompt and H.prompt ~= "") and H.prompt or (H.hint and H.hint()) or ""
    if recent then return p ~= "" and (p .. "   ·   " .. msg) or msg end
    return p
  end
  local recent = time - msg_t < 3.0 and msg ~= ""
  if inUse and prompt ~= "" then return recent and (prompt .. "   ·   " .. msg) or prompt end
  if recent then return msg end
  if prompt ~= "" then return prompt end
  return d and d.hint or ""
end

local function pill(key, text)
  return { "row", key = key, style = "hud/toolHint", w = "fit", h = 26, align = "center", pad = 0, gap = 0,
           { "box", key = "l", w = 12, h = 1 },
           { "text", key = "t", w = "fit", h = "fit", textSize = 13, text = text },
           { "box", key = "r", w = 12, h = 1 } }
end

-- The strain gauge while the gravity gun holds something: a dark groove with
-- an ink bar, caution yellow past 70 %, red at the limit.
local function gauge()
  local s = math.max(0, math.min(1, strain))
  local col = strain >= 1 and { 0.97, 0.34, 0.25 } or (s > 0.7 and { 1.0, 0.80, 0.28 } or { 0.77, 0.75, 0.68 })
  return { "row", key = "strain", w = "fit", h = "fit", gap = 8, pad = 0, align = "center",
    { "text", key = "l", style = "hud/label", w = "fit", h = "fit", text = "STRAIN" },
    { "row", key = "g", w = 160, h = 6, radius = 1, pad = 0, gap = 0,
      fill = { 0.02, 0.03, 0.025 }, border = 1, borderColor = { 0, 0, 0, 0.8 },
      { "box", key = "f", w = math.max(2, math.floor(158 * s + 0.5)), h = 6, radius = 1, fill = col } } }
end

function hotbar(carrying)
  if not carrying then return { "col", key = "belt", w = "fit", h = "fit", gap = 0, pad = 0 } end
  local slots = {}
  local b = belt()
  for i, s in ipairs(b) do
    local on = s.id == toolId()
    slots[#slots + 1] = { "row", key = s.id, style = on and "hud/slotActive" or "hud/slot",
      w = "fit", h = 34, gap = 8, align = "center",
      { "text", key = "k", style = on and "hud/keyActive" or "hud/key", w = 20, h = 20,
        textAlign = "center", textValign = "center", text = tostring(i) },
      { "text", key = "l", w = "fit", h = "fit", textSize = 13, text = tool_label(s) } }
  end
  local kids = { pill("hint", hint_line()) }
  if grab and grab.kind ~= "plant" then kids[#kids + 1] = gauge() end
  kids[#kids + 1] = { "row", key = "slots", w = "fit", h = "fit", gap = 6, pad = 0, align = "center",
    items = slots, function(x) return x end }
  local t = { "col", key = "belt", w = "fit", h = "fit", gap = 6, pad = 0, align = "center" }
  for _, k in ipairs(kids) do t[#t + 1] = k end
  return t
end

function hudLine()
  local inv = ref("inventory")
  local parts = {}
  for i, s in ipairs(belt()) do
    parts[#parts + 1] = string.format("%s%d %s", s.id == toolId() and "▸" or " ", i, tool_label(s))
  end
  local head = table.concat(parts, "   ")
  if time - msg_t < 3.0 and msg ~= "" then return head .. "   ·   " .. msg end
  if prompt ~= "" then return head .. "   ·   " .. prompt end
  return head .. "   ·   " .. (inv and inv.line("astro") or "")
end

-- THE RETICLE: a shape per target under it, the target's name and its key
-- under that, and the work as a ring of pips. HUD, in screen pixels (filled
-- circles and bars: never a gizmo line in the world).
--   none      a dim dot: nothing in reach
--   dig/fill  a ring with four ticks (the laser's bore), orange while it bites
--   full      the same in caution yellow: the pack is full / it can't
--   cut       a thin ring with two blade ticks and the word
--   grab      four corner brackets: something loose
--   heavy     the brackets in caution yellow: it will only drag
--   hold      the brackets closed in, tinted by the strain
--   plant     the brackets in the plant's green
--   interact  an E key: a door or a crate wants E
local RET = {
  ink = { 0.92, 0.89, 0.81 }, muted = { 0.56, 0.55, 0.50 }, accent = { 0.97, 0.55, 0.22 },
  warn = { 1.0, 0.80, 0.28 }, danger = { 0.97, 0.34, 0.25 },
  plant = { 0.55, 0.9, 0.6 }, hot = { 1.0, 0.96, 0.86 },
}
local function bar(x, y, w, h, c, a)  -- a filled bar with a dark edge
  draw.rect(x - 1, y - 1, w + 2, h + 2, 0, 0, 0, a * 0.45)
  draw.rect(x, y, w, h, c[1], c[2], c[3], a)
end
local function draw_reticle()
  if not (draw and draw.circleOutline and draw.rect and camera and camera.screenRect) then return end
  local ax, ay = aim_pixel()
  if not ax then return end
  if cinematicUp() then return end
  local _, _, _, vh = camera.screenRect()
  local k = (vh or 720) / uiDesignH()
  -- the rifle draws its own (a crosshair with the charge; its scope's picture)
  if toolId() == "surveyor" then
    local SV = ref("surveyor")
    if SV and SV.drawReticle then SV.drawReticle(ax, ay, k, first_person()) return end
  end
  local kind = reticleKind or "none"
  local c, a = RET.ink, 0.85
  if kind == "none" then c, a = RET.muted, 0.6 end
  if kind == "full" or kind == "heavy" then c = RET.warn end
  if kind == "plant" then c = RET.plant end
  if kind == "cut" then c = RET.hot end
  if inUse and (kind == "dig" or kind == "fill" or kind == "cut" or kind == "plant") then c = RET.accent end
  if kind == "hold" then
    local s = math.min(1, strain)
    c = { 0.55 + 0.45 * s, 0.92 - 0.35 * s, 1.0 - 0.75 * s }
    if strain >= 1 then c = RET.danger end
  end
  local r, g, b = c[1], c[2], c[3]
  if kind == "grab" or kind == "heavy" or kind == "hold" or kind == "plant" then
    -- corner brackets, closed in on a hold
    local d = (kind == "hold" and 9 or 14) * k
    local l, t = 6 * k, 1.6 * k
    for _, sx in ipairs({ -1, 1 }) do
      for _, sy in ipairs({ -1, 1 }) do
        local cx, cy = ax + sx * d, ay + sy * d
        bar(sx > 0 and cx - l or cx, cy - t / 2, l, t, c, a)
        bar(cx - t / 2, sy > 0 and cy - l or cy, t, l, c, a)
      end
    end
    draw.circle(ax, ay, 1.5 * k, r, g, b, a)
  elseif kind == "interact" then
    if draw.rectOutline then
      draw.rectOutline(ax - 9 * k, ay - 9 * k, 18 * k, 18 * k, 0, 0, 0, 0.5, 3.5 * k)
      draw.rectOutline(ax - 9 * k, ay - 9 * k, 18 * k, 18 * k, r, g, b, a, 1.6 * k)
    end
    if draw.text then draw.text(ax, ay - 6.5 * k, "E", 12 * k, r, g, b, a, "center") end
  else
    local rr = (kind == "cut") and 7 * k or 9 * k
    draw.circleOutline(ax, ay, rr, 0, 0, 0, a * 0.45, 3.5 * k)
    draw.circleOutline(ax, ay, rr, r, g, b, a, (kind == "cut") and 1.2 * k or 1.6 * k)
    draw.circle(ax, ay, 1.5 * k, r, g, b, a)
    if kind == "dig" or kind == "fill" or kind == "full" then
      -- four ticks: the laser's aim is a bore, not a point
      local t, l0, l1 = 1.6 * k, 11 * k, 16 * k
      bar(ax - t / 2, ay - l1, t, l1 - l0, c, a); bar(ax - t / 2, ay + l0, t, l1 - l0, c, a)
      bar(ax - l1, ay - t / 2, l1 - l0, t, c, a); bar(ax + l0, ay - t / 2, l1 - l0, t, c, a)
    elseif kind == "cut" then
      -- two blade ticks across, and the word
      local t = 1.4 * k
      bar(ax - 15 * k, ay - t / 2, 6 * k, t, c, a); bar(ax + 9 * k, ay - t / 2, 6 * k, t, c, a)
      if draw.text then
        draw.text(ax, ay + 11 * k, "CUT", 11 * k, 0, 0, 0, 0.55, "center")
        draw.text(ax, ay + 10 * k, "CUT", 11 * k, r, g, b, a, "center")
      end
    end
  end
  -- The work: a ring of pips lit by the progress (the dig's next unit, the
  -- cut and the uproot through the plant, a hold's strain).
  if progress > 0.01 and kind ~= "none" and kind ~= "interact" then
    local n = 24
    local lit = math.floor(progress * n + 0.5)
    for i = 0, n - 1 do
      local ang = -math.pi / 2 + i / n * 2 * math.pi
      local px, py = ax + math.cos(ang) * 22 * k, ay + math.sin(ang) * 22 * k
      if i < lit then draw.circle(px, py, 1.5 * k, RET.accent[1], RET.accent[2], RET.accent[3], 0.95)
      else draw.circle(px, py, 1.0 * k, r, g, b, 0.3) end
    end
  end
  if draw.text then
    -- the target and the key: one short line under the reticle
    local lab = reticleLabel
    if lab and lab ~= "" then
      draw.text(ax, ay + 30 * k, lab, 12 * k, 0, 0, 0, 0.6, "center")
      draw.text(ax, ay + 29 * k, lab, 12 * k, r, g, b, math.min(1, a + 0.1), "center")
    end
    -- what was just collected, rising and fading
    if collected and time - collected.t < 1.6 then
      local u = (time - collected.t) / 1.6
      local fa = u < 0.7 and 1.0 or (1 - (u - 0.7) / 0.3)
      local y = ay - 32 * k - u * 22 * k
      draw.text(ax, y + 1, collected.text, 13 * k, 0, 0, 0, 0.6 * fa, "center")
      draw.text(ax, y, collected.text, 13 * k, RET.accent[1], RET.accent[2], RET.accent[3], fa, "center")
    end
  end
end

local hud
local function draw_hud(carrying)
  if not hud then hud = find("Tool HUD") end
  if not hud then return end
  local el = hud:getcomponent("UiElement")
  local pm, om = ref("pause_menu"), ref("orbit_map")
  -- A facility panel (the Tracking Station, the depot) or the Ops Board owns
  -- the screen while it is up, as the pause menu does: the hotbar and the
  -- belt's prompts go under it.
  local fm, ob = ref("facility_menu"), ref("ops_board")
  local up = (carrying or gate ~= GATE_ABOARD) and not (pm and pm.open)
    and not (om and om.isOpen and om.isOpen())
    and not (fm and fm.isOpen and fm.isOpen()) and not (ob and ob.isOpen and ob.isOpen())
  -- (the rifle's scope picture in first person fills the view: no hotbar over
  -- it — but the picture itself IS the reticle, so that one stays: hiding it
  -- with the hotbar left a bare zoom with no scope at all)
  local reticle_up = up
  if up and toolId() == "surveyor" and first_person() then
    local SV = ref("surveyor")
    if SV and (SV.scopeK or 0) > 0.6 then up = false end
  end
  if el then el.visible = up end
  if el then
    local y = (access and access.captions and access.captions()) and -84 or -16
    if el.posY ~= y then el.posY = y end
  end
  if carrying and prompt == "" and gate ~= "in hand" then prompt = gate end
  hudText = carrying and hudLine() or ("tools stowed  ·  " .. gate)
  if up and ui and ui.make then ui.make(hud, hotbar(carrying)) end
  reticle_draw = (reticle_up and carrying and gate == "in hand") and draw_reticle or nil
end

function update(node, dt)
  inUse = false
  prompt = ""
  reticleKind, reticleLabel = "none", ""
  local carrying = on_foot(node)
  tick(node, dt, carrying)
  -- A door or a crate wants E: the reticle says so over whatever the tool
  -- would have shown, unless the tool is working.
  if carrying and not inUse and reticleKind == "none" then
    local t = e_taken()
    if t then reticle_set("interact", t) end
  end
  -- The aim point is a WORLD point of this update; the ticks then carry the
  -- planet (and the crew on it) on along its orbit before lateUpdate poses
  -- the arms and the head. Held in the planet's frame for that.
  aim_body = aimX and to_body({ x = aimX, y = aimY, z = aimZ }) or nil
  draw_hud(carrying)
end

-- The aim point where it is NOW (for lateUpdate's poses: the walker's head,
-- the hold), or nil.
function aimNow()
  if not aim_body then return nil end
  local w = to_world(aim_body)
  return w.x, w.y, w.z
end
