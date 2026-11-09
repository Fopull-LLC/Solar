-- SMOKE: THE AIR YOU CAN BREATHE (expansion X2; scripts/atmo.lua).
--
--   * the templates: every world type's mix sums to 1, the pressure is the
--     density's (p0 = atmo / 0.75), Earth-like worlds hold 0.21 bar of O2;
--   * BREATHABLE for each AIR choice at the datum and up high: earth and rich
--     breathe, thin breathes THIN (the mask), none has no oxygen; toxic
--     gases (SO2, CO2, CH4) are named and keep the helmet on;
--   * RANDOM leans breathable: 60 % (55–65 %) of 2,000 seeds resolve to a
--     breathable choice, and the roll is the seed's (the same twice);
--   * THE GENERATOR (system_generator with the engine's rng and noise):
--     an alien home with Random air over many home seeds is breathable at its
--     datum and inside the suit's band about 60 % of the time; an explicit
--     Earth choice is always breathable, None never; the choice reloads the same;
--   * OLD SAVES: a save with no `g_air` publishes `legacy` air everywhere and
--     every reader keeps its old verdict: aero.oxygen equals the old OXY rule
--     on every world, the suit's breathableAt agrees with the old rule;
--   * THE SUIT: a toxic world keeps the helmet on with the gas named, thin air
--     lets it off; the jets' oxygen follows the air off the home world and
--     the home's jets fly whatever its air;
--   * ROOMS (room_air): the outside's CO2 seeds a new room (unbreathable until
--     scrubbed), a vent relaxes to it exactly (one step = many to 1e-6), the
--     N2 Compressor brings the outside's CO2 with its inert gas;
--   * THE SCENE HALF: thin air with an O2 Mask draws the suit at a sixth,
--     without one hurts; the Command building refills the suit.
--
--   luajit solar/tests/smoke_atmo.lua


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


-- ── atmo.lua, pure ──────────────────────────────────────────────────────────
local function loadlib(path, extra)
  local e = setmetatable(extra or {}, { __index = _G })
  local f = assert(loadfile("solar/scripts/" .. path))
  setfenv(f, e)
  f()
  return e
end
local A = loadlib("atmo.lua")
local function sum(g) local s = 0 for _, v in pairs(g) do s = s + v end return s end

for t in pairs(A.TEMPLATES) do
  local air = A.roll({ type = t, atmo = 0.75, tempK = 290 })
  check("template " .. t .. " sums to 1", air and math.abs(sum(air.gases) - 1) < 1e-9, air and sum(air.gases))
end
check("p0 is the density's: 0.75 → 1 bar", math.abs(A.p0Of(0.75) - 1) < 1e-12 and math.abs(A.p0Of(0.6) - 0.8) < 1e-12)
check("airless: no air record", A.roll({ type = "regolith", atmo = 0 }) == nil)
do
  local thin = A.roll({ type = "verdant", atmo = 0.45 })
  local thick = A.roll({ type = "verdant", atmo = 0.9 })
  check("an Earth-like world holds 0.21 bar of O2 at its datum, thin or thick",
    math.abs(thin.p0 * thin.o2 - 0.21) < 1e-6 and math.abs(thick.p0 * thick.o2 - 0.21) < 1e-6)
end

-- each AIR choice on an Earth-like home (p0 0.9 bar)
local CH = {}
for _, c in ipairs({ "earth", "rich", "thin", "alien" }) do
  CH[c] = A.roll({ type = "verdant", atmo = 0.675, tempK = 290, home = true, choice = c })
end
do
  local ok, why, info = A.breathable(CH.earth, 1)
  check("earth: breathable at the datum, not thin", ok and not info.thin, why)
  ok, why, info = A.breathable(CH.rich, 1)
  check("rich: breathable, 0.35 bar of O2", ok and math.abs(info.ppO2 - 0.35) < 1e-6, info.ppO2)
  ok, why, info = A.breathable(CH.thin, 1)
  check("thin: the helmet may come off but the air is THIN (the mask)", ok and info.thin == true, why)
  ok, why = A.breathable(CH.alien, 1)
  check("none: no oxygen, the helmet stays on", not ok and why:find("oxygen") ~= nil, why)
  -- up high: share 0.6 of the datum's density
  ok, why, info = A.breathable(CH.earth, 0.6)
  check("earth up high (0.6): thin", ok and info.thin, why)
  ok, why = A.breathable(CH.thin, 0.6)
  check("thin up high (0.6): too thin, the helmet stays on", not ok and why:find("thin") ~= nil, why)
  ok, why = A.breathable(CH.earth, 0.02)
  check("almost no air: no air", not ok, why)
  check("verdicts in a word", A.verdict(CH.earth) == "BREATHABLE" and A.verdict(CH.thin) == "THIN" and A.verdict(CH.alien) == "NO OXYGEN"
    and A.verdict(nil) == "NONE")
