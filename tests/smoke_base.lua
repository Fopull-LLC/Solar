-- SMOKE HARNESS for base_facilities.lua: runs the real script against a stubbed
-- engine API (a round, offset planet + a crew node on its surface) and drives the
-- placement to completion. Catches Lua runtime errors and the classic sins this
-- kind of surface-anchoring code commits:
--   * writing WORLD coords into a planet-parented node (the round-7 far-side bug):
--     every facility's local coords must be BODY-RELATIVE, not absolute.
--   * facilities seated off the ground / flung away by a bad raycast.
--   * not all facilities placed (an angle that never finds ground).
--   * the base MOVING between sessions — it is sited once, saved body-relative,
--     and rebuilt on the same ground however far the crew has wandered.
--   * anything sited while the loading screen is still up (the crew is parked
--     over the north pole then, not standing where they live).
--   * the ring drawn on a FLAT MAP. Planets are round: a facility 36 m from the
--     base on a 200 m world is 10 degrees round the curve, so it has its own
--     local up. A ring laid across the tangent plane leans every building by
--     that angle and probes for ground from a point that is already inside the
--     hill on any world with real relief. Assertion 6 is the guard.
--
--   luajit solar/tests/smoke_base.lua

local TICK = 1 / 60

-- Planet OFFSET from the origin so a "local == world" bug can't accidentally pass.
local planet = { name = "Athosil", x = 300, y = -120, z = 80, radius = 200, mu = 4.0e5, soi = 5000 }
local planet_node = { __id = 1, name = planet.name, x = planet.x, y = planet.y, z = planet.z, valid = true }

-- Crew on the +Y-ish surface of the planet (a point at radius on the surface).
local up0 = { x = 0.12, y = 0.97, z = 0.21 }
local ul = math.sqrt(up0.x^2 + up0.y^2 + up0.z^2)
up0.x, up0.y, up0.z = up0.x / ul, up0.y / ul, up0.z / ul
local crew = {
  __id = 2, name = "Astronaut", valid = true,
  x = planet.x + up0.x * planet.radius,
  y = planet.y + up0.y * planet.radius,
  z = planet.z + up0.z * planet.radius,
}

local nodes = { planet_node, crew }
local spawned = {}
local next_id = 100

_G.vec3 = function(x, y, z) return { x = x, y = y, z = z } end
_G.log = function(_) end
_G.find = function(name)
  for _, n in ipairs(nodes) do if n.name == name then return n end end
  return nil
end
-- Every flatten the siting asks for, in order: (radius, mode).
local sculpts = {}
_G.terrain = { warm = function() end,
  sculpt = function(x, y, z, radius, strength, mode)
    -- Body-relative, as the planet stood when the op was SENT.
    sculpts[#sculpts + 1] = { x = x - planet.x, y = y - planet.y, z = z - planet.z,
                              r = radius, mode = mode }
  end }
_G.space = {
  bodies = function() return { planet } end,
  body = function(name) if name == planet.name then return planet end end,
}
local STORE = {}
_G.save = { get = function(k) return STORE[k] end, set = function(k, v) STORE[k] = v end }
-- The loading screen: while `loading` is true nothing may be sited.
local gm = { loading = false }
_G.findScript = function(kind) if kind == "game_manager" then return gm end end

-- Faithful ray/sphere intersection against the planet.
_G.raycast = function(ox, oy, oz, dx, dy, dz, maxd)
  local ocx, ocy, ocz = ox - planet.x, oy - planet.y, oz - planet.z
  local b = 2 * (dx * ocx + dy * ocy + dz * ocz)
  local c = ocx^2 + ocy^2 + ocz^2 - planet.radius^2
  local disc = b * b - 4 * c
  if disc < 0 then return nil end
  local t = (-b - math.sqrt(disc)) / 2
  if t < 0 or t > (maxd or 1e9) then return nil end
  return { distance = t }
end

