-- BASE FACILITIES — the home spaceport. Everything that stands at the base for
-- the whole session: the Vehicle Assembly Building, the Command Centre, the
-- Commerce Depot, the Tracking Station (the comms dish the facilities menu
-- reads `comms.ships` through), the power yard, the propellant farm, Launch
-- Complex 1 — and the ground they stand on: a graded plain with a paved runway,
-- a taxiway, aprons, roads and the crawlerway out to the pad, with their lights,
-- a perimeter fence and the signs.
--
-- THE BASE IS A PLACE. It is sited ONCE — at the crew's landing site, and only
-- after the loading screen has handed the world over — and then remembered
-- body-relative in the save (`base.body`, `base.x/y/z`, plus this layout's
-- `base.layout`, `base.heading` and `base.r`). Every later session rebuilds it
-- on the same ground. (Before that the ring was cut around wherever the
-- astronaut happened to be when the terrain first answered — on a loaded save,
-- the loading hover over the north pole.)
--
-- THE LAYOUT IS DRAWN ON THE SPHERE. A home world is 600–950 m across the
-- radius: a 250 m runway spans 15–24° of it, and its ends sit 8–13 m below the
-- tangent plane at its middle. Nothing here is laid on a flat map. The layout
-- is written in ARC metres in a frame at the base centre C — u along the
-- runway, v across it, (u, v, up) right-handed like east-north-up — and mapped
-- onto the sphere of the graded radius R:
--
--   * a building's lot (u, v) is the point d = √(u²+v²) metres round the
--     great circle on that bearing (azimuthal equidistant), stood on its OWN
--     radial up there, its front turned to the layout direction it faces;
--   * a paved strip (runway, taxiway, road, apron) is the great-circle arc
--     between its two ends, s along it and w across it, every vertex on the
--     sphere — so the runway is straight AND follows the curve, and a rover
--     driving down its centreline stays on it.
--
-- THE GROUND IS GRADED TO THAT SPHERE. Discs of `terrain.sculpt(..,"flatten")`
-- are laid along every strip and over every lot, each centred ON the sphere of
-- radius R with the planet's radial up as its plane (the engine's default on a
-- planet), so the overlapping tangent planes converge on the sphere to a few
-- centimetres. The paving is a mesh laid 10 cm over that ground (a mesh, not a
-- collider: wheels and boots ride the graded terrain). The edits persist in the
-- slot's terrain; a later session only checks a few points (terrain.query on
-- the sphere) and regrades if the ground has moved.
--
-- The draw cost is held down on purpose: every building is one glb with at
-- most five materials (tools/gen_base.py, colours as vertex colours), and the
-- whole of the paving, the light fittings and the fixtures are three meshes
-- built here (mesh.build, vertex-coloured). Only the pad floodlights, two apron
-- floods and the buildings' interior lamps are real lights.
--
-- The world agent keeps the plain flat (scripts/system_generator.lua) and the
-- scatter off the paving (flora_field / mineral_field ask `keepClear`); see
-- SCRATCH homeworld_spec.md, "Base footprint".

-- ── the layout (arc metres from the base centre C) ───────────────────────────
LAYOUT_VERSION = 3   -- 3: the 50 × 50 × 72 m VAB (tools/vab_dims.py); Command, Power, Tracking moved out

-- The runway, 250 × 18 m paved plus 6 m blast pads, 3 m shoulders.
RUNWAY = { v = -62.0, u0 = -131.0, u1 = 131.0, blast = 6.0, half = 9.0, shoulder = 3.0 }
-- The taxiway from the runway's north shoulder to the VAB apron.
TAXIWAY = { u = 0.0, v0 = -50.0, v1 = -24.0, half = 6.0 }

-- Paved strips other than the runway: { name, u0, v0, u1, v1, half-width,
-- kind } (kind picks the paint).
STRIPS = {
  { "Apron",       0.0, -24.0,   0.0,   2.6, 24.0, "apron" },
  { "Crawlerway",  0.0,  57.6,   0.0,  96.0,  8.0, "crawler" },
  { "Road East",  24.0,  -8.0,  96.0,  -8.0,  4.0, "road" },
  { "Road West", -24.0,  -8.0, -66.0,  -8.0,  4.0, "road" },
  { "Depot Yard", -50.0, -4.0, -50.0,   5.8,  9.0, "yard" },
  { "Command Walk", 50.0, -4.0, 50.0,   1.7,  4.0, "walk" },
  { "Power Yard",  84.0,  -4.0,  84.0,  8.0,  3.0, "walk" },
  { "Fuel Spur",   -8.0, 104.0, -31.0, 104.0,  3.0, "road" },
}

-- The buildings. face = the layout direction the model's FRONT (+Z) turns to
-- ("S" = −v, toward the runway). seat/ox/oz come from tools/gen_base.py: the
-- prefab origin sits `seat` over the ground and (ox, oz) off the lot centre
-- along the model's own x / z (the engine centres a model on its box, and a
-- crane or a ramp makes the box lopsided). lot = the model's x × z footprint,
-- for the grading and for keepClear: the model's whole box (x × z), centred on
-- the prefab origin.
FACILITIES = {
  { prefab = "FacHangar",   u = 0.0,   v = 28.0,  face = "S", seat = -0.240, ox = 0.000, oz = 0.000,  lot = { 51.4, 59.1 }, lift = 0.15,
    interior = "VabInterior" },
  { prefab = "FacCommand",  u = 50.0,  v = 12.0,  face = "S", seat = 8.954,  ox = 0.874, oz = 2.070,  lot = { 32.2, 18.9 }, lift = 0.15 },
  { prefab = "FacDepot",    u = -50.0, v = 12.0,  face = "S", seat = 5.204,  ox = 5.065, oz = 0.000,  lot = { 32.5, 18.0 }, lift = 0.15 },
  { prefab = "FacTracking", u = 40.0,  v = 46.0,  face = "S", seat = 5.877,  ox = 0.000, oz = -1.333, lot = { 11.1, 15.5 } },
  { prefab = "FacPower",    u = 84.0,  v = 14.0,  face = "S", seat = 2.570,  ox = 0.013, oz = 0.000,  lot = { 18.0, 12.0 } },
  { prefab = "BaseFuel",    u = -40.0, v = 112.0, face = "W", seat = 8.967,  ox = 0.000, oz = 0.000,  lot = { 28.0, 18.0 } },
  { prefab = "BasePad",     u = 0.0,   v = 125.0, face = "N", seat = 16.520, ox = 0.000, oz = -4.011, lot = { 42.0, 50.0 } },
}
-- Launch Complex 1, in its own ground frame (tools/gen_base.py): the mount is
-- the lot centre, the hardstand top HS_H over the ground.
PAD = { u = 0.0, v = 125.0, hs = 2.0 }

-- The fence round the building compound (u0, v0, u1, v1), with its gates.
FENCE = { u0 = -70.0, v0 = -30.0, u1 = 100.0, v1 = 62.0,
          gates = { { side = "S", a = -9.0, b = 9.0 }, { side = "N", a = -11.0, b = 11.0 } } }

-- How far round from C the base reaches (the runway's corners, the pad's
-- masts) plus room: what the world agent keeps flat, and the scatter's cheap
-- pre-check in keepClear.
FOOTPRINT_RADIUS = 175.0

-- Grading: disc radius and spacing (m), and passes. Each flatten moves the
-- ground only part of the way inside its disc's soft rim; three passes over
-- overlapping discs leave it within a few cm of the sphere.
GRADE = { r = 20.0, step = 13.0, passes = 2, margin = 6.0,
          probeStep = 4.0, probeMin = 40.0, cutTop = 120.0, cutR = 8.5, fillR = 6.0, near = 450.0 }
-- How far over the sea the graded plain stands at the least (m): a rover on
-- the runway must be on dry land, clear of the water's reach.
SEA_MARGIN = 4.0
-- Paving height over the graded ground.
PAVE_H = 0.14

-- Published so the objectives HUD can point at the base and the debug keys can
-- send you home. World coordinates, refreshed every frame the base exists.
sited = false
baseX, baseY, baseZ = 0, 0, 0
baseBody = nil
-- { body, x, y, z (body-relative centre), radius } once sited; nil before.
footprint = nil

local want_spawn = false
local wait_t = 0.0
local last_note = 0.0
-- On 0.117 rc19 and later (floptle/0515) the site's ground is found with
-- terrain.raycast and made final with terrain.prepare before the fit:
-- READY_R round the centre (every point the fit samples — the runway's far
-- corners are ~150 m out), READY_WAIT s at most. rc16 had both calls, but
-- there a cast could stop on stand-in ground and still say exact (fits
-- 57-216 m over the real ground), and a prepare asked while the world
-- streamed in was dropped (the 15 s wait bought nothing): an older engine
-- keeps the query march below.
READY_R, READY_WAIT = 150.0, 15.0
local ready_t0, ready_late, ready_said = nil, false, false
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
FIELD_RAYCAST = terrain ~= nil and terrain.raycast ~= nil and terrain.ready ~= nil and terrain.prepare ~= nil
  and engine_at_least(0, 117, 0, 19)
local casts, casts_inexact = 0, 0
local done = {}       -- prefab -> true once spawned
local placed = 0
local built = nil     -- { nodes = {...}, meshes = {...} } runtime meshes
local grade_later = nil  -- a grade put off until the crew comes home
local recheck_at = nil   -- when to look at the ground again after grading
local regrades = 0
-- The worst error the last check found: a regrade that leaves it where it
-- was (within 2 cm) cannot fix it (it is not the grade's to fix: a feature
-- the probe lands on, or a field the brush cannot reach), so a second try
-- stops there instead of grading the same ground again in view.
local last_worst = nil
local function grade_stuck(worst)
  local same = last_worst ~= nil and math.abs(worst - last_worst) < 0.02
  last_worst = worst
  return same
end
local grade_job = nil
local pave_pending = nil  -- paving waiting for the grade under it
local pave_job = nil
local F = nil         -- the layout frame once known

-- Cross-script singletons, resolved once and kept: `findScript` walks the whole
-- scene (floptle/0063). A handle stays good until the scene changes, and
-- `.valid` is how you find out that it has.
local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or not r.valid then r = findScript(kind); refs[kind] = r end
  return r
end

-- ── time-slicing ─────────────────────────────────────────────────────────────
-- Siting is a JOB: a coroutine resumed once a frame that yields once it has
-- spent WORK_MS of this frame's wall clock (checked at its units of work: a
-- field query, a row of paving, a fitting). The engine stops a script that
-- runs 2 s without returning, and on a loaded machine — the world still
-- generating on every core — fitting the layout (a few thousand field
-- marches) and building the paving got there and the base was never sited.
-- It used to be counted in units (250 a frame, 2,500 behind the loading
-- curtain), not os.clock, which counts the process's CPU across threads
-- (~10× wall time while the world generates); but a unit is anything from a
-- microsecond to a march, and behind the curtain that made 80–190 ms frames.
-- The clock here is the WALL (app.wallClock), so other threads don't count.
WORK_MS = 3.0
WORK_MS_CURTAIN = 6.0   -- behind the loading curtain (it holds the curtain up)
WORK_CHECK = 4          -- units between looks at the clock
local job, job_active, units = nil, false, 0
local function wall() return (app and app.wallClock and app.wallClock()) or os.clock() end
JOB_T0 = 0
function work(n)
  units = units + (n or 1)
  if not job_active or units < WORK_CHECK then return end
  units = 0
  local gm = refs.game_manager
  local budget = (gm and gm.valid ~= false and gm.curtain) and WORK_MS_CURTAIN or WORK_MS
  if (wall() - JOB_T0) * 1000 >= budget then
    coroutine.yield()
  end