end
do
  local cases = { greenhouse = "SO₂", sulfur = "SO₂", volcanic = "SO₂", ironred = "CO₂", titan = "CH₄" }
  for t, gas in pairs(cases) do
    local air = A.roll({ type = t, atmo = 0.75, tempK = 290 })
    local ok, why, info = A.breathable(air, 1)
    check(t .. ": toxic, the gas named (" .. gas .. ")", not ok and info.toxic ~= nil and why:find(gas, 1, true) ~= nil, why)
  end
  check("a mix in words", A.gasesText(CH.earth):find("N₂", 1, true) == 1, A.gasesText(CH.earth))
end

-- RANDOM leans breathable
do
  local n, b = 2000, 0
  local same = true
  for s = 1, n do
    local c = A.resolveChoice("random", s * 7919 + 13)
    if A.breathableChoice(c) then b = b + 1 end
    if A.resolveChoice("random", s * 7919 + 13) ~= c then same = false end
  end
  check(string.format("random: %.1f %% of %d seeds breathable (55–65 %%)", 100 * b / n, n), b / n >= 0.55 and b / n <= 0.65, b / n)
  check("random: the same seed resolves the same", same)
  check("an explicit choice is kept; none is nil", A.resolveChoice("thin", 5) == "thin" and A.resolveChoice(nil, 5) == nil)
end

-- ── the generator: alien homes with Random air ──────────────────────────────
local BT = env.BREATHE_TYPES
do
  local N, nb, inband, typed = 30, 0, true, true
  for i = 1, N do
    local hs = 1000 + i * 7717
    local s, b = regen(1911564384, { g_homeKind = "alien", g_homeSeed = hs, g_air = "random" })
    local name, w = homeOf(s, b)
    local f = env.homeFeatures(name)
    local want = A.breathableChoice(A.resolveChoice("random", hs))
    if f.breathable then nb = nb + 1 end
    check(hs .. ": the air is chosen, not an old save's", type(w.air) == "table" and not w.air.legacy, w.air and w.air.legacy)
    check(hs .. ": breathable exactly when Random rolled a breathable air", (f.breathable == true) == want,
      string.format("%s %s %s %s", tostring(f.breathable), tostring(want), tostring(w.geo.type), tostring(w.bio.tempK)))
    if want then
      if not (w.bio.tempK >= 240 and w.bio.tempK <= 315) then inband = false end
      if not BT[w.geo.type] then typed = false end
    end
  end
  check(string.format("random alien homes: %d of %d breathable (about 60 %%)", nb, N), nb >= 0.35 * N and nb <= 0.85 * N, nb)
  check("…each breathable one inside the suit's band (240–315 K)", inband)
  check("…and of a type its air does not make", typed)
end
do
  local s, b = regen(1911564384, { g_homeKind = "alien", g_homeSeed = 4242, g_air = "earth" })
  local name, w = homeOf(s, b)
  local f = env.homeFeatures(name)
  check("an alien home with Earth air: helmet off", f.breathable == true and f.airVerdict == "BREATHABLE", f.airVerdict)
  local s2, b2 = regen(1911564384, { g_homeKind = "alien", g_homeSeed = 4242, g_air = "earth" })
  local _, w2 = homeOf(s2, b2)
  check("…and reloads the same world and air", w2.geo.type == w.geo.type and w2.bio.tempK == w.bio.tempK
    and math.abs(w2.air.o2 - w.air.o2) < 1e-12)
  local s3, b3 = regen(1911564384, { g_homeKind = "alien", g_homeSeed = 4242, g_air = "alien" })
  local n3 = homeOf(s3, b3)
  check("an alien home with no oxygen: helmet on", env.homeFeatures(n3).breathable == false)
  local s4, b4 = regen(1911564384, { g_air = "thin" })
  local n4, w4 = homeOf(s4, b4)
  check("the built home with Thin air: thin", A.verdict(w4.air) == "THIN" and w4.air.choice == "thin", A.verdict(w4.air))
  check("…and the generator remembers the choice", env.lastAirChoice == "thin")
  -- other worlds: never the home's choice
  local others = true
  for k, v in pairs(s4) do
    if k:sub(1, 6) == "world." and k ~= "world." .. n4 and type(v) == "table" and type(v.air) == "table" and v.air.choice then others = false end
  end
  check("…which no other world takes", others)
  check("every world has a magnetic field (moons none)", type(w4.mag) == "number" and w4.mag > 20, w4.mag)
