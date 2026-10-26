-- SMOKE HARNESS: where the water is.
--
--   "all caves / underground in general is treated as underwater ... the rest
--   of the underground has air. this means cave diving explorations will be
--   possible again since you arent forced underwater constantly"
--
-- The sea was a sphere: everything under its radius was "in the sea", so every
-- cave below sea level was water. climate.seaDepth now asks whether the sea can
-- REACH the point: the column up to its surface is open and the surface there
-- is open sea, or the point is in a cave that connects to open water through
-- passages below the sea's level (a bounded flood fill, run a slice a frame in
-- climate.update). Run against an analytic planet with a dry grotto under the
-- land, a sealed bubble under the seabed, a sea cave with a tunnel out to the
-- seabed, and a pit dug below sea level from dry land.
--
-- Also flora_gen.fadeBands: every scatter layer dissolves out at its reach.
--
--   luajit solar/tests/smoke_water.lua

local T = 0.0
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local function norm(x, y, z) local l = len(x, y, z); return x / l, y / l, z / l end

-- ── the planet ──────────────────────────────────────────────────────────────
-- Radius 100, sea at 98. Land (ground at 110) where x > 0, seabed (ground at 90)
-- where x < 0.
local SEA = 98
local function ground(ux, uy, uz)
  local t = math.max(0, math.min(1, (ux + 0.05) / 0.1))
  return 90 + 20 * t * t * (3 - 2 * t)
end
local function at(ux, uy, uz, r) local a, b, c = norm(ux, uy, uz); return a * r, b * r, c * r end
local function seg_dist(px, py, pz, ax, ay, az, bx, by, bz)
  local dx, dy, dz = bx - ax, by - ay, bz - az
  local t = ((px - ax) * dx + (py - ay) * dy + (pz - az) * dz) / (dx * dx + dy * dy + dz * dz)
  t = math.max(0, math.min(1, t))
  return len(px - ax - dx * t, py - ay - dy * t, pz - az - dz * t)
end
-- Hollows: spheres { x, y, z, r } and tunnels { a = {x,y,z}, b = {x,y,z}, r }.
local GROTTO = { at(1, 0.2, 0, 94) }; GROTTO[4] = 3.0          -- under the land, below sea level
local BUBBLE = { at(-1, 0, 0.35, 84) }; BUBBLE[4] = 3.0        -- sealed, under the seabed
local SEACAVE = { at(-1, 0.3, 0, 84) }; SEACAVE[4] = 3.0       -- under the seabed, with a way out
local TUNNEL = { a = { SEACAVE[1], SEACAVE[2], SEACAVE[3] }, b = { at(-1, 0.42, 0, 92) }, r = 1.6 }
local PIT = { a = { at(1, -0.25, 0, 95) }, b = { at(1, -0.25, 0, 115) }, r = 2.5 }
local function sdf(x, y, z)
  local r = len(x, y, z)
  local ux, uy, uz = x / r, y / r, z / r
  local d = r - ground(ux, uy, uz)          -- negative inside rock
  for _, s in ipairs({ GROTTO, BUBBLE, SEACAVE }) do
    d = math.max(d, s[4] - len(x - s[1], y - s[2], z - s[3]))
  end
  for _, t in ipairs({ TUNNEL, PIT }) do
    d = math.max(d, t.r - seg_dist(x, y, z, t.a[1], t.a[2], t.a[3], t.b[1], t.b[2], t.b[3]))
  end
  return d
end

local API = {
  space = {
    dominant = function() return "W" end,
    body = function(n) return n == "W" and { x = 0, y = 0, z = 0, radius = 100, name = "W" } or nil end,
  },
  save = { get = function(k) if k == "world.W" then return { sea = SEA, radius = 100, relief = 10, kind = "canyon" } end end,
           set = function() end },
  terrain = { query = function(x, y, z) return sdf(x, y, z) end },
  findScript = function() return nil end,
  find = function() return nil end,
  log = function() end,
  vec3 = function(x, y, z) return { x = x, y = y, z = z } end,
}
local function load_script(path)
  local env = setmetatable({}, { __index = function(_, k)
    if k == "time" then return T end
    return API[k] or _G[k]
  end })
  local chunk = assert(loadfile(path))
  setfenv(chunk, env)
  chunk()
  env.params = {}
  for k, v in pairs(env.defaults or {}) do env.params[k] = v end
  return env
end
local cl = load_script("solar/scripts/climate.lua")

