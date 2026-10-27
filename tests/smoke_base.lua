-- SMOKE HARNESS for base_facilities.lua — the spaceport. Runs the real script
-- against a stubbed engine (an offset round planet, a crew node on it, a
-- terrain field whose ground the flattens really move) and drives the siting
-- to completion. It holds the layout to its contracts:
--
--   1. nothing is sited while the loading screen is up;
--   2. every structure is parented to the planet, in BODY-RELATIVE local
--      coords, stood on its OWN radial up (the layout is drawn on the sphere),
--      its origin `seat` over the graded ground;
--   3. the tracking dish is within 80 m of the base centre (comms.station);
--      the launch pad is ≥ 80 m from every building and on the far side of
--      the compound from the runway;
--   4. the runway is straight AND follows the curve: every centreline vertex
--      of the paving lies on one great circle, at the graded radius;
--   5. the ground is graded to that radius (flatten discs centred ON it), and
--      a reload only checks it — no second grading;
--   6. the launch sites: the pad's deck point, and the runway threshold facing
--      down the runway; a base whose runway was left out answers the pad;
--   7. keepClear: true on the paving and the lots, false out in the field;
--   8. an OLD save (a base sited before this layout) is laid out where it
--      stands, never moved.
--   9. the floor: a row of static slabs under every strip, on the sphere; and
--      the foundations: digClamp keeps digs out of every strip's and lot's
--      column (GUARD.margin wider), not out of open ground or deep rock.
--
--   luajit solar/tests/smoke_base.lua

local TICK = 1 / 60
local function approx(a, b, e) return math.abs(a - b) <= e end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end

local planet = { name = "Athosil", x = 3000, y = -1200, z = 800, radius = 640, mu = 4.0e5, soi = 50000 }
local planet_node = { __id = 1, name = planet.name, valid = true }
-- Ground: the sphere plus a gentle swell, until the flattens level it.
local graded = {}            -- list of { dir, R, r }: discs that have landed
local HILL = nil            -- { x, y, z (unit), arc, height }: a hill the grade must cut
local function ground_r(dx, dy, dz)
  local g = planet.radius + 1.2 * math.sin(dx * 9) * math.cos(dz * 7)
  if HILL then
    local c = dx * HILL.x + dy * HILL.y + dz * HILL.z
    local a = math.acos(math.max(-1, math.min(1, c))) * planet.radius
    if a < HILL.arc then g = g + HILL.height * (1 - a / HILL.arc) end
  end
  for _, d in ipairs(graded) do
    local c = dx * d.x + dy * d.y + dz * d.z
    local arc = math.acos(math.max(-1, math.min(1, c))) * d.R
    if arc < d.r * 0.6 then g = d.R end
  end
  return g
end

local up0 = { x = 0.31, y = 0.62, z = 0.72 }
do local l = len(up0.x, up0.y, up0.z); up0.x, up0.y, up0.z = up0.x / l, up0.y / l, up0.z / l end
local crew = { __id = 2, name = "Astronaut", valid = true }
local function put_crew(u)
  local g = ground_r(u.x, u.y, u.z) + 1.0
  crew.x, crew.y, crew.z = planet.x + u.x * g, planet.y + u.y * g, planet.z + u.z * g
end
put_crew(up0)

local nodes, spawned, created, meshes = {}, {}, {}, {}
local queries, worst_frame = 0, 0
local cutfill = {}
local sculpts, paints = 0, 0
local STORE = {}
_G.vec3 = function(x, y, z) return { x = x, y = y, z = z } end
_G.log = function() end
_G.time = 0
_G.find = function(name)
  if name == planet.name then return planet_node end
  if name == "Astronaut" then return crew end
  for _, n in ipairs(nodes) do if n.name == name and n.valid then return n end end
