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
-- FLYING (see "the craft's extent" and "the flight camera's modes" below):
--   MIDDLE DRAG  slide the pivot over the craft   ALT + SCROLL  slide it along the craft
--   HOME  pivot back to the middle   C  camera mode (auto · free orbit · chase · horizon)
--   F6    photo orbit (on foot too)  V  the pilot's seat
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
  -- The view's vertical field of view (radians; the system scene's Camera),
  -- for framing a whole craft (`zoomRange`).
  fov_y = 1.1519173,
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
-- How far out of the rock the pivot and the camera are kept (m).
CAM_CLEAR = 0.3
local pivot_lift = 0.0   -- how far the pivot came up out of the rock this frame
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
-- thing in the way", not "where the hull ends" (the craft, its crew and tyres
-- can all be ignored at once since floptle/0473, which `sweep` does, but that
-- says nothing of how far the hull reaches). Casting back in
-- from beyond the craft to find its far side was tried on rc6 and was worse
-- (the view in the ground 27 frames a rover test against 7, see the rc6
-- notes), so the camera keeps the craft's parts as balls: each part's
-- collision box (its RigidBody half extents times
-- the part's scale, as the engine builds it) wrapped in a sphere, re-read when
-- the craft gains or loses parts, placed each frame from the parts' local
-- poses (so a hinge that moves its arm moves its balls). The rover's tyres
-- hang off it as bodies of their own and join them.
local HULL_MARGIN = 0.45    -- the view's near plane and a little air
local hull_cache = { id = nil, n = -1, parts = {}, gen = 0, t = -10.0 }
-- How often the parts list is checked against the craft's children, and how
-- often a big craft's balls re-read their local poses. `vn:children()` makes a
-- table of every part, and each `c.x` is a read across the engine: done every
-- frame they were ~5 ms at 1,000 parts (perfbench g_launch_pad, rc10).
local HULL_RECHECK = 0.5
local HULL_POSE_EVERY = 0.25
local HULL_POSE_SMALL = 150     -- at or under this many parts, poses every frame
-- `vessel` (optional) is the craft's controller: its `partsGen()` steps the
-- moment it gains or loses parts (a stage, a joint that failed), so a craft
-- that changed shape is re-read that frame, not up to HULL_RECHECK later.
local function parts_gen(vessel)
  local f = vessel and vessel.partsGen
  local ok, g = false, nil
  if type(f) == "function" then ok, g = pcall(f) end
  return ok and g or nil
end
local function hull_parts(vn, vessel)
  if vn and vn.valid and vn.children then
    local pg = parts_gen(vessel)
    local stale = hull_cache.id ~= vn.id or time - hull_cache.t > HULL_RECHECK or time < hull_cache.t
      or pg ~= hull_cache.pg
    local kids = stale and vn:children() or nil
    if kids then hull_cache.t, hull_cache.pg = time, pg end
    if kids and (hull_cache.id ~= vn.id or hull_cache.n ~= #kids) then
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
      hull_cache = { id = vn.id, n = #kids, parts = parts, gen = hull_cache.gen + 1, t = time, pg = pg }
    end
  end
  return hull_cache.parts
end
local function hull_balls(vessel)
  local out = {}
  local vn = vessel.node
  if vn and vn.valid and vn.children then
    hull_parts(vn, vessel)
    if #hull_cache.parts > 0 then
      local o = vn:toWorld(vec3(0, 0, 0))
      local ex = vn:toWorld(vec3(1, 0, 0)) - o
      local ey = vn:toWorld(vec3(0, 1, 0)) - o
      local ez = vn:toWorld(vec3(0, 0, 1)) - o
      -- (components read once: each `.x` of a vec3 is a call)
      local o_x, o_y, o_z = o.x, o.y, o.z
      local exx, exy, exz = ex.x, ex.y, ex.z
      local eyx, eyy, eyz = ey.x, ey.y, ey.z
      local ezx, ezy, ezz = ez.x, ez.y, ez.z
      local parts = hull_cache.parts
      local fresh = #parts <= HULL_POSE_SMALL or not hull_cache.pose_t or hull_cache.pose_gen ~= hull_cache.gen
        or time - hull_cache.pose_t > HULL_POSE_EVERY or time < hull_cache.pose_t
      if fresh then hull_cache.pose_t, hull_cache.pose_gen = time, hull_cache.gen end
      for _, p in ipairs(parts) do
        local c = p.node
        if fresh then
          if c.valid then p.lx, p.ly, p.lz = c.x or 0, c.y or 0, c.z or 0 else p.lx = nil end
        end
        local lx, ly, lz = p.lx, p.ly, p.lz
        if lx then
          out[#out + 1] = { x = o_x + exx * lx + eyx * ly + ezx * lz, y = o_y + exy * lx + eyy * ly + ezy * lz,
                            z = o_z + exz * lx + eyz * ly + ezz * lz, r = p.r }
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
  -- (the vectors' components read once: each `.x` of a vec3 is a call)
  local ox, oy, oz = o.x, o.y, o.z
  local dx, dy, dz = dir.x, dir.y, dir.z
  for _, b in ipairs(balls) do
    local r = (b.r or 0.5) + HULL_MARGIN
    local cx, cy, cz = b.x - ox, b.y - oy, b.z - oz
    local dc = math.sqrt(cx * cx + cy * cy + cz * cz) + r
    if dc > reach then reach = dc end
    local t = cx * dx + cy * dy + cz * dz
    local d2 = cx * cx + cy * cy + cz * cz - t * t
    if d2 < r * r then
      local e = t + math.sqrt(r * r - d2)
      if e > far then far = e end
    end
  end
  return far, reach
end

-- ── the craft's extent, the pivot over it, and the zoom it needs ───────────
-- "you are stuck to the pod position but it would be nice if somehow i could
-- move the camera up or down the span of the craft too as well as left or
-- right when it's a larger craft". The view used to orbit the crew's pod: on
-- a 20 m rocket the pod is at the very top, and the rest of the stack hung off
-- the bottom of the screen. Now the view orbits a PIVOT that starts at the
-- middle of the craft's bounds and can be slid anywhere over it:
--
--   MIDDLE MOUSE (hold, drag)  slide the pivot over the craft, in the plane
--                              of the screen (up/down the stack, side to side)
--   ALT + SCROLL               slide it along the craft's long axis
--   HOME                       back to the middle of the craft
--
-- The pivot is kept in the CRAFT'S frame (a slid pivot rides the craft as it
-- turns) and clamped to the box its parts' centres span, so it can never be
-- dragged off into empty air. The zoom range comes from the craft's size: a
-- 60 m rocket can be framed whole, and a probe core still filled.
--
-- Pure: tests/smoke_flightcam.lua holds these.

-- The box a craft's parts span, in the craft's own frame. `parts` is a list
-- of { x, y, z, r } (a part's local centre and the radius of the ball round
-- it). Returns nil for no parts, else
--   lo/hi    the box round the parts' balls (how big the craft LOOKS)
--   clo/chi  the box of the part centres (where the pivot may go)
--   centre   the middle of lo..hi;  radius  half its diagonal
--   axis     "x" | "y" | "z", the box's longest side (the craft's main axis)
function craftBounds(parts)
  if not parts or #parts == 0 then return nil end
  local huge = math.huge
  local lx, ly, lz, hx, hy, hz = huge, huge, huge, -huge, -huge, -huge
  local clx, cly, clz, chx, chy, chz = huge, huge, huge, -huge, -huge, -huge
  for _, p in ipairs(parts) do
    local x, y, z, r = p.x or 0, p.y or 0, p.z or 0, p.r or 0
    if x - r < lx then lx = x - r end
    if y - r < ly then ly = y - r end
    if z - r < lz then lz = z - r end
    if x + r > hx then hx = x + r end
    if y + r > hy then hy = y + r end
    if z + r > hz then hz = z + r end
    if x < clx then clx = x end
    if y < cly then cly = y end
    if z < clz then clz = z end
    if x > chx then chx = x end
    if y > chy then chy = y end
    if z > chz then chz = z end
  end
  local sx, sy, sz = hx - lx, hy - ly, hz - lz
  local axis = "y"
  if sx > sy and sx >= sz then axis = "x" elseif sz > sy and sz > sx then axis = "z" end
  return {
    lo = vec3(lx, ly, lz), hi = vec3(hx, hy, hz),
    clo = vec3(clx, cly, clz), chi = vec3(chx, chy, chz),
    centre = vec3((lx + hx) * 0.5, (ly + hy) * 0.5, (lz + hz) * 0.5),
    radius = 0.5 * math.sqrt(sx * sx + sy * sy + sz * sz),
    size = vec3(sx, sy, sz), axis = axis,
  }
end

-- A local point held inside the box of part centres.
function clampPivot(b, p)
  if not b then return p end
  return vec3(math.clamp(p.x, b.clo.x, b.chi.x), math.clamp(p.y, b.clo.y, b.chi.y),
    math.clamp(p.z, b.clo.z, b.chi.z))
end

-- The pivot slid `d` metres along the craft's main axis (clamped).
function slideAlongAxis(b, p, d)
  if not b then return p end
  local q = vec3(p.x + (b.axis == "x" and d or 0), p.y + (b.axis == "y" and d or 0),
    p.z + (b.axis == "z" and d or 0))
  return clampPivot(b, q)
end

-- The orbit's zoom limits for a craft of bounding radius `radius` and a
-- camera of vertical field of view `fov_y` (radians):
--   mind  the closest orbit (a probe is still filled; a big craft's closest
--         orbit grows with it, but slowly: slide the pivot to get close)
--   maxd  the farthest (the whole craft small in the frame)
--   fit   the distance that frames the whole craft, top to bottom
ZOOM = { floor = 3.0, ceil = 40.0, near_k = 0.15, near_base = 8.0, far_k = 2.5, fit_pad = 1.15 }
function zoomRange(radius, fov_y)
  radius = math.max(0.1, radius or 1.0)
  local half = math.tan(math.clamp((fov_y or 1.15) * 0.5, 0.1, 1.4))
  local fit = radius / half * ZOOM.fit_pad
  local mind = math.max(ZOOM.floor, math.min(radius + 1.0, ZOOM.near_base + ZOOM.near_k * radius))
  local maxd = math.max(ZOOM.ceil, fit * ZOOM.far_k)
  fit = math.clamp(fit, mind, maxd)
  return mind, maxd, fit
end

-- The craft's axes in the world, from its node's rendered pose.
local function craft_basis(vn)
  local o = vn:toWorld(vec3(0, 0, 0))
  local ex = (vn:toWorld(vec3(1, 0, 0)) - o):normalized()
  local ey = (vn:toWorld(vec3(0, 1, 0)) - o):normalized()
  local ez = (vn:toWorld(vec3(0, 0, 1)) - o):normalized()
  return o, ex, ey, ez
end

-- The sphere sweep the view backs out along, passing THROUGH the craft's own
-- parts, its crew and its tyres (the subject, not walls) and stopping at
-- anything else. The old sweep stopped at the first thing it met, found the
-- crew sitting at the pivot, threw the whole result away — and so while
-- flying the camera never saw the ground at all.
--
-- Since 0.117.0-rc6 the sweep meets the craft's parts too (it starts inside
-- the pod). Until rc7 a query ignored one node, so the sweep began ignoring
-- the craft and stepped past the crew and the tyres one hit at a time (up to
-- 12 casts, each re-entering the craft it had stopped ignoring). Since
-- floptle/0473 `ignore` takes a list: one cast passes the craft, the crew and
-- every tyre (`passes`, a list of nodes). No `ignoreStart`: everything the
-- ball starts against or inside is the subject, already ignored, and on rc6
-- it shrank the ball enough to let the view sink 0.15 m from the ground.
local function sweep(from, dir, maxd, passes)
  local hit = spherecast(from, dir, 0.25, maxd, { ignore = passes })
  if not (hit and hit.distance) then return nil end
  return hit.distance, hit
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
  -- the right-click menu (context_menu.lua) needs its pointer too
  local cm = script_ref("context_menu")
  if cm and cm.isOpen and cm.isOpen() then return true end
  return false
end

-- ── the seat view (first person inside the craft) ──────────────────────────
-- While flying, `V` (or scrolling in past the closest orbit) puts the view in
-- the commander's seat. V again moves to the next occupied seat of the craft,
-- and past the last one comes back out (Esc or a scroll out leave at once).
--
-- CLOSED PARTS (Pod Mk1, Pod Mk2, Crew Cabin, Swift Cockpit) have a real
-- interior, built at human scale by tools/gen_iva.py and kept by iva.lua on the
-- `interior` layer. The main camera never draws that layer; here a second
-- camera, "Iva Cam", is STACKED on it (drawn over an empty depth buffer, so
-- nothing outside can ever poke into the room), placed at the seat's eye and
-- turned exactly as the main camera is. The main camera looks out from the
-- hull's own window point (iva.mainEye) with the part's exterior hidden, so
-- the world shows wherever the room has a window and nowhere else.
--
-- OPEN SEATS (the Command Seat, the Moto Saddle) are first person at the
-- rider's head, the helmet parked off-camera (iva.park) so the visor never
-- fills the view; the rider's own body stays in view below.
--
-- Published: `cockpit` is a rung on the Esc ladder (pause_menu.lua) just like
-- `firstPerson` is on foot; `seatView` = { uid, slot, open } while in it.
cockpit = false
seatView = nil
-- How far the head turns (a helmet in a couch, the torso helping it round):
-- far enough to look back over the shoulder and straight up and down.
local SEAT_YAW, SEAT_UP, SEAT_DOWN = math.rad(170), math.rad(80), math.rad(72)
local OPEN_YAW = math.rad(125)
local seat_yaw, seat_pitch = 0.0, -0.08
local seat_vessel = nil
-- Layers (project.ron): bit i = the i-th listed layer after Default.
local ALL = 4294967295
local INTERIOR_BIT, OFFSTAGE_BIT = 16, 32
-- What the main camera draws when no seat view is up: everything but the
-- interiors and the parked nodes. tool_belt asks for this too (cullBase).
function cullBase() return ALL - INTERIOR_BIT - OFFSTAGE_BIT end
local iva_cam, iva_cam_making, iva_fov = nil, false, nil
local main_mask_set, main_node = nil, nil

local function find_desc(n, name, depth)
  if not (n and n.valid) or (depth or 0) > 5 then return nil end
  for _, c in ipairs(n:children() or {}) do
    if c.name == name then return c end
    local f = find_desc(c, name, (depth or 0) + 1)
    if f then return f end
  end
  return nil
end

local function iva_ref() return script_ref("iva") end

-- The seats V steps through on craft `vessel`: the commander's first, then
-- every other occupied seat, closed parts and open ones alike.
function seatList(vessel)
  local out = {}
  local C, I = script_ref("crew"), iva_ref()
  if not (vessel and C) then return out end
  local active = C.activeId and C.activeId()
  local closed = {}
  if I and I.closedSeats then
    for _, s in ipairs(I.closedSeats(vessel)) do closed[s.uid .. ":" .. s.slot] = s end
  end
  local map = C.seatMap and C.seatMap(vessel) or {}
  local first, rest = {}, {}
  for _, s in ipairs(map) do
    local occupied = s.taken ~= nil
    local c = closed[s.uid .. ":" .. s.slot]
    if occupied or (c and #map == 1) then
      local e = { uid = s.uid, slot = s.slot, open = c == nil, id = s.taken }
      if s.taken ~= nil and s.taken == active then first[#first + 1] = e else rest[#rest + 1] = e end
    end
  end
  for _, e in ipairs(rest) do first[#first + 1] = e end
  -- an older controller (no seat map): the piloted pod, closed
  if #first == 0 and vessel.stationUid and I and I.closedSeats then
    for _, s in ipairs(I.closedSeats(vessel)) do
      if s.uid == vessel.stationUid then first[1] = { uid = s.uid, slot = s.slot, open = false } break end
    end
  end
  return first
end

local function main_mask(node, stacked)
  main_node = node
  local key = stacked and "iva" or "base"
  if main_mask_set == key then return end
  local ok = pcall(function()
    if stacked then node:setCamera { stack = { "Iva Cam" }, cullMask = cullBase() }
    else node:setCamera { stack = {}, cullMask = cullBase() } end
  end)
  if ok then main_mask_set = key end
end

local function ensure_iva_cam(node)
  if iva_cam and iva_cam.valid then return iva_cam end
  if iva_cam_making or not createNode then return nil end
  iva_cam_making = true
  createNode("Iva Cam", nil, function(n)
    iva_cam_making = false
    iva_cam = n
    -- (post "after": the cabin is laid over the picture after depth of field
    -- and motion blur, so they leave it sharp; grade and tonemap still apply.
    -- No sky capture or fog of its own: its reflections read the frame's sky
    -- map, and a cabin has no fog. Its sun shadows stay: the sun comes in
    -- through the windows and nowhere else.)
    pcall(function() n:setCamera { fovY = params.fov_y or 1.15, active = false, cullMask = INTERIOR_BIT, post = "after",
                                   sky = false, fog = false } end)
  end)
  return nil
end

-- Enter or leave the seat view. `on` = true enters at the first seat of the
-- list (or `at`, an index); false leaves.
function setCockpit(on, vessel, at)
  local I = iva_ref()
  if on then
    local list = seatList(vessel)
    local s = list[at or 1]
    if not s then cockpit = false return false end
    seat_vessel = vessel
    seatView = { uid = s.uid, slot = s.slot, open = s.open, index = at or 1, count = #list, id = s.id }
    if I then
      if s.open then I.clearView() else I.setView(vessel, s.uid, s.slot) end
    end
    if s.open then
      local a = find("Astronaut")
      for _, nm in ipairs({ "Helmet", "Helmet Visor", "Helmet Lamps" }) do
        local h = find_desc(a, nm)
        if h and I and I.park then I.park(h) end
      end
    end
    seat_yaw, seat_pitch = 0.0, -0.08
    cockpit = true
  else
    if I and I.clearView then I.clearView() end
    seatView, seat_vessel = nil, nil
    cockpit = false
    if main_node and main_node.valid then main_mask(main_node, false) end
  end
  return cockpit
end

-- Turn the head in the seat view (probes, a cutscene): radians, clamped.
function setSeatLook(yaw, pitch)
  local ylim = (seatView and seatView.open) and OPEN_YAW or SEAT_YAW
  seat_yaw = math.clamp(yaw or 0, -ylim, ylim)
  seat_pitch = math.clamp(pitch or 0, -SEAT_DOWN, SEAT_UP)
end

-- V in the seat: the next seat, or out after the last.
function nextSeat(vessel)
  if not cockpit then return setCockpit(true, vessel) end
  local i = (seatView and seatView.index or 1) + 1
  local list = seatList(vessel)
  if i > #list then return setCockpit(false) end
  return setCockpit(true, vessel, i)
end

-- The look, in the eye's frame (right, up, back), as a world direction.
local function look_dir(right, up, back)
  local cp = math.cos(seat_pitch)
  return (right * (math.sin(seat_yaw) * cp) + up * math.sin(seat_pitch) - back * (math.cos(seat_yaw) * cp)):normalized()
end

-- The head's own up for that look: the look turned a further quarter turn up
-- (∂look/∂pitch), so it is square to the look at every yaw and pitch and
-- turns smoothly with them.
-- THE VIEW SNAPPED ROUND (playtest 2026-10-27: "the camera often snaps around
-- while I look around" in the seat). The up handed to lookAt was the seat's
-- up, swapped for the seat's back once the look came within 11.5° of it —
-- but the head may pitch up to 80°, so every look up past 78.5° crossed that
-- line, and with the head turned the swap rolled the picture by up to the
-- yaw itself (170° looking back over the shoulder).
local function look_up(right, up, back)
  local sp, cp = math.sin(seat_pitch), math.cos(seat_pitch)
  return (right * (-math.sin(seat_yaw) * sp) + up * cp + back * (math.cos(seat_yaw) * sp)):normalized()
end

-- The seat view, once per frame. Returns false if the seat has gone (staged
-- away, destroyed, the crew out) and the view must fall back to the orbit.
local function seat_view(node, dt, blocked)
  local I, v, sv = iva_ref(), seat_vessel, seatView
  if not (I and v and sv and v.node and v.node.valid) then setCockpit(false) return false end
  local eye, right, up, back, place
  if sv.open then
    -- the avatar rides its own seat; another member's open seat is their doll
    local C = script_ref("crew")
    local a = (sv.id and C and C.activeId and C.activeId() ~= sv.id and C.dollOf and C.dollOf(sv.id)) or find("Astronaut")
    local o, X, Y = nil, nil, nil
    if I.partFrame then o, X, Y = I.partFrame(v, sv.uid) end
    if not (a and o) then setCockpit(false) return false end
    -- the rider's own eye, just in front of their face (iva.riderEye)
    place, right, up, back = I.riderEye(v, sv.uid, a)
    if not place then setCockpit(false) return false end
  else
    eye, right, up, back = I.eyeOf(v, sv.uid, sv.slot)
    place = I.mainEye(v, sv.uid)
    if not (eye and place) then setCockpit(false) return false end
  end
  -- The mouse always turns the head in here (a panel takes the pointer back).
  local looking = not blocked
  input.setMouseLocked(looking)
  mouseLooking = looking
  if looking then
    local dx, dy = input.mouse_delta()
    local st = script_ref("settings")
    local sens = params.sensitivity * 0.01 * ((st and st.lookScale) or 1.0)
    if st and st.invertY then dy = -dy end
    local ylim = sv.open and OPEN_YAW or SEAT_YAW
    seat_yaw = math.clamp(seat_yaw + dx * sens, -ylim, ylim)
    seat_pitch = math.clamp(seat_pitch - dy * sens, -SEAT_DOWN, SEAT_UP)
  end
  local fwd = look_dir(right, up, back)
  -- The same shake the orbit takes, scaled to a head strapped into a couch:
  -- the cabin rattles round you by centimetres, not metres.
  local sh = save.get("cam.shake") or 0.0
  if access.reducedMotion() then sh = 0.0 end
  local jx, jy = 0.0, 0.0
  if sh > 0.002 then
    local amp = sh * sh * 0.012
    jx, jy = (math.random() * 2 - 1) * amp, (math.random() * 2 - 1) * amp
  end
  -- the head's own up (look_up): never the seat's up swapped for its back
  local lup = look_up(right, up, back)
  place = place + right * jx + up * jy
  node.pos = place
  node:lookAt(place + fwd, lup)
  if sv.open then
    main_mask(node, false)
  else
    local ic = ensure_iva_cam(node)
    if ic then
      local e = eye + right * jx + up * jy
      ic.pos = e
      ic:lookAt(e + fwd, lup)
      local fv = params.fov_y
      local cc = node.getcomponent and node:getcomponent("Camera")
      if cc and cc.fovY then fv = cc.fovY end
      if iva_fov ~= fv then
        pcall(function() ic:setCamera { fovY = fv } end)
        iva_fov = fv
      end
      main_mask(node, true)
    end
  end
  fwd_x, fwd_y, fwd_z = fwd.x, fwd.y, fwd.z
  cam_x, cam_y, cam_z = place.x, place.y, place.z
  local flat = fwd:flatten(up)
  if flat:length() == 0 then flat = back * -1 end
  flat_x, flat_y, flat_z = flat.x, flat.y, flat.z
  if I.need then I.need(v) end
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
-- The closest the view may come to the pivot while flying: the craft's
-- closest orbit (`zoomRange`), set each frame.
local CHASE_MIN = 5.0
local lift_now, lift_t = 0.0, -10.0
local lift_want, lift_none = 0.0, nil   -- lift_none: no lift fits; the next step to try
local LIFT_SCAN = 2
function chase_clip(vessel, head, up, room_d, dt)
  if time - lift_t > 0.25 then lift_now, lift_want, lift_none = 0.0, 0.0, nil end   -- a new chase starts level
  lift_t = time
  local balls = hull_balls(vessel)
  -- what the view passes through: the craft (its parts), the crew, the tyres
  local passes = {}
  if vessel.node and vessel.node.valid then passes[#passes + 1] = vessel.node end
  local astro = find("Astronaut")
  if astro and astro.valid then passes[#passes + 1] = astro end
  for _, w in ipairs((vessel.R2 and vessel.R2.wheels) or {}) do
    if w.tyre and w.tyre.valid then passes[#passes + 1] = w.tyre end
  end
  local function trial(lift)
    local lp = math.max(-PITCH_LIMIT, pitch - lift)
    local f = (ref * math.cos(lp) + up * math.sin(lp)):normalized()
    local need, reach = hull_exit(balls, head, f * -1)
    need = math.max(need, math.min(reach, CHASE_MIN))
    local want = math.max(room_d, need)
    local hd = sweep(head, f * -1, want + 0.3, passes)
    local room = hd and math.max(0.0, hd - 0.1) or want
    return f, need, math.min(want, room), room >= need, lp <= -PITCH_LIMIT
  end
  -- The least lift that leaves room outside the hull. Each trial is a
  -- spherecast that meets every part of the craft, so the search starts from
  -- last frame's answer instead of from level: while that still fits, look
  -- down at most two steps a frame (the lift eases down slower than that
  -- anyway) and at level itself; when it no longer fits, search the whole
  -- range from level as before. When none fits, the view holds the top lift
  -- and the search goes on from level a few steps a frame (LIFT_SCAN), so a
  -- view boxed in on every side costs three casts a frame, not eighteen.
  -- (perfbench, rc10: 17 + 1 spherecasts a frame were 20-40 ms on the pad
  -- with a 1,000-part craft.)
  local want_lift = nil
  local k0 = math.max(0, math.min(LIFT_STEPS, math.floor((lift_want or 0) / LIFT_STEP + 0.5)))
  if lift_none then
    local k = lift_none
    for _ = 1, LIFT_SCAN do
      local _, _, _, ok2, top2 = trial(k * LIFT_STEP)
      if ok2 then want_lift = k * LIFT_STEP break end
      k = k + 1
      if top2 or k > LIFT_STEPS then k = 0 end
    end
    lift_none = (want_lift == nil) and k or nil
    want_lift = want_lift or LIFT_STEPS * LIFT_STEP
  else
    local ok = k0 > 0 and select(4, trial(k0 * LIFT_STEP))
    if ok then
      want_lift = k0 * LIFT_STEP
      for k = k0 - 1, math.max(1, k0 - 2), -1 do
        if not select(4, trial(k * LIFT_STEP)) then break end
        want_lift = k * LIFT_STEP
      end
      if want_lift > 0 and select(4, trial(0)) then want_lift = 0 end
    else
      for k = 0, LIFT_STEPS do
        local _, _, _, ok2, top2 = trial(k * LIFT_STEP)
        if ok2 then want_lift = k * LIFT_STEP break end
        if top2 then break end
      end
    end
    lift_none = (want_lift == nil) and 0 or nil
    want_lift = want_lift or LIFT_STEPS * LIFT_STEP
  end
  lift_want = want_lift
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

-- ── the flight camera's modes ───────────────────────────────────────────────
-- "a better solution that lets people admire their crafts more". C cycles how
-- the orbit follows the craft you are flying, and says so on screen:
--
--   Auto     in air (or near the ground), moving: the orbit swings round
--            behind the way you are going, like a chase car; drag with the
--            right button and it waits a moment before taking over again.
--            In space: a free orbit (the craft turns, the view does not).
--   Free orbit    the view stays where you put it; the horizon stays level.
--   Chase    LOCKED to the craft: it turns, rolls and pitches with it, as if
--            on a boom bolted to the hull.
--   Horizon  the horizon stays level, and the view turns as the craft yaws:
--            always the same side of the craft, the sky always up.
--
--   F6  PHOTO ORBIT: the view circles slowly round the pivot, for admiring
--       (F4 hides the interface for the picture; F12 takes it). F6 or Esc
--       stops it; the mouse and the zoom still work while it turns.
CAM_MODES = { "auto", "free", "chase", "horizon" }
CAM_MODE_NAMES = { auto = "Auto", free = "Free orbit", chase = "Chase (locked to the craft)",
                   horizon = "Locked to the horizon" }
camMode = "auto"           -- published
photoOrbit = false         -- published
PHOTO_ORBIT_RATE = math.rad(9)
ZOOM_STEP = 1.15           -- one scroll click while flying zooms by this factor
-- Published, for probes and the HUD: the piloted craft's extent and pivot.
--   { radius, axis, mind, maxd, fit, pivot = local vec3, centre = local vec3 }
craftFrame = nil
local craft = { id = nil, b = nil, t = -10.0, gen = -1, off = vec3(0, 0, 0), now = nil,
                lock = nil, axes = nil, look_t = -10.0, air = false, air_t = -10.0, zoomed = false,
                fit_r = nil }
local mode_msg, mode_msg_t = nil, -10.0
local last_up = vec3(0, 1, 0)

local function say(msg) mode_msg, mode_msg_t = msg, time end

-- The craft's bounds, refreshed when its parts change and twice a second (a
-- hinge swings an arm). A craft with no parts to read (a test rig, the frame
-- a craft is still being built) falls back to its pod.
local function craft_update(vessel, vn, swapped)
  if swapped or craft.id ~= vn.id then
    craft = { id = vn.id, b = nil, t = -10.0, gen = -1, off = vec3(0, 0, 0), now = nil,
              lock = nil, axes = nil, look_t = -10.0, air = false, air_t = -10.0, zoomed = false,
              fit_r = nil }
  end
  local parts = hull_parts(vn, vessel)
  if craft.gen ~= hull_cache.gen or time - craft.t > 0.5 or not craft.b then
    craft.gen, craft.t = hull_cache.gen, time
    local list = {}
    -- (a big craft's poses as the chase view last read them, when that was
    -- this frame's or recent enough; each `c.x` is a read across the engine)
    local recent = #parts > HULL_POSE_SMALL and hull_cache.pose_t and hull_cache.pose_gen == hull_cache.gen
      and time - hull_cache.pose_t <= HULL_POSE_EVERY and time >= hull_cache.pose_t
    for _, p in ipairs(parts) do
      local c = p.node
      if recent then
        if p.lx then list[#list + 1] = { x = p.lx, y = p.ly, z = p.lz, r = p.r } end
      elseif c.valid then list[#list + 1] = { x = c.x or 0, y = c.y or 0, z = c.z or 0, r = p.r } end
    end
    if #list == 0 then
      list[1] = { x = vessel.podLX or 0, y = vessel.podLY or 1.2, z = vessel.podLZ or 0, r = 1.0 }
    end
    craft.b = craftBounds(list)
  end
  local b = craft.b
  local mind, maxd, fit = zoomRange(b.radius, params.fov_y)
  -- Frame the whole craft when you take it, and again while it is still
  -- being put together, until you zoom yourself.
  if not craft.zoomed and (craft.fit_r == nil or math.abs(craft.fit_r - b.radius) > 0.25) then
    craft.fit_r = b.radius
    params.distance = fit
  end
  CHASE_MIN = mind
  craftFrame = { radius = b.radius, axis = b.axis, mind = mind, maxd = maxd, fit = fit,
                 centre = b.centre, pivot = craft.now or b.centre, off = craft.off }
  return b, mind, maxd, fit
end

-- The pivot this frame, in the craft's frame: the middle of the bounds plus
-- your slide, held on the craft, eased so a slide or a reset glides.
local function craft_pivot(dt)
  local b = craft.b
  local want = clampPivot(b, b.centre + craft.off)
  craft.off = want - b.centre          -- a slide past the end stops there
  if not craft.now then craft.now = want
  else craft.now = craft.now + (want - craft.now) * (1 - math.exp(-10 * dt)) end
  if craftFrame then craftFrame.pivot = craft.now end
  return craft.now
end

-- A world direction in the craft's frame and back (its axes are unit and
-- square: a craft node is never scaled).
local function to_local(d, ex, ey, ez) return vec3(d:dot(ex), d:dot(ey), d:dot(ez)) end
local function to_world(l, ex, ey, ez) return ex * l.x + ey * l.y + ez * l.z end

-- Slide the pivot by a mouse drag of (dx, dy) pixels, in the plane of the
-- screen, at a rate that keeps the craft under the cursor.
function panPivot(dx, dy)
  local vn = target
  if not (craft.b and vn and vn.valid) then return end
  local f = vec3(fwd_x, fwd_y, fwd_z)
  local right = f:cross(last_up)
  if right:length() < 1e-6 then return end
  right = right:normalized()
  local sup = right:cross(f):normalized()
  local k = math.max(params.distance or 10, 2.0) * 0.0011
  local d = right * (dx * k) - sup * (dy * k)
  local _, ex, ey, ez = craft_basis(vn)
  craft.off = craft.off + to_local(d, ex, ey, ez)
  craft.off = clampPivot(craft.b, craft.b.centre + craft.off) - craft.b.centre
end

-- Slide the pivot along the craft's long axis by `clicks` of the wheel:
-- toward whichever end is higher on the screen for a positive scroll.
function slidePivot(clicks)
  local vn = target
  local b = craft.b
  if not (b and vn and vn.valid) then return end
  local _, ex, ey, ez = craft_basis(vn)
  local ax = (b.axis == "x" and ex) or (b.axis == "z" and ez) or ey
  local f = vec3(fwd_x, fwd_y, fwd_z)
  local sup = f:cross(last_up):cross(f)
  local sign = (sup:length() > 1e-6 and ax:dot(sup) < 0) and -1 or 1
  local len = (b.axis == "x" and b.size.x) or (b.axis == "z" and b.size.z) or b.size.y
  local step = math.max(0.5, len * 0.08)
  local p = slideAlongAxis(b, b.centre + craft.off, clicks * step * sign)
  craft.off = p - b.centre
end

function resetPivot()
  craft.off = vec3(0, 0, 0)
  say("Pivot: middle of the craft")
end

function setCamMode(m)
  if not CAM_MODE_NAMES[m] then return end
  camMode = m
  craft.lock = nil
  say("Camera: " .. CAM_MODE_NAMES[m])
end

function cycleCamMode()
  for i, m in ipairs(CAM_MODES) do
    if m == camMode then setCamMode(CAM_MODES[i % #CAM_MODES + 1]) return camMode end
  end
  setCamMode("auto")
  return camMode
end

function setPhotoOrbit(on)
  photoOrbit = on == true
  say(photoOrbit and "Photo orbit — F6 or Esc to stop" or "Photo orbit off")
end

-- Is the craft somewhere a chase view makes sense: in a world's air, or near
-- its ground? Checked twice a second.
local function craft_in_air(p)
  if time - craft.air_t < 0.5 then return craft.air end
  craft.air_t = time
  craft.air = false
  local d = space and space.dominant and space.dominant(p.x, p.y, p.z)
  local b = d and space.body(d)
  if not b then return false end
  local alt = (p - vec3(b.x, b.y, b.z)):length() - (b.radius or 0)
  local w = save.get("world." .. d)
  local top = 0
  if w and (w.atmo or 0) > 0.01 then
    top = w.atmoHeight or 0
    if top <= 0 then top = (b.radius or 100) * 0.35 end
  end
  craft.air = alt < math.max(top, 1500.0)
  return craft.air
end

-- The craft's velocity over the world it is in. A node's velocity is already
-- that (a craft clamped to the pad reads 0 while its planet runs along its
-- rails at 240 m/s), so the body's own is NOT taken off: doing so swung the
-- chase round to follow the planet's orbit.
local function craft_vel(vn)
  return vec3(vn.vx or 0, vn.vy or 0, vn.vz or 0)
end

-- How far the craft has turned about `up` since the last frame (radians),
-- read off whichever of its axes lies flattest (a rocket standing on its
-- tail turns about its own long axis; its side does the telling).
local function craft_yaw_step(ex, ey, ez, up)
  local now = { ex, ey, ez }
  local prev = craft.axes
  craft.axes = now
  if not prev then return 0.0 end
  local best, bl = nil, 0.3
  for i = 1, 3 do
    local l = 1 - now[i]:dot(up) ^ 2
    if l > bl then best, bl = i, l end
  end
  if not best then return 0.0 end
  local a = prev[best] - up * prev[best]:dot(up)
  local b = now[best] - up * now[best]:dot(up)
  if a:length() < 0.3 or b:length() < 0.3 then return 0.0 end
  return math.atan2(a:cross(b):dot(up), a:dot(b))
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
  -- The gravity gun uses the wheel for its hold distance while it holds
  -- something (tool_belt.wantsScroll): the view must not zoom with it.
  do
    local tb = script_ref("tool_belt")
    if tb and tb.wantsScroll == true and not piloting then dz = 0.0 end
  end
  local maxd, mind = params.max_distance, params.min_distance
  -- Flying: the range comes from the craft's size (`zoomRange`), and a click
  -- is a FACTOR, so the wheel crosses a 130 m range as quickly as a 14 m one.
  -- One more click in from the closest orbit is the pilot's seat (as on foot,
  -- one click past the closest orbit is the eyes), and one click out leaves it.
  -- ALT + the wheel slides the pivot along the craft instead.
  if piloting then
    local _
    _, mind, maxd = craft_update(vessel, vessel.node, swapped)
    if dz ~= 0 and not cockpit and not blocked and input.key("alt") then
      slidePivot(dz / math.max(params.zoom_speed, 1e-3))
      dz = 0.0
    end
  end
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
      if math.abs(dz) > 0.01 then craft.zoomed = true end
      params.distance = math.clamp(params.distance * ZOOM_STEP ^ (-dz), mind, maxd)
    end
    if not blocked and input.pressed("v") then nextSeat(vessel) end
    if cockpit and not blocked and input.pressed("escape") then setCockpit(false) end
    if not blocked and not cockpit then
      if input.pressed("c") then cycleCamMode() end
      if input.pressed("home") then resetPivot() end
    end
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
  -- PHOTO ORBIT (F6). Not in first person or the seat: there is nothing to
  -- circle. Esc stops it before it opens anything (see `escTakenAt`).
  if not blocked and not cockpit and input.pressed("f6") then
    if firstPerson then firstPerson = false; params.distance = mind; clip_back = nil end
    setPhotoOrbit(not photoOrbit)
  end
  if photoOrbit and (cockpit or firstPerson) then photoOrbit = false end
  if photoOrbit and not blocked and input.pressed("escape") then
    setPhotoOrbit(false)
    escTakenAt = time
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

  -- CHASE, LOCKED TO THE CRAFT: the view's up and heading are held in the
  -- craft's own frame, captured from the view as it is when the mode starts
  -- (so nothing jumps), and carried round with the craft. Leaving the mode,
  -- the up eases back to the world's at the usual rate.
  local ex, ey, ez
  if piloting then
    local _o
    _o, ex, ey, ez = craft_basis(target)
  end
  if piloting and camMode == "chase" then
    if not craft.lock then
      craft.lock = { up = to_local(up, ex, ey, ez), ref = to_local(ref, ex, ey, ez) }
    end
    up = to_world(craft.lock.up, ex, ey, ez):normalized()
    cup = up
    ref = to_world(craft.lock.ref, ex, ey, ez)
  end

  -- Parallel-transport the yaw reference: project the previous reference onto
  -- the new tangent plane. Walking around the planet turns the frame WITH the
  -- surface, so the camera never rolls wildly or flips at the equator.
  ref = ref:flatten(up)
  if ref:length() == 0 then
    -- Degenerate (reference was parallel to up): pick any tangent.
    ref = up:cross(vec3(1, 0, 0)):normalized()
    if ref:length() == 0 then ref = up:cross(vec3(0, 0, 1)):normalized() end
  end

  -- LOCKED TO THE HORIZON: the view turns as the craft yaws. (The step is
  -- measured every frame, so the mode starts without a jump.)
  if piloting then
    local yaw = craft_yaw_step(ex, ey, ez, up)
    if camMode == "horizon" and math.abs(yaw) < 1.0 then ref = ref:rotatedAround(up, yaw) end
  end
  -- AUTO: in the air and moving, the orbit swings round behind the way the
  -- craft is going — gently, faster the faster it goes, and not for a moment
  -- after you have turned the view yourself.
  if piloting and camMode == "auto" and not photoOrbit and time - craft.look_t > 1.5
    and craft_in_air(target.pos) then
    local v = craft_vel(target)
    local hv = v - up * v:dot(up)
    local hs = hv:length()
    if hs > 3.0 then
      local dir = hv * (1 / hs)
      local ang = math.atan2(ref:cross(dir):dot(up), ref:dot(dir))
      if math.abs(ang) < math.rad(120) then
        ref = ref:rotatedAround(up, ang * (1 - math.exp(-1.5 * math.min(1, hs / 15) * dt)))
      end
    end
  end
  if photoOrbit then ref = ref:rotatedAround(up, PHOTO_ORBIT_RATE * dt) end

  -- Mouse steers while looking (RMB / shift lock); yaw rotates the reference
  -- around up (Rodrigues, u ⊥ r so it's just cos/sin), pitch is clamped.
  --
  -- IN FIRST PERSON THE MOUSE ALWAYS STEERS. Requiring a held right button to
  -- turn your own head is the single thing most responsible for first person
  -- "just not feeling right" here: the view is the aim, and a view you have to
  -- hold a button to move is a view you are fighting. The one exception is a
  -- panel — the depot's Sell button needs a pointer, and a grabbed mouse has
  -- none, so the panels take the cursor back for as long as they are up.
  -- Flying, the MIDDLE button held slides the pivot over the craft instead
  -- (`panPivot`): drag up and the view climbs the stack.
  local panning = piloting and not blocked and input.button(2) == true
  -- SHIFT LOCK IS THE WALKER'S (playtest 2026-10-27: "shiftlock gets stuck in
  -- flight"): its toggle (MMB / Alt) is off while flying — the middle button
  -- pans the pivot and Alt is the holds' and the pivot slide's — so a lock
  -- carried aboard could never be let go of, and the mouse stayed trapped.
  -- Flying, the view turns on a held right button (or the seat view); the
  -- walker's lock waits, untouched, for the next EVA.
  local locked = shiftlock and not piloting
  local looking = (not blocked) and (firstPerson or locked or input.button(1) or panning)
  input.setMouseLocked(looking)
  mouseLooking = looking
  last_up = up
  if panning then
    local dx, dy = input.mouse_delta()
    if (dx or 0) ~= 0 or (dy or 0) ~= 0 then panPivot(dx or 0, dy or 0) end
  elseif looking then
    local dx, dy = input.mouse_delta()
    -- The player's sensitivity and invert-Y (Settings ▸ Camera, settings.lua).
    local st = script_ref("settings")
    local sens = params.sensitivity * 0.01 * ((st and st.lookScale) or 1.0)
    if st and st.invertY then dy = -dy end
    -- Yaw spins the reference about the LOCAL up, not about world +Y — which
    -- is the whole reason this camera exists.
    ref = ref:rotatedAround(up, -dx * sens)
    pitch = math.clamp(pitch - dy * sens, -PITCH_LIMIT, PITCH_LIMIT)
    if (dx or 0) ~= 0 or (dy or 0) ~= 0 then craft.look_t = time end
  end
  if piloting and camMode == "chase" and craft.lock then
    craft.lock.ref = to_local(ref, ex, ey, ez)
  end

  -- FOLLOW. Walking without holding the view, the orbit drifts round behind
  -- where you are going, so a long walk sideways turns into a walk away from
  -- the camera instead of a circle round it. Never while you back toward the
  -- camera — following that would spin the view round to face you.
  if not looking and not piloting and not photoOrbit and params.follow_yaw > 0 then
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
  --
  -- The craft's pivot (see `craftBounds`) is in the craft's frame for the same
  -- reason: the middle of the craft by default, wherever you slid it after.
  local head
  if piloting and vessel and target and craft.b then
    -- `toWorld` composes the vessel's own rotation for us — the nine-term
    -- YXZ expansion this used to spell out by hand.
    head = target:toWorld(craft_pivot(dt))
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
    -- (not while the world loads: the crew is held 60 m over the ground then,
    -- with nothing over them, and the first sweeps after a world lands cost
    -- the engine 20+ ms each — measured on the home-world arrival frame)
    local gm = lift > 0.05 and script_ref("game_manager") or nil
    if lift > 0.05 and not (gm and gm.loading) then
      local roofhit = spherecast(target.pos, up, 0.25, lift, target)
      if roofhit and roofhit.distance and not (roofhit.node and roofhit.node.id == target.id) then
        head = head - up * (lift - math.max(0.0, roofhit.distance - 0.05))
      end
    end
    -- …and never INSIDE the rock (playtest 2026-10-27: "the character pokes
    -- through the ground… the camera snaps in and looks from beneath the
    -- terrain"). With the crew sunk into the ground the pivot was in the rock,
    -- the wall clip's ball started inside it and answered "a wall at 0 m", and
    -- the view sat at the pivot looking at the terrain's underside and the
    -- sea from below. The ground's own field says where the pivot is (cheap,
    -- (the walker reads it at the crew's centre ten times a second, the
    -- ground net); with the centre inside it, the pivot comes up to the
    -- surface. (A bored tunnel is air: nothing changes there.)
    pivot_lift = 0.0
    local wk = script_ref("planet_walker")
    local gn = wk and wk.groundNet
    local q = gn and gn.q
    if q and q < 0 then
      local h = (head - target.pos):dot(up)
      if q + h < CAM_CLEAR then
        pivot_lift = math.min(6.0, CAM_CLEAR - (q + h))
        head = head + up * pivot_lift
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
  -- (The snap in from under the ground, playtest 2026-10-27, was not this
  -- rule but a pivot inside the rock — the ball's first contact at 0 m: see
  -- the pivot's ground guard above. A real wall still pulls it in at once.)
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
  -- NEVER UNDER THE GROUND. On foot, a camera the sweep let into the rock (a
  -- ball that started inside it, a collision mesh not built yet, the ease
  -- above) is brought back along its line toward the pivot, which is in the
  -- open, to the last point outside it.
  -- (only when something is off: the pivot had to come up out of the rock,
  -- or the sweep pulled the view in — never on an open hillside)
  if not piloting and not firstPerson and back > 0.05 and (pivot_lift > 0 or back < room_d - 0.01)
    and terrain and terrain.query then
    local q = terrain.query(place.x, place.y, place.z)
    if q and q < CAM_CLEAR * 0.5 then
      local lo, hi = 0.0, back
      for _ = 1, 6 do
        local mid = (lo + hi) * 0.5
        local p2 = head - fwd * mid
        local qm = terrain.query(p2.x, p2.y, p2.z)
        if qm == nil or qm >= CAM_CLEAR * 0.5 then lo = mid else hi = mid end
      end
      back = lo
      clip_back = math.min(clip_back or lo, lo)
      place = head - fwd * back
      hidesBody = firstPerson or back < 0.7
      target.visible = not hidesBody
    end
  end
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
local atmo_ref, flare_ref

-- ── THE DEATH HOLD (docs/crew-and-items.md §2.3) ─────────────────────────────
-- When a crew member dies the view holds on the place for a couple of seconds
-- before control passes on (crew_alerts_hud.lua calls this). Kept relative to
-- the body it happened on: the planet moves metres a tick, so a world point
-- would slide out of frame.
local hold = nil
function holdOn(x, y, z, secs)
  local node = main_node or (findScript("planet_camera") or {}).node
  if not (node and space and space.dominant) then return false end
  local d = space.dominant(x, y, z)
  local b = d and space.body(d)
  if not b then return false end
  local cx, cy, cz = node.x, node.y, node.z
  -- frame it: back off to 6 m from the point if the camera is far or on it
  local dx, dy, dz = cx - x, cy - y, cz - z
  local l = math.sqrt(dx * dx + dy * dy + dz * dz)
  if l > 25 or l < 2 then
    local ux, uy, uz = x - b.x, y - b.y, z - b.z
    local ul = math.max(1e-6, math.sqrt(ux * ux + uy * uy + uz * uz))
    ux, uy, uz = ux / ul, uy / ul, uz / ul
    if l < 1e-3 then dx, dy, dz, l = ux, uy, uz, 1 end
    dx, dy, dz = dx / l, dy / l, dz / l
    cx, cy, cz = x + (dx + ux) * 4.0, y + (dy + uy) * 4.0, z + (dz + uz) * 4.0
  end
  hold = { body = d, px = x - b.x, py = y - b.y, pz = z - b.z, cx = cx - b.x, cy = cy - b.y, cz = cz - b.z,
           t1 = time + (secs or 2.0) }
  return true
end
function holding() return hold ~= nil end

local function hold_tick(node)
  if not hold then return false end
  if time > hold.t1 then hold = nil return false end
  local b = space.body(hold.body)
  if not b then hold = nil return false end
  local p = vec3(b.x + hold.px, b.y + hold.py, b.z + hold.pz)
  local c = vec3(b.x + hold.cx, b.y + hold.cy, b.z + hold.cz)
  local up = (p - vec3(b.x, b.y, b.z)):normalized()
  node.pos = c
  node:lookAt(p, up)
  local f = (p - c):normalized()
  fwd_x, fwd_y, fwd_z = f.x, f.y, f.z
  cam_x, cam_y, cam_z = c.x, c.y, c.z
  return true
end

function lateUpdate(node, dt)
  -- The interiors and parked nodes are never the main camera's to draw.
  if main_mask_set == nil or (main_mask_set == "iva" and not (cockpit and seatView and not seatView.open)) then
    main_mask(node, false)
  end
  -- The VAB builder's own camera has the view (build_host); this one waits.
  local gm = script_ref("game_manager")
  if gm and gm.inputOwner == "builder" then return end
  if cinematic_tick(node, dt) then
    -- the free camera placed the view itself
  elseif hold_tick(node) then
    -- a death: the view holds on the place
  else
    place_camera(node, dt)
  end
  -- The camera mode / pivot line, for a couple of seconds after a change
  -- (never in cinematic mode: that is for pictures).
  if mode_msg and time - mode_msg_t < 2.2 and not cinematic and draw and draw.text
    and camera and camera.screenSize then
    local sw, sh = camera.screenSize()
    if sw and sh then
      local k = sh / 1080
      local a = math.min(1.0, (2.2 - (time - mode_msg_t)) * 2.5) * 0.92
      draw.text(sw * 0.5, sh * 0.14, mode_msg, 22 * k, 0.92, 0.89, 0.81, a, "center")
    end
  end
  if not atmo_ref or not atmo_ref.valid then atmo_ref = findScript("atmosphere") end
  if atmo_ref and atmo_ref.valid and atmo_ref.follow then atmo_ref.follow(dt) end
  -- The sun flare projects the star through the camera, so it too wants the
  -- camera where this frame put it (its own lateUpdate runs before ours).
  if not flare_ref or not flare_ref.valid then flare_ref = findScript("sun_flare") end
  if flare_ref and flare_ref.valid and flare_ref.follow then flare_ref.follow(dt) end
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
-- T, for a probe: freeze time (only while the free camera flies, as the key).
function setTimeFreeze(on) if freecam then set_freeze(on == true) end end
-- The shutter, for a probe (F12 is the player's).
function takeScreenshot() screenshot() end
