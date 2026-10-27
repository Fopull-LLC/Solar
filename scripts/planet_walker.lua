-- Planet-surface character controller (pairs with planet_camera.lua).
--
-- Movement happens in the tangent plane of the body's LOCAL up (−gravity), with
-- the forward direction taken from the planet camera's published view basis — so
-- W always walks "away from the camera" no matter where on the planet you stand.
-- The body's Rigidbody should have "align to gravity" ON so the capsule (and any
-- children) tilt with the surface.
--
--   W A S D   move (camera-relative)      SPACE  jump (when grounded)
--   SHIFT     hold to sprint

defaults = {
  --@header Movement
  -- Ground speed with no modifier held.
  --@range 0 20 --@units m/s
  walk = 4.5,
  -- Ground speed while SHIFT is held.
  --@range 0 30 --@units m/s
  run = 8.0,
  -- How hard the feet chase the speed you ask for: the share of the gap closed
  -- each second, exponentially. High is snappy, low is icy.
  --@range 1 40 --@units 1/s
  accel = 14.0,
  -- The same, with nothing under you. Low, so a jump commits you to it but
  -- you can still steer a landing.
  --@range 0 20 --@units 1/s
  air_accel = 2.5,
  -- Upward speed SPACE gives you, along the surface's up. 5.2 m/s is a
  -- 1.4 m hop at Earth's 9.8 m/s² (a new save's home, gravity version 2),
  -- 1.9 m at 7 and 3.4 m on a 4 m/s² moon: a jump commits you, it doesn't
  -- float you (playtest 2026-10-23, "gravity is pretty floaty": 10.4 m/s
  -- jumped 7.7 m and hung 3 s in the air at g 7).
  --@range 0 20 --@units m/s
  jump = 5.2,
  -- How far down to look for ground (a capsule's feet plus slack).
  --@range 0.2 5 --@units m
  ground_ray = 1.6,
  -- The most upward speed a CONTACT may give you while your feet are down —
  -- enough to walk up a kerb, not enough to launch. See the up-axis block in
  -- `update`: this number is the whole fix for "constantly flinging up into the
  -- air". Zero pins you to the ground and you will catch on every seam.
  --@range 0 8 --@units m/s
  step_pop = 1.6,
  -- Terminal velocity. A long fall that outruns the collider goes through it.
  --@range 5 200 --@units m/s
  fall_max = 60.0,
  -- Faster than this along the ground and the feet let go: no run or fall
  -- makes it, so the body is riding something or flying ballistic (stepped
  -- out of an orbiting craft, thrown clear of a wreck). Gravity, contacts and
  -- the RCS Pack own it; see `stand_down`.
  --@range 10 60 --@units m/s
  float_fast = 15.0,

  --@header Character model
  -- Facing offset (radians) added to the character's yaw — flip by π if the
  -- model faces backwards.
  --@slider -3.15 3.15 --@step 0.01 --@units rad
  face_offset = 0.0,
  -- How fast the body turns to face where it is going (exponential, 1/s).
  --@range 1 40 --@units 1/s
  turn = 12.0,

  --@header Swimming
  -- Slower than walking (see the water block in update).
  --@range 0 20 --@units m/s
  swim = 3.0,
  --@range 0 20 --@units m/s
  swim_fast = 4.6,
  -- The climb rate SPACE / CTRL give you against the buoyant bob.
  --@range 0 20 --@units m/s
  swim_climb = 3.2,
  -- How hard a swimmer chases the speed asked for (as `accel`, 1/s). Water
  -- is thick: a stroke takes a moment to get you going and you glide to a
  -- stop, which is what lets the strokes read as the thing moving you.
  --@range 1 40 --@units 1/s
  swim_accel = 4.0,
  -- The share of the swim speed you get backing up or swimming sideways
  -- while you face the view (aiming): a back-scull and a side stroke are
  -- slower than a crawl.
  --@range 0 1
  swim_back = 0.5,
  --@range 0 1
  swim_side = 0.7,
  -- How fast a swimmer turns to face where they are going (as `turn`).
  --@range 1 40 --@units 1/s
  swim_turn = 5.0,

  --@header Breath
  -- Seconds of air in the suit with the head under water (a full tank).
  --@range 5 300 --@units s
  o2_secs = 60.0,
  -- Seconds to refill an empty tank in air, or aboard any craft.
  --@range 0.5 60 --@units s
  o2_refill = 5.0,
  -- Seconds between running out of air and waking at the base.
  --@range 0.5 10 --@units s
  o2_blackout = 2.5,
  -- What the rescue costs the company, when it can pay.
  --@range 0 5000
  o2_fee = 250,
}

-- IS THE CREW OUT AND ABOUT? Published, and the answer every interaction gate in
-- the game should be asking for.
--
-- The question they used to ask was `astronaut.visible`, which is a DIFFERENT
-- question wearing the same clothes. planet_camera hides the body whenever the
-- camera ends up within 0.7 m of it — scrolled into first person, yes, but also
-- any time the wall-clip ray finds a wall behind you. Walking INSIDE one of the
-- base buildings does that constantly, and so does standing beside your own
-- rocket. So the facility prompt switched itself off as you stepped through the
-- door, and the mining laser died in any tight space: "sometimes they work other
-- times completely broken."
--
-- This flag means what those gates meant: the crew is out of the pod, the world
-- is running, and they are under their own control.
onFoot = false
-- Feet on something (contact, or the ground probe). Published for the camera,
-- which smooths a step up while you are walking and follows tightly in the air.
grounded = false

local cam
local rig
-- When we last left the ground under our own power. The ground probe reaches
-- 1.6 m down, so for the first fraction of a second of a jump we are still
-- "grounded" by it — and the up-axis rule below would take the jump straight
-- back off us. Held for exactly as long as it takes to clear the probe.
local jump_t = -10.0
local JUMP_LOCKOUT = 0.28
-- The swim float's own radial speed (see the WATER block in update).
local swim_vup = 0
-- The tangent velocity we are steering, eased toward what the keys ask for.
-- Kept here rather than read back off the body: a contact's sideways shove is
-- the solver's business for one frame, not a speed to hold.
local mvx, mvy, mvz = 0.0, 0.0, 0.0
-- The slope's share of last frame's up speed, so this frame can tell the climb
-- we asked for from the push a contact gave us.
local slope_vup = 0.0
local was_contact = false
local air_t = 0.0          -- seconds since the feet were last down
local flying = false       -- a jump or a real fall is under way

-- Animated character (the "AstroModel" child).
local model = nil          -- nil = unresolved, else the node
local model_y = nil        -- its authored height under the capsule
local anim = nil
local face_yaw = 0.0       -- model yaw, in the Astronaut node's frame
local yaw_rate = 0.0
local FOOTSTEPS = "audio/kenney/impact/footstep_concrete_00"

-- Scripted steering, for test rigs and cutscenes: while set, it replaces the
-- keys. `f`/`s` are forward and right (−1..1) in the camera's frame; `jump`
-- jumps once, the next time the feet are down; `climb` is SPACE (+1) or CTRL
-- (−1) in the water.
local steer_f, steer_s, steer_sprint, steer_jump, steer_climb = nil, 0.0, false, false, 0
function steer(f, s, sprint, jump, climb)
  steer_f, steer_s, steer_sprint, steer_jump = f, s or 0.0, sprint == true, jump == true
  steer_climb = climb or 0
end

-- Cross-script singletons, resolved once and kept: `findScript` walks the whole
-- scene (floptle/0063), and asking every frame is what made this project do a
-- hundred scans a frame. A handle stays good until the scene changes, and
-- `.valid` is how you find out that it has.
local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or not r.valid then r = findScript(kind); refs[kind] = r end
  return r
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

