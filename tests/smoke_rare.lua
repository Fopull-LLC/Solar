-- SMOKE HARNESS: rare niches (climate.lua rareScan) and rare species
-- (flora_gen.lua rareFor). Builds an analytic planet with one of every niche
-- carved into it — a peak, a ravine, a rock shelf over a hollow, a lake basin,
-- a river channel — hands climate.rareScan its distance field and its
-- rivers and lakes, and checks:
--
--   * every niche is found, and each plant sits IN its niche (on the peak,
--     on the ravine floor between its walls, on the floor under the shelf,
--     just above the lake's water, on a riverbank above the bed);
--   * ore pockets sit 7–14 m down, wholly in rock, spread apart;
--   * the scan is deterministic (same world → same answer, whatever the
--     per-call budget), a different seed differs, and a field that does not
--     answer is a "fail" to retry, not an answer;
--   * rare species: one per niche, deterministic, distinct colours, and asking
--     for them never moves a roll of the ordinary cast (speciesFor).
--
--   luajit solar/tests/smoke_rare.lua

local failed, count = 0, 0
local function check(desc, ok, detail)
  count = count + 1
  if not ok then
    failed = failed + 1
    print("✗ " .. desc .. (detail ~= nil and ("   [" .. tostring(detail) .. "]") or ""))
  end
end

local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local function norm(x, y, z) local l = len(x, y, z) return x / l, y / l, z / l end

-- A tiny seeded rng with the engine's interface (flora_gen's speciesFor uses it).
local function make_rng(seed)
  local s = math.floor(seed or 1) % 2147483647
  if s <= 0 then s = s + 2147483646 end
  local r = {}
  function r:next() s = (s * 48271) % 2147483647; return s / 2147483647 end
  function r:range(a, b) return a + (b - a) * self:next() end
  function r:int(a, b) return a + math.floor(self:next() * (b - a + 1)) end
  function r:pick(t) return t[math.floor(self:next() * #t) + 1] end
  return r
end

local store = {}
local API = {
  save = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end },
  log = function() end, rng = make_rng,
  space = { body = function() return nil end, dominant = function() return nil end },
  findScript = function() return nil end,
}
local function load_script(path)
  local env = setmetatable({}, { __index = function(_, k) return API[k] or _G[k] end })
  local chunk = assert(loadfile(path))
  setfenv(chunk, env)
  chunk()
  env.params = {}
  for k, v in pairs(env.defaults or {}) do env.params[k] = v end
  return env
end
-- math.noise for climate's sample (not used by the scan); harmless stand-in.
math.noise = math.noise or function(x, y, z) return math.sin(x * 1.7 + y * 2.3 + z * 0.7) * 0.5 end

local cl = load_script("solar/scripts/climate.lua")
local fg = load_script("solar/scripts/flora_gen.lua")
API.findScript = function(k) if k == "climate" then return cl end end

-- ── the planet ──────────────────────────────────────────────────────────────
local R = 420
local P_DIR = { norm(0.2, 1, 0.1) }          -- the peak
local L_DIR = { norm(1, 0.1, 0.2) }          -- the lake
local O_DIR = { norm(-1, 0.2, 0.3) }         -- the rock shelf
-- The ravine: a great-circle arc from A to B.
local RA = { norm(0.3, -0.2, 1) }
local RB = { norm(-0.3, -0.25, 1) }
-- The river: another arc.
local VA = { norm(0.6, -1, -0.2) }
local VB = { norm(0.2, -1, -0.6) }

local function ang(a, ux, uy, uz) return math.acos(math.max(-1, math.min(1, a[1] * ux + a[2] * uy + a[3] * uz))) * R end
-- Distance (along the ground) from a direction to an arc, and where on it.
local function arc_dist(A, B, ux, uy, uz)
  local best, bp = 1e9, nil
  for i = 0, 28 do
    local t = i / 28
    local x, y, z = norm(A[1] + (B[1] - A[1]) * t, A[2] + (B[2] - A[2]) * t, A[3] + (B[3] - A[3]) * t)
    local d = ang({ x, y, z }, ux, uy, uz)
    if d < best then best, bp = d, { x, y, z } end
  end
  return best, bp
end
local function smooth(t) t = math.max(0, math.min(1, t)) return t * t * (3 - 2 * t) end

local RAV_W, RAV_D = 14, 20
local RIV_W, RIV_D = 8, 2.5
local LAKE_R, LAKE_D, LAKE_LEVEL = 60, 7, -3.5

local function ground(ux, uy, uz)
  local g = R + 4 * math.sin(ux * 9) * math.cos(uz * 7)    -- a gentle roll
  local dp = ang(P_DIR, ux, uy, uz)
  g = g + 70 * math.exp(-(dp / 70) ^ 2)                     -- the peak
  local dr = arc_dist(RA, RB, ux, uy, uz)
  g = g - RAV_D * (1 - smooth((dr - RAV_W * 0.5) / 8))      -- the ravine: steep walls
  local dv = arc_dist(VA, VB, ux, uy, uz)
  g = g - RIV_D * (1 - smooth((dv - RIV_W * 0.5) / 3))      -- the river channel
  local dl = ang(L_DIR, ux, uy, uz)
  g = g - LAKE_D * (1 - smooth(dl / LAKE_R))                -- the lake basin
  return g
end

-- Signed distance, the engine's way: a narrow band (±6 m) of an approximate
-- distance (radial gap, scaled down to stay safe on slopes), plus the shelf:
-- a slab of rock 4–7 m up over a hollow, around O_DIR.
local function sdf(x, y, z)
  local r = len(x, y, z)
  local ux, uy, uz = x / r, y / r, z / r
  local d = (r - ground(ux, uy, uz)) * 0.6
  local dO = ang(O_DIR, ux, uy, uz)
  local slab = math.max(math.abs(r - (ground(O_DIR[1], O_DIR[2], O_DIR[3]) + 5.5)) - 1.5, dO - 20)
  d = math.min(d, slab)
  return math.max(-6, math.min(6, d))
end

local function arc_points(A, B, n)
  local pts, wid = {}, {}
  for i = 0, n do
    local x, y, z = norm(A[1] + (B[1] - A[1]) * i / n, A[2] + (B[2] - A[2]) * i / n, A[3] + (B[3] - A[3]) * i / n)
    pts[#pts + 1], pts[#pts + 2], pts[#pts + 3] = x * R, y * R, z * R
  end
  return pts
end
local function widths(n, w) local t = {} for i = 1, n + 1 do t[i] = w end return t end
local RAV_N, RIV_N = 40, 40
local hydro = {
  rivers = {
    { river = false, depth = RAV_D, points = arc_points(RA, RB, RAV_N), widths = widths(RAV_N, RAV_W) },
    { river = true, depth = RIV_D, points = arc_points(VA, VB, RIV_N), widths = widths(RIV_N, RIV_W) },
  },
  lakes = { { x = L_DIR[1] * R, y = L_DIR[2] * R, z = L_DIR[3] * R, reach = LAKE_R * 0.62, level = LAKE_LEVEL, depth = LAKE_D } },
}
-- The lake's reach is where its water meets the ground: solve for it.
do
  local lo, hi = 0, LAKE_R
  for _ = 1, 40 do
    local m = (lo + hi) / 2
    local g = R - LAKE_D * (1 - smooth(m / LAKE_R))
    if g < R + LAKE_LEVEL then lo = m else hi = m end
  end
  hydro.lakes[1].reach = lo
end

local W = { radius = R, seed = 4242, sea = 0, atmo = 0.7, relief = 10,
            shape = { peak = 80, low = 30, layers = { overhangs = true } } }

local function run(w, budget)
  local sc = cl.rareScan(w, hydro, sdf)
  local st, calls = "running", 0
  repeat
    st = sc.step(budget)
    calls = calls + 1
  until st ~= "running" or calls > 100000
  return sc, st, calls
end

-- ── 1. every niche, in its place ────────────────────────────────────────────
local sc, st, calls = run(W, 4000)
check("the scan finishes", st == "done", tostring(st) .. " " .. tostring(sc.why))
check("…a little at a time", calls > 3, calls)
local res = sc.result or { plants = {}, ores = {} }
local by = {}
for _, p in ipairs(res.plants) do by[p.niche] = by[p.niche] or {}; table.insert(by[p.niche], p) end
for _, n in ipairs(cl.RARE_NICHES) do
  check("niche found: " .. n, by[n] and #by[n] >= 1, by[n] and #by[n] or 0)
end
local total = #res.plants
check("a handful, not a field (≤ 15)", total >= 5 and total <= 15, total)

local function alt(p) return len(p.x, p.y, p.z) - R end
local function dir(p) return norm(p.x, p.y, p.z) end
for _, p in ipairs(by.peak or {}) do
  local ux, uy, uz = dir(p)
  check("peak plant on the peak", ang(P_DIR, ux, uy, uz) < 90 and alt(p) > 40, string.format("%.0f m away, alt %.1f", ang(P_DIR, ux, uy, uz), alt(p)))
end
for _, p in ipairs(by.ravine or {}) do
  local ux, uy, uz = dir(p)
  local d = arc_dist(RA, RB, ux, uy, uz)
  check("ravine plant on the ravine floor", d < RAV_W * 0.5 + 2 and alt(p) < -RAV_D * 0.6,
    string.format("%.1f m off the centreline, alt %.1f", d, alt(p)))
end
for _, p in ipairs(by.cave or {}) do
  local ux, uy, uz = dir(p)
  local r = len(p.x, p.y, p.z)
  local roof = 9
  for h = 2, 10, 0.5 do roof = math.min(roof, sdf(ux * (r + h), uy * (r + h), uz * (r + h))) end
  check("cave plant under the shelf", ang(O_DIR, ux, uy, uz) < 20 and math.abs(r - ground(ux, uy, uz)) < 0.4 and roof < 0,
    string.format("%.1f m from the shelf centre, %.2f m off the floor, roof sdf %.1f", ang(O_DIR, ux, uy, uz), r - ground(ux, uy, uz), roof))
  check("…standing on the floor, not the shelf top", r < ground(O_DIR[1], O_DIR[2], O_DIR[3]) + 2, alt(p))
end
for _, p in ipairs(by.lake or {}) do
  local ux, uy, uz = dir(p)
  local above = alt(p) - LAKE_LEVEL
  local d = ang(L_DIR, ux, uy, uz)
  check("lake plant on the shore, just above the water", above >= 0.1 and above <= 2.6 and d < LAKE_R * 1.6,
    string.format("%.2f m above the water, %.0f m from the centre", above, d))
end
for _, p in ipairs(by.river or {}) do
  local ux, uy, uz = dir(p)
  local d, c = arc_dist(VA, VB, ux, uy, uz)
  local bed = ground(ux, uy, uz) - ground(c[1], c[2], c[3])
  check("river plant on the bank, out of the channel", d >= RIV_W * 0.5 and d < RIV_W * 0.5 + 6 and bed > 0.3,
    string.format("%.1f m from the centreline, %.1f m above the bed", d, bed))
end
-- Spread: no two of a niche on top of each other.
for n, list in pairs(by) do
  for i = 1, #list do
    for j = i + 1, #list do
      local a, b = list[i], list[j]
      check("two " .. n .. " plants are spread apart", len(a.x - b.x, a.y - b.y, a.z - b.z) >= cl.RARE_RULES.sep[n] - 0.5)
    end
  end
end

-- ── 2. ore pockets ──────────────────────────────────────────────────────────
check("six ore pockets", #res.ores == 6, #res.ores)
for i, o in ipairs(res.ores) do
  local ux, uy, uz = dir(o)
  local g = ground(ux, uy, uz)
  local depth = g - len(o.x, o.y, o.z)
  check("pocket " .. i .. " is 7–14 m down", depth >= 6.5 and depth <= 14.5, depth)
  check("pocket " .. i .. " is in solid rock", sdf(o.x, o.y, o.z) <= -1.0, sdf(o.x, o.y, o.z))
  for j = i + 1, #res.ores do
    local q = res.ores[j]
    check("pockets " .. i .. "/" .. j .. " are spread apart", len(o.x - q.x, o.y - q.y, o.z - q.z) >= cl.RARE_RULES.oreSep - 0.5)
  end
end

-- ── 3. determinism ──────────────────────────────────────────────────────────
local function sig(r)
  local t = {}
  for _, p in ipairs(r.plants) do t[#t + 1] = string.format("%s:%.2f,%.2f,%.2f", p.niche, p.x, p.y, p.z) end
  for _, o in ipairs(r.ores) do t[#t + 1] = string.format("ore:%.2f,%.2f,%.2f", o.x, o.y, o.z) end
  return table.concat(t, ";")
end
local sc2 = run(W, 4000)
check("the same world scans the same", sig(sc2.result) == sig(res))
local sc3 = run(W, 137)
check("…whatever the per-call budget", sig(sc3.result) == sig(res))
local W2 = {}
for k, v in pairs(W) do W2[k] = v end
W2.seed = 99
local sc4 = run(W2, 4000)
check("another seed places differently", sig(sc4.result) ~= sig(res))
check("…but finds the same niches", (function()
  local s = {}
  for _, p in ipairs(sc4.result.plants) do s[p.niche] = true end
  for _, n in ipairs(cl.RARE_NICHES) do if not s[n] then return false end end
  return true
end)())

-- ── 4. a field that is not all there ────────────────────────────────────────
do
  local holes = cl.rareScan(W, hydro, function(x, y, z)
    if x > 0 and y > 0 then return nil end
    return sdf(x, y, z)
  end)
  local s2
  repeat s2 = holes.step(5000) until s2 ~= "running"
  check("a field with holes is a fail to retry, not an answer", s2 == "fail" and holes.result == nil, s2)
  -- Absent chunks read as open air (a positive band): the march runs off the
  -- bottom of the world, which is also a fail.
  local air = cl.rareScan(W, hydro, function(x, y, z)
    if x > 0 and y > 0 and z > 0 then return 6 end
    return sdf(x, y, z)
  end)
  repeat s2 = air.step(5000) until s2 ~= "running"
  check("ground that reads as open air is a fail too", s2 == "fail", s2)
end

-- ── 5. a world without overhangs or hydro ───────────────────────────────────
do
  local W3 = { radius = R, seed = 7, sea = 0, atmo = 0.7, relief = 10, shape = { peak = 80, low = 30, layers = { overhangs = false } } }
  local s = cl.rareScan(W3, nil, sdf)
  local r
  repeat r = s.step(5000) until r ~= "running"
  local n = {}
  for _, p in ipairs(s.result.plants) do n[p.niche] = (n[p.niche] or 0) + 1 end
  check("no rivers, lakes or overhang layer: peaks only", r == "done" and (n.peak or 0) >= 1
    and not n.cave and not n.ravine and not n.lake and not n.river)
end

-- ── 6. rare species ─────────────────────────────────────────────────────────
do
  local w = { name = "Testa", kind = "canyon", seed = 4242, radius = R, relief = 10, atmo = 0.7, sea = 0, insol = 1.0 }
  store["world.Testa"] = w
  local before = {}
  for _, sp in ipairs(fg.speciesFor("Testa", w)) do before[#before + 1] = sp.name .. "/" .. sp.shape end
  fg.forget("Testa")
  local rare = fg.rareFor("Testa", w)
  local after = {}
  for _, sp in ipairs(fg.speciesFor("Testa", w)) do after[#after + 1] = sp.name .. "/" .. sp.shape end
  check("asking for rare species never moves the ordinary cast", table.concat(before, ",") == table.concat(after, ","))
  check("the ordinary cast is not empty (the comparison means something)", #before > 0, #before)
  local cols = {}
  for _, n in ipairs(cl.RARE_NICHES) do
    local sp = rare[n]
    check("a rare species for " .. n, sp ~= nil and sp.mat == "rare_" .. n and sp.niche == n)
    if sp then
      check(n .. " species glows", (sp.glow or 0) > 0 and sp.emissive ~= nil)
      check(n .. " species stands out (≥ 1.5 m)", sp.height >= 1.3, sp.height)
      cols[#cols + 1] = sp.glowColor
    end
  end
  -- Every pair of glow colours is told apart.
  local close = 0
  for i = 1, #cols do
    for j = i + 1, #cols do
      local d = len(cols[i][1] - cols[j][1], cols[i][2] - cols[j][2], cols[i][3] - cols[j][3])
      if d < 0.12 then close = close + 1 end
    end
  end
  check("each niche glows its own colour", close == 0, close)
  -- Deterministic per world; another world rolls other names.
  local fg2 = load_script("solar/scripts/flora_gen.lua")
  local again = fg2.rareFor("Testa", w)
  check("rare species are deterministic per world", again.peak.name == rare.peak.name and again.cave.shape == rare.cave.shape)
  local w2 = {}
  for k, v in pairs(w) do w2[k] = v end
  w2.seed = 5
  local other = fg2.rareFor("Other", w2)
  local differ = false
  for _, n in ipairs(cl.RARE_NICHES) do if other[n].name ~= rare[n].name then differ = true end end
  check("another world names them differently", differ)
end

if failed > 0 then
  print(string.format("✗ %d of %d checks failed", failed, count))
  os.exit(1)
end
print(string.format("✓ rare niches: %d checks", count))
