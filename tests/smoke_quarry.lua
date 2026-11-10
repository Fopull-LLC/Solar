-- SMOKE: the quarry's rules (expansion X5; scripts/quarry.lua;
-- docs/base-building.md §23).
--
--   * four posts → the frame (a 20 × 20 m rectangle on a sphere, turned any
--     way; refusals: three posts, not a rectangle, not square, too small, too
--     big);
--   * the cells: 1.2 m, walls 1 m inside, the serpentine (every cell once,
--     neighbours 1.2 m apart, layers 0.6 m down);
--   * the survey: air over low ground, the mix of a layer with a vein in it;
--   * the rate by hardness (soil, rock, ore, zero-g);
--   * the profile: kg a second by the mix, the next layer's boundary;
--   * the catch-up list equals the cells claimed;
--   * pack / unpack.
--
--   luajit solar/tests/smoke_quarry.lua

local failures, passed = {}, 0
local function check(ok, msg)
  if ok then passed = passed + 1 else failures[#failures + 1] = msg end
end
local function near(a, b, tol) return math.abs(a - b) <= (tol or 1e-9) end

local function load(path)
  local E = setmetatable({ save = { get = function() end, set = function() end }, findScript = function() end, log = function() end },
                         { __index = _G })
  local f = assert(loadfile("solar/scripts/" .. path))
  setfenv(f, E)
  f()
  return E
end
local Q = load("quarry.lua")
local M = load("materials.lua")

-- a 20 × 20 rectangle on a 600 km sphere, at a point and turned 30°
local Rb = 600000
local function onSphere(lat, lon) return { math.cos(lat) * math.cos(lon) * Rb, math.sin(lat) * Rb, math.cos(lat) * math.sin(lon) * Rb } end
local C = onSphere(0.3, 1.1)
local function nrm(v) local l = math.sqrt(v[1] ^ 2 + v[2] ^ 2 + v[3] ^ 2); return { v[1] / l, v[2] / l, v[3] / l } end
local U = nrm(C)
local function cross(a, b) return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] } end
local E1 = nrm(cross(U, { 0, 1, 0 }))
local E2 = cross(U, E1)
local th = math.rad(30)
local A = { E1[1] * math.cos(th) + E2[1] * math.sin(th), E1[2] * math.cos(th) + E2[2] * math.sin(th), E1[3] * math.cos(th) + E2[3] * math.sin(th) }
local B = cross(U, A)
local function post(a, b, h)
  h = h or 0
  return { x = C[1] + A[1] * a + B[1] * b + U[1] * h, y = C[2] + A[2] * a + B[2] * b + U[2] * h, z = C[3] + A[3] * a + B[3] * b + U[3] * h }
end
local posts = { post(10, 10), post(-10, 10, 0.3), post(-10, -10), post(10, -10, -0.2) }
local q, why = Q.fromPosts(posts)
check(q ~= nil, "a 20 × 20 rectangle is a quarry: " .. tostring(why))
check(near(q.hx, 10, 1e-6) and near(q.hz, 10, 1e-6), string.format("its half sizes 10 × 10 (%.4f %.4f)", q.hx, q.hz))
check(near(q.U[1] * U[1] + q.U[2] * U[2] + q.U[3] * U[3], 1, 1e-9), "its up is the radial")
check(math.abs(q.R[1] * q.U[1] + q.R[2] * q.U[2] + q.R[3] * q.U[3]) < 1e-9, "R ⟂ U")
-- each post back in the frame sits on a corner
for _, p in ipairs(posts) do
  local lx, _, lz = Q.toLocal(q, p.x, p.y, p.z)
  check(near(math.abs(lx), 10, 1e-6) and near(math.abs(lz), 10, 1e-6), string.format("a post on a corner (%.3f, %.3f)", lx, lz))
end
-- 32 × 10 is fine, and turned the other way round too
check(Q.fromPosts({ post(16, 5), post(-16, 5), post(-16, -5), post(16, -5) }) ~= nil, "32 × 10 is a quarry")
-- refusals
local _, w1 = Q.fromPosts({ post(10, 10), post(-10, 10), post(-10, -10) })
check(w1 and w1:find("four"), "three posts: " .. tostring(w1))
local _, w2 = Q.fromPosts({ post(10, 10), post(-10, 10), post(-10, -10), post(14, -10) })
check(w2 and (w2:find("rectangle") or w2:find("square")), "a skewed four: " .. tostring(w2))
local _, w3 = Q.fromPosts({ post(1.5, 1.5), post(-1.5, 1.5), post(-1.5, -1.5), post(1.5, -1.5) })
check(w3 and w3:find("at least"), "3 m a side: " .. tostring(w3))
local _, w4 = Q.fromPosts({ post(20, 5), post(-20, 5), post(-20, -5), post(20, -5) })
check(w4 and w4:find("at most"), "40 m a side: " .. tostring(w4))