-- ── breath ──────────────────────────────────────────────────────────────────
-- The suit carries a tank of air that drains while the HEAD is under water
-- (climate.seaDepth at the helmet, which is the connected-water rule: a dry
-- cave below sea level is air) and fills again in air or aboard any craft —
-- a craft counts as air, so a sealed one is a submarine. Empty, the crew
-- blacks out: control goes, and a moment later they wake at the base (the
-- company's rescue, a fee when the books can stand it). The suit pack's
-- contents are NOT lost: they sink where the crew went down as a salvage
-- crate (scripts/salvage.lua) with a marker over it, and swimming back down
-- and pressing E puts them back in the pack — a death drop, not a deletion. `oxygen` is 0..1, `o2Left` seconds of air left,
-- `headUnder` whether the helmet is under water; status_hud shows a chip
-- while the tank is not full.
oxygen = 1.0
o2Left = 60.0
headUnder = false
downed = false            -- blacked out, waiting for the rescue
downLeft = nil            -- seconds of the blackout's grace left (crew.alerts)
local down_src = nil      -- what ran out: "suit" | "hold"
drowned = 0               -- times the crew has run out of air (probes)
lastDrop = nil            -- the salvage crate id the last blackout left (probes)
local down_t = 0.0

-- Where the crew wakes: the colony, else straight up out of the water.
local function rescue_point(node, ux, uy, uz)
  local name = save.get("base.body")
  local bx, by, bz = save.get("base.x"), save.get("base.y"), save.get("base.z")
  local b = type(name) == "string" and space.body(name)
  if b and bx and by and bz then
    local l = math.sqrt(bx * bx + by * by + bz * bz)
    if l > 1e-3 then
      return b.x + bx + bx / l * 2.5, b.y + by + by / l * 2.5, b.z + bz + bz / l * 2.5
    end
  end
  local cl = ref("climate")
  local d = space.dominant(node.x, node.y, node.z)
  local bb = d and space.body(d)
  local sea = (cl and d and cl.seaRadius and cl.seaRadius(d)) or 0
  if bb and sea > 0 then
    return bb.x + ux * (sea + 1.5), bb.y + uy * (sea + 1.5), bb.z + uz * (sea + 1.5)
  end
  return node.x + ux * 3, node.y + uy * 3, node.z + uz * 3
end

-- The pack's materials go into a salvage crate on the bottom where the crew
-- went down (salvage.drop). Without the salvage library (a harness) they stay
-- in the pack: nothing the crew carried is ever deleted.
local function drop_pack(node, wx, wy, wz)
  local sv = ref("salvage")
  local dom = space.dominant and space.dominant(wx, wy, wz)
  if not (sv and sv.drop and dom) then return nil, 0 end
  local ok, id, kg, e = pcall(sv.drop, dom, wx, wy, wz, node)
  if not ok then log("breath: the salvage drop failed: " .. tostring(id)) return nil, 0 end
  return id, kg or 0, e
end

local function blackout_end(node, ux, uy, uz)
  local wx, wy, wz = node.x, node.y, node.z
  local id, kg, e = drop_pack(node, wx, wy, wz)
  local x, y, z = rescue_point(node, ux, uy, uz)
  node.x, node.y, node.z = x, y, z
  node.vx, node.vy, node.vz = 0, 0, 0
  downed = false
  oxygen, o2Left = 1.0, params.o2_secs
  breath, suitO2 = 1.0, 1.0
  if persistAirNow then persistAirNow() end
  local co = ref("company")
  local fee = math.floor(params.o2_fee or 0)
  local paid = fee > 0 and co and co.afford and co.afford(fee) and co.spend(fee, "crew rescue") or false
  local bc = ref("big_caption")
  if bc and bc.show then
    local why = "Out of air. The company brought the crew back to the base"
    if id and kg > 0.05 then
      local sv = ref("salvage")
      local where = sv and sv.fromBase and e and sv.fromBase(e) or nil
      why = why .. string.format(". The suit pack (%.0f kg) sank where you went down%s — follow the SUIT PACK marker, swim down and press E to take it back",
        kg, where and (", " .. where) or "")
    end
    if paid then why = why .. string.format(". Rescue: $%d", fee) end
    bc.show("CREW LOST", why .. ".", 7.0)
  end
  lastDrop = id
  log(string.format("breath: the crew ran out of air and woke at the base (pack %.1f kg %s, fee %s)",
    kg or 0, id and ("in salvage crate " .. tostring(id)) or "kept", paid and ("$" .. fee) or "none"))
end

-- SUIT AIR (docs/crew-and-items.md §2.3, §5.8; the rule is crew.lua's).
-- With the helmet on wherever the air outside can't be breathed — vacuum,
-- poison, thin air, and under water — the crew breathes the suit's air: the
-- Oxygen Tanks in the pack first (items.drawO2, WS3), then the suit's own
-- built-in supply (`suitO2`, 0..1 of crew.SUIT_AIR_SECS). Bare-headed under
-- water it is held breath, as before (`breath`, o2_secs, × suit.breathMult).
-- Aboard any craft the suit fills again (and boarding fills the tanks).
--
-- Published for the HUD and probes: `oxygen` / `o2Left` are the reserve the
-- crew is breathing from NOW (suit air in all, or held breath), `breath`,
-- `suitO2`, `airLeft` / `airCap` (seconds of suit air, tanks included) and
-- `airSource` ("suit" | "hold" | "ambient").
breath = 1.0
suitO2 = 1.0
airLeft = 1200.0
airCap = 1200.0
airSource = "ambient"
local air = { t = -10.0, breathable = true, save_t = 0.0, saved = 1.0, tanks = nil, cap_t = -10.0 }

local function crew_air_lib()
  local c = ref("crew")
  if c and c.drawAir and c.airSource then return c end
  return nil
end

-- (cached a few times a second: the climate and aero lookups are not free)
local function breathable_now(node, su)
  if time - air.t < 0.5 then return air.breathable end
  air.t = time
  local ok = true
  if su and su.breathableAt then ok = su.breathableAt(node.x, node.y, node.z) == true end
  air.breathable = ok
  return ok
end

local function suit_air_cap(c, pack)
  if time - air.cap_t < 1.0 then return airCap end
  air.cap_t = time
  local n, cap = 0, 0
  local inv, I = ref("inventory"), ref("items")
  if inv and inv.itemCount then
    local ok, k = pcall(inv.itemCount, pack, "o2tank")
    n = ok and (k or 0) or 0
  end
  local d = I and I.def and I.def("o2tank")
  cap = (d and d.fill and d.fill.cap) or 900
  airCap = (c.SUIT_AIR_SECS or 1200) + n * cap
  return airCap
end

-- Keep the record's `o2` current (every 2 s while it changes): the suit's
-- air survives a save and a scene change.
local function persist_air(force)
  if not force and (time - air.save_t < 2.0 or math.abs(suitO2 - air.saved) < 1e-4) then return end
  air.save_t, air.saved = time, suitO2
  local c = ref("crew")
  if c and c.patch and c.activeId then
    local id = c.activeId()
    if id then pcall(c.patch, id, { o2 = suitO2 }) end
  end
end

function persistAirNow() persist_air(true) end

-- (crew slice 2) The avatar became another crew member: their suit's air
-- from their record (crew.lua's switch calls this; the next breath reloads).
function reloadSuit()
  air.loaded = false
  air.tanks, air.tanks_pack = nil, nil
  air.cap_t = -10.0
  downed, downLeft = false, nil
  breath = 1.0
end

-- One frame of breath. `under`: the helmet is in water; `aboard`: in a craft.
-- Returns true while blacked out (the controller hands the body to the water).
local function breathe(node, dt, under, aboard, ux, uy, uz)
  local secs = math.max(1, params.o2_secs)
  if not air.loaded then
    -- the suit's air as the record left it (a save, a scene change)
    local c = ref("crew")
    if c and c.get and c.activeId then
      air.loaded = true
      local r = c.get(c.activeId())
      if r and type(r.o2) == "number" then suitO2, air.saved = r.o2, r.o2 end
    end
  end
  headUnder = under and not aboard
  if downed then
    down_t = down_t + dt
    -- (crew slice 2) With death on, the grace is crew.lua's (15 s on an
    -- empty suit, 10 s under water) and its end is a death, not a rescue:
    -- crew.blackoutEnd handles it. Boarding or surfacing inside the grace
    -- saves them (aboard / head out of the water ends the blackout below).
    local c = ref("crew")
    local death = c and c.deathOn and c.blackoutEnd and c.deathOn()
    local grace = death and c.blackoutGrace and c.blackoutGrace(down_src) or params.o2_blackout
    downLeft = math.max(0, grace - down_t)
    if death and (aboard or (down_src == "hold" and not headUnder)) then
      downed, downLeft = false, nil
      breath = math.max(breath, 0.05)
      log("breath: out of the blackout in time")
      return false
    end
    if down_t >= grace then
      if death and c.blackoutEnd(down_src) then
        downed, downLeft = false, nil
        oxygen, o2Left, breath, suitO2 = 1.0, params.o2_secs, 1.0, 1.0
      else
        blackout_end(node, ux, uy, uz)
      end
    end
    return downed
  end
  local su = ref("suit")
  local c = crew_air_lib()
  local src
  if aboard then
    src = "ambient"
  elseif c and su and su.helmetOn then
    src = c.airSource(su.helmetOn() == true, headUnder, headUnder or breathable_now(node, su))
  else
    -- no suit or crew library (a harness): today's rule, held breath under water
    src = headUnder and "hold" or "ambient"
  end
  airSource = src
  if src == "hold" then
    -- Bare-headed (scripts/suit.lua) the crew is holding their breath, not
    -- breathing from the tank: it goes `breath_hold` times faster.
    local mult = (su and su.breathMult and su.breathMult()) or 1.0
    breath = math.max(0, breath - dt / secs * mult)
  else
    breath = math.min(1, breath + dt / math.max(0.1, params.o2_refill))
  end
  if c then
    local pack = (c.packOf and c.packOf()) or "astro"
    if aboard then
      if suitO2 < 1 then suitO2 = 1.0 end
    elseif src == "suit" then
      if not air.tanks or air.tanks_pack ~= pack then air.tanks, air.tanks_pack = c.tanksOf(pack), pack end
      suitO2, airLeft = c.drawAir(suitO2, dt, air.tanks)
    end
    suit_air_cap(c, pack)
    if src ~= "suit" and time - (air.left_t or -10) > 1.0 then
      air.left_t = time
      local t = air.tanks_pack == pack and air.tanks or c.tanksOf(pack)
      airLeft = suitO2 * (c.SUIT_AIR_SECS or 1200) + t.reserve()
    end
    persist_air(false)
  end
  if src == "suit" then
    oxygen = airCap > 0 and math.max(0, math.min(1, airLeft / airCap)) or 0
    o2Left = airLeft
  else
    oxygen = breath
    o2Left = breath * secs
  end
  local out = (src == "hold" and breath <= 0) or (src == "suit" and airLeft <= 0)
  if out then
    downed, down_t, down_src = true, 0.0, src
    drowned = drowned + 1
    local fx = ref("sfx")
    if fx and fx.caption then fx.caption("out of air") end
    log(src == "suit" and "breath: the suit is out of air — blacking out" or "breath: out of air — blacking out")
    return true
  end
  return false
end

-- Probes and cheats: set the tank (0..1).
function setOxygen(v)
  breath = math.max(0, math.min(1, v or 1)); oxygen = breath; o2Left = breath * params.o2_secs
end
-- ...and the suit's built-in air (0..1).
function setSuitAir(v) suitO2 = math.max(0, math.min(1, v or 1)); persist_air(true) end

-- ── trunks and rocks ────────────────────────────────────────────────────────
-- Scattered trees and rocks have no colliders, so the crew walked through
-- them. flora_field publishes the ones round the crew as `obstacles` (a
-- trunk: ground point, up, radius, height; a rock: centre and radius), and
-- the walker keeps its capsule out of them on the ground plane: the speed
-- into one is taken away (walk into a trunk and you stop; at an angle you
-- slide round it), and a crew already inside is eased out.
local CREW_R = 0.35
bumped = 0          -- obstacles touched this frame (probes)
function bump(node, dt, ux, uy, uz)
  bumped = 0
  local ff = ref("flora_field")
  local list = ff and ff.obstacles
  if not (list and #list > 0 and ff.obstaclesBody) then return end
  local b = space.body(ff.obstaclesBody)
  if not b then return end
  local px, py, pz = node.x - b.x, node.y - b.y, node.z - b.z
  for _, o in ipairs(list) do
    local dx, dy, dz = px - o.x, py - o.y, pz - o.z
    local k = dx * o.ux + dy * o.uy + dz * o.uz
    local reach = (o.h or 0) > 0 and (k > -1.0 and k < o.h + 0.5) or (math.abs(k) < o.r + 1.0)
    if reach then
      -- On the crew's ground plane, from the prop's axis (or centre) out.
      local qx, qy, qz = dx - o.ux * k, dy - o.uy * k, dz - o.uz * k
      local qu = qx * ux + qy * uy + qz * uz
      qx, qy, qz = qx - ux * qu, qy - uy * qu, qz - uz * qu
      local d = math.sqrt(qx * qx + qy * qy + qz * qz)
      local rr = o.r + CREW_R
      if (o.h or 0) <= 0 then
        -- A rock is a ball: narrower above and below its middle.
        rr = math.sqrt(math.max(0, o.r * o.r - k * k)) + CREW_R
      end
      if d < rr and d > 1e-4 then
        bumped = bumped + 1
        local nx, ny, nz = qx / d, qy / d, qz / d
        local vin = mvx * nx + mvy * ny + mvz * nz
        if vin < 0 then mvx, mvy, mvz = mvx - nx * vin, mvy - ny * vin, mvz - nz * vin end
        local push = math.min((rr - d) * 10, 3.0)
        mvx, mvy, mvz = mvx + nx * push, mvy + ny * push, mvz + nz * push
      end
    end
  end
end

local function resolve_model(node)
  -- Keep looking until we actually have a LIVE model child: on frame 1 the
  -- "AstroModel" child may not be spawned yet, and giving up then left the
  -- character in its bind pose forever. The animator binds a frame or two
  -- after that (its clip list is empty until it has), so it is re-asked for
  -- until it answers with clips.
  if not (model and model.valid) then
    model, anim, model_y = nil, nil, nil
    for _, c in ipairs(node:children()) do
      if c.name == "AstroModel" then model = c end
    end
    if model then model_y = model.y or 0.0 end
  end
  if model and not anim then
    local a = model:animator()
    if a and #a:clips() > 0 then anim = a end
  end
end

local function norm(x, y, z)
  local l = math.sqrt(x * x + y * y + z * z)
  if l < 1e-6 then return 0, 0, 0 end
  return x / l, y / l, z / l
end

-- The signed shortest turn from angle a to angle b.
local function wrap(d)
  return (d + math.pi) % (2 * math.pi) - math.pi
end

local function smoothstep(a, b, x)
  local t = math.clamp((x - a) / (b - a), 0.0, 1.0)
  return t * t * (3 - 2 * t)
end

-- ── the animation rig ────────────────────────────────────────────────────────
-- animation_controllers/character.actl.ron (generated by
-- tools/gen_astronaut_anims.py) has a Base layer of ordinary states — idle,
-- jump, fall, land — and above it a Gait layer: ONE blend state mixing walk,
-- run and sprint by the `gait` parameter (0, 1, 2), frozen and scrubbed from
-- here to a phase. Every clip in a blend plays at the same normalised time, so
-- a walk blending into a run keeps both sets of feet in step. The strides are
-- the generator's: the ground one full cycle covers at the speed it was
-- authored for. Playing phase at speed / stride per second is what keeps a foot
-- that is down from sliding.
local STRIDE = { walk = 1.6, run = 3.312, sprint = 5.58 }
local phase = 0.0          -- 0 = left heel strike, 0.5 = right
local gait_amt = 0.0       -- 0 = standing (Base shows), 1 = a gait owns the body
local gait_sent = nil      -- the last `gait` written, so an unchanged one isn't re-sent
local layer_w = {}         -- last weights written, so unchanged ones aren't re-sent
local land_dip = 0.0
-- What `update` measured for `lateUpdate`'s pose this frame (one table, kept;
-- `on` says whether this frame filled it).
local pose_req = { on = false, spd = 0.0, ground = false, stand = 0.0, stride = 0.0 }
-- Swimming (see SWIMMING, below): whether the swim layers own the body, and
-- how far they have faded in. `swimming` is published (the tool belt puts the
-- laser away: both hands are stroking).
swimming = false
local swim_anim = false
local swim_w = 0.0

local function set_weight(layer, w)
  if math.abs((layer_w[layer] or -1) - w) > 0.004 then
    anim:setLayerWeight(layer, w)
    layer_w[layer] = w
  end
end

-- Where a ground speed sits on the Gait blend: 0 walk, 1 run, 2 sprint. The
-- two ramps never overlap, so at most two clips are ever mixed.
local function gait_at(spd)
  return smoothstep(2.4, 4.2, spd) + smoothstep(5.8, 8.2, spd)
end

-- Footstep at each heel strike: the phase crossing 0 (left) or 0.5 (right).
local vfx_ref = nil   -- the effects director: a dust scuff per footfall
local function footstep(node, from, to)
  local crossed = math.floor(to * 2) ~= math.floor(from * 2) or to < from
  if not crossed then return end
  if not (vfx_ref and vfx_ref.valid) then vfx_ref = findScript and findScript("vfx") end
  if vfx_ref then vfx_ref.step(node.x, node.y, node.z) end
  local n = math.floor(time * 137.0) % 5
  audio.play(FOOTSTEPS .. n .. ".ogg", node,
    { track = "SFX", volume = 0.5, mode = "spatial", falloff = "inverse",
      minDistance = 3.0, maxDistance = 60.0 })
end

-- Drive the layers from what the body is actually doing.
local function animate(node, dt, spd, on_ground, jumped, swimming, landed_at)
  if anim then
    -- Base: a jump the moment it's asked for; FALL only after a moment with
    -- nothing underfoot (a kerb or a crest is not a fall); LAND on touchdown.
    local st = anim:state("Base")
    if jumped then
      anim:restart("jump", 0.06, "Base")
    elseif not on_ground and not swimming then
      if st == "jump" then
        local d = anim:duration("jump") or 0.5
        if (anim:time("Base") or 0) > d - 0.12 then anim:crossfade("fall", 0.25, "Base") end
      elseif st ~= "fall" and air_t > 0.15 then
        anim:crossfade("fall", 0.2, "Base")
      end
    elseif landed_at then
      if st == "fall" or st == "jump" then anim:restart("land", 0.05, "Base") end
    elseif st == "fall" or st == "jump" then
      anim:crossfade("idle", 0.2, "Base")
    end
  end

  -- Gaits: in on the ground (or wading) as soon as the body moves, out
  -- quickly when it leaves the ground. Swimming is the swim layers' business:
  -- the gait lets go as they come in and takes back over as you climb out.
  local want_amt = ((on_ground or swimming) and not swim_anim and smoothstep(0.15, 0.6, spd)) or 0.0
  gait_amt = gait_amt + (want_amt - gait_amt) * (1 - math.exp(-(want_amt < gait_amt and 14 or 8) * dt))
  local g = gait_at(spd)
  local stride = g < 1 and STRIDE.walk + (STRIDE.run - STRIDE.walk) * g
    or STRIDE.run + (STRIDE.sprint - STRIDE.run) * (g - 1)
  local before = phase
  if gait_amt > 0.01 then phase = (phase + dt * spd / stride) % 1.0 end
  if on_ground and not swimming and gait_amt > 0.5 then footstep(node, before, phase) end
  if not anim then return end

  set_weight("Gait", math.clamp(gait_amt, 0, 1))
  if gait_amt > 0 then
    if not gait_sent or math.abs(gait_sent - g) > 0.002 then
      anim:setParam("gait", g)
      gait_sent = g
    end
    -- The run clip is the blend's clock; the other two follow it by phase.
    anim:seek(phase * (anim:duration("run") or 1.0), "Gait")
  end
end

function start(node)
  rig = node:getcomponent("RigidBody")
  cam = ref("planet_camera")
  -- SALVAGE (scripts/salvage.lua): the crates a blackout leaves. Its node is
  -- spawned when the scene carries none, as the aero library is.
  if spawn and findScript and not findScript("salvage") then
    pcall(spawn, "SalvageLib", vec3(0, 0, 0))
  end
end

-- The yaw, in the Astronaut node's own frame, that faces a WORLD direction.
-- The node is kept upright by the engine (align to gravity) with a shortest-arc
-- turn, so its heading drifts against the world as you walk round the planet;
-- a yaw worked out from world axes was right only near the spawn and spun the
-- character when the view ran along world ±Y.
local function local_yaw(node, dx, dy, dz)
  local l = node:toLocal(node.pos + vec3(dx, dy, dz))
  local p = node:toLocal(node.pos)
  local lx, lz = l.x - p.x, l.z - p.z
  if lx * lx + lz * lz < 1e-8 then return nil end
  return math.atan2(lx, lz) + params.face_offset
end

-- ── the pose on top of the clips ─────────────────────────────────────────────
-- Leaning, looking and planting the feet are written onto the bones each frame
-- (anim:addBoneRot / reach / lookAt). They last one frame, run after the clips
-- in the order they are called, and hand the bone back the frame we stop.
--
-- WHEN: ALL OF IT IS ISSUED FROM `lateUpdate`. The frame runs update →
-- animation → physics and the rails → lateUpdate → draw, and the engine
-- re-poses a rig AFTER lateUpdate whenever any script queued a pose write
-- there — every write of the frame, `update`'s included, solved against the
-- transforms as they are THEN (floptle-editor anim.rs `apply_late_commands`).
-- The tool belt puts the hands on the tool from lateUpdate on every frame a
-- tool is out, so a foot target worked out in `update` was a point on the
-- world BEFORE the ticks carried the planet (and the crew on it) 1.5–4 m
-- along its orbit: each knee reached for a spot metres behind the body,
-- straightening and swinging with the orbit's direction against the body's
-- heading. That is the "leg IK freaking out, flipping directions and
-- flickering up and down" of the 2026-10-24 playtest (measured: ankles
-- jumping 1.7 m in the model's own frame on the frames a tick ran). Issued
-- here, every world point (a ray hit, a pole, a look target) comes from the
-- same world the re-pose converts it out of, and nothing moves before the
-- frame is drawn. The clips themselves still advance in `update`.
--
-- The rig (models/astronaut/astronaut_male.glb) is Blender's, hung upside
-- down: `MaleArm` is the armature root, and no clip keys it, so it is ours;
-- `Back` is the torso hanging from the chest; `Hip` — with both legs — is a
-- CHILD of Back. Skeleton space faces +Z with +Y up and +X on the left, and
-- MaleArm's own axes are it turned 90° about X, so a bank about the skeleton's
-- forward is a YAW of MaleArm. Back and Hip sit near 180° about X: pitch keeps
-- its sign on them, yaw and roll flip. The numbers are the rest pose's, from
-- tools/gen_astronaut_anims.py.
local MA_UP = 1.61496       -- MaleArm's origin over the soles (skeleton space)
local HIP_Y, HIP_Z = -0.30701, 0.01622   -- the Hip joint from Back's origin
local ANKLE = 0.0722        -- the ankle over the sole, standing flat
local TOE = vec3(0.0, -0.2546, 0.9671)   -- a foot's rest heel-to-toe, skeleton space
local HIP_DROP_MAX = 0.3    -- under a bent leg's reach, or the low foot can't get there
local REACH_UP, REACH_DOWN = 0.5, 0.6    -- how far above / below the soles a foot looks

local bank_s, pitch_s, twist_s = 0.0, 0.0, 0.0
local accel_s, last_spd = 0.0, 0.0
local look_w, look_dir = 0.0, nil
local plant_w, plant_drop = 0.0, 0.0
local ma_dy = 0.0   -- how far this frame's writes have moved MaleArm up so far

-- The model's forward (+Z, the way the rig faces), as a world vector.
local function model_forward(node)
  return node:toWorld(vec3(math.sin(face_yaw), 0, math.cos(face_yaw))) - node:toWorld(vec3(0, 0, 0))
end

-- LOOK. The head follows the view — or, with the trigger held, the spot the
-- tool is working — and the chest takes a share of the turn so one neck bone
-- isn't doing it all. The view's pitch is halved and capped: an orbit camera
-- looks DOWN at the crew, and a head copying it stares at its boots. A view
-- behind the back lets go rather than wringing the neck round.
local function look(node, dt, up)
  local head = anim:boneWorld("Head")
  local want, dir = 0.0, nil
  if head and cam and cam.fwd_x then
    local f = vec3(cam.fwd_x, cam.fwd_y, cam.fwd_z)
    local tb = ref("tool_belt")
    -- (The aim point where it is now: `look` runs in lateUpdate, after the
    -- ticks moved the planet on from where the belt measured it.)
    local ax, ay, az
    if tb and tb.inUse == true and tb.aimX then
      if tb.aimNow then ax, ay, az = tb.aimNow() end
      if not ax then ax, ay, az = tb.aimX, tb.aimY, tb.aimZ end
    end
    if ax then
      dir = (vec3(ax, ay, az) - head):normalized()
    else
      local fu = f:dot(up)
      local flat = (f - up * fu):normalized()
      local pitch = math.clamp(math.asin(math.clamp(fu, -1, 1)) * 0.5, -0.35, 0.45)
      dir = flat * math.cos(pitch) + up * math.sin(pitch)
    end
    local yaw = local_yaw(node, dir.x, dir.y, dir.z)
    local off = yaw and wrap(yaw - face_yaw) or 0.0
    want = 1 - smoothstep(math.rad(95), math.rad(120), math.abs(off))
    twist_s = twist_s + (math.clamp(off * 0.25, -0.35, 0.35) * want - twist_s) * (1 - math.exp(-5 * dt))
  else
    twist_s = twist_s * math.exp(-5 * dt)
  end
  look_w = look_w + (want - look_w) * (1 - math.exp(-5 * dt))
  if dir then
    look_dir = look_dir and (look_dir + (dir - look_dir) * (1 - math.exp(-8 * dt))):normalized() or dir
  end
  return head
end

-- LEAN. A runner banks into a turn as far as the speed and the turn rate
-- would tip them (half of it — a full bank reads as a stunt), leans into a
-- speed-up and sits back out of a stop. The whole body banks about the feet;
-- the chest adds its share of the bank, all of the pitch and the look's twist,
-- turning about the Hip joint with the legs turned back, so the stride under
-- it is the clip's.
local function lean(dt, spd, on_ground)
  local bank, pitch = 0.0, 0.0
  if on_ground then
    local a = (spd - last_spd) / math.max(dt, 1e-4)
    accel_s = accel_s + (math.clamp(a, -30, 30) - accel_s) * (1 - math.exp(-6 * dt))
    bank = -math.atan(spd * yaw_rate / 9.8) * 0.5     -- + yaw is a LEFT turn; + roll tips right
    pitch = math.atan(accel_s / 9.8) * 0.8
  else
    accel_s = 0.0
  end
  last_spd = spd
  local k = 1 - math.exp(-8 * dt)
  bank_s = bank_s + (math.clamp(bank, -0.3, 0.3) - bank_s) * k
  pitch_s = pitch_s + (math.clamp(pitch, -0.2, 0.25) - pitch_s) * k

  local b = bank_s * 0.7
  if math.abs(b) > 1e-4 then
    anim:addBoneRot("MaleArm", b, 0, 0)
    anim:addBonePos("MaleArm", vec3(-MA_UP * math.sin(b), MA_UP * (math.cos(b) - 1), 0))
    ma_dy = ma_dy + MA_UP * (math.cos(b) - 1)
  end
  local r, p, y = bank_s * 0.3, pitch_s, twist_s * (1 - swim_w)
  if math.abs(r) + math.abs(p) + math.abs(y) > 1e-4 then
    anim:addBoneRot("Back", -y, p, -r)
    anim:addBoneRot("Hip", y, -p, r)
    -- Where that swung the Hip joint (skeleton space, small angles), undone by
    -- moving Back the other way — in MaleArm's axes and half-scale.
    local dx = -HIP_Y * math.sin(r) + HIP_Z * math.sin(y)
    local dy = HIP_Y * (math.cos(p) * math.cos(r) - 1) - HIP_Z * math.sin(p)
    local dz = HIP_Y * math.sin(p) + HIP_Z * (math.cos(p) - 1)
    anim:addBonePos("Back", vec3(-dx, -dz, dy) * 2)
  end
end

-- FEET ON UNEVEN GROUND. The capsule rests on its lowest point, so on a slope
-- or a rock one foot hangs in the air and the other is buried. Each foot looks
-- down the body's up for the ground under it; the hips drop to the lower one
-- and both legs reach for their own, knees bending forward, soles turned to
-- the slope. Standing, from a fixed stance; striding, from the clip's own
-- foot lifted onto the ground under it (`plant`, below). Faded, never snapped.
--
-- Where the STANDING feet are is not read off the foot bones: `boneWorld` answers a pose
-- this already bent (see below), and reading it back walks the feet
-- down a slope a little further every frame. The idle stance is fixed in the
-- rig's space (tools/gen_astronaut_anims.py), so the feet are placed from
-- MaleArm, which no clip moves, less what we moved it by last frame; the soles'
-- plane is found the same way. (The constant that guessed it was 8 cm out, and
-- a straight leg can't stretch 8 cm.)
--
-- THE GROUND UNDER A FOOT IS A PLANE, NOT A RAY. Terrain is a surface-nets
-- mesh, and a foot standing on one of its creases had its single ray land on
-- one face one frame and the other face the next — 53° apart on a measured
-- spot — so the sole flipped between them and the ankle hopped 7 cm, every
-- other frame, for as long as you stood there (the "shivering" legs). Each
-- foot now casts three rays (heel, toe, outside edge) and stands on the plane
-- through them, and what it stands on is held in the frame of the world under
-- it and eased, so a sample that does move moves the foot smoothly. Held in
-- the PLANET's frame, not the crew's: the planet carries both, and a foot
-- planted there stays planted whatever the body above it does.

local STANCE = { Left = vec3(0.1389, -1.5428, -0.0858), Right = vec3(-0.1389, -1.5428, -0.0858) }
local SIDES = { "Left", "Right" }          -- a fixed order; pairs() has none
-- Where each foot's three rays land around its centre: metres along the
-- foot's forward and out to its side (heel, toe, outside edge).
local PROBE = { { -0.08, 0.0 }, { 0.13, 0.0 }, { 0.02, 0.07 } }
local FOOT_EASE = 14.0                     -- 1/s: how fast a held foot follows the ground
-- A held foot ignores ground that moved less than this: a surface-nets crease
-- re-sampled a millimetre off, or a normal a degree off, is not a step.
local FOOT_DEAD, NORMAL_DEAD = 0.004, math.rad(2.0)
local LEG = 0.909                          -- thigh 0.412 + shin 0.497: the leg's full reach (rig)
local foot_s = {}                          -- side → { p, n } in the ground's frame
local stride_s = {}                        -- side → { off, n } the ground under a striding foot
local stride_w = 0.0                       -- how much the strides' feet follow the ground
local foot_frame, foot_frame_name = nil, nil
local foot_here = nil                      -- the body, in that frame, last frame
-- Published for probes: the last frame's foot work.
feet = { plant = 0, stride = 0, drop = 0, left = 0, right = 0 }

-- The ground under one foot: the plane through three rays, as a point under
-- the foot's centre and a normal. One ray missing (a ledge) falls back to the
-- centre's own ray and its normal.
local function foot_ground(node, over, up, fwd, out_dir)
  local pts = {}
  for i, o in ipairs(PROBE) do
    local q = over + fwd * o[1] + out_dir * o[2]
    local h = raycast(q + up * REACH_UP, -up, REACH_UP + REACH_DOWN, node)
    if not (h and h.x) then pts = nil break end
    pts[i] = vec3(h.x, h.y, h.z)
  end
  if pts then
    local n = (pts[2] - pts[1]):cross(pts[3] - pts[1])
    if n:dot(up) < 0 then n = -n end
    n = n:normalized()
    local nu = n:dot(up)
    if nu > 0.5 then
      return over + up * (n:dot(pts[1] - over) / nu), n
    end
  end
  local h = raycast(over + up * REACH_UP, -up, REACH_UP + REACH_DOWN, node)
  if not h then return nil end
  local n = vec3(h.nx or 0, h.ny or 0, h.nz or 0)
  if n:dot(up) < 0.5 then n = up end
  return over + up * (REACH_UP - h.distance), n
end

-- The node of the world we stand on (its frame holds the planted feet), or
-- nil for the world frame (a flat level, a test).
local function ground_frame(node)
  local d = space and space.dominant and space.dominant(node.x, node.y, node.z)
  if d ~= foot_frame_name or not (foot_frame and foot_frame.valid) then
    foot_frame_name = d
    foot_frame = d and find and find(d) or nil
    foot_s = {}
  end
  if foot_frame and foot_frame.valid and foot_frame.toLocal then return foot_frame end
  return nil
end

-- The knee's pole. The knee bends toward the BODY's forward, made square to
-- the leg — so the direction never comes from anything that can change sign:
-- not the target's offset, not the view, not last frame's pose. A leg hanging
-- straight down bends its knee forward; one reaching ahead bends it forward
-- and up; one kicked up behind (a sprint's recovery) bends it forward and
-- DOWN, which is where a knee goes. (A pole a fixed step in front of the
-- ankle was nearly ON the line of a leg kicked up behind, and the knee swung
-- out sideways: 0.3 m, measured, on the run.) A touch out over the toes, and
-- half a leg out from the leg's middle, so the solve is never near the flip.
local function knee_pole(hip, ankle, up, fwd, out_dir)
  local d = ankle - hip
  local L = d:length()
  if L < 1e-4 then return ankle + fwd * 0.5 end
  d = d * (1 / L)
  local k = fwd - d * fwd:dot(d)
  if k:length() < 0.25 then
    -- The leg lies along the body's forward (a kick straight out ahead): the
    -- knee goes up.
    k = k + (up - d * up:dot(d)) * 0.5
  end
  k = (k:normalized() + out_dir * 0.12):normalized()
  return (hip + ankle) * 0.5 + k * 0.5
end

-- FEET. Two jobs, faded into each other by how much a stride owns the legs:
--   standing  each foot stands on the plane under its fixed stance spot,
--             held in the planet's frame (see above) and eased, with a dead
--             band, the hips dropped so the LOWER foot reaches;
--   striding  the clip's foot is lifted or lowered by the ground under it,
--             measured from the flat plane of the soles the clip was authored
--             on, and the hips drop for the downhill one — so a walk up, down
--             or across a slope puts each foot on the slope instead of in it
--             or over it, and the stride's own timing (and its no-skate
--             speed match) is untouched.
-- Each foot's IK weight falls away when its target is beyond the leg (a
-- ledge, a hole) rather than straightening toward it, and to nothing in the
-- air or the water (`stand_want` and `stride_want` are 0 there).
local function plant(node, dt, up, stand_want, stride_want)
  local fresh = plant_w < 0.02
  plant_w = plant_w + (stand_want - plant_w) * (1 - math.exp(-(stand_want < plant_w and 12 or 6) * dt))
  stride_w = stride_w + (stride_want - stride_w) * (1 - math.exp(-(stride_want < stride_w and 14 or 6) * dt))
  if plant_w < 0.01 then foot_s = {} end
  if stride_w < 0.01 then stride_s = {} end
  if plant_w < 0.01 and stride_w < 0.01 then
    plant_drop = plant_drop * math.exp(-10 * dt)
    feet.plant, feet.stride, feet.drop = 0, 0, plant_drop
    return
  end
  local fwd = model_forward(node)
  fwd = (fwd - up * fwd:dot(up)):normalized()
  local left = up:cross(fwd)
  -- Where the clips alone put it. `boneWorld` reads the animator's pose plus
  -- the writes this node queued so far this frame, never last frame's
  -- (0.117.0-rc3, card 0413), so only this frame's `ma_dy` comes off.
  local ma = anim:boneWorld("MaleArm")
  if not ma then return end
  ma = ma - up * ma_dy
  local base = node.pos + up * ((ma - node.pos):dot(up) - MA_UP)
  local frame = ground_frame(node)
  local k = 1 - math.exp(-FOOT_EASE * dt)
  -- A body shoved along the ground (a contact pushing it out of a slope) takes
  -- its feet with it at once: easing them after it leaves them in the ground.
  local here = frame and frame:toLocal(node.pos) or node.pos
  if foot_here and (here - foot_here):length() > 0.03 then fresh = true end
  foot_here = here
  local sw = stride_w / math.max(1e-4, stride_w + plant_w)   -- the stride's share of the target
  local hits, low = {}, 0.0
  for _, side in ipairs(SIDES) do
    local out_dir = left * (side == "Left" and 1 or -1)
    local st = STANCE[side]
    local stand_pos, stand_n, clip_ankle, stride_off, stride_n
    if plant_w >= 0.01 then
      local p = ma + left * st.x + fwd * st.z
      local over = base + (p - base) - up * (p - base):dot(up)
      local gp, gn = foot_ground(node, over, up, fwd, out_dir)
      if gp then
        gp = over + up * math.clamp((gp - over):dot(up), -HIP_DROP_MAX, HIP_DROP_MAX)
        -- Held in the ground's frame and eased; a fresh plant (or a foot that
        -- has moved off where it was) takes the new ground as it is, and a
        -- sample within the dead band changes nothing at all.
        local lp, ln = gp, gn
        if frame then
          lp = frame:toLocal(gp)
          ln = frame:toLocal(gp + gn) - lp
        end
        local fs = foot_s[side]
        local dp = fs and (lp - fs.p):length() or 1e9
        if fresh or not fs or dp > 0.25 then
          fs = { p = lp, n = ln }
          foot_s[side] = fs
        else
          if dp > FOOT_DEAD then fs.p = fs.p + (lp - fs.p) * k end
          if fs.n:dot(ln) < math.cos(NORMAL_DEAD) then fs.n = (fs.n + (ln - fs.n) * k):normalized() end
        end
        stand_pos, stand_n = fs.p, fs.n
        if frame then
          stand_pos = frame:toWorld(fs.p)
          stand_n = (frame:toWorld(fs.p + fs.n) - stand_pos):normalized()
        end
        stand_pos = stand_pos + stand_n * ANKLE
        low = math.min(low, (stand_pos - stand_n * ANKLE - over):dot(up) * (1 - sw))
      else
        foot_s[side] = nil
      end
    end
    if stride_w >= 0.01 then
      -- The clip's ankle (with this frame's lean), its height over the flat
      -- soles, and the ground under it measured from that same plane.
      clip_ankle = anim:boneWorld("Foot." .. side)
      if clip_ankle then
        local hc = (clip_ankle - base):dot(up)
        local over = clip_ankle - up * hc
        local h = raycast(over + up * REACH_UP, -up, REACH_UP + REACH_DOWN, node)
        local ss = stride_s[side]
        if not ss then ss = { off = 0.0, n = up }; stride_s[side] = ss end
        if h then
          local off = math.clamp(REACH_UP - h.distance, -HIP_DROP_MAX, HIP_DROP_MAX)
          if math.abs(off - ss.off) > FOOT_DEAD then ss.off = ss.off + (off - ss.off) * (1 - math.exp(-20 * dt)) end
          local n = vec3(h.nx or 0, h.ny or 0, h.nz or 0)
          if n:dot(up) < 0.6 then n = up end
          ss.n = (ss.n + (n - ss.n) * (1 - math.exp(-12 * dt))):normalized()
        else
          ss.off = ss.off * math.exp(-10 * dt)
        end
        stride_off, stride_n = ss.off, ss.n
        -- A foot that is down (near the soles) is the one the hips must
        -- reach for; a foot swinging through the air is lifted with the
        -- ground under it but does not pull the hips down.
        local down = 1 - smoothstep(ANKLE + 0.04, ANKLE + 0.14, hc)
        low = math.min(low, stride_off * down * sw)
      end
    end
    hits[side] = { stand = stand_pos, sn = stand_n, clip = clip_ankle, off = stride_off, on = stride_n }
  end
  plant_drop = plant_drop + (math.min(HIP_DROP_MAX, -low) - plant_drop) * (1 - math.exp(-10 * dt))
  local wsum = math.min(1.0, plant_w + stride_w)
  anim:addBonePos("MaleArm", vec3(0, -plant_drop * wsum, 0))
  ma_dy = ma_dy - plant_drop * wsum
  feet.plant, feet.stride, feet.drop = plant_w, stride_w, plant_drop * wsum
  -- The hip joints, after that drop: what each leg can reach from.
  local hips = ma - up * (plant_drop * wsum) - up * (MA_UP - 0.974)
  for _, side in ipairs(SIDES) do
    local h = hits[side]
    local out_dir = left * (side == "Left" and 1 or -1)
    local target, n, w
    if h.stand and h.clip and h.off then
      local ct = h.clip + up * h.off
      target = h.stand + (ct - h.stand) * sw
      n = (h.sn + (h.on - h.sn) * sw):normalized()
      w = wsum
    elseif h.stand then
      target, n, w = h.stand, h.sn, plant_w
    elseif h.clip and h.off then
      target, n, w = h.clip + up * h.off, h.on, stride_w
    end
    if target then
      -- Beyond the leg (from its hip joint, which stands out to its side):
      -- let the clip have the foot rather than straighten toward a hole.
      local hip = hips + out_dir * 0.1 + fwd * -0.045
      local reach = (target - hip):length()
      -- (Standing straight, the ankle is 0.90 m from the hip: the rest leg is
      -- all but straight, so the fade starts past the leg, with slack for the
      -- hip joint being an estimate.)
      w = w * (1 - smoothstep(LEG * 1.05, LEG * 1.25, reach))
      feet[side == "Left" and "left" or "right"] = w
      if w > 0.005 then
        anim:reach("Foot." .. side, target, { pole = knee_pole(hip, target, up, fwd, out_dir), weight = w })
        -- The sole on the ground: standing, always; striding, while that
        -- foot is down (the clip rolls it heel-to-toe in the air).
        local sole_w = w
        if h.clip and sw > 0.5 then
          local hc = (h.clip - base):dot(up)
          sole_w = w * (1 - smoothstep(ANKLE + 0.02, ANKLE + 0.1, hc)) * 0.8
        end
        if sole_w > 0.01 then
          local along = (fwd - n * fwd:dot(n)):normalized()
          anim:lookAt({ "Foot." .. side }, target + along * TOE.z + n * TOE.y,
            { axis = TOE, limit = 35, weight = sole_w })
        end
      end
    end
  end
