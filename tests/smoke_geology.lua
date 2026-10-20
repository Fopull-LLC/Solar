-- SMOKE HARNESS: PLANET GEOLOGY (world scale 3, 2026-10).
--
-- On scale 3 every body is rolled as a GEOLOGY (system_generator.lua
-- rollGeology → geoOpts3): a planet type chosen by its physics, then what it is
-- made of, then shaped with the engine's relief layers (mountains, warp,
-- plateau, terrace, overhangs, ravines, rivers, biomes). This drives the real
-- generator with the engine's rng and checks:
--   * DIVERSITY: a sweep of seeds yields most of the catalogue, and two worlds
--     of the same type differ visibly (materials, relief, relief scale, sea);
--   * every paint lands on a palette slot that has a texture (terrain/system.palette);
--   * PHYSICS: seas only under air; liquid water only between freezing and
--     boiling; methane seas only on cold hydrocarbon worlds; a frozen sea is
--     the SeaIce prefab; the spawn world is a type a colony can start on;
--   * every scale-3 world publishes the `bio` / `water` / climate / `shape`
--     fields the flora, ocean and climate scripts read, in the documented shape;
--   * LAYERS: every type uses the layers its geology calls for (alpine ranges,
--     canyon terraces and ravines, river worlds' rivers ending at their sea),
--     every biome rule paints a textured slot with valid ranges, and no two
--     worlds of a type share a layer recipe;
--   * RIVERS AND LAKES: hydroOf publishes them in the documented shape, thins
--     them, asks the engine once per world per save (again for a save made
--     before engine 0.117 rc3's rivers), and hydroWarm asks the same off the
--     script thread (callbacks) into the same record, never into another save;
--   * determinism (same seed, same worlds) and scales 1 and 2 untouched (no
--     geology, no layers).
--
--   luajit solar/tests/smoke_geology.lua

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
  spawn = function(prefab, _, fn) local n = mknode(prefab) n.prefab = prefab if fn then fn(n) end return n end,
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

-- The palette: which slots have a texture.
local palette = {}
do
  local f = assert(io.open("solar/terrain/system.palette"))
  local i = 0
  for line in (f:read("*a") .. "\n"):gmatch("([^\n]*)\n") do
    i = i + 1
    local path = line:match("^([^|]*)")
    if path and path ~= "" then
      palette[i] = path
      local t = io.open("solar/" .. path, "rb")
      check(t ~= nil, "palette slot " .. i .. "'s texture exists: " .. path)
      if t then t:close() end
    end
  end
  f:close()
end

local FAMILIES = { canyon = true, dune = true, ice = true, frost = true, lava = true, crystal = true, barren = true }

local function roll(seed, scale)
  store, generated, nodes = {}, {}, {}
  env.regenerate(seed, { scale = scale or 3, pregen = true })
  return store
end

local function ser(v, out)
  out = out or {}
  if type(v) == "table" then
    local ks = {}
    for k in pairs(v) do ks[#ks + 1] = tostring(k) end
    table.sort(ks)
    out[#out + 1] = "{"
    for _, k in ipairs(ks) do
      out[#out + 1] = k .. "="
      ser(v[k] ~= nil and v[k] or v[tonumber(k)], out)
    end
    out[#out + 1] = "}"
  elseif type(v) == "number" then out[#out + 1] = string.format("%.9g,", v)
  else out[#out + 1] = tostring(v) .. "," end
  return table.concat(out)
end

local seen, byType, worlds, spawnTypes = {}, {}, 0, {}
local nlayer = { mountains = 0, warp = 0, plateau = 0, terrace = 0, overhangs = 0, ravines = 0, rivers = 0, rules = 0 }
local recipes = {}
local SEEDS = 120
for seed = 1, SEEDS do
  local st = roll(seed)
  local home = st["system.home"]
  for bi, b in ipairs(home.bodies) do
    local w = st["world." .. b.name]
    worlds = worlds + 1
    check(w and w.geo and w.bio, "seed " .. seed .. ": " .. b.name .. " publishes geo + bio")
    if w and w.geo and w.bio then
      local t = w.geo.type
      seen[t] = true
      check(env.GEO_TYPES[t] ~= nil, "a known type: " .. tostring(t))
      check(FAMILIES[w.kind], t .. "'s family is one mining/climate know: " .. tostring(w.kind))
      local bio = w.bio
      check(type(bio.temp) == "number" and bio.temp >= 0 and bio.temp <= 1, "bio.temp in 0..1")
      check(type(bio.tempK) == "number" and bio.tempK > 0, "bio.tempK")
      check(type(bio.moist) == "number" and bio.moist >= 0 and bio.moist <= 1, "bio.moist in 0..1")
      check(type(bio.fertility) == "number" and type(bio.soil) == "string", "bio.fertility / soil")
      check(bio.palette and #bio.palette.high == 3 and #bio.palette.low == 3 and #bio.palette.foliage == 3,
        "bio.palette has high / low / foliage colours")
      check(w.climTemp == bio.temp, "the climate's anchor is the bio temperature")
      -- Air, seas, physics.
      local air = (w.atmo or 0) > 0
      if (w.sea or 0) > 0 then
        check(air, seed .. ": " .. t .. " has a sea only under air")
        check(w.water and #w.water.deep == 3 and #w.water.shallow == 3 and w.water.clarity,
          "a sea publishes its water chemistry")
        if w.water then
          if w.water.state == "liquid" then
            check(bio.tempK >= 268 and bio.tempK <= 375, seed .. ": liquid water between freezing and boiling ("
              .. bio.tempK .. " K)")
          elseif w.water.state == "methane" then
            check(t == "titan" and bio.tempK <= 200, "methane seas only on a cold hydrocarbon world")
          else
            check(w.water.state == "ice" and bio.tempK <= 268, "a frozen sea is below freezing")
          end
        end
      else
        check(w.water == nil, "no sea, no water record")
      end
      if b.parent ~= home.star then
        check(not air and (w.sea or 0) == 0, "moons are airless and dry")
      end
      if bi == 1 then
        spawnTypes[t] = true
        check(env.GEO_TYPES[t].spawn, seed .. ": the spawn world is a colony type (" .. t .. ")")
      end
      byType[t] = byType[t] or {}
      table.insert(byType[t], { relief = b.relief / b.radius, sea = (w.sea or 0) > 0,
        hi = bio.mats.high, lo = bio.mats.low, patch = bio.mats.patch, seed = seed,
        col = bio.palette.high })
    end
  end
  -- Every genspec paints only textured slots; gen-cost bounds.
  for _, n in ipairs(nodes) do
    local o = n.gen
    if o then
      for _, k in ipairs({ "surfaceA", "surfaceB", "subsoil", "strata", "deep", "craterDust", "iceCaps", "pockets", "seam", "corePaint" }) do
        local pnt = o[k]
        if pnt then
          check(pnt.slot >= 1 and pnt.slot <= 32 and palette[pnt.slot] ~= nil,
            string.format("seed %d %s: %s paints slot %s, which has a texture", seed, n.name, k, tostring(pnt.slot)))
          check(pnt.color and #pnt.color == 3, k .. " has a colour")
        end
      end
      check((o.craters or 0) <= 30, "crater count stays cheap to fill")
      check(o.relief <= o.radius * 0.16 + 1e-6, "relief within 16% of the radius")
      -- The fbm base's steepness (GEO_MAX_SLOPE3, softened from scale 2's 0.45
      -- now that 0.117 draws the near ground at full detail).
      check(o.relief * (o.bumpFreq or 4.3) / o.radius <= env.GEO_MAX_SLOPE3 + 1e-6,
        string.format("seed %d %s: slope %.2f within the steepness cap", seed, n.name, o.relief * (o.bumpFreq or 4.3) / o.radius))
      -- The layers: in range, and every rule a textured paint.
      if o.mountains then
        local m = o.mountains
        check(m.height > 0 and m.height <= o.radius * 0.15 and m.coverage > 0 and m.coverage <= 1
          and m.sharpness > 0 and m.scale > 0, seed .. ": mountains in range")
        nlayer.mountains = nlayer.mountains + 1
      end
      for _, k in ipairs({ "warp", "plateau", "terrace", "overhangs", "ravines", "rivers" }) do
        if o[k] then nlayer[k] = nlayer[k] + 1 end
      end
      if o.rivers then
        check(o.rivers.count >= 1 and o.rivers.count <= 8 and o.rivers.width > 0 and o.rivers.seaLevel ~= nil,
          seed .. ": rivers sized and given somewhere to end")
        local w = store["world." .. n.name]
        if w and (w.sea or 0) > 0 then
          check(math.abs(o.rivers.seaLevel - (w.sea - o.radius)) < 1e-6, seed .. ": rivers end at the sea")
        end
      end
      if o.ravines then check(o.ravines.depth > 0 and o.ravines.width > 0 and o.ravines.length > 0, seed .. ": ravines in range") end
      if o.overhangs then check(o.overhangs.strength > 0 and o.overhangs.depth > 0, seed .. ": overhangs in range") end
      for bi, rule in ipairs(o.biomes or {}) do
        nlayer.rules = nlayer.rules + 1
        check(rule.slot and palette[rule.slot] and rule.color and #rule.color == 3,
          string.format("seed %d %s: biome rule %d paints a textured slot", seed, n.name, bi))
        for _, k in ipairs({ "latitude", "altitude", "slope", "moisture" }) do
          if rule[k] then check(#rule[k] == 2 and rule[k][1] <= rule[k][2], seed .. ": biome range " .. k .. " is {min, max}") end
        end
        for k in pairs(rule) do
          check(({ slot = 1, color = 1, latitude = 1, altitude = 1, slope = 1, moisture = 1, nearRiver = 1 })[k],
            "biome rule key " .. tostring(k) .. " is one the engine takes")
        end
      end
      if o.deferCaves then
        local w = store["world." .. n.name]
        local sig = string.format("%s|%s|%s|%s|%s|%s|%s|%.3g|%.3g", tostring(o.mountains and string.format("%.3g", o.mountains.height)),
          tostring(o.warp and string.format("%.3g", o.warp.strength)), tostring(o.plateau ~= nil), tostring(o.terrace and string.format("%.3g", o.terrace.step)),
          tostring(o.overhangs ~= nil), tostring(o.ravines and o.ravines.count), tostring(o.rivers and o.rivers.count), o.relief, o.bumpFreq)
        recipes[#recipes + 1] = { type = w and w.geo and w.geo.type, sig = sig }
      end
    end
  end
  -- A frozen sea is SeaIce, a liquid (or methane) one is Sea.
  for _, b in ipairs(home.bodies) do
    local w = st["world." .. b.name]
    if w and w.water then
      local want = (w.water.state == "ice") and "SeaIce" or "Sea"
      local found = false
      for _, n in ipairs(nodes) do
        if n.prefab == want and math.abs((n.scale or 0) - w.sea) < 1e-6 then found = true end
      end
      check(found, seed .. ": " .. b.name .. "'s " .. w.water.state .. " sea is a " .. want)
    end
  end
end

-- DIVERSITY across the catalogue.
local nseen, ntypes = 0, 0
for _ in pairs(seen) do nseen = nseen + 1 end
for _ in pairs(env.GEO_TYPES) do ntypes = ntypes + 1 end
check(nseen >= ntypes - 2, string.format("%d seeds roll %d of the %d planet types", SEEDS, nseen, ntypes))
local nspawn = 0
for _ in pairs(spawnTypes) do nspawn = nspawn + 1 end
check(nspawn >= 8, "the spawn world comes in at least 8 types (" .. nspawn .. ")")
-- …and two worlds of one type are not twins.
local pairs_, twins = 0, 0
for t, list in pairs(byType) do
  for i = 1, #list do
    for j = i + 1, math.min(#list, i + 6) do
      local a, b = list[i], list[j]
      pairs_ = pairs_ + 1
      local dc = math.abs(a.col[1] - b.col[1]) + math.abs(a.col[2] - b.col[2]) + math.abs(a.col[3] - b.col[3])
      local differ = a.hi ~= b.hi or a.lo ~= b.lo or a.patch ~= b.patch or a.sea ~= b.sea
        or math.abs(a.relief - b.relief) > 0.15 * math.max(a.relief, b.relief) or dc > 0.08
      if not differ then twins = twins + 1 end
    end
  end
end
check(pairs_ > 50 and twins <= pairs_ * 0.1, string.format("same-type worlds differ: %d near-twins of %d pairs", twins, pairs_))

-- Every layer is in use somewhere, and no two worlds of a type share a recipe.
for k, v in pairs(nlayer) do check(v >= 10, string.format("the %s layer is used (%d bodies)", k, v)) end
do
  local sigs, dup = {}, 0
  for _, rc in ipairs(recipes) do
    local key = tostring(rc.type) .. "#" .. rc.sig
    if sigs[key] then dup = dup + 1 end
    sigs[key] = true
  end
  check(#recipes > 300 and dup == 0, string.format("%d layered worlds, %d share a recipe", #recipes, dup))
end
-- Types do what their geology says.
do
  local want = {
    alpine = function(o) return o.mountains and o.mountains.height >= o.radius * 0.08 and o.overhangs and o.rivers end,
    canyon = function(o) return o.terrace and o.ravines and o.plateau end,
    archipelago = function(o) return o.mountains and o.rivers end,
    verdant = function(o) return o.rivers and o.rivers.count >= 5 end,
    crystal = function(o) return o.overhangs and o.overhangs.strength >= 5 and o.mountains.sharpness >= 4 end,
    dune = function(o) return o.warp and o.warp.strength >= 0.2 end,
    glacial = function(o) return o.mountains and o.ravines and not o.plateau end,
    maria = function(o) return o.plateau and o.ravines and not o.mountains end,
  }
  local hit = {}
  for seed = 1, 40 do
    local st = roll(seed)
    for _, n in ipairs(nodes) do
      local w = n.gen and st["world." .. n.name]
      local t = w and w.geo and w.geo.type
      if t and want[t] then
        hit[t] = (hit[t] or 0) + 1
        check(want[t](n.gen), "seed " .. seed .. ": a " .. t .. " world has its layers")
      end
    end
  end
  for t in pairs(want) do check((hit[t] or 0) > 0, "40 seeds roll a " .. t .. " world to check") end
end

-- RIVERS AND LAKES: hydroOf over a stub engine that answers like 0.117 rc3
-- does — two rivers that run down to their sea (one 450 points long), a
-- ravine, and three lakes (one too small to keep) — synchronously, or later
-- through a callback when given one.
do
  local asked, later = 0, {}
  local function rivers_of(o)
    local R = o.radius
    local a, b = {}, {}
    for i = 0, 99 do
      local t = i * 0.02
      a[i * 3 + 1], a[i * 3 + 2], a[i * 3 + 3] = R * math.cos(t), R * math.sin(t), 0
    end
    local wa = {}
    for i = 1, 100 do wa[i] = 6 + i * 0.05 end
    local wb = {}
    for i = 0, 449 do
      local d = { 0.2 + i * 2 / R, 0.9, 0.1 }
      local l = math.sqrt(d[1] ^ 2 + d[2] ^ 2 + d[3] ^ 2)
      b[i * 3 + 1], b[i * 3 + 2], b[i * 3 + 3] = d[1] / l * R, d[2] / l * R, d[3] / l * R
      wb[i + 1] = 4 + i * 0.01
    end
    return { { river = true, depth = 5, points = a, widths = wa }, { river = true, depth = 4, points = b, widths = wb },
      { river = false, depth = 30, points = { 0, R, 0, 1, R, 0, 2, R, 0, 3, R, 0, 4, R, 0, 5, R, 0, 6, R, 0 }, widths = { 9, 9, 9, 9, 9, 9, 9 } } }
  end
  local function lakes_of(o, q)
    check(q and q.cell and q.minDepth and o.voxel >= 2 * o.radius / 112 - 1e-6,
      "lakes are asked on the coarse relief grid")
    local R = o.radius
    return { { level = 12.5, center = { x = 0, y = 0, z = R + 12.5 }, reach = 80, area = 9000, depth = 6 },
      { level = 30, center = { x = R + 30, y = 0, z = 0 }, reach = 30, area = 1800, depth = 3 },
      { level = 2, center = { x = 0, y = -R - 2, z = 0 }, reach = 2, area = 9, depth = 1.1 } }
  end
  env.terrain.planetRivers = function(o, cb)
    asked = asked + 1
    if cb then later[#later + 1] = function() cb(rivers_of(o)) end return end
    return rivers_of(o)
  end
  env.terrain.planetLakes = function(o, q, cb)
    asked = asked + 1
    if cb then later[#later + 1] = function() cb(lakes_of(o, q)) end return end
    return lakes_of(o, q)
  end
  local function deliver() local l = later; later = {} for _, f in ipairs(l) do f() end end
  -- A wet world with rivers.
  local name, wet
  for seed = 1, 60 do
    local st = roll(seed)
    for k, w in pairs(st) do
      if k:match("^world%.") and w.hydro and w.shape and w.shape.layers.rivers and (w.atmo or 0) > 0 then name, wet = w.name, w end
    end
    if name then break end
  end
  check(name ~= nil, "a world with rivers to ask about")
  if name then
    -- roll() warmed the home world's: let those answers land first.
    deliver()
    asked = 0
    store["hydro." .. name] = nil
    local h = env.hydroOf(name)
    check(asked == 2 and h and h.v == env.HYDRO_V and h.seed == wet.seed, "hydroOf asks the engine for rivers and lakes")
    check(env.HYDRO_V >= 2, "rivers traced by engine 0.117 rc3 are a new hydro version")
    check(env.hydroOf(name) == h and asked == 2, "…once: the answer is kept in the save")
    check(store["hydro." .. name] == h, "…under hydro.<name>")
    local rivers, ravines, maxpts = 0, 0, 0
    for _, r in ipairs(h.rivers) do
      check(type(r.points) == "table" and #r.points % 3 == 0 and #r.widths == #r.points / 3 and r.length > 0,
        "a river is x,y,z points with a width each and a length")
      maxpts = math.max(maxpts, #r.points / 3)
      if r.river then rivers = rivers + 1 else ravines = ravines + 1 end
    end
    check(rivers == 2 and ravines == 1, "each channel comes back once: two rivers and a ravine")
    check(maxpts <= 200 and maxpts >= 150, "…a long river thinned to at most 200 points (" .. maxpts .. " kept)")
    check(#h.lakes == 2 and h.lakes[1].level == 12.5 and h.lakes[1].reach == 80 and h.lakes[1].z == wet.radius + 12.5,
      "the lakes come back (the puddle is not one), level and centre as the engine said")
    -- A save that kept the rivers of an older engine asks again.
    asked = 0
    store["hydro." .. name] = { seed = wet.seed, v = 1, rivers = {}, lakes = {} }
    check(env.hydroOf(name).v == env.HYDRO_V and asked == 2, "a save with an older hydro version asks again")
    -- Off the script thread: the same record, once both answers are in.
    local sync = ser(store["hydro." .. name])
    store["hydro." .. name] = nil
    asked = 0
    env.hydroWarm(name)
    check(asked == 2 and #later == 2 and store["hydro." .. name] == nil and env.hydroPending(name),
      "hydroWarm asks both questions with callbacks and holds nothing yet")
    env.hydroWarm(name)
    check(asked == 2, "…and does not ask twice while they are out")
    deliver()
    check(not env.hydroPending(name) and store["hydro." .. name] ~= nil and ser(store["hydro." .. name]) == sync,
      "…and their answers make exactly the record hydroOf makes")
    asked = 0
    env.hydroWarm(name)
    check(asked == 0, "a warm save is not asked again")
    -- Answers that land after another save was loaded are dropped.
    local slot = "a"
    env.save.slot = function() return slot end
    store["hydro." .. name] = nil
    env.hydroWarm(name)
    slot = "b"
    deliver()
    check(store["hydro." .. name] == nil and not env.hydroPending(name), "answers for a save that is no longer loaded are dropped")
    env.save.slot = nil
  end
  env.terrain.planetRivers, env.terrain.planetLakes = nil, nil
end

-- Determinism.
local a = ser(roll(4242)); local b = ser(roll(4242))
check(a == b, "the same seed rolls the same worlds")

-- Scales 1 and 2 have no geology (their worlds regenerate as they were).
for _, sc in ipairs({ 1, 2 }) do
  local st1 = roll(4242, sc)
  for k, w in pairs(st1) do
    if k:match("^world%.") then check(w.geo == nil and w.bio == nil and w.shape == nil, "scale " .. sc .. " worlds carry no geology") end
  end
  for _, n in ipairs(nodes) do
    if n.gen then check(n.gen.mountains == nil and n.gen.biomes == nil and n.gen.deferCaves == nil, "scale " .. sc .. ": no relief layers") end
  end
end

if #failures == 0 then
  local list = {}
  for t in pairs(seen) do list[#list + 1] = t end
  table.sort(list)
  print(string.format("GEOLOGY SMOKE OK — %d worlds over %d seeds, %d/%d types (%s), %d spawn types, %d/%d same-type pairs differ; layers on %d/%d/%d/%d/%d/%d/%d bodies (mountains/warp/plateau/terrace/overhangs/ravines/rivers), %d biome rules",
    worlds, SEEDS, nseen, ntypes, table.concat(list, " "), nspawn, pairs_ - twins, pairs_,
    nlayer.mountains, nlayer.warp, nlayer.plateau, nlayer.terrace, nlayer.overhangs, nlayer.ravines, nlayer.rivers, nlayer.rules))
  os.exit(0)
else
  print("GEOLOGY SMOKE FAILURES:")
  local shown = {}
  for _, f in ipairs(failures) do
    if not shown[f] then shown[f] = true; print("  ✗ " .. f) end
  end
  os.exit(1)
end
