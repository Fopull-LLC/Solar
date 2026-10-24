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
--                  craft — hold LMB and it is caught at the point you aimed
--                  at and pulled to a spot in front of you on a spring.
--                  Scroll: nearer / further.  R: throw.  Release: drop.
--                  Aimed at a plant it uproots it (the harvest).
--   TERRAIN LASER  hold LMB: DIG cuts rock and streams it into the pack.
--                  Q: switch to FILL, which lays rock back down out of the
--                  pack's own rubble (the spade's raise, with a price).
--   RELAY BEACON   consumable. LMB plants one where it can stand; Q picks
--                  a planted one back up. Bought at the depot's BUY counter.
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
  -- about 0.4 t held against the home world's pull.
  --@range 0.5 40
  grav_force = 4.0,
  --@range 2 20 --@units rad/s
  grav_omega = 9.0,        -- how fast a light object snaps to the aim
  --@range 0.2 1.5
  grav_zeta = 0.8,         -- damping ratio of the pull
  --@range 0.02 3 --@units t
  grav_mref = 0.25,        -- stiffness stops growing with mass past this
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
holding = nil    -- { name, mass, strain, kind } while the gravity gun holds something
strain = 0.0     -- 0..1+ how hard the gravity gun is working
wantsScroll = false -- the gravity gun is using the wheel (the camera leaves it alone)
gate = "starting up"
hudText = ""
-- TEST HOOKS (probes and the smoke harness): `sim` overrides the mouse and
-- keys — { btn = { [0]=true }, pressed = { r = true }, scroll = n, aim = {ox,oy,oz,dx,dy,dz} }.
sim = nil

-- What each kind of gear does on the belt. The ORDER is the belt's order.
TOOL_ORDER = { "gravgun", "laser", "beacon" }
TOOLDEF = {
  gravgun = { label = "Gravity Gun", prefab = "ToolGravGun", fp_prefab = "ToolGravGunFP",
              hint = "hold LMB to grab  ·  scroll nearer / further  ·  R throw  ·  aim at a plant to uproot it" },
  laser   = { label = "Terrain Laser", prefab = "ToolLaser", fp_prefab = "ToolLaserFP",
              hint = "hold LMB to dig  ·  Q switches DIG / FILL" },
  beacon  = { label = "Relay Beacon", consumable = true,
              hint = "LMB plant a relay beacon  ·  Q pick one up" },
}

-- Where the hands hold each model and where its beam leaves, relative to the
-- model's centre (tools/gen_tools.py prints these). `fore` is the other
-- hand's hold. The first-person models carry their own gloved hands and are
-- different meshes, so they have their own centre and their own numbers.
RIG = {
  gravgun = { grip = { 0.0, -0.056, 0.123 }, muzzle = { 0.0, 0.029, -0.227 }, fore = { 0.0, -0.061, -0.052 } },
  laser   = { grip = { 0.022, -0.048, 0.195 }, muzzle = { 0.022, 0.037, -0.42 }, fore = { 0.022, -0.043, -0.105 } },
}
RIG_FP = {
  gravgun = { grip = { 0.092, 0.101, -0.042 }, muzzle = { 0.092, 0.186, -0.392 } },
  laser   = { grip = { 0.091, 0.111, 0.049 }, muzzle = { 0.091, 0.196, -0.566 } },
}
-- THIRD PERSON: how each tool is carried, in the body's frame (metres from the
-- right shoulder joint: in toward the chest, down, forward), at rest (`low`,
-- a relaxed low-ready) and while the trigger is held (`aim`). Every tool is at
-- TRUE SIZE (scale 1): the gravity gun is 0.64 m long, the laser 0.83 m.
-- `pitch` is the low-ready's muzzle-down angle.
HOLD = {
  gravgun = { low = { 0.07, 0.25, 0.30 }, aim = { 0.08, 0.19, 0.33 }, pitch = -0.32,
              rwrist = { 0.02, 0.015, 0.065 }, lwrist = { -0.02, -0.015, 0.07 },
              rfing = { -0.1, -0.4, -0.9 }, lfing = { 0.25, -0.25, -0.93 } },
  laser   = { low = { 0.08, 0.25, 0.27 }, aim = { 0.10, 0.12, 0.24 }, pitch = -0.38,
              rwrist = { 0.02, 0.015, 0.065 }, lwrist = { -0.015, -0.035, 0.08 },
              rfing = { -0.1, -0.4, -0.9 }, lfing = { 0.15, 0.05, -0.98 } },
}
-- The Laser Tool node (the old rifle, bone-attached to Hand.Right) still
-- carries the laser's particle beam; the tools themselves no longer hang off
-- it (see THE HOLD).
-- FIRST PERSON: where the grip sits in the camera's frame (+x right, +y up,
-- -z ahead), at true size, and the view-model camera's field of view.
local VIEW_AT = { 0.22, -0.31, -0.62 }
local VIEW_SCALE = 1.0
local VM_FOV = 0.95
-- The render layer the view models live on: "viewmodel" (project.ron), else
-- the project's spare "entity" layer — the bit is the layer's place in
-- project.ron's list, after the implicit Default at 0. tests/smoke_toolgate.lua
-- checks the list still says so.
local VM_LAYERS = { { "viewmodel", 3 }, { "entity", 1 } }

