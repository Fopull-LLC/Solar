-- SMOKE HARNESS: there is no set water level (climate.lua, the water pass S1).
--
--   luajit solar/tests/smoke_water_reach.lua
--
-- A 100 m world with a sea at radius 95, on an analytic field:
--  * an OCEAN basin round +X (a bowl carved down to r 70);
--  * an INLAND PIT round +Z, 15 m wide and 4 m under the sea's radius, that
--    no sea can reach: it must read DRY (the old 8 m ring test called it sea);
--  * a TRENCH pit beside the ocean whose mouth opens into it: WET;
--  * a LAKE bowl at +Y filled to r 97, and a PIT dug 22 m from it: the pit
--    seeps full to the lake's level over ~35 s (a pool), and then reads wet;
--  * a channel dug through the lake's rim: a BREACH, and the lake drains.
-- The field is read where the planet is each frame (it moves on its rails).

local T = 0.0
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end

local BODY = { x = 0, y = 0, z = 0, radius = 100, name = "W" }
local SEA = 95
local digs = {}   -- balls taken out of the ground by the test's "laser"
local function sdf_local(x, y, z)
  local d = len(x, y, z) - 100
  -- the ocean basin
  d = math.max(d, -(len(x - 160, y, z) - 90))
  -- the inland pit (+Z)
  d = math.max(d, -(len(x, y, z - 106) - 15))
  -- the trench pit, 35° from +X toward +Z, its mouth reaching the ocean
  local a = math.rad(35)
  d = math.max(d, -(len(x - 100 * math.cos(a), y, z - 100 * math.sin(a)) - 12))
  -- the lake bowl (+Y)
  d = math.max(d, -(len(x, y - 100, z) - 15))
  -- two sealed cave chambers under the land: a karst sump (-X, +0.3Y) and a
  -- lava tube's (-X, -0.3Y), 6 m balls centred 12 m down
  local cl = 1 / math.sqrt(1 + 0.09)
  d = math.max(d, -(len(x + 88 * cl, y - 88 * 0.3 * cl, z) - 6))
  d = math.max(d, -(len(x + 88 * cl, y + 88 * 0.3 * cl, z) - 6))
  for _, g in ipairs(digs) do d = math.max(d, -(len(x - g[1], y - g[2], z - g[3]) - g[4])) end
  return d
end
local reads, misaimed = 0, 0
local COLD = false   -- the field not answering (ground streaming in)
local function sdf(x, y, z)
  if COLD then return nil end
  reads = reads + 1
  local lx, ly, lz = x - BODY.x, y - BODY.y, z - BODY.z
  if len(lx, ly, lz) > 200 then misaimed = misaimed + 1 end
  return sdf_local(lx, ly, lz)
end

