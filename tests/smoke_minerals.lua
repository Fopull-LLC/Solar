-- SMOKE HARNESS for mineral_field.lua — the rock lying on a planet's surface,
-- and the ore the mining laser breaks off it.
--
--   luajit solar/tests/smoke_minerals.lua
--
-- The stubbed engine is flora's (tests/smoke_flora.lua): Ground regions in
-- the PARENT node's frame, bilinear density grids, 64-bit ids that come back
-- as lossy doubles, every scattered mesh checked on disk. What it pins:
--  * rock is laid on patches around the crew, anchored to the planet, with
--    every kind (gravel, stone, boulder, crystal) present somewhere;
--  * `nearest` finds a rock lying ON the ground (where the engine drops it),
--    and `breakAt` pays its material and makes it GONE — not just paid for;
--  * a full pack breaks nothing and the rock stays;
--  * a broken rock stays broken when the field is rebuilt (a reload), and the
--    field grows back after `regrow`.

local T = 0.0

-- ── engine API ──────────────────────────────────────────────────────────────
local API, store, logs = {}, {}, {}
API.save = {
  get = function(k) return store[k] end,
  set = function(k, v) store[k] = v end,
  flush = function() end,
}
function API.log(m) logs[#logs + 1] = tostring(m) end
function API.print(m) logs[#logs + 1] = tostring(m) end
function API.vec3(x, y, z) return { x = x, y = y, z = z } end

local function make_rng(seed)
  local s = (seed or 12345) % 2147483647
  if s <= 0 then s = s + 2147483646 end
  local r = { seed = seed or 12345 }
  function r:next()
    s = (s * 16807) % 2147483647
    return (s - 1) / 2147483646
  end
  function r:range(a, b) return a + (b - a) * r:next() end
  function r:int(a, b) return a + math.floor(r:next() * (b - a + 1) - 1e-9) end
  function r:pick(t) return t[1 + math.floor(r:next() * #t - 1e-9)] end
  return r
end
function API.rng(seed) return make_rng(seed or 98765) end

local function noise(x, y, z, seed)
  seed = seed or 0
  local a = math.sin(x * 1.7 + seed * 0.13) * math.cos(y * 1.3 - seed * 0.21)
  local b = math.sin(z * 2.1 - seed * 0.07) * math.cos(x * 0.9 + y * 0.5)
  return math.max(-1, math.min(1, (a + b) * 0.5))
end
math.noise = noise
math.fbm = function(x, y, z, oct) return noise(x * 3.1, y * 2.7, z * 3.3, 3) * 0.9 end
math.saturate = function(v) return math.max(0, math.min(1, v)) end

-- ── the world ───────────────────────────────────────────────────────────────
local BODY = { name = "Verdance", x = 1000, y = 0, z = -500, radius = 412,
               mu = 6.0 * 400 * 400, soi = 60000 }
local SURFACE = 400.0
local LATE_BODY
API.space = {
  bodies = function() return { BODY } end,
  body = function(n)
    if n == BODY.name then return BODY end
    if LATE_BODY and n == LATE_BODY.name then return LATE_BODY end
    if n == "Other" or n == "Dead" or (n and n:match("^W%d+$")) then
      return { name = n, x = 0, y = 0, z = 0, radius = 300, mu = 5 * 300 * 300, soi = 1 }
    end
    return nil
  end,
  dominant = function(x, y, z)
    local d = math.sqrt((x - BODY.x) ^ 2 + (y - BODY.y) ^ 2 + (z - BODY.z) ^ 2)
    return d < BODY.soi and BODY.name or nil
  end,
}

local ray_count = 0
function API.raycast(ox, oy, oz, dx, dy, dz, maxd)
  ray_count = ray_count + 1
  local rx, ry, rz = ox - BODY.x, oy - BODY.y, oz - BODY.z
  local r = math.sqrt(rx * rx + ry * ry + rz * rz)
  local dot = (rx * dx + ry * dy + rz * dz) / math.max(1e-9, r)
  if dot > -0.2 then return nil end
  -- March the ray to the sphere (the stub is a sphere of radius SURFACE).
  local b = rx * dx + ry * dy + rz * dz
  local c = r * r - SURFACE * SURFACE
  local disc = b * b - c
  if disc < 0 then return nil end
  local t = -b - math.sqrt(disc)
  if t < 0 or t > (maxd or 0) then return nil end
  local hx, hy, hz = rx + dx * t, ry + dy * t, rz + dz * t
  return { x = BODY.x + hx, y = BODY.y + hy, z = BODY.z + hz,
           nx = hx / SURFACE, ny = hy / SURFACE, nz = hz / SURFACE, distance = t }
end
API.terrain = {
  query = function(x, y, z)
    local d = math.sqrt((x - BODY.x) ^ 2 + (y - BODY.y) ^ 2 + (z - BODY.z) ^ 2)
    return d - SURFACE
  end,
}

-- ── nodes ───────────────────────────────────────────────────────────────────
local by_name = {}
local next_id = 100
local function make_node(name, parent)
  next_id = next_id + 1
  local n = { __id = next_id, name = name, valid = true, x = 0, y = 0, z = 0,
              yaw = 0, pitch = 0, roll = 0, scale_x = 1, scale_y = 1, scale_z = 1,
              tags = {}, kids = {}, parent = parent, visible = true }
  function n:setPrimitive(shape, color) self.shape = shape end
  function n:setMaterial(m) self.material = m end
  function n:destroy() self.valid = false; if by_name[self.name] == self then by_name[self.name] = nil end end
  by_name[name] = n
  return n
end
local nodes_made = 0
function API.createNode(name, a, b)
  local parent, cb = nil, nil
  for _, v in ipairs({ a, b }) do
    if type(v) == "function" then cb = v elseif type(v) == "table" then parent = v end
  end
  nodes_made = nodes_made + 1
  local n = make_node(name, parent)
  if cb then cb(n) end
  return n
end
local PLANET = make_node(BODY.name, nil)
local ASTRO = make_node("Astronaut", nil)
function API.find(name) return by_name[name] end
function API.findTagged() return {} end

-- ── scatter (Ground regions, as the engine builds them) ─────────────────────
-- R = Ry(yaw)·Rx(pitch)·Rz(roll), the engine's order; its columns are the
-- node's X, Y, Z axes in the parent's frame.
local function axes_of(n)
  local cr, sr, cp, sp = math.cos(n.roll), math.sin(n.roll), math.cos(n.pitch), math.sin(n.pitch)
  local cy, sy = math.cos(n.yaw), math.sin(n.yaw)
  local function ry(v) return { v[1] * cy + v[3] * sy, v[2], -v[1] * sy + v[3] * cy } end
  return ry({ cr, sr * cp, sr * sp }), ry({ -sr, cr * cp, cr * sp }), ry({ 0, -sp, cp })
end
local function mix32(a)
  a = (a * 1103515245 + 12345) % 2147483648
  a = (a * 1103515245 + 12345) % 2147483648
  return a
end
local SRC, next_src = {}, 0
local function density_at(src, u, v)
  local d = src.density
  if not d then return 1 end
  local rows = src.densityRows
  local fu, fv = math.max(0, math.min(1, u)) * (rows - 1), math.max(0, math.min(1, v)) * (rows - 1)
  local c0, r0 = math.min(rows - 2, math.floor(fu)), math.min(rows - 2, math.floor(fv))
  local tu, tv = fu - c0, fv - r0
  local function at(r, c) return d[r * rows + c + 1] end
  local top = at(r0, c0) + (at(r0, c0 + 1) - at(r0, c0)) * tu
  local bot = at(r0 + 1, c0) + (at(r0 + 1, c0 + 1) - at(r0 + 1, c0)) * tu
  return top + (bot - top) * tv
end
local function instances(src)
  if src.cache then return src.cache end
  local out = {}
  local n = math.ceil(src.halfX / src.chunk)
  for ci = -n, n - 1 do
    for cj = -n, n - 1 do
      for k = 0, src.perChunk - 1 do
        local h = mix32(src.seed * 7 + (ci + 1000) * 7919 + (cj + 1000) * 104729 + k * 13)
        local fx = (h % 10007) / 10007
        local fz = (mix32(h) % 10009) / 10009
        local keep = (mix32(h + 5) % 10037) / 10037
        local lx, lz = (ci + fx) * src.chunk, (cj + fz) * src.chunk
        if math.abs(lx) <= src.halfX and math.abs(lz) <= src.halfZ then
          local d = density_at(src, lx / (2 * src.halfX) + 0.5, lz / (2 * src.halfZ) + 0.5)
          if keep < d then
            -- a 53-bit id (exact in a double), from (seed, chunk, index)
            out[#out + 1] = { id = h * 1048576 + k * 4099 + 17, lx = lx, lz = lz,
                              scale = src.scaleMin + (src.scaleMax - src.scaleMin) * keep }
          end
        end
      end
    end
  end
  src.cache = out
  return out
end
local function live(src)
  local out = {}
  for _, i in ipairs(instances(src)) do
    if not src.removed[i.id] then out[#out + 1] = i end
  end
  return out
end
API.scatter = {
  create = function(o)
    for k in pairs(o) do
      local okk = ({ asset = 1, lod = 1, range = 1, seed = 1, center = 1, radius = 1, halfX = 1, halfZ = 1,
        align = 1, perChunk = 1, chunk = 1, scaleMin = 1, scaleMax = 1, fade = 1, density = 1,
        densityRows = 1, parent = 1, tint = 1, emissive = 1, emissiveStrength = 1 })[k]
      if not okk then error("scatter.create: unknown option " .. k) end
    end
    assert(o.center and o.center.x == 0 and o.center.y == 0 and o.center.z == 0,
      "an anchored region's centre is in its parent's frame (0,0,0)")
    assert(o.halfX and o.parent, "surface props use Ground regions anchored to a patch node")
    assert(by_name[o.parent], "parent node exists: " .. tostring(o.parent))
    if type(o.density) == "table" then
      assert(#o.density >= o.densityRows * o.densityRows, "density grid has rows² values")
    end
    for _, b in ipairs(o.lod or {}) do
      local f = io.open("solar/" .. b.asset, "r")
      assert(f, "scatter asset exists on disk: " .. b.asset)
      f:close()
    end
    next_src = next_src + 1
    o.id = next_src
    o.removed = {}
    SRC[next_src] = o
    return next_src
  end,
  destroy = function(id) local had = SRC[id] ~= nil; SRC[id] = nil; return had end,
  cost = function(id)
    local s = SRC[id]
    if not s then return {} end
    -- Like the engine: what is RESIDENT, i.e. within the outermost band of
    -- the eye (the astronaut stands in for the camera).
    local node = by_name[s.parent]
    local ex, _, ez = axes_of(node)
    local far = s.lod[#s.lod].distance
    local n = 0
    for _, i in ipairs(instances(s)) do
      local wx = BODY.x + node.x + ex[1] * i.lx + ez[1] * i.lz
      local wy = BODY.y + node.y + ex[2] * i.lx + ez[2] * i.lz
      local wz = BODY.z + node.z + ex[3] * i.lx + ez[3] * i.lz
      if math.sqrt((wx - ASTRO.x) ^ 2 + (wy - ASTRO.y) ^ 2 + (wz - ASTRO.z) ^ 2) <= far then n = n + 1 end
    end
    return { props = n, chunks = 1 }
  end,
  near = function(id, p, radius)
    local s = SRC[id]
    if not s then return {} end
    local node = by_name[s.parent]
    local ex, _, ez = axes_of(node)
    local out = {}
    for _, i in ipairs(live(s)) do
      local wx = BODY.x + node.x + ex[1] * i.lx + ez[1] * i.lz
      local wy = BODY.y + node.y + ex[2] * i.lx + ez[2] * i.lz
      local wz = BODY.z + node.z + ex[3] * i.lx + ez[3] * i.lz
      local d = math.sqrt((wx - p.x) ^ 2 + (wy - p.y) ^ 2 + (wz - p.z) ^ 2)
      if d <= radius then
        out[#out + 1] = { id = i.id, pos = { x = wx, y = wy, z = wz }, distance = d, scale = i.scale, param = 0.5 }
      end
    end
    table.sort(out, function(a, b) return a.distance < b.distance end)
    return out
  end,
  remove = function(id, inst)
    local s = SRC[id]
    if not s then return false end
    local had = s.removed[inst]
    s.removed[inst] = true
    return not had
  end,
  restore = function(id, inst)
    local s = SRC[id]
    if not s then return 0 end
    if inst == nil then
      local n = 0
      for _ in pairs(s.removed) do n = n + 1 end
      s.removed = {}
      return n
    end
    local had = s.removed[inst]
    s.removed[inst] = nil
    return had and 1 or 0
  end,
  removed = function(id)
    local s = SRC[id]
    local out = {}
    if s then for k in pairs(s.removed) do out[#out + 1] = k end end
    table.sort(out)
    return out
  end,
}
local preload_calls = 0
API.assets = { preload = function(list, cb) preload_calls = preload_calls + 1; cb({}) end }
API.decals = nil

-- ── script loading ──────────────────────────────────────────────────────────
local envs = {}
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
  envs[kind] = env
  return env
end
function API.findScript(kind) return envs[kind] end
function API.findScripts(kind)
  if kind == "vessel_controller" then return {} end
  return envs[kind] and { envs[kind] } or {}
end

load_script("solar/scripts/materials.lua", "materials")
local inv = load_script("solar/scripts/inventory.lua", "inventory")
load_script("solar/scripts/climate.lua", "climate")
local mf = load_script("solar/scripts/mineral_field.lua", "mineral_field")

store["world." .. BODY.name] = {
  name = BODY.name, kind = "canyon", seed = 20260728, radius = SURFACE,
  relief = 24.0, sea = 0, atmo = 0.7, insol = 1.0,
}

local checks = {}
local function check(desc, ok, detail)
  checks[#checks + 1] = { desc = desc, ok = ok and true or false, detail = detail }
end

ASTRO.x, ASTRO.y, ASTRO.z = BODY.x + SURFACE + 1.0, BODY.y, BODY.z
local function tick(n)
  for _ = 1, n or 1 do
    T = T + 0.25
    mf.update({}, 0.25)
  end
end
tick(120)
check("rock is laid out around the crew", mf.patchCount > 0 and mf.sources > 0,
  mf.patchCount .. " patches, " .. mf.sources .. " sources")
check("…anchored to the world it lies on", mf.anchored == true and mf.bodyName == BODY.name)
check("…with rocks in it", mf.count > 10, mf.count)
local kinds = {}
for _, s in pairs(SRC) do kinds[s.lod[1].asset] = true end
check("every rock kind is laid somewhere", (function()
  for _, k in ipairs(mf.KIND_LIST) do if not kinds[k.lod[1]] then return false, k.id end end
  return true
end)())

-- Find a rock: sweep the ground around the crew.
local function find_rock(kind_id)
  for r = 1, 60 do
    for i = 0, 23 do
      local a = i * math.pi / 12
      local dir = { 0, math.cos(a), math.sin(a) }
      local px = BODY.x + SURFACE
      local py, pz = BODY.y + dir[2] * r, BODY.z + dir[3] * r
      -- back onto the sphere
      local dx, dy, dz = px - BODY.x, py - BODY.y, pz - BODY.z
      local l = math.sqrt(dx * dx + dy * dy + dz * dz)
      px, py, pz = BODY.x + dx / l * SURFACE, BODY.y + dy / l * SURFACE, BODY.z + dz / l * SURFACE
      local h = mf.nearest(px, py, pz, 3.0)
      if h and (not kind_id or h.kind.id == kind_id) then return h end
    end
  end
end
local rock = find_rock()
check("the laser can find a rock", rock ~= nil)
if rock then
  local r = math.sqrt((rock.pos.x - BODY.x) ^ 2 + (rock.pos.y - BODY.y) ^ 2 + (rock.pos.z - BODY.z) ^ 2)
  check("…lying on the ground, not on the patch plane above it", math.abs(r - SURFACE) < 0.05, r - SURFACE)
  local at = rock.pos
  local hit = mf.nearest(at.x, at.y, at.z, 1.0)
  check("aiming at it finds it", hit ~= nil and hit.distance < 0.05)
  local mat, took = mf.breakAt(hit, "astro")
  check("breaking it pays its material", mat == rock.kind.mat and took == rock.kind.yield, tostring(mat) .. " x" .. tostring(took))
  check("…into the pack", inv.count("astro", mat) >= took)
  local again = mf.nearest(at.x, at.y, at.z, 0.3)
  check("…and the rock is GONE", again == nil)
  check("the break is saved", (function()
    for k, v in pairs(store) do
      if k:match("^rocks2%.") and type(v) == "table" and #v >= 1 and v[1] == hit.id then return true end
    end
    return false
  end)())
  mf.clearAll()
  tick(120)
  check("a broken rock stays broken when the field is rebuilt", mf.nearest(at.x, at.y, at.z, 0.3) == nil)
  T = T + mf.params.regrow + 10
  tick(8)
  check("…and the field grows back after `regrow`", mf.nearest(at.x, at.y, at.z, 0.3) ~= nil)

  -- An old save's hole (a position in the patch plane) becomes an id.
  local rk = find_rock()
  if rk then
    local okey = string.format("rocks.%s.%s.%s", BODY.name, rk.patch, rk.kind.id)
    local nkey = string.format("rocks2.%s.%s.%s", BODY.name, rk.patch, rk.kind.id)
    store[okey] = { math.floor(rk.lx * 100 + 0.5) / 100, math.floor(rk.lz * 100 + 0.5) / 100 }
    store[nkey] = nil
    mf.clearAll()
    tick(120)
    check("an old hole save is converted: the rock stays broken", mf.nearest(rk.pos.x, rk.pos.y, rk.pos.z, 0.3) == nil)
    check("…the old record is deleted and the id saved", store[okey] == nil and type(store[nkey]) == "table"
      and store[nkey][1] == rk.id)
  end

  -- A full pack: the rock stays standing.
  local rock2 = find_rock()
  if rock2 then
    inv.add("astro", "iron", 1e6)
    inv.add("astro", "silica", 1e6)
    inv.add("astro", "regolith", 1e6)
    inv.add("astro", "crystal", 1e6)
    local p2 = rock2.pos
    local h2 = mf.nearest(p2.x, p2.y, p2.z, 1.0)
    local _, took2 = mf.breakAt(h2, "astro")
    check("a full pack breaks nothing…", took2 == 0)
    check("…and the rock is still standing", mf.nearest(p2.x, p2.y, p2.z, 0.3) ~= nil)
  end
end

-- The ground moved: rocks on it are declared again once the edits there go
-- quiet (flora_field folds the edits; mineral_field re-drops its own).
do
  load_script("solar/scripts/flora_field.lua", "flora_field")
  local srcs0, made0 = mf.sources, next_src
  for i = 1, 120 do
    mf.groundChanged(ASTRO.x - i * 0.05, ASTRO.y, ASTRO.z, 2.4)
    if i % 8 == 0 then T = T + 0.12; mf.update({}, 0.12) end
  end
  check("a laser's bites are one region for the rocks too", mf.groundBusy() == 1 and next_src == made0, mf.groundBusy())
  tick(8)
  local q = mf.groundBusy()
  tick(q + 20)
  check("…the rock sources under it are declared again, each once", next_src > made0 and next_src - made0 <= srcs0
    and mf.groundBusy() == 0, (next_src - made0) .. " of " .. srcs0)
  check("…and every source still stands", mf.sources == srcs0, mf.sources .. " vs " .. srcs0)
end

-- Airless crust still gets rock; a gas body gets none.
store["world." .. BODY.name].kind = "gas"
mf.clearAll()
tick(10)
check("a gas body has no rock on it", mf.sources == 0, mf.sources)

local bad = {}
for _, c in ipairs(checks) do
  if not c.ok then bad[#bad + 1] = "  ✗ " .. c.desc .. (c.detail and ("   [" .. tostring(c.detail) .. "]") or "") end
end
if #bad == 0 then
  print(string.format("MINERAL SMOKE OK — %d checks passed  (%d rocks resident, %d sources)", #checks, mf.count, mf.sources))
  os.exit(0)
end
print("MINERAL SMOKE FAILURES:")
for _, b in ipairs(bad) do print(b) end
for i = math.max(1, #logs - 10), #logs do print("  " .. tostring(logs[i])) end
os.exit(1)
