-- SMOKE HARNESS: THE BUILT HOME WORLD (homeGen 2) and its guaranteed finds.
--
-- The programme's Rare Finds are campaign goals, so a new save's home world is
-- built rather than rolled (system_generator HOME_GEN) and its rare finds are
-- topped up until every niche has its three (climate RARE_HOME_V). This drives
-- the real system_generator.lua and climate.lua with the engine's rng and
-- noise (xorshift32 and the hash-lattice value noise of floptle-core
-- noise.rs, reimplemented bit for bit in integer steps; the floats agree with
-- the engine's f32 to ~1e-5) and checks:
--
--   * THE GATING: a fresh save is homeGen 2 (written back), a save that has
--     played or already has a home roster is 1, a stored version is kept, and
--     scale 1 / 2 saves never have one;
--   * THE STREAMS: on every seed, homeGen 2 changes the home world only —
--     every other body (planets, moons, orbits, air, terrain seeds) is the
--     world homeGen 1 rolls;
--   * HABITABLE: air, a liquid sea, rivers, lakes asked for, a mild climate —
--     on seed 1815586866 too, whose rolled home (Solmiver) is airless;
--   * LATITUDE: the ground the opts make (homeHeight, the generator's own
--     relief formula) stands high over both polar caps with peaks above the
--     snow line, and low over the equatorial band; several long ravines and
--     overhangs are always on;
--   * THE BASE SITE: published on the equatorial plain, and kept;
--   * THE GUARANTEE: on a world with no lakes, rivers or shelters, the top-up
--     pass still gives every niche its three (forced), and three geode
--     pockets, never on the base's ground and never moving a plant already
--     placed; where edits are allowed a cave plant gets a grotto dug for it,
--     with rock over it.
--
--   luajit solar/tests/smoke_homeworld.lua

local bit = require("bit")
local failed, count = 0, 0
local function check(desc, ok, detail)
  count = count + 1
  if not ok then
    failed = failed + 1
    print("✗ " .. desc .. (detail ~= nil and ("   [" .. tostring(detail) .. "]") or ""))
  end
end

-- ── the engine's rng(seed) and noise ────────────────────────────────────────
local M32 = 4294967296
local function U32(x) return x % M32 end
local function rng(seed)
  local st = U32(math.floor(seed or 1))
  if st == 0 then st = 0x9E3779B9 end
  local function nxt()
    local x = bit.tobit(st)
    x = bit.bxor(x, bit.lshift(x, 13))
    x = bit.bxor(x, bit.rshift(x, 17))
    x = bit.bxor(x, bit.lshift(x, 5))
    st = U32(x)
    return st
  end
  local r = { seed = seed }
  function r:next() return math.floor(nxt() / 256) / 16777216 end
  function r:range(a, b) return a + (b - a) * self:next() end
  function r:int(a, b)
    local lo, hi = math.min(a, b), math.max(a, b)
    return lo + nxt() % (hi - lo + 1)
  end
  function r:pick(list) return list[self:int(1, #list)] end
  return r
end
local function mul32(a, b)
  local al, ah = a % 65536, math.floor(a / 65536)
  return (al * b + ((ah * b) % 65536) * 65536) % M32
end
local function xr(h, s) return U32(bit.bxor(bit.tobit(h), bit.rshift(bit.tobit(h), s))) end
local function hash(seed, x, y, z)
  local h = U32(mul32(seed, 0x9E3779B9) + mul32(U32(x), 0x85EBCA6B) + mul32(U32(y), 0xC2B2AE35) + mul32(U32(z), 0x27D4EB2F))
  h = xr(h, 15); h = mul32(h, 0x2C1B3C6D); h = xr(h, 12); h = mul32(h, 0x297A2D39); h = xr(h, 15)
  return h / M32 * 2 - 1
end
local floor = math.floor
local function value(x, y, z, seed)
  seed = U32(floor(seed or 0))
  local bx, by, bz = floor(x), floor(y), floor(z)
  local fx, fy, fz = x - bx, y - by, z - bz
  local sx, sy, sz = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy), fz * fz * (3 - 2 * fz)
  local function c(dx, dy, dz) return hash(seed, bx + dx, by + dy, bz + dz) end
  local function l(a, b, t) return a + (b - a) * t end
  return l(l(l(c(0, 0, 0), c(1, 0, 0), sx), l(c(0, 1, 0), c(1, 1, 0), sx), sy),
           l(l(c(0, 0, 1), c(1, 0, 1), sx), l(c(0, 1, 1), c(1, 1, 1), sx), sy), sz)
end
local function fbm(x, y, z, oct, seed)
  oct = math.max(1, math.min(10, floor(oct or 4)))
  local amp, sum, norm = 1, 0, 0
  for i = 0, oct - 1 do
    local o = i * 19.19
    sum = sum + value(x + o, y + o, z + o, seed) * amp
    norm = norm + amp
    amp = amp * 0.5
    x, y, z = (0.36 * x - 0.80 * y + 0.48 * z) * 2.03, (0.80 * x + 0.52 * y + 0.30 * z) * 2.03,
              (-0.48 * x + 0.30 * y + 0.82 * z) * 2.03
  end
  return sum / norm
end
-- Spot values the engine's math.noise / math.fbm gave (rc3, bench probe).
check("the noise port matches the engine (value)", math.abs(value(0.1, 0.2, 0.3, 7) - (-0.616469622)) < 1e-5,
  value(0.1, 0.2, 0.3, 7))
check("the noise port matches the engine (fbm)", math.abs(fbm(-3.7, 12.2, 5.5, 3, 123456789) - 0.137829855) < 1e-5,
  fbm(-3.7, 12.2, 5.5, 3, 123456789))

-- ── the generator, against stubs ────────────────────────────────────────────
local store = {}
local nodes = {}
local function mknode(name)
  local n = { name = name, valid = true, tags = {}, x = 0, y = 0, z = 0 }
  function n:setTerrain(id) self.terrainId = id end
  function n:setTerrainGen(o) self.gen = o end
  function n:setCelestial(c) self.cel = c end
  function n:setPrimitive() end
  function n:setMaterial() end
  function n:destroy() self.valid = false end
  nodes[#nodes + 1] = n
  return n
end
local gmath = setmetatable({ noise = value, fbm = fbm }, { __index = math })
local env = setmetatable({
  rng = rng, math = gmath,
  save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end },
  print = function() end, log = function() end,
  terrain = { generatePlanet = function() end },
  createNode = function(name, a, b)
    local fn = type(a) == "function" and a or b
    local n = mknode(name)
    if fn then fn(n) end
    return n
  end,
  spawn = function(_, _, fn) local n = mknode("spawned") if fn then fn(n) end return n end,
  find = function() return nil end,
  findTagged = function(tag)
    local out = {}
    for _, n in ipairs(nodes) do
      if n.valid then for _, t in ipairs(n.tags or {}) do if t == tag then out[#out + 1] = n end end end
    end
    return out
  end,
  space = { time = function() return 0 end },
  vec3 = function(x, y, z) return { x = x, y = y, z = z } end,
}, { __index = _G })
local chunk = assert(loadfile("solar/scripts/system_generator.lua"))
setfenv(chunk, env)
chunk()

-- ── 1. the gating ───────────────────────────────────────────────────────────
check("the current home recipe is 2", env.HOME_GEN == 2)
store = {}
check("a fresh scale-3 save builds its home world", env.homeGenFor({ scale = 3 }) == 2 and store.g_homeGen == 2,
  store.g_homeGen)
store = { g_played = 12 }
check("a save that has played keeps the rolled home", env.homeGenFor({ scale = 3 }) == 1 and store.g_homeGen == 1)
store = { ["system.home"] = { bodies = {} } }
check("…so does one that already has a home roster", env.homeGenFor({ scale = 3 }) == 1)
store = { ["base.body"] = "Kaolun" }
check("…or a base", env.homeGenFor({ scale = 3 }) == 1)
store = { g_homeGen = 2, g_played = 50 }
check("a stored recipe is kept, whatever else the save holds", env.homeGenFor({ scale = 3 }) == 2)
store = { g_homeGen = 1 }
check("…a stored 1 too", env.homeGenFor({ scale = 3 }) == 1)
store = {}
check("scale 2 never has one", env.homeGenFor({ scale = 2 }) == 1 and store.g_homeGen == nil)
check("…nor scale 1", env.homeGenFor({ scale = 1 }) == 1 and store.g_homeGen == nil)
check("an explicit recipe wins", env.homeGenFor({ scale = 3, homeGen = 1 }) == 1)

local function regen(seed, hg)
  store, nodes = {}, {}
  env.regenerate(seed, { scale = 3, pregen = true, homeGen = hg })
  local bodies = {}
  for _, n in ipairs(nodes) do
    if n.valid and n.gen and n.cel then bodies[n.name] = { gen = n.gen, cel = n.cel } end
  end
  local s = {}
  for k, v in pairs(store) do s[k] = v end
  return s, bodies
end

-- ── 2. the streams, 3. habitable, 4. latitude, 5. the site ─────────────────
local SEEDS = { 1815586866, 1911564384, 31337, 424242, 777001, 7 }
local function dirs(n)
  local out, ga = {}, math.pi * (3 - math.sqrt(5))
  for i = 0, n - 1 do
    local y = 1 - (i + 0.5) / n * 2
    local rr = math.sqrt(1 - y * y)
    out[#out + 1] = { math.cos(ga * i) * rr, y, math.sin(ga * i) * rr, lat = math.deg(math.asin(y)) }
  end
  return out
end
local D = dirs(2000)
for _, seed in ipairs(SEEDS) do
  local s1, b1 = regen(seed, 1)
  local s2, b2 = regen(seed, 2)
  local h1, h2 = s1["system.home"], s2["system.home"]
  local home = h2.bodies[1].name
  check(seed .. ": the home world keeps its name, size and orbit", h1.bodies[1].name == home
    and h1.bodies[1].radius == h2.bodies[1].radius and h1.bodies[1].a == h2.bodies[1].a
    and h1.bodies[1].mu == h2.bodies[1].mu)
  check(seed .. ": the same bodies roll", #h1.bodies == #h2.bodies and h1.star == h2.star)
  local same = true
  for i = 2, #h1.bodies do
    local a, b = h1.bodies[i], h2.bodies[i]
    local ga, gb = b1[a.name], b2[b.name]
    if not (a.name == b.name and a.radius == b.radius and a.a == b.a and a.mu == b.mu and a.atmo == b.atmo
      and a.kind == b.kind and ga and gb and ga.gen.seed == gb.gen.seed and ga.gen.relief == gb.gen.relief
      and ga.cel.e == gb.cel.e and ga.cel.m0 == gb.cel.m0) then
      same = false
    end
  end
  check(seed .. ": every other body is the world the rolled recipe makes", same)

  local w = s2["world." .. home]
  local o = b2[home].gen
  local c = b2[home].cel
  check(seed .. ": the home world has air", (w.atmo or 0) >= 0.6 and (c.atmoHeight or 0) >= o.radius * 0.25
    and c.atmoHeight <= o.radius * 0.45, w.atmo)
  check(seed .. ": …a liquid sea", w.water and w.water.state == "liquid" and (w.sea or 0) > o.radius - o.relief, w.sea)
  check(seed .. ": …a mild climate", (w.climTemp or 0) > 0.5 and w.climTemp < 0.75 and (w.climMoist or 0) >= 0.6,
    w.climTemp)
  check(seed .. ": …rivers, and lakes asked for", o.rivers and o.rivers.count >= 5 and w.hydro == true
    and env.GENSPEC[home] and env.GENSPEC[home].wet, o.rivers and o.rivers.count)
  check(seed .. ": …several long ravines", o.ravines and o.ravines.count >= 5 and o.ravines.length >= o.radius * 1.1
    and o.ravines.depth >= 20, o.ravines and o.ravines.count)
  check(seed .. ": …overhangs", o.overhangs and o.overhangs.strength >= 3, o.overhangs and o.overhangs.strength)
  check(seed .. ": …polar ranges", o.mountains and o.mountains.height >= o.radius * 0.1)
  check(seed .. ": the world record says it is the built home", w.shape and w.shape.home == 2 and w.geo.home == true)
  local snowRule, latRule = false, false
  for _, r in ipairs(o.biomes or {}) do
    if r.altitude and r.altitude[1] == w.shape.snowline then snowRule = true end
    if r.latitude and r.latitude[2] == 90 then latRule = true end
  end
  check(seed .. ": snow above the snow line, glacier at the poles", snowRule and latRule)
  check(seed .. ": the subsoil stays under the overhangs' reach", o.subsoilDepth >= o.overhangs.strength + o.voxel)
  check(seed .. ": the occluder is under the caves", c.occluderRadius < o.radius - o.caveDepth)
  -- Latitude: the ground the opts make.
  local cap = { { n = 0, s = 0, mx = -1e9 }, { n = 0, s = 0, mx = -1e9 } }
  local eq, eqHigh, eqs = { n = 0, s = 0 }, 0, {}
  for _, d in ipairs(D) do
    local h = env.homeHeight(o, d[1], d[2], d[3])
    if math.abs(d.lat) > 62 then
      local k = d.lat > 0 and 1 or 2
      cap[k].n, cap[k].s, cap[k].mx = cap[k].n + 1, cap[k].s + h, math.max(cap[k].mx, h)
    elseif math.abs(d.lat) < 30 then
      eq.n, eq.s = eq.n + 1, eq.s + h
      eqs[#eqs + 1] = h
      if h > w.shape.snowline then eqHigh = eqHigh + 1 end
    end
  end
  table.sort(eqs)
  local eqMean, eqP90 = eq.s / eq.n, eqs[math.floor(#eqs * 0.9)]
  for k, nm in ipairs({ "north", "south" }) do
    local m = cap[k].s / cap[k].n
    check(string.format("%d: the %s cap is mountainous (mean %.0f m vs the equator's %.1f)", seed, nm, m, eqMean),
      m >= 20 and m >= eqMean * 4)
    check(string.format("%d: …with peaks above the snow line (%.0f m > %.0f m)", seed, cap[k].mx, w.shape.snowline),
      cap[k].mx >= w.shape.snowline + 15)
  end
  check(string.format("%d: the equatorial band is lowland (p90 %.1f m, %.1f%% above the snow line)", seed, eqP90,
    100 * eqHigh / eq.n), eqP90 <= o.mountains.height * 0.15 and eqHigh / eq.n <= 0.02)
  -- The base site.
  local site = s2["home.site"]
  check(seed .. ": a base site is published", env.lastBaseDir and site and site.seed == o.seed and site.v == env.HOME_GEN)
  if site then
    check(string.format("%d: …on the equatorial plain (lat %.0f, ±%.1f m)", seed, site.lat, site.dev),
      math.abs(site.lat) <= 12.5 and site.dev >= 0 and site.dev <= 6 and site.h > w.shape.seaAlt + 4)
  end
  -- The rolled recipe still rolls what it always did.
  local w1 = s1["world." .. home]
  check(seed .. ": homeGen 1 is the rolled world", not (w1.shape and w1.shape.home) and env.lastHomeGen == 2)
  if seed == 1815586866 then
    check("1815586866: the ROLLED home is the airless one the save would have had", (w1.atmo or 0) == 0, w1.atmo)
  end
end
-- A save keeps its base site once picked.
do
  store, nodes = {}, {}
  env.regenerate(31337, { scale = 3, pregen = true })
  local site = store["home.site"]
  site.x, site.y, site.z = 0, 0, 1   -- as if picked by an earlier build
  nodes = {}
  env.regenerate(31337, { scale = 3, pregen = true })
  check("a save keeps the base site it was given", env.lastBaseDir and env.lastBaseDir[3] == 1)
  check("…and the recipe it was made with", store.g_homeGen == 2)
end

-- ── 6. the guarantee ────────────────────────────────────────────────────────
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local function norm(x, y, z) local l = len(x, y, z) return x / l, y / l, z / l end
local cl
do
  local cenv = setmetatable({
    save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end },
    log = function() end, rng = rng, math = gmath,
    space = { body = function() return nil end, dominant = function() return nil end },
    findScript = function() return nil end,
  }, { __index = _G })
  local cc = assert(loadfile("solar/scripts/climate.lua"))
  setfenv(cc, cenv)
  cc()
  cenv.params = {}
  for k, v in pairs(cenv.defaults or {}) do cenv.params[k] = v end
  cl = cenv
end
store = { ["system.home"] = { bodies = { { name = "Homey" }, { name = "Moony" } } } }
check("the home world is the roster's first planet", cl.homeWorldName() == "Homey")

-- A dull world: rolling ground, one ravine with steep walls, no lakes, no
-- rivers, no sea, no shelters.
local R = 600
local RA, RB = { norm(0.6, -0.2, 1) }, { norm(-0.7, -0.3, 0.8) }
local function ang(a, ux, uy, uz) return math.acos(math.max(-1, math.min(1, a[1] * ux + a[2] * uy + a[3] * uz))) * R end
local function arc_dist(ux, uy, uz)
  local best = 1e9
  for i = 0, 60 do
    local t = i / 60
    local x, y, z = norm(RA[1] + (RB[1] - RA[1]) * t, RA[2] + (RB[2] - RA[2]) * t, RA[3] + (RB[3] - RA[3]) * t)
    best = math.min(best, ang({ x, y, z }, ux, uy, uz))
  end
  return best
end
local function smooth(t) t = math.max(0, math.min(1, t)) return t * t * (3 - 2 * t) end
local function ground(ux, uy, uz)
  local g = R + 5 * math.sin(ux * 6) * math.cos(uz * 5) + 3 * math.sin(uy * 7)
  g = g - 22 * (1 - smooth((arc_dist(ux, uy, uz) - 8) / 2.5))
  return g
end
local dug = {}
local function sdf(x, y, z)
  local r = len(x, y, z)
  local ux, uy, uz = x / r, y / r, z / r
  local d = (r - ground(ux, uy, uz)) * 0.6
  for _, s in ipairs(dug) do d = math.max(d, s[4] - len(x - s[1], y - s[2], z - s[3])) end
  return math.max(-6, math.min(6, d))
end
local pts = {}
for i = 0, 40 do
  local x, y, z = norm(RA[1] + (RB[1] - RA[1]) * i / 40, RA[2] + (RB[2] - RA[2]) * i / 40, RA[3] + (RB[3] - RA[3]) * i / 40)
  pts[#pts + 1], pts[#pts + 2], pts[#pts + 3] = x * R, y * R, z * R
end
local wids = {}
for i = 1, 41 do wids[i] = 16 end
local hydro = { rivers = { { river = false, depth = 22, points = pts, widths = wids } }, lakes = {} }
local W = { radius = R, seed = 777, sea = 0, atmo = 0.7, relief = 10,
            shape = { peak = 12, low = 30, layers = { overhangs = true, ravines = true } } }
local AV = { x = 0, y = R, z = 0, r = 200 }   -- the base, at the north pole here

local function drive(sc)
  local st, n = "running", 0
  repeat st = sc.step(5000); n = n + 1 until st ~= "running" or n > 100000
  return st
end
local function counts(plants)
  local c = {}
  for _, p in ipairs(plants) do c[p.niche] = (c[p.niche] or 0) + 1 end
  return c
end

local first = cl.rareScan(W, hydro, sdf, { avoid = AV })
check("the dull world's scan finishes", drive(first) == "done", first.why)
local d = first.result
local c0 = counts(d.plants)
check("…and comes up short (no lakes, rivers or shelters)", (c0.lake or 0) == 0 and (c0.river or 0) == 0
  and (c0.cave or 0) == 0, string.format("lake %d river %d cave %d", c0.lake or 0, c0.river or 0, c0.cave or 0))
local before = {}
for i, p in ipairs(d.plants) do before[i] = { p.niche, p.x, p.y, p.z } end

local function topup(dig)
  local sc = cl.rareScan(W, hydro, sdf, { rules = cl.RARE_RELAXED, have = d, fallback = true, caves = true,
    avoid = AV, ores = cl.RARE_HOME_ORES, dig = dig })
  local st = drive(sc)
  return sc, st
end

-- 6a. an OLD save: placement only.
local sc, st = topup(nil)
check("the top-up finishes", st == "done", sc.why)
if os.getenv("HOME_DEBUG") then print("old save forced: " .. table.concat(sc.forced or {}, ", ")) end
local all = {}
for _, p in ipairs(d.plants) do all[#all + 1] = p end
for _, p in ipairs(sc.result.plants) do all[#all + 1] = p end
local c = counts(all)
for _, n in ipairs(cl.RARE_NICHES) do
  check("old save: " .. n .. " has its three", (c[n] or 0) >= cl.RARE_HOME_KEEP, c[n] or 0)
end
check("old save: three geode pockets at least", #d.ores + #sc.result.ores >= cl.RARE_HOME_ORES, #d.ores + #sc.result.ores)
check("old save: no grotto dug", (sc.dug or 0) == 0 and #dug == 0)
local forcedCave = 0
for _, p in ipairs(sc.result.plants) do
  check("a topped-up plant is new, not a moved one", p.forced ~= nil or p.s ~= nil)
  if p.niche == "cave" and p.forced == "wallfoot" then forcedCave = forcedCave + 1 end
  local gl = len(p.x, p.y, p.z)
  check("…standing on the ground", math.abs(gl - ground(p.x / gl, p.y / gl, p.z / gl)) < 0.6,
    string.format("%s %.2f", p.niche, gl - ground(p.x / gl, p.y / gl, p.z / gl)))
  check("…off the base's ground", len(p.x - AV.x, p.y - AV.y, p.z - AV.z) >= AV.r)
end
check("old save: the cave plants stand at the foot of the ravine wall", forcedCave >= 3, forcedCave)
local apart = true
for i = 1, #all do
  for j = i + 1, #all do
    local p, q = all[i], all[j]
    if len(p.x - q.x, p.y - q.y, p.z - q.z) < 25 then
      apart = false
      if os.getenv("HOME_DEBUG") then print("close:", p.niche, p.forced, q.niche, q.forced, len(p.x - q.x, p.y - q.y, p.z - q.z)) end
    end
  end
end
check("no two rare plants share a spot, whatever their niches", apart)
for _, o in ipairs(sc.result.ores) do
  check("a topped-up pocket is in solid rock", sdf(o.x, o.y, o.z) <= -1)
end
local unchanged = #d.plants == #before
for i, p in ipairs(d.plants) do
  local b = before[i]
  if not (b and b[1] == p.niche and b[2] == p.x and b[3] == p.y and b[4] == p.z) then unchanged = false end
end
check("nothing already placed moves", unchanged)
local sc2 = topup(nil)
local same = #sc2.result.plants == #sc.result.plants
for i, p in ipairs(sc2.result.plants) do
  local q = sc.result.plants[i]
  if not (q and q.x == p.x and q.y == p.y and q.z == p.z and q.niche == p.niche) then same = false end
end
check("the top-up is deterministic", same)

-- 6b. a NEW save: a grotto for each cave plant.
local digs = 0
local sc3, st3 = topup(function(x, y, z, r) digs = digs + 1; dug[#dug + 1] = { x, y, z, r } end)
check("new save: the top-up finishes", st3 == "done", sc3.why)
if os.getenv("HOME_DEBUG") then print("new save forced: " .. table.concat(sc3.forced or {}, ", ") .. " digs " .. digs) end
local grottoes = 0
for _, p in ipairs(sc3.result.plants) do
  if p.niche == "cave" and p.forced == "grotto" then
    grottoes = grottoes + 1
    local l = len(p.x, p.y, p.z)
    local ux, uy, uz = p.x / l, p.y / l, p.z / l
    local roof = false
    for h = 1.5, 8, 0.5 do if sdf(ux * (l + h), uy * (l + h), uz * (l + h)) < 0 then roof = true end end
    check("…a grotto plant has rock over it", roof)
    check("…and stands on the grotto floor", math.abs(sdf(p.x, p.y, p.z)) < 0.3, sdf(p.x, p.y, p.z))
    check("…open to the ravine", sdf(p.x + ux * 1, p.y + uy * 1, p.z + uz * 1) > 0.3)
  end
end
check("new save: three grottoes dug for the cave plants", grottoes >= 3 and (sc3.dug or 0) >= 3 and digs >= 6,
  string.format("%d grottoes, %d digs", grottoes, digs))

if failed == 0 then
  print(string.format("✓ home world: %d checks — gated per save, other worlds untouched, habitable with polar ranges and an equatorial plain on %d seeds, every niche and three geodes guaranteed", count, #SEEDS))
  os.exit(0)
else
  print(string.format("✗ %d of %d checks failed", failed, count))
  os.exit(1)
end
