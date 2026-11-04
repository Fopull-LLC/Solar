-- SMOKE HARNESS: AN ALIEN HOME WORLD (the new-save panel's "Home world" choice).
--
-- A save made with `g_homeKind = "alien"` rolls its home planet from the
-- geology catalogue (system_generator alienHomeWorld) from its own home seed,
-- instead of the built Earth-like world. This drives the real
-- system_generator.lua with the engine's rng and noise (the port from
-- smoke_homeworld.lua) and checks:
--
--   * THE DEFAULT: a save with no home kind is the built home (homeGen 2),
--     writes no home-kind keys, and rolls exactly what an explicit "earth" does;
--   * THE ROLL: an alien home is one of ALIEN_TYPES, has air, gravity in the
--     ALIEN_G band, a radius in the save's range, and no built-home markers (no
--     base site published: game_manager's dry-site search sites it);
--   * THE SEED: the same home seed is the same world (twice, and in another
--     galaxy); different seeds give different worlds; a missing seed is taken
--     from the terrain stream and kept;
--   * FEATURES: homeFeatures says what the world has (all on the built home),
--     and bodiesWith which other worlds of the system have a feature.
--
--   luajit solar/tests/smoke_alien_home.lua


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

-- A new save as the panel makes it (scale 4), with `extra` keys set first.
local function regen(seed, extra)
  store, nodes = {}, {}
  for k, v in pairs(extra or {}) do store[k] = v end
  env.regenerate(seed, { scale = 4, pregen = true })
  local bodies = {}
  for _, n in ipairs(nodes) do
    if n.valid and n.gen and n.cel then bodies[n.name] = { gen = n.gen, cel = n.cel } end
  end
  local s = {}
  for k, v in pairs(store) do s[k] = v end
  return s, bodies
end
local function homeOf(s, b)
  local h = s["system.home"]
  local name = h.bodies[1].name
  return name, s["world." .. name], b[name].gen, b[name].cel
end
local ALIEN = {}
for _, t in ipairs(env.ALIEN_TYPES) do ALIEN[t[1]] = true end
local function same_world(o1, c1, o2, c2)
  return o1.seed == o2.seed and o1.radius == o2.radius and o1.relief == o2.relief and o1.bumpFreq == o2.bumpFreq
    and c1.mu == c2.mu and c1.atmoDensity == c2.atmoDensity and c1.atmoHeight == c2.atmoHeight
end

-- ── 1. the default ──────────────────────────────────────────────────────────
check("the kind of a save with none is earth", env.homeKindFor({ scale = 4 }) == "earth")
check("…and of scale 2, whatever it says", env.homeKindFor({ scale = 2, homeKind = "alien", homeSeed = 5 }) == "earth")
local GAL = { 1911564384, 31337, 777001 }
for _, gs in ipairs(GAL) do
  local s0, b0 = regen(gs)
  local s1, b1 = regen(gs, { g_homeKind = "earth" })
  local n0, w0, o0, c0 = homeOf(s0, b0)
  local n1, w1, o1, c1 = homeOf(s1, b1)
  check(gs .. ": a default save writes no home-kind keys", s0.g_homeKind == nil and s0.g_homeSeed == nil)
  check(gs .. ": …and builds the Earth-like home", w0.shape and w0.shape.home == 2 and w0.geo.home == true
    and env.lastHomeKind == "earth" or false)
  check(gs .. ": an explicit earth is the same world", n0 == n1 and same_world(o0, c0, o1, c1))
  local f = env.homeFeatures(n0)
  check(gs .. ": the built home has every feature", f and f.kind == "earth" and f.air and f.breathable ~= false and f.sea
    and f.rivers and f.ravines and f.caves and f.overhangs and f.mountains and f.flora, f and f.type)
end