end
_G.findScript = function(kind) if kind == "game_manager" then return _G.GM end end
_G.GM = { loading = false }
-- The siting job's clock (base_facilities slices by wall time): every field
-- query costs QUERY_MS of it, so the budget reads as a number of queries.
local QUERY_MS = 0.05
FAKE_WALL = 0
_G.app = { wallClock = function() return FAKE_WALL end }
_G.space = {
  bodies = function() return { planet } end,
  body = function(n) if n == planet.name then return planet end end,
}
_G.save = { get = function(k) local v = STORE[k]; if v == false then return nil end return v end,
            set = function(k, v) STORE[k] = v end }
_G.terrain = {
  warm = function() end,
  query = function(x, y, z)
    queries = queries + 1
    FAKE_WALL = FAKE_WALL + QUERY_MS / 1000
    if NOFIELD then return 6.0 end          -- a world whose field is not made yet: clamped air everywhere
    local dx, dy, dz = x - planet.x, y - planet.y, z - planet.z
    local r = len(dx, dy, dz)
    return r - ground_r(dx / r, dy / r, dz / r)
  end,
  sculpt = function(x, y, z, radius, strength, mode)
    assert(mode == "flatten" or mode == "smooth" or mode == "lower" or mode == "raise", "unexpected sculpt " .. tostring(mode))
    if mode ~= "flatten" then sculpts = sculpts + 1; cutfill[mode] = (cutfill[mode] or 0) + 1 return end
    local dx, dy, dz = x - planet.x, y - planet.y, z - planet.z
    local r = len(dx, dy, dz)
    if strength >= 0.99 then graded[#graded + 1] = { x = dx / r, y = dy / r, z = dz / r, R = r, r = radius } end
    sculpts = sculpts + 1
  end,
  paint = function() paints = paints + 1 end,
}
_G.mesh = {
  build = function(t)
    local nv = #t.positions / 3
    assert(nv == math.floor(nv) and nv > 0, "positions not in threes")
    assert(#t.normals == #t.positions and #t.uvs / 2 == nv and #t.colors / 4 == nv, "uneven lists")
    assert(#t.indices % 3 == 0, "indices not in threes")
    for _, i in ipairs(t.indices) do assert(i >= 1 and i <= nv, "index out of range " .. i) end
    for _, v in ipairs(t.positions) do assert(v == v and math.abs(v) < 1e6, "non-finite position") end
    local name = "mesh:" .. (#meshes + 1)
    meshes[#meshes + 1] = { name = name, t = t }
    return name
  end,
  free = function() end,
}
local function new_node(name, parent)
  local n = { name = name, valid = true, parent = parent, x = 0, y = 0, z = 0 }
  function n:setUp(u, f) self.up_set, self.fwd_set = u, f end
  function n:setMaterial(m) self.mat = m end
  function n:lookAt(t, u) self.look = t end
  function n:destroy() self.valid = false end
  nodes[#nodes + 1] = n
  return n
end
_G.createNode = function(name, parent, fn)
  local n = new_node(name, parent)
  created[#created + 1] = n
  if fn then fn(n) end
end
_G.spawn = function(prefab, pos, fn, parent)
  local n = new_node(prefab, parent)
  n.x, n.y, n.z = pos.x, pos.y, pos.z
  n.world = { x = pos.x, y = pos.y, z = pos.z }
  spawned[#spawned + 1] = n
  if fn then fn(n) end
end

local BF
local function session(limit)
  local env = setmetatable({}, { __index = _G })
  local chunk = assert(loadfile("solar/scripts/base_facilities.lua"))
  setfenv(chunk, env)
  chunk()
  BF = env
  env.start({})
  for _ = 1, (limit or 6000) do
    queries = 0
    time = time + TICK
    env.update({}, TICK)
    worst_frame = math.max(worst_frame, queries)
    if env.sited then return true end
  end
  return false
end

-- ── 1. not while loading ────────────────────────────────────────────────────
GM.loading = true
assert(not session(120), "sited during the loading screen")
assert(#spawned == 0 and STORE["base.body"] == nil, "nothing may be sited while loading")
GM.loading = false

-- ── session 1: a new base ───────────────────────────────────────────────────
assert(session(), "the spaceport never finished siting")
local R = STORE["base.r"]
assert(STORE["base.layout"] == BF.LAYOUT_VERSION and R and STORE["base.heading"], "layout not saved")
assert(math.abs(R - planet.radius) < 2.0, string.format("graded radius %.1f is not the ground's", R))
local hx, hy, hz = STORE["base.x"], STORE["base.y"], STORE["base.z"]
assert(approx(len(hx, hy, hz), R, 1e-6), "the saved centre is not on the graded sphere")
local c = { x = hx / R, y = hy / R, z = hz / R }
assert(c.x * up0.x + c.y * up0.y + c.z * up0.z > 0.99999, "the base is not where the crew stood")
local sculpts1 = sculpts
assert(sculpts1 > 150 and sculpts1 < 2400, "grading sent " .. sculpts1 .. " ops")
for _, d in ipairs(graded) do
  assert(approx(d.R, R, 1e-6), "a flatten disc not centred on the graded sphere")
end

assert(not cutfill.lower and not cutfill.raise, "a flat site needs no cut or fill")

-- 0. time-sliced: no frame does more than its budget of field queries (the
-- engine stops a script that runs 2 s; a loaded machine got there)
local per_frame = math.ceil(BF.WORK_MS / QUERY_MS) + BF.WORK_CHECK
-- (+ the grade check's ~100 point reads, made at once in update, as before)
assert(worst_frame <= per_frame + 120,
  string.format("one frame made %d field queries (budget %d)", worst_frame, per_frame))

-- 2. structures
local want = {}
for _, f in ipairs(BF.FACILITIES) do want[f.prefab] = f end
local seen, pos = {}, {}
for _, n in ipairs(spawned) do
  local f = want[n.name]
  if f then
    seen[n.name] = true
    assert(n.parent == planet_node, n.name .. " is not parented to the planet")
    local wx, wy, wz = planet.x + n.x, planet.y + n.y, planet.z + n.z
    assert(approx(wx, n.world.x, 1e-6) and approx(wy, n.world.y, 1e-6) and approx(wz, n.world.z, 1e-6),
      n.name .. " local coords are not body-relative")
    local r = len(n.x, n.y, n.z)
    local want_r = math.sqrt((R + f.seat + (f.lift or 0)) ^ 2 + f.ox ^ 2 + f.oz ^ 2)
    assert(approx(r, want_r, 0.05), string.format("%s seated at r %.2f, want %.2f", n.name, r, want_r))
    local u = n.up_set
    local ul = len(u.x, u.y, u.z)
    local gx, gy, gz = n.x - u.x / ul * f.seat, n.y - u.y / ul * f.seat, n.z - u.z / ul * f.seat  -- (unused)
    local gl = len(gx, gy, gz)
    local fx, fy, fz = n.fwd_set.x, n.fwd_set.y, n.fwd_set.z
    assert(math.abs((fx * u.x + fy * u.y + fz * u.z) / len(fx, fy, fz) / ul) < 1e-6, n.name .. " faces up or down")
    pos[n.name] = { x = n.x / r, y = n.y / r, z = n.z / r }
  end
end
for name in pairs(want) do assert(seen[name], "missing structure " .. name) end
local floods = 0
for _, n in ipairs(spawned) do if n.name == "BaseFlood" then floods = floods + 1; assert(n.look, "a flood not aimed") end end
assert(floods == 2, "expected 2 apron floods, got " .. floods)

-- 3. distances (arc metres from the centre)
local function arc(a, b) return math.acos(math.max(-1, math.min(1, a.x * b.x + a.y * b.y + a.z * b.z))) * R end
local dish = arc(pos.FacTracking, c)
assert(dish < 80, string.format("the tracking dish is %.0f m from the base centre (comms needs < 80)", dish))
local Fr = BF.frameOf(c, STORE["base.heading"], R)
local pad = BF.dirAt(Fr, BF.PAD.u, BF.PAD.v)
for name, p in pairs(pos) do
  if name ~= "BasePad" and name ~= "BaseFuel" then
    assert(arc(p, pad) >= 80, string.format("%s is only %.0f m from the pad", name, arc(p, pad)))
  end
end

-- 4. the runway: straight on the sphere, at the graded radius
local A = nil
for _, mm in ipairs(meshes) do if not A then A = mm end end
local S = BF.stripOf(Fr, BF.RUNWAY.u0, BF.RUNWAY.v, BF.RUNWAY.u1, BF.RUNWAY.v)
assert(approx(S.L, BF.RUNWAY.u1 - BF.RUNWAY.u0, 2.0), string.format("runway %.1f m long", S.L))
local O = { x = c.x * R, y = c.y * R, z = c.z * R }
local onc, worst_r, worst_plane = 0, 0, 0
local P = A.t.positions
for i = 1, #P, 3 do
  local x, y, z = P[i] + O.x, P[i + 1] + O.y, P[i + 2] + O.z
  local r = len(x, y, z)
  local d = { x = x / r, y = y / r, z = z / r }
  local w = math.asin(math.max(-1, math.min(1, d.x * S.n.x + d.y * S.n.y + d.z * S.n.z))) * R
  if math.abs(w) < 0.5 then
    local top = math.abs(r - (R + BF.PAVE_H)) < 0.05
    if top then
      onc = onc + 1
      worst_r = math.max(worst_r, math.abs(r - (R + BF.PAVE_H)))
      worst_plane = math.max(worst_plane, math.abs(w))
    end
  end
end
assert(onc > 100, "few runway centreline vertices found: " .. onc)
assert(worst_plane <= 0.451, string.format("the centreline leaves its great circle by %.3f m", worst_plane))
local n1, n2 = BF.runwayNumbers(BF.frameOf(c, 0, R))
assert(n1 == "09" and n2 == "27", "an east–west runway is 09/27, got " .. n1 .. "/" .. n2)

-- 6. launch sites
local ps = BF.launchSite("pad")
assert(ps and ps.kind == "pad" and ps.deck, "no pad site")
assert(approx(len(ps.x, ps.y, ps.z), R + BF.PAD.hs, 1e-6), "the pad site is not the hardstand top")
assert(arc({ x = ps.up.x, y = ps.up.y, z = ps.up.z }, pad) < 0.01, "the pad site is not at the mount")
local rs = BF.launchSite("runway")
assert(rs and rs.kind == "runway" and not rs.deck, "no runway site")
assert(approx(len(rs.x, rs.y, rs.z), R, 1e-6), "the runway site is not on the ground")
local t0 = { x = S.b.x - S.a.x, y = S.b.y - S.a.y, z = S.b.z - S.a.z }
local tl = len(t0.x, t0.y, t0.z)
assert((rs.fwd.x * t0.x + rs.fwd.y * t0.y + rs.fwd.z * t0.z) / tl > 0.97, "the runway site does not face down the runway")
local d_th = arc(rs.up, S.a)
assert(d_th > 10 and d_th < 30, string.format("the runway site is %.0f m from the threshold end", d_th))

-- 7. keepClear
local function rel(u, v) local d = BF.dirAt(Fr, u, v); return d.x * R, d.y * R, d.z * R end
assert(BF.keepClear(planet.name, rel(0, BF.RUNWAY.v)), "the runway centre must be kept clear")
assert(BF.keepClear(planet.name, rel(0, -10)), "the apron must be kept clear")
assert(BF.keepClear(planet.name, rel(0, 17)), "the VAB lot must be kept clear")
assert(BF.keepClear(planet.name, rel(0, 125)), "the pad must be kept clear")
assert(not BF.keepClear(planet.name, rel(120, 40)), "open ground NE of the compound is not paved")
assert(not BF.keepClear(planet.name, rel(0, -110)), "open ground south of the runway is not paved")
assert(not BF.keepClear("Elsewhere", rel(0, 0)), "another world's ground is never the base's")

-- 9. the floor and its foundations: every strip is a row of static slabs on the
-- sphere, parented to the planet in body-relative coords, their tops SLAB.top
-- over the grade; and digClamp keeps every dig out of a strip's or a lot's
-- column (GUARD.margin wider), but not out of open ground, deep rock or
-- another world.
local slabs, slab_area = 0, 0
for _, n in ipairs(spawned) do
  if n.name == "PaveSlab" then
    slabs = slabs + 1
    assert(n.parent == planet_node, "a floor slab is not parented to the planet")
    assert(approx(planet.x + n.x, n.world.x, 1e-6) and approx(planet.z + n.z, n.world.z, 1e-6), "a slab's local coords are not body-relative")
    assert(approx(len(n.x, n.y, n.z), R + BF.SLAB.top - BF.SLAB.thick / 2, 1e-6), "a slab's top is not SLAB.top over the grade")
    assert(n.scale and n.scale.y == BF.SLAB.thick and n.scale.x > 1 and n.scale.z > 1, "a slab was not scaled to its piece")
    local u = n.up_set
    assert(u and math.abs(len(n.x, n.y, n.z) - (n.x * u.x + n.y * u.y + n.z * u.z)) < 1e-6, "a slab is not turned to its radial up")
    slab_area = slab_area + n.scale.x * (n.scale.z - 2 * BF.SLAB.overlap)
  end
end
assert(slabs >= 40 and BF.SLAB_COUNT == slabs, "floor slabs: " .. slabs .. " (count " .. tostring(BF.SLAB_COUNT) .. ")")
assert(slab_area > 262 * 24 + 26 * 12 + 26 * 48, string.format("the slabs cover %.0f m² — less than the runway, taxiway and apron", slab_area))
local function wrel(u, v, h)
  local d = BF.dirAt(Fr, u, v)
  return planet.x + d.x * (R + h), planet.y + d.y * (R + h), planet.z + d.z * (R + h)
end
local function refused(u, v, h, r) local x, y, z = wrel(u, v, h); return BF.digRefused(x, y, z, r) ~= nil end
-- (across the runway in its own strip frame: a great circle, it bows ~1 m off v = const)
local RS = BF.stripOf(Fr, BF.RUNWAY.u0, BF.RUNWAY.v, BF.RUNWAY.u1, BF.RUNWAY.v)
local edge = BF.RUNWAY.half + BF.RUNWAY.shoulder
local function rw(s, w, h)
  local d = BF.stripDir(RS, s, w)
  return planet.x + d.x * (R + h), planet.y + d.y * (R + h), planet.z + d.z * (R + h)
end
local function rw_refused(s, w, h, r) local x, y, z = rw(s, w, h); return BF.digRefused(x, y, z, r) ~= nil end
assert(rw_refused(RS.L / 2, 0, 0, 0.6), "a dig on the runway was allowed")
assert(rw_refused(RS.L / 2 + 40, 0, -4, 0.6), "a dig 4 m under the runway was allowed")
for _, s in ipairs({ 1.0, RS.L / 4, RS.L / 2, RS.L - 1.0 }) do
  assert(rw_refused(s, -edge - 1.0, 0, 0.6), "a dig 1 m off the runway's edge was allowed")
  assert(rw_refused(s, edge + 1.0, 0, 0.6), "a dig 1 m off the runway's north edge was allowed")
  assert(not rw_refused(s, -edge - BF.GUARD.margin - 1.0, 0, 0.6), "a dig 3 m off the runway's edge was refused")
end
assert(rw_refused(-1.0, 0, 0, 0.6) and not rw_refused(-BF.GUARD.margin - 1.5, 0, 0, 0.6), "the runway's end is not guarded right")
assert(refused(BF.PAD.u + 5, BF.PAD.v, -1, 0.6), "a dig under the pad was allowed")
assert(refused(50, 3.5 - 0.5, 0, 0.6), "a dig at the Command Centre's floor was allowed")
assert(not refused(120, 40, 0, 0.6), "a dig in open ground NE of the compound was refused")
assert(not refused(0, -10, -40, 2.0), "a dig 40 m under the apron (deep rock) was refused")
do
  local x, y, z = rw(RS.L / 2, 0, 0)
  local r, why = BF.digClamp(x, y, z, 3.0)
  assert(r == 0 and type(why) == "string" and why:find("foundations"), "digClamp on the runway: " .. tostring(r) .. " " .. tostring(why))
  x, y, z = rw(RS.L / 2, -edge - 3.0, 0)
  r = BF.digClamp(x, y, z, 3.0)
  assert(r > 0.8 and r < 1.2, string.format("a 3 m ball 3 m off the edge should shrink to ~1 m, got %.2f", r))
  local far = BF.digClamp(x + 1e5, y, z, 3.0)
  assert(far == 3.0, "a dig on another world was clamped")
end

-- the grade is checked once it has landed and recorded: a resume sends nothing
for _ = 1, 400 do time = time + TICK; BF.update({}, TICK) end
assert(STORE["base.graded"] == BF.LAYOUT_VERSION, "a grade that holds is recorded in the save")

-- ── session 2: reload; the ground holds, nothing is graded again ───────────
spawned, created, meshes = {}, {}, {}
planet.x, planet.y, planet.z = planet.x + 9000, planet.y - 400, planet.z + 2500
assert(session(), "the base never rebuilt in session 2")
assert(sculpts == sculpts1, "a reload re-graded ground that holds (" .. (sculpts - sculpts1) .. " ops)")
assert(STORE["base.x"] == hx and STORE["base.r"] == R, "a reload moved the base")
local n = 0
for _, s2 in ipairs(spawned) do if want[s2.name] then n = n + 1 end end
assert(n == #BF.FACILITIES, "session 2 rebuilt " .. n .. " structures")

-- ── session 3: an OLD save (layout 1) is laid out where it stands ──────────
for _, k in ipairs({ "base.r", "base.heading", "base.layout", "base.runway" }) do STORE[k] = nil end
local old = { x = 0.5, y = 0.5, z = -math.sqrt(0.5) }
STORE["base.x"], STORE["base.y"], STORE["base.z"] = old.x * 641.3, old.y * 641.3, old.z * 641.3
put_crew(old)
spawned, created, meshes = {}, {}, {}
assert(session(), "an old save's base never laid out")
local bx, by, bz = STORE["base.x"], STORE["base.y"], STORE["base.z"]
local bl = len(bx, by, bz)
assert((bx * old.x + by * old.y + bz * old.z) / bl > 0.999999, "an old save's base moved")
assert(STORE["base.layout"] == BF.LAYOUT_VERSION, "an old save was not upgraded to the new layout")

-- ── session 3b: the crew is far round the world when the ground needs
-- grading — it waits for them, then grades when they come home ──────────
do
  for _, k in ipairs({ "base.r", "base.heading", "base.layout", "base.runway" }) do STORE[k] = nil end
  local home = { x = STORE["base.x"], y = STORE["base.y"], z = STORE["base.z"] }
  local hl = len(home.x, home.y, home.z)
  local away = { x = -home.y / hl, y = home.x / hl, z = 0 }
  local al = len(away.x, away.y, away.z)
  away = { x = away.x / al, y = away.y / al, z = away.z / al }
  put_crew(away)
  spawned, created, meshes = {}, {}, {}
  local before = sculpts
  assert(session(), "a base with the crew away never stood")
  assert(sculpts == before, "graded with the crew " .. math.floor(planet.radius * 1.5) .. " m away")
  put_crew({ x = home.x / hl, y = home.y / hl, z = home.z / hl })
  for _ = 1, 400 do time = time + TICK; BF.update({}, TICK) end
  assert(sculpts > before + 100, "the grade never ran once the crew came home")
end

-- ── session 4: a hill under the pad — the grade must CUT it, not roof it ──
for _, k in ipairs({ "base.r", "base.heading", "base.layout", "base.runway" }) do STORE[k] = nil end
local hb = { x = STORE["base.x"], y = STORE["base.y"], z = STORE["base.z"] }
do
  local F4 = BF.frameOf(hb, 0, len(hb.x, hb.y, hb.z))
  local d = BF.dirAt(F4, 0, 125)
  HILL = { x = d.x, y = d.y, z = d.z, arc = 70, height = 14 }
end
graded, cutfill = {}, {}
spawned, created, meshes = {}, {}, {}
assert(session(), "the base on a hill never laid out")
do
  -- Either the fit turned the layout off the hill, or the grade cut it: the
  -- ground left above the grade anywhere on the paving is what counts.
  local F5 = BF.frameOf(hb, STORE["base.heading"], STORE["base.r"])
  local worst = 0
  for _, f in ipairs(BF.FACILITIES) do
    local d = BF.dirAt(F5, f.u, f.v)
    local hh = ground_r(d.x, d.y, d.z) - STORE["base.r"]
    if hh > 1.5 then
      worst = math.max(worst, hh)
    end
  end
  assert(worst == 0 or (cutfill.lower or 0) > 10,
    string.format("ground %.1f m over the grade on a lot, %d cuts", worst, cutfill.lower or 0))
  print(string.format("  hill: heading %.0f°, %d cuts, %d fills", math.deg(STORE["base.heading"]), cutfill.lower or 0, cutfill.raise or 0))
end
-- and a hill the layout cannot dodge: one under the whole site's north half
do
  for _, k in ipairs({ "base.r", "base.heading", "base.layout", "base.runway" }) do STORE[k] = nil end
  local d = BF.dirAt(BF.frameOf(hb, 0, len(hb.x, hb.y, hb.z)), 0, 40)
  HILL = { x = d.x, y = d.y, z = d.z, arc = 400, height = 30 }
  graded, cutfill = {}, {}
  spawned, created, meshes = {}, {}, {}
  assert(session(), "the base on a big hill never laid out")
  assert((cutfill.lower or 0) > 0 and (cutfill.raise or 0) > 0,
    string.format("a sloping site needs cut and fill (%d cuts, %d fills)", cutfill.lower or 0, cutfill.raise or 0))
  print(string.format("  slope: %d cuts, %d fills", cutfill.lower or 0, cutfill.raise or 0))
end
HILL = nil

-- ── session 5: a low plain just over the sea — graded SEA_MARGIN over it ──
-- (seed 1911564384's lowland stands 2–6 m over its sea: the plain must never
-- be graded down at the water, where a rover floats instead of driving.)
do
  local sea = planet.radius - 1.0          -- the ground is 0–2 m over the sea
  STORE["world." .. planet.name] = { sea = sea }
  for _, k in ipairs({ "base.r", "base.heading", "base.layout", "base.runway" }) do STORE[k] = nil end
  graded, cutfill = {}, {}
  spawned, created, meshes = {}, {}, {}
  assert(session(), "the base by the sea never laid out")
  local Rs = STORE["base.r"]
  assert(Rs >= sea + BF.SEA_MARGIN - 1e-9,
    string.format("the plain is graded %.2f m over the sea (want ≥ %.1f)", Rs - sea, BF.SEA_MARGIN))
  local low = math.huge
  for _, d in ipairs(graded) do low = math.min(low, d.R) end
  assert(#graded > 0 and low >= sea + BF.SEA_MARGIN - 1e-6,
    string.format("a flatten disc landed %.2f m over the sea", low - sea))
  -- a base already laid out keeps its radius, whatever the sea says now
  STORE["world." .. planet.name] = { sea = Rs + 2.0 }
  spawned, created, meshes = {}, {}, {}
  assert(session(), "the sea-side base did not come back")
  assert(STORE["base.r"] == Rs, "a sited base was regraded to a new sea")
  STORE["world." .. planet.name] = nil
  print(string.format("  by the sea: graded %.1f m over it (ground %.1f m over it)", Rs - sea, planet.radius - sea))
end

-- ── session 6: the ground is not there yet (a world still being made reads
-- as clamped air all the way down). The old 80-step march answered "the
-- ground is at r ≈ top − 430 m" and the spaceport was fitted hundreds of
-- metres under the surface; now the base waits for the ground. ────────────
do
  for _, k in ipairs({ "base.body", "base.x", "base.y", "base.z", "base.r", "base.heading", "base.layout", "base.runway", "base.graded" }) do STORE[k] = nil end
  put_crew(up0)
  STORE["world." .. planet.name] = { radius = planet.radius, relief = 40 }
  NOFIELD = true
  spawned, created, meshes = {}, {}, {}
  assert(not session(300), "sited on ground that is not there (" .. tostring(STORE["base.r"]) .. ")")
  assert(STORE["base.r"] == nil, "a radius was fitted to a field that is not there")
  NOFIELD = false
  for _ = 1, 6000 do time = time + TICK; BF.update({}, TICK); if BF.sited then break end end
  assert(BF.sited, "the base never sited once the ground came")
  assert(math.abs(STORE["base.r"] - planet.radius) < 2.0,
    string.format("graded to r %.1f on ground at r %.1f", STORE["base.r"], planet.radius))
  STORE["world." .. planet.name] = nil
  print(string.format("  no field yet: waited, then graded to r %.1f", STORE["base.r"]))
end

-- ── session 7: the engine keeps at most 4,096 edits waiting and drops the
-- rest; a grade bigger than that must be sent at its pace, none lost, and
-- the check waits until the queue has stayed empty. ──────────────────────
do
  local Q, CAP, PER_FRAME, peak, dropped, sent = 0, 4096, 40, 0, 0, 0
  local sculpt0, paint0 = terrain.sculpt, terrain.paint
  terrain.pending = function() return Q end
  terrain.sculpt = function(...)
    if Q >= CAP then dropped = dropped + 1; return 0 end
    Q = Q + 1; sent = sent + 1; peak = math.max(peak, Q); sculpt0(...); return sent
  end
  terrain.paint = function(...) if Q >= CAP then dropped = dropped + 1; return end; Q = Q + 1; paint0(...) end
  for _, k in ipairs({ "base.body", "base.x", "base.y", "base.z", "base.r", "base.heading", "base.layout", "base.runway", "base.graded" }) do STORE[k] = nil end
  put_crew(up0)
  local inflight0 = nil
  spawned, created, meshes = {}, {}, {}
  local env = setmetatable({}, { __index = _G })
  local chunk = assert(loadfile("solar/scripts/base_facilities.lua"))
  setfenv(chunk, env)
  chunk()
  BF = env
  BF.GRADE.inflight = 300                 -- a small window, so a ~1,500-op grade spans many frames
  env.start({})
  local checked_at_zero = true
  for _ = 1, 20000 do
    time = time + TICK
    Q = math.max(0, Q - PER_FRAME)
    env.update({}, TICK)
    if STORE["base.graded"] and Q > 0 then checked_at_zero = false end
    if env.sited then break end
  end
  assert(BF.sited, "the paced grade never finished")
  assert(dropped == 0, dropped .. " edits dropped by the engine's queue")
  assert(peak <= 300 + 1, "the grade kept " .. peak .. " edits waiting (window 300)")
  assert(STORE["base.graded"] == BF.LAYOUT_VERSION and checked_at_zero, "the grade was checked before it had landed")
  terrain.pending, terrain.sculpt, terrain.paint = nil, sculpt0, paint0
  print(string.format("  paced: %d ops, at most %d waiting, none dropped", sent, peak))
end

print(string.format("smoke_base OK — sliced (worst frame %d queries), %d structures, graded with %d ops, runway %.0f m %s, dish %.0f m from the centre",
  worst_frame, #BF.FACILITIES, sculpts1, S.L, n1 .. "/" .. n2, dish))