local SFX = {
  hum     = "audio/kenney/sci-fi/forceField_004.ogg",
  ore     = "audio/kenney/impact/impactMining_00",   -- + 0..4
  denied  = "audio/kenney/interface/error_003.ogg",
  swap    = "audio/kenney/interface/pluck_001.ogg",
  plant   = "audio/kenney/interface/confirmation_002.ogg",
  pickup  = "audio/kenney/interface/drop_002.ogg",
  grab    = "audio/kenney/sci-fi/forceField_000.ogg",
  hold    = "audio/kenney/sci-fi/engineCircular_001.ogg",
  drop    = "audio/kenney/sci-fi/forceField_002.ogg",
  throw   = "audio/kenney/sci-fi/laserLarge_002.ogg",
  dry     = "audio/kenney/sci-fi/laserSmall_001.ogg",
  fill    = "audio/kenney/sci-fi/slime_000.ogg",
  mode    = "audio/kenney/interface/switch_002.ogg",
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

function toolId()
  return equipped or "gravgun"
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
  n.scale = VIEW_SCALE
  n.x, n.y, n.z = VIEW_AT[1] - g[1] * VIEW_SCALE, VIEW_AT[2] - g[2] * VIEW_SCALE, VIEW_AT[3] - g[3] * VIEW_SCALE
  n:setAngles(0, 0, 0)
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
  local all = 4294967295
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

-- Show the equipped tool in the right place (or nothing), and move the first-
-- person model: sway against the look, bob with the walk, kick on recoil.
local function show_models(node, dt, carrying)
  local h = hand()
  local cn = cam_node()
  local want = carrying and shown_tool(toolId()) or nil
  local fp = first_person()
  local am = crew_model()
  for _, id in ipairs({ "gravgun", "laser" }) do
    local tp = am and model_of("tp", id, am, place_tp)
    local fv = cn and model_of("fp", id, cn, place_fp)
    local on = want == id
    if tp and tp.visible ~= (on and not fp) then tp.visible = on and not fp end
    if fv and fv.visible ~= (on and fp) then fv.visible = on and fp end
  end
  if cn then view_model_cam(cn, fp and want ~= nil) end
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
  local g = RIG_FP[want].grip
  local lean = inUse and 0.012 or 0.0
  fv.x = VIEW_AT[1] - g[1] * VIEW_SCALE + view.sx + bx - lean
  fv.y = VIEW_AT[2] - g[2] * VIEW_SCALE + view.sy - by + view.kick * 0.2 - dip * 0.22
  fv.z = VIEW_AT[3] - g[3] * VIEW_SCALE + view.kick
  -- Toed in toward the crosshair 7 m out, then the sway's lag and the kick.
  local yaw_in = math.atan(VIEW_AT[1] / 7.0)
  local pitch_in = math.atan(-VIEW_AT[2] / 7.0)
  fv:setAngles(yaw_in + view.sx * 1.2, pitch_in + view.kick * 1.4 + view.sy * 1.0 - dip * 0.7, -view.sx * 1.5)
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
  local grip = SR + vec3(inn, -down, 0) + flat * fwdv + vec3(0, math.max(0, dir.y) * 0.12, 0)
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
local function muzzle()
  local id = toolId()
  local fp = first_person()
  local rig = RIG_FP[id]
  if fp and rig and cam and cam.fwd_x then
    local a = find("Astronaut")
    local cn = cam_node()
    if a and cn then
      local ux, uy, uz = a.up_x or 0, a.up_y or 1, a.up_z or 0
      local eh = (cam.params and cam.params.eye_height) or 1.6
      local ex, ey, ez = a.x + ux * eh, a.y + uy * eh, a.z + uz * eh
      local fx, fy, fz = cam.fwd_x, cam.fwd_y, cam.fwd_z
      local r, u = cn:worldRight(), cn:worldUp()
      local g, mz = rig.grip, rig.muzzle
      local lx = VIEW_AT[1] + (mz[1] - g[1]) * VIEW_SCALE + view.sx
      local ly = VIEW_AT[2] + (mz[2] - g[2]) * VIEW_SCALE + view.sy
      local lz = VIEW_AT[3] + (mz[3] - g[3]) * VIEW_SCALE + view.kick
      local main_fov = (cam.params and cam.params.fov_y) or 1.15
      local s = (vm.on and math.tan(main_fov * 0.5) / math.tan(VM_FOV * 0.5)) or 1.0
      lx, ly = lx * s, ly * s
      -- camera frame: +x right, +y up, -z forward
      return ex + r.x * lx + u.x * ly - fx * lz, ey + r.y * lx + u.y * ly - fy * lz, ez + r.z * lx + u.z * ly - fz * lz
    end
  end
  local m = models[fp and "fp" or "tp"][id]
  rig = fp and RIG_FP[id] or RIG[id]
  if rig and m and m ~= "spawning" and m.valid and m.toWorld then
    local mz = rig.muzzle
    local w = m:toWorld(vec3(mz[1], mz[2], mz[3]))
    if w then return w.x, w.y, w.z end
  end
  local a = find("Astronaut")
  if a and cam and cam.fwd_x then
    return a.x + cam.fwd_x * 0.6, a.y + cam.fwd_y * 0.6 + 0.3, a.z + cam.fwd_z * 0.6
  end
  return nil
end

-- ── beams: ribbons of quads, drawn in the camera pass ───────────────────────

local BEAM_GLOW = "textures/vfx/beam/glow.png"
local BEAM_CORE = "textures/vfx/beam/core.png"

-- A camera-facing ribbon through `pts` (flat x,y,z list), `w` half-width.
beamQuads = 0   -- quads the beams drew last frame (the smoke harness and probes read it)
local function ribbon(pts, w, tex, r, g, b, a)
  if not (draw and draw.quad) then return end
  local ex, ey, ez = cam and cam.cam_x, cam and cam.cam_y, cam and cam.cam_z
  if not ex then return end
  local n = #pts / 3
  if n < 2 then return end
  -- One side vector PER POINT (the tangent there × the view to it), shared by
  -- the two quads that meet at it: a ribbon bent near the camera stays one
  -- unbroken strip instead of a fan of fins.
  local side = {}
  for i = 1, n do
    local i0, i1 = math.max(1, i - 1), math.min(n, i + 1)
    local tx = pts[i1 * 3 - 2] - pts[i0 * 3 - 2]
    local ty = pts[i1 * 3 - 1] - pts[i0 * 3 - 1]
    local tz = pts[i1 * 3] - pts[i0 * 3]
    local vx, vy, vz = pts[i * 3 - 2] - ex, pts[i * 3 - 1] - ey, pts[i * 3] - ez
    local sx, sy, sz = ty * vz - tz * vy, tz * vx - tx * vz, tx * vy - ty * vx
    local sl = len(sx, sy, sz)
    if sl < 1e-9 then sx, sy, sz, sl = 0, 1, 0, 1 end
    side[i] = { sx / sl * w, sy / sl * w, sz / sl * w }
  end
  for i = 1, n - 1 do
    local ax, ay, az = pts[i * 3 - 2], pts[i * 3 - 1], pts[i * 3]
    local bx, by, bz = pts[i * 3 + 1], pts[i * 3 + 2], pts[i * 3 + 3]
    local sa, sb = side[i], side[i + 1]
    beamQuads = beamQuads + 1
    draw.quad(tex, ax - sa[1], ay - sa[2], az - sa[3], ax + sa[1], ay + sa[2], az + sa[3],
      bx + sb[1], by + sb[2], bz + sb[3], bx - sb[1], by - sb[2], bz - sb[3], r, g, b, a,
      0, (i - 1) / (n - 1), 1, i / (n - 1))
  end
end

-- A quadratic Bézier from p0 through control c to p2, as a flat point list.
local function bezier(p0x, p0y, p0z, cx, cy, cz, p2x, p2y, p2z, segs)
  local pts = {}
  for i = 0, segs do
    local t = i / segs
    local u = 1 - t
    pts[#pts + 1] = u * u * p0x + 2 * u * t * cx + t * t * p2x
    pts[#pts + 1] = u * u * p0y + 2 * u * t * cy + t * t * p2y
    pts[#pts + 1] = u * u * p0z + 2 * u * t * cz + t * t * p2z
  end
  return pts
end

-- ── aiming ring (laser) ─────────────────────────────────────────────────────

local RING = {
  idle = { 0.55, 0.70, 0.78 },
  ok   = { 0.30, 0.88, 0.76 },
  hot  = { 1.00, 0.78, 0.35 },
  full = { 1.00, 0.45, 0.30 },
  fill = { 0.45, 0.78, 1.00 },
}

local tick_x, tick_y, tick_z = 1, 0, 0
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
  local cx, cy, cz = hit.x + nx * 0.08, hit.y + ny * 0.08, hit.z + nz * 0.08
  local r = radius
  draw.disc(cx, cy, cz, nx, ny, nz, 0.0, r, c[1], c[2], c[3], 0.10)
  draw.disc(cx, cy, cz, nx, ny, nz, r, r * 1.05, c[1], c[2], c[3], 0.35)
  draw.ring(cx, cy, cz, nx, ny, nz, r, c[1], c[2], c[3], 0.9)
  if firing and not fill and cut_progress > 0.02 then
    draw.disc(cx, cy, cz, nx, ny, nz, 0.0, r * cut_progress, RING.hot[1], RING.hot[2], RING.hot[3], 0.16)
    draw.ring(cx, cy, cz, nx, ny, nz, r * cut_progress, RING.hot[1], RING.hot[2], RING.hot[3], 0.85)
  end
  local sx, sy, sz = tick_x, tick_y, tick_z
  local sd = sx * nx + sy * ny + sz * nz
  sx, sy, sz = sx - nx * sd, sy - ny * sd, sz - nz * sd
  local sl = len(sx, sy, sz)
  if sl < 0.2 then
    sx, sy, sz = 1 - nx * nx, -nx * ny, -nx * nz
    sl = len(sx, sy, sz)
    if sl < 1e-3 then sx, sy, sz, sl = 0, 0, 1, 1 end
  end
  sx, sy, sz = sx / sl, sy / sl, sz / sl
  tick_x, tick_y, tick_z = sx, sy, sz
  local tx, ty, tz = ny * sz - nz * sy, nz * sx - nx * sz, nx * sy - ny * sx
  local inner, outer = r * 1.12, r * 1.55
  for _, d in ipairs({ { sx, sy, sz }, { -sx, -sy, -sz }, { tx, ty, tz }, { -tx, -ty, -tz } }) do
    draw.line(cx + d[1] * inner, cy + d[2] * inner, cz + d[3] * inner,
              cx + d[1] * outer, cy + d[2] * outer, cz + d[3] * outer, c[1], c[2], c[3], 0.9)
  end
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
    if ps and not ps:isPlaying() then ps:play() end
    if ps then ps:setIntensity(0.3 + power) end
    if light then
      if kind == "fill" then light.r, light.g, light.b = 0.45, 0.75, 1.0
      else light.r, light.g, light.b = 1.0, 0.62, 0.3 end
      light.intensity = 2.0 + power * 7.0
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

local rocks = {}   -- loose chunks knocked free, oldest first
local function knock_loose(x, y, z, nx, ny, nz)
  if params.rocks_max <= 0 or not spawn then return end
  while #rocks >= params.rocks_max do
    local old = table.remove(rocks, 1)
    if old and old ~= "spawning" and old.valid then old:destroy() end
  end
  local slot = #rocks + 1
  rocks[slot] = "spawning"
  local px, py, pz = x + nx * 0.9, y + ny * 0.9, z + nz * 0.9
  spawn("LooseRock", vec3(px, py, pz), function(n)
    rocks[slot] = n
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
  local mat, _, rich = survey(hit.x, hit.y, hit.z)
  if not mat then return end
  local took = inv.add("astro", mat, rich and 2 or 1)
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
    knock_loose(hit.x, hit.y, hit.z, ux, uy, uz)
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
    return nil
  end
  local nx, ny, nz = h.nx or 0, h.ny or 1, h.nz or 0
  local px, py, pz = h.x + nx * 0.45, h.y + ny * 0.45, h.z + nz * 0.45
  local near = len(px - node.x, py - node.y, pz - node.z) < params.fill_radius + 0.9
  local bad = nil
  if near then bad = "too close — you would bury yourself"
  elseif not rock and fill_credit <= 0 then bad = "the canister is empty — dig some rock first" end
  prompt = "FILL  ·  " .. (bad or "hold LMB to lay rock") .. "  ·  " .. stock_txt
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
        local fx = ref("vfx")
        if fx and fx.dig then fx.dig(h.x, h.y, h.z, true) end
        if math.random() < 0.35 then play(SFX.fill, { track = "SFX", volume = 0.35, pitch = 0.8 + math.random() * 0.3 }) end
      end
    end
    show_beam(h, charge, "fill")
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
  if n:hasTag("loose_rock") then return "Loose Rock" end
  local vc = n.getScript and n:getScript("vessel_controller")
  if vc and vc.craftName then return vc.craftName end
  local nm = n.name or "object"
  if nm == "Vessel" or nm:sub(1, 6) == "Vessel" then return "Debris" end
  return nm
end


-- Where the held point is, in the world, now (and the node's pose answer).
local function grab_world(g)
  if not (g and g.node and g.node.valid) then return nil end
  local w = g.node:toWorld(vec3(g.lp.x, g.lp.y, g.lp.z))
  return w.x, w.y, w.z
end

lastRelease = nil   -- why the gravity gun last let go (probes read it)
local function release(why_, quiet_)
  if grab then lastRelease = why_ or (quiet_ and "quiet") or "trigger up" end
  if grab and grab.kind ~= "plant" and not quiet_ then
    play(SFX.drop, { track = "SFX", volume = 0.45, pitch = 0.9 + math.random() * 0.2 })
  end
  grab, holding, strain, wantsScroll = nil, nil, 0.0, false
  hum_off()
  if why_ then say(why_) end
end

local function try_grab(node, ox, oy, oz, dx, dy, dz)
  local h = ray_hit(node, ox, oy, oz, dx, dy, dz, params.grav_reach)
  if h and h.node then
    local n, kind, inf = dynamic_of(h.node)
    if n and n.id ~= node.id then
      if inf.anchored then return nil, "it's clamped down" end
      local lp = n:toLocal(vec3(h.x, h.y, h.z))
      local d = math.max(params.grav_min, math.min(params.grav_max, h.range))
      return { kind = kind, node = n, lp = lp, dist = d, mass = inf.mass or 0.1, name = name_of(n, kind),
               ox = h.x - node.x, oy = h.y - node.y, oz = h.z - node.z, stretch = 0, t0 = time }, nil, h
    end
  end
  -- No body: a plant? (scattered plants have no colliders)
  local ff = ref("flora_field")
  if ff and ff.nearestPlant then
    local back = len(node.x - ox, node.y - oy, node.z - oz)
    local p = ff.nearestPlant(ox, oy, oz, dx, dy, dz, params.cut_reach + back, 2.0, params.cut_grab)
    if p and p.rec and len(p.x - node.x, p.y - node.y, p.z - node.z) <= params.cut_reach then
      -- Only if the plant is nearer than the ground the ray hits: the aim
      -- must pass through the plant, not through the hill behind it.
      if not h or len(p.x - node.x, p.y - node.y, p.z - node.z) <= h.range + 1.0 then
        return { kind = "plant", plant = p, pid = p.pid, work = 0, name = p.rec.sp.name,
                 need = math.max(0.3, (p.rec.sp.work or 1) * params.uproot), t0 = time }, nil, h
      end
    end
  end
  return nil, h and "nothing loose there — it's part of the ground" or "nothing in reach", h
end

-- Every frame while the gun is out.
local function fire_grav(node, dt, firing)
  local ox, oy, oz, dx, dy, dz = aim_ray(node)
  if not ox then release() show_beam(nil) return end
  local back = len(node.x - ox, node.y - oy, node.z - oz)
  aimMat, aimDepth = nil, 0
  if grab and not firing then
    release()
  end
  if not grab then
    wantsScroll = false
    show_beam(nil)
    -- What the crosshair is over, before the click. Asked ten times a second
    -- while idle (a plant query walks every flora source in reach), and on
    -- the frame the trigger goes down.
    local cand, why_, h
    local pv = grab_preview
    if not firing and pv and time - pv.t < 0.1 and dx * pv.dx + dy * pv.dy + dz * pv.dz > 0.99995 then
      cand, why_, h = pv.cand, pv.why, pv.h
    else
      cand, why_, h = try_grab(node, ox, oy, oz, dx, dy, dz)
      grab_preview = { t = time, cand = cand, why = why_, h = h, dx = dx, dy = dy, dz = dz }
    end
    if h then aimDist, aimX, aimY, aimZ = h.range, h.x, h.y, h.z else aimDist, aimX, aimY, aimZ = nil, nil, nil, nil end
    if cand and cand.kind == "plant" then
      prompt = string.format("GRAVITY GUN  ·  %s  ·  hold LMB to uproot it", cand.name)
      plant_req = { h = to_body({ x = cand.plant.x, y = cand.plant.y, z = cand.plant.z }), ready = false,
                    height = cand.plant.height, ux = cand.plant.ux, uy = cand.plant.uy, uz = cand.plant.uz }
    elseif cand then
      local _, _, _, g = gravity_at(node.x, node.y, node.z)
      local lift = (cand.mass * g) / math.max(0.01, params.grav_force)
      prompt = string.format("GRAVITY GUN  ·  %s  ·  %s  ·  %s", cand.name,
        cand.mass >= 1 and string.format("%.1f t", cand.mass) or string.format("%.0f kg", cand.mass * 1000),
        lift > 2.5 and "far too heavy for the gun — it will only strain"
          or (lift > 1 and "too heavy to lift — you can drag it" or "hold LMB to grab"))
    else
      prompt = "GRAVITY GUN  ·  " .. (why_ or "nothing in reach") .. "  ·  aim at something loose and hold LMB"
    end
    if not firing then need_release = false end
    if firing and not need_release and time - grab_try_t > 0.25 then
      grab_try_t = time
      if cand then
        grab = cand
        if cand.kind ~= "plant" then
          holding = { name = cand.name, mass = cand.mass, strain = 0, kind = cand.kind }
          play(SFX.grab, { track = "SFX", volume = 0.55, pitch = 1.1 - math.min(0.4, cand.mass) })
          if h then spawnEffect("Sparks", vec3(h.x, h.y, h.z), { normal = vec3(h.nx or 0, h.ny or 1, h.nz or 0), intensity = 0.4, scale = 0.5 }) end
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
  if grab.kind == "plant" then
    local p = grab.plant
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
                  ux = p.ux, uy = p.uy, uz = p.uz }
    hum_on(SFX.hold, 0.12 + progress * 0.2, 0.8 + progress * 0.6)
    local fx = ref("vfx")
    if fx and fx.cut then fx.cut(mx, my, mz) end
    local inv = ref("inventory")
    prompt = string.format("UPROOTING %s  %d%%  ·  %s", grab.name, math.floor(progress * 100 + 0.5),
      inv and inv.line("astro") or "")
    if grab.work >= grab.need then
      local ff = ref("flora_field")
      local got, dropped = {}, 0
      if ff and ff.harvest then got, dropped = ff.harvest(p, "astro") end
      local mats = ref("materials")
      local parts = {}
      for _, g in ipairs(got) do
        parts[#parts + 1] = string.format("%s ×%d", (mats and mats.label(g.mat)) or g.mat, g.n)
      end
      say(#parts > 0 and table.concat(parts, ", ") .. (dropped > 0 and "  (pack full)" or "")
        or "pack full — nothing taken")
      if fx and fx.harvest then fx.harvest(p.x, p.y, p.z, p.height) end
      play(SFX.pickup, { track = "SFX", volume = 0.5 })
      recoil = recoil + 0.02
      grab, progress = nil, 0
      hum_off()
      need_release = true       -- don't grab the next plant on the same held click
    end
    return
  end

  if not (grab.node and grab.node.valid) then release("it's gone") show_beam(nil) return end
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
  -- Too far behind the aim for too long (snagged, or far too heavy): let go.
  if (grab.stretch or 0) > params.grav_break then
    release("lost the grip — " .. grab.name .. " is snagged or too heavy")
    show_beam(nil)
    return
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
    spawnEffect("Sparks", vec3(gx, gy, gz), { intensity = 0.8, scale = 0.7 })
    recoil = recoil + 0.06
    publish_shake(0.12)
    local nm = grab.name
    release(nil, true)
    need_release = true
    say(string.format("threw the %s  ·  %.0f m/s", nm, j / math.max(m, 1e-3)))
    show_beam(nil)
    return
  end
  show_beam({ x = gx, y = gy, z = gz }, 0.4 + math.min(1, strain) * 0.6, "grav", { aimx = dx, aimy = dy, aimz = dz })
  hum_on(SFX.hold, 0.10 + math.min(1, strain) * 0.25, 0.7 + math.min(1.2, strain) * 0.5)
  publish_shake(math.min(0.08, strain * 0.05))
  local mtxt = grab.mass >= 1 and string.format("%.1f t", grab.mass) or string.format("%.0f kg", grab.mass * 1000)
  local stxt = strain >= 1.0 and "OVERLOAD — too heavy for the gun"
    or string.format("strain %d%%", math.floor(strain * 100 + 0.5))
  prompt = string.format("HOLDING %s  ·  %s  ·  %s  ·  %.1f m  ·  scroll nearer / further  ·  R throw  ·  release to drop",
    grab.name, mtxt, stxt, grab.dist)
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

function fire_beacon(node, dt, firing)
  local net, inv = ref("comms"), ref("inventory")
  local now_down = firing and not trig_was
  trig_was = firing
  inUse = false
  local h = laser_shot(node)
  if not (net and inv and net.placeBeacon) then prompt = "no comms network in this scene" return end
  if not h then prompt = string.format("no ground within %.0f m of the crosshair", params.laser_reach) return end
  local bname = space.dominant(h.x, h.y, h.z)
  local body = bname and space.body(bname)
  if not body then prompt = "no world under the crosshair" return end
  local near = net.beaconNear(h.x, h.y, h.z, BEACON.grab)
  if near then
    prompt = string.format("Q  pick up %s  (%s)", near.name,
      near.linked and string.format("linked, %d%%", math.floor((near.strength or 0) * 100 + 0.5)) or "no link")
    beacon_req = { pick = true, body = bname, x = near.gx - body.x, y = near.gy - body.y, z = near.gz - body.z }
    if key_q() then
      if inv.addGear("astro", "beacon", 1) < 1 then
        say("PACK FULL — no room to carry the beacon")
        play(SFX.denied, { track = "UI", volume = 0.5 })
      else
        net.removeBeacon(near.id)
        say(near.name .. " picked up")
        play(SFX.pickup, { track = "UI", volume = 0.5 })
      end
    end
    return
  end
  local ux, uy, uz = h.x - body.x, h.y - body.y, h.z - body.z
  local R = len(ux, uy, uz)
  ux, uy, uz = ux / R, uy / R, uz / R
  local nx, ny, nz = field_normal(h.x, h.y, h.z)
  if not nx then nx, ny, nz = h.nx or ux, h.ny or uy, h.nz or uz end
  local carried = inv.gearCount("astro", "beacon")
  local bad = nil
  if carried < 1 then bad = "no beacons in the pack — buy them at the depot's BUY counter"
  elseif nx * ux + ny * uy + nz * uz < BEACON.slope then bad = "too steep to stand a beacon on"
  elseif net.beaconNear(h.x, h.y, h.z, BEACON.spacing) then bad = "too close to another beacon" end
  local lx, ly, lz = h.x - body.x, h.y - body.y, h.z - body.z
  local p = preview
  if not p or p.body ~= bname or time - p.t > 0.3
    or (lx - p.x) ^ 2 + (ly - p.y) ^ 2 + (lz - p.z) ^ 2 > 0.25 then
    local links, connected = net.previewLinks(h.x, h.y, h.z)
    for _, l in ipairs(links) do l.x, l.y, l.z = l.x - body.x, l.y - body.y, l.z - body.z end
    p = { body = bname, x = lx, y = ly, z = lz, links = links, connected = connected, t = time }
    preview = p
  end
  local names = {}
  for i, l in ipairs(p.links) do
    if i > 3 then names[#names + 1] = string.format("+%d more", #p.links - 3) break end
    names[#names + 1] = string.format("%s %d%%", l.name, math.floor(l.hop * 100 + 0.5))
  end
  local links_txt = #names > 0 and ("links to: " .. table.concat(names, ", "))
    or "links to: nothing — no relay with a path home in sight"
  prompt = bad and (bad .. "   ·   " .. links_txt)
    or (string.format("LMB plant (%d in the pack)   ·   ", carried) .. links_txt)
  beacon_req = { body = bname, x = lx, y = ly, z = lz, R = R, ok = bad == nil, linked = p.connected, links = p.links }
  if now_down then
    if bad then
      say(bad)
      play(SFX.denied, { track = "UI", volume = 0.5 })
    elseif inv.removeGear("astro", "beacon", 1) == 1 then
      local id = net.placeBeacon(bname, h.x, h.y, h.z)
      if id then
        say(string.format("Relay %d planted — %s", id, p.connected and links_txt or "no link home yet"))
        play(SFX.plant, { track = "UI", volume = 0.5 })
        preview = nil
      else
        inv.addGear("astro", "beacon", 1)
      end
    end
  end
end

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
    draw.ring(x + ux * 0.1, y + uy * 0.1, z + uz * 0.1, ux, uy, uz, 1.2, 1.0, 0.78, 0.35, 0.95)
    draw.ring(x + ux * 0.1, y + uy * 0.1, z + uz * 0.1, ux, uy, uz, 1.35, 1.0, 0.78, 0.35, 0.5)
    return
  end
  ghost(true, x, y, z, ux, uy, uz, req.ok)
  local E = ref("electronics")
  local c = req.ok and (req.linked and { 0.30, 0.95, 0.80 } or { 1.0, 0.78, 0.35 }) or { 1.0, 0.38, 0.30 }
  draw.ring(x + ux * 0.08, y + uy * 0.08, z + uz * 0.08, ux, uy, uz, 0.6, c[1], c[2], c[3], 0.9)
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

local function paint_plant(req)
  local w = to_world(req.h)
  local c = req.ready and RING.ok or RING.idle
  local ux, uy, uz = req.ux or 0, req.uy or 1, req.uz or 0
  draw.ring(w.x + ux * 0.1, w.y + uy * 0.1, w.z + uz * 0.1, ux, uy, uz, 0.6, c[1], c[2], c[3], 0.9)
  draw.ring(w.x + ux * 0.1, w.y + uy * 0.1, w.z + uz * 0.1, ux, uy, uz, 0.6 + 0.25 * progress,
    RING.hot[1], RING.hot[2], RING.hot[3], 0.6 * progress)
end

local function paint_beam(req, dt)
  local w = to_world(req.h)
  local mx, my, mz = muzzle()
  if not mx then return end
  local p = req.p or 0.5
  local fl = 0.85 + 0.3 * math.random()
  if req.kind == "grav" or req.kind == "plant" then
    -- The bent beam: out of the barrel along the aim, then curving onto the
    -- grab point. Aim away and the control point swings with the aim before
    -- the object follows, so the beam bows the way you pulled.
    local ax, ay, az = req.aimx or (w.x - mx), req.aimy or (w.y - my), req.aimz or (w.z - mz)
    local al = len(ax, ay, az)
    if al < 1e-6 then return end
    ax, ay, az = ax / al, ay / al, az / al
    local d = len(w.x - mx, w.y - my, w.z - mz)
    local cx, cy, cz = mx + ax * d * 0.55, my + ay * d * 0.55, mz + az * d * 0.55
    local pts = bezier(mx, my, mz, cx, cy, cz, w.x, w.y, w.z, 18)
    local s = math.min(1.0, strain)
    local r, g, b = 0.55 + 0.45 * s, 0.92 - 0.35 * s, 1.0 - 0.75 * s
    if req.kind == "plant" then r, g, b = 0.55, 1.0, 0.6 end
    ribbon(pts, 0.10 + 0.05 * p, BEAM_GLOW, r, g, b, 0.45 * fl)
    ribbon(pts, 0.025 + 0.01 * p, BEAM_CORE, 1.0, 1.0, 1.0, 0.9)
    -- the catch: a small ring at the grab point
    local nx, ny, nz = w.x - cx, w.y - cy, w.z - cz
    draw.ring(w.x, w.y, w.z, nx, ny, nz, 0.14 + 0.04 * math.sin(time * 18), r, g, b, 0.9)
  else
    local pts = { mx, my, mz, w.x, w.y, w.z }
    if req.kind == "fill" then
      ribbon(pts, 0.09 + 0.06 * p, BEAM_GLOW, 0.45, 0.75, 1.0, 0.5 * fl)
      ribbon(pts, 0.02 + 0.015 * p, BEAM_CORE, 0.85, 0.95, 1.0, 0.95)
    else
      local h = heat
      ribbon(pts, 0.08 + 0.08 * p, BEAM_GLOW, 1.0, 0.55 + 0.3 * h, 0.22 + 0.4 * h, 0.55 * fl)
      ribbon(pts, 0.018 + 0.02 * p, BEAM_CORE, 1.0, 0.92, 0.8, 0.95)
    end
    impact(w, p, req.kind)
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
    end
    beam_req, ring_req, plant_req, beacon_req = nil, nil, nil, nil
    return
  end
  stowed = false
  show_models(node, dt, gate == "in hand")
  hold_pose(dt, not first_person())
  if beam_req then
    paint_beam(beam_req, dt)
    if beam_req.kind == "grav" or beam_req.kind == "plant" then impact(nil) end
    -- The particle beam rides the laser in the hand (third person only: in
    -- first person the hand, and everything on it, is not drawn).
    if beam_req.kind == "dig" and not first_person() then beam_particles(to_world(beam_req.h), beam_req.p)
    else beam_particles(nil) end
  elseif beam_req == false then
    impact(nil)
    beam_particles(nil)
  end
  beam_req = nil

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

  paint_beacon(beacon_req)
  beacon_req = nil
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
  recoil = recoil + 0.03
end

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
  for i, s in ipairs(b) do
    if pressed(tostring(i)) then equip(s.id, b) end
  end
  if not slot_of(toolId(), b) then
    local fallback = (b[1] and b[1].id) or "gravgun"
    if equipped ~= fallback then equip(fallback, b) end
  end
  tool = slot_of(toolId(), b) or 1

  local id = toolId()
  local firing = btn(0)
  inUse = firing
  if id ~= "gravgun" and grab then release("tool changed", true) end
  if id ~= "gravgun" then wantsScroll = false end
  if id == "laser" then
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
  elseif id == "gravgun" then
    if not grab then hum_off() end
    fire_grav(node, dt, firing)
  elseif id == "beacon" then
    hum_off()
    show_beam(nil)
    fire_beacon(node, dt, firing)
    aimMat = nil
  end
end

-- ── the hotbar ──────────────────────────────────────────────────────────────

function tool_label(s)
  if s.consumable then return string.format("%s ×%d", s.label, s.n) end
  if s.id == "laser" then return s.label .. (laserMode == "fill" and "  ·  FILL" or "  ·  DIG") end
  return s.label
end

local function hint_line()
  local d = TOOLDEF[toolId()]
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

-- The crosshair: a small ring on the pixel the tool shoots through.
local function draw_reticle()
  if not (draw and draw.circleOutline and camera and camera.screenRect) then return end
  local ax, ay = aim_pixel()
  if not ax then return end
  if cinematicUp() then return end
  local _, _, _, vh = camera.screenRect()
  local k = (vh or 720) / uiDesignH()
  local r, g, b, a = 0.28, 0.86, 0.74, 0.9
  local head = prompt:match("^[^·]*·%s*(.*)$") or prompt
  if head:sub(1, 3) == "no " or head:sub(1, 7) == "nothing" then r, g, b, a = 0.75, 0.80, 0.86, 0.55 end
  if prompt:sub(1, 9) == "PACK FULL" then r, g, b, a = 1.0, 0.72, 0.32, 0.95 end
  if grab and grab.kind ~= "plant" then
    local s = math.min(1, strain)
    r, g, b = 0.55 + 0.45 * s, 0.92 - 0.35 * s, 1.0 - 0.75 * s
    draw.circleOutline(ax, ay, 14 * k, r, g, b, 0.35, 1.2 * k)
  end
  draw.circleOutline(ax, ay, 9 * k, 0.0, 0.0, 0.0, a * 0.45, 3.5 * k)
  draw.circleOutline(ax, ay, 9 * k, r, g, b, a, 1.6 * k)
  draw.circle(ax, ay, 1.6 * k, r, g, b, a)
end

local hud
local function draw_hud(carrying)
  if not hud then hud = find("Tool HUD") end
  if not hud then return end
  local el = hud:getcomponent("UiElement")
  local pm, om = ref("pause_menu"), ref("orbit_map")
  local up = (carrying or gate ~= GATE_ABOARD) and not (pm and pm.open)
    and not (om and om.isOpen and om.isOpen())
  if el then el.visible = up end
  if el then
    local y = (access and access.captions and access.captions()) and -84 or -16
    if el.posY ~= y then el.posY = y end
  end
  if carrying and prompt == "" and gate ~= "in hand" then prompt = gate end
  hudText = carrying and hudLine() or ("tools stowed  ·  " .. gate)
  if up and ui and ui.make then ui.make(hud, hotbar(carrying)) end
  reticle_draw = (up and carrying and gate == "in hand") and draw_reticle or nil
end

function update(node, dt)
  inUse = false
  prompt = ""
  local carrying = on_foot(node)
  tick(node, dt, carrying)
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