-- ── the cells ───────────────────────────────────────────────────────────────
local nx, nz, per, layers, totalc = Q.cells(q)
check(nx == 15 and nz == 15, string.format("18 m inside the walls = 15 × 15 cells (%d × %d)", nx, nz))
check(layers == 50, string.format("30 m down = 50 layers (%d)", layers))
check(totalc == 15 * 15 * 50, "the total")
do
  local seen, ok, maxStep = {}, true, 0
  local px, py, pz
  for i = 1, per * 3 do
    local k, iz, ix, lx, ly, lz = Q.cellAt(q, i)
    local key = k .. ":" .. iz .. ":" .. ix
    if seen[key] then ok = false end
    seen[key] = true
    if math.abs(lx) > 10 - Q.WALL + 1e-9 or math.abs(lz) > 10 - Q.WALL + 1e-9 then ok = false end
    if px then
      local d = math.sqrt((lx - px) ^ 2 + (lz - pz) ^ 2)
      if py == ly then maxStep = math.max(maxStep, d) end
    end
    px, py, pz = lx, ly, lz
  end
  check(ok, "every cell once, inside the walls")
  check(near(maxStep, Q.CELL, 1e-9), string.format("the serpentine steps 1.2 m (max %.3f)", maxStep))
  local _, _, _, _, ly1 = Q.cellAt(q, 1)
  local _, _, _, _, ly2 = Q.cellAt(q, per + 1)
  check(near(ly1 - ly2, Q.LAYER, 1e-9), "the next layer is 0.6 m down")
  -- the layer's last cell and the next layer's first are one step apart (the head doesn't cross the pit)
  local _, _, _, ax, _, az = Q.cellAt(q, per)
  local _, _, _, bx, _, bz = Q.cellAt(q, per + 1)
  check(near(math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2), 0, 1e-9), "a layer starts under where the last one ended")
end

-- ── the survey ──────────────────────────────────────────────────────────────
-- ground at +0.7 m on the +x half, 0 on the other; regolith down to 3 m, then
-- basalt, and an iron vein through the layers 5–7 m down on the +z half
local function ground(lx, lz) return lx > 0 and 0.7 or 0.0 end
local function sample(lx, ly, lz)
  if ly > ground(lx, lz) then return nil end
  local d = ground(lx, lz) - ly
  if lz > 0 and ly < -5 and ly > -7 then return "iron" end
  return d < 3 and "regolith" or "basalt"
end
local mix = Q.survey(q, sample, ground, M.hardness)
check(near(q.ytop, 1.2, 1e-9), string.format("the cut starts at the highest ground, rounded up to a layer (%.2f)", q.ytop))
local _, _, _, layers2 = Q.cells(q)
check(layers2 == 52, string.format("2 more layers for the hill (%d)", layers2))
check(near(mix[1].air, 1.0, 1e-9), "the first layer (0.9 m up) is all air: " .. tostring(mix[1].air))
check(near(mix[2].air, 0.5, 1e-9), "the second (0.3 m up) is half air (the low half)")
local kv = math.floor((1.2 + 6) / 0.6)    -- 6 m down
check(mix[kv + 1].comp.iron and near(mix[kv + 1].comp.iron, 0.5, 1e-9), "half the layer 6 m down is iron ore: " .. tostring(mix[kv + 1].comp.iron))
check(mix[kv + 1].hard > 1.15, "it is harder than the rock round it")

-- ── the rate ────────────────────────────────────────────────────────────────
check(Q.rateOf(0.7) == 0.5 and Q.rateOf(1.15) == 0.25 and Q.rateOf(1.45) == 0.12 and Q.rateOf(1.45, true) == 1.0, "soil 0.5, rock 0.25, ore 0.12, zero-g 1 m³/s")
check(near(Q.cellSecs(q, 0), Q.CELL_VOL / Q.AIR_RATE, 1e-12), "an air cell is a sweep")
check(Q.cellSecs(q, kv) > Q.cellSecs(q, 4), "a cell in the vein takes longer than one in regolith")

-- ── the profile ─────────────────────────────────────────────────────────────
do
  local P = Q.profile(q, per * 4 + 3, M)
  check(P.layer == 4 and near(P.toNext, per - 3, 1e-9), string.format("layer 4, %.0f cells to the next", P.toNext))
  local k = Q.kgPerM3("regolith", M)
  local want = P.cps * Q.CELL_VOL * k
  check(near(P.kgps.regolith or 0, want, 1e-12), string.format("regolith %.5f kg/s = cps × cell × kg/m³", P.kgps.regolith or 0))
  check(Q.kgPerM3("iron", M) > Q.kgPerM3("regolith", M), "an ore unit takes less volume (and weighs more)")
  local Pend = Q.profile(q, Q.cells(q) and select(5, Q.cells(q)), M)
  check(Pend.done, "the bottom of the cut is done")
end

-- ── catch-up ────────────────────────────────────────────────────────────────
local list = Q.catchUp(10, 25.7)
check(#list == 15 and list[1] == 11 and list[15] == 25, "the cells claimed but not dug (11..25)")
check(#Q.catchUp(10, 25.7, 4) == 4, "bounded")

-- ── pack / unpack ───────────────────────────────────────────────────────────
local t = Q.pack(q)
local q2 = Q.unpackQ(t)
check(q2 and near(q2.hx, q.hx) and near(q2.ytop, q.ytop) and #q2.mix == #q.mix, "unpacked")
check(q2 and near(q2.mix[kv + 1].comp.iron, 0.5, 1e-4), "the mix survives")
check(near(Q.cellSecs(q2, kv), Q.cellSecs(q, kv), 1e-9), "its rate too")
-- (the save's depth: a mix layer is a flat record)
local function depth(v, d) d = d or 0; if type(v) ~= "table" then return d end local m = d + 1; for _, x in pairs(v) do m = math.max(m, depth(x, d + 1)) end return m end
check(depth(t) <= 4, "the record nests " .. depth(t) .. " deep")

if #failures == 0 then
  print(string.format("smoke_quarry: %d checks passed", passed))
else
  for _, f in ipairs(failures) do print("FAIL " .. f) end
  print(string.format("smoke_quarry: %d passed, %d FAILED", passed, #failures))
  os.exit(1)
end
