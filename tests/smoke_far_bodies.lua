-- SMOKE HARNESS for far_bodies.lua — a far world drawn as one low-res mesh.
--
--   luajit solar/tests/smoke_far_bodies.lua
--
-- A stubbed engine with a home world under the camera, a moon at 18 radii and
-- a far planet at 150 radii. What it pins:
--  * the icosphere is the size it says: level 4 = 2 562 vertices and 5 120
--    triangles, level 5 = 10 242 / 20 480, one mesh.build per variant;
--  * building is time-sliced: no frame works out much more than `budget`
--    vertices, and a far world's mesh still arrives within a few hundred frames;
--  * the world under the camera never gets an impostor; the moon and the far
--    planet do, pulled toward the camera (shrunk to keep its size on screen)
--    so they are in front of the chunks, a pixel proud, fully opaque;
--  * a cold world (the engine draws its ball) gets the COVER mesh, every vertex
--    outside the ball; a resident one the TRUE mesh;
--  * the rules: fades in past nearRadii, out below minPixels, stays on when the
--    LOD anchor is far away (the map), refines when big or focused;
--  * the sea: ground under it is drawn at the sea's radius in the water colour;
--  * the per-save cache round-trips (and refuses a stale key), and a second
--    session reads it back instead of building;
--  * setActive(false) hides everything; a destroyed body is forgotten.

