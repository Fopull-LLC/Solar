-- SMOKE HARNESS: WORLD SCALE VERSIONS (2026-10).
--
-- The worlds grew twice (system_generator SCALES: version 2, planets 240–380 m
-- and orbits from 24 km; version 3, planets 600–950 m shaped with the 0.117
-- relief layers, orbits from 60 km). A save keeps the scale it was made at, for life: its
-- dug terrain, its colony and its parked craft belong to THAT world, and the
-- galaxy is regenerated from the seed on every load. This drives the real
-- system_generator.lua and game_manager's worldScale() with the engine's own
-- rng (xorshift32, floptle-core noise.rs, reimplemented bit for bit) and checks:
--   * the player's save (slot1, seed 1902723835, made before versions
--     existed) regenerates EXACTLY the world on file: every home body's
--     radius, relief, orbit, µ and air, digit for digit;
--   * a save with no `g_scale` that has played is version 1; a fresh slot gets
--     the current scale; a stored version is never rewritten;
--   * the player's CURRENT slot1 (seed 1187844297, made at scale 2 on
--     2026-10-13) regenerates exactly the world on file too: scale 2 is the
--     archetype recipe at the bigger sizes, frozen;
--   * a scale-2 roll has the new sizes, and every body's terrain fill is
--     bounded (radius + relief over voxel ≤ the budget), caves capped;
--   * a scale-3 roll: planets 600–950 m, the voxel following the radius
--     (radius / voxel ≤ voxelSpan, never under 1.5 m or over voxelMax), caves
--     capped and deferred, every length × 2.5 and µ × 6.25 against scale 2, the
--     sphere of influence at 12 radii, relief layers on, spawn above the peaks;
--   * neighbour systems inherit home's scale.
--
--   luajit solar/tests/smoke_world_scale.lua

local bit = require("bit")

-- ── the engine's rng(seed): xorshift32 → [0,1) from the top 24 bits ────────
local function U32(x) return x % 4294967296 end
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

