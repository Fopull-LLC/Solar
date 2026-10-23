-- Planet-aware third-person orbit camera (pairs with planet_walker.lua).
--
-- An ordinary orbit camera works in WORLD yaw/pitch — on a radial-gravity
-- planet that frame stops matching "up" the moment you leave the pole, and the view
-- fights you. This one orbits in the CHARACTER'S local frame: up = the body's
-- −gravity up, and the yaw reference is parallel-transported as you walk around the
-- sphere, so the horizon stays level all the way around the planet.
--
--   RIGHT MOUSE (hold)  orbit    SCROLL  zoom    MIDDLE MOUSE / ALT  toggle lock
--
-- CINEMATIC MODE (see the section near the end):
--   F4   hide the interface        F5   free camera        T    freeze time (free camera)
--   F12  screenshot (user://screenshots)                  ESC  leave cinematic mode
-- (Not F1–F3: the editor keeps those for Play, Pause and Step, and a game
-- running in it never sees them.)
--
-- Exposes its view basis (env globals) for the walker and the tool belt:
--   fwd_x/fwd_y/fwd_z     the exact view direction (world space)
--   flat_x/flat_y/flat_z  that direction projected onto the tangent plane
--   cam_x/cam_y/cam_z     the camera position
--
-- ATTACH to a TOP-LEVEL Camera node (NOT parented to the player: script node
-- coordinates are parent-local, so a moving parent would double-apply).

defaults = {
  distance = 7.0,
  min_distance = 1.5,
  max_distance = 14.0,
  height = 1.2,        -- look-at point above the character's origin, along up
  -- FIRST PERSON: where the eyes are, along up. The astronaut's capsule is
  -- 2.0 m TIP TO TIP about its origin (`Body::capsule` — "total standing
  -- height"), so the crown is at +1.0 and the eyes sit just under it. Reusing
  -- `height` here would have put the camera 0.2 m ABOVE the head: fine as an
  -- orbit pivot, which is what it is for, and a floating drone in first person.
  eye_height = 0.85,
  -- Indoors (a roof within `ceiling_probe` over the crew) the orbit comes in to
  -- this, and the view may not look down from above the head: a building's
  -- ceiling is lower than a third-person camera's normal perch.
  indoor_distance = 3.5,
  ceiling_probe = 4.5,
  -- How quickly the pivot follows the crew UP AND DOWN while walking. A kerb
  -- pops the capsule up a few centimetres in one frame; followed exactly, the
  -- whole view jolts. In the air it follows tightly.
  pivot_follow = 12.0,
  -- While walking without holding the view, the orbit drifts round behind the
  -- direction of travel at this rate (rad/s at full speed; 0 = never).
  follow_yaw = 0.5,
  sensitivity = 0.3,
  zoom_speed = 1.0,
  start_pitch = -0.3,
  -- OVER THE SHOULDER: while a tool is in use the pivot slides this far to the
  -- crew's right, so the body stops standing between the camera and the rock
  -- face or plant being worked. Eased in and out; 0 = never.
  shoulder = 0.6,
}

shiftlock = false
-- Are we behind the eyes? Published, because it changes what other scripts mean:
-- the tool belt aims down the middle of the view, and nothing should be drawing
-- a body we are standing inside.
--
-- This used to be inferred, by everyone, from "is the camera within 0.7 m of the
-- character" — which is ALSO true every time the wall-clip ray finds something
-- behind you. So walking through a doorway, standing beside your own rocket or
-- backing into a tunnel snapped the view to the eyes and back out again, and the
-- game read as broken in exactly the places you spend the most time. First
-- person is now a MODE you scroll into, not a distance that happens to you.
firstPerson = false
-- Published: the mouse is grabbed to turn the view this frame (first person,
-- shift lock, a held right button). While it is not, the cursor is the aim.
mouseLooking = false
-- Is the camera the reason the body isn't drawing? The walker self-heals the
-- astronaut's visibility (a vessel that seated the crew and then died leaves it
-- hidden with nobody to undo it) and that heal used to run every frame, against
-- this camera — so first person turned the node off and the walker turned the
-- MODEL CHILD, the part you actually see, straight back on. You spent first
-- person inside your own head. One owner: the camera decides, the walker asks.
hidesBody = false
-- View basis for other scripts (world space; set every frame).
fwd_x, fwd_y, fwd_z = 0.0, 0.0, -1.0
flat_x, flat_y, flat_z = 0.0, 0.0, -1.0
cam_x, cam_y, cam_z = 0.0, 0.0, 0.0
-- The point the view orbits (the crew's chest, or eyes in first person).
pivot_x, pivot_y, pivot_z = 0.0, 0.0, 0.0

local target
local pitch = nil
-- The yaw reference direction, parallel-transported across the planet surface.
local ref = vec3(0, 0, -1)
-- The camera's up, SLEW-LIMITED toward −gravity. On foot it tracks fast (level
-- horizon as you walk); while FLYING it tracks GENTLY, so it follows the planet's
-- local vertical as you fly around the body (no more "upside-down on the far
-- side") yet spreads the discontinuous −gravity flip at an SOI hand-off into an
-- easy reorient instead of a jarring snap — see the up-slew below.
local cup = nil
-- The wall clip's distance, eased. See the clip block in lateUpdate.
local clip_back = nil
-- The pivot's height above the planet's centre, eased (see `pivot_follow`),
-- and the most the orbit may pull out to, eased toward the indoor limit.
local pivot_r = nil
local room_cap = nil
-- The over-the-shoulder offset now (eased), and when a tool was last fired.
local shoulder_now, shoulder_t = 0.0, -100.0

local PITCH_LIMIT = math.pi * 0.5 - 0.08

-- Point the view along a world direction (and optionally set its pitch). For
-- scripted views — test rigs, a cutscene, "look at the thing you just built".
-- The direction is flattened onto the local ground plane on the next frame.
function face(dx, dy, dz, p)
  ref = vec3(dx, dy, dz)
  if p then pitch = p end
end

local was_piloting = false
local was_vessel = nil      -- the piloted craft's node id (a switch is a new subject)

-- ── which way is up ─────────────────────────────────────────────────────────
-- Straight out from the centre of the world the subject is on, worked out from
-- where that world IS. Since 0.117.0-rc6 the subject's own `node.up` agrees
-- with it on every tick (a floating-origin recentre no longer leaves gravity
-- pointing off to one side; measured within 0.01° walking and standing), but
-- it is still the default +Y before a body's first tick and on the frame a
-- body is teleported, and it is gravity, not the world the VIEW belongs to —
-- so the camera keeps its own.
--
-- The world is chosen with HYSTERESIS: patched conics hand you from a planet
-- to its moon (or back) at a sharp sphere, and a craft skimming that sphere
-- would have its up flip between two centres frame by frame. A new world has
-- to stay dominant for `SOI_HOLD` before the view changes frame, and then the
-- turn is eased and RATE-LIMITED (`UP_RATE_*`), so no single frame ever turns
-- the horizon by more than a fraction of a degree. The view only SNAPS where
-- it cuts anyway: the first frame, a switch to a craft somewhere else, a
-- teleport, or coming back from the map or the pilot's seat.
local SOI_HOLD = 0.5
local UP_RATE_FOOT, UP_RATE_FLY = math.rad(120), math.rad(40)   -- most a second
local up_body, up_cand, up_cand_t = nil, nil, 0.0
local placed_t = nil        -- when the orbit view was last placed
local placed_rel = nil      -- the subject, from its world's centre, then
local placed_body = nil

local function world_up(p, dt)
  if not (space and space.dominant) then return nil end
  local d = space.dominant(p.x, p.y, p.z)
  if d ~= up_body then
    if not up_body or not space.body(up_body) then
      up_body, up_cand = d, nil
    elseif d ~= nil and d == up_cand then
      up_cand_t = up_cand_t + dt
      if up_cand_t >= SOI_HOLD then up_body, up_cand = d, nil end
    else
      up_cand, up_cand_t = d, 0.0
    end
  else
    up_cand = nil
  end
  local b = up_body and space.body(up_body)
  if not b then return nil end
  local r = p - vec3(b.x, b.y, b.z)
  if r:length() < 1e-3 then return nil end
  return r:normalized(), r, up_body
end

-- Turn `cur` toward `want` by an eased step of at most `max_step` radians.
local function slew(cur, want, rate, max_step, dt)
  local a = cur:angleTo(want)
  if a < 1e-6 then return want end
  local step = math.min(a * (1 - math.exp(-rate * dt)), max_step)
  local axis = cur:cross(want)
  if axis:length() < 1e-9 then
    -- Opposite: any axis across them will do.
    axis = cur:cross(vec3(1, 0, 0))
    if axis:length() < 1e-6 then axis = cur:cross(vec3(0, 0, 1)) end
  end
  return cur:rotatedAround(axis:normalized(), step):normalized()
end

-- ── a craft's own hull, for the chase view ──────────────────────────────────
-- How far back the view must sit to be clear of the craft it is chasing. Rays
-- and sweeps see a craft's parts since 0.117.0-rc6, but they answer "the first
-- thing in the way", not "where the hull ends", and a query takes one node to
-- ignore — not the ground, the crew and the craft at once. Casting back in
-- from beyond the craft to find its far side was tried on rc6 and was worse
-- (the view in the ground 27 frames a rover test against 7, see the rc6
-- notes), so the camera keeps the craft's parts as balls: each part's
-- collision box (its RigidBody half extents times
-- the part's scale, as the engine builds it) wrapped in a sphere, re-read when
-- the craft gains or loses parts, placed each frame from the parts' local
-- poses (so a hinge that moves its arm moves its balls). The rover's tyres
-- hang off it as bodies of their own and join them.
local HULL_MARGIN = 0.45    -- the view's near plane and a little air
local hull_cache = { id = nil, n = -1, parts = {} }
local function hull_balls(vessel)
  local out = {}
  local vn = vessel.node
  if vn and vn.valid and vn.children then
    local kids = vn:children()
    if hull_cache.id ~= vn.id or hull_cache.n ~= #kids then
      local parts = {}
      for _, c in ipairs(kids) do
        local getc = c.getcomponent or c.getComponent
        local rb = getc and getc(c, "RigidBody")
        if rb then
          local hx = (rb.half_x or 0) * math.abs(c.scale_x or 1)
          local hy = (rb.half_y or 0) * math.abs(c.scale_y or 1)
          local hz = (rb.half_z or 0) * math.abs(c.scale_z or 1)
          local r = math.sqrt(hx * hx + hy * hy + hz * hz)
          parts[#parts + 1] = { node = c, r = (r > 0.05) and r or 0.6 }
        end
      end
      hull_cache = { id = vn.id, n = #kids, parts = parts }
    end
    if #hull_cache.parts > 0 then
      local o = vn:toWorld(vec3(0, 0, 0))
      local ex = vn:toWorld(vec3(1, 0, 0)) - o
      local ey = vn:toWorld(vec3(0, 1, 0)) - o
      local ez = vn:toWorld(vec3(0, 0, 1)) - o
      for _, p in ipairs(hull_cache.parts) do
        local c = p.node
        if c.valid then
          local w = o + ex * (c.x or 0) + ey * (c.y or 0) + ez * (c.z or 0)
          out[#out + 1] = { x = w.x, y = w.y, z = w.z, r = p.r }
        end
      end
    end
  end
  if #out == 0 and vessel.hullSpheres then
    for _, b in ipairs(vessel.hullSpheres() or {}) do out[#out + 1] = b end
  end
  local r2 = vessel.R2
  for _, w in ipairs((r2 and r2.wheels) or {}) do
    local t = w.tyre
    if t and t.valid then out[#out + 1] = { x = t.x, y = t.y, z = t.z, r = (w.r or 0.4) + 0.05 } end
  end
  return out
end

-- How far back along `dir` from `o` the view must sit to be outside every
-- one of those spheres the line passes through (0 = none in the way).
-- Also: how far the whole craft reaches from `o` (the farthest ball's far
-- side), which the view keeps clear of too, up to the closest orbit: the view
-- tucked in BETWEEN a rover's wheels is outside every part and still inside
-- the craft.
local function hull_exit(balls, o, dir)
  local far, reach = 0.0, 0.0
  for _, b in ipairs(balls) do
    local r = (b.r or 0.5) + HULL_MARGIN
    local cx, cy, cz = b.x - o.x, b.y - o.y, b.z - o.z
    local dc = math.sqrt(cx * cx + cy * cy + cz * cz) + r
    if dc > reach then reach = dc end
    local t = cx * dir.x + cy * dir.y + cz * dir.z
    local d2 = cx * cx + cy * cy + cz * cz - t * t
    if d2 < r * r then
      local e = t + math.sqrt(r * r - d2)
      if e > far then far = e end
    end
  end
  return far, reach
end

-- The sphere sweep the view backs out along, passing THROUGH the craft's own
-- parts, its crew and its tyres (the subject, not walls) and stopping at
-- anything else. The old sweep stopped at the first thing it met, found the
-- crew sitting at the pivot, threw the whole result away — and so while
-- flying the camera never saw the ground at all.
--
-- Since 0.117.0-rc6 the sweep meets the craft's parts too (it starts inside
-- the pod), so it begins ignoring the whole craft and steps past the crew and
-- tyres one at a time. No `ignoreStart`: on rc6 it shrinks the ball for the
-- whole sweep to the gap to whatever is nearest at the start (the crew), which
-- let the view sink 0.15 m from the ground on a slope; and a ball that starts
-- INSIDE a body still meets it at 0, so a hit at the start steps a ball's
-- width on.
local function sweep(from, dir, maxd, passes, craft)
  local o, gone, ign = from, 0.0, craft
  for _ = 1, 12 do
    local hit = spherecast(o, dir, 0.25, maxd - gone, { ignore = ign })
    if not (hit and hit.distance) then return nil end
    local n = hit.node
    local par = n and n.valid and n.parent
    local part = craft and par and par.valid and par.id == craft.id
    if n and n.valid and (part or passes[n.id]) then
      local step = hit.distance + ((hit.distance < 0.01) and 0.25 or 0.05)
      gone, o, ign = gone + step, o + dir * step, part and craft or n
      if gone >= maxd then return nil end
    else
      return gone + hit.distance, hit
    end
  end
  return nil
end

-- Cross-script singletons, resolved once and kept (floptle/0063 — findScript is
-- a scene walk).
-- NOT `ref`: that name is already taken, six lines up, by the yaw reference
-- vector this whole camera is built around. Shadowing it turns `ref:flatten(up)`
-- into an attempt to index a function.
local refs = {}
local function script_ref(kind)
  local r = refs[kind]
  if not r or not r.valid then r = findScript(kind); refs[kind] = r end
  return r
end

local function map()
  return script_ref("orbit_map")
end

-- Is one of the game's panels in front of the player? First person grabs the
-- mouse, and a grabbed mouse cannot click a Sell button — so the grab has to
-- know about the panels. The panels each already publish this for the tool belt.
local function panel_open()
  local pm = script_ref("pause_menu")
  if pm and pm.open then return true end
  local fm = script_ref("facility_menu")
  if fm and fm.isOpen and fm.isOpen() then return true end
  local ob = script_ref("ops_board")
  if ob and ob.isOpen and ob.isOpen() then return true end
  local ip = script_ref("inventory_panel")
  if ip and ip.open then return true end
  return false
end

-- ── the pilot's seat ────────────────────────────────────────────────────────
-- While flying, `V` (or scrolling in past the closest orbit) puts the view in
-- the commander's seat, looking out of the pod's window. The pod prefab carries
-- the cabin as a disabled "Pod Interior" subtree (seat, console, the crew's legs
-- and gloves, a lamp): it is switched on only while we are in here, so it costs
-- nothing the rest of the time. The exterior hull has a real window opening and
-- a dark liner, so nothing has to be hidden or cut away.
--
-- Published: `cockpit` is a rung on the Esc ladder (pause_menu.lua) just like
-- `firstPerson` is on foot.
cockpit = false
-- The eye in the POD's frame (metres): the seat faces the window on −Z.
local SEAT_EYE = vec3(0.0, 0.0, 0.06)
-- How far the head turns: a helmet in a couch, not an owl.
local SEAT_YAW, SEAT_UP, SEAT_DOWN = math.rad(110), math.rad(60), math.rad(55)
local seat = nil            -- { pod =, interior = } of the piloted vessel
local seat_yaw, seat_pitch = 0.0, -0.08

-- The piloted vessel's command pod: the part carrying a "Pod Interior", the
-- one nearest the published pod offset when a craft has several.
local function find_seat(vessel)
  local vn = vessel and vessel.node
  if not (vn and vn.valid and vn.children) then return nil end
  -- Riding an open Command Seat: there is no cabin to look out of.
  if vessel.podSeat then return nil end
  local best, bd = nil, nil
  for _, c in ipairs(vn:children()) do
    for _, g in ipairs(c:children()) do
      if g.name == "Pod Interior" then
        local dx = (c.x or 0) - (vessel.podLX or 0)
        local dy = (c.y or 0) - (vessel.podLY or 0)
        local dz = (c.z or 0) - (vessel.podLZ or 0)
        local d = dx * dx + dy * dy + dz * dz
        if not bd or d < bd then best, bd = { pod = c, interior = g, vessel = vn }, d end
        break
      end
    end
  end
  return best
end

-- Enter or leave the seat. Entering needs a pod with a cabin; a craft without
-- one (its pod lost to a crash) stays in third person.
function setCockpit(on, vessel)
  if on then
    local s = find_seat(vessel)
    if not s then cockpit = false return false end
    seat = s
    seat.interior.enabled = true
    seat_yaw, seat_pitch = 0.0, -0.08
    cockpit = true
  else
    if seat and seat.interior and seat.interior.valid then seat.interior.enabled = false end
    seat = nil
    cockpit = false
  end
  return cockpit
end

-- The seat view, once per frame. Returns false if the pod has gone (staged
-- away, destroyed) and the view must fall back to the orbit.
local function seat_view(node, dt, blocked)
  local pod, vn = seat and seat.pod, seat and seat.vessel
  if not (pod and pod.valid and vn and vn.valid) then setCockpit(false) return false end
  -- Compose through the VESSEL's pose, not the pod's own toWorld: a child's
  -- world transform is a frame behind its moving parent in the camera pass,
  -- and at 10 m/s that left the eye 18 cm down by the cabin floor. The pod's
  -- local pose (the blueprint's; YXZ like everywhere in this project) is
  -- exact, so parent ∘ local is this frame's seat.
  local cy, sy = math.cos(pod.yaw or 0), math.sin(pod.yaw or 0)
  local cx, sx = math.cos(pod.pitch or 0), math.sin(pod.pitch or 0)
  local cz, sz = math.cos(pod.roll or 0), math.sin(pod.roll or 0)
  local lx = vec3(cy * cz + sy * sx * sz, cx * sz, -sy * cz + cy * sx * sz)
  local ly = vec3(-cy * sz + sy * sx * cz, cx * cz, sy * sz + cy * sx * cz)
  local lz = lx:cross(ly)
  local lp = vec3(pod.x or 0, pod.y or 0, pod.z or 0)
  local o = vn:toWorld(lp)
  local ex = (vn:toWorld(lp + lx) - o):normalized()
  local ey = (vn:toWorld(lp + ly) - o):normalized()
  local ez = (vn:toWorld(lp + lz) - o):normalized()
  -- The mouse always turns the head in here (a panel takes the pointer back).
  local looking = not blocked
  input.setMouseLocked(looking)
  mouseLooking = looking
  if looking then
    local dx, dy = input.mouse_delta()
    local st = script_ref("settings")
    local sens = params.sensitivity * 0.01 * ((st and st.lookScale) or 1.0)
    if st and st.invertY then dy = -dy end
    seat_yaw = math.clamp(seat_yaw + dx * sens, -SEAT_YAW, SEAT_YAW)
    seat_pitch = math.clamp(seat_pitch - dy * sens, -SEAT_DOWN, SEAT_UP)
  end
  local cp = math.cos(seat_pitch)
  local fwd = (ex * (math.sin(seat_yaw) * cp) + ey * math.sin(seat_pitch)
    + ez * (-math.cos(seat_yaw) * cp)):normalized()
  local place = o + ex * SEAT_EYE.x + ey * SEAT_EYE.y + ez * SEAT_EYE.z
  -- The same shake the orbit takes, scaled to a head strapped into a couch:
  -- the cabin rattles round you by centimetres, not metres.
  local sh = save.get("cam.shake") or 0.0
  if access.reducedMotion() then sh = 0.0 end
  if sh > 0.002 then
    local amp = sh * sh * 0.012
    place = place + ex * ((math.random() * 2 - 1) * amp) + ey * ((math.random() * 2 - 1) * amp)
  end
  node.pos = place
  node:lookAt(place + fwd, ey)
  fwd_x, fwd_y, fwd_z = fwd.x, fwd.y, fwd.z
  cam_x, cam_y, cam_z = place.x, place.y, place.z
  local flat = fwd:flatten(ey)
  if flat:length() == 0 then flat = ez * -1 end
  flat_x, flat_y, flat_z = flat.x, flat.y, flat.z
  return true
end

local function acquire()
  for _, s in ipairs(findScripts("planet_walker")) do
    if net.isMine(s.node) then return s.node end
  end
  local w = findScript("planet_walker")
  return (w and w.node) or find("Astronaut") or find("Player")
end

-- ── the chase view: outside the craft, above the ground ────────────────────
-- Driving a rover the view kept ending up INSIDE it. The sweep that keeps the
-- camera out of walls ignored the craft, as it had to — but on 0.117.0-rc3 the
-- craft's parts were invisible to sweeps anyway, so it was the crew parked at
-- the pivot and the rover's own tyres that it met: the crew threw the sweep away (so the
-- ground was never seen, and the camera sank into hills behind the rover), and
-- a crewless rover's tyre pulled the view in to a metre from the pod, in among
-- its parts.
--
-- Now: the view backs out along its line, passing through the craft, its crew
-- and its tyres, and may come in for the ground or a wall — but never closer than the
-- far side of the craft's own hull along that line (`hull_exit`). Where the
-- ground leaves no room outside the hull (a rover on a slope, the view low
-- behind it), the view RISES over it instead, a few degrees at a time, the way
-- a boom camera lifts over a wall: quickly up, slowly back down.
local LIFT_STEP, LIFT_STEPS = 0.06, 16
local CHASE_MIN = 5.0       -- the closest orbit while flying (see `mind`)
local lift_now, lift_t = 0.0, -10.0
function chase_clip(vessel, head, up, room_d, dt)
  if time - lift_t > 0.25 then lift_now = 0.0 end   -- a new chase starts level
  lift_t = time
  local balls = hull_balls(vessel)
  local passes = {}
  local astro = find("Astronaut")
  if astro then passes[astro.id] = true end
  for _, w in ipairs((vessel.R2 and vessel.R2.wheels) or {}) do
    if w.tyre and w.tyre.valid then passes[w.tyre.id] = true end
  end
  local function trial(lift)
    local lp = math.max(-PITCH_LIMIT, pitch - lift)
    local f = (ref * math.cos(lp) + up * math.sin(lp)):normalized()
    local need, reach = hull_exit(balls, head, f * -1)
    need = math.max(need, math.min(reach, CHASE_MIN))
    local want = math.max(room_d, need)
    local hd = sweep(head, f * -1, want + 0.3, passes, vessel.node)
    local room = hd and math.max(0.0, hd - 0.1) or want
    return f, need, math.min(want, room), room >= need, lp <= -PITCH_LIMIT
  end
  -- The least lift that leaves room outside the hull.
  local want_lift = nil
  for k = 0, LIFT_STEPS do
    local _, _, _, ok, top = trial(k * LIFT_STEP)
    if ok then want_lift = k * LIFT_STEP break end
    if top then break end
  end
  want_lift = want_lift or LIFT_STEPS * LIFT_STEP
  if want_lift > lift_now then
    lift_now = lift_now + (want_lift - lift_now) * (1 - math.exp(-15 * dt))
  else
    lift_now = lift_now + (want_lift - lift_now) * (1 - math.exp(-2 * dt))
  end
  local f, need, back = trial(lift_now)
  -- Outside the hull comes first: a frame of ground in the corner of the view
  -- while the lift catches up is a lesser thing than a frame inside the craft.
  return math.max(back, need), need, f
end

local function place_camera(node, dt)
  -- Map mode: the orbit map owns the camera while it's open — orbiting the
  -- focused body, not the player. Stand down entirely.
  local m = map()
  if m and m.map_view then return end
  -- Built vessels spawn/despawn at runtime — fetch fresh, never cache, and
  -- scan EVERY instance (several craft can be alive; the piloted one is the
  -- camera's subject, not whichever findScript happens to return first).
  local vessel = nil
  for _, s in ipairs(findScripts("vessel_controller")) do
    if s.piloting then vessel = s break end
  end
  local piloting = vessel ~= nil
  -- Swap on the TRANSITION, not by handle comparison (handles are fresh tables
  -- per access — equality never matches, which stuck the camera on the craft
  -- after exit). Switching from one craft to another (the [ ] switcher, the
  -- Tracking Station) is a transition too, by the node's id: `piloting` never
  -- goes false in between, and the view used to stay on the craft you left.
  local vid = piloting and vessel.node.id or nil
  local swapped = false
  if piloting ~= was_piloting or vid ~= was_vessel then
    was_piloting, was_vessel = piloting, vid
    target = (piloting and vessel.node) or acquire()
    swapped = true
  end
  if not (target and target.valid) then
    target = acquire()
    swapped = true
    if not target then return end
  end
  if pitch == nil then pitch = params.start_pitch end

  -- NOT SHIFT: on foot that is sprint, and a key that both sprints and
  -- toggles the mouse grab did both every time you ran.
  if (input.clicked(2) or input.pressed("alt")) and not piloting then shiftlock = not shiftlock end

  -- ── zoom, and the line between third person and first ───────────────────────
  -- The old rule was one continuous range from `max_distance` down to zero, so
  -- between about 1.5 m and 0 the camera sat INSIDE the character: half a metre
  -- of view that is neither one thing nor the other, and which you had to scroll
  -- through in both directions. First person is a mode now. You scroll in to the
  -- closest orbit, one more click drops you behind the eyes, and one click out
  -- puts you straight back on the shoulder — no mush in between.
  local blocked = panel_open()
  local dz = input.scroll() * params.zoom_speed   -- + is toward the character
  local maxd = piloting and math.max(params.max_distance, 40.0) or params.max_distance
  -- Flying: never zoom INSIDE the hull (the ship visual spans ~2 units). One
  -- more click in from the closest orbit is the pilot's seat (as on foot, one
  -- click past the closest orbit is the eyes), and one click out leaves it.
  local mind = piloting and math.max(params.min_distance, 5.0) or params.min_distance
  if cockpit and not piloting then setCockpit(false) end
  if piloting then
    firstPerson = false
    if cockpit then
      if dz < -0.01 then
        setCockpit(false)
        params.distance = mind
      end
    elseif dz > 0.01 and params.distance <= mind + 0.001 then
      setCockpit(true, vessel)
    else
      params.distance = math.clamp(params.distance - dz, mind, maxd)
    end
    if not blocked and input.pressed("v") then setCockpit(not cockpit, vessel) end
    if cockpit and not blocked and input.pressed("escape") then setCockpit(false) end
    if cockpit and seat_view(node, dt, blocked) then return end
  elseif firstPerson then
    if dz < -0.01 then
      firstPerson = false
      params.distance = mind
      clip_back = nil   -- an explicit scroll arrives NOW; the ease is for walls
    end
  else
    local want = math.clamp(params.distance - dz, mind, maxd)
    if dz > 0.01 and params.distance <= mind + 0.001 then
      firstPerson = true
      clip_back = nil
    end
    params.distance = want
  end

  -- ESC LEAVES FIRST PERSON. First person grabs the mouse, and the HUD's ☰
  -- button — the only way back to the main menu — needs a pointer. A mode you
  -- can only leave if you happen to know about the scroll wheel is a trap, and
  -- Esc is the key everybody tries first.
  if firstPerson and not blocked and input.pressed("escape") then
    firstPerson = false
    params.distance = mind
    clip_back = nil
  end

  -- Desired local up: out from the centre of the subject's world (see
  -- `world_up`). Only with no world at all (a flat level) the body's own up.
  local want_up, rel, rel_body = world_up(target.pos, dt)
  if not want_up then
    want_up = target.up
    if not want_up or want_up:length() == 0 then want_up = vec3(0, 1, 0) end
  end
  -- Slew-limit the up so a hand-off between worlds can't SNAP the view.
  -- FLYING uses a GENTLE rate: flying around a planet turns the local vertical
  -- only slowly (the orbital rate), so the camera tracks it near-perfectly and
  -- never ends up upside-down on the far side — but the change of frame at an
  -- SOI hand-off is spread over a second or two into a smooth reorient. ON
  -- FOOT it tracks fast so the horizon stays level as you walk round the world.
  -- Either way no frame turns it by more than its rate limit allows.
  local cut = cup == nil or swapped or (placed_t and time - placed_t > 0.3)
    or (rel and placed_rel and rel_body == placed_body and (rel - placed_rel):length() > 50)
  if cut then
    cup = want_up
  else
    cup = slew(cup, want_up, piloting and 1.5 or 8.0, (piloting and UP_RATE_FLY or UP_RATE_FOOT) * dt, dt)
  end
  placed_t, placed_rel, placed_body = time, rel, rel_body
  local up = cup

  -- Parallel-transport the yaw reference: project the previous reference onto
  -- the new tangent plane. Walking around the planet turns the frame WITH the
  -- surface, so the camera never rolls wildly or flips at the equator.
  ref = ref:flatten(up)
  if ref:length() == 0 then
    -- Degenerate (reference was parallel to up): pick any tangent.
    ref = up:cross(vec3(1, 0, 0)):normalized()
    if ref:length() == 0 then ref = up:cross(vec3(0, 0, 1)):normalized() end
  end

  -- Mouse steers while looking (RMB / shift lock); yaw rotates the reference
  -- around up (Rodrigues, u ⊥ r so it's just cos/sin), pitch is clamped.
  --
  -- IN FIRST PERSON THE MOUSE ALWAYS STEERS. Requiring a held right button to
  -- turn your own head is the single thing most responsible for first person
  -- "just not feeling right" here: the view is the aim, and a view you have to
  -- hold a button to move is a view you are fighting. The one exception is a
  -- panel — the depot's Sell button needs a pointer, and a grabbed mouse has
  -- none, so the panels take the cursor back for as long as they are up.
  local looking = (not blocked) and (firstPerson or shiftlock or input.button(1))
  input.setMouseLocked(looking)
  mouseLooking = looking
  if looking then
    local dx, dy = input.mouse_delta()
    -- The player's sensitivity and invert-Y (Settings ▸ Camera, settings.lua).
    local st = script_ref("settings")
    local sens = params.sensitivity * 0.01 * ((st and st.lookScale) or 1.0)
    if st and st.invertY then dy = -dy end
    -- Yaw spins the reference about the LOCAL up, not about world +Y — which
    -- is the whole reason this camera exists.
    ref = ref:rotatedAround(up, -dx * sens)
    pitch = math.clamp(pitch - dy * sens, -PITCH_LIMIT, PITCH_LIMIT)
  end

  -- FOLLOW. Walking without holding the view, the orbit drifts round behind
  -- where you are going, so a long walk sideways turns into a walk away from
  -- the camera instead of a circle round it. Never while you back toward the
  -- camera — following that would spin the view round to face you.
  if not looking and not piloting and params.follow_yaw > 0 then
    local vel = vec3(target.vx or 0, target.vy or 0, target.vz or 0)
    local tv = vel - up * vel:dot(up)
    local sp = tv:length()
    if sp > 0.5 then
      local dir = tv * (1 / sp)
      local ang = math.atan2(ref:cross(dir):dot(up), ref:dot(dir))
      if math.abs(ang) < math.rad(100) then
        ref = ref:rotatedAround(up, ang * math.min(1, params.follow_yaw * math.min(1, sp / 8) * dt))
      end
    end
  end

  -- INDOORS: a roof over the crew brings the orbit in and stops it looking
  -- down from above the head, where it would sit in the ceiling. A raycast
  -- straight up is the whole test — every building is a roof, and so is a
  -- tunnel you have bored.
  -- The roof sets a CEILING on the zoom, eased, rather than a zoom: your own
  -- scroll setting is untouched and comes back when you step outside.
  local roof = (not piloting) and raycast(target.pos, up, params.ceiling_probe, target) or nil
  local cap = roof and params.indoor_distance or maxd
  if room_cap == nil or piloting then room_cap = cap end
  room_cap = room_cap + (cap - room_cap) * (1 - math.exp(-4 * dt))
  local room_d = math.min(params.distance, room_cap)
  if roof and not firstPerson and pitch < -0.3 then
    pitch = pitch + (-0.3 - pitch) * (1 - math.exp(-6 * dt))
  end

  -- View direction in the local frame: reference tilted by pitch toward up.
  local fwd = (ref * math.cos(pitch) + up * math.sin(pitch)):normalized()

  -- Look-at point: the character's head (along LOCAL up, not world Y). A
  -- piloted VESSEL's center is its CAPSULE, composed HERE from the node's
  -- rendered pose + the published pod-local offset: computed in the camera
  -- pass it sits exactly on the ship this frame draws — a fixedUpdate world
  -- position lags the rails carry (offset + jitter), and a gravity-up height
  -- guess slides off the hull the moment the vessel pitches.
  local head
  if piloting and vessel and vessel.podLY and target then
    -- `toWorld` composes the vessel's own rotation for us — the nine-term
    -- YXZ expansion this used to spell out by hand.
    head = target:toWorld(vec3(vessel.podLX or 0, vessel.podLY, vessel.podLZ or 0))
  else
    -- Third person orbits a point at chest height; first person sits at the
    -- EYES, which is higher. Pivoting first person around the chest is what
    -- makes a camera feel like it is mounted to a trolley rather than a head.
    --
    -- The pivot's height is EASED along up (see `pivot_follow`), measured from
    -- the planet's centre: the planet moves on rails, so the crew's world
    -- position is racing along its orbit and only the distance from the
    -- centre says whether they stepped up.
    local base = target.pos
    local d = space and space.dominant(base.x, base.y, base.z)
    local b = d and space.body(d)
    if b then
      local r = (base - vec3(b.x, b.y, b.z)):length()
      local walker = script_ref("planet_walker")
      local rate = (walker and walker.grounded) and params.pivot_follow or 40.0
      if not pivot_r or math.abs(r - pivot_r) > 1.5 then pivot_r = r end
      pivot_r = pivot_r + (r - pivot_r) * (1 - math.exp(-rate * dt))
      base = base + up * (pivot_r - r)
    end
    head = base + up * (firstPerson and params.eye_height or params.height)
    -- The pivot itself must be in the open. Under a low roof — a bore the
    -- laser cuts is 2.2–4 m tall (2.4 × 0.85 × charge) and the pivot sits 2.2 m
    -- over the floor — it was inside the rock, and the wall clip below sweeps
    -- FROM the pivot, so it never fired and the view looked out from inside
    -- the terrain. Sweep the same ball up from the crew's centre and stop
    -- short of whatever is overhead.
    local lift = (head - target.pos):dot(up)
    if lift > 0.05 then
      local roofhit = spherecast(target.pos, up, 0.25, lift, target)
      if roofhit and roofhit.distance and not (roofhit.node and roofhit.node.id == target.id) then
        head = head - up * (lift - math.max(0.0, roofhit.distance - 0.05))
      end
    end
  end

  -- OVER THE SHOULDER. In third person the crew stands dead centre — exactly
  -- between the camera and the face the laser is cutting or the plant the
  -- cutter is on. While a tool is firing (and for a beat after, so bursts do
  -- not bob the view) the pivot eases to the right. A wall at your right
  -- shoulder caps it, so the pivot never ends up inside one.
  if not piloting then
    local tb = script_ref("tool_belt")
    if tb and tb.inUse then shoulder_t = time end
  end
  local want = (not piloting and not firstPerson and time - shoulder_t < 1.5)
    and (params.shoulder or 0) or 0.0
  shoulder_now = shoulder_now + (want - shoulder_now) * (1 - math.exp(-5 * dt))
  if shoulder_now > 0.01 and not piloting then
    local right = fwd:cross(up):normalized()
    local side = shoulder_now
    local wall = spherecast(head, right, 0.2, side + 0.3, target)
    if wall and wall.distance then side = math.min(side, math.max(0.0, wall.distance - 0.3)) end
    head = head + right * side
  end

  -- Wall clip: sweep a ball from the head back toward the camera, ignoring the
  -- player. A ball, not a ray: the view is a volume, and a ray slips through
  -- the gap at a door frame or a rock's edge that the near plane then cuts.
  local back = firstPerson and 0.0 or room_d
  local hull_floor = 0.0
  if piloting and not firstPerson then
    back, hull_floor, fwd = chase_clip(vessel, head, up, room_d, dt)
  else
    local hit = (not firstPerson) and spherecast(head, -fwd, 0.25, room_d + 0.3, target) or nil
    -- The wall clip must see WALLS only. The astronaut is not a wall.
    if hit and hit.node then
      local astro = find("Astronaut")
      if astro and hit.node.id == astro.id then hit = nil end
    end
    if hit and hit.distance then
      -- Never past the contact: a 0.3 m floor here put the camera INSIDE a wall
      -- the pivot was within 0.35 m of. Closer than 0.7 hides the body anyway.
      back = math.max(0.0, hit.distance - 0.05)
    end
  end

  -- SNAP IN, EASE OUT. A camera may never spend a frame inside a wall, so a
  -- closer answer is taken immediately — but popping back to full orbit the
  -- instant a doorway clears is what made walking around the base feel like the
  -- view was flinching. Coming out is a glide. (Chasing a craft it never comes
  -- in past the craft's own hull.)
  if clip_back == nil or back <= clip_back then
    clip_back = back
  else
    clip_back = clip_back + (back - clip_back) * math.min(1.0, dt * 6.0)
  end
  back = firstPerson and 0.0 or math.max(clip_back, hull_floor)

  -- Don't draw a body we are standing inside — first person, or a wall that has
  -- pushed the view into the character's shoulders. (While piloting, the vessel
  -- owns the astronaut's visibility — leave it alone.)
  hidesBody = firstPerson or back < 0.7
  if not piloting then
    target.visible = not hidesBody
  end

  local place = head - fwd * back
  -- SCREEN SHAKE: the vessel publishes cam.shake (liftoff rumble, buffeting,
  -- crashes). Jitter the camera position along its right/up so the view rattles
  -- while the look target holds steady. Squared for an ease-in (small = subtle).
  -- REDUCED MOTION. The engine snaps its own UI transitions when a player asks
  -- for it, but it cannot tell which of a game's movement is the game — so the
  -- shake is ours to switch off, and this is the only place in the project that
  -- moves the view for effect. (v0.33.0, ⚙ Settings → ♿ Accessibility.)
  local sh = save.get("cam.shake") or 0.0
  if access.reducedMotion() then sh = 0.0 end
  if sh > 0.002 then
    local amp = sh * sh * 0.5
    place = place
      + ref * ((math.random() * 2 - 1) * amp)
      + up * ((math.random() * 2 - 1) * amp)
  end
  node.pos = place

  -- Point the camera down `fwd` with the LOCAL up overhead, so the horizon
  -- reads level all the way around the planet. `lookAt` with an `up` sets the
  -- roll too — that is the entire twenty-line undo-yaw-then-pitch dance.
  node:lookAt(place + fwd, up)

  -- Publish the basis for the walker + dig tool.
  fwd_x, fwd_y, fwd_z = fwd.x, fwd.y, fwd.z
  cam_x, cam_y, cam_z = place.x, place.y, place.z
  pivot_x, pivot_y, pivot_z = head.x, head.y, head.z
  -- Flat against the BODY's up, not the camera's slewed one: this is the
  -- walker's forward, and it has to lie in the plane the crew walks on.
  local flat = fwd:flatten(want_up)
  if flat:length() == 0 then flat = ref end
  flat_x, flat_y, flat_z = flat.x, flat.y, flat.z
end

-- The haze (atmosphere.lua) reads where the camera is, so it is told the
-- moment the camera is placed — every frame, whichever way this one went (the
-- map, the cockpit, on foot). Two nodes' lateUpdates run in load order, which
-- is not something to rely on, so this is a call rather than an ordering.
local atmo_ref
function lateUpdate(node, dt)
  if cinematic_tick(node, dt) then
    -- the free camera placed the view itself
  else
    place_camera(node, dt)
  end
  if not atmo_ref or not atmo_ref.valid then atmo_ref = findScript("atmosphere") end
  if atmo_ref and atmo_ref.valid and atmo_ref.follow then atmo_ref.follow(dt) end
end

-- ── CINEMATIC MODE ──────────────────────────────────────────────────────────
-- The playtest asked for "the ui toggleable for cinematic mode, which also lets
-- you do a freecam and get pictures". Three keys and a shutter:
--
--   F4  hides every screen layer (the HUD, the objectives card, prompts,
--       toasts, the flight instruments). Published as `cinematic`; the scripts
--       that paint markers straight onto the screen (draw.*) ask it and stand
--       down too. The game goes on underneath: you can still walk and fly.
--   F5  the FREE CAMERA. It takes the keyboard and mouse — W A S D fly along
--       the view, SPACE / CTRL rise and sink, SHIFT is five times faster, the
--       scroll wheel sets the speed, the mouse looks — and hides the interface
--       while it flies. `freecam` is published: the walker, the craft and the
--       tool belt leave the keys alone while it is true, so W does not also
--       walk the crew off a cliff. The world keeps simulating.
--   T   (in the free camera) freezes time: the gameplay tick stops, the
--       camera does not. T again, or leaving the free camera, lets it go.
--   F12 a screenshot of the window, to user://screenshots/solar_NNNN.png. It
--       is what you see: with the interface when it is up, without it when not.
--
-- The free camera is kept RELATIVE TO THE WORLD it started over: its position
-- is stored from that body's centre and recomposed every frame in this, the
-- camera pass, from where the body is now. The planets move on rails, so a
-- camera held in world coordinates would watch the ground slide away under it
-- at orbital speed.
--
-- ESC leaves cinematic mode before it opens anything (`escTakenAt`, the way the
-- panels hand the pause menu an Esc that was theirs), and leaving restores
-- every layer exactly as it was found.
cinematic = false      -- the interface is hidden (F4, or the free camera)
freecam = false        -- the free camera has the keyboard and mouse
timeFrozen = false     -- T in the free camera
escTakenAt = -1
local CINE_LAYERS = { "Ship HUD", "Sound and Settings" }
local cine_ui = false            -- F4's own switch (the free camera hides on its own)
local cine_layers = nil          -- { {layer=, was=} } switched off by us
local fc = nil                   -- the free camera: { body, rel, ref, pitch, speed }
local shot_n, shot_msg, shot_msg_t = nil, nil, -10.0
local self_node = nil            -- this camera (for setFreecam from a probe)
FREECAM_SPEED = { start = 8.0, min = 0.5, max = 20000.0, fast = 5.0, step = 1.25 }

local function cine_hide(on)
  if on and not cine_layers then
    cine_layers = {}
    for _, nm in ipairs(CINE_LAYERS) do
      local n = find(nm)
      local l = n and n:getcomponent("UiLayer")
      if l then
        cine_layers[#cine_layers + 1] = { layer = l, was = l.enabled }
        l.enabled = false
      end
    end
  elseif not on and cine_layers then
    for _, c in ipairs(cine_layers) do c.layer.enabled = c.was ~= false and c.was ~= 0 end
    cine_layers = nil
  end
end

-- Hold the layers off while hidden: a scene script that switches its own
-- layer on (a loading screen ending) must not bring the HUD back mid-shot.
local function cine_hold()
  if not cine_layers then return end
  for _, c in ipairs(cine_layers) do
    if c.layer.enabled == true or c.layer.enabled == 1 then c.layer.enabled = false end
  end
end

local function set_freeze(on)
  if on == timeFrozen then return end
  timeFrozen = on
  if physics and physics.pause then physics.pause(on) end
end

local function body_pos(name)
  local b = name and space and space.body and space.body(name)
  if not b then return nil end
  return vec3(b.x, b.y, b.z)
end

local function freecam_enter(node)
  local m = map()
  if m and m.map_view and m.toggle then m.toggle() end
  if cockpit then setCockpit(false) end
  firstPerson = false
  local p = node.pos
  local d = space and space.dominant and space.dominant(p.x, p.y, p.z)
  local bp = body_pos(d)
  local up = bp and (p - bp):normalized() or vec3(0, 1, 0)
  local f = vec3(fwd_x, fwd_y, fwd_z)
  local r = f:flatten(up)
  if r:length() < 1e-6 then r = up:cross(vec3(1, 0, 0)) end
  if r:length() < 1e-6 then r = up:cross(vec3(0, 0, 1)) end
  fc = { body = bp and d or nil, rel = bp and (p - bp) or p, ref = r:normalized(),
         pitch = math.asin(math.clamp(f:dot(up), -1, 1)), speed = FREECAM_SPEED.start }
  -- Nobody should be invisible in a picture of them.
  if target and target.valid and target.visible == false then
    local piloting = false
    for _, s in ipairs(findScripts("vessel_controller")) do if s.piloting then piloting = true end end
    if not piloting then target.visible = true end
  end
  freecam = true
end

local function freecam_leave()
  freecam = false
  fc = nil
  set_freeze(false)
end

-- One frame of the free camera. Pure motion: no collision, no follow.
function freecamStep(node, dt, keys, mdx, mdy, scroll)
  local bp = body_pos(fc.body)
  if fc.body and not bp then
    -- The world it was over has gone (a far system streamed out): carry on
    -- from where the camera is, in plain world space.
    fc.body = nil
  end
  local pos = bp and (bp + fc.rel) or fc.rel
  local up = bp and fc.rel:normalized() or vec3(0, 1, 0)
  if fc.rel:length() < 1e-3 then up = vec3(0, 1, 0) end
  fc.ref = fc.ref:flatten(up)
  if fc.ref:length() < 1e-6 then
    fc.ref = up:cross(vec3(1, 0, 0))
    if fc.ref:length() < 1e-6 then fc.ref = up:cross(vec3(0, 0, 1)) end
  end
  fc.ref = fc.ref:normalized()
  local st = script_ref("settings")
  local sens = params.sensitivity * 0.01 * ((st and st.lookScale) or 1.0)
  if st and st.invertY then mdy = -mdy end
  fc.ref = fc.ref:rotatedAround(up, -mdx * sens)
  fc.pitch = math.clamp(fc.pitch - mdy * sens, -PITCH_LIMIT, PITCH_LIMIT)
  if scroll and scroll ~= 0 then
    fc.speed = math.clamp(fc.speed * FREECAM_SPEED.step ^ scroll, FREECAM_SPEED.min, FREECAM_SPEED.max)
  end
  local fwd = (fc.ref * math.cos(fc.pitch) + up * math.sin(fc.pitch)):normalized()
  local right = fwd:cross(up):normalized()
  local mv = vec3(0, 0, 0)
  if keys.w then mv = mv + fwd end
  if keys.s then mv = mv - fwd end
  if keys.d then mv = mv + right end
  if keys.a then mv = mv - right end
  if keys.space then mv = mv + up end
  if keys.ctrl then mv = mv - up end
  if mv:length() > 1e-6 then
    local k = fc.speed * (keys.shift and FREECAM_SPEED.fast or 1.0) * dt
    pos = pos + mv:normalized() * k
  end
  fc.rel = bp and (pos - bp) or pos
  return pos, fwd, up
end

local function screenshot()
  if not (camera and camera.capture) then print("camera: this build cannot take a screenshot") return end
  local sw, sh = 1920, 1080
  if camera.screenSize then sw, sh = camera.screenSize() end
  sw, sh = math.max(1, math.min(4096, sw or 1920)), math.max(1, math.min(4096, sh or 1080))
  if not shot_n then
    shot_n = 0
    local ok, list = pcall(assets.getContents, "user://screenshots")
    if ok and type(list) == "table" then
      for _, path in ipairs(list) do
        local k = tonumber(tostring(path):match("solar_(%d+)%.png$"))
        if k and k > shot_n then shot_n = k end
      end
    end
  end
  shot_n = shot_n + 1
  local path = string.format("user://screenshots/solar_%04d.png", shot_n)
  local show = not cinematic
  local ok, err = pcall(camera.capture, { w = sw, h = sh, ui = show, draws = show }, function(bytes, why)
    if not bytes then print("camera: screenshot failed — " .. tostring(why)) return end
    local wok, werr = assets.writeBytes(path, bytes)
    if wok then
      print("camera: screenshot " .. path)
      shot_msg, shot_msg_t = "Screenshot saved — " .. path:gsub("^user://", ""), time
    else
      print("camera: screenshot not written — " .. tostring(werr))
    end
  end)
  if not ok then print("camera: screenshot " .. tostring(err)) end
end

-- The cinematic keys, every frame; returns true when the free camera placed
-- the view (and place_camera must not).
function cinematic_tick(node, dt)
  self_node = node
  local blocked = panel_open()
  local m = map()
  if input.pressed("f12") then screenshot() end
  if not blocked then
    if input.pressed("f4") then cine_ui = not cine_ui end
    if input.pressed("f5") then
      if freecam then freecam_leave() else freecam_enter(node) end
    end
    if freecam and input.pressed("t") then set_freeze(not timeFrozen) end
    if (cine_ui or freecam) and input.pressed("escape") then
      escTakenAt = time
      cine_ui = false
      if freecam then freecam_leave() end
    end
  end
  -- The map takes the camera back (M is the map's own key): the free camera ends.
  if freecam and m and m.map_view then freecam_leave() end
  local want = cine_ui or freecam
  if want ~= cinematic then cinematic = want; cine_hide(want) end
  cine_hold()
  -- The "saved" line, after the picture was taken (never in it).
  if shot_msg and time - shot_msg_t < 2.0 and draw and draw.text and camera and camera.screenSize then
    local sw, sh = camera.screenSize()
    if sw and sh then
      local k = sh / 1080
      draw.text(sw * 0.5, sh - 48 * k, shot_msg, 18 * k, 0.92, 0.89, 0.81, 0.9, "center")
    end
  end
  if not freecam then return false end
  if blocked then
    input.setMouseLocked(false)
    mouseLooking = false
    return true
  end
  input.setMouseLocked(true)
  mouseLooking = true
  local mdx, mdy = input.mouse_delta()
  local keys = { w = input.key("w"), a = input.key("a"), s = input.key("s"), d = input.key("d"),
                 space = input.key("space"), ctrl = input.key("ctrl"), shift = input.key("shift") }
  local pos, fwd, up = freecamStep(node, dt, keys, mdx or 0, mdy or 0, input.scroll())
  node.pos = pos
  node:lookAt(pos + fwd, up)
  fwd_x, fwd_y, fwd_z = fwd.x, fwd.y, fwd.z
  cam_x, cam_y, cam_z = pos.x, pos.y, pos.z
  return true
end

-- For a probe (and the pause menu's "leave"): switch the modes from a script.
function setCinematic(on) cine_ui = on == true end
function setFreecam(on)
  if on and not freecam and self_node then freecam_enter(self_node)
  elseif not on and freecam then freecam_leave() end
end
function freecamState() return fc end
-- The shutter, for a probe (F12 is the player's).
function takeScreenshot() screenshot() end