_G.spawn = function(prefab, pos, cb, parent)
  local inst = { __id = next_id, name = prefab, valid = true,
    x = pos.x, y = pos.y, z = pos.z, pitch = 0, roll = 0, yaw = 0, parent = parent }
  next_id = next_id + 1
  nodes[#nodes + 1] = inst
  if cb then cb(inst) end
  spawned[#spawned + 1] = { prefab = prefab, world = { x = pos.x, y = pos.y, z = pos.z }, inst = inst }
  return inst
end

-- ── run ─────────────────────────────────────────────────────────────────────
local function run_session(host_name, limit)
  local chunk = assert(loadfile("solar/scripts/base_facilities.lua"))
  chunk() -- fresh script state (its `done`/`placed` locals reset)
  assert(type(start) == "function", "base_facilities must define start()")
  assert(type(update) == "function", "base_facilities must define update()")
  start(crew)
  local host = { __id = 3, name = host_name }
  for _ = 1, (limit or 6000) do
    update(host, TICK)
    if #spawned >= 5 then return true end
  end
  return false
end

-- Session 1, still loading: the crew is parked over the pole, nothing goes up.
gm.loading = true
assert(not run_session("Base Facilities", 240), "sited during the loading screen")
assert(#spawned == 0, "expected nothing sited while loading, got " .. #spawned)
assert(STORE["base.body"] == nil, "the base site must not be recorded while loading")

-- Session 1, loaded: the colony goes up around the crew and is remembered.
gm.loading = false
assert(run_session("Base Facilities"), "base placement never completed (100s of ticks)")

-- ── assertions ────────────────────────────────────────────────────────────
assert(#spawned == 5, "expected 5 facilities, got " .. #spawned)

-- The ground is levelled out to every CORNER. The command centre is 12 × 18 m
-- — corners 10.8 m from its middle — and an 11 m brush (which falls off toward
-- its rim) left them humped up through the floor. Half-diagonal + 4 m, and
-- enough passes to actually get there.
do
  local by_r = {}
  for _, c in ipairs(sculpts) do
    assert(c.mode == "flatten", "siting only flattens, got " .. tostring(c.mode))
    by_r[c.r] = (by_r[c.r] or 0) + 1
  end
  local biggest = 0
  for r, n in pairs(by_r) do
    biggest = math.max(biggest, r)
    assert(n >= 3, string.format("a %.1f m flatten ran only %d passes", r, n))
  end
  assert(biggest >= 14.5, string.format(
    "the command centre's flatten must reach its corners (≥ 14.5 m), got %.1f m", biggest))
end

-- FEW terrain ops. Every op costs the frame a collider rebuild (about a
-- quarter of a second each on a real planet): a grid of ~500 small levelling
-- patches froze the landing for half a minute. Siting a colony is the big
-- flattens and nothing else, and the colony counts as sited the frame after.
do
  local before = #sculpts
  for _ = 1, 3 do update({ __id = 3, name = "Base Facilities" }, TICK) end
  assert(sited, "the colony is sited the frame after its ground is flattened")
  assert(#sculpts == before, "nothing more is sculpted after siting, got " .. (#sculpts - before))
  assert(#sculpts <= 30, "siting sent " .. #sculpts .. " terrain ops — a few big passes, never a grid")
end

local seen = {}
for _, s in ipairs(spawned) do
  seen[s.prefab] = true
  -- 1. Parented to the planet node.
  assert(s.inst.parent == planet_node, s.prefab .. " must be parented to the planet")
  -- 2. Local coords are BODY-RELATIVE, not world. World pos ≈ body + local.
  local lx, ly, lz = s.inst.x, s.inst.y, s.inst.z
  local wx, wy, wz = planet.x + lx, planet.y + ly, planet.z + lz
  local dw = math.sqrt((wx - s.world.x)^2 + (wy - s.world.y)^2 + (wz - s.world.z)^2)
  assert(dw < 1e-3, s.prefab .. " local coords are NOT body-relative (far-side bug): off by " .. dw)
  -- 3. Seated near the surface (origin within a few units above ground).
  local r = math.sqrt((wx - planet.x)^2 + (wy - planet.y)^2 + (wz - planet.z)^2)
  local above = r - planet.radius
  assert(above > 0.2 and above < 6.0, s.prefab .. " badly seated: " .. above .. " above surface")
  -- 4. Near the base, not flung across the system.
  local db = math.sqrt((wx - crew.x)^2 + (wy - crew.y)^2 + (wz - crew.z)^2)
  assert(db < 60, s.prefab .. " sited too far from base: " .. db)
  -- 5. Ringed at a sane ARC distance round the surface (not a chord across a
  -- tangent plane, which reads short and climbs as the radius grows).
  local fx, fy, fz = (wx - planet.x) / r, (wy - planet.y) / r, (wz - planet.z) / r
  local dot = math.max(-1, math.min(1, fx * up0.x + fy * up0.y + fz * up0.z))
  local arc = math.acos(dot) * planet.radius
  assert(arc > 24 and arc < 46,
    string.format("%s is %.0f m round the surface from the base — off the ring", s.prefab, arc))
  -- 6. Standing on ITS OWN local up. A building that inherited the BASE's
  -- normal leans by the arc angle — ten degrees at this radius. Checked the
  -- way the engine applies it: +Y through R = Ry(yaw)·Rx(pitch)·Rz(roll)
  -- (glam's EulerRot::YXZ, radians), so a yaw that swings the building off its
  -- up — the old bug, a `215` "degrees" yaw on top of a yaw-free tilt — fails.
  local p, r2, y = s.inst.pitch or 0, s.inst.roll or 0, s.inst.yaw or 0
  local bx = -math.sin(r2) * math.cos(y) + math.cos(r2) * math.sin(p) * math.sin(y)
  local by = math.cos(r2) * math.cos(p)
  local bz = math.sin(r2) * math.sin(y) + math.cos(r2) * math.sin(p) * math.cos(y)
  local lean = math.deg(math.acos(math.max(-1, math.min(1, bx * fx + by * fy + bz * fz))))
  assert(lean < 0.01,
    string.format("%s leans %.2f degrees off its own local up", s.prefab, lean))
end
for _, want in ipairs({ "FacCommand", "FacHangar", "FacPower", "FacTracking", "FacDepot" }) do
  assert(seen[want], "missing facility: " .. want)
end

-- 7. The site is remembered BODY-RELATIVE (absolute coords go stale on an orbit).
assert(STORE["base.body"] == planet.name, "the base site's body was not saved")
local hx, hy, hz = STORE["base.x"], STORE["base.y"], STORE["base.z"]
assert(hx and hy and hz, "the base site offset was not saved")
local hr = math.sqrt(hx * hx + hy * hy + hz * hz)
assert(math.abs(hr - planet.radius) < 2.0,
  string.format("the saved site is not on the surface (r = %.1f)", hr))
local first = { x = planet.x + hx, y = planet.y + hy, z = planet.z + hz }

-- ── session 2: reload, crew 300 m away, the base must NOT follow them ───────
local before = #spawned
-- The planet has moved on its orbit AND the crew wakes up somewhere else.
planet.x, planet.y, planet.z = planet.x + 5000, planet.y - 800, planet.z + 1200
planet_node.x, planet_node.y, planet_node.z = planet.x, planet.y, planet.z
local away = { x = 0.62, y = 0.70, z = 0.35 }
local al = math.sqrt(away.x^2 + away.y^2 + away.z^2)
crew.x = planet.x + away.x / al * planet.radius
crew.y = planet.y + away.y / al * planet.radius
crew.z = planet.z + away.z / al * planet.radius
spawned = {}
assert(run_session("Base Facilities"), "the base never rebuilt in session 2")
assert(#spawned == 5, "session 2 expected 5 facilities, got " .. #spawned)

-- Same ground, moved only by the planet's own orbit: the saved offset is what
-- carries the colony, so it must be UNCHANGED and the buildings must land on it.
assert(STORE["base.x"] == hx and STORE["base.y"] == hy and STORE["base.z"] == hz,
  "session 2 overwrote the saved base site")
local site2 = { x = planet.x + hx, y = planet.y + hy, z = planet.z + hz }
for _, s in ipairs(spawned) do
  local d = math.sqrt((s.world.x - site2.x)^2 + (s.world.y - site2.y)^2 + (s.world.z - site2.z)^2)
  assert(d < 60, s.prefab .. " rebuilt " .. math.floor(d) .. " m from the saved site")
end
local crew_d = math.sqrt((crew.x - site2.x)^2 + (crew.y - site2.y)^2 + (crew.z - site2.z)^2)
assert(crew_d > 100, "the test crew should be far from home (got " .. math.floor(crew_d) .. " m)")

print(string.format(
  "smoke_base OK — 5 facilities sited, body-relative, seated; base stayed home across a reload (crew %.0f m away)",
  crew_d))