-- ── stubs ────────────────────────────────────────────────────────────────────
local store = {}
local save = {
  get = function(k) return store[k] end,
  set = function(k, v) store[k] = v end,
}
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
local generated = {}
local env = setmetatable({
  rng = rng, save = save,
  print = function() end, log = function() end,
  terrain = { generatePlanet = function(id, o) generated[#generated + 1] = { id = id, o = o } end },
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
      if n.valid then
        for _, t in ipairs(n.tags or {}) do if t == tag then out[#out + 1] = n end end
      end
    end
    return out
  end,
  space = { time = function() return 0 end },
  vec3 = function(x, y, z) return { x = x, y = y, z = z } end,
}, { __index = _G })

local chunk = assert(loadfile("solar/scripts/system_generator.lua"))
setfenv(chunk, env)
chunk()
env.params = {}
for k, v in pairs(env.defaults) do env.params[k] = v end

local failures = {}
local function check(cond, what)
  if not cond then failures[#failures + 1] = "CHECK FAILED: " .. what end
end
local function near(a, b, tol) return a and b and math.abs(a - b) <= (tol or 1e-9) * math.max(1, math.abs(b)) end

-- ── 1. the player's save regenerates as the world on file ───────────────────
-- slot1's generator keys, as stored (32-bit floats from the menu sliders), and
-- what its home roster and world records say. Read from save/slot1.ron on
-- 2026-10-13; the file itself is never opened here.
local SLOT1 = {
  seed = 1902723835,
  opts = { planets = 3.0, moonChance = 0.6000000238418579, atmoChance = 0.800000011920929,
           caveScale = 1.0, minOrbit = 5000.0, spacing = 2.200000047683716, radiusMin = 100.0,
           radiusMax = 230.0, gravityMin = 4.5, gravityMax = 10.0, starScale = 1.0 },
  star = "Veil", starMu = 71423929.33368683,
  bodies = {
    { name = "Ryuneth", a = 5986.28830909729, radius = 162.80427813529968, relief = 11.661190856345991,
      mu = 260477.45308796156, atmo = 0.7594801962375641, kind = "dune", atmoHeight = 55.68592307464681 },
    { name = "Drail", a = 14887.407408361158, radius = 195.49861311912537, relief = 13.384976343028855,
      mu = 361809.70681186777, atmo = 0.5703859150409698, kind = "lava", atmoHeight = 64.92864540660206 },
    { name = "Solol", a = 28955.926151410837, radius = 152.9482477903366, relief = 10.225779970856516,
      mu = 146931.6844491984, atmo = 0.6392443627119064, kind = "ice", atmoHeight = 59.103271949877914 },
  },
}

local function regen(seed, opts, scale)
  store = {}
  generated = {}
  local o = {}
  for k, v in pairs(opts) do o[k] = v end
  o.scale = scale
  o.pregen = true
  env.regenerate(seed, o)
end

for _, sc in ipairs({ { nil, "no g_scale (pre-version save)" }, { 1, "g_scale 1" } }) do
  regen(SLOT1.seed, SLOT1.opts, sc[1])
  local home = store["system.home"]
  check(home and home.star == SLOT1.star and near(home.mu, SLOT1.starMu),
    sc[2] .. ": slot1's star comes back (" .. tostring(home and home.star) .. ")")
  check(home and #home.bodies == #SLOT1.bodies, sc[2] .. ": slot1's home system has its three planets")
  for i, want in ipairs(SLOT1.bodies) do
    local got = home and home.bodies[i]
    check(got and got.name == want.name and got.kind == want.kind and near(got.a, want.a)
      and near(got.radius, want.radius) and near(got.relief, want.relief) and near(got.mu, want.mu)
      and near(got.atmo, want.atmo),
      string.format("%s: %s regenerates exactly (r %.6f vs %.6f, a %.3f vs %.3f)", sc[2], want.name,
        got and got.radius or -1, want.radius, got and got.a or -1, want.a))
    local w = store["world." .. want.name]
    check(w and near(w.atmoHeight, want.atmoHeight), sc[2] .. ": " .. want.name .. "'s air is as high as it was")
  end
  check(env.scaleVersion == 1 and env.scale == env.SCALES[1], sc[2] .. ": the generator publishes scale 1")
  -- The spawn planet's genspec is the OLD one: no voxel knob, caves by radius.
  local g = generated[1] and generated[1].o
  check(g and g.voxel == nil and near(g.radius, SLOT1.bodies[1].radius),
    sc[2] .. ": the pre-generated home fill is the original recipe (no voxel override)")
end

-- ── 1b. the player's CURRENT save (scale 2) regenerates as the world on file ─
-- slot1 was remade on 2026-10-13 at scale 2 (save/slot1.ron, read that day and
-- again on 2026-10-20; the file itself is never opened here). For a few days
-- the geology roll ran on scale 2 and re-rolled this save into another system
-- (its home Atheth, an ice world with a 75 MB dug field, came back as a canyon
-- world with a sea); scale 2 is the archetype recipe again and this holds it.
local SLOT1B = {
  seed = 1187844297,
  opts = { planets = 3.0, moonChance = 0.6000000238418579, atmoChance = 0.800000011920929,
           caveScale = 1.0, minOrbit = 24000.0, spacing = 2.200000047683716, radiusMin = 240.0,
           radiusMax = 380.0, gravityMin = 3.5, gravityMax = 8.5, starScale = 1.0 },
  star = "Umiland",
  bodies = {
    { name = "Atheth", a = 23697.88970947266, radius = 365.55790543556213, relief = 14.623230699616142,
      mu = 772589.8978199402, atmo = 0.5335959374904633, kind = "ice", sea = 0, atmoHeight = 134.62216787718103 },
    { name = "Zorunun", a = 1579.4467899275319, radius = 65.64292073249817, relief = 3.790875213543062,
      mu = 7996.144265224786, atmo = 0, kind = "ice", sea = 0 },
    { name = "Veunver", a = 56735.46325904409, radius = 357.21123576164246, relief = 25.600874253445845,
      mu = 814411.7019711981, atmo = 0.7988595396280289, kind = "canyon", sea = 344.3297243178217, atmoHeight = 131.45372011176764 },
    { name = "Pelveros", a = 1870.1078521770612, radius = 60.83724617958069, relief = 3.028821070162493,
      mu = 12551.457260273564, atmo = 0, kind = "ice", sea = 0 },
    { name = "Taverquo", a = 128812.68132471325, radius = 311.2411415576935, relief = 23.834510445053954,
      mu = 660667.1765295637, atmo = 0.7250899314880371, kind = "dune", sea = 0, atmoHeight = 88.01615860273368 },
    { name = "Umru", a = 1566.8456507829856, radius = 77.71680951118469, relief = 4.599898210508545,
      mu = 12498.608142458383, atmo = 0, kind = "crystal", sea = 0 },
  },
}
regen(SLOT1B.seed, SLOT1B.opts, 2)
do
  local home = store["system.home"]
  check(home and home.star == SLOT1B.star and home.scale == 2, "slot1 (scale 2): its star Umiland comes back")
  check(home and #home.bodies == #SLOT1B.bodies, "slot1 (scale 2): six bodies, as on file")
  for i, want in ipairs(SLOT1B.bodies) do
    local got = home and home.bodies[i]
    check(got and got.name == want.name and got.kind == want.kind and near(got.a, want.a)
      and near(got.radius, want.radius) and near(got.relief, want.relief) and near(got.mu, want.mu)
      and near(got.atmo, want.atmo) and near(got.sea, want.sea),
      string.format("slot1 (scale 2): %s regenerates exactly (got %s %s r %.6f a %.3f)", want.name,
        tostring(got and got.name), tostring(got and got.kind), got and got.radius or -1, got and got.a or -1))
    local w = store["world." .. want.name]
    if want.atmoHeight then check(w and near(w.atmoHeight, want.atmoHeight), "slot1 (scale 2): " .. want.name .. "'s air") end
    check(w and w.geo == nil and w.shape == nil, "slot1 (scale 2): " .. want.name .. " is an archetype world, not a geology")
  end
  local g = generated[1] and generated[1].o
  check(g and near(g.voxel, math.max(1.5, (SLOT1B.bodies[1].radius + SLOT1B.bodies[1].relief + 2) / 175))
    and g.mountains == nil and g.deferCaves == nil,
    "slot1 (scale 2): the home fill is the scale-2 recipe (voxel by the 175 budget, no relief layers)")
end

-- ── 2. which saves are which version ────────────────────────────────────────
local gm_store = {}
local genh = { CURRENT_SCALE = env.CURRENT_SCALE }
local genv = setmetatable({
  save = { get = function(k) return gm_store[k] end, set = function(k, v) gm_store[k] = v end },
  findScript = function(k) return k == "system_generator" and genh or nil end,
  print = function() end, log = function() end,
}, { __index = _G })
local gchunk = assert(loadfile("solar/scripts/game_manager.lua"))
setfenv(gchunk, genv)
gchunk()
gm_store = { g_seed = 1902723835, g_played = 30, ["base.body"] = "Ryuneth" }
check(genv.worldScale() == 1 and gm_store.g_scale == 1, "a save that has played, with no g_scale, is scale 1")
gm_store = { g_seed = 5, ["parts.rating"] = { v = 2 } }
check(genv.worldScale() == 1, "…so is one with a frozen parts catalogue")
gm_store = { g_seed = 1911564384 }
check(genv.worldScale() == env.CURRENT_SCALE and gm_store.g_scale == env.CURRENT_SCALE,
  "a fresh slot (only a seed) gets the current scale")
gm_store = { g_scale = 1 }
check(genv.worldScale() == 1, "a stored version is kept")
gm_store = { g_scale = 2, g_played = 4 }
check(genv.worldScale() == 2, "…whatever else the save holds")
gm_store = { g_scale = 3 }
check(genv.worldScale() == 3, "…a scale-3 one too")
check(env.CURRENT_SCALE == 3, "scale 3 is current")
-- The menu creates saves at the same version the generator calls current.
local menv = setmetatable({ save = { get = function() end, set = function() end } }, { __index = _G })
local mchunk = assert(loadfile("solar/scripts/menu_newsave.lua"))
setfenv(mchunk, menv)
mchunk()
check(menv.WORLD_SCALE == env.CURRENT_SCALE, "the new-save panel writes the current scale")

-- ── 3. a scale-2 world ──────────────────────────────────────────────────────
local S2 = env.SCALES[2]
local worst_span, n_bodies, n_planets = 0, 0, 0
for _, seed in ipairs({ 1911564384, 31337, 424242, 777001, 99, 1902723835 }) do
  regen(seed, {}, 2)
  check(env.scaleVersion == 2 and env.scale == S2, "seed " .. seed .. ": the generator publishes scale 2")
  local home = store["system.home"]
  check(home and home.scale == 2, "seed " .. seed .. ": the roster records its scale")
  check(home and home.mu >= S2.starMu[1] and home.mu <= S2.starMu[2], "seed " .. seed .. ": a scale-2 star")
  for _, n in ipairs(nodes) do
    if n.valid and n.gen and n.cel then
      local o, c = n.gen, n.cel
      n_bodies = n_bodies + 1
      local span = (o.radius + o.relief + 2) / (o.voxel or 1.5)
      worst_span = math.max(worst_span, span)
      check(span <= S2.voxelHalf + 1e-6, string.format("seed %d: %s fills %.0f voxels centre-to-peak (≤ %d)",
        seed, n.name, span, S2.voxelHalf))
      check((o.voxel or 1.5) >= 1.5 and (o.voxel or 1.5) <= 2.5,
        string.format("seed %d: %s's voxel %.2f m stays walkable", seed, n.name, o.voxel or 1.5))
      check(o.caveDepth <= S2.caveMax + 1e-6, string.format("seed %d: %s's caves %.0f m ≤ %d m", seed, n.name,
        o.caveDepth, S2.caveMax))
      check(o.relief <= o.radius * 0.16 + 1e-6, seed .. ": relief stays under 16% of the radius")
      check(o.mountains == nil and o.biomes == nil, seed .. ": scale 2 has no relief layers")
      if c.parent == home.star then
        n_planets = n_planets + 1
        check(o.radius >= S2.radiusMin and o.radius <= S2.radiusMax,
          string.format("seed %d: planet %s r %.0f in %d–%d", seed, n.name, o.radius, S2.radiusMin, S2.radiusMax))
        local g = c.mu / (o.radius * o.radius)
        check(g >= S2.gravityMin - 1e-9 and g <= S2.gravityMax + 1e-9, string.format("seed %d: g %.2f", seed, g))
        check(c.a >= S2.minOrbit * 0.9, string.format("seed %d: %s orbits at %.0f m", seed, n.name, c.a))
        check(c.soi >= 12 * o.radius, string.format("seed %d: %s's SOI %.0f ≥ 12 radii", seed, n.name, c.soi))
        if (c.atmoHeight or 0) > 0 then
          check(c.atmoHeight >= o.radius * 0.25 and c.atmoHeight <= o.radius * 0.45,
            seed .. ": the air is a quarter to under half the radius deep")
        end
      else
        check(o.radius >= 9 and o.radius <= S2.moonR[2] + 1e-9, string.format("seed %d: moon %s r %.0f", seed, n.name, o.radius))
      end
    end
  end
end
check(n_planets >= 12 and n_bodies > n_planets, string.format("rolled %d planets and %d bodies", n_planets, n_bodies))
-- The spawn planet is generated at its own voxel.
check(generated[1] and generated[1].o.voxel and generated[1].o.voxel >= 1.5, "the spawn fill carries its voxel")

-- ── 3b. a scale-3 world ────────────────────────────────────────────────────
local S3 = env.SCALES[3]
local n3, np3, worst_vox, spawn_ok = 0, 0, 0, 0
check(S3 and S3.geology and S3.layers, "scale 3 rolls geology with the relief layers")
-- Every length 2.5× scale 2's, at the same surface gravity (so µ × 6.25).
check(near(S3.minOrbit, S2.minOrbit * 2.5) and near(S3.starMu[1], S2.starMu[1] * 6.25)
  and near(S3.starMu[2], S2.starMu[2] * 6.25) and near(S3.moonR[2], S2.moonR[2] * 2.5)
  and near(S3.sector, S2.sector * 2.5) and S3.gravityMin == S2.gravityMin and S3.gravityMax == S2.gravityMax
  and near(S3.alt, S2.alt * 2.5) and math.abs(S3.speed - S2.speed * math.sqrt(2.5)) < 0.02,
  "scale 3 is scale 2 × 2.5 in length, × 6.25 in µ, × √2.5 in speed")
for _, seed in ipairs({ 1911564384, 31337, 424242, 777001, 99, 1902723835, 7, 23 }) do
  regen(seed, {}, 3)
  check(env.scaleVersion == 3 and env.scale == S3, "seed " .. seed .. ": the generator publishes scale 3")
  local home = store["system.home"]
  check(home and home.scale == 3, "seed " .. seed .. ": the roster records scale 3")
  check(home and home.mu >= S3.starMu[1] and home.mu <= S3.starMu[2], "seed " .. seed .. ": a scale-3 star")
  for _, n in ipairs(nodes) do
    if n.valid and n.gen and n.cel then
      local o, c = n.gen, n.cel
      n3 = n3 + 1
      local v = o.voxel
      worst_vox = math.max(worst_vox, v)
      check(v and v >= 1.5 and v <= S3.voxelMax + 1e-9 and (v <= 1.5 + 1e-9 or o.radius / v <= S3.voxelSpan + 1e-6),
        string.format("seed %d: %s's voxel %.2f m follows its radius %.0f", seed, n.name, v or -1, o.radius))
      check(o.deferCaves == true and o.caveDepth <= S3.caveMax + 1e-6, seed .. ": caves capped and deferred")
      check(o.subsoilDepth >= 2 * v - 1e-9, string.format("seed %d %s: subsoil %.1f m is two voxels down", seed, n.name, o.subsoilDepth))
      if o.overhangs then
        check(o.subsoilDepth >= o.overhangs.strength + v - 1e-9, seed .. ": the subsoil sits below the overhangs' reach")
      end
      check(c.occluderRadius >= 0 and c.occluderRadius < o.radius - o.caveDepth, seed .. ": the occluder is under the caves")
      local w = store["world." .. n.name]
      check(w and w.shape and w.shape.peak > 0 and w.relief == w.shape.peak,
        seed .. ": " .. n.name .. " publishes its shape and its peak as relief")
      if c.parent == home.star then
        np3 = np3 + 1
        check(o.radius >= S3.radiusMin and o.radius <= S3.radiusMax,
          string.format("seed %d: planet %s r %.0f in %d–%d", seed, n.name, o.radius, S3.radiusMin, S3.radiusMax))
        local g = c.mu / (o.radius * o.radius)
        check(g >= S3.gravityMin - 1e-9 and g <= S3.gravityMax + 1e-9, string.format("seed %d: g %.2f", seed, g))
        check(c.a >= S3.minOrbit * 0.9, string.format("seed %d: %s orbits at %.0f m", seed, n.name, c.a))
        check(c.soi >= 12 * o.radius, string.format("seed %d: %s's SOI %.0f ≥ 12 radii", seed, n.name, c.soi))
        if (c.atmoHeight or 0) > 0 then
          check(c.atmoHeight >= o.radius * 0.25 and c.atmoHeight <= o.radius * 0.45, seed .. ": air a quarter to under half the radius")
        end
      else
        check(o.radius >= 9 and o.radius <= S3.moonR[2] + 1e-9, string.format("seed %d: moon %s r %.0f", seed, n.name, o.radius))
      end
    end
  end
  -- The crew is set down above the tallest ground the layers can raise.
  local first = home.bodies[1]
  local w1 = store["world." .. first.name]
  if env.lastSpawnRadius >= first.radius + w1.shape.peak - 1e-6 then spawn_ok = spawn_ok + 1 end
  local g1 = generated[1] and generated[1].o
  check(g1 and g1.radius == first.radius and g1.mountains ~= nil or g1.plateau ~= nil or g1.warp ~= nil,
    "seed " .. seed .. ": the spawn fill carries the relief layers")
end
check(np3 >= 16 and n3 > np3, string.format("scale 3 rolled %d planets and %d bodies", np3, n3))
check(spawn_ok == 8, "the spawn radius clears the peaks on every seed")

-- ── 4. neighbours inherit home's scale ──────────────────────────────────────
regen(31337, {}, 2)
local before = #nodes
local name = env.buildNeighbour(4242, 6e7, 0.5, 3e6, 64, "galaxysystem")
check(name ~= nil, "a neighbour builds")
for i = before + 1, #nodes do
  local n = nodes[i]
  if n.gen and n.cel and n.cel.parent == name then
    check(n.gen.radius >= S2.radiusMin and n.gen.voxel and n.gen.mountains == nil, "a scale-2 home's neighbour has scale-2 planets")
  end
end
regen(31337, {}, 3)
before = #nodes
name = env.buildNeighbour(4242, 1.5e8, 0.5, 7.5e6, 64, "galaxysystem")
for i = before + 1, #nodes do
  local n = nodes[i]
  if n.gen and n.cel and n.cel.parent == name then
    check(n.gen.radius >= S3.radiusMin and n.gen.deferCaves, "a scale-3 home's neighbour has scale-3 planets")
  end
end
regen(SLOT1.seed, SLOT1.opts, nil)
before = #nodes
name = env.buildNeighbour(4242, 2e6, 0.5, 7e5, 64, "galaxysystem")
for i = before + 1, #nodes do
  local n = nodes[i]
  if n.gen and n.cel and n.cel.parent == name then
    check(n.gen.radius <= 230 and n.gen.voxel == nil, "a scale-1 home's neighbour is the original recipe")
  end
end

if #failures == 0 then
  print(string.format("WORLD SCALE SMOKE OK — both slot1 saves regenerate digit-for-digit (scale 1 and scale 2), versions are per save, scale 2 bounded (worst fill %.0f voxels centre-to-peak over %d bodies), scale 3 sized and layered (%d bodies, coarsest voxel %.2f m)",
    worst_span, n_bodies, n3, worst_vox))
  os.exit(0)
else
  print("WORLD SCALE SMOKE FAILURES:")
  for _, f in ipairs(failures) do print("  ✗ " .. f) end
  os.exit(1)
end
