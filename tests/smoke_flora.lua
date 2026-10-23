-- SMOKE HARNESS: the living surface. Runs the real climate.lua, flora_gen.lua
-- and flora_field.lua against a stubbed engine and checks the whole chain —
-- world record → environment → species cast → library meshes on disk →
-- patches and scatter sources → harvest into the inventory → regrowth.
--
--   luajit solar/tests/smoke_flora.lua
--
-- Fidelity notes (the bugs this stub is shaped to catch):
--  * The planet is a real SPHERE: `raycast` and `terrain.query` answer
--    analytically at the body's surface radius, so a patch frame built wrong
--    puts its plants nowhere near the ground and the aim test misses.
--  * `scatter` is modelled as the engine does Ground regions: instances are a
--    pure function of (seed, chunk, index), placed in the PARENT NODE's frame,
--    rejected by the bilinear density grid. A density hole that is not exactly
--    where the plant stood leaves the plant standing, here as in the game.
--  * `near` answers as the engine does: once the draw driver has run, a prop is
--    `settled` and stands where it was dropped onto the sphere along the
--    patch's up, and `distance` measures to that landed place; before then it
--    answers `settled = false` on the patch plane, 20-30 m above the ground.
--  * Instance ids are 53-bit, as the engine's are since 0.117 (exact as Lua
--    numbers), and `remove`/`restore`/`removed` work as the engine's do: a
--    removed id generates nothing until it is restored.
--  * Every species' mesh files must exist on disk: a typo'd asset name is an
--    invisible plant in the game and a failed check here.

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
math.fbm = function(x, y, z) return noise(x, y, z, 3) * 0.8 end

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
local rare_nodes = 0   -- the handful of rare plants (and their glow) per world
function API.createNode(name, a, b)
  local parent, cb = nil, nil
  for _, v in ipairs({ a, b }) do
    if type(v) == "function" then cb = v elseif type(v) == "table" then parent = v end
  end
  if name:sub(1, 5) == "Rare " then rare_nodes = rare_nodes + 1 end
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
-- Frames the engine's draw driver has run (it runs after the scripts' update
-- each frame, and is what drops props onto the ground).
local DRAWN = 0
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
-- What the engine draws: every instance but the removed ones.
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
    assert(o.halfX and o.parent, "flora uses Ground regions anchored to a patch node")
    assert(by_name[o.parent], "parent node exists: " .. tostring(o.parent))
    if type(o.density) == "table" then
      assert(#o.density >= o.densityRows * o.densityRows, "density grid has rows² values")
    end
    for _, b in ipairs(o.lod or {}) do
      local f = io.open("solar/" .. b.asset, "r")
      assert(f, "scatter asset exists on disk: " .. b.asset)
      f:close()
    end
    if o.tint then assert(#o.tint == 3, "tint is {r,g,b}") end
    next_src = next_src + 1
    o.id = next_src
    o.removed = {}
    o.born = DRAWN   -- settles once the draw driver has run after this
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
    local ex, ey, ez = axes_of(node)
    local out = {}
    for _, i in ipairs(live(s)) do
      local wx = BODY.x + node.x + ex[1] * i.lx + ez[1] * i.lz
      local wy = BODY.y + node.y + ex[2] * i.lx + ez[2] * i.lz
      local wz = BODY.z + node.z + ex[3] * i.lx + ez[3] * i.lz
      -- Where it stands. Like the engine (scatter_draw.rs `settle`): once the
      -- draw driver has run since the source was declared, a prop is dropped
      -- onto the ground ALONG THE REGION'S OWN UP (the patch normal, not the
      -- radial) — cast from 60 m above, 150 m long — so its patch-plane x,z
      -- are unchanged and only its height moves. Until then, or with no
      -- ground under it, it answers `settled = false` at the nominal plane.
      -- `distance` and the radius test measure to wherever it stands.
      local px, py, pz, ux, uy, uz, settled = wx, wy, wz, ey[1], ey[2], ey[3], false
      if DRAWN > s.born then
        local hit = API.raycast(wx + ey[1] * 60, wy + ey[2] * 60, wz + ey[3] * 60, -ey[1], -ey[2], -ey[3], 150)
        ray_count = ray_count - 1   -- the engine's ray, not the script's
        if hit then
          px, py, pz, ux, uy, uz, settled = hit.x, hit.y, hit.z, hit.nx, hit.ny, hit.nz, true
        end
      end
      local d = math.sqrt((px - p.x) ^ 2 + (py - p.y) ^ 2 + (pz - p.z) ^ 2)
      if d <= radius then
        out[#out + 1] = { id = i.id, pos = { x = px, y = py, z = pz }, up = { x = ux, y = uy, z = uz },
                          distance = d, scale = i.scale, param = 0.5, settled = settled }
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
local cl = load_script("solar/scripts/climate.lua", "climate")
local fg = load_script("solar/scripts/flora_gen.lua", "flora_gen")
local ff = load_script("solar/scripts/flora_field.lua", "flora_field")

store["world." .. BODY.name] = {
  name = BODY.name, kind = "canyon", seed = 20260728, radius = SURFACE,
  relief = 24.0, sea = SURFACE - 6.0, atmo = 0.7, insol = 1.0,
}

local checks = {}
local function check(desc, ok, detail)
  checks[#checks + 1] = { desc = desc, ok = ok and true or false, detail = detail }
end

-- ── 1. climate ──────────────────────────────────────────────────────────────
local w = cl.worldOf(BODY.name)
check("the world record is published and read back", w and w.kind == "canyon", w and w.kind)
local equator = cl.sampleRel(w, SURFACE + 4, 0, 0)
local pole = cl.sampleRel(w, 0, SURFACE + 4, 0)
check("the poles are colder than the equator", pole.temp < equator.temp - 0.05)
check("below sea level is ocean", ({ ocean = 1, reef = 1 })[cl.sampleRel(w, SURFACE - 30, 0, 0).biome])

-- ── 2. the library ──────────────────────────────────────────────────────────
check("the generated library is in flora_gen", type(fg.LIBRARY) == "table" and #fg.LIBRARY >= 40,
  fg.LIBRARY and #fg.LIBRARY)
check("…with its palettes", type(fg.PALETTES) == "table" and #fg.PALETTES >= 16)
check("every library shape has its LOD files on disk (a tree's trunk too)", (function()
  for _, lib in ipairs(fg.LIBRARY) do
    for l = 0, lib.lods - 1 do
      local parts = { "" }
      if lib.twin then parts[2] = "_bark" end
      for _, part in ipairs(parts) do
        local path = string.format("solar/models/flora/%s%s_l%d.gltf", lib.id, part, l)
        local f = io.open(path, "r")
        if not f then return false, path end
        local txt = f:read("*a")
        f:close()
        -- linear with mipmaps, so far foliage doesn't shimmer
        if not txt:find('"minFilter":9987', 1, true) then return false, path .. " sampler" end
      end
    end
    local f = io.open("solar/models/flora/" .. lib.id .. ".bin", "rb")
    if not f then return false end
    f:close()
  end
  return true
end)())
check("…and the neutral pictures they tint", (function()
  local need = { "foliage_l0", "foliage_n", "foliage_glow", "rock_l0", "rock_n", "rock_mr", "bark_rough_l0", "bark_smooth_l0",
                 "bark_palm_l0", "bark_stalk_l0", "turf" }
  for _, n in ipairs(need) do
    local f = io.open("solar/textures/flora/" .. n .. ".png", "rb")
    if not f then return false, n end
    f:close()
  end
  return true
end)())
check("trees (and only trees) draw their trunk from a twin", (function()
  local n = 0
  for _, lib in ipairs(fg.LIBRARY) do
    if lib.twin then
      n = n + 1
      if lib.form ~= "tree" or not lib.bark then return false, lib.id end
    end
  end
  return n >= 10, n
end)())
check("grass, trees, shrubs, fungi, succulents, alien forms and kelp are all in it", (function()
  local kinds = {}
  for _, lib in ipairs(fg.LIBRARY) do kinds[lib.kind] = true end
  for _, k in ipairs({ "grass", "broadleaf", "conifer", "palm", "bush", "shrub", "fern", "succulent",
                       "cactus", "fungus", "spire", "crystal", "tubes", "coral", "kelp" }) do
    if not kinds[k] then return false end
  end
  return true
end)())

-- ── 3. species ──────────────────────────────────────────────────────────────
local sp1 = fg.speciesFor(BODY.name)
check("a living world rolls a cast", #sp1 >= 5, "#" .. #sp1)
check("…every species tinted (and a tree's trunk too)", (function()
  for _, s in ipairs(sp1) do
    if not (type(s.tint) == "table" and #s.tint == 3) then return false, s.name end
    if s.twin and not (type(s.barkTint) == "table" and #s.barkTint == 3) then return false, s.name end
    if (s.glow or 0) > 0 and not (s.emissive and s.emissiveStrength == s.glow) then return false, s.name end
  end
  return true
end)())
check("…named, shaped, coloured and useful", (function()
  for _, s in ipairs(sp1) do
    if type(s.name) ~= "string" or s.name == "" then return false end
    if #s.yields == 0 or not (s.height > 0) then return false end
    if not (s.palette and s.shape and s.scaleMin > 0 and s.scaleMax >= s.scaleMin) then return false end
  end
  return true
end)())
check("…with a grass carpet on a wet temperate world", (function()
  for _, s in ipairs(sp1) do if s.role == "carpet" and s.kind == "grass" then return true end end
  return false
end)())
check("…and trees", (function()
  for _, s in ipairs(sp1) do if s.form == "tree" then return true end end
  return false
end)())
check("a sea puts kelp in the water and nowhere else", (function()
  local aquatic = 0
  for _, s in ipairs(sp1) do
    if s.aquatic then aquatic = aquatic + 1 end
    if s.aquatic ~= (s.form == "kelp") then return false end
  end
  return aquatic >= 1
end)())
check("the roll is deterministic", (function()
  local again = fg.speciesFor(BODY.name)
  return again == sp1
end)())

-- Diversity: forty worlds, forty different floras.
local sigs, dup = {}, 0
local tints = {}
for i = 1, 40 do
  local nm = "W" .. i
  store["world." .. nm] = { name = nm, kind = ({ "canyon", "dune", "ice", "crystal" })[1 + i % 4],
    seed = 1000 + i * 7777, radius = 300, relief = 20, sea = (i % 3 == 0) and 295 or 0,
    atmo = 0.6, insol = 0.4 + (i % 5) * 0.2 }
  local list = fg.speciesFor(nm)
  local parts = {}
  for _, s in ipairs(list) do parts[#parts + 1] = s.shape .. "/" .. s.palette end
  table.sort(parts)
  local sig = table.concat(parts, ",")
  if sigs[sig] then dup = dup + 1 end
  sigs[sig] = true
  for _, s in ipairs(list) do tints[s.palette] = true end
end
local npal = 0
for _ in pairs(tints) do npal = npal + 1 end
check("forty worlds roll forty different floras", dup == 0, dup .. " duplicates")
check("…across most of the palettes", npal >= 12, npal .. " palettes used")

-- Light: a red dwarf's worlds go dark, a blue-white star's go pale/cool.
local function mean_value(starColor)
  local tot, n = 0, 0
  for i = 1, 30 do
    local nm = "S" .. tostring(starColor[3]) .. "_" .. i
    local rec = { name = nm, kind = "canyon", seed = 5000 + i * 31, radius = 300, relief = 20, sea = 0,
                  atmo = 0.6, insol = 1.0, starColor = starColor, gravity = 6 }
    for _, s in ipairs(fg.speciesFor(nm, rec)) do
      local c = s.leafColor
      tot = tot + (c[1] + c[2] + c[3]) / 3
      n = n + 1
    end
  end
  return tot / math.max(1, n)
end
local red = mean_value({ 1.0, 0.5, 0.34 })
local blue = mean_value({ 0.72, 0.82, 1.0 })
check("plants under a red dwarf are darker than under a blue-white star", red < blue - 0.05,
  string.format("%.2f vs %.2f", red, blue))

-- The terrain side's per-planet biome (scale-2 worlds): a published pigment
-- hint pulls the flora toward it, and barren regolith grows no grass carpet.
local function pigment_value(pig)
  local tot, n = 0, 0
  for i = 1, 20 do
    local nm = "B" .. tostring(pig[1]) .. "_" .. i
    local rec = { name = nm, kind = "canyon", seed = 7000 + i * 13, radius = 300, relief = 20, sea = 0,
                  atmo = 0.6, insol = 1.0, gravity = 6,
                  bio = { type = "steppe", temp = 0.5, moist = 0.6, fertility = 0.8, soil = "loam",
                          palette = { foliage = pig } } }
    for _, s in ipairs(fg.speciesFor(nm, rec)) do
      local c = s.leafColor
      tot = tot + (c[1] + c[2] + c[3]) / 3
      n = n + 1
    end
  end
  return tot / math.max(1, n)
end
local dark_pig, pale_pig = pigment_value({ 0.07, 0.06, 0.08 }), pigment_value({ 0.78, 0.9, 0.88 })
check("a published foliage pigment steers the palettes", dark_pig < pale_pig - 0.1,
  string.format("%.2f vs %.2f", dark_pig, pale_pig))
check("barren regolith grows no grass carpet", (function()
  local rec = { name = "Reg", kind = "barren", seed = 99, radius = 300, relief = 20, sea = 0, atmo = 0.5,
                insol = 1.0, bio = { type = "regolith", temp = 0.4, moist = 0.0, fertility = 0.0, soil = "regolith" } }
  for _, s in ipairs(fg.speciesFor("Reg", rec)) do if s.role == "carpet" then return false end end
  return true
end)())

-- Gravity: low gravity grows taller.
local function mean_tree(g)
  local tot, n = 0, 0
  for i = 1, 25 do
    local nm = "G" .. g .. "_" .. i
    local rec = { name = nm, kind = "canyon", seed = 9000 + i * 17, radius = 300, relief = 20, sea = 0,
                  atmo = 0.7, insol = 1.0, gravity = g }
    for _, s in ipairs(fg.speciesFor(nm, rec)) do
      if s.form == "tree" then tot = tot + (s.scaleMin + s.scaleMax) / 2; n = n + 1 end
    end
  end
  return tot / math.max(1, n)
end
local lowg, highg = mean_tree(2.5), mean_tree(11)
check("low gravity grows bigger plants than high gravity", lowg > highg * 1.15,
  string.format("%.2f vs %.2f", lowg, highg))

-- Glow is rare and subtle.
local glowing, total, maxglow = 0, 0, 0
for i = 1, 40 do
  for _, s in ipairs(fg.speciesFor("W" .. i)) do
    total = total + 1
    if s.glow > 0 then glowing = glowing + 1 end
    maxglow = math.max(maxglow, s.glow)
  end
end
check("glow is rare", glowing > 0 and glowing < total * 0.3, glowing .. "/" .. total)
check("…and never bright enough to wash a plant out", maxglow <= 0.8, maxglow)
check("glowing species carry glow sap", (function()
  for i = 1, 40 do
    for _, s in ipairs(fg.speciesFor("W" .. i)) do
      if s.glow > 0 then
        local has = false
        for _, y in ipairs(s.yields) do if y.mat == "glowsap" then has = true end end
        if not has then return false end
      end
    end
  end
  return true
end)())

store["world.Dead"] = { name = "Dead", kind = "barren", seed = 5, radius = 90, relief = 6, sea = 0, atmo = 0, insol = 0.4 }
check("nothing grows on an airless world", #fg.speciesFor("Dead") == 0)
local LATE = "LateWorld"
LATE_BODY = { name = LATE, x = 9e5, y = 0, z = 0, radius = 180, soi = 4000, mu = 1e5 }
check("a world with no record yet grows nothing", #fg.speciesFor(LATE) == 0)
store["world." .. LATE] = { name = LATE, kind = "canyon", seed = 42, radius = 180, relief = 12, atmo = 0.7, sea = 0, insol = 1.0 }
check("…and grows again once its record arrives, rather than staying bare", #fg.speciesFor(LATE) > 0)

local y = fg.harvestYield(sp1[1], 4242)
check("a plant yields materials", #y > 0 and y[1].n > 0)
check("…the same ones every time it's asked", (function()
  local z = fg.harvestYield(sp1[1], 4242)
  for i, e in ipairs(z) do if e.mat ~= y[i].mat or e.n ~= y[i].n then return false end end
  return #z == #y
end)())

-- ── 4. the field ────────────────────────────────────────────────────────────
-- Stand on dry land (just above the sea, at the equator).
ASTRO.x, ASTRO.y, ASTRO.z = BODY.x + SURFACE + 1.0, BODY.y, BODY.z
local function tick(n)
  for _ = 1, n or 1 do
    T = T + 0.25
    ff.update({}, 0.25)
    ff.lateUpdate({}, 0.25)
    DRAWN = DRAWN + 1
  end
end
ff.params.interval = 0.0
local nodes_before = nodes_made - rare_nodes
tick(80)
check("the meshes are preloaded before anything is scattered", preload_calls == 1, preload_calls)
check("standing on a living world opens patches", ff.patchCount > 0, ff.patchCount)
check("…and scatter sources on them", ff.sources > 0, ff.sources)
check("…with plants in them", ff.count > 0, ff.count)
check("…within the prop budget", ff.count <= ff.params.max_props * 1.25, ff.count)
check("the field costs a handful of nodes, not one per plant",
  nodes_made - rare_nodes - nodes_before <= ff.patchCount + ff.params.motes + 2,
  (nodes_made - rare_nodes - nodes_before) .. " nodes for " .. ff.count .. " plants")
check("…anchored to the body we're on", ff.bodyName == BODY.name)

-- The patch frame is right: a plant's rolled place lies in a plane tangent to
-- the sphere at the patch centre, and its ground point is on the surface.
local any = ff.nearestPlant(ASTRO.x, ASTRO.y, ASTRO.z, 1, 0, 0, 60, -1)
check("the cutter can find a plant", any ~= nil)
check("…standing on the ground", any and math.abs(math.sqrt((any.x - BODY.x) ^ 2 + (any.y - BODY.y) ^ 2
  + (any.z - BODY.z) ^ 2) - SURFACE) < 0.05)

-- Determinism: walk away, clear, come back.
local before = ff.surveyLines(ASTRO.x, ASTRO.y, ASTRO.z, 40)
ff.clearAll()
tick(80)
local after = ff.surveyLines(ASTRO.x, ASTRO.y, ASTRO.z, 40)
check("the same ground regrows the same stand", (function()
  if #before ~= #after or #before == 0 then return false end
  for i, l in ipairs(before) do if l ~= after[i] then return false end end
  return true
end)(), #before .. " vs " .. #after)

-- In orbit nothing new is planted.
ASTRO.x = BODY.x + SURFACE + 2000
local kept = ff.sources
tick(2)
check("nothing new is planted from orbit", ff.sources <= kept)
ASTRO.x = BODY.x + SURFACE + 1.0
tick(40)

-- ── 5. harvesting ───────────────────────────────────────────────────────────
-- Aim at a tall plant's trunk from beside it (not at its root).
local tall
for i = 0, 35 do
  local a = i * 0.1745
  local h = ff.nearestPlant(ASTRO.x, ASTRO.y, ASTRO.z, 0, math.cos(a), math.sin(a), 40, -1)
  if h and (not tall or h.height > tall.height) then tall = h end
end
check("there is something tall to aim at", tall ~= nil and tall.height > 1.0, tall and tall.height)
if tall then
  local ux, uy, uz = tall.ux, tall.uy, tall.uz
  local sx, sy, sz = 0, 1, 0
  if math.abs(uy) > 0.9 then sx, sy, sz = 1, 0, 0 end
  local ex = tall.x + sx * 1.2 + ux * 1.5
  local ey = tall.y + sy * 1.2 + uy * 1.5
  local ez = tall.z + sz * 1.2 + uz * 1.5
  local up_at = tall.height * 0.9
  local tx, ty, tz = tall.x + ux * up_at, tall.y + uy * up_at, tall.z + uz * up_at
  local ax, ay, az = tx - ex, ty - ey, tz - ez
  local al = math.sqrt(ax * ax + ay * ay + az * az)
  ax, ay, az = ax / al, ay / al, az / al
  local trunk = ff.nearestPlant(ex, ey, ez, ax, ay, az, 8.0, 0.55, 1.5)
  check("aiming at a plant's TRUNK finds it", trunk ~= nil and trunk.pid == tall.pid)
  check("…and says where to put the beam", trunk and trunk.ax ~= nil and trunk.height ~= nil)

  local spname = tall.rec.sp.name
  local n0 = #ff.surveyLines(tall.x, tall.y, tall.z, 0.5)
  local got, dropped = ff.harvest(tall, "astro")
  check("harvesting yields into the pack", #got > 0, got[1] and got[1].mat)
  check("…the pack holds it", #got > 0 and inv.count("astro", got[1].mat) >= got[1].n)
  local again = ff.nearestPlant(ex, ey, ez, ax, ay, az, 8.0, 0.55, 1.5)
  check("…and the plant is GONE (not just paid for)", again == nil
    or math.sqrt((again.x - tall.x) ^ 2 + (again.y - tall.y) ^ 2 + (again.z - tall.z) ^ 2) > 0.05)
  local still = 0
  for _, l in ipairs(ff.surveyLines(tall.x, tall.y, tall.z, 0.3)) do
    if l:find(spname, 1, true) then still = still + 1 end
  end
  check("…from the field itself, not just the aim test", still == 0, n0 .. " → " .. still)
  check("the cut is saved", (function()
    for k, v in pairs(store) do
      if k:match("^flora2%.") and type(v) == "table" and #v >= 1 and v[1] == tall.rec.inst then return true end
    end
    return false
  end)())
  -- It stays cut across a rebuild (a reload streams the patch back in).
  ff.clearAll()
  tick(80)
  local back = ff.nearestPlant(ex, ey, ez, ax, ay, az, 8.0, 0.55, 1.5)
  local function same(h)
    return h and math.sqrt((h.x - tall.x) ^ 2 + (h.y - tall.y) ^ 2 + (h.z - tall.z) ^ 2) < 0.05
  end
  check("a cut plant stays cut when the field is rebuilt", not same(back))
  -- …and grows back once `regrow` has passed.
  T = T + ff.params.regrow + 10
  tick(4)
  local grown = ff.nearestPlant(ex, ey, ez, ax, ay, az, 8.0, 0.55, 1.5)
  check("…but grows back after `regrow`", same(grown))
  check("dropped units are reported, not silently voided", dropped >= 0)
end

-- An old save's "hole" (a position in the patch plane, from before ids were
-- exact) becomes an id: the plant that stood there stays cut, and the old
-- record goes.
do
  local h
  for i = 0, 35 do
    local a = i * 0.1745
    local c = ff.nearestPlant(ASTRO.x, ASTRO.y, ASTRO.z, 0, math.cos(a), math.sin(a), 40, -1)
    if c then h = c; break end
  end
  check("an old hole save has a plant to test on", h ~= nil)
  if h then
    local okey = string.format("flora.%s.%s.%d", BODY.name, h.rec.patch, h.rec.sp.id)
    local nkey = string.format("flora2.%s.%s.%d", BODY.name, h.rec.patch, h.rec.sp.id)
    store[okey] = { math.floor(h.rec.lx * 100 + 0.5) / 100, math.floor(h.rec.lz * 100 + 0.5) / 100 }
    store[nkey] = nil
    ff.clearAll()
    tick(80)
    local still = false
    for _, l in ipairs(ff.surveyLines(h.x, h.y, h.z, 0.05)) do
      if l:find(h.rec.sp.name, 1, true) then still = true end
    end
    check("an old hole save is converted: the plant stays cut", not still)
    check("…the old record is deleted and the id saved", store[okey] == nil and type(store[nkey]) == "table"
      and store[nkey][1] == h.rec.inst, tostring(store[nkey] and store[nkey][1]) .. " vs " .. tostring(h.rec.inst))
  end
end

-- ── report ──────────────────────────────────────────────────────────────────
local bad = {}
for _, c in ipairs(checks) do
  if not c.ok then
    bad[#bad + 1] = "  ✗ " .. c.desc .. (c.detail and ("   [" .. tostring(c.detail) .. "]") or "")
  end
end
if #bad == 0 then
  print(string.format("FLORA SMOKE OK — %d checks passed  (%d props, %d sources, %d rays)",
    #checks, ff.count, ff.sources, ray_count))
  os.exit(0)
end
print("FLORA SMOKE FAILURES:")
for _, b in ipairs(bad) do print(b) end
print("\n-- script logs --")
for i = math.max(1, #logs - 20), #logs do print("  " .. tostring(logs[i])) end
os.exit(1)