-- ── 2. the roll, 3. the seed ────────────────────────────────────────────────
local HSEEDS = { 1, 42, 1234567, 987654321, 55555, 31415926, 2718281, 600613, 8, 99 }
local seen = {}
local types = {}
for _, hs in ipairs(HSEEDS) do
  local s, b = regen(GAL[1], { g_homeKind = "alien", g_homeSeed = hs })
  local name, w, o, c = homeOf(s, b)
  local g = c.mu / (o.radius * o.radius)
  types[#types + 1] = w.geo.type
  check(hs .. ": an alien home is an alien type (" .. tostring(w.geo.type) .. ")", ALIEN[w.geo.type] == true and w.geo.home == nil)
  check(hs .. ": …has air", (w.atmo or 0) >= env.ALIEN_AIR[1] - 1e-9 and (c.atmoHeight or 0) > 0, w.atmo)
  check(string.format("%d: …gravity %.2f in the band", hs, g), g >= env.ALIEN_G[1] - 1e-9 and g <= env.ALIEN_G[2] + 1e-9)
  check(hs .. ": …a radius in the save's range", o.radius >= 600 and o.radius <= 950, o.radius)
  check(hs .. ": …not the built home (no site published, the search sites it)", (w.shape == nil or w.shape.home == nil)
    and env.lastBaseDir == nil and env.homeSitePending == false and env.lastHomeKind == "alien")
  check(hs .. ": …its body is as big as its ground", c.bodyRadius > o.radius and c.occluderRadius < o.radius - o.caveDepth
    and c.soi > c.bodyRadius * 4)
  check(hs .. ": …keeps its home kind and seed", s.g_homeKind == "alien" and s.g_homeSeed == hs)
  local f = env.homeFeatures(name)
  check(hs .. ": homeFeatures says alien", f and f.kind == "alien" and f.air == true and f.type == w.geo.type)
  check(hs .. ": …and nothing built-home-only unless rolled", f and f.ravines == (o.ravines ~= nil) and f.rivers == (o.rivers ~= nil))
  local bw = env.bodiesWith("ravines")
  local bwok = type(bw) == "table"
  for _, nm in ipairs(bw or {}) do if nm == name or not env.homeFeatures(nm).ravines then bwok = false end end
  check(hs .. ": bodiesWith names only other worlds that have it", bwok)
  local s2, b2 = regen(GAL[1], { g_homeKind = "alien", g_homeSeed = hs })
  local _, _, o2, c2 = homeOf(s2, b2)
  check(hs .. ": the same seed regenerates the same world", same_world(o, c, o2, c2))
  local s3, b3 = regen(GAL[2], { g_homeKind = "alien", g_homeSeed = hs })
  local _, w3, o3, c3 = homeOf(s3, b3)
  check(hs .. ": …in another galaxy too", same_world(o, c, o3, c3) and w3.geo.type == w.geo.type)
  seen[o.seed] = (seen[o.seed] or 0) + 1
end
local distinct = 0
for _ in pairs(seen) do distinct = distinct + 1 end
check("different seeds give different worlds", distinct == #HSEEDS, distinct)
local tset, nt = {}, 0
for _, t in ipairs(types) do if not tset[t] then tset[t] = true; nt = nt + 1 end end
check("…of several types (" .. table.concat(types, ", ") .. ")", nt >= 4, nt)

-- a missing seed: taken from the terrain stream, kept, and the same next time
local s4, b4 = regen(GAL[1], { g_homeKind = "alien" })
local _, w4, o4, c4 = homeOf(s4, b4)
check("an alien save without a seed keeps one", type(s4.g_homeSeed) == "number" and s4.g_homeSeed > 0, s4.g_homeSeed)
local s5, b5 = regen(GAL[1], { g_homeKind = "alien", g_homeSeed = s4.g_homeSeed })
local _, _, o5, c5 = homeOf(s5, b5)
check("…which regenerates the same world", same_world(o4, c4, o5, c5))

-- ── names: the whole-name list (g_names 2, new galaxies only) ──────────────
do
  local function names_of(s)
    local out, list = {}, {}
    for _, b in ipairs(s["system.home"].bodies) do out[b.name] = true; list[#list + 1] = b.name end
    return out, list
  end
  local isList = {}
  for _, n in ipairs(env.NAMES) do isList[n] = true end
  local sa, ba = regen(GAL[1])
  local sb, bb = regen(GAL[1], { g_names = 2 })
  local _, la = names_of(sa)
  local _, lb = names_of(sb)
  local listed, old = 0, 0
  for _, n in ipairs(la) do if isList[n] then old = old + 1 end end
  for _, n in ipairs(lb) do if isList[n] then listed = listed + 1 end end
  check("an older save names no world from the list", old == 0, table.concat(la, ","))
  check("a new galaxy names some worlds from the list", listed > 0, table.concat(lb, ","))
  check("…and as many worlds as before", #la == #lb)
  local _, _, oa, ca = homeOf(sa, ba)
  local _, _, ob, cb = homeOf(sb, bb)
  check("…and the same home world from the same seed", same_world(oa, ca, ob, cb))
  local sc, _ = regen(GAL[1], { g_names = 2 })
  local _, lc = names_of(sc)
  check("…and the same names again", table.concat(lb, ",") == table.concat(lc, ","))
end

if failed == 0 then
  print(string.format("✓ alien home: %d checks — default saves untouched, alien homes rolled from %d seeds (%d types), same seed same world", count, #HSEEDS, nt))
  os.exit(0)
else
  print(string.format("✗ %d of %d checks failed", failed, count))
  os.exit(1)
end