end

-- ── old saves: legacy air, the old verdicts ─────────────────────────────────
local AE = loadlib("aero.lua")
local OLD_OXY = { archipelago = 1, verdant = 1, alpine = 1, steppe = 1, tundra = 1, dune = 0.8, greenhouse = 0, titan = 0 }
local function old_oxygen(w)
  if (w.atmo or 0) < 0.05 then return 0 end
  if type(w.geo) == "table" then
    if w.geo.home then return 1 end
    return OLD_OXY[w.geo.type or ""] or 0
  end
  return (w.atmo or 0) > 0.3 and 1 or 0
end
do
  local agree, legacy, nw = true, true, 0
  for _, args in ipairs({ { 1911564384, {} }, { 31337, {} }, { 1911564384, { g_homeKind = "alien", g_homeSeed = 42 } },
                          { 777001, { g_homeKind = "alien", g_homeSeed = 99 } } }) do
    local s = regen(args[1], args[2])
    for k, w in pairs(s) do
      if k:sub(1, 6) == "world." and type(w) == "table" then
        nw = nw + 1
        if w.air and not w.air.legacy then legacy = false end
        if AE.oxygen(w) ~= old_oxygen(w) then agree = false end
        if A.legacyOxygen(w) ~= old_oxygen(w) then agree = false end
      end
    end
    check(args[1] .. ": an old save writes no g_air", s.g_air == nil)
  end
  check(string.format("old saves: every world's air is legacy (%d worlds)", nw), legacy)
  check("old saves: aero.oxygen is the old OXY rule on every world", agree)
end
-- the jets: off the home world they burn what is there; the home flies whatever its air
do
  local co2 = { atmo = 0.75, geo = { type = "ironred" }, air = A.roll({ type = "ironred", atmo = 0.75 }) }
  local earthy = { atmo = 0.75, geo = { type = "ironred" }, air = A.roll({ type = "ironred", atmo = 0.75, choice = "earth" }) }
  local alienHome = { atmo = 0.75, geo = { type = "verdant", home = true }, air = A.roll({ type = "verdant", atmo = 0.75, home = true, choice = "alien" }) }
  check("jets: no O2 in a CO2 world's air", AE.jetOxygen(co2, false) < 0.05, AE.jetOxygen(co2, false))
  check("jets: an Earth-like air burns", math.abs(AE.jetOxygen(earthy, false) - 1) < 1e-6)
  check("jets: the home's jets fly even in oxygen-free home air", AE.jetOxygen(alienHome, true) == 1)
end