local saved = {}
local serial, feed = 0, {}
UG = { kindNow = nil }   -- the fake underground script: what cave kind the eye is in
local EYE = nil          -- body-relative eye override (nil = over the lake)
local nodes, meshes, freed = {}, {}, 0
local API = {
  space = {
    dominant = function() return "W" end,
    body = function(n) return n == "W" and { x = BODY.x, y = BODY.y, z = BODY.z, radius = 100, name = "W" } or nil end,
  },
  save = {
    get = function(k)
      if k == "world.W" then
        return { sea = SEA, radius = 100, relief = 6, kind = "temperate", atmo = 1, hydro = true, shape = { low = 10 },
                 water = { state = "liquid", deep = { 0.03, 0.14, 0.22 }, shallow = { 0.12, 0.46, 0.5 }, clarity = 3 } }
      end
      if k == "hydro.W" then
        return { lakes = { { x = 0, y = 97, z = 0, level = -3, reach = 10, depth = 5 } }, rivers = {} }
      end
      return saved[k]
    end,
    set = function(k, v) saved[k] = v end,
  },
  terrain = {
    query = sdf, busy = function() return false end,
    editSerial = function() return serial end,
    editsSince = function(s) local out = {}; for _, e in ipairs(feed) do if e.serial > s then out[#out + 1] = e end end; return out end,
  },
  mesh = { build = function(t) meshes[#meshes + 1] = t; return "mesh:" .. #meshes end, free = function() freed = freed + 1 end },
  createNode = function(name, parent, fn)
    local n = { name = name, valid = true }
    function n:setShaderParam() end
    function n:material() return {} end
    function n:setMaterial() end
    function n:destroy() self.valid = false end
    nodes[#nodes + 1] = n
    if fn then fn(n) end
  end,
  -- the water sheets come from prefabs (WaterSheet / RiverSheet) now
  spawn = function(prefab, pos, fn, parent)
    local n = { name = prefab, valid = true, prefab = prefab }
    function n:setShaderParam() end
    function n:material() return {} end
    function n:setMaterial() end
    function n:destroy() self.valid = false end
    nodes[#nodes + 1] = n
    if fn then fn(n) end
  end,
  app = { wallClock = function() return os.clock() end },
  findScript = function(n) if n == "underground" then return UG end return nil end,
  find = function(n) if n == "Astronaut" then return { x = BODY.x, y = BODY.y + 102, z = BODY.z } end end,
  log = function() end,
  print = function() end,
  vec3 = function(x, y, z) return { x = x, y = y, z = z } end,
}
local env = setmetatable({}, { __index = function(_, k)
  if k == "time" then return T end
  return API[k] or _G[k]
end })
local chunk = assert(loadfile("solar/scripts/climate.lua"))
setfenv(chunk, env)
chunk()
env.params = {}
for k, v in pairs(env.defaults or {}) do env.params[k] = v end

local fails = 0
local function check(ok, msg)
  print((ok and "ok   " or "FAIL ") .. msg)
  if not ok then fails = fails + 1 end
end

-- the planet on its rails: 30 m a frame, the eye riding it over the lake
local function frames(n)
  for _ = 1, n do
    T = T + 1 / 60
    BODY.x = BODY.x + 30
    if EYE then env.setEye(BODY.x + EYE[1], BODY.y + EYE[2], BODY.z + EYE[3])
    else env.setEye(BODY.x, BODY.y + 102, BODY.z) end
    env.update({}, 1 / 60)
  end
end
local function depth_at(ux, uy, uz, r)
  local l = len(ux, uy, uz)
  return env.seaDepth(BODY.x + ux / l * r, BODY.y + uy / l * r, BODY.z + uz / l * r)
end
local function dig(x, y, z, r)
  serial = serial + 1
  digs[#digs + 1] = { x, y, z, r }
  feed[#feed + 1] = { serial = serial, body = "W", x = x, y = y, z = z, r = r, kind = "dig" }
end

frames(30)   -- the lake is built, the edit feed is primed

-- 1. the sea's reach
local ocean = depth_at(1, 0, 0, 93)
check(ocean ~= nil and ocean > 1.9 and ocean < 2.1, string.format("open ocean, 2 m under the surface, reads 2 m of water (%s)", tostring(ocean)))
local pit = depth_at(0, 0, 1, 93)
frames(6)
pit = depth_at(0, 0, 1, 93)
check(pit == -1, string.format("the inland pit under the sea's radius reads DRY (%s), though it is 20 m wide", tostring(pit)))
local a = math.rad(35)
local trench = depth_at(math.cos(a), 0, math.sin(a), 93)
frames(6)
trench = depth_at(math.cos(a), 0, math.sin(a), 93)
check(trench ~= nil and trench > 1.9, string.format("the trench pit, open to the ocean, reads WET (%s)", tostring(trench)))
local st = env.reachStats
check(st.floods >= 3 and st.dry >= 1 and st.wet >= 2, string.format("reach floods: %d (%d wet, %d dry, %d cold)", st.floods, st.wet, st.dry, st.cold))
-- the second read of a cell is a lookup, not a flood
local f0 = st.floods
for _ = 1, 20 do depth_at(0, 0, 1, 93); depth_at(1, 0, 0, 93) end
check(env.reachStats.floods == f0, "repeated reads hit the cell cache (no new floods)")

-- 1b. the answers STICK (cpuperf, 11-13: a pit beside the sea flipped dry /
-- wet between reads and the walker flipped between running and swimming):
-- a cold field changes nothing, a fresh spot under a cold field is dry (no
-- ring-test guess), and a dig near the sea's radius keeps every answer
-- until its new flood lands.
COLD = true
local c_pit, c_tr, c_oc = depth_at(0, 0, 1, 93), depth_at(math.cos(a), 0, math.sin(a), 93), depth_at(1, 0, 0, 93)
check(c_pit == -1 and c_tr and c_tr > 1.9 and c_oc and c_oc > 1.9,
  string.format("under a cold field the pit stays dry and the trench and the ocean wet (%s, %s, %s)", tostring(c_pit), tostring(c_tr), tostring(c_oc)))
local c_new = depth_at(0.3, 0, 1, 93)
check(c_new == -1, string.format("a spot never asked before, under a cold field, is dry: no guess (%s)", tostring(c_new)))
COLD = false
dig(95.5, 0, 30, 1.2)   -- a small dig at the sea's radius: every cell goes stale
local flips = 0
for _ = 1, 30 do
  frames(1)
  local p1, p2 = depth_at(0, 0, 1, 93), depth_at(math.cos(a), 0, math.sin(a), 93)
  if p1 ~= -1 or not (p2 and p2 > 1.9) then flips = flips + 1 end
end
check(flips == 0, string.format("after a dig near the sea the pit stays dry and the trench wet through the re-floods (%d flips in 30 frames)", flips))

-- 2. a pit dug 22 m from the lake seeps full to the lake's level
local lake_depth0 = depth_at(0, 1, 0, 96)
check(lake_depth0 ~= nil and lake_depth0 > 0.9, string.format("the lake holds water 1 m under its level (%s)", tostring(lake_depth0)))
local pa = 0.22
local px, py, pz = math.sin(pa) * 101, math.cos(pa) * 101, 0
local pre = depth_at(px, py, pz, 96)
check(pre == nil or pre <= 0, string.format("before the dig, the ground there is dry (%s)", tostring(pre)))
dig(px, py, pz, 6)
frames(120)
local wn = env.waterNear()
local pool = nil
for _, p in pairs(wn.poolSpecs or {}) do if p.kind == "pit" then pool = p end end
check(pool ~= nil, "the dig made a PIT POOL spec")
if pool then
  check(math.abs(pool.target - (-3)) < 0.05, string.format("…whose target is the lake's level (−3 m: %.2f)", pool.target))
  frames(60 * 40)
  check(math.abs(pool.level - pool.target) < 0.01, string.format("…and it filled to it in 40 s (level %.2f)", pool.level))
  local d = depth_at(px, py, pz, 96)
  check(d ~= nil and d > 0.5, string.format("the full pit reads as water 1 m under its surface (%s)", tostring(d)))
  check(saved["pools.W"] ~= nil and #saved["pools.W"] >= 1, "the pool is in the save (pools.W)")
end

-- 2b. a pit 30 m from the lake's shore (45 m from its centre) stays dry:
-- water seeps only beside water you can see (Ty, 11-12b)
local qa = 0.45
dig(math.sin(qa) * 101, math.cos(qa) * 101, 0, 6)
frames(120)
local n_near = 0
for _, p in pairs(env.waterNear().poolSpecs or {}) do if p.kind == "pit" then n_near = n_near + 1 end end
check(n_near == 1, string.format("a pit 30 m from the lake's shore stays dry (%d pit pools)", n_near))
check(saved["pools.W"] ~= nil and saved["pools.W"][1].v == 2, "pool records carry their rule's version")

-- 3. a dry pit far from any water stays dry
local dx, dy, dz = 0, math.cos(math.rad(60)), -math.sin(math.rad(60))
dig(dx * 101, dy * 101, dz * 101, 6)
frames(120)
local n_pits = 0
for _, p in pairs(env.waterNear().poolSpecs or {}) do if p.kind == "pit" then n_pits = n_pits + 1 end end
check(n_pits == 1, string.format("a pit 60° from every water stays dry (%d pit pools)", n_pits))

-- 4. a channel dug through the lake's rim drains it
local rimx = 16.0
dig(rimx, 97.5, 0, 3)
dig(rimx + 3, 97.3, 0, 3)
dig(rimx + 6, 97.1, 0, 3)
frames(90)
local lv = env.waterNear().levels[1]
local tg = env.waterNear().targets[1]
check(tg ~= nil and tg < -3.5, string.format("the breach sets the lake a lower target (%s)", tostring(tg)))
frames(60 * 50)
lv = env.waterNear().levels[1]
check(lv ~= nil and tg ~= nil and math.abs(lv - tg) < 0.05 and lv < -3.5,
  string.format("the lake drained to the breach's height (level %s, target %s)", tostring(lv), tostring(tg)))
check(saved["lakeLevel.W"] ~= nil, "the live level is in the save (lakeLevel.W)")
local d2 = depth_at(0, 1, 0, 96.6)
check(d2 == nil or d2 <= 0, string.format("0.4 m under the old level is air now (%s)", tostring(d2)))
local d3 = depth_at(0, 1, 0, 95.0)
check(d3 ~= nil and d3 > 0.5, string.format("…and 2 m under it is still lake (%s)", tostring(d3)))
-- 5. a karst cave's lowest chamber holds a sump; a lava tube's does not
local cl = 1 / math.sqrt(1 + 0.09)
local n_before = 0
for _, p in pairs(env.waterNear().poolSpecs or {}) do if p.kind == "cave" then n_before = n_before + 1 end end
UG.kindNow = "lava_tube"
EYE = { -88 * cl, -88 * 0.3 * cl, 0 }
frames(60 * 8)
local n_lava = 0
for _, p in pairs(env.waterNear().poolSpecs or {}) do if p.kind == "cave" then n_lava = n_lava + 1 end end
check(n_lava == n_before, string.format("a lava tube's chamber gets no sump (%d cave pools)", n_lava))
UG.kindNow = "karst"
EYE = { -88 * cl, 88 * 0.3 * cl, 0 }
frames(60 * 8)
local sump = nil
for _, p in pairs(env.waterNear().poolSpecs or {}) do if p.kind == "cave" then sump = p end end
check(sump ~= nil, "a karst chamber's floor holds a SUMP")
if sump then
  check(sump.level > -18.5 and sump.level < -15, string.format("…at a level over the chamber's floor (level %.2f m, floor %.2f)", sump.level, sump.floor or -99))
  frames(60)
  local cd = depth_at(-cl, 0.3 * cl, 0, 100 + sump.level - 0.6)
  check(cd ~= nil and cd > 0.3, string.format("0.6 m under the sump's surface is water (%s)", tostring(cd)))
  local ad = depth_at(-cl, 0.3 * cl, 0, 100 + sump.level + 1.0)
  check(ad == nil or ad <= 0, string.format("1 m over it is cave air, not sea (%s)", tostring(ad)))
end
EYE, UG.kindNow = nil, nil
check(misaimed == 0, "every read is at the planet's position that frame (" .. misaimed .. " aimed at where it was)")

if fails > 0 then print(fails .. " FAILED"); os.exit(1) end
print("all water reach checks passed")