local T = 0.0
local API, store, files, logs = {}, {}, {}, {}
API.save = {
  get = function(k) return store[k] end,
  set = function(k, v) store[k] = v end,
  slot = function() return "slot5" end,
}
function API.print(m) logs[#logs + 1] = tostring(m) end
function API.vec3(x, y, z) return { x = x, y = y, z = z } end

-- noise: smooth, deterministic, about -1..1 (the real one is floptle-core's)
local fbm_calls = 0
local function noise(x, y, z, seed)
  seed = seed or 0
  local a = math.sin(x * 1.7 + seed * 0.13) * math.cos(y * 1.3 - seed * 0.21)
  local b = math.sin(z * 2.1 - seed * 0.07) * math.cos(x * 0.9 + y * 0.5)
  return math.max(-1, math.min(1, (a + b) * 0.5))
end
local M = setmetatable({}, { __index = math })
M.noise = function(...) return noise(...) end
M.fbm = function(x, y, z, oct, seed)
  fbm_calls = fbm_calls + 1
  return noise(x * 1.1, y * 0.9, z * 1.3, seed) * 0.8
end
API.math = M

local function make_rng(seed)
  local s = (seed or 12345) % 2147483647
  if s <= 0 then s = s + 2147483646 end
  local r = {}
  function r:next() s = (s * 16807) % 2147483647; return (s - 1) / 2147483646 end
  function r:range(a, b) return a + (b - a) * r:next() end
  return r
end
API.rng = make_rng

-- ── the world ───────────────────────────────────────────────────────────────
local HOME = { name = "Home", x = 0, y = 0, z = 0, radius = 830, soi = 9000 }
local MOON = { name = "Moon", x = 0, y = 0, z = -18 * 190, radius = 190, soi = 800 }
local FAR = { name = "Far", x = 150 * 700, y = 0, z = 0, radius = 700, soi = 8000 }
local STAR = { name = "Sun", x = 5e6, y = 0, z = 0, radius = 7000, soi = -1 }
local BODIES = { STAR, HOME, MOON, FAR }
API.space = { bodies = function() return BODIES end }

local function opts(R, relief, seed)
  return { radius = R, relief = relief, seed = seed, bumpFreq = 3,
    mountains = { height = relief * 2, scale = 4, sharpness = 2, coverage = 0.4, octaves = 4 },
    surfaceA = { slot = 16, color = { 0.8, 0.7, 0.5 } }, surfaceB = { slot = 13, color = { 0.6, 0.6, 0.6 } },
    iceCaps = { lat = 0.8, slot = 22, color = { 0.9, 0.95, 1 } },
    biomes = { { slot = 24, color = { 0.6, 0.6, 0.6 }, slope = { 30, 90 } } } }
end
local GEN = { GENSPEC = {
  Home = { opts = opts(800, 20, 11) },
  Moon = { opts = opts(183, 10, 22) },
  Far = { opts = opts(680, 60, 33) },
} }
store["world.Home"] = { radius = 800, relief = 40, seed = 11, sea = 798,
  water = { state = "liquid", deep = { 0.1, 0.3, 0.5 } } }
store["world.Moon"] = { radius = 183, relief = 20, seed = 22, sea = 0 }
store["world.Far"] = { radius = 680, relief = 120, seed = 33, sea = 0 }

-- nodes
local nodes, by_name, next_id = {}, {}, 1
local function mknode(name, parent)
  local n = { name = name, valid = true, id = next_id, parent = parent, visible = true, scale = 1 }
  next_id = next_id + 1
  function n:setMaterial(m) self.mat = m end
  function n:setWorldPos(v) self.x, self.y, self.z = v.x, v.y, v.z end
  nodes[#nodes + 1] = n
  by_name[name] = by_name[name] or n
  return n
end
for _, b in ipairs(BODIES) do mknode(b.name) end
-- home has air: a cloud deck at 0.35 of a 40 m atmosphere
function by_name.Home:getcomponent(kind)
  if kind == "CelestialBody" then return { atmoHeight = 40, atmoDensity = 1, cloudHeight = 0.35 } end
end
function API.find(name) return by_name[name] end
function API.createNode(name, parent, fn)
  local n = mknode(name, parent)
  if fn then fn(n) end
end
local function kids(of)
  local out = {}
  for _, n in ipairs(nodes) do if n.parent == of and n.valid then out[#out + 1] = n end end
  return out
end

-- meshes
local built, freed, mesh_id = {}, {}, 0
API.mesh = {
  build = function(t)
    assert(#t.positions % 3 == 0 and #t.indices % 3 == 0, "uneven lists")
    assert(#t.colors == #t.positions / 3 * 4, "a colour per vertex")
    for _, i in ipairs(t.indices) do assert(i >= 1 and i <= #t.positions / 3, "index in range") end
    for _, v in ipairs(t.positions) do assert(v == v and v < 1e9 and v > -1e9, "finite") end
    mesh_id = mesh_id + 1
    local name = "mesh:" .. mesh_id
    built[name] = t
    built[#built + 1] = name
    return name
  end,
  free = function(name) freed[name] = true; return true end,
}

-- camera: a pinhole at CAM looking at LOOK, 1280×720, 66° vertical
local CAM = { x = 0, y = 812, z = 0 }
local LOOK = MOON
local W, H, FOV = 1280, 720, 1.1519
local function norm(x, y, z) local l = math.sqrt(x * x + y * y + z * z); return x / l, y / l, z / l, l end
API.camera = {
  exists = function() return true end,
  screenSize = function() return W, H end,
  screenToRay = function(sx, sy)
    local fx, fy, fz = norm(LOOK.x - CAM.x, LOOK.y - CAM.y, LOOK.z - CAM.z)
    -- up: world y unless looking along it
    local ux, uy, uz = 0, 1, 0
    if math.abs(fy) > 0.95 then ux, uy, uz = 1, 0, 0 end
    local rx, ry, rz = norm(fy * uz - fz * uy, fz * ux - fx * uz, fx * uy - fy * ux)
    ux, uy, uz = ry * fz - rz * fy, rz * fx - rx * fz, rx * fy - ry * fx
    local F = (H / 2) / math.tan(FOV / 2)
    local a, b = (sx - W / 2) / F, -(sy - H / 2) / F
    local dx, dy, dz = norm(fx + rx * a + ux * b, fy + ry * a + uy * b, fz + rz * a + uz * b)
    return CAM.x, CAM.y, CAM.z, dx, dy, dz
  end,
}

local ANCHOR = nil
local RESIDENT = { Home = true, Moon = true }
API.terrain = {
  lodAnchor = function(...) if select("#", ...) > 0 then ANCHOR = ... end; return ANCHOR end,
  query = function(x, y, z)
    for _, b in ipairs(BODIES) do
      if RESIDENT[b.name] and math.abs(x - b.x) + math.abs(y - b.y) + math.abs(z - b.z) < 1 then return -b.radius * 0.5 end
    end
    return 50
  end,
}
API.assets = {
  readBytes = function(p) if files[p] then return files[p] end; return nil, "missing" end,
  writeBytes = function(p, s) files[p] = s; return true end,
}
API.os = os

local envs = {}
local function load_script(path, kind)
  local env = setmetatable({}, { __index = function(_, k)
    if k == "time" then return T end
    return API[k] or _G[k]
  end })
  local chunk = assert(loadfile(path))
  setfenv(chunk, env)
  chunk()
  env.params = {}
  for k, v in pairs(env.defaults or {}) do env.params[k] = v end
  envs[kind] = env
  return env
end
function API.findScript(kind) if kind == "system_generator" then return GEN end; return envs[kind] end

local fails = 0
local function check(ok, msg)
  if ok then print("ok   " .. msg) else print("FAIL " .. msg); fails = fails + 1 end
end

local fb = load_script("solar/scripts/far_bodies.lua", "far_bodies")

-- ── the rules, on their own ─────────────────────────────────────────────────
do
  local a1 = fb.decide(3 * 100, 3 * 100, 100, 300, false, true)
  local a2 = fb.decide(20 * 100, 20 * 100, 100, 50, false, true)
  local a3 = fb.decide(20 * 100, 20 * 100, 100, 1.0, false, true)
  local a4, l4 = fb.decide(4 * 100, 40 * 100, 100, 230, true, true)
  check(a1 == 0, "a world the camera is within 3 radii of keeps its chunks (alpha " .. a1 .. ")")
  check(a2 == 1, "a world 20 radii away is all impostor")
  check(a3 == 0, "a world a pixel across is left to the engine's dot")
  check(a4 == 1, "the map framing a world while detail stays with the ship: impostor however close")
  check(l4 == fb.params.focusLevel, "a focused world big on screen refines to the focus level")
  local _, lb = fb.decide(20 * 100, 20 * 100, 100, 120, false, true)
  check(lb == fb.params.bigLevel, "a world big on screen refines to bigLevel")
  local _, _, cov1 = fb.decide(20 * 100, 20 * 100, 100, 50, false, false)
  local _, _, cov2 = fb.decide(20 * 100, 20 * 100, 100, 50, false, true)
  local _, _, cov3 = fb.decide(20 * 100, 50 * 100, 100, 50, false, true)
  check(cov1 and not cov2 and cov3, "cover mesh where the engine draws its ball (cold, or past 42 radii of the anchor)")
  -- monotone fade: no step bigger than a few percent per tenth of a radius
  local worst, prev = 0, nil
  for k = 30, 140 do
    local a = fb.decide(k * 10, k * 10, 100, 200, false, true)
    if prev then worst = math.max(worst, math.abs(a - prev)) end
    prev = a
  end
  check(worst < 0.06, string.format("the cross-fade has no pop (largest step %.3f per 0.1 R)", worst))
end

-- ── a session: from the home surface, looking at the moon ───────────────────
local per_frame_worst = 0
local function frames(n)
  for _ = 1, n do
    T = T + 1 / 60
    fbm_calls = 0
    fb.lateUpdate(nil, 1 / 60)
    per_frame_worst = math.max(per_frame_worst, fbm_calls)
  end
end
frames(400)

local moon_imp = kids(by_name.Moon)[1]
local home_imp = kids(by_name.Home)[1]
local far_imp = kids(by_name.Far)[1]
check(moon_imp ~= nil and moon_imp.visible, "the moon at 18 radii has a visible impostor")
check(home_imp == nil or not home_imp.visible, "the world under the camera has none showing")
check(moon_imp and moon_imp.model and built[moon_imp.model] ~= nil, "the moon's impostor wears a built mesh")
local mt = moon_imp and built[moon_imp.model]
check(mt and #mt.positions == 2562 * 3 and #mt.indices == 5120 * 3,
  "level 4: 2 562 vertices, 5 120 triangles (" .. (mt and (#mt.positions / 3 .. "/" .. #mt.indices / 3) or "none") .. ")")
-- drawn nearer the camera (pulled toward it, shrunk to keep its size) and
-- proudPixels bigger on screen than the ground: ~554 px a radian here
local pull, proud_px = 0, 0
if moon_imp and moon_imp.x then
  local dc = math.sqrt((MOON.x - CAM.x) ^ 2 + (MOON.y - CAM.y) ^ 2 + (MOON.z - CAM.z) ^ 2)
  pull = math.sqrt((moon_imp.x - MOON.x) ^ 2 + (moon_imp.y - MOON.y) ^ 2 + (moon_imp.z - MOON.z) ^ 2)
  local toward = (moon_imp.x - MOON.x) * (CAM.x - MOON.x) + (moon_imp.y - MOON.y) * (CAM.y - MOON.y)
    + (moon_imp.z - MOON.z) * (CAM.z - MOON.z)
  if toward < 0 then pull = -pull end
  proud_px = (moon_imp.scale * dc / (dc - pull) - 1) * 183 * 554 / dc
end
check(pull > 0.3 * MOON.radius, string.format("pulled %.0f m toward the camera, in front of the chunks", pull))
check(math.abs(proud_px - fb.params.proudPixels) < 0.3,
  string.format("and the same size on screen, %.2f px proud", proud_px))
check(moon_imp and moon_imp.mat and moon_imp.mat.alpha == 1, "fully opaque at 18 radii")
-- vertices sit near the moon's radius
if mt then
  local lo, hi = math.huge, 0
  for i = 1, #mt.positions, 3 do
    local r = math.sqrt(mt.positions[i] ^ 2 + mt.positions[i + 1] ^ 2 + mt.positions[i + 2] ^ 2)
    lo, hi = math.min(lo, r), math.max(hi, r)
  end
  check(lo > 183 - 60 and hi < 183 + 60 and hi - lo > 1, string.format("the moon's ground spans r %.1f–%.1f", lo, hi))
end
-- the moon is resident: TRUE mesh (some vertex under the ball radius)
local moon_cover = false
if mt then
  for i = 1, #mt.positions, 3 do
    local r = math.sqrt(mt.positions[i] ^ 2 + mt.positions[i + 1] ^ 2 + mt.positions[i + 2] ^ 2)
    if r < MOON.radius then moon_cover = true end
  end
end
check(moon_cover, "a resident world draws its TRUE ground (some of it under the ball's radius)")
-- budget: 10 fbm-ish calls a vertex at most, budget vertices a frame
check(per_frame_worst <= fb.params.budget * 4 * 12,
  string.format("time-sliced: worst frame %d noise calls (budget %d vertices)", per_frame_worst, fb.params.budget))

-- the far planet: 300 radii, cold → cover mesh, every vertex outside its ball
LOOK = FAR
frames(400)
far_imp = kids(by_name.Far)[1]
local fm = far_imp and far_imp.model and built[far_imp.model]
check(far_imp ~= nil and far_imp.visible, "the far planet (150 radii, ~4 px) has an impostor")
local inside = 0
if fm then
  for i = 1, #fm.positions, 3 do
    local r = math.sqrt(fm.positions[i] ^ 2 + fm.positions[i + 1] ^ 2 + fm.positions[i + 2] ^ 2)
    if r < FAR.radius * 1.004 - 1e-6 then inside = inside + 1 end
  end
end
check(fm and inside == 0, "a cold world wears the COVER mesh: no vertex inside the engine's ball (" .. inside .. ")")

-- the map: camera 2.5 radii from the far planet, anchor on the crew at home
ANCHOR = { x = 0, y = 812, z = 0 }
CAM = { x = FAR.x, y = FAR.y + 2.5 * FAR.radius, z = FAR.z }
fb.focus("Far")
local t0 = T
local refined
for _ = 1, 3000 do
  frames(1)
  local m = far_imp.model and built[far_imp.model]
  if m and #m.positions >= 40962 * 3 then refined = T - t0; break end
end
check(far_imp.visible and far_imp.mat.alpha == 1, "the map framing it: the impostor stays on at 2.5 radii")
check(refined ~= nil, string.format("focused, it refines to level 6 (%s s of 60 fps frames)", refined and string.format("%.1f", refined) or "never"))

-- the sea: home seen from 12 radii
ANCHOR = nil
CAM = { x = 0, y = 0, z = -12 * 830 } -- 12 home radii out (the moon is only 4)
LOOK = HOME
fb.focus(nil)
frames(600)
home_imp = kids(by_name.Home)[1]
local hm = home_imp and home_imp.model and built[home_imp.model]
check(home_imp ~= nil and home_imp.visible, "home seen from 12 radii has an impostor")
local wet, dry_low = 0, 0
if hm then
  for i = 1, #hm.positions / 3 do
    local x, y, z = hm.positions[i * 3 - 2], hm.positions[i * 3 - 1], hm.positions[i * 3]
    local r = math.sqrt(x * x + y * y + z * z)
    if r < 798 - 1e-3 then dry_low = dry_low + 1 end
    local c = hm.colors
    if math.abs(r - 798) < 1e-3 and math.abs(c[i * 4 - 2] - 0.18) < 0.01 then wet = wet + 1 end
  end
end
check(hm and dry_low == 0, "nothing is drawn under the sea's surface")
local hpull = home_imp and home_imp.x and math.sqrt(home_imp.x ^ 2 + home_imp.y ^ 2 + home_imp.z ^ 2) or -1
check(hpull >= 0 and hpull <= 0.5 * 0.35 * 40 + 1e-6,
  string.format("on a world with air the pull stays under the cloud deck (%.1f m, deck at 14 m)", hpull))
check(wet > 0, "the sea is painted the water colour (" .. wet .. " vertices)")

-- the cache: round trip, a stale key refused, a second session reads it back
do
  local Hs, Cs = { 1.5, -3.25, 40.0 }, { 0.1, 0.2, 0.3, 1, 0, 0.5, 0.25, 0.75, 1 }
  local s = fb.encode("k1", Hs, Cs, 3)
  local H2, C2 = fb.decode(s, "k1", 3)
  local okh = H2 and math.abs(H2[1] - 1.5) < 0.01 and math.abs(H2[2] + 3.25) < 0.01 and math.abs(H2[3] - 40) < 0.01
  local okc = C2 and math.abs(C2[3] - 0.3) < 0.005 and math.abs(C2[6] - 0.5) < 0.005
  check(okh and okc, "cache encode/decode round-trips heights and colours")
  check(fb.decode(s, "k2", 3) == nil, "a cache made for another genspec is refused")
  local nfiles = 0
  for p in pairs(files) do if p:match("^user://farlod/slot5/") then nfiles = nfiles + 1 end end
  check(nfiles >= 3, "meshes are kept per save slot (" .. nfiles .. " files)")
  local fb2 = load_script("solar/scripts/far_bodies.lua", "far_bodies")
  fb = fb2
  for _, n in ipairs(nodes) do if n.name:match("^FarLOD") then n.valid = false end end
  CAM = { x = 0, y = 812, z = 0 }
  LOOK = MOON
  frames(60)
  check(fb.stats():match("cached [1-9]"), "a second session reads the meshes back: " .. fb.stats():sub(1, 60))
end

-- off, and a destroyed body
fb.setActive(false)
local any = false
for _, n in ipairs(nodes) do if n.name:match("^FarLOD") and n.valid and n.visible then any = true end end
check(not any, "setActive(false) hides every impostor")
fb.setActive(true)
by_name.Moon.valid = false
frames(70)
check(not fb.stats():match("Moon%["), "a destroyed body is forgotten")

if fails > 0 then
  print(fails .. " FAILED")
  os.exit(1)
end
print("all far_bodies checks passed")
