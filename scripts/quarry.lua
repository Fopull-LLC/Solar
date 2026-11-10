-- QUARRY — a frame that digs the ground inside its bounds (expansion X5;
-- work/expansion/PLAN.md §3.1; docs/base-building.md §23).
--
-- PURE. No engine calls: it loads from disk in a luajit test
-- (tests/smoke_quarry.lua). The scene half is scripts/logistics.lua.
--
-- THE FRAME. Four Quarry Posts on the ground are a rectangle (each side 4 to
-- 32 m, square within POST_TOL); a Quarry Drive within DRIVE_R of it is its
-- winch, its head and its discharge. `fromPosts` turns the posts' ground points
-- (body-relative, docs/positions-and-frames.md rule 1) into the quarry's frame:
-- its centre O, its up U (the radial there), its axes R and F along the sides,
-- the half sizes hx, hz. Everything after is in that frame (lx, ly, lz), and
-- turned back to the body's frame only when a dig is made.
--
-- THE CUT. The head digs a SERPENTINE over the rectangle in CELL (1.2 m)
-- cells, one LAYER (0.6 m) at a time, walls WALL m inside the posts, from the
-- top of the ground down to `depth` (DEPTH_MAX, the head's 30 m of cable, or
-- the floor the player sets in 0.5 m steps). Cell i of the whole cut is
-- (layer k, row iz, column ix) by `cellAt`; progress is counted in cells.
--
-- THE SURVEY. When the frame completes, 4 × 4 columns are probed layer by
-- layer (the scene's sampler: mineral_field.materialAt, the ground's height
-- by a ray): `mix[k] = { air (share of columns above the ground), hard (the
-- solid share's hardness), comp = { mat = share of the solid } }`. That is
-- the estimate the closed form runs on while the quarry is out of reach; the
-- live digs (terrain.yields) are the truth while it is near.
--
-- THE RATE. A cell takes CELL_VOL × (solid / rate(hard) + air / AIR_RATE)
-- seconds: the bucket-wheel cuts 0.5 m³/s of soil (hardness ≤ 0.9), 0.25 of
-- rock (≤ 1.3), 0.12 of the hard ores; on a small body (no gravity to lift
-- against) 1 m³/s. What a solid m³ yields is the laser's own rule
-- (mineral_field: `dig_unit` m³ of the ground's yield volume a unit, ore 0.4
-- of that) times YIELD_K, the head's bulk factor (the hand laser's volume pays
-- a trickle: its income is its bite, tool_belt pop_unit), in kg by the
-- material's unit mass: soil 10 kg a m³, iron ore 70. The engine's yield
-- volume is about a real m³ (measured in the X5 probe), so a live dig pays
-- terrain.yields × YIELD_K through mineral_field (trackDig's k) and the two
-- paths agree.
--
--   fromPosts(posts, opts)   → q | nil, why
--   cells(q)                 → nx, nz, per layer, layers, total
--   cellAt(q, i)             → k, iz, ix, lx, ly, lz  (the cell's centre, quarry frame)
--   toBody(q, lx, ly, lz)    → body-relative x, y, z
--   columns(q)               → the 16 survey columns { lx, lz }
--   survey(q, sample)        → mix   (sample(lx, ly, lz) → mat | nil above the ground)
--   cellSecs(q, k)           → s a cell in layer k
--   profile(q, prog)         → { cps, kgps = { mat = kg/s }, toNext (cells), done }
--   kgPerM3(mat, M)          → kg a solid m³ of `mat` yields
--   catchUp(dug, prog)       → the cell indices claimed but not dug yet
--   pack(q) / unpackQ(t)     → the save's flat record

V = 1
CELL = 1.2               -- m: a bite's footprint
LAYER = 0.6              -- m: a layer's depth
CELL_VOL = CELL * CELL * LAYER
WALL = 1.0               -- m: the walls are left this far inside the posts
SIDE_MIN, SIDE_MAX = 4.0, 32.0
POST_TOL = 0.9           -- m: how far a post may sit off a true rectangle
DEPTH_MAX = 30.0         -- m: the head's cable
DRIVE_R = 14.0           -- m: a drive this near the rectangle's edge is its winch
AIR_RATE = 4.0           -- m³/s: the head sweeping air (ground lower than the top layer)
RATE = { soil = 0.5, rock = 0.25, ore = 0.12, zerog = 1.0 }
DIG_R = 0.9              -- m: a live bite's radius (covers a cell's diagonal: 0.85)
DIG_UNIT = 30.0          -- mineral_field's dig_unit
ORE_K = 0.4              -- an ore's unit takes 0.4 of that
YIELD_K = 200            -- a quarry's bulk factor: units for the laser's one per m³ cut (live digs pay terrain.yields × this)
MAX_QUARRIES = 4         -- a world: until the engine evicts edited ground (card 0658)

local function norm(x, y, z)
  local l = math.sqrt(x * x + y * y + z * z)
  if l < 1e-12 then return 0, 0, 0, 0 end
  return x / l, y / l, z / l, l
end
local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
local function sub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
local function cross(a, b) return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] } end

