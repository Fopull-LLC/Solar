-- SMOKE HARNESS: cave kinds and dressing (worlds W4, 2026-11-10).
--
--   * cave_kinds.lua (pure): the eight kinds are complete (walls in the
--     library, props, decals, ambience, hazards, air, rewards, facts); every
--     model, decal and recording they name is on disk; every W2 formation and
--     every world type has its kinds; kindsFor sums to one; principalOf never
--     answers collapse; regionOf is deterministic, uses every kind a formation
--     offers and does not stripe (neighbouring regions are unrelated)
--   * cave_field.lua in a stub cave (a floor, a roof 6 m up, walls): the kind
--     is published with its air and hazards; cells are dressed once, within
--     the node cap, hanging props leave headroom; the placements are saved and
--     a fresh run reads the same ones; a prop whose rock is dug away goes
--   * underground.lua: each kind eases the ambience to its own (floor, tint,
--     haze, tone, drips, creaks) and starts its recorded bed
--   * flashlight.lua: a flat torch takes a spare cell on L, and only then
--
--   luajit solar/tests/smoke_cave_kinds.lua

local checks, failures = 0, {}
local function ok(cond, msg)
  checks = checks + 1
  if not cond then failures[#failures + 1] = msg end
end
local function exists(p)
  local f = io.open("solar/" .. p, "rb")
  if f then f:close() return true end
  return false
end
local function load(path, api)
  local env = setmetatable({}, { __index = function(_, k)
    if k == "time" then return api.time or 0 end
    return api[k] or _G[k]
  end })
  local chunk = assert(loadfile(path))
  setfenv(chunk, env)
  chunk()
  env.params = {}
  for k, v in pairs(env.defaults or {}) do env.params[k] = v end
  return env
end

local CK = load("solar/scripts/cave_kinds.lua", {})
local G = load("solar/scripts/geology.lua", {})

-- ── the table ───────────────────────────────────────────────────────────────
ok(#CK.ORDER == 8, "eight kinds")
for _, id in ipairs(CK.ORDER) do
  local K = CK.KINDS[id]
  ok(K and K.id == id and K.label, id .. ": a kind with its id and label")
  if K then
    if K.walls then
      for _, n in ipairs(K.walls) do ok(G.LAYER[n] ~= nil, id .. ": wall " .. n .. " is a library layer") end
    else
      ok(id == "collapse" or id == "chasm", id .. ": only collapse and chasm keep the formation's own walls")
    end
    ok(K.depth and K.depth[1] < K.depth[2], id .. ": a depth band")
    ok(#K.props >= 3, id .. ": three or more prop placements")
    local at = {}
    for _, p in ipairs(K.props) do
      at[p.at] = true
      ok(p.at == "ceil" or p.at == "floor" or p.at == "wall", id .. ": a prop is placed on a roof, floor or wall")
      ok(p.orient == "hang" or p.orient == "stand" or p.orient == "normal" or p.orient == "drape", id .. ": a prop has an orientation")
      ok(p.s and p.s[1] > 0 and p.s[2] >= p.s[1], id .. ": a scale range")
      for lod = 0, 1 do ok(exists(CK.propModel(p.id, lod)), id .. ": model on disk " .. CK.propModel(p.id, lod)) end
      ok(exists(CK.PROP_DIR .. p.id .. ".bin"), id .. ": its geometry on disk")
    end
    ok(at.ceil and at.floor, id .. ": something on the roof and something on the floor")
    ok(#K.decals >= 1, id .. ": wall marks")
    for _, d in ipairs(K.decals) do ok(exists(CK.decalTexture(d.tex)), id .. ": decal on disk " .. CK.decalTexture(d.tex)) end
    local A = K.amb
    ok(A and A.floor and A.floor > 0 and A.floor < 0.2, id .. ": an ambient floor (dark, never pitch zero)")
    ok(A and A.tint and #A.tint == 3, id .. ": an ambient colour")
    ok(A and A.fog and #A.fog == 5, id .. ": a haze (colour, density, reach)")
    ok(A and A.tone and A.drips and A.creak and A.groan, id .. ": tone, drips, creaks, groans")
    if A and A.loop then ok(exists(A.loop.clip), id .. ": its bed is on disk " .. A.loop.clip) end
    local H = CK.hazardsOf(id)
    ok(type(H.unstable) == "number" and H.unstable >= 0 and H.unstable <= 1, id .. ": rockfall chance in 0..1")
    ok(type(H.dose) == "number" and type(H.drop) == "number", id .. ": dose and drop are numbers")
    H.unstable = 99
    ok(CK.hazardsOf(id).unstable ~= 99, id .. ": hazardsOf hands out a copy")
    local air = CK.airOf(id)
    if air then for g, v in pairs(air) do ok(v > 0 and v < 0.2, id .. ": air " .. g .. " a partial pressure in bar") end end
    ok(K.rewards and K.rewards.rp and K.rewards.rp > 0, id .. ": first-entry RP")
    ok(K.facts and #K.facts >= 3, id .. ": three real facts")
    local P = CK.propsOf(id, { 0.4, 0.4, 0.4 })
    for _, p in ipairs(P) do ok(p.tint and #p.tint == 3, id .. ": every prop has a tint") end
  end
end
-- the kinds are told apart by their look and sound
local floors, beds = {}, {}
for _, id in ipairs(CK.ORDER) do
  local A = CK.KINDS[id].amb
  floors[string.format("%.3f", A.floor)] = true
  if A.loop then beds[A.loop.clip] = true end
end
local nf, nb = 0, 0
for _ in pairs(floors) do nf = nf + 1 end
for _ in pairs(beds) do nb = nb + 1 end
ok(nf >= 7, "the kinds' darkness differs (" .. nf .. " floors)")
ok(nb >= 4, "four kinds have a recorded bed of their own (" .. nb .. ")")
for _, c in ipairs({ "audio/ambience/cave_ice_crack_1.ogg", "audio/ambience/cave_ice_crack_2.ogg", "audio/ambience/cave_ice_crack_3.ogg" }) do
  ok(exists(c), "ice crack on disk " .. c)
end
for _, id in ipairs(CK.propIds()) do ok(exists(CK.propModel(id, 0)), "prop " .. id) end
ok(exists("models/cave/flare_l0.gltf"), "the flare's model")

-- ── coverage: formations and types ──────────────────────────────────────────
local used = {}
local nform = 0
for ty, list in pairs(G.FORMATIONS) do
  local kinds_of_type = {}
  for _, f in ipairs(list) do
    nform = nform + 1
    ok(CK.FORMATION_KINDS[f.id] ~= nil, "formation " .. f.id .. " has cave kinds")
    local l = CK.kindsFor(f.id, 0.5, ty)
    local sum, hasCollapse = 0, false
    for _, e in ipairs(l) do
      sum = sum + e[2]; used[e[1]] = true; kinds_of_type[e[1]] = true
      if e[1] == "collapse" then hasCollapse = true end
    end
    ok(math.abs(sum - 1) < 1e-9, f.id .. ": kindsFor sums to 1")
    ok(hasCollapse, f.id .. ": a collapse is always possible")
    for _, u in ipairs({ 0, 0.3, 0.7, 0.999 }) do
      local p = CK.principalOf(f.id, ty, u)
      ok(p ~= "collapse" and CK.KINDS[p], f.id .. ": the principal kind is never collapse (" .. tostring(p) .. ")")
      local K = CK.KINDS[p]
      local cave = f.cave and f.cave[1]
      local wall = CK.wallFor(p, cave, u)
      ok(wall == nil or G.LAYER[wall] ~= nil, f.id .. ": its wall is a library layer")
      if K.walls then
        local inlist = false
        for _, n in ipairs(K.walls) do if n == wall then inlist = true end end
        ok(inlist, f.id .. ": its wall is one of the kind's")
      end
    end
  end
  local n = 0
  for _ in pairs(kinds_of_type) do n = n + 1 end
  ok(n >= 2, ty .. ": two or more cave kinds (" .. n .. ")")
end
for id in pairs(CK.FORMATION_KINDS) do
  local found = false
  for _, list in pairs(G.FORMATIONS) do for _, f in ipairs(list) do if f.id == id then found = true end end end
  ok(found, "FORMATION_KINDS." .. id .. " is a real formation")
end
for _, id in ipairs(CK.ORDER) do ok(used[id], id .. " occurs on some formation") end
local TYPES = { "archipelago", "verdant", "alpine", "canyon", "steppe", "dune", "saltflat", "ironred", "tundra", "glacial",
  "volcanic", "sulfur", "greenhouse", "crystal", "titan", "frost", "regolith", "maria" }
for _, t in ipairs(TYPES) do ok(CK.TYPE_KINDS[t] ~= nil, "type " .. t .. " has fallback kinds (worlds before formations)") end
-- depth: vents and tubes deep, collapse shallow
local function w(list, id) for _, e in ipairs(list) do if e[1] == id then return e[2] end end return 0 end
ok(w(CK.kindsFor("pahoehoe_aa", 0.9), "lava_tube") > w(CK.kindsFor("pahoehoe_aa", 0.05), "lava_tube"), "lava tubes lie deeper")
ok(w(CK.kindsFor("pahoehoe_aa", 0.05), "collapse") > w(CK.kindsFor("pahoehoe_aa", 0.9), "collapse"), "collapses lie shallow")

-- ── regions ─────────────────────────────────────────────────────────────────
do
  local R, cd = 900, 80
  local k1, c1 = CK.regionOf(1234, 100.5, 820.2, 300.1, R, cd, "tuff_scoria", "volcanic")
  local k2, c2 = CK.regionOf(1234, 100.5, 820.2, 300.1, R, cd, "tuff_scoria", "volcanic")
  ok(k1 == k2 and c1 == c2, "regionOf is deterministic")
  local diffSeed = 0
  local counts, same, pairsN = {}, 0, 0
  for i = -20, 20 do
    for j = -20, 20 do
      local x, z = i * CK.REGION + 7, j * CK.REGION + 7
      local y = 860
      local k = CK.regionOf(55, x, y, z, R, cd, "tuff_scoria", "volcanic")
      counts[k] = (counts[k] or 0) + 1
      local kn = CK.regionOf(55, x + CK.REGION, y, z, R, cd, "tuff_scoria", "volcanic")
      pairsN = pairsN + 1
      if k == kn then same = same + 1 end
      if CK.regionOf(56, x, y, z, R, cd, "tuff_scoria", "volcanic") ~= k then diffSeed = diffSeed + 1 end
    end
  end
  for _, e in ipairs(CK.kindsFor("tuff_scoria", (R - 860) / cd)) do
    ok((counts[e[1]] or 0) > 0, "every kind the formation offers turns up in some region: " .. e[1])
  end
  -- unrelated neighbours: the chance two neighbours agree is about Σ w²
  local exp = 0
  for _, e in ipairs(CK.kindsFor("tuff_scoria", (R - 860) / cd)) do exp = exp + e[2] * e[2] end
  local got = same / pairsN
  ok(math.abs(got - exp) < 0.08, string.format("neighbouring regions are unrelated (agree %.2f, expected %.2f)", got, exp))
  ok(diffSeed > pairsN * 0.3, "another seed gives other regions (" .. diffSeed .. ")")
  -- hash uniform
  local bins = {}
  for i = 0, 9 do bins[i] = 0 end
  for i = 1, 4000 do local u = CK.hash(9, i, i * 3, -i); bins[math.floor(u * 10)] = bins[math.floor(u * 10)] + 1 end
  local lo, hi = 1e9, 0
  for i = 0, 9 do lo = math.min(lo, bins[i]); hi = math.max(hi, bins[i]) end
  ok(lo > 320 and hi < 480, "the hash is uniform (" .. lo .. ".." .. hi .. ")")
end

-- ── cave_field in a stub cave ───────────────────────────────────────────────
-- A world of radius R; a cave from R − 30 (floor) to R − 24 (roof) under 24 m
-- of rock, walls 9 m off every level ray. The planet races along its rails.
local function cave_world(kindName, store)
  local R = 1000
  local B = { name = "Home", x = 0, y = 0, z = 0, radius = R, mu = 9.0 * R * R, soi = 1e9 }
  local FLOOR, ROOF = R - 30, R - 24
  local astro = { x = 0, y = FLOOR + 0.05, z = 0, valid = true }
  local made, destroyed = {}, 0
  local dug = {}
  local planet = { valid = true, name = "Home" }
  local cfg = { enclosed = 1.0 }
  local api = {
    time = 0, vec3 = function(x, y, z) return { x = x, y = y, z = z } end,
    find = function(n) if n == "Astronaut" then return astro end if n == "Home" then return planet end end,
    findScript = function(k)
      if k == "planet_walker" then return { valid = true, onFoot = true } end
      if k == "underground" then return { valid = true, enclosed = cfg.enclosed, cave = true } end
      if k == "cave_kinds" then return CK end
      if k == "planet_camera" then return { valid = true, fwd_x = 1, fwd_y = 0, fwd_z = 0 } end
    end,
    save = { get = function(k)
      if k == "world.Home" then
        return { seed = 7, radius = R, kind = "lava", geo = { type = "volcanic", family = "lava" },
          bio = { formation = { id = "pahoehoe_aa" }, caves = { depth = 80, principal = "lava_tube" }, palette = { rock = { 0.3, 0.28, 0.26 } } } }
      end
      return store[k]
    end, set = function(k, v) store[k] = v end },
    space = { dominant = function() return "Home" end, body = function() return B end },
    terrain = {
      query = function(x, y, z)
        local px, py, pz = x - B.x, y - B.y, z - B.z
        local r = math.sqrt(px * px + py * py + pz * pz)
        local hz = math.sqrt(px * px + pz * pz)
        for _, d in ipairs(dug) do
          if math.abs(px - d[1]) + math.abs(py - d[2]) + math.abs(pz - d[3]) < 1.2 then return 1.0 end
        end
        if r > FLOOR and r < ROOF and hz < 30 then return math.min(r - FLOOR, ROOF - r, 30 - hz) end
        return -1
      end,
      raycast = function(o, d, far)
        local px, py, pz = o.x - B.x, o.y - B.y, o.z - B.z
        local r = math.sqrt(px * px + py * py + pz * pz)
        local radial = (px * d.x + py * d.y + pz * d.z) / r
        local dist
        if r > R then
          -- from above the ground: down to the surface
          if radial < -0.99 then dist = r - R else return nil end
        elseif radial > 0.99 then if cfg.open then return nil end; dist = ROOF - r
        elseif radial < -0.99 then dist = r - FLOOR
        else dist = 9 end
        if dist <= 0 or dist > far then return nil end
        local n = radial > 0.99 and { x = -px / r, y = -py / r, z = -pz / r } or (radial < -0.99 and { x = px / r, y = py / r, z = pz / r })
          or { x = -d.x, y = -d.y, z = -d.z }
        return { distance = dist, pos = { x = o.x + d.x * dist, y = o.y + d.y * dist, z = o.z + d.z * dist }, normal = n }
      end,
    },
    createNode = function(name, parent, cb)
      local n = { valid = true, name = name, parent = parent }
      n.destroy = function(self) self.valid = false; destroyed = destroyed + 1 end
      n.setUp = function(self, u, f) self.up = u; self.fwd = f end
      n.setTint = function(self, t) self.tint = t end
      made[#made + 1] = n
      cb(n)
    end,
    decals = { add = function() return 1 end, remove = function() return true end },
  }
  local F = load("solar/scripts/cave_field.lua", api)
  if kindName then F.params.forceKind = kindName end
  return F, api, B, astro, made, function() return destroyed end, dug, cfg
end

do
  local store = {}
  local F, api, B, astro, made, ndestroyed, dug, cfg = cave_world(nil, store)
  for step = 1, 400 do                        -- 20 s at 20 Hz, walking 1 m/s
    api.time = step * 0.05
    B.x = B.x + 50; astro.x = astro.x + 50 + 0.05
    F.update({}, 0.05)
  end
  ok(F.caveKind ~= nil and CK.KINDS[F.caveKind], "in the cave a kind is published (" .. tostring(F.caveKind) .. ")")
  ok(F.label == CK.labelOf(F.caveKind), "…with its label")
  ok(F.depth and math.abs(F.depth - 28.35) < 1.0, string.format("the rock overhead (%.1f m)", F.depth or -1))
  ok(F.height and math.abs(F.height - 6) < 0.2, string.format("the roof-to-floor height (%.1f m)", F.height or -1))
  ok(type(F.hazard) == "table" and F.hazard.drop ~= nil, "the hazards, with the drop ahead")
  ok(#F.cells() >= 1, "a region cell is marked visited")
  local recs, hanging_ok, total = 0, true, 0
  for _, c in pairs(store["cave.cells.Home"] or {}) do
    total = total + 1
    for _, r in ipairs(c.p or {}) do
      recs = recs + 1
      local K = CK.KINDS[r[12]]
      ok(K ~= nil, "a placement records its kind")
      -- hanging: from the roof, no lower than 2.2 m over the floor
      local rr = math.sqrt(r[2] ^ 2 + r[3] ^ 2 + r[4] ^ 2)
      if r[5] * r[2] + r[6] * r[3] + r[7] * r[4] < -0.9 * rr then
        local tip = rr - r[11] * 1.3
        if tip < 970 + 2.0 then hanging_ok = false end
      end
    end
  end
  ok(F.stats.gen > 0 and total > 0, "cells were dressed (" .. total .. ")")
  ok(recs > 0, "with formations (" .. recs .. ")")
  ok(hanging_ok, "hanging formations leave headroom over the floor")
  ok(F.stats.nodes <= F.params.maxNodes, "at most maxNodes nodes (" .. F.stats.nodes .. ")")
  local live = 0
  for _, n in ipairs(made) do
    if n.valid and n.name:sub(1, 5) == "Cave " then
      live = live + 1
      ok(n.parent and n.parent.name == "Home", "a formation is a child of the planet (body-local)")
      ok(n.model and n.model:match("^models/cave/.+_l[01]%.gltf$"), "a formation draws a cave model")
      ok(n.tint and n.tint.color, "a formation is tinted")
    end
  end
  ok(live > 0 and live <= 48, "formation nodes alive within the cap (" .. live .. ")")
  -- a second run over the same save reads the same placements and dresses nothing new
  local before = {}
  for k, c in pairs(store["cave.cells.Home"]) do before[k] = c.p end
  F.onDestroy()
  local F2, api2, B2, astro2, _, _, dug2 = cave_world(nil, store)
  B2.x = B.x; astro2.x = astro.x
  for step = 1, 40 do api2.time = 100 + step * 0.05; F2.update({}, 0.05) end
  local kept = true
  for k, p in pairs(before) do if store["cave.cells.Home"][k].p ~= p then kept = false end end
  ok(kept, "a fresh run over the save keeps every cell it already dressed")
  ok(F2.stats.nodes > 0, "…and shows the saved formations")
  -- dig away the rock under the formation nearest the eye: it goes for good
  local ex, ey, ez = astro2.x - B2.x, astro2.y + 1.6, astro2.z
  local victim, bd = nil, 1e9
  for _, c in pairs(store["cave.cells.Home"]) do
    for _, r in ipairs(c.p) do
      local d = math.sqrt((r[2] - ex) ^ 2 + (r[3] - ey) ^ 2 + (r[4] - ez) ^ 2)
      if r[11] > 0 and d < bd then victim, bd = r, d end
    end
  end
  dug2[#dug2 + 1] = { victim[2] - victim[5] * 0.25, victim[3] - victim[6] * 0.25, victim[4] - victim[7] * 0.25 }
  for step = 1, 300 do api2.time = 103 + step * 0.05; F2.update({}, 0.05) end
  ok(victim[11] == 0, "a formation whose rock is dug away is gone (and saved gone)")
  F2.onDestroy()
  -- out of the cave: no kind
  local store3 = {}
  local F3, api3, B3, astro3, _, _, _, cfg3 = cave_world(nil, store3)
  cfg3.enclosed = 0.0; cfg3.open = true
  for step = 1, 40 do api3.time = step * 0.05; F3.update({}, 0.05) end
  ok(F3.caveKind == nil, "under open sky there is no cave kind")
end

-- every kind dresses a cave with its own props
do
  local seen = {}
  for _, id in ipairs(CK.ORDER) do
    local store = {}
    local F, api, B, astro = cave_world(id, store)
    for step = 1, 200 do api.time = step * 0.05; astro.x = astro.x + 0.05; F.update({}, 0.05) end
    ok(F.caveKind == id, id .. ": the forced kind is published")
    local ids = {}
    for _, c in pairs(store["cave.cells.Home"] or {}) do
      for _, r in ipairs(c.p or {}) do ids[r[1]] = true end
    end
    local allowed = {}
    for _, p in ipairs(CK.KINDS[id].props) do allowed[p.id] = true end
    local n = 0
    for pid in pairs(ids) do
      n = n + 1
      ok(allowed[pid], id .. ": only its own props (" .. pid .. ")")
    end
    ok(n >= 1, id .. ": props placed (" .. n .. " kinds of prop)")
    F.onDestroy()
  end
end

-- ── underground: each kind its own ambience ─────────────────────────────────
do
  local R = 1000
  local B = { name = "Home", x = 0, y = 0, z = 0, radius = R, mu = 9.0 * R * R, soi = 1e9 }
  local astro = { x = 0, y = R, z = 0, valid = true }
  local plays = {}
  local light = { ambientR = 0.2, ambientG = 0.2, ambientB = 0.2, fog = true, fogColorR = 0.5, fogColorG = 0.5, fogColorB = 0.5,
                  fogEnd = 900, fogStart = 10, fogVolumetric = false }
  local cfK = { valid = true, caveKind = nil }
  local api = {
    time = 0, vec3 = function(x, y, z) return { x = x, y = y, z = z } end,
    find = function(n)
      if n == "Astronaut" then return astro end
      if n == "Lighting" then return { getcomponent = function() return light end } end
    end,
    findScript = function(k)
      if k == "planet_walker" then return { valid = true, onFoot = true } end
      if k == "vfx" then return { valid = true, airAt = function() return 1.0 end } end
      if k == "cave_field" then return cfK end
      if k == "cave_kinds" then return CK end
    end,
    save = { get = function() return { climMoist = 0.2 } end },
    space = { dominant = function() return "Home" end, body = function() return B end },
    terrain = { raycast = function(o, d, far)
      local px, py, pz = o.x - B.x, o.y - B.y, o.z - B.z
      local r = math.sqrt(px * px + py * py + pz * pz)
      local radial = (px * d.x + py * d.y + pz * d.z) / r
      local dist
      if radial > 0.99 then dist = R + 6 - r elseif radial < -0.99 then dist = r - R else dist = 8 end
      if dist <= 0 or dist > far then return nil end
      return { distance = dist, pos = { x = o.x + d.x * dist, y = o.y + d.y * dist, z = o.z + d.z * dist } }
    end },
    audio = { play = function(clip, a, b, c, o)
      local h = { clip = clip, vol = 0, lp = 0 }
      h.setVolume = function(self, v) self.vol = v end
      h.setLowpass = function(self, v) self.lp = v end
      h.stop = function(self) self.stopped = true end
      h.setPosition = function() end
      plays[#plays + 1] = h
      return h
    end },
  }
  local U = load("solar/scripts/underground.lua", api)
  U.params.effects = false
  local res = {}
  for _, id in ipairs({ "karst", "salt", "vent", "lava_tube", "ice", "chasm" }) do
    cfK.caveKind = id
    for step = 1, 400 do
      api.time = api.time + 0.05
      light.ambientR, light.ambientG, light.ambientB = 0.2, 0.2, 0.2   -- the weather writes each frame
      light.fogColorR, light.fogColorG, light.fogColorB, light.fogEnd = 0.5, 0.5, 0.5, 900
      U.update({}, 0.05)
      U.lateUpdate({}, 0.05)
    end
    local A = CK.KINDS[id].amb
    res[id] = { amb = light.ambientR + light.ambientG + light.ambientB, r = light.ambientR, b = light.ambientB, fog = light.fogEnd }
    ok(U.kindNow == id, id .. ": underground follows the cave's kind")
    ok(math.abs((U.ambK.floor or 0) - A.floor) < 0.01, id .. ": the ambient floor eased to the kind's")
    ok(math.abs(light.fogColorR - A.fog[1]) < 0.06, string.format("%s: the haze takes the kind's colour (%.3f vs %.3f)", id, light.fogColorR, A.fog[1]))
    ok(light.fogEnd <= 110 * A.fog[5] + 1, id .. ": the haze closes in to the kind's reach (" .. light.fogEnd .. ")")
    if A.loop then
      local on = false
      for _, h in ipairs(plays) do if h.clip == A.loop.clip and not h.stopped and h.vol > 0.01 then on = true end end
      ok(on, id .. ": its bed plays (" .. A.loop.clip .. ")")
    end
  end
  ok(res.salt.amb > res.karst.amb * 3, "a salt cavern is far brighter than a karst gallery")
  ok(res.lava_tube.r > res.lava_tube.b * 1.5, "a lava tube's dark is red")
  ok(res.ice.b > res.ice.r * 1.4, "an ice cave's is blue")
  ok(res.vent.fog < res.karst.fog, "a vent's haze closes in nearer than a karst cave's")
  -- leaving the kinds: the bed fades and stops
  cfK.caveKind = nil
  for step = 1, 600 do api.time = api.time + 0.05; U.update({}, 0.05); U.lateUpdate({}, 0.05) end
  local still = 0
  for _, h in ipairs(plays) do if h.clip:find("cave_vent") and not h.stopped then still = still + 1 end end
  ok(still == 0, "out of the kinds, the beds stop")
end

-- ── flashlight: spare cells ─────────────────────────────────────────────────
do
  local bag = { flashlight = 1, cell = 2 }
  local fill = { flashlight = { 0.0 } }
  local store = {}
  local inv = {
    valid = true,
    itemCount = function(_, id) return bag[id] or 0 end,
    fills = function(_, id) local t = store["inv.fill.astro"]; return (t and t[id]) or fill[id] or {} end,
    removeItem = function(_, id, n) if (bag[id] or 0) >= n then bag[id] = bag[id] - n return n end return 0 end,
  }
  local api = {
    time = 0,
    findScript = function(k) if k == "inventory" then return inv end end,
    save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end },
  }
  local FL = load("solar/scripts/flashlight.lua", api)
  ok(FL.cellsLeft() == 2, "two spare cells counted")
  ok(math.abs(FL.minutesLeft() - 0) < 1e-6, "a flat torch has no minutes left")
  local okOn = FL.setOn(true)
  ok(okOn and FL.on, "L on a flat torch swaps in a spare cell and lights")
  ok(FL.cellsLeft() == 1, "…using one cell")
  ok(math.abs(FL.minutesLeft() - 240) < 1e-6, "…4 h of light (" .. tostring(FL.minutesLeft()) .. ")")
  FL.setOn(false)
  ok(FL.setOn(true) and FL.cellsLeft() == 1, "a charged torch takes no cell")
end

-- ── the helmet lamps share the lamp cell (Ty's coordinator, 2026-11-10) ──────
do
  local bag = { cell = 1 }            -- no torch: the suit's own lamp cell
  local store = {}
  local suit = { valid = true, beamLit = 2.0, beamEmergency = false }
  local inv = {
    valid = true,
    itemCount = function(_, id) return bag[id] or 0 end,
    fills = function() return {} end,
    removeItem = function(_, id, n) if (bag[id] or 0) >= n then bag[id] = bag[id] - n return n end return 0 end,
  }
  local api = {
    time = 0,
    findScript = function(k) if k == "inventory" then return inv end if k == "suit" then return suit end end,
    find = function() return nil end,
    save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end },
  }
  local FL = load("solar/scripts/flashlight.lua", api)
  ok(FL.cellLevel() == 100, "without a torch the suit's lamp cell starts full")
  ok(math.abs(FL.drawNow() - FL.HELMET_DRAW) < 1e-9, "the helmet lamps draw at a share of the torch's rate")
  ok(math.abs(FL.minutesLeft() - 240 / FL.HELMET_DRAW) < 1e-6, "…so the cell lasts longer on them (" .. FL.minutesLeft() .. " min)")
  for _ = 1, 600 do api.time = api.time + 1; FL.update({}, 1.0) end
  local lvl = FL.cellLevel()
  local want = 100 - 600 * FL.HELMET_DRAW * 100 / (4 * 3600)
  ok(math.abs(lvl - want) < 0.5, string.format("ten minutes of helmet lamps drain the cell (%.2f, want %.2f)", lvl, want))
  store["crew.lampcell.astro"] = 0
  suit.beamEmergency = true
  ok(FL.drawNow() == 0, "the emergency glow draws nothing")
  ok(FL.swapCell() and FL.cellLevel() == 100 and bag.cell == 0, "a spare cell goes into the suit's lamp housing")
end

if #failures == 0 then
  print(string.format("CAVE KINDS SMOKE OK — %d checks passed (%d formations covered)", checks, nform))
  os.exit(0)
else
  print("CAVE KINDS SMOKE FAILURES:")
  local shown = {}
  for _, f in ipairs(failures) do
    if not shown[f] then shown[f] = true; print("  ✗ " .. f) end
  end
  print(string.format("(%d of %d checks failed)", #failures, checks))
  os.exit(1)
end