end

-- ── SWIMMING ────────────────────────────────────────────────────────────────
-- The swim clips (tools/gen_astronaut_anims.py) are authored UPRIGHT — +Y the
-- way the head points, +Z the way the chest faces — on three layers over the
-- gaits (animation_controllers/character.actl.ron):
--   Swim      along the body, by `swimF`: back-scull −1, tread 0, stroke +1.
--             The stroke is a front crawl at the surface and a breaststroke
--             under it: two states, crossfaded by depth.
--   SwimSide  the side stroke, by `swimS` (−1 to your right, +1 to your left).
--   SwimVert  the vertical strokes, by `swimV` (+1 hauling up, −1 diving).
-- All of it is read off the body's REAL velocity in the model's own frame, so
-- the stroke is the one you are doing: speed blends a tread into a stroke, a
-- sideways or vertical share of the motion fades its layer in, and each
-- layer's playback rate is the speed along its axis over the metres one cycle
-- covers (STROKE, the generator's) — the swimmer's version of the gait's
-- stride, so a pulling hand holds the water instead of slipping through it.
--
-- The ATTITUDE is not in the clips: the whole rig is turned about the body's
-- middle by a bone write on MaleArm, the root no clip keys — level for a
-- crawl, tipped back for a back-scull, head-down for a dive, upright to tread
-- — and banked into a turn. One clip then serves every attitude, two clips
-- blend without limbs swinging through each other, and the capsule, the
-- physics and the camera (which follows the capsule, never a bone) don't
-- feel it.
local SWIM_T = { tread = 2.4, hover = 3.0, crawl = 1.4, breast = 1.8, back = 2.0, side = 1.8, vert = 1.6 }
local STROKE = { crawl = 3.0, breast = 2.6, back = 2.0, side = 2.4, ascend = 2.2, descend = 2.4 }
-- MaleArm's origin over the body's middle — the capsule's centre, 0.94 m over
-- the soles — which is what the body turns about. Skeleton space.
local SWIM_PIVOT = MA_UP - 0.94
local swim_out_t = 0.0
local swim_under = false
local sw_f, sw_s, sw_v = 0.0, 0.0, 0.0          -- the blend parameters, eased
local sw_side, sw_vert = 0.0, 0.0               -- those layers' shares, eased
local sw_vf, sw_vs, sw_vu = 0.0, 0.0, 0.0       -- velocity in the model's frame
local sw_vu_att = 0.0                           -- the vertical part you are swimming
local sw_rate = { Swim = 1.0, SwimSide = 1.0, SwimVert = 1.0 }
local sw_sent = {}
local sw_pitch, sw_bank, sw_lift = 0.0, 0.0, 0.0
local depth_s = 0.0
-- What the swim is doing, for probes and tests (updated in place).
swimState = { w = 0, f = 0, s = 0, v = 0, side = 0, vert = 0, pitch = 0, bank = 0, lift = 0,
              under = false, rate = 1, vf = 0, vs = 0, vu = 0 }

local function ease(cur, want, rate, dt)
  return cur + (want - cur) * (1 - math.exp(-rate * dt))
end

local function send(kind, key, v, eps)
  if not sw_sent[key] or math.abs(sw_sent[key] - v) > eps then
    if kind == "param" then anim:setParam(key, v) else anim:setSpeed(v, key) end
    sw_sent[key] = v
  end
end

-- In or out of the water, and the layers. Called every frame from `update`.
local function swim_drive(node, dt, up, in_water, depth, feet_down, climb)
  -- Feet on the bottom is wading — the gait's. Off it, in water deep enough
  -- to float, is swimming. A beat of grace on the way out, so a trough or a
  -- toe brushing a rock doesn't flick the body upright and back.
  local want = in_water and not feet_down
  swim_out_t = want and 0.0 or swim_out_t + dt
  if want then swim_anim = true elseif swim_out_t > 0.3 then swim_anim = false end
  swimming = swim_anim
  swim_w = ease(swim_w, swim_anim and 1 or 0, swim_anim and 3.0 or 5.0, dt)
  if depth then depth_s = ease(depth_s, depth, 4.0, dt) end

  if not (in_water or swim_anim or swim_w > 0.002) then
    sw_vf, sw_vs, sw_vu, sw_vu_att = 0.0, 0.0, 0.0, 0.0
    sw_f, sw_side, sw_vert = 0.0, 0.0, 0.0
    local ss = swimState
    ss.w, ss.f, ss.side, ss.vert, ss.vf, ss.vs, ss.vu = 0, 0, 0, 0, 0, 0, 0
    if anim then set_weight("Swim", 0.0); set_weight("SwimSide", 0.0); set_weight("SwimVert", 0.0) end
    return
  end
  local v = vec3(node.vx or 0, node.vy or 0, node.vz or 0)
  local fwd = model_forward(node)
  fwd = (fwd - up * fwd:dot(up)):normalized()
  local left = up:cross(fwd)
  sw_vf, sw_vs, sw_vu = v:dot(fwd), v:dot(left), v:dot(up)
  -- Only a stroke you are making turns you over. Sinking after a jump in is
  -- feet-first and the buoyant float back up is a tread: vertical motion you
  -- are not swimming (SPACE / CTRL) counts for a third in the strokes and not
  -- at all in the attitude.
  if (climb > 0 and sw_vu > 0) or (climb < 0 and sw_vu < 0) then
    sw_vu_att = sw_vu
  else
    sw_vu, sw_vu_att = sw_vu * 0.3, 0.0
  end
  local mag = math.abs(sw_vf) + math.abs(sw_vs) + math.abs(sw_vu) + 0.05
  sw_f = ease(sw_f, math.clamp(sw_vf / 1.4, -1, 1), 5.0, dt)
  if math.abs(sw_vs) > 0.05 then sw_s = ease(sw_s, sw_vs > 0 and 1 or -1, 6.0, dt) end
  if math.abs(sw_vu) > 0.05 then sw_v = ease(sw_v, sw_vu > 0 and 1 or -1, 6.0, dt) end
  sw_side = ease(sw_side, smoothstep(0.25, 0.9, math.abs(sw_vs)) * smoothstep(0.3, 0.7, math.abs(sw_vs) / mag), 4.0, dt)
  sw_vert = ease(sw_vert, smoothstep(0.5, 1.4, math.abs(sw_vu)) * smoothstep(0.35, 0.75, math.abs(sw_vu) / mag), 4.0, dt)
  -- A crawl needs air. With some slack, so the chop doesn't flick it.
  if depth then
    if swim_under and depth < 1.4 then swim_under = false
    elseif not swim_under and depth > 1.9 then swim_under = true end
  end

  -- Cycles a second: the speed along each axis over a cycle's metres, never
  -- quite stalling; a tread at its own easy pace. Each layer's clock is its
  -- state's own clip (crawl / breaststroke / side / ascend), hence the × T.
  local t_move = swim_under and SWIM_T.breast or SWIM_T.crawl
  local idle = 1 / (swim_under and SWIM_T.hover or SWIM_T.tread)
  local move
  if sw_vf >= 0 then
    move = math.max(sw_vf / (swim_under and STROKE.breast or STROKE.crawl), 0.55 / t_move)
  else
    move = math.max(-sw_vf / STROKE.back, 0.55 / SWIM_T.back)
  end
  local hz = idle + (move - idle) * math.abs(sw_f)
  sw_rate.Swim = ease(sw_rate.Swim, hz * t_move, 4.0, dt)
  hz = math.max(math.abs(sw_vs) / STROKE.side, 0.5 / SWIM_T.side)
  sw_rate.SwimSide = ease(sw_rate.SwimSide, hz * SWIM_T.side, 4.0, dt)
  hz = math.max(math.abs(sw_vu) / (sw_vu > 0 and STROKE.ascend or STROKE.descend), 0.5 / SWIM_T.vert)
  sw_rate.SwimVert = ease(sw_rate.SwimVert, hz * SWIM_T.vert, 4.0, dt)

  local ss = swimState
  ss.w, ss.f, ss.s, ss.v, ss.side, ss.vert = swim_w, sw_f, sw_s, sw_v, sw_side, sw_vert
  ss.under, ss.rate, ss.vf, ss.vs, ss.vu = swim_under, sw_rate.Swim, sw_vf, sw_vs, sw_vu
  if not anim then return end
  set_weight("Swim", swim_w)
  set_weight("SwimSide", swim_w * sw_side)
  set_weight("SwimVert", swim_w * sw_vert)
  if swim_w < 0.002 then return end
  local st = swim_under and "swim_under" or "swim_surface"
  if anim:state("Swim") ~= st then anim:crossfade(st, 0.6, "Swim") end
  send("param", "swimF", sw_f, 0.002)
  send("param", "swimS", sw_s, 0.002)
  send("param", "swimV", sw_v, 0.002)
  for l, r in pairs(sw_rate) do send("speed", l, r, 0.01) end
end

-- The swimmer's attitude, as a bone write (see above). Level at speed, upright
-- to tread, the body's long axis along the way it moves through the water —
-- up a climb, head-down into a dive — tipped back to back-scull; banked into
-- a turn; and near the surface lifted so a treader's chin and a crawler's back
-- are at the waterline (the capsule floats with its middle 0.7 m down).
local function swim_pose(dt)
  local tp, tb, tl = 0.0, 0.0, 0.0
  if swim_anim then
    local fwd = math.max(sw_vf, 0.0)
    local vu = sw_vu_att
    local sag = math.sqrt(fwd * fwd + vu * vu)
    local travel = math.pi / 2 - math.atan2(vu, fwd)      -- 0 straight up, π/2 level, π straight down
    if not swim_under then travel = travel - 0.1 end      -- a crawl rides a touch head-up
    local m = smoothstep(0.35, 1.6, sag)
    local rest = swim_under and 0.26 or 0.14
    tp = rest + (travel - rest) * m - 0.38 * smoothstep(0.3, 1.2, -sw_vf) * (1 - m)
    tp = math.clamp(tp, -0.6, 2.8)
    -- Water is softer than gravity: a swimmer rolls into a turn more than a
    -- runner leans, and leans a touch into a sideways swim.
    local h = math.sqrt(sw_vf * sw_vf + sw_vs * sw_vs)
    tb = math.clamp(-math.atan(h * yaw_rate / 4.0) * 0.8 - 0.06 * sw_vs, -0.6, 0.6)
    -- (Not while diving: a duck-dive passes through level on its way down.)
    local level = smoothstep(0.6, 1.4, sw_pitch) * (1 - smoothstep(2.0, 2.6, sw_pitch))
      * (1 - smoothstep(0.3, 1.0, -vu))
    local surf = 1 - smoothstep(1.0, 1.8, depth_s)
    tl = surf * math.max(0.0, depth_s - (0.55 + (0.12 - 0.55) * level))
  end
  -- Slow to turn over, quicker to stand back up on climbing out.
  sw_pitch = ease(sw_pitch, tp, swim_anim and 2.5 or 5.0, dt)
  sw_bank = ease(sw_bank, tb, 3.0, dt)
  sw_lift = ease(sw_lift, tl, 3.0, dt)
  swimState.pitch, swimState.bank, swimState.lift = sw_pitch, sw_bank, sw_lift
  if math.abs(sw_pitch) + math.abs(sw_bank) + math.abs(sw_lift) < 1e-4 then return end
  -- MaleArm's axes are the skeleton's turned 90° about X, so a pitch about the
  -- skeleton's left is MaleArm's pitch and a bank about its forward is
  -- MaleArm's yaw: one write is a bank of the pitched body. Then MaleArm is
  -- moved so the turn is about the body's middle rather than its own origin.
  local p, b, L = sw_pitch, sw_bank, SWIM_PIVOT
  anim:addBoneRot("MaleArm", b, p, 0)
  local dy = L * math.cos(p) * math.cos(b) - L + sw_lift
  anim:addBonePos("MaleArm", vec3(-L * math.cos(p) * math.sin(b), dy, L * math.sin(p)))
  ma_dy = ma_dy + dy
end

-- The whole pose, in the order the engine applies it: bone writes (the lean,
-- the hips' drop), then the legs' reach, then the head's look.
local function pose(node, dt, up, spd, on_ground, standing, striding)
  ma_dy = 0.0
  local head = look(node, dt, up)
  lean(dt, spd, on_ground)
  swim_pose(dt)
  plant(node, dt, up, standing, striding)
  -- Swimming, the head keeps its stroke (a crawl's breath, a dive's tuck) and
  -- only leans a little toward where you look.
  if head and look_dir and look_w > 0.01 then
    anim:lookAt({ "Head" }, head + look_dir * 10,
      { limit = 75 - 40 * swim_w, weight = 0.9 * look_w * (1 - 0.7 * swim_w) })
  end
end

-- LOCAL UP: straight out from the centre of the world under us — worked out
-- from where that world IS, every frame, not read off the body.
--
-- `node.up` is the body's −gravity, and on 0.117.0-rc3 it is wrong for one
-- tick every few seconds: the floating origin recentres after the rails have
-- rebuilt gravity, and `World::rebase` shifts the old point sources but not the
-- planets' µ/r² centres, so that tick pulls toward a spot ~4 km away (measured
-- 12–76° off the vertical, once every 4–17 s while standing on a moving world).
-- Read as "up", that tilted the walk, swung the feet's rays sideways and rolled
-- the camera for a split second. The geometry has no such tick. (No world
-- under us at all — a flat level, a test — and the body's up is all there is.)
function local_up(node)
  local d = space and space.dominant and space.dominant(node.x, node.y, node.z)
  local b = d and space.body(d)
  if b then
    local x, y, z = norm(node.x - b.x, node.y - b.y, node.z - b.z)
    if x ~= 0 or y ~= 0 or z ~= 0 then return x, y, z end
  end
  local ux, uy, uz = node.up_x, node.up_y, node.up_z
  if not ux or (ux == 0 and uy == 0 and uz == 0) then
    ux, uy, uz = norm(node.x, node.y, node.z)
    if ux == 0 and uy == 0 and uz == 0 then ux, uy, uz = 0, 1, 0 end
  end
  return ux, uy, uz
end

-- STANDING UP STRAIGHT. The engine keeps the astronaut node upright by turning
-- it a third of the way toward the body's up at each writeback — so on that
-- bad tick (see `local_up`) the whole crew leaned up to 20° for a few frames
-- and stood back up: a shiver of the entire body. After the writeback, before
-- the frame is drawn, the node is stood along the true vertical; on every
-- other frame that is the turn the engine made anyway. Rotation only — the
-- capsule's collision shape follows the body's up, not the node's.
--
-- Then the pose (see WHEN, above): the lean, the look and the feet, against
-- the body and the ground where they are now — after the ticks, in the same
-- frame the engine re-poses the rig and draws it.
function lateUpdate(node, dt)
  local req = pose_req.on and pose_req or nil
  pose_req.on = false
  if not onFoot then return end
  local ux, uy, uz = local_up(node)
  local u = vec3(ux, uy, uz)
  -- (not while the body's turn is someone else's: crew_task turns off its
  -- alignUp to square the crew on a job in space, with the work under them
  -- as often as beside them, and standing them back up along the planet's
  -- vertical here every frame undid that — evaprobe `facing`, 110° off with
  -- the station's hull below the crew)
  local getc = node.getComponent or node.getcomponent
  local rb = getc and getc(node, "RigidBody")
  local own = not (rb and (rb.alignUp == false or rb.alignUp == 0))
  if own and node.worldUp and node.setUp then
    local cur = node:worldUp()
    if cur and cur:dot(u) < 0.999999 then node:setUp(u) end
  end
  if req and anim and model and model.valid then
    pose(node, dt, u, req.spd, req.ground, req.stand, req.stride)
  end
end

-- HELD AT A JOB, OR FLOATING (docs/crew-and-items.md §5.7, §6.3). Two cases
-- where the feet's velocity chase must not run:
--   * held: crew_task places the body every tick in the part's frame (it is
--     kinematic); movement keys do nothing, and the crew faces the work;
--   * free fall in space (nothing under them for 50 m) or with the RCS Pack's
--     thrust live: there is no ground to chase, and a velocity written here
--     would be an absolute one — orbital, km/s, frame-dependent. Gravity and
--     the pack (eva_pack, which only ever ADDS Δv) own the body; the crew
--     faces the view.
-- The tangent velocity the walker steers is re-read off the body, so landing
-- or a release hands back to walking without a jolt. → true when handled.
holding = false     -- published: held at a job this frame
floating = false    -- published: free fall / pack flight this frame
function holdStart() holding = true end
function holdEnd() holding = false end
local space_t, space_on = -10.0, false
-- Above the air (no atmosphere, or past its top: climate's world record),
-- with nothing under the crew for 50 m. A fall through air stays the
-- walker's (terminal velocity, air control); a world the climate library
-- doesn't know is never space. Cached 0.2 s; asked afresh on the first frame
-- on foot after a while (the frame they step out of a hatch).
local function above_air(node)
  local cl = ref("climate")
  local d = space and space.dominant and space.dominant(node.x, node.y, node.z)
  local w = d and cl and cl.worldOf and cl.worldOf(d)
  local b = d and space.body(d)
  if not (w and b) then return false end
  if (w.atmo or 0) <= 0.005 then return true end
  local R = w.radius or b.radius or 800
  local H = (w.atmoHeight or 0) > 0 and w.atmoHeight or 0.35 * R
  local alt = math.sqrt((node.x - b.x) ^ 2 + (node.y - b.y) ^ 2 + (node.z - b.z) ^ 2) - R
  return alt >= H
end
-- Is node `n` part of a craft in flight (not landed, not clamped)? Under the
-- crew in space that is no ground: an orbiting station below them is falling
-- with them.
local function craft_in_flight(n)
  for _ = 1, 6 do
    if not (n and n.valid ~= false) then return false end
    local v = n.getScript and n:getScript("vessel_controller")
    if v then
      local i = assembly and assembly.info and assembly.info(n)
      return i ~= nil and not i.grounded and not i.anchored
    end
    n = n.parent
  end
  return false
end
local function in_space(node, ux, uy, uz)
  if time - space_t < 0.2 then return space_on end
  space_t = time
  space_on = false
  if not above_air(node) then return false end
  -- nothing under them for 50 m but craft that are themselves in flight
  local x, y, z, left = node.x, node.y, node.z, 50.0
  for _ = 1, 4 do
    local h = raycast(x, y, z, -ux, -uy, -uz, left, node)
    if h == nil then space_on = true return true end
    if not craft_in_flight(h.node) then return false end
    local d = (h.distance or left) + 0.05
    left = left - d
    if left <= 0 then space_on = true return true end
    x, y, z = x - ux * d, y - uy * d, z - uz * d
  end
  return false
end
local last_foot_t = -10.0
local function stand_down(node, dt, ux, uy, uz, fx, fy, fz, on_ground, swimming)
  if time - last_foot_t > 0.5 then space_t = -10.0 end
  last_foot_t = time
  local cl = ref("crew")
  local is_held = cl ~= nil and cl.held ~= nil and cl.held() == true
  local ep = ref("eva_pack")
  -- Faster along the ground than feet go (params.float_fast): stepped out of
  -- a craft in orbit, its 68 m/s is the crew's too, and the chase below
  -- writes an ABSOLUTE walking velocity. It did whenever the 50 m ray found
  -- the hull under the hatch: the first frame on foot wrote |v| = 0, 68 m/s
  -- relative to the station, and the crew went into the planet (evaprobe
  -- 2026-10-27, 1 run in 4). Asked every frame, contact or not: a hull
  -- touched in orbit is no ground to walk on either.
  local vu0 = node.vx * ux + node.vy * uy + node.vz * uz
  local fast = node.vx * node.vx + node.vy * node.vy + node.vz * node.vz - vu0 * vu0 > params.float_fast * params.float_fast
  local float = not is_held and not swimming
    and (fast or (not on_ground and ((ep ~= nil and ep.live == true) or in_space(node, ux, uy, uz))))
  holding, floating = is_held, float
  if not (is_held or float) then return false end
  local vu = node.vx * ux + node.vy * uy + node.vz * uz
  mvx, mvy, mvz = node.vx - ux * vu, node.vy - uy * vu, node.vz - uz * vu
  if rig then rig.friction = 0 end
  if model then
    local want
    local ct = is_held and ref("crew_task")
    if ct and ct.aimNow and cl.activeId then
      local ax, ay, az = ct.aimNow(cl.activeId())
      if ax then want = local_yaw(node, ax - node.x, ay - node.y, az - node.z) end
    else
      want = local_yaw(node, fx, fy, fz)
    end
    if want then face_yaw = face_yaw + wrap(want - face_yaw) * (1 - math.exp(-params.turn * dt)) end
    model.yaw = face_yaw
  end
  animate(node, dt, 0.0, is_held, false, false, false)
  return true
end

-- ── THE GROUND NET ──────────────────────────────────────────────────────────
-- Terrain collision is the engine's meshed surface triangles, and a triangle
-- only pushes a body that is still on its outer side: once the capsule's
-- centre is past the floor (a fast fall onto ground not meshed yet, a frame of
-- several catch-up ticks, a grade or an edit that raised the rock round the
-- feet) nothing pushes it back and it drops on through the planet — "inside
-- the planet, cave walls seen from the inside, STRANDED". So, every NET_EVERY
-- seconds, one terrain.query at the capsule's centre: standing (or swimming)
-- clear of the rock, that spot is remembered in the PLANET's frame (the planet
-- moves metres a tick); NET_DEEP metres inside the rock on two checks in a row,
-- the crew is put back on the last safe spot — lifted until it is clear of
-- rock, never into it — and the rescue is logged. One query a tenth of a
-- second: nothing next to the frame.
local NET_EVERY = 0.1
local NET_DEEP = 1.0      -- rock over the capsule's centre that means "through"
local NET_SAFE = 0.4      -- clearance a remembered spot must have
local NET_UNMADE = 8.0    -- metres under the safe spot, in ground not made yet
local net_t = -10.0
local net_bad = 0
local net_safe = nil      -- { name, x, y, z, rot } on the planet; rot: a node frame
-- For probes and tests: checks run, rescues made, the last query and rescue.
groundNet = { checks = 0, rescues = 0, q = nil, last = nil }
-- Whether the walker is holding the crew up on the ground's field this frame
-- because the collision probe found no ground there (see THE FIELD FLOOR).
fieldFloor = false
-- A probe that wants to watch a fall through the floor switches it off.
groundNetOn = true

local function net_to_local(name, x, y, z)
  local f = find and find(name)
  if f and f.valid and f.toLocal then
    local l = f:toLocal(vec3(x, y, z))
    return l.x, l.y, l.z, true
  end
  local b = space.body and space.body(name)
  if b then return x - b.x, y - b.y, z - b.z, false end
  return nil
end
local function net_to_world(s)
  if s.rot then
    local f = find and find(s.name)
    if not (f and f.valid and f.toWorld) then return nil end
    local w = f:toWorld(vec3(s.x, s.y, s.z))
    return w.x, w.y, w.z
  end
  local b = space.body and space.body(s.name)
  if b then return b.x + s.x, b.y + s.y, b.z + s.z end
  return nil
end

-- Returns true when it moved the crew this frame.
local function ground_net(node, ux, uy, uz, on_ground, swimming)
  if not groundNetOn or not (terrain and terrain.query and space and space.dominant) then return false end
  if time - net_t < NET_EVERY then return false end
  net_t = time
  local x, y, z = node.x, node.y, node.z
  local q = terrain.query(x, y, z)
  if q == nil then net_bad = 0 return false end
  local name = space.dominant(x, y, z)
  if not name then return false end
  local b = space.body and space.body(name)
  local r = b and math.sqrt((x - b.x) ^ 2 + (y - b.y) ^ 2 + (z - b.z) ^ 2) or 0
  groundNet.checks = groundNet.checks + 1
  groundNet.q = q
  if terrain.ready and not terrain.ready(x, y, z) then
    -- Ground not made yet (deep rock is generated when something comes near):
    -- the query reads it as open air, and so does the collider. Fallen well
    -- below the last spot stood on, through that, is a fall through too.
    if not (net_safe and net_safe.name == name and net_safe.r - r > NET_UNMADE) then net_bad = 0 return false end
  elseif q > -NET_DEEP then
    net_bad = 0
    if (on_ground or swimming) and q >= NET_SAFE then
      local lx, ly, lz, rot = net_to_local(name, x, y, z)
      if lx then net_safe = { name = name, x = lx, y = ly, z = lz, rot = rot, r = r } end
    end
    return false
  end
  net_bad = net_bad + 1
  if net_bad < 2 then return false end
  net_bad = 0
  -- Where to: the last safe spot on this planet, else straight up from here.
  local tx, ty, tz
  if net_safe and net_safe.name == name then tx, ty, tz = net_to_world(net_safe) end
  if not tx then tx, ty, tz = x, y, z end
  -- Up from there in quarter metres until the capsule's centre is clear of
  -- the rock (a cave's roof is never climbed into: the spot itself is tried
  -- first, and it was clear when it was remembered).
  local lift = 0.0
  local placed = false
  for _ = 1, 32 do
    local px, py, pz = tx + ux * lift, ty + uy * lift, tz + uz * lift
    local pq = terrain.query(px, py, pz)
    if pq and pq >= NET_SAFE + 0.2 then tx, ty, tz, placed = px, py, pz, true break end
    lift = lift + 0.25
  end
  if not placed then
    tx, ty, tz = rescue_point(node, ux, uy, uz)
  end
  local unmade = terrain.ready and not terrain.ready(x, y, z)
  print(string.format("WALKER NET rescue: %s at (%.1f, %.1f, %.1f) v %.1f m/s on %s -> %s lift %.1f m",
    unmade and string.format("%.1f m under the last safe spot, in ground not made yet", net_safe.r - r)
      or string.format("%.2f m inside the rock", -q), x, y, z, math.sqrt(node.vx ^ 2 + node.vy ^ 2 + node.vz ^ 2), tostring(name),
    placed and (net_safe and "the last safe spot" or "straight up") or "the rescue point", lift))
  node.x, node.y, node.z = tx, ty, tz
  node.vx, node.vy, node.vz = 0, 0, 0
  mvx, mvy, mvz = 0.0, 0.0, 0.0
  swim_vup, slope_vup = 0.0, 0.0
  -- a rescue is a teleport, not a fall: the crew's impact check waits
  local cl = ref("crew")
  if cl and cl.quietMonitors then pcall(cl.quietMonitors, 1.0) end
  groundNet.rescues = groundNet.rescues + 1
  groundNet.last = { t = time, depth = -q, x = tx, y = ty, z = tz, placed = placed }
  return true
end

function update(node, dt)
  if not cam then cam = ref("planet_camera") end
  -- The character model rides as a child; keep its visibility mirrored to us so
  -- boarding/EVA (which toggle node.visible) hide/show the whole astronaut even
  -- though a child's visibility isn't auto-inherited.
  resolve_model(node)
  if model then model.visible = node.visible end
  -- Hands off while a craft is flying us: it parks and carries this body
  -- itself. Fetched fresh with EVERY instance scanned, because several craft
  -- can be alive and only one of them has a pilot in it.
  -- (Aboard a craft is air: the tank refills there.)
  for _, vessel in ipairs(findScripts("vessel_controller")) do
    if vessel.piloting then onFoot = false; breathe(node, dt, false, true) return end
  end
  if (save.get("shipyard.pilot") or 0) == 1 then onFoot = false; breathe(node, dt, false, true) return end
  -- Nor while the world is still streaming in: the crew is parked in the sky
  -- over the spawn planet then, not standing anywhere they could interact with.
  local gm = ref("game_manager")
  -- Nor while building in the VAB: build_host parks the crew at the console.
  if gm and gm.inputOwner == "builder" then onFoot = false; breathe(node, dt, false, true) return end
  if gm and gm.loading then onFoot = false return end
  -- Nothing is piloting us anywhere: we must be walkable, and visible unless
  -- the CAMERA is deliberately hiding us.
  --
  -- The self-heal (a destroyed vessel can't un-hide the astronaut it seated) was
  -- unconditional, and it ran against planet_camera every single frame: the
  -- camera turned the astronaut node off for first person, and this turned the
  -- AstroModel child — the part you actually see, which does not inherit its
  -- parent's visibility — straight back on. First person put you inside your own
  -- head. The camera owns the decision now; this only asks, and only heals the
  -- case the camera isn't responsible for.
  onFoot = true
  local cam_hides = cam ~= nil and cam.hidesBody == true
  if not node.visible and not cam_hides then node.visible = true end
  if model then model.visible = node.visible end

  local ux, uy, uz = local_up(node)

  -- Forward = the camera's view, flattened against THIS BODY's up. The camera
  -- publishes a flat view too, but against its own slewed up, which trails the
  -- body's on a fast walk round a small world — and a forward that isn't in our
  -- tangent plane walks us into the ground or off it.
  local fx, fy, fz
  if cam and cam.fwd_x then
    fx, fy, fz = cam.fwd_x, cam.fwd_y, cam.fwd_z
  else
    local yaw = input.aimYaw() or 0.0
    fx, fy, fz = -math.sin(yaw), 0.0, -math.cos(yaw)
  end
  local fd = fx * ux + fy * uy + fz * uz
  fx, fy, fz = norm(fx - ux * fd, fy - uy * fd, fz - uz * fd)
  if fx == 0 and fy == 0 and fz == 0 and cam and cam.flat_x then
    -- Looking straight down: the published flat view already chose a heading.
    fx, fy, fz = cam.flat_x, cam.flat_y, cam.flat_z
    fd = fx * ux + fy * uy + fz * uz
    fx, fy, fz = norm(fx - ux * fd, fy - uy * fd, fz - uz * fd)
  end
  if fx == 0 and fy == 0 and fz == 0 then return end
  -- right = forward × up (tangent, ⊥ forward).
  local rx = fy * uz - fz * uy
  local ry = fz * ux - fx * uz
  local rz = fx * uy - fy * ux

  local f, s, sprint = 0, 0, false
  if steer_f then
    f, s, sprint = steer_f, steer_s, steer_sprint
  else
    if input.key("w") then f = f + 1 end
    if input.key("s") then f = f - 1 end
    if input.key("d") then s = s + 1 end
    if input.key("a") then s = s - 1 end
    sprint = input.key("shift")
  end
  local il = math.sqrt(f * f + s * s)
  if il > 1 then f, s = f / il, s / il end
  local speed = sprint and params.run or params.walk

  -- Grounding with forgiveness: contact flag OR a short probe along −up.
  local contact = node.grounded == true
  local ground_hit = nil
  if not contact and params.ground_ray > 0 then
    ground_hit = raycast(node.x, node.y, node.z, -ux, -uy, -uz, params.ground_ray, node)
  end
  -- THE FIELD FLOOR. On engine 0.117 rc25+ a body resting on ground it
  -- reached can lose that ground's collision triangles a few frames later
  -- (seen in caves: the collision ray misses the floor terrain.raycast still
  -- finds 1 m below), and the crew then sinks through the floor and falls into
  -- the planet. The ground's own field is the truth, so where the collision
  -- probe finds nothing it asks the field (terrain.raycast reads the field,
  -- not the collision meshes): ground there is ground under the feet, and a
  -- body sunk into it is held up (`field_sunk`, below). Where the collider is
  -- right, the two agree and this never runs.
  local field_sunk = nil
  if not contact and not ground_hit and params.ground_ray > 0 and terrain and terrain.raycast then
    local th = terrain.raycast(vec3(node.x, node.y, node.z), vec3(-ux, -uy, -uz), params.ground_ray)
    if th and th.distance then
      ground_hit = { distance = th.distance, field = true }
      local half = (node.height or 2.0) * 0.5
      if th.distance < half - 0.02 then field_sunk = half - th.distance end
    end
  end
  fieldFloor = field_sunk ~= nil
  local on_ground = contact or ground_hit ~= nil
  grounded = on_ground

  -- WATER. A world's sea is a sphere at a fixed radius (climate owns the rule),
  -- and inside it you swim: slower, no jump, and buoyant — you rise to the
  -- surface on your own and bob there. SPACE climbs, CTRL dives. The water has
  -- no collider (it's drawn, not simulated — floptle/0038), so this controller
  -- IS the swimming physics, which is why the drag and the bob live here.
  local cl = ref("climate")
  local depth = cl and cl.seaDepth(node.x, node.y, node.z) or nil
  local swimming = depth ~= nil and depth > 0.7
  if swimming then
    speed = sprint and params.swim_fast or params.swim
  end

  -- BREATH: the helmet sits ~0.75 m above the capsule's centre. Out of air,
  -- the keys go dead and the body drifts until the rescue.
  -- (Depth is radial, so the helmet's is the body's less that height.)
  local head_r = (node.height or 2.0) * 0.5 - 0.25
  local hd = depth and (depth - head_r) or nil
  if breathe(node, dt, hd ~= nil and hd > 0.05, false, ux, uy, uz) then
    f, s, sprint = 0, 0, false
    speed = 0
  end
  if not downed and not holding and ground_net(node, ux, uy, uz, on_ground, swimming) then return end
  if stand_down(node, dt, ux, uy, uz, fx, fy, fz, on_ground, swimming) then return end

  -- ── the tangent velocity ────────────────────────────────────────────────────
  -- Eased toward what the keys ask for rather than set to it, so a start has a
  -- step or two of pick-up and a stop a step of run-out — and in the air far
  -- more gently, so a jump is committed but a landing can still be steered.
  -- Re-flattened every frame: the tangent plane turns under you as you walk.
  local tx, ty, tz = (fx * f + rx * s) * speed, (fy * f + ry * s) * speed, (fz * f + rz * s) * speed
  if swimming and model then
    -- A swimmer is fastest the way they face: backing up is a scull and
    -- sideways a side stroke. (Not aiming, the body turns to face the way you
    -- swim, so this is only the moment of turning round.)
    local mf = model_forward(node)
    local mfx, mfy, mfz = norm(mf.x, mf.y, mf.z)
    local along = tx * mfx + ty * mfy + tz * mfz
    local k_along = along < 0 and params.swim_back or 1.0
    local lx, ly, lz = tx - mfx * along, ty - mfy * along, tz - mfz * along
    tx = mfx * along * k_along + lx * params.swim_side
    ty = mfy * along * k_along + ly * params.swim_side
    tz = mfz * along * k_along + lz * params.swim_side
  end
  local md = mvx * ux + mvy * uy + mvz * uz
  mvx, mvy, mvz = mvx - ux * md, mvy - uy * md, mvz - uz * md
  local rate = swimming and params.swim_accel or (on_ground and params.accel or params.air_accel)
  local k = 1 - math.exp(-rate * dt)
  mvx, mvy, mvz = mvx + (tx - mvx) * k, mvy + (ty - mvy) * k, mvz + (tz - mvz) * k

  -- ── the up axis ─────────────────────────────────────────────────────────────
  -- WHATEVER THE SOLVER DID TO US THIS FRAME arrives here as `vup`, and this
  -- used to write it straight back out. So the controller did not merely
  -- tolerate an ejection impulse — it MAINTAINED one. Terrain is a surface-nets
  -- mesh whose faces meet at angles; being pushed out of a seam, off a crest or
  -- out of the wall of a tunnel you just bored hands you a few metres per second
  -- along the local up, and the next frame took that as the velocity to hold.
  -- Cross a ridge at a run and the capsule left the planet. That is "constantly
  -- flinging up into the air", and it is also how you end up in the void.
  --
  -- So while the feet are down the up axis is OURS. It is a jump, or the climb
  -- the slope asks for plus at most a kerb's worth of pop — enough to walk up a
  -- step, not enough to launch. Only in the air does physics get the axis back,
  -- and even there a contact cannot hand out more climb than a jump would.
  local vup = node.vx * ux + node.vy * uy + node.vz * uz
  local impact = -vup
  local airborne = (not on_ground) or (time - jump_t) < JUMP_LOCKOUT
  local jumped = false
  if swimming then
    -- Buoyancy pulls you toward the surface, hard when you're deep and gently
    -- as you reach it, so floating is the resting state rather than a fight.
    local want = math.min(2.2, math.max(0.0, depth - 0.7) * 1.1)
    if not downed and (input.key("space") or (steer_f and steer_climb > 0)) then want = params.swim_climb end
    if not downed and (input.key("ctrl") or (steer_f and steer_climb < 0)) then want = -params.swim_climb end
    -- Eased from THIS controller's own last value, not from the body's: the
    -- sea is an engine Water Volume now, and its Archimedes push lands on the
    -- capsule between frames. Easing from the body's velocity folded that push
    -- in every frame on top of the swim float, and a swimmer let go three
    -- metres down came out of the water four metres into the air.
    swim_vup = swim_vup + (want - swim_vup) * math.min(1.0, dt * 4.0)
    vup = swim_vup
    slope_vup = 0.0
  elseif not airborne then
    -- SLOPES: the move is along the ground, not the tangent plane, so a hill
    -- is climbed at the speed you asked for instead of being shoved up it by
    -- the solver one contact at a time — and walking down it keeps the feet on
    -- it instead of skipping off in little ballistic hops.
    local slope = 0.0
    local n = node.groundNormal
    if n then
      local nu = n.x * ux + n.y * uy + n.z * uz
      if nu > 0.35 then slope = -(mvx * n.x + mvy * n.y + mvz * n.z) / nu end
    end
    -- SNAP DOWN. Walking off a crest or down a step, the contact goes a frame
    -- before the probe does; the body would sail on at its old height and come
    -- down a moment later. Pulled back onto the ground the probe still sees.
    if not contact and was_contact and ground_hit then
      local gap = ground_hit.distance - (node.height or 2.0) * 0.5
      if gap > 0.02 then slope = math.min(slope, -math.min(8.0, gap / math.max(dt, 1e-3))) end
    end
    swim_vup = vup
    if not downed and (input.pressed("space") or (steer_f and steer_jump)) then
      steer_jump = false
      vup = params.jump
      jump_t = time
      jumped = true
      slope = 0.0
      local fx = ref("sfx"); if fx and fx.playAt then fx.playAt("jump", node) end
    else
      vup = slope + math.min(vup - slope_vup, params.step_pop)
    end
    slope_vup = slope
  else
    vup = math.max(-params.fall_max, math.min(vup, params.jump))
    swim_vup = vup
    slope_vup = 0.0
  end
  was_contact = contact
  -- Held up on the field floor: no sinking, and back up out of it gently.
  if field_sunk and not jumped then
    vup = math.max(vup, math.min(3.0, field_sunk / math.max(dt, 1e-3) * 0.5))
  end
  bump(node, dt, ux, uy, uz)
  node.vx = mvx + ux * vup
  node.vy = mvy + uy * vup
  node.vz = mvz + uz * vup

  -- Standing still on a slope: max friction so you don't slide downhill.
  if rig then
    if f == 0 and s == 0 and on_ground then
      rig.friction = 1
    else
      rig.friction = 0
    end
  end

  -- ── the character: facing, then the animation layers ──────────────────────
  -- What the body is ACTUALLY doing, not what the keys say: run into a wall
  -- and you stand; get shoved and your legs catch up.
  local bvx, bvy, bvz = node.vx, node.vy, node.vz
  local bu = bvx * ux + bvy * uy + bvz * uz
  bvx, bvy, bvz = bvx - ux * bu, bvy - uy * bu, bvz - uz * bu
  local spd = math.sqrt(bvx * bvx + bvy * bvy + bvz * bvz)

  -- Face the way you are going; while AIMING — behind the eyes, shift-locked,
  -- or the tool in your hand is running — face the view instead, so the body
  -- is behind the tool and a strafe is a strafe. (No model, nothing to turn.)
  if model then
    local tb = ref("tool_belt")
    local aiming = cam ~= nil and (cam.firstPerson == true or cam.shiftlock == true)
      or (tb ~= nil and tb.inUse == true)
    local want
    if aiming and tb ~= nil and tb.inUse == true and tb.aimX then
      -- The tool aims through the cursor, which need not be the middle of the
      -- view: face the point it is working.
      want = local_yaw(node, tb.aimX - node.x, tb.aimY - node.y, tb.aimZ - node.z)
    elseif aiming then
      want = local_yaw(node, fx, fy, fz)
    elseif spd > 0.3 then
      want = local_yaw(node, bvx, bvy, bvz)
    end
    local before = face_yaw
    if want then
      local turn = swim_anim and params.swim_turn or params.turn
      face_yaw = face_yaw + wrap(want - face_yaw) * (1 - math.exp(-turn * dt))
    end
    yaw_rate = yaw_rate + (wrap(face_yaw - before) / math.max(dt, 1e-4) - yaw_rate) * math.min(1, dt * 10)
  end

  if airborne then air_t = air_t + dt else air_t = 0.0 end
  -- In the air for real: a jump, or long enough off the ground that it wasn't
  -- a kerb. Coming down from that is a landing.
  if jumped or (airborne and not swimming and air_t > 0.15) then flying = true end
  local landed = flying and not airborne
  if landed or swimming then flying = false end
  if landed then
    -- The knees take the landing: a dip of the whole model, deeper for a
    -- harder landing, springing back. The land clip does the same while you
    -- stand; this is what shows it while a gait owns the legs.
    land_dip = math.min(0.12, math.max(0.0, impact) * 0.012 + 0.03)
    -- (Not on the jump's own frame, which also reads as `landed` here.)
    local fx = not jumped and ref("sfx")
    if fx and fx.playAt then fx.playAt("land", node, math.min(1.0, 0.3 + math.max(0.0, impact) * 0.07)) end
  end
  land_dip = land_dip * math.exp(-9 * dt)
  local feet_down = contact or (ground_hit ~= nil and ground_hit.distance < 1.15)
  local climb = 0
  if input.key("space") or (steer_f and steer_climb > 0) then climb = 1 end
  if input.key("ctrl") or (steer_f and steer_climb < 0) then climb = -1 end
  swim_drive(node, dt, vec3(ux, uy, uz), swimming, depth, feet_down, climb)
  animate(node, dt, spd, not airborne, jumped, swimming, landed)
  -- The pose itself is lateUpdate's (see WHEN, above): what it needs from
  -- this frame's movement is kept for it.
  if anim then
    local down = not (airborne or jumped or swimming or flying)
    local r = pose_req
    r.on, r.spd, r.ground = true, spd, not airborne and not swimming
    r.stand, r.stride = down and (1 - gait_amt) or 0.0, down and gait_amt or 0.0
  end

  if model then
    model.yaw = face_yaw
    if model_y then model.y = model_y - land_dip * gait_amt end
  end
end
