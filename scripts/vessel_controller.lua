-- VESSEL CONTROLLER — flies a BUILT ship (the compound assembly rebuilt from
-- your blueprint) with the same cockpit feel as the scout ship: rate-commanded
-- attitude, SAS hold modes, the navball + tapes, a live HUD, real pooled fuel.
-- Thrust is honest: applied AT each engine's blueprint offset through the
-- compound physics — an off-CoM engine torques the stack, exactly as built.
--
--   F        board / exit the pod (walk to the hatch ring to re-board)
--   SPACE    clamped → release the launch clamps; flying → next stage
--   SHIFT / CTRL   throttle up / down    X  cut    Z  full
--   W/S      pitch (S pulls the nose UP)   A/D  yaw   Q/E  roll
--   T        SAS on/off    1-7  hold: 1 stability · 2 prograde · 3 retrograde
--            · 4 normal · 5 anti-nml · 6 radial-in · 7 radial-out
--   . / ,    time-warp up / down (KSP rules: coasting or parked only; any
--            stick input drops to 1×; the vessel rides exact Kepler rails)
--   M        map (focus + trajectories follow THIS craft while piloted)
--
-- Launching from the builder seats you in the pod from the first frame, with
-- the vessel CLAMPED (anchored) to the launchpad until you release. Fuel pools
-- across every tank on board; staging away tanks takes their share with them.


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

-- Cinematic mode (planet_camera, F4 / F5): the boarding ring and the docking
-- guides are interface, and hide with it. Global, so no function here gains an
-- upvalue (lateUpdate and fixedUpdate sit at LuaJIT's ceiling).
local cine_pc, cine_miss = nil, -10.0
function cinematicUp()
  if not (cine_pc and cine_pc.valid) then
    if (time or 0) - cine_miss < 2.0 then return false end
    cine_pc = findScript("planet_camera")
    if not cine_pc then cine_miss = time or 0 return false end
  end
  return cine_pc.cinematic == true
end

defaults = {
  torque = 60.0,        -- attitude authority per axis (vs the compound inertia)
  max_rate = 1.0,       -- commanded turn rate cap, rad/s
  rate_accel = 2.5,     -- pointing-mode braking law, rad/s²
  board_range = 3.4,    -- how close the astronaut must be to the pod to board
  throttle_rate = 0.5,  -- full throttle in 2 s of held SHIFT
  refuel_rate = 15.0,   -- units/s while clamped on the pad
}

-- Published (walker/camera defer & follow; SAS buttons read/drive these).
-- `piloting` = this is the craft you are controlling; `crewAboard` = the crew
-- is riding in it. They differ for a PROBE: you fly it from the ground (the
-- crew stays where they are), and for a crewed craft you've switched away
-- from (the crew stays in their seat while you fly something else).
piloting = false
crewAboard = false
-- When the crew last stepped out of this craft (standDown), published so the
-- craft next to it doesn't seat them again on the same F press (crewOnFoot).
leftAt = -100.0
throttle = 0.0
fuel = 0.0
-- True while we've asked the engine to keep this vessel out of distant-craft
-- LOD (assembly.keepLive) — set while flying from the map, whose camera pulls
-- far back and would otherwise freeze us on rails (dead throttle/steering).
local kept_live = false
-- Where the camera should orbit: the capsule. podL* is the pod's LOCAL
-- offset — planet_camera composes it with the node's RENDERED pose in its
-- own pass, so the orbit center sits on the ship the frame actually draws
-- (a fixedUpdate world position lags the rails carry: offset + jitter).
-- focusX/focusHeight stay published for other readers.
podLX, podLY, podLZ = 0, 1.2, 0
focusX, focusY, focusZ = nil, nil, nil
focusHeight = 1.2
sas_mode = "stability"
-- Everything the flight HUD draws that isn't already one of these globals,
-- measured at 10 Hz by fixedUpdate (see its telemetry block) and rendered by
-- scripts/flight_hud.lua. nil until the first measurement.
tele = nil
-- Has this craft left the ground since the clamps let go? A craft that arrived
-- any other way (a parked ship you walked up to) got where it is by flying.
hasFlown = true
flown = { air = 0.0, alt0 = nil }  -- the latch's own state (see fixedUpdate)
-- Has this craft LEFT ITS LAUNCH SPOT: clamps released, or moved more than a
-- few metres from where it rolled out? Not the same as `hasFlown`. A rover never
-- leaves the ground, so it never "flies", but one driven off the pad is a craft
-- somewhere in the world, and flight_ops' fleet record must keep it (a rover
-- parked 100 m out used to be gone after a reload). A craft that arrived any
-- other way (restored, undocked) has left it by definition.
leftPad = true
-- WHERE THE CREW SITS, apart from what COMMANDS the craft. `pod_uid` (below) is
-- the command part: the keep-side of every staging cut, the part whose loss
-- loses the craft, the rover's front. The crew can sit in any crewed part
-- aboard (a pod, or an open Command Seat), whichever they climbed into: F
-- boards the one nearest them. `crewSeats` lists every crewed part
-- { uid, x, y, z, seat }; `stationUid` is the one they are in, or would be put
-- in (the command pod by default). `pod`, `podSeat` and podLX/Y/Z describe that
-- station, so the seat pose, the camera and the hatch ring follow it.
crewSeats = {}
stationUid = nil
-- Peripheral state (published: damage tolerance + HUD read it).
gear_deployed = true
-- Current reentry-heating rate (dmg/s at the nose; published for the HUD).
heating = 0.0
local heat_fx_t = -10.0
-- Parachutes: armed in staging, deployed on their stage; while open + in
-- atmosphere they drag hard against velocity (a soft descent). Ripped off if
-- opened too fast/high (they only bite in thick air).
chutes = {}                -- { {x,y,z, h, uid, canopy} } from the blueprint
chutes_deployed = false    -- published for the HUD
local chute_anim = 0.0     -- the canopies' inflated area, 0 packed … 1 full (drag ∝ it)
-- The deploy sequence's state (update_chutes), published for the canopies
-- scripts/parachute.lua draws: lines paying out (stretch 0 → 1), then the
-- inflated area through a reefed stage to full. A global, so fixedUpdate
-- spends no upvalue on it.
chute_fill = { t = 0.0, stretch = 0.0, area = 0.0, dens = 0.0, spd = 0.0 }
local sas_last = "stability"

-- ── ship peripherals ────────────────────────────────────────────────────────
-- Landing-gear fold angles (roll radians about Z). The leg's two joints swing
-- from a STOWED pose (thigh folded up, shin jack-knifed back) to a DEPLOYED one
-- (thigh out+down, knee unfolded so the foot reaches out and down). Tuned in
-- crates/floptle-assets/examples/leg_probe.rs against the recentered meshes.
-- NOTE: if a leg folds the WRONG way, flip the STOW value (past the DEP value).
local GEAR_DEP_U, GEAR_STOW_U = 0.5, 3.0   -- upper strut (hip)
local GEAR_DEP_K, GEAR_STOW_K = 0.4, -2.4  -- lower strut (knee)
local function gear_lerp(a, b, f) return a + (b - a) * f end

-- PART ANIMATIONS, by the `anim` a part's deploy module names
-- (scripts/electronics.lua). Every folding part now moves ON ITS OWN — its own
-- state in `rec.st.deployed`, its own fold in `panim[uid]` — so one panel can be
-- out while another is stowed, and an action group can move any set of them.
-- f: 0 stowed … 1 deployed. `pose` is the child's authored pose, cached once.
local ANIMS = {
  -- MULTI-JOINTED fold: each leg part is a hierarchy (PartLegs.prefab.ron) —
  -- LegUpperPivot rolls at the hip, LegKneePivot (its child) rolls at the knee.
  -- We drive BOTH so the leg folds up + jack-knifes (retracted) and swings
  -- out + down with the knee unfolding (deployed).
  legs = function(child, pose, f)
    local j = pose.joints
    if not j then
      j = {}
      for _, c in ipairs(child:children()) do
        if c.name == "LegUpperPivot" then
          j.upper = c
          for _, gc in ipairs(c:children()) do
            if gc.name == "LegKneePivot" then j.knee = gc end
          end
        end
      end
      pose.joints = j
    end
    if j.upper then j.upper.roll = gear_lerp(GEAR_STOW_U, GEAR_DEP_U, f) end
    if j.knee then j.knee.roll = gear_lerp(GEAR_STOW_K, GEAR_DEP_K, f) end
    -- A LANDING GEAR (PartGearS/M) folds its leg aft (toward −Y, about Z)
    -- into the hull, the tyre swinging with it.
    if j.gear == nil then
      j.gear = false
      for _, c in ipairs(child:children()) do
        if c.name == "GearPivot" then j.gear = c end
        if c.name == "Tyre" then j.tyre, j.t0 = c, { c.x, c.y } end
      end
    end
    if j.gear then
      local a = -(1 - f) * math.pi / 2
      j.gear.roll = a
      if j.tyre and j.t0 then
        local px, py = j.gear.x, j.gear.y
        local ddx, ddy = j.t0[1] - px, j.t0[2] - py
        local c, s = math.cos(a), math.sin(a)
        j.tyre.x, j.tyre.y, j.tyre.roll = px + ddx * c - ddy * s, py + ddx * s + ddy * c, a
      end
    end
  end,
  -- A DISH folds flat for launch and, deployed, swings its boresight onto
  -- whoever it is talking to (`pose.aim`, set by the comms pass): the authored
  -- frame turned toward the target by up to 80°, eased in with the fold.
  dish = function(child, pose, f)
    local a = pose.aim
    if a and f > 0 then
      local yaw, pitch, roll = aim_euler(pose, a, f)
      child.yaw, child.pitch, child.roll = yaw, pitch, roll
    else
      child.yaw, child.pitch, child.roll = pose.yaw or 0, (pose.pitch or 0) - (1 - f) * 1.4, pose.roll or 0
    end
    child.scale_y = pose.sy * (0.5 + 0.5 * f)
  end,
  -- SOLAR PANELS: the wing folds about its hinge (PartSolar's SolarWingPivot)
  -- — flat along the hull, cells out, for launch — and swings open on Deploy.
  -- (It used to squash the whole part along X about its centre, which drew a
  -- thin strip floating off the hull: "the solar panels are squished".)
  solar = function(child, pose, f)
    if pose.wing == nil then
      pose.wing = false
      for _, c in ipairs(child:children()) do
        if c.name == "SolarWingPivot" then pose.wing = c end
      end
    end
    if pose.wing and pose.wing.valid ~= false then
      pose.wing.yaw = (1 - f) * (math.pi / 2)
      return
    end
    child.scale_x = (pose.sx or 1.0) * (0.18 + 0.82 * f)  -- an old panel with no hinge
    child.pitch = (pose.pitch or 0) - (1 - f) * 0.5
  end,
  -- The WHIP telescopes: a third of its height stowed, its foot kept on the
  -- mount (the mesh is centred, so the centre drops as it shortens).
  whip = function(child, pose, f)
    local k = 0.3 + 0.7 * f
    child.scale_y = pose.sy * k
    child.y = pose.y - (1 - k) * (pose.h or 0.9) * 0.5
  end,
}

-- The device KINDS the peripherals console and the old per-kind calls see:
-- each is a SET of parts (by module), switched together by `setPeripheral` and
-- shown as one row. The keys are the standard action groups' (G, U, Y, R) and
-- are fired through the groups now (`groupKeysTick`), not read here.
local DEVICES = {
  gear = {
    key = "g", label = "GEAR", order = 1, state = "deployed",
    detect = function(d, E) local m = E and E.modOf(d, "deploy") return (m and m.anim == "legs") or (not E and (d.legs or 0) == 1) end,
    parts = {}, on = true, anim = 1.0, speed = 2.0, pose = {}, nodes = {},
  },
  comms = {
    key = "u", label = "ANTENNAS", order = 2, state = "deployed",
    detect = function(d, E) local m = E and E.modOf(d, "deploy") return (m and (m.anim == "dish" or m.anim == "whip")) or (not E and (d.comms or 0) == 1) end,
    parts = {}, on = false, anim = 0.0, speed = 1.2, pose = {}, nodes = {},
  },
  solar = {
    key = "u", label = "SOLAR PANELS", order = 3, state = "deployed",
    detect = function(d, E) local m = E and E.modOf(d, "deploy") return (m and m.anim == "solar") or (not E and (d.solar or 0) == 1) end,
    parts = {}, on = false, anim = 0.0, speed = 0.8, pose = {}, nodes = {},
  },
  lights = {
    key = "y", label = "LIGHTS", order = 4, state = "lit", verb_on = "ON", verb_off = "OFF",
    detect = function(d, E) return E and E.modOf(d, "light") ~= nil end,
    parts = {}, on = false, anim = 0.0, speed = 8.0, pose = {}, nodes = {},
  },
  -- RCS: the "state" is the thruster bus MASTER (R, like SAS's T); each block
  -- also has its own on/off (`rec.st.rcs`) for the groups. `launch = false`
  -- because thrusters idle on the pad.
  rcs = {
    key = "r", label = "RCS", order = 0, launch = false,
    verb_on = "ON", verb_off = "OFF",
    detect = function(d) return (d.rcs or 0) == 1 end,
    parts = {}, on = false, anim = 0.0, speed = 8.0, pose = {}, nodes = {},
  },
}

-- Per-part fold (uid → 0..1) and the per-part pose cache / child handles.
local panim, ppose, pnode = {}, {}, {}

-- The fold of one part, for the stress model and the comms pass.
function partAnim(uid) return panim[uid] or 0 end

-- Translation state, published for the HUD and the peripherals console.
rcs = { thrust = 0.0, firing = false, cmd = 0.0 }

local bp = nil
local launch_mode = false -- arrived via the builder's LAUNCH (clamp lifecycle)
local released = false    -- the pilot has released the clamps at least once
local info_seen = false   -- first sighting of the live compound (diagnostics)
local no_info_t = 0.0     -- how long we've piloted WITHOUT a compound
local engines = {}     -- { {x,y,z, dx,dy,dz, thrust, burn, branch} } vessel-local, live only
local tanks = {}       -- { {y, fuel, branch} } vessel-local, live only
-- SEPARATION EVENTS in firing order (the builder's STAGING panel decides):
-- {kind="axial", uid, y} splits everything below the cut; {kind="ring",
-- branches={...}} kicks a whole booster ring away laterally. SPACE fires
-- events[1]; an axial cut prunes events that depart with the lower stack.
local events = {}
local pod = { x = 0, y = 0.5, z = 0 }
-- Damage model (assembly.impacts → per-part strength): see the block after
-- the staging helpers.
local bp_by_uid = {}   -- uid → blueprint part record
local bp_in_branch = {} -- uid → radial-branch root uid (nil = on the spine)
local bp_kids = {}     -- uid → { child uids } (the attachment tree; built in load_bp)
local pod_uid = nil    -- the crewed part's uid = the tree's keep-side anchor
local axial_set_cache = {} -- dec uid → set of uids that DEPART when it fires (memoized)
local eid_uid = {}     -- part entity id → blueprint uid (resolved once, then stable)
local part_hp = {}     -- uid → 1.0 pristine … 0.0 destroyed
local destroyed = false -- the POD is gone: the vessel is lost
-- PHYSICS INTEGRITY state (the seat, the clamps, joint stress, breakup and the
-- safety net — see the section of that name above `fixedUpdate`). One table, so
-- the whole subsystem costs the file one local and `fixedUpdate` no upvalue.
local integ = {
  gone = {},        -- uid → true once that part has left this craft (staged, shed, broken off)
  gen = 0,          -- bumped whenever the craft's part set changes (invalidates the caches)
  seated = false,   -- THIS controller made the crew kinematic (and must hand them back)
  seat_t = -10.0,   -- last time the seat's kinematic flag was re-asserted
  box = {},         -- uid → { cx,cy,cz, ex,ey,ez, m } collider box in the vessel frame
  strain = {},      -- uid → accumulated overload·seconds at that part's joint
  prev = nil,       -- last tick's state for the safety net { vx,vy,vz, rx,ry,rz, dom }
  af = nil,         -- smoothed proper acceleration (world, m/s²) for the stress model
  wprev = nil, alpha = nil,
  release_t = nil,  -- when the launch clamps let go
  fired = {},       -- safety-net kind → count (published via `integrity()`)
  note_t = {},      -- safety-net kind → last log time (rate-limits the log)
}
-- Published: steps whenever the craft's part set changes (the camera re-reads
-- its hull the moment it does, instead of polling every part every frame).
function partsGen() return integ.gen end
-- Separation and seating knobs, published so a probe can A/B them on a live
-- craft (`vc.physTune.clear = false`). The defaults are what the game ships:
--   clear   move a departing piece out of any collider OVERLAP with the hull
--           before it is released (a split piece starts where it was, and an
--           overlap is resolved by the engine as a shove on both halves)
--   ignore  seconds a departing piece and the hull pass through each other
--           (`physics.ignorePair`, engine 0.112), so pieces that merely TOUCH
--           at the seam can't knock each other as they part; 0 = off
--   seatKinematic  the seated crew rides as a kinematic passenger
--   loads   the stress model fails joints on the load through them (off: only
--           the dynamic-pressure and canopy limits; for a harness that pins a
--           craft's velocity against a force, which no real craft can do)
-- (A craft left parked needs nothing from here: since floptle/0385 the engine
-- puts a resting assembly to sleep and wakes it on any push.)
physTune = { clear = true, ignore = 0.5, seatKinematic = true, loads = true }
local smoke_t = 0.0
local scrape_t = 0.0    -- rate-limits topple/belly-slide grinding damage
local part_total = 0
local fuel_cap = 0.0
-- ── electrical (EC) — batteries store it, solar panels make it, comms spend it ─
-- All one table so fixedUpdate spends a SINGLE upvalue on the electrical state
-- (that function is close to Lua's 60-upvalue ceiling).
local elec = {
  charge = 0.0,     -- current electric charge
  cap = 0.0,        -- total battery capacity (Σ part ec)
  gen = 0.0,        -- generation at full sun (Σ deployed-panel gen)
  comms = false,    -- carries at least one comms dish
  link = false,     -- dish deployed AND powered = telemetry live (tracker)
  ptime = 0.0,      -- rate-limits the tracker heartbeat
  sun = nil, sun_t = -10.0,
}
local boarding = false
local astronaut, hud, hud_prompt
local hud_panel  -- the backing frame the map's text block sits inside
local hud_t = -10.0
local navball, tape_spd, tape_alt, txt_spd, txt_alt, txt_hdg
-- KSP-style warp ladder.
local WARP_STEPS = { 1, 5, 10, 50, 100, 1000, 10000 }


-- The orbit map, resolved ONCE. `findScript` walks every node in the scene
-- comparing script names (floptle/0063), and this is asked for on every tick
-- of every vessel — so it is cached, and only re-resolved if the handle dies
-- (a scene change). The same shape is used for every cross-script singleton in
-- this project.
local map_ref
local function map()
  if not map_ref or not map_ref.valid then map_ref = findScript("orbit_map") end
  return map_ref
end

-- ── math helpers (same conventions as the scout ship) ───────────────────────
local function norm(x, y, z)
  local l = math.sqrt(x * x + y * y + z * z)
  if l < 1e-6 then return 0, 0, 0 end
  return x / l, y / l, z / l
end

local function cross(ax, ay, az, bx, by, bz)
  return ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
end

-- Vessel-frame basis from the node's YXZ euler (matches the engine writeback).
-- The NOSE is the stack axis (+Y — the pod points up), fwd completes the frame.
local function basis(node)
  local cy, sy = math.cos(node.yaw), math.sin(node.yaw)
  local cx, sx = math.cos(node.pitch), math.sin(node.pitch)
  local cz, sz = math.cos(node.roll), math.sin(node.roll)
  local rx = vec3(cy * cz + sy * sx * sz, cx * sz, -sy * cz + cy * sx * sz)
  local up = vec3(-cy * sz + sy * sx * cz, cx * cz, sy * sz + cy * sx * cz)
  local rz = vec3(sy * cx, -sx, cy * cx)
  return rx, up, rz
end

-- ── audio ────────────────────────────────────────────────────────────────────
-- Spatial SFX ride the world through the SFX mixer bus (a short reverb +
-- compressor there sell scale and stop a stack of engines swamping the mix);
-- the ambient drone sits on the Ambient bus. Persistent LOOPS (engine, reentry,
-- bed) keep ONE voice and ride its volume/pitch with throttle/heat instead of
-- restarting — no clicks, no voice churn. Real recordings (audio/foley,
-- audio/SOURCES.md): NASA's SLS at full thrust, CC0 pyro bangs, clunks,
-- servos and pneumatics. The air is a synthesised roar, never a tone: the
-- old Kenney force-field loop decayed 60 dB every 0.95 s, so looped it beeped
-- about once a second — under every rover past 10 m/s.
local SFX = {
  engine   = "audio/foley/rocket_roar.ogg",
  ignite   = "audio/foley/rocket_ignite.ogg",
  stage    = "audio/foley/pyro_bang.ogg",
  boosters = "audio/foley/pyro_far.ogg",
  clamp    = "audio/foley/clamp_clunk.ogg",
  thump    = "audio/foley/rover_bump.ogg",
  explode  = "audio/foley/pyro_bang.ogg",
  boom     = "audio/foley/explosion_far.ogg",
  chute    = "audio/foley/hiss_short.ogg",
  reentry  = "audio/foley/wind_roar.ogg",
  gear     = "audio/foley/servo_run.ogg",
  motor    = "audio/foley/rover_motor.ogg",
  gravel   = "audio/foley/rover_gravel.ogg",
  -- live state, kept here so the chunk needs no new locals (LuaJIT's 200):
  -- the rover's two loops, and when the craft last left the ground
  live     = { motor = nil, gravel = nil, air_since = nil },
}
local engine_sfx, reentry_sfx = nil, nil
local throttle_prev = 0.0
local was_grounded = false   -- for the touchdown dust puff
local launch_dust_t = -10.0  -- throttle-up ground-dust cadence
local wind_intensity = 0.0   -- 0..~1.4 air density × speed (roar + shake)
local shake_published = false -- did THIS vessel last write cam.shake? (clean 0)
-- SCREEN SHAKE: a transient magnitude (bumped by impacts/explosions, decays
-- fast) added to a continuous base (wind + ground thrust). Published each frame
-- as `cam.shake` for planet_camera to jitter the view. `add_shake` spikes it.
local shake = 0.0
local function add_shake(amount)
  shake = math.min(1.6, shake + amount)
end
-- Publish the shared cam.shake for planet_camera. `base` is the continuous
-- component (wind/thrust, piloting only). We only write when we have something
-- to say (piloting, or a live transient from an impact) so parked/other craft
-- never stomp the value; a single trailing 0 settles the view.
local function publish_shake(base)
  local total = shake + (base or 0.0)
  if (base and base > 0.0) or total > 0.01 then
    save.set("cam.shake", math.min(1.0, total))
    shake_published = true
  elseif shake_published then
    save.set("cam.shake", 0.0)
    shake_published = false
  end
end

-- A one-shot spatial hit at a world point (KSP-scale falloff, SFX bus).
local function sfx3(clip, x, y, z, vol, pitch)
  if not audio then return end
  audio.play(clip, x, y, z, {
    track = "SFX", volume = vol or 1.0, pitch = pitch or 1.0,
    mode = "spatial", falloff = "inverse", minDistance = 4.0, maxDistance = 800.0,
  })
end

-- Blast a crater where an explosion meets the ground: a real gouge PLUS a wide
-- scorched scuff so the scar reads even on a glancing blast. `sd < r * 2` widens the
-- proximity gate (a blast a little above the surface still leaves a mark), and the
-- dig is deepened so a destroyed ship visibly cracks the ground.
local function make_crater(x, y, z, r)
  local sd = terrain.query(x, y, z)
  if not sd then return end
  if sd < r * 2.0 then
    -- Scorch first (color-only, always lands within reach); then dig if genuinely in.
    terrain.paint(x, y, z, r * 1.6, 0.08, 0.07, 0.06, 0.7)
  end
  -- (never into the base's foundations: the ball shrinks to stay clear of them)
  if sd < r then r = baseDigRadius(x, y, z, r); if r >= 0.3 then terrain.dig(x, y, z, r, 1.0); groundChangedAt(x, y, z, r) end end
end

-- The engine LOOP follows the vessel and rides the throttle; born on the first
-- burn, muted (not stopped) when idle so there's no restart pop.
local function update_engine_audio(node, burning, thr)
  if not audio then return end
  if burning then
    if not engine_sfx then
      engine_sfx = audio.play(SFX.engine, node, {
        track = "SFX", loop = true, mode = "spatial", falloff = "inverse",
        minDistance = 6.0, maxDistance = 900.0, volume = 0.0 })
    end
    if engine_sfx then
      engine_sfx:setVolume(0.35 + thr * 0.8)
      engine_sfx:setPitch(0.82 + thr * 0.5)
    end
  elseif engine_sfx then
    engine_sfx:setVolume(0.0)
  end
end

-- The atmospheric ROAR: one loop whose volume rides the WIND (air density ×
-- speed — you hear it long before you're hot) and climbs further as reentry
-- heating builds; pitch rises with speed. This is the audible "you're going too
-- fast, slow down" cue Ty wanted, and it silences as the air thins out.
local function update_wind_audio(node, wind, flux, spd)
  if not audio then return end
  local intensity = math.max(wind, flux * 5.0) -- burning adds to the roar
  if intensity > 0.03 then
    if not reentry_sfx then
      reentry_sfx = audio.play(SFX.reentry, node, {
        track = "SFX", loop = true, mode = "spatial", falloff = "inverse",
        minDistance = 8.0, maxDistance = 1200.0, volume = 0.0 })
    end
    if reentry_sfx then
      reentry_sfx:setVolume(math.min(1.0, intensity * 1.6))
      reentry_sfx:setPitch(0.7 + math.min(0.9, (spd or 0) / 320.0))
    end
  elseif reentry_sfx then
    reentry_sfx:setVolume(0.0)
  end
end

-- The ROVER: the drive motors whine up with the wheel speed and the effort
-- on the stick, and the tyres crunch over the ground while they are on it.
-- Two loops that live with the craft and are muted, not stopped, at rest.
function SFX.drive(node, live, spd, effort, on_ground)
  if not audio then return end
  local L = SFX.live
  local roll = live and math.min(1.0, spd / 10.0) or 0.0
  local push = live and math.min(1.0, math.abs(effort or 0)) or 0.0
  local mv = (roll > 0.02 or push > 0.05) and (0.10 + 0.30 * roll + 0.20 * push) or 0.0
  local gv = (live and on_ground and spd > 0.4) and (0.15 + 0.55 * roll) or 0.0
  if mv > 0 and not L.motor then
    L.motor = audio.play(SFX.motor, node, { track = "SFX", loop = true, mode = "spatial",
      falloff = "inverse", minDistance = 4.0, maxDistance = 120.0, volume = 0.0 })
  end
  if gv > 0 and not L.gravel then
    L.gravel = audio.play(SFX.gravel, node, { track = "SFX", loop = true, mode = "spatial",
      falloff = "inverse", minDistance = 4.0, maxDistance = 90.0, volume = 0.0 })
  end
  if L.motor then
    L.motor:setVolume(mv)
    L.motor:setPitch(0.55 + 0.75 * roll + 0.10 * push)
  end
  if L.gravel then
    L.gravel:setVolume(gv)
    L.gravel:setPitch(0.80 + 0.35 * roll)
  end
end

-- Stop the vessel's persistent loops (EVA, breakup) — silence, don't leak.
local function silence_loops()
  if engine_sfx then engine_sfx:stop(); engine_sfx = nil end
  if reentry_sfx then reentry_sfx:stop(); reentry_sfx = nil end
  local L = SFX.live
  if L.motor then L.motor:stop(); L.motor = nil end
  if L.gravel then L.gravel:stop(); L.gravel = nil end
end

-- ── blueprint ───────────────────────────────────────────────────────────────
-- The part's local +Y (its thrust/stack axis) in the VESSEL frame, from the
-- blueprint's YXZ rotation — a sideways-mounted engine pushes sideways.
local function part_axis(d)
  local cy, sy = math.cos(d.yaw or 0), math.sin(d.yaw or 0)
  local cx, sx = math.cos(d.pitch or 0), math.sin(d.pitch or 0)
  local cz, sz = math.cos(d.roll or 0), math.sin(d.roll or 0)
  return -cy * sz + sy * sx * cz, cx * cz, sy * sz + cy * sx * cz
end

-- The part's local +X in the VESSEL frame — the OUTWARD direction of anything
-- the builder mounted on a flank. `radial_orient` parts are yawed by
-- `atan2(-dz, dx)` precisely so their +X points away from the hull, so this is
-- where a side-mounted docking port mates and where an RCS block's nozzles aim.
local function part_axis_x(d)
  local cy, sy = math.cos(d.yaw or 0), math.sin(d.yaw or 0)
  local cx, sx = math.cos(d.pitch or 0), math.sin(d.pitch or 0)
  local cz, sz = math.cos(d.roll or 0), math.sin(d.roll or 0)
  return cy * cz + sy * sx * sz, cx * sz, -sy * cz + cy * sx * sz
end

-- `override` is the blueprint an UNDOCKED module is handed at the seam (see
-- `undock`); without one we're the shipyard's launch and read the saved build.
local function load_bp(override)
  bp = override or save.get("shipyard.blueprint")
  engines, tanks, events, part_total, fuel_cap = {}, {}, {}, 0, 0.0
  elec.cap, elec.gen, elec.comms = 0.0, 0.0, false
  local decouplers, boosters = {}, {}
  if not bp or not bp.parts then return end
  -- THE TREE, made whole from the builder's links first (SPLIT.normalize: a
  -- part held on by a weld or a demoted link is hung off its partner, not left
  -- as a second root that stays behind when its craft separates).
  if bp.links then SPLIT.normalize(bp.parts, bp.links, bp.root) else SPLIT.normalize(bp.parts, nil, bp.root) end
  local by_uid = {}
  for _, d in pairs(bp.parts) do by_uid[d.uid] = d end
  local kids = SPLIT.kids(bp.parts)
  -- THE COMMAND POD. A stack can carry MORE THAN ONE crewed part — a lander
  -- riding its mothership through a docking seam is exactly that — and `pairs`
  -- order is arbitrary, so "whichever crewed part came last" made `pod_uid`
  -- nondeterministic. That matters: `axial_departing` inverts its cut to keep
  -- the pod side, so a coin-flip there undocked the MOTHERSHIP instead of the
  -- lander. Pick the crewed part nearest the tree root (the primary craft's
  -- pod), tie-broken by uid so the same blueprint always flies the same way.
  local best_pod, best_rank
  -- (no crewed part: the PROBE CORE nearest the root commands the craft)
  local want_kind = nil
  for _, d in pairs(bp.parts) do
    if d.kind == "crewed" then want_kind = "crewed" break end
    if d.kind == "probe" then want_kind = "probe" end
  end
  for _, d in pairs(bp.parts) do
    if d.kind == want_kind then
      local depth, u, guard = 0, d.uid, 0
      while by_uid[u] and (by_uid[u].parent or 0) ~= 0 and guard < 64 do
        u = by_uid[u].parent
        depth, guard = depth + 1, guard + 1
      end
      -- A real pod outranks an open COMMAND SEAT: with both aboard the crew
      -- flies from the pod, and a seat only commands when it is all there is.
      local rank = depth * 1e6 + d.uid + (((d.seat or 0) == 1) and 1e9 or 0)
      if not best_rank or rank < best_rank then best_rank, best_pod = rank, d end
    end
  end
  if best_pod then
    pod = { x = best_pod.x, y = best_pod.y, z = best_pod.z }
    pod_uid = best_pod.uid
  end
  podCrewed = best_pod ~= nil and best_pod.kind == "crewed"
  -- An OPEN SEAT (the builder's `seat`): its rider stays in view, seated
  -- (scripts/command_seat.lua poses them); a pod hides its crew.
  podSeat = podCrewed and (best_pod.seat or 0) == 1
  -- Every place the crew can sit (see `crewSeats`); they start in the command
  -- pod, which a real pod wins over a seat (the rank above).
  stationUid = podCrewed and best_pod.uid or nil
  -- Radial-decoupler BRANCHES: each = what that decoupler throws off (the
  -- side without the crew, SPLIT.sides); they separate as one group, their
  -- engines burn from the start and their tanks drain first.
  local in_branch = {} -- uid → branch root uid
  for _, d in pairs(bp.parts) do
    if (d.radial or 0) == 1 and (d.decouple or 0) == 1 then
      local uids = SPLIT.sides(by_uid, kids, d.uid, best_pod and best_pod.uid or nil)
      for u in pairs(uids) do in_branch[u] = in_branch[u] or d.uid end
      local pos = {}
      for u in pairs(uids) do
        local dd = by_uid[u]
        if dd then pos[#pos + 1] = { x = dd.x, y = dd.y, z = dd.z } end
      end
      boosters[#boosters + 1] = { uid = d.uid, x = d.x, y = d.y, z = d.z,
                                  uids = uids, pos = pos }
    end
  end
  for _, dev in pairs(DEVICES) do
    dev.parts, dev.nodes, dev.pose = {}, {}, {}
    -- Roll out in each device's LAUNCH state (gear down, thrusters cold).
    dev.on = dev.launch ~= false
    dev.anim, dev.anim_applied = dev.on and 1.0 or 0.0, nil
  end
  panim, ppose, pnode = {}, {}, {}
  for _, d in pairs(bp.parts) do
    part_total = part_total + 1
    if (d.thrust or 0) > 0 then
      local ax, ay, az = part_axis(d)
      -- a JET's thrust and burn follow its spool and its air (aeroTick): it
      -- starts cold
      local jet = afHas(d, "jet")
      engines[#engines + 1] = { x = d.x, y = d.y, z = d.z, dx = ax, dy = ay, dz = az,
                                thrust = d.thrust, burn = d.burn or 1,
                                branch = in_branch[d.uid], uid = d.uid, rec = d,
                                jet = jet or nil, jk = jet and 0 or nil, jb = jet and 0 or nil }
    end
    if (d.fuel or 0) > 0 then
      -- `left` is what this tank still holds; `ft` its propellant's tonnes per
      -- unit (0 for a build saved before propellant had mass).
      tanks[#tanks + 1] = { y = d.y, fuel = d.fuel, left = d.fuel, ft = d.fuel_t or 0,
                            branch = in_branch[d.uid], uid = d.uid }
      fuel_cap = fuel_cap + d.fuel
    end
    if (d.decouple or 0) == 1 and (d.radial or 0) ~= 1 then
      decouplers[#decouplers + 1] = { uid = d.uid, y = d.y }
    end
  end
  rescanSeats(bp.parts)
  table.sort(decouplers, function(a, b) return a.y < b.y end)
  -- Build the ordered EVENT list: booster branches group into ring events by
  -- symmetry group (a lone radial decoupler is its own ring), axial cuts are
  -- one event each. Order = the builder's saved stages; parts without one
  -- fall back to the classic default (rings first, then axial bottom-up).
  local rings = {}
  for _, g in ipairs(boosters) do
    local dd = by_uid[g.uid]
    local key = (dd and dd.sym and dd.sym ~= 0) and ("g" .. dd.sym) or ("u" .. g.uid)
    local ev = rings[key]
    if not ev then
      ev = { kind = "ring", branches = {}, stage = 1e9, y = g.y }
      rings[key] = ev
      events[#events + 1] = ev
    end
    ev.branches[#ev.branches + 1] = g
    local st = dd and (dd.stage or 0) or 0
    if st > 0 and st < ev.stage then ev.stage = st end
    ev.y = math.min(ev.y, g.y)
  end
  for _, dec in ipairs(decouplers) do
    local dd = by_uid[dec.uid]
    local st = dd and (dd.stage or 0) or 0
    events[#events + 1] = { kind = "axial", uid = dec.uid, y = dec.y,
                            stage = st > 0 and st or 1e9 }
  end
  -- PARACHUTES: every chute part on board is armed as ONE deploy event
  -- (staging it opens all of them). Defaults LAST (you pull the chutes on
  -- the way down, after everything else has separated).
  chutes = {}
  local chute_uids = {}
  local chute_stage = 1e9
  for _, d in pairs(bp.parts) do
    if (d.chute or 0) == 1 then
      chutes[#chutes + 1] = { x = d.x, y = d.y, z = d.z, h = d.h, uid = d.uid }
      chute_uids[#chute_uids + 1] = d.uid
      local st = d.stage or 0
      if st > 0 and st < chute_stage then chute_stage = st end
    end
  end
  if #chutes > 0 then
    events[#events + 1] = { kind = "chute", uids = chute_uids,
                            stage = chute_stage < 1e9 and chute_stage or 2e9 }
  end
  -- FAIRINGS: each one's jettison is its own event (and its own action).
  for _, d in pairs(bp.parts) do
    if (d.fairing or 0) > 0 and (d.fr or 0) > 0 and not (type(d.st) == "table" and d.st.jettisoned) then
      local st = d.stage or 0
      events[#events + 1] = { kind = "fairing", uid = d.uid, y = d.y, stage = st > 0 and st or 1e9 }
    end
  end
  for _, ev in ipairs(events) do
    if ev.stage >= 1e9 then
      -- default rank: rings ahead of axial, lower first; chutes dead last.
      if ev.kind == "chute" then
        ev.stage = 3e6
      else
        ev.stage = 1e6 + (ev.kind == "ring" and 0 or 1e3) + ev.y
      end
    end
  end
  table.sort(events, function(a, b) return a.stage < b.stage end)
  fuelSort()
  fuelSync()
  -- Electronics: every part's live state (batteries roll out of the VAB topped
  -- up, legs down, panels and antennas stowed — or whatever a restored craft's
  -- records say), the device sets, and the action groups.
  do
    local E = elib()
    local stateOf = E and E.stateOf
    if stateOf then for _, d in pairs(bp.parts) do stateOf(d) end end
  end
  bp_by_uid = by_uid
  integ.gone = {}
  part_hp = {}
  for _, d in pairs(bp.parts) do part_hp[d.uid] = 1.0 end
  elecRescan()
  groupsReset(bp.groups, bp.controls)
  focusHeight = pod.y
  podLX, podLY, podLZ = pod.x, pod.y, pod.z
  -- Damage model state: every part starts pristine.
  bp_by_uid = by_uid
  bp_in_branch = in_branch
  bp_kids = kids            -- the attachment tree (uid → children) for staging
  axial_set_cache = {}      -- recompute departing sets for this blueprint
  eid_uid = {}              -- clear the part-entity → uid cache
  part_hp = {}
  for _, d in pairs(bp.parts) do part_hp[d.uid] = 1.0 end
  -- ...except what a restored craft's records say: its parts' WEAR rides in
  -- their state (`st.hp`, written by fleetParts), so a dented tank is still
  -- dented after a reload and a repair kit still has something to mend.
  for _, d in pairs(bp.parts) do
    local h = type(d.st) == "table" and tonumber(d.st.hp) or nil
    if h and h > 0 and h < 1 then part_hp[d.uid] = h end
  end
  integ.gone, integ.box, integ.strain = {}, {}, {}
  integ.gen = integ.gen + 1
  -- (elecRescan above already sorted THIS part set — the same records, none
  -- gone, all whole — so the new generation needs no second pass: at 1,000
  -- parts that pass is ~15 ms, on the rollout's busiest frame)
  elec.gen_seen = integ.gen
  destroyed = false
  chutes_deployed = false
  chute_fill = { t = 0.0, stretch = 0.0, area = 0.0, dens = 0.0, spd = 0.0 }
  -- Docking ports are peripherals, not staging events — they're rescanned here
  -- and again after every dock/undock rewrites the tree.
  dock.ports, dock.latched, dock.pending, dock.target = {}, 0, nil, nil
  dockRescan()
  holdRegister(dock.node)
end


-- Is this engine part of the CURRENTLY BURNING set? Bottom live axial stage
-- + every still-attached side booster (boosters light with stage 1 and burn
-- until their radial decoupler fires).
local function engine_active(e, cut)
  -- Its own switch first: an engine shut down by action stays down; one
  -- activated by action burns whatever stage it sits in.
  local st = e.rec and e.rec.st
  if st then
    if st.running == false then return false end
    if st.forced then return true end
  end
  if e.branch then return true end -- attached booster (dropped at separation)
  return e.y < cut - 0.01
end

-- The PHYSICS-FRESH base of the vessel frame. Inside fixedUpdate the node
-- transform lags this tick's rails carry (the planet moved ~1.5 u since the
-- node was last written) — using node coords put thrust ~a hull-width off the
-- real engines (a constant spurious torque the SAS fought forever), and drew
-- boarding rings beside the ship. `info.origin` is the sim's own anchor.
local function base_of(node, info)
  if info and info.origin then
    return info.origin.x, info.origin.y, info.origin.z
  end
  return node.x, node.y, node.z
end

local function pod_world(node, info)
  local rx, up, rz = basis(node)
  local bx, by, bz = base_of(node, info)
  return bx + rx.x * pod.x + up.x * pod.y + rz.x * pod.z,
         by + rx.y * pod.x + up.y * pod.y + rz.y * pod.z,
         bz + rx.z * pod.x + up.z * pod.y + rz.z * pod.z
end

-- Boarding reach: distance to the vessel's SPINE (base → pod), not to the pod
-- point itself — a pod on top of a tall stack is 6+ units off the ground, and
-- demanding you touch it made re-boarding physically impossible. Standing at
-- the rocket counts as climbing the ladder.
--
-- The astronaut is read off its NODE, which inside fixedUpdate lags this
-- tick's rails carry exactly as our own root node does, while `info.origin`
-- does not. Measured raw, a crew member standing 2.4 m from a parked hull read
-- 5.5 m away (a 4 m carry on Vever), so neither F nor the "F — board" prompt
-- answered beside it. Carry the astronaut by the same lag first.
--
-- A craft with more than one crew position (a pod AND a Command Seat) answers
-- the one NEAREST the astronaut: walk up to the seat and F sits you in it, walk
-- to the pod's hatch and F climbs into the pod. Returns the distance and that
-- station ({ uid, x, y, z, seat }; nil on a craft with no crewed part, when the
-- distance is to the current `pod`). For a seat the reach is to the seat itself
-- (an open seat has no ladder up the stack); for a pod, to the spine below it.
local function board_dist(node, a, info)
  local sx, sy, sz = base_of(node, info) -- spine base (stack bottom)
  local ax, ay, az = a.x + (sx - node.x), a.y + (sy - node.y), a.z + (sz - node.z)
  local rx, up, rz = basis(node)
  local function to(lx, ly, lz, spine)
    local px = sx + rx.x * lx + up.x * ly + rz.x * lz
    local py = sy + rx.y * lx + up.y * ly + rz.y * lz
    local pz = sz + rx.z * lx + up.z * ly + rz.z * lz
    local dx, dy, dz = px - sx, py - sy, pz - sz
    local len2 = dx * dx + dy * dy + dz * dz
    local t = 1.0
    if spine and len2 > 1e-9 then
      t = ((ax - sx) * dx + (ay - sy) * dy + (az - sz) * dz) / len2
      t = math.max(0.0, math.min(1.0, t))
    end
    local cx, cy, cz = sx + dx * t, sy + dy * t, sz + dz * t
    return math.sqrt((ax - cx) ^ 2 + (ay - cy) ^ 2 + (az - cz) ^ 2)
  end
  local best, bd = nil, nil
  for _, st in ipairs(crewSeats) do
    if not integ.gone[st.uid] and (part_hp[st.uid] or 1) > 0 then
      local d = to(st.x, st.y, st.z, not st.seat)
      if not bd or d < bd then best, bd = st, d end
    end
  end
  if best then return bd, best end
  return to(pod.x, pod.y, pod.z, true), nil
end

-- Rebuild `crewSeats` from a part list (the blueprint; after a docking, the
-- merged craft). The current station stays if it is still aboard.
function rescanSeats(parts)
  crewSeats = {}
  local cl = crewLibNow()
  for _, d in pairs(parts or bp_by_uid) do
    local def = cl and cl.seatDef(d)
    if d.kind == "crewed" or def then
      crewSeats[#crewSeats + 1] = { uid = d.uid, x = d.x, y = d.y, z = d.z, seat = (d.seat or 0) == 1 or (def and def.open == true),
                                    slots = def and #def.seats or 1, command = (not def) or def.command == true }
    end
  end
  table.sort(crewSeats, function(a, b) return a.uid < b.uid end)
end

-- Put the crew's place at this station (a crewSeats entry or its uid): the
-- seated pose, the camera's centre, the hatch ring and the exit all follow.
-- The COMMAND part (`pod_uid`) does not change. Returns true if it exists.
function setStation(st)
  if type(st) ~= "table" then
    local uid = st
    st = nil
    for _, s in ipairs(crewSeats) do if s.uid == uid then st = s end end
  end
  if not st then return false end
  stationUid = st.uid
  pod = { x = st.x, y = st.y, z = st.z }
  podSeat = st.seat == true
  podLX, podLY, podLZ = st.x, st.y, st.z
  focusHeight = st.y
  return true
end

-- Where the crew sits (or would): the station's uid, and whether it is an open seat.
function crewStation() return stationUid, podSeat end
-- The COMMAND part's uid (staging keep-side, damage, the rover's front),
-- whichever crew position the crew is in.
function commandUid() return pod_uid end

-- ── instruments (the scout ship's cluster, reused verbatim) ─────────────────
local function set_hud(text)
  if not hud then hud = find("Ship HUD Text") end
  if not hud_panel then hud_panel = find("HUD Panel") end
  -- Toggle the BACKING PANEL (the text rides inside it) so the frame appears and
  -- vanishes with the readout — never an empty box while walking around.
  local panel = hud_panel or hud
  if panel then
    local el = panel:getcomponent("UiElement")
    if el then el.visible = text ~= nil end
  end
  if hud and text then hud.text = text end
end

local prompt_last = nil
local function set_prompt(text)
  promptText = text   -- published (probes read what the prompt says)
  if not hud_prompt then hud_prompt = find("Vessel HUD") end
  if hud_prompt and text ~= prompt_last then
    hud_prompt.text = text
    prompt_last = text
  end
end

local function find_instruments()
  if navball then return end
  navball = find("Navball")
  tape_spd, tape_alt = find("Speed Tape"), find("Alt Tape")
  txt_spd, txt_alt = find("Speed Readout"), find("Alt Readout")
  txt_hdg = find("Heading Readout")
end

local function set_navball(on)
  find_instruments()
  for _, inst in ipairs({ navball, tape_spd, tape_alt, txt_spd, txt_alt, txt_hdg }) do
    if inst then
      local el = inst:getcomponent("UiElement")
      if el then el.visible = on and 1 or 0 end
    end
  end
end

-- Navball uniforms: the vessel basis in the LOCAL HORIZON frame (x=east,
-- y=radial up, z=north) + prograde + the SAS aim ring. Same math as the ship.
local function update_navball(node, nx, ny, nz, fx, fy, fz, tgtx, tgty, tgtz)
  find_instruments()
  if not navball then return end
  local d = space.dominant(node.x, node.y, node.z)
  local b = d and space.body(d)
  if not b then return end
  local ux, uy, uz = norm(node.x - b.x, node.y - b.y, node.z - b.z)
  local ex, ey, ez
  if math.abs(uy) > 0.93 then
    ex, ey, ez = norm(cross(0, 0, 1, ux, uy, uz))
  else
    ex, ey, ez = norm(cross(0, 1, 0, ux, uy, uz))
  end
  if ex == 0 and ey == 0 and ez == 0 then ex, ey, ez = 1, 0, 0 end
  local nhx, nhy, nhz = cross(ux, uy, uz, ex, ey, ez)
  local function toH(vx, vy, vz)
    return vx * ex + vy * ey + vz * ez,
           vx * ux + vy * uy + vz * uz,
           vx * nhx + vy * nhy + vz * nhz
  end
  local rx2, ry2, rz2 = cross(fx, fy, fz, nx, ny, nz)
  local bx2, by2, bz2 = cross(nx, ny, nz, rx2, ry2, rz2)
  navball:setShaderParam("right", toH(rx2, ry2, rz2))
  navball:setShaderParam("up", toH(bx2, by2, bz2))
  navball:setShaderParam("nose", toH(nx, ny, nz))
  local vl = math.sqrt(node.vx ^ 2 + node.vy ^ 2 + node.vz ^ 2)
  if vl > 2.0 then
    navball:setShaderParam("prograde", toH(node.vx / vl, node.vy / vl, node.vz / vl))
  else
    navball:setShaderParam("prograde", 0, 0, 0)
  end
  if tgtx then
    navball:setShaderParam("sasTarget", toH(tgtx, tgty, tgtz))
  else
    navball:setShaderParam("sasTarget", 0, 0, 0)
  end
  local he = nx * ex + ny * ey + nz * ez
  local hn = nx * nhx + ny * nhy + nz * nhz
  local heading = (math.deg(math.atan2(he, hn)) + 360) % 360
  local dxr, dyr, dzr = node.x - b.x, node.y - b.y, node.z - b.z
  local alt = math.sqrt(dxr * dxr + dyr * dyr + dzr * dzr) - b.radius
  local tk_v, tk_a = worldScaleK()
  if tape_spd then tape_spd:setShaderParam("tape", vl, tk_v > 1.2 and 60 or 40, 5) end
  if tape_alt then tape_alt:setShaderParam("tape", alt, tk_a > 1.5 and 300 or 150, tk_a > 1.5 and 50 or 25) end
  if txt_spd then txt_spd.text = string.format("%.0f", vl) end
  -- (never "-0": a craft sitting on the pad wobbles either side of zero)
  if txt_alt then txt_alt.text = string.format("%.0f", math.abs(alt) < 0.5 and 0 or alt) end
  if txt_hdg then txt_hdg.text = string.format("%03.0f°", heading) end
end

-- ── effects director ────────────────────────────────────────────────────────
-- vfx.lua fires every physical effect in the planet's own frame (see its
-- header). Resolved lazily and re-resolved if it goes; nil in a harness, where
-- each call site falls back to its plain spawnEffect.
local fx_ref = nil
local function fxd()
  if not (fx_ref and fx_ref.valid) then fx_ref = findScript and findScript("vfx") or nil end
  return fx_ref
end

-- The ground was dug here (a crater, a scrape, the drill): the plants and
-- rocks on it are dropped onto it again (flora_field groundChanged, which
-- tells mineral_field too). A global, not a local: this chunk is at its cap.
local ff_ref = nil
function groundChangedAt(x, y, z, r)
  if not (ff_ref and ff_ref.valid) then ff_ref = findScript and findScript("flora_field") or nil end
  if ff_ref and ff_ref.groundChanged then pcall(ff_ref.groundChanged, x, y, z, r) end
end
-- The base's foundations can't be dug (base_facilities digClamp): the radius a
-- blast, gouge or drill may dig there, r where nothing guarded is near. A global
-- table and function for the same reason as above.
BASE_GUARD = { ref = nil }
function baseDigRadius(x, y, z, r)
  local g = BASE_GUARD
  if not (g.ref and g.ref.valid) then g.ref = findScript and findScript("base_facilities") or nil end
  if not (g.ref and g.ref.digClamp) then return r end
  local ok, rr = pcall(g.ref.digClamp, x, y, z, r)
  return (ok and type(rr) == "number") and rr or r
end

-- ── engine plumes ───────────────────────────────────────────────────────────
-- Every live engine part carries an "Engine Flame" child (Flame vfx + point
-- light); the plume density and light follow the throttle. Staged-away
-- engines re-root under the detached stage, so `node:children()` only ever
-- yields the LIVE stack — no bookkeeping.
-- (The engine children are listed once per part set and once a second, not
-- every tick: walking every part's handle and name each tick was a fixed cost
-- that grew with the craft, flames or no flames.)
FLAME_KIDS = { gen = -1, id = nil, t = -10.0, list = {} }
local function set_flames(node, pct, cut)
  local on = pct > 0.02
  cut = cut or math.huge
  local F = FLAME_KIDS
  if F.gen ~= integ.gen or F.id ~= node.id or time - F.t >= 1.0 or time < F.t then
    local list = {}
    for _, c in ipairs(node:children()) do
      if c.name and c.name:find("PartEngine") then list[#list + 1] = c end
    end
    F.gen, F.id, F.t, F.list = integ.gen, node.id, time, list
  end
  for _, c in ipairs(F.list) do
    -- Only ACTIVE engines light: match the child to its blueprint engine by
    -- local pose (bottom live stage + attached side boosters burn; parts
    -- above the next decoupler are a later stage, cold until their turn).
    if c.valid ~= false then
      local live = false
      if on then
        for _, e in ipairs(engines) do
          if math.abs((c.x or 0) - e.x) < 0.05 and math.abs((c.y or 0) - e.y) < 0.05
            and math.abs((c.z or 0) - e.z) < 0.05 and engine_active(e, cut) then
            live = true
            break
          end
        end
      end
      for _, f in ipairs(c:children()) do
        if f.name == "Engine Flame" then
          local ps = f:particles()
          if ps then
            if live and not ps:isPlaying() then ps:play() end
            if not live and ps:isPlaying() then ps:stop() end
            if live then ps:setIntensity(0.25 + pct * 1.25) end
          end
          local light = f:getcomponent("PointLight")
          if light then light.intensity = live and (0.8 + pct * 4.0) or 0.0 end
          local fx = fxd()
          if fx then fx.flame(f, live, pct) end
        end
      end
    end
  end
end

-- ── SAS ─────────────────────────────────────────────────────────────────────
local SAS_KEYS = {
  ["1"] = "stability", ["2"] = "prograde", ["3"] = "retrograde",
  ["4"] = "normal", ["5"] = "antinormal", ["6"] = "radialin",
  ["7"] = "radialout", ["8"] = "dock", ["9"] = "node", ["0"] = "target",
}

function setSAS(m)
  sas_mode = m
  if m ~= "off" then sas_last = m end
end

-- SAS TARGET / ANTI-TARGET (modes "target", "antitarget"): the hold is worked
-- out by scripts/targeting.lua (the target, our docking port, the roll), which
-- hands back the wanted angular velocity and the aim. Global, so fixedUpdate
-- spends no upvalue on it. → dwx, dwy, dwz, aimx, aimy, aimz or nil (hold).
TGT_HOLD = { ref = nil, miss = -10.0 }
function targetHold(node, nx, ny, nz)
  local H = TGT_HOLD
  if not (H.ref and H.ref.valid ~= false) then
    if (time or 0) - H.miss < 2.0 then return nil end
    H.ref = findScript and findScript("targeting") or nil
    if not H.ref then H.miss = time or 0 return nil end
  end
  if not H.ref.steer then return nil end
  local ok, a, b, c, d, e, f = pcall(H.ref.steer, node.id, nx, ny, nz, sas_mode, params.max_rate, params.rate_accel)
  if not ok then return nil end
  return a, b, c, d, e, f
end

local function sas_target_dir(node, db, mode)
  -- The planned burn is the one hold that doesn't come from the state vector:
  -- the map worked its direction out during the trajectory walk and cached it,
  -- because the walk isn't running out here in flight. Answered first, and
  -- without needing a dominant body — a burn direction is a burn direction.
  if mode == "node" then
    local m = map()
    if not m or not m.burnDirection then return nil end
    return m.burnDirection()
  end
  if not db then return nil end
  local vx, vy, vz = node.vx, node.vy, node.vz
  local vl = math.sqrt(vx * vx + vy * vy + vz * vz)
  if vl < 2.0 then return nil end
  local pgx, pgy, pgz = vx / vl, vy / vl, vz / vl
  if mode == "prograde" then return pgx, pgy, pgz end
  if mode == "retrograde" then return -pgx, -pgy, -pgz end
  local hx, hy, hz = cross(node.x - db.x, node.y - db.y, node.z - db.z, vx, vy, vz)
  local nmx, nmy, nmz = norm(hx, hy, hz)
  if nmx == 0 and nmy == 0 and nmz == 0 then return nil end
  if mode == "normal" then return nmx, nmy, nmz end
  if mode == "antinormal" then return -nmx, -nmy, -nmz end
  local rox, roy, roz = cross(pgx, pgy, pgz, nmx, nmy, nmz)
  if mode == "radialout" then return rox, roy, roz end
  if mode == "radialin" then return -rox, -roy, -roz end
  return nil
end

-- ══ SPLIT RULEBOOK BEGIN (pure: tests/smoke_stage_split.lua loads this block) ══
-- Where a craft comes apart, from its records alone (no scene, no engine).
--
-- SPLIT.normalize(recs, links, root) makes the attachment tree (`parent`/`att`)
-- whole. The builder joins parts by LINKS (builder_graph): the primary link is
-- the record's `parent`, but a part can be held on by a link that is not
-- primary — a WELD, or a stack link demoted when its partner was re-attached
-- elsewhere. Such a part has `parent` 0 and looked, to the flight, like a
-- second root: the playtest's jet cockpit (welded to its fuselage) stayed on
-- the rocket when the radial decoupler under the jet fired, and took the
-- controls with it. Every tree the links join to the main one is re-rooted at
-- the joined part and hung off its partner, so the tree reaches every part
-- the builder showed attached. `root` (the blueprint's) picks the main tree;
-- without one, the largest. Returns how many records changed.
--
-- SPLIT.sides(by_uid, kids, dec, keep, alive) → the set that LEAVES when
-- decoupler `dec` fires: the cut is the decoupler's own joint (dec → its
-- parent); the decoupler leaves with what is built onto it, unless `keep`
-- (the part the crew sits in, else the command part) is on that side — then
-- the parent's side leaves and the decoupler stays with the crew. A radial
-- decoupler is the same cut: a jet hung on a rocket's radial decoupler with
-- the crew in the jet keeps the jet and drops the rocket. `alive(u)` (optional)
-- says a part is still aboard.
SPLIT = {}
local function split_opp(side)
  if side == "top" then return "bottom" end
  if side == "bottom" then return "top" end
  return "surface"
end
function SPLIT.normalize(recs, links, root)
  local by, list = {}, {}
  for _, d in pairs(recs) do
    if d.uid then by[d.uid] = d; list[#list + 1] = d.uid end
  end
  table.sort(list)
  local changed = 0
  -- parents that name nobody aboard, and cycles, are cut first
  for _, u in ipairs(list) do
    local d = by[u]
    if (d.parent or 0) ~= 0 and not by[d.parent] then d.parent = 0; changed = changed + 1 end
  end
  local state = {}
  for _, u in ipairs(list) do
    if not state[u] then
      local path, on, x = {}, {}, u
      while x and x ~= 0 and by[x] and not state[x] do
        if on[x] then by[x].parent = 0; changed = changed + 1; break end
        on[x] = true
        path[#path + 1] = x
        x = by[x].parent
      end
      for _, p in ipairs(path) do state[p] = true end
    end
  end
  local tree_of = {}
  local function retree()
    tree_of = {}
    for _, u in ipairs(list) do
      if not tree_of[u] then
        local path, x = {}, u
        while true do
          if tree_of[x] then break end
          path[#path + 1] = x
          local p = by[x].parent or 0
          if p == 0 then tree_of[x] = x break end
          x = p
        end
        local r = tree_of[x]
        for _, p in ipairs(path) do tree_of[p] = r end
      end
    end
  end
  retree()
  local main = root and by[root] and tree_of[root] or nil
  if not main then
    local count, best = {}, nil
    for _, u in ipairs(list) do
      local t = tree_of[u]
      count[t] = (count[t] or 0) + 1
      if not best or count[t] > count[best] or (count[t] == count[best] and t < best) then best = t end
    end
    main = best
  end
  if not main or not links then return changed end
  local ls = {}
  for _, l in ipairs(links) do
    if l.a and l.b and by[l.a] and by[l.b] and l.a ~= l.b then ls[#ls + 1] = l end
  end
  table.sort(ls, function(p, q) if p.a ~= q.a then return p.a < q.a end return p.b < q.b end)
  local function hang(x, host, l)
    -- re-root x's tree at x (each edge on the way to its root turns round)
    local path, y = {}, x
    while y ~= 0 and by[y] do path[#path + 1] = y; y = by[y].parent or 0 end
    for i = #path, 2, -1 do
      local p, c = by[path[i]], by[path[i - 1]]
      p.parent, p.att = c.uid, split_opp(c.att)
    end
    local d = by[x]
    d.parent = host
    local side = (l.a == host) and l.sa or l.sb
    d.att = (side and side ~= "") and side or "surface"
    changed = changed + 1
  end
  local grew = true
  while grew do
    grew = false
    for _, l in ipairs(ls) do
      local ta, tb = tree_of[l.a], tree_of[l.b]
      if ta == main and tb ~= main then hang(l.b, l.a, l); grew = true
      elseif tb == main and ta ~= main then hang(l.a, l.b, l); grew = true end
      if grew then retree() break end
    end
  end
  return changed
end
-- children index of a record set (uid → { child uids }, sorted)
function SPLIT.kids(recs)
  local by, kids = {}, {}
  for _, d in pairs(recs) do if d.uid then by[d.uid] = d end end
  for u, d in pairs(by) do
    local p = d.parent or 0
    if p ~= 0 and by[p] then
      kids[p] = kids[p] or {}
      kids[p][#kids[p] + 1] = u
    end
  end
  for _, k in pairs(kids) do table.sort(k) end
  return kids
end
function SPLIT.sides(by, kids, dec, keep, alive)
  local ok = function(u) return by[u] ~= nil and (not alive or alive(u)) end
  local function grow(from, block)
    local set, q = { [from] = true }, { from }
    while #q > 0 do
      local u = table.remove(q)
      for _, k in ipairs(kids[u] or {}) do
        if not set[k] and k ~= block and ok(k) then set[k] = true; q[#q + 1] = k end
      end
    end
    return set
  end
  local d = by[dec]
  if not d then return {} end
  local p = d.parent or 0
  if p ~= 0 and ok(p) then
    local sub = grow(dec)
    if keep and sub[keep] and keep ~= dec then
      local inv = {}
      for u in pairs(by) do if not sub[u] and ok(u) then inv[u] = true end end
      return inv
    end
    return sub
  end
  -- a decoupler at the tree's root: it stays with the piece the crew is in
  -- (else its biggest), and every other piece built onto it leaves
  local pieces, stay, best = {}, nil, -1
  for _, k in ipairs(kids[dec] or {}) do
    if ok(k) then
      local s, n = grow(k), 0
      for _ in pairs(s) do n = n + 1 end
      pieces[#pieces + 1] = s
      if keep and s[keep] then stay = #pieces; best = math.huge
      elseif n > best then stay, best = #pieces, n end
    end
  end
  local out = {}
  if keep == dec then stay = nil end
  for i, s in ipairs(pieces) do
    if i ~= stay then for u in pairs(s) do out[u] = true end end
  end
  if keep == dec or not next(out) then
    -- nothing on the far side: the decoupler itself is all that goes
    if keep ~= dec then out[dec] = true end
  end
  return out
end
-- ══ SPLIT RULEBOOK END ══

-- ── staging ─────────────────────────────────────────────────────────────────
-- The DEPARTING SET of a decoupler (axial or radial), by the ATTACHMENT TREE —
-- not world height (SPLIT.sides): the cut is the decoupler's own joint, and
-- the side WITHOUT the crew leaves. This is why a nose cone hung LOW on an
-- upper stage stays, and a strut dangling DOWN from an upper stage is not swept
-- off by a cut below it (both were the "geometry read the wrong stage" bug).
-- Radial parts ride whichever spine part they're bolted to — the tree already
-- encodes that. Memoized per decoupler and keep-side; cleared each load_bp.
--
-- THE KEEP SIDE is the crew's (2026-10-26 playtest): the part the crew sits in
-- when they are aboard, else the command part. Control stays with the crew; a
-- piece that carries a command part of its own leaves as a craft you can
-- switch to (r2SplitCraft), anything else as debris.
function splitKeeper()
  if crewAboard and stationUid and bp_by_uid[stationUid] and not integ.gone[stationUid] then return stationUid end
  if pod_uid and bp_by_uid[pod_uid] and not integ.gone[pod_uid] then return pod_uid end
  return nil
end
-- Events ride away with the parts they act on: a decoupler, a fairing or a
-- booster branch in `dep` leaves with it; a chute event keeps the chutes still
-- aboard. Purely by tree membership.
function pruneEvents(dep)
  local keep = {}
  for _, e2 in ipairs(events) do
    if e2.kind == "axial" or e2.kind == "fairing" then
      if not dep[e2.uid] then keep[#keep + 1] = e2 end
    elseif e2.kind == "chute" then
      local us = {}
      for _, u in ipairs(e2.uids or {}) do if not dep[u] then us[#us + 1] = u end end
      if #us > 0 then e2.uids = us; keep[#keep + 1] = e2 end
    else
      local bs = {}
      for _, g in ipairs(e2.branches or {}) do if not dep[g.uid] then bs[#bs + 1] = g end end
      if #bs > 0 then e2.branches = bs; keep[#keep + 1] = e2 end
    end
  end
  events = keep
  if chutes then
    local kc = {}
    for _, c in ipairs(chutes) do if not dep[c.uid] then kc[#kc + 1] = c end end
    chutes = kc
  end
end
-- After a split: when the command part went with the other piece (the crew
-- sat elsewhere, a seat or a second pod), what stays is commanded from where
-- the crew sits, else the nearest command part still aboard.
function splitRecommand(dep)
  if not (pod_uid and dep[pod_uid]) then return end
  local best, rank = nil, nil
  if crewAboard and stationUid and bp_by_uid[stationUid] and not dep[stationUid] then best = bp_by_uid[stationUid] end
  if not best then
    for u, d in pairs(bp_by_uid) do
      if not dep[u] and not integ.gone[u] and (d.kind == "crewed" or d.kind == "probe") then
        local r = (d.kind == "crewed" and 0 or 1e7) + u
        if not rank or r < rank then best, rank = d, r end
      end
    end
  end
  if best then
    pod_uid = best.uid
    podCrewed = best.kind == "crewed"
    if not (crewAboard and stationUid and not dep[stationUid]) then
      pod = { x = best.x, y = best.y, z = best.z }
      podLX, podLY, podLZ = best.x, best.y, best.z
      focusHeight = best.y
      podSeat = podCrewed and (best.seat or 0) == 1
      stationUid = podCrewed and best.uid or nil
    end
  else
    pod_uid, podCrewed = nil, false
  end
  rescanSeats()
end
-- A piece's name: the craft's, then its command part ("Ascent · Mk1 Cockpit"),
-- else its biggest part ("Ascent · FT-M Tank").
function splitName(recs, node)
  local base = (craftName ~= "Vessel" and craftName) or (node and node.name) or "Craft"
  local E = elib()
  local cmd, big = nil, nil
  for _, r in ipairs(recs) do
    if E and E.modOf(r, "command") and (not cmd or (r.uid or 0) < (cmd.uid or 0)) then cmd = r end
    if not big or (r.mass or 0) > (big.mass or 0) then big = r end
  end
  local r = cmd or big
  return base .. " · " .. ((r and (r.label or r.id)) or "stage")
end
local function axial_departing(dec_uid)
  local keep = splitKeeper()
  local key = tostring(dec_uid) .. "/" .. tostring(keep) .. "/" .. tostring(integ.gen)
  local cached = axial_set_cache[key]
  if cached then return cached end
  local set = SPLIT.sides(bp_by_uid, bp_kids, dec_uid, keep, function(u) return not integ.gone[u] end)
  axial_set_cache[key] = set
  return set
end

-- Which live child node belongs to a departing axial cut: match the live child
-- (vessel-local coords ≈ blueprint coords) to its blueprint uid, then ask the
-- tree whether that uid is on the departing side.
local function child_departs_axial(child, dec_uid)
  local set = axial_departing(dec_uid)
  -- By entity first: a part an actuator has moved is not at its blueprint spot.
  local known = eid_uid[child.id]
  if known then return set[known] == true end
  for uid, q in pairs(bp_by_uid) do
    if math.abs((child.x or 0) - q.x) < 0.06 and math.abs((child.y or 0) - q.y) < 0.06
      and math.abs((child.z or 0) - q.z) < 0.06 then
      return set[uid] == true
    end
  end
  return false -- unmatched: keep it attached rather than eject a mystery part
end

-- Detaching a decoupler's whole subtree also gives away those tanks' share of
-- the pooled fuel and forgets those engines — decided by the departing SET
-- (tree membership), so branch (booster) engines/tanks leave exactly when their
-- subtree does, with no per-part y guessing.
--
-- `drop_set` is the one place a set of parts LEAVES this craft, whatever took
-- them (a decoupler, a booster ring, a joint that failed under load, a part
-- that broke): their engines and tanks leave the pools, and they are marked
-- GONE, which takes them out of every per-part pass — heating, smoke, hull
-- contact, the stress model. (Before, a staged-away part stayed in those passes
-- as a ghost at its old blueprint spot: a spent stage could still "burn up on
-- reentry" from inside the craft that had dropped it.)
local function drop_set(set)
  local keep_e, keep_t, cap = {}, {}, 0.0
  for _, e in ipairs(engines) do
    if not set[e.uid] then keep_e[#keep_e + 1] = e end
  end
  for _, t in ipairs(tanks) do
    if not set[t.uid] then
      keep_t[#keep_t + 1] = t
      cap = cap + t.fuel
    end
  end
  engines, tanks, fuel_cap = keep_e, keep_t, cap
  fuelSync()   -- departing tanks take exactly what is left in them
  for u in pairs(set) do
    integ.gone[u] = true
    part_hp[u] = nil
  end
  integ.gen = integ.gen + 1
end

-- ── PROPELLANT ──────────────────────────────────────────────────────────────
-- The pool is the sum of what every tank still holds (`t.left`), and it is
-- drunk from the tanks that will LEAVE SOONEST first: side boosters, then the
-- bottom stage, upward — `tanks` is kept in that order (fuelSort). So a stage
-- that separates dry throws away its empty tanks and nothing else, and its Δv
-- is what the builder quotes. Propellant has mass (`t.ft` tonnes per unit, from
-- the blueprint): each tank part's RigidBody carries what it still holds
-- (massSync), so the craft flies as heavy as the builder says and lightens as
-- it burns.
-- Globals, so fixedUpdate reaches them without spending an upvalue.
function fuelSort()
  table.sort(tanks, function(a, b)
    local ab, bb = a.branch and 0 or 1, b.branch and 0 or 1
    if ab ~= bb then return ab < bb end
    if math.abs(a.y - b.y) > 1e-3 then return a.y < b.y end
    return (a.uid or 0) < (b.uid or 0)
  end)
end

function fuelSync()
  local s = 0.0
  for _, t in ipairs(tanks) do s = s + (t.left or 0) end
  fuel = s
  return s
end

-- Draw `units` (tanks that leave soonest first). Returns what it got.
function fuelDraw(units)
  local need = units or 0
  for _, t in ipairs(tanks) do
    if need <= 0 then break end
    local l = t.left or 0
    if l > 0 then
      local take = math.min(l, need)
      t.left = l - take
      need = need - take
    end
  end
  fuelSync()
  return (units or 0) - math.max(0, need)
end

-- Set the pool to `total` units, filling the tanks that leave LAST first.
function fuelFill(total)
  local left = math.max(0, total or 0)
  for i = #tanks, 1, -1 do
    local t = tanks[i]
    local f = math.min(t.fuel or 0, left)
    t.left = f
    left = left - f
  end
  fuelSync()
end

-- Tonnes of propellant aboard.
function fuelMass()
  local m = 0.0
  for _, t in ipairs(tanks) do m = m + (t.left or 0) * (t.ft or 0) end
  return m
end

-- Tonnes of propellant in the tank part `uid` (0 for anything else).
function tankFuelT(uid)
  for _, t in ipairs(tanks) do
    if t.uid == uid then return (t.left or 0) * (t.ft or 0) end
  end
  return 0.0
end

-- Units still in tank part `uid`, or nil when it isn't a live tank.
function tankLeft(uid)
  for _, t in ipairs(tanks) do
    if t.uid == uid then return t.left or 0 end
  end
  return nil
end

-- THE CRAFT'S TRUE MASS: the blueprint's dry parts still aboard, plus what the
-- tanks hold, plus the hold's load (`holdT`, set by holdApplyMass). It is what
-- massSync gives the physics, part by part, so assembly.info(node).mass reads
-- the same number a tick later. Returns dry, wet (tonnes).
holdT = 0.0
function trueMass()
  local dry = 0.0
  for u, d in pairs(bp_by_uid or {}) do
    if not integ.gone[u] and (part_hp[u] or 1) > 0 then dry = dry + (d.mass or 0) end
  end
  dry = dry + (holdT or 0) + lockerT()
  return dry, dry + fuelMass()
end

-- Δv left, stage by stage, the way the builder quotes it: each remaining axial
-- stage burns its OWN tanks (they drain first) on its own engines, under
-- everything still above it; boosters ride with the bottom stage. True masses.
function stagedDv()
  local cuts = {}
  for _, ev in ipairs(events) do
    if ev.kind == "axial" then cuts[#cuts + 1] = ev.y end
  end
  table.sort(cuts)
  local total = 0.0
  for k = 0, #cuts do
    local lo = (k == 0) and -math.huge or cuts[k]
    local hi = cuts[k + 1] or math.huge
    local m0, own, th, burn = 0.0, 0.0, 0.0, 0.0
    for u, d in pairs(bp_by_uid or {}) do
      if not integ.gone[u] and (part_hp[u] or 1) > 0 and (d.y or 0) > lo + 0.01 then
        m0 = m0 + (d.mass or 0)
      end
    end
    for _, t in ipairs(tanks) do
      if t.y > lo + 0.01 then
        local f = (t.left or 0) * (t.ft or 0)
        m0 = m0 + f
        if t.y < hi - 0.01 or (k == 0 and t.branch) then own = own + f end
      end
    end
    for _, e in ipairs(engines) do
      if (e.y > lo + 0.01 and e.y < hi - 0.01) or (k == 0 and e.branch) then
        th, burn = th + e.thrust, burn + (e.burn or 0)
      end
    end
    if k == 0 then m0 = m0 + (holdT or 0) end
    local ft = 0.0
    for _, t in ipairs(tanks) do if (t.ft or 0) > 0 then ft = t.ft break end end
    if th > 0 and burn > 0 and ft > 0 and own > 0 and m0 > own then
      total = total + th / (burn * ft) * math.log(m0 / (m0 - own))
    end
  end
  return total
end

local function drop_departing(dec_uid)
  drop_set(axial_departing(dec_uid))
end

-- ── damage / destruction ────────────────────────────────────────────────────
-- `assembly.impacts()` reports how hard each PART hit something last tick
-- (the engine attributes every contact's impulse to the part that took it).
-- Tolerances are IMPACT SPEEDS (m/s), like KSP's crash tolerance: the felt
-- Δv is the impulse divided by the vessel's mass, so a 40-tonne ship and a
-- 4-tonne ship judge the same touchdown the same way (absolute impulse
-- thresholds made big ships shred themselves just settling on the pad).
-- Under ~half a part's tolerance a hit is just a landing; past that, damage
-- accumulates (the part smoulders); a full-tolerance blow — or worn-out HP
-- — BREAKS the part: explosion, the part shears off as wreckage, and losing
-- the pod loses the ship. Fuel tanks go up in a real BLAST (see break_part).
-- FRAGILE by design (Ty): a real spacecraft is delicate — a topple, a scrape,
-- a careless bump should HURT, not bounce off. These are low crash speeds, so
-- flying clean matters. Damage starts well under the tolerance (see damage_tick)
-- and a part that's already beaten up breaks far easier.
-- The ENGINE is the landing gear of every stack that comes down on its chutes:
-- the bell touches first. At 4.5 m/s the starter rocket's own textbook chute
-- landing (measured 5.1 m/s on engine 0.116) crushed the bell, and the bell's
-- blast took the tank and the pod with it. 7 m/s is a firm landing, still
-- well short of a drop.
-- The CREWED pod is built to come home: a real capsule shrugs off a 4.5 m/s
-- chute touchdown (First Flight's landing broke a 5 m/s pod and lost the
-- contract), so 9 m/s — still well short of a drop.
-- PROBE cores had no entry and fell to 5 m/s — and a ROVER BODY is a probe
-- core: a rover that drove off a 2 m ledge at 8 m/s landed its chassis at
-- 9–13 m/s of contact speed and burst. A probe core is a sealed box of
-- electronics (KSP's take 12–15 m/s); a rover chassis (a part that carries
-- the wheels, `front`) is built to be driven over rough ground (20).
local TOLERANCE = { crewed = 9, tank = 3.5, engine = 7.0, structural = 6, canvas = 2.5, probe = 12 }
local function part_tolerance(d)
  -- A wheel's tyre and suspension are made to take the ground (a rover set
  -- down off a lander, a drop off a ledge): like deployed legs, and more.
  if (d.wheel or "") ~= "" then return 20 end
  if (d.front or 0) == 1 then return 20 end
  if (d.legs or 0) == 1 then
    -- Legs exist to hit the ground — but only DEPLOYED ones absorb it.
    return gear_deployed and 9 or 3
  end
  return TOLERANCE[d.kind or "structural"] or 5
end
-- Damage stays DISARMED while clamped/assembling and for a settle window
-- after release — the pad handshake is not a crash.
local damage_arm = 0.0

-- The live child node (and blueprint uid) behind a reported part entity id.
-- The uid is resolved by NEAREST blueprint part (not an exact-pose match) and
-- CACHED: a part that's been knocked out of its authored pose used to miss the
-- old 0.05 threshold and silently drop its impact — so a deflected, grinding
-- or already-wounded part took no further damage. Nearest-match + cache fixes
-- that (the entity id is stable, so one resolve holds for the part's life).
-- The node's pose is read ONCE (each `c.x` is a read across the engine), and
-- the records are walked as an array snapshot taken in `pairs` order (so a
-- tie still goes to the same part). A 1,000-part rollout resolves every part
-- on its first tick: reading the pose inside the loop was 3 engine reads per
-- part per part, 3 million, ~600 ms in one frame (perfbench g_launch_rollout).
-- The snapshot is also binned on a UID_CELL grid: a part within one cell of
-- the node is provably the nearest of all (anything outside the 27 cells round
-- it is at least a cell away), so the whole list is only walked for a part
-- that has wandered further than that from every record.
UID_SNAP = { src = nil, gen = -1, u = {}, d = {}, grid = {} }
UID_CELL = 0.25
function uidCellKey(ix, iy, iz) return ((ix + 200000) * 400000 + (iy + 200000)) * 400000 + (iz + 200000) end
-- The snapshot, fresh for this part set.
local function uid_snap()
  local S = UID_SNAP
  if S.src ~= bp_by_uid or S.gen ~= integ.gen then
    local h = UID_CELL
    local us, ds, grid, n = {}, {}, {}, 0
    for u, d in pairs(bp_by_uid) do
      n = n + 1
      us[n], ds[n] = u, d
      local k = uidCellKey(math.floor(d.x / h), math.floor(d.y / h), math.floor(d.z / h))
      local l = grid[k]
      if not l then l = {}; grid[k] = l end
      l[#l + 1] = n
    end
    S.src, S.gen, S.u, S.d, S.grid = bp_by_uid, integ.gen, us, ds, grid
  end
  return S
end
-- The first record (in `pairs` order) still aboard within `tol` (≤ UID_CELL / 2)
-- of a vessel-frame point on every axis: what a walk of bp_by_uid that breaks
-- on the first such record finds.
function uidNear(px, py, pz, tol)
  local S, h = uid_snap(), UID_CELL
  local best = nil
  for ix = math.floor((px - tol) / h), math.floor((px + tol) / h) do
    for iy = math.floor((py - tol) / h), math.floor((py + tol) / h) do
      for iz = math.floor((pz - tol) / h), math.floor((pz + tol) / h) do
        local l = S.grid[uidCellKey(ix, iy, iz)]
        if l then
          for _, i in ipairs(l) do
            local d = S.d[i]
            if (not best or i < best) and not integ.gone[S.u[i]] and math.abs(px - d.x) < tol
              and math.abs(py - d.y) < tol and math.abs(pz - d.z) < tol then
              best = i
            end
          end
        end
      end
    end
  end
  return best and S.u[best] or nil
end
local function uid_of_node(c)
  local eid = c.id
  local uid = eid_uid[eid]
  if not uid then
    local S = uid_snap()
    local h = UID_CELL
    local cx, cy, cz = c.x or 0, c.y or 0, c.z or 0
    local us, ds = S.u, S.d
    local best, bd, bi = nil, 1e9, nil
    -- the 27 cells round the node, in snapshot order (so a tie goes the same way)
    local ix, iy, iz = math.floor(cx / h), math.floor(cy / h), math.floor(cz / h)
    local near = nil
    for ox = -1, 1 do
      for oy = -1, 1 do
        for oz = -1, 1 do
          local l = S.grid[uidCellKey(ix + ox, iy + oy, iz + oz)]
          if l then
            for _, i in ipairs(l) do
              local d = ds[i]
              local dx, dy, dz = cx - d.x, cy - d.y, cz - d.z
              local dd = dx * dx + dy * dy + dz * dz
              if dd < bd or (dd == bd and bi and i < bi) then bd, best, bi = dd, us[i], i end
            end
            near = true
          end
        end
      end
    end
    if not (near and bd < h * h) then
      best, bd = nil, 1e9
      for i = 1, #us do
        local d = ds[i]
        local dx, dy, dz = cx - d.x, cy - d.y, cz - d.z
        local dd = dx * dx + dy * dy + dz * dz
        if dd < bd then bd, best = dd, us[i] end
      end
    end
    uid = best
    eid_uid[eid] = uid
  end
  return uid
end

-- `kids` (optional): the node's children by entity id, made once by a caller
-- that resolves many contacts in one tick — `node:children()` makes a handle
-- per part, and a 1,000-part craft resting or grinding on the ground
-- reports hundreds of contacts a tick.
-- The map is kept per part set, and remade when a contact names a part it
-- does not have (a part that arrived since).
-- (at most once a tick: a contact on something that is not a part — a tyre
-- hangs off as a body of its own — must not remake it per contact)
KIDS_BY = { gen = -1, id = nil, map = nil, t = nil }
function kidsById(node, fresh)
  local K = KIDS_BY
  if (fresh and K.t ~= time) or not K.map or K.gen ~= integ.gen or K.id ~= node.id then
    local m = {}
    for _, c in ipairs(node:children()) do m[c.id] = c end
    K.gen, K.id, K.map, K.t = integ.gen, node.id, m, time
  end
  return K.map
end
local function uid_of_child(node, eid, kids)
  if kids then
    local c = kids[eid]
    if not (c and c.valid ~= false) then c = kidsById(node, true)[eid] end
    if c then
      local uid = uid_of_node(c)
      if uid then return uid, c end
    end
    return nil
  end
  for _, c in ipairs(node:children()) do
    if c.id == eid then
      local uid = uid_of_node(c)
      if uid then return uid, c end
    end
  end
  return nil
end

-- THE CRAFT WEIGHS WHAT IT CARRIES (floptle/0406: `rb.mass` is live). Each
-- part's RigidBody is given its blueprint dry mass, plus the propellant its
-- tank still holds, plus its share of the hold's cargo (`holdT`); the engine
-- re-derives the compound's mass, centre of mass and inertia on the next tick,
-- with no rebuild and no kick. So thrust, RCS, drag, contacts and torques all
-- act on the craft the builder quoted, lightening as it burns. A part's mass is
-- written only when it moves (a tank that is burning, a hold that was loaded);
-- the part list is re-read when the craft changes (its part set, or the count
-- of parts in its compound), and every 10 s besides (it was every second: a
-- 13 ms read of every part at 1,000 parts, perfbench g_launch_pad). A big
-- craft's parts arrive over several frames: each weighs what it carries the
-- tick its compound counts it.
local mass_sync = { gen = -1, t = -10.0, list = {}, bays = 0, last = {}, np = -1 }
function massSync(node, info)
  local ms = mass_sync
  local np = info and info.parts and #info.parts or ms.np
  if ms.gen ~= integ.gen or time - ms.t >= 10.0 or np ~= ms.np then
    ms.gen, ms.t, ms.np = integ.gen, time, np
    local list, bays = {}, 0
    for _, c in ipairs(node:children()) do
      -- parts only (a part node carries its prefab's name): never a passenger
      local nm = c.name or ""
      local u = nm:sub(1, 4) == "Part" and uid_of_node(c)
      local d = u and bp_by_uid[u]
      local rb = d and not integ.gone[u] and c:getcomponent("RigidBody")
      if rb then
        list[#list + 1] = { rb = rb, uid = u, d = d, eid = c.id }
        if (d.cargo or 0) > 0 then bays = bays + 1 end
      end
    end
    ms.list, ms.bays = list, bays
  end
  local share = (ms.bays > 0) and (holdT or 0) / ms.bays or 0.0
  local total = 0.0
  -- Each part's propellant by uid, from one pass over the tanks. tankFuelT
  -- scans every tank for every part, every tick: parts × tanks (perfbench:
  -- 1,000 parts, 40 tanks — massSync led vessel_controller on the pad).
  local fuel_t = ms.fuel_t or {}
  ms.fuel_t = fuel_t
  for k in pairs(fuel_t) do fuel_t[k] = nil end
  for _, t in ipairs(tanks) do
    if t.uid and fuel_t[t.uid] == nil then fuel_t[t.uid] = (t.left or 0) * (t.ft or 0) end
  end
  for _, e in ipairs(ms.list) do
    local d = e.d
    local m = math.max(0.001, (d.mass or 0) + (fuel_t[e.uid] or 0.0)
      + (((d.cargo or 0) > 0) and share or 0.0) + (LOCKER_T[e.uid] or 0.0))
    -- a powered wheel whose tyre is out: the tyre body carries its share
    if R2.live and (d.wheel or "") ~= "" then m = math.max(0.001, m * (1 - TYRE_SHARE)) end
    local was = ms.last[e.eid]
    if not was or math.abs(m - was) > 1e-6 then
      e.rb.mass = m
      ms.last[e.eid] = m
    end
    total = total + m
  end
  -- A craft restored in flight (fleet handoff `vel`): pushed to its orbital
  -- velocity the first tick its compound weighs what the parts now say, so
  -- the push is the right size and lands through the right centre of mass.
  local push = integ.push
  if push and #ms.list > 0 then
    local i = assembly.info(node)
    if i and (i.mass or 0) > 0 and math.abs(i.mass - total) < 1e-3 * math.max(1, total) then
      integ.push = nil
      local v0, c = i.vel, i.com or i.origin
      assembly.impulseAt(node, vec3((push.x - v0.x) * i.mass, (push.y - v0.y) * i.mass,
        (push.z - v0.z) * i.mass), c)
      integ.handoff_t = time + 1.0 -- (the safety net reads the jump a tick late)
      log(string.format("vessel: back on its orbit at %.1f m/s", math.sqrt(push.x ^ 2 + push.y ^ 2 + push.z ^ 2)))
    end
  end
end

-- Push a part's visible battle damage to its hull shader (the `damage` uniform
-- on hullPanels.flsl: 0 pristine … 1 wrecked — scorch, gouges, dents). Driven
-- straight off the part's remaining HP so the hull visibly deteriorates as you
-- scrape and crash it, exactly what Ty couldn't see before.
local diag_dmg_logged = false
-- (every mesh-child name tools/gen_part_meshes.py writes under a bare collider
-- root: a part whose mesh child is missing here gets setShaderParam on that
-- root, which the engine answers with "has no Material … nothing for it to
-- drive" and the part never shows its wear. A root with its own mesh, like
-- the landing legs, is painted as a whole below.)
MESH_KIDS = { Body = true, Mount = true, Tyre = true, Base = true, Head = true, Stage = true,
              Hub = true, Fingers = true, Housing = true, Bit = true, Panel = true, Flap = true,
              Leg = true, Blade = true, SolarYoke = true, SolarWing = true }
local function set_part_damage(c, hp)
  if c and c.valid then
    local dmg = 1.0 - math.max(0.0, math.min(1.0, hp or 1.0))
    -- Parts wearing the hullPanels shader take the uniform. The textured
    -- parts (tools/gen_part_meshes.py) have NO node Material — their look is
    -- per-part `object_materials`, all on hullPanels.flsl now — and
    -- node:material() RAISES on such a node, which took this whole controller
    -- down on the first scrape. So: ask for the component first; a part
    -- without one gets the `damage` param through setShaderParam (which fans
    -- out to every child's materials: scorch, gouges, dents), and a soot TINT
    -- only when that call isn't there or fails.
    -- Round-two parts carry their meshes as named children (the root is the
    -- collider): the wear goes on those.
    local kids = nil
    for _, k in ipairs(c.children and c:children() or {}) do
      if MESH_KIDS[k.name or ""] then kids = kids or {}; kids[#kids + 1] = k end
    end
    if kids then
      for _, k in ipairs(kids) do pcall(k.setShaderParam, k, "damage", dmg) end
      return
    end
    local getc = c.getcomponent or c.getComponent
    local has_mat = false
    if getc then
      local okc, comp = pcall(getc, c, "Material")
      has_mat = okc and comp ~= nil
    end
    local own = nil
    if has_mat and c.material then
      local okm, m = pcall(c.material, c)
      own = okm and m or nil
    end
    local painted = false
    if own and own.shader and own.shader ~= "" then
      pcall(c.setShaderParam, c, "damage", dmg)
      painted = true
    elseif not has_mat and c.setShaderParam then
      painted = pcall(c.setShaderParam, c, "damage", dmg)
    end
    if painted then
      -- (the shader draws the wear; no tint on top)
    elseif c.setTint and dmg > 0.02 then
      local v = math.sqrt(dmg)
      pcall(c.setTint, c, { 1 - 0.55 * v, 1 - 0.6 * v, 1 - 0.64 * v })
    elseif c.setTint then
      pcall(c.setTint, c)
    end
    if not diag_dmg_logged and dmg > 0.05 then
      diag_dmg_logged = true
      log(string.format(
        "DMG DIAG: painting damage=%.2f on %s — if the hull shows no scorch/" ..
        "scratches, the material's `damage` uniform isn't reaching the shader.",
        dmg, c.name or "part"))
    end
  end
end

-- Published for tests/smoke_part_damage.lua: paint a part's wear by hand.
function paintDamage(c, hp) set_part_damage(c, hp) end

-- The live child node for a blueprint uid (position match) — used to paint
-- damage on parts wounded by a chain reaction they weren't directly hit by.
-- The children are read ONCE a tick (per part set) into a snapshot binned on
-- a 0.12 m grid, and the answer is still the FIRST child, in the engine's
-- order, inside the 6 cm box: walking `node:children()` per call made a
-- handle and three engine reads per part, per part asked about, and shedding
-- 976 parts at once asked about all of them (perfbench g_launch_release: a
-- 1.1 s frame).
CHILD_SNAP = { t = nil, gen = -1, id = nil, n = 0, kids = nil, x = nil, y = nil, z = nil, grid = nil }
CHILD_CELL = 0.12
-- The first child (engine order) within `tol` (≤ CHILD_CELL / 2) of a
-- vessel-frame point on every axis, or nil.
function childNear(node, px, py, pz, tol)
  local S, h = CHILD_SNAP, CHILD_CELL
  if S.t ~= time or S.gen ~= integ.gen or S.id ~= node.id then
    local kids = node:children()
    local xs, ys, zs, grid = {}, {}, {}, {}
    for i, c in ipairs(kids) do
      local x, y, z = c.x or 0, c.y or 0, c.z or 0
      xs[i], ys[i], zs[i] = x, y, z
      local k = uidCellKey(math.floor(x / h), math.floor(y / h), math.floor(z / h))
      local l = grid[k]
      if not l then l = {}; grid[k] = l end
      l[#l + 1] = i
    end
    S.t, S.gen, S.id, S.kids, S.x, S.y, S.z, S.grid = time, integ.gen, node.id, kids, xs, ys, zs, grid
  end
  local best = nil
  local x0, x1 = math.floor((px - tol) / h), math.floor((px + tol) / h)
  local y0, y1 = math.floor((py - tol) / h), math.floor((py + tol) / h)
  local z0, z1 = math.floor((pz - tol) / h), math.floor((pz + tol) / h)
  for ix = x0, x1 do
    for iy = y0, y1 do
      for iz = z0, z1 do
        local l = S.grid[uidCellKey(ix, iy, iz)]
        if l then
          for _, i in ipairs(l) do
            if (not best or i < best) and math.abs(S.x[i] - px) < tol and math.abs(S.y[i] - py) < tol
              and math.abs(S.z[i] - pz) < tol and S.kids[i].valid ~= false then
              best = i
            end
          end
        end
      end
    end
  end
  return best and S.kids[best] or nil
end
local function child_of_uid(node, uid)
  local d = bp_by_uid[uid]
  if not d then return nil end
  local known = R2 and R2.node[uid]
  if known and known.valid then return known end
  return childNear(node, d.x, d.y, d.z, 0.06)
end

-- A destroyed part's engines/tanks leave the pools (its fuel share with it).
local function drop_part(uid)
  local keep_e, keep_t, cap = {}, {}, 0.0
  for _, e in ipairs(engines) do
    if e.uid ~= uid then keep_e[#keep_e + 1] = e end
  end
  for _, t in ipairs(tanks) do
    if t.uid ~= uid then
      keep_t[#keep_t + 1] = t
      cap = cap + t.fuel
    end
  end
  engines, tanks, fuel_cap = keep_e, keep_t, cap
  fuelSync()
end

-- ══ ELECTRONICS ══════════════════════════════════════════════════════════════
--
-- Everything electrical about this craft, by its parts' MODULES
-- (scripts/electronics.lua holds the rules; this is where they meet the hull):
--
--   devices   every folding part eases toward its own `st.deployed`, lights
--             follow `st.lit` (update_peripherals)
--   power     supply (sunlit panels, running engines' alternators), storage
--             (each battery's own charge in `st.charge`) and loads (command
--             parts, reaction wheels by how hard they are working, radios,
--             lights), stepped at 10 Hz (power_tick)
--   comms     what our antennas add up to, handed to the network
--             (scripts/comms.lua), and the path home it hands back
--   control   who may fly this: the crew if they are aboard; a probe core only
--             with power AND a link home (controlTick)
--   actions   every part action and the action groups that fire them
--             (partAction, fireGroup, groupKeysTick)
--
-- All of it is reached from fixedUpdate through globals or the `elec` table:
-- that function sits at LuaJIT's 60-upvalue ceiling.

-- The rulebook, resolved once (nil in a harness without it — the craft then
-- flies the way it did before electronics: always powered, always in contact).
-- (A global, not a local: load_bp, far above, asks for it too.)
local elib_ref = nil
function elib()
  if not elib_ref or not elib_ref.valid then
    elib_ref = findScript and findScript("electronics") or nil
  end
  return elib_ref
end

-- A table of the rulebook's functions in front of its script handle: the same
-- functions, fetched once (a field that is not a function still reads through).
-- Within one pass a part's modules can't change, so they are looked up once
-- a part (modOf as the rulebook's: the first module of that type).
function elecFns(E)
  local modsOf, memo = E.modsOf, {}
  local function mods(rec)
    local v = memo[rec]
    if v == nil then v = modsOf(rec); memo[rec] = v end
    return v
  end
  local function modOf(rec, ty)
    for _, m in ipairs(mods(rec)) do if m.type == ty then return m end end
    return nil
  end
  return setmetatable({ modOf = modOf, modsOf = mods, stateOf = E.stateOf }, { __index = E })
end

-- The comms network (scripts/comms.lua), resolved once.
local comms_ref = nil
local function comms_net()
  if not comms_ref or not comms_ref.valid then
    comms_ref = findScript and findScript("comms") or nil
  end
  return comms_ref
end

-- Is this part still aboard and in one piece?
local function aboard(uid)
  return bp_by_uid[uid] ~= nil and not integ.gone[uid] and (part_hp[uid] or 1) > 0
end

-- The craft's parts that are still aboard, uid → record (what every electronics
-- question is asked about).
function aboardRecs()
  local out = {}
  for u, d in pairs(bp_by_uid) do
    if aboard(u) then out[u] = d end
  end
  return out
end

-- Re-sort the parts into device sets and electrical roles. Cheap; run whenever
-- the part list changes (rollout, docking, undocking, staging, breakage).
function elecRescan()
  local E = elib()
  -- (the rulebook's functions fetched once a pass: each `E.x` through the
  -- script handle is a call into the engine, ~0.4 µs, ten a part)
  if E then E = elecFns(E) end
  elec.parts = {}       -- uids with any electrical module
  elec.crewPart, elec.probePart = nil, nil
  for _, dev in pairs(DEVICES) do dev.parts = {} end
  local list = {}
  for u, d in pairs(bp_by_uid) do list[#list + 1] = d end
  table.sort(list, function(a, b) return (a.uid or 0) < (b.uid or 0) end)
  for _, d in ipairs(list) do
    local u = d.uid
    if aboard(u) then
      for _, dev in pairs(DEVICES) do
        if dev.detect(d, E) then dev.parts[#dev.parts + 1] = u end
      end
      if E then
        E.stateOf(d)
        for _, m in ipairs(E.modsOf(d)) do
          if m.type == "command" then
            if (m.crew or 0) > 0 then elec.crewPart = elec.crewPart or u
            else elec.probePart = elec.probePart or u end
          end
        end
        if #E.modsOf(d) > 0 then elec.parts[#elec.parts + 1] = u end
        local dm = E.modOf(d, "deploy")
        if panim[u] == nil then panim[u] = (dm and d.st and d.st.deployed) and 1.0 or 0.0 end
      elseif d.kind == "crewed" then
        elec.crewPart = elec.crewPart or u
      end
    end
  end
  elec.gen_seen = integ.gen
  -- A device kind is "on" when most of its parts are (without the rulebook the
  -- parts carry no state and the kind's own switch stands).
  for id, dev in pairs(DEVICES) do
    if E and id ~= "rcs" and dev.state and #dev.parts > 0 then
      local on = 0
      for _, u in ipairs(dev.parts) do
        local st = bp_by_uid[u] and bp_by_uid[u].st
        if st and st[dev.state] then on = on + 1 end
      end
      dev.on = on * 2 >= #dev.parts
    end
  end
end

-- The authored frame of a part turned toward `a` (vessel frame, unit) by up to
-- 80°, eased by f. Returns the YXZ Euler angles a child node takes.
function aim_euler(pose, a, f)
  local cy, sy = math.cos(pose.yaw or 0), math.sin(pose.yaw or 0)
  local cx, sx = math.cos(pose.pitch or 0), math.sin(pose.pitch or 0)
  local cz, sz = math.cos(pose.roll or 0), math.sin(pose.roll or 0)
  local X = { cy * cz + sy * sx * sz, cx * sz, -sy * cz + cy * sx * sz }
  local Y = { -cy * sz + sy * sx * cz, cx * cz, sy * sz + cy * sx * cz }
  local Z = { sy * cx, -sx, cy * cx }
  local kx, ky, kz = cross(Y[1], Y[2], Y[3], a.x, a.y, a.z)
  local s = math.sqrt(kx * kx + ky * ky + kz * kz)
  local c = Y[1] * a.x + Y[2] * a.y + Y[3] * a.z
  if s > 1e-6 then
    local th = math.min(math.atan2(s, c), math.rad(80)) * f
    kx, ky, kz = kx / s, ky / s, kz / s
    local ct, st = math.cos(th), math.sin(th)
    local function rot(v)
      local d = kx * v[1] + ky * v[2] + kz * v[3]
      local qx, qy, qz = cross(kx, ky, kz, v[1], v[2], v[3])
      return { v[1] * ct + qx * st + kx * d * (1 - ct), v[2] * ct + qy * st + ky * d * (1 - ct),
               v[3] * ct + qz * st + kz * d * (1 - ct) }
    end
    X, Y, Z = rot(X), rot(Y), rot(Z)
  end
  local pitch = math.asin(math.max(-1, math.min(1, -Z[2])))
  return math.atan2(Z[1], Z[3]), pitch, math.atan2(X[2], Y[2])
end

-- Per-tick actuation: ease every folding part toward its own state and pose
-- its live child (legs fold, panels unfold, whips telescope, dishes swing onto
-- their link); lamps follow their switch (and go dark with no power). VISUAL
-- only — a leg's COLLISION is a stable always-on footprint box on PartLegs (a
-- fold-tracking collider made a gear-up craft slide; see the history in git).
local function update_peripherals(node, dt)
  local E = elib()
  if (elec.gen_seen or -1) ~= integ.gen then elecRescan() end
  local function child_for(uid, d)
    local ch = pnode[uid]
    if ch and ch.valid then return ch end
    ch = R2 and R2.node[uid]
    if ch and ch.valid then pnode[uid] = ch return ch end
    ch = nil
    for _, c in ipairs(node:children()) do
      if math.abs((c.x or 0) - d.x) < 0.05 and math.abs((c.z or 0) - d.z) < 0.05
        and math.abs((c.y or 0) - d.y) < 0.45 then
        ch = c
        break
      end
    end
    pnode[uid] = ch
    return ch
  end
  for id, dev in pairs(DEVICES) do
    local maxa = 0
    if id ~= "rcs" then
      for _, uid in ipairs(dev.parts) do
        local d = bp_by_uid[uid]
        if d then
          -- the part's own switch; a part that has none follows its kind's
          local st = d.st or {}
          local on = st[dev.state]
          if on == nil then on = dev.on end
          if id == "lights" then
            local lit = on == true and (elec.served == nil or (elec.served[uid] or 1) > 0.5)
            local ch = child_for(uid, d)
            if ch then
              local lamp = ppose[uid]
              if lamp == nil then
                lamp = false
                for _, c in ipairs(ch:children()) do if c.name == "Lamp" then lamp = c end end
                ppose[uid] = lamp
              end
              if lamp and lamp.valid then
                local l = lamp:getcomponent("PointLight")
                if l then
                  local want = lit and 2.6 or 0.0
                  if math.abs((l.intensity or 0) - want) > 0.01 then l.intensity = want end
                end
              end
            end
            panim[uid] = lit and 1.0 or 0.0
          else
            local target = on and 1.0 or 0.0
            local a = panim[uid] or target
            local moved = a ~= target
            if moved then
              local step = dev.speed * dt
              a = (a < target) and math.min(target, a + step) or math.max(target, a - step)
              panim[uid] = a
            end
            local m = E and E.modOf(d, "deploy")
            local kind = (m and m.anim) or (id == "gear" and "legs") or (id == "solar" and "solar") or "dish"
            local ch = child_for(uid, d)
            if ch then
              local pose = ppose[uid]
              if not pose then
                pose = { x = ch.x, y = ch.y, z = ch.z, sy = ch.scale_y or 1.0, sx = ch.scale_x or 1.0,
                         pitch = ch.pitch or 0, roll = ch.roll or 0, yaw = ch.yaw or 0, h = d.h }
                ppose[uid] = pose
                moved = true
              end
              -- a dish re-poses when its target moves; everything else only while it folds
              local aim = (kind == "dish") and elec.aim or nil
              if aim ~= pose.aim then pose.aim = aim; moved = true end
              if moved or pose.applied ~= a then
                pose.applied = a
                local fn = ANIMS[kind]
                if fn then fn(ch, pose, a) end
              end
            end
          end
          if (panim[uid] or 0) > maxa then maxa = panim[uid] end
        end
      end
      dev.anim = maxa
    end
  end
  gear_deployed = DEVICES.gear.on
end

-- One part action, by id (electronics actionsOf: "deployed.on", "decouple",
-- "lit.toggle" …). `force` sets a toggle rather than flipping it (a group
-- toggled as one). Returns true if it did something.
function partAction(uid, act_id, force, amount)
  local E = elib()
  local d = bp_by_uid[uid]
  if not (E and d and aboard(uid)) then return false end
  local act = type(act_id) == "table" and act_id or E.actionOf(d, act_id)
  if not act then return false end
  local st = E.stateOf(d)
  if act.kind == "trigger" then
    if act.id == "decouple" then return fireSeparation(uid) end
    if act.id == "chute" then return fireSeparation(uid) end
    if act.id == "cutChute" then
      if chutes_deployed then cutChutes() return true end
      return false
    end
    if act.id == "undock" then return undock(uid) end
    if act.id == "jettison" then return fireSeparation(uid) end
    if act.id == "release" then return r2ClawRelease(uid) end
    return false
  end
  -- An AXIS (an actuator's setpoint) moves while its key is HELD, by the
  -- `amount` the hold gives (rate × tick: groupKeysTick); a press on its own
  -- only does `.center`.
  if act.kind == "axis" then
    if act.dir ~= 0 and not amount then return false end
    local _, ch = E.applyAction(st, act, nil, act.dir ~= 0 and amount or nil)
    if ch and act.axis == "extension" then st.extended = (st.extension or 0) > 0.4 end
    return true
  end
  local was = act.state and st[act.state]
  local v, changed = E.applyAction(st, act, force, 1.0)
  if act.state == "extended" and changed then
    -- Extend / Retract run the piston to its end stop.
    local m = E.modOf(d, "piston")
    st.extension = v and 0.8 or 0.0
  end
  if act.state == "armed" and changed and v == false then r2ClawRelease(uid) end
  if act.state == "running" and changed then
    -- An engine switched ON by hand runs whatever the staging says; one
    -- switched OFF stays off until switched on again.
    st.forced = v == true
  end
  if changed then elecRescanDevices() end
  return changed or was == v
end

-- A device set's `on` follows its parts (cheap; after any action).
function elecRescanDevices()
  for id, dev in pairs(DEVICES) do
    if id ~= "rcs" and dev.state and #dev.parts > 0 then
      local on = 0
      for _, u in ipairs(dev.parts) do
        local st = bp_by_uid[u] and bp_by_uid[u].st
        if st and st[dev.state] then on = on + 1 end
      end
      dev.on = on * 2 >= #dev.parts
    end
  end
  gear_deployed = DEVICES.gear.on
end

-- Fire the separation event a decoupler / chute part belongs to, out of the
-- staging order: the event moves to the front of the stack and fires, exactly
-- as SPACE would have fired it. Nothing about staging is locked.
function fireSeparation(uid)
  for i, ev in ipairs(events) do
    local mine = false
    if ev.kind == "axial" or ev.kind == "fairing" then mine = ev.uid == uid
    elseif ev.kind == "chute" then
      for _, u in ipairs(ev.uids or {}) do if u == uid then mine = true end end
    elseif ev.kind == "ring" then
      for _, g in ipairs(ev.branches or {}) do if g.uid == uid then mine = true end end
    end
    if mine then
      -- just this event (not the rest of its stage), as SPACE would fire it
      local node = dock.node
      if destroyed or not node or not node.valid then return false end
      local info = assembly.info(node)
      if not info or info.anchored then return false end
      table.remove(events, i)
      if ev.kind ~= "chute" and ev.kind ~= "fairing" then r2Before(node) end
      return fireEvent(node, info, ev)
    end
  end
  return false
end

-- THE CONTROLS RULEBOOK (scripts/controls.lua): key groups on any free key,
-- and AXES — pitch, yaw, roll, throttle, steer, drive or custom key pairs
-- driving actuator setpoints with gain and trim. Spawned (ControlsLib) when
-- the scene has no node running it, as aeroLib does.
ctlAxes = nil
ctlAxesData = nil
local clib_ref = { lib = nil, asked = false }
function clib()
  local C = clib_ref.lib
  if C and C.valid then return C end
  C = findScript and findScript("controls") or nil
  -- (a just-spawned ControlsLib is found a frame before its chunk has run)
  if C and type(C.live) ~= "function" then return nil end
  if not C and not clib_ref.asked and spawn then
    clib_ref.asked = true
    pcall(spawn, "ControlsLib", vec3(0, 0, 0))
  end
  clib_ref.lib = C
  if C and not ctlAxes and ctlAxesData then ctlAxes = C.live(ctlAxesData) end
  return C
end

-- The Controls card (flight_hud, O): keys with their lamps, axes with tapes.
function controlsCard()
  local E, C = elib(), clib()
  if not (E and C) then return nil end
  return C.card(ctlGroups, ctlAxes, aboardRecs(), E)
end

-- How many custom controls this craft has (the first-flight toast).
function controlsCustomCount()
  local E, C = elib(), clib()
  if not (E and C) then return 0 end
  return C.customCount(ctlGroups, ctlAxes, E)
end

-- THE ACTION GROUPS this craft flies with (gid → { name, binds, on }).
-- From the blueprint if the player edited them, else the standard set.
ctlGroups = {}

function groupsReset(packed, controls)
  local E = elib()
  -- the craft's AXES (WP5, scripts/controls.lua): none on an old craft
  -- (kept packed too: the ControlsLib may land a frame after the craft)
  local C = clib()
  ctlAxesData = controls
  ctlAxes = C and C.live(controls) or nil
  if not E then ctlGroups = {} return end
  if packed then
    ctlGroups = E.unpackGroups(packed)
  else
    ctlGroups = E.defaultGroups(aboardRecs())
  end
end

-- Fire one group: every bound action, toggles moving as one. Returns the count.
function fireGroup(gid)
  local E = elib()
  if not E then return 0 end
  local n = E.fireGroup(ctlGroups, gid, aboardRecs(), function(uid, act, force)
    return partAction(uid, act, force)
  end)
  return n
end

-- The groups for the HUD strip: { id, key, label, n, on } for every group with
-- anything in it (the standard ones that act by themselves — SAS, RCS, Abort —
-- always).
function groupStrip()
  local E = elib()
  if not E then return {} end
  local recs = aboardRecs()
  E.pruneGroups(ctlGroups, recs)
  local out = {}
  for _, g in ipairs(E.groupList()) do
    local gg = ctlGroups[g.id]
    local n = gg and #gg.binds or 0
    if n > 0 then
      out[#out + 1] = { id = g.id, key = g.key, label = (gg and gg.name) or g.label, n = n,
                        on = E.groupState(ctlGroups, g.id, recs), standard = g.standard }
    end
  end
  -- key groups on any other key (controls.lua "k:<key>")
  local C = clib()
  for _, g in ipairs(C and C.extraGroups(ctlGroups) or {}) do
    out[#out + 1] = { id = g.id, key = g.key, label = g.label, n = #ctlGroups[g.id].binds,
                      on = E.groupState(ctlGroups, g.id, recs), cap = C.keyLabel(g.key) }
  end
  return out
end

-- THE KEYS. Each group's key fires it; SAS (T) and RCS (R) are also the
-- autopilot and thruster MASTER switches, as they always were; Abort
-- (Backspace) cuts the throttle and then fires whatever you put in it. ALT+1…9
-- pick an autopilot hold (the numbers themselves are the custom groups, as in
-- KSP). The digits stand down while the map is open (they toggle its layers),
-- and Backspace while a burn is being planned (it deletes the burn).
local DIGIT = { ["1"] = true, ["2"] = true, ["3"] = true, ["4"] = true, ["5"] = true,
                ["6"] = true, ["7"] = true, ["8"] = true, ["9"] = true, ["0"] = true }
function groupKeysTick(node, info)
  local E = elib()
  local alt = input.key("alt")
  if alt and not dock.map then
    for k, m in pairs(SAS_KEYS) do
      if input.pressed(k) and elec.control ~= false then setSAS(m) end
    end
  end
  local list = E and E.groupList() or {
    { id = "gear", key = "g" }, { id = "deploy", key = "u" }, { id = "rcs", key = "r" }, { id = "sas", key = "t" } }
  for _, g in ipairs(list) do
    local k = g.key
    local skip = (DIGIT[k] and (dock.map or alt)) or (k == "backspace" and dock.plan)
    if not skip and input.pressed(k) then activateGroup(g.id) end
    -- Actuator setpoints ride a HELD key: angle, extension, rotor speed.
    if not skip and E and input.key(k) and elec.control ~= false then holdGroupAxes(g.id, node) end
  end
  controlsTick(node)
end

-- WP5: the key groups on any other key, then the AXES — every tick, the
-- craft's axis bindings turn the stick and the custom key pairs into actuator
-- setpoints (controls.evaluate), written into the parts' state the way
-- partAction does (controls.apply); robo_tick then drives the joints there.
-- Nothing answers without control, or while the map is open (its keys).
function controlsTick(node)
  local E, C = elib(), clib()
  if not (E and C) or dock.map then return end
  for _, g in ipairs(C.extraGroups(ctlGroups)) do
    if input.pressed(g.key) then activateGroup(g.id) end
    if input.key(g.key) and elec.control ~= false then holdGroupAxes(g.id, node) end
  end
  if ctlAxes and #ctlAxes.axes > 0 and elec.control ~= false and not dock.plan and not destroyed then
    local recs = aboardRecs()
    local inp = C.readInputs(ctlAxes, input.key, input.pressed, { throttle = throttle })
    -- a headless run cannot press keys: a probe sets CTL_PROBE = { src = value }
    if CTL_PROBE then for k, v in pairs(CTL_PROBE) do inp[k] = v end end
    C.apply(C.evaluate(ctlAxes, inp, recs, 1.0 / 60.0, E), recs, E)
  end
end

-- Every axis action bound to a group, moved by one tick of its rate (the key
-- is held). Toggles and triggers fire on the press (activateGroup).
function holdGroupAxes(gid, node)
  local E = elib()
  local g = ctlGroups[gid]
  if not (E and g and #g.binds > 0) then return end
  local dt = 1.0 / 60.0
  for _, b in ipairs(g.binds) do
    local d = bp_by_uid[b.uid]
    local act = d and E.actionOf(d, b.act)
    if act and act.kind == "axis" and act.dir ~= 0 then
      partAction(b.uid, act, nil, (act.rate or 1) * dt)
    end
  end
end

-- Fire one group as its key would: the masters first (SAS, RCS, abort's
-- throttle cut), then everything bound to it. The HUD's group rows call this
-- too. Refused, and said, with no control.
function activateGroup(gid)
  local E = elib()
  local node = dock.node
  if destroyed or not (node and node.valid) then return false end
  if elec.control == false then
    caption("no control — " .. (elec.why or "no signal"))
    return false
  end
  local note = nil
  if gid == "sas" then
    sas_mode = (sas_mode ~= "off") and "off" or sas_last
    note = "SAS " .. (sas_mode == "off" and "off" or "on")
  elseif gid == "rcs" then
    if #DEVICES.rcs.parts > 0 then
      DEVICES.rcs.on = not DEVICES.rcs.on
      note = "RCS " .. (DEVICES.rcs.on and "on" or "off")
    end
  elseif gid == "abort" then
    throttle = 0.0
    note = "ABORT"
  end
  local n = E and fireGroup(gid) or 0
  if not E and (gid == "gear" or gid == "deploy") then
    for _, id in ipairs(gid == "gear" and { "gear" } or { "comms", "solar" }) do
      if #DEVICES[id].parts > 0 then setPeripheral(id) end
    end
  end
  if n > 0 or note then
    local gg = ctlGroups[gid]
    local info2 = E and E.groupInfo(gid)
    local label = (gg and gg.name) or (info2 and info2.label) or gid
    local i = assembly.info(node)
    local bx2, by2, bz2 = base_of(node, i)
    sfx3(SFX.gear, bx2, by2, bz2, 0.6, 1.0)
    local say = note or label:lower()
    if n > 0 and note then say = note .. " · " .. label:lower() end
    caption(say)
    log(string.format("group %s: %d action%s%s", label, n, n == 1 and "" or "s", note and (" · " .. note) or ""))
  end
  return true
end

-- The light the panels see is measured against the home world's orbit: 1 at
-- the base's distance from its star.
local function ref_flux(E, bodies)
  if elec.ref then return elec.ref end
  local name = save.get("base.body")
  local b = type(name) == "string" and space.body(name) or nil
  if not b then return nil end
  local sun = E.sunOf(b.x, b.y, b.z, bodies, nil)
  if not sun or sun.name == b.name then return nil end
  local d2 = (sun.x - b.x) ^ 2 + (sun.y - b.y) ^ 2 + (sun.z - b.z) ^ 2
  elec.ref = sun.mu / math.max(d2, 1)
  return elec.ref
end

-- Where a part sits in the world, and an axis of it.
local function part_world(node, info, d, ax, ay, az)
  local rx, up, rz = basis(node)
  local bx, by, bz = base_of(node, info)
  local x = bx + rx.x * d.x + up.x * d.y + rz.x * d.z
  local y = by + rx.y * d.x + up.y * d.y + rz.y * d.z
  local z = bz + rx.z * d.x + up.z * d.y + rz.z * d.z
  if not ax then return x, y, z end
  return x, y, z, rx.x * ax + up.x * ay + rz.x * az, rx.y * ax + up.y * ay + rz.y * az,
    rx.z * ax + up.z * ay + rz.z * az
end

-- WHO MAY FLY THIS. Published on `elec` (fixedUpdate reads it for free):
--   control  true/false     mode "crew" | "probe" | nil
--   why      the reason there's no control, in the HUD's words
function controlTick()
  local can, mode, why = false, nil, nil
  local st = elec.probePart and bp_by_uid[elec.probePart] and bp_by_uid[elec.probePart].st
  if crewAboard and (commander() ~= nil or not crewLibNow()) then
    can, mode = true, "crew"
  elseif crewAboard and not elec.probePart then
    why = "NO CREW AT THE CONTROLS — a cabin flies nothing"
  elseif not elib() then
    can, mode = true, "crew"            -- no rulebook: fly as before
  elseif not elec.probePart then
    why = (crewCount() > 0 and "CREW ABOARD — switch to them with [ ]")
      or (elec.crewPart and "NO CREW — the pod is empty") or "NO COMMAND PART"
  elseif st and st.hibernate then
    why = "PROBE CORE OFF — hibernating"
  elseif elec.served and (elec.served[elec.probePart] or 1) < 0.5 then
    why = "NO POWER — the probe core is dark"
  elseif not elec.link then
    why = "NO SIGNAL — " .. (elec.linkWhy or "no path home")
  else
    can, mode = true, "probe"
  end
  elec.control, elec.mode, elec.why = can, mode, why
end

-- ELECTRICAL tick, 10 Hz: supply, demand, the batteries, the radios, the link,
-- and who has control. Runs piloted or derelict — a dead-stick probe on panels
-- keeps its radio up and stays on the network.
local function power_tick(node, info, dt)
  elec.acc = (elec.acc or 0) + dt
  if elec.acc < 0.1 then return end
  dt, elec.acc = elec.acc, 0
  local E = elib()
  if (elec.gen_seen or -1) ~= integ.gen then elecRescan() end
  if not E then
    elec.link, elec.control = true, true
    return
  end
  local now = time
  -- The bodies are read EVERY tick, never cached: these worlds move hundreds
  -- of metres a second on their rails, and a craft (read now) set against
  -- where its planet was even half a second ago sits tens of metres off its
  -- own ground — the sun "set" at noon and shone after dark (2026-10-23).
  elec.bodies, elec.bodies_t = space.bodies() or {}, now
  local bodies = elec.bodies
  local ref = ref_flux(E, bodies)
  -- The step in GAME seconds: time warp runs the world (and the batteries)
  -- warp× faster than the frame's dt (2026-10-23: panels charged at 1× speed
  -- under any warp).
  local st_now = space.time and space.time() or nil
  local warp_now = space.warp and space.warp() or 1
  if E.gameStep then
    dt = E.gameStep(elec.st_last, st_now, dt, warp_now)
  else
    dt = dt * math.max(1, warp_now)
  end
  elec.st_last, elec.game_dt = st_now, dt
  local supply, loads, cells, batts = 0.0, {}, {}, {}
  local sunlit, panels = false, 0
  local plist = {}
  local wheels = {}
  local cut = math.huge
  for _, ev in ipairs(events) do
    if ev.kind == "axial" and ev.y < cut then cut = ev.y end
  end
  local burning = throttle > 0.02 and fuel > 0 and not info.anchored
  for _, u in ipairs(elec.parts) do
    local d = bp_by_uid[u]
    if d and aboard(u) then
      local st = E.stateOf(d)
      for _, m in ipairs(E.modsOf(d)) do
        local ty = m.type
        if ty == "battery" then
          local c = { cap = m.ec or 0, charge = math.min(m.ec or 0, st.charge or 0), on = st.flow ~= false, st = st }
          cells[#cells + 1] = c
        elseif ty == "solar" then
          -- Every panel counts, open or folded (a folded wing lies along the
          -- hull with its cells out: electronics.panelExposure). Its mount
          -- axis in the WORLD (the part's rotation, then the craft's).
          local ax, ay, az = part_axis_x(d)
          local x, y, z, wx, wy, wz = part_world(node, info, d, ax, ay, az)
          plist[#plist + 1] = { gen = m.gen or 0, ax = wx, ay = wy, az = wz, deployed = panim[u] or 0,
                                x = x, y = y, z = z }
          panels = panels + 1
        elseif ty == "rtg" then
          supply = supply + (m.gen or 0)
        elseif ty == "engine" then
          if burning and st.running ~= false then
            for _, e in ipairs(engines) do
              if e.uid == u and engine_active(e, cut) then supply = supply + (m.alt or 0) * throttle end
            end
          end
        elseif ty == "command" then
          loads[#loads + 1] = { id = u, rate = (m.draw or 0) * (st.hibernate and 0.1 or 1), pri = 9 }
        elseif ty == "wheel" then
          if st.wheel ~= false then
            local use = math.min(1, elec.wheel_use or 0)
            loads[#loads + 1] = { id = "w" .. u, rate = (m.draw or 0) * (0.05 + 0.95 * use), pri = 6 }
            wheels[#wheels + 1] = { id = "w" .. u, torque = m.torque or 1 }
          end
        elseif ty == "antenna" then
          local folds = E.modOf(d, "deploy") ~= nil
          if not folds or (st.deployed and (panim[u] or 0) > 0.9) then
            loads[#loads + 1] = { id = "a" .. u, rate = m.draw or 0, pri = 7 }
          end
        elseif ty == "light" then
          if st.lit then loads[#loads + 1] = { id = u, rate = m.draw or 0, pri = 2 } end
        end
      end
    end
  end
  -- Motors (round two): wheels, actuators, the claw and the drill draw what
  -- they asked for this tick (R2.draw, by load id).
  for id, rate in pairs(R2.draw) do
    if rate > 0 then loads[#loads + 1] = { id = id, rate = rate, pri = 4 } end
  end
  -- SUNLIGHT over the step: integrated along the craft's and its world's
  -- motion (a long warp step spans a good part of a day, or several orbits).
  if #plist > 0 then
    local cx, cy, cz = base_of(node, info)
    for _, p in ipairs(plist) do p.ox, p.oy, p.oz = p.x - cx, p.y - cy, p.z - cz end
    local v = info.vel
    local landed = info.anchored or info.grounded or R2.onWheels or false
    local sun_out, lit
    if E.solarOverStep then
      sun_out, lit = E.solarOverStep(plist, { x = cx, y = cy, z = cz, vx = v and v.x or 0, vy = v and v.y or 0,
        vz = v and v.z or 0, landed = landed, bodies = bodies }, dt, ref)
    else
      sun_out, lit = 0, 0
      for _, p in ipairs(plist) do
        if (p.deployed or 0) > 0.9 then
          local o = E.solarOutput(p.gen, p.x, p.y, p.z, p.ax, p.ay, p.az, bodies, ref)
          sun_out = sun_out + o
          if o > 0 then lit = 1 end
        end
      end
    end
    supply = supply + sun_out
    sunlit = sun_out > 0 or (lit or 0) > 0
  end
  local rep = E.powerStep({ supply = supply, loads = loads, cells = cells }, dt)
  for _, c in ipairs(cells) do c.st.charge = c.charge end
  -- isolated batteries still count toward what's aboard
  local cap, charge = 0, 0
  for _, c in ipairs(cells) do cap, charge = cap + c.cap, charge + c.charge end
  elec.cap, elec.charge = cap, charge
  elec.supply, elec.demand, elec.net = rep.supply, rep.demand, rep.net
  elec.brownout = rep.brownout
  elec.served = rep.served
  elec.sunlit, elec.panels = sunlit, panels
  elec.gen = supply
  local tk = 0
  for _, w in ipairs(wheels) do tk = tk + w.torque * (rep.served[w.id] or 0) end
  elec.torque_k = math.min(1.5, tk)
  -- The radios: the ones with power, folded out where they fold.
  local skip = {}
  for u in pairs(integ.gone) do skip[u] = true end
  for u, d in pairs(bp_by_uid) do
    if (part_hp[u] or 1) <= 0 then skip[u] = true end
    if E.modOf(d, "antenna") then
      local s = rep.served["a" .. u]
      if s == nil or s < 0.5 then skip[u] = true end
      -- a craft whose command part is dark can't key its radio either
      if elec.probePart and not crewAboard and (rep.served[elec.probePart] or 1) < 0.5 then skip[u] = true end
    end
  end
  local ant = E.antennaSummary(bp_by_uid, skip, true)
  elec.antenna = ant
  elec.comms = ant.n > 0
  local px, py, pz = pod_world(node, info)
  local silent = nil
  if ant.n == 0 then
    silent = E.antennaSummary(bp_by_uid, integ.gone, true).n == 0 and "no antenna aboard"
      or "no power for its radio"
  end
  -- `ox..oz`: the pod's offset from the craft's root node, so the network
  -- (comms.lua) can place the antenna at the root's position AT ITS OWN SOLVE
  -- — px is a tenth of a second old by then, which on a world moving 240 m/s
  -- is a rover 24 m into the hillside.
  elec.node = { x = px, y = py, z = pz, any = ant.any, relay = ant.relay, rate = ant.rate, silent = silent,
                ox = px - (node.worldX or node.x), oy = py - (node.worldY or node.y), oz = pz - (node.worldZ or node.z) }
  -- The path home, from the network's last solve.
  local net = comms_net()
  local cs = net and net.statusOf and net.statusOf(node.id) or nil
  if cs then
    elec.link, elec.signal, elec.hops = cs.connected == true, cs.strength or 0, cs.hops or 0
    elec.linkWhy = cs.why
    elec.path = cs.names
    elec.bandwidth = cs.bandwidth or 0
    -- the dishes swing onto whoever we talk to
    if cs.parentPos and cs.connected then
      local rx, up, rz = basis(node)
      local dx, dy, dz = cs.parentPos.x - px, cs.parentPos.y - py, cs.parentPos.z - pz
      local l = math.sqrt(dx * dx + dy * dy + dz * dz)
      if l > 1e-3 then
        dx, dy, dz = dx / l, dy / l, dz / l
        local a = { x = dx * rx.x + dy * rx.y + dz * rx.z, y = dx * up.x + dy * up.y + dz * up.z,
                    z = dx * rz.x + dy * rz.y + dz * rz.z }
        local o = elec.aim
        if not o or math.abs(o.x - a.x) + math.abs(o.y - a.y) + math.abs(o.z - a.z) > 0.02 then elec.aim = a end
      end
    else
      elec.aim = nil
    end
  elseif not net then
    -- No network in this scene (a harness): a craft with a radio is in contact.
    elec.link, elec.signal, elec.hops = ant.n > 0, ant.n > 0 and 1 or 0, ant.n > 0 and 1 or 0
  end
  controlTick()
  -- Tracker heartbeat (1 Hz): the comms.ships registry the Command Centre counts.
  if now - (elec.ptime or -10) > 1.0 then
    elec.ptime = now
    local key = "v" .. tostring(node.id or 0)
    local ships = save.get("comms.ships") or {}
    local was = ships[key] ~= nil
    if elec.link then
      ships[key] = { name = node.name or "Vessel", x = node.x, y = node.y, z = node.z,
                     charge = elec.charge, cap = elec.cap, t = now }
      save.set("comms.ships", ships)
    elseif was then
      ships[key] = nil
      save.set("comms.ships", ships)
    end
  end
end

-- Share `total` EC across the batteries by capacity (an old record's pooled
-- charge; a probe that sets a craft's charge).
function elecSetCharge(total)
  local E = elib()
  if not E then elec.charge = total return end
  local cap = 0
  for u, d in pairs(bp_by_uid) do
    local m = E.modOf(d, "battery")
    if m and aboard(u) then cap = cap + (m.ec or 0) end
  end
  if cap <= 0 then return end
  local k = math.max(0, math.min(1, (total or 0) / cap))
  for u, d in pairs(bp_by_uid) do
    local m = E.modOf(d, "battery")
    if m and aboard(u) then E.stateOf(d).charge = (m.ec or 0) * k end
  end
  elec.charge = math.min(cap, total or 0)
end

-- What this craft offers the comms network (comms.lua asks every craft).
function commsNode()
  if destroyed then return nil end
  return elec.node
end

-- One line of the electrical state (probes and the console).
function elecDebug()
  local s = {}
  for k, v in pairs(elec.served or {}) do s[#s + 1] = tostring(k) .. "=" .. string.format("%.2f", v) end
  return string.format("supply %.2f demand %.2f charge %.1f/%.1f served{%s} probe=%s link=%s ctl=%s why=%s parts=%d",
    elec.supply or -1, elec.demand or -1, elec.charge or -1, elec.cap or -1, table.concat(s, ","),
    tostring(elec.probePart), tostring(elec.link), tostring(elec.control), tostring(elec.why), #(elec.parts or {}))
end

-- The control state, for the HUD, the tracking station and the switcher.
function controlState()
  return { can = elec.control ~= false, mode = elec.mode, why = elec.why, crew = crewAboard == true,
           probe = elec.probePart ~= nil, pod = elec.crewPart ~= nil, lost = destroyed == true,
           charge = elec.charge, cap = elec.cap, linkWhy = elec.linkWhy }
end


-- PARACHUTE DEPLOYMENT, tick by tick: the physics the drag uses and the
-- canopies (scripts/parachute.lua) draw, so what you see is what slows you.
--   1. the mortar pops the lid and the pilot chute drags the bagged canopy
--      out into the airflow: the lines pay out faster than the craft falls
--      (the mortar's own ~10 m/s in still air); nothing drags yet;
--   2. at line stretch the canopy fills to its REEFED area and holds it a
--      moment (the reefing line keeps the opening shock down);
--   3. disreefed, it fills to full over a few canopy diameters of travel
--      (fill time ∝ D/v, as real canopies do): about 1 s from line stretch at
--      60 m/s, 2 s at 20 m/s; thin air fills slower, and cannot hold the
--      canopy fully open at all.
--   The whole opening, mortar to full, runs 1-3 s. (This world's atmospheres
--   are ~70 m deep: a real canopy's 8-diameter fill would still be opening
--   when a late deploy hit the ground.)
--   4. with no air through it (landed, stopped, or out of the atmosphere) it
--      spills and collapses in a third of a second.
-- chute_anim is the inflated area fraction: the drag and the over-pressure
-- tear both read it.
local function update_chutes(node, dt)
  local f = chute_fill
  if not chutes_deployed or f.cut then
    if not chutes_deployed and f.t > 0 then
      f.t, f.stretch, f.area, f.ls = 0.0, 0.0, 0.0, nil
    end
    f.area = 0.0
    chute_anim = 0.0
    return
  end
  local info = assembly.info(node)
  if not info then return end
  local v = info.vel
  local spd = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
  local dens = 0.0 -- the same band model as the drag and heating
  local dom = space.dominant(node.x, node.y, node.z)
  local db = dom and space.body(dom)
  if db and db.radius then
    local dx, dy, dz = node.x - db.x, node.y - db.y, node.z - db.z
    local alt = math.sqrt(dx * dx + dy * dy + dz * dz) - db.radius
    dens = airBandAt(db, alt)
  end
  f.t, f.dens, f.spd, f.grounded = f.t + dt, dens, spd, info.grounded or false
  local PACK_LEN = 12.5   -- riser + lines + canopy, m (models/parts/parachute.glb)
  local FILL_D = 7.1      -- the inflated canopy's diameter, m
  local REEF_S, REEF_AREA = 0.4, 0.2
  if f.stretch < 1.0 then
    f.stretch = math.min(1.0, f.stretch + dt * math.max(10.0, 1.5 * spd) / PACK_LEN)
    -- Only the pilot chute pulls (a drag too small to count), so the canopy's
    -- over-pressure tear comes at line stretch — the opening shock — when
    -- chute_anim first rises above zero.
    f.area = 0.0
    if f.stretch >= 1.0 then f.ls = f.t end
  else
    local reefed = f.t - (f.ls or 0) < REEF_S
    -- Thin air cannot hold a canopy open: it stays partly collapsed.
    local hold = 0.3 + 0.7 * math.min(1.0, math.max(0.0, (dens - 0.03) / 0.37))
    local air = dens > 0 and spd > 1.2 and not info.grounded
    local target = air and math.min(reefed and REEF_AREA or 1.0, hold) or 0.0
    if target > f.area then
      local rate = math.min(6.0, math.max(0.8,
        spd / (2.5 * FILL_D) * (0.2 + 0.8 * math.sqrt(dens))))
      f.area = math.min(target, f.area + (target - f.area) * math.min(1.0, dt * rate * 2.2) + dt * 0.02)
    else
      f.area = f.area + (target - f.area) * math.min(1.0, dt * 3.0)
    end
  end
  chute_anim = f.area
end

-- CUT THE CHUTES: the canopies part from their risers and fly free (the
-- canisters stay). Nothing drags after this. Returns true if any were open.
function cutChutes()
  if not chutes_deployed or chute_fill.cut or #chutes == 0 then return false end
  chute_fill.cut = true
  for _, c in ipairs(chutes) do c.canopy = nil end
  chute_anim = 0.0
  caption("the chutes are cut away")
  log("parachutes cut")
  return true
end

-- Departing parts take their plumes with them: stop any engine flame on the
-- nodes about to split away (nothing owns them afterwards — un-quenched,
-- a dropped booster's plume burned forever).
local function quench(parts_nodes)
  for _, pn in ipairs(parts_nodes) do
    for _, f in ipairs(pn:children()) do
      if f.name == "Engine Flame" or f.name == "Engine Flame Vac" then
        local ps = f:particles()
        if ps and ps:isPlaying() then ps:stop() end
        local light = f:getcomponent("PointLight")
        if light then light.intensity = 0.0 end
      end
    end
  end
end

-- Kick a freshly-split wreck away from the impact with a consistent tumble.
-- TWO fixes for "debris flies off weird": (1) the lift is along GRAVITY-UP
-- (radial on a planet — world +Y is sideways when you've landed on a
-- sphere's flank, which threw wreck out horizontally), and (2) the kick is a
-- Δv scaled by the wreck's own mass (impulse = m·Δv) so a 0.15 t decoupler and
-- a 0.8 t engine tumble away at the SAME speed instead of the light bits
-- rocketing off. `dv` is metres/second.
-- Gravity-up (radial from the dominant body) at a world point; world +Y only
-- when there is no body. "Up" on a round planet is never world +Y in general.
local function radial_up(x, y, z)
  local dom = space.dominant(x, y, z)
  local b = dom and space.body(dom)
  if b then
    local ax, ay, az = x - b.x, y - b.y, z - b.z
    local al = math.sqrt(ax * ax + ay * ay + az * az)
    if al > 1e-3 then return ax / al, ay / al, az / al end
  end
  return 0, 1, 0
end

-- ── DEBRIS THAT HANGS IN THE AIR ───────────────────────────────────────────
-- (playtest 2026-10-23: "debris often left floating"). Until 0.117.0-rc6 every
-- piece a craft shed was watched here: kept out of the distant-craft LOD, let
-- go if it hung in the air, put back if it sank into the ground. The engine
-- does all of it since 0.117.0-rc7: the LOD freezes a compound only when it
-- rests (floptle/0493), collision follows moving bodies as well as the camera
-- (0492), and a sleeping piece wakes when its ground is dug away. Measured on
-- rc7 with no watcher and the LOD anchor 3 km off for 30 s after a breakup:
-- 4 of 4 pieces landed (0 hanging, 0 sunk; 3 runs), and every piece fell
-- 7-8 m when the ground was dug from under it.

-- `clear` (m, optional) first moves the wreck that far straight out from the
-- impact, so it starts clear of the hull it just left: overlapping colliders
-- are resolved by the engine as a collision, which is a kick of its own on top
-- of this one (and the trigger of the engine's depenetration runaway).
-- `away` (optional) = { gap, x, y, z }: how far, and along which world unit
-- direction, the wreck must move to clear the hull it left (from clearAway —
-- AWAY FROM WHAT STAYS, which is not the same as away from the impact: for a
-- crushed engine bell the impact is below it, and "away from the impact"
-- moved the bell up through the tank and pod above it).
local function debris_kick(junk, hx, hy, hz, dv, away, hull, also)
  local ji = assembly.info(junk)
  if not ji then return end
  local cx, cy, cz = ji.com.x, ji.com.y, ji.com.z
  local ox, oy, oz = cx - hx, cy - hy, cz - hz     -- outward from the impact
  local ol = math.sqrt(ox * ox + oy * oy + oz * oz)
  if ol < 1e-3 then ox, oy, oz, ol = 0, 1, 0, 1 end
  ox, oy, oz = ox / ol, oy / ol, oz / ol
  local ux, uy, uz = radial_up(cx, cy, cz)          -- gravity-up (radial)
  -- Out of any overlap and passing through the hull (and the other pieces of
  -- the same breakup) for a moment: see releasePiece.
  local a = away or { gap = 0, x = ox, y = oy, z = oz }
  releasePiece(junk, hull, a.x, a.y, a.z, a.gap, also)
  if dv <= 0 then return end -- velocity kept exactly: no impulse at all
  local g = physTune.clear and (a.gap or 0) or 0
  local m = (ji.mass and ji.mass > 0) and ji.mass or 0.2
  assembly.impulseAt(junk, vec3(
    (ox + ux * 0.5) * dv * m,
    (oy + uy * 0.5) * dv * m,
    (oz + uz * 0.5) * dv * m), vec3(cx + a.x * g, cy + a.y * g, cz + a.z * g))
end

-- ── docking ─────────────────────────────────────────────────────────────────
-- A DOCKING PORT is the one part that both JOINS two craft and CUTS one back in
-- half, and it's driven entirely from the peripherals panel — no staging, no
-- one-way commitment. The mission it exists for: park a mothership in orbit,
-- undock the lander, go down, come back up, latch on again, fly home.
--
-- CAPTURE is honest soft docking. Bring two free ports face to face — inside
-- the capture radius, roughly square to each other, closing slowly — and the
-- latch takes. Physically the two compounds MERGE into one rigid body carrying
-- their combined momentum (`assembly.merge`), so an off-centre catch spins the
-- stack exactly as much as it should and nothing is created out of nothing.
--
-- ABSORPTION is what makes undocking free. The captured craft's blueprint is
-- folded into ours — its parts, engines, tanks, batteries, panels and its own
-- ports all become ours — and its tree is RE-ROOTED at the port that mated, so
-- the merged attachment tree records exactly which parts arrived through which
-- seam. Cutting there is then the same topological split a decoupler does,
-- except the departing half comes away as a LIVE craft (`assembly.split` roots
-- it at the Vessel prefab, scripts and all) carrying a blueprint we hand it at
-- the seam. Take control of it and fly it.
--
-- Everything here is deliberately GLOBAL: the peripherals panel reads this
-- state cross-script, and `fixedUpdate` sits at Lua's 60-upvalue ceiling — a
-- global reference costs it nothing where another local would break it.
local DOCK_ASSIST_R = 6.0     -- soft-capture magnetism reaches this far
local DOCK_LOCKOUT = 2.5      -- s of no-recapture after an undock (or you'd re-latch)

-- ── the docking maths (global: no upvalues for fixedUpdate) ─────────────────
-- A port's ROLL KEY: its first guide petal (tools/gen_part_meshes.py
-- part_dockport: three petals, the first 0.3 rad round from the part's +X in
-- its XZ plane); a radial port mates along +X and keys on its +Y. Two ports
-- seat with their petals interleaved: 60° apart, every 120°.
-- (scripts/targeting.lua TM is the same maths for the SAS hold and the HUD.)
DOCKM = { fold = 3, offset = math.pi / 3, petal = 0.3 }
function DOCKM.partBasis(yaw, pitch, roll)
  local cy, sy = math.cos(yaw or 0), math.sin(yaw or 0)
  local cx, sx = math.cos(pitch or 0), math.sin(pitch or 0)
  local cz, sz = math.cos(roll or 0), math.sin(roll or 0)
  return { cy * cz + sy * sx * sz, cx * sz, -sy * cz + cy * sx * sz },
         { -cy * sz + sy * sx * cz, cx * cz, sy * sz + cy * sx * cz },
         { sy * cx, -sx, cy * cx }
end
function DOCKM.keyLocal(rec)
  local X, Y, Z = DOCKM.partBasis(rec and rec.yaw, rec and rec.pitch, rec and rec.roll)
  if rec and (rec.att or "") == "radial" then return Y[1], Y[2], Y[3] end
  local c, s = math.cos(DOCKM.petal), math.sin(DOCKM.petal)
  return X[1] * c + Z[1] * s, X[2] * c + Z[2] * s, X[3] * c + Z[3] * s
end
-- The craft's TICK axes (assembly.info right/up; Z = R × U); drawn ones only
-- without a compound (a test rig).
function DOCKM.tickAxes(node, info)
  if info and info.right and info.up then
    local R, U = info.right, info.up
    return R, U, vec3(R.y * U.z - R.z * U.y, R.z * U.x - R.x * U.z, R.x * U.y - R.y * U.x)
  end
  return basis(node)
end
function DOCKM.across(vx, vy, vz, ax, ay, az)
  local d = vx * ax + vy * ay + vz * az
  local x, y, z = vx - ax * d, vy - ay * d, vz - az * d
  local l = math.sqrt(x * x + y * y + z * z)
  if l < 1e-9 then return nil end
  return x / l, y / l, z / l
end
function DOCKM.rotate(vx, vy, vz, ax, ay, az, t)
  local c, s = math.cos(t), math.sin(t)
  local cx, cy, cz = ay * vz - az * vy, az * vx - ax * vz, ax * vy - ay * vx
  local d = (ax * vx + ay * vy + az * vz) * (1 - c)
  return vx * c + cx * s + ax * d, vy * c + cy * s + ay * d, vz * c + cz * s + az * d
end
-- The key a port with axis A must take to interleave with the key tk, the
-- slot nearest its key mk now. → Kx, Ky, Kz.
function DOCKM.matchKey(Ax, Ay, Az, tkx, tky, tkz, mkx, mky, mkz)
  local bx, by, bz = DOCKM.across(tkx, tky, tkz, Ax, Ay, Az)
  if not bx then return nil end
  local px, py, pz = DOCKM.across(mkx, mky, mkz, Ax, Ay, Az)
  local best, bk = -2, nil
  for j = 0, DOCKM.fold - 1 do
    local kx, ky, kz = DOCKM.rotate(bx, by, bz, Ax, Ay, Az, DOCKM.offset + j * 2 * math.pi / DOCKM.fold)
    local d = px and (kx * px + ky * py + kz * pz) or (j == 0 and 1 or -1)
    if d > best then best, bk = d, { kx, ky, kz } end
  end
  return bk[1], bk[2], bk[3]
end
-- The rotation (rows) taking frame (a, k, a×k) onto (A, K, A×K): R = W·Cᵀ.
function DOCKM.frameRot(a, k, A, K)
  local b = { a[2] * k[3] - a[3] * k[2], a[3] * k[1] - a[1] * k[3], a[1] * k[2] - a[2] * k[1] }
  local B = { A[2] * K[3] - A[3] * K[2], A[3] * K[1] - A[1] * K[3], A[1] * K[2] - A[2] * K[1] }
  local C, W = { a, k, b }, { A, K, B }
  local R = {}
  for i = 1, 3 do
    R[i] = {}
    for j = 1, 3 do R[i][j] = W[1][i] * C[1][j] + W[2][i] * C[2][j] + W[3][i] * C[3][j] end
  end
  return R
end
-- A rotation matrix → its axis × angle (radians).
function DOCKM.rotVec(R)
  local tr = R[1][1] + R[2][2] + R[3][3]
  local c = math.max(-1, math.min(1, (tr - 1) / 2))
  local th = math.acos(c)
  if th < 1e-7 then return 0, 0, 0, 0 end
  local x, y, z = R[3][2] - R[2][3], R[1][3] - R[3][1], R[2][1] - R[1][2]
  local l = math.sqrt(x * x + y * y + z * z)
  if l < 1e-9 then
    -- a half turn: the axis from the diagonal
    x, y, z = math.sqrt(math.max(0, (R[1][1] + 1) / 2)), math.sqrt(math.max(0, (R[2][2] + 1) / 2)),
              math.sqrt(math.max(0, (R[3][3] + 1) / 2))
    l = math.sqrt(x * x + y * y + z * z)
  end
  return x / l * th, y / l * th, z / l * th, th
end

dock = {
  -- The capture envelope lives ON the published table, not in locals: the HUD
  -- and the panel tick the pilot's checklist against these every frame, and
  -- `fixedUpdate` is at Lua's 60-upvalue ceiling — three more captured locals
  -- is exactly the kind of thing that breaks it. A global costs nothing.
  captureR = 0.55,   -- port faces this close latch (metres)
  alignMin = 0.80,   -- ...if they're at least this square to each other
  driftMax = 1.5,    -- ...and closing/drifting no faster than this (m/s)
  ports = {},      -- every mating face on the craft, vessel-local
  assist = true,   -- soft-capture magnetism (the panel toggles it)
  target = nil,    -- live approach readout: range / align / closing / lateral
  latched = 0,     -- how many of our ports are currently mated
  arm = 0.0,       -- `time` before which capture is locked out (post-undock)
  pending = nil,   -- a capture in flight, folded in on the tick the merge lands
  auto = false,    -- docking autopilot: RCS flies the approach for you
  lock = nil,      -- { id = <their node id>, uid = <their port uid> } target lock
  map = false,     -- the map view owns the screen (published by fixedUpdate)
  msg = "",        -- one-line status the panel and HUD show
  node = nil,      -- our own root (stashed so the cross-script hooks can reach it)
  next_uid = 1,    -- uid allocator for absorbed parts
}

-- Find one of our port records by blueprint uid.
local function dock_port(uid)
  for _, p in ipairs(dock.ports) do
    if p.uid == uid then return p end
  end
  return nil
end

-- Rebuild the attachment tree + the staging caches from the CURRENT blueprint.
-- Every dock and undock rewrites the tree, and `axial_departing` memoises off
-- it — stale caches there would cut the wrong half off the ship.
local function dock_retree()
  bp_kids = {}
  for u, d in pairs(bp_by_uid) do
    local pu = d.parent or 0
    if pu ~= 0 and bp_by_uid[pu] then
      bp_kids[pu] = bp_kids[pu] or {}
      bp_kids[pu][#bp_kids[pu] + 1] = u
    end
  end
  axial_set_cache = {}
end

-- Which way does this port FACE, and is that face usable?
--
-- A STACKED port has an axial neighbour on one side and open space on the
-- other, and only the open face can mate — so its axis is its own ±Y, signed
-- by which side is free. A port bolted to a FLANK is a different animal: the
-- hull is behind it by construction and its mating face is the outward one,
-- which for a `radial_orient` part is its local **+X** (see the builder's
-- `yaw = atan2(-dz, dx)` — that yaw is chosen precisely to aim +X outward).
-- Getting this wrong is why a side berth used to point at the sky.
--
-- Read off the attachment TREE, not geometry: a part nudged half a centimetre
-- must not change which way its port faces. Returns (ax, ay, az, buried).
local function dock_face(d)
  local radial = (d.att or "") == "radial"
  local ax, ay, az
  if radial then
    ax, ay, az = part_axis_x(d)
  else
    ax, ay, az = part_axis(d)
  end
  local plus, minus = false, false
  local function mark(q)
    if not q then return end
    local proj = (q.x - d.x) * ax + (q.y - d.y) * ay + (q.z - d.z) * az
    if proj > 0.01 then
      plus = true
    elseif proj < -0.01 then
      minus = true
    end
  end
  -- A radial port's own mount sits behind it; only an AXIAL mount blocks a face.
  if not radial then mark(bp_by_uid[d.parent or 0]) end
  for _, u in ipairs(bp_kids[d.uid] or {}) do
    local q = bp_by_uid[u]
    if q then mark(q) end
  end
  if radial then
    -- One usable face. Anything parked out along it buries the port.
    return ax, ay, az, plus
  end
  if plus and minus then return ax, ay, az, true end
  local sign = plus and -1 or 1
  return ax * sign, ay * sign, az * sign, false
end

-- (Re)build the port list from the current blueprint — after load, after every
-- dock and after every undock. Existing port records are kept (their latch
-- state and cached light node ride along) and re-posed.
function dockRescan()
  local keep = {}
  for _, p in ipairs(dock.ports) do keep[p.uid] = p end
  dock.ports, dock.latched = {}, 0
  for u, d in pairs(bp_by_uid) do
    if u >= dock.next_uid then dock.next_uid = u + 1 end
    if (d.dock or 0) == 1 and (part_hp[u] or 0) > 0 then
      local p = keep[u] or { uid = u }
      p.x, p.y, p.z = d.x, d.y, d.z
      p.ax, p.ay, p.az, p.buried = dock_face(d)
      p.radial = (d.att or "") == "radial"
      if p.mate and not bp_by_uid[p.mate] then p.mate = nil end
      dock.ports[#dock.ports + 1] = p
    end
  end
  -- MATED IN THE VAB: two docking ports stacked face to face in the builder are
  -- ALREADY a seam — that's how you carry a lander up bolted to its mothership,
  -- and it's the whole point of the part. Nothing captured them, so nothing set
  -- their latch; read it off the attachment tree instead. Without this the pair
  -- comes up "blocked" (both faces occupied, neither mated) and there is no way
  -- to ever separate them — which is exactly what a stacked pair looks like.
  --
  -- A LONE port is not a seam. One port with a part welded to each face is just
  -- a structural spacer: there'd be nothing on the far half to re-dock to, so
  -- refusing it is honest rather than handing you a one-way separation that
  -- silently ends the mission. Ports come in pairs.
  for _, p in ipairs(dock.ports) do
    if not p.mate then
      local d = bp_by_uid[p.uid]
      local pu = (d and (d.att or "") ~= "radial") and (d.parent or 0) or 0
      local host = pu ~= 0 and bp_by_uid[pu]
      if host and (host.dock or 0) == 1 then
        local q = dock_port(pu)
        if q and not q.mate then p.mate, q.mate = q.uid, p.uid end
      end
    end
  end
  dock.latched = 0
  for _, p in ipairs(dock.ports) do
    if p.mate then dock.latched = dock.latched + 1 end
  end
end

-- A port's world position + outward axis, from the PHYSICS-fresh vessel frame
-- (`info.origin`, not the node pose — see `base_of`: on an orbiting world the
-- node lags the rails carry by a tick, which is metres at orbital speed and
-- would put every capture test off the real hardware).
local function dock_world(node, info, p)
  -- TICK poses throughout (docs/positions-and-frames.md rule 2): the origin
  -- AND the axes from assembly.info, never the tick origin with the node's
  -- drawn axes (that mix put a port up to a tick of rotation off at range).
  local R, U, Z = DOCKM.tickAxes(node, info)
  local bx, by, bz = base_of(node, info)
  local kx, ky, kz = DOCKM.keyLocal(bp_by_uid[p.uid])
  return bx + R.x * p.x + U.x * p.y + Z.x * p.z,
         by + R.y * p.x + U.y * p.y + Z.y * p.z,
         bz + R.z * p.x + U.z * p.y + Z.z * p.z,
         R.x * p.ax + U.x * p.ay + Z.x * p.az,
         R.y * p.ax + U.y * p.ay + Z.y * p.az,
         R.z * p.ax + U.z * p.ay + Z.z * p.az,
         R.x * kx + U.x * ky + Z.x * kz,
         R.y * kx + U.y * ky + Z.y * kz,
         R.z * kx + U.z * ky + Z.z * kz
end

-- The live child node for a port uid, cached (ports don't move within the hull).
local function dock_light(node, p)
  if p.light and p.light.valid then return p.light end
  local c = child_of_uid(node, p.uid)
  if not c then return nil end
  for _, g in ipairs(c:children()) do
    if g.name == "Dock Light" then
      p.light = g
      return g
    end
  end
  return nil
end

-- The capture indicator on the port itself: dark idle, amber while a target is
-- inside the soft-capture cone, green once latched. The whole approach reads
-- off the hardware — you can fly a dock without ever looking at the HUD.
local function dock_lamp(node, p, mode)
  local l = dock_light(node, p)
  if not l then return end
  local el = l:getcomponent("PointLight")
  if not el then return end
  if mode == "latched" then
    el.r, el.g, el.b, el.intensity = 0.25, 1.0, 0.35, 1.6
  elseif mode == "near" then
    el.r, el.g, el.b, el.intensity = 1.0, 0.72, 0.2, 1.2
  else
    el.intensity = 0.0
  end
end

-- ── cross-script handshake ─────────────────────────────────────────────────
-- Every port this craft can currently mate through, in WORLD space. The other
-- vessel's controller calls this to find us — including while we're derelict,
-- unpiloted or a bare station module, which is exactly when it matters.
function dockFaces()
  local out = {}
  local node = dock.node
  if destroyed or not node or not node.valid then return out end
  local info = assembly.info(node)
  if not info then return out end
  for _, p in ipairs(dock.ports) do
    if not p.buried and not p.mate then
      local x, y, z, ax, ay, az, kx, ky, kz = dock_world(node, info, p)
      out[#out + 1] = { uid = p.uid, x = x, y = y, z = z, ax = ax, ay = ay, az = az,
                        kx = kx, ky = ky, kz = kz, h = (bp_by_uid[p.uid] or {}).h }
    end
  end
  return out
end

-- Everything the vessel absorbing us needs to fold our blueprint into theirs.
-- Parts are handed over with their live ENTITY ids: after the merge that's the
-- only way to find them again, because their coordinates are about to be
-- re-expressed in the other craft's frame (the engine re-parents them).
function dockManifest(port_uid)
  local node = dock.node
  if not node or not node.valid then return nil end
  local parts = {}
  for _, c in ipairs(node:children()) do
    local best, bd = nil, 1e9
    local known = eid_uid[c.id]
    if known and bp_by_uid[known] then best, bd = known, 0 end
    for u, d in pairs(known and {} or bp_by_uid) do
      local dx, dy, dz = (c.x or 0) - d.x, (c.y or 0) - d.y, (c.z or 0) - d.z
      local dd = dx * dx + dy * dy + dz * dz
      if dd < bd then bd, best = dd, u end
    end
    if best and bd < 0.06 then
      parts[#parts + 1] = { eid = c.id, uid = best, rec = bp_by_uid[best],
                            hp = part_hp[best] or 1.0 }
    end
  end
  local E = elib()
  return { name = node.name or "Module", parts = parts, portUid = port_uid,
           fuel = fuel, charge = elec.charge, piloted = piloting, crew = crewAboard,
           groups = E and E.packGroups(ctlGroups) or nil,
           controls = (clib() and ctlAxes) and clib().pack(ctlAxes) or nil }
end

-- The craft as it is NOW, for the fleet record flight_ops saves (a craft left
-- somewhere is rebuilt from it next session): every blueprint part still
-- aboard, plus the pooled fuel and charge. Unlike dockManifest it doesn't match
-- scene children by position, so nothing a staging or a rebuild re-based is
-- dropped from the list.
function fleetParts()
  if destroyed then return nil end
  local out = {}
  for u, d in pairs(bp_by_uid) do
    if not integ.gone[u] and (part_hp[u] or 1) > 0 then
      out[#out + 1] = d
      -- its wear rides in its state (packRecord keeps numbers), so a reload
      -- brings the dents back (load_bp) — nil when it is whole
      if type(d.st) == "table" then
        local h = part_hp[u] or 1
        d.st.hp = (h < 0.999) and math.floor(h * 1000 + 0.5) / 1000 or nil
      end
    end
  end
  table.sort(out, function(a, b) return (a.uid or 0) < (b.uid or 0) end)
  local E = elib()
  return { parts = out, fuel = fuel, charge = elec.charge, pod = podCrewed == true,
           probe = elec.probePart ~= nil, crew = crewAboard == true,
           station = stationUid, flown = hasFlown ~= false,
           groups = E and E.packGroups(ctlGroups) or nil,
           controls = (clib() and ctlAxes) and clib().pack(ctlAxes) or nil }
end

-- Stand down: our root is about to be retired by the merge. Release the pilot's
-- instruments so the absorbing craft owns the screen cleanly.
function dockAbsorbed()
  piloting = false
  crewAboard = false   -- they ride the craft that absorbs us now (it reads `crew`)
  throttle = 0.0
  silence_loops()
  dock.msg = "absorbed"
end

-- ── control transfer ───────────────────────────────────────────────────────
-- The pilot rides whichever pod you're flying. Undocking a lander and taking it
-- down is then one click instead of an EVA in orbit.
function releaseControl()
  if not piloting then return end
  piloting = false
  -- (the crew, if aboard, stay in their seat: you're only looking elsewhere)
  throttle = 0.0
  if dock.node and dock.node.valid then set_flames(dock.node, 0) end
  silence_loops()
  throttle_prev = 0.0
  set_hud(nil)
  set_navball(false)
end

function takeControl()
  local node = dock.node
  if destroyed or not node or not node.valid then return false end
  if not podCrewed then
    dock.msg = "no crew pod aboard — this craft can't be crewed"
    return false
  end
  local clt = crewLibNow()
  local tid = clt and clt.activeId and clt.activeId()
  if clt and tid and not memberSlot(tid) and not freeSeat(stationUid) then
    dock.msg = "every seat aboard is taken"
    return false
  end
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.node and v.node.id ~= node.id then
      if v.releaseControl then v.releaseControl() end
      -- The crew can only be in one seat: they leave the other craft's.
      if v.crewAboard and v.crewLeave then v.crewLeave() end
      if tid and v.unseatMember then v.unseatMember(tid) end
    end
  end
  if not astronaut or not astronaut.valid then astronaut = find("Astronaut") end
  -- Into a pod they vanish; an open COMMAND SEAT keeps its rider in view.
  if astronaut then astronaut.visible = podSeat == true end
  piloting = true
  crewAboard = true
  seatAvatarCheck()
  setStationOf(tid)
  set_navball(true)
  sas_mode, sas_last = "stability", "stability"
  log("control transferred to " .. (node.name or "vessel"))
  return true
end

-- FLY IT FROM HERE. Take the controls of this craft WITHOUT moving the crew:
-- a probe flown over its comms link, or a look at any craft you own. Whether
-- the controls actually answer is `controlState()` — a probe needs power and a
-- path home; a pod needs its crew in it. The crew stay wherever they are (on
-- foot at the base, or in another craft's seat).
function remoteControl()
  local node = dock.node
  if destroyed or not node or not node.valid then return false end
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.releaseControl and v.node and v.node.id ~= node.id then v.releaseControl() end
  end
  piloting = true
  set_navball(true)
  sas_mode, sas_last = "stability", "stability"
  hud_t = -10.0
  log("remote control: " .. (node.name or "vessel") .. (crewAboard and " (crew aboard)" or ""))
  return true
end

-- The crew are leaving this craft's seat for another one (a transfer): they
-- are no longer ours to carry.
function crewLeave()
  crewAboard = false
  if dock.node and dock.node.valid then seatCrew(dock.node, false) end
end

-- When the craft you were flying is gone (lost, recovered, absorbed), control
-- falls back: to the craft the crew is sitting in, or to the crew on foot.
function controlFallback(except_id)
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.node and v.node.valid and v.node.id ~= except_id and v.piloting then return v end
  end
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.node and v.node.valid and v.node.id ~= except_id and v.crewAboard and v.remoteControl then
      v.remoteControl()
      return v
    end
  end
  if not astronaut or not astronaut.valid then astronaut = find("Astronaut") end
  if astronaut then astronaut.visible = true end
  return nil
end

-- ── capture ────────────────────────────────────────────────────────────────
-- ONE side does the work. The piloted craft drives if there is one, otherwise
-- the lower node id — both controllers see identical geometry, so they agree on
-- who's master without a handshake and the latch never fires twice.
local function dock_is_master(node, v)
  if piloting ~= (v.piloting or false) then return piloting end
  return (node.id or 0) < (v.node.id or 0)
end

-- THE HARD DOCK'S SNAP. The merge welds the module where it met us: within
-- 3 cm and 1° once soft capture has done its work, but not exact. Here, in
-- OUR craft's frame (blueprint records and the parts' local poses only: no
-- world positions, nothing that moves on rails), the module is turned and
-- moved as one rigid piece so its port sits exactly on ours: axes collinear,
-- faces flush, petals interleaved. The pieces were already this close, so the
-- correction is a few millimetres; the compound is rebuilt (momentum kept).
function dockSnap(node, pend, man, remap, live)
  local mate = remap[man.portUid]
  local P = pend.port
  local Pm = P and bp_by_uid[P.uid]
  local Q = mate and bp_by_uid[mate]
  if not (P and Pm and Q and P.ax) then return end
  local am = { P.ax, P.ay, P.az }
  local km = { DOCKM.keyLocal(Pm) }
  local X, Y = DOCKM.partBasis(Q.yaw, Q.pitch, Q.roll)
  local aq = ((Q.att or "") == "radial") and X or Y
  if aq[1] * am[1] + aq[2] * am[2] + aq[3] * am[3] > 0 then aq = { -aq[1], -aq[2], -aq[3] } end
  local kq = { DOCKM.keyLocal(Q) }
  local A = { -am[1], -am[2], -am[3] }
  local Kx, Ky, Kz = DOCKM.matchKey(A[1], A[2], A[3], km[1], km[2], km[3], kq[1], kq[2], kq[3])
  if not Kx then return end
  -- (kq across aq, exactly, before the frame is built)
  local qx, qy, qz = DOCKM.across(kq[1], kq[2], kq[3], aq[1], aq[2], aq[3])
  if not qx then return end
  local R = DOCKM.frameRot(aq, { qx, qy, qz }, A, { Kx, Ky, Kz })
  local seat = (Pm.h or 0.28) * 0.5 + (Q.h or 0.28) * 0.5
  local T = { Pm.x + am[1] * seat, Pm.y + am[2] * seat, Pm.z + am[3] * seat }
  local Q0 = { Q.x, Q.y, Q.z }
  local function rot(v)
    return R[1][1] * v[1] + R[1][2] * v[2] + R[1][3] * v[3],
           R[2][1] * v[1] + R[2][2] * v[2] + R[2][3] * v[3],
           R[3][1] * v[1] + R[3][2] * v[2] + R[3][3] * v[3]
  end
  local _, _, _, th = DOCKM.rotVec(R)
  local moved = math.sqrt((T[1] - Q0[1]) ^ 2 + (T[2] - Q0[2]) ^ 2 + (T[3] - Q0[3]) ^ 2)
  local n = 0
  for _, pp in ipairs(man.parts) do
    local u, c = remap[pp.uid], live[pp.eid]
    local rec = u and bp_by_uid[u]
    if rec then
      local dx, dy, dz = rot({ (rec.x or 0) - Q0[1], (rec.y or 0) - Q0[2], (rec.z or 0) - Q0[3] })
      rec.x, rec.y, rec.z = T[1] + dx, T[2] + dy, T[3] + dz
      local Xb, Yb, Zb = DOCKM.partBasis(rec.yaw, rec.pitch, rec.roll)
      local Xn, Yn, Zn = { rot(Xb) }, { rot(Yb) }, { rot(Zb) }
      local pitch = math.asin(math.max(-1, math.min(1, -Zn[2])))
      local yaw, roll
      if math.abs(Zn[2]) > 1 - 1e-10 then yaw, roll = math.atan2(-Xn[3], Xn[1]), 0
      else yaw, roll = math.atan2(Zn[1], Zn[3]), math.atan2(Xn[2], Yn[2]) end
      rec.yaw, rec.pitch, rec.roll = yaw, pitch, roll
      if c and c.valid ~= false then
        c.x, c.y, c.z = rec.x, rec.y, rec.z
        if c.setAngles then c:setAngles(yaw, pitch, roll) end
      end
      n = n + 1
    end
  end
  log(string.format("DOCK SNAP: the module set exact — moved %.1f mm, turned %.2f°, %d parts", moved * 1000, math.deg(th), n))
  if assembly.rebuild then assembly.rebuild(node) end
end

-- Fold a captured module's blueprint into ours. Runs the tick AFTER the merge
-- was queued — by then every absorbed part is one of OUR children and its LOCAL
-- pose is already expressed in our frame, so we read the merged geometry
-- straight off the live nodes instead of re-deriving it from port maths.
-- Whatever the physics welded IS, by definition, where the parts are.
local function dock_absorb(node)
  local pend = dock.pending
  local man = pend.manifest
  local live = {}
  for _, c in ipairs(node:children()) do live[c.id] = c end
  local remap, absorbed = {}, {}
  for _, p in ipairs(man.parts) do
    local c = live[p.eid]
    if c then
      local u = dock.next_uid
      dock.next_uid = u + 1
      remap[p.uid] = u
      local E = elib()
      local rec = E and E.deepCopy(p.rec) or {}
      if not E then for k, val in pairs(p.rec) do rec[k] = val end end
      rec.uid = u
      rec.x, rec.y, rec.z = c.x or 0, c.y or 0, c.z or 0
      rec.yaw, rec.pitch, rec.roll = c.yaw or 0, c.pitch or 0, c.roll or 0
      rec.stage = 0                -- staging order is the host's business now
      -- A module's actuators arrive where they stood: that pose is now the
      -- part's rest pose (read off the live nodes above), so their joint
      -- positions start from zero here.
      if type(rec.st) == "table" and (rec.robo or "") ~= "" then
        rec.st.cur, rec.st.angle, rec.st.extension = 0, 0, 0
      end
      bp_by_uid[u] = rec
      part_hp[u] = p.hp
      eid_uid[p.eid] = u           -- exact, so the damage model needs no guess
      absorbed[#absorbed + 1] = u
    end
  end
  if #absorbed == 0 then
    dock.pending = nil
    dock.msg = "capture failed — the module's parts never arrived"
    return
  end
  if pend.snap then dockSnap(node, pend, man, remap, live) end
  for _, u in ipairs(absorbed) do
    local rec = bp_by_uid[u]
    rec.parent = remap[rec.parent or 0] or 0
  end
  -- RE-ROOT the module's tree at the port that mated, then hang that port off
  -- ours. Without the re-root, an undock at this seam would only take the part
  -- of the module BELOW the port with it — the module's own tree head, and
  -- everything between, would stay welded to us.
  local mate = remap[man.portUid]
  if mate then
    local function reroot(u)
      local pu = bp_by_uid[u] and bp_by_uid[u].parent or 0
      if pu == 0 or not bp_by_uid[pu] then return end
      reroot(pu)
      bp_by_uid[pu].parent = u
    end
    reroot(mate)
    bp_by_uid[mate].parent = pend.port.uid
  end
  -- Pools: the module's engines, tanks, batteries and panels are ours now, and
  -- it brings its own propellant and charge rather than diluting ours.
  for _, u in ipairs(absorbed) do
    local d = bp_by_uid[u]
    part_total = part_total + 1
    if (d.thrust or 0) > 0 then
      local ax, ay, az = part_axis(d)
      engines[#engines + 1] = { x = d.x, y = d.y, z = d.z, dx = ax, dy = ay, dz = az,
                                thrust = d.thrust, burn = d.burn or 1, uid = u, rec = d }
    end
    if (d.fuel or 0) > 0 then
      tanks[#tanks + 1] = { y = d.y, fuel = d.fuel, left = 0.0, ft = d.fuel_t or 0, uid = u }
      fuel_cap = fuel_cap + d.fuel
    end
  end
  fuelSort()
  fuelFill(math.min(fuel_cap, fuel + (man.fuel or 0)))
  -- Electronics: the module's parts carry their own state (each battery its own
  -- charge), so its devices, power and radios simply join ours; its action
  -- groups fold into ours (its group 1 fires with our group 1).
  integ.gen = integ.gen + 1
  elecRescan()
  do
    local E = elib()
    if E and man.groups then
      E.mergeGroups(ctlGroups, E.remapGroups(E.unpackGroups(man.groups), remap))
    end
    local C = clib()
    if C and man.controls then
      ctlAxes = C.merge(ctlAxes or C.newCtl(), C.remap(C.live(man.controls), remap))
    end
  end
  if man.crew then crewAboard = true end
  rescanSeats()
  -- The rescan pairs the seam for us: we just hung the module's port off ours
  -- in the tree, which is the same shape as a pair stacked in the VAB, so one
  -- rule covers both and there's no second place for latch state to go stale.
  dock_retree()
  dockRescan()
  dock.pending = nil
  dock.arm = time + DOCK_LOCKOUT
  dock.msg = string.format("DOCKED — %s (%d parts)", man.name or "module", #absorbed)
  log(dock.msg)
end

-- ── undock ─────────────────────────────────────────────────────────────────
-- Cut the stack at a mated seam and send the far half away as a LIVE craft.
-- Same topological split a decoupler fires (the mate plus everything hanging
-- off it departs, the pod side stays), but rooted at the Vessel prefab so its
-- own controller wakes up — with the blueprint we hand it at the seam.
function undock(port_uid)
  local node = dock.node
  if destroyed or not node or not node.valid then return false end
  local p = port_uid and dock_port(port_uid)
  if not p then
    for _, q in ipairs(dock.ports) do
      if q.mate then p = q; break end
    end
  end
  if not p or not p.mate then
    dock.msg = "nothing docked at that port"
    return false
  end
  local info = assembly.info(node)
  if not info then return false end
  r2Before(node)
  -- The seam sits BETWEEN the two mated ports, and each keeps its own half —
  -- so the cut anchor is whichever of the pair hangs off the other, whichever
  -- row you clicked. Anchoring on the near side instead would send our own
  -- port away with the module (and it did, until this).
  local anchor = p.mate
  if (bp_by_uid[p.uid] or {}).parent == p.mate then anchor = p.uid end
  local dep = axial_departing(anchor)
  local parts_nodes = {}
  for _, child in ipairs(node:children()) do
    if child_departs_axial(child, anchor) then parts_nodes[#parts_nodes + 1] = child end
  end
  if #parts_nodes == 0 then
    dock.msg = "undock failed — the module's parts aren't on this hull"
    return false
  end
  -- The departing half's own blueprint, in OUR frame for now; the split
  -- callback re-bases it onto the new craft's origin once physics has placed it.
  local sub, n = { parts = {} }, 0
  local E = elib()
  local sub_charge = 0
  for u in pairs(dep) do
    local d = bp_by_uid[u]
    if d then
      n = n + 1
      if type(d.st) == "table" and d.st.charge then sub_charge = sub_charge + d.st.charge end
      -- A copy for the save (handed over through save.set): the record's live
      -- state (`st` — a battery's charge, a panel's fold) and its modules ride
      -- along packed (electronics packRecord), no longer shared with ours.
      -- (save.set holds 16 levels since floptle/0422; the packing stays the
      -- one record format the fleet and the dock both read.)
      local rec = E and E.packRecord(d) or {}
      if not E then for k, val in pairs(d) do rec[k] = val end end
      rec.stage = 0
      if not dep[rec.parent or 0] then rec.parent = 0 end -- the seam is its new root
      sub.parts[n] = rec
    end
  end
  -- Pools + bookkeeping: fuel/engines/tanks by the departing set, then strip
  -- the module out of the blueprint, the devices and the electrical system.
  -- What the module takes with it is what `drop_departing` stops counting as
  -- ours — it flies away with its own propellant, not a full set of tanks.
  local fuel_before = fuel
  drop_departing(anchor)
  sub.fuel = math.max(0.0, fuel_before - fuel)
  -- The departing half gets the SAME re-capture lockout we do. The lockout is
  -- per-craft, and a freshly born controller has no memory of having just
  -- undocked — without this it would drive a capture on its very first frame,
  -- still touching the port it just left, and the module would never get clear.
  sub.lockout = DOCK_LOCKOUT
  for _, dev in pairs(DEVICES) do
    local keep = {}
    for _, u in ipairs(dev.parts) do
      if dep[u] then
        dev.pose[u], dev.nodes[u] = nil, nil
      else
        keep[#keep + 1] = u
      end
    end
    dev.parts = keep
  end
  for u in pairs(dep) do
    local d = bp_by_uid[u]
    if d then
      part_total = math.max(0, part_total - 1)
      bp_by_uid[u], part_hp[u] = nil, nil
      panim[u], ppose[u], pnode[u] = nil, nil, nil
    end
  end
  -- Charge splits by battery: each battery's charge rides in its own record, so
  -- the module leaves with exactly what ITS batteries hold. Its action groups
  -- go with the parts they name; ours keep the rest.
  sub.charge = sub_charge
  if E then
    local dset = {}
    for u in pairs(dep) do dset[u] = true end
    sub.groups = E.packGroups(E.subsetGroups(ctlGroups, dset))
    if clib() and ctlAxes then sub.controls = clib().pack(clib().subset(ctlAxes, dset)) end
    E.pruneGroups(ctlGroups, aboardRecs())
  end
  integ.gen = integ.gen + 1
  elecRescan()
  for eid, u in pairs(eid_uid) do
    if dep[u] then eid_uid[eid] = nil end
  end
  -- The seam's world pose, captured BEFORE the split (the closure pushes the
  -- module out along the port's own axis, so it leaves squarely, not sideways).
  local sx, sy, sz, sax, say, saz = dock_world(node, info, p)
  local name = (craftName ~= "Vessel" and craftName or (node.name or "Vessel")) .. " module"
  quench(parts_nodes)
  sfx3(SFX.clamp, sx, sy, sz, 0.7, 1.25)
  assembly.split(node, parts_nodes, function(stage)
    if not stage then return end
    local si = assembly.info(stage)
    if si and si.origin then
      -- Re-base the handoff blueprint onto the new craft's own origin: its
      -- controller reads part coordinates as offsets from ITS root, and the
      -- split rooted it at the detached half's centre of mass. Both halves
      -- share our orientation at this instant, so the basis is still ours.
      local rx, up, rz = basis(node)
      local bx2, by2, bz2 = base_of(node, assembly.info(node) or si)
      local dx, dy, dz = si.origin.x - bx2, si.origin.y - by2, si.origin.z - bz2
      local lx = dx * rx.x + dy * rx.y + dz * rx.z
      local ly = dx * up.x + dy * up.y + dz * up.z
      local lz = dx * rz.x + dy * rz.y + dz * rz.z
      for _, rec in ipairs(sub.parts) do
        rec.x, rec.y, rec.z = rec.x - lx, rec.y - ly, rec.z - lz
      end
      sub.name = name
      save.set("dock.handoff." .. tostring(stage.id or 0), sub)
      -- A gentle spring push ALONG the port axis — enough to open a gap the
      -- solver won't immediately re-close, nowhere near enough to tumble it.
      -- The axis is signed against where the departing half actually sits: a
      -- mated port's own +Y points INTO its partner, so taking it at face value
      -- shoves the module straight back through the ship it just left.
      local ax, ay, az = sax, say, saz
      if (si.com.x - sx) * ax + (si.com.y - sy) * ay + (si.com.z - sz) * az < 0 then
        ax, ay, az = -ax, -ay, -az
      end
      local dv, m = 0.45, math.max(0.1, si.mass or 1.0)
      assembly.teleport(stage, vec3(si.origin.x + ax * 0.18,
                                    si.origin.y + ay * 0.18,
                                    si.origin.z + az * 0.18))
      assembly.impulseAt(stage, vec3(ax * dv * m, ay * dv * m, az * dv * m), si.com)
      local fx = fxd()
      if fx then fx.separate(si.com.x, si.com.y, si.com.z) else spawnEffect("SepPuff", si.com.x, si.com.y, si.com.z) end
    end
    stage.name = name
    log(string.format("UNDOCKED — %s away (%d parts)", name, n))
  end, "Vessel")
  -- Both halves of the seam come free — whichever side actually departed, the
  -- surviving port must not be left believing it's still mated.
  local partner = dock_port(p.mate)
  p.mate = nil
  if partner then partner.mate = nil end
  dock_retree()
  dockRescan()
  dock.arm = time + DOCK_LOCKOUT
  dock.msg = "UNDOCKED"
  return true
end

-- ── the docking tick ───────────────────────────────────────────────────────
-- Publish the approach readout, run soft-capture magnetism, drive the port
-- lamps, and take the latch when the geometry says we've arrived. Global so
-- `fixedUpdate` can call it without spending one of its last upvalues.
function dockTick(node, info, dt)
  dock.node = node
  if destroyed or #dock.ports == 0 then
    dock.target = nil
    return
  end
  if dock.pending then
    -- The engine re-parents the absorbed part nodes when it performs the merge,
    -- at the end of the tick that queued it. Fold the module in the moment they
    -- actually show up as OUR children — asking whether the part COUNT grew
    -- would be fooled by a merge that lands inside this same pass (and by a
    -- part breaking off in the meantime).
    local want = dock.pending.manifest.parts[1]
    local arrived = false
    for _, c in ipairs(node:children()) do
      if want and c.id == want.eid then
        arrived = true
        break
      end
    end
    if arrived then
      dock_absorb(node)
    elseif time - dock.pending.t > 2.0 then
      dock.pending = nil
      dock.msg = "capture timed out"
    end
    return
  end
  local mine = {}
  for _, p in ipairs(dock.ports) do
    if p.mate then
      dock_lamp(node, p, "latched")
    elseif not p.buried then
      local x, y, z, ax, ay, az, kx, ky, kz = dock_world(node, info, p)
      mine[#mine + 1] = { p = p, x = x, y = y, z = z, ax = ax, ay = ay, az = az, kx = kx, ky = ky, kz = kz }
    else
      dock_lamp(node, p, "off")
    end
  end
  if #mine == 0 then
    dock.target = nil
    return
  end
  -- Nearest facing pair across every other live craft. Craft obviously out of
  -- reach are rejected on their ROOT position first — a system full of parked
  -- probes must not cost a per-port sweep sixty times a second.
  local best
  local bx0, by0, bz0 = base_of(node, info)
  for _, v in ipairs(findScripts("vessel_controller")) do
    local far = false
    if v.node and v.node.valid then
      local tp = v.node.tickPos or v.node   -- (tick pose against our tick origin)
      local dx0, dy0, dz0 = tp.x - bx0, tp.y - by0, tp.z - bz0
      far = (dx0 * dx0 + dy0 * dy0 + dz0 * dz0) > (DOCK_ASSIST_R + 60.0) ^ 2
    end
    if v.dockFaces and v.node and v.node.valid and v.node.id ~= node.id and not far then
      for _, q in ipairs(v.dockFaces()) do
        for _, m in ipairs(mine) do
          local dx, dy, dz = q.x - m.x, q.y - m.y, q.z - m.z
          local d = math.sqrt(dx * dx + dy * dy + dz * dz)
          local align = -(m.ax * q.ax + m.ay * q.ay + m.az * q.az)
          -- A LOCKED target always wins, however far or however crooked: once
          -- you've picked a berth the readout must keep describing THAT berth,
          -- or the numbers you're flying on jump to a nearer port mid-approach.
          local locked = dock.lock and dock.lock.id == v.node.id
            and dock.lock.uid == q.uid and (not dock.lock.mine or dock.lock.mine == m.p.uid)
          if (locked or (d < DOCK_ASSIST_R and align > 0.15))
            and (not best or best.locked ~= true) and (locked or not best or d < best.d) then
            local inv = 1.0 / math.max(d, 1e-6)
            best = { d = d, align = align, m = m, q = q, v = v, locked = locked,
                     ux = dx * inv, uy = dy * inv, uz = dz * inv }
          end
        end
      end
    end
  end
  for _, m in ipairs(mine) do
    dock_lamp(node, m.p, (best and best.m == m) and "near" or "off")
  end
  if not best then
    dock.target = nil
    return
  end
  -- Relative motion at the seam (theirs minus ours): + closing = coming together.
  local oi = assembly.info(best.v.node)
  local rvx = (oi and oi.vel.x or 0) - info.vel.x
  local rvy = (oi and oi.vel.y or 0) - info.vel.y
  local rvz = (oi and oi.vel.z or 0) - info.vel.z
  local closing = -(rvx * best.ux + rvy * best.uy + rvz * best.uz)
  local drift = math.sqrt(rvx * rvx + rvy * rvy + rvz * rvz)
  local proj = (best.q.x - best.m.x) * best.m.ax + (best.q.y - best.m.y) * best.m.ay
             + (best.q.z - best.m.z) * best.m.az
  dock.target = {
    name = best.v.node.name or "craft", range = best.d, align = best.align,
    closing = closing, drift = drift,
    lateral = math.sqrt(math.max(0.0, best.d * best.d - proj * proj)),
    port = best.m.p.uid, uid = best.q.uid, id = best.v.node.id,
    locked = best.locked or false,
    -- Geometry the autopilot and the guide lines fly on: both port faces in
    -- world space, the APPROACH CORRIDOR (down the target's own normal — you
    -- come in along their centreline, not straight at them from wherever you
    -- happen to be), and their velocity so we match it instead of the world's.
    mx = best.m.x, my = best.m.y, mz = best.m.z,
    qx = best.q.x, qy = best.q.y, qz = best.q.z,
    max = -best.q.ax, may = -best.q.ay, maz = -best.q.az,
    vx = oi and oi.vel.x or 0, vy = oi and oi.vel.y or 0, vz = oi and oi.vel.z or 0,
  }
  -- SOFT CAPTURE and HARD DOCK (dockCapture, below): inside a metre, square
  -- within 20° and slow, the pair is drawn face to face and turned coaxial,
  -- rolled to the nearest petal slot; once flush and true it latches and the
  -- seam is set exact (dock_absorb). Outside it, the long, gentle magnet.
  local cap = dockCapture(node, info, best, oi, dt)
  -- THE LONG MAGNET: a spring toward their port plus a damper on the relative
  -- motion. The SPRING is applied at our port, so it swings the craft square as
  -- well as pulling it in; the DAMPER goes through the centre of mass, because
  -- braking is not supposed to be a steering input. Both craft run this and
  -- each pulls only ITSELF. Everything scales with our own mass.
  if not cap and dock.assist and best.align > 0.35 and not info.anchored and time > dock.arm then
    local m = math.max(0.1, info.mass or 1.0)
    -- (never below zero: a LOCKED berth is followed at any range, and past
    -- DOCK_ASSIST_R this went negative — a repulsion growing with distance,
    -- which threw two craft 40 m apart away from each other at 125 m/s)
    local pull = math.max(0.0, math.min(1.0, (DOCK_ASSIST_R - best.d) / DOCK_ASSIST_R)) * best.align
    local k, c = 2.2 * m * pull, 1.6 * m * pull
    assembly.forceAt(node, vec3(best.ux * k, best.uy * k, best.uz * k),
      vec3(best.m.x, best.m.y, best.m.z))
    assembly.force(node, vec3(rvx * c, rvy * c, rvz * c))
  end
  -- LATCH: the faces flush and true (or held close and nearly so for a few
  -- seconds), past the lockout that stops a fresh undock snapping back on.
  if cap == "seat" and dock_is_master(node, best.v) then
    local man = best.v.dockManifest and best.v.dockManifest(best.q.uid)
    if man and #man.parts > 0 then
      -- No tyre joint may hang off either hull through the weld.
      r2Before(node)
      if best.v.r2Before then best.v.r2Before(best.v.node) end
      best.v.dockAbsorbed()
      assembly.merge(node, best.v.node)
      dock.pending = { port = best.m.p, manifest = man, t = time, snap = true }
      log(string.format("DOCK SEAT: gap %.3f m, misalignment %.2f° (axis %.2f°), drift %.3f m/s after %.1f s of soft capture",
        dock.soft and dock.soft.gap or -1, dock.soft and dock.soft.th or -1, dock.soft and dock.soft.ang or -1,
        dock.soft and dock.soft.drift or -1, dock.soft and (time - dock.soft.t0) or -1))
      dock.target = nil
      dock.soft = nil
      add_shake(0.06)
      sfx3(SFX.clamp, best.m.x, best.m.y, best.m.z, 0.85, 1.15)
      dock.msg = "hard dock"
    end
  end
end

-- SOFT CAPTURE → HARD DOCK. Ty: the docked pair sat crooked — the old latch
-- welded whatever pose the ports met at (up to 37° off). Now:
--   SOFT  within `range` m of seating (our port's centre against where it
--         belongs: out along their axis, faces flush), within `angle` and
--         slower than `drift`: a critically damped spring on the gap and on
--         the full misalignment (axis AND roll, to the nearest petal slot)
--         draws the pair together. The MASTER applies it to both craft as
--         equal and opposite impulses (and couples) on the REDUCED mass and
--         inertia, so momentum is conserved and neither craft is kicked: a
--         probe and a station move by their shares. Eased in over half a
--         second, its acceleration capped.
--   HARD  flush and true (`seatGap`, `seatAng`, `seatDrift`), or held within
--         8 cm and 2.5° for `patience` s: → "seat", and the master merges.
--         dock_absorb then sets the seam EXACT in the merged craft's frame.
-- Tick poses throughout (dock_world, assembly.info). → nil | "soft" | "seat".
DOCK_CAP = { range = 1.0, angle = math.rad(20), drift = 0.8, seatGap = 0.03, seatAng = 1.0,
             seatDrift = 0.05, patience = 4.0, kp = 4.0, kd = 4.0, kpr = 4.0, kdr = 4.0,
             amax = 2.0, alphamax = 1.5 }
local function inertia_mean(i)
  local I = i and i.inertia
  if not (I and I[1] and I[2] and I[3]) then return (i and i.mass or 1) * 0.5 end
  return math.max(1e-4, (I[1].x + I[2].y + I[3].z) / 3)
end
-- An angular impulse L as a pure couple about cm (the safety net's form).
function DOCKM.couple(n, Lx, Ly, Lz, cm)
  local Ll = math.sqrt(Lx * Lx + Ly * Ly + Lz * Lz)
  if Ll < 1e-12 then return end
  local ex, ey, ez = Ly, -Lx, 0
  if math.abs(Lz) > math.abs(Lx) and math.abs(Lz) > math.abs(Ly) then ex, ey, ez = Lz, 0, -Lx end
  local el = math.sqrt(ex * ex + ey * ey + ez * ez)
  ex, ey, ez = ex / el, ey / el, ez / el
  local jx = (Ly * ez - Lz * ey) * 0.5
  local jy = (Lz * ex - Lx * ez) * 0.5
  local jz = (Lx * ey - Ly * ex) * 0.5
  assembly.impulseAt(n, vec3(jx, jy, jz), vec3(cm.x + ex, cm.y + ey, cm.z + ez))
  assembly.impulseAt(n, vec3(-jx, -jy, -jz), vec3(cm.x - ex, cm.y - ey, cm.z - ez))
end
function dockCapture(node, info, best, oi, dt)
  local C = DOCK_CAP
  local m, q = best.m, best.q
  if not (oi and oi.com and info.com and dock.assist and m.kx and q.kx) or info.anchored or oi.anchored
    or time <= dock.arm then
    dock.soft = nil
    return nil
  end
  local seat = ((bp_by_uid[m.p.uid] or {}).h or 0.28) * 0.5 + (q.h or 0.28) * 0.5
  local ex, ey, ez = q.x + q.ax * seat - m.x, q.y + q.ay * seat - m.y, q.z + q.az * seat - m.z
  local gap = math.sqrt(ex * ex + ey * ey + ez * ez)
  local ang = math.acos(math.max(-1, math.min(1, -(m.ax * q.ax + m.ay * q.ay + m.az * q.az))))
  -- OUR VELOCITY RELATIVE TO THEIRS, from how the seam itself moves (the gap
  -- vector, both ends tick poses of the same read, tick to tick): the other
  -- craft's assembly.info vel read a steady 0.31 m/s that wasn't there (an
  -- unpiloted craft), which stalled the damper against the spring 0.32 m out.
  local S0 = dock.soft
  local rvx, rvy, rvz = info.vel.x - oi.vel.x, info.vel.y - oi.vel.y, info.vel.z - oi.vel.z
  if S0 and S0.ex and dt and dt > 0 then
    local nx, ny, nz = -(ex - S0.ex) / dt, -(ey - S0.ey) / dt, -(ez - S0.ez) / dt
    local pv = S0.rv or { nx, ny, nz }
    rvx, rvy, rvz = pv[1] + (nx - pv[1]) * 0.5, pv[2] + (ny - pv[2]) * 0.5, pv[3] + (nz - pv[3]) * 0.5
  end
  local drift = math.sqrt(rvx * rvx + rvy * rvy + rvz * rvz)
  if not (S0 and S0.ex) then drift = 0 end   -- (unmeasured on the first tick: judged from the next)
  -- (a little hysteresis: once held, it lets go only further out)
  local hold = dock.soft and 1.3 or 1.0
  if gap > C.range * hold or ang > C.angle * hold or drift > C.drift * hold then
    dock.soft = nil
    return nil
  end
  local A = { -q.ax, -q.ay, -q.az }
  local Kx, Ky, Kz = DOCKM.matchKey(A[1], A[2], A[3], q.kx, q.ky, q.kz, m.kx, m.ky, m.kz)
  if not Kx then return nil end
  local R = DOCKM.frameRot({ m.ax, m.ay, m.az }, { m.kx, m.ky, m.kz }, A, { Kx, Ky, Kz })
  local rx, ry, rz, th = DOCKM.rotVec(R)
  local w1, w2 = info.angVel or vec3(0, 0, 0), oi.angVel or vec3(0, 0, 0)
  local wrx, wry, wrz = w1.x - w2.x, w1.y - w2.y, w1.z - w2.z
  local wr = math.sqrt(wrx * wrx + wry * wry + wrz * wrz)
  if not dock.soft then
    dock.soft = { t0 = time }
    log(string.format("DOCK SOFT CAPTURE: gap %.2f m, misaligned %.1f° (axis %.1f°), drift %.2f m/s",
      gap, math.deg(th), math.deg(ang), drift))
  end
  local S = dock.soft
  S.gap, S.th, S.ang, S.drift, S.wr = gap, math.deg(th), math.deg(ang), drift, wr
  S.rv = (S0 and S0.ex) and { rvx, rvy, rvz } or nil   -- (measured from the second tick on)
  S.ex, S.ey, S.ez = ex, ey, ez
  local held = time - S.t0
  if (gap < C.seatGap and S.th < C.seatAng and drift < C.seatDrift and wr < 0.05)
    or (held > C.patience and gap < 0.08 and S.th < 2.5) then
    return "seat"
  end
  if not dock_is_master(node, best.v) then return "soft" end
  local m1, m2 = math.max(0.01, info.mass or 1), math.max(0.01, oi.mass or 1)
  local mu = m1 * m2 / (m1 + m2)
  local ramp = math.min(1.0, held / 0.5)
  local ax_, ay_, az_ = (C.kp * ex - C.kd * rvx) * ramp, (C.kp * ey - C.kd * rvy) * ramp, (C.kp * ez - C.kd * rvz) * ramp
  local al = math.sqrt(ax_ * ax_ + ay_ * ay_ + az_ * az_)
  if al > C.amax then ax_, ay_, az_ = ax_ * C.amax / al, ay_ * C.amax / al, az_ * C.amax / al end
  local jx, jy, jz = mu * ax_ * dt, mu * ay_ * dt, mu * az_ * dt
  assembly.impulseAt(node, vec3(jx, jy, jz), info.com)
  assembly.impulseAt(best.v.node, vec3(-jx, -jy, -jz), oi.com)
  local I1, I2 = inertia_mean(info), inertia_mean(oi)
  local Ir = I1 * I2 / (I1 + I2)
  local bx_, by_, bz_ = (C.kpr * rx - C.kdr * wrx) * ramp, (C.kpr * ry - C.kdr * wry) * ramp, (C.kpr * rz - C.kdr * wrz) * ramp
  local bl = math.sqrt(bx_ * bx_ + by_ * by_ + bz_ * bz_)
  if bl > C.alphamax then bx_, by_, bz_ = bx_ * C.alphamax / bl, by_ * C.alphamax / bl, bz_ * C.alphamax / bl end
  local Lx, Ly, Lz = Ir * bx_ * dt, Ir * by_ * dt, Ir * bz_ * dt
  DOCKM.couple(node, Lx, Ly, Lz, info.com)
  DOCKM.couple(best.v.node, -Lx, -Ly, -Lz, oi.com)
  return "soft"
end

-- ── RCS ─────────────────────────────────────────────────────────────────────
-- Pooled translation authority. Every fitted block adds thrust and the push
-- goes through the CENTRE OF MASS — a deliberate simplification, and the one
-- that makes docking flyable. A real block set fires asymmetric nozzles and you
-- spend the whole approach fighting the spin they induce; here a lopsided set
-- costs you nothing but looks wrong. That is the right trade for a control
-- whose entire job is 5 cm corrections.
--
--   H / N   translate FORE / AFT — along the nose, the axis a stack docks on
--   J / L   translate left / right
--   I / K   translate up / down
--   R       RCS on / off (also a row in the peripherals console)
local RCS_BURN = 0.06   -- fuel per second per block at full deflection
local rcs_plumes = nil  -- uid → the block's plume node, resolved once

-- Every fitted block's world position + its share of the push, plus the pooled
-- thrust. Also where the plume nodes get cached.
local function rcs_total()
  local t, n = 0.0, 0
  for _, u in ipairs(DEVICES.rcs.parts) do
    local d = bp_by_uid[u]
    -- each block's own switch (an action) as well as the bus master
    if d and not (d.st and d.st.rcs == false) then
      t = t + (d.rcs_thrust or 0)
      n = n + 1
    end
  end
  return t, n
end

-- Light or stop every block's plume together. The blocks fire as a set, so one
-- tell for the set is honest — and it means a ringed craft doesn't flicker.
local function rcs_plume(node, on, mag)
  if not rcs_plumes then rcs_plumes = {} end
  for _, u in ipairs(DEVICES.rcs.parts) do
    local pn = rcs_plumes[u]
    if not (pn and pn.valid) then
      pn = nil
      local c = child_of_uid(node, u)
      if c then
        for _, g in ipairs(c:children()) do
          if g.name == "RCS Plume" then pn = g end
        end
      end
      rcs_plumes[u] = pn
    end
    if pn then
      local ps = pn:particles()
      if ps then
        if on and not ps:isPlaying() then ps:play() end
        if not on and ps:isPlaying() then ps:stop() end
        if on then ps:setIntensity(0.25 + mag * 0.7) end
      end
      local l = pn:getcomponent("PointLight")
      if l then l.intensity = on and (0.4 + mag * 1.6) or 0.0 end
    end
  end
end

-- The DOCKING AUTOPILOT's translation command, in the VESSEL frame
-- (right, nose, forward). It flies the approach the way you would if you were
-- patient: kill the lateral offset first, and only close along the axis once
-- you're near the centreline — then close slowly, slower the nearer you get.
-- Returns nil when there's nothing to fly toward.
local function rcs_auto_cmd(node, info)
  local t = dock.target
  if not (dock.auto and t and t.mx) then return nil end
  local rx, up, rz = basis(node)
  local fwd = { x = -rz.x, y = -rz.y, z = -rz.z }
  local right = {}
  right.x, right.y, right.z = cross(fwd.x, fwd.y, fwd.z, up.x, up.y, up.z)
  -- Offset from OUR port to THEIRS, split into "along their axis" (the
  -- approach corridor) and "across it" (the miss).
  local dx, dy, dz = t.qx - t.mx, t.qy - t.my, t.qz - t.mz
  local along = dx * t.max + dy * t.may + dz * t.maz
  local ox, oy, oz = dx - t.max * along, dy - t.may * along, dz - t.maz * along
  local lat = math.sqrt(ox * ox + oy * oy + oz * oz)
  -- Desired velocity: cancel the miss at ~0.4 m/s, close at a rate that falls
  -- off with range and waits for the centreline.
  local wx, wy, wz = 0.0, 0.0, 0.0
  if lat > 0.02 then
    local s = math.min(0.4, lat * 0.8) / lat
    wx, wy, wz = ox * s, oy * s, oz * s
  end
  local close = (lat < 0.25) and math.min(0.35, math.max(0.06, t.range * 0.4)) or 0.0
  wx = wx + t.max * close
  wy = wy + t.may * close
  wz = wz + t.maz * close
  -- ...and steer toward it: command = (want − have), clamped to the stick.
  local ex = wx - (info.vel.x - (t.vx or 0))
  local ey = wy - (info.vel.y - (t.vy or 0))
  local ez = wz - (info.vel.z - (t.vz or 0))
  local el = math.sqrt(ex * ex + ey * ey + ez * ez)
  if el < 0.01 then return 0, 0, 0 end
  local g = math.min(1.0, el * 3.0) / el
  ex, ey, ez = ex * g, ey * g, ez * g
  -- Same ordering the stick uses: (right, fore along the nose, seat-up).
  return ex * right.x + ey * right.y + ez * right.z,
         ex * up.x + ey * up.y + ez * up.z,
         ex * fwd.x + ey * fwd.y + ez * fwd.z
end

-- Read the stick (or the autopilot), push, burn, and light the plumes. Global
-- so `fixedUpdate` can call it without spending one of its last upvalues.
function rcsTick(node, info, dt)
  local dev = DEVICES.rcs
  if destroyed or #dev.parts == 0 then
    rcs.firing, rcs.cmd = false, 0.0
    return
  end
  local n_on
  rcs.thrust, n_on = rcs_total()
  -- Vessel-frame command: (right, FORE along the nose, up out of the seat).
  local tx, ty, tz = 0, 0, 0
  if piloting and not dock.map and elec.control ~= false then
    tx = (input.key("l") and 1 or 0) - (input.key("j") and 1 or 0)
    ty = (input.key("h") and 1 or 0) - (input.key("n") and 1 or 0)
    tz = (input.key("i") and 1 or 0) - (input.key("k") and 1 or 0)
  end
  local manual = (tx ~= 0 or ty ~= 0 or tz ~= 0)
  if not manual then
    -- The autopilot only ever has the stick when you don't.
    local ax, ay, az = rcs_auto_cmd(node, info)
    if ax then tx, ty, tz = ax, ay, az end
  end
  local mag = math.sqrt(tx * tx + ty * ty + tz * tz)
  local live = dev.on and mag > 0.01 and fuel > 0 and not info.anchored
    and rcs.thrust > 0
  rcs.firing, rcs.cmd = live, live and math.min(1.0, mag) or 0.0
  if not live then
    rcs_plume(node, false, 0)
    return
  end
  mag = math.min(1.0, mag)
  local inv = 1.0 / math.sqrt(tx * tx + ty * ty + tz * tz)
  tx, ty, tz = tx * inv, ty * inv, tz * inv
  -- Vessel frame → world. `ty` rides the NOSE (`up` is the stack axis here),
  -- which is what you want on a stack: H closes the gap, N backs off. `tz`
  -- rides the seat's up, which is the hull's −Z column.
  local rx, up, rz = basis(node)
  local fx, fy, fz = -rz.x, -rz.y, -rz.z
  local rgx, rgy, rgz = cross(fx, fy, fz, up.x, up.y, up.z)
  local wx = rgx * tx + up.x * ty + fx * tz
  local wy = rgy * tx + up.y * ty + fy * tz
  local wz = rgz * tx + up.z * ty + fz * tz
  -- The physics weighs the craft wet (massSync): a full craft translates slower.
  local f = rcs.thrust * mag
  assembly.force(node, vec3(wx * f, wy * f, wz * f))
  fuelDraw((n_on or #dev.parts) * RCS_BURN * mag * dt)
  rcs_plume(node, true, mag)
end

-- ── hull contact (INTERIM) ──────────────────────────────────────────────────
-- The engine's solver has no body-vs-body pass: two separated vessels pass
-- straight through each other, which makes a station something you fly through
-- rather than dock with. Until the engine grows real compound-vs-compound
-- contacts (task floptle/0032), this is a game-side stand-in.
--
-- Every part is one sphere at its SMALLEST half-dimension. Deliberately
-- conservative: an approximation that under-reports is a bumper you can still
-- dock through, while one that over-reports is a force field that shoves the
-- port away before it can ever latch. Overlaps push apart with a spring-damper
-- applied AT the contact, so a glancing hit spins you the way it should.
-- DOCKING PORTS ARE EXEMPT — they have to touch to latch.
local BUMP_K, BUMP_C = 55.0, 10.0
local bump_cache = { t = -1.0, list = nil, radius = 0.0 }

local function part_radius(d)
  local wide = math.max(d.rx or 0, d.rz or 0)
  if wide <= 0 then wide = (d.h or 1.0) * 0.5 end
  return math.max(0.12, math.min(wide, (d.h or 1.0) * 0.5))
end

-- Our live hull, as world spheres — cached per tick because every other vessel
-- in range asks for it, and both sides of a pair ask every tick.
function hullSpheres()
  if bump_cache.t == time and bump_cache.list then return bump_cache.list, bump_cache.radius end
  local node = dock.node
  local out = {}
  bump_cache.t, bump_cache.list, bump_cache.radius = time, out, 0.0
  if destroyed or not node or not node.valid then return out, 0.0 end
  local info = assembly.info(node)
  if not info then return out, 0.0 end
  local rx, up, rz = basis(node)
  local bx, by, bz = base_of(node, info)
  local reach = 0.0
  local rxx, rxy, rxz, upx, upy, upz = rx.x, rx.y, rx.z, up.x, up.y, up.z
  local rzx, rzy, rzz = rz.x, rz.y, rz.z
  for u, d in pairs(bp_by_uid) do
    if (d.dock or 0) ~= 1 and (part_hp[u] or 0) > 0 then
      local r = part_radius(d)
      out[#out + 1] = {
        x = bx + rxx * d.x + upx * d.y + rzx * d.z,
        y = by + rxy * d.x + upy * d.y + rzy * d.z,
        z = bz + rxz * d.x + upz * d.y + rzz * d.z,
        r = r,
      }
      local off = math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z) + r
      if off > reach then reach = off end
    end
  end
  bump_cache.radius = reach
  return out, reach
end

-- How far the live hull reaches from the craft's base: the `reach` that
-- hullSpheres returns, without placing a ball per part. Cached per part set
-- (integ.gen steps when a part breaks off or arrives), so hullBump only lays
-- out the balls — a table per part, every tick — when another craft is close
-- enough to touch (perfbench g_launch_release: 1,000 balls a tick for nobody).
HULL_REACH = { gen = -1, src = nil, reach = 0.0, n = 0 }
function hullReachNow()
  if destroyed then return 0.0, 0 end
  local H = HULL_REACH
  if H.gen ~= integ.gen or H.src ~= bp_by_uid then
    local reach, n = 0.0, 0
    for u, d in pairs(bp_by_uid) do
      if (d.dock or 0) ~= 1 and (part_hp[u] or 0) > 0 then
        n = n + 1
        local off = math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z) + part_radius(d)
        if off > reach then reach = off end
      end
    end
    H.gen, H.src, H.reach, H.n = integ.gen, bp_by_uid, reach, n
  end
  return H.reach, H.n
end

function hullBump(node, info, dt)
  if destroyed or info.anchored then return end
  local my_reach, my_n = hullReachNow()
  if my_n == 0 then return end
  local mine = nil
  local m = math.max(0.1, info.mass or 1.0)
  local bx, by, bz = base_of(node, info)
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.hullSpheres and v.node and v.node.valid and v.node.id ~= node.id then
      local dx0, dy0, dz0 = v.node.x - bx, v.node.y - by, v.node.z - bz
      local d0 = math.sqrt(dx0 * dx0 + dy0 * dy0 + dz0 * dz0)
      local their_reach
      if v.hullReachNow then their_reach = v.hullReachNow() else their_reach = select(2, v.hullSpheres()) end
      local theirs = (d0 < my_reach + their_reach + 2.0) and v.hullSpheres() or nil
      if theirs and #theirs > 0 then
        if not mine then mine = hullSpheres() end
        local oi = assembly.info(v.node)
        local ovx = oi and oi.vel.x or 0
        local ovy = oi and oi.vel.y or 0
        local ovz = oi and oi.vel.z or 0
        for _, a in ipairs(mine) do
          for _, b in ipairs(theirs) do
            local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
            local dd = dx * dx + dy * dy + dz * dz
            local sum = a.r + b.r
            if dd < sum * sum and dd > 1e-9 then
              local dist = math.sqrt(dd)
              local ux, uy, uz = dx / dist, dy / dist, dz / dist
              -- Spring out of the overlap...
              local push = math.min(sum - dist, 0.6) * BUMP_K * m
              -- ...and damp the CLOSING component only, so resting contact
              -- settles instead of pumping energy into a stack of parts.
              local rvx = info.vel.x - ovx
              local rvy = info.vel.y - ovy
              local rvz = info.vel.z - ovz
              local vn = rvx * ux + rvy * uy + rvz * uz
              if vn < 0 then push = push - vn * BUMP_C * m end
              assembly.forceAt(node, vec3(ux * push, uy * push, uz * push),
                vec3((a.x + b.x) * 0.5, (a.y + b.y) * 0.5, (a.z + b.z) * 0.5))
            end
          end
        end
      end
    end
  end
end

-- ── docking guides ──────────────────────────────────────────────────────────
-- Drawn in the CAMERA pass (post-writeback), because a guide computed in
-- fixedUpdate floats a rails-carry beside the hull on any orbiting world — the
-- exact error that would make an alignment aid lie to you.
--
-- Three things, and no more: a ring on each port face so you can SEE which
-- hardware is talking; the approach CORRIDOR down the target's own centreline,
-- which is the line you actually have to fly; and the miss — a bar from where
-- you are to where the corridor is, which turns "am I lined up?" into a length
-- you can watch shrink. The corridor goes green the moment every capture
-- condition is met, so the last second of a dock needs no HUD at all.
-- The guides are drawn in the camera pass, but `dock.target` was measured in
-- the physics tick, up to a rails carry away from the drawn frame (metres on
-- a moving world): both faces are read again here, from the drawn poses, so
-- every line starts and ends on the hardware the frame shows. → a copy of
-- the target, or nil.
function dockGuidePose(t0)
  -- DRAWN poses for both faces (docs/positions-and-frames.md rule 2): each
  -- craft root's toWorld this pass, never its tick origin mixed with its
  -- drawn axes (`dock_world` is the physics read, for capture).
  local node = dock.node
  local p = dock_port(t0.port)
  if not (node and node.valid and p) then return nil end
  local function face(n, q)
    if not n.toWorld then return dock_world(n, assembly.info(n), q) end   -- (a test rig's node)
    local o = n:toWorld(vec3(q.x, q.y, q.z))
    local a = n:toWorld(vec3(q.x + q.ax, q.y + q.ay, q.z + q.az))
    return o.x, o.y, o.z, a.x - o.x, a.y - o.y, a.z - o.z
  end
  local t = {}
  for k, v in pairs(t0) do t[k] = v end
  t.mx, t.my, t.mz = face(node, p)
  local found = false
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.node and v.node.valid and v.node.id == t0.id and v.dock then
      for _, q in ipairs(v.dock.ports) do
        if q.uid == t0.uid then
          local ax, ay, az
          t.qx, t.qy, t.qz, ax, ay, az = face(v.node, q)
          t.max, t.may, t.maz = -ax, -ay, -az
          found = true
        end
      end
    end
  end
  if not found then return nil end
  local dx, dy, dz = t.mx - t.qx, t.my - t.qy, t.mz - t.qz
  t.range = math.sqrt(dx * dx + dy * dy + dz * dz)
  local along = -(dx * t.max + dy * t.may + dz * t.maz)
  t.along = along
  t.lateral = math.sqrt(math.max(0.0, t.range * t.range - along * along))
  return t
end

function dockGuides()
  local t = dock.target
  if not t or not t.mx or dock.map or cinematicUp() then return end
  t = dockGuidePose(t)
  if not t then return end
  local ok = t.range < dock.captureR and t.align > dock.alignMin
    and t.drift < dock.driftMax
  local r, g, b = 1.0, 0.72, 0.2
  if ok then
    r, g, b = 0.3, 1.0, 0.45
  elseif t.locked then
    r, g, b = 0.5, 0.8, 1.0
  end
  -- The two faces.
  draw.ring(t.mx, t.my, t.mz, t.max, t.may, t.maz, 0.42, r, g, b, 0.95)
  draw.ring(t.qx, t.qy, t.qz, t.max, t.may, t.maz, 0.42, r, g, b, 0.7)
  -- The corridor: back down the target's normal, far enough to fly in on.
  -- (at least out to where the miss bar meets it: a bar ending past the
  -- drawn corridor points at nothing)
  local L = math.max(2.0, math.min(12.0, t.range * 2.0), (t.along or 0) + 2.0)
  draw.line(t.qx, t.qy, t.qz,
            t.qx - t.max * L, t.qy - t.may * L, t.qz - t.maz * L, r, g, b, 0.5)
  -- The MISS: our port, out to its own point on the corridor. Watch it shrink.
  local dx, dy, dz = t.mx - t.qx, t.my - t.qy, t.mz - t.qz
  local along = dx * t.max + dy * t.may + dz * t.maz
  local cx = t.qx + t.max * along
  local cy = t.qy + t.may * along
  local cz = t.qz + t.maz * along
  -- (near only: at range the bar is metres long and reads as a line to nowhere)
  if t.lateral > 0.03 and t.range < 12.0 then
    draw.line(t.mx, t.my, t.mz, cx, cy, cz, 1.0, 0.35, 0.35, 0.9)
  end
  -- Where we'd arrive if we just kept drifting: the closing-rate lead marker.
  if t.closing > 0.02 then
    draw.sphere(cx, cy, cz, 0.10, r, g, b, 0.8)
  end
end

-- ── ending a flight ─────────────────────────────────────────────────────────

-- STAND DOWN — the one teardown every way out of the pod goes through: stepping
-- out at the hatch (F), recovering the craft at the base, ending the flight at
-- the Tracking Station, and losing the pod in a breakup. Four places used to
-- spell this out line by line and one of them was always a line short — the
-- navball left up, the engine loop still humming, the crew still invisible.
--
-- `x,y,z` places the astronaut; omit it to leave them where they are. The
-- velocity is worth passing when you're stepping out of something moving: an
-- EVA that starts at rest beside a craft doing 4 m/s is a crew member being
-- run over by their own rocket.
-- Is this craft lost (its pod gone)? `destroyed` is a local, so a handle can't
-- read it: flight_ops' fleet sync asks this instead.
function isLost() return destroyed == true end

-- WHERE THE CREW STEPS OUT: beside the crew position (px, py, pz, world), past
-- the hull's widest reach, 0.4 m up — on the craft's right first, then its
-- left, front, back and the diagonals, a metre further out on a second pass.
-- The first spot where the crew's capsule (r 0.33, 2 m tall; its middle is
-- tested) overlaps nothing but themselves wins: a crew put down INSIDE something (the pad's hardstand, a
-- hold-down clamp, a building, another craft, this hull) is a body overlapping
-- a collider, which the engine resolves by shoving it out — the "thrown 8 m on
-- stepping out" report. Nothing clear anywhere: the first spot, as before.
-- Global: fixedUpdate has no upvalue to spare.
function exitSpot(node, info, px, py, pz)
  local rx, up, rz = basis(node)
  local reach = hullReach() + 0.6
  if not astronaut or not astronaut.valid then astronaut = find("Astronaut") end
  local s = 0.70710678
  local dirs = { { 1, 0 }, { -1, 0 }, { 0, -1 }, { 0, 1 }, { s, -s }, { -s, -s }, { s, s }, { -s, s } }
  local first = nil
  for pass = 0, 1 do
    local r = reach + pass * 1.0
    for _, d in ipairs(dirs) do
      local ox, oz = d[1] * r, d[2] * r
      local cx = px + rx.x * ox + rz.x * oz + up.x * 0.4
      local cy = py + rx.y * ox + rz.y * oz + up.y * 0.4
      local cz = pz + rx.z * ox + rz.z * oz + up.z * 0.4
      first = first or { cx, cy, cz }
      if not overlapSphere then return cx, cy, cz end
      local clear = true
      -- (the capsule's middle 1.3 m: its feet may touch the ground they land on)
      for _, k in ipairs({ -0.32, 0.32 }) do
        local hits = overlapSphere(vec3(cx + up.x * k, cy + up.y * k, cz + up.z * k), 0.33,
          astronaut and { ignore = astronaut } or nil)
        for _, h in ipairs(hits or {}) do
          if not (astronaut and h.node and h.node.id == astronaut.id) then clear = false break end
        end
        if not clear then break end
      end
      if clear then return cx, cy, cz end
    end
  end
  log("vessel: no clear spot to step out on — out on the right as before")
  return first[1], first[2], first[3]
end

function standDown(node, x, y, z, vx, vy, vz)
  piloting = false
  if crewAboard then
    local cl = crewLibNow()
    local id = cl and cl.activeId and cl.activeId()
    if id then unseatMember(id) end
  end
  crewAboard = false
  leftAt = time or 0.0
  throttle = 0.0
  throttle_prev = 0.0
  set_flames(node, 0)
  silence_loops()
  set_hud(nil)
  set_navball(false)
  set_prompt("")
  if not astronaut or not astronaut.valid then astronaut = find("Astronaut") end
  -- Out of the seat: a body again (it rode as a kinematic passenger).
  seatCrew(node, false)
  -- ...at its own size again (a seat shrank the capsule: motoRiderShape).
  -- Here as well as in r2Tick, which a wrecked craft no longer runs.
  if R2.riderShape then motoRiderShape(node) end
  if astronaut then
    if x then
      astronaut.x, astronaut.y, astronaut.z = x, y, z
      astronaut.vx, astronaut.vy, astronaut.vz = vx or 0, vy or 0, vz or 0
    end
    astronaut.visible = true
  end
end

-- Is this craft parked? (Landed and stopped — the precondition for every way of
-- ending a flight except walking away from the wreck.) Published so the flight
-- card can ask without duplicating the test.
-- With HYSTERESIS: a rover creeping to a stop crossed 1.5 m/s and lost a
-- tyre's contact for a tick over and over, so the card flickered between
-- "flying" and "recover". Parked comes on below 1.5 m/s on the ground and
-- goes off only past 2.5 m/s or after 0.5 s off the ground.
PARKED_H = { on = false, air_t = nil }
function parked()
  local node = dock.node
  if destroyed or not node or not node.valid then PARKED_H.on = false return false end
  local info = assembly.info(node)
  if not info then PARKED_H.on = false return false end
  local v = info.vel
  local spd = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
  local ground = info.grounded or R2.onWheels
  if ground then PARKED_H.air_t = nil elseif not PARKED_H.air_t then PARKED_H.air_t = time end
  if PARKED_H.on then
    if spd > 2.5 or (PARKED_H.air_t and time - PARKED_H.air_t > 0.5) then PARKED_H.on = false end
  elseif ground and spd < 1.5 then
    PARKED_H.on = true
  end
  return PARKED_H.on
end

-- ── recovery ────────────────────────────────────────────────────────────────
-- Bring a craft home and you get most of its hardware value back. That is the
-- other half of the money loop: a hull is BOUGHT at rollout, so the difference
-- between a landing and a crater is the difference between an expensive flight
-- and a ruinous one — and between a company that grows and one that doesn't.
--
-- Recoverable means: landed, stopped, and near enough to the base that a truck
-- could plausibly go and get it. Damaged parts refund less; destroyed ones
-- refund nothing, because they aren't there.
local RECOVER_RANGE = 260.0   -- metres from the base site
-- Fraction of a pristine part's value returned. 0.85 since space parts became
-- the expensive tier (parts_registry, 2026-10-26): a craft you land and bring
-- home costs 15% of itself, so it is the crater that costs, not the flight.
local RECOVER_RATE = 0.85

-- Distance to the home base (the crew spawn), in the body-relative frame that
-- survives the planet's orbit. nil when there's no base on this world.
local function base_distance(node)
  local a = find("Astronaut")
  local home = find("FacCommand") or find("FacHangar")
  local d = space.dominant(node.x, node.y, node.z)
  local b = d and space.body(d)
  if not (home and b) then return nil end
  -- Facilities are planet-PARENTED, so their coords are already body-relative.
  local rx2, ry2, rz2 = node.x - b.x, node.y - b.y, node.z - b.z
  local dx, dy, dz = rx2 - home.x, ry2 - home.y, rz2 - home.z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- What this craft is worth back, right now.
function recoverValue()
  local v = 0.0
  for u, d in pairs(bp_by_uid) do
    local hp = part_hp[u] or 0
    if hp > 0 then v = v + (d.cost or 0) * RECOVER_RATE * hp end
  end
  return math.floor(v)
end

-- Can we recover here? Returns (ok, why-not).
function recoverReady()
  local node = dock.node
  if destroyed or not node or not node.valid then return false, "no craft" end
  -- A craft still clamped to the pad has not flown: "recovering" it would be a
  -- refund for pressing Launch.
  if hasFlown == false then return false, "not launched yet" end
  local info = assembly.info(node)
  if not info then return false, "no craft" end
  if not (info.grounded or R2.onWheels) then return false, "not landed" end
  local sp = math.sqrt(info.vel.x ^ 2 + info.vel.y ^ 2 + info.vel.z ^ 2)
  if sp > 1.5 then return false, "still moving" end
  local d = base_distance(node)
  if not d then return false, "no base on this world" end
  if d > RECOVER_RANGE then
    return false, string.format("%.0f m from base", d)
  end
  return true, nil
end

-- Recover: bank the value, put the pilot back on the ground at the base, and
-- take the craft off the map. Everything docked to it comes home too — that's
-- the point of hauling a full stack back rather than shedding it in orbit.
function recoverCraft()
  local ok = recoverReady()
  if not ok then return false end
  local node = dock.node
  local value = recoverValue()
  local co = findScript("company")
  if co and co.earn then
    co.earn(value, "recovered " .. (node.name or "craft") .. " (" .. part_total .. " parts)")
  end
  -- Whatever it was carrying comes home with it: a recovery is the crane
  -- unloading the hold, not the hold being thrown away with the hull.
  local inv = findScript("inventory")
  if inv and holdId and not inv.isEmpty(holdId) then
    local n = inv.transferAll(holdId, "base")
    if n > 0 then log(string.format("  cargo: %d unit(s) into the warehouse", n)) end
  end
  -- ...and so do the stowage lockers (materials to the warehouse; gear goes
  -- back on the crew's racks, the warehouse's gear bag)
  if inv then
    for _, l in ipairs(LOCKERS) do
      inv.transferAll(l.cid, "base")
      for _, g in ipairs(inv.gearItems and inv.gearItems(l.cid) or {}) do
        local n = inv.removeGear(l.cid, g.id, g.n)
        if n > 0 then inv.addGear("base", g.id, n) end
      end
    end
  end
  save.set("mission.recovered", true)
  local clr = crewLibNow()
  if clr and clr.noteHome then
    local act = clr.activeId and clr.activeId()
    for _, s in ipairs(seatsOf()) do
      if s.taken and not (crewAboard and s.taken == act) then
        pcall(clr.noteHome, s.taken)
        seatMember(s.uid, s.slot, nil)
      end
    end
  end
  if crewAboard then
    local i2 = assembly.info(node)
    local bx2, by2, bz2 = base_of(node, i2)
    standDown(node, bx2, by2 + 2.0, bz2)
  elseif piloting then
    releaseControl()
    controlFallback(node.id)
  end
  log(string.format("RECOVERED — %s   +$%d", node.name or "craft", value))
  r2Cleanup()
  destroy(node)
  destroyed = true
  return true
end

-- ── the cargo hold ─────────────────────────────────────────────────────────
-- Every Cargo Bay aboard pools into ONE inventory container, keyed by the
-- craft's name ("hold:Kestrel I"). The astronaut fills it on the surface (the
-- inventory panel's transfer), the Commerce Depot empties it at home, and a
-- recovered craft brings its load in with it.
--
-- What's inside is REAL MASS: `holdApplyMass` reads the manifest into `holdT`,
-- and massSync spreads it over the bays' rigidbodies (the engine re-derives the
-- compound's mass, CoM and inertia, no rebuild), so the loaded return trip
-- climbs worse than the empty outbound one did.
--
-- Two craft with the SAME NAME share a hold. That's a consequence of keying on
-- something the player chose and can recognise, and it's the honest trade: a
-- name you can find beats a uid you can't.
holdId = nil          -- published: the inventory container, nil = no bays
holdCap = 0.0         -- published: kilograms
craftName = "Vessel"  -- published
local hold_parts = {}
local CARGO_T_PER_KG = 0.001   -- game mass units per kilogram of cargo

function holdRegister(node)
  hold_parts, holdCap = {}, 0.0
  for _, d in pairs((bp and bp.parts) or {}) do
    if (d.cargo or 0) > 0 then
      hold_parts[#hold_parts + 1] = { uid = d.uid, dry = d.mass or 0.9 }
      holdCap = holdCap + d.cargo
    end
  end
  -- (the engine's node names can't be written from Lua — every craft's root
  -- is "Vessel" — so the craft's NAME lives here, in `craftName`)
  if craftName == "Vessel" and node and node.valid and node.name then craftName = node.name end
  holdId = (holdCap > 0) and ("hold:" .. craftName) or nil
  local inv = findScript("inventory")
  if inv and holdId then inv.setCap(holdId, holdCap) end
  holdT = holdMass() * CARGO_T_PER_KG -- a hold that comes back loaded weighs it
  lockerRegister()
end

function holdMass()
  local inv = findScript("inventory")
  if not (inv and holdId) then return 0.0 end
  return inv.mass(holdId)
end

-- Push the manifest's mass into the physics. Call after any transfer: the
-- bays take their share on the next tick (massSync).
function holdApplyMass(node)
  holdT = holdMass() * CARGO_T_PER_KG
  lockerApplyMass()
  return #hold_parts > 0 or #LOCKERS > 0
end

-- ── STOWAGE LOCKERS (parts with `store` kg) ───────────────────────────────
-- Unlike the pooled hold, every locker is ITS OWN container ("locker:<n>"):
-- the context menu (scripts/context_providers.lua) opens one part and moves
-- things between it and the crew's pack. The number is the part's own, kept
-- in its state (`st.locker`), so it rides the fleet record, a docking and a
-- reload with the part, and the contents (inventory's save keys) with it.
-- What a locker holds is real mass ON THAT PART (LOCKER_T, read by massSync).
LOCKERS = {}       -- { { uid, cid, cap } }
LOCKER_T = {}      -- uid → tonnes in that locker
LOCKER_STORE = { locker = 80 }  -- kg by part id, for records saved before `store`
function lockerRegister()
  LOCKERS, LOCKER_T = {}, {}
  local inv = findScript("inventory")
  local E = elib()
  for u, d in pairs(bp_by_uid) do
    local cap = tonumber(d.store) or 0
    if cap <= 0 then cap = LOCKER_STORE[d.id or ""] or 0 end
    if cap > 0 and not integ.gone[u] then
      local st = (E and E.stateOf) and E.stateOf(d) or d.st
      if type(st) ~= "table" then st = {}; d.st = st end
      if not st.locker then
        local n = (save.get("locker.seq") or 0) + 1
        save.set("locker.seq", n)
        st.locker = n
      end
      local cid = "locker:" .. tostring(st.locker)
      if inv then inv.setCap(cid, cap) end
      LOCKERS[#LOCKERS + 1] = { uid = u, cid = cid, cap = cap }
    end
  end
  table.sort(LOCKERS, function(a, b) return a.uid < b.uid end)
  lockerApplyMass()
end
function lockerApplyMass()
  local inv = findScript("inventory")
  for _, l in ipairs(LOCKERS) do
    LOCKER_T[l.uid] = inv and inv.mass(l.cid) * CARGO_T_PER_KG or 0
  end
end
function lockerT()
  local t = 0
  for u, m in pairs(LOCKER_T) do
    if not integ.gone[u] and (part_hp[u] or 1) > 0 then t = t + m end
  end
  return t
end
-- The locker on part `uid` → container id, capacity (kg); nil for any other part.
function lockerOf(uid)
  for _, l in ipairs(LOCKERS) do
    if l.uid == uid and not integ.gone[uid] then return l.cid, l.cap end
  end
  return nil
end

-- ── PART SERVICE (the context menu's view of one part) ─────────────────────
-- Read-only questions and the few changes the menu may make, so it never
-- reaches into the damage model's or the tanks' own tables.

-- The blueprint record of a part still aboard and whole (nil otherwise).
function partRec(uid)
  if uid and aboard(uid) then return bp_by_uid[uid] end
  return nil
end
-- Its health: 1 pristine … 0 broken (nil when it isn't aboard).
function partHp(uid)
  if not (uid and bp_by_uid[uid]) or integ.gone[uid] then return nil end
  return part_hp[uid] or 1.0
end
-- The blueprint uid behind a part's live node (a ray's hit.node).
function uidOfNode(c)
  if not (c and c.valid ~= false) then return nil end
  return uid_of_node(c)
end
-- Every part that is worn (0 < hp < 1): { { uid, hp } } — for probes and HUDs.
function damagedParts()
  local out = {}
  for u, h in pairs(part_hp) do
    if h > 0 and h < 0.999 and bp_by_uid[u] and not integ.gone[u] then out[#out + 1] = { uid = u, hp = h } end
  end
  table.sort(out, function(a, b) return a.uid < b.uid end)
  return out
end
-- MEND a part: its health up to `to` (default whole). A part that has BROKEN
-- (hp 0) is wreckage that has left the craft, and nothing mends that — the
-- model's rule, not the menu's. Repaints the wear. Returns the new hp, or
-- nil and why.
function repairPart(uid, to)
  local h = partHp(uid)
  if not h then return nil, "that part isn't on this craft" end
  if h <= 0 then return nil, "it is wrecked — beyond a field repair" end
  local want = math.max(h, math.min(1.0, to or 1.0))
  part_hp[uid] = want
  local node = dock.node
  if node and node.valid then set_part_damage(child_of_uid(node, uid), want) end
  return want
end
-- Probes and cheats: wear a part to `hp` (never below 0.05: this is not a
-- way to break one — the damage model does that).
function wearPart(uid, hp)
  if not partHp(uid) then return nil end
  part_hp[uid] = math.max(0.05, math.min(1.0, hp or 0.5))
  local node = dock.node
  if node and node.valid then set_part_damage(child_of_uid(node, uid), part_hp[uid]) end
  return part_hp[uid]
end
-- A part's own state field (`st.<k>`, which rides the fleet record, docking
-- and revert): read it, or with a value write it (`false` clears). The crew's
-- jobs keep their progress here (st.rprog). nil when the part isn't aboard.
function partSt(uid, k, v, write)
  local d = uid and bp_by_uid[uid]
  if not d or integ.gone[uid] then return nil end
  if write then
    d.st = type(d.st) == "table" and d.st or {}
    if v == false then d.st[k] = nil else d.st[k] = v end
  end
  return type(d.st) == "table" and d.st[k] or nil
end

-- ── PART FRAMES, NOW (the crew's repair lock, docs/crew-and-items.md §6.3) ─
-- Where a part is THIS tick, for a body a script holds against it. The craft's
-- axes come from `assembly.info` (this tick's, where the node's are a frame's)
-- and the origin from `info.origin` (clear of the rails carry the node lags
-- by: the same compensation the seat uses, see base_of / board_dist). The
-- frame's origin is the part's blueprint point and its axes are the craft's,
-- so a point stored in it rides the part however the craft turns or the
-- planet moves. The same frame serves a point picked off the screen: measured
-- on 0.117.0-rc27 in lateUpdate, node:toWorld (the drawn pose) agrees with
-- this to the millimetre, while node.x/basis(node) read a rails carry behind
-- (3.4 m in orbit). `rendered` is accepted for callers that pass it and
-- changes nothing. → a table, or nil when the part or the craft is gone.
function partFrameNow(uid, rendered)
  rendered = false
  local d = uid and bp_by_uid[uid]
  if not d or integ.gone[uid] or (part_hp[uid] or 1) <= 0 then return nil end
  local node = dock.node
  if destroyed or not (node and node.valid) then return nil end
  local info = assembly.info(node)
  local R, U, Z
  if info and info.right and info.up and not rendered then
    R, U = info.right, info.up
    -- Z = R × U (the frame is right-handed): no sign convention to get wrong
    Z = vec3(R.y * U.z - R.z * U.y, R.z * U.x - R.x * U.z, R.x * U.y - R.y * U.x)
  else
    R, U, Z = basis(node)
  end
  local bx, by, bz
  if rendered or not info then bx, by, bz = node.x, node.y, node.z else bx, by, bz = base_of(node, info) end
  local F = {
    ox = bx + R.x * d.x + U.x * d.y + Z.x * d.z,
    oy = by + R.y * d.x + U.y * d.y + Z.y * d.z,
    oz = bz + R.z * d.x + U.z * d.y + Z.z * d.z,
    rx = R.x, ry = R.y, rz = R.z, ux = U.x, uy = U.y, uz = U.z, zx = Z.x, zy = Z.y, zz = Z.z,
    vx = 0, vy = 0, vz = 0, wx = 0, wy = 0, wz = 0, cx = bx, cy = by, cz = bz,
  }
  if info then
    F.vx, F.vy, F.vz = info.vel.x, info.vel.y, info.vel.z
    if info.angVel then F.wx, F.wy, F.wz = info.angVel.x, info.angVel.y, info.angVel.z end
    if info.com then
      F.cx, F.cy, F.cz = info.com.x, info.com.y, info.com.z
      -- (com is in the same frame as the origin we used)
      if rendered then F.cx, F.cy, F.cz = F.cx + node.x - info.origin.x, F.cy + node.y - info.origin.y, F.cz + node.z - info.origin.z end
    end
  end
  return F
end

-- How far the craft's PHYSICS frame (info.origin, this tick) is from the
-- root's x/y/z (the pose interpolated for the camera, which lags up to a tick
-- of the world's rails carry: 3.4 m in a low orbit, card 0543). Read in the
-- same pass, another node's x/y/z lags by the same amount, so `node.x + lag`
-- is that node in the physics frame.
-- NOT the tick pose: measured on rc30 in orbit, an assembly root's
-- tickX/Y/Z is not in info.origin's frame (the crew's tick pose plus
-- origin − root tick came out 3.0 m off the work spot, wandering tick to
-- tick, where x/y/z gave 0.008 m). `render` is accepted and changes nothing.
-- → lx, ly, lz, false (zeros without a compound)
function nodeLag(render)
  local node = dock.node
  if not (node and node.valid) then return 0, 0, 0, false end
  local info = assembly.info(node)
  if not (info and info.origin) then return 0, 0, 0, false end
  return info.origin.x - node.x, info.origin.y - node.y, info.origin.z - node.z, false
end

-- Another node (the crew) in this craft's physics frame, from its x/y/z read
-- in the same pass as the root's (nodeLag).
function physPosOf(n)
  if not n then return nil end
  local kx, ky, kz = nodeLag()
  return n.x + kx, n.y + ky, n.z + kz
end

-- A point in part `uid`'s frame → where it is in the world this tick, and how
-- fast it is moving there (info.vel + angVel × (p − com)).
-- → wx, wy, wz, vx, vy, vz (nil when the part is gone)
function partPointNow(uid, lx, ly, lz, rendered)
  local F = partFrameNow(uid, rendered)
  if not F then return nil end
  local px = F.ox + F.rx * lx + F.ux * ly + F.zx * lz
  local py = F.oy + F.ry * lx + F.uy * ly + F.zy * lz
  local pz = F.oz + F.rz * lx + F.uz * ly + F.zz * lz
  local qx, qy, qz = px - F.cx, py - F.cy, pz - F.cz
  return px, py, pz,
    F.vx + F.wy * qz - F.wz * qy,
    F.vy + F.wz * qx - F.wx * qz,
    F.vz + F.wx * qy - F.wy * qx
end

-- A world point (and optionally a world direction) → part `uid`'s frame.
-- `rendered` as for partFrameNow: a ray hit from this frame's picture.
function partLocalNow(uid, wx, wy, wz, rendered, dx, dy, dz)
  local F = partFrameNow(uid, rendered)
  if not F then return nil end
  local qx, qy, qz = wx - F.ox, wy - F.oy, wz - F.oz
  local lx = qx * F.rx + qy * F.ry + qz * F.rz
  local ly = qx * F.ux + qy * F.uy + qz * F.uz
  local lz = qx * F.zx + qy * F.zy + qz * F.zz
  if not dx then return lx, ly, lz end
  return lx, ly, lz,
    dx * F.rx + dy * F.ry + dz * F.rz, dx * F.ux + dy * F.uy + dz * F.uz, dx * F.zx + dy * F.zy + dz * F.zz
end

-- ── EVA (docs/crew-and-items.md §3.3, §3.5) ────────────────────────────────
-- The craft's side of "may the crew step out": landed or splashed and still,
-- or off the ground with the engines quiet. `space`: nothing under the craft
-- for 50 m (an RCS Pack is then the only way to steer).
-- → { surface, space, speed, throttle, accel } or nil
function evaState()
  local node = dock.node
  if destroyed or not (node and node.valid) then return nil end
  local info = assembly.info(node)
  if not info then return nil end
  local v = info.vel
  local speed = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
  local surface = info.grounded == true or info.anchored == true or R2.onWheels == true or WATER.splashed == true
  local space_ = false
  if not surface then
    local px, py, pz = pod_world(node, info)
    local d0 = space.dominant(px, py, pz)
    local b0 = d0 and space.body(d0)
    if b0 then
      local ux, uy, uz = norm(px - b0.x, py - b0.y, pz - b0.z)
      local reach = hullReach() + 0.5
      local hit = raycast and raycast(px - ux * reach, py - uy * reach, pz - uz * reach, -ux, -uy, -uz, 50.0) or nil
      space_ = hit == nil
    end
  end
  return { surface = surface, space = space_, speed = speed, throttle = throttle or 0, accel = 0 }
end

-- STEP OUT, now (the checks are crew.evaCheck's): out at the clear spot
-- beside the crew position, moving with the craft AT that spot
-- (vel + angVel × r), so in space they start at rest relative to the craft
-- and float beside it. Warp drops to 1×. Global: crew.eva and F call it.
-- Asked between ticks (a confirm's click, crew.eva from a menu) it lands on
-- the next tick: the crew rides the seat as a KINEMATIC body, and one moved
-- outside fixedUpdate on a moving world stands a rails carry behind where it
-- was put — inside the hull, which then throws it off at hundreds of m/s.
function evaNow(in_tick)
  local node = dock.node
  if destroyed or not (node and node.valid) or not crewAboard then return false end
  if not in_tick then
    dock.evaPending = true
    return true
  end
  local info = assembly.info(node)
  local ex, ey, ez = nil, nil, nil
  if stationUid and not podSeat then ex, ey, ez = hatchSpot(stationUid) end
  if not ex then
    local px, py, pz = pod_world(node, info)
    ex, ey, ez = exitSpot(node, info, px, py, pz)
  end
  local vx, vy, vz = 0, 0, 0
  if info then
    vx, vy, vz = info.vel.x, info.vel.y, info.vel.z
    if info.angVel and info.com then
      local w, c = info.angVel, info.com
      local qx, qy, qz = ex - c.x, ey - c.y, ez - c.z
      vx, vy, vz = vx + w.y * qz - w.z * qy, vy + w.z * qx - w.x * qz, vz + w.x * qy - w.y * qx
    end
  end
  if space.warp and space.warp() > 1.001 then space.warp(1); warpSay("Warp ×1 · stepping out") end
  standDown(node, ex, ey, ez, vx, vy, vz)
  -- Off the ground, the first moments out are watched (evaGuard).
  if info and not (info.grounded or info.anchored or R2.onWheels or WATER.splashed) then
    dock.evaGuard = { t1 = (time or 0) + 0.6, n = 0 }
  else
    dock.evaGuard = nil
  end
  local c = findScript("crew")
  if c and c.noteAfoot then pcall(c.noteAfoot, c.activeId()) end
  local ep = findScript("eva_pack")
  if ep and ep.evaStarted then pcall(ep.evaStarted, node) end
  return true
end

-- THE FIRST MOMENTS OUT, off the ground: for 0.6 s after evaNow the crew
-- must still be at rest relative to the craft where they float (nothing they
-- can do in that time — the pack's ~1 m/s² — changes that by 2 m/s). Anything
-- else is something writing them an absolute velocity: the walker took the
-- hull under the hatch for ground and wrote |v| 0 over an orbit's 68 m/s
-- (evaprobe 2026-10-27, the crew thrown into the planet). Put back to the
-- craft's velocity at that point, and said in the log so it is found and
-- fixed where it came from. Called from fixedUpdate (the physics frame).
function evaGuard(node, info)
  local g = dock.evaGuard
  if not g then return end
  local a = astronaut
  if crewAboard or (time or 0) > g.t1 or not (info and info.origin and info.com and a and a.valid) then
    dock.evaGuard = nil
    return
  end
  local ax, ay, az = a.x + info.origin.x - node.x, a.y + info.origin.y - node.y, a.z + info.origin.z - node.z
  local c, w = info.com, info.angVel or { x = 0, y = 0, z = 0 }
  local qx, qy, qz = ax - c.x, ay - c.y, az - c.z
  local pvx = info.vel.x + w.y * qz - w.z * qy
  local pvy = info.vel.y + w.z * qx - w.x * qz
  local pvz = info.vel.z + w.x * qy - w.y * qx
  local rx, ry, rz = a.vx - pvx, a.vy - pvy, a.vz - pvz
  local rel = math.sqrt(rx * rx + ry * ry + rz * rz)
  if rel > 2.0 then
    a.vx, a.vy, a.vz = pvx, pvy, pvz
    g.n = g.n + 1
    if g.n == 1 then
      log(string.format("vessel: EVA guard: the crew was moving %.1f m/s against the craft %.2f s after stepping out; put back at rest beside it",
        rel, g.t1 - (time or 0)))
    end
  end
end

-- F while flying: ask crew.lua whether the crew may go (refused with the
-- reason; no RCS Pack in space asks first through eva_pack's confirm), then
-- go. Without the crew library: today's F.
function evaPress(node, info)
  local c = findScript("crew")
  if not (c and c.evaCheck) then return evaNow(true) end
  local id = c.activeId()
  local ok, why, warn = c.evaCheck(id)
  if not ok then
    log("EVA refused: " .. tostring(why))
    local fx = findScript("sfx")
    if fx and fx.caption then fx.caption("can't step out: " .. tostring(why)) end
    return false
  end
  if warn then
    local ep = findScript("eva_pack")
    if ep and ep.askEva then ep.askEva(id, warn) return false end
  end
  return evaNow(true)
end

-- ── SEATS: who sits where (docs/crew-and-items.md §3.2, §3.3) ─────────────
-- The truth is on the PART: `st.crew<k> = memberId` (crew.lua's slot
-- accessors; plain numbers, so a fleet record, a staging split, a docking
-- and a revert carry them with no extra code). `crewAboard` keeps its old
-- meaning: THE AVATAR (crew.active) rides this craft. Every other seated
-- member is a doll (crew.lua places them). All globals: the main chunk is at
-- Lua's 200-local ceiling and fixedUpdate at the 60-upvalue one.
function crewLibNow()
  local cl = CREWLIB.ref
  if not (cl and cl.valid ~= false) and (time or 0) - CREWLIB.t > 2.0 then
    CREWLIB.t = time or 0
    cl = findScript("crew")
    CREWLIB.ref = cl
  end
  if cl and cl.valid ~= false and cl.seatDef then return cl end
  return nil
end
function seatAlive(u)
  return bp_by_uid[u] ~= nil and not integ.gone[u] and (part_hp[u] or 1) > 0
end
-- The parts that HAVE seats, cached until the craft's structure changes (a
-- 1,000-part craft has a handful): uid → record, and the sorted uids.
SEATC = { bp = nil, gen = -1, n = -1, parts = {}, uids = {} }
function seatParts()
  local c = crewLibNow()
  if not c then return {}, {} end
  if SEATC.bp ~= bp_by_uid or SEATC.gen ~= integ.gen or SEATC.n ~= part_total then
    local parts, uids = {}, {}
    for u, d in pairs(bp_by_uid) do
      if c.seatDef(d) then parts[u] = d; uids[#uids + 1] = u end
    end
    table.sort(uids)
    SEATC.bp, SEATC.gen, SEATC.n, SEATC.parts, SEATC.uids = bp_by_uid, integ.gen, part_total, parts, uids
  end
  return SEATC.parts, SEATC.uids
end
-- Every slot aboard: { {uid, slot, open, command, taken = id|nil, x,y,z (vessel frame), label} … }
function seatsOf()
  local out = {}
  local c = crewLibNow()
  if not c or destroyed then return out end
  local _, uids = seatParts()
  for _, u in ipairs(uids) do
    local d = seatAlive(u) and bp_by_uid[u]
    local def = c.seatDef(d)
    if def then
      for k, s in ipairs(def.seats) do
        out[#out + 1] = { uid = u, slot = k, open = def.open == true, command = def.command == true,
                          taken = c.memberAt(d, k), x = d.x + s.x, y = d.y + s.y, z = d.z + s.z,
                          label = d.label or d.id, hatch = def.hatch ~= nil }
      end
    end
  end
  return out
end
-- Everyone aboard (the commander first, then slot order).
function crewIds()
  local out = {}
  local c = crewLibNow()
  if not c then
    -- no crew library (a harness): the avatar while crewAboard
    local cl = crewAboard and findScript("crew")
    local id = cl and cl.activeId and cl.activeId()
    return id and { id } or {}
  end
  local cmd = commander()
  if cmd then out[1] = cmd end
  for _, s in ipairs(seatsOf()) do
    if s.taken and s.taken ~= cmd then out[#out + 1] = s.taken end
  end
  return out
end
function crewCount() return #crewIds() end
-- The member at the controls: the best-ranked COMMAND slot (§3.3).
function commander()
  local c = crewLibNow()
  if not c then return crewIds()[1] end
  local function depth(u)
    local n, g = 0, 0
    while bp_by_uid[u] and (bp_by_uid[u].parent or 0) ~= 0 and g < 64 do u = bp_by_uid[u].parent; n, g = n + 1, g + 1 end
    return n
  end
  return c.commanderOf((seatParts()), depth, seatAlive)
end
-- Seat member `id` in (uid, slot), or empty it (id nil). → ok, why
function seatMember(uid, slot, id)
  local c = crewLibNow()
  local d = uid and bp_by_uid[uid]
  if not (c and d) then return false, "no such part" end
  local def = c.seatDef(d)
  if not def or not slot or slot < 1 or slot > #def.seats then return false, "no such seat" end
  if id then
    local cur = c.memberAt(d, slot)
    if cur and cur ~= id then return false, "that seat is taken" end
    -- one seat per member
    for u2, d2 in pairs((seatParts())) do
      local def2 = c.seatDef(d2)
      if def2 then for k = 1, #def2.seats do if c.memberAt(d2, k) == id then c.setMemberAt(d2, k, nil) end end end
    end
  end
  c.setMemberAt(d, slot, id)
  return true, nil
end
-- Where member `id` sits aboard: uid, slot (nil when not aboard).
function memberSlot(id)
  local c = crewLibNow()
  if not (c and id) then return nil, nil end
  for _, s in ipairs(seatsOf()) do if s.taken == id then return s.uid, s.slot end end
  return nil, nil
end
-- The free slot boarding fills (`prefer_uid` first, then command slots).
function freeSeat(prefer_uid)
  local c = crewLibNow()
  if not c then return nil, nil end
  return c.freeSlot((seatParts()), prefer_uid, seatAlive)
end
-- Take member `id` out of whatever seat they have aboard.
function unseatMember(id)
  local u, k = memberSlot(id)
  if u then seatMember(u, k, nil) end
  return u ~= nil
end
-- The avatar's member must be in a seat while it rides (an older save's
-- craft, a crew transfer): put them in the station's free slot, else any.
function seatAvatarCheck()
  local c = crewLibNow()
  if not (c and crewAboard) then return end
  local id = c.activeId and c.activeId()
  if not id or memberSlot(id) then return end
  local u, k = freeSeat(stationUid)
  if not u and stationUid and bp_by_uid[stationUid] then u, k = stationUid, 1 end
  if u then
    local d = bp_by_uid[u]
    c.setMemberAt(d, k, id)
    log(string.format("vessel: crew #%d seated in %s slot %d", id, tostring(d.label or d.id), k))
  end
end
-- The station (camera centre, hatch, open-seat pose) at member `id`'s part.
function setStationOf(id)
  local u = memberSlot(id)
  if u then return setStation(u) end
  return false
end
-- The hatch of part `uid` now: point and outward normal in the world (the
-- physics frame, partFrameNow), or nil (an open seat, a part with no hatch).
function hatchWorld(uid)
  local c = crewLibNow()
  local d = uid and bp_by_uid[uid]
  local def = c and d and c.seatDef(d)
  local h = def and def.hatch
  if not h then return nil end
  local F = partFrameNow(uid)
  if not F then return nil end
  return F.ox + F.rx * h.x + F.ux * h.y + F.zx * h.z,
         F.oy + F.ry * h.x + F.uy * h.y + F.zy * h.z,
         F.oz + F.rz * h.x + F.uz * h.y + F.zz * h.z,
         F.rx * h.nx + F.ux * h.ny + F.zx * h.nz,
         F.ry * h.nx + F.uy * h.ny + F.zy * h.nz,
         F.rz * h.nx + F.uz * h.ny + F.zz * h.nz
end
-- A clear capsule-sized spot outside part `uid`'s hatch (§3.5: 0.9 m out
-- along its normal, 0.4 m up), else today's exitSpot round the hull.
function hatchSpot(uid)
  local node = dock.node
  if destroyed or not (node and node.valid) then return nil end
  local info = assembly.info(node)
  local hx, hy, hz, nx, ny, nz = hatchWorld(uid)
  if hx then
    local ux, uy, uz = radial_up(hx, hy, hz)
    -- off the ground the suit must float clear of every hull, feet and
    -- helmet too (touching one reads as standing on it): further out
    local i0 = info
    local aloft = i0 and not (i0.grounded or i0.anchored or R2.onWheels or WATER.splashed)
    local out_, up_ = aloft and 1.3 or 0.9, aloft and 0.0 or 0.4
    local cx, cy, cz = hx + nx * out_ + ux * up_, hy + ny * out_ + uy * up_, hz + nz * out_ + uz * up_
    local clear = true
    if overlapSphere then
      if not astronaut or not astronaut.valid then astronaut = find("Astronaut") end
      for _, k in ipairs(aloft and { -0.66, -0.32, 0.32, 0.66 } or { -0.32, 0.32 }) do
        local hits = overlapSphere(vec3(cx + ux * k, cy + uy * k, cz + uz * k), 0.33,
          astronaut and { ignore = astronaut } or nil)
        for _, h in ipairs(hits or {}) do
          if not (astronaut and h.node and h.node.id == astronaut.id) then clear = false break end
        end
        if not clear then break end
      end
    end
    if clear then dock.lastExit = "hatch" return cx, cy, cz end
  end
  dock.lastExit = "hull"   -- (published for probes: the hatch was blocked)
  local d = uid and bp_by_uid[uid]
  local q = d or pod
  local rx, up, rz = basis(node)
  local bx, by, bz = base_of(node, info)
  local px = bx + rx.x * q.x + up.x * q.y + rz.x * q.z
  local py = by + rx.y * q.x + up.y * q.y + rz.y * q.z
  local pz = bz + rx.z * q.x + up.z * q.y + rz.z * q.z
  return exitSpot(node, info, px, py, pz)
end
-- THE AVATAR COMES ABOARD as member `id` (already seated here): crew.lua's
-- switch to a craft with crew. Takes the controls; the avatar rides hidden
-- (or seated in view in an open seat) at their station.
function avatarBoard(id)
  local node = dock.node
  if destroyed or not (node and node.valid) then return false end
  for _, ov in ipairs(findScripts("vessel_controller")) do
    if ov.node and ov.node.id ~= node.id then
      if ov.releaseControl then ov.releaseControl() end
      if ov.crewAboard and ov.crewLeave then ov.crewLeave() end
    end
  end
  if not astronaut or not astronaut.valid then astronaut = find("Astronaut") end
  if not memberSlot(id) then
    local u, k = freeSeat(stationUid)
    if u then seatMember(u, k, id) end
  end
  setStationOf(id)
  piloting = true
  crewAboard = true
  if astronaut then
    astronaut.visible = podSeat == true
    local px, py, pz = pod_world(node, assembly.info(node))
    astronaut.x, astronaut.y, astronaut.z = px, py, pz
  end
  set_navball(true)
  sas_mode, sas_last = "stability", "stability"
  hud_t = -10.0
  integ.seated = false   -- seatCrew re-asserts the passenger next tick
  return true
end
-- A crewed part broke (hp 0) or the craft came apart around it: its
-- occupants die (crew.kill; with death off they're rescued). The avatar is
-- left to the caller (standDown) when death is off.
function crewPartBroken(node, uid, x, y, z)
  local c = crewLibNow()
  local d = uid and bp_by_uid[uid]
  local def = c and d and c.seatDef(d)
  if not def then return end
  local active = c.activeId and c.activeId()
  local ids = {}
  for k = 1, #def.seats do
    local id = c.memberAt(d, k)
    if id then
      ids[#ids + 1] = id
      c.setMemberAt(d, k, nil)
    end
  end
  for _, id in ipairs(ids) do
    if id == active and crewAboard then
      if c.deathOn and c.deathOn() then
        pcall(c.kill, id, "cabin", nil, { x = x, y = y, z = z, craft = craftName })
      end
    else
      pcall(c.kill, id, "cabin", nil, { x = x, y = y, z = z, craft = craftName })
    end
  end
end
-- The craft is lost but some crewed parts held: their crew are set down
-- beside the wreck, alive (CrewBodies), as the avatar is.
function crewEvacuate(node, x, y, z)
  local c = crewLibNow()
  if not c then return end
  local active = c.activeId and c.activeId()
  local ux, uy, uz = radial_up(x, y, z)
  local n = 0
  for u, d in pairs(bp_by_uid) do
    local def = c.seatDef(d)
    if def then
      for k = 1, #def.seats do
        local id = c.memberAt(d, k)
        if id then
          c.setMemberAt(d, k, nil)
          if id ~= active or not crewAboard then
            n = n + 1
            local a = n * 1.3
            local rx, _, rz = basis(node)
            local px = x + ux * 2.0 + rx.x * math.cos(a) * 2.2 + rz.x * math.sin(a) * 2.2
            local py = y + uy * 2.0 + rx.y * math.cos(a) * 2.2 + rz.y * math.sin(a) * 2.2
            local pz = z + uz * 2.0 + rx.z * math.cos(a) * 2.2 + rz.z * math.sin(a) * 2.2
            if c.setDown then pcall(c.setDown, id, px, py, pz) end
          end
        end
      end
    end
  end
end
-- Is the avatar's member seated in these part records (a fleet record's)?
-- True with no crew library, or when no part carries a slot (an old record).
function avatarSeatedIn(parts)
  local c = crewLibNow()
  if not c then return true end
  local id = c.activeId and c.activeId()
  local any = false
  for _, d in pairs(parts or {}) do
    local def = c.seatDef(d)
    if def then
      for k = 1, #def.seats do
        local m = c.memberAt(d, k)
        if m then any = true; if m == id then return true end end
      end
    end
  end
  return not any
end
-- The avatar rides ONE craft: any other that thinks it carries them lets go
-- (and their seat there empties).
function avatarExclusive()
  local node = dock.node
  local c = crewLibNow()
  local id = c and c.activeId and c.activeId()
  for _, ov in ipairs(findScripts("vessel_controller")) do
    if ov.node and node and ov.node.id ~= node.id then
      if ov.crewAboard and ov.crewLeave then ov.crewLeave() end
      if id and ov.unseatMember then ov.unseatMember(id) end
    end
  end
end
-- "F — board Pod Mk2 (2 free)", "F — sit in the seat", "Pod Mk1 is full".
function boardPrompt(st)
  local cl = crewLibNow()
  local d = st and bp_by_uid[st.uid]
  if not (cl and d) then return (st and st.seat) and "F — sit in the seat" or "F — board the pod" end
  local def = cl.seatDef(d)
  local free = 0
  for k = 1, (def and #def.seats or 1) do if not cl.memberAt(d, k) then free = free + 1 end end
  local name = d.label or d.id or "the pod"
  if free == 0 then
    local u = freeSeat(st.uid)
    if not u then return name .. " is full" end
    return string.format("F — board (%s is full: another seat)", name)
  end
  if st.seat then return "F — sit in the seat" end
  return string.format("F — board %s (%d free)", name, free)
end
-- THE LAUNCH SEATS (§3.2): the VAB's plan (the blueprint's `crew`, or the
-- CREW tab's `shipyard.crew`), checked by crew.launchPlan: members at base
-- or the avatar's member; the avatar flies as the commander. With no plan,
-- the avatar takes the best command slot (today's launch).
function crewLaunch()
  local cl = crewLibNow()
  -- A RESTORED craft (a fleet record, a scene change): its seats came with
  -- it. The avatar rides it only if their member is in one of them — the
  -- crew may have climbed into a fresh launch since the record was written.
  if not (cl and cl.launchPlan and podCrewed and launch_mode and not released) then
    if cl and not avatarSeatedIn(bp_by_uid) then
      crewAboard, piloting = false, false
      log("vessel: restored without its crew — they are elsewhere now")
      return
    end
    avatarExclusive()
    seatAvatarCheck()
    return
  end
  avatarExclusive()
  -- the member is in this craft now: no fleet record keeps them seated
  -- elsewhere (one written before the launch, restored after it)
  local act0 = cl.activeId and cl.activeId()
  local fl = save.get("fleet.craft")
  if act0 and type(fl) == "table" then
    local dirty = false
    for _, rec in pairs(fl) do
      for _, d in ipairs(type(rec) == "table" and rec.parts or {}) do
        local def = cl.seatDef(d)
        for k = 1, (def and #def.seats or 0) do
          if cl.memberAt(d, k) == act0 then cl.setMemberAt(d, k, nil); dirty = true end
        end
      end
      if type(rec) == "table" and rec.crew == true then rec.crew = false; dirty = true end
    end
    if dirty then save.set("fleet.craft", fl) end
  end
  local plan = (bp and type(bp.crew) == "table" and bp.crew) or save.get("shipyard.crew")
  local active = cl.activeId and cl.activeId()
  local avail = function(id)
    local r = cl.get(id)
    if not r or r.status == "dead" then return false end
    if id == active then return true end
    return r.status == "base"
  end
  local list, cmdr = cl.launchPlan(bp_by_uid, type(plan) == "table" and plan or nil, avail, active)
  for _, e in ipairs(list) do
    seatMember(e.uid, e.slot, e.id)
    if cl.noteAboard then pcall(cl.noteAboard, e.id, craftName) end
  end
  if cmdr and cmdr ~= active and cl.launchAs then
    -- the avatar flies as the commander; the member it was goes into the building
    pcall(cl.launchAs, cmdr, craftName)
  end
  setStationOf(cmdr or active)
  seatAvatarCheck()
  log(string.format("vessel: %d crew aboard at launch", #list))
end
-- Does this departing set carry seated crew (they leave as a live craft)?
function depHasCrew(dep)
  local c = crewLibNow()
  if not c then return false end
  for u in pairs(dep) do
    local d = bp_by_uid[u]
    local def = d and c.seatDef(d)
    if def then for k = 1, #def.seats do if c.memberAt(d, k) then return true end end end
  end
  return false
end

-- A warp refusal or drop, said where the player looks (the warp chip,
-- warp_chip.lua) as well as in the log. A global, not a local: fixedUpdate
-- sits at LuaJIT's upvalue ceiling (platform 0086).
function warpSay(msg)
  log(msg)
  local wc = findScript("warp_chip")
  if wc and wc.say then pcall(wc.say, msg) end
end

-- Rails warp waits while anyone is on EVA in space (§5.7).
function evaBlocksWarp()
  local c = findScript("crew")
  if not (c and c.onEvaInSpace) then return false end
  local ok, on = pcall(c.onEvaInSpace)
  return ok and on == true
end

-- The crew has just climbed in: the RCS Pack refills from this craft's
-- propellant, Oxygen Tanks fill from its air, the record says aboard.
function crewBoarded(node)
  local c = findScript("crew")
  local id = c and c.activeId and c.activeId()
  if not id then return end
  local ep = findScript("eva_pack")
  if ep and ep.refill then pcall(ep.refill, id, dock.node) end
  local I = findScript("items")
  if I and I.refillO2 and c.packOf then pcall(I.refillO2, c.packOf(id)) end
  if c.noteAboard then pcall(c.noteAboard, id, craftName) end
end

-- Each tank aboard: { { uid, left, cap, t (tonnes held), stage order } } in
-- the order the engines draw them (the stage that leaves first, first).
function tankList()
  local out = {}
  for i, t in ipairs(tanks) do
    if t.uid and aboard(t.uid) then
      out[#out + 1] = { uid = t.uid, left = t.left or 0, cap = t.fuel or 0, t = (t.left or 0) * (t.ft or 0),
                        order = i, branch = t.branch and true or false }
    end
  end
  return out
end
-- PUMP up to `units` of propellant from tank part `from` to tank part `to`:
-- what fits in `to`, never more than `from` holds. The pool, the tanks'
-- masses (massSync) and the staging's Δv follow on the next tick. → moved.
function tankTransfer(from, to, units)
  if from == to then return 0 end
  local a, b = nil, nil
  for _, t in ipairs(tanks) do
    if t.uid == from and not a then a = t end
    if t.uid == to and not b then b = t end
  end
  if not (a and b and aboard(from) and aboard(to)) then return 0 end
  local room = math.max(0, (b.fuel or 0) - (b.left or 0))
  local move = math.max(0, math.min(units or math.huge, a.left or 0, room))
  if move <= 0 then return 0 end
  a.left = (a.left or 0) - move
  b.left = (b.left or 0) + move
  fuelSync()
  return move
end

-- What the HUD / panels say about the hold. nil when the craft has no bays —
-- the row hides itself rather than reading "0 / 0 kg".
function holdLine()
  if not holdId then return nil end
  local inv = findScript("inventory")
  if not inv then return nil end
  return string.format("HOLD  %s", inv.line(holdId))
end

-- ── the peripherals interface ──────────────────────────────────────────────
-- What the peripherals panel talks to. It's a GENERIC device browser: it asks
-- for the fitted device list and toggles entries by id, so a new peripheral
-- appears in the UI the moment it's in the DEVICES registry above — no panel
-- edits, no new scene nodes, no second place to keep in sync.
function peripherals()
  local out = {}
  for id, dev in pairs(DEVICES) do
    if #dev.parts > 0 then
      out[#out + 1] = { id = id, label = dev.label, key = dev.key, on = dev.on,
                        anim = dev.anim, count = #dev.parts, order = dev.order or 50,
                        -- A thruster bus is ON/OFF; a folding leg is
                        -- DEPLOYED/STOWED. The row says whichever fits.
                        verbOn = dev.verb_on or "DEPLOYED",
                        verbOff = dev.verb_off or "STOWED",
                        instant = dev.launch == false and dev.speed >= 8.0 }
    end
  end
  table.sort(out, function(a, b)
    if a.order ~= b.order then return a.order < b.order end
    return a.label < b.label
  end)
  return out
end

-- Toggle (or set) one device. Same path the keybind takes, so the panel button
-- and the key are genuinely the same control — never two half-wired ones.
function setPeripheral(id, on)
  local dev = DEVICES[id]
  if not dev or #dev.parts == 0 then return false end
  -- A probe out of contact (or dark) takes no commands, from the console either.
  if elec.control == false then
    dock.msg = "no control — " .. (elec.why or "no signal")
    return false
  end
  if on == nil then on = not dev.on end
  if dev.on == on then return true end
  dev.on = on
  -- Every part of the kind follows (the RCS bus is a master switch on its own).
  if dev.state then
    for _, u in ipairs(dev.parts) do
      local d = bp_by_uid[u]
      if d then
        d.st = d.st or {}
        d.st[dev.state] = on
      end
    end
  end
  if id == "gear" then gear_deployed = on end
  local node = dock.node
  if node and node.valid then
    local i = assembly.info(node)
    local bx, by, bz = base_of(node, i)
    sfx3(SFX.gear, bx, by, bz, 0.7, on and 1.0 or 0.9)
  end
  log(dev.label .. (on and " deployed" or " retracted"))
  return true
end

-- The docking rows: one entry per port, in a stable order, with everything the
-- panel needs to draw and act on it.
-- Lock (or clear) the berth we're flying to. The panel cycles through every
-- port in reach; a lock keeps the readout, the guides and DOCK ALIGN all
-- describing the SAME berth instead of snapping to whatever drifts nearest.
function dockLock()
  local t = dock.target
  if dock.lock then
    dock.lock = nil
    dock.msg = "target released"
    return false
  end
  if not t then
    dock.msg = "nothing in range to lock"
    return false
  end
  dock.lock = { id = t.id, uid = t.uid }
  dock.msg = "target locked: " .. (t.name or "craft")
  return true
end

function dockPorts()
  local out = {}
  for _, p in ipairs(dock.ports) do
    out[#out + 1] = { uid = p.uid, mate = p.mate, buried = p.buried and not p.mate,
                      y = p.y }
  end
  table.sort(out, function(a, b)
    if a.y ~= b.y then return a.y > b.y end
    return a.uid < b.uid
  end)
  return out
end

-- Forward-declared: a tank blast can chain into neighbors breaking.
local break_part

-- One-shot diagnostic (once per play session): confirm in the Console that the
-- destruction FX are actually being issued and where, so a "no explosion" report
-- can be pinned to spawn vs render.
local diag_fx_logged = false

break_part = function(node, uid, d, c, hx, hy, hz, depth)
  -- A part that has already left this craft (shed, staged, split by an earlier
  -- link of this same chain) is not ours to break, and splitting its node a
  -- second time would split a node that is no longer our child.
  if integ.gone[uid] then return end
  depth = (depth or 0) + 1
  part_hp[uid] = 0
  -- Ship velocity so the blast's embers/sparks/smoke carry its momentum.
  local _iv = assembly.info(node)
  local evx, evy, evz = 0.0, 0.0, 0.0
  if _iv and _iv.vel then evx, evy, evz = _iv.vel.x, _iv.vel.y, _iv.vel.z end
  local is_boom = (d.fuel or 0) > 0 or d.kind == "engine"
  local fx = fxd()
  if fx then fx.explode(hx, hy, hz, evx, evy, evz, is_boom) else spawnEffect("Explosion", hx, hy, hz) end
  if not diag_fx_logged then
    diag_fx_logged = true
    log(string.format(
      "FX DIAG: first Explosion spawned at (%.1f, %.1f, %.1f) — if you see no " ..
      "particle here, it's a render issue, not a missing call.", hx, hy, hz))
  end
  -- Fuel tanks AND engines are EXPLOSIVE: they detonate, jolt harder, and can
  -- set off their neighbours (the chain reaction below).
  -- Explosive means there is something to burn: a tank while IT holds more
  -- than dregs (tanks drain bottom-up, so a spent lower tank is just a can), an engine only while it is LIT. A cold, dry engine
  -- bell crushed on landing is a broken part, not a bomb (it used to detonate
  -- and set off the tank and the pod above it).
  local is_tank = (d.fuel or 0) > 0 and (tankLeft(uid) or 0) > d.fuel * 0.05
  local is_explosive = is_tank or (d.kind == "engine" and throttle > 0.05 and fuel > 0)
  add_shake(is_explosive and 0.8 or 0.45)
  -- A boom at the break, spatial through the SFX bus; explosive parts go off
  -- deeper and louder. Slight per-part pitch spread so a chain doesn't machine-gun.
  sfx3(is_explosive and SFX.boom or SFX.explode, hx, hy, hz,
    is_explosive and 1.0 or 0.8, 0.92 + (uid % 5) * 0.03)
  drop_part(uid)
  crewPartBroken(node, uid, hx, hy, hz)
  -- A destroyed chute stops dragging (it stayed in the pool and kept pulling,
  -- canopy and all, from a part that was no longer there), and a destroyed
  -- device stops being driven.
  local live_chutes = {}
  for _, ch in ipairs(chutes) do
    if ch.uid ~= uid then live_chutes[#live_chutes + 1] = ch end
  end
  if #live_chutes ~= #chutes then chutes = live_chutes end
  for _, dev in pairs(DEVICES) do
    for i = #dev.parts, 1, -1 do
      if dev.parts[i] == uid then table.remove(dev.parts, i); dev.nodes[uid] = nil end
    end
  end
  -- Any part failing against the ground leaves a scar; a fuel tank tears a real
  -- crater (bigger with more fuel), an engine a modest one, a strut a scuff.
  local crater_r = is_tank and (2.6 + math.min(4.0, (d.fuel or 0) / 55))
    or (d.kind == "engine" and 2.1 or 1.5)
  make_crater(hx, hy, hz, crater_r)
  log("BOOM: " .. (d.label or d.id or "part") .. " destroyed!")
  -- CHAIN REACTION: every break throws a concussion into the parts STILL
  -- ATTACHED nearby (staged-away parts aren't children — the blast can't reach
  -- bookkeeping ghosts). An EXPLOSIVE part (fuel tank or engine) goes off far
  -- harder — extra fireballs, a shove on the whole vessel, and enough damage to
  -- set off its explosive neighbours, which cook off in turn and ripple through
  -- a tightly-packed stack. Even a structural break sends a lighter shock that
  -- can finish an already-wounded neighbour.
  if depth <= 6 then
    local blast, power
    if is_explosive then
      if fx then
        fx.explode(hx + 0.7, hy + 0.5, hz - 0.4, evx, evy, evz, false)
        fx.explode(hx - 0.5, hy + 0.9, hz + 0.6, evx, evy, evz, false)
      else
        spawnEffect("Explosion", hx + 0.7, hy + 0.5, hz - 0.4)
        spawnEffect("Explosion", hx - 0.5, hy + 0.9, hz + 0.6)
      end
      local i0 = assembly.info(node)
      if i0 then
        -- The blast shoves the hull along the local UP (radial), not world +Y:
        -- on a planet's flank world +Y is sideways.
        local ux, uy, uz = radial_up(hx, hy, hz)
        local j = i0.mass * 1.5
        assembly.impulseAt(node, vec3(ux * j, uy * j, uz * j), vec3(hx, hy, hz))
      end
      blast, power = crater_r, 0.9
    else
      blast, power = crater_r * 0.8, 0.4
    end
    for u2, d2 in pairs(bp_by_uid) do
      local hp2 = part_hp[u2]
      if u2 ~= uid and hp2 and hp2 > 0 and not integ.gone[u2] then
        local dx2, dy2, dz2 = d2.x - d.x, d2.y - d.y, d2.z - d.z
        local dist = math.sqrt(dx2 * dx2 + dy2 * dy2 + dz2 * dz2)
        if dist < blast then
          local c2 = childNear(node, d2.x, d2.y, d2.z, 0.05) -- the live child for u2, matched by position
          if c2 then
            part_hp[u2] = hp2 - (1.0 - dist / blast) * power
            if part_hp[u2] <= 0 then
              break_part(node, u2, d2, c2, hx, hy, hz, depth)
            end
          end
        end
      end
    end
  end
  if d.kind == "crewed" or uid == pod_uid then
    -- The POD is the ship. Its pilot is put clear of the wreck AT REST, for the
    -- reason `shatter` gives: the wreck's velocity at the moment it fails is the
    -- worst number of the flight, and a crew ejected at it (plus a 3 m/s hop
    -- along world +Y, sideways on a planet's flank) leaves the planet.
    -- (A PROBE core is the ship too; its crew, if any, were never in it — they
    -- stay where they are and the controls go back to them.)
    destroyed = true
    silence_loops()
    local was_piloting = piloting
    crewEvacuate(node, hx, hy, hz)
    if crewAboard then
      local ux, uy, uz = radial_up(hx, hy, hz)
      standDown(node, hx + ux * 2.0, hy + uy * 2.0, hz + uz * 2.0, 0, 0, 0)
    elseif piloting then
      releaseControl()
      controlFallback(node.id)
    end
    log("the pod is gone — vessel lost")
    local fx_s = findScript("sfx") -- the sting and the VESSEL LOST caption
    if fx_s and fx_s.vesselLost then fx_s.vesselLost(was_piloting, craftName) end
    return
  end
  -- The broken part shears off as its own wreck. It keeps its velocity; only an
  -- EXPLOSIVE part (fuel, a lit engine) adds a blast of its own — a crushed
  -- strut does not fling itself away. It is moved clear of the hull first.
  local i2 = assembly.info(node)
  if c and c.valid and i2 and #i2.parts > 1 then
    local away = clearAway(node, { [uid] = true })
    integ.gone[uid] = true
    integ.gen = integ.gen + 1
    quench({ c })
    assembly.split(node, { c }, function(junk)
      debris_kick(junk, hx, hy, hz, is_explosive and 3.0 or 0.0, away, node)
    end)
    -- What hung off the part that broke has nothing holding it any more: every
    -- piece of the attachment tree the break cut off from the pod comes away as
    -- its own body (the engine under a tank that blew, a booster whose mount
    -- went). The pod's piece is the craft that keeps flying.
    local pieces = {}
    for _, k in ipairs(bp_kids[uid] or {}) do
      local set, queue = {}, { k }
      while #queue > 0 do
        local u = table.remove(queue)
        if not set[u] and not integ.gone[u] then
          set[u] = true
          for _, kk in ipairs(bp_kids[u] or {}) do queue[#queue + 1] = kk end
        end
      end
      pieces[#pieces + 1] = set
    end
    local below = {}
    for _, set in ipairs(pieces) do for u in pairs(set) do below[u] = true end end
    local above = {}
    for u in pairs(bp_by_uid) do
      if u ~= uid and not below[u] and not integ.gone[u] then above[u] = true end
    end
    pieces[#pieces + 1] = above
    for _, set in ipairs(pieces) do
      if next(set) and not (pod_uid and set[pod_uid]) then
        shedSet(node, set, "its mount broke", 1.0, false)
      end
    end
  end
end

-- A HIT FROM OUTSIDE (a weapon: scripts/surveyor.lua's plasma bolt; later
-- anything that wounds a hull at a point): the part's hp down by `amount`,
-- its wear repainted (the hull shader's scorch), and at 0 it BREAKS the way a
-- crash breaks it (break_part: its blast, its chain, its crew). World point
-- x,y,z is where it was struck (the blast's centre). → the new hp, or nil
-- when the part isn't aboard and whole.
function hitPart(uid, amount, x, y, z)
  local h = partHp(uid)
  if not h or h <= 0 then return nil end
  local node = dock.node
  local d = bp_by_uid[uid]
  local c = node and node.valid and child_of_uid(node, uid) or nil
  local hp = math.max(0, h - math.max(0, amount or 0))
  part_hp[uid] = hp
  if c then set_part_damage(c, hp) end
  if hp <= 0 and c and d then
    local w = c.worldPos
    break_part(node, uid, d, c, x or (w and w.x), y or (w and w.y), z or (w and w.z))
  end
  return hp
end

-- A CATASTROPHIC hit doesn't just crush the contact parts — the airframe FAILS
-- and the ship comes apart. Every surviving part shears into its own tumbling
-- wreck kicked away from the impact, over a big crater and a low boom. Latched
-- by `destroyed` so it fires exactly once.
local function shatter(node, hx, hy, hz, spd, info)
  if destroyed then return end
  destroyed = true
  log("CATASTROPHIC BREAKUP")
  add_shake(1.4) -- the whole airframe failing is a hard jolt
  local evx, evy, evz = 0.0, 0.0, 0.0
  if info and info.vel then evx, evy, evz = info.vel.x, info.vel.y, info.vel.z end
  local fx = fxd()
  if fx then
    fx.explode(hx, hy, hz, evx, evy, evz, true)
    fx.explode(hx + 0.8, hy + 0.6, hz - 0.5, evx, evy, evz, false)
    fx.explode(hx - 0.6, hy + 0.3, hz + 0.7, evx, evy, evz, false)
  else
    spawnEffect("Explosion", hx, hy, hz)
    spawnEffect("Explosion", hx + 0.8, hy + 0.6, hz - 0.5)
    spawnEffect("Explosion", hx - 0.6, hy + 0.3, hz + 0.7)
  end
  sfx3(SFX.boom, hx, hy, hz, 1.0, 0.85)
  sfx3(SFX.explode, hx, hy, hz, 0.9, 1.05)
  -- CAPTIONS. The engine draws these only while a player has them on, so they
  -- are written beside the sound with no `if` around them (v0.33.0). Only the
  -- sounds that CARRY something go here — the ones a player who cannot hear
  -- them would otherwise learn about from the wreckage.
  caption("the hull breaks up")
  local fx_s = findScript("sfx") -- the sting and the VESSEL LOST caption
  if fx_s and fx_s.vesselLost then fx_s.vesselLost(piloting, craftName) end
  if fx then fx.explode(hx + 0.2, hy + 1.4, hz + 0.3, evx, evy, evz, true) -- a secondary up high
  else spawnEffect("Explosion", hx + 0.2, hy + 1.4, hz + 0.3) end
  make_crater(hx, hy, hz, 4.8)
  silence_loops()
  -- Put the pilot clear of the wreck — AT REST.
  --
  -- They used to be stood down carrying the wreck's own velocity plus a hop, and
  -- the wreck's velocity at the moment of a breakup is by definition the worst
  -- number in the whole flight. A crew ejected at it does not land near the
  -- crash; they leave. Reported as *"I got sent flying off infinitely into the
  -- void and got softlocked"* — an astronaut on an escape trajectory, on foot,
  -- with nothing to fly and no way home.
  --
  -- Surviving a breakup is meant to cost you the ship, not the save. They come
  -- to a stop beside the wreck; getting home from there is `flight_ops`.
  -- Everyone still seated goes with the airframe (§2.3: the craft is lost
  -- with them in it; with death off the avatar is set down as before).
  for u in pairs(bp_by_uid) do crewPartBroken(node, u, hx, hy + 2.0, hz) end
  if crewAboard then
    standDown(node, hx, hy + 2.0, hz, 0, 0, 0)
  elseif piloting then
    releaseControl()
    controlFallback(node.id)
  end
  -- Shear every part loose (leave the last one so the compound stays valid).
  local live = {}
  for _, ch in ipairs(node:children()) do live[#live + 1] = ch end
  -- The kick is the airframe failing — real energy, but a hull that hit at
  -- 50 m/s does not throw its parts at 11 m/s straight up: capped at 8, and
  -- every piece is first moved clear of the parts around it so the engine has
  -- no overlap to "resolve" on top of it.
  local kick = math.min(8.0, spd * 0.18)
  local shards = {}
  local rx, up, rz = basis(node)
  local bx, by, bz = base_of(node, info)
  for i = 1, #live - 1 do
    local ch = live[i]
    if ch and ch.valid then
      local u
      for uu, dd in pairs(bp_by_uid) do
        if not integ.gone[uu] and math.abs((ch.x or 0) - dd.x) < 0.06
          and math.abs((ch.y or 0) - dd.y) < 0.06 and math.abs((ch.z or 0) - dd.z) < 0.06 then
          u = uu
          break
        end
      end
      local away = u and clearAway(node, { [u] = true }) or nil
      if u then integ.gone[u] = true end
      quench({ ch })
      assembly.split(node, { ch }, function(junk)
        -- Every shard passes through the hull AND the shards before it for a
        -- moment: they were one body a tick ago, touching at every seam.
        debris_kick(junk, hx, hy, hz, kick, away, node, shards)
        shards[#shards + 1] = junk
      end)
    end
  end
  integ.gen = integ.gen + 1
  for uid in pairs(part_hp) do part_hp[uid] = 0 end
end

-- Closing speed INTO THE SURFACE (m/s) above which a hit fails the whole
-- airframe rather than just the parts it touched — a genuine lithobrake, not a
-- hard landing.
--
-- ⚠ THIS IS THE NORMAL COMPONENT, AND IT HAS TO BE. It was judged on `speedAbs`,
-- the TOTAL contact speed, which is the right metric for per-part wear and the
-- wrong one for total destruction: total speed counts the part of your motion
-- that is ALONG the ground. A touchdown with a few m/s of sink and twelve of
-- lateral drift — which is most landings, on a planet, in wind, off a chute —
-- summed past 13 and vaporised the whole ship the instant it made contact.
-- Reported as *"I tried landing pretty softly with my parachute and a bit of
-- thrust but as soon as it touched the ground it disintegrated"*.
--
-- A fast belly-slide still hurts, and hurts progressively: it feeds `speedAbs`
-- into the per-part damage below, which scrapes, wounds and eventually shears
-- parts off. What it no longer does is skip straight to the whole airframe.
local SHATTER_SPEED = 13.0
-- How much of a contact's speed ALONG the surface counts toward a part's
-- damage (see damage_tick). Global: damage_tick is at its upvalue budget.
SLIDE_FEEL = 0.65

-- The most a single contact may claim beyond the craft's OWN speed before it is
-- treated as a solver artifact rather than a crash.
--
-- A contact's reported speed is the velocity of the contact POINT, which is the
-- body's velocity plus its rotation about that point — so on a real hit it can
-- legitimately exceed the hull's speed, and this allowance covers a fast tumble.
-- What it cannot legitimately be is forty when the ship is doing four. That is
-- what a deep penetration resolving in one tick looks like, and terrain
-- collision drifts out of step with the drawn surface often enough to produce
-- them (floptle/0074): a spike like that used to shatter an intact ship and fire
-- the crew off at the ejection velocity.
local ARTIFACT_MARGIN = 9.0
-- How fast a surviving-but-overloaded part loses HP, per second, at full
-- overload (a hit just short of its crash tolerance). A brief bump chips; a
-- sustained grind tears through in a fraction of a second. Fragile by design.
local DAMAGE_RATE = 3.0
-- One-shot latch for the stale-engine warning (see damage_tick).
local engine_version_warned = false
-- Throttled crash diagnostics to the Console (contact count / worst speed / terrain
-- proximity). Turn on while tuning crashes; the log is rate-limited to twice a
-- second. OFF in the shipped game — it fires on every contact, so taxiing or
-- resting on legs fills the Console with lines about nothing happening. The
-- artifact report above is not gated by it: that one is a real diagnosis.
local DAMAGE_DEBUG = false
local dbg_t = 0

local function damage_tick(node, info, dt)
  -- Disarmed while clamped or still assembling; release starts a settle
  -- window — the pad handshake must never read as a crash (big ships were
  -- shredding themselves the moment they spawned).
  if info.anchored or (launch_mode and not released) then
    damage_arm = time
    return
  end
  if time - damage_arm < 2.5 then return end
  -- SEVERITY is the honest ENERGY of each contact: `speedAbs`, the TOTAL closing
  -- speed. The old model judged by `speed` — the NORMAL component only — which
  -- collapses on a glancing hit or a hit against a CURVED planet (a 30 m/s ram
  -- 65° off-normal read ~12 m/s and bounced off). Total speed captures a ram, a
  -- topple and a belly-slide with ONE number, so it drives every crash effect:
  -- no more dead-zone between a "normal hit" and a "scrape". Pre-scan every live
  -- part's hardest hit (and the worst overall) BEFORE applying anything, so a
  -- catastrophic blow fails the whole airframe even if it landed on the pod.
  local hits = {}
  local worst, wx, wy, wz = 0.0, nil, nil, nil
  -- The airframe-failure test runs on the NORMAL component, tracked separately
  -- from the energy metric that drives per-part wear. See SHATTER_SPEED.
  local worst_normal = 0.0
  -- What the craft is ACTUALLY doing, as the plausibility ceiling for anything a
  -- contact claims. `info.vel` is the compound's velocity in the dominant body's
  -- frame — the same frame the terrain collider is carried in — so on a landing
  -- it is the sink-and-drift the pilot flew, not the planet's 99 m/s of orbit.
  local ov = info.vel
  local own = math.sqrt(ov.x * ov.x + ov.y * ov.y + ov.z * ov.z)
  -- ...and what it was doing a tick ago: by the time a script reads it, the
  -- impact tick has already taken most of the speed away (an 87 m drop that
  -- arrived at 25 m/s read 4 m/s here, which capped a real lithobrake at 13).
  -- The safety net keeps last tick's speed.
  own = math.max(own, integ.spd_before or 0)
  local ceiling = own + ARTIFACT_MARGIN
  local artifacts = 0
  local raw = assembly.impacts(node)
  local kids = #raw > 1 and kidsById(node) or nil
  local touch = #raw > 0 and {} or nil -- uid → impulse: where the craft touches (the stress model's support)
  for _, h in ipairs(raw) do
    -- STALE-ENGINE GUARD: speedAbs is a NEW engine field. If it's missing, the
    -- editor binary predates this session's physics work — damage falls back to
    -- the old normal-speed metric (bounces, hard to break) and the anim/particle
    -- fixes aren't in either. Shout ONCE so it's obvious a rebuild is needed.
    if h.speedAbs == nil and not engine_version_warned then
      engine_version_warned = true
      log("[!] ENGINE OUT OF DATE — impacts have no `speedAbs`. Rebuild/reinstall " ..
        "the editor: the damage energy-metric, particle and animation fixes are " ..
        "in the Rust binary, not the Lua. Run `cargo run -p floptle-editor` (or " ..
        "reinstall the freshly-built version).")
    end
    local uid, c = uid_of_child(node, h.part, kids)
    local d = uid and bp_by_uid[uid]
    local hp = uid and part_hp[uid]
    if uid and touch then touch[uid] = (touch[uid] or 0) + math.max(0, h.impulse or 0) end
    if d and hp and hp > 0 then
      local nrm = h.speed or 0
      local energy = math.max(h.speedAbs or 0, nrm)             -- total closing speed
      -- A contact the craft could not physically have delivered is a solver
      -- artifact, not a crash. Clamp rather than discard: a real hit that merely
      -- brushes the ceiling still lands at full plausible force, and the
      -- clamping is counted so it can be reported instead of hidden.
      if energy > ceiling then
        artifacts = artifacts + 1
        energy = ceiling
        nrm = math.min(nrm, ceiling)
      end
      local slide = math.sqrt(math.max(0.0, energy * energy - nrm * nrm))
      -- What a part FEELS: its speed into the surface, and two thirds of its
      -- speed along it. Along-the-ground speed is partly a scrape, not a
      -- blow: judged at full weight, a rover body brushing the ground at 10
      -- m/s of driving speed was a 10 m/s crash. A fast belly-slide still
      -- wears through (a pod sliding at 25 m/s feels 16), a leg that lands
      -- with 14 m/s of drift still goes, and a ram at a low angle still has
      -- its normal part.
      local feel = math.sqrt(nrm * nrm + (SLIDE_FEEL * slide) ^ 2)
      hits[#hits + 1] = { uid = uid, c = c, d = d, hp = hp,
                          e = feel, slide = slide, x = h.x, y = h.y, z = h.z }
      if energy > worst then worst, wx, wy, wz = energy, h.x, h.y, h.z end
      if nrm > worst_normal then worst_normal = nrm end
    end
  end
  -- The parts that touched, for the stress model (stressContact): each by its
  -- impulse, plus a quarter of the mean so a part resting with none (the
  -- engine resolves a resting contact by position) still bears a share.
  integ.contact = nil
  if touch and next(touch) then
    local sum, nt = 0, 0
    for _, j in pairs(touch) do sum, nt = sum + j, nt + 1 end
    local floor = 0.25 * sum / nt + 1e-6
    for u, j in pairs(touch) do touch[u] = j + floor end
    integ.contact = { t = time, w = touch }
  end
  if artifacts > 0 and time - dbg_t > 1.0 then
    dbg_t = time
    log(string.format(
      "CRASH: ignored %d contact(s) reporting more than the craft's own %.1f m/s "
      .. "— collision is out of step with the surface here (floptle/0074)",
      artifacts, own))
  end
  -- DIAGNOSTIC: when contacts arrive, report (throttled) what the crash model sees —
  -- contact count, the worst closing speed vs the shatter threshold, and whether the
  -- terrain query finds ground at the impact. This turns "it just slides / no crater"
  -- into hard data: no line at all = the compound reports ZERO terrain contacts (LOD/
  -- residency/anchor), a line with worst≈0 = grazing-only, a line with sd=nil = the
  -- crater is gated out because no resident terrain is under the hit.
  if DAMAGE_DEBUG and #raw > 0 and time - dbg_t > 0.5 then
    dbg_t = time
    local sd = wx and terrain.query(wx, wy, wz)
    log(string.format(
      "CRASH DIAG: %d contact(s), worst=%.1f m/s (shatter %.0f), terrain sd=%s",
      #raw, worst, SHATTER_SPEED, sd and string.format("%.2f", sd) or "nil (no ground here)"))
  end
  -- A genuinely violent strike fails the WHOLE airframe — the ship bursts apart.
  -- Gated on how fast it went INTO the ground, not on how fast it was going: a
  -- ship sliding along the surface is a ship being torn up part by part, and the
  -- loop below is what does that.
  if not destroyed and worst_normal >= SHATTER_SPEED and wx then
    shatter(node, wx, wy, wz, worst_normal, info)
    return
  end
  local spark = time - scrape_t > 0.10
  local dug = false
  -- Ship world velocity, handed to crash effects so sparks/dust/debris ride its
  -- momentum instead of being stranded in space (inherit_velocity on the effects).
  local vv = info.vel
  local vx, vy, vz = vv.x, vv.y, vv.z
  for _, h in ipairs(hits) do
    local live = part_hp[h.uid] or 0   -- a chain reaction may have claimed it first
    if live > 0 then
      -- Wounded parts are weaker: tolerance scales with remaining HP, so repeated
      -- hits COMPOUND. A hit that MEETS the (HP-scaled) crash tolerance crushes
      -- the part on contact; between the ~35%-of-tolerance floor and that limit
      -- it WEARS at a dt-scaled rate set by how far past the floor it landed —
      -- a brief bump scuffs, a sustained grind tears through in a fraction of a
      -- second. Legs get the same treatment but a far higher tolerance (they're
      -- built to hit the ground — when deployed).
      local tol = part_tolerance(h.d) * (0.45 + 0.55 * live)
      local floor = tol * 0.35
      if h.e >= tol then
        set_part_damage(h.c, 0)
        part_hp[h.uid] = 0
        break_part(node, h.uid, h.d, h.c, h.x, h.y, h.z)
      elseif h.e >= floor then
        local over = (h.e - floor) / math.max(0.5, tol - floor)   -- 0 … 1
        part_hp[h.uid] = live - over * DAMAGE_RATE * dt
        set_part_damage(h.c, part_hp[h.uid])
        if part_hp[h.uid] <= 0 then
          break_part(node, h.uid, h.d, h.c, h.x, h.y, h.z)
        elseif spark then
          -- A part grinding on the surface throws hot sparks and kicks up gritty
          -- dust (not soft smoke) — both inherit the ship's velocity so they streak
          -- along the scrape instead of puffing straight up.
          local fx = fxd()
          if fx then fx.scrape(h.x, h.y, h.z, vx, vy, vz)
          else
            spawnEffect("Sparks", h.x, h.y, h.z)
            spawnEffect("ScrapeDust", h.x, h.y, h.z)
          end
          add_shake(math.min(0.4, 0.1 + over * 0.3))
          sfx3(SFX.stage, h.x, h.y, h.z, math.min(0.6, 0.25 + over * 0.4), 1.2)
        end
        -- TERRAIN DEFORMATION: a hull biting the ground GOUGES it — you can't
        -- grind or ram the surface without carving a scar (and that scar is why
        -- the ship keeps taking damage as it drags). Rate-limited to one dig per
        -- beat so a drag cuts a trench, not a canyon; only when the contact is
        -- genuinely on terrain (legs are exempt — they're meant to touch down).
        if spark and not dug and (h.d.legs or 0) ~= 1 then
          local r = 0.6 + math.min(2.0, h.e * 0.12)
          local sd = terrain.query(h.x, h.y, h.z)
          if sd and sd < r and baseDigRadius(h.x, h.y, h.z, r) >= r then
            terrain.dig(h.x, h.y, h.z, r, 0.6)
            groundChangedAt(h.x, h.y, h.z, r)
            -- SCUFF the surface where the hull bit in: a dark scratch mark painted
            -- over a wider radius than the gouge (color-only — no remesh cost), so
            -- the scar reads even where the dig is shallow.
            terrain.paint(h.x, h.y, h.z, r * 1.4, 0.12, 0.1, 0.09, 0.55)
            dug = true
          end
        end
      end
      if destroyed then break end
    end
  end
  if spark then scrape_t = time end
  if destroyed then return end
  -- Damaged parts SMOULDER: a smoke puff re-anchored to the part each beat,
  -- so the trail follows the flying (or crashed) ship.
  if time - smoke_t > 0.7 then
    smoke_t = time
    local rx, up, rz = basis(node)
    local bx, by, bz = base_of(node, info)
    for uid, hp in pairs(part_hp) do
      if hp > 0 and hp < 0.65 then
        local d = bp_by_uid[uid]
        if d then
          -- Keep the visible damage in sync (a part wounded by a CHAIN reaction
          -- it wasn't directly hit by still shows its scars).
          set_part_damage(child_of_uid(node, uid), hp)
          local fx = fxd()
          if fx then
            fx.smolder(uid,
              bx + rx.x * d.x + up.x * d.y + rz.x * d.z,
              by + rx.y * d.x + up.y * d.y + rz.y * d.z,
              bz + rx.z * d.x + up.z * d.y + rz.z * d.z,
              info.vel.x, info.vel.y, info.vel.z)
          else
            spawnEffect("Smoke",
              bx + rx.x * d.x + up.x * d.y + rz.x * d.z,
              by + rx.y * d.x + up.y * d.y + rz.y * d.z,
              bz + rx.z * d.x + up.z * d.y + rz.z * d.z)
          end
        end
      end
    end
  end
end


-- ── lifecycle ───────────────────────────────────────────────────────────────
-- Rename this craft (the Tracking Station; a restored or undocked craft wakes
-- with its name). Node names can't be written from Lua, so this is the name.
function renamed(name)
  if type(name) == "string" and name ~= "" then craftName = name end
end

function start(node)
  dock.node = node
  -- A craft that just UNDOCKED wakes up with the blueprint the vessel it left
  -- handed it at the seam, keyed by this root's own id (see `undock`) — not the
  -- shipyard's launch build, which describes a completely different ship.
  local hk = "dock.handoff." .. tostring(node.id or 0)
  local handoff = save.get(hk)
  if handoff and handoff.parts then
    save.set(hk, false)
    if handoff.name then craftName = handoff.name end
    local had_state = false
    for _, d in pairs(handoff.parts) do if d.st ~= nil then had_state = true end end
    load_bp(handoff)
    -- `load_bp` rolls a fresh build out of the VAB with full tanks; an undocked
    -- module arrives with exactly what it was carrying at the seam.
    fuelFill(math.min(fuel_cap, handoff.fuel or fuel_cap))
    -- Each battery's charge rides in its record now; a record from before that
    -- has only the pooled figure, shared out by capacity.
    if not had_state and handoff.charge then elecSetCharge(handoff.charge) end
    dock.arm = time + (handoff.lockout or 0.0)   -- drift clear before re-latching
    -- A craft rebuilt in flight (flight_ops fleet restore) is pushed to its
    -- orbital velocity in the rebuild's callback: one tick's jump from rest
    -- the safety net must not read as a solver kick and take back.
    integ.handoff_t = time + 3.0
    -- ...and the velocity it is restored at, given by massSync once the parts
    -- weigh what they carry (so the push is sized for the real craft).
    if type(handoff.vel) == "table" then integ.push = handoff.vel end
    -- The crew was in this seat when the game was saved: they still are, and
    -- they're flying it (the boarding handoff seats them on the first tick).
    -- (crew slice 2) ...if the avatar's member is in one of its seats: a
    -- stale `crew` flag on a craft they left must not pull them back in. A
    -- record from before the seats (no slot anywhere) trusts the flag.
    if handoff.crew and podCrewed and avatarSeatedIn(handoff.parts) then boarding = true end
    -- ...in the crew position they were sitting in (a pod, or the seat).
    if handoff.station then setStation(handoff.station) end
    -- A craft saved before it ever flew (released on the pad, a rover driven
    -- off it) is still one that hasn't: no recovery refund for a launch.
    if handoff.flown == false then hasFlown = false end
    log(string.format("%s: undocked module online (%d parts, %.0f fuel)",
      node.name or "vessel", part_total, fuel))
  else
    load_bp()
  end
  if (save.get("shipyard.pilot") or 0) == 1 then
    save.set("shipyard.pilot", 0)
    -- A fresh rollout gets a name of its own (the builder's, if it gave one).
    if craftName == "Vessel" then
      local n = (save.get("names.n") or 0) + 1
      save.set("names.n", n)
      craftName = (bp and bp.name) or string.format("%s %d", podCrewed and "Craft" or "Probe", n)
      holdId = (holdCap > 0) and ("hold:" .. craftName) or nil
      if holdId then
        local inv = findScript("inventory")
        if inv then inv.setCap(holdId, holdCap) end
      end
    end
    boarding = true
    launch_mode = true
    hasFlown = false
    leftPad = false
  end
end

local runaway_logged = false
-- Clamp-release readiness: the full blueprint count, OR a part count that has
-- stopped changing (a blueprint part that never spawned must not weld the
-- clamps shut forever — the spawner logs what went missing).
local parts_seen, parts_t = -1, 0.0

local function assembly_ready(info)
  if #info.parts >= part_total then return true end
  if #info.parts ~= parts_seen then
    parts_seen, parts_t = #info.parts, time
  end
  return #info.parts > 0 and time - parts_t > 2.0
end

-- ── physics integrity: the seat, the clamps, joint stress, breakup, safety ──
--
-- THE LAUNCH BUG (Ty, 2026-10-01: "when i pressed space to launch my ship i
-- immidiately glitched out absolutely crazily being sent absolutely flying").
-- Measured on engine 0.111.1 with the default contract craft, launched through
-- the builder → spawner path and released the way SPACE does:
--
--   * The seated crew is a live DYNAMIC capsule (r 0.33, 2 m tall) that this
--     script parks at the pod every tick. Since engine 0.104 ("Vessels collide")
--     bodies and assemblies push each other apart — so the pilot sat INSIDE the
--     hull, overlapping the pod, the tank and the chute. While clamped nothing
--     happens (an anchored compound is never moved); the moment the clamps let
--     go, every tick resolved that overlap again.
--   * The overlap pushes the hull by POSITION only (the pilot is handed the
--     ship's velocity, so there is no closing speed and no impulse), so the
--     craft hung on its own pilot while gravity piled up velocity: -0.9 m/s
--     after 0.25 s while it had not moved at all, -8 m/s after 1.7 s.
--   * Then the engine's per-step correction budget ran away (pairs.rs: once the
--     budget rounds a hair below zero, every further correction is scaled by a
--     NEGATIVE factor and the budget doubles): the hull jumped 26 m sideways in
--     one tick, off the pad, and fell 9 m onto bare terrain with the stored
--     velocity. In a stand-alone repro the same thing flips the stack 102° in a
--     single step. That is "sent flying / glitched into the terrain".
--
-- The fix here is that a seated pilot is a passenger, not a body: KINEMATIC
-- while seated (kinematic bodies take no part in body-vs-assembly contacts),
-- handed back to physics when they stand down. With that alone the same launch
-- measures 0.40 m of drop onto the deck and v = 0, every time; the spawner now
-- also seats the craft 2 cm over the deck instead of 40 cm.
--
-- The rest of this section makes the craft behave like a physical object that
-- can fail rather than a rigid brick that either bounces or vaporises:
--
--   STRESS. Every attachment (a part to its parent in the builder's tree) has a
--   strength in kN. Each joint is a cut through the craft, and it carries the
--   force that really passes through it: what the side beyond it needs to
--   move with the craft (its mass times the PROPER acceleration at its centre
--   — what the hull feels, gravity excluded — spin included, ω×(ω×r) + α×r),
--   less the external forces already acting on that side: each engine's
--   thrust, the air on each part, the canopies, the water, and the ground
--   where the craft touches it (stressSolve, above stressTick). So a stack on
--   the pad loads its BOTTOM joint with the weight above it, and under thrust
--   the joint over the engine carries the most. Acceleration and forces are
--   smoothed over ~0.1 s alike. A joint over its limit accumulates strain and
--   lets go; more than twice its limit, it lets go at once. Dynamic pressure
--   (½ρv²) has its own limit per part — tiny for a deployed solar panel or
--   dish, very large for the hull — and an open parachute tears off above its
--   safe deploy pressure.
--
--   BREAKUP. What fails is the side of the joint WITHOUT the pod (the same tree
--   cut a decoupler makes). It leaves as its own body with the velocity it had
--   (the engine's split conserves point velocity), its engines/tanks leave the
--   pools, the craft's mass and centre of mass are recomputed by the engine, and
--   staging events that rode with it go too. A heavily overloaded fuelled tank
--   or a lit engine goes off as it tears away (the existing explosion hooks).
--
--   NO DEPENETRATION KICKS. A split piece starts exactly where it was: touching
--   its old neighbours, and sometimes overlapping them (a leg's footprint box
--   sits inside the hull). Left alone the engine resolves that overlap as a
--   collision on the next step — a kick nobody asked for, and the trigger for
--   the budget runaway above. So every piece that leaves is first moved clear
--   of what stays behind, along the direction it is leaving in, by exactly the
--   overlap of their collider boxes plus 3 cm, and gets NO impulse of its own.
--   (There is no way to switch collision off between two assemblies from a
--   script — no runtime layer matrix, and project.ron is not this script's — so
--   "suppressed briefly" is done geometrically, which also costs nothing.)
--
--   SAFETY NET. Whatever is left over is caught and LOGGED, never hidden: a
--   spin past 12 rad/s is braked back to it with an exact angular impulse
--   (inertia from the part boxes), a one-tick speed GAIN that no force on board
--   explains is clamped back, a one-tick jump of the hull is reported, and a
--   NaN anywhere stops the controller from feeding it back into the sim.
--   `integrity()` reports how often each fired.

-- Joint strength (kN) by part kind: the load the attachment to the parent part
-- takes before it starts to give. A part may carry its own `strength` in the
-- blueprint (builder.lua's registry); this is the fallback for older builds.
-- Scale: the starter rocket's pod (1.3 t with its chute) leaves the tank at
-- ~46 g, a launch is ~1.5 g, a hard chute opening ~15 g, a 10 rad/s tumble
-- with the pod 1.5 m out ~15 g.
local JOINT_KN = { crewed = 600, tank = 450, engine = 500, structural = 350, canvas = 150 }
-- Dynamic pressure (kPa) any part takes; deployed fragile kit takes far less.
local QMAX_KPA = 80
local AIR_RHO = 1.2           -- sea-level air density (kg/m³) at band density 1
-- An open canopy tears above this dynamic pressure (≈ 104 m/s in sea-level
-- air, ≈ 147 m/s where the air is half as thick) — KSP's "safe to deploy"
-- speed, as a pressure so it follows the air. Rated by pressure rather than by
-- load so a heavy craft isn't arbitrarily unable to use chutes at all; its
-- heavier snatch still loads every OTHER joint through the g-load above.
local CHUTE_SAFE_KPA = 6.5
local SPIN_MAX = 12.0         -- rad/s: past this the safety net brakes the tumble
local KICK_TOL = 6.0          -- m/s of unexplained one-tick speed gain tolerated
KICK_SUM = 4.0                -- m/s of unexplained gain tolerated over ~0.5 s (global: upvalue budget)
local JUMP_TOL = 3.0          -- m of unexplained one-tick hull movement reported
local STRESS_SAMPLE_MAX = 400 -- m/s²: the most one tick's Δv may say about a SUSTAINED load

local function integ_note(kind, msg)
  integ.fired[kind] = (integ.fired[kind] or 0) + 1
  if time - (integ.note_t[kind] or -10) > 1.0 then
    integ.note_t[kind] = time
    log(msg)
  end
end

-- Published: how often each safety-net clamp fired this flight, plus the stress
-- state (the probes and the HUD can read it).
function integrity()
  local out = {}
  for k, n in pairs(integ.fired) do out[k] = n end
  return out
end

-- IS THE CREW ON FOOT? Not `astronaut.visible`, which used to stand in for
-- it: planet_camera hides the body in first person and whenever a wall pushes
-- the view into the shoulders (so F refused to board from there), and an open
-- COMMAND SEAT keeps its rider in view (so a craft parked beside it offered
-- "F — board" to someone already sitting in another one). On foot = aboard no
-- craft, and not this very moment stepping out of ANOTHER one: the F that
-- stands you up from one craft must not seat you in the craft parked beside
-- it (`except_id` = the asking craft's node id; climbing back into the craft
-- you just left is fine). Global: no upvalue spent in fixedUpdate, and a
-- probe or the HUD can ask it too.
-- (a global: the file's main chunk is at Lua's 200-local ceiling)
CREWLIB = { ref = nil, t = -10.0 }
function crewOnFoot(except_id)
  if not astronaut or not astronaut.valid then astronaut = find("Astronaut") end
  if not astronaut then return false end
  -- held at a job (crew_task): not free to climb in, and no "F — board" prompt
  local cl = CREWLIB.ref
  if not (cl and cl.valid ~= false) and (time or 0) - CREWLIB.t > 2.0 then
    CREWLIB.t = time or 0
    cl = findScript("crew")
    CREWLIB.ref = cl
  end
  if cl and cl.valid ~= false and cl.held and cl.held() then return false end
  local now = time or 0.0
  for _, v in ipairs(findScripts("vessel_controller")) do
    if v.crewAboard then return false end
    if now - (v.leftAt or -100.0) < 0.3 and not (except_id and v.node and v.node.id == except_id) then
      return false
    end
  end
  return true
end

-- BOARD: the crew climbs in (F beside the craft, within board_range of its
-- spine). Into a pod they vanish; into an open COMMAND SEAT they stay in view,
-- seated (podSeat; scripts/command_seat.lua poses them). Global so a probe or a
-- future button can do what F does. Returns true if they boarded.
function boardNow(node, info)
  node = node or dock.node
  if destroyed or not (node and node.valid) then return false end
  info = info or assembly.info(node)
  if not astronaut or not astronaut.valid then astronaut = find("Astronaut") end
  if not (podCrewed and not crewAboard and astronaut and crewOnFoot(node.id)) then return false end
  -- Held at a job (a repair): F doesn't pull them off it; cancel does.
  local cl = findScript("crew")
  if cl and cl.held and cl.held() then return false end
  -- The crew position NEAREST them: the seat they walked up to, or the pod.
  local d, st = board_dist(node, astronaut, info)
  if d > params.board_range then return false end
  -- ...into a free slot of that part, else the nearest free one aboard (§3.5)
  local clb = crewLibNow()
  local bid = clb and clb.activeId and clb.activeId()
  if clb and bid then
    local u, k = freeSeat(st and st.uid or stationUid)
    if not u then
      local fx = findScript("sfx")
      if fx and fx.caption then fx.caption(string.format("%s is full", tostring((st and bp_by_uid[st.uid] and bp_by_uid[st.uid].label) or craftName))) end
      return false
    end
    seatMember(u, k, bid)
    setStation(u)
  elseif st then setStation(st) end
  -- Climbing in takes the controls from whatever you were flying.
  for _, ov in ipairs(findScripts("vessel_controller")) do
    if ov.releaseControl and ov.node and ov.node.id ~= node.id then ov.releaseControl() end
  end
  piloting = true
  crewAboard = true
  astronaut.visible = podSeat == true
  set_navball(true)
  -- Board in a stability hold — never inherit a velocity-pointing mode
  -- into a takeoff (a vertical climb's "retrograde" points at the core).
  sas_mode, sas_last = "stability", "stability"
  hud_t = -10.0 -- repaint the HUD immediately
  crewBoarded(node)
  return true
end

-- THE SEAT. The crew rides as a passenger: kinematic while seated, dynamic
-- again when they stand down. Idempotent and cheap — the piloting vessel calls
-- it every tick (it re-asserts the flag twice a second in case anything else
-- flipped it), every other vessel only acts if it was the one that seated them.
function seatCrew(node, on)
  if not astronaut or not astronaut.valid then astronaut = find("Astronaut") end
  local a = astronaut
  if not a then return end
  if on and physTune.seatKinematic == false then return end -- probe A/B only
  if on then
    if integ.seated and time - integ.seat_t < 0.5 then return end
  else
    if not integ.seated then return end
    -- The crew may be in another craft's seat now: it keeps them seated.
    for _, v in ipairs(findScripts("vessel_controller")) do
      if v.crewAboard and v.node and node and v.node.id ~= node.id then
        integ.seated = false
        return
      end
    end
  end
  local getc = a.getComponent or a.getcomponent
  local rb = getc and getc(a, "RigidBody")
  if rb then
    -- Written only when it differs (the read answers true/false or 1/0).
    local is = rb.kinematic == true or rb.kinematic == 1
    if is ~= on then rb.kinematic = on and 1 or 0 end
  end
  integ.seated, integ.seat_t = on, time
end

-- Is this point within a few ticks of any sphere-of-influence boundary? At an
-- SOI seam the engine steps the craft's velocity by the difference of the two
-- frames (a planet's whole orbital speed) with no force at all — and the node
-- position the dominant body is judged from lags a tick, so a one-tick spike
-- right there is a frame change, not a load and not a solver artifact.
local function near_soi_seam(x, y, z, spd, dt)
  local margin = math.max(50.0, spd * dt * 4.0)
  for _, b in ipairs(space.bodies() or {}) do
    if (b.soi or 0) > 0 then
      local d = math.sqrt((x - b.x) ^ 2 + (y - b.y) ^ 2 + (z - b.z) ^ 2)
      if math.abs(d - b.soi) < margin then return true end
    end
  end
  return false
end

-- THE CLAMPS. SPACE on the pad comes here, and so do probes (a headless run
-- cannot press keys). Releases only a fully assembled craft; returns true when
-- the clamps actually let go.
function releaseClamps()
  local node = dock.node
  if not node or not node.valid then return false end
  local info = assembly.info(node)
  if not info then return false end
  if info.anchored then
    if not assembly_ready(info) then
      log(string.format("clamps hold: %d / %d parts assembled", #info.parts, part_total))
      return false
    end
  elseif not (launch_mode and not released) then
    return false -- already flying
  end
  -- The crew must already be a passenger when the hull starts to move.
  if piloting then seatCrew(node, true) end
  released = true
  leftPad = true   -- off the clamps: a craft in the world (the fleet keeps it)
  integ.release_t, integ.prev, integ.af = time, nil, nil
  assembly.setAnchored(node, false)
  r2Rollout(node, info)
  local bx, by, bz = base_of(node, info)
  sfx3(SFX.clamp, bx, by, bz, 0.9, 1.0) -- the clamps let go with a clank
  caption("the launch clamps release")
  log("launch clamps released")
  return true
end

-- A part's collider box in the VESSEL frame: centre and axis-aligned half
-- extents of the turned box, from the live part's RigidBody (what the physics
-- compound is made of) or the blueprint's footprint when it can't be read.
local function part_box(node, uid)
  local b = integ.box[uid]
  if b then return b end
  local d = bp_by_uid[uid]
  if not d then return nil end
  local hx, hy, hz = d.rx or 0.5, (d.h or 1.0) * 0.5, d.rz or 0.5
  if hx <= 0 then hx = 0.5 end
  if hz <= 0 then hz = 0.5 end
  local c = child_of_uid(node, uid)
  local getc = c and (c.getComponent or c.getcomponent)
  local rb = getc and getc(c, "RigidBody")
  if rb and rb.half_y and rb.half_y > 0 then
    -- The engine builds the box as half_extents × the part node's scale
    -- (floptle-physics build_assemblies); the component reports the unscaled
    -- prefab numbers. Read the scale off the live part at first sight (before
    -- a chute's canopy grows it).
    hx = (rb.half_x or hx) * math.abs(c.scale_x or 1)
    hy = rb.half_y * math.abs(c.scale_y or 1)
    hz = (rb.half_z or hz) * math.abs(c.scale_z or 1)
  end
  local Xx, Xy, Xz = part_axis_x(d)
  local Yx, Yy, Yz = part_axis(d)
  local Zx, Zy, Zz = Xy * Yz - Xz * Yy, Xz * Yx - Xx * Yz, Xx * Yy - Xy * Yx
  b = { cx = d.x, cy = d.y, cz = d.z, m = math.max(0.01, d.mass or 0.5),
        ex = math.abs(Xx) * hx + math.abs(Yx) * hy + math.abs(Zx) * hz,
        ey = math.abs(Xy) * hx + math.abs(Yy) * hy + math.abs(Zy) * hz,
        ez = math.abs(Xz) * hx + math.abs(Yz) * hy + math.abs(Zz) * hz,
        hx = hx, hy = hy, hz = hz }
  integ.box[uid] = b
  return b
end

-- How far the hull reaches out along the vessel's +X (where the crew steps out),
-- from the part boxes; never less than the old fixed 1.6 m.
function hullReach()
  local node = dock.node
  local r = 1.6
  if not node or not node.valid then return r end
  for u in pairs(bp_by_uid) do
    local b = not integ.gone[u] and part_box(node, u)
    if b and b.cx + b.ex > r then r = b.cx + b.ex end
  end
  return r
end

-- Mass and centre (vessel frame) of a set of uids still aboard.
local function set_mass(node, set)
  local m, x, y, z = 0.0, 0.0, 0.0, 0.0
  local fuel_by = tankFuelMap()        -- (tankFuelT for every part, from one pass over the tanks)
  for u in pairs(set) do
    if not integ.gone[u] then
      local b = part_box(node, u)
      if b then
        local bm = b.m + (fuel_by[u] or 0.0)   -- a tank weighs what it still holds
        m = m + bm
        x, y, z = x + b.cx * bm, y + b.cy * bm, z + b.cz * bm
      end
    end
  end
  if m <= 0 then return 0, 0, 0, 0 end
  return m, x / m, y / m, z / m
end

-- How far (m) the departing set must move along vessel-frame unit `d` so that
-- none of its boxes overlaps a box that stays — plus a 3 cm air gap. Boxes that
-- merely touch count as overlapping (the solver treats a zero gap as contact).
local function clearance(node, set, dx, dy, dz)
  local need = 0.0
  local stay = {}
  local emax = 0.0
  for u in pairs(bp_by_uid) do
    if not set[u] and not integ.gone[u] then
      local b = part_box(node, u)
      if b then
        stay[#stay + 1] = b
        if b.ey > emax then emax = b.ey end
      end
    end
  end
  -- (sorted by height, so each departing box is tested only against the boxes
  -- that can reach it vertically — the same pairs, so the same answer: a
  -- thousand parts against a thousand was 9 ms of the breakup frame)
  table.sort(stay, function(p, q) return p.cy < q.cy end)
  local ns = #stay
  local adx, ady, adz = math.abs(dx), math.abs(dy), math.abs(dz)
  for u in pairs(set) do
    local a = not integ.gone[u] and part_box(node, u)
    if a then
      local reach = a.ey + emax + 0.01 + 1e-6
      local lo, hi = 1, ns + 1
      local want = a.cy - reach
      while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if stay[mid].cy < want then lo = mid + 1 else hi = mid end
      end
      local top = a.cy + reach
      for i = lo, ns do
        local b = stay[i]
        if b.cy > top then break end
        if math.abs(a.cx - b.cx) <= a.ex + b.ex + 0.01
          and math.abs(a.cy - b.cy) <= a.ey + b.ey + 0.01
          and math.abs(a.cz - b.cz) <= a.ez + b.ez + 0.01 then
          local ca = a.cx * dx + a.cy * dy + a.cz * dz
          local cb = b.cx * dx + b.cy * dy + b.cz * dz
          local ea = adx * a.ex + ady * a.ey + adz * a.ez
          local eb = adx * b.ex + ady * b.ey + adz * b.ez
          local s = (cb + eb) - (ca - ea)
          if s > need then need = s end
        end
      end
    end
  end
  -- Deeper than this and the piece was built buried in the hull; move it what
  -- is sane and let the solver take the rest over a few bounded steps.
  return math.min(need, 1.2) + 0.03
end

-- The way a set of parts leaves the hull — from the centre of what STAYS
-- toward the centre of what goes (vessel frame) — and how far along it the set
-- must move to clear every box that stays: { gap, x, y, z } in world terms.
-- Measure before the set is marked gone (gone parts don't count).
function clearAway(node, set)
  local _, kx, ky, kz = set_mass(node, set)
  local keep = {}
  for u in pairs(bp_by_uid) do if not set[u] then keep[u] = true end end
  local _, sx, sy, sz = set_mass(node, keep)
  local dx, dy, dz = kx - sx, ky - sy, kz - sz
  local dl = math.sqrt(dx * dx + dy * dy + dz * dz)
  if dl < 1e-4 then dx, dy, dz, dl = 0, -1, 0, 1 end
  dx, dy, dz = dx / dl, dy / dl, dz / dl
  local gap = clearance(node, set, dx, dy, dz)
  local rx, up, rz = basis(node)
  return { gap = gap,
           x = rx.x * dx + up.x * dy + rz.x * dz,
           y = rx.y * dx + up.y * dy + rz.y * dz,
           z = rx.z * dx + up.z * dy + rz.z * dz,
           lx = kx, ly = ky, lz = kz }
end

-- Let a piece that has just been split off go cleanly: out of any collider
-- overlap with the hull (`gap` metres along world unit (wx,wy,wz), from
-- `clearance`), and passing through the hull for `physTune.ignore` seconds so
-- the two faces that were bolted together can't knock each other apart. Any
-- push the caller then gives it (a decoupler's charge, a blast) is the only
-- energy in the separation. `also` lists other fresh pieces of the same event
-- (a breakup) that should pass through this one too.
function releasePiece(piece, hull, wx, wy, wz, gap, also)
  local pi = assembly.info(piece)
  if physTune.clear and gap and gap > 0 and pi and pi.origin then
    assembly.teleport(piece, vec3(pi.origin.x + wx * gap, pi.origin.y + wy * gap,
      pi.origin.z + wz * gap))
  end
  local secs = physTune.ignore or 0
  if secs > 0 and physics and physics.ignorePair then
    if hull and hull.valid ~= false then physics.ignorePair(piece, hull, secs) end
    for _, other in ipairs(also or {}) do
      if other.valid ~= false then physics.ignorePair(piece, other, secs) end
    end
  end
end

-- SHED a set of parts as ONE new body: the general form of "this much of the
-- craft just came off". The pod never leaves this way (a set holding it is
-- refused — losing the pod is break_part's job). Returns true if it split.
--   why      a few words for the log ("g-load", "dynamic pressure", …)
--   blast    true = it goes off as it leaves (explosion hooks + a light kick)
function shedSet(node, set, why, sev, blast, at_uid)
  if destroyed or not node or not node.valid then return false end
  if pod_uid and set[pod_uid] then return false end
  local nodes, n_set = {}, 0
  for u in pairs(set) do
    if not integ.gone[u] then
      n_set = n_set + 1
      local c = child_of_uid(node, u)
      if c and c.valid then nodes[#nodes + 1] = c end
    end
  end
  if #nodes == 0 then return false end
  local info = assembly.info(node)
  if not info or #info.parts <= #nodes then return false end -- never split off everything
  r2Before(node)
  -- Which way it leaves: from what stays toward what goes.
  local away = clearAway(node, set)
  local gap, wx, wy, wz = away.gap, away.x, away.y, away.z
  local kx, ky, kz = away.lx, away.ly, away.lz
  local rx, up, rz = basis(node)
  -- Bookkeeping before the split, so this tick's passes already see the new craft.
  -- Named after the part at the torn joint: the lowest-uid part whose parent
  -- stays behind (deterministic, unlike pairs() order).
  -- (`at_uid`: the joint's own part on the leaving side, when the caller
  -- knows it — a joint under the pod of a stack built up from its engine
  -- leaves with the part BELOW the cut, whose parent is nobody.)
  local label, lu = "part", nil
  for u in pairs(set) do
    local d = bp_by_uid[u]
    if d and not set[d.parent or 0] and (not lu or u < lu) then
      lu, label = u, d.label or d.id or "part"
    end
  end
  if at_uid and set[at_uid] and bp_by_uid[at_uid] then
    label = bp_by_uid[at_uid].label or bp_by_uid[at_uid].id or "part"
  end
  drop_set(set)
  local keep_ev = {}
  for _, ev in ipairs(events) do
    if ev.kind == "axial" or ev.kind == "fairing" then
      if not set[ev.uid] then keep_ev[#keep_ev + 1] = ev end
    elseif ev.kind == "chute" then
      local us = {}
      for _, u in ipairs(ev.uids) do if not set[u] then us[#us + 1] = u end end
      if #us > 0 then ev.uids = us; keep_ev[#keep_ev + 1] = ev end
    else
      local bs = {}
      for _, g in ipairs(ev.branches) do
        if not set[g.uid] then bs[#bs + 1] = g end
      end
      if #bs > 0 then ev.branches = bs; keep_ev[#keep_ev + 1] = ev end
    end
  end
  events = keep_ev
  local live_chutes = {}
  for _, c in ipairs(chutes) do
    if not set[c.uid] then live_chutes[#live_chutes + 1] = c end
  end
  if #live_chutes ~= #chutes then chutes = live_chutes end
  for _, dev in pairs(DEVICES) do
    local keep_p = {}
    for _, u in ipairs(dev.parts) do
      if not set[u] then keep_p[#keep_p + 1] = u else dev.nodes[u] = nil end
    end
    dev.parts = keep_p
  end
  quench(nodes)
  log(string.format("STRESS: %s tore away (%s, %.0f%% of its limit) — %d part(s) leave "
    .. "as their own body, %.2f m clear, velocity kept", label, why, (sev or 1) * 100,
    #nodes, gap))
  local bx, by, bz = base_of(node, info)
  local px = bx + rx.x * kx + up.x * ky + rz.x * kz
  local py = by + rx.y * kx + up.y * ky + rz.y * kz
  local pz = bz + rx.z * kx + up.z * ky + rz.z * kz
  sfx3(blast and SFX.boom or SFX.stage, px, py, pz, blast and 1.0 or 0.8, 0.9)
  caption(blast and "a part explodes and tears away" or "a part tears away")
  add_shake(blast and 0.8 or 0.35)
  if blast then
    local v = info.vel
    local fx = fxd()
    if fx then
      fx.explode(px, py, pz, v.x, v.y, v.z, true)
      fx.explode(px + wx * 0.6, py + wy * 0.6, pz + wz * 0.6, v.x, v.y, v.z, false)
    else
      spawnEffect("Explosion", px, py, pz)
      spawnEffect("Explosion", px + wx * 0.6, py + wy * 0.6, pz + wz * 0.6)
    end
  else
    -- A structural tear: the joint snapping — a puff, sparks and loose bolts.
    local fx = fxd()
    if fx then fx.separate(px, py, pz, info.vel.x, info.vel.y, info.vel.z) end
  end
  assembly.split(node, nodes, function(junk)
    -- Clear of the hull, at the velocity it had: no impulse from overlap.
    releasePiece(junk, node, wx, wy, wz, gap)
    local ji = assembly.info(junk)
    if ji and ji.origin then
      if blast and ji.com then
        -- An explosion is real energy: a light, mass-scaled push off the hull,
        -- through the centre of mass where the clear-out has put it (the
        -- teleport is applied before this impulse; pushing at the old spot
        -- would add a spin of gap × push for nothing).
        local m = math.max(0.05, ji.mass or 0.2)
        local g = physTune.clear and gap or 0
        assembly.impulseAt(junk, vec3(wx * 2.5 * m, wy * 2.5 * m, wz * 2.5 * m),
          vec3(ji.com.x + wx * g, ji.com.y + wy * g, ji.com.z + wz * g))
      end
    end
  end)
  return true
end

-- A JOINT fails: the part `uid` comes off its parent, and with it everything
-- on its side of that joint (away from the pod).
function shedJoint(node, uid, why, sev, blast)
  if integ.gone[uid] then return false end
  local set = axial_departing(uid)
  local d = bp_by_uid[uid]
  -- the part on the leaving side of the cut: this one, or (the set turned
  -- round because the pod is on this side) its parent
  return shedSet(node, set, why, sev, blast, set[uid] and uid or (d and d.parent))
end

-- THE STRESS TREE. Every joint is a CUT through the attachment tree: it
-- splits the craft in two, the side that keeps the pod and the side that
-- would leave (the same tree cut a decoupler makes, `axial_departing`). Hang
-- the tree from the pod instead of from whatever part the builder started
-- with, and the leaving side of EVERY joint is one subtree of it. So one pass
-- over the parts, children before parents, sums every joint's mass, first
-- moment and external force at once, O(parts) a tick, where a set per joint
-- was O(parts²) (a 1,000-part spine: ~500,000 set entries).
--   ord   live part uids, breadth-first from the root (a parent before its children)
--   pi    tree index → its parent's index (0 at a root)
--   ri    tree index → the index of the root of its piece
--   idx   uid → tree index
-- Live parts the pod can't reach (a docked craft's own tree, a pod-less
-- probe) hang from their own tree root, where their departing side is the
-- plain subtree, as `axial_departing` has it.
function stressTreeBuild(by_uid, kids, root_uid, gone)
  local ord, pi, ri, idx = {}, {}, {}, {}
  local function live(u) return u ~= nil and u ~= 0 and by_uid[u] ~= nil and not gone[u] end
  local function hang(r)
    ord[#ord + 1] = r
    local ir = #ord
    idx[r], pi[ir], ri[ir] = ir, 0, ir
    local q = ir
    while q <= #ord do
      local u = ord[q]
      local p = by_uid[u].parent
      if live(p) and not idx[p] then
        ord[#ord + 1] = p; idx[p] = #ord; pi[#ord], ri[#ord] = q, ir
      end
      for _, k in ipairs(kids[u] or {}) do
        if live(k) and not idx[k] then
          ord[#ord + 1] = k; idx[k] = #ord; pi[#ord], ri[#ord] = q, ir
        end
      end
      q = q + 1
    end
  end
  if live(root_uid) then hang(root_uid) end
  local rest = {}
  for u in pairs(by_uid) do if live(u) and not idx[u] then rest[#rest + 1] = u end end
  table.sort(rest)
  for _, u in ipairs(rest) do   -- tree roots first (a part with no live parent) …
    if not idx[u] and not live(by_uid[u].parent) then hang(u) end
  end
  for _, u in ipairs(rest) do   -- … then anything left (a loop in bad data)
    if not idx[u] then hang(u) end
  end
  return { n = #ord, ord = ord, pi = pi, ri = ri, idx = idx }
end

-- The tree index whose subtree is joint (u → its parent p)'s leaving side,
-- or nil when the two are not linked in the tree.
function stressJointSide(T, u, p)
  local iu, ip = T.idx[u], T.idx[p]
  if not iu or not ip then return nil end
  if T.pi[iu] == ip then return iu end
  if T.pi[ip] == iu then return ip end
  return nil
end

-- THE LOAD THROUGH EVERY JOINT (pure: the probes and tests call it as is).
-- For the cut at joint k, with A its leaving side (the subtree at tree index
-- s), the force the rest of the craft puts through the joint into A is what A
-- needs to move with the craft, less what already pushes on A from outside:
--
--     L = Σ_A m_i a_i − F_A − R_A
--     a_i = a + α×r_i + ω×(ω×r_i)        (rigid body; r_i from the centre of mass)
--     Σ_A m_i a_i = m_A a + α×S_A + ω×(ω×S_A),   S_A = Σ_A m_i r_i
--
-- a is the craft's PROPER acceleration (gravity taken out, so gravity is in
-- no force here either: weight is "the ground pushing up", exactly as an
-- accelerometer reads it). F_A is the external force on A this model knows
-- part by part: engine thrust, the air on each body and surface, the
-- canopies, the water. R is what is left over — the whole craft's
-- Σ m a − F — which is the force nobody booked: the ground, the pad, a
-- contact, a bump, the solver. R_A is A's share of it:
--   * in contact (grounded, on wheels, touching something) it is the
--     support, and it acts where the craft touches: shared by the contact
--     weights c (the parts that touch, or the craft's lowest parts against
--     the push when nothing says which touch), R_A = R · c_A / c_total;
--   * in free flight it is the small remainder of what this model can't
--     place (a CoM force: RCS, the coasting drag; the filter's lag), spread
--     by mass, R_A = R · m_A / m_total, so it loads no joint.
-- Because R closes the books (Σ over the whole craft of m a − F − R = 0),
-- the load computed from the other side, B, is exactly −L: Newton's third
-- law holds by construction.
--   P   per tree index: m, x,y,z (world, from the centre of mass), fx,fy,fz (world, kN)
--   cw  per tree index contact weight, or nil (free flight)
--   kin { ax,ay,az, alx,aly,alz, wx,wy,wz }
--   out filled: out.x[k], out.y[k], out.z[k] = L for joint list[k] (kN)
function stressSolve(T, list, P, cw, kin, out)
  local n, pi, ri = T.n, T.pi, T.ri
  local M, SX, SY, SZ = T.M or {}, T.SX or {}, T.SY or {}, T.SZ or {}
  local FX, FY, FZ, C = T.FX or {}, T.FY or {}, T.FZ or {}, T.C or {}
  T.M, T.SX, T.SY, T.SZ, T.FX, T.FY, T.FZ, T.C = M, SX, SY, SZ, FX, FY, FZ, C
  local pm, px, py, pz, pfx, pfy, pfz = P.m, P.x, P.y, P.z, P.fx, P.fy, P.fz
  for i = 1, n do
    local m = pm[i]
    M[i], SX[i], SY[i], SZ[i] = m, m * px[i], m * py[i], m * pz[i]
    FX[i], FY[i], FZ[i] = pfx[i], pfy[i], pfz[i]
    C[i] = cw and cw[i] or 0
  end
  -- children before parents: breadth-first order, walked backwards
  for i = n, 2, -1 do
    local p = pi[i]
    if p > 0 then
      M[p], SX[p], SY[p], SZ[p] = M[p] + M[i], SX[p] + SX[i], SY[p] + SY[i], SZ[p] + SZ[i]
      FX[p], FY[p], FZ[p], C[p] = FX[p] + FX[i], FY[p] + FY[i], FZ[p] + FZ[i], C[p] + C[i]
    end
  end
  local ax, ay, az, alx, aly, alz, wx, wy, wz =
    kin.ax, kin.ay, kin.az, kin.alx, kin.aly, kin.alz, kin.wx, kin.wy, kin.wz
  local ox, oy, oz = out.x or {}, out.y or {}, out.z or {}
  out.x, out.y, out.z = ox, oy, oz
  -- each piece's residual R, worked out the first time one of its joints asks
  local rx, ry, rz, rdone = T.RX or {}, T.RY or {}, T.RZ or {}, {}
  T.RX, T.RY, T.RZ = rx, ry, rz
  for k = 1, #list do
    local s = list[k].s
    local m, sx, sy, sz = M[s], SX[s], SY[s], SZ[s]
    local wsx, wsy, wsz = wy * sz - wz * sy, wz * sx - wx * sz, wx * sy - wy * sx
    local lx = m * ax + (aly * sz - alz * sy) + (wy * wsz - wz * wsy) - FX[s]
    local ly = m * ay + (alz * sx - alx * sz) + (wz * wsx - wx * wsz) - FY[s]
    local lz = m * az + (alx * sy - aly * sx) + (wx * wsy - wy * wsx) - FZ[s]
    local r = ri[s]
    if not rdone[r] then
      rdone[r] = true
      local mr, qx, qy, qz = M[r], SX[r], SY[r], SZ[r]
      local vx, vy, vz = wy * qz - wz * qy, wz * qx - wx * qz, wx * qy - wy * qx
      rx[r] = mr * ax + (aly * qz - alz * qy) + (wy * vz - wz * vy) - FX[r]
      ry[r] = mr * ay + (alz * qx - alx * qz) + (wz * vx - wx * vz) - FY[r]
      rz[r] = mr * az + (alx * qy - aly * qx) + (wx * vy - wy * vx) - FZ[r]
    end
    local share = 0
    if C[r] > 0 then share = C[s] / C[r] elseif M[r] > 0 then share = m / M[r] end
    ox[k], oy[k], oz[k] = lx - share * rx[r], ly - share * ry[r], lz - share * rz[r]
  end
  return out
end

-- EXTERNAL FORCES, part by part (world, kN): every force this script puts on
-- the hull at a known part is booked here as it is applied — each engine's
-- thrust, the air on each body and surface (aeroStressForces), the canopies'
-- pull, the water on each part. The stress pass reads them the tick after (the
-- velocity change it measures is the one those forces made) and smooths them
-- with the same filter as the acceleration, so the two always agree.
-- Anything not booked (the ground, a bump, RCS, the coasting drag, the
-- solver) is the residual R above.
STRESS_F = { px = {}, py = {}, pz = {}, sx = {}, sy = {}, sz = {},
             lx = 0, ly = 0, lz = 0, lsx = 0, lsy = 0, lsz = 0 }
function stressForce(uid, fx, fy, fz)
  if uid == nil then return end
  local F = STRESS_F
  local px = F.px
  if px[uid] then
    px[uid], F.py[uid], F.pz[uid] = px[uid] + fx, F.py[uid] + fy, F.pz[uid] + fz
  else
    px[uid], F.py[uid], F.pz[uid] = fx, fy, fz
  end
end
-- A force through the centre of mass in the sim that is really the air's
-- (the coasting drag): booked whole, placed on the leading parts by
-- stressTick.
function stressLead(fx, fy, fz)
  local F = STRESS_F
  F.lx, F.ly, F.lz = F.lx + fx, F.ly + fy, F.lz + fz
end
-- Fold this tick's booked forces into the smoothed ones (k as the
-- acceleration's filter; 1 = restart) and clear the book.
function stressForcesSmooth(k)
  local F = STRESS_F
  F.lsx, F.lsy, F.lsz = F.lsx + (F.lx - F.lsx) * k, F.lsy + (F.ly - F.lsy) * k, F.lsz + (F.lz - F.lsz) * k
  F.lx, F.ly, F.lz = 0, 0, 0
  local px, py, pz, sx, sy, sz = F.px, F.py, F.pz, F.sx, F.sy, F.sz
  for u, x in pairs(sx) do
    local nx = px[u]
    local a, b, c
    if nx then
      a, b, c = x + (nx - x) * k, sy[u] + (py[u] - sy[u]) * k, sz[u] + (pz[u] - sz[u]) * k
    else
      a, b, c = x * (1 - k), sy[u] * (1 - k), sz[u] * (1 - k)
    end
    if not nx and a * a + b * b + c * c < 1e-10 then
      sx[u], sy[u], sz[u] = nil, nil, nil
    else
      sx[u], sy[u], sz[u] = a, b, c
    end
  end
  for u, x in pairs(px) do
    if sx[u] == nil then sx[u], sy[u], sz[u] = x * k, py[u] * k, pz[u] * k end
    px[u], py[u], pz[u] = nil, nil, nil
  end
end
-- The same ceiling the acceleration sample has (STRESS_SAMPLE_MAX, ~40 g):
-- this model is for SUSTAINED loads. A canopy opened fast pulls up to half
-- the craft's speed out of it in one tick (chute drag's cap): booked raw,
-- that one-tick snatch is hundreds of g. The tick's booked forces are scaled
-- together until their sum is at most `cap` (kN).
function stressForcesCap(cap)
  local F = STRESS_F
  local px, py, pz = F.px, F.py, F.pz
  local sx, sy, sz = F.lx, F.ly, F.lz
  for u, x in pairs(px) do sx, sy, sz = sx + x, sy + py[u], sz + pz[u] end
  local s = math.sqrt(sx * sx + sy * sy + sz * sz)
  if s <= cap then return end
  local f = cap / s
  for u, x in pairs(px) do px[u], py[u], pz[u] = x * f, py[u] * f, pz[u] * f end
  F.lx, F.ly, F.lz = F.lx * f, F.ly * f, F.lz * f
end
-- Forget the book (and, with `all`, the smoothed forces too).
function stressForcesDrop(all)
  local F = STRESS_F
  for u in pairs(F.px) do F.px[u], F.py[u], F.pz[u] = nil, nil, nil end
  F.lx, F.ly, F.lz = 0, 0, 0
  if all then F.sx, F.sy, F.sz, F.lsx, F.lsy, F.lsz = {}, {}, {}, 0, 0, 0 end
end

-- The air's force on each body and surface of the aero model, booked part by
-- part: the very sums aero.step made, scaled as the total was (`sc`: the
-- half-the-airspeed cap and AERO.scale), turned into the world. An aero.lua
-- that keeps each one's force from its step (M.kept: b.fx …) is read as is;
-- otherwise they are worked out again (the same bodyForce / surfaceForce at
-- the same air, spin and deflection: ~0.5 ms a tick at 1,000 parts).
function aeroStressForces(A, M, env, sc, rx, up, rz)
  local rxx, rxy, rxz, upx, upy, upz, rzx, rzy, rzz = rx.x, rx.y, rx.z, up.x, up.y, up.z, rz.x, rz.y, rz.z
  if M.kept then
    for _, list in ipairs({ M.bodies, M.surfs }) do
      for _, b in ipairs(list) do
        local fx, fy, fz = b.fx or 0, b.fy or 0, b.fz or 0
        if fx ~= 0 or fy ~= 0 or fz ~= 0 then
          stressForce(b.uid, (rxx * fx + upx * fy + rzx * fz) * sc, (rxy * fx + upy * fy + rzy * fz) * sc,
            (rxz * fx + upz * fy + rzz * fz) * sc)
        end
      end
    end
    return
  end
  if not (A.bodyForce and A.surfaceForce and A.machDrag) then return end
  local vx, vy, vz = env.vx or 0, env.vy or 0, env.vz or 0
  local wx, wy, wz = env.wx or 0, env.wy or 0, env.wz or 0
  local cx, cy, cz = env.cx or 0, env.cy or 0, env.cz or 0
  local rho = env.rho or 0
  local Mach = math.sqrt(vx * vx + vy * vy + vz * vz) / math.max(env.a or 340, 1)
  local mk = A.machDrag(Mach)
  local bodyForce, surfaceForce = A.bodyForce, A.surfaceForce
  for _, b in ipairs(M.bodies) do
    local qx, qy, qz = b.x - cx, b.y - cy, b.z - cz
    local fx, fy, fz = bodyForce(b, vx + wy * qz - wz * qy, vy + wz * qx - wx * qz, vz + wx * qy - wy * qx, rho, mk)
    if fx ~= 0 or fy ~= 0 or fz ~= 0 then
      stressForce(b.uid, (rxx * fx + upx * fy + rzx * fz) * sc, (rxy * fx + upy * fy + rzy * fz) * sc,
        (rxz * fx + upz * fy + rzz * fz) * sc)
    end
  end
  for _, s in ipairs(M.surfs) do
    local qx, qy, qz = s.x - cx, s.y - cy, s.z - cz
    local fx, fy, fz = surfaceForce(s, vx + wy * qz - wz * qy, vy + wz * qx - wx * qz, vz + wx * qy - wy * qx,
      rho, Mach, (s.defl or 0) * (s.tau or 1))
    if fx ~= 0 or fy ~= 0 or fz ~= 0 then
      stressForce(s.uid, (rxx * fx + upx * fy + rzx * fz) * sc, (rxy * fx + upy * fy + rzy * fz) * sc,
        (rxz * fx + upz * fy + rzz * fz) * sc)
    end
  end
end

-- The joints to load-check and the tree they hang in, rebuilt whenever the
-- craft's part set changes: one per part whose parent is still aboard, with
-- `s`, the tree index of its leaving side. (That includes the pod's own joint
-- when the builder's tree starts elsewhere — a stack built up from its
-- engine: the joint under the pod is as real as any, and what leaves when it
-- goes is everything but the pod's side. Before, it was never checked, so
-- the loads depended on which part the craft was started from.) The leaving
-- SET itself is only made when a joint fails (shedJoint).
local function joints(node)
  local key = integ.joints
  if key and key.gen == integ.gen and key.tree == axial_set_cache then return key.list, key.T end
  local gone = integ.gone
  local T = stressTreeBuild(bp_by_uid, bp_kids, pod_uid, gone)
  local list = {}
  for u, d in pairs(bp_by_uid) do
    local p = d.parent or 0
    if p ~= 0 and not gone[u] then
      local s = stressJointSide(T, u, p)
      if s then list[#list + 1] = { uid = u, d = d, s = s } end
    end
  end
  table.sort(list, function(a, b) return a.uid < b.uid end) -- deterministic order
  integ.joints = { gen = integ.gen, tree = axial_set_cache, list = list, T = T }
  return list, T
end

local function joint_strength(d, hp)
  local s = (d.strength or 0) > 0 and d.strength
    or ((d.legs or 0) == 1 and 300)
    or ((d.decouple or 0) == 1 and 400)
    or JOINT_KN[d.kind or "structural"] or 350
  -- A wounded part is a weaker anchor: damage and stress compound.
  return s * (0.4 + 0.6 * math.max(0, math.min(1, hp or 1)))
end

local function part_qmax(d)
  -- inside a fairing the air never reaches it
  if (d.faired or 0) ~= 0 and r2Faired(d) then return 1e9 end
  local q = (d.maxq or 0) > 0 and d.maxq or QMAX_KPA
  -- An extended panel, dish or whip is a sail: it tears off at low pressure.
  local m = elib() and elib().modOf(d, "deploy")
  if m and m.anim ~= "legs" and (panim[d.uid] or 0) > 0.3 then
    q = math.min(q, m.anim == "solar" and 4 or 6)
  elseif not m and (d.solar or 0) == 1 and DEVICES.solar.anim > 0.3 then q = math.min(q, 4)
  elseif not m and (d.comms or 0) == 1 and DEVICES.comms.anim > 0.3 then q = math.min(q, 6) end
  return q
end

-- THE WORLD'S SCALE (system_generator SCALES, frozen per save). Speeds and
-- heights on a bigger world are bigger in proportion: orbital speed goes as
-- sqrt(g·r), so the reentry glow, the heating onset, the aero gate and the HUD
-- tapes all ride `speed` (1 on the original worlds, 1.4 on scale 2) and
-- `alt`. Globals on purpose — fixedUpdate sits at Lua's upvalue ceiling.
function worldScaleK()
  local g = vc_scale_gen
  if not (g and g.valid) then
    g = findScript and findScript("system_generator") or nil
    vc_scale_gen = g
  end
  local sc = g and g.scale
  return (sc and sc.speed) or 1.0, (sc and sc.alt) or 1.0
end

-- THE AIR BAND: the share of the ground's air (0 … 1) at `alt` metres over
-- body `db`, which the chutes, the heating, the coasting drag and the joint
-- loads all read. Scale 1–3 worlds keep the band they were tuned on: linear
-- to 35 % of the radius. A deep-air world (scale 4+: its world record carries
-- `atmoScaleH`, system_generator SCALES[4]) has air up to its published
-- top, so the band is the aero model's own curve there (aero.lua airShare:
-- e^(−h/Hs) tapered to nothing at the top) — a chute opens, and a re-entry
-- heats, in the same air the wings fly in. Global on purpose (the upvalue
-- ceiling); the world record is cached per body for a few seconds.
AIRBAND = { name = nil, w = nil, t = -100 }
function airBandAt(db, alt)
  if not (db and db.radius) then return 0.0 end
  if time - AIRBAND.t > 3 or AIRBAND.name ~= db.name or time < AIRBAND.t then
    AIRBAND.name, AIRBAND.t = db.name, time
    AIRBAND.w = db.name and save.get("world." .. db.name) or nil
  end
  local w = AIRBAND.w
  if w and (w.atmoScaleH or 0) > 0 and (w.atmoHeight or 0) > 0 then
    if (w.atmo or 0) <= 0.005 then return 0.0 end
    if alt <= 0 then return 1.0 end
    local H, Hs = w.atmoHeight, w.atmoScaleH
    if alt >= H then return 0.0 end
    local e0 = math.exp(-H / Hs)
    return (math.exp(-alt / Hs) - e0) / (1 - e0)
  end
  local band = db.radius * 0.35
  if alt <= 0 then return 1.0 end
  if alt >= band then return 0.0 end
  return 1.0 - alt / band
end

-- Air density factor (0 … 1, the same band model as drag and heating) and the
-- dominant body, at the craft.
local function air_at(node)
  local dom = space.dominant(node.x, node.y, node.z)
  local db = dom and space.body(dom)
  if not db or not db.radius then return 0.0, db end
  local dx, dy, dz = node.x - db.x, node.y - db.y, node.z - db.z
  local alt = math.sqrt(dx * dx + dy * dy + dz * dz) - db.radius
  return airBandAt(db, alt), db
end

-- Each tank part's propellant (t) by uid, as tankFuelT reads it (the first
-- tank record with that uid), from one pass over the tanks.
function tankFuelMap()
  local out = {}
  for _, t in ipairs(tanks) do
    if t.uid ~= nil and out[t.uid] == nil then out[t.uid] = (t.left or 0) * (t.ft or 0) end
  end
  return out
end

-- Each joint's leaving side's WET mass now (uid → t): the parts' boxes plus
-- what their tanks hold, summed up the stress tree. (What the stress pass
-- loads each joint with; a probe or test can hold it against the set.)
function stressSideMass(node)
  local list, T = joints(node)
  local fuel_by = tankFuelMap()
  local M = {}
  for i = 1, T.n do
    local u = T.ord[i]
    local b = part_box(node, u)
    M[i] = (b and b.m or 0) + (fuel_by[u] or 0)
  end
  for i = T.n, 2, -1 do
    local p = T.pi[i]
    if p > 0 then M[p] = M[p] + M[i] end
  end
  local out = {}
  for _, j in ipairs(list) do out[j.uid] = M[j.s] end
  return out
end

-- WHERE THE UNBOOKED FORCE ACTS (stressTick's contact weights, by tree
-- index into cw; returns their sum). When the craft is touching something:
--   * the parts the engine says touched last tick (assembly.impacts, booked
--     by damage_tick into integ.contact: each by its impulse, plus a floor
--     so a part resting with no impulse still takes a share);
--   * the mounts of the wheels whose tyres are on the ground;
--   * a claw that has hold of something (assembly.grip: the weld is a force
--     no contact reports).
-- Failing those (the settle window after the clamps let go, when the damage
-- model is not reading contacts yet), an ESTIMATE: the parts that lead into
-- the push (dx,dy,dz, the unbooked force's direction: the ground pushes up,
-- so the craft's lowest parts — stressLeading).
function stressContact(node, T, P, cw, dx, dy, dz, rx, up, rz)
  local n, idx = T.n, T.idx
  for i = 1, n do cw[i] = 0 end
  local got = 0
  local ct = integ.contact
  if ct and ct.t == time then
    for u, w in pairs(ct.w) do
      local i = idx[u]
      if i then cw[i] = cw[i] + w; got = got + w end
    end
  end
  if R2.onWheels then
    for _, w in ipairs(R2.wheels) do
      local t = w.tyre
      if t and t.valid and t.grounded then
        local i = idx[w.uid]
        if i then cw[i] = cw[i] + 1; got = got + 1 end
      end
    end
  end
  if R2.claws then
    for _, c in ipairs(R2.claws) do
      local i = c.gripped and idx[c.uid]
      if i then cw[i] = cw[i] + 1; got = got + 1 end
    end
  end
  if got > 0 then return got end
  return stressLeading(node, T, P, cw, dx, dy, dz, rx, up, rz)
end

-- The parts that LEAD into a push along (dx,dy,dz): weight 1 in cw for every
-- part whose box reaches within 0.3 m of the craft's extreme point against
-- it (the ground pushes up: the lowest parts; the air pushes back: the parts
-- in front). Returns how many. (`boxOf` stands in for part_box in a test.)
function stressLeading(node, T, P, cw, dx, dy, dz, rx, up, rz, boxOf)
  local n, got = T.n, 0
  boxOf = boxOf or part_box
  for i = 1, n do cw[i] = 0 end
  local dl = math.sqrt(dx * dx + dy * dy + dz * dz)
  if dl < 1e-9 then return 0 end
  dx, dy, dz = dx / dl, dy / dl, dz / dl
  -- the push in the vessel frame, for each box's reach along it
  local vx = math.abs(dx * rx.x + dy * rx.y + dz * rx.z)
  local vy = math.abs(dx * up.x + dy * up.y + dz * up.z)
  local vz = math.abs(dx * rz.x + dy * rz.y + dz * rz.z)
  local low, lo = T.LOW or {}, math.huge
  T.LOW = low
  for i = 1, n do
    local b = boxOf(node, T.ord[i])
    local reach = b and (vx * b.ex + vy * b.ey + vz * b.ez) or 0
    local h = P.x[i] * dx + P.y[i] * dy + P.z[i] * dz - reach
    low[i] = h
    if h < lo then lo = h end
  end
  for i = 1, n do
    if low[i] <= lo + 0.3 then cw[i] = 1; got = got + 1 end
  end
  return got
end

-- Published: the last stress pass, joint by joint — { uid, kn, pct, m } for
-- every joint (kN through it, % of its strength, its leaving side's mass),
-- worst first; whether the craft was in contact; and the stress tree (its
-- per-part inputs in T.P, the kinematics in T.kin). For probes and the
-- tests; built only when asked.
function stressReport()
  local L = integ.sload
  if not L then return {} end
  local rows = {}
  for k, j in ipairs(L.list) do
    local kn = L.kn[k]
    if kn then
      rows[#rows + 1] = { uid = j.uid, id = j.d.id, kn = kn, pct = 100 * kn / joint_strength(j.d, part_hp[j.uid]),
                          m = L.T.M and L.T.M[j.s] or 0 }
    end
  end
  table.sort(rows, function(a, b) return a.pct > b.pct end)
  return rows, L.contact, L.T
end

-- part_qmax(j.d) with the part's deploy module looked up once per joint
-- (a part's modules are fixed by its blueprint record).
function jointQmax(j)
  local d = j.d
  if (d.faired or 0) ~= 0 and r2Faired(d) then return 1e9 end
  local q = (d.maxq or 0) > 0 and d.maxq or QMAX_KPA
  local m = j.qmod
  if m == nil then
    local E = elib()
    if not E then return part_qmax(d) end
    m = E.modOf(d, "deploy") or false
    j.qmod = m
  end
  if m and m.anim ~= "legs" and (panim[d.uid] or 0) > 0.3 then
    q = math.min(q, m.anim == "solar" and 4 or 6)
  elseif not m and (d.solar or 0) == 1 and DEVICES.solar.anim > 0.3 then q = math.min(q, 4)
  elseif not m and (d.comms or 0) == 1 and DEVICES.comms.anim > 0.3 then q = math.min(q, 6) end
  return q
end

-- THE FIRST STRESS PASS, made ahead. The first tick after the clamps let go
-- read every part's collider box (an engine read per part) and built the
-- stress tree at once. While the craft is held (on the pad, in the clamps)
-- nothing it is made of changes, so the same caches are filled then, a couple
-- of milliseconds a tick: the release finds them made. Only once every part
-- has spawned (a part not there yet would be sized from the blueprint, and
-- kept so).
STRESS_WARM_MS = 2.0
function stressWarm(node, info)
  if destroyed or not node or not node.valid or not info or #(info.parts or {}) < part_total then return end
  if integ.warm_done == integ.gen and integ.joints and integ.joints.gen == integ.gen
    and integ.joints.tree == axial_set_cache then return end
  local clock = app and app.wallClock
  if not clock then return end
  local t0 = clock()
  local wm = integ.warm
  if not wm or wm.gen ~= integ.gen or wm.tree ~= axial_set_cache then
    local all = {}
    for u in pairs(bp_by_uid) do if not integ.gone[u] then all[#all + 1] = u end end
    table.sort(all)
    wm = { gen = integ.gen, tree = axial_set_cache, k = 0, all = all, b = 0 }
    integ.warm = wm
  end
  -- every part's box (finding a part's node indexes the craft's children once
  -- a tick: many boxes a tick, not one)
  while wm.b < #wm.all do
    wm.b = wm.b + 1
    part_box(node, wm.all[wm.b])
    if wm.b % 16 == 0 and (clock() - t0) * 1000 > STRESS_WARM_MS then return end
  end
  local list = joints(node)
  while wm.k < #list do
    wm.k = wm.k + 1
    local j = list[wm.k]
    if not integ.gone[j.uid] then jointQmax(j) end
    if wm.k % 64 == 0 and (clock() - t0) * 1000 > STRESS_WARM_MS then return end
  end
  integ.warm_done = integ.gen
end

-- STRESS: load every joint, fail the ones past their limit. Runs piloted or not
-- (a derelict hit hard breaks the same), never while clamped or in the settle
-- window after release. The load through each joint is stressSolve's (above):
-- what its leaving side needs to move with the craft, less the external
-- forces already on that side.
function stressTick(node, info, dt)
  if destroyed or info.anchored or (launch_mode and not released) or dt <= 0 then
    integ.af, integ.wprev, integ.vprev = nil, nil, nil
    stressForcesDrop(true)
    if not destroyed and (info.anchored or (launch_mode and not released)) then stressWarm(node, info) end
    return
  end
  local v, w = info.vel, info.angVel
  -- A spin past the safety net's ceiling is being braked this very tick (see
  -- safetyTick); load the joints with the spin the craft is allowed to have,
  -- not with a solver artifact's 300 rad/s.
  local wl = math.sqrt(w.x * w.x + w.y * w.y + w.z * w.z)
  if wl > SPIN_MAX then
    local f = SPIN_MAX / wl
    w = { x = w.x * f, y = w.y * f, z = w.z * f }
  end
  local dom = space.dominant(node.x, node.y, node.z)
  -- Proper acceleration = dv/dt − gravity. A frame change (SOI seam) steps the
  -- velocity without any force: restart the filter instead of reading a spike.
  local vp = integ.vprev
  integ.vprev = { x = v.x, y = v.y, z = v.z, dom = dom }
  if not vp or vp.dom ~= dom or space.warp() > 1.001 then
    integ.af, integ.wprev = nil, nil
    stressForcesDrop(true)
    return
  end
  local gx, gy, gz = 0, 0, 0
  if space.gravity then
    local o = info.com or info.origin
    gx, gy, gz = space.gravity(o.x, o.y, o.z)
    gx, gy, gz = gx or 0, gy or 0, gz or 0
  end
  local ax = (v.x - vp.x) / dt - gx
  local ay = (v.y - vp.y) / dt - gy
  local az = (v.z - vp.z) / dt - gz
  -- One tick's sample is capped at ~40 g: a bigger instantaneous Δv is a
  -- contact (the impact model above judges those, part by part) or a solver
  -- artifact (the safety net's business) — this model is for SUSTAINED loads:
  -- thrust, drag, a canopy, a tumble, a grinding slide.
  local am = math.sqrt(ax * ax + ay * ay + az * az)
  if am > STRESS_SAMPLE_MAX and near_soi_seam(node.x, node.y, node.z,
      math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z), dt) then
    stressForcesDrop(false)
    return -- a frame change, not a load (see near_soi_seam)
  end
  if am > STRESS_SAMPLE_MAX then
    local f = STRESS_SAMPLE_MAX / am
    ax, ay, az = ax * f, ay * f, az * f
  end
  local k = math.min(1.0, dt / 0.08)
  -- (the booked forces get the same ceiling and ride the same filter,
  -- restarted with it)
  stressForcesCap(STRESS_SAMPLE_MAX * math.max(info.mass or 0, 0.01))
  stressForcesSmooth(integ.af and k or 1.0)
  local af = integ.af or { x = ax, y = ay, z = az }
  af.x, af.y, af.z = af.x + (ax - af.x) * k, af.y + (ay - af.y) * k, af.z + (az - af.z) * k
  integ.af = af
  local wp = integ.wprev or { x = w.x, y = w.y, z = w.z }
  local al = integ.alpha or { x = 0, y = 0, z = 0 }
  al.x = al.x + ((w.x - wp.x) / dt - al.x) * k
  al.y = al.y + ((w.y - wp.y) / dt - al.y) * k
  al.z = al.z + ((w.z - wp.z) / dt - al.z) * k
  integ.alpha, integ.wprev = al, { x = w.x, y = w.y, z = w.z }
  -- Settle window after release, shared with the damage model: the pad
  -- handshake is not a load case.
  if time - damage_arm < 1.0 then return end
  local rx, up, rz = basis(node)
  local bx, by, bz = base_of(node, info)
  local cm = info.com or info.origin
  local spd = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
  local dens = air_at(node)
  local q_kpa = 0.5 * AIR_RHO * dens * spd * spd / 1000.0
  local worst, worst_j, worst_sev, worst_why = 0.0, nil, 0.0, nil
  local list, T = joints(node)
  local n, ord = T.n, T.ord
  -- Each part this tick: its wet mass, where it is (world, from the centre of
  -- mass) and the smoothed external force booked on it.
  local P = T.P
  if not P then
    P = { m = {}, x = {}, y = {}, z = {}, fx = {}, fy = {}, fz = {}, c = {} }
    T.P = P
  end
  local pm, ppx, ppy, ppz, pfx, pfy, pfz = P.m, P.x, P.y, P.z, P.fx, P.fy, P.fz
  local fuel_by = tankFuelMap()
  local SF = STRESS_F
  local sfx, sfy, sfz = SF.sx, SF.sy, SF.sz
  -- (every vector's components read once, not per part: a vec3's `.x` is a
  -- call into the engine)
  local rxx, rxy, rxz, upx, upy, upz = rx.x, rx.y, rx.z, up.x, up.y, up.z
  local rzx, rzy, rzz = rz.x, rz.y, rz.z
  local ox, oy, oz = bx - cm.x, by - cm.y, bz - cm.z
  local tm, tsx, tsy, tsz, tfx, tfy, tfz = 0, 0, 0, 0, 0, 0, 0
  for i = 1, n do
    local u = ord[i]
    local b = part_box(node, u)
    local m, lx, ly, lz = 0, 0, 0, 0
    if b then m, lx, ly, lz = b.m + (fuel_by[u] or 0), b.cx, b.cy, b.cz end
    local x = ox + rxx * lx + upx * ly + rzx * lz
    local y = oy + rxy * lx + upy * ly + rzy * lz
    local z = oz + rxz * lx + upz * ly + rzz * lz
    local fx, fy, fz = sfx[u] or 0, sfy[u] or 0, sfz[u] or 0
    pm[i], ppx[i], ppy[i], ppz[i], pfx[i], pfy[i], pfz[i] = m, x, y, z, fx, fy, fz
    tm, tsx, tsy, tsz = tm + m, tsx + m * x, tsy + m * y, tsz + m * z
    tfx, tfy, tfz = tfx + fx, tfy + fy, tfz + fz
  end
  local wx, wy, wz = w.x, w.y, w.z
  local kin = T.kin or {}
  T.kin = kin
  kin.ax, kin.ay, kin.az, kin.alx, kin.aly, kin.alz, kin.wx, kin.wy, kin.wz =
    af.x, af.y, af.z, al.x, al.y, al.z, wx, wy, wz
  -- The coasting drag (a force through the centre of mass in the sim, the
  -- air's in truth) is booked on the parts in front of it.
  local lx, ly, lz = SF.lsx, SF.lsy, SF.lsz
  if lx * lx + ly * ly + lz * lz > 1e-6 then
    local nl = stressLeading(node, T, P, P.c, lx, ly, lz, rx, up, rz)
    if nl > 0 then
      local c = P.c
      lx, ly, lz = lx / nl, ly / nl, lz / nl
      for i = 1, n do
        if c[i] > 0 then pfx[i], pfy[i], pfz[i] = pfx[i] + lx, pfy[i] + ly, pfz[i] + lz end
      end
      tfx, tfy, tfz = tfx + lx * nl, tfy + ly * nl, tfz + lz * nl
    end
  end
  -- The force nobody booked (the residual R of stressSolve, whole craft).
  -- TOUCHING something, it is the support, and it acts where the craft
  -- touches (stressContact). Otherwise (free flight: RCS, a bump, the
  -- filter's lag) it is spread by mass and loads nothing.
  local cw = nil
  local ct = integ.contact
  if info.grounded or info.gripped or R2.onWheels or (ct and ct.t == time) then
    local vsx, vsy, vsz = wy * tsz - wz * tsy, wz * tsx - wx * tsz, wx * tsy - wy * tsx
    local Rx = tm * af.x + (al.y * tsz - al.z * tsy) + (wy * vsz - wz * vsy) - tfx
    local Ry = tm * af.y + (al.z * tsx - al.x * tsz) + (wz * vsx - wx * vsz) - tfy
    local Rz = tm * af.z + (al.x * tsy - al.y * tsx) + (wx * vsy - wy * vsx) - tfz
    if stressContact(node, T, P, P.c, Rx, Ry, Rz, rx, up, rz) > 0 then cw = P.c end
  end
  local L = integ.sload
  if not L or L.T ~= T then
    L = { T = T, list = list, out = {}, kn = {} }
    integ.sload = L
  end
  L.contact = cw ~= nil
  local out = stressSolve(T, list, P, cw, kin, L.out)
  local lox, loy, loz, kn = out.x, out.y, out.z, L.kn
  local g_now = math.sqrt(af.x * af.x + af.y * af.y + af.z * af.z) / 9.81
  local canopy = chutes_deployed and chute_anim > 0
  -- (physTune.loads = false: a harness that pins the velocity against a
  -- force — physics that can't happen — switches the load check off; the
  -- pressure checks stay)
  local loads_on = physTune.loads ~= false
  for kk = 1, #list do
    local j = list[kk]
    kn[kk] = nil
    if not integ.gone[j.uid] then
      local lx, ly, lz = lox[kk], loy[kk], loz[kk]
      local load = math.sqrt(lx * lx + ly * ly + lz * lz) -- kN
      kn[kk] = load
      local d = j.d
      local is_chute = (d.chute or 0) == 1
      -- An open canopy's own lines are rated by the air they take (below),
      -- not by the craft they hold up: the pull through them is the craft's
      -- weight and more, by design (a heavy craft can still use chutes). So
      -- is one paying out, or whose pull is still fading from the filter.
      local sev = 0.0
      if loads_on and not (is_chute and (canopy or chutes_deployed or sfx[j.uid] ~= nil)) then
        sev = load / joint_strength(d, part_hp[j.uid])
      end
      -- (the reason is worded only for the joint that fails, not for every
      -- joint every tick)
      local why = 1
      -- Dynamic pressure on the part itself.
      local qs = q_kpa / jointQmax(j)
      if qs > sev then sev, why = qs, 2 end
      -- An open canopy: the air it can take before the lines part.
      if is_chute and canopy then
        local cs = q_kpa / CHUTE_SAFE_KPA
        if cs > sev then
          sev, why = cs, 3
        end
      end
      if sev > 1.0 then
        integ.strain[j.uid] = (integ.strain[j.uid] or 0) + (sev - 1.0) * dt
      else
        integ.strain[j.uid] = math.max(0, (integ.strain[j.uid] or 0) - dt * 0.05)
      end
      -- Past 2× it goes at once; past 1× it goes once the overload has lasted
      -- (0.04 overload·s: 40 % over for 0.1 s, 10 % over for 0.4 s) — and
      -- only while it is still over: a joint that was overloaded and has
      -- since been unloaded (the craft broke elsewhere first) doesn't go off
      -- later as a delayed charge; its strain stays until it heals or the
      -- load comes back.
      local fails = sev > 2.0 or (sev > 1.0 and (integ.strain[j.uid] or 0) > 0.04)
      -- A canopy's lines part at the opening shock, not after a while:
      -- over its safe pressure while open is a tear at once.
      if is_chute and canopy and q_kpa > CHUTE_SAFE_KPA then
        fails = true
      end
      if fails and sev > worst then
        if why == 1 then
          why = string.format("%.0f kN at %.1f g", load, g_now)
        end
        worst, worst_j, worst_sev, worst_why = sev, j, sev, why
      end
    end
  end
  -- One failure per tick, the worst: the craft is a different shape afterwards
  -- and every load is re-read next tick against the new one.
  if worst_why == 2 then
    worst_why = string.format("%.1f kPa dynamic pressure", q_kpa)
  elseif worst_why == 3 then
    worst_why = string.format("canopy opened into %.1f kPa (%.0f m/s)", q_kpa, spd)
  end
  if worst_j then
    local d = worst_j.d
    local fuelled = false
    for u in pairs(axial_departing(worst_j.uid)) do
      local dd = bp_by_uid[u]
      if dd and not integ.gone[u] and (((dd.fuel or 0) > 0 and (tankLeft(u) or 0) > dd.fuel * 0.25)
        or (dd.kind == "engine" and throttle > 0.05)) then
        fuelled = true
      end
    end
    -- A fuelled tank or a lit engine torn off HARD goes off as it leaves.
    local blast = fuelled and worst_sev > 1.6
    integ.strain[worst_j.uid] = 0
    shedJoint(node, worst_j.uid, worst_why, worst_sev, blast)
    if (d.chute or 0) == 1 then log("chute ripped: " .. worst_why) end
  end
end

-- A LOWER BOUND on the craft's moment of inertia, about any axis: the sum of
-- each live part's smallest principal moment about its own centre (a box's is
-- m/3·(a²+b²) for its two smallest half-extents), with no parallel-axis terms.
-- The true tensor is always at least this, so an angular impulse sized with it
-- can only ever SLOW each component of a spin, never reverse or amplify it.
-- (The first version estimated the full tensor from the blueprint; after a
-- breakup it still counted parts that had left, overestimated a one-part wreck
-- ~18×, and the "brake" span the wreck up until its state went NaN.)
local function inertia_floor(node, info)
  local live = {}
  for _, c in ipairs(node:children()) do
    if c.valid ~= false then
      -- (the pose read once, and the records looked up on a grid: this ran
      -- three engine reads per part per part while a big wreck tumbled)
      local u = uidNear(c.x or 0, c.y or 0, c.z or 0, 0.06)
      if u then live[u] = true end
    end
  end
  local I, m = 0.0, 0.0
  for u in pairs(live) do
    local b = part_box(node, u)
    if b then
      local h = { b.hx, b.hy, b.hz }
      table.sort(h)
      I = I + b.m / 3.0 * (h[1] * h[1] + h[2] * h[2])
      m = m + b.m
    end
  end
  if I <= 0 or m <= 0 then return nil end
  -- And half of it again: the bound is only as good as the box sizes it was
  -- built from, and a brake that overestimates inertia AMPLIFIES a spin (the
  -- first version read unscaled collider boxes, took a lone 0.55-scale
  -- parachute for 3× its real inertia, and span a wreck up to NaN). A brake
  -- built on half the floor just takes a couple more ticks.
  I = I * 0.5
  -- Never scale UP (that could break the bound); scale down if the engine
  -- says the craft is lighter than its parts' listed masses.
  if info.mass and info.mass > 0 and info.mass < m then I = I * info.mass / m end
  return I
end

-- The smallest principal moment of the inertia tensor the solver turns this
-- craft with (assembly.info, floptle/0393), t·m²; nil on an engine without it.
-- The eigenvalues of a symmetric 3×3 in closed form.
function inertiaMin(info)
  local I = info and info.inertia
  if not (I and I[1] and I[2] and I[3]) then return nil end
  local a, b, c = I[1].x, I[2].y, I[3].z
  local d, e, f = I[1].y, I[1].z, I[2].z
  local p1 = d * d + e * e + f * f
  if p1 < 1e-18 then return math.min(a, b, c) end
  local q = (a + b + c) / 3
  local p = math.sqrt(((a - q) ^ 2 + (b - q) ^ 2 + (c - q) ^ 2 + 2 * p1) / 6)
  if p < 1e-12 then return q end
  local A, B, C = (a - q) / p, (b - q) / p, (c - q) / p
  local D, E, F = d / p, e / p, f / p
  local r = (A * (B * C - F * F) - D * (D * C - F * E) + E * (D * F - B * E)) / 2
  local phi = math.acos(math.max(-1, math.min(1, r))) / 3
  return q + 2 * p * math.cos(phi + 2 * math.pi / 3)
end

-- THE REACTION WHEELS. The attitude law asks for a torque of `tk` per rad/s of
-- rate error on every axis. That gain was set for craft weighing their prefabs;
-- weighing what they really weigh (massSync) a light stack — a pod and a tank
-- once its engine has broken off — has so little inertia that one tick of it
-- overshot the error, and the next overshot further: a craft resting on the
-- ground span itself up to 20 rad/s and broke. The gain is capped so a tick
-- takes out at most half the error about the craft's lightest axis (the
-- solver's own tensor says which); a heavy craft feels exactly `tk`.
function wheelTorque(node, info, ex, ey, ez, tk, dt)
  local k = tk
  local lam = inertiaMin(info)
  if lam and lam > 0 and dt and dt > 0 then k = math.min(k, 0.5 * lam / dt) end
  assembly.torque(node, vec3(ex * k, ey * k, ez * k))
end

-- THE SAFETY NET. Never the thing that makes the craft behave — the things above
-- are — but whatever slips past them is caught here and logged.
function safetyTick(node, info, dt)
  if info.anchored or dt <= 0 then integ.prev = nil return end
  local v, w, o = info.vel, info.angVel, info.origin
  if v.x ~= v.x or v.y ~= v.y or v.z ~= v.z or w.x ~= w.x or w.y ~= w.y or w.z ~= w.z
    or not o or o.x ~= o.x then
    throttle = 0.0
    integ_note("nan", "SAFETY: the physics state of this craft is NaN — throttle cut; "
      .. "please report this line")
    integ.prev = nil
    return
  end
  local warp = space.warp()
  local dom = space.dominant(node.x, node.y, node.z)
  local db = dom and space.body(dom)
  local spd = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
  local m = math.max(0.05, info.mass or 1)
  local cm = info.com or o
  -- 1. SPIN. Brake anything past SPIN_MAX back to it with an exact angular
  -- impulse (a pure couple: two equal and opposite pushes, no net shove).
  local wl = math.sqrt(w.x * w.x + w.y * w.y + w.z * w.z)
  if wl > SPIN_MAX and warp <= 1.001 and physTune.spinBrake ~= false then
    -- ΔL = I·Δω with Δω = s·ω, s ∈ [-1, 0): the spin scaled straight back to
    -- the ceiling in one tick. I is the tensor the solver turns this craft
    -- with (assembly.info, floptle/0393), so the brake can't over- or
    -- undershoot. Without it (an older engine), the inertia floor: a lower
    -- bound that only ever slows each component, over a few ticks.
    local s = SPIN_MAX / wl - 1.0
    local LX, LY, LZ
    local It = info.inertia
    if It and It[1] and It[2] and It[3] then
      local ox, oy, oz = w.x * s, w.y * s, w.z * s
      LX = It[1].x * ox + It[1].y * oy + It[1].z * oz
      LY = It[2].x * ox + It[2].y * oy + It[2].z * oz
      LZ = It[3].x * ox + It[3].y * oy + It[3].z * oz
    else
      local I = inertia_floor(node, info)
      if I then LX, LY, LZ = I * w.x * s, I * w.y * s, I * w.z * s end
    end
    if LX and LX == LX then
      local Ll = math.sqrt(LX * LX + LY * LY + LZ * LZ)
      if Ll > 1e-9 then
        -- A pure couple: J = (L × e)/2 at cm ± e (e ⟂ L, unit) gives 2·e×J = L.
        local ex, ey, ez = LY, -LX, 0
        if math.abs(LZ) > math.abs(LX) and math.abs(LZ) > math.abs(LY) then ex, ey, ez = LZ, 0, -LX end
        local el = math.sqrt(ex * ex + ey * ey + ez * ez)
        ex, ey, ez = ex / el, ey / el, ez / el
        local jx = (LY * ez - LZ * ey) * 0.5
        local jy = (LZ * ex - LX * ez) * 0.5
        local jz = (LX * ey - LY * ex) * 0.5
        assembly.impulseAt(node, vec3(jx, jy, jz), vec3(cm.x + ex, cm.y + ey, cm.z + ez))
        assembly.impulseAt(node, vec3(-jx, -jy, -jz), vec3(cm.x - ex, cm.y - ey, cm.z - ez))
        integ_note("spin", string.format("SAFETY: spin clamp — %.1f rad/s, braking toward %.0f", wl, SPIN_MAX))
      end
    end
  end
  local p = integ.prev
  integ.spd_before = p and p.spd or nil -- last tick's speed (damage_tick reads it)
  integ.prev = { vx = v.x, vy = v.y, vz = v.z, spd = spd, dom = dom,
                 rx = db and o.x - db.x, ry = db and o.y - db.y, rz = db and o.z - db.z }
  if not p or p.dom ~= dom or warp > 1.001 then return end
  -- 2. ENERGY. A one-tick speed GAIN beyond what gravity, the engines and a
  -- generous allowance for collisions can deliver is a solver artifact: take
  -- the speed back to what was possible, keeping the new direction.
  local g = 0
  if space.gravity then
    local gx, gy, gz = space.gravity(cm.x, cm.y, cm.z)
    g = math.sqrt((gx or 0) ^ 2 + (gy or 0) ^ 2 + (gz or 0) ^ 2)
  end
  local thrust = 0
  for _, e in ipairs(engines) do thrust = thrust + (e.thrust or 0) end
  local allow = (g + thrust * math.max(throttle, 0) / m + 5.0) * dt + KICK_TOL
  if spd > p.spd + allow and spd > 1e-3 and time > (integ.handoff_t or -1)
    and not near_soi_seam(node.x, node.y, node.z, spd, dt) then
    local want = (p.spd + allow) / spd
    assembly.impulseAt(node, vec3(v.x * (want - 1) * m, v.y * (want - 1) * m,
      v.z * (want - 1) * m), cm)
    integ_note("kick", string.format("SAFETY: velocity clamp — %.1f m/s gained in one tick "
      .. "(%.1f → %.1f m/s, %.1f possible); taken back", spd - p.spd, p.spd, spd, p.spd + allow))
    integ.excess = 0
  elseif time > (integ.handoff_t or -1) and not near_soi_seam(node.x, node.y, node.z, spd, dt) then
    -- ...and a SUSTAINED one. A broken rover dragging its torn-off end
    -- along the ground while its front wheels drove, with its wheel boxes
    -- coming back into the ground as the tyres stowed, gained a few m/s a
    -- tick — under the one-tick limit every time — and left the planet. What
    -- nothing on board explains is summed over about half a second; past
    -- KICK_SUM it is taken back to the speed the craft could have had.
    local base = (g + thrust * math.max(throttle, 0) / m + 5.0) * dt
    integ.excess = (integ.excess or 0) * math.exp(-dt / 0.5) + math.max(0, spd - p.spd - base)
    if integ.excess > KICK_SUM and spd > 1e-3 then
      local keep = math.max(0, spd - integ.excess)
      local want = keep / spd
      assembly.impulseAt(node, vec3(v.x * (want - 1) * m, v.y * (want - 1) * m, v.z * (want - 1) * m), cm)
      integ_note("kick_sum", string.format("SAFETY: sustained velocity clamp — %.1f m/s gained over ~0.5 s that "
        .. "nothing aboard explains (now %.1f m/s); taken back to %.1f", integ.excess, spd, keep))
      integ.excess = 0
    end
  end
  -- 3. JUMP. A hull that moved much further than its velocity carries it in a
  -- tick (body-relative, so the planet's orbit doesn't count) is reported.
  if db and p.rx then
    local ex = (o.x - db.x) - (p.rx + p.vx * dt)
    local ey = (o.y - db.y) - (p.ry + p.vy * dt)
    local ez = (o.z - db.z) - (p.rz + p.vz * dt)
    local jl = math.sqrt(ex * ex + ey * ey + ez * ez)
    if jl > JUMP_TOL then
      integ_note("jump", string.format("SAFETY: the hull jumped %.1f m in one tick with "
        .. "nothing to move it (engine depenetration?)", jl))
    end
  end
end

-- CHUTE DRAG at the canopy. Through the centre of mass a parachute only slows
-- the craft; it never rights it, so a craft that had drifted onto its side
-- came down on its side and landed on its pod (First Flight: nose −54°, the
-- pod crushed). A canopy pulls from above the craft: the pull acts at the
-- chutes' mean position, which hangs the stack pod-up under them like a
-- pendulum (the SAS rate damper then settles the swing).
--   The lever is capped so that swing can never be stiffer than the tick can
-- integrate — ω_n·dt ≤ 0.3 with ω_n² = F·L/I, I the craft's smallest
-- principal moment (the solver's tensor; the inertia floor, a lower bound, on
-- an engine without one), so the cap is conservative. That only bites in the first
-- ticks of a fast opening; at terminal speed the full lever applies.
function chuteDrag(node, info, fx, fy, fz, dt)
  local f = math.sqrt(fx * fx + fy * fy + fz * fz)
  local cm = info.com or info.origin
  if f < 1e-6 or #chutes == 0 or not cm then
    assembly.force(node, vec3(fx, fy, fz))
    return
  end
  -- (the pull is the canopies': booked on them for the stress model)
  local nc = #chutes
  for _, c in ipairs(chutes) do stressForce(c.uid, fx / nc, fy / nc, fz / nc) end
  local rx, up, rz = basis(node)
  local bx, by, bz = base_of(node, info)
  local px, py, pz = 0, 0, 0
  for _, c in ipairs(chutes) do
    px = px + bx + rx.x * c.x + up.x * c.y + rz.x * c.z
    py = py + by + rx.y * c.x + up.y * c.y + rz.y * c.z
    pz = pz + bz + rx.z * c.x + up.z * c.y + rz.z * c.z
  end
  px, py, pz = px / #chutes - cm.x, py / #chutes - cm.y, pz / #chutes - cm.z
  local lever = math.sqrt(px * px + py * py + pz * pz)
  local I = inertiaMin(info) or inertia_floor(node, info)
  if lever < 1e-3 or not I then
    assembly.force(node, vec3(fx, fy, fz))
    return
  end
  local wn_dt = 0.3
  local max_lever = (wn_dt / math.max(dt, 1e-4)) ^ 2 * I / f
  local k = math.min(1.0, max_lever / lever)
  assembly.forceAt(node, vec3(fx, fy, fz), vec3(cm.x + px * k, cm.y + py * k, cm.z + pz * k))
end


-- ── water: buoyancy and drag ───────────────────────────────────────────────
-- "crafts also currently dont float in water." The engine floats compounds in
-- its water volumes, but places that water once a frame while the planet
-- moves every rails tick, so on an orbiting world its sea sits a carry away
-- from the drawn one (a crate hovered 1.2 m over a sea, another rose 13 m
-- over a lake). The sea's own WaterVolume is therefore kept out of physics
-- (prefabs/Sea.prefab.ron: density 0.001, no drag) and the craft is floated
-- here, from the water as the planet carries it:
--   * the SEA is a sphere of the world's sea radius about the body's centre
--     (climate.seaRadius; open water only, climate.seaDepth's rule), a frozen
--     sea floats nothing; LAKES are climate.lakeDepth, per point;
--   * each part is a box (its collider × the scale it is drawn at), cut in
--     2 × 2 × 2 cells; a cell displaces the share of its volume below the
--     surface, pushed up along the water's up at the centre of what is under,
--     so a craft rights itself the way its hull is shaped (a pod floats
--     upright; one tipped over has its low side pushed up harder);
--   * how much of a part's box is sealed, buoyant volume depends on what it
--     is (a pod or a tank is a sealed shell; a girder, a nozzle or a canvas
--     is mostly open), so a craft floats or sinks by its real density;
--   * water drag on each cell's own velocity (quadratic, plus a gentle
--     linear term so a craft at the surface settles instead of bobbing for
--     ever), capped so one tick can never reverse the craft; and an angular
--     drag on how much of it is wet.
-- Forces are held for the tick (assembly.force / torque) from fixedUpdate.
WATER_SEALED = { crewed = 2.0, probe = 1.6, tank = 1.0, structural = 0.4, engine = 0.12,
                 canvas = 0.15, wheel = 0.9 }
-- A capsule's mass sits low, in its heat shield and floor; the physics holds
-- every part's mass at its box's centre, which floats a pod on its side. The
-- righting a low centre of gravity gives (a metacentric height, m) is added
-- for command parts, by how much of each is in the water.
WATER_BALLAST = { crewed = 0.25, probe = 0.15 }
WATER_RHO = 1.0          -- t/m³: the game's masses are tonnes (prefabs/Sea.prefab.ron)
WATER_CD = 1.0           -- quadratic drag coefficient on a cell's wet face
WATER_LIN = 0.6          -- 1/s: linear damping per tonne of water displaced
WATER_ANG = 2.0          -- 1/s: angular damping of a fully wet craft
WATER = { splashed = false, wet = 0, depth = nil, still_t = 0, still = false, anchored = false, frozen = {} }

local function water_frozen(body)
  local f = WATER.frozen[body]
  if f ~= nil then return f end
  f = false
  local bn = find and find(body)
  for _, c in ipairs(bn and bn.children and bn:children() or {}) do
    if c.name == "SeaIce" then f = true end
  end
  WATER.frozen[body] = f
  return f
end

function isSplashed() return WATER.splashed == true end
function waterState() return { splashed = WATER.splashed, wet = WATER.wet, depth = WATER.depth, still = WATER.still } end

function waterTick(node, info, dt)
  if dt <= 0 or info.anchored and not WATER.anchored then WATER.splashed, WATER.wet = false, 0 return end
  local warp = space.warp()
  -- On the rails (time warp) a floating craft is held where it floats: a
  -- conic from the sea surface would carry it into the planet.
  if warp > 1.001 then
    if WATER.splashed and not WATER.anchored and not info.anchored then
      assembly.setAnchored(node, true)
      WATER.anchored = true
    end
    return
  elseif WATER.anchored then
    assembly.setAnchored(node, false)
    WATER.anchored = false
    return
  end
  if not (WATER.cl and WATER.cl.valid ~= false) then WATER.cl = findScript and findScript("climate") or nil end
  local cl = WATER.cl
  if not cl then return end
  local com = info.com or info.origin
  local d = space.dominant(com.x, com.y, com.z)
  local b = d and space.body(d)
  if not b then WATER.splashed, WATER.wet = false, 0 return end
  -- how far the craft reaches from its centre (once per part set)
  if WATER.gen ~= integ.gen then
    WATER.gen = integ.gen
    local reach = 1
    for u in pairs(bp_by_uid) do
      local bx = not integ.gone[u] and part_box(node, u)
      if bx then reach = math.max(reach, math.sqrt(bx.cx ^ 2 + bx.cy ^ 2 + bx.cz ^ 2) + math.max(bx.ex, bx.ey, bx.ez)) end
    end
    WATER.reach = reach + 1
  end
  local px, py, pz = com.x - b.x, com.y - b.y, com.z - b.z
  local dist = math.sqrt(px * px + py * py + pz * pz)
  local R = (cl.seaRadius and cl.seaRadius(d)) or 0
  local sea = R > 0 and dist - R < WATER.reach and not water_frozen(d)
  if sea and dist < R then
    -- open water only: a hole dug below sea level from dry land is dry
    -- (climate.seaDepth asks the ring of sea round the point; -1 = ringed).
    -- Eight terrain queries: asked twice a second, not every tick.
    if time - (WATER.open_t or -10) > 0.5 then
      WATER.open_t = time
      local sd = cl.seaDepth and cl.seaDepth(com.x, com.y, com.z)
      WATER.open = not (sd ~= nil and sd < 0)
    end
    if not WATER.open then sea = false end
  end
  local lake = cl.lakeDepth and cl.lakeDepth(d, com.x, com.y, com.z) ~= nil
  if not sea and not lake then
    WATER.splashed, WATER.wet, WATER.depth, WATER.still = false, 0, nil, false
    return
  end
  WATER.depth = sea and (R - dist) or cl.lakeDepth(d, com.x, com.y, com.z)
  -- A craft no one is flying that floats at rest is left alone (no push):
  -- one in the distant-craft LOD stays frozen where it floats rather than
  -- being woken by the water every tick; a live one that starts to sink or
  -- drift picks the water up again within a tick or two.
  local v, w = info.vel, info.angVel
  local spd = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
  local wl = math.sqrt(w.x * w.x + w.y * w.y + w.z * w.z)
  if not piloting and WATER.splashed then
    if spd < 0.05 and wl < 0.02 then WATER.still_t = WATER.still_t + dt else WATER.still_t = 0 end
    if WATER.still and (spd > 0.15 or wl > 0.05) then WATER.still = false end
    if WATER.still_t > 3 then WATER.still = true end
    if WATER.still then return end
  else
    WATER.still, WATER.still_t = false, 0
  end
  local ux, uy, uz = px / dist, py / dist, pz / dist        -- the water's up (radial)
  local g = 7.0
  if space.gravity then
    local gx, gy, gz = space.gravity(com.x, com.y, com.z)
    if gx then g = math.sqrt(gx * gx + gy * gy + gz * gz) end
  end
  local rx, up, rz = basis(node)
  local bx, by, bz = base_of(node, info)
  local m = math.max(0.05, info.mass or 1)
  local cells, wetV, totV, csum = {}, 0, 0, 0
  -- (each vector's components read once: a vec3's `.x` is a call)
  local rxx, rxy, rxz, upx, upy, upz = rx.x, rx.y, rx.z, up.x, up.y, up.z
  local rzx, rzy, rzz = rz.x, rz.y, rz.z
  local vx, vy, vz, wx, wy, wz = v.x, v.y, v.z, w.x, w.y, w.z
  local comx, comy, comz, bdx, bdy, bdz = com.x, com.y, com.z, b.x, b.y, b.z
  for u, dd in pairs(bp_by_uid) do
    local bxx = not integ.gone[u] and part_box(node, u)
    if bxx then
      local kind = ((dd.wheel or "") ~= "") and "wheel" or (dd.kind or "structural")
      local V = 8 * bxx.hx * bxx.hy * bxx.hz * (WATER_SEALED[kind] or 0.45)
      local Vc = V / 8
      local hx, hy, hz = bxx.ex * 0.5, bxx.ey * 0.5, bxx.ez * 0.5
      local hu = math.abs(ux * rxx + uy * rxy + uz * rxz) * hx + math.abs(ux * upx + uy * upy + uz * upz) * hy
        + math.abs(ux * rzx + uy * rzy + uz * rzz) * hz
      hu = math.max(hu, 0.02)
      local pwet = 0
      -- A part wholly clear of the sea (and no lake about): none of its eight
      -- corners can be wet, as every corner lies within `rad` of its centre.
      -- Its volume still counts; the corner loop is skipped. (A tall craft on
      -- a pad by the sea is inside WATER.reach, and this ran 8 corners for
      -- every part, every tick.)
      local dry = false
      if sea and not lake then
        local rad = math.sqrt(hx * hx + hy * hy + hz * hz)
        local mx = bx + rxx * bxx.cx + upx * bxx.cy + rzx * bxx.cz - bdx
        local my = by + rxy * bxx.cx + upy * bxx.cy + rzy * bxx.cz - bdy
        local mz = bz + rxz * bxx.cx + upz * bxx.cy + rzz * bxx.cz - bdz
        dry = R - math.sqrt(mx * mx + my * my + mz * mz) + rad + hu < -1e-3
      end
      if dry then for _ = 0, 7 do totV = totV + Vc end end
      for k = 0, dry and -1 or 7 do
        local ox = bxx.cx + ((k % 2 == 0) and -hx or hx)
        local oy = bxx.cy + ((math.floor(k / 2) % 2 == 0) and -hy or hy)
        local oz = bxx.cz + ((k < 4) and -hz or hz)
        local cx = bx + rxx * ox + upx * oy + rzx * oz
        local cy = by + rxy * ox + upy * oy + rzy * oz
        local cz = bz + rxz * ox + upz * oy + rzz * oz
        local depth = -1e9
        if sea then
          local qx, qy, qz = cx - bdx, cy - bdy, cz - bdz
          depth = R - math.sqrt(qx * qx + qy * qy + qz * qz)
        end
        if lake then
          local ld = cl.lakeDepth(d, cx, cy, cz)
          if ld and ld > depth then depth = ld end
        end
        totV = totV + Vc
        local f = math.max(0, math.min(1, (depth + hu) / (2 * hu)))
        pwet = pwet + f / 8
        if f > 0 then
          local Vs = Vc * f
          wetV = wetV + Vs
          -- the centre of what is under: the middle of the wet slab
          local sh = hu - f * hu
          local c = { x = cx - ux * sh, y = cy - uy * sh, z = cz - uz * sh, px = cx, py = cy, pz = cz, Vs = Vs, f = f,
                      A = Vc ^ (2 / 3) * f, u = u }
          -- the cell's own velocity, planet frame (info.vel is the craft's
          -- velocity in its dominant body's frame; still water)
          local rxp, ryp, rzp = cx - comx, cy - comy, cz - comz
          c.vx = vx + wy * rzp - wz * ryp
          c.vy = vy + wz * rxp - wx * rzp
          c.vz = vz + wx * ryp - wy * rxp
          c.s = math.sqrt(c.vx * c.vx + c.vy * c.vy + c.vz * c.vz)
          c.k = 0.5 * WATER_RHO * WATER_CD * c.A * c.s + WATER_RHO * Vs * WATER_LIN
          csum = csum + c.k
          cells[#cells + 1] = c
        end
      end
      local gm = WATER_BALLAST[kind]
      if gm and pwet > 0 then
        -- the part's own up, turned toward the water's: m g GM sin(tilt)
        local Yx, Yy, Yz = part_axis(dd)
        local wx = rxx * Yx + upx * Yy + rzx * Yz
        local wy = rxy * Yx + upy * Yy + rzy * Yz
        local wz = rxz * Yx + upz * Yy + rzz * Yz
        local k = gm * bxx.m * g * pwet
        cells.rx = (cells.rx or 0) + (wy * uz - wz * uy) * k
        cells.ry = (cells.ry or 0) + (wz * ux - wx * uz) * k
        cells.rz = (cells.rz or 0) + (wx * uy - wy * ux) * k
      end
    end
  end
  WATER.wet = totV > 0 and wetV / totV or 0
  WATER.splashed = WATER.wet > 0.02
  if #cells == 0 then return end
  -- one tick of drag can at most take 80 % of the speed away, never reverse it
  local kcap = math.min(1, 0.8 * m / (dt * math.max(csum, 1e-9)))
  local Fx, Fy, Fz = 0, 0, 0
  local Tx, Ty, Tz = cells.rx or 0, cells.ry or 0, cells.rz or 0
  for _, c in ipairs(cells) do
    local fb = WATER_RHO * c.Vs * g
    local fx, fy, fz = ux * fb, uy * fb, uz * fb
    local rx1, ry1, rz1 = c.x - com.x, c.y - com.y, c.z - com.z
    Tx, Ty, Tz = Tx + ry1 * fz - rz1 * fy, Ty + rz1 * fx - rx1 * fz, Tz + rx1 * fy - ry1 * fx
    Fx, Fy, Fz = Fx + fx, Fy + fy, Fz + fz
    local k = c.k * kcap
    local dx, dy, dz = -c.vx * k, -c.vy * k, -c.vz * k
    local rx2, ry2, rz2 = c.px - com.x, c.py - com.y, c.pz - com.z
    Tx, Ty, Tz = Tx + ry2 * dz - rz2 * dy, Ty + rz2 * dx - rx2 * dz, Tz + rx2 * dy - ry2 * dx
    Fx, Fy, Fz = Fx + dx, Fy + dy, Fz + dz
    stressForce(c.u, fx + dx, fy + dy, fz + dz) -- (the water on this part, for the stress model)
  end
  -- angular drag, exponential on how much of the craft is wet (never flips a spin)
  local I = info.inertia
  if I and I[1] and wl > 1e-4 then
    local s = (1 - math.exp(-WATER_ANG * math.min(1, WATER.wet * 2) * dt)) / dt
    local ox, oy, oz = -w.x * s, -w.y * s, -w.z * s
    Tx = Tx + I[1].x * ox + I[1].y * oy + I[1].z * oz
    Ty = Ty + I[2].x * ox + I[2].y * oy + I[2].z * oz
    Tz = Tz + I[3].x * ox + I[3].y * oy + I[3].z * oz
  end
  assembly.force(node, vec3(Fx, Fy, Fz))
  assembly.torque(node, vec3(Tx, Ty, Tz))
end

-- ── a stage that can fly itself ─────────────────────────────────────────────
-- Does this departing set carry a command part (a pod, a probe core, a rover
-- body)?
function r2DepartsWithCommand(dep)
  local E = elib()
  if not E then return false end
  for u in pairs(dep) do
    local d = bp_by_uid[u]
    if d and not integ.gone[u] and E.modOf(d, "command") then return true end
  end
  return depHasCrew(dep)
end

-- Split `dep` off as its own live craft (the Vessel prefab, its own
-- controller), the way `undock` does at a docking seam: its blueprint, fuel,
-- charge and action groups go with it, pushed gently away along the stack.
function r2SplitCraft(node, info, dec_uid, dep, parts_nodes, nx, ny, nz)
  local E = elib()
  local sub, n = { parts = {} }, 0
  local sub_charge = 0
  for u in pairs(dep) do
    local d = bp_by_uid[u]
    if d and not integ.gone[u] then
      n = n + 1
      if type(d.st) == "table" and d.st.charge then sub_charge = sub_charge + d.st.charge end
      local rec = E and E.packRecord(d) or {}
      -- its own staging order rides along (its decouplers fire in the order
      -- the builder gave them, on the new craft's SPACE)
      if not dep[rec.parent or 0] then rec.parent = 0 end
      sub.parts[n] = rec
    end
  end
  -- the builder's links among its parts (SPLIT.normalize on the new craft)
  if bp and bp.links then
    local ls = {}
    for _, l in ipairs(bp.links) do if dep[l.a] and dep[l.b] then ls[#ls + 1] = l end end
    if #ls > 0 then sub.links = ls end
  end
  local fuel_before = fuel
  pruneEvents(dep)
  -- it leaves AWAY FROM WHAT STAYS (a rover under a lander drops, a probe
  -- on a rover's back falls off behind it), measured before it is gone
  local away = clearAway(node, dep)
  local gap = away.gap
  drop_set(dep)
  sub.fuel = math.max(0.0, fuel_before - fuel)
  sub.charge = sub_charge
  sub.lockout = 2.0
  for _, dev in pairs(DEVICES) do
    local kp = {}
    for _, u in ipairs(dev.parts) do if not dep[u] then kp[#kp + 1] = u end end
    dev.parts = kp
  end
  if E then
    local dset = {}
    for u in pairs(dep) do dset[u] = true end
    sub.groups = E.packGroups(E.subsetGroups(ctlGroups, dset))
    if clib() and ctlAxes then sub.controls = clib().pack(clib().subset(ctlAxes, dset)) end
  end
  for u in pairs(dep) do
    if bp_by_uid[u] then
      part_total = math.max(0, part_total - 1)
      bp_by_uid[u], part_hp[u] = nil, nil
      panim[u], ppose[u], pnode[u] = nil, nil, nil
    end
  end
  if E then E.pruneGroups(ctlGroups, aboardRecs()) end
  for eid, u in pairs(eid_uid) do if dep[u] then eid_uid[eid] = nil end end
  integ.gen = integ.gen + 1
  splitRecommand(dep)
  elecRescan()
  dock_retree()
  dockRescan()
  quench(parts_nodes)
  local name = splitName(sub.parts, node)
  local bx, by, bz = base_of(node, info)
  sfx3(SFX.stage, bx, by, bz, 0.9, 1.0)
  caption(string.format("%s separates — switch to it with [ ]", name))
  assembly.split(node, parts_nodes, function(stage)
    if not stage then return end
    releasePiece(stage, node, away.x, away.y, away.z, gap)
    local si = assembly.info(stage)
    if si and si.origin then
      local rx, up, rz = basis(node)
      local bx2, by2, bz2 = base_of(node, assembly.info(node) or si)
      local dx, dy, dz = si.origin.x - bx2, si.origin.y - by2, si.origin.z - bz2
      local lx = dx * rx.x + dy * rx.y + dz * rx.z
      local ly = dx * up.x + dy * up.y + dz * up.z
      local lz = dx * rz.x + dy * rz.y + dz * rz.z
      for _, rec in ipairs(sub.parts) do rec.x, rec.y, rec.z = rec.x - lx, rec.y - ly, rec.z - lz end
      sub.name = name
      save.set("dock.handoff." .. tostring(stage.id or 0), sub)
      local m = math.max(0.1, si.mass or 1)
      assembly.impulseAt(stage, vec3(away.x * 1.5 * m, away.y * 1.5 * m, away.z * 1.5 * m), si.com)
    end
    stage.name = name
    log(string.format("STAGED — %s away as its own craft (%d parts)", name, n))
  end, "Vessel")
  return true
end

-- STAGING: what SPACE does once the clamps are off — the next event in the
-- builder's firing order (chutes, a booster ring, or an axial cut). Published so
-- probes can stage a headless flight (no key can be pressed there), and so the
-- SPACE handler in fixedUpdate stays one line. Returns true if something fired.
function stageNext()
  local node = dock.node
  if destroyed or not node or not node.valid or #events == 0 then return false end
  local info = assembly.info(node)
  if not info or info.anchored then return false end
  -- ONE STAGE = every event the builder put in it (a decoupler and the chutes
  -- under it, a booster ring and a fairing…): they fire on the same SPACE, in
  -- list order. Events with no stage of their own are a stage each.
  local first = table.remove(events, 1)
  local group = { first }
  while events[1] and first.stage and first.stage < 1e6 and events[1].stage == first.stage do
    group[#group + 1] = table.remove(events, 1)
  end
  for _, ev in ipairs(group) do
    if ev.kind ~= "chute" and ev.kind ~= "fairing" then r2Before(node) break end
  end
  for _, ev in ipairs(group) do
    if node.valid and not destroyed then fireEvent(node, assembly.info(node) or info, ev) end
  end
  return true
end

-- Is the event still aboard (an earlier event of its stage may have carried
-- its parts away)? Trims a ring's branches and a chute event's chutes.
function stageEventLive(ev)
  local live = function(u) return bp_by_uid[u] ~= nil and not integ.gone[u] end
  if ev.kind == "axial" or ev.kind == "fairing" then return live(ev.uid) end
  if ev.kind == "chute" then
    local us = {}
    for _, u in ipairs(ev.uids or {}) do if live(u) then us[#us + 1] = u end end
    ev.uids = us
    return #us > 0
  end
  local bs = {}
  for _, g in ipairs(ev.branches or {}) do if live(g.uid) then bs[#bs + 1] = g end end
  ev.branches = bs
  return #bs > 0
end

-- Cut the craft at decoupler `dec_uid`: the side without the crew leaves
-- (SPLIT.sides). A piece with a command part of its own leaves as a craft you
-- can switch to; anything else leaves as debris with a kick of `dv` m/s along
-- `kick` (world unit; nil = away from what stays).
function separateAt(node, info, dec_uid, dv, kick, what)
  local dep = axial_departing(dec_uid)
  if not next(dep) then return false end
  local parts_nodes = {}
  for _, child in ipairs(node:children()) do
    if child_departs_axial(child, dec_uid) then parts_nodes[#parts_nodes + 1] = child end
  end
  if #parts_nodes == 0 then return false end
  if r2DepartsWithCommand(dep) then
    -- The piece that leaves carries a command part of its own (a rover under
    -- a lander, a probe on a booster, an empty pod): it goes as a LIVE craft
    -- you can switch to and fly, like an undocked module.
    return r2SplitCraft(node, info, dec_uid, dep, parts_nodes)
  end
  -- Measured BEFORE the piece is marked gone (clearance skips gone parts):
  -- which way it leaves (from the kept mass toward its own), and how far it
  -- must move along that to be out of the hull.
  local away = clearAway(node, dep)
  local gap = away.gap
  local kx, ky, kz = away.x, away.y, away.z
  if kick then kx, ky, kz = kick.x, kick.y, kick.z end
  local recs = {}
  for u in pairs(dep) do if bp_by_uid[u] then recs[#recs + 1] = bp_by_uid[u] end end
  local name = splitName(recs, node)
  pruneEvents(dep)
  drop_set(dep)
  splitRecommand(dep)
  local n_away = #parts_nodes
  quench(parts_nodes)
  local bx, by, bz = base_of(node, info)
  sfx3(what == "ring" and SFX.boosters or SFX.stage, bx, by, bz, 0.9, 1.0) -- the charge fires
  caption(what == "ring" and "the boosters separate" or "a stage separates")
  assembly.split(node, parts_nodes, function(stage)
    if not stage then return end
    releasePiece(stage, node, kx, ky, kz, gap)
    local si = assembly.info(stage)
    if si then
      -- Mass-scaled Δv: a FLAT impulse gave a heavy stage almost no push
      -- (Δv = impulse/mass), so close-mounted pieces clung to the hull and
      -- looked stuck. The charge is the only energy in the separation (the
      -- piece only moves out of a real overlap first, releasePiece).
      local m = math.max(0.1, si.mass)
      local g2 = physTune.clear and gap or 0
      assembly.impulseAt(stage, vec3(kx * dv * m, ky * dv * m, kz * dv * m),
        vec3(si.com.x + kx * g2, si.com.y + ky * g2, si.com.z + kz * g2))
      local fx = fxd()
      if fx then fx.separate(si.com.x, si.com.y, si.com.z, info.vel.x, info.vel.y, info.vel.z)
      else spawnEffect("SepPuff", si.com.x, si.com.y, si.com.z) end
    end
    stage.name = name
    log(string.format("%s away: %s (%d parts)", what == "ring" and "booster" or "stage", name, n_away))
  end)
  return true
end

-- Fire ONE separation event (already taken off the list).
function fireEvent(node, info, ev)
  if not stageEventLive(ev) then return false end
  local bx, by, bz = base_of(node, info)
  local rx, up, rz = basis(node)
  if ev.kind == "chute" then
    -- PARACHUTES: pop them open. They start dragging (see the drag pass
    -- below) as soon as they're in thick enough air.
    chutes_deployed = true
    chute_fill = { t = 0.0, stretch = 0.0, area = 0.0, dens = 0.0, spd = 0.0 }
    sfx3(SFX.chute, bx, by, bz, 0.8, 1.0) -- the canopy cracks open
    -- One canopy per chute part (prefabs/Parachute.prefab.ron): it finds its
    -- chute by `canopy` and draws chute_fill from the canister up.
    for _, c in ipairs(chutes) do
      local wx = bx + rx.x * c.x + up.x * c.y + rz.x * c.z
      local wy = by + rx.y * c.x + up.y * c.y + rz.y * c.z
      local wz = bz + rx.z * c.x + up.z * c.y + rz.z * c.z
      spawn("Parachute", vec3(wx, wy, wz), function(n)
        n.visible = false -- shown once its bones are placed (no rest-pose frame)
        c.canopy = n.id
      end)
    end
    do -- the mortar's puff out of each chute canister
      local fx = fxd()
      if fx then
        local crx, cup, crz = basis(node)
        for _, c in ipairs(chutes) do
          fx.chute(bx + crx.x * c.x + cup.x * c.y + crz.x * c.z, by + crx.y * c.x + cup.y * c.y + crz.y * c.z,
            bz + crx.z * c.x + cup.z * c.y + crz.z * c.z, info.vel.x, info.vel.y, info.vel.z)
        end
      end
    end
    caption("the parachutes crack open")
    log("parachutes deployed")
  elseif ev.kind == "fairing" then
    r2Jettison(node, ev.uid)
  elseif ev.kind == "ring" then
    -- A BOOSTER RING: every branch in the ring leaves at once (symmetric
    -- pairs together, so the ship stays balanced). A branch kicks OUTWARD
    -- from the spine when it is the booster that leaves; when the crew rode
    -- the "booster" (a jet on a rocket's radial decoupler), the rocket is
    -- what leaves, away from the crew's side.
    for _, g in ipairs(ev.branches) do
      if bp_by_uid[g.uid] and not integ.gone[g.uid] then
        local dep = axial_departing(g.uid)
        local kick = nil
        if dep[g.uid] then
          local ol = math.sqrt(g.x * g.x + g.z * g.z)
          local ox, oz = 1, 0
          if ol > 1e-4 then ox, oz = g.x / ol, g.z / ol end
          kick = { x = rx.x * ox + rz.x * oz, y = rx.y * ox + rz.y * oz, z = rx.z * ox + rz.z * oz }
        end
        separateAt(node, assembly.info(node) or info, g.uid, 4.5, kick, "ring")
      end
    end
  else
    -- An AXIAL cut: the spent stage falls back along the stack, away from
    -- what stays (a lander leaving its descent stage, the classic stack).
    separateAt(node, info, ev.uid, 3.5, nil, "axial")
  end
  return true
end

-- ══ ROUND TWO: ROVERS, ROBOTICS, FAIRINGS, THE CLAW AND THE DRILL ════════════
--
-- Everything that MOVES inside a craft, by its parts' modules (electronics):
--
--   wheels    `drive`   the tyre is a live body hung from the chassis on the
--             engine's wheel joint (floptle/0420): suspension, motor, brake,
--             grip by the load it carries. W/S drive, A/D steer (skid: the
--             two sides run at different speeds), B the brakes. A rover that
--             stops is held by its wheel brakes (motor on, speed 0), which
--             hold the spot on a 20° voxel slope since 0.117.0-rc3.
--   robotics  `hinge` `piston` `rotor`  KINEMATIC: the moving half of the
--             part and everything built onto it are re-posed inside the one
--             compound each tick (node poses + assembly.syncColliders) and
--             the motor's torque against the load decides whether it moves.
--             Engine hinges between two assemblies hold their pivot on an
--             orbiting planet since 0.117.0-rc3 (0.3 mm over 25 s), but a
--             craft of several assemblies is still not one vessel in info,
--             rails or saves, and joint state is not saved (0420 "not
--             done"). Kept in one compound, the craft stays ONE
--             vessel for all of those, its joint state is the parts' own `st`
--             (saved with the record, re-applied on load), and staging,
--             docking and breakage split it like any other.
--   fairings  `fairing` a shell built to fit the payload (electronics
--             fairingShell) that keeps the air and heat off what is inside,
--             and jettisons in two halves by action or staging event.
--   claw      `claw`    armed, it grips whatever its fingers touch
--             (assembly.grip) and holds until released.
--   drill     `drill`   lowered and running on a landed or gripped craft, it
--             bores the ground (terrain.dig, small bites) and lifts what it
--             cuts into the hold (the same rock survey the mining laser uses).
--
-- ARTICULATED PARTS LIVE ONLY IN THE ACTIVE BUBBLE: the tyres exist while the
-- craft is piloted, at 1× warp, on (or right over) the ground; otherwise the
-- wheels are rigid parts of the hull (their box takes the craft's weight), so
-- rails, distant-craft LOD, warp and saves only ever see one assembly.
--
-- All of it is reached through globals: fixedUpdate sits at LuaJIT's
-- 60-upvalue ceiling. State lives in the one `R2` table.

TYRE_SHARE = 0.6
R2_TYRE_RATIO = 12.0   -- a tyre weighs at least 1/12 of the load it carries (hang_tyre)
R2 = {
  gen = -1,           -- integ.gen the part lists were built for
  wheels = {},        -- { uid, d, m (drive module), r, tx, side, node, tyre, seat }
  robo = {},          -- robotic parts in pod-out order
  chain = {},         -- uid → { robotic uids moving it, innermost first }
  node = {},          -- uid → live part node (resolved at rest, kept by entity id)
  rest = {},          -- uid → { x,y,z, X,Y,Z } rest pose, vessel frame
  live = false,       -- tyres are out
  driving = false,    -- WASD is driving the wheels this tick (attitude stands down)
  drive = 0.0, steer = 0.0,
  hold_t = 0.0, park = false,
  claws = {}, drills = {}, fairings = {},
  shells = {},        -- fairing uid → { meshes, nodes } (kept across rescans)
  holdoff = 0.0,      -- seconds of fixed ticks before the tyres may come out (a split, a rollout)
  last_cap = nil,
  draw = {},          -- load id → EC/s wanted this tick (power_tick reads it)
  speed = 0.0,
}

local function r2_basis(yaw, pitch, roll)
  local cy, sy = math.cos(yaw or 0), math.sin(yaw or 0)
  local cx, sx = math.cos(pitch or 0), math.sin(pitch or 0)
  local cz, sz = math.cos(roll or 0), math.sin(roll or 0)
  return { cy * cz + sy * sx * sz, cx * sz, -sy * cz + cy * sx * sz },
         { -cy * sz + sy * sx * cz, cx * cz, sy * sz + cy * sx * cz },
         { sy * cx, -sx, cy * cx }
end

local function r2_euler(X, Y, Z)
  local pitch = math.asin(math.max(-1, math.min(1, -Z[2])))
  return math.atan2(Z[1], Z[3]), pitch, math.atan2(X[2], Y[2])
end

-- Rotate vector v about unit axis k by angle a.
local function r2_rot(v, k, a)
  local c, s = math.cos(a), math.sin(a)
  local d = v[1] * k[1] + v[2] * k[2] + v[3] * k[3]
  local cx = k[2] * v[3] - k[3] * v[2]
  local cy = k[3] * v[1] - k[1] * v[3]
  local cz = k[1] * v[2] - k[2] * v[1]
  return { v[1] * c + cx * s + k[1] * d * (1 - c), v[2] * c + cy * s + k[2] * d * (1 - c),
           v[3] * c + cz * s + k[3] * d * (1 - c) }
end

-- The live node of part `uid`: resolved by entity id while the craft is at
-- rest (uid_of_node caches it for the part's life), so a part a hinge has
-- swung away from its blueprint spot is still found.
function r2NodeOf(node, uid)
  local c = R2.node[uid]
  if c and c.valid then return c end
  for _, ch in ipairs(node:children()) do
    local nm = ch.name or ""
    if nm:sub(1, 4) == "Part" and uid_of_node(ch) == uid then
      R2.node[uid] = ch
      return ch
    end
  end
  return nil
end

local function child_named(n, name)
  if not (n and n.valid) then return nil end
  for _, c in ipairs(n:children()) do if c.name == name then return c end end
  return nil
end

-- ── wheel settings and steering (SCRATCH wheel_spec.md) ────────────────────
-- Globals on purpose: pure functions of the blueprint, so tests can run them,
-- and no upvalue is spent in the functions that call them.
--
-- THE ENGINE'S WHEEL: a wheel joint spins its tyre about the CHASSIS's Z axis
-- turned by the joint's `steer` (degrees) about the suspension axis (the
-- chassis's +Y here). So every wheel gets a base steer that lines that axle
-- up with its own part's axle (a wheel mounted on the front or back face of a
-- chassis, axle along X, would otherwise roll sideways), and a spin SIGN that
-- makes its roll carry the craft toward the front; a mirrored pair gets
-- opposite base steers and the same forward roll.

-- The engine's steer turns the axle about +Y by +steer degrees; +1 if that
-- turns a front wheel toward the craft's left (measured on 0.117.0-rc3).
R2_STEER_SIGN = 1

-- One wheel's settings from its craft record (`wcfg`), defaults filled in.
WCFG_DEFAULT = { steer = "auto", steerMax = 25, drive = "auto", motor = 1, brake = 1,
                 spring = 1, damper = 1, travel = nil, friction = 1, skid = false }
function r2WheelCfg(d)
  local w = type(d) == "table" and type(d.wcfg) == "table" and d.wcfg or {}
  local function num(v, def, lo, hi)
    v = tonumber(v)
    if not v or v ~= v then return def end
    return math.max(lo, math.min(hi, v))
  end
  local function mode(v)
    v = type(v) == "string" and v:lower() or "auto"
    if v == "on" or v == "off" or v == "invert" or v == "auto" then return v end
    return "auto"
  end
  return { steer = mode(w.steer), steerMax = num(w.steerMax, 25, 0, 60), drive = mode(w.drive),
           motor = num(w.motor, 1, 0, 1), brake = num(w.brake, 1, 0, 1),
           spring = num(w.spring, 1, 0.25, 4), damper = num(w.damper, 1, 0.25, 4),
           travel = tonumber(w.travel), friction = num(w.friction, 1, 0.5, 2), skid = w.skid == true }
end

-- ── how fast a wheel rolls and how hard it pushes (playtest 2026-10-23) ─────
-- "its equally as fast to traverse with a rover / car i built as it is with a
-- astronaut". The catalogue's hub motors topped out at 5 / 7 / 9 m/s (S/M/L),
-- the traction control let them push at 0.3 g, and the steering eased off
-- past 4.5 m/s, so a rover ran at a jog. A wheel now rolls at what its size
-- makes sensible for a light electric rover — a medium wheel (r 0.4 m) at
-- 22 m/s, 525 rpm — and pushes hard enough to get there in a few seconds.
-- Floors, so a craft saved with the old figures (its records carry `mods`)
-- drives on the new ones too; a catalogue that rates higher wins.
R2_WHEEL_TOP = { S = 14.0, M = 22.0, L = 28.0 }      -- m/s on the level, full stick
R2_WHEEL_TORQUE = { S = 0.35, M = 0.9, L = 2.0 }     -- kN·m, rated like thrust (× parts.rating)
R2_TC = 0.55          -- traction control: g the motors may push the craft at on the level
R2_LK_MAX = 24.0      -- the most the traction control's lead may be scaled up (drive_tick, THE LEAD ADAPTS)
R2_LAT_MU = 0.47      -- the share of the tyres' grip a turn may use, sideways (0.42 g on R2_TYRE_MU, as before it rose)
R2_LAT_SSF = 0.45     -- …and the share of the rollover threshold (half track / CoM height)
R2_ANTIROLL = 2.0     -- anti-roll bar: × m·g·track of roll torque per radian of lean
R2_TYRES_VMAX = 45.0  -- m/s: faster than this the tyres fold back into the hull
R2_GEAR_VMAX = 90.0   -- …but a plane's landing gear rolls on to takeoff and landing speeds
-- The tyre's friction (× the wheel's Grip setting). It is the one limit the
-- engine's wheel always honours (see drive_tick: its motor cap does not cap
-- the drive), so it is set where a rover should live: a knobbly tyre on dirt,
-- 0.9 g of push, braking and cornering, enough to climb 40° and hold there.
-- The project grips each tyre ONCE (project.ron `wheel_friction: Single`,
-- floptle 0575): until engine 0.117.1-dev.1368 a wheel-joint tyre also took
-- its ground contact's own friction, about twice this, and 0.7 here drove
-- like 1.4. The turn and lean limits (R2_LAT_MU, auto_drive BIKE_MU_SHARE)
-- were scaled down with the rise so a turn asks what it did.
R2_TYRE_MU = 0.9
R2_G_REF = 9.8        -- the gravity the figures are for (a lighter world slows them)

-- A wheel's top speed (m/s) on a world of gravity g: its size's figure or the
-- catalogue's, whichever is higher, and slower on a light world, where the
-- same tyre grips less (the speed a curve of the same radius holds goes as
-- the square root of g).
function r2TopSpeed(w, g)
  local m = w.m or {}
  local top = math.max(tonumber(m.speed) or 0, R2_WHEEL_TOP[w.size or "M"] or 0)
  if top <= 0 then top = 7 end
  local vk = math.max(0.6, math.min(1.0, math.sqrt(math.max(g or R2_G_REF, 0) / R2_G_REF)))
  return top * vk
end

-- A wheel's full motor torque (kN·m): the catalogue's (already rated for the
-- home world) or its size's floor rated the same way (`rk` = parts.rating thrust).
function r2FullTorque(w, rk)
  local m = w.m or {}
  return math.max(tonumber(m.torque) or 0.6, (R2_WHEEL_TORQUE[w.size or "M"] or 0) * (rk or 1))
end

-- How hard (m/s²) the rover may turn on a world of gravity g: the lesser of
-- the tyres' sideways grip (friction mu) and the acceleration that would lift
-- its inside wheels (g · half track / CoM height — the static stability
-- factor), each with a margin. Never under 0.15 g: a rover must still turn.
function r2Lateral(g, plan, mu)
  g = g or R2_G_REF
  local grip = R2_LAT_MU * (mu or 1)
  local ssf = 1.0
  if plan and (plan.hcg or 0) > 0.05 and (plan.track or 0) > 0.05 then
    ssf = 0.5 * plan.track / plan.hcg
  end
  return g * math.max(0.15, math.min(grip, R2_LAT_SSF * ssf))
end

-- The craft's front in the vessel frame, level: { x, z } (unit). A part
-- marked `front` (a rover body) or a command seat faces its +X; failing
-- those, the command part's +X; failing that, the vessel's +X.
function r2FrontOf(bp, gone, cmd_uid, basis_fn)
  local function level(d)
    local X = basis_fn(d.yaw, d.pitch, d.roll)
    local l = math.sqrt(X[1] * X[1] + X[3] * X[3])
    if l < 0.5 then return nil end
    return { x = X[1] / l, z = X[3] / l }
  end
  local best, bu
  for u, d in pairs(bp or {}) do
    if not (gone and gone[u]) and ((d.front or 0) == 1 or (d.seat or 0) == 1 or d.seat == true) then
      if not bu or u < bu then
        local f = level(d)
        if f then best, bu = f, u end
      end
    end
  end
  if best then return best end
  local d = cmd_uid and bp and bp[cmd_uid]
  if d and not (gone and gone[cmd_uid]) then
    local f = level(d)
    if f then return f end
  end
  return { x = 1, z = 0 }
end

-- Is there a part that says where the front is (a rover body, a seat)?
function r2HasFrontPart(bp, gone)
  for u, d in pairs(bp or {}) do
    if not (gone and gone[u]) and ((d.front or 0) == 1 or (d.seat or 0) == 1 or d.seat == true) then return true end
  end
  return false
end

-- The way the rider faces, level (vessel frame): the seat the crew sits in
-- (stationUid), else the craft's command seat, else the lowest-uid seat
-- aboard. nil with no seat, or one that faces up or down.
function r2SeatFront()
  local function isSeat(d) return d and ((d.seat or 0) == 1 or d.seat == true) end
  local d
  for _, u in ipairs({ stationUid or false, pod_uid or false }) do
    local q = u and bp_by_uid[u]
    if not d and q and not integ.gone[u] and isSeat(q) then d = q end
  end
  if not d then
    local bu
    for u, q in pairs(bp_by_uid) do
      if not integ.gone[u] and isSeat(q) and (not bu or u < bu) then d, bu = q, u end
    end
  end
  if not d then return nil end
  local X = r2_basis(d.yaw, d.pitch, d.roll)
  local l = math.sqrt(X[1] * X[1] + X[3] * X[3])
  if l < 0.5 then return nil end
  return { x = X[1] / l, z = X[3] / l }
end

-- A BIKE'S FRONT IS ITS FORK (playtest 2026-10-26: "sometimes it gets the
-- direction wrong and it drives better backwards"). The front came from the
-- seat's facing, so a saddle put on the other way round made the swing arm
-- the front: W rode it tail-first, steering on the rear wheel. Now a fork or a
-- swing arm says it, whatever the saddle does: from the swing arm to the fork
-- when there are both, else a fork's +X (it mounts on a front face), else
-- the way a swing arm's −X points. Level, vessel frame; nil without either.
function r2MotoFront(E)
  if not E then return nil end
  local fx, fz, nf, ax, az, na = 0, 0, 0, 0, 0, 0
  local dx, dz = 0, 0
  for u, d in pairs(bp_by_uid) do
    if not integ.gone[u] and (part_hp[u] or 1) > 0 then
      local m = E.modOf(d, "susp")
      if m and (m.kind == "fork" or m.kind == "arm") then
        local X = r2_basis(d.yaw, d.pitch, d.roll)
        local s = m.kind == "fork" and 1 or -1
        dx, dz = dx + s * X[1], dz + s * X[3]
        if m.kind == "fork" then fx, fz, nf = fx + (d.x or 0), fz + (d.z or 0), nf + 1
        else ax, az, na = ax + (d.x or 0), az + (d.z or 0), na + 1 end
      end
    end
  end
  if nf + na == 0 then return nil end
  if nf > 0 and na > 0 then
    local px, pz = fx / nf - ax / na, fz / nf - az / na
    if math.sqrt(px * px + pz * pz) > 0.3 then dx, dz = px, pz end
  end
  local l = math.sqrt(dx * dx + dz * dz)
  if l < 1e-3 then return nil end
  return { x = dx / l, z = dz / l }, nf
end

-- A FRONT THE WHEELS CAN'T ROLL ALONG (a seat or a probe core put on
-- sideways): when most of the craft's wheels would roll across it, the front
-- is turned onto the line they roll on, the way nearest the old front (or
-- the fork's). Landing gear doesn't vote (it is laid along the front).
-- Returns the new front, or nil to keep it.
function r2RollFront(E, F, mf)
  if not (E and F) then return nil end
  local sx, sz, n, across = 0, 0, 0, 0
  for u, d in pairs(bp_by_uid) do
    if not integ.gone[u] and (part_hp[u] or 1) > 0 and E.modOf(d, "drive") and not afHas(d, "gear") then
      local X = r2_basis(d.yaw, d.pitch, d.roll)
      local rx, rz = -X[3], X[1]                  -- the roll line: axle × up
      local l = math.sqrt(rx * rx + rz * rz)
      if l > 0.3 then
        rx, rz = rx / l, rz / l
        local a = rx * F.x + rz * F.z
        if math.abs(a) < R2_REALIGN then across = across + 1 end
        -- sign-aligned with the first wheel's line
        if n > 0 and rx * sx + rz * sz < 0 then rx, rz = -rx, -rz end
        sx, sz, n = sx + rx, sz + rz, n + 1
      end
    end
  end
  if n == 0 or across * 2 <= n then return nil end
  local l = math.sqrt(sx * sx + sz * sz)
  if l < 1e-3 then return nil end
  sx, sz = sx / l, sz / l
  local ref = mf or F
  local s = sx * ref.x + sz * ref.z
  if math.abs(s) < 0.05 then s = sx + sz end     -- square across: a fixed choice
  if s < 0 then sx, sz = -sx, -sz end
  return { x = sx, z = sz }
end

-- A wheel's base steer and spin sign, from its mount (w.axle, vessel frame)
-- and the craft's front F.
-- A WHEEL ROLLS ALONG THE CRAFT (playtest 2026-10-26: "sometimes the jet /
-- aircraft's landing gear points in the wrong direction or is like fighting
-- and it makes the aircraft jump around crazily"). A landing gear's axle was
-- its part's Z, so a gear turned on its leg, or hung from a part whose own
-- axes run another way (a hub block, a plate), rolled ACROSS the runway and
-- its tyre's side grip fought the take-off roll. A wheel whose part axle
-- stands upright (on a belly) or runs within R2_REALIGN of the front is laid
-- across the front instead (the drawn tyre follows the joint): landing gear
-- always, any wheel that would otherwise roll sideways. Its spin sign then
-- follows the front like any other wheel's.
R2_REALIGN = 0.5   -- |roll · front| under this: the wheel is turned to roll along the front
function r2WheelSetup(w, F)
  w.cfg = r2WheelCfg(w.d)
  local ax, az = w.axle[1], w.axle[3]
  F = F or { x = 1, z = 0 }
  local hl = math.sqrt(ax * ax + az * az)
  w.realigned = nil
  if w.gear or hl < 0.3 or math.abs((-az * F.x + ax * F.z) / math.max(hl, 1e-6)) < R2_REALIGN then
    -- across the front (sign kept nearest the part's own, so a mirrored
    -- pair stays a pair)
    local nx, nz = F.z, -F.x
    if nx * ax + nz * az < 0 then nx, nz = -nx, -nz end
    if not w.gear or math.abs(nx * ax + nz * az) < 0.999 * math.max(hl, 1e-6) then w.realigned = true end
    ax, az = nx, nz
  end
  local th = math.deg(math.atan2(ax, az))
  if th > 90 then th = th - 180 elseif th <= -90 then th = th + 180 end
  w.steer0 = th
  -- a positive spin about the (base-steered) axle rolls the wheel this way
  local r = math.rad(th)
  local dx, dz = -math.cos(r), math.sin(r)
  local along = dx * F.x + dz * F.z
  local rs = 0
  if math.abs(along) > 0.3 then rs = along > 0 and 1 or -1 end
  if w.cfg.drive == "off" then rs = 0 elseif w.cfg.drive == "invert" then rs = -rs end
  w.rs = rs
  return w
end

-- Where each wheel sits about the centre of mass (a along the front, l to the
-- left), which wheels steer, and the line the turn pivots on.
function r2SteerPlan(wheels, F, bp, gone)
  F = F or { x = 1, z = 0 }
  local m, cx, cz = 0, 0, 0
  for u, d in pairs(bp or {}) do
    if not (gone and gone[u]) then
      local dm = math.max(0.001, d.mass or 0.1)
      m, cx, cz = m + dm, cx + d.x * dm, cz + d.z * dm
    end
  end
  if m > 0 then cx, cz = cx / m, cz / m end
  local Lx, Lz = F.z, -F.x            -- up × front
  local amin, amax = math.huge, -math.huge
  for _, w in ipairs(wheels) do
    local dx, dz = w.cx - cx, w.cz - cz
    w.a = dx * F.x + dz * F.z
    w.l = dx * Lx + dz * Lz
    amin, amax = math.min(amin, w.a), math.max(amax, w.a)
  end
  local span = (#wheels > 0) and (amax - amin) or 0
  local piv_n, piv = 0, 0
  for _, w in ipairs(wheels) do
    local c = w.cfg or r2WheelCfg(w.d)
    w.cfg = c
    if c.steer == "off" or c.steerMax <= 0 then w.steers = false
    elseif c.steer == "on" or c.steer == "invert" then w.steers = true
    else w.steers = span > 0.3 and w.a > 0.2 * span end
    w.ssign = (c.steer == "invert") and -1 or 1
    if not w.steers then piv_n, piv = piv_n + 1, piv + w.a end
  end
  local plan = { pivot = piv_n > 0 and piv / piv_n or 0 }
  -- how wide it stands and how tall its centre of mass sits over the
  -- ground the tyres touch (r2Lateral)
  local lmin, lmax, gy = math.huge, -math.huge, math.huge
  for _, w in ipairs(wheels) do
    lmin, lmax = math.min(lmin, w.l or 0), math.max(lmax, w.l or 0)
    gy = math.min(gy, (w.cy or 0) - (w.r or 0.4))
  end
  if #wheels > 0 then
    local my, mm = 0, 0
    for u, d in pairs(bp or {}) do
      if not (gone and gone[u]) then
        local dm = math.max(0.001, d.mass or 0.1)
        my, mm = my + (d.y or 0) * dm, mm + dm
      end
    end
    plan.track = lmax - lmin
    plan.hcg = mm > 0 and (my / mm - gy) or 0
  end
  local best = 0
  for _, w in ipairs(wheels) do
    if w.steers and math.abs(w.a - plan.pivot) > best then
      best, plan.ref = math.abs(w.a - plan.pivot), w
    end
  end
  R2.plan = plan
  return plan
end

-- This tick's steer (degrees, + toward the left about the wheel's own base)
-- and drive (−1…1 of top speed along the front, + forward) for every wheel.
-- Ackermann: every steering wheel points across the turn's centre, which
-- lies on the pivot line (the wheels that don't steer); each wheel's speed
-- is its own distance from that centre. The steering eases off with speed.
--
-- SPEED-SENSITIVE STEERING. Given `alat` (m/s², the sideways acceleration the
-- craft may turn at: drive_tick sizes it from the grip and how tall the rover
-- stands, r2Lateral), the lock is held to the turn that pulls exactly that at
-- this speed — tan δ = wheelbase · alat / v² — so full lock at a crawl, a
-- gentle arc at 20 m/s, and never a turn that rolls the rover. Without it
-- (an old caller) the lock eases as R2_STEER_EASE / speed.
R2_STEER_EASE = 4.5   -- m/s: full lock up to here, then lock × this / speed
function r2WheelCmd(wheels, plan, drive, steer, spd, alat)
  plan = plan or { pivot = 0 }
  local out = {}
  local ref = plan.ref
  local R = nil                    -- the turn centre's offset to the left (m)
  if ref and math.abs(steer or 0) > 1e-3 then
    local lock = ref.cfg and ref.cfg.steerMax or 25
    local k = math.min(1, R2_STEER_EASE / math.max(spd or 0, 1e-3))
    local arm = math.abs((ref.a or 0) - (plan.pivot or 0))
    if alat and alat > 0 and arm > 1e-3 and lock > 0 then
      local v2 = math.max((spd or 0) * (spd or 0), 1e-6)
      k = math.min(1, math.deg(math.atan(arm * alat / v2)) / lock)
    end
    local d = math.rad(steer * k * lock)
    if math.abs(d) > 1e-4 then
      -- the centre that puts the most-turned wheel (the inside one) at the
      -- commanded angle; every other steering wheel turns less
      for _, w in ipairs(wheels) do
        local arm = w.a - plan.pivot
        if w.steers and math.abs(arm) > 1e-3 then
          local r = math.abs(arm) / math.tan(d) + (w.l or 0)
          if not R or math.abs(r) > math.abs(R) then R = r end
        end
      end
    end
  end
  for k, w in ipairs(wheels) do
    local c = w.cfg or {}
    local st, scale = 0, 1
    if R then
      local arm, lat = w.a - plan.pivot, R - (w.l or 0)
      if w.steers then
        st = math.deg(math.atan(arm / lat))
        local mx = c.steerMax or 25
        st = math.max(-mx, math.min(mx, st)) * (w.ssign or 1)
      end
      scale = math.sqrt(arm * arm + lat * lat) / math.abs(R)
    end
    local dv = (drive or 0) * scale
    if c.skid and math.abs(steer or 0) > 1e-3 then
      -- skid steer on top: the wheels on the inside of the turn hold back
      local side = (w.l or 0) >= 0 and 1 or -1
      dv = dv - steer * side * (math.abs(drive or 0) > 0.05 and 0.6 or 1.0)
    end
    out[k] = { steer = st, drive = math.max(-1.3, math.min(1.3, dv)) }
  end
  return out
end

-- ── the control mode (scripts/craft_mode.lua) ──────────────────────────────
-- The craft's MODE says what its wheels do, not the wheels' part type
-- (playtest 2026-10-26: one landing gear on a rover made it a plane that W
-- could no longer drive). It is resolved with the part lists (r2_scan):
--   rover     every wheel, landing gear too, drives and steers (drive_tick);
--             a folded gear is no wheel until it comes down (r2Stowed)
--   aircraft  every wheel, a rover wheel too, is the plane's gear: free-rolling
--             (w.rs = 0), brakes, the nose steering with the rudder, the stick
--             flying (R2.gear)
--   rocket    the wheels only roll and brake, and the stick turns the craft
--             (R2.passive)
-- The player's choice is on the command parts' records (`ctrl`, which the
-- fleet save, a staging and a docking carry) and wins; with none, Auto reads
-- the whole craft (craft_mode.autoOf). Until the library node answers (it is
-- spawned on first use) the tyres wait (wheels_wanted "mode").
CTRL = { lib = nil, asked = false, t = -100, cap = nil }
function craftModeLib()
  local L = CTRL.lib
  if L and L.valid ~= false and type(L.resolve) == "function" then return L end
  L = findScript and findScript("craft_mode") or nil
  -- (a just-spawned CraftModeLib is found a frame before its chunk has run)
  if L and type(L.resolve) ~= "function" then return nil end
  if not L and not CTRL.asked and spawn then
    CTRL.asked = true
    pcall(spawn, "CraftModeLib", vec3(0, 0, 0))
  end
  CTRL.lib = L
  return L
end

-- The mode this craft flies by: R2.mode, R2.ctrlSet (the player's, nil =
-- Auto), R2.ctrlAuto and why, and the flags the wheel code reads.
function r2ResolveMode()
  local L = craftModeLib()
  local prev = R2.mode
  if not L then
    R2.modeWait = true
    return
  end
  R2.modeWait = nil
  local dead = {}
  for u in pairs(bp_by_uid) do
    if integ.gone[u] or (part_hp[u] or 1) <= 0 then dead[u] = true end
  end
  local mode, set, auto, why = L.resolve(bp_by_uid, pod_uid, dead)
  -- (a blueprint whose command parts don't carry it: the builder's own)
  if not set and bp and L.normalize(bp.ctrl) then set = L.normalize(bp.ctrl); mode = set end
  R2.mode, R2.ctrlSet, R2.ctrlAuto, R2.ctrlWhy = mode, set, auto, why
  R2.gear = mode == "aircraft"
  R2.passive = mode == "rocket"
  if prev ~= nil and prev ~= mode then CTRL.t = time end
  if prev ~= mode then log(string.format("control mode: %s (%s; auto %s: %s)", mode, set and "chosen" or "auto", tostring(auto), tostring(why))) end
end

-- Published (HUD, context menu, probes): { mode, set, auto, why, label, t }.
function ctrlModeInfo()
  local L = craftModeLib()
  local label = L and L.describe and L.describe(R2.ctrlSet, R2.ctrlAuto or R2.mode) or tostring(R2.mode)
  return { mode = R2.mode, set = R2.ctrlSet, auto = R2.ctrlAuto, why = R2.ctrlWhy, label = label, t = CTRL.t }
end

-- The player's choice ("rover" | "aircraft" | "rocket"; "auto" or nil hands
-- it back to Auto): written on every command part aboard and on the
-- blueprint, so it flies, saves and docks with them. The wheels are re-read
-- at once (the tyres come in and go out again the new way).
function setCtrlMode(m)
  local L = craftModeLib()
  m = L and L.normalize(m) or ((m == "rover" or m == "aircraft" or m == "rocket") and m or nil)
  for u, d in pairs(bp_by_uid) do
    if L and L.isCommand(d) and not integ.gone[u] then d.ctrl = m end
  end
  if bp then bp.ctrl = m end
  R2.gen = -1
  CTRL.t = time
  log("control mode set: " .. tostring(m or "auto"))
  return true
end

-- A landing gear folded away (G): no wheel at all until it comes down.
function r2Stowed(w) return w.gear == true and gearIsUp(w.uid) end
-- Which gear are folded, as one string (a change re-lays the tyres).
function r2StowSig()
  local s = ""
  for _, w in ipairs(R2.wheels) do if w.gear then s = s .. (gearIsUp(w.uid) and "1" or "0") end end
  return s
end
-- Every wheel folded away (or none to fold out).
function r2AllStowed()
  for _, w in ipairs(R2.wheels) do if not r2Stowed(w) then return false end end
  return true
end
-- The steering plan over the wheels that are down: a folded gear neither
-- steers nor sets the line the turn pivots on (a rover with its nose gear
-- folded steers on its front wheels, as it would without it).
function r2Replan()
  local list = {}
  for _, w in ipairs(R2.wheels) do
    if r2Stowed(w) then w.steers, w.a, w.l = false, w.a or 0, w.l or 0 else list[#list + 1] = w end
  end
  r2SteerPlan(list, R2.fwd, bp_by_uid, integ.gone)
end

-- ── the part lists ──────────────────────────────────────────────────────────
-- Rebuilt whenever the craft's part set changes (integ.gen). Every part node
-- is resolved to its uid here, BEFORE anything moves: later lookups go by
-- entity id.
local function r2_scan(node)
  local E = elib()
  R2.gen = integ.gen
  R2.wheels, R2.robo, R2.chain, R2.claws, R2.drills, R2.fairings = {}, {}, {}, {}, {}, {}
  for _, ch in ipairs(node:children()) do
    local nm = ch.name or ""
    if nm:sub(1, 4) == "Part" then
      local u = uid_of_node(ch)
      if u and not R2.node[u] then R2.node[u] = ch end
    end
  end
  if not E then return end
  E = elecFns(E)   -- (one pass: each part's modules looked up once)
  -- The craft's FRONT, as the vessel frame sees it (level, in its X–Z plane):
  -- a rover body's or a command seat's +X; else the command part's +X; else
  -- the vessel's +X. W drives this way. (R2.front is the old ±X sign, kept
  -- for the readers that still use it.)
  r2ResolveMode()
  R2.fwd = r2FrontOf(bp_by_uid, integ.gone, pod_uid, r2_basis)
  R2.fwdWhy = "seat or command part"
  -- a bike's front is its FORK (and a swing arm's other end), whichever way
  -- the saddle was put on (r2MotoFront)
  local mf, nfork = r2MotoFront(E)
  if mf then
    R2.fwd, R2.fwdWhy = mf, "fork / swing arm"
    -- …a swing arm alone only says which LINE the bike runs on; which end
    -- is the front is then the rider's: the seat the crew sits in (or the
    -- craft's seat), when it faces along that line (playtest 2026-10-27:
    -- "put the seat facing forwards"). A fork always leads: the bars must
    -- be at the front, or the balance (motoBike) steers out of the lean.
    local sf = r2SeatFront()
    if sf then
      local dd = sf.x * mf.x + sf.z * mf.z
      if dd < -0.7 and (nfork or 0) == 0 then
        mf = { x = -mf.x, z = -mf.z }
        R2.fwd, R2.fwdWhy = mf, "the seat (along the swing arm's line)"
      elseif dd < -0.7 then
        log("moto: the seat faces the swing arm, not the fork: the fork's end is the front")
      end
    end
  end
  -- a craft flown nose-first (a plane): its front is the nose — a cockpit's,
  -- an Aircraft's, or a tilted command part's when nothing else says where
  -- the front is (a rover's probe core lying on its side is not a nose)
  if AERO.gen ~= integ.gen then aeroScan() end
  local an = AERO.frame and AERO.frame.n
  local pd = pod_uid and bp_by_uid[pod_uid]
  if an and math.sqrt(an.x * an.x + an.z * an.z) > 0.5
    and (R2.mode == "aircraft" or afHas(pd, "cockpit") or not (mf or r2HasFrontPart(bp_by_uid, integ.gone))) then
    local l = math.sqrt(an.x * an.x + an.z * an.z)
    R2.fwd, R2.fwdWhy = { x = an.x / l, z = an.z / l }, "nose"
  else
    -- …and a front the wheels can't roll along (a seat put on sideways) is
    -- turned to the line they roll on (r2RollFront)
    local rf = r2RollFront(E, R2.fwd, mf)
    if rf then R2.fwd, R2.fwdWhy = rf, "the wheels' rolling line" end
  end
  R2.front = (math.abs(R2.fwd.x) >= math.abs(R2.fwd.z) and R2.fwd.x < 0) and -1 or 1
  local depth = {}
  local function depth_of(u)
    if depth[u] then return depth[u] end
    local n, cur, guard = 0, u, 0
    while bp_by_uid[cur] and (bp_by_uid[cur].parent or 0) ~= 0 and guard < 64 do
      cur = bp_by_uid[cur].parent
      n, guard = n + 1, guard + 1
    end
    depth[u] = n
    return n
  end
  for u, d in pairs(bp_by_uid) do
    if not integ.gone[u] and (part_hp[u] or 1) > 0 then
      local X, Y, Z = r2_basis(d.yaw, d.pitch, d.roll)
      R2.rest[u] = { x = d.x, y = d.y, z = d.z, X = X, Y = Y, Z = Z, yaw = d.yaw or 0, pitch = d.pitch or 0, roll = d.roll or 0 }
      local dm = E.modOf(d, "drive")
      if dm then
        local r = dm.r or 0.4
        local w = { uid = u, d = d, m = dm, r = r, size = d.wheel or "M" }
        -- the tyre's centre: out along the part's +X (its axle) from the part centre
        local half = (d.rx or 0.2)
        local tyre_w = ({ S = 0.18, M = 0.26, L = 0.38 })[w.size] or 0.26
        w.tx = half - tyre_w / 2
        -- a MOTO WHEEL (`centred`): the tyre sits on the part's own centre, its
        -- axle running through to both ends (docs/auto-engineering.md)
        if dm.centred then w.tx = 0 end
        w.cx, w.cy, w.cz = d.x + X[1] * w.tx, d.y + X[2] * w.tx, d.z + X[3] * w.tx
        w.axle = X
        if afHas(d, "gear") then
          -- A LANDING GEAR: the tyre at the foot of the leg (+X), its axle the
          -- part's Z. How it rolls is the craft's mode's (a rover drives it).
          w.gear = true
          w.tx = (d.rx or 0.5) - r
          w.cx, w.cy, w.cz = d.x + X[1] * w.tx, d.y + X[2] * w.tx, d.z + X[3] * w.tx
          w.axle = Z
        end
        w.side = (w.cz >= 0) and 1 or -1
        r2WheelSetup(w, R2.fwd)
        -- an aircraft's or a rocket's wheels roll free: no motor pushes them
        -- (a rover's, landing gear too, drive)
        if R2.gear or R2.passive then w.rs = 0 end
        R2.wheels[#R2.wheels + 1] = w
      end
      for _, kind in ipairs({ "hinge", "piston", "rotor" }) do
        local m = E.modOf(d, kind)
        if m then R2.robo[#R2.robo + 1] = { uid = u, d = d, m = m, kind = kind, depth = depth_of(u) } end
      end
      if E.modOf(d, "claw") then
        R2.clawState = R2.clawState or {}
        local c = R2.clawState[u] or { uid = u }
        c.d, c.m = d, E.modOf(d, "claw")
        R2.clawState[u] = c
        R2.claws[#R2.claws + 1] = c
      end
      if E.modOf(d, "drill") then
        local old = R2.drillState and R2.drillState[u]
        local dr = old or { uid = u, lower = 0, prog = 0 }
        dr.d, dr.m = d, E.modOf(d, "drill")
        R2.drills[#R2.drills + 1] = dr
        R2.drillState = R2.drillState or {}
        R2.drillState[u] = dr
      end
      if (d.fairing or 0) > 0 and (d.fr or 0) > 0 then R2.fairings[#R2.fairings + 1] = { uid = u, d = d } end
    end
  end
  table.sort(R2.robo, function(a, b) if a.depth ~= b.depth then return a.depth < b.depth end return a.uid < b.uid end)
  table.sort(R2.wheels, function(a, b) return a.uid < b.uid end)
  R2.hasGear = false
  for _, w in ipairs(R2.wheels) do if w.gear then R2.hasGear = true end end
  motoScan()     -- suspension parts, the moto wheel, gyros (auto-engineering)
  r2Replan()
  motoPlan()     -- …and whether it is a two-wheeler
  -- Each robotic part's MOVING SET: the side of it away from the command
  -- part, by the attachment tree; and which of its halves carries that side.
  for _, r in ipairs(R2.robo) do
    local set = axial_departing(r.uid)
    local inverted = set[r.uid] == nil
    local mv = {}
    for u in pairs(set) do if u ~= r.uid and not integ.gone[u] then mv[u] = true end end
    r.set = mv
    -- head side (+Y of the part) or base side?
    local d = r.d
    local head = true
    if inverted then
      head = (d.att or "") == "bottom"      -- hung under its parent: the parent is at its top
    else
      local up, dn = 0, 0
      for _, k in ipairs(bp_kids[r.uid] or {}) do
        local q = bp_by_uid[k]
        if q then
          if q.att == "top" then up = up + 1
          elseif q.att == "bottom" then dn = dn + 1
          else
            local Y = R2.rest[r.uid].Y
            local h = (q.x - d.x) * Y[1] + (q.y - d.y) * Y[2] + (q.z - d.z) * Y[3]
            if h >= 0 then up = up + 1 else dn = dn + 1 end
          end
        end
      end
      head = up >= dn
    end
    r.head = head
    r.sign = head and 1 or -1
    local st = E.stateOf(d)
    r.cur = st.cur or 0
  end
  -- Per part, the robotic parts that move it, innermost (nearest the part) first.
  for _, r in ipairs(R2.robo) do
    for u in pairs(r.set) do
      local c = R2.chain[u]
      if not c then c = {}; R2.chain[u] = c end
      table.insert(c, 1, r)    -- R2.robo is pod-out: later = nearer the part
    end
  end
  -- wheels on a moving robotic part ride rigid (their mount moves)
  for _, w in ipairs(R2.wheels) do w.onRobo = R2.chain[w.uid] ~= nil end
  R2.posed = false
end

-- ── kinematic robotics ──────────────────────────────────────────────────────

-- A robotic part's motion as a function of a rest-frame point and basis.
local function robo_apply(r, p, B)
  local rest = R2.rest[r.uid]
  if r.kind == "piston" then
    local e = r.cur * r.sign
    local a = rest.Y
    return { p[1] + a[1] * e, p[2] + a[2] * e, p[3] + a[3] * e }, B
  end
  local axis = (r.kind == "hinge") and rest.Z or rest.Y
  local ang = math.rad(r.cur) * r.sign
  local q = { rest.x, rest.y, rest.z }
  local v = r2_rot({ p[1] - q[1], p[2] - q[2], p[3] - q[3] }, axis, ang)
  local nb = B and { r2_rot(B[1], axis, ang), r2_rot(B[2], axis, ang), r2_rot(B[3], axis, ang) } or nil
  return { q[1] + v[1], q[2] + v[2], q[3] + v[3] }, nb
end

-- Where part `u` is now: its rest pose through every robotic part moving it.
local function robo_pose(u)
  local rest = R2.rest[u]
  if not rest then return nil end
  local p = { rest.x, rest.y, rest.z }
  local B = { rest.X, rest.Y, rest.Z }
  for _, r in ipairs(R2.chain[u] or {}) do p, B = robo_apply(r, p, B) end
  return p, B
end

-- Write the moved poses onto the live nodes, then re-pose the compound's
-- shapes and have it re-weigh (the centre of mass moved with the arm).
local function robo_write(node)
  local moved = false
  for u, ch in pairs(R2.chain) do
    local n = r2NodeOf(node, u)
    if n and not integ.gone[u] then
      local p, B = robo_pose(u)
      if p then
        n.x, n.y, n.z = p[1], p[2], p[3]
        n:setAngles(r2_euler(B[1], B[2], B[3]))
        moved = true
      end
    end
  end
  -- the parts' own moving halves (Head / Base, a piston's Stage)
  for _, r in ipairs(R2.robo) do
    local n = r2NodeOf(node, r.uid)
    if n and not integ.gone[r.uid] then
      local mv = child_named(n, r.head and "Head" or "Base")
      local pose = r.pose0
      if not pose and mv then
        pose = {}
        for _, nm in ipairs({ "Head", "Base", "Stage" }) do
          local c = child_named(n, nm)
          if c then pose[nm] = { x = c.x, y = c.y, z = c.z } end
        end
        r.pose0 = pose
      end
      if mv and pose then
        local p0 = pose[mv.name]
        if r.kind == "piston" then
          local e = r.cur * r.sign
          mv.y = p0.y + e
          local stg = child_named(n, "Stage")
          if stg and pose.Stage then stg.y = pose.Stage.y + e * 0.5 end
        else
          local ang = math.rad(r.cur) * r.sign
          if r.kind == "hinge" then
            local c, s = math.cos(ang), math.sin(ang)
            mv.x, mv.y = p0.x * c - p0.y * s, p0.x * s + p0.y * c
            mv:setAngles(0, 0, ang)
          else
            local c, s = math.cos(ang), math.sin(ang)
            mv.x, mv.z = p0.x * c + p0.z * s, -p0.x * s + p0.z * c
            mv:setAngles(ang, 0, 0)
          end
        end
      end
    end
  end
  if moved then
    assembly.syncColliders(node)
    -- re-derive mass, centre of mass and inertia (floptle/0406): nudge one
    -- part's mass by a hair and back on the next sync
    local any = R2.robo[1] and r2NodeOf(node, R2.robo[1].uid)
    local rb = any and any:getcomponent("RigidBody")
    if rb then
      R2.nudge = not R2.nudge
      rb.mass = math.max(0.001, (rb.mass or 0.05) + (R2.nudge and 1e-5 or -1e-5))
    end
  end
end

-- The gravity torque (about a hinge's or rotor's axis) or force (along a
-- piston) the moving set puts on the motor, vessel frame: what it has to
-- beat to move the load AGAINST gravity.
local function robo_load(node, info, r)
  if not space.gravity then return 0 end
  local cm = info.com or info.origin
  local gx, gy, gz = space.gravity(cm.x, cm.y, cm.z)
  if not gx then return 0 end
  local rx, up, rz = basis(node)
  local g = { gx * rx.x + gy * rx.y + gz * rx.z, gx * up.x + gy * up.y + gz * up.z, gx * rz.x + gy * rz.y + gz * rz.z }
  local rest = R2.rest[r.uid]
  local q, B = robo_pose(r.uid)
  if not q then q, B = { rest.x, rest.y, rest.z }, { rest.X, rest.Y, rest.Z } end
  local total = 0
  if r.kind == "piston" then
    local a = B[2]
    for u in pairs(r.set) do
      local d = bp_by_uid[u]
      if d then total = total + ((d.mass or 0) + tankFuelT(u)) * (g[1] * a[1] + g[2] * a[2] + g[3] * a[3]) end
    end
    return total * r.sign
  end
  local a = (r.kind == "hinge") and B[3] or B[2]
  for u in pairs(r.set) do
    local d = bp_by_uid[u]
    local p = d and robo_pose(u)
    if p then
      local m = (d.mass or 0) + tankFuelT(u)
      local vx, vy, vz = p[1] - q[1], p[2] - q[2], p[3] - q[3]
      -- (v × m g) · a
      local tx = vy * g[3] - vz * g[2]
      local ty = vz * g[1] - vx * g[3]
      local tz = vx * g[2] - vy * g[1]
      total = total + m * (tx * a[1] + ty * a[2] + tz * a[3])
    end
  end
  return total * r.sign
end

local function robo_tick(node, info, dt)
  local E = elib()
  if not E or #R2.robo == 0 then return end
  local changed = not R2.posed
  for _, r in ipairs(R2.robo) do
    local d = r.d
    local st = E.stateOf(d)
    local served = (elec.served and elec.served["r" .. r.uid]) or 1
    local want, rate = r.cur, 0
    local spd = math.max(0.1, (st.speed or 100) / 100)
    -- the setpoint inside the joint's own travel (whoever wrote it)
    if r.kind == "hinge" then
      st.angle = math.max(-90, math.min(90, st.angle or 0))
      want, rate = st.angle, (r.m.rate or 30) * spd
    elseif r.kind == "piston" then
      st.extension = math.max(0, math.min(0.8, st.extension or 0))
      want, rate = st.extension, (r.m.rate or 0.3) * spd
    end
    local moving = false
    r.stalled = false
    if not st.locked and served > 0.5 then
      if r.kind == "rotor" then
        if st.spin then
          local w = (st.rpm or 0) * 6.0        -- deg/s
          if math.abs(w) > 0.01 then
            r.cur = (r.cur + w * dt) % 360
            moving = true
          end
        end
      elseif math.abs(want - r.cur) > 1e-4 then
        local step = math.min(math.abs(want - r.cur), rate * dt)
        local dir = (want > r.cur) and 1 or -1
        -- the motor against the load: a hinge that cannot lift what it
        -- carries stalls (it never lets go — it holds)
        local load = robo_load(node, info, r)
        local cap = (r.kind == "piston") and (r.m.force or 8) or (r.m.torque or 3)
        -- `load` > 0: gravity pulls the setpoint UP (it helps a move up);
        -- a move against it needs the motor to beat it
        if dir * load >= 0 or math.abs(load) < cap then
          r.cur = r.cur + dir * step
          moving = true
        else
          r.stalled = true
        end
      end
    end
    if moving then changed = true end
    R2.draw["r" .. r.uid] = (r.m.draw or 0.5) * (moving and 1.0 or 0.05)
    st.cur = r.cur
  end
  if changed then
    robo_write(node)
    R2.posed = true
  end
end

-- ── wheels ──────────────────────────────────────────────────────────────────

-- Vessel-frame point → world, from the physics-fresh base.
local function v2w(node, info, x, y, z)
  local rx, up, rz = basis(node)
  local bx, by, bz = base_of(node, info)
  return bx + rx.x * x + up.x * y + rz.x * z, by + rx.y * x + up.y * y + rz.y * z, bz + rx.z * x + up.z * y + rz.z * z
end

-- The part's own collider: the whole wheel (rigid), or a stub in the bracket
-- (live: the tyre body carries the craft).
local function wheel_collider(node, w, live)
  local n = r2NodeOf(node, w.uid)
  local rb = n and n:getcomponent("RigidBody")
  if not rb then return end
  if live or (w.gear and gearIsUp(w.uid)) then
    rb.half_x, rb.half_y, rb.half_z = 0.05, 0.05, 0.05
  else
    -- a hair short of the tyre: a rover going rigid on its suspension
    -- settles a few centimetres onto its wheel boxes instead of finding them
    -- buried in the ground (a depenetration kick the damage model reads as a
    -- crash)
    -- (a two-wheeler's moto wheels stand it up: motoStand)
    local hx = w.d.rx or 0.2
    if R2.bike and w.m and w.m.centred then hx = math.max(hx, BIKE_STAND) end
    rb.half_x, rb.half_y, rb.half_z = hx, w.r - 0.04, w.r - 0.04
  end
  local t = child_named(n, "Tyre")
  if t then t.visible = not live end
end

-- THE STAND. A two-wheeler nobody is riding (its tyres in: unpiloted, warped,
-- parked) stood on two boxes as narrow as its tyres and fell over (playtest
-- 2026-10-26; motoprobe). Its moto wheels' boxes are then BIKE_STAND across
-- the axle, the footprint a centre stand gives it: it tips only past ~25°.
-- Out on its live tyres again, the rider's feet or a gyro hold it.
-- THE RIDER'S CAPSULE (playtest 2026-10-26: "motorcycles … hardly get any
-- torque and [can't] climb hills … sometimes it drives better backwards").
-- A rider in an open seat is parked in it as the astronaut's kinematic
-- capsule, 2 m tall and 0.33 m round, and on a saddle that reaches down
-- through the frame and both tyres. physics.ignorePair (command_seat) does
-- not stop a kinematic body's contacts on 0.117.0-rc38, so the capsule —
-- re-placed every tick and frame on a planet moving metres a tick — shoved
-- the bike: a parked bike rolled off at up to 1.8 m/s², and under full drive
-- it crawled at 0.4–0.7 m/s or went backwards (motoprobe bikelab, `tinyrider`
-- A/B: 0.4 m/s → 15.6 m/s). While anyone rides a SEAT (a saddle, the Command
-- Seat) the capsule is shrunk to a point (RIDER_R), and given back the moment
-- they are off it. (Engine card: ignorePair and kinematic contacts.)
RIDER_R = 0.01
function motoRiderShape(node)
  local a = astronaut
  if not (a and a.valid) then a = find("Astronaut") end
  local getc = a and (a.getComponent or a.getcomponent)
  local rb = getc and getc(a, "RigidBody")
  if not rb then return end
  local d = pod_uid and bp_by_uid[pod_uid]
  local seat = d and ((d.seat or 0) == 1 or d.seat == true)
  local on = crewAboard == true and seat and not destroyed
  if on and not R2.riderShape then
    -- (never remember a point as the size to give back: another craft's
    -- seat may have shrunk it already — the walker's own size then)
    local big = (rb.radius or 0) > RIDER_R * 1.5
    R2.riderShape = { r = big and rb.radius or 0.33, h = big and rb.height or 2.0, id = a.id }
    rb.radius, rb.height = RIDER_R, 2 * RIDER_R
  elseif not on and R2.riderShape then
    local k = R2.riderShape
    R2.riderShape = nil
    if a.id == k.id then rb.radius, rb.height = k.r or 0.33, k.h or 2.0 end
  elseif on and (rb.radius or 0) > RIDER_R * 1.5 then
    -- (something put it back while they still ride: shrink it again)
    rb.radius, rb.height = RIDER_R, 2 * RIDER_R
  end
end

BIKE_STAND = 0.30
function motoStand(node)
  if R2.live or not R2.bike or not (node and node.valid) then return end
  local any = false
  for _, w in ipairs(R2.wheels) do
    if w.m and w.m.centred then wheel_collider(node, w, false); any = true end
  end
  if any then assembly.rebuild(node) end
end

-- Should the tyres be out? The active bubble only: piloted, at 1× warp, not
-- clamped, the craft assembled, on or just over the ground, not too fast.
local function wheels_wanted(node, info)
  if #R2.wheels == 0 or destroyed or not piloting then return false, "unpiloted" end
  if info.anchored then return false, "clamped" end
  -- (on the ground they stay out through a warp: the engine counts the craft
  -- grounded through them, floptle/0483; in the air a warp coasts the chassis
  -- and the tyres apart, so they come in)
  if space.warp() > 1.001 and not info.grounded then return false, "warp" end
  if R2.holdoff > 0 then return false, "holdoff" end
  if not assembly_ready(info) or integ.push then return false, "assembling" end
  if R2.modeWait then return false, "mode" end
  if R2.autoWait then return false, "auto" end
  -- (folded landing gear is no wheel: with every wheel folded there is
  -- nothing to put down; with some, the rest roll — r2Tick re-lays them)
  if r2AllStowed() then return false, "gear up" end
  local v = info.vel
  if math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) > (R2.gear and R2_GEAR_VMAX or R2_TYRES_VMAX) then return false, "fast" end
  -- Landing gear is the pilot's (G): lowered, it stays out in the air. Folding
  -- it after 2.5 s aloft and putting it back near the ground made a plane
  -- climbing out at 2-3 m flip its gear every tick, rebuilding the craft until
  -- the nose dropped into the runway.
  if R2.gear then return true end
  if R2.live then
    -- out: they stay out while any tyre is on the ground, and for a couple
    -- of seconds of air (a bump, a hop) before they fold back into the hull
    for _, w in ipairs(R2.wheels) do
      if w.tyre and w.tyre.valid and w.tyre.grounded then R2.air_t = time return true end
    end
    if info.grounded then R2.air_t = time return true end
    return time - (R2.air_t or time) < 2.5, "airborne"
  end
  if info.grounded then return true end
  -- just over the ground: a rover set down by a lander, a hop
  local w = R2.wheels[1]
  local x, y, z = v2w(node, info, w.cx, w.cy, w.cz)
  local _, up = basis(node)
  local h = raycast(x, y, z, -up.x, -up.y, -up.z, w.r + 1.5, node)
  return h ~= nil
end

local function tyres_out(node, info)
  local any = 0
  for _, w in ipairs(R2.wheels) do
    local faired = (w.d.faired or 0) ~= 0 and r2Faired(w.d)
    w.out = false
    if not w.onRobo and not faired and not r2Stowed(w) then
      wheel_collider(node, w, true)
      if w.susp then motoCollider(node, w.susp, true) end
      any = any + 1
      w.want, w.out = true, true
    end
  end
  if any == 0 then return end
  R2.nOut = any
  R2.stow_live = r2StowSig()
  -- The hull drops its wheel boxes now, in fixedUpdate: a rebuild keeps the
  -- assembly's physics pose on a moving planet (floptle/0449, 0.117.0-rc3).
  assembly.rebuild(node)
  damage_arm = math.max(damage_arm, time - 1.5)   -- the swap is not a crash
  R2.hold_t, R2.drive, R2.steer = 0, 0, 0
  R2.live = true
  R2.air_t = time
  -- A fresh body lands where it was placed on a moving planet (floptle/0449),
  -- so each tyre is let go and hung on its joint the moment it exists. (It
  -- must not stay kinematic, as the prefab has it: a script-owned kinematic
  -- body is not carried with its planet and is left a carry behind.)
  local rx, up, rz = basis(node)
  local yaw, pitch, roll = r2_euler({ rx.x, rx.y, rx.z }, { up.x, up.y, up.z }, { rz.x, rz.y, rz.z })
  for _, w in ipairs(R2.wheels) do
    if w.want then
      w.want = nil
      local x, y, z = v2w(node, info, w.cx, w.cy, w.cz)
      -- a tyre on a suspension part comes out where the ground has it, not
      -- 4 cm into it under the rigid wheel box: a soft spring on a light tyre
      -- turned that overlap into a kick (a parked bike thrown to 4 m/s)
      if w.susp then x, y, z = x + up.x * 0.04, y + up.y * 0.04, z + up.z * 0.04 end
      spawn("WheelTyre" .. (w.size or "M"), vec3(x, y, z), function(t)
        if not R2.live or not (node and node.valid) then destroy(t) return end
        t:setAngles(yaw, pitch, roll)
        w.tyre = t
        -- its own mesh, looked up now (r2TyreVisuals: never a handle kept
        -- from the tyre before it)
        w.mesh, w.mesh_of = child_named(t, "TyreMesh"), t.id
        w.jointed = false
        hang_tyre(node, w, assembly.info(node))
      end)
    end
  end
  log(string.format("rover: %d wheel(s) on the ground", #R2.wheels))
end

local function tyres_in(node)
  if not R2.live then return end
  R2.live = false
  -- The tyres go and the hull takes its wheel boxes back in one go: a jointed
  -- body destroyed in the frame its chassis is rebuilt is fine since
  -- 0.117.0-rc3 (floptle/0420).
  for _, w in ipairs(R2.wheels) do
    if w.tyre and w.tyre.valid then destroy(w.tyre) end
    w.tyre, w.jointed, w.mesh, w.mesh_of, w.out = nil, false, nil, nil, false
    wheel_collider(node, w, false)
    if w.susp then motoCollider(node, w.susp, false) end
  end
  if node and node.valid then assembly.rebuild(node) end
  damage_arm = math.max(damage_arm, time - 1.5)   -- the swap is not a crash
  R2.driving = false
  R2.hold_t = 0
  R2.bikeT0, R2.leanTs = nil, nil
end

-- Hang one tyre on its wheel joint, dynamic, at the mount it was spawned on.
function hang_tyre(node, w, info)
  local t = w.tyre
  if not (t and t.valid and info) or w.jointed then return end
  local m = w.m
  -- THE SPRING. The joint's stiffness is a frequency on the joint's
  -- effective mass — the light tyre's, not the hull's — so it is sized
  -- here from what each wheel carries under this craft on this world.
  -- The tyre, hub and motor are most of a powered wheel's mass (60 %; the
  -- bracket keeps the rest, massSync): a tyre feather-light against the
  -- hull it carries spins on a slope instead of gripping.
  local mt = math.max(0.005, (w.d.mass or 0.12) * TYRE_SHARE)
  local g = 7.0
  if space.gravity then
    local gx, gy, gz = space.gravity(info.com.x, info.com.y, info.com.z)
    if gx then g = math.sqrt(gx * gx + gy * gy + gz * gz) end
  end
  local load = (info.mass or 1) * g / math.max(1, R2.nOut or #R2.wheels)
  -- A TYRE NO LIGHTER THAN R2_TYRE_RATIO OF WHAT IT CARRIES (playtest
  -- 2026-10-26: a jet's gear "fighting … makes the aircraft jump around").
  -- The joint's spring works on the tyre's mass, and no setting makes it
  -- stiffer than about that mass per tick squared: a 21 kg nose tyre under a
  -- 3 t jet ran at the 45 Hz cap, all but rigid each tick, 150:1 against its
  -- load — the light-tyre chatter of card 0562 — and threw the jet up off
  -- the runway as it rotated. The stock rover's tyres sit near 1:2.5 and a
  -- bike's 1:4.5; a heavy aircraft's gear is brought to 1:R2_TYRE_RATIO (its
  -- leg keeps the rest of its part's mass, so the craft weighs a few % more
  -- on its wheels).
  mt = math.max(mt, load / math.max(g, 0.1) / R2_TYRE_RATIO)
  -- (sized for 1 cm in this simple model; the joint's soft step gives
  -- about three times that, and a heavy end a little more)
  local sag = 0.01 * w.r / 0.4
  local f = math.sqrt(load / (sag * mt)) / (2 * math.pi)
  f = math.max(4.0, math.min(45.0, f))
  -- the wheel's own settings (wcfg): a stiffer or softer spring (stiffness
  -- goes as the frequency squared), its damping and its grip
  local c = w.cfg or r2WheelCfg(w.d)
  f = f * math.sqrt(c.spring or 1)
  local rb = t:getcomponent("RigidBody")
  if rb then rb.kinematic = 0; rb.mass = mt; rb.friction = R2_TYRE_MU * (c.friction or 1) end
  -- The mount is named (otherAnchor, hull space), not left at "where the
  -- tyre stands now": the engine re-derives an unnamed anchor every time any
  -- joint or compound in the scene changes, which bakes whatever sag the
  -- tyre has at that moment into its rest (0.117.0-rc3; tyres ended up to
  -- 0.4 m up their mounts).
  -- ON A SUSPENSION PART (a fork, a swing arm, a strut): its own spring and
  -- damper, along its own axis (motoSpring)
  local axis, damp = vec3(0, 1, 0), 0.7 * (c.damper or 1)
  if w.susp and w.susp.axis and AUTO.lib then f, damp, axis = motoSpring(w, info, mt, g, c) end
  t:setJoint{ kind = "wheel", to = node, axis = axis, otherAnchor = vec3(w.cx, w.cy, w.cz),
              stiffness = f, damping = damp, motorSpeed = 0, maxForce = (m.torque or 0.6),
              steer = w.steer0 or 0 }
  w.jointed = true
  w.joint_age = 0   -- seconds of ticks since it was hung, counted in drive_tick
end

-- THE TYRES AS DRAWN. The live tyre is a ball to the physics, held to spin
-- about its axle only; it is not turned when the axle steers, so its mesh
-- would keep facing straight ahead. Each frame the mesh is laid along the
-- engine's axle (base steer + steering) and turned by the distance rolled.
-- THE MESH HANDLE IS THE CURRENT TYRE'S (playtest 2026-10-26: "wheels often
-- face the wrong direction when getting off and back on"). A script's node
-- handle is the engine's bare slot number, and a destroyed node's slot is
-- handed to the next node spawned, so the TyreMesh handle kept from the tyre
-- before a get-off/get-on read `valid` again and pointed at ANOTHER new node:
-- this wheel's mesh was laid on some other node, and its own was never laid
-- at all and turned with its ball (probe: up to 50° of yaw while turning; the
-- player saw a rear wheel square across). So the handle is dropped with its
-- tyre (tyres_in), taken fresh with the new one, and checked against it.
function r2TyreVisuals(node, dt)
  if not (R2.live and node and node.valid) then return end
  local rx, up, rz = basis(node)
  local info = assembly.info(node)
  local v = info and info.vel or { x = 0, y = 0, z = 0 }
  for _, w in ipairs(R2.wheels) do
    local t = w.tyre
    if t and t.valid then
      if not (w.mesh and w.mesh.valid and w.mesh_of == t.id) then w.mesh, w.mesh_of = child_named(t, "TyreMesh"), t.id end
      local mnode = w.mesh
      if mnode then
        local s = math.rad((w.steer0 or 0) + R2_STEER_SIGN * (w.steerNow or 0))
        local sx, sz = math.sin(s), math.cos(s)
        local Dx, Dy, Dz = rx.x * sx + rz.x * sz, rx.y * sx + rz.y * sz, rx.z * sx + rz.z * sz
        -- roll: a positive spin about D carries the wheel along (−cos s, 0, sin s)
        local qx, qy, qz = -rx.x * sz + rz.x * sx, -rx.y * sz + rz.y * sx, -rx.z * sz + rz.z * sx
        local roll = (v.x * qx + v.y * qy + v.z * qz) / math.max(0.05, w.r or 0.4)
        w.spin = ((w.spin or 0) + roll * dt) % (2 * math.pi)
        local c, sn = math.cos(w.spin), math.sin(w.spin)
        -- the hull's up, turned by the spin about the axle
        local cxx, cxy, cxz = Dy * up.z - Dz * up.y, Dz * up.x - Dx * up.z, Dx * up.y - Dy * up.x
        local Yx, Yy, Yz = up.x * c + cxx * sn, up.y * c + cxy * sn, up.z * c + cxz * sn
        -- forward (−Z) = Y × X, with the mesh's X along the axle
        local Fx, Fy, Fz = Yy * Dz - Yz * Dy, Yz * Dx - Yx * Dz, Yx * Dy - Yy * Dx
        mnode:setUp(vec3(Yx, Yy, Yz), vec3(Fx, Fy, Fz))
      end
    end
  end
end

-- STABILITY ASSIST while driving (SAS on): the reaction wheels damp the
-- rover's pitch and roll RATES — a wheelie, a roll over a ridge — and leave
-- its yaw to the wheels. Rates, not attitude: on a slope it still settles to
-- the ground under it.
function r2Steady(node, info, tk, dt)
  local w = info.angVel
  local _, up = basis(node)
  -- no steering asked: hold the heading too (a wheel that slips on a hill
  -- must not slew the rover across it)
  local yr = (math.abs(R2.steer or 0) > 0.05) and (w.x * up.x + w.y * up.y + w.z * up.z) or 0
  -- ANTI-ROLL: lean the body back level over its own tyres (drive_tick
  -- measures the lean from the suspension, so a sidehill is not fought)
  local ar = R2.antiroll or { x = 0, y = 0, z = 0 }
  local ex, ey, ez = up.x * yr - w.x + ar.x, up.y * yr - w.y + ar.y, up.z * yr - w.z + ar.z
  -- (a two-wheeler's roll is its balance's: motoBike)
  if R2.bike then ex, ey, ez = motoSteadyMask(node, ex, ey, ez) end
  wheelTorque(node, info, ex, ey, ez, tk, dt)
end

-- A ROVER IN THE AIR (playtest 2026-10-26: "as soon as you get any air w is
-- making the craft tilt to the right"). Off its tyres a rover used to fall
-- through to the SHIP's stick, whose pitch axis is the ship's right — and for
-- a rover built round an upright pod that is the rover's FRONT, so W rolled
-- it right at the full 1 rad/s (probe: 84° of roll in 1.9 s of air). Now a
-- rover (driven wheels, not landing gear) that left the ground less than
-- ROVER_AIR_HOLD s ago keeps the rover's keys on the rover's own axes, and
-- they LEAN it, like a rider on a dirt bike, rather than spin it:
--   W / S  nose ROVER_AIR_LEAN down / up from where it left the ground
--   A / D  roof ROVER_AIR_LEAN left / right of where it left the ground
--   Q / E  turn left / right at ROVER_AIR_RATE
-- Off the keys it holds the attitude it took off with (SAS on) or coasts
-- (SAS off). W is held to drive, so it must not pitch the rover over: a rate
-- on the key (the first version) put a held W's rover on its nose (42° down
-- in 1.4 s of air). All of it on the craft's real reaction wheels
-- (elec.torque_k) at ROVER_AIR_TK of their authority, at most
-- ROVER_AIR_RATE. Back on its tyres, the keys drive again (R2.driving).
ROVER_AIR_RATE = 0.6               -- rad/s, the most it turns
ROVER_AIR_LEAN = math.rad(15)      -- the lean a key asks for
ROVER_AIR_GAIN = 2.5               -- rad/s per rad of lean error
ROVER_AIR_TK = 0.5                 -- share of the reaction wheels' authority
ROVER_AIR_HOLD = 8.0               -- s off the ground before the ship's stick takes over

-- Is this craft a rover in the air right now? (R2.ground_t: the last tick on
-- the ground; R2.air0: its pitch and lean as it left it; R2.air_up: the local
-- up this tick.)
function r2AirMode(info)
  if #R2.wheels == 0 or R2.gear or R2.passive then R2.air0 = nil return false end
  if R2.driving or R2.onWheels or (info and (info.grounded or info.anchored)) then
    R2.ground_t, R2.air0 = time, nil
    return false
  end
  if not (R2.ground_t ~= nil and (time - R2.ground_t) < ROVER_AIR_HOLD) then R2.air0 = nil return false end
  local c = info and (info.com or info.origin)
  local U = nil
  if c and space and space.gravity then
    local gx, gy, gz = space.gravity(c.x, c.y, c.z)
    local l = gx and math.sqrt(gx * gx + gy * gy + gz * gz) or 0
    if l > 1e-6 then U = { x = -gx / l, y = -gy / l, z = -gz / l } end
  end
  R2.air_up = U
  return true
end

-- The rover's axes in the world: its front (R2.fwd, level in the vessel
-- frame), its up, and its right = front × up.
function r2AirAxes(F, rx, up, rz)
  local fx, fy, fz = rx.x * F.x + rz.x * F.z, rx.y * F.x + rz.y * F.z, rx.z * F.x + rz.z * F.z
  local l = math.sqrt(fx * fx + fy * fy + fz * fz)
  if l < 1e-6 then fx, fy, fz, l = rx.x, rx.y, rx.z, 1 end
  fx, fy, fz = fx / l, fy / l, fz / l
  local ux, uy, uz = up.x, up.y, up.z
  local gx, gy, gz = fy * uz - fz * uy, fz * ux - fx * uz, fx * uy - fy * ux
  return { x = fx, y = fy, z = fz }, { x = ux, y = uy, z = uz }, { x = gx, y = gy, z = gz }
end

-- The angular velocity the rover's keys ask for (world). k: p = W − S,
-- y = the lean key (+ leans the roof left; the rover hands it Q − E),
-- r = the turn key (+ turns right; the rover hands it D − A). w: the craft's
-- angular velocity now; hold: SAS on. U: the local up (nil: rates only);
-- ref: { th, ph } the pitch and lean it left the ground with (filled in the
-- first time). Pitch th = asin(front·U), + nose up; lean ph = asin(right·U),
-- + roof leaning left. A turn about +right lifts the front; one about +front
-- tips the roof right; one about +up turns the front left.
function r2AirStick(k, rx, up, rz, w, hold, F, U, ref)
  local Fw, Uv, Rt = r2AirAxes(F or R2.fwd or { x = 1, z = 0 }, rx, up, rz)
  local rate = ROVER_AIR_RATE
  local function cur(a) return w.x * a.x + w.y * a.y + w.z * a.z end
  local function clampr(v) return math.max(-rate, math.min(rate, v)) end
  local p, y, r = k.p or 0, k.y or 0, k.r or 0
  local wr, wf
  if U then
    local function asn(v) return math.asin(math.max(-1, math.min(1, v))) end
    local th = asn(Fw.x * U.x + Fw.y * U.y + Fw.z * U.z)
    local ph = asn(Rt.x * U.x + Rt.y * U.y + Rt.z * U.z)
    if ref and not ref.th then ref.th, ref.ph = th, ph end
    local th0, ph0 = ref and ref.th or th, ref and ref.ph or ph
    -- pitch: W leans the nose back (th0 + LEAN), like gassing a dirt bike in
    -- the air, and S forward; off the keys hold th0 (SAS) or coast
    if p ~= 0 or hold then wr = clampr(ROVER_AIR_GAIN * (th0 + p * ROVER_AIR_LEAN - th)) else wr = cur(Rt) end
    if y ~= 0 or hold then wf = clampr(-ROVER_AIR_GAIN * (ph0 + y * ROVER_AIR_LEAN - ph)) else wf = cur(Fw) end
  else
    wr = p ~= 0 and p * rate or (hold and 0 or cur(Rt))
    wf = y ~= 0 and -y * rate or (hold and 0 or cur(Fw))
  end
  local wu = r ~= 0 and -r * rate or (hold and 0 or cur(Uv))
  return Rt.x * wr + Fw.x * wf + Uv.x * wu, Rt.y * wr + Fw.y * wf + Uv.y * wu, Rt.z * wr + Fw.z * wf + Uv.z * wu
end

-- Drive, steer, brake and park, every tick the tyres are out
-- (wheel_spec.md). W/S drive every driven wheel along the craft's front,
-- each by the spin sign its mount gives it; A/D STEER the steerable wheels
-- about their suspension (the joint's `steer`, floptle/0420), Ackermann-style
-- about the line of the wheels that don't steer, and less at speed. Off the
-- stick the wheels roll free; B (the Brakes group) or a stop brakes them.
local function drive_tick(node, info, dt)
  local E = elib()
  local ctl = piloting and elec.control ~= false and not dock.plan
  local dcmd = ctl and ((input.key("w") and 1 or 0) - (input.key("s") and 1 or 0)) or 0
  local scmd = ctl and ((input.key("a") and 1 or 0) - (input.key("d") and 1 or 0)) or 0
  -- A headless run cannot press keys: a probe drives through R2.cmd.
  if ctl and R2.cmd then dcmd, scmd = R2.cmd.drive or 0, R2.cmd.steer or 0 end
  -- AN AIRCRAFT'S WHEELS (landing gear or not): W/S are the elevators, not a
  -- drive; the jets push it. The nose wheel steers with the rudder (A/D), and
  -- the parking brake lets go the moment the throttle opens. A ROCKET'S roll
  -- the same way and don't steer: A/D are the stick's.
  if R2.gear then
    dcmd = (throttle > 0.05) and 1 or 0
    if ctl and AERO.cmd then scmd = AERO.cmd.y or 0 end
  elseif R2.passive then
    dcmd, scmd = (throttle > 0.05) and 1 or 0, 0
  end
  -- the stick eases in and out like a throttle (no wheelspin from a key tap)
  local function ease(cur, want, up, down)
    if want > cur then return math.min(want, cur + up * dt) end
    return math.max(want, cur - down * dt)
  end
  R2.drive = ease(R2.drive, dcmd, 0.8, 3.0)
  R2.steer = ease(R2.steer, scmd, 2.5, 3.0)
  local grounded = 0
  for _, w in ipairs(R2.wheels) do
    if w.jointed and w.tyre and w.tyre.valid and w.tyre.grounded then grounded = grounded + 1 end
  end
  R2.onWheels = grounded > 0
  R2.driving = ctl and grounded > 0 and not R2.gear and not R2.passive
  R2.ctl = ctl
  local v = info.vel
  local spd = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
  R2.speed = spd
  -- top speed and torque for this world: the catalogue rated the motors for
  -- home (builder finishBlueprint); on a lighter world a wheel grips less,
  -- and a rover that turns at speed there rolls — the top speed comes down
  -- with sqrt(g) (the speed a curve of the same radius holds).
  local rxv, upv, rzv = basis(node)
  local gdir = { x = 0, y = 0, z = 0 }
  local gl = R2_G_REF
  if space.gravity then
    local cm = info.com or info.origin
    local gx, gy, gz = space.gravity(cm.x, cm.y, cm.z)
    if gx then gdir = { x = gx, y = gy, z = gz }; gl = math.sqrt(gx * gx + gy * gy + gz * gz) end
  end
  -- the catalogue's rating (motors are rated like thrust, for the home world)
  if not R2.rk then
    local rt = save and save.get and save.get("parts.rating")
    R2.rk = type(rt) == "table" and tonumber(rt.thrust) or 1
  end
  -- PARKING: next to stopped with no drive asked → the wheel brakes hold it
  -- (floptle/0420: a braked wheel holds the spot it stopped on). Above a
  -- walking pace the wheels roll free off the stick; below it the brakes
  -- catch the rover before a hill can get it rolling. Steering alone doesn't
  -- let go of a parked rover.
  -- (not a two-wheeler: a parked wheel holds the spot it stopped on, and a
  -- bike rocking on its feet or gyro tore its light tyres off those spots —
  -- it stands on its rider or gyro and rolls free, B still brakes it)
  if dcmd == 0 and spd < 0.8 and grounded >= math.min(3, #R2.wheels) and not R2.bike then
    R2.hold_t = R2.hold_t + dt
  elseif dcmd ~= 0 or spd > 1.2 then
    R2.hold_t = 0
  end
  -- TRACTION CONTROL: the motors may push the craft no harder than R2_TC g
  -- on the level — more on a hill, by the slope they are climbing — and back
  -- off by half while one axle is off the ground (a wheelie, a crest). A tall
  -- rover with its weight aft tips over backwards long before 1 g. The wheel's
  -- Motor setting (wcfg.motor) scales what it may push with.
  local F = R2.fwd or { x = 1, z = 0 }
  local fx = rxv.x * F.x + rzv.x * F.z
  local fy = rxv.y * F.x + rzv.y * F.z
  local fz = rxv.z * F.x + rzv.z * F.z
  local climb = math.abs(fx * gdir.x + fy * gdir.y + fz * gdir.z)   -- g · sin(slope)
  local front_up, rear_up = 0, 0
  for _, w in ipairs(R2.wheels) do
    if w.tyre and w.tyre.valid and w.tyre.grounded then
      if (w.a or 0) > 0 then front_up = front_up + 1 else rear_up = rear_up + 1 end
    end
  end
  local accel = R2_TC * gl + climb
  -- a two-wheeler pushes no harder than lifts its front wheel (motoPlan)
  if R2.bike and R2.wheelieK then accel = math.min(accel, R2.wheelieK * gl + climb) end
  if (front_up == 0) ~= (rear_up == 0) then accel = accel * 0.5 end
  -- …and what the lead adapts to (below): that push less the slope's share,
  -- the craft's own acceleration along its front
  R2.want_a = math.max(0.05 * gl, accel - climb)
  -- off the stick the lead starts over: a lead wound up for the last run
  -- (or a stop) put a big push into the first tick of the next one, and a
  -- bike set off backwards on its rear tyre hopping and spinning
  if math.abs(R2.drive or 0) < 0.02 then R2.lk = 1.5 end
  -- STALL: driven but barely moving (parked in a dip or a rut, nose against
  -- a bump the chassis slope doesn't see) → after half a second let the
  -- motors work up to their full torque over the next second, so a rover can
  -- always crawl out of where it stopped. Gone the moment it rolls.
  if dcmd ~= 0 and spd < 0.4 then
    R2.stall_t = (R2.stall_t or 0) + dt
  else
    R2.stall_t = 0
  end
  local stall_k = math.max(0, math.min(1, (R2.stall_t - 0.5) / 1.0))
  local n_drive = 0
  for _, w in ipairs(R2.wheels) do if (w.rs or 0) ~= 0 and w.out then n_drive = n_drive + 1 end end
  n_drive = math.max(1, n_drive)
  -- HILL HOLD: off the stick and rolling DOWNHILL → the motors hold back the
  -- slope and a little more, so a rover let go of on a hill slows to a walk
  -- and the parking hold takes it, instead of coasting down it for good (a
  -- 5° slope at 0.7 g rolled a released rover 12.5 m before it stopped).
  -- On the level, and coasting uphill, the wheels still roll free.
  local gmag = math.sqrt(gdir.x * gdir.x + gdir.y * gdir.y + gdir.z * gdir.z)
  local downhill = spd > 0.05 and (v.x * gdir.x + v.y * gdir.y + v.z * gdir.z) / spd or 0  -- g along the motion
  local hill_hold = dcmd == 0 and grounded > 0 and gmag > 0 and downhill > 0.02 * gmag and not R2.bike   -- (a bike: see the parking hold)
  local hill_a = hill_hold and (downhill + 0.15 * gmag) or 0
  -- signed forward speed, for the steering's speed limit
  local vf = v.x * fx + v.y * fy + v.z * fz
  local mu = 1
  for _, w in ipairs(R2.wheels) do if w.cfg and w.cfg.friction then mu = math.min(mu, w.cfg.friction) end end
  local cmds = r2WheelCmd(R2.wheels, R2.plan, R2.drive, R2.steer, math.abs(vf), r2Lateral(gl, R2.plan, mu * R2_TYRE_MU))
  R2.dt = dt
  -- a TWO-WHEELER: the bars and the lean are the balance's (motoBike)
  if R2.bike and not R2.gear and not R2.passive and grounded > 0 then motoBike(node, info, cmds, vf, gl, dt, rxv, upv, rzv, gdir) end
  local power = 0
  local limited, lmot = nil, 1   -- did the traction control hold a wheel back this tick (and which way)
  local smin = 1                  -- the worst-served motor (published: R2.served)
  for k, w in ipairs(R2.wheels) do
    local t = w.tyre
    if w.jointed then w.joint_age = (w.joint_age or 0) + dt end
    local j = w.jointed and (w.joint_age or 0) > 0.05 and t and t.valid and t:getcomponent("Joint")
    if j and w.susp then motoSusp(w, j) end
    if j then
      local c = w.cfg or {}
      local cmd = cmds[k]
      local st = E and E.stateOf(w.d) or {}
      local served = (elec.served and elec.served["d" .. w.uid]) or 1
      smin = math.min(smin, served)
      local m = w.m
      local vmax = r2TopSpeed(w, gl)
      local brakes = st.brakes == true
      j.steer = (w.steer0 or 0) + R2_STEER_SIGN * cmd.steer
      w.steerNow = cmd.steer
      local full = r2FullTorque(w, R2.rk)
      local torque = math.min(full, accel * (info.mass or 1) * w.r / n_drive)
      torque = (torque + (full - torque) * stall_k) * (c.motor or 1)
      local want = cmd.drive          -- −1…1 of this wheel's top speed, signed along the front
      -- THE RIM SPEED IS RATE-LIMITED, not just the torque. On 0.117.0-rc6
      -- the wheel joint's motor cap (maxForce) does not cap the drive: the
      -- tyre's grip pushes the chassis through the mount to match the rim
      -- speed the motor spun the light tyre up to, limited only by friction
      -- (floptle-physics joints.rs tyre_grip; measured 0 → 22 m/s in 2.3 s,
      -- ~1 g, with the traction control asking for 0.55 g). So the speed the
      -- motor turns at leads the craft's own by at most what the traction
      -- control (or the brakes) allow this tick, and the grip can only
      -- deliver that.
      local sk = (math.abs(R2.drive) > 0.02) and (cmd.drive / R2.drive) or 1   -- Ackermann / skid share
      local cur = vf * sk                                                      -- this wheel's ground speed now
      if brakes or R2.hold_t > 0.15 then
        j.motor = 1
        -- at speed the brakes stop it at up to 0.8 g (a hard stop that
        -- doesn't stand it on its nose); at a crawl they hold with all they have
        local bf = full * 2.0 * (c.brake or 1)
        if spd > 1.5 then
          bf = math.min(bf, 0.8 * gl * (info.mass or 1) * w.r / math.max(1, grounded))
          local dv = 0.8 * gl * (c.brake or 1) * dt
          local tgt = cur > 0 and math.max(0, cur - dv) or math.min(0, cur + dv)
          j.motorSpeed = w.rs * tgt / w.r * 57.29578
        else
          j.motorSpeed = 0
        end
        j.maxForce = bf
      elseif hill_hold and w.tyre.grounded then
        j.motor = 1
        j.motorSpeed = 0
        j.maxForce = math.min(full * 2.0 * (c.brake or 1), hill_a * (info.mass or 1) * w.r / grounded)
      elseif (w.rs or 0) == 0 or st.motor == false or served < 0.3 or math.abs(want) < 0.02 then
        -- off the stick (or an undriven wheel): it rolls free
        j.motor = 0
        j.motorSpeed = 0
      else
        j.motor = 1
        -- the traction control's push this tick, as the lead the rim may
        -- run ahead of (or, slowing, behind) the ground speed it has now
        -- (stalled in a rut: up to a further 1 g to crawl out)
        local lead = (accel + stall_k * gl) * (c.motor or 1) * served * dt * (R2.lk or 1.5)
        local tgt = want * vmax
        if math.abs(tgt - cur) > lead then
          limited = (tgt > cur) and 1 or -1
          lmot = math.min(lmot, (c.motor or 1) * served)
        end
        tgt = math.max(cur - lead, math.min(cur + lead, tgt))
        j.motorSpeed = w.rs * tgt / w.r * 57.29578
        j.maxForce = full * (c.motor or 1) * served   -- the motor at full; the lead above is the traction control
        power = power + (m.draw or 0.8) * math.abs(want)
      end
      R2.draw["d" .. w.uid] = (m.draw or 0.8) * (brakes and 0 or math.abs(want)) + 0.01
    end
  end
  R2.power = power
  R2.vf = vf
  R2.served = smin
  -- ANTI-ROLL (r2Steady applies it): how far the body leans over its tyres —
  -- the left tyres hanging lower on their springs than the right ones means
  -- the left side has risen — asked back level at 3 rad/s per rad, about the
  -- craft's front. A turn leans a tall rover outward on soft springs (18° on
  -- a pod rover at 16 m/s); the reaction wheels hold most of that off.
  local hl, nl, hr, nr = 0, 0, 0, 0
  for _, w in ipairs(R2.wheels) do
    local t = w.tyre
    if t and t.valid and w.jointed then
      local mx, my, mz = v2w(node, info, w.cx, w.cy, w.cz)
      local h = (t.x - mx) * upv.x + (t.y - my) * upv.y + (t.z - mz) * upv.z
      if (w.l or 0) > 0.05 then hl, nl = hl + h, nl + 1 elseif (w.l or 0) < -0.05 then hr, nr = hr + h, nr + 1 end
    end
  end
  local tr = R2.plan and R2.plan.track or 0
  if nl > 0 and nr > 0 and tr > 0.2 and grounded >= 2 then
    local phi = math.atan((hr / nr - hl / nl) / tr)
    R2.phi = phi
    local k = -3.0 * phi
    R2.antiroll = { x = fx * k, y = fy * k, z = fz * k }
    -- …and an anti-roll BAR: what a real one does through the springs (it
    -- loads the outside spring and lifts the inside one), as a roll torque on
    -- the body: R2_ANTIROLL × m·g·track per radian of lean over the tyres,
    -- never more than the craft's own righting moment (m·g·track/2), plus a
    -- damper on the roll rate. On the tyres' springs alone a light rover
    -- leaned 23° in a 0.5 g turn, put its body on the ground at 20 m/s and
    -- the engine's depenetration threw it about at 2400 rad/s.
    local m = info.mass or 1
    local mgt = m * gl * tr
    local wr = info.angVel.x * fx + info.angVel.y * fy + info.angVel.z * fz
    local I = (inertiaMin and inertiaMin(info)) or (m * tr * tr / 12)
    local tq = -R2_ANTIROLL * mgt * phi - 4.0 * I * wr
    tq = math.max(-0.5 * mgt, math.min(0.5 * mgt, tq))
    assembly.torque(node, vec3(fx * tq, fy * tq, fz * tq))
  else
    R2.antiroll = nil
  end
  -- THE LEAD ADAPTS. How much acceleration a given rim-speed lead buys
  -- depends on the craft (its mass, how high its centre sits over the tyres,
  -- how many wheels drive): measured, a light rover made the traction
  -- control's 0.55 g from a lead of 0.55 g·dt, one with a pod on top barely
  -- 0.1 g. So the lead is scaled until the craft's own acceleration along
  -- its front matches what the traction control allows.
  local am = (vf - (R2.vf_prev or vf)) / math.max(dt, 1e-3)
  R2.vf_prev = vf
  R2.a_s = (R2.a_s or 0) + (am - (R2.a_s or 0)) * math.min(1, dt * 6)
  if limited and grounded > 0 then
    local want_a = (R2.want_a or R2_TC * gl) * lmot
    local e = (want_a - limited * R2.a_s) / math.max(want_a, 0.1)
    R2.lk = math.max(1, math.min(R2_LK_MAX, (R2.lk or 1.5) * math.exp(math.max(-1, math.min(1, e)) * dt * 6)))
  end
  if R2.gear or R2.hasGear then gearOleo(node, info, dt, upv, gl) end
end

-- THE OLEO (playtest 2026-10-26: the landing gear "is like fighting and it
-- makes the aircraft jump around crazily"). A landing gear's tyre hangs on
-- the engine's wheel joint, a soft spring on the light tyre with no travel
-- limit and a damping the joint caps (hang_tyre): a jet touching down at
-- 2 m/s and 43 m/s pressed its main gear 0.28 m up their legs (twice their
-- travel) and the spring threw it back off the runway at 7.5 m/s, 8–10 m up
-- (motoprobe jetgear: bounce 8.2–10.0 m on every landing, on 0.117.0-rc38
-- before this change and after the axle fix alike). A real gear's oleo
-- damps the stroke both ways and bottoms on a stop. Here, for every gear
-- (and every wheel of an Aircraft) whose tyre is down: a damper on the leg's
-- stroke rate, R2_OLEO_C × the load it carries per m/s, compressing and
-- extending alike, as an impulse on the hull at the leg's mount along the
-- craft's up; at rest the stroke doesn't move and it adds nothing (the
-- joint's spring still carries the craft).
-- WHY IT STILL BOUNCED, and the cap. The per-tick log of a touchdown
-- (motoprobe jetgear, finelog) shows the light tyre at 43 m/s shoved 0.28 m
-- up its leg in two ticks at a 2 m/s sink — further than the sink could
-- carry it: the engine pushing a fast ball out of the ground it sank into —
-- and the joint's spring, at 91 kN on a 10 kN load, throwing the jet up at
-- 7 m/s. No damper a script can add stops one tick's spring. So the gear may
-- not lift the craft: while a tyre is down, and R2_GEAR_HOLD s after, the
-- hull's climb (radial, over the planet) is held to R2_GEAR_VUP, the rest
-- taken off at the centre of mass. A take-off is unaffected: the wings lift
-- the craft off its gear at well under that, and once the tyres are off the
-- ground the cap lets go.
R2_OLEO_C = 1.2      -- s/m: the damper's force per m/s of stroke, × the static load
R2_GEAR_VUP = 1.5    -- m/s: the most the gear may push the craft up
R2_GEAR_HOLD = 0.4   -- s after the last tyre left the ground
R2_GEAR_CAPG = 4.0   -- g: the most the cap takes off in a tick
R2_GEAR_QMAX = 0.35  -- rad/s: the most the gear may pitch the craft
function gearOleo(node, info, dt, upv, gl)
  if not (dt and dt > 0 and info) then return end
  local n = math.max(1, R2.nOut or #R2.wheels)
  local load = (info.mass or 1) * (gl or 9.8) / n
  local down = false
  for _, w in ipairs(R2.wheels) do
    local t = w.tyre
    local j = (w.gear or R2.gear) and w.jointed and t and t.valid and t:getcomponent("Joint")
    if j then
      local s = (j.position or 0) / WHEEL_POS_SCALE            -- + up the leg
      -- (the stroke rate smoothed over a few ticks: the light tyre's contact
      -- chatter read raw made the damper itself a source of bumps)
      local raw = w.oleo_s and (s - w.oleo_s) / dt or 0
      w.oleo_s = s
      w.oleo_sd = (w.oleo_sd or 0) + (raw - (w.oleo_sd or 0)) * math.min(1, dt * 20)
      local sd = w.oleo_sd
      if t.grounded and (w.joint_age or 0) > 0.1 then
        down = true
        local F = R2_OLEO_C * load * sd
        -- (never more than 1.5 × its load either way: one tick must not fling it)
        F = math.max(-1.5 * load, math.min(1.5 * load, F))
        if math.abs(F) > 1e-4 then
          local mx, my, mz = v2w(node, info, w.cx, w.cy, w.cz)
          assembly.impulseAt(node, vec3(upv.x * F * dt, upv.y * F * dt, upv.z * F * dt), vec3(mx, my, mz))
          -- (booked on the leg for the stress model: the ground's push through it)
          stressForce(w.uid, upv.x * F, upv.y * F, upv.z * F)
        end
        w.oleoF = F
      else
        w.oleoF = 0
      end
    end
  end
  if down then R2.gearDown_t = time end
  -- (an Aircraft's only: a rover with a landing gear climbs a hill faster than that)
  if R2.gear and R2.gearDown_t and time - R2.gearDown_t < R2_GEAR_HOLD and space.gravity then
    local c = info.com or info.origin
    local gx, gy, gz = space.gravity(c.x, c.y, c.z)
    local gm = gx and math.sqrt(gx * gx + gy * gy + gz * gz) or 0
    if gm > 1e-6 then
      local Ux, Uy, Uz = -gx / gm, -gy / gm, -gz / gm
      local v = info.vel
      local vu = v.x * Ux + v.y * Uy + v.z * Uz
      if vu > R2_GEAR_VUP then
        -- (at most R2_GEAR_CAPG g a tick, and booked through the centre of
        -- mass for the stress model: unbooked, it read as a 900 kN shock and
        -- tore the gear off)
        local m = info.mass or 1
        local dv = math.min(vu - R2_GEAR_VUP, R2_GEAR_CAPG * gm * dt)
        local J = dv * m
        assembly.impulseAt(node, vec3(-Ux * J, -Uy * J, -Uz * J), vec3(c.x, c.y, c.z))
        stressLead(-Ux * J / dt, -Uy * J / dt, -Uz * J / dt)
        R2.gearCapped = (R2.gearCapped or 0) + 1
      end
      -- …and may not pitch it faster than R2_GEAR_QMAX: a main gear a little
      -- ahead of the centre of mass (the probe jet's, once its tank drains)
      -- kicked the nose up 6° at touchdown, the wing lifted it 3–4 m off the
      -- runway and it came down nose first. A pure couple about the craft's
      -- pitch axis (two opposite impulses along the up, either side of the
      -- centre of mass), at most R2_GEAR_CAPG g's worth of turn a tick.
      local F = R2.fwd or { x = 1, z = 0 }
      local rxv, _, rzv = basis(node)
      local nx, ny, nz = rxv.x * F.x + rzv.x * F.z, rxv.y * F.x + rzv.y * F.z, rxv.z * F.x + rzv.z * F.z
      local Rx, Ry, Rz = ny * Uz - nz * Uy, nz * Ux - nx * Uz, nx * Uy - ny * Ux   -- right = nose × up
      local rl = math.sqrt(Rx * Rx + Ry * Ry + Rz * Rz)
      local It = info.inertia
      if rl > 0.5 and It and It[1] then
        Rx, Ry, Rz = Rx / rl, Ry / rl, Rz / rl
        local w = info.angVel
        local q = w.x * Rx + w.y * Ry + w.z * Rz
        if math.abs(q) > R2_GEAR_QMAX then
          local dq = (math.abs(q) - R2_GEAR_QMAX) * (q > 0 and -1 or 1)
          -- the angular impulse that takes dq off about the right axis
          local Ip = Rx * (It[1].x * Rx + It[1].y * Ry + It[1].z * Rz) + Ry * (It[2].x * Rx + It[2].y * Ry + It[2].z * Rz)
            + Rz * (It[3].x * Rx + It[3].y * Ry + It[3].z * Rz)
          local L = dq * Ip
          local d = 2.0
          local Lmax = R2_GEAR_CAPG * gm * dt * (info.mass or 1) * d
          L = math.max(-Lmax, math.min(Lmax, L))
          -- impulses ±J·up at c ± d·nose: angular impulse 2·d·(nose × up)·J = 2dJ·right
          local J = L / (2 * d)
          assembly.impulseAt(node, vec3(Ux * J, Uy * J, Uz * J), vec3(c.x + nx * d, c.y + ny * d, c.z + nz * d))
          assembly.impulseAt(node, vec3(-Ux * J, -Uy * J, -Uz * J), vec3(c.x - nx * d, c.y - ny * d, c.z - nz * d))
        end
      end
    end
  end
end

-- ══ AUTO-ENGINEERING: SUSPENSION PARTS, THE MOTO WHEEL AND BIKES ═══════════
-- (docs/auto-engineering.md; the maths is scripts/auto_drive.lua on the
-- AutoLib node, the parts scripts/parts_auto.lua.)
--
--   SUSPENSION  a wheel clamped in a Telescopic Fork or a Swing Arm, or bolted
--               to a Coil-over Strut, hangs on the engine's wheel joint along
--               THAT part's axis (the fork's raked head) with a real spring
--               and damper: the craft's weight sits it a third of the way into
--               its travel (so it takes 3 g to bottom it: the engine's wheel
--               joint has no travel limit, and changing a loaded spring's
--               rate on the fly pumps energy into it), damped near half
--               critical. The wheel's own Spring, Damper and Travel settings
--               tune it. The fork's legs, the arm and the strut's
--               knuckle are drawn following the tyre.
--   BIKES       a craft whose wheels all run in one line stays up the way a
--               rider keeps a motorcycle up: at speed by steering under the
--               fall (A/D ask for a LEAN and the turn follows from it, a
--               countersteer included), at a walk by the rider's feet; a
--               Balance Gyro holds it at any speed, with or without a rider.
AUTO = { lib = nil, asked = false }
function autoLib()
  local L = AUTO.lib
  if L and type(L.suspJoint) == "function" then return L end
  L = findScript and findScript("auto_drive") or nil
  if L and type(L.suspJoint) ~= "function" then return nil end
  if not L and not AUTO.asked and spawn then
    AUTO.asked = true
    pcall(spawn, "AutoLib", vec3(0, 0, 0))
  end
  AUTO.lib = L
  return L
end

-- The part a wheel is clamped in (its parent, or a part built onto it — a
-- fork put on a wheel first), when that part carries a suspension.
function motoHost(E, w)
  local cands = { w.d.parent }
  for _, k in ipairs(bp_kids[w.uid] or {}) do cands[#cands + 1] = k end
  for _, u in ipairs(cands) do
    local d = u and bp_by_uid[u]
    local sm = d and not integ.gone[u] and E.modOf(d, "susp")
    if sm then return { uid = u, d = d, m = sm } end
  end
  return nil
end

-- r2_scan, after the wheel list and before the steering plan: which wheels
-- ride a suspension part (their axis, base steer, spin sign and whether
-- they steer), and the gyros aboard.
function motoScan()
  local E = elib()
  R2.gyros, R2.autoWait = {}, nil
  if not E then return end
  local any = false
  for u, d in pairs(bp_by_uid) do
    if not integ.gone[u] and (part_hp[u] or 1) > 0 then
      local gm = E.modOf(d, "gyro")
      if gm then R2.gyros[#R2.gyros + 1] = { uid = u, d = d, m = gm }; any = true end
    end
  end
  for _, w in ipairs(R2.wheels) do
    w.susp = (not w.gear) and motoHost(E, w) or nil
    if w.susp then any = true end
  end
  local L = autoLib()
  if not L then
    if any then R2.autoWait = true end
    return
  end
  local F = R2.fwd or { x = 1, z = 0 }
  for _, w in ipairs(R2.wheels) do
    local s = w.susp
    local rr = s and R2.rest[s.uid]
    if s and rr then
      -- (a wheel that would roll across the front — on a strut bolted to a
      -- front face, its axle along the craft — is laid across it, as
      -- r2WheelSetup does for a wheel on the hull)
      local D = w.axle
      local hl = math.sqrt(D[1] * D[1] + D[3] * D[3])
      if hl < 0.3 or math.abs((-D[3] * F.x + D[1] * F.z) / math.max(hl, 1e-6)) < R2_REALIGN then
        D = { F.z, 0, -F.x }
        w.realigned = true
      end
      -- the joint's spring slides along the craft's UP, never the part's
      -- raked axis: the engine budgets a tyre's grip on that spring's push,
      -- and on a leaning axis the drive's own share unloaded it going
      -- forward and loaded it in reverse (auto_drive.jointAxis; playtest
      -- 2026-10-27, the bike that was "a beast" only backwards)
      local a, st0, own
      if L.jointAxis then a, st0, own = L.jointAxis(s.m, rr.X, rr.Y, rr.Z, D)
      else a, st0 = L.suspAxis(s.m, rr.X, rr.Y, rr.Z, D); own = a end
      s.axis, s.partAxis = a, own
      s.raked = own and math.abs(own[2] or 1) < 0.999 or false
      w.steer0 = st0
      local rd = L.rollDir(L.axleOf(a, st0), { 0, 1, 0 })
      local along = rd[1] * F.x + rd[3] * F.z
      local rs = math.abs(along) > 0.3 and (along > 0 and 1 or -1) or 0
      local c = w.cfg or r2WheelCfg(w.d)
      w.cfg = c
      if c.drive == "off" then rs = 0 elseif c.drive == "invert" then rs = -rs end
      if R2.gear or R2.passive then rs = 0 end
      w.rs = rs
      -- a fork steers, a swing arm never does (unless the wheel is told to);
      -- a strut leaves it to the wheel's own rule (ahead of the centre of mass)
      if c.steer == "auto" then
        if (s.m.steer or -1) == 1 then c.steer = "on" elseif (s.m.steer or -1) == 0 then c.steer = "off" end
      end
    end
  end
end

-- After the steering plan: is it a bike, how long is it, who rides it.
function motoPlan()
  local L = AUTO.lib
  R2.bike = false
  if not L or #R2.wheels < 2 then return end
  local list = {}
  for _, w in ipairs(R2.wheels) do if not r2Stowed(w) then list[#list + 1] = w end end
  R2.bike = L.isBike(list)
  local amin, amax = math.huge, -math.huge
  for _, w in ipairs(list) do amin, amax = math.min(amin, w.a or 0), math.max(amax, w.a or 0) end
  R2.wheelbase = math.max(0.3, amax - amin)
  -- the push that would lift the front: g × (CoM ahead of the rear axle) /
  -- (CoM height), with a margin; the traction control stays under it
  local hcg = (R2.plan and R2.plan.hcg) or 0.8
  R2.wheelieK = 0.6 * math.max(0.05, -amin) / math.max(0.3, hcg)
  R2.rider = false
  for u, d in pairs(bp_by_uid) do
    if not integ.gone[u] and ((d.seat or 0) == 1 or d.seat == true) then R2.rider = true end
  end
  if R2.bike then
    log(string.format("moto: a two-wheeler (wheelbase %.2f m, %s, %d gyro, front %.2f %.2f, CoM %.2f m up)", R2.wheelbase,
      R2.rider and "a seat" or "no seat", #R2.gyros, (R2.fwd or {}).x or 0, (R2.fwd or {}).z or 0, (R2.plan or {}).hcg or -1))
  end
  for _, w in ipairs(R2.wheels) do
    if w.susp then
      log(string.format("moto: wheel %d on %s: axis %.2f %.2f %.2f%s, base steer %.1f, spin %d, steers %s, a %.2f l %.2f",
        w.uid, tostring(w.susp.m.kind), w.susp.axis and w.susp.axis[1] or 0, w.susp.axis and w.susp.axis[2] or 0,
        w.susp.axis and w.susp.axis[3] or 0, w.susp.raked and " (raked)" or "", w.steer0 or 0, w.rs or 0, tostring(w.steers), w.a or 0, w.l or 0))
    end
  end
end

-- The load on one wheel as it stands (kN): a two-wheeler's by the lever rule
-- (its weight is not shared evenly between the ends), else an even share.
function motoLoad(w, info, g)
  local m = info.mass or 1
  local n = math.max(1, R2.nOut or #R2.wheels)
  if #R2.wheels == 2 then
    local o = (R2.wheels[1] == w) and R2.wheels[2] or R2.wheels[1]
    local span = math.abs((w.a or 0) - (o.a or 0))
    if span > 0.2 then
      local share = math.max(0.15, math.min(0.85, math.abs(o.a or 0) / span))
      return m * g * share
    end
  end
  return m * g / n
end

-- hang_tyre for a wheel on a suspension part: the joint's frequency and
-- damping from the spring and damper this corner wants (auto_drive), and
-- the axis it slides on. Returns stiffness, damping, axis.
function motoSpring(w, info, mt, g, c)
  local L, s = AUTO.lib, w.susp
  local wc = type(w.d.wcfg) == "table" and tonumber(w.d.wcfg.travel) or nil
  s.travel = wc or s.m.travel or 0.15
  s.mt = mt
  s.load = s.load or motoLoad(w, info, g)
  local k, cd = L.springFor(s.load, s.travel, s.m.sag, s.m.zeta, g, c.spring, c.damper)
  s.k, s.c = k, cd
  local f, z, ke, ce = L.suspJoint(k, cd, mt, R2.dt or (1 / 60))
  s.ke, s.ce = ke, ce
  return f, z, vec3(s.axis[1], s.axis[2], s.axis[3])
end

-- Every tick, per suspended wheel: how far it is compressed (the drawing and
-- the probes read it). The joint's own measure: a wheel joint's `position`
-- is its travel along the axis in metres, but it comes back through the
-- degrees conversion the engine gives turning joints (× 57.3, 0.117.0-rc37),
-- so it is divided back here. (A world-space measure — the tyre against
-- its mount — is a tick of the planet's travel off on a world on its rails.)
WHEEL_POS_SCALE = 57.29578
function motoSusp(w, j)
  local s = w.susp
  if not (s and j) then return end
  s.comp = (j.position or 0) / WHEEL_POS_SCALE      -- + the wheel has come up toward the hull
  s.peak = math.max(s.peak or 0, s.comp)
end

-- A TWO-WHEELER, every tick its tyres are out: the lean, the lean asked for,
-- the bars (steering balance at speed) and the torque the rider's body and
-- feet or a gyro put in. Rewrites the steering wheels' commands.
BIKE_EASE = 0.8
-- STEERING BALANCE (auto_drive.bikeSteer: the bars turned under the fall,
-- A/D asking for a lean) is off: on the engine's ball tyres it held the
-- probe's straights and turns on some runs and threw the bike on others
-- (docs/auto-engineering.md). Off, A/D steer as on a rover and the rider's
-- weight and feet, or a gyro, hold the lean the turn wants.
BIKE_STEER_BALANCE = false
BIKE_LEAN_RATE = math.rad(30)   -- rad/s
function motoBike(node, info, cmds, vf, gl, dt, rxv, upv, rzv, gdir)
  local L = AUTO.lib
  if not L or R2.motoOff then return end   -- (motoOff: a probe's switch)
  local F = R2.fwd or { x = 1, z = 0 }
  local Fw = { rxv.x * F.x + rzv.x * F.z, rxv.y * F.x + rzv.y * F.z, rxv.z * F.x + rzv.z * F.z }
  local gl2 = math.max(1e-6, gl)
  local U = { -gdir.x / gl2, -gdir.y / gl2, -gdir.z / gl2 }
  -- the front, level (the bike's own front leans and pitches with it)
  local d = Fw[1] * U[1] + Fw[2] * U[2] + Fw[3] * U[3]
  local Fl = L.vec.unit({ Fw[1] - U[1] * d, Fw[2] - U[2] * d, Fw[3] - U[3] * d })
  local wv = info.angVel
  local phi, rate = L.leanOf(Fl, { upv.x, upv.y, upv.z }, U, { wv.x, wv.y, wv.z })
  -- (the rate smoothed over a few ticks: the damping term amplified the
  -- tyres' contact chatter)
  R2.leanRateS = (R2.leanRateS or rate) + (rate - (R2.leanRateS or rate)) * math.min(1, dt * 20)
  rate = R2.leanRateS
  local yaw = wv.x * U[1] + wv.y * U[2] + wv.z * U[3]            -- + turning left
  local alat = vf * yaw                                           -- m/s², + to the left
  local plan = R2.plan or {}
  local h = math.max(0.25, plan.hcg or 0.7)
  local Lb = R2.wheelbase or 1.4
  local lock = 25
  for _, w in ipairs(R2.wheels) do if w.steers and w.cfg then lock = w.cfg.steerMax or lock end end
  local mu = R2_TYRE_MU
  local stick = R2.steer or 0                                     -- eased A/D, + left
  local phiT
  if BIKE_STEER_BALANCE then
    phiT = L.leanTarget(stick, math.abs(vf), gl, Lb, lock, mu)
  else
    -- A/D ask for a lean (the rider's weight, feet or a gyro put it there)
    phiT = L.leanTarget(stick, math.abs(vf), gl, Lb, lock, mu)
  end
  -- the lean asked for comes on at BIKE_LEAN_RATE: a rider tips in, and a
  -- step to full lean overshot it into a lowside
  local pt = R2.leanTs or phi
  phiT = pt + math.max(-BIKE_LEAN_RATE * dt, math.min(BIKE_LEAN_RATE * dt, phiT - pt))
  R2.leanTs = phiT
  local share, steer = 0, nil
  if BIKE_STEER_BALANCE then
    share = L.steerShare(vf)
    local st = L.bikeSteer(phi, rate, phiT, vf, gl, Lb, h, lock)
    -- below a walk the bars are the rider's (full lock on A/D); above it the
    -- balance has them
    local direct = stick * lock
    steer = direct + (st - direct) * share
    for k, w in ipairs(R2.wheels) do
      if w.steers and cmds[k] then cmds[k].steer = steer * (w.ssign or 1) end
    end
  else
    -- …and the bars FOLLOW THE LEAN, as a real fork's trail turns it: the
    -- turn the lean balances, tan δ = L g tan φ / v². Leaned further than
    -- the turn, the turn tightens and stands it up; less, it widens and the
    -- bike falls in: the lean leads, the turn follows. At a walk the bars
    -- are the rider's (A/D, full lock).
    share = L.steerShare(vf)
    local vv = math.max(1.0, math.abs(vf))
    local eq = math.deg(math.atan(Lb * gl * math.tan(phi) / (vv * vv)))
    if vf < 0 then eq = -eq end
    eq = math.max(-lock, math.min(lock, eq))
    steer = stick * lock * (1 - share) + eq * share
    for k, w in ipairs(R2.wheels) do
      if w.steers and cmds[k] then cmds[k].steer = steer * (w.ssign or 1) end
    end
  end
  -- the torque: the gyros (served by the power) and the rider
  local gt, draw_k = 0, 0
  for _, g in ipairs(R2.gyros or {}) do
    local served = (elec.served and elec.served["g" .. g.uid]) or 1
    gt = gt + (g.m.torque or 1.5) * served
  end
  local rider = R2.rider and crewAboard == true
  -- eased in from 40 % over BIKE_EASE s once a tyre is down: at full
  -- authority the moment the tyres came out, the torque on a craft still
  -- settling onto its springs threw it end over end (probe: 7.8 m/s, both
  -- tyres in the air, a second after a parked bike's tyres came out)
  local down = 0
  for _, w in ipairs(R2.wheels) do if w.tyre and w.tyre.valid and w.tyre.grounded then down = down + 1 end end
  if down >= 1 and not R2.bikeT0 then R2.bikeT0 = time end
  local ease = R2.bikeT0 and math.min(1, 0.4 + 0.6 * (time - R2.bikeT0) / BIKE_EASE) or 0
  local tmax = L.balanceAuthority(gt, rider, vf) * ease
  local I = (info.mass or 0.3) * h * h
  local tq = L.bikeTorque(phi, rate, phiT, info.mass or 0.3, h, gl, alat, tmax, I)
  -- (+ leans it left: a turn about −front). About the bike's OWN front, not
  -- the level one: pitched up a slope or on its springs, a turn about the
  -- level front is part yaw, and the balance spun the bike on the spot.
  local Fb = L.vec.unit(Fw)
  assembly.torque(node, vec3(-Fb[1] * tq, -Fb[2] * tq, -Fb[3] * tq))
  if gt > 0 then draw_k = math.min(1, math.abs(tq) / math.max(0.1, gt)) end
  for _, g in ipairs(R2.gyros or {}) do R2.draw["g" .. g.uid] = (g.m.draw or 0.4) * (0.15 + 0.85 * draw_k) end
  R2.lean, R2.leanT, R2.leanRate, R2.bikeSteer, R2.bikeTorque, R2.alat, R2.yawRate = phi, phiT, rate, steer, tq, alat, yaw
  R2.gl, R2.tmax, R2.share = gl, tmax, share
  R2.gyroSpin = (R2.gyroSpin or 0) + dt * (gt > 0 and 40 or 0)
end

-- r2Steady on a bike: the roll is the balance's, not the reaction wheels'
-- (they would hold it upright through a turn and throw it over).
function motoSteadyMask(node, ex, ey, ez)
  if not R2.bike then return ex, ey, ez end
  local rxv, _, rzv = basis(node)
  local F = R2.fwd or { x = 1, z = 0 }
  local fx, fy, fz = rxv.x * F.x + rzv.x * F.z, rxv.y * F.x + rzv.y * F.z, rxv.z * F.x + rzv.z * F.z
  local d = ex * fx + ey * fy + ez * fz
  return ex - d * fx, ey - d * fy, ez - d * fz
end

-- A suspension part's own box while its wheel's tyre is out: a stub at its
-- centre, as a wheel's is (wheel_collider). A fork's or swing arm's box
-- takes in the wheel it holds, and the live tyre hung inside it was thrown
-- clear of it the moment it came out (0.117.0-rc37: a parked bike kicked to
-- 5.7 m/s).
function motoCollider(node, s, live)
  local n = r2NodeOf(node, s.uid)
  local rb = n and n:getcomponent("RigidBody")
  if not rb then return end
  if live then
    rb.half_x, rb.half_y, rb.half_z = 0.05, 0.05, 0.05
  else
    local d = s.d
    rb.half_x, rb.half_y, rb.half_z = d.rx or 0.2, (d.h or 0.5) / 2, d.rz or 0.2
  end
end

-- THE MOVING HALVES AS DRAWN (lateUpdate): a fork's steering half turns and
-- its legs slide, a swing arm swings, a strut's knuckle slides and steers and
-- its wishbone follows; a moto wheel's axle stubs hide with its tyre out (the
-- live tyre carries its own), and a gyro's flywheel caps spin.
function motoFind(n, name, depth)
  if not (n and n.valid) then return nil end
  for _, c in ipairs(n:children()) do
    if c.name == name then return c end
  end
  if (depth or 0) < 3 then
    for _, c in ipairs(n:children()) do
      local f = motoFind(c, name, (depth or 0) + 1)
      if f then return f end
    end
  end
  return nil
end
function motoVisuals(node, dt)
  if not (node and node.valid) then return end
  for _, w in ipairs(R2.wheels) do
    local s = w.susp
    if s then
      local pn = r2NodeOf(node, s.uid)
      if pn then
        s.vis = s.vis or {}
        local V = s.vis
        if not (V.of == pn.id) then
          V.of = pn.id
          V.steer = motoFind(pn, "ForkSteer") or motoFind(pn, "StrutSlide")
          V.slide = motoFind(pn, "ForkSlide")
          V.arm = motoFind(pn, "ArmPivot")
          V.y0 = V.steer and V.steer.y or 0
          if not V.slide and V.steer and s.m.kind == "strut" then V.slide = V.steer end
        end
        local live = R2.live and w.tyre and w.tyre.valid and w.jointed
        local comp = live and (s.comp or 0) or 0
        local stv = live and (w.steerNow or 0) * R2_STEER_SIGN or 0
        local P = AUTO.lib and AUTO.lib.poseOf(s.m.kind, comp, stv, s.m.len) or { slide = comp, steer = math.rad(stv), arm = 0 }
        if s.m.kind == "fork" then
          if V.steer then V.steer:setAngles(P.steer, 0, 0) end
          if V.slide then V.slide.y = P.slide end
        elseif s.m.kind == "arm" then
          if V.arm then V.arm:setAngles(0, 0, P.arm) end
        elseif s.m.kind == "strut" then
          if V.steer then V.steer:setAngles(P.steer, 0, 0); V.steer.y = V.y0 + P.slide end
          if V.arm then V.arm:setAngles(0, 0, P.arm) end
        end
      end
    end
    if w.m and w.m.centred then
      local wn = r2NodeOf(node, w.uid)
      local ax = wn and child_named(wn, "Axle")
      local want = not (R2.live and w.out)
      if ax and ax.visible ~= want then ax.visible = want end
    end
  end
  if #(R2.gyros or {}) > 0 then
    for _, g in ipairs(R2.gyros) do
      local gn = r2NodeOf(node, g.uid)
      local fw = gn and child_named(gn, "Flywheel")
      if fw then fw:setAngles(0, (R2.gyroSpin or 0) % (2 * math.pi), 0) end
    end
  end
end

-- Published (probes, the HUD): the bike's state and each suspension's.
function motoState()
  local o = { g = R2.gl, tmax = R2.tmax, share = R2.share, bike = R2.bike == true, lean = R2.lean, leanT = R2.leanT, steer = R2.bikeSteer, torque = R2.bikeTorque, yaw = R2.yawRate,
              alat = R2.alat, wheelbase = R2.wheelbase, rider = R2.rider, gyros = #(R2.gyros or {}), susp = {} }
  for _, w in ipairs(R2.wheels) do
    local s = w.susp
    if s then
      o.susp[#o.susp + 1] = { uid = w.uid, kind = s.m.kind, comp = s.comp, peak = s.peak, travel = s.travel, k = s.k,
                              c = s.c, ke = s.ke, ce = s.ce, load = s.load, raked = s.raked, steer0 = w.steer0 }
    end
  end
  return o
end

-- ── claw ───────────────────────────────────────────────────────────────────
function r2ClawRelease(uid)
  local node = dock.node
  local E = elib()
  if not (node and node.valid and E) then return false end
  local released = false
  for _, c in ipairs(R2.claws) do
    if c.uid == uid or uid == nil then
      if c.gripped then released = true end
      c.gripped = false
      E.stateOf(c.d).armed = false
    end
  end
  assembly.release(node)
  if released then caption("the claw lets go"); log("claw: released") end
  return true
end

local function claw_tick(node, info, dt)
  local E = elib()
  if not E then return end
  for _, c in ipairs(R2.claws) do
    local st = E.stateOf(c.d)
    local n = r2NodeOf(node, c.uid)
    -- the fingers: open while armed and empty, shut when holding or stowed
    local f = child_named(n, "Fingers")
    local open = st.armed and not c.gripped
    c.open = (c.open or 0) + ((open and 1 or 0) - (c.open or 0)) * math.min(1, dt * 4)
    if f then
      local k = 0.82 + 0.38 * c.open
      if math.abs((f.scale_x or 1) - k) > 0.005 then f.scale_x, f.scale_z = k, k end
    end
    R2.draw["c" .. c.uid] = st.armed and ((c.m.draw or 0.05)) or 0
    if st.armed and not c.gripped then
      -- the tip: the part's −Y end, the way its fingers point
      local p, B = robo_pose(c.uid)
      if not p then local r = R2.rest[c.uid]; p, B = { r.x, r.y, r.z }, { r.X, r.Y, r.Z } end
      local Y = B[2]
      local tx, ty, tz = p[1] - Y[1] * 0.32, p[2] - Y[2] * 0.32, p[3] - Y[3] * 0.32
      local wx, wy, wz = v2w(node, info, tx, ty, tz)
      local rx, up, rz = basis(node)
      local dx = -(rx.x * Y[1] + up.x * Y[2] + rz.x * Y[3])
      local dy = -(rx.y * Y[1] + up.y * Y[2] + rz.y * Y[3])
      local dz = -(rx.z * Y[1] + up.z * Y[2] + rz.z * Y[3])
      local hit = raycast(wx, wy, wz, dx, dy, dz, 0.35, { ignore = r2Own(node) })
      local served = (elec.served and elec.served["c" .. c.uid]) or 1
      if hit and served > 0.5 then
        -- another craft's part grips that craft; the ground grips the ground
        local target = nil
        if hit.node and hit.node.valid ~= false then
          local par = hit.node.parent
          if par and assembly.info(par) then target = hit.node end
        end
        assembly.grip(node, vec3(hit.x, hit.y, hit.z), target, (c.m.hold or 400))
        c.gripped = true
        c.grip_t = time
        caption("the claw bites")
        log(string.format("claw: gripped %s at %.2f m", target and "a craft" or "the ground", hit.distance or 0))
      end
    elseif c.gripped and time - (c.grip_t or 0) > 0.5 and not info.gripped then
      -- torn loose (past its hold)
      c.gripped = false
      st.armed = false
      caption("the claw is torn loose")
    end
  end
end

-- ── drill ──────────────────────────────────────────────────────────────────
local function drill_tick(node, info, dt)
  local E = elib()
  if not E then return end
  for _, dr in ipairs(R2.drills) do
    local st = E.stateOf(dr.d)
    local n = r2NodeOf(node, dr.uid)
    local bit = child_named(n, "Bit")
    if bit and not dr.bit0 then dr.bit0 = { x = bit.x, y = bit.y, z = bit.z } end
    local target = st.deployed and 1 or 0
    dr.lower = dr.lower + math.max(-dt * 0.8, math.min(dt * 0.8, target - dr.lower))
    local served = (elec.served and elec.served["q" .. dr.uid]) or 1
    local on = st.drilling and st.deployed and dr.lower > 0.95
    local ok_ground = info.grounded or info.gripped or R2.onWheels
    local working = false
    local why = nil
    if on then
      if not ok_ground then why = "the drill needs the craft landed or gripped"
      elseif served < 0.5 then why = "the drill has no power"
      elseif not holdId then why = "no cargo bay aboard — the cores have nowhere to go" end
    end
    if bit and dr.bit0 then
      bit.y = dr.bit0.y - 0.5 * dr.lower
      if on and not why then
        dr.spin = ((dr.spin or 0) + dt * 14) % (2 * math.pi)
        bit:setAngles(dr.spin, 0, 0)
      end
    end
    if on and not why then
      -- the bit's tip, and the ground under it (straight down the part's −Y)
      local p, B = robo_pose(dr.uid)
      if not p then local r = R2.rest[dr.uid]; p, B = { r.x, r.y, r.z }, { r.X, r.Y, r.Z } end
      local Y = B[2]
      local tipd = 0.6 + 0.5 * dr.lower
      local wx, wy, wz = v2w(node, info, p[1] - Y[1] * 0.1, p[2] - Y[2] * 0.1, p[3] - Y[3] * 0.1)
      local rx, up, rz = basis(node)
      local dx = -(rx.x * Y[1] + up.x * Y[2] + rz.x * Y[3])
      local dy = -(rx.y * Y[1] + up.y * Y[2] + rz.y * Y[3])
      local dz = -(rx.z * Y[1] + up.z * Y[2] + rz.z * Y[3])
      local hit = raycast(wx, wy, wz, dx, dy, dz, tipd + (dr.m.reach or 0.9), { ignore = r2Own(node) })
      if not hit then
        why = "the drill can't reach the ground — set down closer"
      elseif baseDigRadius(hit.x, hit.y, hit.z, 0.4) < 0.4 then
        why = "the base's foundations — can't drill here"
      else
        working = true
        dr.prog = dr.prog + dt * (dr.m.rate or 4) / 60.0 -- units a minute → per tick
        if time - (dr.dig_t or -10) > 1.2 then
          dr.dig_t = time
          -- a small bite at the face: the bore deepens as it goes
          terrain.dig(hit.x + dx * 0.15, hit.y + dy * 0.15, hit.z + dz * 0.15, 0.22, 0.6)
          groundChangedAt(hit.x, hit.y, hit.z, 0.4)
          local fx = fxd()
          if fx and fx.dig then fx.dig(hit.x, hit.y, hit.z, false) end
        end
        while dr.prog >= 1.0 do
          dr.prog = dr.prog - 1.0
          local inv = findScript("inventory")
          local tb = findScript("tool_belt")
          local mat = tb and tb.survey and tb.survey(hit.x, hit.y, hit.z)
          if inv and mat then
            local took = inv.add(holdId, mat, 1)
            if took and took > 0 then
              holdApplyMass(node)
              dr.cores = (dr.cores or 0) + took
              local mats = findScript("materials")
              caption(string.format("core: %s  ·  %s", mats and mats.label and mats.label(mat) or mat,
                inv.line and inv.line(holdId) or ""))
              log(string.format("drill: +1 %s into %s", mat, holdId))
            else
              why = "the hold is full"
              st.drilling = false
            end
          end
        end
      end
    end
    if why and why ~= dr.why then caption(why) end
    dr.why = why
    dr.working = working
    R2.draw["q" .. dr.uid] = working and (dr.m.draw or 1.2) or 0
  end
end

-- ── fairings ───────────────────────────────────────────────────────────────
local function fairing_build(node)
  local E = elib()
  if not (E and E.fairingShell and mesh and mesh.build) then return end
  for _, f in ipairs(R2.fairings) do
    local d = f.d
    local st = E.stateOf(d)
    local n = r2NodeOf(node, f.uid)
    if n and not st.jettisoned and not R2.shells[f.uid] then
      local sh = { meshes = {}, nodes = {} }
      R2.shells[f.uid] = sh
      -- The shell the builder drew (fprof) or fitted, in 2 or 3 clamshell
      -- pieces (fsplit) — electronics.fairingMeshOf; an older rulebook only
      -- knows the fitted halves.
      local pieces = E.fairingMeshOf and (d.fsplit or 2) or 2
      for k = 1, pieces do
        local m = E.fairingMeshOf and E.fairingMeshOf(d, k, 24) or E.fairingShell(d.fr, d.fy0 or 0.1, d.fhc, d.fhn, k - 1, 24)
        local name = mesh.build(m)
        sh.meshes[k] = name
        createNode("Fairing Shell", n, function(c)
          c.model = name
          c:setMaterial{ texture = "textures/parts/paint_albedo.png", normalMap = "textures/parts/paint_normal.png",
                         roughnessMap = "textures/parts/paint_orm.png", occlusionMap = "textures/parts/paint_orm.png",
                         shading = "physical", roughness = 0.75, metallic = 0.25 }
          sh.nodes[k] = c
        end)
      end
    end
  end
end

-- Is the payload part `d` still inside its (un-jettisoned) fairing?
function r2Faired(d)
  local fu = d and (d.faired or 0)
  if not fu or fu == 0 then return false end
  local f = bp_by_uid[fu]
  if not f or integ.gone[fu] or (part_hp[fu] or 1) <= 0 then return false end
  return not (type(f.st) == "table" and f.st.jettisoned)
end

-- Split the shell: its clamshell pieces (2 or 3, `fsplit`) come away as
-- debris, each pushed straight out from the axis on its own side. Each piece
-- is a fresh FairingHalf body carrying a copy of its shell mesh;
-- it is spawned KINEMATIC and seated on the hull for a few ticks from the
-- physics pose (a body spawned free on an orbiting planet lands one tick of
-- the orbit behind — ~6 m at scale 3, reported on 0420), then let go with
-- the hull's velocity and the springs' push. The shell on the base hides as
-- it leaves.
function r2Jettison(node, uid)
  local E = elib()
  local d = bp_by_uid[uid]
  if not (E and d and node and node.valid) then return false end
  local st = E.stateOf(d)
  if st.jettisoned then return false end
  st.jettisoned = true
  local sh = R2.shells[uid]
  local shellm = d.shellm or 0
  local X, Y, Z = r2_basis(d.yaw, d.pitch, d.roll)
  local prof = E.fairingProfileOf and E.fairingProfileOf(d)
  local pieces = prof and (d.fsplit or 2) or 2
  for k = 1, pieces do
    -- piece k's centre (ox, oy, oz) and outward way (dx, dz), in the base's
    -- frame (electronics.fairingPieceInfo); the fitted halves as before when
    -- the rulebook can't say
    local pi = prof and E.fairingPieceInfo(prof, k, pieces) or nil
    if not pi then
      local sgn = (k == 1) and 1 or -1
      local hh = (d.fhc + d.fhn - (d.fy0 or 0.1)) * 0.5
      pi = { ox = 0, oy = ((d.fy0 or 0.1) + d.fhc + d.fhn) * 0.5, oz = sgn * d.fr * 0.5, dx = 0, dz = sgn,
             hx = d.fr * 0.8, hy = math.max(0.1, hh), hz = d.fr * 0.4 }
    end
    local out = { X[1] * pi.dx + Z[1] * pi.dz, X[2] * pi.dx + Z[2] * pi.dz, X[3] * pi.dx + Z[3] * pi.dz }
    local deb = { half = k - 1, mesh = sh and sh.meshes[k], shell = sh and sh.nodes[k],
                  lx = d.x + X[1] * pi.ox + Y[1] * pi.oy + Z[1] * pi.oz,
                  ly = d.y + X[2] * pi.ox + Y[2] * pi.oy + Z[2] * pi.oz,
                  lz = d.z + X[3] * pi.ox + Y[3] * pi.oy + Z[3] * pi.oz,
                  Z = out, part = { d.yaw or 0, d.pitch or 0, d.roll or 0 },
                  m = math.max(0.005, shellm / pieces) }
    local info = assembly.info(node)
    local wx, wy, wz = v2w(node, info, deb.lx, deb.ly, deb.lz)
    spawn("FairingHalf", vec3(wx, wy, wz), function(h)
      -- Let go DYNAMIC, where the shell stands now, moving with the craft
      -- plus a push out: a fresh body lands where it is placed on a moving
      -- planet since 0.117.0-rc3 (floptle/0449), so the "spawn kinematic and
      -- seat it for 3 ticks" workaround is gone.
      if not (node and node.valid) then destroy(h) return end
      local ci = assembly.info(node)
      local rx, up, rz = basis(node)
      local function w(v) return { rx.x * v[1] + up.x * v[2] + rz.x * v[3], rx.y * v[1] + up.y * v[2] + rz.y * v[3],
                                   rx.z * v[1] + up.z * v[2] + rz.z * v[3] } end
      local Xp, Yp, Zp = r2_basis(deb.part[1], deb.part[2], deb.part[3])
      h:setAngles(r2_euler(w(Xp), w(Yp), w(Zp)))
      local hx, hy, hz = v2w(node, ci, deb.lx, deb.ly, deb.lz)
      h.x, h.y, h.z = hx, hy, hz
      local rb = h:getcomponent("RigidBody")
      if rb then
        rb.half_x, rb.half_y, rb.half_z = pi.hx, pi.hy, pi.hz
        rb.mass = deb.m
        rb.kinematic = 0
      end
      if deb.mesh then
        createNode("Shell", h, function(c)
          c.model = deb.mesh
          c:setMaterial{ texture = "textures/parts/paint_albedo.png", normalMap = "textures/parts/paint_normal.png",
                         roughnessMap = "textures/parts/paint_orm.png", shading = "physical", roughness = 0.75, metallic = 0.25 }
          c.x, c.y, c.z = -pi.ox, -pi.oy, -pi.oz
        end)
      end
      local o = w(deb.Z)
      local v = ci and ci.vel or { x = 0, y = 0, z = 0 }
      h.vx = v.x + o[1] * 3.0 + up.x * 0.5
      h.vy = v.y + o[2] * 3.0 + up.y * 0.5
      h.vz = v.z + o[3] * 3.0 + up.z * 0.5
      physics.ignorePair(h, node, 1.5)
      if deb.shell and deb.shell.valid then deb.shell.visible = false end
      deb.node = h
      -- (and only if it is still a fairing half: one the depot took is gone,
      -- and its handle — a bare slot number — can read `valid` again on the
      -- next node spawned; engine card 0552)
      after(25.0, function() if h.valid and h.name == "FairingHalf" then destroy(h) end end)
    end)
  end
  -- the shells' mass leaves with them
  d.mass = math.max(0.01, (d.mass or 0) - shellm)
  d.shellm = 0
  integ.gen = integ.gen + 1
  local bx, by, bz = base_of(node, assembly.info(node))
  sfx3(SFX.stage, bx, by, bz, 0.8, 1.3)
  caption(pieces == 3 and "the fairing splits three ways" or "the fairing splits away")
  log("fairing jettisoned")
  return true
end

-- ── rollout ────────────────────────────────────────────────────────────────
-- A ROVER (wheels, no engines) leaves the launch clamps beside the pad, on
-- the levelled ground, not on a deck 2.5 m up with nothing to drive down.
function r2Rollout(node, info)
  if #R2.wheels == 0 or #engines > 0 then return end
  local rx, up, rz = basis(node)
  local bx, by, bz = base_of(node, info)
  local out = 7.0
  local qx, qy, qz = bx + rx.x * out + up.x * 4, by + rx.y * out + up.y * 4, bz + rx.z * out + up.z * 4
  local h = raycast(qx, qy, qz, -up.x, -up.y, -up.z, 20, node)
  if not h then return end
  -- the lowest point of the craft sits on the ground (its wheels' bottoms)
  local low = 0
  for _, w in ipairs(R2.wheels) do low = math.min(low, w.cy - w.r) end
  local ox, oy, oz = info.origin.x - bx, info.origin.y - by, info.origin.z - bz
  local lift = -low + 0.05
  assembly.teleport(node, vec3(h.x + up.x * lift + ox, h.y + up.y * lift + oy, h.z + up.z * lift + oz))
  integ.handoff_t = time + 1.0   -- (the safety net: this jump is ours)
  integ.prev = nil
  R2.holdoff = math.max(R2.holdoff, 0.5)
  log("rover: rolled out beside the pad")
end

-- ── the tick ───────────────────────────────────────────────────────────────
-- THE HOLD-OFF COUNTS DOWN IN TICKS (seconds of fixed dt). It used to be an
-- absolute `time` set in the update pass and compared here, and until
-- 0.117.0-rc6 the tick clock trailed the frame clock by many seconds after a
-- load (a rover released after a 39 s load kept its tyres in for 11 s). Since
-- rc7 one `time` is shared and the tick clock no longer falls behind
-- (floptle/0469, 0491), but a frame's ticks still read the clock one frame
-- behind update's (measured: 0.05 s at 20 fps, 0.9 s on a 0.9 s hitch), so a
-- countdown in ticks is still the exact form, and it stays.
-- PARKED ROVERS AND WARP. A rover on its live tyres counts as grounded through
-- them since 0.117.0-rc7 (floptle/0483, assembly.info.grounded too), so the
-- engine keeps it on realtime physics and holds the warp: the tyres stay out
-- (wheels_wanted) and nothing is pinned. (Until rc6 it was anchored for the
-- warp, r2WarpPin, and the tyres came in.) Measured on rc7: parked 110 m out,
-- warped 1→5→10× by the keys, held 10× for 5.8 s, grounded every frame,
-- drift 0.00 m, and it drove off at 22 m/s straight after.
-- The craft and its live tyres (bodies of their own), for a query's ignore
-- list (floptle/0473): a claw or a drill must not take hold of its own wheel.
function r2Own(node)
  local own = { node }
  for _, w in ipairs(R2.wheels) do
    if w.tyre and w.tyre.valid then own[#own + 1] = w.tyre end
  end
  return own
end

function r2Tick(node, info, dt)
  R2.holdoff = math.max(0, (R2.holdoff or 0) - (dt or 0))
  if R2.gen ~= integ.gen then
    if R2.live then tyres_in(node); R2.holdoff = math.max(R2.holdoff, 0.5) end
    r2_scan(node)
    motoStand(node)
    fairing_build(node)
  end
  robo_tick(node, info, dt)
  claw_tick(node, info, dt)
  drill_tick(node, info, dt)
  -- (the library node answered: read the mode now)
  if R2.modeWait and craftModeLib() then r2ResolveMode(); R2.gen = -1 end
  if R2.autoWait and autoLib() then R2.gen = -1 end
  -- LANDING GEAR FOLDING (G), in any mode. Tyres in: the leg's wheel box
  -- goes and comes with it. Tyres out: the tyres are laid again without the
  -- folded legs (a rover drives on, a plane's come in), and back with them
  -- when they are down.
  if R2.hasGear then
    local sig = r2StowSig()
    if R2.stow_sig ~= nil and sig ~= R2.stow_sig then
      r2Replan()
      if R2.live then
        if sig ~= R2.stow_live then
          log("rover: the gear " .. (#sig > 0 and sig:find("1") and "folds" or "comes down") .. ": the tyres are laid again")
          tyres_in(node)
          R2.holdoff = math.max(R2.holdoff, 0.25)
        end
      else
        for _, w in ipairs(R2.wheels) do if w.gear then wheel_collider(node, w, false) end end
        assembly.rebuild(node)
        damage_arm = math.max(damage_arm, time - 1.5)
      end
    end
    R2.stow_sig = sig
  end
  motoRiderShape(node)
  local want, why = wheels_wanted(node, info)
  R2.why = want and "out" or why   -- published: why the tyres are in (HUD, probes)
  if want and not R2.live then tyres_out(node, info)
  elseif not want and R2.live then
    log("rover: wheels stowed (" .. tostring(why) .. ")")
    tyres_in(node)
  end
  if R2.live then
    drive_tick(node, info, dt)
  else
    R2.driving, R2.onWheels = false, false
  end
  SFX.drive(node, R2.live and not R2.gear and not R2.passive, R2.speed or 0, R2.drive or 0, R2.onWheels)
end

-- Before the craft is cut (staging, undocking, a part tearing off, docking):
-- the tyres come in, so no joint is left hanging off a piece that leaves.
function r2Before(node)
  if R2.live then tyres_in(node) end
  R2.holdoff = math.max(R2.holdoff, 1.0)
end

function r2Cleanup()
  for _, w in ipairs(R2.wheels) do
    if w.tyre and w.tyre.valid then destroy(w.tyre) end
    w.tyre, w.mesh, w.mesh_of = nil, nil, nil
  end
  R2.live = false
  for _, sh in pairs(R2.shells) do
    for _, m in ipairs(sh.meshes or {}) do if mesh and mesh.free then mesh.free(m) end end
  end
  R2.shells = {}
end

function onDestroy(node)
  r2Cleanup()
  -- A CRAFT GONE UNDER ITS RIDER (despawned, cleared by a script) with the
  -- crew still in the seat: the crew rode as a kinematic passenger, and with
  -- nothing left to un-seat them they stayed kinematic — left behind in space
  -- by the planet's travel, hundreds of metres up a second later (verified
  -- 2026-10-27, verifyprobe vbike). Stood down where the craft was, with its
  -- velocity, as a step-out would (recoverCraft does this before it destroys).
  if crewAboard and not destroyed then
    local x, y, z = node and node.x, node and node.y, node and node.z
    local ok = pcall(function()
      local up = node.up or vec3(0, 1, 0)
      standDown(node, x + up.x * 1.5, y + up.y * 1.5, z + up.z * 1.5, node.vx or 0, node.vy or 0, node.vz or 0)
    end)
    if not ok then pcall(seatCrew, node, false) end
  end
  -- a craft gone under its rider (recovered, despawned) gives the capsule
  -- back too: nothing of this controller runs again to do it
  local k = R2.riderShape
  if k then
    R2.riderShape = nil
    local a = find and find("Astronaut")
    local getc = a and (a.getComponent or a.getcomponent)
    local rb = getc and getc(a, "RigidBody")
    if rb and a.id == k.id then rb.radius, rb.height = k.r or 0.33, k.h or 2.0 end
  end
end

-- Standing on its own tyres counts as on the ground (the hull's compound is
-- not touching anything: the tyre bodies carry it). flight_ops and the
-- landing checks ask this.
function r2OnWheels() return R2.onWheels == true end

-- What the HUD and probes read: the rover, the robots, the claw, the drill.
function roundTwoState()
  local out = { live = R2.live, driving = R2.driving, speed = R2.speed, parked = R2.live and R2.hold_t > 0.15,
                wheels = #R2.wheels, grounded = 0, robo = {}, claws = {}, drills = {} }
  for _, w in ipairs(R2.wheels) do
    if w.tyre and w.tyre.valid and w.tyre.grounded then out.grounded = out.grounded + 1 end
  end
  for _, r in ipairs(R2.robo) do
    out.robo[#out.robo + 1] = { uid = r.uid, kind = r.kind, cur = r.cur, stalled = r.stalled, n = 0 }
  end
  for _, c in ipairs(R2.claws) do out.claws[#out.claws + 1] = { uid = c.uid, gripped = c.gripped == true } end
  for _, d in ipairs(R2.drills) do
    out.drills[#out.drills + 1] = { uid = d.uid, working = d.working == true, cores = d.cores or 0, why = d.why, lower = d.lower }
  end
  return out
end

-- ── AERODYNAMICS (scripts/aero.lua) ─────────────────────────────────────────
-- Per-part drag, lift, control surfaces and jets for the craft you fly. The
-- maths is scripts/aero.lua (findScript("aero"), on the AeroLib node, spawned
-- here when the scene has none); this side builds the craft's model from its
-- blueprint, hands it the air, the wind and the stick every tick, applies the
-- force and torque that come back, poses the control surfaces and feeds the
-- jets' thrust to the engine loop (`e.jk`, `e.jb`). Everything is reached
-- through globals: fixedUpdate has no upvalue to spare.
--
-- THE CONTROL FRAME. A rocket flies by its stack: nose +Y, top −Z (the pod's
-- window). A craft whose command part flies nose-first (a cockpit, `af`
-- "cockpit") or lies down (a pod built on its side) flies by THAT part: its
-- +Y is the nose and its −Z the top, so a plane laid along the runway pitches,
-- yaws and rolls about its own axes and the navball reads its attitude.
--
-- TRIM: ALT + W/S, A/D, Q/E move the trim (the surfaces' rest), ALT + X
-- zeroes it. The SAS's stability assist damps the rates the stick isn't
-- asking for through the surfaces as well as the reaction wheels.
AERO = {
  lib = nil, asked = false,
  model = nil, gen = -1, gu = nil,
  frame = nil,            -- { n = nose, f = top } in the vessel frame; nil = the rocket's
  trim = { p = 0, y = 0, r = 0 },
  cmd = nil,              -- a probe's stick { p, y, r } (a headless run cannot press keys)
  world = nil, world_name = nil, world_t = -100,
  pivots = {},            -- uid → the surface's moving node (FlapPivot / SurfacePivot) or false
  hud = nil,              -- published as tele.aero
  active = false,
}
AERO_TRIM_RATE = 0.35     -- trim travel per second of a held ALT + key
AERO_TRIM_MAX = 0.6

function aeroLib()
  local A = AERO.lib
  if A and A.valid then return A end
  A = findScript and findScript("aero") or nil
  if not A and not AERO.asked and spawn then
    AERO.asked = true
    pcall(spawn, "AeroLib", vec3(0, 0, 0))
  end
  AERO.lib = A
  return A
end

-- Does a part's aero spec carry this word ("jet", "gear", "cockpit")?
function afHas(d, word)
  local s = d and d.af
  return type(s) == "string" and (" " .. s .. " "):find(" " .. word .. "[ =]") ~= nil
end

-- A landing gear folded away (G): its fold, by the same per-part animation the
-- legs use.
function gearIsUp(uid) return (panim[uid] or 1) < 0.5 end
function gearState()
  local up = false
  for _, w in ipairs(R2.wheels) do if w.gear and gearIsUp(w.uid) then up = true end end
  return up
end

-- Re-read the craft (its part set changed): the control frame, and the model
-- is rebuilt on the next aero tick.
function aeroScan()
  AERO.gen = integ.gen
  AERO.model, AERO.pivots = nil, {}
  AERO.frame = nil
  local d = pod_uid and bp_by_uid[pod_uid]
  if d and not integ.gone[pod_uid] then
    local _, Y, Z = r2_basis(d.yaw, d.pitch, d.roll)
    if afHas(d, "cockpit") or Y[2] < 0.866 then
      AERO.frame = { n = { x = Y[1], y = Y[2], z = Y[3] }, f = { x = -Z[1], y = -Z[2], z = -Z[3] } }
    end
  end
end

-- The control frame in the world: nose, then top.
function aeroFrame(rx, up, rz)
  local n, f = AERO.frame.n, AERO.frame.f
  return rx.x * n.x + up.x * n.y + rz.x * n.z, rx.y * n.x + up.y * n.y + rz.y * n.z, rx.z * n.x + up.z * n.y + rz.z * n.z,
         rx.x * f.x + up.x * f.y + rz.x * f.z, rx.y * f.x + up.y * f.y + rz.y * f.z, rx.z * f.x + up.z * f.y + rz.z * f.z
end

-- A probe's stick, in place of the keys.
function aeroCmd(p, y, r)
  local c = AERO.cmd
  if not c then return p, y, r end
  return c.p or 0, c.y or 0, c.r or 0
end
function setThrottle(v) throttle = math.max(0, math.min(1, tonumber(v) or 0)) end

-- The moving node of a control surface (for the eye only: the flight's
-- deflection is the model's).
local function aero_pivot(node, uid)
  local pv = AERO.pivots[uid]
  if pv ~= nil and (pv == false or pv.valid) then return pv end
  pv = false
  local n = r2NodeOf(node, uid)
  if n then
    for _, c in ipairs(n:children()) do
      if c.name == "SurfacePivot" then pv = c end
      if c.name == "FlapHinge" then
        for _, g in ipairs(c:children()) do if g.name == "FlapPivot" then pv = g end end
      end
    end
  end
  AERO.pivots[uid] = pv
  return pv
end

-- THE TICK, from fixedUpdate's attitude block: the stick (sp, sy, sr), the
-- SAS's rate error (ex, ey, ez, world), and the stick's rotation axes in the
-- world (pitch ap, yaw ay, roll ar).
function aeroTick(node, info, dt, thr, sp, sy, sr, ex, ey, ez, apx, apy, apz, ayx, ayy, ayz, arx, ary, arz)
  AERO.active = false
  if AERO.gen ~= integ.gen then aeroScan() end
  -- trim: ALT + the stick keys
  if piloting and elec.control ~= false and not dock.plan and input.key("alt") then
    local T = AERO.trim
    local function k(a, b) return (input.key(a) and 1 or 0) - (input.key(b) and 1 or 0) end
    T.p = math.max(-AERO_TRIM_MAX, math.min(AERO_TRIM_MAX, T.p + k("w", "s") * AERO_TRIM_RATE * dt))
    T.y = math.max(-AERO_TRIM_MAX, math.min(AERO_TRIM_MAX, T.y + k("a", "d") * AERO_TRIM_RATE * dt))
    T.r = math.max(-AERO_TRIM_MAX, math.min(AERO_TRIM_MAX, T.r + k("e", "q") * AERO_TRIM_RATE * dt))
    if input.pressed("x") then T.p, T.y, T.r = 0, 0, 0 end
  end
  if info.anchored or dt <= 0 or space.warp() > 1.001 then return end
  local A = aeroLib()
  -- (a library node spawned this tick answers before its script has loaded)
  if not (A and A.airAt and A.build and A.step) then return end
  local dom = space.dominant(node.x, node.y, node.z)
  local b = dom and space.body(dom)
  if not (b and b.radius) then return end
  local com = info.com
  local dx, dy, dz = com.x - b.x, com.y - b.y, com.z - b.z
  local R = b.radius
  local alt = math.sqrt(dx * dx + dy * dy + dz * dz) - R
  if AERO.world_name ~= dom or time - AERO.world_t > 5 or time < AERO.world_t then
    AERO.world, AERO.world_name, AERO.world_t = save.get("world." .. dom), dom, time
  end
  local rho, a, o2 = A.airAt(AERO.world, alt, (b.mu or 0) / (R * R), R)
  -- the model: rebuilt when the craft changes or a gear folds
  local gu = R2.hasGear and r2StowSig() or false
  if not AERO.model or AERO.gu ~= gu then
    AERO.gu = gu
    -- (a running jet keeps its spool through a rebuild: the gear folding is
    -- not a flame-out)
    local old = AERO.model and AERO.model.byuid
    AERO.model = A.build(bp_by_uid, {
      gone = integ.gone,
      faired = function(d) return (d.faired or 0) ~= 0 and r2Faired(d) end,
      shell = function(d) return not (type(d.st) == "table" and d.st.jettisoned) end,
      gearUp = function(d) return gearIsUp(d.uid) end,
      top = AERO.frame and AERO.frame.f or { x = 0, y = 0, z = -1 },
    })
    AERO.model.byuid = {}
    for _, j in ipairs(AERO.model.jets) do
      AERO.model.byuid[j.uid] = j
      if old and old[j.uid] then j.s = old[j.uid].s or 0 end
    end
  end
  local M = AERO.model
  if rho <= 0 and #M.jets == 0 then AERO.hud = nil return end
  -- into the vessel frame: the centre of mass, the air past it, the spin
  local rx, up, rz = basis(node)
  local bx, by, bz = base_of(node, info)
  local cx, cy, cz = com.x - bx, com.y - by, com.z - bz
  local wx, wy, wz = 0, 0, 0
  if weather and weather.windAt then
    local ok, wv = pcall(weather.windAt, vec3(com.x, com.y, com.z))
    if ok and wv then wx, wy, wz = wv.x or 0, wv.y or 0, wv.z or 0 end
  end
  local v, w = info.vel, info.angVel
  local vx, vy, vz = v.x - wx, v.y - wy, v.z - wz
  local function loc(x, y, z) return x * rx.x + y * rx.y + z * rx.z, x * up.x + y * up.y + z * up.z, x * rz.x + y * rz.y + z * rz.z end
  local env = { rho = rho, a = a, o2 = o2, dt = dt, throttle = (fuel > 0) and thr or 0 }
  env.cx, env.cy, env.cz = loc(cx, cy, cz)
  env.vx, env.vy, env.vz = loc(vx, vy, vz)
  env.wx, env.wy, env.wz = loc(w.x, w.y, w.z)
  local function vl(x, y, z) local p, q, s = loc(x, y, z) return { x = p, y = q, z = s } end
  env.ap, env.ay, env.ar = vl(apx, apy, apz), vl(ayx, ayy, ayz), vl(arx, ary, arz)
  -- the surfaces' command: stick + trim, and the assist on the axes the
  -- stick leaves alone (gentler the harder the air pushes)
  local T = AERO.trim
  local cp, cyw, cr = sp + T.p, sy + T.y, sr + T.r
  local V = math.sqrt(env.vx * env.vx + env.vy * env.vy + env.vz * env.vz)
  if sas_mode ~= "off" and elec.control ~= false then
    local q = 0.5 * rho * V * V
    local ks = math.max(0.08, math.min(1.0, 1500 / math.max(q, 1)))
    if sp == 0 then cp = cp + math.max(-1, math.min(1, 1.2 * ks * (ex * apx + ey * apy + ez * apz))) end
    if sy == 0 then cyw = cyw + math.max(-1, math.min(1, 1.2 * ks * (ex * ayx + ey * ayy + ez * ayz))) end
    if sr == 0 then cr = cr + math.max(-1, math.min(1, 1.2 * ks * (ex * arx + ey * ary + ez * arz))) end
  end
  if elec.control == false then cp, cyw, cr = T.p, T.y, T.r end
  env.ctl = { p = math.max(-1, math.min(1, cp)), y = math.max(-1, math.min(1, cyw)), r = math.max(-1, math.min(1, cr)) }
  local fx, fy, fz, tx, ty, tz = A.step(M, env)
  -- never more than half the airspeed in one tick (an explicit step of a
  -- stiff drag must not reverse the craft)
  local m = math.max(info.mass or 1, 1e-3)
  local fm = math.sqrt(fx * fx + fy * fy + fz * fz)
  local capk = 1
  if fm * dt > 0.5 * V * m and fm > 0 then
    local k = 0.5 * V * m / (fm * dt)
    capk = k
    fx, fy, fz, tx, ty, tz = fx * k, fy * k, fz * k, tx * k, ty * k, tz * k
  end
  -- (AERO.scale: a probe's A/B switch on the air's force; 1 in the game)
  local ks = AERO.scale or 1
  fx, fy, fz, tx, ty, tz = fx * ks, fy * ks, fz * ks, tx * ks, ty * ks, tz * ks
  -- (A parked craft is pushed by the breeze too: since engine rc33 a sleeper
  -- absorbs force changes under a fifth of its weight, so this no longer
  -- keeps it awake — tools/perf/results/rc33.md.)
  if fm > 0 and ks > 0 then
    assembly.force(node, vec3(rx.x * fx + up.x * fy + rz.x * fz, rx.y * fx + up.y * fy + rz.y * fz, rx.z * fx + up.z * fy + rz.z * fz))
    assembly.torque(node, vec3(rx.x * tx + up.x * ty + rz.x * tz, rx.y * tx + up.y * ty + rz.y * tz, rx.z * tx + up.z * ty + rz.z * tz))
    -- ...and the same air booked part by part for the stress model, once it
    -- is worth booking (20 Pa: ~6 m/s at sea level; under that the
    -- remainder is spread by mass and loads nothing)
    if M.diag and (M.diag.q or 0) > 20 then aeroStressForces(A, M, env, capk * ks, rx, up, rz) end
  end
  AERO.active = true
  -- the jets' thrust for the engine loop (next tick)
  local jk, jn, air = 0, 0, 0
  for _, e in ipairs(engines) do
    if e.jet then
      local j = M.byuid[e.uid]
      e.jk, e.jb = j and j.jk or 0, j and j.jb or 0
      if j then jk, jn, air = jk + j.s, jn + 1, M.diag and M.diag.air or 0 end
    end
  end
  -- the surfaces, posed
  for _, s in ipairs(M.surfs) do
    if s.ctl then
      local pv = aero_pivot(node, s.uid)
      if pv then pv.pitch = s.defl end
    end
  end
  -- the HUD: angle of attack and sideslip in the control frame, Mach, stall
  local F = AERO.frame
  local n = F and F.n or { x = 0, y = 1, z = 0 }
  local f = F and F.f or { x = 0, y = 0, z = -1 }
  local rgx, rgy, rgz = n.y * f.z - n.z * f.y, n.z * f.x - n.x * f.z, n.x * f.y - n.y * f.x
  local vn = env.vx * n.x + env.vy * n.y + env.vz * n.z
  local vf = env.vx * f.x + env.vy * f.y + env.vz * f.z
  local vr = env.vx * rgx + env.vy * rgy + env.vz * rgz
  local D = M.diag or {}
  AERO.hud = {
    aoa = V > 1 and math.deg(math.atan2(-vf, vn)) or 0, slip = V > 1 and math.deg(math.atan2(vr, vn)) or 0,
    mach = D.mach or 0, q = D.q or 0, stall = D.stall or 0, lift = D.lift or 0, drag = D.drag or 0,
    rho = rho, airspeed = V, trim = { p = T.p, y = T.y, r = T.r },
    jet = jn > 0 and { spool = jk / jn, air = air, n = jn } or nil,
  }
end

function fixedUpdate(node, dt)
  if not astronaut or not astronaut.valid then astronaut = find("Astronaut") end
  local info = assembly.info(node)

  -- State diagnostics + clamp redundancy: the moment the compound exists,
  -- say so — and on a builder launch, ENGAGE the clamps from this side too
  -- (belt and braces: a lost spawner callback must not leave the vessel
  -- loose on the pad). A piloted vessel with no compound for seconds is an
  -- impossible state worth shouting about.
  if info and not info_seen then
    info_seen = true
    if launch_mode and not released and not info.anchored then
      assembly.setAnchored(node, true)
      log("vessel: clamps engaged (" .. #info.parts .. " parts)")
    else
      log("vessel: compound live (" .. #info.parts .. " parts)")
    end
  end
  if piloting and not info then
    no_info_t = no_info_t + dt
    if no_info_t > 5.0 and no_info_t - dt <= 5.0 then
      log("vessel: PILOTED BUT NO PHYSICS ASSEMBLY under this root for 5s — " ..
        "the launch cannot proceed; please report this line")
    end
  else
    no_info_t = 0.0
  end

  -- Launch handoff: climb into the pod the moment the astronaut node exists.
  if boarding and astronaut then
    boarding = false
    piloting = true
    -- A crewed craft takes the crew; a PROBE is flown from the ground, and the
    -- crew stands at the base and watches it go.
    crewAboard = podCrewed == true
    -- (crewLaunch may hand the crew back: a restored craft they've left)
    if crewAboard then crewLaunch() end
    if piloting then astronaut.visible = (not crewAboard) or podSeat == true end
    if piloting then set_navball(true) end
    sas_mode, sas_last = "stability", "stability"
    log(crewAboard and "vessel: you're in the pod — SHIFT throttle, SPACE releases the clamps"
      or "vessel: probe on the pad, flown from the ground — SHIFT throttle, SPACE releases the clamps")
  end

  -- Runaway diagnostic (an uncontrolled vessel past 50 u/s = report data).
  if info and not piloting and not runaway_logged then
    local v = info.vel
    local speed = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
    if speed > 50 then
      runaway_logged = true
      log(string.format(
        "VESSEL RUNAWAY: speed %.0f  pos (%.1f, %.1f, %.1f)  grounded=%s",
        speed, node.x, node.y, node.z, tostring(info.grounded)))
    end
  end

  -- ---- damage: what did each part hit last tick, and how hard? -----------
  -- Runs piloted OR derelict — a parked ship hit by falling wreckage breaks
  -- all the same. (While clamped/anchored the sim makes no contacts.)
  -- The safety net reads this tick's state first (and logs what it clamps);
  -- then contact damage, then the joint-stress model. All three are globals or
  -- were already upvalues: this function sits at LuaJIT's 60-upvalue ceiling.
  -- The parts weigh what they carry (fuel, cargo) before anything pushes.
  if info then massSync(node, info) end
  if info then safetyTick(node, info, dt) end
  if info then damage_tick(node, info, dt) end
  if info then stressTick(node, info, dt) end
  if info and not destroyed then waterTick(node, info, dt) end
  -- DOCKING runs piloted or not — a station module has to keep its ports live
  -- so a lander can find them, and the soft-capture magnetism is mutual. Global
  -- call: `fixedUpdate` is at Lua's 60-upvalue ceiling and a global costs it
  -- nothing (same reason `power_tick` was exiled to lateUpdate).
  if info and not destroyed then dockTick(node, info, dt) end
  -- Wheels, actuators, the claw, the drill, fairings (round two): global, so
  -- this function spends no upvalue on them.
  if info and not destroyed then r2Tick(node, info, dt) end
  -- (Electrical power_tick runs in lateUpdate — fixedUpdate is at Lua's upvalue
  -- ceiling, so the power system lives in the post-writeback pass instead.)
  if destroyed then
    set_prompt("")
    -- A lost vessel drops off the tracker (inlined so fixedUpdate doesn't spend
    -- another upvalue on tracker_heartbeat — it's near Lua's 60-upvalue ceiling).
    if elec.link then
      elec.link = false
      local ships = save.get("comms.ships") or {}
      ships["v" .. tostring(node.id or 0)] = nil
      save.set("comms.ships", ships)
    end
    -- The breakup boom still shakes the (now on-foot) view, then settles.
    shake = shake * math.max(0.0, 1.0 - dt * 5.0)
    publish_shake(0.0)
    return -- a podless derelict: nothing left to board or fly
  end

  local px, py, pz = pod_world(node, info)
  local bx, by, bz = base_of(node, info)
  local rx, up, rz = basis(node)
  -- Ship frame: nose = stack axis (+Y), fwd = −Z column, right = fwd × nose.
  local nx, ny, nz = up.x, up.y, up.z
  local fx, fy, fz = -rz.x, -rz.y, -rz.z
  -- (a cockpit, or a command part laid down, flies by its own axes: aeroScan)
  if AERO.frame then nx, ny, nz, fx, fy, fz = aeroFrame(rx, up, rz) end
  -- The camera's orbit center: the CAPSULE's live world position (the root
  -- node sits at the stack base, and gravity-up offsets drift off the hull
  -- the moment the vessel pitches — world-exact is the only stable center).
  focusX, focusY, focusZ = px, py, pz
  -- Only the BOTTOM live stage burns: everything above the next decoupler
  -- waits its turn. No axial cuts left = every remaining engine fires.
  local cut = math.huge
  for _, ev in ipairs(events) do
    if ev.kind == "axial" and ev.y < cut then cut = ev.y end
  end

  -- ---- board / exit -------------------------------------------------------
  -- (an EVA asked between ticks: crew.eva, the no-pack confirm)
  if dock.evaPending then
    dock.evaPending = nil
    evaNow(true)
  end
  if input.pressed("f") and astronaut then
    if piloting and not crewAboard then
      -- Flying a probe from the ground: there is no hatch to step out of.
    elseif piloting then
      -- Out past the hull's widest reach on that side, never inside it: a crew
      -- capsule stepping out INTO a side booster is a body overlapping the
      -- hull, which the engine resolves as a collision (the launch fling).
      -- ...and never into anything else either (exitSpot tries the sides in
      -- turn for one clear of the pad, its clamps, a wall or the hull).
      -- crew.evaCheck decides whether they may (evaPress; a global, so this
      -- function spends no upvalue on it).
      evaPress(node, info)
    else
      boardNow(node, info)
    end
  end

  -- The seated astronaut rides the pod as a KINEMATIC passenger. "Bodies don't
  -- push each other" stopped being true in engine 0.104: a dynamic crew capsule
  -- parked inside the hull every tick was the launch fling (see seatCrew).
  if crewAboard and astronaut then
    seatCrew(node, true)
    astronaut.x, astronaut.y, astronaut.z = px, py, pz
    if info then
      astronaut.vx, astronaut.vy, astronaut.vz = info.vel.x, info.vel.y, info.vel.z
    else
      astronaut.vx, astronaut.vy, astronaut.vz = 0, 0, 0
    end
  end

  if not piloting then
    -- hand the crew back to physics if we were seating them — unless they're
    -- still in our seat while you fly something else
    if not crewAboard then seatCrew(node, false) end
    if dock.evaGuard then evaGuard(node, info) end
    -- Handed off (EVA, lost, staged): rejoin the LOD if we were kept live.
    if kept_live then
      assembly.keepLive(node, false)
      kept_live = false
    end
    -- (The hatch RING is drawn in lateUpdate — the camera pass — where the
    -- node pose matches what this frame renders; drawing it here put it a
    -- rails-carry beside the visible ship.)
    -- The prompt names the crew position F will put them in (the nearest).
    local bd, bst = nil, nil
    if astronaut and podCrewed and not crewAboard then bd, bst = board_dist(node, astronaut, info) end
    if bd and bd <= params.board_range + 1.4 and crewOnFoot(node.id) then
      set_prompt(boardPrompt(bst))
    else
      set_prompt("")
    end
    return
  end
  set_prompt("")
  if not info then
    tele = { waiting = true, parts = 0, parts_total = part_total, stages = {} }
    return
  end

  -- ---- the map is a fly-on-instruments view for a built vessel -----------
  -- KSP lets you FLY from the map — throttle up watching your trajectory bend,
  -- steer, stage — so a piloted vessel keeps FULL control while the map is
  -- open. (The cockpit stands down while it is; the map paints its own
  -- readout.)
  --
  -- The exception is PLAN mode, where the map's burn tuner takes the same six
  -- attitude keys. `planning` is the map saying so; `dock.plan` is us agreeing
  -- to keep our hands off until it lets go.
  local m = map()
  local map_open = (m and m.map_view) or false
  dock.map = map_open
  dock.plan = map_open and m and m.planning or false
  -- Flying from the map pulls the camera far back; keep this vessel exempt from
  -- distant-craft LOD while it's open so throttle/steering stay live and our
  -- orbital velocity keeps feeding the trajectory. Released when the map closes.
  if map_open ~= kept_live then
    assembly.keepLive(node, map_open)
    kept_live = map_open
  end

  -- ---- time warp (compounds coast on their own Kepler rails now) ---------
  local warp = space.warp()
  -- How fast the galaxy will let us go, and why.
  --
  -- Past this system, space is GENERATED as the ship reaches it. Warp is the
  -- one control that can outrun that: at 10000× the ship crosses a sector in
  -- the time the generator needs for a single world, so a fast enough warp
  -- would ask for dozens of star systems at once and the machine would spend
  -- the next minute building all of them. The ladder therefore has a ceiling,
  -- the galaxy owns it, and it drops while a system is actually being built.
  -- Inside the home system there is nothing to generate and the ceiling is
  -- infinite, so this costs nothing where it does not apply.
  --
  -- Written INLINE against a script-env global rather than as a file-scope
  -- helper on purpose: a local up there is an upvalue of this function, and
  -- this function already sits one under LuaJIT's 60-upvalue ceiling — adding
  -- one stopped the whole script loading (platform 0086). A global costs a
  -- table lookup and no upvalue. `findScript` is a full scene scan (0063), so
  -- the handle is cached and only re-resolved when it dies.
  local warp_cap, warp_why = math.huge, nil
  if not gx_ref or not gx_ref.valid then gx_ref = findScript("galaxy") end
  if gx_ref and gx_ref.valid then
    -- Plain calls, not method calls: an export on a script handle is a
    -- function, not a method (`rs.unlock(id)` everywhere else in this project).
    local ok, lim = pcall(gx_ref.maxWarp)
    if ok and type(lim) == "number" then
      warp_cap = lim
      local ok2, why = pcall(gx_ref.warpNote)
      if ok2 and type(why) == "string" then warp_why = why end
    end
  end
  -- A ceiling that drops UNDER the warp we are already at takes it down with
  -- it. This is the one that matters: the ceiling falls the instant the galaxy
  -- starts building a system, which is exactly when the ship must not be
  -- crossing a sector a second. A step down is said on screen (warpSay): a
  -- drop the player can't see the reason for reads as a broken key.
  if warp > warp_cap + 0.001 then
    local down = 1
    for _, w in ipairs(WARP_STEPS) do
      if w <= warp_cap + 0.001 then down = w end
    end
    if down < warp then
      space.warp(down)
      warpSay(string.format("Warp ×%d · %s", down, warp_why or "limited out here"))
      warp = down
    end
  end
  if input.pressed(".") or input.pressed(",") then
    local dir = input.pressed(".") and 1 or -1
    local idx = 1
    for i, w in ipairs(WARP_STEPS) do
      if warp >= w - 0.5 then idx = i end
    end
    local nxt = WARP_STEPS[math.max(1, math.min(#WARP_STEPS, idx + dir))]
    -- Refusing to go UP is not the same as being dragged down: say why, or the
    -- key just stops working and that reads as a broken control.
    if nxt > warp and nxt > warp_cap + 0.001 then
      warpSay(warp_why and ("Warp limited · " .. warp_why)
        or string.format("Warp limited to ×%d out here", math.floor(warp_cap)))
      nxt = warp
    end
    if nxt > warp then
      -- KSP rules: no thrust, and either parked or high enough that the
      -- conic can't clip terrain this instant.
      local alt_ok = info.grounded or info.anchored or R2.onWheels
      local d0 = space.dominant(node.x, node.y, node.z)
      local b0 = d0 and space.body(d0)
      if not alt_ok and b0 then
        local rr = math.sqrt((bx - b0.x) ^ 2 + (by - b0.y) ^ 2 + (bz - b0.z) ^ 2)
        alt_ok = rr - b0.radius > 40.0
      end
      if throttle > 0.01 then
        warpSay("Warp limited · cut the throttle first")
        nxt = warp
      elseif evaBlocksWarp() then
        warpSay("Warp limited · crew on EVA in space")
        nxt = warp
      elseif not alt_ok then
        warpSay("Warp limited · too low to coast (under 40 m)")
        nxt = warp
      end
    end
    if nxt ~= warp then
      space.warp(nxt)
      warp = nxt
    end
  end
  -- Hands on the stick cancel warp — the rails own the ship up there. (This
  -- holds in the map too now: the map is a live flying view, so any control
  -- input there should still drop warp, same as out of it.)
  if warp > 1.001 then
    local touched = input.key("shift") or input.key("ctrl") or input.key("z")
      or input.key("w") or input.key("a") or input.key("s") or input.key("d")
      or input.key("q") or input.key("e")
    if touched then
      space.warp(1)
      warp = 1
      warpSay("Warp ×1 · controls")
    end
  end

  -- ---- throttle + pooled fuel (live in the map too) ----------------------
  -- No control (a probe out of contact or dark): the throttle stays where it
  -- was left, except that a dark probe's engines have nobody to keep them lit.
  if elec.control ~= false then
    if input.key("shift") then throttle = throttle + params.throttle_rate * dt end
    if input.key("ctrl") then throttle = throttle - params.throttle_rate * dt end
    if input.key("x") and not input.key("alt") then throttle = 0.0 end
    if input.key("z") then throttle = 1.0 end
  elseif elec.why and elec.why:sub(1, 8) == "NO POWER" then
    throttle = 0.0
  end
  throttle = math.max(0.0, math.min(1.0, throttle))
  if fuel <= 0.0 then throttle = 0.0 end
  local burn_total = 0.0
  for _, e in ipairs(engines) do
    -- (a jet burns by what its spool and its air let it: aeroTick's e.jb)
    if engine_active(e, cut) then burn_total = burn_total + e.burn * (e.jet and (e.jb or 0) / math.max(throttle, 0.05) or 1) end
  end
  local refueling = false
  if info.anchored and fuel < fuel_cap then
    fuelFill(math.min(fuel_cap, fuel + params.refuel_rate * dt))
    refueling = true
  elseif throttle > 0 and not info.anchored then
    fuelDraw(throttle * burn_total * dt)
  end

  -- ---- thrust at every ACTIVE engine's offset, along ITS OWN axis --------
  local total_thrust = 0.0
  for _, e in ipairs(engines) do
    if engine_active(e, cut) then total_thrust = total_thrust + e.thrust end
  end
  THRUST_LIVE = 0.0 -- what the engines deliver now, in this air (the HUD's THRUST/TWR)
  if throttle > 0 and not info.anchored and fuel > 0 then
    -- NOZZLES (rating version 3, parts_registry ENGINE NICHES): a rocket's
    -- thrust falls in thick air by its nozzle's sea-level share `asl` (the
    -- blueprint's; absent on older builds = the same everywhere), at the burn
    -- rate it always had: k = 1 − (1 − asl)·σ. σ is the air's density over
    -- reference sea level: the AIR BAND the chutes, drag and heating read
    -- (airBandAt, the aero curve on a deep-air world) times the world's
    -- ground density (its record's atmo over aero.lua's ATMO_REF 0.75), so
    -- engines and drag agree. Globals only: this function is at its upvalue
    -- ceiling.
    local sig = 0.0
    do
      local dom = space.dominant(node.x, node.y, node.z)
      local db = dom and space.body(dom)
      if db and db.radius then
        local dx, dy, dz = node.x - db.x, node.y - db.y, node.z - db.z
        local share = airBandAt(db, math.sqrt(dx * dx + dy * dy + dz * dz) - db.radius)
        local w = AIRBAND.w
        sig = math.max(0.0, math.min(2.5, share * ((w and w.atmo) or 0) / 0.75))
      end
    end
    for _, e in ipairs(engines) do
      if engine_active(e, cut) then
        -- Physics-fresh base: thrust lands ON the hull, not a rails-carry
        -- beside it (the old node-pose math was a constant torque bias).
        local ex = bx + rx.x * e.x + up.x * e.y + rz.x * e.z
        local ey = by + rx.y * e.x + up.y * e.y + rz.y * e.z
        local ez = bz + rx.z * e.x + up.z * e.y + rz.z * e.z
        -- The engine's blueprint orientation IS its thrust axis (its local
        -- +Y in the vessel frame) — a sideways engine pushes sideways, which
        -- is what makes rocket cars and lateral thrusters real.
        local wdx = rx.x * e.dx + up.x * e.dy + rz.x * e.dz
        local wdy = rx.y * e.dx + up.y * e.dy + rz.y * e.dz
        local wdz = rx.z * e.dx + up.z * e.dy + rz.z * e.dz
        local asl = e.rec and e.rec.asl
        local nk = (asl and asl < 1) and math.max(0.05, 1.0 - (1.0 - asl) * sig) or 1.0
        local f = e.thrust * (e.jet and (e.jk or 0) or throttle * nk)
        THRUST_LIVE = THRUST_LIVE + f
        assembly.forceAt(node, vec3(wdx * f, wdy * f, wdz * f), vec3(ex, ey, ez))
        stressForce(e.uid, wdx * f, wdy * f, wdz * f) -- (booked on the engine for the stress model)
      end
    end
  end
  set_flames(node, (info.anchored or fuel <= 0) and 0 or throttle, cut)

  -- ---- engine audio: ignition crack + a loop that rides the throttle ------
  local burning = throttle > 0.02 and not info.anchored and fuel > 0 and total_thrust > 0
  if burning and throttle_prev <= 0.02 then
    -- The ignition crack fires at the base of the stack.
    sfx3(SFX.ignite, bx, by, bz, 0.9, 1.0)
    caption("the engines light")
  end
  update_engine_audio(node, burning, throttle)
  throttle_prev = burning and throttle or 0.0

  -- ---- ground FX: touchdown dust + a rolling exhaust cloud under thrust ----
  -- The ground contact point is a touch below the stack base.
  local gsd = terrain.query(bx, by, bz)
  local near_ground = info.grounded or (gsd ~= nil and gsd < 4.0)
  -- A TOUCHDOWN is a landing: the craft was off the ground for a while first.
  -- A rover's contact flag flickers over every bump at speed, and each flicker
  -- used to ring a metal clank and print "touchdown" (50 in a 25 s drive).
  if not info.grounded then SFX.live.air_since = SFX.live.air_since or time end
  if info.grounded and not was_grounded and time - (SFX.live.air_since or time) > 0.6 then
    -- Touching down is worth saying however gently it happened — the dust and
    -- the thump below are gated on landing HARD, and a caption that only fires
    -- on a bad landing would tell a player they had crashed and nothing else.
    caption("touchdown")
    -- Only kick up dust for a real touchdown, not a creep onto the pad.
    local vv = info.vel
    local sp = math.sqrt(vv.x * vv.x + vv.y * vv.y + vv.z * vv.z)
    if sp > 1.5 then
      local fx = fxd()
      if fx then fx.touchdown(bx, by, bz, sp) else spawnEffect("TouchDust", bx, by, bz) end
      sfx3(SFX.thump, bx, by, bz, math.min(0.9, 0.3 + sp * 0.05), 1.0)
      add_shake(math.min(0.5, sp * 0.03)) -- a firm touchdown thuds the view
    end
  end
  was_grounded = info.grounded or false
  if info.grounded then SFX.live.air_since = nil end
  if burning and near_ground and time - launch_dust_t > 0.16 then
    launch_dust_t = time
    -- The ground blast under the engines is vfx.lua's (it follows each
    -- plume down to the ground); this one-shot is the harness fallback.
    if not fxd() then spawnEffect("LaunchDust", bx, by, bz) end
  end

  -- ---- reentry / atmospheric heating -------------------------------------
  -- Below the atmo band (alt < 35% of the body's radius) the air bites: WIND
  -- roars (proportional to density × speed), a mild aero DRAG bleeds you when
  -- you coast in fast (so slowing down actually matters — Ty's ask), and past
  -- ~35 m/s the windward parts turn speed into HEAT (flux ~ density^1.5 · v³)
  -- — fire licks off them and a part that cooks through breaks up in flight.
  heating = 0.0
  wind_intensity = 0.0
  do
    -- space.dominant can return nil while the galaxy is still streaming in
    -- (right after a launch, before the dominant body is resolved); guard it
    -- or space.body(nil) throws every frame and aborts the rest of the update.
    local dom2 = space.dominant(node.x, node.y, node.z)
    local db2 = dom2 and space.body(dom2)
    if db2 and not info.anchored and not info.grounded and not R2.onWheels then
      local dxh, dyh, dzh = node.x - db2.x, node.y - db2.y, node.z - db2.z
      local alt = math.sqrt(dxh * dxh + dyh * dyh + dzh * dzh) - db2.radius
      -- (the band's density, from airBandAt: the deep air of a scale-4 world
      -- reaches its published top; `band` is just "still inside the air")
      local band_d = airBandAt(db2, alt)
      local band = band_d > 0 and math.huge or -math.huge
      local v = info.vel
      local spd = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
      -- Wind + drag live across the WHOLE band (not just when hot).
      -- ALTITUDE IS ABOVE THE BODY'S NOMINAL RADIUS, and real ground can lie
      -- BELOW it (Golilil's pad sits 7.6 m under its datum). Every air effect
      -- used to be gated on alt > 0, so the last metres above any low ground
      -- had no air at all: a craft slowed to 5.8 m/s under its chute fell the
      -- rest of the way unbraked and broke at 9.6 m/s. Below the datum the
      -- air is simply sea-level air.
      if alt < band then
        local dens = math.min(1.0, band_d)
        wind_intensity = dens * math.min(1.4, math.max(0.0, (spd - 8.0) / 80.0))
        -- Aero drag opposes velocity through the CoM (∝ density · v²). Gated to
        -- fast UNPOWERED flight: coasting/reentry is where "slow down" bites,
        -- and it leaves powered ascent (and the tuned smoke force counts) alone.
        local vk = worldScaleK()
        if spd > 45.0 * vk and throttle < 0.02 then
          -- Same half-the-speed-per-tick ceiling as the chute drag below.
          local dk = math.min(0.0045, 0.5 * info.mass / (dt * spd * dens + 1e-9))
          assembly.force(node, vec3(
            -v.x * spd * dens * dk, -v.y * spd * dens * dk, -v.z * spd * dens * dk))
          stressLead(-v.x * spd * dens * dk, -v.y * spd * dens * dk, -v.z * spd * dens * dk)
        end
        -- VISUAL reentry glow, DECOUPLED from damage: plasma licks off the windward
        -- side from ~45 m/s (scaled by density × speed), so a normal descent looks
        -- hot even though the part-cooking DAMAGE pass below only bites past 90 m/s.
        -- (Previously the Heat effect only ever spawned inside the >90 damage gate, so
        -- ordinary reentries showed nothing.) Streams off the nose, riding ship velocity.
        local glow = math.max(0.0, (spd - 45.0 * vk) / (130.0 * vk)) * dens
        local hfx = glow > 0.04 and fxd()
        if hfx then
          hfx.heat(node, glow, v.x, v.y, v.z)
        elseif glow > 0.04 and time - heat_fx_t > (0.30 - math.min(0.18, glow * 0.2)) then
          heat_fx_t = time
          local gs = math.max(spd, 1e-3)
          local gvx, gvy, gvz = v.x / gs, v.y / gs, v.z / gs
          local grx, gup, grz = basis(node)
          local gbx, gby, gbz = base_of(node, info)
          spawnEffect("Heat",
            gbx + gvx * 1.2 + gup.x * 0.8,
            gby + gvy * 1.2 + gup.y * 0.8,
            gbz + gvz * 1.2 + gup.z * 0.8)
        end
      end
      local vk2 = worldScaleK()
      if alt < band and spd > 90.0 * vk2 then
        -- Heating only bites at genuinely reckless speed now. The old curve
        -- (onset 35 m/s, (spd/40)³·0.06) cooked a normal ascent/descent — a
        -- ~146 m/s craft burned up in a second, which made the ship untestable.
        -- Onset 90 m/s, a gentler cube and coefficient: you can fly fast, but a
        -- screaming-fast reentry (250+ m/s) still lights you up over a few s.
        local density = math.min(1.0, band_d)
        heating = density ^ 1.5 * (spd / (130.0 * vk2)) ^ 3 * 0.03 -- dmg/sec at the nose
        local ivx, ivy, ivz = v.x / spd, v.y / spd, v.z / spd
        local rx2, up2, rz2 = basis(node)
        -- Rank parts by how far forward they sit along the velocity.
        local best_proj = -math.huge
        for uid2, d2 in pairs(bp_by_uid) do
          if part_hp[uid2] and part_hp[uid2] > 0 then
            local wx = rx2.x * d2.x + up2.x * d2.y + rz2.x * d2.z
            local wy = rx2.y * d2.x + up2.y * d2.y + rz2.y * d2.z
            local wz = rx2.z * d2.x + up2.z * d2.y + rz2.z * d2.z
            local proj = wx * ivx + wy * ivy + wz * ivz
            if proj > best_proj then best_proj = proj end
          end
        end
        for uid2, d2 in pairs(bp_by_uid) do
          local hp2 = part_hp[uid2]
          -- (a payload inside its fairing takes no heat: the shell does)
          if hp2 and hp2 > 0 and not ((d2.faired or 0) ~= 0 and r2Faired(d2)) then
            local wx = rx2.x * d2.x + up2.x * d2.y + rz2.x * d2.z
            local wy = rx2.y * d2.x + up2.y * d2.y + rz2.y * d2.z
            local wz = rx2.z * d2.x + up2.z * d2.y + rz2.z * d2.z
            local proj = wx * ivx + wy * ivy + wz * ivz
            -- Windward third takes the flux; leeward parts ride in the wake.
            if proj > best_proj - 1.0 then
              part_hp[uid2] = hp2 - heating * dt
              if part_hp[uid2] <= 0 then
                local px2, py2, pz2 = bx + wx, by + wy, bz + wz
                local c2 = nil
                for _, ch in ipairs(node:children()) do
                  if math.abs((ch.x or 0) - d2.x) < 0.05 and math.abs((ch.y or 0) - d2.y) < 0.05
                    and math.abs((ch.z or 0) - d2.z) < 0.05 then
                    c2 = ch
                    break
                  end
                end
                break_part(node, uid2, d2, c2, px2, py2, pz2)
                log("burned up on reentry: " .. (d2.label or d2.id or "part"))
              end
            end
          end
        end
        -- (The plasma VFX is now spawned by the decoupled glow block above, which
        -- covers this >90 regime too — no separate spawn here.)
      end

      -- ---- PARACHUTE DRAG: the reason the atmosphere is here -------------
      -- An open canopy in thick air drags HARD against velocity, opposing
      -- your fall — a soft touchdown instead of a lithobraking. Drag scales
      -- with air density and v² (real aero), pooled across every open chute,
      -- and it pulls at the CANOPY, so a craft hangs pod-up under it (see
      -- chuteDrag).
      if chutes_deployed and #chutes > 0 and alt < band then
        -- Drag ∝ air density · v² (real aero), pooled across every open chute
        -- and scaled by how full the canopy is (chute_anim, driven by
        -- update_chutes). Through the CoM so it decelerates without tumbling.
        local density = math.min(1.0, band_d)
        -- Terminal speed under the canopies is sqrt(m·g / (k·density)). At 0.9
        -- the starter rocket (3.6 t) came down at 5.8 m/s on an 8.4 g world —
        -- a hard landing for a first flight; 1.3 gives 4.8 m/s there and
        -- 3.7 m/s on Bryolru (g 4.9).
        local drag_k = 1.3 * #chutes * chute_anim
        -- NEVER more than half the speed in one tick. Drag ∝ v² with a canopy
        -- this size is ~5,000 m/s² at 150 m/s: integrated explicitly that is a
        -- Δv bigger than v itself, which REVERSED the craft and fired it back
        -- up the way it came. Real drag can only ever slow you to rest. (A
        -- canopy opened that fast tears off anyway — see stressTick.)
        local cap = (spd * density * drag_k > 0)
          and math.min(1.0, 0.5 * info.mass / (dt * spd * density * drag_k)) or 1.0
        drag_k = drag_k * cap
        local fx3 = -v.x * spd * density * drag_k
        local fy3 = -v.y * spd * density * drag_k
        local fz3 = -v.z * spd * density * drag_k
        if not info.anchored then
          chuteDrag(node, info, fx3, fy3, fz3, dt)
        end
      end
    else
      chute_anim = 0.0
    end
  end
  -- The roar rides the wind (density × speed) and climbs with reentry heat.
  do
    local v = info.vel
    local spd = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
    update_wind_audio(node, wind_intensity, heating, spd)
  end

  -- ---- screen shake: decay the transient, add the continuous, publish -----
  shake = shake * math.max(0.0, 1.0 - dt * 5.0)
  local base = 0.0
  if piloting then
    base = math.min(0.55, wind_intensity * 0.4)            -- atmospheric buffet
    if burning and near_ground then base = base + throttle * 0.14 end -- liftoff rumble
    if heating > 0.05 then base = base + math.min(0.35, heating * 1.5) end
  end
  publish_shake(base)

  -- ---- attitude: rate-commanded, the KSP feel ----------------------------
  -- THE KEYS: T (SAS), R (RCS), G U Y B, Backspace (abort) and 1–0 are the
  -- action groups now (groupKeysTick, a global — this function has no upvalues
  -- to spare); ALT+1…9 pick the autopilot hold. With no control, none answer.
  groupKeysTick(node, info)
  update_peripherals(node, dt)
  -- Translation + hull contact. Both are globals so `fixedUpdate` spends no
  -- upvalue on them (it sits at Lua's 60-upvalue ceiling; see `power_tick`).
  rcsTick(node, info, dt)
  hullBump(node, info, dt)
  update_chutes(node, dt)
  -- In the map's PLAN mode these six keys are moving the burn, not the craft.
  -- Reading them here as well would fly the ship every time you tuned a node.
  local stick = not dock.plan and elec.control ~= false and not R2.driving and not input.key("alt")
  local p = stick and ((input.key("w") and 1 or 0) - (input.key("s") and 1 or 0)) or 0
  local y = stick and ((input.key("a") and 1 or 0) - (input.key("d") and 1 or 0)) or 0
  local r = stick and ((input.key("e") and 1 or 0) - (input.key("q") and 1 or 0)) or 0
  if AERO.cmd and stick then p, y, r = aeroCmd(p, y, r) end
  local rgx, rgy, rgz = cross(fx, fy, fz, nx, ny, nz) -- ship right
  local w = info.angVel
  local manual = (p ~= 0 or y ~= 0 or r ~= 0)
  local sas_on = sas_mode ~= "off"
  local sasm_x, sasm_y, sasm_z
  -- Desired world angular velocity, decomposed on the ship basis.
  local dwx, dwy, dwz
  -- A ROVER OFF THE GROUND keeps the rover's keys, on the rover's own axes
  -- (r2AirStick): W/S lean the nose back/forward like a dirt bike, A/D keep
  -- steering (a gentle turn, as they steer on the ground, so steering off a
  -- bump never tips the rover), Q/E lean the roof left/right; each a gentle
  -- lean from the attitude it took off with. The ship's axes put "pitch"
  -- about the rover's front, so W rolled a jumping rover to the right
  -- (playtest 2026-10-26). The stick's own k.y is the lean key and k.r the
  -- turn key, so the keys are handed over swapped: lean = Q − E, turn = D − A.
  if r2AirMode(info) then
    R2.air0 = R2.air0 or {}
    dwx, dwy, dwz = r2AirStick({ p = p, y = -r, r = -y }, rx, up, rz, w, sas_on, nil, R2.air_up, R2.air0)
    p, y, r = 0, 0, 0   -- (no control surface answers the rover's lean)
    R2.airStick = true
  elseif manual or sas_mode == "stability" or sas_mode == "off" then
    -- Current rates on the ship axes (so released axes can persist SAS-off).
    local cur_p = w.x * rgx + w.y * rgy + w.z * rgz
    local cur_y = w.x * fx + w.y * fy + w.z * fz
    local cur_r = w.x * nx + w.y * ny + w.z * nz
    local hold = sas_on and 0 or nil
    local want_p = p ~= 0 and p * params.max_rate or (hold or cur_p)
    local want_y = y ~= 0 and y * params.max_rate or (hold or cur_y)
    local want_r = r ~= 0 and r * params.max_rate or (hold or cur_r)
    if not manual and sas_mode == "off" then
      want_p, want_y, want_r = cur_p, cur_y, cur_r
    end
    dwx = rgx * want_p + fx * want_y + nx * want_r
    dwy = rgy * want_p + fy * want_y + ny * want_r
    dwz = rgz * want_p + fz * want_y + nz * want_r
  else
    -- Pointing autopilot: rotate the nose toward the target with the KSP
    -- braking law (fastest rate that can still stop on arrival).
    --
    -- DOCK ALIGN (mode "dock", key 8) is the SAME law about a different vector:
    -- it swings whichever PORT you're flying onto the approach corridor. That
    -- distinction is the whole feature — aiming the nose at the target is
    -- wrong for a side berth and wrong for a belly port, and it's why lining
    -- up by hand was so miserable. Align the port, not the ship.
    local cur_x, cur_y, cur_z = nx, ny, nz
    local tx, ty, tz
    if sas_mode == "dock" then
      local t = dock.target
      if t and t.mx then
        local p
        for _, q in ipairs(dock.ports) do
          if q.uid == t.port then p = q end
        end
        if p then
          cur_x = rx.x * p.ax + up.x * p.ay + rz.x * p.az
          cur_y = rx.y * p.ax + up.y * p.ay + rz.y * p.az
          cur_z = rx.z * p.ax + up.z * p.ay + rz.z * p.az
          tx, ty, tz = t.max, t.may, t.maz
        end
      end
    elseif sas_mode == "target" or sas_mode == "antitarget" then
      dwx, dwy, dwz, sasm_x, sasm_y, sasm_z = targetHold(node, nx, ny, nz)
    else
      local ddom = space.dominant(node.x, node.y, node.z)
      local db = ddom and space.body(ddom)
      tx, ty, tz = sas_target_dir(node, db, sas_mode)
    end
    if tx then
      sasm_x, sasm_y, sasm_z = tx, ty, tz
      local axx, axy, axz = cross(cur_x, cur_y, cur_z, tx, ty, tz)
      local s = math.sqrt(axx * axx + axy * axy + axz * axz)
      local c = cur_x * tx + cur_y * ty + cur_z * tz
      if s > 1e-5 then
        local theta = math.atan2(s, c)
        local rate = math.min(params.max_rate, math.sqrt(2 * params.rate_accel * theta))
        dwx, dwy, dwz = (axx / s) * rate, (axy / s) * rate, (axz / s) * rate
      else
        dwx, dwy, dwz = 0, 0, 0
      end
    elseif not dwx then
      dwx, dwy, dwz = 0, 0, 0
    end
  end
  -- (soft capture owns the attitude while it draws the ports together: the
  -- wheels would hold the craft against it)
  if dock.soft and not manual then dwx, dwy, dwz = w.x, w.y, w.z end
  -- THE AIR: per-part drag and lift, the control surfaces on the stick (and
  -- the SAS's rate error), the jets' thrust for the next tick.
  aeroTick(node, info, dt, throttle, p, y, r, dwx - w.x, dwy - w.y, dwz - w.z, rgx, rgy, rgz, fx, fy, fz, nx, ny, nz)
  -- Authority is the REACTION WHEELS', and only the powered ones (torque_k: 1
  -- for a pod's, less for a probe core's, 0 flat). The wheels' draw follows
  -- how hard they're working (wheel_use).
  local tk = (elec.torque_k or 1.0) * params.torque
  -- (a rover in the air leans gently: half the wheels' authority)
  if R2.airStick then tk = tk * ROVER_AIR_TK; R2.airStick = nil end
  -- (A rover on its wheels steers with them: WASD is the drive, not the
  -- stick; with SAS on, the reaction wheels only steady its pitch and roll.)
  if not info.anchored and warp <= 1.001 and R2.driving then
    if sas_mode ~= "off" then r2Steady(node, info, tk, dt) end
    elec.wheel_use = 0.2
  elseif not info.anchored and warp <= 1.001 then
    wheelTorque(node, info, dwx - w.x, dwy - w.y, dwz - w.z, tk, dt)
    elec.wheel_use = math.min(1, math.sqrt((dwx - w.x) ^ 2 + (dwy - w.y) ^ 2 + (dwz - w.z) ^ 2) * 2.0)
  else
    elec.wheel_use = 0
  end

  -- ---- SPACE: clamps first, then boosters, then axial stages (live in map) -
  if input.pressed("space") and elec.control == false then
    caption("no control — " .. (elec.why or "no signal"))
  elseif input.pressed("space") then
    if info.anchored or (launch_mode and not released) then
      -- The clamps (and the SELF-HEAL for a mid-launch sim rebuild that cleared
      -- the anchored flag before we ever released — `released` must latch or
      -- damage stays disarmed forever) live in ONE place, `releaseClamps`,
      -- which probes call too since a headless run cannot press SPACE.
      releaseClamps()
    elseif #events > 0 then
      stageNext()
    end
  end

  update_navball(node, nx, ny, nz, fx, fy, fz, sasm_x, sasm_y, sasm_z)

  -- ---- has this craft actually FLOWN? ------------------------------------
  -- Released from the clamps AND then off the ground for a second or 5 m up.
  -- Sitting on the pad is not a flight: the end-of-flight card offered to
  -- RECOVER a rocket that had never left it, and "land intact" ticked there.
  -- Latch state lives on the published `flown` table, not in locals — this
  -- function is at LuaJIT's 60-upvalue ceiling and a global costs none.
  if not hasFlown and not info.anchored then
    local fd = space.dominant(node.x, node.y, node.z)
    local fb = fd and space.body(fd)
    local fr = fb and math.sqrt((bx - fb.x) ^ 2 + (by - fb.y) ^ 2 + (bz - fb.z) ^ 2) or 0
    flown.alt0 = flown.alt0 or fr
    flown.air = (info.grounded or R2.onWheels) and 0.0 or (flown.air + dt)
    if flown.air >= 1.0 or fr - flown.alt0 > 5.0 then hasFlown = true end
    -- Left the launch spot (see `leftPad`): more than 4 m from it, in the
    -- body's frame (the planet moves on rails under us).
    if fb and not leftPad then
      local ox, oy, oz = bx - fb.x, by - fb.y, bz - fb.z
      flown.p0 = flown.p0 or { ox, oy, oz }
      local q = flown.p0
      if (ox - q[1]) ^ 2 + (oy - q[2]) ^ 2 + (oz - q[3]) ^ 2 > 16.0 then leftPad = true end
    end
  end

  -- ---- telemetry (10 Hz) → `tele`, drawn by scripts/flight_hud.lua ---------
  -- This function only MEASURES. Everything the pilot reads is laid out by the
  -- flight HUD from this one table, which is also what keeps the rendering out
  -- of a function with no upvalues left to spend.
  if time - hud_t >= 0.1 then
    hud_t = time
    local t = {
      warp = warp, warp_cap = warp_cap, warp_why = warp_why,
      anchored = info.anchored, grounded = info.grounded or R2.onWheels,
      -- in the water (waterTick): the HUD's situation reads SPLASHED
      splashed = isSplashed(),
      situation = isSplashed() and "SPLASHED" or ((info.grounded or R2.onWheels) and "LANDED" or nil),
      ready = assembly_ready(info), parts = #info.parts, parts_total = part_total,
      -- TWR is finished below, once the local gravity is known (not 9.81).
      mass = info.mass,
      fuel_cap = fuel_cap, refueling = refueling,
      ec = elec.charge, ec_cap = elec.cap, ec_gen = elec.gen,
      ec_net = elec.net or 0, ec_supply = elec.supply or 0, ec_demand = elec.demand or 0,
      brownout = elec.brownout, sunlit = elec.sunlit, panels = elec.panels or 0,
      comms = elec.comms, link = elec.link, dish_up = DEVICES.comms.on,
      signal = elec.signal or 0, hops = elec.hops or 0, path = elec.path,
      bandwidth = elec.bandwidth or 0,
      control = elec.control ~= false, ctl_mode = elec.mode, ctl_why = elec.why,
      crew = crewAboard == true, probe = elec.probePart ~= nil,
      solar = (elec.panels or 0) > 0 and (elec.gen or 0) > 0,
      has_gear = #DEVICES.gear.parts > 0, has_rcs = #DEVICES.rcs.parts > 0,
      rcs_on = DEVICES.rcs.on, rcs_blocks = #DEVICES.rcs.parts,
      chute_open = chute_anim,
      -- the air (aeroTick): aoa, slip, mach, q, stall, trim, jet
      aero = AERO.hud,
    }
    local dom = space.dominant(node.x, node.y, node.z)
    local b = dom and space.body(dom)
    if b then
      local dxr, dyr, dzr = node.x - b.x, node.y - b.y, node.z - b.z
      local rlen = math.sqrt(dxr * dxr + dyr * dyr + dzr * dzr)
      local spd = math.sqrt(node.vx ^ 2 + node.vy ^ 2 + node.vz ^ 2)
      t.alt, t.spd = rlen - b.radius, spd
      t.vspd = (node.vx * dxr + node.vy * dyr + node.vz * dzr) / rlen
      t.nose = math.deg(math.asin(math.max(-1, math.min(1,
        (nx * dxr + ny * dyr + nz * dzr) / rlen))))
      t.vorb = math.sqrt(b.mu / rlen)
      t.g = b.mu / (rlen * rlen)
      t.vesc = t.vorb * 1.41421
      local o = space.elements(node.x, node.y, node.z, node.vx, node.vy, node.vz)
      if o then
        t.body, t.pe = o.body, o.periapsis - b.radius
        if o.apoapsis then t.ap, t.period = o.apoapsis - b.radius, o.period end
      end
    end
    -- Damage: the worst-off surviving part (the smoke tells you where).
    for uid, hp in pairs(part_hp) do
      if hp > 0 and hp < 1 and (not t.hp or hp < t.hp) then
        local d = bp_by_uid[uid]
        t.hp, t.hp_part = hp, (d and (d.label or d.id)) or "part"
      end
    end
    -- The stage stack, in firing order: what each SPACE does, and what burns
    -- after it. Burning now = the live axial stage + every attached booster.
    local n_act, th_act, b_act = 0, 0, 0
    for _, e in ipairs(engines) do
      if engine_active(e, cut) then
        n_act, th_act, b_act = n_act + 1, th_act + e.thrust, b_act + (e.burn or 0)
      end
    end
    t.eng, t.thrust = n_act, th_act
    -- The TRUE wet mass (blueprint dry parts + propellant + hold), and what
    -- the fuel aboard is worth on the engines lit now:
    -- Δv by Tsiolkovsky, and seconds at full throttle.
    local fm = fuelMass()
    local dry_t, wet_t = trueMass()
    t.fuel_t, t.mass, t.dry = fm, wet_t, dry_t
    local ft = (fuel > 0) and fm / fuel or 0
    -- Staged like the builder's TOTAL (equal to the plain Tsiolkovsky figure
    -- for a single stage); `dv_now` is the whole pool on the engines lit now.
    t.dv_now = (b_act > 0 and ft > 0 and dry_t > 0)
      and th_act / (b_act * ft) * math.log(wet_t / dry_t) or 0
    t.dv = stagedDv()
    t.burn_s = (b_act > 0) and fuel / b_act or 0
    -- What the engines are PRODUCING (0 on the clamps, at idle or with dry
    -- tanks) and the TWR of that, in the local gravity; `twr_max` is the
    -- full-throttle figure, which is what the builder quotes at the pad.
    -- THRUST_LIVE is the force the thrust loop put on the hull this frame:
    -- a nozzle's sea-level loss in thick air and a jet's spool are in it.
    local gl = t.g or 0
    t.thrust_now = (info.anchored or fuel <= 0) and 0 or (THRUST_LIVE or th_act * throttle)
    t.twr = (t.mass > 0 and gl > 0) and t.thrust_now / (t.mass * gl) or 0
    t.twr_max = (t.mass > 0 and gl > 0) and th_act / (t.mass * gl) or 0
    t.stages = {}
    for i, ev in ipairs(events) do
      local st = { kind = ev.kind, eng = 0, kn = 0 }
      if ev.kind == "ring" then
        -- The boosters this ring throws away, engines and all.
        st.n = #ev.branches
        local mine = {}
        for _, g in ipairs(ev.branches) do mine[g.uid] = true end
        for _, e in ipairs(engines) do
          if e.branch and mine[e.branch] then st.eng, st.kn = st.eng + 1, st.kn + e.thrust end
        end
      elseif ev.kind == "chute" then
        st.n = #ev.uids
      elseif ev.kind == "fairing" then
        st.n = 1
      else
        -- The engines this cut uncovers: above it, below the next cut up.
        local above = math.huge
        for j = i + 1, #events do
          local e2 = events[j]
          if e2.kind == "axial" and e2.y > ev.y and e2.y < above then above = e2.y end
        end
        for _, e in ipairs(engines) do
          if not e.branch and e.y >= ev.y and e.y < above - 0.01 then
            st.eng, st.kn = st.eng + 1, st.kn + e.thrust
          end
        end
      end
      -- one card a SPACE: events the builder put in one stage fire together
      local prev = t.stages[#t.stages]
      local evp = events[i - 1]
      if prev and evp and ev.stage and ev.stage < 1e6 and evp.stage == ev.stage then
        prev.also = prev.also or {}
        prev.also[#prev.also + 1] = st
        prev.eng, prev.kn = prev.eng + st.eng, prev.kn + st.kn
      else
        t.stages[#t.stages + 1] = st
      end
    end
    tele = t
  end
end

-- Camera-pass drawing: the hatch ring must sit on the ship THE FRAME RENDERS
-- (lateUpdate reads post-writeback poses) — drawn from fixedUpdate it floats
-- a rails-carry beside the hull on any orbiting world.
function lateUpdate(node, dt)
  -- the live tyres as drawn: along their steered axles, rolling
  if R2.live then r2TyreVisuals(node, dt) end
  -- forks, swing arms and struts follow their wheels (auto-engineering)
  if #R2.wheels > 0 and AUTO.lib then motoVisuals(node, dt) end
  -- A craft nobody is flying still folds and points what it's told to (the
  -- Tracking Station, a docked partner's groups) — the piloted one does this in
  -- its fixed tick.
  if not piloting and not destroyed and (elec.gen_seen or -1) >= 0 then update_peripherals(node, dt) end
  -- Electrical system runs here (post-writeback): solar charge, comms draw and
  -- the tracker heartbeat. It lives in lateUpdate, not fixedUpdate, purely
  -- because fixedUpdate is at Lua's 60-upvalue ceiling. Runs piloted OR derelict.
  if not destroyed then
    local einfo = assembly.info(node)
    if einfo then power_tick(node, einfo, dt) end
  end
  if piloting then dockGuides() end
  -- the avatar's member always has a seat while it rides (an old save's craft)
  if crewAboard and (time or 0) - (CREWLIB.chk or -10) > 1.0 then
    CREWLIB.chk = time or 0
    seatAvatarCheck()
  end
  -- A seat whose part has gone (shed, staged) can't hold its rider: they move
  -- to the command pod if there is one (a lost pod loses the craft anyway).
  if crewAboard and stationUid and stationUid ~= pod_uid
    and (integ.gone[stationUid] or (part_hp[stationUid] or 1) <= 0) and pod_uid then
    setStation(pod_uid)
    if astronaut then astronaut.visible = podSeat == true end
  end
  if piloting or crewAboard or not podCrewed or not astronaut then return end
  local info = assembly.info(node)
  local bd, st = board_dist(node, astronaut, info)
  if bd > params.board_range + 1.4 then return end
  if not crewOnFoot(node.id) then return end
  -- the ring marks the crew position F will board (the nearest one)
  local q = st or pod
  local rx, up, rz = basis(node)
  local px = node.x + rx.x * q.x + up.x * q.y + rz.x * q.z
  local py = node.y + rx.y * q.x + up.y * q.y + rz.y * q.z
  local pz = node.z + rx.z * q.x + up.z * q.y + rz.z * q.z
  if not cinematicUp() then draw.ring(px, py, pz, up.x, up.y, up.z, 0.75, 0.3, 0.95, 1.0, 0.9) end
end
