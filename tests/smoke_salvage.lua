-- SMOKE: SALVAGE — the suit pack the sea keeps, and taking it back.
--
-- Running out of air under water used to delete the pack (planet_walker
-- blackout_end). Now planet_walker hands the pack to scripts/salvage.lua,
-- which drops its materials into a crate on the bottom where the crew went
-- down, keeps it in the save, marks it, and gives it back on E. This drives
-- the real salvage.lua and the real inventory.lua / materials.lua against a
-- stub world (a planet that moves on its rails, a sea floor 9 m down):
--   * a drop moves the pack's materials into the crate — nothing destroyed,
--     the suit's gear stays on the crew, an empty pack drops nothing;
--   * the crate lies on the bottom under the drop point, body-relative (it
--     rides the planet), and its node is spawned parented to the planet and
--     sinks there from the drop point;
--   * it survives a reload (the save), and a second blackout makes a second crate;
--   * the prompt comes up within reach, E puts the contents back; a full pack
--     takes what fits and the rest stays in the crate; an emptied crate goes;
--   * the marker draws the crate's name, mass and distance on screen.
--
--   luajit solar/tests/smoke_salvage.lua

local T = 0.0
local failures = {}
local function check(cond, what)
  if not cond then failures[#failures + 1] = "CHECK FAILED: " .. what end
end

-- ── the stub world ──────────────────────────────────────────────────────────
local store = {}
local logs = {}
local API = {}
API.save = {
  get = function(k) return store[k] end,
  set = function(k, v) store[k] = v end,
  delete = function(k) store[k] = nil end,
}
API.log = function(s) logs[#logs + 1] = s end
API.print = function() end
API.vec3 = function(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end

-- a planet of radius 500 m on rails (its centre moves), the sea floor 9 m
-- under any point near the surface
local PLANET = { name = "Ground", x = 1000.0, y = 0.0, z = 0.0, radius = 500, mu = 9.8 * 500 * 500 }
API.space = {
  body = function(n) return n == "Ground" and PLANET or nil end,
  dominant = function() return "Ground" end,
}
local FLOOR = 9.0
local rays = 0
API.raycast = function(x, y, z, dx, dy, dz, max)
  rays = rays + 1
  return { x = x + dx * FLOOR, y = y + dy * FLOOR, z = z + dz * FLOOR, distance = FLOOR, nx = -dx, ny = -dy, nz = -dz }
end

local function node(name)
  local n = { name = name, valid = true, x = 0, y = 0, z = 0 }
  function n:destroy() self.valid = false end
  function n:setUp(u, f) self.up = u end
  return n
end
local planet_node = node("Ground")
local spawned = {}
API.find = function(n) return n == "Ground" and planet_node or nil end
API.spawn = function(prefab, pos, cb, parent)
  local n = node(prefab)
  n.x, n.y, n.z, n.parent, n.prefab = pos.x, pos.y, pos.z, parent, prefab
  spawned[#spawned + 1] = n
  if cb then cb(n) end
end

local keys = {}
API.input = { pressed = function(k) return keys[k] == true end }

local drawn = {}
API.draw = {
  text = function(x, y, s) drawn[#drawn + 1] = s end,
  rect = function() end, circle = function() end, circleOutline = function() end,
}
API.camera = {
  screenRect = function() return 0, 0, 1280, 720 end,
  worldToScreen = function() return 640, 300, 10, true end,
}

-- ── the scripts ─────────────────────────────────────────────────────────────
local envs = {}
API.findScript = function(kind) return envs[kind] end
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
  env.valid = true
  envs[kind] = env
  return env
end
local M = load_script("solar/scripts/materials.lua", "materials")
local inv = load_script("solar/scripts/inventory.lua", "inventory")
local sv = load_script("solar/scripts/salvage.lua", "salvage")
local ASTRO = node("Astronaut")
envs.planet_walker = { onFoot = true, node = ASTRO, valid = true }
local caption
envs.big_caption = { show = function(t, s) caption = { t, s } end, valid = true }

local function tick(n)
  for _ = 1, n or 1 do
    T = T + 1 / 60
    sv.update(nil, 1 / 60)
    keys = {}
  end
end

-- ── 1. drop ─────────────────────────────────────────────────────────────────
inv.ensureKit("astro")
inv.addGear("astro", "beacon", 1)
check(inv.add("astro", "iron", 10) == 10 and inv.add("astro", "crystal", 5) == 5, "the pack is loaded")
local pack_kg = inv.mass("astro") - inv.gearMass("astro")
check(math.abs(pack_kg - (10 * M.kg("iron") + 5 * M.kg("crystal"))) < 1e-9, "the pack weighs its materials")

-- the crew goes down 3 m under the surface, 20 m off the planet's +X
local wx, wy, wz = PLANET.x + 503.0, PLANET.y + 20.0, PLANET.z
local id, kg, e = sv.drop("Ground", wx, wy, wz, ASTRO)
check(id ~= nil and math.abs(kg - pack_kg) < 1e-6, string.format("the drop takes the whole pack (%.1f of %.1f kg)", kg or -1, pack_kg))
check(inv.count("astro", "iron") == 0 and inv.count("astro", "crystal") == 0, "...out of the pack")
check(inv.count(sv.containerOf(id), "iron") == 10 and inv.count(sv.containerOf(id), "crystal") == 5,
  "...and into the crate, unit for unit (nothing deleted)")
check(inv.gearCount("astro", "beacon") == 1 and inv.gearCount("astro", "laser") == 1,
  "the suit's gear stays with the crew")
-- the bottom: 9 m further down the local vertical, plus the crate's half height
local rel = { x = wx - PLANET.x, y = wy - PLANET.y, z = wz - PLANET.z }
local rl = math.sqrt(rel.x ^ 2 + rel.y ^ 2 + rel.z ^ 2)
local rec = store["salvage." .. id]
check(type(rec) == "table" and rec.b == "Ground", "the crate is in the save")
local bed_r = math.sqrt(rec.x ^ 2 + rec.y ^ 2 + rec.z ^ 2)
check(math.abs(bed_r - (rl - FLOOR + 0.4)) < 1e-6, string.format("...lying on the bottom (%.2f m from the centre, dropped at %.2f)", bed_r, rl))
check(math.abs(rec.sx - rel.x) < 1e-9 and math.abs(rec.sy - rel.y) < 1e-9, "...and remembers where it was dropped")
local id0 = sv.drop("Ground", wx, wy, wz, ASTRO)
check(id0 == nil, "an empty pack drops nothing")

-- ── 2. in the world ─────────────────────────────────────────────────────────
tick(2)
local crate
for _, n in ipairs(spawned) do if n.prefab == "SalvageCrate" and n.valid then crate = n end end
check(crate and crate.parent == planet_node, "a SalvageCrate node is spawned, parented to its planet")
check(crate and math.abs(crate.x - rec.sx) < 0.2 and math.abs(crate.y - rec.sy) < 0.2,
  "...where it was dropped (body-relative)")
tick(60 * 8)
check(crate and math.abs(crate.x - rec.x) < 1e-6 and math.abs(crate.y - rec.y) < 1e-6 and math.abs(crate.z - rec.z) < 1e-6,
  "...and it sinks to the bottom")
-- the planet moves on its rails: the crate's world position goes with it
PLANET.x = PLANET.x + 37.0
local L = sv.list()
check(#L == 1 and math.abs(L[1].x - (PLANET.x + rec.x)) < 1e-9, "the crate rides its planet (world = planet + body-relative)")

-- ── 3. the marker ───────────────────────────────────────────────────────────
ASTRO.x, ASTRO.y, ASTRO.z = PLANET.x + 600, PLANET.y, PLANET.z
drawn = {}
tick(1)
sv.lateUpdate(nil, 1 / 60)
local marked = false
for _, s in ipairs(drawn) do if s:find("SUIT PACK", 1, true) and s:find("kg", 1, true) and s:find(" m", 1, true) then marked = true end end
check(marked, "the marker names the crate, its mass and the distance: " .. table.concat(drawn, " | "))
check(not sv.prompting(), "...and from afar there's no prompt")

-- ── 4. reload ───────────────────────────────────────────────────────────────
-- a fresh script over the same save (a scene load takes the old nodes with
-- it): the crate is still there
for _, n in ipairs(spawned) do n.valid = false end
local sv2 = load_script("solar/scripts/salvage.lua", "salvage")
sv = sv2
local L2 = sv.list()
check(#L2 == 1 and L2[1].id == id and math.abs((L2[1].kg or 0) - pack_kg) < 1e-6, "the crate survives a reload")
tick(70)
local after = 0
for _, n in ipairs(spawned) do if n.prefab == "SalvageCrate" and n.valid then after = after + 1 end end
check(after >= 1, "...and its node comes back")

-- ── 5. recover ──────────────────────────────────────────────────────────────
-- the crew swims up to it: the prompt, then E
local w = sv.list()[1]
ASTRO.x, ASTRO.y, ASTRO.z = w.x + 1.0, w.y + 1.0, w.z
tick(1)
check(sv.prompting(), "within reach the E prompt comes up")
drawn = {}
sv.lateUpdate(nil, 1 / 60)
local prompt = false
for _, s in ipairs(drawn) do if s:find("Recover the suit pack", 1, true) then prompt = true end end
check(prompt, "...and says so on screen")
-- first, with the pack nearly full: it takes what fits
check(inv.add("astro", "regolith", 45) == 45, "the crew has refilled the pack meanwhile")
local room = inv.free("astro")
keys.e = true
tick(1)
local left_kg = inv.mass(sv.containerOf(id))
check(left_kg > 0 and inv.free("astro") < 3.0, string.format(
  "a full pack takes what fits (%.1f kg free before, %.1f kg left in the crate)", room, left_kg))
check(caption and caption[1] == "SALVAGE", "...and says what it couldn't take: " .. tostring(caption and caption[2]))
check(#sv.list() == 1, "...the crate stays with the rest")
-- empty the pack (sell the regolith), go back
inv.remove("astro", "regolith", 45)
keys.e = true
tick(1)
check(inv.count("astro", "iron") == 10 and inv.count("astro", "crystal") == 5, "E puts every unit back in the pack")
check(#sv.list() == 0 and inv.isEmpty(sv.containerOf(id)), "...and the emptied crate goes")
check(store["salvage." .. id] == nil and #(store["salvage.list"] or {}) == 0, "...from the save too")
check(caption and caption[1] == "PACK RECOVERED", "...with a caption: " .. tostring(caption and caption[2]))
local gone = true
for _, n in ipairs(spawned) do if n.prefab == "SalvageCrate" and n.valid then gone = false end end
check(gone, "...and its node")

-- ── 6. two crates ───────────────────────────────────────────────────────────
inv.add("astro", "ice", 3)
local a1 = sv.drop("Ground", wx, wy, wz, ASTRO)
inv.add("astro", "copper", 2)
local a2 = sv.drop("Ground", wx + 30, wy, wz, ASTRO)
check(a1 and a2 and a1 ~= a2 and #sv.list() == 2, "a second blackout leaves a second crate")
local near = sv.nearest(PLANET.x + 533, wy - PLANET.y + PLANET.y, wz, 50)
check(near and near.id == a2, "nearest picks the closer one")
check(sv.fromBase(near) == nil, "with no base on that world the caption names no distance")
store["base.body"], store["base.x"], store["base.y"], store["base.z"] = "Ground", 500, 0, 0
check(sv.fromBase(near) and sv.fromBase(near):find("from the base", 1, true), "with one it does: " .. tostring(sv.fromBase(near)))

if #failures > 0 then
  print("SALVAGE SMOKE FAILURES:")
  for _, f in ipairs(failures) do print("  ✗ " .. f) end
  os.exit(1)
end
print("SALVAGE SMOKE OK — the pack sinks as a crate, survives a reload, and comes back on E")