local checks = {}
local function check(desc, ok, detail)
  checks[#checks + 1] = { desc = desc, ok = ok and true or false, detail = detail }
end
local function run(secs)
  for _ = 1, math.floor(secs * 60) do T = T + 1 / 60; cl.update({}, 1 / 60) end
end

-- Sanity: the hollows are open and the rock round them is rock.
check("the grotto is air in the field", sdf(GROTTO[1], GROTTO[2], GROTTO[3]) > 2)
check("…under rock", sdf(at(1, 0.2, 0, 99)) < 0)

-- Open sea: wet, as deep as it is under the surface.
local sx, sy, sz = at(-1, -0.3, 0, 95)
local d = cl.seaDepth(sx, sy, sz)
check("open sea is water", d and math.abs(d - 3) < 1e-6, d)
check("…and the swimmer reads it so", cl.isUnderwater(sx, sy, sz) == true)
check("above the sea is air", not cl.isUnderwater(at(-1, -0.3, 0, 99)))

-- A grotto under the land, below sea level: air (it was water before).
local gx, gy, gz = GROTTO[1], GROTTO[2], GROTTO[3]
check("a grotto under the land, below sea level, is air", cl.isUnderwater(gx, gy, gz) == false,
  cl.seaDepth(gx, gy, gz))
check("…its column is roofed", cl.columnOpen(0, 0, 0, gx, gy, gz, SEA) == false)
run(2)
check("…and stays air once its cave has been looked at", cl.isUnderwater(gx, gy, gz) == false)

-- A sealed bubble under the seabed: air, though the sea is over it.
local bx, by, bz = BUBBLE[1], BUBBLE[2], BUBBLE[3]
check("a sealed hollow under the seabed reads dry at first", cl.isUnderwater(bx, by, bz) == false)
run(2)
check("…and stays dry: nothing connects it to the sea", cl.isUnderwater(bx, by, bz) == false)

-- A sea cave with a tunnel out to the seabed: flooded, once the fill finds the way.
local cx, cy, cz = SEACAVE[1], SEACAVE[2], SEACAVE[3]
check("a sea cave's column is roofed", cl.columnOpen(0, 0, 0, cx, cy, cz, SEA) == false)
cl.isUnderwater(cx, cy, cz)          -- asks; the fill starts
local n0 = cl.floodCount()
run(3)
check("the cave fill finishes", cl.floodCount() > n0, cl.floodCount())
check("a cave with a passage to open water below the sea's level is flooded", cl.isUnderwater(cx, cy, cz) == true,
  cl.floodStats and string.format("%d cells, wet %s", cl.floodStats.cells, tostring(cl.floodStats.wet)))
local cd = cl.seaDepth(cx, cy, cz)
check("…to the sea's level", cd and math.abs(cd - (SEA - 84)) < 1e-6, cd)

-- A pit dug from dry land to below sea level: air (the surface over it is land).
local px, py, pz = at(1, -0.25, 0, 96)
check("the pit is open to the sky", cl.columnOpen(0, 0, 0, px, py, pz, SEA) == true)
check("a pit dug below sea level from dry land is dry", cl.isUnderwater(px, py, pz) == false, cl.seaDepth(px, py, pz))

-- Ground streaming in: for a moment the field under a diver reads rock over
-- them (a roofed column, then a cave not looked at yet). They were just read
-- wet, so the wet answer holds through it instead of flashing to -1 (which
-- refilled the suit tank); the hold runs out, so a real roof still wins.
local busy = false
API.terrain.busy = function() return busy end
check("the diver is in the sea", (cl.seaDepth(sx, sy, sz) or 0) > 0)
API.terrain.query = function(x, y, z) return -1 end  -- the stale field: rock
local held = cl.seaDepth(sx, sy, sz)
check("a stale roof right after a wet read holds the water", held and math.abs(held - 3) < 1e-6, held)
check("…and is counted", (cl.wetHolds or 0) >= 1, cl.wetHolds)
check("…but not 10 m away, where nothing was read wet", (cl.seaDepth(at(-1, -0.2, 0, 95)) or 0) <= 0)
busy = true
run(3)
check("while the terrain is streaming the hold lasts longer", (cl.seaDepth(sx, sy, sz) or 0) > 0)
busy = false
run(2)
check("once it runs out, a roof that is still there is dry", (cl.seaDepth(sx, sy, sz) or 0) <= 0, cl.seaDepth(sx, sy, sz))
API.terrain.query = function(x, y, z) return sdf(x, y, z) end
API.terrain.busy = nil
check("the field back, the sea is water again", (cl.seaDepth(sx, sy, sz) or 0) > 0)

-- Cost: an open-sea answer is a handful of field reads.
local reads = 0
API.terrain.query = function(x, y, z) reads = reads + 1; return sdf(x, y, z) end
cl.seaDepth(sx, sy, sz)
check("an open-sea answer costs a few dozen field reads at most", reads <= 30, reads)
API.terrain.query = function(x, y, z) return sdf(x, y, z) end

-- ── fading: every scatter layer dissolves out at its reach ──────────────────
local fg = load_script("solar/scripts/flora_gen.lua")
local lod, fade = fg.fadeBands({ { asset = "g.prefab.ron", at = 1.0 } }, 26, "mesh:1")
check("a one-band layer (grass) gets a band of nothing past its reach", #lod == 2 and lod[2].asset == "mesh:1"
  and lod[1].distance == 26 and lod[2].distance > 26 and lod[2].distance < 27.5)
-- A dissolve, not a snap, but a narrow one: the engine's dissolve is a screen
-- door, and every plant inside a window draws as a grid of dots.
check("…and a fade window of a few metres (a dissolve, not a snap, not a screen-door belt)", fade >= 1.5 and fade <= 4, fade)
lod, fade = fg.fadeBands({ { asset = "a", at = 0.22 }, { asset = "b", at = 0.55 }, { asset = "c", at = 1.0 } }, 150, "mesh:1")
check("a tree keeps its bands, nearest first, and ends in nothing", #lod == 4 and lod[1].distance == 33
  and lod[3].distance == 150 and lod[4].asset == "mesh:1")
check("…its window is a few metres, never more than half the narrowest band", fade <= 33 * 0.5 + 1e-9 and fade >= 1.5 and fade <= 4, fade)
lod = fg.fadeBands({ { asset = "a", at = 1.0 } }, 40, nil)
check("with no empty mesh (no renderer) the list is just the bands", #lod == 1)

-- ── report ──────────────────────────────────────────────────────────────────
local bad = {}
for _, c in ipairs(checks) do
  if not c.ok then
    bad[#bad + 1] = "  ✗ " .. c.desc .. (c.detail ~= nil and ("   [" .. tostring(c.detail) .. "]") or "")
  end
end
if #bad == 0 then
  print(string.format("WATER SMOKE OK — %d checks passed", #checks))
  os.exit(0)
end
print("WATER SMOKE FAILURES:")
for _, b in ipairs(bad) do print(b) end
os.exit(1)