-- posts = { { x, y, z } … } body-relative ground points. opts = { depth, zerog }
function fromPosts(posts, opts)
  opts = opts or {}
  if type(posts) ~= "table" or #posts ~= 4 then
    return nil, string.format("a quarry is four Quarry Posts on the corners of a rectangle (%d placed)", type(posts) == "table" and #posts or 0)
  end
  local C = { 0, 0, 0 }
  for _, p in ipairs(posts) do C[1], C[2], C[3] = C[1] + p.x / 4, C[2] + p.y / 4, C[3] + p.z / 4 end
  local ux, uy, uz = norm(C[1], C[2], C[3])
  local U = { ux, uy, uz }
  -- the posts in the tangent plane, sorted by angle round the centre
  local ref0 = sub({ posts[1].x, posts[1].y, posts[1].z }, C)
  local a0 = sub(ref0, { U[1] * dot(ref0, U), U[2] * dot(ref0, U), U[3] * dot(ref0, U) })
  local ax, ay, az, al = norm(a0[1], a0[2], a0[3])
  if al < 1e-6 then return nil, "the posts stand on one spot" end
  local A = { ax, ay, az }
  local B = cross(U, A)
  local P = {}
  for _, p in ipairs(posts) do
    local d = sub({ p.x, p.y, p.z }, C)
    local u, v = dot(d, A), dot(d, B)
    P[#P + 1] = { u = u, v = v, ang = math.atan2(v, u), h = dot(d, U) }
  end
  table.sort(P, function(a, b) return a.ang < b.ang end)
  local E = {}
  for i = 1, 4 do
    local p, q = P[i], P[i % 4 + 1]
    E[i] = { q.u - p.u, q.v - p.v }
  end
  local function L(e) return math.sqrt(e[1] * e[1] + e[2] * e[2]) end
  local l1, l2, l3, l4 = L(E[1]), L(E[2]), L(E[3]), L(E[4])
  if math.abs(l1 - l3) > POST_TOL or math.abs(l2 - l4) > POST_TOL then
    return nil, string.format("the posts aren't a rectangle: opposite sides %.1f / %.1f m and %.1f / %.1f m", l1, l3, l2, l4)
  end
  local c12 = (E[1][1] * E[2][1] + E[1][2] * E[2][2]) / math.max(1e-9, l1 * l2)
  if math.abs(c12) * math.min(l1, l2) > POST_TOL then
    return nil, string.format("the posts aren't square: a corner is %.0f° off", math.deg(math.asin(math.min(1, math.abs(c12)))))
  end
  local w, d = (l1 + l3) / 2, (l2 + l4) / 2
  for _, s in ipairs({ w, d }) do
    if s < SIDE_MIN - 1e-6 then return nil, string.format("a side is %.1f m: a quarry is at least %.0f m a side", s, SIDE_MIN) end
    if s > SIDE_MAX + 1e-6 then return nil, string.format("a side is %.1f m: a quarry is at most %.0f m a side (the bridge's span)", s, SIDE_MAX) end
  end
  -- the axes: R along the first side (averaged with its opposite), F = U × R
  local ex, ey = (E[1][1] - E[3][1]) / 2, (E[1][2] - E[3][2]) / 2
  local el = math.sqrt(ex * ex + ey * ey)
  local Rv = { (A[1] * ex + B[1] * ey) / el, (A[2] * ex + B[2] * ey) / el, (A[3] * ex + B[3] * ey) / el }
  local Fv = cross(Rv, U)
  -- (the ground level of the frame: the posts' mean, the centre)
  local q = { v = V, ox = C[1], oy = C[2], oz = C[3], U = U, R = Rv, F = Fv, hx = w / 2, hz = d / 2,
              depth = math.min(DEPTH_MAX, opts.depth or DEPTH_MAX), zerog = opts.zerog == true, ytop = 0 }
  return q
end

function toBody(q, lx, ly, lz)
  local R, U, F = q.R, q.U, q.F
  return q.ox + R[1] * lx + U[1] * ly + F[1] * lz, q.oy + R[2] * lx + U[2] * ly + F[2] * lz, q.oz + R[3] * lx + U[3] * ly + F[3] * lz
end
-- a body-relative point into the quarry frame
function toLocal(q, x, y, z)
  local d = { x - q.ox, y - q.oy, z - q.oz }
  return dot(d, q.R), dot(d, q.U), dot(d, q.F)
end

function cells(q)
  local nx = math.max(1, math.floor((2 * q.hx - 2 * WALL) / CELL + 1e-9))
  local nz = math.max(1, math.floor((2 * q.hz - 2 * WALL) / CELL + 1e-9))
  local layers = math.max(1, math.floor(((q.ytop or 0) + q.depth) / LAYER + 1e-9))
  return nx, nz, nx * nz, layers, nx * nz * layers
end

-- cell i (1-based) of the cut: layer k, row iz, column ix (0-based), its centre
function cellAt(q, i)
  local nx, nz, per = cells(q)
  local j = i - 1
  local k = math.floor(j / per)
  local r = j - k * per
  local iz = math.floor(r / nx)
  local ix = r - iz * nx
  -- (serpentine: odd rows run back; odd layers run the rows back too)
  if iz % 2 == 1 then ix = nx - 1 - ix end
  if k % 2 == 1 then iz = nz - 1 - iz; ix = nx - 1 - ix end
  local lx = -nx * CELL / 2 + (ix + 0.5) * CELL
  local lz = -nz * CELL / 2 + (iz + 0.5) * CELL
  local ly = (q.ytop or 0) - (k + 0.5) * LAYER
  return k, iz, ix, lx, ly, lz
end

-- the 16 survey columns: a 4 × 4 grid over the cut
function columns(q)
  local nx, nz = cells(q)
  local wx, wz = nx * CELL, nz * CELL
  local out = {}
  for a = 0, 3 do
    for b = 0, 3 do out[#out + 1] = { lx = -wx / 2 + (a + 0.5) * wx / 4, lz = -wz / 2 + (b + 0.5) * wz / 4 } end
  end
  return out
end

-- sample(lx, ly, lz) → mat, or nil where the point is above the ground.
-- ground(lx, lz) → the ground's height in the frame (optional: sets ytop, the
-- top of the cut, at the highest ground over the rectangle).
function survey(q, sample, ground, hardOf)
  if ground then
    local top = -1e9
    for _, c in ipairs(columns(q)) do local g = ground(c.lx, c.lz); if g and g > top then top = g end end
    if top > -1e8 then q.ytop = math.max(0, math.ceil(top / LAYER - 1e-6) * LAYER) end
  end
  local _, _, _, layers = cells(q)
  local mix = {}
  local cols = columns(q)
  for k = 0, layers - 1 do
    local y = (q.ytop or 0) - (k + 0.5) * LAYER
    local air, n, comp = 0, 0, {}
    for _, c in ipairs(cols) do
      local m = sample(c.lx, y, c.lz)
      n = n + 1
      if m then comp[m] = (comp[m] or 0) + 1 else air = air + 1 end
    end
    local solid = n - air
    local hard, hk = 0, 0
    local cl = {}
    for m, c in pairs(comp) do
      cl[m] = c / math.max(1, solid)
      local h = hardOf and hardOf(m) or 1
      hard, hk = hard + h * c, hk + c
    end
    mix[k + 1] = { air = air / math.max(1, n), hard = hk > 0 and hard / hk or 1, comp = cl }
  end
  q.mix = mix
  return mix
end

function rateOf(hard, zerog)
  if zerog then return RATE.zerog end
  if hard <= 0.9 then return RATE.soil end
  if hard <= 1.3 then return RATE.rock end
  return RATE.ore
end

-- s a cell takes in layer k (0-based)
function cellSecs(q, k)
  local L = q.mix and q.mix[k + 1]
  local air = L and L.air or 0
  local hard = L and L.hard or 1
  local solid = 1 - air
  return CELL_VOL * (solid / rateOf(hard, q.zerog) + air / AIR_RATE)
end

-- kg a solid m³ of `mat` yields (M = materials: kg(mat), isOre(mat))
function kgPerM3(mat, M)
  local u = DIG_UNIT
  if M and M.isOre and M.isOre(mat) then u = u * ORE_K end
  local kg = (M and M.kg and M.kg(mat)) or 1
  return YIELD_K / u * kg
end

-- What the head is doing at progress `prog` (cells, a float): its pace in
-- cells a second, what it yields a second by the survey (kg), the cells to
-- the next layer, and done at the bottom of the cut.
function profile(q, prog, M)
  local _, _, per, layers, total = cells(q)
  if prog >= total - 1e-9 then return { cps = 0, kgps = {}, toNext = math.huge, done = true } end
  local k = math.floor(prog / per + 1e-12)
  if k >= layers then k = layers - 1 end
  local secs = cellSecs(q, k)
  local cps = 1 / secs
  local L = q.mix and q.mix[k + 1]
  local kgps = {}
  if L then
    local solid = 1 - (L.air or 0)
    for m, s in pairs(L.comp or {}) do
      kgps[m] = cps * CELL_VOL * solid * s * kgPerM3(m, M)
    end
  end
  return { cps = cps, kgps = kgps, toNext = (k + 1) * per - prog, done = false, layer = k }
end

-- The cells claimed (prog) but not dug (dug, the last cell dug): what the
-- scene digs when the chunks are resident again.
function catchUp(dug, prog, max)
  local out = {}
  local last = math.floor(prog + 1e-9)
  for i = (dug or 0) + 1, last do
    out[#out + 1] = i
    if max and #out >= max then break end
  end
  return out
end

-- m³ cut so far at progress prog (for the readouts)
function cutM3(q, prog) return (prog or 0) * CELL_VOL end
-- the layer and depth at progress prog
function depthAt(q, prog)
  local _, _, per, layers = cells(q)
  local k = math.min(layers - 1, math.floor((prog or 0) / per + 1e-12))
  return k, (k + 1) * LAYER - (q.ytop or 0)
end

-- The save keeps the frame and its survey (flat lists: a mix layer is
-- { air, hard, mats = "iron:0.25,regolith:0.75" }).
function pack(q)
  local mix = {}
  for k, L in ipairs(q.mix or {}) do
    local ks = {}
    for m in pairs(L.comp or {}) do ks[#ks + 1] = m end
    table.sort(ks)
    local parts = {}
    for _, m in ipairs(ks) do parts[#parts + 1] = string.format("%s:%.4f", m, L.comp[m]) end
    mix[k] = { a = L.air, h = L.hard, m = table.concat(parts, ",") }
  end
  return { v = V, o = { q.ox, q.oy, q.oz }, u = q.U, r = q.R, f = q.F, hx = q.hx, hz = q.hz, d = q.depth, zg = q.zerog or nil,
           yt = q.ytop, mix = mix }
end
function unpackQ(t)
  if type(t) ~= "table" or type(t.o) ~= "table" then return nil end
  local q = { v = t.v or V, ox = t.o[1], oy = t.o[2], oz = t.o[3], U = t.u, R = t.r, F = t.f, hx = t.hx, hz = t.hz,
              depth = t.d or DEPTH_MAX, zerog = t.zg == true, ytop = t.yt or 0, mix = {} }
  for k, L in ipairs(t.mix or {}) do
    local comp = {}
    for m, s in string.gmatch(L.m or "", "([%w_]+):([%d%.]+)") do comp[m] = tonumber(s) end
    q.mix[k] = { air = L.a or 0, hard = L.h or 1, comp = comp }
  end
  return q
end