-- ── the suit (scripts/suit.lua) against stubs ──────────────────────────────
do
  local function vec3(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end
  local function W(t, extra) local w = { atmo = 0.75, atmoHeight = 300, radius = 800, geo = { type = t }, bio = { tempK = 290 } }
    for k, v in pairs(extra or {}) do w[k] = v end return w end
  local WORLDS = {
    Leg = W("dune", { air = A.roll({ type = "dune", atmo = 0.75, legacy = true }) }),
    Old = W("dune"),
    Tox = W("sulfur", { air = A.roll({ type = "sulfur", atmo = 0.75 }) }),
    Thin = W("verdant", { air = A.roll({ type = "verdant", atmo = 0.75, home = true, choice = "thin" }), geo = { type = "verdant", home = true } }),
    LegCO2 = W("ironred", { air = A.roll({ type = "ironred", atmo = 0.75, legacy = true }) }),
    OldCO2 = W("ironred"),
  }
  local BODIES, names = {}, { "Leg", "Old", "Tox", "Thin", "LegCO2", "OldCO2" }
  for i, n in ipairs(names) do BODIES[n] = { name = n, x = i * 10000, y = 0, z = 0, radius = 800 } end
  local function dominant(x, y, z)
    for n, b in pairs(BODIES) do if math.abs(x - b.x) < 3000 then return n end end
  end
  local walker = { onFoot = true, downed = false, headUnder = false, swimming = false, valid = true }
  local SCRIPTS = { planet_walker = walker, climate = { valid = true, worldOf = function(n) return WORLDS[n] end },
                    big_caption = { valid = true, show = function() end }, atmo = A, aero = AE }
  local function node(name, kids) local n = { name = name, valid = true, visible = true }; n.children = function() return kids or {} end; return n end
  local model = node("AstroModel", { node("Helmet", {}) })
  model.bonePos = function() return vec3(0, 0, 0) end
  model.animator = function() return { reach = function() end } end
  local crew = node("Astronaut", { model })
  local saved = {}
  local SE = setmetatable({ vec3 = vec3, findScript = function(k) return SCRIPTS[k] end,
    save = { get = function(k) return saved[k] end, set = function(k, v) saved[k] = v end },
    space = { dominant = dominant, body = function(n) return BODIES[n] end }, audio = { play = function() end } }, { __index = _G })
  local sc = assert(loadfile("solar/scripts/suit.lua"))
  setfenv(sc, SE)
  sc()
  SE.params = {}
  for k, v in pairs(SE.defaults) do SE.params[k] = v end
  local function at(n, alt) local b = BODIES[n]; return b.x, 800 + (alt or 0), 0 end
  -- old saves: a legacy world says what the same world said before air existed
  local same = true
  for _, pair in ipairs({ { "Leg", "Old" }, { "LegCO2", "OldCO2" } }) do
    for _, alt in ipairs({ 0, 40, 90, 140, 200 }) do
      local a1, w1 = SE.breathableAt(at(pair[1], alt))
      local a2, w2 = SE.breathableAt(at(pair[2], alt))
      if a1 ~= a2 or w1 ~= w2 then same = false end
    end
  end
  check("old saves: the suit's verdict on a legacy world is the old one, at every height", same)
  local ok, why = SE.breathableAt(at("Tox"))
  check("a sulfur world: the helmet stays on, SO2 named", ok == false and why:find("SO₂", 1, true) ~= nil, why)
  ok, why = SE.breathableAt(at("Thin"))
  check("a thin-air home: the helmet may come off (the mask is atmo's)", ok == true, why)
  ok, why = SE.breathableAt(at("Thin", 120))
  check("…and up high it may not", ok == false, why)
end

-- ── rooms (scripts/room_air.lua) ────────────────────────────────────────────
do
  local RA = loadlib("room_air.lua", { save = { get = function() end, set = function() end }, findScript = function() end, log = function() end })
  local co2air = A.roll({ type = "ironred", atmo = 0.75 })
  local p, xo, co = RA.outsideOf(co2air, 1)
  check("the outside of a CO2 world: about 1 atm, no O2, 95 % CO2", math.abs(p - 1) < 1e-9 and xo < 0.01 and co > 0.9, co)
  local V = 30
  local st = RA.outsideAir(V, p, xo, co)
  local s0 = RA.statusOf(st, V)
  check("a room closed round it starts as it is: unbreathable for its CO2", not s0.breathable and s0.co2 > 0.5, s0.why)
  -- a vent relaxes every amount to the outside's, exactly
  local function vent(dt, n)
    local s = { N = V * 0.78, x = V * 0.21, c = 0, q = 0, feed = false }
    for _ = 1, n do RA.advance(s, { V = V, tau = 40, pout = p, xout = xo, cout = co }, dt / n) end
    return s
  end
  local a, b = vent(600, 1), vent(600, 600)
  check("a vent on a CO2 world: one step equals many to 1e-6", math.abs(a.c - b.c) < 1e-6 and math.abs(a.N - b.N) < 1e-6 and math.abs(a.x - b.x) < 1e-6,
    string.format("%.9f %.9f", a.c, b.c))
  check("…and the room fills with the outside's CO2", a.c / V > 0.9 * co * p)
  -- sealed: scrubbers clear it; the compressor's makeup brings CO2 along
  local s1 = RA.outsideAir(V, p, xo, co)
  s1.q, s1.feed = 0, false
  RA.advance(s1, { V = V, crew = 0, S = 2.4e-5 * 10 }, 3600 * 48)
  check("sealed, ten scrubbers clear a room of CO2 in two days (flush it instead)", s1.c < 1e-6, s1.c)
  local s2 = { N = 0, x = 0, c = 0, q = 0, feed = false }
  RA.advance(s2, { V = V, crew = 0, JN = 0.004 * 0.03, Jc = 0.004 * 0.97 }, 600)
  check("the compressor on a CO2 world brings mostly CO2", s2.c > 10 * s2.N, string.format("%.3f %.3f", s2.c, s2.N))
  local s3 = { N = 0, x = 0, c = 0, q = 0, feed = false }
  RA.advance(s3, { V = V, crew = 0, JN = 0.004 * 0.03, Jc = 0.004 * 0.97, S = 2.4e-5 * 200 }, 600)
  check("…which its scrubbers take out", s3.c < 1e-6 and s3.N > 0, s3.c)
  check("an old save's outside is still O2N and no CO2", select(3, RA.outsideOf(nil, 1)) == 0)
end

-- ── the scene half: the mask, hypoxia, the Command building's air ───────────
do
  local thin = A.roll({ type = "verdant", atmo = 0.75, home = true, choice = "thin" })
  local w = { atmo = 0.75, atmoHeight = 300, radius = 800, geo = { type = "verdant", home = true }, bio = { tempK = 290 }, air = thin }
  local astro = { name = "Astronaut", x = 0, y = 800, z = 0, valid = true }
  local cmd = { name = "FacCommand", valid = true, x = 0, y = 800, z = 500 }
  function cmd.toLocal(self, v) return { x = v.x - self.x, y = v.y - self.y, z = v.z - self.z } end
  local helmet = false
  local hurt, mask = 0, 0
  local walker = { onFoot = true, downed = false, suitO2 = 1.0, valid = true }
  function walker.setSuitAir(v) walker.suitO2 = v end
  local SCR = {
    planet_walker = walker,
    suit = { valid = true, helmetOn = function() return helmet end },
    climate = { valid = true, worldOf = function() return w end },
    inventory = { valid = true, itemCount = function(_, id) return id == "o2mask" and mask or 0 end },
    crew = { valid = true, packOf = function() return "astro" end, activeId = function() return 1 end, SUIT_AIR_SECS = 1200,
             hurt = function(_, amt) hurt = hurt + amt end },
    big_caption = { valid = true, show = function() end },
  }
  local E = loadlib("atmo.lua", {
    findScript = function(k) return SCR[k] end,
    find = function(n) return (n == "Astronaut" and astro) or (n == "FacCommand" and cmd) or nil end,
    space = { dominant = function() return "Home" end, body = function() return { name = "Home", x = 0, y = 0, z = 0, radius = 800 } end },
    vec3 = function(x, y, z) return { x = x, y = y, z = z } end,
  })
  local function run(secs) for _ = 1, secs do E.time = (E.time or 0) + 1; E.update(nil, 1) end end
  E.time = 10
  run(60)
  check("thin air, no mask: hypoxia hurts (about 1 % a minute)", hurt > 0.008 and hurt < 0.012 and E.lastState == "hypoxia", hurt)
  check("…and the suit's air is untouched", walker.suitO2 == 1.0)
  hurt, mask = 0, 1
  run(600)
  local used = 1 - walker.suitO2
  check("thin air with the O2 Mask: no harm", hurt == 0 and E.lastState == "mask")
  check(string.format("…drawing the suit at a sixth (%.4f of a tank in 10 min)", used), math.abs(used - 600 / 1200 / 6) < 0.01, used)
  helmet = true
  local before = walker.suitO2
  run(30)
  check("helmet on: the mask rule stands down", walker.suitO2 == before and E.lastState == nil)
  -- the Command building refills the suit
  walker.suitO2 = 0.4
  astro.z = 500 + 12
  run(2)
  check("by the Command building's door the suit is topped up", walker.suitO2 == 1.0 and E.stats.refills >= 1)
  walker.suitO2 = 0.4
  astro.z = 500 + 40
  run(2)
  check("…but not 40 m off", walker.suitO2 == 0.4)
end

if failed == 0 then
  print(string.format("✓ atmo: %d checks — templates, choices, random 60 %%, alien homes, old saves unchanged, suit, rooms, mask", count))
  os.exit(0)
else
  print(string.format("✗ %d of %d checks failed", failed, count))
  os.exit(1)
end