end
-- (each resume starts the frame's budget)
local function job_begin() job_active, units, JOB_T0 = true, 0, wall() end

-- ── vector helpers (plain tables, so the smoke harness needs no vec3) ────────
local sqrt, sin, cos, acos, atan2, abs = math.sqrt, math.sin, math.cos, math.acos, math.atan2, math.abs
local function V(x, y, z) return { x = x, y = y, z = z } end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function cross(a, b) return V(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end
local function add(a, b, k) k = k or 1 return V(a.x + b.x * k, a.y + b.y * k, a.z + b.z * k) end
local function mul(a, k) return V(a.x * k, a.y * k, a.z * k) end
local function len(a) return sqrt(dot(a, a)) end
local function unit(a)
  local l = len(a)
  if l < 1e-12 then return V(0, 1, 0) end
  return V(a.x / l, a.y / l, a.z / l)
end
local function clamp(x, a, b) return math.max(a, math.min(b, x)) end

-- ── the frame and the map onto the sphere ────────────────────────────────────

-- The layout frame at unit direction `c` (planet-local), the runway turned
-- `heading` radians from local east toward north, on a sphere of radius R.
function frameOf(c, heading, R)
  c = unit(c)
  local Y = V(0, 1, 0)
  local north = add(Y, c, -dot(Y, c))
  if len(north) < 1e-3 then north = add(V(1, 0, 0), c, -c.x) end
  north = unit(north)
  local east = cross(north, c)
  local h = heading or 0
  local eu = unit(add(mul(east, cos(h)), north, sin(h)))
  local ev = cross(c, eu)
  return { c = c, eu = eu, ev = ev, north = north, east = east, R = R, heading = h }
end

-- Layout (u, v) → planet-local unit direction (azimuthal equidistant about C).
function dirAt(Fr, u, v)
  local d = sqrt(u * u + v * v)
  if d < 1e-9 then return Fr.c end
  local a = d / Fr.R
  local t = add(mul(Fr.eu, u / d), Fr.ev, v / d)
  return unit(add(mul(Fr.c, cos(a)), t, sin(a)))
end

-- Planet-local direction (any length) → layout (u, v).
function uvOf(Fr, p)
  local d = unit(p)
  local cd = clamp(dot(d, Fr.c), -1, 1)
  local t = add(d, Fr.c, -cd)
  local tl = len(t)
  if tl < 1e-12 then return 0, 0 end
  local a = acos(cd) * Fr.R
  return a * dot(t, Fr.eu) / tl, a * dot(t, Fr.ev) / tl
end

-- A front direction in the layout ("S" = −v …) as a tangent at `up`.
local FACE = { S = { 0, -1 }, N = { 0, 1 }, E = { 1, 0 }, W = { -1, 0 } }
local function face_at(Fr, up, face)
  local f = FACE[face] or FACE.S
  local w = add(mul(Fr.eu, f[1]), Fr.ev, f[2])
  return unit(add(w, up, -dot(w, up)))
end

-- A great-circle strip between layout points: s ∈ [0, L] along, w across
-- (+w = the a×b side, which is +v for a strip running +u).
function stripOf(Fr, u0, v0, u1, v1)
  local a, b = dirAt(Fr, u0, v0), dirAt(Fr, u1, v1)
  local om = acos(clamp(dot(a, b), -1, 1))
  local n = unit(cross(a, b))
  return { a = a, b = b, om = om, n = n, L = om * Fr.R, R = Fr.R }
end

-- Unit direction at (s, w) on a strip.
function stripDir(S, s, w)
  local t = S.om > 1e-9 and s / S.L or 0
  local d
  if S.om > 1e-9 then
    local so = sin(S.om)
    d = add(mul(S.a, sin((1 - t) * S.om) / so), S.b, sin(t * S.om) / so)
  else
    d = S.a
  end
  local k = w / S.R
  return unit(add(mul(d, cos(k)), S.n, sin(k)))
end

-- The along-strip tangent at s (on the centreline).
local function stripTan(S, s)
  return unit(cross(S.n, stripDir(S, s, 0)))
end

local function runway_strip(Fr)
  return stripOf(Fr, RUNWAY.u0, RUNWAY.v, RUNWAY.u1, RUNWAY.v)
end

-- ── where a launch rolls out ─────────────────────────────────────────────────

-- The frame of THIS save's base, from the save alone (vessel_spawner and
-- game_manager ask before anything here has run). nil when the save has no
-- layout-2 base.
local function saved_frame()
  local name = save.get("base.body")
  local bx, by, bz = save.get("base.x"), save.get("base.y"), save.get("base.z")
  if not (type(name) == "string" and bx and by and bz) then return nil end
  if (save.get("base.layout") or 0) < LAYOUT_VERSION then return nil end
  local R = save.get("base.r") or sqrt(bx * bx + by * by + bz * bz)
  return frameOf(V(bx, by, bz), save.get("base.heading") or 0, R), name
end

-- A launch site, body-relative: { body, kind, x, y, z (the point the craft
-- stands on), up = {x,y,z}, fwd = {x,y,z} (the way it should face; the runway's
-- direction), deck = true when the pad's clamps go down }. `kind` is "pad" or
-- "runway"; a base with no runway answers the pad. nil without a base.
function launchSite(kind)
  local Fr, name = saved_frame()
  if not Fr then return nil end
  if kind == "runway" and save.get("base.runway") ~= false then
    local S = runway_strip(Fr)
    local s = RUNWAY.blast + 14.0         -- just past the threshold bars, on the centreline
    local d = stripDir(S, s, 0)
    local p = mul(d, Fr.R)
    return { body = name, kind = "runway", x = p.x, y = p.y, z = p.z, up = d, fwd = stripTan(S, s), deck = false }
  end
  local d = dirAt(Fr, PAD.u, PAD.v)
  local p = mul(d, Fr.R + PAD.hs)
  return { body = name, kind = "pad", x = p.x, y = p.y, z = p.z, up = d, fwd = face_at(Fr, d, "N"), deck = true }
end

-- A facility's lot in layout space: its box's centre (u, v) and half sizes,
-- turned by the way it faces. The model's +X is up × front.
function lotRect(f)
  local hx, hz = f.lot[1] / 2, f.lot[2] / 2
  local du, dv, hu, hv
  if f.face == "N" then du, dv, hu, hv = -f.ox, f.oz, hx, hz
  elseif f.face == "E" then du, dv, hu, hv = f.oz, f.ox, hz, hx
  elseif f.face == "W" then du, dv, hu, hv = -f.oz, -f.ox, hz, hx
  else du, dv, hu, hv = f.ox, -f.oz, hx, hz end
  return f.u + du, f.v + dv, hu, hv
end

-- ── keep the scatter off the paving ──────────────────────────────────────────

local function in_strip(u, v, u0, v0, u1, v1, half)
  local du, dv = u1 - u0, v1 - v0
  local L2 = du * du + dv * dv
  local t = L2 > 0 and ((u - u0) * du + (v - v0) * dv) / L2 or 0
  if t < -0.02 or t > 1.02 then return false end
  local px, py = u0 + du * t - u, v0 + dv * t - v
  return px * px + py * py <= half * half
end

-- Is this body-relative point on the base's paving, a lot or the pad? The
-- flora and rock fields skip such points. Cheap enough to sample a density
-- grid with: a distance pre-check, then rectangles in layout space.
function keepClear(bodyName, rx, ry, rz)
  if not footprint or bodyName ~= footprint.body or not F then return false end
  local dx, dy, dz = rx - footprint.x, ry - footprint.y, rz - footprint.z
  if dx * dx + dy * dy + dz * dz > (FOOTPRINT_RADIUS + 10) ^ 2 then return false end
  local u, v = uvOf(F, V(rx, ry, rz))
  local m = 3.0
  if save.get("base.runway") ~= false and
     in_strip(u, v, RUNWAY.u0 - 4, RUNWAY.v, RUNWAY.u1 + 4, RUNWAY.v, RUNWAY.half + RUNWAY.shoulder + m + 2) then
    return true
  end
  if in_strip(u, v, TAXIWAY.u, TAXIWAY.v0, TAXIWAY.u, TAXIWAY.v1, TAXIWAY.half + m) then return true end
  for _, s in ipairs(STRIPS) do
    if in_strip(u, v, s[2], s[3], s[4], s[5], s[6] + m) then return true end
  end
  for _, f in ipairs(FACILITIES) do
    local cu, cv, hu, hv = lotRect(f)
    if abs(u - cu) <= hu + m and abs(v - cv) <= hv + m then return true end
  end
  return false
end

-- ── siting ───────────────────────────────────────────────────────────────────

-- The body whose SOI we're inside (nearest wins when SOIs nest).
local function dominant_at(x, y, z)
  local best, bd = nil, nil
  for _, b in ipairs(space.bodies()) do
    local dx, dy, dz = x - b.x, y - b.y, z - b.z
    local d = sqrt(dx * dx + dy * dy + dz * dz)
    if (b.soi or -1) > 0 and d < b.soi and (not best or d < bd) then
      best, bd = b, d
    end
  end
  return best
end

function start(node)
  -- Wait for the crew + terrain to exist, then place the base once.
  want_spawn = true
  log("base: siting the spaceport — waiting for the base terrain…")
end

-- Which world the base belongs to. Once sited it is THAT planet's spaceport:
-- if the crew is off visiting another world nothing is built — the base is
-- waiting for them at home.
local function site_body(crew)
  local home = save.get("base.body")
  local here = dominant_at(crew.x, crew.y, crew.z)
  if home then
    if not here or here.name ~= home then return nil end
    return space.body(home) or here
  end
  return here
end

-- How far above the body's centre a probe must start to be outside the terrain.
local function probe_altitude(body)
  local w = save.get("world." .. (body.name or ""))
  local r = (w and w.radius) or body.radius or 100
  local relief = (w and w.relief) or 0
  return r + relief * 2.0 + 120.0
end

-- The ground's radius along unit direction d, marched down the terrain's
-- distance field (a true distance: stepping by it never passes through ground).
-- Works as soon as the field exists, before any collision is meshed.
--
-- The field's distance is clamped a few metres out, so the march goes ~5 m a
-- step: from a scale-3/4 world's probe altitude (radius + 2·peak + 120 m) the
-- ground can be 400 m down. A march that has not FOUND the ground answers
-- nil, never the radius it stopped at: the old 80-step cap returned "the
-- ground is at r 630" on a world of radius 922 whose ground was not made yet
-- (no field there reads as air all the way down), and the spaceport was
-- fitted 290 m under the surface — 23,000 cuts, a grade that never held
-- ("22 m off": the rock over it) and the curtain up for minutes.
--
-- With FIELD_RAYCAST it is one terrain.raycast down the field instead: the
-- first surface along the ray, nil for a miss ("air", or "unknown": ground
-- the world has not made yet) — the same "not found" the march answers,
-- without the march. A hit that crossed stand-in ground (exact false) is
-- used as the march would use it, and counted: try_place has made the site
-- final first, so the count says when that did not hold.
local function ground_r(body, d, top)
  if FIELD_RAYCAST then
    work(4)
    local b = space.body(body.name) or body      -- live: the job spans frames
    local hit = terrain.raycast(V(b.x + d.x * top, b.y + d.y * top, b.z + d.z * top),
      V(-d.x, -d.y, -d.z), top * 0.75)
    if not hit then return nil end
    casts = casts + 1
    if not hit.exact then casts_inexact = casts_inexact + 1 end
    return top - hit.distance
  end
  local r = top
  for _ = 1, 600 do
    work(1)
    local b = space.body(body.name) or body      -- live: the job spans frames
    local q = terrain.query(b.x + d.x * r, b.y + d.y * r, b.z + d.z * r)
    if not q then return nil end
    if q < 0.12 then return r - math.max(q, 0) end
    r = r - math.max(q * 0.9, 0.08)
    if r < top * 0.25 then return nil end
  end
  return nil
end

-- Where the layout samples the ground when it is fitted: along the runway, at
-- the pad, the lots and the aprons. { u, v, what }.
local function fit_samples()
  local out = {}
  for k = 0, 10 do
    local u = RUNWAY.u0 + (RUNWAY.u1 - RUNWAY.u0) * k / 10
    out[#out + 1] = { u, RUNWAY.v, "runway" }
    out[#out + 1] = { u, RUNWAY.v + RUNWAY.half, "runway" }
    out[#out + 1] = { u, RUNWAY.v - RUNWAY.half, "runway" }
  end
  for _, f in ipairs(FACILITIES) do
    local cu, cv, hu = lotRect(f)
    out[#out + 1] = { cu, cv, f.prefab }
    out[#out + 1] = { cu + hu * 0.8, cv, f.prefab }
    out[#out + 1] = { cu - hu * 0.8, cv, f.prefab }
  end
  for _, s in ipairs(STRIPS) do
    out[#out + 1] = { (s[2] + s[4]) / 2, (s[3] + s[5]) / 2, s[1] }
  end
  return out
end

-- The sea's radius on this body (the world record's, as climate.seaRadius
-- reads it), or nil for a dry world.
local function seaRadiusOf(body)
  local w = save.get("world." .. (body.name or ""))
  local sea = w and w.sea
  if type(sea) == "number" and sea > 0 then return sea end
  return nil
end

local function water_at(body, d, g)
  local cl = ref("climate")
  if not (cl and cl.waterLevelAt) then return nil end
  local ok, wl = pcall(cl.waterLevelAt, body.name, d.x, d.y, d.z, g)
  return ok and wl or nil
end

-- FIT THE LAYOUT to the ground around C: the graded radius R (the ground at
-- the core, never under the water), and the heading that needs the least
-- earthwork and puts nothing in the water. East–west wins a tie, so on the
-- flat plain a home world keeps for it the runway is 09/27.
function fitLayout(body, c)
  c = unit(c)
  local top = probe_altitude(body)
  -- R: the median ground over the core (the lots round C).
  local core = {}
  local F0 = frameOf(c, 0, body.radius or 100)
  for _, p in ipairs({ { 0, 0 }, { 25, 0 }, { -25, 0 }, { 0, 25 }, { 0, -25 }, { 40, 12 }, { -40, 12 }, { 0, 40 }, { 0, -40 } }) do
    local g = ground_r(body, dirAt(F0, p[1], p[2]), top)
    if g then core[#core + 1] = g end
  end
  if #core == 0 then return nil end
  table.sort(core)
  local R = core[math.floor((#core + 1) / 2)]
  local wl = water_at(body, c, R)
  if wl and R < wl + 1.5 then R = wl + 1.5 end
  -- Never down at the sea: the plain is graded SEA_MARGIN over it at least
  -- (water_at only answers once the ground is already UNDER the water, so a
  -- core 0.1 m over the sea passed), the grade filling up where the ground is
  -- lower and the edge discs ramping it back down. A base already laid out
  -- keeps its saved radius.
  local sea = seaRadiusOf(body)
  if sea and R < sea + SEA_MARGIN then R = sea + SEA_MARGIN end
  -- Heading: 24 candidates, cost = earthwork + 400 per wet sample.
  local samples = fit_samples()
  top = R + 40.0       -- the footprint's ground is near R; a shorter march
  local best, best_cost, best_wet = 0, nil, 0
  for k = 0, 23 do
    local h = k * math.pi / 12
    local Fr = frameOf(c, h, R)
    local cost, wet, rw_wet = 0, 0, 0
    for _, sp in ipairs(samples) do
      local d = dirAt(Fr, sp[1], sp[2])
      local g = ground_r(body, d, top) or R
      cost = cost + abs(g - R)
      local w = water_at(body, d, g)
      if w and g < w + 0.5 then
        wet = wet + 1
        if sp[3] == "runway" then rw_wet = rw_wet + 1 end
      end
    end
    cost = cost + wet * 400 + math.min(k, 24 - k) * 0.05
    if not best_cost or cost < best_cost then best, best_cost, best_wet = h, cost, rw_wet end
  end
  return R, best, best_cost, best_wet
end

-- The flatten discs: centres (unit directions) along every strip and over
-- every lot. Each disc is centred ON the sphere of radius R.
function gradeDiscs(Fr, runway)
  local out = {}
  local step, m = GRADE.step, GRADE.margin
  local function strip(S, half)
    local reach = half + m
    local rows = math.max(1, math.ceil(2 * reach / (GRADE.r * 0.95)))
    local ns = math.max(1, math.ceil(S.L / step))
    for i = 0, ns do
      local s = S.L * i / ns
      for j = 0, rows - 1 do
        local w = rows == 1 and 0 or (-reach + GRADE.r * 0.45 + (2 * reach - GRADE.r * 0.9) * j / (rows - 1))
        out[#out + 1] = stripDir(S, s, w)
      end
    end
  end
  if runway then strip(runway_strip(Fr), RUNWAY.half + RUNWAY.shoulder) end
  strip(stripOf(Fr, TAXIWAY.u, TAXIWAY.v0 - 4, TAXIWAY.u, TAXIWAY.v1), TAXIWAY.half)
  for _, s in ipairs(STRIPS) do strip(stripOf(Fr, s[2], s[3], s[4], s[5]), s[6]) end
  for _, f in ipairs(FACILITIES) do
    local cu, cv, w, d = lotRect(f)
    w, d = w + 2, d + 2
    local nu = math.max(1, math.ceil(2 * w / step))
    local nv = math.max(1, math.ceil(2 * d / step))
    for i = 0, nu do
      for j = 0, nv do
        out[#out + 1] = dirAt(Fr, cu - w + 2 * w * i / nu, cv - d + 2 * d * j / nv)
      end
    end
  end
  return out
end

-- The paint discs along every paved strip (centre line, radius half + 2.5).
SUBBASE = { asphalt = { 0.24, 0.24, 0.25 }, concrete = { 0.50, 0.50, 0.48 } }
function paveDiscs(Fr, runway)
  local out = {}
  local function strip(S, half, col)
    local r = half + 2.5
    local rows = half > 10 and 3 or 1
    local n = math.max(1, math.ceil(S.L / (r * 0.9)))
    for i = 0, n do
      for j = 1, rows do
        local w = rows == 1 and 0 or (-half * 0.6 + half * 1.2 * (j - 1) / (rows - 1))
        out[#out + 1] = { d = stripDir(S, S.L * i / n, w), r = rows == 1 and r or r * 0.6, col = col }
      end
    end
  end
  if runway then strip(runway_strip(Fr), RUNWAY.half + RUNWAY.shoulder, SUBBASE.asphalt) end
  strip(stripOf(Fr, TAXIWAY.u, TAXIWAY.v0, TAXIWAY.u, TAXIWAY.v1), TAXIWAY.half, SUBBASE.asphalt)
  for _, st in ipairs(STRIPS) do
    strip(stripOf(Fr, st[2], st[3], st[4], st[5]), st[6], st[7] == "road" and SUBBASE.asphalt or SUBBASE.concrete)
  end
  return out
end

-- THE EDGES. Outside the graded reach the natural ground can sit metres
-- above or below the sphere (±2–5 m over a home plain's 180 m, more on an
-- old save's site); a hard edge there is a step with the paving's kerb
-- showing. A ring of softer half-strength flattens and smooths just outside
-- every strip and lot ramps the ground down (or up) to it.
function blendDiscs(Fr, runway)
  local out = {}
  local function strip(S, half)
    local w = half + GRADE.margin + GRADE.r * 0.55
    local ns = math.max(1, math.ceil(S.L / (GRADE.step * 1.4)))
    for i = 0, ns do
      local s = S.L * i / ns
      for _, sg in ipairs({ -1, 1 }) do out[#out + 1] = stripDir(S, s, w * sg) end
    end
    for _, s in ipairs({ -GRADE.r * 0.6, S.L + GRADE.r * 0.6 }) do out[#out + 1] = stripDir(S, s, 0) end
  end
  if runway then strip(runway_strip(Fr), RUNWAY.half + RUNWAY.shoulder) end
  strip(stripOf(Fr, TAXIWAY.u, TAXIWAY.v0 - 4, TAXIWAY.u, TAXIWAY.v1), TAXIWAY.half)
  for _, st in ipairs(STRIPS) do strip(stripOf(Fr, st[2], st[3], st[4], st[5]), st[6]) end
  for _, f in ipairs(FACILITIES) do
    local cu, cv, hu, hv = lotRect(f)
    local du, dv = hu + 9, hv + 9
    local n = 3
    for k = -n, n do
      local t = k / n
      out[#out + 1] = dirAt(Fr, cu + du * t, cv - dv)
      out[#out + 1] = dirAt(Fr, cu + du * t, cv + dv)
      out[#out + 1] = dirAt(Fr, cu - du, cv + dv * t)
      out[#out + 1] = dirAt(Fr, cu + du, cv + dv * t)
    end
  end
  return out
end

-- Is the graded ground still where it was left? A handful of points on the
-- sphere: the field's distance there is ~0 when the grade stands.
local function grade_holds(body, Fr, runway)
  local pts = { { 0, 0 }, { 0, -15 }, { 40, -8 }, { -50, -8 }, { 0, 60 }, { PAD.u, PAD.v - 20 }, { 40, 12 }, { -50, 12 } }
  if runway then
    for k = 0, 4 do pts[#pts + 1] = { RUNWAY.u0 + 10 + (RUNWAY.u1 - RUNWAY.u0 - 20) * k / 4, RUNWAY.v } end
  end
  for _, f in ipairs(FACILITIES) do pts[#pts + 1] = { f.u, f.v } end
  local worst = 0
  for _, p in ipairs(pts) do
    local d = dirAt(Fr, p[1], p[2])
    local q = terrain.query(body.x + d.x * Fr.R, body.y + d.y * Fr.R, body.z + d.z * Fr.R)
    if not q then return false, 1e9 end
    worst = math.max(worst, abs(q))
    -- and nothing hanging over it: rock above the grade is a roof
    for _, hh in ipairs({ 6.0, 11.0, 16.0, 22.0 }) do
      local qa = terrain.query(body.x + d.x * (Fr.R + hh), body.y + d.y * (Fr.R + hh), body.z + d.z * (Fr.R + hh))
      if qa and qa < 0.5 then worst = math.max(worst, hh) end
    end
  end
  return worst < 0.35, worst
end

-- Where the craft parked at the base are (body-relative), so a re-laid
-- layout's grade leaves their ground alone: the fleet's records (flight_ops)
-- and any vessel already standing. A disc whose reach covers one is skipped.
keep_off = nil
local KEEP_OFF_R = 6.0     -- a craft's own reach round its origin (m)
function parked_craft(body)
  local out = {}
  local function add_pt(x, y, z) if x and y and z then out[#out + 1] = V(x, y, z) end end
  for _, v in ipairs(findScripts and findScripts("vessel_controller") or {}) do
    local n = v.node
    if n and n.valid then add_pt(n.x - body.x, n.y - body.y, n.z - body.z) end
  end
  local fleet = save.get("fleet.craft")          -- flight_ops' records: x/y/z body-relative
  if type(fleet) == "table" then
    for _, rec in pairs(fleet) do
      if type(rec) == "table" and rec.body == body.name then add_pt(rec.x, rec.y, rec.z) end
    end
  end
  return out
end
local function kept_off(d, R, reach)
  if not keep_off then return false end
  for _, p in ipairs(keep_off) do
    local dx, dy, dz = d.x * R - p.x, d.y * R - p.y, d.z * R - p.z
    if dx * dx + dy * dy + dz * dz < (reach + KEEP_OFF_R) ^ 2 then return true end
  end
  return false
end

-- THE GRADE IS SENT IN ONE GO and the ENGINE paces it (0.117.0-rc7, cards
-- 0475/0480): script terrain edits queue, land in order a few milliseconds'
-- worth a frame (each whole), each resolved into its planet's frame the
-- moment it is made — so a carried-over op lands where it was aimed on a
-- planet that has moved on its rails — and an edit made while that ground is
-- still streaming in waits for it and lands on top. `terrain.pending()` says
-- how many are still to land: the grade is done when it reaches 0. (Solar
-- used to send GRADE.perFrame a frame and call the grade done once the last
-- was SENT; on rc7 that was ~800 ops still queued, the paving laid on the
-- ungraded ground, the check found it 0.9 m off and a second grade of ~800
-- ops ran in view.)
--
-- SENT AT THE ENGINE'S PACE, NOT ALL AT ONCE. The engine keeps at most 4,096
-- edits waiting and DROPS any more (once-only warning; floptle-script
-- terrain_api MAX_PENDING_OPS): a grade of more than that sent in one go lost
-- the rest, the check found the ground off and graded it all again. So the
-- list goes out as fast as the queue has room — `terrain.capacity()` since
-- rc16 (floptle/0516), GRADE.inflight at a time before — topped up as it
-- lands, and an op the engine refuses (receipt 0, paint's too) waits for the
-- next frame. And a queue that has
-- just gone empty is not trusted on one read: it must stay empty for
-- GRADE.settle frames (on rc10 `pending()` did not count the ops a worker was
-- still making), and a check that fails is read again a second later before
-- anything is regraded.
GRADE.inflight = 2048
GRADE.settle = 3
-- Behind the loading screen the engine may spend more of a frame landing
-- edits (`terrain.editBudget`, 0.117 rc11): nobody is looking at the frame.
GRADE.curtainBudget = 24.0
local grade_q = nil      -- { body = name, list = { {kind, x, y, z, r} ... }, i = next to send } until sent
local grade_landing = false   -- sent; the engine is still landing it
local landed_quiet = 0        -- frames the edit queue has read empty since the last op was sent
local check_now = false       -- a grade made at siting has landed: check it before the curtain goes
local check_at = nil          -- a failed check is read again at this time before regrading
local relooked = false        -- …once per grade
local budget_raised = false
local function edits_pending() return terrain.pending and terrain.pending() or 0 end
local function grade_busy() return grade_q ~= nil or grade_landing end
local function edit_budget(raise)
  if not terrain.editBudget or raise == budget_raised then return end
  budget_raised = raise
  terrain.editBudget(raise and GRADE.curtainBudget or nil)
end
-- Cut balls are listed top down (the dig of a ball near the surface must not
-- leave a hanging lid above it); each sits cutR over the next, its bottom
-- 1.5 m over the grade at the lowest.
local function grade(body, Fr, runway)
  if not terrain.sculpt then return 0 end
  local discs = gradeDiscs(Fr, runway)
  local blends = blendDiscs(Fr, runway)
  if keep_off and #keep_off > 0 then
    local function keep(ds, reach)
      local out = {}
      for _, d in ipairs(ds) do if not kept_off(d, Fr.R, reach) then out[#out + 1] = d end end
      return out
    end
    local n0 = #discs + #blends
    discs, blends = keep(discs, GRADE.r), keep(blends, GRADE.r * 1.25)
    log(string.format("base: %d grade discs left off the ground under parked craft", n0 - #discs - #blends))
  end
  local list = {}
  -- CUT AND FILL FIRST. A flatten only reshapes the ground within a few
  -- voxels of its plane: rock standing higher than that is left where it
  -- was, so a hill over the grade became a ROOF over the base (an old save's
  -- site on Goleth: a 5 m slab hanging over the apron), and a hollow deeper
  -- than that stays a hollow. So each disc is probed up its radial: where
  -- there is rock above the grade it is dug out in balls from the top down,
  -- and where there is air below it, it is filled; the flattens then finish
  -- the surface. On a flat plain the probes find nothing and add no ops.
  local b = space.body(body.name) or body
  local cuts, fills = 0, 0
  local probes = {}
  for _, d in ipairs(discs) do probes[#probes + 1] = d end
  for _, d in ipairs(blends) do probes[#probes + 1] = d end
  -- The field's distance is CLAMPED a few metres out (the 2.15 m voxels
  -- carry ±6 m), so "is there rock up here?" is asked at points 4 m apart
  -- with a 3 m reach, never from far away (asked at 10 m with an 8.5 m reach,
  -- clear air read as rock and a flat plain got 2,000 needless cuts).
  --
  -- OVERHANGS. The rock is looked for in COLUMNS, not just over each disc's
  -- centre: the centre and four points half a disc step off it diagonally
  -- (balls of cutR over centres GRADE.step apart left pillars between them,
  -- which the flattens then undercut into a hanging slab: the "22 m off" roof
  -- past the VAB's north door after the layout-3 upgrade). And each column
  -- is followed UP while it is still in rock — to GRADE.cutTop — so a hill
  -- taller than the old 36 m probe is cut from its top down, never left as
  -- a lid over the hollow cut under it.
  local seen = {}
  local function column(d)
    -- one column per 4 m cell (neighbouring discs share their corners)
    local k = string.format("%d:%d:%d", math.floor(d.x * Fr.R / 4 + 0.5), math.floor(d.y * Fr.R / 4 + 0.5),
      math.floor(d.z * Fr.R / 4 + 0.5))
    if seen[k] then return end
    seen[k] = true
    local want = {}
    local hc, last = GRADE.probeStep, nil
    while hc <= GRADE.cutTop and (hc <= GRADE.probeMin or (last and hc - last <= 12.0)) do
      work(1)
      b = space.body(body.name) or b
      local q = terrain.query(b.x + d.x * (Fr.R + hc), b.y + d.y * (Fr.R + hc), b.z + d.z * (Fr.R + hc))
      if q and q < 3.0 then
        last = hc
        -- the ball that takes this rock out, never reaching below the grade
        local c = math.max(hc, GRADE.cutR + 1.5)
        local key = math.floor(c / GRADE.cutR + 0.5)
        if not want[key] then want[key] = c end
      end
      hc = hc + GRADE.probeStep
    end
    local hs = {}
    for _, c in pairs(want) do hs[#hs + 1] = c end
    table.sort(hs, function(a, b2) return a > b2 end)       -- top down
    for _, c in ipairs(hs) do
      list[#list + 1] = { "lower", d.x * (Fr.R + c), d.y * (Fr.R + c), d.z * (Fr.R + c), GRADE.cutR, 1.0 }
      cuts = cuts + 1
    end
  end
  local off = GRADE.step * 0.5
  for _, d in ipairs(probes) do
    column(d)
    local ref = abs(d.y) < 0.9 and V(0, 1, 0) or V(1, 0, 0)
    local t1 = unit(cross(d, ref))
    local t2 = cross(d, t1)
    for _, sg in ipairs({ { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }) do
      column(unit(add(add(mul(d, Fr.R), t1, sg[1] * off), t2, sg[2] * off)))
    end
  end
  for _, d in ipairs(probes) do
    work(1)
    -- (the job yields across frames, and the planet moves ~4 m a tick: the
    -- centre is read again after every unit of work, as the columns do)
    b = space.body(body.name) or b
    local h = -3.0
    local q = terrain.query(b.x + d.x * (Fr.R + h), b.y + d.y * (Fr.R + h), b.z + d.z * (Fr.R + h))
    if q and q > 0.3 then
      list[#list + 1] = { "raise", d.x * (Fr.R - GRADE.fillR), d.y * (Fr.R - GRADE.fillR), d.z * (Fr.R - GRADE.fillR), GRADE.fillR, 1.0 }
      fills = fills + 1
    end
  end
  if cuts + fills > 0 then log(string.format("base: earthwork — %d cuts, %d fills before the grade", cuts, fills)) end
  for _ = 1, GRADE.passes do
    for _, d in ipairs(discs) do
      list[#list + 1] = { "flatten", d.x * Fr.R, d.y * Fr.R, d.z * Fr.R, GRADE.r, 1.0 }
    end
  end
  for _, d in ipairs(blends) do
    list[#list + 1] = { "flatten", d.x * Fr.R, d.y * Fr.R, d.z * Fr.R, GRADE.r * 1.25, 0.45 }
  end
  -- …and the ground under and beside the paving is painted as its sub-base
  -- (dark grey under asphalt, light grey under concrete), so wherever it
  -- meets the kerb it reads as a shoulder, not as meadow.
  if terrain.paint then
    for _, pd in ipairs(paveDiscs(Fr, runway)) do
      local d = pd.d
      list[#list + 1] = { "paint", d.x * Fr.R, d.y * Fr.R, d.z * Fr.R, pd.r, pd.col }
    end
  end
  grade_q = { body = body.name, list = list }
  local n = 0
  for _, e in ipairs(list) do if e[1] ~= "paint" then n = n + 1 end end
  local np = #list - n
  if np > 0 then log(string.format("base: %d paint ops lay the sub-base under the paving", np)) end
  return n
end

-- Send the grade at the engine's pace (GRADE.inflight waiting at most), then
-- wait for it to land and stay landed. True while work remains.
local function grade_step()
  local gm = ref("game_manager")
  edit_budget(gm ~= nil and gm.curtain == true)
  local q = grade_q
  if q then
    local b = space.body(q.body)
    if not b then return true end
    -- The engine says how much room its queue has (0.117 rc16, floptle/0516);
    -- an older one is kept GRADE.inflight deep, a guess under its cap.
    local room = terrain.capacity and terrain.capacity() or (GRADE.inflight - edits_pending())
    local i = q.i or 1
    while room > 0 and i <= #q.list do
      local e = q.list[i]
      local id
      if e[1] == "paint" then
        -- (a receipt since rc16; nothing before, which is not a refusal)
        id = terrain.paint(b.x + e[2], b.y + e[3], b.z + e[4], e[5], e[6][1], e[6][2], e[6][3], 1.0)
      else
        id = terrain.sculpt(b.x + e[2], b.y + e[3], b.z + e[4], e[5], e[6], e[1])
      end
      if id == 0 then break end            -- refused: the queue is full; again next frame
      i, room = i + 1, room - 1
    end
    q.i = i
    if i > #q.list then grade_q, grade_landing, landed_quiet = nil, true, 0 end
    return true
  end
  if grade_landing then
    if edits_pending() > 0 then landed_quiet = 0; return true end
    landed_quiet = landed_quiet + 1
    if landed_quiet < GRADE.settle then return true end
  end
  grade_landing = false
  relooked = false
  edit_budget(false)
  return false
end

-- ── the buildings ────────────────────────────────────────────────────────────

local function place_facility(f, body, Fr, planet_node)
  local up = dirAt(Fr, f.u, f.v)
  local fwd = face_at(Fr, up, f.face)
  local right = cross(up, fwd)                        -- the model's +X
  local g = mul(up, Fr.R)
  local o = add(add(add(g, up, f.seat + (f.lift or 0)), right, f.ox), fwd, f.oz)
  spawn(f.prefab, vec3(body.x + o.x, body.y + o.y, body.z + o.z), function(inst)
    -- +Y on the local up, +Z (the front) toward `fwd` (setUp's forward is the
    -- node's −Z). One whole-rotation write (engine 0403).
    inst:setUp(vec3(up.x, up.y, up.z), vec3(-fwd.x, -fwd.y, -fwd.z))
    -- Parent-local coords: for a facility parented to its planet, local IS
    -- the body-relative offset (never add the body position).
    inst.x, inst.y, inst.z = o.x, o.y, o.z
  end, planet_node)
  -- The VAB's interior shares the shell's origin and rotation (tools/gen_vab.py).
  if f.interior then
    spawn(f.interior, vec3(body.x + o.x, body.y + o.y, body.z + o.z), function(inst)
      inst:setUp(vec3(up.x, up.y, up.z), vec3(-fwd.x, -fwd.y, -fwd.z))
      inst.x, inst.y, inst.z = o.x, o.y, o.z
    end, planet_node)
  end
end

-- Two apron floodlights on masts (real spots, aimed at the apron).
local APRON_FLOODS = { { -23.0, -23.0 }, { 23.0, -23.0 } }
local function place_floods(body, Fr, planet_node)
  for _, p in ipairs(APRON_FLOODS) do
    local up = dirAt(Fr, p[1], p[2])
    local o = mul(up, Fr.R + 15.6)
    local tgt = mul(dirAt(Fr, 0, -8), Fr.R)
    spawn("BaseFlood", vec3(body.x + o.x, body.y + o.y, body.z + o.z), function(inst)
      inst.x, inst.y, inst.z = o.x, o.y, o.z
      local b2 = space.body(body.name) or body
      if inst.lookAt then
        inst:lookAt(vec3(b2.x + tgt.x, b2.y + tgt.y, b2.z + tgt.z), vec3(up.x, up.y, up.z))
      end
    end, planet_node)
  end
end

-- ── the built meshes: paving, light fittings, fixtures ───────────────────────

-- A mesh under construction: flat arrays for mesh.build.
local function newMesh()
  return { p = {}, n = {}, uv = {}, c = {}, i = {}, nv = 0 }
end
local function vert(M, p, n, u, v, col)
  local k = M.nv
  M.p[3 * k + 1], M.p[3 * k + 2], M.p[3 * k + 3] = p.x, p.y, p.z
  M.n[3 * k + 1], M.n[3 * k + 2], M.n[3 * k + 3] = n.x, n.y, n.z
  M.uv[2 * k + 1], M.uv[2 * k + 2] = u, v
  M.c[4 * k + 1], M.c[4 * k + 2], M.c[4 * k + 3], M.c[4 * k + 4] = col[1], col[2], col[3], 1.0
  M.nv = k + 1
  return k + 1
end
local function tri(M, a, b, c)
  local i = #M.i
  M.i[i + 1], M.i[i + 2], M.i[i + 3] = a, b, c
end
-- A quad a-b-c-d, wound counter-clockwise seen from the side `n` faces.
local function quad(M, a, b, c, d, n, col, uvs)
  uvs = uvs or { 0, 0, 1, 0, 1, 1, 0, 1 }
  local i1 = vert(M, a, n, uvs[1], uvs[2], col)
  local i2 = vert(M, b, n, uvs[3], uvs[4], col)
  local i3 = vert(M, c, n, uvs[5], uvs[6], col)
  local i4 = vert(M, d, n, uvs[7], uvs[8], col)
  -- Orient by the face normal the corners actually make.
  local fn = cross(add(b, a, -1), add(c, a, -1))
  if dot(fn, n) >= 0 then
    tri(M, i1, i2, i3); tri(M, i1, i3, i4)
  else
    tri(M, i1, i3, i2); tri(M, i1, i4, i3)
  end
end
-- An oriented box: centre c, axes ax/ay/az (unit), half sizes hx/hy/hz.
local function obox(M, c, ax, ay, az, hx, hy, hz, col, bottom)
  work(1)
  local function P(sx, sy, sz)
    return add(add(add(c, ax, sx * hx), ay, sy * hy), az, sz * hz)
  end
  quad(M, P(-1, 1, -1), P(1, 1, -1), P(1, 1, 1), P(-1, 1, 1), ay, col)
  quad(M, P(1, -1, -1), P(1, 1, -1), P(1, 1, 1), P(1, -1, 1), ax, col)
  quad(M, P(-1, -1, -1), P(-1, 1, -1), P(-1, 1, 1), P(-1, -1, 1), mul(ax, -1), col)
  quad(M, P(-1, -1, 1), P(1, -1, 1), P(1, 1, 1), P(-1, 1, 1), az, col)
  quad(M, P(-1, -1, -1), P(1, -1, -1), P(1, 1, -1), P(-1, 1, -1), mul(az, -1), col)
  if bottom then quad(M, P(-1, -1, -1), P(1, -1, -1), P(1, -1, 1), P(-1, -1, 1), mul(ay, -1), col) end
end
-- A post standing on the sphere at direction d: base at R + h0, height ht.
local function post(M, O, d, R, h0, ht, half, col, tang)
  tang = tang or unit(cross(d, V(0.3, 0.9, 0.2)))
  local bi = cross(d, tang)
  local c = add(mul(d, R + h0 + ht / 2), O, -1)
  obox(M, c, tang, d, bi, half, ht / 2, half, col)
end
-- A bar between two points (body-relative), square section `half`.
local function bar(M, O, p, q, half, col, upish)
  local ax = add(q, p, -1)
  local L = len(ax)
  if L < 1e-6 then return end
  ax = mul(ax, 1 / L)
  local u = upish or V(0, 1, 0)
  local s = cross(ax, u)
  if len(s) < 1e-3 then s = cross(ax, V(1, 0, 0)) end
  s = unit(s)
  local t = cross(s, ax)
  local c = add(mul(add(p, q), 0.5), O, -1)
  obox(M, c, ax, t, s, L / 2, half, half, col)
end

-- Paint (linear, multiplied into the texture).
local COL = {
  asphalt = { 0.36, 0.36, 0.37 }, rubber = { 0.22, 0.22, 0.22 }, rubber2 = { 0.27, 0.27, 0.27 }, shoulder = { 0.55, 0.54, 0.52 }, blast = { 0.40, 0.40, 0.40 },
  white = { 1.0, 1.0, 1.0 }, yellow = { 1.0, 0.74, 0.10 }, concrete = { 1.0, 0.99, 0.96 },
  crawl = { 0.78, 0.77, 0.74 }, track = { 0.58, 0.56, 0.52 }, kerb = { 0.70, 0.70, 0.68 },
  edge = { 0.30, 0.30, 0.30 },
}

-- 5 × 7 digits for the runway's numbers (the same font as tools/gen_base.py).
local DIGITS = {
  ["0"] = { "01110", "10001", "10011", "10101", "11001", "10001", "01110" },
  ["1"] = { "00100", "01100", "00100", "00100", "00100", "00100", "01110" },
  ["2"] = { "01110", "10001", "00001", "00010", "00100", "01000", "11111" },
  ["3"] = { "11110", "00001", "00001", "01110", "00001", "00001", "11110" },
  ["4"] = { "00010", "00110", "01010", "10010", "11111", "00010", "00010" },
  ["5"] = { "11111", "10000", "11110", "00001", "00001", "10001", "01110" },
  ["6"] = { "00110", "01000", "10000", "11110", "10001", "10001", "01110" },
  ["7"] = { "11111", "00001", "00010", "00100", "01000", "01000", "01000" },
  ["8"] = { "01110", "10001", "10001", "01110", "10001", "10001", "01110" },
  ["9"] = { "01110", "10001", "10001", "01111", "00001", "00010", "01100" },
}

-- THE SIGN ATLAS (textures/base/signs.png, tools/base_tex.py): u0, v0, u1, v1
-- of each tile. Written by tools/gen_base.py between the markers — do not edit.
-- SIGN_UV begin
SIGN_UV = {
  ["blast"] = { 0.43994, 0.73991, 0.88818, 0.79785 },
  ["g_-"] = { 0.68799, 0.91569, 0.74951, 0.95671 },
  ["g_0"] = { 0.00439, 0.91569, 0.06592, 0.95671 },
  ["g_1"] = { 0.07275, 0.91569, 0.13428, 0.95671 },
  ["g_2"] = { 0.14111, 0.91569, 0.20264, 0.95671 },
  ["g_3"] = { 0.20947, 0.91569, 0.27100, 0.95671 },
  ["g_4"] = { 0.27783, 0.91569, 0.33936, 0.95671 },
  ["g_5"] = { 0.34619, 0.91569, 0.40771, 0.95671 },
  ["g_6"] = { 0.41455, 0.91569, 0.47607, 0.95671 },
  ["g_7"] = { 0.48291, 0.91569, 0.54443, 0.95671 },
  ["g_8"] = { 0.55127, 0.91569, 0.61279, 0.95671 },
  ["g_9"] = { 0.61963, 0.91569, 0.68115, 0.95671 },
  ["g_A_dir"] = { 0.82471, 0.91569, 0.88623, 0.95671 },
  ["g_A_loc"] = { 0.75635, 0.91569, 0.81787, 0.95671 },
  ["hazard"] = { 0.00439, 0.96126, 0.25342, 0.99186 },
  blast_aspect = 0.1939,
}
-- SIGN_UV end

-- One atlas tile as a quad centred on c, `right` along its width, `up` its
-- height, facing −n (toward the reader) — 2 cm proud along −n.
function sign_quad(M, c, right, up, n, w, h, key)
  local r = SIGN_UV[key]
  if not r then return end
  local f = mul(n, -1)
  local cc = add(c, f, 0.02)
  local p1 = add(add(cc, right, -w / 2), up, h / 2)
  local p2 = add(add(cc, right, w / 2), up, h / 2)
  local p3 = add(add(cc, right, w / 2), up, -h / 2)
  local p4 = add(add(cc, right, -w / 2), up, -h / 2)
  quad(M, p1, p2, p3, p4, f, { 1, 1, 1 }, { r[1], r[2], r[3], r[2], r[3], r[4], r[1], r[4] })
end

-- A row of glyph tiles, left to right along `right` (reader's right is −side).
function glyphs(M, c, side, up, n, gw, gh, list)
  for k, ch in ipairs(list) do
    sign_quad(M, add(c, side, -(k - 1) * gw), mul(side, -1), up, n, gw, gh, "g_" .. ch)
  end
end

-- The runway's designators: the magnetic-style bearing of each direction of
-- travel, in tens of degrees. The one painted at the WEST (s = 0) end is the
-- one you take off on rolling +s.
function runwayNumbers(Fr)
  local S = runway_strip(Fr)
  local mid = stripDir(S, S.L / 2, 0)
  local t = stripTan(S, S.L / 2)
  local north = add(V(0, 1, 0), mid, -mid.y)
  if len(north) < 1e-3 then return "09", "27" end
  north = unit(north)
  local east = cross(north, mid)
  local brg = math.deg(atan2(dot(t, east), dot(t, north))) % 360
  local function num(b)
    local n = math.floor(b / 10 + 0.5) % 36
    if n == 0 then n = 36 end
    return string.format("%02d", n)
  end
  return num(brg), num((brg + 180) % 360)
end

-- The runway's paint at (s, w): s from the west end (0 … 262), w across (+v).
local NUM_PX_S, NUM_PX_W, NUM_S0 = 1.4, 0.9, 34.0
local function digit_on(str, s, w)
  -- Read rolling +s: letter tops toward +s, the reader's right toward −w.
  local x = 4.95 - w                      -- 0 … 9.9 across, left to right
  local row = math.floor((NUM_S0 + 7 * NUM_PX_S - s) / NUM_PX_S)
  if row < 0 or row > 6 or x < 0 or x >= 9.9 then return false end
  local col = math.floor(x / NUM_PX_W)
  local k = col < 5 and 1 or (col > 5 and 2 or nil)
  if not k then return false end
  local c = (k == 1) and col or (col - 6)
  local g = DIGITS[str:sub(k, k)]
  return g and g[row + 1]:sub(c + 1, c + 1) == "1"
end

local function runway_paint(L, n1, n2)
  local B, HALF = RUNWAY.blast, RUNWAY.half
  local DASH0, DASH, GAP = 46.0, 12.0, 8.0
  return function(s, w)
    local aw = abs(w)
    if aw > HALF then
      -- shoulders; where the taxiway leaves (north, at its u), it is taxiway
      local ds = abs(s - (TAXIWAY.u - RUNWAY.u0))
      if w > 0 and ds < TAXIWAY.half then
        if ds <= 0.15 or ds >= TAXIWAY.half - 0.3 then return COL.yellow end
        return COL.asphalt
      end
      return COL.shoulder
    end
    -- the far end reads as the near end turned round
    local near = s <= L / 2
    local ss, ww, num = s, w, n1
    if not near then ss, ww, num = L - s, -w, n2 end
    if ss < B then
      -- blast pad: yellow chevrons pointing at the runway
      if ((ss + aw * 0.8) % 5.0) < 1.6 then return COL.yellow end
      return COL.blast
    end
    if aw >= HALF - 0.9 then return COL.white end                 -- edge stripes
    if ss >= B + 1 and ss < B + 2 then return COL.white end       -- threshold line
    if ss >= B + 3 and ss < B + 21 then                            -- threshold bars
      for _, c in ipairs({ 1.5, 3.3, 5.1, 6.9 }) do
        if aw >= c - 0.6 and aw < c + 0.6 then return COL.white end
      end
      return COL.asphalt
    end
    if digit_on(num, ss, ww) then return COL.white end
    if ss >= 72 and ss < 88 and aw >= 3.4 and aw < 5.6 then return COL.white end   -- aiming point
    -- tyre rubber laid down where wheels touch down and roll out
    if ss >= 60 and ss < 150 and aw < 4.2 then
      local k = math.floor(ss / 4) * 7 + math.floor((ww + 9) / 1.0) * 3
      if aw <= 0.45 and s >= DASH0 and s <= L - DASH0 and ((s - DASH0) % (DASH + GAP)) < DASH then
        return COL.white
      end
      return (k % 5 < 2) and COL.rubber2 or COL.rubber
    end
    if aw <= 0.45 and s >= DASH0 and s <= L - DASH0 then           -- centreline
      if ((s - DASH0) % (DASH + GAP)) < DASH then return COL.white end
    end
    return COL.asphalt
  end
end

local function strip_paint(kind, L, half)
  if kind == "taxi" then
    return function(s, w)
      if abs(w) <= 0.15 then return COL.yellow end
      if abs(w) >= half - 0.3 then return COL.yellow end
      return COL.asphalt
    end
  elseif kind == "apron" then
    return function(s, w)
      -- the lead-in line from the taxiway to the VAB door, and a stop bar
      if abs(w) <= 0.15 and s < L - 4 then return COL.yellow end
      if s >= L - 5.5 and s < L - 5.0 and abs(w) < 5 then return COL.yellow end
      if abs(w) >= half - 0.25 then return COL.yellow end
      return COL.concrete
    end
  elseif kind == "crawler" then
    return function(s, w)
      if abs(abs(w) - 4.0) < 1.6 then return COL.track end
      if abs(w) >= half - 0.3 then return COL.kerb end
      return COL.crawl
    end
  elseif kind == "road" then
    return function(s, w)
      if abs(w) <= 0.08 and (s % 6.0) < 3.0 then return COL.white end
      if abs(w) >= half - 0.25 then return COL.white end
      return COL.asphalt
    end
  elseif kind == "yard" then
    return function(s, w)
      if abs(w) >= half - 0.25 then return COL.yellow end
      return COL.concrete
    end
  end
  return function() return COL.concrete end
end

-- Breakpoints: a regular grid plus every edge the paint has, so each cell is
-- one colour and no flat quad is long enough to sag below the sphere (a 4 m
-- chord sits 3 mm under a 600 m sphere).
local function breaks(a, b, step, extra)
  local t, seen = {}, {}
  local function put(x)
    if x >= a - 1e-6 and x <= b + 1e-6 then
      local k = math.floor(x * 1000 + 0.5)
      if not seen[k] then seen[k] = true; t[#t + 1] = x end
    end
  end
  local n = math.max(1, math.ceil((b - a) / step))
  for i = 0, n do put(a + (b - a) * i / n) end
  for _, x in ipairs(extra or {}) do put(x) end
  table.sort(t)
  return t
end

-- Lay a strip: cells between the breakpoints, one colour each, runs of the
-- same colour merged across (up to `maxw`), a kerb skirt down the sides and
-- ends so no lip shows against the ground.
-- THE PAVING SITS ON THE GROUND AS GRADED, not on the ideal sphere. The
-- grade lands within ~±0.2 m of the sphere, and where it stood higher than
-- the paving's 0.14 m the ground's own texture came up through the aprons and
-- roads in ragged patches, plain from the air. So every paving vertex asks
-- the field where the ground really is there (a short march down the
-- radial from 1 m over the grade) and stands PAVE_H over THAT; the kerb
-- skirts hang 1.2 m from it. `pave_body` is the body the meshes are built for.
local pave_body = nil
local function ground_off(d, R)
  local b = pave_body and space.body(pave_body)
  if not (b and terrain.query) then return 0 end
  local r = R + 1.0
  for _ = 1, 8 do
    work(1)
    b = space.body(pave_body) or b
    local q = terrain.query(b.x + d.x * r, b.y + d.y * r, b.z + d.z * r)
    if not q then return 0 end
    if abs(q) < 0.01 then break end
    r = r - q
  end
  return clamp(r - R, -0.5, 0.8)
end

local function lay_strip(M, O, S, sb, wb, paint, h, tile, maxw, ends)
  local R = S.R
  local gcache = {}
  local function P(s, w, hh)
    local d = stripDir(S, s, w)
    local key = string.format("%.3f:%.3f", s, w)
    local g = gcache[key]
    if not g then
      g = ground_off(d, R)
      gcache[key] = g
    end
    return add(mul(d, R + g + hh), O, -1)
  end
  for i = 1, #sb - 1 do
    work(math.max(1, math.floor(#wb / 3)))
    local s0, s1 = sb[i], sb[i + 1]
    local sm = (s0 + s1) / 2
    local cols = {}
    for j = 1, #wb - 1 do cols[j] = paint(sm, (wb[j] + wb[j + 1]) / 2) end
    local j = 1
    while j < #wb do
      local col = cols[j]
      local k = j
      while k + 1 < #wb and cols[k + 1] == col and wb[k + 2] - wb[j] <= maxw do k = k + 1 end
      local w0, w1 = wb[j], wb[k + 1]
      if col then
        local up = stripDir(S, sm, (w0 + w1) / 2)
        quad(M, P(s0, w0, h), P(s1, w0, h), P(s1, w1, h), P(s0, w1, h), up, col,
          { s0 / tile, w0 / tile, s1 / tile, w0 / tile, s1 / tile, w1 / tile, s0 / tile, w1 / tile })
      end
      j = k + 1
    end
    -- side skirts
    for _, w in ipairs({ wb[1], wb[#wb] }) do
      local out = w < 0 and mul(S.n, -1) or S.n
      quad(M, P(s0, w, h), P(s1, w, h), P(s1, w, h - 1.2), P(s0, w, h - 1.2), out, COL.edge)
    end
  end
  if ends ~= false then
    for _, s in ipairs({ sb[1], sb[#sb] }) do
      local t = stripTan(S, s)
      if s <= sb[1] then t = mul(t, -1) end
      quad(M, P(s, wb[1], h), P(s, wb[#wb], h), P(s, wb[#wb], h - 1.2), P(s, wb[1], h - 1.2), t, COL.edge)
    end
  end
end

-- A light fitting: a small dark base in the fixtures mesh, its lens in the
-- lamps mesh.
-- A cylinder (n-gon prism) from base point b along unit axis `ax`, height h,
-- radius r; sides and a top cap (lens UVs 0..1 across each face).
local function cyl(M, O, b, ax, r, h, col, sides)
  sides = sides or 10
  work(1)
  local t = unit(cross(ax, V(0.3, 0.9, 0.2)))
  local u = cross(ax, t)
  local b0 = add(b, O, -1)
  local top = add(b0, ax, h)
  local ring0, ring1 = {}, {}
  for k = 0, sides - 1 do
    local a = k / sides * 2 * math.pi
    local off = add(mul(t, math.cos(a) * r), u, math.sin(a) * r)
    ring0[k] = add(b0, off)
    ring1[k] = add(top, off)
  end
  for k = 0, sides - 1 do
    local k2 = (k + 1) % sides
    local mid = unit(add(add(ring0[k], b0, -1), add(ring0[k2], b0, -1)))
    quad(M, ring0[k], ring0[k2], ring1[k2], ring1[k], mid, col, { k / sides, 1, (k + 1) / sides, 1, (k + 1) / sides, 0, k / sides, 0 })
  end
  local ci = vert(M, top, ax, 0.5, 0.5, col)
  for k = 0, sides - 1 do
    local k2 = (k + 1) % sides
    local a1, a2 = k / sides * 2 * math.pi, k2 / sides * 2 * math.pi
    local i1 = vert(M, ring1[k], ax, 0.5 + 0.5 * math.cos(a1), 0.5 + 0.5 * math.sin(a1), col)
    local i2 = vert(M, ring1[k2], ax, 0.5 + 0.5 * math.cos(a2), 0.5 + 0.5 * math.sin(a2), col)
    local fn = cross(add(ring1[k], top, -1), add(ring1[k2], top, -1))
    if dot(fn, ax) >= 0 then tri(M, ci, i1, i2) else tri(M, ci, i2, i1) end
  end
end

-- An elevated airfield light as they are made: a frangible stem, a cast
-- housing, and a short glass lens on top — the lens alone glows.
local function fitting(X, Lm, O, d, R, col, size)
  size = size or 0.07
  cyl(X, O, mul(d, R + PAVE_H - 0.05), d, 0.022, 0.24, { 0.32, 0.32, 0.30 }, 6)
  cyl(X, O, mul(d, R + PAVE_H + 0.19), d, size * 1.15, 0.07, { 0.16, 0.16, 0.17 }, 10)
  cyl(Lm, O, mul(d, R + PAVE_H + 0.26), d, size, size * 1.1, col, 10)
end

local LIGHT = {
  edge = { 1.0, 0.95, 0.80 }, green = { 0.2, 1.0, 0.35 }, red = { 1.0, 0.12, 0.08 },
  blue = { 0.25, 0.45, 1.0 }, warm = { 1.0, 0.82, 0.55 }, papiW = { 1.0, 1.0, 0.95 },
  papiR = { 1.0, 0.15, 0.1 }, amber = { 1.0, 0.6, 0.1 },
}

-- Build the three meshes. O is the mesh nodes' origin (body-relative: C on R).
local function build_meshes(Fr, runway)
  local R = Fr.R
  local O = mul(Fr.c, R)
  local A, C, X, Lm, G = newMesh(), newMesh(), newMesh(), newMesh(), newMesh()   -- asphalt, concrete, fixtures, lamps, signs
  local stats = {}

  -- THE RUNWAY
  if runway then
    local S = runway_strip(Fr)
    local L = S.L
    local n1, n2 = runwayNumbers(Fr)
    local HALF, SH, B = RUNWAY.half, RUNWAY.shoulder, RUNWAY.blast
    local sx = { B, B + 1, B + 2, B + 3, B + 21, 72, 88, L - 72, L - 88, L - B, L - B - 1, L - B - 2, L - B - 3, L - B - 21 }
    for k = 0, 7 do
      sx[#sx + 1] = NUM_S0 + k * NUM_PX_S
      sx[#sx + 1] = L - NUM_S0 - k * NUM_PX_S
    end
    for s = 0, B, 1.0 do sx[#sx + 1] = s; sx[#sx + 1] = L - s end
    local DASH0 = 46.0
    local s = DASH0
    while s <= L - DASH0 do sx[#sx + 1] = s; sx[#sx + 1] = s + 12.0; s = s + 20.0 end
    local wx = { -HALF - SH, -HALF, HALF, HALF + SH, -(HALF - 0.9), HALF - 0.9, -0.45, 0.45 }
    for _, c in ipairs({ 1.5, 3.3, 5.1, 6.9 }) do
      wx[#wx + 1] = c - 0.6; wx[#wx + 1] = c + 0.6; wx[#wx + 1] = -c - 0.6; wx[#wx + 1] = -c + 0.6
    end
    for k = 0, 11 do wx[#wx + 1] = -4.95 + k * NUM_PX_W end
    for _, c in ipairs({ 3.4, 5.6 }) do wx[#wx + 1] = c; wx[#wx + 1] = -c end
    for w = -HALF, HALF, 1.0 do wx[#wx + 1] = w end
    local st = TAXIWAY.u - RUNWAY.u0
    for _, ds in ipairs({ -TAXIWAY.half, -TAXIWAY.half + 0.3, -0.15, 0.15, TAXIWAY.half - 0.3, TAXIWAY.half }) do
      sx[#sx + 1] = st + ds
    end
    local sb = breaks(0, L, 4.0, sx)
    local wb = breaks(-HALF - SH, HALF + SH, 6.0, wx)
    lay_strip(A, O, S, sb, wb, runway_paint(L, n1, n2), PAVE_H, 8.0, 6.0)
    stats.runway = L
    stats.numbers = n1 .. "/" .. n2
    -- edge lights every 15 m on the shoulders, threshold bars green outside /
    -- red inside at both ends, and the PAPI boxes on the left of each approach
    local ne = math.floor((L - 2 * B) / 15)
    for k = 0, ne do
      local ss = B + (L - 2 * B) * k / ne
      for _, w in ipairs({ HALF + 0.7, -HALF - 0.7 }) do
        fitting(X, Lm, O, stripDir(S, ss, w), R, LIGHT.edge)
      end
    end
    for _, e in ipairs({ { B - 0.6, B + 0.4 }, { L - B + 0.6, L - B - 0.4 } }) do
      for k = -4, 4 do
        local w = k * 2.2
        fitting(X, Lm, O, stripDir(S, e[1], w), R, LIGHT.green, 0.08)
        fitting(X, Lm, O, stripDir(S, e[2], w), R, LIGHT.red, 0.08)
      end
    end
    for _, p in ipairs({ { 80, HALF + 10 }, { L - 80, -HALF - 10 } }) do
      for k = 0, 3 do
        local w = p[2] + (p[2] > 0 and 1 or -1) * k * 2.4
        local d = stripDir(S, p[1], w)
        post(X, O, d, R, 0.0, 0.7, 0.35, { 0.25, 0.26, 0.28 })
        local t = stripTan(S, p[1])
        local c = add(mul(d, R + 0.95), O, -1)
        obox(Lm, c, cross(t, d), d, t, 0.45, 0.22, 0.05, k < 2 and LIGHT.papiW or LIGHT.papiR)
      end
    end
    -- the windsock, midfield north of the runway
    do
      local d = stripDir(S, L / 2 + 40, HALF + 16)
      post(X, O, d, R, 0.0, 6.5, 0.08, { 0.85, 0.85, 0.85 })
      local t = stripTan(S, L / 2 + 40)
      local top = mul(d, R + 6.2)
      for k = 0, 4 do
        local a = add(top, t, k * 0.6)
        local b2 = add(add(top, t, (k + 1) * 0.6), d, -0.18)
        bar(X, O, a, b2, 0.32 - k * 0.04, k % 2 == 0 and { 1.0, 0.35, 0.05 } or { 0.95, 0.95, 0.95 }, d)
      end
      fitting(X, Lm, O, d, R + 6.3, LIGHT.red, 0.12)
    end
    -- the hold sign at the taxiway: runway designators, white on red
    do
      local Tx = stripOf(Fr, TAXIWAY.u, TAXIWAY.v0, TAXIWAY.u, TAXIWAY.v1)
      local d = stripDir(Tx, 3.0, TAXIWAY.half + 3.0)
      local t = stripTan(Tx, 3.0)
      for _, w in ipairs({ -1.2, 1.2 }) do
        post(X, O, stripDir(Tx, 3.0, TAXIWAY.half + 3.0 + w), R, 0.0, 1.0, 0.06, { 0.3, 0.3, 0.3 })
      end
      local side = cross(d, t)
      local c = add(mul(d, R + 1.5), O, -1)
      -- A location sign (black, yellow "A") beside the mandatory hold sign
      -- (red, the runway's designators in white), each glyph a tile of the
      -- sign atlas laid 2 cm proud of its steel board.
      local str = n1 .. "-" .. n2
      local gw, gh = 0.42, 0.48
      local wsign = #str * gw + gw * 1.3
      obox(X, add(c, side, gw * 0.65), side, d, t, wsign / 2 + 0.06, gh / 2 + 0.06, 0.08, { 0.22, 0.22, 0.23 }, true)
      local face = add(c, t, -0.10)
      local x0 = -wsign / 2 + gw * 0.65
      glyphs(G, add(face, side, x0 + gw * 0.5), side, d, t, gw, gh, { "A_loc" })
      local list = {}
      for k = 1, #str do list[k] = str:sub(k, k) end
      glyphs(G, add(face, side, x0 + gw * 1.3 + gw * 0.5), side, d, t, gw, gh, list)
    end
    -- the launch hazard warning where the crawlerway leaves the compound
    do
      local Sc = stripOf(Fr, 0.0, 31.4, 0.0, 96.0)
      local s0 = 62.0 - 31.4
      local d = stripDir(Sc, s0, -9.6)
      local t = stripTan(Sc, s0)
      for _, w in ipairs({ -9.0, -10.2 }) do
        post(X, O, stripDir(Sc, s0, w), R, 0.0, 1.9, 0.05, { 0.3, 0.3, 0.3 })
      end
      local side = cross(d, t)
      local c = add(mul(d, R + 1.75), O, -1)
      local sw, shh = 2.2, 2.2 * SIGN_UV.blast_aspect
      obox(X, c, side, d, t, sw / 2 + 0.05, shh / 2 + 0.05, 0.03, { 0.25, 0.25, 0.26 }, true)
      sign_quad(G, add(c, t, 0.05), mul(side, -1), d, t, sw, shh, "blast")
    end
  end

  -- THE TAXIWAY (asphalt, a yellow centreline and edges, blue edge lights)
  do
    -- (it starts 0.6 m inside the runway's shoulder and 2 cm above it, so the
    -- junction is one surface with no strip of ground showing between)
    local Tx = stripOf(Fr, TAXIWAY.u, TAXIWAY.v0 - 0.6, TAXIWAY.u, TAXIWAY.v1)
    local half = TAXIWAY.half
    local sb = breaks(0, Tx.L, 4.0)
    local wb = breaks(-half, half, 6.0, { -0.15, 0.15, -half + 0.3, half - 0.3 })
    lay_strip(A, O, Tx, sb, wb, strip_paint("taxi", Tx.L, half), PAVE_H + 0.02, 8.0, 6.0)
    for s = 3.0, Tx.L - 1, 7.0 do
      for _, w in ipairs({ half + 0.6, -half - 0.6 }) do
        fitting(X, Lm, O, stripDir(Tx, s, w), R, LIGHT.blue, 0.06)
      end
    end
  end

  -- APRON, CRAWLERWAY, ROADS, YARDS
  for _, st in ipairs(STRIPS) do
    local S = stripOf(Fr, st[2], st[3], st[4], st[5])
    local half, kind = st[6], st[7]
    local extra = { -half + 0.3, half - 0.3, -half + 0.25, half - 0.25, -0.15, 0.15, -0.08, 0.08 }
    for _, c in ipairs({ 2.4, 5.6 }) do extra[#extra + 1] = c; extra[#extra + 1] = -c end
    local sbx = { S.L - 5.5, S.L - 5.0, S.L - 4 }
    if kind == "road" then for s = 0, S.L, 3.0 do sbx[#sbx + 1] = s end end
    local sb = breaks(0, S.L, 4.0, sbx)
    local wb = breaks(-half, half, 6.0, extra)
    local M = (kind == "road") and A or C
    local h = PAVE_H + ((kind == "apron" or kind == "crawler") and 0.02 or 0.0)
    lay_strip(M, O, S, sb, wb, strip_paint(kind, S.L, half), h, kind == "road" and 8.0 or 4.0, 6.0)
    -- street lamps down the roads and the crawlerway
    if kind == "road" or kind == "crawler" then
      local gap = kind == "road" and 18.0 or 16.0
      local side = kind == "road" and (half + 1.2) or (half + 1.5)
      for s = gap / 2, S.L - 2, gap do
        for _, w in ipairs(kind == "crawler" and { side, -side } or { side }) do
          local d = stripDir(S, s, w)
          post(X, O, d, R, 0.0, 7.0, 0.09, { 0.42, 0.44, 0.46 })
          local inward = mul(S.n, w > 0 and -1 or 1)
          local top = mul(d, R + 7.0)
          local tip = add(top, inward, 1.4)
          bar(X, O, top, tip, 0.05, { 0.42, 0.44, 0.46 }, d)
          local c = add(add(tip, d, -0.1), O, -1)
          local t = stripTan(S, s)
          obox(X, c, inward, d, t, 0.35, 0.08, 0.18, { 0.2, 0.2, 0.22 })
          obox(Lm, add(c, d, -0.09), inward, d, t, 0.30, 0.02, 0.14, LIGHT.warm)
        end
      end
    end
  end

  -- APRON FLOOD MASTS (the lights themselves are BaseFlood prefabs)
  for _, p in ipairs(APRON_FLOODS) do
    local d = dirAt(Fr, p[1], p[2])
    post(X, O, d, R, 0.0, 15.2, 0.16, { 0.50, 0.52, 0.54 })
    local tgt = unit(add(dirAt(Fr, 0, -8), d, -1))
    local t = unit(add(tgt, d, -dot(tgt, d)))
    local c = add(add(mul(d, R + 15.6), t, 0.3), O, -1)
    obox(X, c, cross(d, t), d, t, 1.1, 0.35, 0.2, { 0.2, 0.2, 0.22 })
    obox(Lm, add(c, t, 0.21), cross(d, t), d, t, 0.95, 0.28, 0.01, LIGHT.warm)
  end

  -- THE FENCE round the compound: posts every 3 m, three strands, gates.
  do
    local f = FENCE
    local sides = {
      { "S", f.u0, f.v0, f.u1, f.v0 }, { "E", f.u1, f.v0, f.u1, f.v1 },
      { "N", f.u1, f.v1, f.u0, f.v1 }, { "W", f.u0, f.v1, f.u0, f.v0 },
    }
    local POST = { 0.40, 0.42, 0.44 }
    local WIRE = { 0.30, 0.31, 0.33 }
    local nposts = 0
    for _, sd in ipairs(sides) do
      local du, dv = sd[4] - sd[2], sd[5] - sd[3]
      local Ls = sqrt(du * du + dv * dv)
      local n = math.max(1, math.floor(Ls / 3.0 + 0.5))
      local prev = nil
      for k = 0, n do
        local u = sd[2] + du * k / n
        local v = sd[3] + dv * k / n
        local along = (sd[1] == "S" or sd[1] == "N") and u or v
        local gap = false
        for _, g in ipairs(f.gates) do
          if g.side == sd[1] and along > g.a and along < g.b then gap = true end
        end
        if gap then
          prev = nil
        else
          local d = dirAt(Fr, u, v)
          post(X, O, d, R, -0.2, 2.6, 0.04, POST)
          nposts = nposts + 1
          if prev then
            for _, hh in ipairs({ 0.5, 1.4, 2.25 }) do
              bar(X, O, mul(prev, R + hh), mul(d, R + hh), 0.012, WIRE, d)
            end
          end
          prev = d
        end
      end
    end
    stats.fencePosts = nposts
  end

  stats.verts = { asphalt = A.nv, concrete = C.nv, fixtures = X.nv, lamps = Lm.nv, signs = G.nv }
  return { asphalt = A, concrete = C, fixtures = X, lamps = Lm, signs = G, origin = O, stats = stats }
end

-- Hand the meshes to the engine: one node each, parented to the planet at C.
local MATS = {
  asphalt = { texture = "textures/base/asphalt_albedo.png", normalMap = "textures/base/asphalt_normal.png",
              roughnessMap = "textures/base/asphalt_orm.png", occlusionMap = "textures/base/asphalt_orm.png",
              color = { 1, 1, 1 }, roughness = 1.0, metallic = 0.0, shading = "physical" },
  concrete = { texture = "textures/base/concrete_albedo.png", normalMap = "textures/base/concrete_normal.png",
               roughnessMap = "textures/base/concrete_orm.png", occlusionMap = "textures/base/concrete_orm.png",
               color = { 1, 1, 1 }, roughness = 1.0, metallic = 0.0, shading = "physical" },
  fixtures = { texture = "textures/base/steel_albedo.png", normalMap = "textures/base/steel_normal.png",
               roughnessMap = "textures/base/steel_orm.png", metallicMap = "textures/base/steel_orm.png",
               color = { 1, 1, 1 }, roughness = 1.0, metallic = 1.0, shading = "physical" },
  lamps = { texture = "textures/base/lens.png", color = { 1, 1, 1 }, unlit = true, fog = false },
  signs = { texture = "textures/base/signs.png", color = { 1, 1, 1 }, roughness = 0.62, metallic = 0.05, shading = "physical" },
}
local NAMES = { asphalt = "Base Asphalt", concrete = "Base Concrete", fixtures = "Base Fixtures", lamps = "Base Lamps",
                signs = "Base Signs" }

local function show_meshes(B, planet_node)
  built = { nodes = {}, meshes = {} }
  if not (mesh and mesh.build and createNode) then return end
  for _, k in ipairs({ "asphalt", "concrete", "fixtures", "lamps", "signs" }) do
    local M = B[k]
    if M.nv > 0 then
      local name = mesh.build{ positions = M.p, indices = M.i, normals = M.n, uvs = M.uv, colors = M.c }
      built.meshes[#built.meshes + 1] = name
      createNode(NAMES[k], planet_node, function(n)
        n.x, n.y, n.z = B.origin.x, B.origin.y, B.origin.z
        n.model = name
        n:setMaterial(MATS[k])
        if k ~= "fixtures" then n.castShadow = false end
        built.nodes[#built.nodes + 1] = n
      end)
    end
  end
end

-- Build (or rebuild) the paving, fittings and signs.
function lay_paving(Fr, runway, planet_node)
  if built then
    for _, n in ipairs(built.nodes) do if n.valid then n:destroy() end end
    if mesh and mesh.free then for _, m in ipairs(built.meshes) do mesh.free(m) end end
    built = nil
  end
  local ok, B = pcall(build_meshes, Fr, runway)
  if ok then
    show_meshes(B, planet_node)
    lastBuild = B.stats
    local v = B.stats.verts
    log(string.format("base: paving and fittings built — %d + %d + %d + %d vertices%s", v.asphalt, v.concrete,
      v.fixtures, v.lamps, B.stats.numbers and (", runway " .. B.stats.numbers) or ""))
  else
    log("base: could not build the paving — " .. tostring(B))
  end
end

-- Before a FIT: the site's ground must answer for good. A streamed world's
-- ground away from the crew is a coarse stand-in until something comes near,
-- and a fit read off it is off. Ask the engine to make the site exactly (on
-- its workers) and wait for it — READY_WAIT s at most, then fit on what
-- there is, as before. (A base already laid out is not fitted again, and
-- does not wait.)
local function site_final(body, c, g0)
  if not FIELD_RAYCAST then return true end
  local b, cu = space.body(body.name) or body, unit(c)
  local gx, gy, gz = b.x + cu.x * g0, b.y + cu.y * g0, b.z + cu.z * g0
  if not terrain.ready(gx, gy, gz, READY_R) then
    if not ready_t0 then
      ready_t0 = wait_t
      terrain.prepare(gx, gy, gz, READY_R)
    end
    if wait_t - ready_t0 < READY_WAIT then return false end
    if not ready_late then
      ready_late = true
      log(string.format("base: the site's ground is still not final after %.0f s — fitting on it as it is", READY_WAIT))
    end
  elseif ready_t0 and not ready_said then
    ready_said = true
    log(string.format("base: the site's ground is final (%.1f s)", wait_t - ready_t0))
  end
  return true
end

local function try_place()
  -- Nothing is sited while the loading screen is up: the crew is parked over
  -- the north pole then, not standing where they live.
  local gm = ref("game_manager")
  if gm and gm.loading then return false end
  local crew = find("Astronaut")
  if not crew then return false end
  local body = site_body(crew)
  if not body then return false end
  if body.name and body.name ~= "" then terrain.warm(body.name) end
  -- No planet node, no base: a facility that fails to parent never rides the orbit.
  local planet_node = find(body.name)
  if not planet_node then return false end

  -- THE CENTRE: the saved site, or (first siting) the ground under the crew.
  local hx, hy, hz = save.get("base.x"), save.get("base.y"), save.get("base.z")
  local c, first = nil, false
  if save.get("base.body") == body.name and hx and hy and hz then
    c = V(hx, hy, hz)
  else
    c = V(crew.x - body.x, crew.y - body.y, crew.z - body.z)
    first = true
  end
  if len(c) < 1e-3 then return false end
  -- The terrain must answer before anything is fitted or graded.
  local top = probe_altitude(body)
  local g0 = ground_r(body, unit(c), top)
  if not g0 then return false end

  local R, heading = save.get("base.r"), save.get("base.heading")
  local runway = save.get("base.runway") ~= false
  local fresh = (save.get("base.layout") or 0) < LAYOUT_VERSION or not (R and heading)
  -- AN OLDER LAYOUT ON A SITED BASE (layout 3 brought the 50 m VAB and moved
  -- three buildings out for it) is RE-LAID, not RE-FITTED: the same centre,
  -- radius, heading and runway, so the pad, the runway and every strip stay
  -- exactly where the fleet left its craft, and only the new lots are graded
  -- (`grade` keeps its discs off parked craft: `upgrade`). A fit could turn
  -- the whole spaceport to a new heading under them.
  local was = save.get("base.layout")
  local upgrade = fresh and not first and R and heading and was and true or false
  if upgrade then
    save.set("base.layout", LAYOUT_VERSION)
    save.set("base.graded", false)
    keep_off = parked_craft(body)
    log(string.format("base: layout %s → %d on %s — same site and heading, the new lots to grade (%d parked craft kept clear)",
      tostring(was), LAYOUT_VERSION, body.name, #keep_off))
  elseif fresh then
    if not site_final(body, c, g0) then return false end
    local r2, h2, cost, rw_wet = fitLayout(body, c)
    if not r2 then return false end
    R, heading = r2, h2
    runway = (rw_wet or 0) == 0
    local cu = unit(c)
    save.set("base.body", body.name)
    save.set("base.x", cu.x * R)
    save.set("base.y", cu.y * R)
    save.set("base.z", cu.z * R)
    save.set("base.r", R)
    save.set("base.heading", heading)
    save.set("base.runway", runway)
    save.set("base.layout", LAYOUT_VERSION)
    save.set("base.graded", false)
    log(string.format("base: spaceport %s on %s — graded to r %.1f, runway %s (fit cost %.0f)%s",
      first and "sited" or "laid out", body.name, R,
      runway and string.format("heading %.0f°", (90 - math.deg(heading)) % 360) or "left out: the ground there is under water",
      cost or 0, casts_inexact > 0 and string.format("; %d of %d ground reads crossed stand-in ground", casts_inexact, casts) or ""))
  end
  body = space.body(body.name) or body           -- the fit spanned frames: live again
  F = frameOf(c, heading, R)
  local cu = F.c
  baseBody = body.name
  baseX, baseY, baseZ = body.x + cu.x * R, body.y + cu.y * R, body.z + cu.z * R
  footprint = { body = body.name, x = cu.x * R, y = cu.y * R, z = cu.z * R, radius = FOOTPRINT_RADIUS }

  -- THE GROUND. Graded on a fresh layout, or when it no longer holds — but
  -- only with the crew close by. Terrain streams in around the crew: the
  -- ground of a base the crew is a few kilometres round the world from is
  -- not all resident, and an edit sent there half lands (an old save came
  -- back with the apron graded and a slab of the old hillside still hanging
  -- over it). Away from home the base stands on the ground as it is, and the
  -- grade waits for them to come back (`update`).
  local holds, worst = true, 0
  -- A base graded and checked before keeps its ground: the edits are in the
  -- slot's saved terrain, so a resume sends nothing (`base.graded`).
  if not fresh and save.get("base.graded") ~= LAYOUT_VERSION then holds, worst = grade_holds(body, F, runway) end
  if fresh or not holds then
    local cd = len(V(crew.x - (body.x + cu.x * R), crew.y - (body.y + cu.y * R), crew.z - (body.z + cu.z * R)))
    -- (a save that has played streams its saved ground back in. The engine
    -- holds an EDIT made meanwhile until it has landed (0480), but the
    -- grade's cut and fill probes READ the ground: asked before it lands,
    -- a graded site read as air below the grade and got 537 needless fills)
    local busy = save.get("g_played") ~= nil and terrain.busy and terrain.busy()
    if cd <= GRADE.near and not busy then
      local n = grade(body, F, runway)
      log(string.format("base: grading the spaceport (%d terrain ops%s)", n,
        fresh and "" or string.format(", the ground had moved %.2f m", worst)))
    else
      grade_later = { runway = runway, streaming = busy and cd <= GRADE.near,
                      why = fresh and "new layout" or string.format("ground moved %.2f m", worst) }
      log(string.format("base: the grade waits for %s (%s)",
        busy and "the terrain to finish streaming" or string.format("the crew (%.0f m away)", cd), grade_later.why))
    end
  end

  -- THE BUILDINGS, the floodlights, and the paving.
  for _, f in ipairs(FACILITIES) do
    if not done[f.prefab] then
      place_facility(f, body, F, planet_node)
      done[f.prefab] = true
      placed = placed + 1
    end
  end
  place_floods(body, F, planet_node)
  pave_body = body.name
  -- The paving is laid on the ground as it stands, so it waits for a grade
  -- that is still on its way (`update` lays it the frame the grade is done).
  -- A save that has played streams its saved (graded) ground back in after
  -- the world loads: laid before that lands, the paving followed the ground
  -- as GENERATED and the graded ground then came up over all of it. Wait.
  local streaming = save.get("g_played") ~= nil and terrain.busy and terrain.busy()
  if grade_busy() or streaming then
    pave_pending = { runway = runway, node = planet_node, t = time }
  else
    lay_paving(F, runway, planet_node)
    -- (a grade still waiting for the crew re-lays it when it has landed)
    if grade_later then pave_pending = { runway = runway, node = planet_node } end
  end
  return true
end

-- Tear the base down and forget where it was, so the next tick re-sites it
-- wherever the crew is standing. The debug key (`cheats.lua`, F6) calls this.
function resite()
  for _, f in ipairs(FACILITIES) do
    local n = find(f.prefab)
    if n and n.valid then n:destroy() end
  end
  for _ = 1, #APRON_FLOODS do
    local n = find("BaseFlood")
    if n and n.valid then n:destroy() end
  end
  if built then
    for _, n in ipairs(built.nodes) do if n.valid then n:destroy() end end
    if mesh and mesh.free then for _, m in ipairs(built.meshes) do mesh.free(m) end end
  end
  built = nil
  for _, k in ipairs({ "base.body", "base.x", "base.y", "base.z", "base.r", "base.heading", "base.runway", "base.layout", "base.graded" }) do
    save.set(k, false)
  end
  done, placed, sited, footprint, F = {}, 0, false, nil, nil
  pave_pending, pave_job = nil, nil
  want_spawn, wait_t, last_note = true, 0.0, 0.0
  ready_t0, ready_late, ready_said = nil, false, false
  log("base: spaceport cleared — re-siting where you stand")
end

-- WHICH WORLDS HAVE A TRACKING STATION. A craft at rest on such a world can be
-- RECOVERED from the Tracking Station screen (scripts/tracking_station.lua).
-- Today that is the home world only. A station on another world adds that
-- world here (`otherStations[bodyName] = true`, kept in the save).
otherStations = {}

function trackingStationOn(body)
  if not body then return false end
  if sited and baseBody == body then return true end
  return otherStations[body] == true
end

-- Is ground work still owed or under way? (probes and the loading screen)
function grading()
  return grade_busy() or grade_job ~= nil or check_now or (grade_later ~= nil and grade_later.now == true)
    or (grade_later ~= nil and grade_later.streaming == true) or (pave_pending ~= nil and grade_later == nil)
end

local function finish_siting()
  sited = true
  local crew = find("Astronaut")
  if crew then
    local dx, dy, dz = crew.x - baseX, crew.y - baseY, crew.z - baseZ
    log(string.format("base: the spaceport is standing — %.0f m from the crew", sqrt(dx * dx + dy * dy + dz * dz)))
  else
    log("base: the spaceport is standing")
  end
end

function update(node, dt)
  -- Keep the published base position live: the body is orbiting.
  if baseBody then
    local b = space.body(baseBody)
    local hx, hy, hz = save.get("base.x"), save.get("base.y"), save.get("base.z")
    if b and hx then baseX, baseY, baseZ = b.x + hx, b.y + hy, b.z + hz end
  end
  -- The frames after siting: the grade lands (the engine's pace), it is
  -- CHECKED the frame it has, and only then is the ground done — so a grade
  -- that did not hold is made again behind the loading curtain, never in
  -- view (the regrade below runs while `grading()` still holds the curtain).
  if not want_spawn and not sited and placed >= #FACILITIES then
    if grade_busy() then
      if not grade_step() then check_now = true end
      return
    end
    if check_now and not grade_later and not grade_job and time >= (check_at or 0) then
      check_now, check_at = false, nil
      local b = space.body(baseBody)
      local ok, worst = grade_holds(b, F, save.get("base.runway") ~= false)
      if not ok and not relooked then
        -- read again a second later before anything is regraded
        relooked, check_now, check_at = true, true, time + 1.0
        log(string.format("base: the grade reads %.2f m off — looking again in a second", worst))
      elseif ok then
        save.set("base.graded", LAYOUT_VERSION)
        log(string.format("base: the grade holds (%.2f m) — recorded", worst))
      elseif regrades < 2 and not grade_stuck(worst) then
        regrades = regrades + 1
        grade_later = { runway = save.get("base.runway") ~= false, now = true,
                        why = string.format("check after grading: %.2f m off", worst) }
        log("base: the grade did not hold — " .. grade_later.why .. ", grading again before the curtain goes")
      else
        -- recorded anyway: grading this ground again changes nothing
        save.set("base.graded", LAYOUT_VERSION)
        log(string.format("base: the grade still does not hold (%.2f m) — leaving it", worst))
      end
    end
    if not (grade_later and grade_later.now) and not grade_job and not check_now
       and not (pave_pending and not grade_later) then
      finish_siting()
    end
  end
  -- A grade that waited for the crew: start it when they are back in range,
  -- as its own sliced job, then send it like any other.
  if not want_spawn and grade_later and F and baseBody then
    local crew = find("Astronaut")
    local b = space.body(baseBody)
    if crew and b and len(V(crew.x - baseX, crew.y - baseY, crew.z - baseZ)) <= GRADE.near
       and (grade_job or save.get("g_played") == nil or not (terrain.busy and terrain.busy())) then
      if not grade_job then
        local gl = grade_later
        grade_job = coroutine.create(function()
          local n = grade(b, F, gl.runway)
          log(string.format("base: the crew is home — grading the spaceport (%d terrain ops, %s)", n, gl.why))
        end)
      end
      job_begin()
      local ok, err = coroutine.resume(grade_job)
      job_active = false
      if coroutine.status(grade_job) == "dead" then
        if not ok then log("base: grading failed — " .. tostring(err)) end
        grade_job, grade_later = nil, nil
      end
    end
  end
  -- Paving that waited for its grade: laid (as a sliced job) once the ground
  -- is done.
  if not want_spawn and pave_pending and not grade_busy() and not grade_later and not grade_job and F
     and (pave_job or save.get("g_played") == nil or not (terrain.busy and terrain.busy())
          or time - (pave_pending.t or time) > 25.0) then
    if not pave_job then
      local pp = pave_pending
      pave_job = coroutine.create(function() lay_paving(F, pp.runway, pp.node) end)
    end
    job_begin()
    local ok, err = coroutine.resume(pave_job)
    job_active = false
    if coroutine.status(pave_job) == "dead" then
      if not ok then log("base: paving failed — " .. tostring(err)) end
      pave_job, pave_pending = nil, nil
    end
  end
  if not want_spawn and sited and not grade_later and grade_busy() then
    -- checked as soon as it has landed (an edit no longer lands under ground
    -- still streaming in, 0480), while a curtain that waited for it is up
    if not grade_step() then recheck_at = time end
  end
  -- THE GRADE IS CHECKED once it has landed. Edits that land while a slot's
  -- saved terrain is still streaming in can be laid over by it (an old save's
  -- hanging slab came back after it was cut away): look again, regrade up to
  -- twice.
  if not want_spawn and recheck_at and time >= recheck_at and F and baseBody and not grade_busy() and not grade_later then
    recheck_at = nil
    local b = space.body(baseBody)
    local ok, worst = grade_holds(b, F, save.get("base.runway") ~= false)
    if ok then
      save.set("base.graded", LAYOUT_VERSION)
      log(string.format("base: the grade holds (%.2f m) — recorded", worst))
    end
    if not ok and not relooked then
      relooked, recheck_at = true, time + 1.0
      log(string.format("base: the grade reads %.2f m off — looking again in a second", worst))
    elseif not ok and regrades < 2 and not grade_stuck(worst) then
      regrades = regrades + 1
      grade_later = { runway = save.get("base.runway") ~= false, now = true,
                      why = string.format("check after grading: %.2f m off", worst) }
      log("base: the grade did not hold — " .. grade_later.why .. ", grading again")
    elseif not ok then
      save.set("base.graded", LAYOUT_VERSION)
      log(string.format("base: the grade still does not hold (%.2f m) — leaving it", worst))
    end
  end
  if not want_spawn then return end
  wait_t = wait_t + dt
  if not job then job = coroutine.create(try_place) end
  job_begin()
  local ok, res = coroutine.resume(job)
  job_active = false
  if coroutine.status(job) ~= "dead" then return end
  job = nil
  if not ok then
    log("base: siting failed — " .. tostring(res))
  elseif res then
    want_spawn = false
    return
  end
  if wait_t - last_note > 5.0 then
    last_note = wait_t
    log(string.format("base: waiting for terrain… (%.0fs)", wait_t))
  end
end
