-- CLIMATE — what a place on a planet is LIKE, and therefore what grows there.
--
-- The generator rolls a world's physical facts once (archetype, radius, relief,
-- how much sunlight it gets, whether it has air, where its sea sits) and
-- publishes them to `save.world.<name>`. This script turns those facts plus a
-- position into the three numbers everything downstream actually wants:
--
--     temperature   0 = frozen solid, 1 = scorching
--     moisture      0 = bone dry,     1 = swamp
--     elevation     metres above (or below) the sea, or above the mean surface
--                   on a world that has no sea
--
-- …and the BIOME they add up to. Flora density and species mix come from the
-- biome; so do the shoreline, the snow line and where an ocean starts.
--
-- The model is deliberately simple and deterministic: latitude cools you, height
-- cools you, the sea wets you, and a seeded noise field does the rest. No
-- weather simulation — the point is that two planets rolled from different seeds
-- feel like different WORLDS, not that any one of them is meteorologically real.
--
--     local cl = findScript("climate")
--     local s = cl.sampleAt("Golil", x, y, z)   -- {biome, temp, moist, elev, …}
--     cl.isUnderwater(x, y, z)                  -- for swimming / splashdowns

defaults = {}

-- Biome table. `flora` scales scatter density (0 = nothing grows), `wet` marks
-- the underwater ones, and `label` is what a survey readout says.
BIOMES = {
  ocean    = { label = "Ocean",         flora = 0.55, wet = true },
  reef     = { label = "Shallows",      flora = 1.00, wet = true },
  shore    = { label = "Shoreline",     flora = 0.85 },
  wetland  = { label = "Wetland",       flora = 1.30 },
  forest   = { label = "Forest",        flora = 1.45 },
  jungle   = { label = "Jungle",        flora = 1.80 },
  grass    = { label = "Grassland",     flora = 0.95 },
  steppe   = { label = "Steppe",        flora = 0.45 },
  desert   = { label = "Desert",        flora = 0.18 },
  tundra   = { label = "Tundra",        flora = 0.30 },
  snow     = { label = "Snowfield",     flora = 0.08 },
  highland = { label = "Highlands",     flora = 0.35 },
  ash      = { label = "Ash Waste",     flora = 0.10 },
  crystal  = { label = "Crystal Flats", flora = 0.40 },
  barren   = { label = "Barren",        flora = 0.0 },
}

-- Archetype character: base temperature, base moisture, and whether the world
-- can hold liquid water at all. These are the planet's personality before
-- latitude and altitude get a say.
local KIND = {
  canyon  = { temp = 0.55, moist = 0.45, seas = true },
  dune    = { temp = 0.78, moist = 0.12, seas = false },
  ice     = { temp = 0.16, moist = 0.55, seas = false },
  frost   = { temp = 0.12, moist = 0.40, seas = false },
  lava    = { temp = 0.95, moist = 0.05, seas = false },
  crystal = { temp = 0.45, moist = 0.25, seas = false },
  barren  = { temp = 0.40, moist = 0.02, seas = false },
}

function kindOf(kind)
  return KIND[kind] or KIND.barren
end

-- ── the world record ────────────────────────────────────────────────────────
-- Published by system_generator at roll time. Absent (an authored scene, an old
-- save) we still answer, from whatever the rails know — a body always has a
-- radius and a µ, and "barren, airless, no sea" is the honest default.

-- Read once a frame: the record is asked for per ground sample (the base's
-- water test, the flora, the lakes), and each save.get turned it into Lua
-- again — 8–12 ms of a base-siting frame. Shared within the frame: read it,
-- never write into it.
WORLD_MEMO = { t = nil, slot = nil, recs = {} }
function worldOf(name)
  if not name then return nil end
  local w
  local now = time
  if now then
    local m = WORLD_MEMO
    local sl = save.slot and save.slot() or ""
    if m.t ~= now or m.slot ~= sl then m.t, m.slot, m.recs = now, sl, {} end
    w = m.recs[name]
    if w == nil then
      w = save.get("world." .. name)
      m.recs[name] = w   -- (a miss is not kept: a record can arrive this frame)
    end
  else
    w = save.get("world." .. name)
  end
  if w then return w end
  local b = space.body(name)
  if not b then return nil end
  return { kind = "barren", seed = 1, radius = b.radius or 100, relief = 0,
           sea = 0, atmo = 0, insol = 1.0, name = name }
end

function seaRadius(name)
  local w = worldOf(name)
  return (w and w.sea) or 0
end

-- Does this world have air a plant could breathe? Flora needs SOMETHING; the
-- airless moons stay bare, which is what makes a living world land.
function habitable(name)
  local w = worldOf(name)
  if not w then return false end
  return (w.atmo or 0) > 0.15
end

-- ── the sample ──────────────────────────────────────────────────────────────

local function len(x, y, z)
  return math.sqrt(x * x + y * y + z * z)
end

-- Pure core, so the smoke harness can drive it without a scene: given the world
-- record and a BODY-RELATIVE position, what is it like here?
function sampleRel(w, rx, ry, rz)
  local r = len(rx, ry, rz)
  if r < 1e-6 then r = 1e-6 end
  local radius = w.radius or 100
  local relief = math.max(1.0, w.relief or (radius * 0.06))
  local base = kindOf(w.kind)
  local seed = (w.seed or 1) % 4096

  -- Latitude from the body's own polar axis (+Y in its local frame). Poles are
  -- cold, the equator is not — the one piece of planetary physics that reads
  -- instantly from the ground.
  local lat = math.abs(ry / r)                 -- 0 = equator, 1 = pole
  local sea = w.sea or 0
  local ground = r                              -- radius of this point
  local elev = (sea > 0) and (ground - sea) or (ground - radius)

  -- Insolation scales the archetype's base temperature (a canyon world close in
  -- is a desert; the same roll further out is a steppe).
  -- A scale-3 world publishes its own climate anchor (`climTemp`, from the
  -- geology's equilibrium temperature: starlight, air and greenhouse), which
  -- replaces the archetype's guess.
  local t = w.climTemp or (base.temp * (0.55 + 0.45 * (w.insol or 1.0)))
  t = t - lat * lat * 0.42                      -- polar cooling
  t = t - math.max(0, elev) / relief * 0.22     -- lapse rate with height
  -- A thick atmosphere evens the extremes out; a thin one lets them run.
  local atmo = w.atmo or 0
  t = 0.5 + (t - 0.5) * (1.0 - 0.30 * atmo)
  -- Regional weather: two octaves of the engine's own noise field, seeded per
  -- world so every planet's map of hot and cold is its own.
  local nx, ny, nz = rx / radius * 3.1, ry / radius * 3.1, rz / radius * 3.1
  t = t + math.noise(nx, ny, nz, seed) * 0.10
  t = math.max(0, math.min(1, t))

  local mo = (w.climMoist or base.moist) * (0.5 + 0.5 * atmo)
  if sea > 0 then
    -- Near the sea is wet; a thousand metres above it is not. The falloff is in
    -- units of the world's own relief, so a flat world is wet all over and a
    -- mountainous one has a genuine rain shadow.
    mo = mo + 0.55 * math.max(0, 1.0 - math.max(0, elev) / (relief * 0.9))
  end
  mo = mo + math.noise(nz * 2.3 + 11.0, nx * 2.3, ny * 2.3, seed + 7) * 0.22
  mo = mo - math.max(0, (t - 0.75)) * 0.6       -- the hot places bake dry
  mo = math.max(0, math.min(1, mo))

  local biome = biomeFrom(w, t, mo, elev, relief, sea)
  return { biome = biome, temp = t, moist = mo, elev = elev, lat = lat,
           sea = sea, radius = radius, relief = relief, kind = w.kind,
           label = (BIOMES[biome] or BIOMES.barren).label,
           density = (BIOMES[biome] or BIOMES.barren).flora }
end

-- Temperature + moisture + height → biome. Order matters: water first (you are
-- either under the sea or you aren't), then the extremes, then the middle.
function biomeFrom(w, t, mo, elev, relief, sea)
  if (w.atmo or 0) <= 0.15 then
    -- Airless: the archetype IS the biome. Nothing grows, but the survey
    -- readout should still say something true about where you're standing.
    if w.kind == "lava" then return "ash" end
    if w.kind == "crystal" then return "crystal" end
    if w.kind == "ice" or w.kind == "frost" then return "snow" end
    return "barren"
  end
  if sea > 0 and elev < 0 then
    return elev > -relief * 0.18 and "reef" or "ocean"
  end
  if sea > 0 and elev < relief * 0.05 then return "shore" end
  if t < 0.18 then return "snow" end
  if t < 0.32 then return mo > 0.45 and "tundra" or "steppe" end
  if elev > relief * 0.72 then return "highland" end
  if t > 0.82 and mo < 0.35 then return "desert" end
  if mo > 0.72 then
    if t > 0.62 then return "jungle" end
    return t > 0.40 and "wetland" or "forest"
  end
  if mo > 0.45 then return t > 0.70 and "jungle" or "forest" end
  if mo > 0.24 then return "grass" end
  if t > 0.70 then return "desert" end
  return "steppe"
end

-- The scene-facing form: a WORLD position, resolved against the body it belongs
-- to. Returns nil off every world (deep space is not a climate).
function sampleAt(name, x, y, z)
  local w = worldOf(name)
  local b = name and space.body(name)
  if not (w and b) then return nil end
  return sampleRel(w, x - b.x, y - b.y, z - b.z)
end

-- ── water ───────────────────────────────────────────────────────────────────
-- One rule, used by the swimmer, the splashdown check, the oxygen, the sound,
-- the underwater look and the flora scatter: WATER IS A CONNECTED BODY.
--
-- The sea is a sphere at a fixed radius, but a point under that radius is in
-- the sea only when the sea can reach it:
--
--   * OPEN WATER — the column straight up from the point to the sea's surface
--     is open (no rock over it), and the surface there is open sea, not a hole
--     in the land (the ring of the surface 8 m round it is mostly water).
--   * A FLOODED CAVE — the column is roofed, but the cave the point is in
--     reaches open water through passages that stay below the sea's level.
--     Found by a bounded flood fill over 2 m cells of the terrain's own
--     distance field (`flood_*` below), run a slice a frame in `update`, and
--     kept per cave for a while. Until a cave has been looked at it reads
--     DRY, so a roofed point is never wet by default.
--
-- Everything else under the sea's radius — a cave under a mountain, a dry
-- grotto under the seabed sealed by rock, a pit dug below sea level from dry
-- land — is air. (Before, the sea was the whole sphere, and the engine's sea
-- volume turned every cave below sea level into murky water: ocean.lua now
-- switches that volume's look off whenever the eye is somewhere this says is
-- dry.)

local COL_STEPS = 40      -- sphere-trace steps up a column
local FLOOD_CELL = 1.5    -- flood-fill cell (m)
local FLOOD_MAX = 3200    -- cells one cave may visit before it is called dry
local FLOOD_KEEP = 25.0   -- seconds a cave's answer is kept (digging changes it)
local FLOOD_SLICE = 400   -- field reads a frame the flood may spend (1–5 µs each)
local FLOOD_KEEP_BUSY = 2.0 -- …a dry answer found while the terrain is streaming
local WET_HOLD = 1.5      -- s a point just read wet stays wet through a dry read
local WET_HOLD_BUSY = 5.0 -- …while the terrain worker is streaming ground in
local WET_NEAR = 4.0      -- m: how close a later read must be to keep the hold

-- Is the column from body-relative point (px,py,pz) straight up to radius
-- `top` open? true / false, or nil when the field is not answering there.
function columnOpen(bx, by, bz, px, py, pz, top)
  if not (terrain and terrain.query) then return nil end
  local r = len(px, py, pz)
  if r < 1e-6 then return nil end
  local ux, uy, uz = px / r, py / r, pz / r
  local t = r
  for _ = 1, COL_STEPS do
    if t >= top then return true end
    local q = terrain.query(bx + ux * t, by + uy * t, bz + uz * t)
    if q == nil then return nil end
    if q < 0.05 then return false end
    t = t + math.max(q, 0.3)
  end
  -- A very deep column still being marched is open water (the sea floor
  -- is far below): only rock stops it.
  return true
end

-- Is the sea's surface over unit direction (ux,uy,uz) open sea? (The ring
-- of the surface 8 m round it: open sea is open there, a hole in the land is
-- ringed with rock.)
local function surface_open(bx, by, bz, ux, uy, uz, sea)
  local ax, ay, az = 0, 1, 0
  if math.abs(uy) > 0.9 then ax, ay, az = 1, 0, 0 end
  local t1x, t1y, t1z = uy * az - uz * ay, uz * ax - ux * az, ux * ay - uy * ax
  local l = len(t1x, t1y, t1z)
  t1x, t1y, t1z = t1x / l, t1y / l, t1z / l
  local t2x, t2y, t2z = uy * t1z - uz * t1y, uz * t1x - ux * t1z, ux * t1y - uy * t1x
  local open, n = 0, 0
  for k = 0, 7 do
    local a = k * math.pi / 4
    local ca, sa = math.cos(a) * 8, math.sin(a) * 8
    local q = terrain.query(bx + ux * sea + t1x * ca + t2x * sa, by + uy * sea + t1y * ca + t2y * sa,
      bz + uz * sea + t1z * ca + t2z * sa)
    if q then
      n = n + 1
      if q > 0 then open = open + 1 end
    end
  end
  if n == 0 then return nil end
  return open * 2 >= n
end

-- ── the sea's reach ─────────────────────────────────────────────────────────
-- THERE IS NO SET WATER LEVEL (Ty, 2026-11-12). The sea is a sphere, but a
-- hollow under its radius holds sea only when the sea can REACH it across the
-- surface: a trench cut from the beach floods, a quarry dug inland below sea
-- level is a dry quarry. (The ring test above, 8 m of the surface round the
-- point, called any pit wider than 16 m "sea", wherever it was dug: with the
-- colony sited metres over the sea's radius, digging always found water.)
--
-- The reach is a bounded flood over the sea's surface from the point's own
-- cell, through cells that are open air at the sea's radius: it is SEA when
-- it has found REACH_WIDE open cells (a basin that size at the sea's level is
-- sea, not a pit: a dug hole is called sea only past ~3,600 m² of open water)
-- or gets REACH_BOUND m from where it started, and DRY when ground closes it
-- in first. (A "deep water under the cell" shortcut was tried and dropped:
-- a laser pit 5 m deep read as sea.)
-- Every open cell a finished flood visited is kept (REACH_CELL cube-face
-- cells of the sea sphere), so a swimmer's reads are a table lookup; a dig or
-- fill that lands near the sea's radius forgets the body's cells, and the
-- next read floods again. A fresh question spends up to REACH_INLINE field
-- reads on the spot (a shore finds its shelf in a handful), and a bigger one
-- goes on as a job (REACH_SLICE reads a frame); while it runs, the point
-- reads dry (the WET HOLD below carries a swimmer over it). Where the field is
-- cold (streaming ground) the ring test stands in, as before.
local REACH_CELL = 3.0
local REACH_BOUND = 100.0
local REACH_WIDE = 400
-- (enough for an open-sea cell to be called sea on the spot: a swimmer put
-- down mid-ocean is wet the same frame; about 0.6 ms once per cached region)
local REACH_INLINE = 440
local REACH_SLICE = 600
local REACH_JOBS = 3
local reach = { body = nil, cells = {}, jobs = {}, njobs = 0, R = 0 }
reachStats = { floods = 0, wet = 0, dry = 0, cold = 0, deferred = 0, cells = 0 }

local function tangent_basis(ux, uy, uz)
  local ax, ay, az = 0, 1, 0
  if math.abs(uy) > 0.9 then ax, ay, az = 1, 0, 0 end
  local t1x, t1y, t1z = uy * az - uz * ay, uz * ax - ux * az, ux * ay - uy * ax
  local l = len(t1x, t1y, t1z)
  t1x, t1y, t1z = t1x / l, t1y / l, t1z / l
  return t1x, t1y, t1z, uy * t1z - uz * t1y, uz * t1x - ux * t1z, ux * t1y - uy * t1x
end

-- The cube-face cell (a number) of unit direction (ux,uy,uz), REACH_CELL m
-- wide at radius R (a little narrower toward a face's corners).
local function rkey(ux, uy, uz, R)
  local ax, ay, az = math.abs(ux), math.abs(uy), math.abs(uz)
  local f, u, v
  if ax >= ay and ax >= az then f = ux > 0 and 0 or 1; u, v = uy / ax, uz / ax
  elseif ay >= az then f = uy > 0 and 2 or 3; u, v = ux / ay, uz / ay
  else f = uz > 0 and 4 or 5; u, v = ux / az, uy / az end
  local n = math.max(4, math.floor(R * 1.5708 / REACH_CELL))
  local i = math.min(n - 1, math.floor((u + 1) * 0.5 * n))
  local j = math.min(n - 1, math.floor((v + 1) * 0.5 * n))
  return (f * 4096 + i) * 4096 + j
end

local function reach_reset(name, R)
  reach.body, reach.R, reach.cells, reach.jobs, reach.njobs = name, R, {}, {}, 0
  reach.cold = {}
  reachStats.cells = 0
end

-- One slice of a reach flood: `budget` field reads. Sets J.done, J.wet
-- (true/false) or J.cold (the field did not answer).
local function reach_step(J, budget)
  local b = J.b
  local R, ux, uy, uz = J.R, J.ux, J.uy, J.uz
  local t1x, t1y, t1z, t2x, t2y, t2z = J.t1x, J.t1y, J.t1z, J.t2x, J.t2y, J.t2z
  local bound2 = REACH_BOUND * REACH_BOUND
  while J.head <= #J.queue and budget > 0 do
    local c = J.queue[J.head]
    J.head = J.head + 1
    local a, cc = c[1] * REACH_CELL, c[2] * REACH_CELL
    if a * a + cc * cc >= bound2 then J.wet, J.done = true, true return budget end
    local dx, dy, dz = ux + (t1x * a + t2x * cc) / R, uy + (t1y * a + t2y * cc) / R, uz + (t1z * a + t2z * cc) / R
    local l = len(dx, dy, dz)
    dx, dy, dz = dx / l, dy / l, dz / l
    local q = terrain.query(b.x + dx * R, b.y + dy * R, b.z + dz * R)
    budget = budget - 1
    if q == nil then J.cold, J.done = true, true return budget end
    if q > 0.05 then
      J.open[#J.open + 1] = rkey(dx, dy, dz, R)
      -- Open water REACH_WIDE cells wide at the sea's level is sea (a hole
      -- that size is a basin, not a pit), whatever closes it in further out.
      if #J.open >= REACH_WIDE then J.wet, J.done = true, true return budget end
      local i, j = c[1], c[2]
      for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
        local ni, nj = i + d[1], j + d[2]
        local k = ni * 100000 + nj
        if not J.seen[k] then
          J.seen[k] = true
          J.queue[#J.queue + 1] = { ni, nj }
        end
      end
    end
  end
  if J.head > #J.queue then J.wet, J.done = false, true end
  return budget
end

local function reach_finish(key, J)
  reach.jobs[key] = nil
  reach.njobs = reach.njobs - 1
  if J.cold then
    -- asked again in two seconds, not on every read
    reach.cold = reach.cold or {}
    reach.cold[key] = reach.clock or 0
    reachStats.cold = reachStats.cold + 1
    return
  end
  reachStats.floods = reachStats.floods + 1
  if J.wet then reachStats.wet = reachStats.wet + 1 else reachStats.dry = reachStats.dry + 1 end
  local now = reach.clock or 0
  for _, k in ipairs(J.open) do
    if not reach.cells[k] then reachStats.cells = reachStats.cells + 1 end
    -- (a flood run while the ground was still streaming in is asked again
    -- in a while; its answer stands until the new one lands)
    reach.cells[k] = { wet = J.wet, t = now, soft = J.busy or nil }
  end
end

-- Can the sea reach the surface point over unit direction (ux,uy,uz) of body
-- `name` (position b, sea radius R)? → true / false, and a second value:
-- "pending" (a flood is running: the caller treats the point as dry for now)
-- or "cold" (the field is not answering there: no verdict).
local function reach_query(name, b, R, ux, uy, uz)
  if reach.body ~= name or reach.R ~= R then reach_reset(name, R) end
  local key = rkey(ux, uy, uz, R)
  -- ONE ANSWER PER CELL, AND IT STICKS (cpuperf, 11-13: a pit beside Kaia's
  -- sea read dry, then wet, then dry as answers expired, floods ran against
  -- half-streamed ground and "cold" fell back to the ring test: the walker
  -- flipped between running and swimming). A cell's answer never expires by
  -- the clock. A dig near the sea's radius, or an answer got while the ground
  -- was streaming, marks it STALE: it is asked again in the background and
  -- keeps answering as before until the new flood lands. A cell with no
  -- answer yet is dry while its first flood runs, and where the field is
  -- cold there is no flood and no guess: the last answer, else dry.
  local c = reach.cells[key]
  local now = reach.clock or 0
  if c and c.soft and now - c.t > 12 and not (terrain.busy and terrain.busy()) then c.stale, c.soft = true, nil end
  if c and not c.stale then return c.wet end
  local held = c and c.wet or false
  local ct = reach.cold and reach.cold[key]
  if ct and now - ct < 2.0 then return held, "cold" end
  if reach.jobs[key] then return held, (not c) and "pending" or nil end
  if reach.njobs >= REACH_JOBS then
    reachStats.deferred = reachStats.deferred + 1
    return held, (not c) and "pending" or nil
  end
  local t1x, t1y, t1z, t2x, t2y, t2z = tangent_basis(ux, uy, uz)
  local J = { b = { x = b.x, y = b.y, z = b.z }, R = R, ux = ux, uy = uy, uz = uz,
    t1x = t1x, t1y = t1y, t1z = t1z, t2x = t2x, t2y = t2y, t2z = t2z,
    queue = { { 0, 0 } }, head = 1, seen = { [0] = true }, open = {}, done = false,
    busy = (terrain.busy and terrain.busy()) or false }
  reach_step(J, REACH_INLINE)
  if J.done then
    reach.njobs = reach.njobs + 1
    reach.jobs[key] = J
    reach_finish(key, J)
    -- cold: no verdict and no guess; the last answer stands (dry if none)
    if J.cold then return held, "cold" end
    return J.wet
  end
  reach.jobs[key] = J
  reach.njobs = reach.njobs + 1
  reachStats.deferred = reachStats.deferred + 1
  return held, (not c) and "pending" or nil
end

-- The floods under way, REACH_SLICE reads a frame between them. The body
-- moves on its rails between frames, so each job reads it again.
local function reach_tick(budget)
  if reach.njobs == 0 then return end
  local b = reach.body and space.body(reach.body)
  if not b then reach_reset(nil, 0) return end
  for key, J in pairs(reach.jobs) do
    if budget <= 0 then return end
    J.b.x, J.b.y, J.b.z = b.x, b.y, b.z
    budget = reach_step(J, budget)
    if J.done then reach_finish(key, J) end
  end
end

-- A dig or a fill that landed near the sea's radius: the cells are forgotten
-- (a channel may have opened or closed), the floods under way with them.
local function reach_forget()
  -- (stale, not gone: each cell keeps answering as it did until its new
  -- flood lands, so a dig beside a swimmer does not blink the water off)
  for _, c in pairs(reach.cells) do c.stale = true end
end

-- ── flooded caves ───────────────────────────────────────────────────────────
-- flood.cells["i,j,k"] = { wet = bool, t = time } for every cell a finished
-- fill visited (the whole cave, as far as it went); flood.jobs are fills
-- under way, keyed by their start cell.
local flood = { cells = {}, jobs = {}, n = 0, body = nil, clock = 0 }
local function fkey(i, j, k) return i .. "," .. j .. "," .. k end
local function fcell(px, py, pz)
  return math.floor(px / FLOOD_CELL + 0.5), math.floor(py / FLOOD_CELL + 0.5), math.floor(pz / FLOOD_CELL + 0.5)
end

-- Answer for a roofed point under the sea: true (flooded), false (dry), or
-- nil (not known yet: a fill is queued from here).
local function cave_wet(name, b, px, py, pz, sea)
  if flood.body ~= name then flood.cells, flood.jobs, flood.n, flood.body = {}, {}, 0, name end
  local i, j, k = fcell(px, py, pz)
  local key = fkey(i, j, k)
  local c = flood.cells[key]
  if c and flood.clock - c.t < FLOOD_KEEP then return c.wet end
  if not flood.jobs[key] then
    local n = 0
    for _ in pairs(flood.jobs) do n = n + 1 end
    if n < 4 then
      flood.jobs[key] = { body = name, sea = sea, queue = { { i, j, k } }, head = 1,
        seen = { [key] = true }, list = { key }, wet = false }
    end
  end
  return nil
end

-- One slice of every fill under way. A cell is passable when the field at its
-- centre is no deeper than a fifth of a cell into rock (a passage about a
-- metre wide gets through; a two-metre roof does not leak) and its centre is
-- below the sea's level; a fill that reaches a
-- passable cell whose column is open to open sea floods the cave.
local function flood_step(budget)
  local b = flood.body and space.body(flood.body)
  if not b then flood.jobs = {} return end
  for key, J in pairs(flood.jobs) do
    if budget <= 0 then return end
    local sea = J.sea
    while J.head <= #J.queue and budget > 0 and not J.done do
      local c = J.queue[J.head]
      J.head = J.head + 1
      local px, py, pz = c[1] * FLOOD_CELL, c[2] * FLOOD_CELL, c[3] * FLOOD_CELL
      -- Open to the sea from here? (Cheap first: a cell well clear of rock.)
      local r = len(px, py, pz)
      local col = columnOpen(b.x, b.y, b.z, px, py, pz, sea)
      budget = budget - 4
      if col then
        -- Open to the sky under the sea's radius: sea only where the sea
        -- reaches (reach_query); a flood still running there is waited for.
        local so, state = reach_query(flood.body, b, sea, px / r, py / r, pz / r)
        budget = budget - 8
        if state == "pending" then J.head = J.head - 1 break end
        if so ~= false then J.wet, J.done = true, true end
      end
      if not J.done then
        local N6 = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }
        for _, d in ipairs(N6) do
          local ni, nj, nk = c[1] + d[1], c[2] + d[2], c[3] + d[3]
          local nkey = fkey(ni, nj, nk)
          if not J.seen[nkey] then
            J.seen[nkey] = true
            local qx, qy, qz = ni * FLOOD_CELL, nj * FLOOD_CELL, nk * FLOOD_CELL
            if len(qx, qy, qz) < sea - 0.3 then
              local q = terrain.query(b.x + qx, b.y + qy, b.z + qz)
              budget = budget - 1
              if q and q > -FLOOD_CELL * 0.2 then
                J.queue[#J.queue + 1] = { ni, nj, nk }
                J.list[#J.list + 1] = nkey
              end
            end
          end
        end
        if #J.list >= FLOOD_MAX then J.done = true end
      end
    end
    if J.done or J.head > #J.queue then
      -- A fill over ground still streaming in read a field that is about to
      -- change: its answer is kept for a moment, not FLOOD_KEEP.
      local t_mark = flood.clock
      if not J.wet and terrain.busy and terrain.busy() then t_mark = flood.clock - FLOOD_KEEP + FLOOD_KEEP_BUSY end
      for _, k2 in ipairs(J.list) do flood.cells[k2] = { wet = J.wet, t = t_mark } end
      flood.n = flood.n + 1
      flood.jobs[key] = nil
      floodStats = { cells = #J.list, wet = J.wet, at = key }
    end
  end
end
floodStats = nil

-- Published for the probes: how many cave fills have finished.
function floodCount() return flood.n end

-- WET HOLD. The roof and cave reads come off the terrain field, and ground
-- that is still streaming in answers for a second or two as something else
-- (a freshly streamed sea floor read as a roofed column, then as a cave not
-- looked at yet): a diver read -1, "dry", and the suit tank refilled. So a
-- point that was just read wet stays wet through a dry read from the roof or
-- cave rule for WET_HOLD s (WET_HOLD_BUSY while the terrain worker is
-- streaming), as long as the read is within WET_NEAR m of the wet one. Being
-- above the sea's radius is never held, and a dry cave still reads dry once
-- the hold is over: a swimmer coming into one keeps the water a moment longer.
local wet_seen = {}   -- { body, x, y, z (body-relative), t } — the recent wet reads
local function wet_note(name, px, py, pz)
  local now = flood.clock
  local slot, oldest
  for i, w in ipairs(wet_seen) do
    if w.body == name and len(w.x - px, w.y - py, w.z - pz) < WET_NEAR then slot = i break end
    if not oldest or w.t < wet_seen[oldest].t then oldest = i end
  end
  if not slot then slot = (#wet_seen < 8) and (#wet_seen + 1) or oldest end
  wet_seen[slot] = { body = name, x = px, y = py, z = pz, t = now }
end
local function wet_held(name, px, py, pz)
  local hold = (terrain.busy and terrain.busy()) and WET_HOLD_BUSY or WET_HOLD
  for _, w in ipairs(wet_seen) do
    if w.body == name and flood.clock - w.t <= hold and len(w.x - px, w.y - py, w.z - pz) < WET_NEAR then
      return true
    end
  end
  return false
end
wetHolds = 0   -- (probes) how many dry reads a hold has turned back to wet

-- How deep below the surface of the sea, in metres. Negative = above it (or
-- in a dry cave: -1); nil when this body has no sea (or there's no body).
function seaDepth(x, y, z)
  local d = space.dominant(x, y, z)
  if not d then return nil end
  local sea = seaRadius(d)
  local b = space.body(d)
  if not b then return nil end
  local depth = (sea > 0) and (sea - len(x - b.x, y - b.y, z - b.z)) or nil
  if depth and depth > 0 and terrain and terrain.query then
    local px, py, pz = x - b.x, y - b.y, z - b.z
    local r = len(px, py, pz)
    local col = columnOpen(b.x, b.y, b.z, px, py, pz, sea)
    local wet = depth
    if col == false then
      -- Roofed: a cave. Wet only if it is a flooded one.
      if cave_wet(d, b, px, py, pz, sea) ~= true then depth = -1 end
    elseif col == true then
      -- Under the open sky: sea only where the sea reaches this surface
      -- (reach_query). While its flood runs the point is dry; where the field
      -- is cold the old ring test stands in.
      local so, state = reach_query(d, b, sea, px / r, py / r, pz / r)
      if so == false then depth = -1 end
    else
      -- The field is not answering here (ground streaming in): no roof
      -- test, no flood. The surface cell's last answer stands, else dry —
      -- never "under the sea's radius, so sea" (that flipped a pit wet
      -- whenever its chunk was cold).
      local so = reach_query(d, b, sea, px / r, py / r, pz / r)
      if so ~= true then depth = -1 end
    end
    if depth > 0 then
      wet_note(d, px, py, pz)
    elseif wet_held(d, px, py, pz) then
      depth = wet
      wetHolds = wetHolds + 1
    end
  end
  -- A lake (scale 3) is water too, wherever one is standing near you.
  if not depth or depth <= 0 then
    local ld = lakeDepth(d, x, y, z)
    if ld then return ld end
    -- …and a river: shallow running water you wade (riverAt, below)
    local rd = riverAt(d, x, y, z)
    if rd and rd > 0 then return rd end
  end
  return depth
end

function isUnderwater(x, y, z)
  local d = seaDepth(x, y, z)
  return d ~= nil and d > 0
end

-- The outward normal of the water surface here — "up" for anything floating.
function upAt(x, y, z, name)
  local d = name or space.dominant(x, y, z)
  local b = d and space.body(d)
  if not b then return 0, 1, 0 end
  local dx, dy, dz = x - b.x, y - b.y, z - b.z
  local l = len(dx, dy, dz)
  if l < 1e-6 then return 0, 1, 0 end
  return dx / l, dy / l, dz / l
end

-- A one-line survey of where someone is standing — the HUD's location readout.
function surveyLine(x, y, z)
  local d = space.dominant(x, y, z)
  if not d then return nil end
  local s = sampleAt(d, x, y, z)
  if not s then return d end
  local depth = seaDepth(x, y, z)
  if depth and depth > 0 then
    return string.format("%s · %s · %.0f m down", d, s.label, depth)
  end
  return string.format("%s · %s · %.0f°C", d, s.label, -40 + s.temp * 90)
end

-- ── rivers and lakes (world scale 3) ────────────────────────────────────────
--
-- A scale-3 world carves rivers down valleys and fills its basins to their
-- spill heights (engine cards 0416/0417; system_generator `hydroOf`). The
-- engine does not draw that water yet, so this does: LAKE SURFACES at each
-- lake's level and RIVER RIBBONS along the carved beds, both wearing the sea's
-- own shader (shaders/ocean.flsl reads its "up" from the object position, so a
-- mesh made in the planet's own frame, under the body, is lit and waved like
-- the sea), built only near the eye and given back when it leaves.
--
-- A lake's surface is found against the REAL ground: a lattice on the sphere
-- of radius + level around the lake, flood-filled out from the lake through
-- points that are open air at the water's height and have ground within the
-- lake's depth below them (so the water never spills down the far side of its
-- own spill point), plus one ring of shore that tucks under the terrain.
-- `lakeDepth` reads the same lattice, so the swimmer, the flora and the HUD
-- agree with what is drawn, and the engine's water volumes for it (buoyancy,
-- swimming, a river's current) are laid over the same lattice cells.

-- The water of a lake, by the world's type when it has no sea of its own.
local FRESH = {
  default = { deep = { 0.03, 0.14, 0.22 }, shallow = { 0.12, 0.46, 0.50 }, clarity = 3.0 },
  verdant = { deep = { 0.03, 0.12, 0.08 }, shallow = { 0.22, 0.42, 0.24 }, clarity = 2.0 },
  tundra  = { deep = { 0.06, 0.05, 0.03 }, shallow = { 0.34, 0.26, 0.14 }, clarity = 1.6 },
  alpine  = { deep = { 0.04, 0.22, 0.30 }, shallow = { 0.30, 0.66, 0.70 }, clarity = 3.5 },
  glacial = { deep = { 0.05, 0.25, 0.33 }, shallow = { 0.35, 0.70, 0.72 }, clarity = 2.0 },
  steppe  = { deep = { 0.05, 0.12, 0.14 }, shallow = { 0.30, 0.45, 0.38 }, clarity = 1.8 },
  titan   = { deep = { 0.05, 0.03, 0.01 }, shallow = { 0.30, 0.20, 0.08 }, clarity = 9.0 },
}

local LAKE_NEAR = 700       -- build a lake when the eye is this close to its shore (m)
local LAKE_FAR = 1100       -- …and give it back past this
local RIVER_NEAR = 600      -- river ribbons within this of the eye
local MAX_LAKE_N = 96       -- lattice points across a lake

-- The engine's water (water.addVolume, 0.117 rc3): captured here, before the
-- local `water` below (this script's own bookkeeping) shadows the name.
local engine_water = water
-- Lakes and river stretches built near the eye are declared to the engine as
-- real water (card 0417 a), so they float things, let the crew swim and carry
-- what floats down the current. Each is a set of "lake" discs on the sphere
-- of its own surface, each as wide as the bit of water it stands for: the
-- engine's lake is a disc out to its farthest shore, which past a spill point
-- would stand over the lower ground beyond it, and its heightfield is flat
-- in its node's frame, so its "up" leans off the radial by a degree per
-- radius/57 metres — a floating crate is pushed sideways by that lean.
--
-- OFF for now (engine 0.117 rc3): the engine poses declared water once a
-- frame, before the 60 Hz ticks that move the planet on its rails, so on an
-- orbiting world the water the physics floats things in is (ticks this frame
-- × the planet's step) away from the water drawn — measured on Rymiru
-- (280 m/s): a 20 kg crate dropped on a lake rose to 13 m above it, and one
-- dropped in a river sank to its bed. Declared near a shore that would lift
-- the crew off the bank. Turn it on when the engine carries declared water
-- per tick; everything else here is ready (and was verified: a crate rides a
-- river's current at 0.80 m/s of 0.93 within 6 s where the lag happened to
-- miss it).
local VOLUMES = false
local water = { body = nil, lakes = {}, rivers = {}, hydro = nil, t = 0,
  stats = { rows = 0, knot = 0, nog = 0, under = 0, turn = 0, drop = 0, short = 0 } }
local gen_ref
local eye_x, eye_y, eye_z = nil, nil, nil

-- BUILDING A LAKE OR A RIVER IS A JOB, resumed once a frame for BUILD_MS of
-- wall time: a lake's lattice is a few thousand field reads and a river's
-- first piece walks its whole bed (river_tau), and built in one go they were
-- 50–230 ms frames (rc7, scale-3 worlds). `slice(b)` is called in the hot
-- loops; it yields only inside the build job's own coroutine, and refreshes
-- the body's position after a yield (the planet moves on its rails between
-- frames, and every read is at b + a body-relative point).
local BUILD_MS = 2.0
local build_co, build_t0, build_n = nil, 0, 0
local function wall() return (app and app.wallClock and app.wallClock()) or (os and os.clock and os.clock()) or 0 end
local function slice(b)
  if build_co == nil or coroutine.running() ~= build_co then return end
  build_n = build_n + 1
  if build_n % 8 ~= 0 then return end
  if (wall() - build_t0) * 1000 < BUILD_MS then return end
  coroutine.yield()
  build_t0 = wall()
  local nb = water.body and space.body(water.body)
  if nb and b then b.x, b.y, b.z = nb.x, nb.y, nb.z end
end

-- A probe or the map can say where the eye is (nil hands it back).
function setEye(x, y, z)
  if x then eye_x, eye_y, eye_z = x, y, z else eye_x = nil end
end

local function eye()
  if eye_x then return eye_x, eye_y, eye_z end
  local pc = findScript and findScript("planet_camera")
  if pc and (pc.cam_x ~= 0 or pc.cam_y ~= 0 or pc.cam_z ~= 0) then return pc.cam_x, pc.cam_y, pc.cam_z end
  local a = find and find("Astronaut")
  if a then return a.x, a.y, a.z end
  return nil
end

-- The rivers and lakes of a world: { rivers = {...}, lakes = {...} } (see
-- system_generator `hydroOf`), or nil on a world without them. May take
-- seconds the first time a save asks about a world.
function hydroOf(name)
  if not name then return nil end
  if not (gen_ref and gen_ref.valid) then gen_ref = findScript and findScript("system_generator") end
  if gen_ref and gen_ref.hydroOf then return gen_ref.hydroOf(name) end
  return save.get("hydro." .. name)
end

-- How far (m, along the ground, roughly) the nearest river is from a WORLD
-- point on body `name`, and that river's width there; nil without rivers.
function riverDistance(name, x, y, z)
  local h = hydroOf(name)
  local b = name and space.body(name)
  if not (h and b) then return nil end
  local px, py, pz = x - b.x, y - b.y, z - b.z
  local r = len(px, py, pz)
  if r < 1 then return nil end
  local best, bw = nil, nil
  for _, rv in ipairs(h.rivers or {}) do
    if rv.river then
      local p = rv.points
      local s = r / ((rv.points[1] and len(p[1], p[2], p[3])) or r)
      for i = 1, #p / 3 - 1 do
        local ax, ay, az = p[i * 3 - 2] * s, p[i * 3 - 1] * s, p[i * 3] * s
        local bx, by, bz = p[i * 3 + 1] * s, p[i * 3 + 2] * s, p[i * 3 + 3] * s
        local ex, ey, ez = bx - ax, by - ay, bz - az
        local ee = ex * ex + ey * ey + ez * ez
        local t = ee > 0 and math.max(0, math.min(1, ((px - ax) * ex + (py - ay) * ey + (pz - az) * ez) / ee)) or 0
        local d = len(px - ax - ex * t, py - ay - ey * t, pz - az - ez * t)
        if not best or d < best then best, bw = d, rv.widths[i] end
      end
    end
  end
  return best, bw
end

-- The water near a BODY-RELATIVE point, for something that samples many
-- points close together (flora_field, once per patch): the river segments and
-- lakes within `reach` metres, as a list `wetness` reads. Cheap to keep: a
-- few dozen entries. nil when the world has no rivers or lakes.
function wetNear(name, rx, ry, rz, reach)
  local h = hydroOf(name)
  local w = worldOf(name)
  if not (h and w) then return nil end
  local R = w.radius or 100
  local out = { segs = {}, lakes = {} }
  local r = len(rx, ry, rz)
  if r < 1 then return nil end
  local ux, uy, uz = rx / r, ry / r, rz / r
  local cosr = math.cos((reach + 40) / R)
  for _, rv in ipairs(h.rivers or {}) do
    if rv.river then
      local p = rv.points
      for i = 1, #p / 3 - 1 do
        local ax, ay, az = p[i * 3 - 2], p[i * 3 - 1], p[i * 3]
        local al = len(ax, ay, az)
        if (ax * ux + ay * uy + az * uz) / al > cosr then
          local bx, by, bz = p[i * 3 + 1], p[i * 3 + 2], p[i * 3 + 3]
          local bl = len(bx, by, bz)
          -- On the unit sphere × R: ground height does not matter here.
          out.segs[#out.segs + 1] = { ax / al * R, ay / al * R, az / al * R, bx / bl * R, by / bl * R, bz / bl * R,
            (rv.widths[i] or 8) * 0.35 }
        end
      end
    end
  end
  for _, L in ipairs(h.lakes or {}) do
    local ll = len(L.x, L.y, L.z)
    local c = (L.x * ux + L.y * uy + L.z * uz) / ll
    if c > math.cos((reach + L.reach + 40) / R) then
      out.lakes[#out.lakes + 1] = { L.x / ll * R, L.y / ll * R, L.z / ll * R, L.reach, R + L.level }
    end
  end
  if #out.segs == 0 and #out.lakes == 0 then return nil end
  return out
end

-- How wet the ground is at a BODY-RELATIVE point (`g` its ground radius) from
-- a `wetNear` list: 1 on a riverbank or lake shore, falling to 0 by `band`
-- metres from the water; and whether the point is under a lake's water.
-- → wet (0..1), inLake (bool)
function wetness(list, x, y, z, g, band)
  if not list then return 0, false end
  band = band or 26
  local R = nil
  local l = len(x, y, z)
  local best = 1e9
  for _, sg in ipairs(list.segs) do
    R = R or len(sg[1], sg[2], sg[3])
    local px, py, pz = x / l * R, y / l * R, z / l * R
    local ex, ey, ez = sg[4] - sg[1], sg[5] - sg[2], sg[6] - sg[3]
    local ee = ex * ex + ey * ey + ez * ez
    local t = ee > 0 and math.max(0, math.min(1, ((px - sg[1]) * ex + (py - sg[2]) * ey + (pz - sg[3]) * ez) / ee)) or 0
    local d = len(px - sg[1] - ex * t, py - sg[2] - ey * t, pz - sg[3] - ez * t) - sg[7]
    if d < best then best = d end
  end
  local in_lake = false
  for _, L in ipairs(list.lakes) do
    local Rr = len(L[1], L[2], L[3])
    local d = len(x / l * Rr - L[1], y / l * Rr - L[2], z / l * Rr - L[3])
    if d < L[4] * 1.3 + band then
      -- Within the basin's reach: below the water's level is lake, a little
      -- above it is the shore.
      local above = (g or l) - L[5]
      if above < -0.3 and d < L[4] then in_lake = true end
      local sd = math.max(above, 0) * 4 + math.max(0, d - L[4] * 1.1)
      if sd < best then best = sd end
    end
  end
  if best >= band then return 0, in_lake end
  local k = 1 - math.max(0, best) / band
  return k * k * (3 - 2 * k), in_lake
end

-- The radius of the highest standing water over planet-local unit direction
-- (dx,dy,dz) whose ground is at radius `g`: the sea's, or a lake's whose basin
-- holds this point by the same test the lake surface is flood-filled with
-- (within the lake's lattice, ground under the water and no deeper than its
-- depth + 4 m below it) — without the connectivity, so it errs wet. nil when
-- no water stands there. For siting (a colony must not be put down in a lake
-- that is not built yet: game_manager's dry_site).
function waterLevelAt(name, dx, dy, dz, g)
  local w = worldOf(name)
  if not w then return nil end
  local level = ((w.sea or 0) > 0 and g < w.sea) and w.sea or nil
  local h = w.hydro and hydroOf(name)
  if not h then return level end
  local R = w.radius or 100
  for _, L in ipairs(h.lakes or {}) do
    local Rl = R + L.level
    if g < Rl and g > Rl - (L.depth or 4) - 4 then
      local ll = len(L.x, L.y, L.z)
      local c = (L.x * dx + L.y * dy + L.z * dz) / ll
      local arc = math.acos(math.max(-1, math.min(1, c))) * Rl
      if arc < L.reach * 1.15 + 6 and (not level or Rl > level) then level = Rl end
    end
  end
  -- The pools found on this world (pits that seeped full, cave sumps).
  if name == water.body then
    for _, p in pairs(water.pools or {}) do
      local Rp = R + (p.target or p.level)
      if g < Rp and g > Rp - (p.depth or 2) - 3 then
        local ll = len(p.x, p.y, p.z)
        local c = (p.x * dx + p.y * dy + p.z * dz) / ll
        local arc = math.acos(math.max(-1, math.min(1, c))) * Rp
        if arc < p.reach * 1.15 + 3 and (not level or Rp > level) then level = Rp end
      end
    end
  end
  return level
end

-- A tangent basis at unit direction (ux,uy,uz).
local function basis(ux, uy, uz)
  local ax, ay, az = 0, 1, 0
  if math.abs(uy) > 0.9 then ax, ay, az = 1, 0, 0 end
  local t1x, t1y, t1z = uy * az - uz * ay, uz * ax - ux * az, ux * ay - uy * ax
  local l = len(t1x, t1y, t1z)
  t1x, t1y, t1z = t1x / l, t1y / l, t1z / l
  return t1x, t1y, t1z, uy * t1z - uz * t1y, uz * t1x - ux * t1z, ux * t1y - uy * t1x
end

-- The water a lake or river is made of. A world whose sea is liquid lends its
-- lakes the sea's chemistry; a frozen sea's world (its fresh water still runs
-- in the rivers and stands in the sheltered basins) and a world with no sea
-- take the fresh water of their type; a cold world's is glacial.
local function water_look(w)
  local wt = w and w.water
  if wt and wt.deep and wt.state ~= "ice" then return wt end
  local ty = w and w.geo and w.geo.type
  if FRESH[ty] then return FRESH[ty] end
  if (wt and wt.state == "ice") or (w and w.climTemp and w.climTemp < 0.3) then return FRESH.glacial end
  return FRESH.default
end

-- How much light the water column sends back, by its colour. Clear blue and
-- green water is lit as it is; warm-coloured water (tannin, iron, a
-- hydrocarbon sea) is dark stuff whose "shallow" tint, lit at full sun, read
-- as a sheet of sand. Hydrocarbon is darkest of all.
function waterLight(wt)
  if not (wt and wt.shallow) then return 1.0 end
  if wt.state == "methane" then return 0.42 end
  local r, g, b = wt.shallow[1], wt.shallow[2], wt.shallow[3]
  if r > b * 1.4 then return 0.6 end
  return 1.0
end

-- Absorption per metre, per channel (ocean.flsl / river.flsl Beer–Lambert),
-- from the water's chemistry: its "shallow" tint is what a bed looks like
-- through about a clarity-length of it, so a channel the tint holds little of
-- is one the water eats fast. Clear ocean comes out near (0.5, 0.07, 0.05)/m
-- (red gone in a couple of metres, blue carrying on: turquoise, then navy);
-- tannin water eats blue first (amber), methane hardly anything (dark
-- because what it scatters back is dark).
function waterAbsorb(wt)
  local sh = wt and wt.shallow or { 0.12, 0.46, 0.5 }
  local cl = math.max(0.5, wt and wt.clarity or 3)
  local function k(c) return (-math.log(math.max(0.03, math.min(0.95, c * 1.6))) + 0.05) / cl end
  return k(sh[1]), k(sh[2]), k(sh[3])
end

-- The sky as water reflects it: the horizon and the zenith of the air the
-- engine draws (atmosphere.lua re-saturates the rolled colour; the engine
-- draws the horizon at 1.12× it with a fifth of white and the zenith at about
-- 0.6×). Thin air reflects a darker sky; none reflects space.
-- → hr, hg, hb, zr, zg, zb
function waterSky(w)
  local atmo = w and w.atmo or 0
  if atmo <= 0.01 then return 0.02, 0.025, 0.035, 0.01, 0.012, 0.02 end
  local r, g, b = w.atmoR or 0.55, w.atmoG or 0.68, w.atmoB or 0.92
  local at = findScript and findScript("atmosphere")
  if at and at.skyAir then r, g, b = at.skyAir(r, g, b, atmo) end
  local k = math.min(1, atmo * 1.6)
  local hr, hg, hb = (r + (1 - r) * 0.22) * 1.12, (g + (1 - g) * 0.22) * 1.12, (b + (1 - b) * 0.22) * 1.12
  return 0.03 + hr * k, 0.035 + hg * k, 0.05 + hb * k, 0.015 + r * 0.6 * k, 0.02 + g * 0.6 * k, 0.03 + b * 0.6 * k
end

local function dress(n, w, kind, ux, uy, uz)
  -- The material and the shader come from the prefab the sheet is spawned
  -- from (WaterSheet / RiverSheet): a node made with createNode and given a
  -- model has no Material of its own, setMaterial puts no shader on, and
  -- the handle write `node:material().shader = …` read back false — every
  -- lake and river drew in the default material (the water pass, 11-12).
  pcall(function() n.castShadow = false end)
end
-- The shader's parameters, pushed the tick AFTER the node is made: a
-- material set from a script lands at the pass's flush, so a setShaderParam
-- in the same callback found "no Material" and every lake and river wore the
-- shader's defaults (hundreds of warnings a run, said once per parameter).
-- `update` calls this for every sheet marked `undressed`.
local function dress_params(n, w, kind, ux, uy, uz)
  local river = kind == "river"
  local atmo = w and w.atmo or 0
  local hr, hg, hb, zr, zg, zb = waterSky(w)
  n:setShaderParam("skyColor", hr, hg, hb, 1)
  n:setShaderParam("zenithColor", zr, zg, zb, 1)
  local wt = water_look(w)
  n:setShaderParam("deepColor", wt.deep[1], wt.deep[2], wt.deep[3], 1)
  n:setShaderParam("shallowColor", wt.shallow[1], wt.shallow[2], wt.shallow[3], 1)
  n:setShaderParam("bodyLight", waterLight(wt))
  local ar, ag, ab = waterAbsorb(wt)
  n:setShaderParam("absorb", ar, ag, ab)
  -- Hydrocarbon lakes are famously still (Titan's are mirror-flat).
  local calm = (wt.state == "methane" or (w.geo and w.geo.type == "titan")) and 0.18 or 1
  if river then
    -- A river is shallow and stirred: it reads clearer than the lake it
    -- feeds, and it runs faster down a steeper world.
    n:setShaderParam("bump", (0.14 + 0.12 * math.min(1, atmo)) * (0.5 + 0.5 * calm))
    -- uv.y is travel time (river_tau), so 1 is the water's real speed.
    n:setShaderParam("flowSpeed", 1.0)
  else
    -- A lake is sheltered: gentle ripples, finer than the sea's swell.
    n:setShaderParam("bump", (0.08 + 0.12 * math.min(1, atmo)) * calm)
    n:setShaderParam("waveScale", 0.55)
    n:setShaderParam("waveSpeed", 0.22)
    n:setShaderParam("surfDepth", 0.25)
    -- The swell's frame (ocean.flsl: a plane wave within ~30° of capDir is a
    -- wave on the sphere): the lake's own centre. Its size follows the wind
    -- (update, lake_waves) with a lake's short fetch.
    if ux then
      n:setShaderParam("capDir", ux, uy, uz)
      -- the swell's fixed direction (ocean.flsl swellDir): a tangent at the
      -- lake's centre, never the live wind
      local t1x, t1y, t1z = tangent_basis(ux, uy, uz)
      n:setShaderParam("swellDir", t1x, t1y, t1z)
    end
    n:setShaderParam("waveAmp", 0.04 * calm)
    n:setShaderParam("waveLen", 3.0)
    local bn = space and space.body and space.body(water.body)
    if bn and bn.mu and w.radius then n:setShaderParam("gAccel", bn.mu / (w.radius * w.radius)) end
  end
end

-- The swell on a lake from the wind: ocean.lua's spectrum (JONSWAP,
-- fetch-limited) with a lake's 300 m fetch. → amplitude, wavelength.
local function lake_waves(U, g)
  U = math.max(U or 0, 0.8)
  g = math.max(g or 9.81, 0.1)
  local x = g * 300 / (U * U)
  local Hs = 1.6e-3 * math.sqrt(x) * U * U / g
  local Tp = 0.286 * x ^ (1 / 3) * U / g
  return math.min(0.5, Hs * 0.5 * 0.8), math.max(1.2, math.min(20, g * Tp * Tp / 6.2832))
end

-- The ground radius under planet-local unit direction d, marched down the
-- distance field from above the peaks (as game_manager's spawn search does: a
-- true distance never steps through ground, and never stops on a cave roof).
-- nil when the field is cold.
local function ground_r(b, dx, dy, dz, top, bottom)
  local r = top
  for _ = 1, 200 do
    slice(b)
    local q = terrain.query(b.x + dx * r, b.y + dy * r, b.z + dz * r)
    if not q then return nil end
    if q < 0.12 then return r - math.max(q, 0) end
    r = r - math.max(q * 0.9, 0.08)
    if r < bottom then return nil end
  end
  return r
end

-- One lake: the lattice, flood-filled from the lake against the real ground.
local function build_lake(b, w, L)
  -- (the four neighbours, made once: building them per cell was 40k tables a lake)
  local DIRS4 = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
  local R = w.radius
  local Rl = R + L.level
  local cx, cy, cz = L.x, L.y, L.z
  local cl = len(cx, cy, cz)
  local ux, uy, uz = cx / cl, cy / cl, cz / cl
  local t1x, t1y, t1z, t2x, t2y, t2z = basis(ux, uy, uz)
  local half = L.reach * 1.4 + 10
  local s = math.max(1.5, half * 2 / MAX_LAKE_N)
  local N = math.floor(half * 2 / s) + 1
  local off = (N - 1) * 0.5
  local floor_r = Rl - (L.depth or 4) - 4
  local function dir(i, j)
    local a, c = (i - off) * s / Rl, (j - off) * s / Rl
    local x, y, z = ux + t1x * a + t2x * c, uy + t1y * a + t2y * c, uz + t1z * a + t2z * c
    local l = len(x, y, z)
    return x / l, y / l, z / l
  end
  -- 1 = water, 2 = shore ring, 0 = not this lake.
  --
  -- A point is water when it is open air at the water's height and the
  -- ground under it is no deeper than the lake's depth + 4 m (deeper ground
  -- outside the basin is the far side of the spill point). Inside the lake's
  -- own reach a deeper hole is still the lake (the published depth is a
  -- coarse grid's), and a point whose terrain is not answering yet (a chunk
  -- still streaming) is taken as water there, so the surface is never cut
  -- into grid-cell holes; the lake is rebuilt once the ground has settled.
  -- (Both used to fail the test: rectangular holes through the surface onto
  -- the bed, in the deep middles and over unstreamed chunks.)
  local state, open, open_qa = {}, {}, {}
  local unknown = 0
  local function key(i, j) return j * N + i end
  local reach2 = L.reach * L.reach
  local function is_water(i, j)
    local k = key(i, j)
    if open[k] == nil then
      slice(b)
      local dx, dy, dz = dir(i, j)
      local qa = terrain.query(b.x + dx * Rl, b.y + dy * Rl, b.z + dz * Rl)
      local qb = terrain.query(b.x + dx * floor_r, b.y + dy * floor_r, b.z + dz * floor_r)
      local ri, rj = (i - off) * s, (j - off) * s
      local d2 = ri * ri + rj * rj
      if d2 > half * half then open[k] = false
      elseif qa == nil or qb == nil then
        open[k] = d2 <= reach2
        if open[k] then unknown = unknown + 1 end
      else
        -- Past the reach, ground a little deeper than the floor test is still
        -- this lake's (the published depth is coarse): only a drop of 12 m
        -- past the floor reads as the far side of the spill point.
        local ok = qb < 0 or d2 <= reach2
        if not ok and qa > 0.05 then
          local deep_r = floor_r - 12
          local qc = terrain.query(b.x + dx * deep_r, b.y + dy * deep_r, b.z + dz * deep_r)
          ok = qc ~= nil and qc < 0
        end
        open[k] = qa > 0.05 and ok
      end
      open_qa[k] = qa
    end
    return open[k]
  end
  -- Seed: the water point nearest the lake's centre (a crescent's centroid
  -- can be on land).
  local si, sj = nil, nil
  local c0 = math.floor(off + 0.5)
  for rr = 0, math.floor(N / 2) do
    for i = c0 - rr, c0 + rr do
      for j = c0 - rr, c0 + rr do
        if not si and i >= 0 and j >= 0 and i < N and j < N
          and (math.abs(i - c0) == rr or math.abs(j - c0) == rr) and is_water(i, j) then si, sj = i, j end
      end
    end
    if si then break end
  end
  if not si then return nil end
  local stack, nwet = { { si, sj } }, 0
  state[key(si, sj)] = 1
  while #stack > 0 do
    slice(b)
    local p = table.remove(stack)
    nwet = nwet + 1
    for _, d in ipairs(DIRS4) do
      local i, j = p[1] + d[1], p[2] + d[2]
      if i >= 0 and j >= 0 and i < N and j < N and not state[key(i, j)] then
        if is_water(i, j) then
          state[key(i, j)] = 1
          stack[#stack + 1] = { i, j }
        else
          state[key(i, j)] = 2
        end
      end
    end
  end
  if nwet < 4 then return nil end
  -- Fill: a point the fill could not confirm, with water on three or four
  -- sides and no ground at the water's height (an unknown or a deep spot,
  -- not an island), is water too. Two passes close the pinholes.
  for _ = 1, 2 do
    local add = {}
    for j = 1, N - 2 do
      slice(b)
      for i = 1, N - 2 do
        local k = key(i, j)
        if state[k] ~= 1 then
          local qa = open_qa[k]
          if qa == nil or qa > 0 then
            local wn = 0
            for _, d in ipairs(DIRS4) do
              if state[key(i + d[1], j + d[2])] == 1 then wn = wn + 1 end
            end
            if wn >= 3 then add[#add + 1] = k end
          end
        end
      end
    end
    for _, k in ipairs(add) do state[k] = 1; nwet = nwet + 1 end
    -- Every neighbour of water is at least shore, so the mesh closes round it.
    for _, k in ipairs(add) do
      local i, j = k % N, math.floor(k / N)
      for _, d in ipairs(DIRS4) do
        local kk = key(i + d[1], j + d[2])
        if not state[kk] then state[kk] = 2 end
      end
    end
  end
  -- The shore ring's directions (every third cell, 400 at most): the lapping
  -- sound (ambient_tick) finds the nearest to the eye.
  local shore, sk = {}, 0
  for k, st in pairs(state) do
    if st == 2 then
      sk = sk + 1
      if sk % 3 == 0 and #shore < 400 then
        local sx2, sy2, sz2 = dir(k % N, math.floor(k / N))
        shore[#shore + 1] = { sx2, sy2, sz2 }
      end
    end
  end
  -- The mesh: every lattice cell with a water corner and no corner outside.
  local pos, idx, vid, uvs = {}, {}, {}, {}
  local function vert(i, j)
    local k = key(i, j)
    if vid[k] then return vid[k] end
    local dx, dy, dz = dir(i, j)
    local r = Rl - 0.12
    pos[#pos + 1], pos[#pos + 2], pos[#pos + 3] = dx * r, dy * r, dz * r
    -- uv = (edge, 7): ocean.flsl fades a lake toward 0. A ring vertex over
    -- open air at the water's height (the lattice's limit, not a bank) is
    -- the only place the mesh could end in a straight line over water.
    local qa = open_qa[k]
    local fade = (state[k] ~= 1 and (qa == nil or qa > 0.3)) and 0 or 1
    uvs[#uvs + 1], uvs[#uvs + 2] = fade, 7
    vid[k] = #pos / 3
    return vid[k]
  end
  for j = 0, N - 2 do
    slice(b)
    for i = 0, N - 2 do
      local a, b2, c, d = state[key(i, j)], state[key(i + 1, j)], state[key(i, j + 1)], state[key(i + 1, j + 1)]
      if a and b2 and c and d and (a == 1 or b2 == 1 or c == 1 or d == 1) then
        local v00, v10, v01, v11 = vert(i, j), vert(i + 1, j), vert(i, j + 1), vert(i + 1, j + 1)
        -- Counter-clockwise seen from above (t1 × t2 = up).
        idx[#idx + 1], idx[#idx + 2], idx[#idx + 3] = v00, v10, v11
        idx[#idx + 1], idx[#idx + 2], idx[#idx + 3] = v00, v11, v01
      end
    end
  end
  if #idx == 0 then return nil end
  local ok, name = pcall(mesh.build, { positions = pos, indices = idx, uvs = uvs })
  if not ok then return nil end
  -- The engine's water for it (card 0417 a), on the sphere the mesh is
  -- drawn on. One disc over the whole lake when the disc would hold no air
  -- that is not this lake's (no lower ground past a spill point inside it);
  -- otherwise one disc per block of lattice cells holding water, centred on
  -- them and reaching just past the farthest.
  local vols = {}
  if engine_water and engine_water.addVolume then
    local Rv = Rl - 0.12
    -- `depth`: the lake's bed (engine 0.117 rc6), so a cave under a lake is
    -- dry rather than "under" it. With VOLUMES off the discs are the
    -- underwater LOOK only, like the sea's own volume (no buoyancy, no drag:
    -- the crew swims in planet_walker, craft float in vessel_controller).
    local bed = (L.depth or 4) + 4
    local look = water_look(w)
    local function disc(cx, cy, cz, reach)
      local o = { shape = "lake", parent = water.body,
        center = vec3(cx * Rv, cy * Rv, cz * Rv), radius = Rv, reach = reach, depth = bed }
      if not VOLUMES then
        o.density, o.drag, o.angularDrag = 0.0, 0.0, 0.0   -- 0: look and water.at only, no buoyancy, no warnings (engine rc38)
        local d = look.deep or { 0.04, 0.2, 0.3 }
        o.tint = { math.min(1, d[1] * 1.4 + 0.02), math.min(1, d[2] * 1.4 + 0.02), math.min(1, d[3] * 1.4 + 0.02) }
        o.visibility = 4 + (look.clarity or 3) * 3
      end
      vols[#vols + 1] = o
    end
    local function ang(ax, ay, az, bx, by, bz)
      return math.acos(math.max(-1, math.min(1, ax * bx + ay * by + az * bz)))
    end
    -- The whole lake: centred on its water, out to its farthest water cell.
    local sx, sy, sz, nw = 0, 0, 0, 0
    for k, st in pairs(state) do
      slice(b)
      if st == 1 then
        local dx, dy, dz = dir(k % N, math.floor(k / N))
        sx, sy, sz, nw = sx + dx, sy + dy, sz + dz, nw + 1
      end
    end
    local l = len(sx, sy, sz)
    local cx, cy, cz = sx / l, sy / l, sz / l
    local far = 0
    for k, st in pairs(state) do
      slice(b)
      if st == 1 then
        local dx, dy, dz = dir(k % N, math.floor(k / N))
        far = math.max(far, ang(dx, dy, dz, cx, cy, cz) * Rv)
      end
    end
    local reach = far + s * 0.75
    -- Would that disc stand over air that is not this lake? (every other
    -- lattice point inside it: open at the water's height and not water)
    local leak = false
    for j = 0, N - 1 do
      slice(b)
      for i = 0, N - 1 do
        if not leak and state[key(i, j)] ~= 1 then
          local dx, dy, dz = dir(i, j)
          if ang(dx, dy, dz, cx, cy, cz) * Rv <= reach then
            local qa = open_qa[key(i, j)]
            if qa == nil then slice(b); qa = terrain.query(b.x + dx * Rv, b.y + dy * Rv, b.z + dz * Rv) end
            if qa and qa > 0.05 then leak = true end
          end
        end
      end
    end
    if not leak then
      disc(cx, cy, cz, reach)
    else
      local B = math.max(1, math.ceil(math.max(16, L.reach / 3) / s))
      for bj = 0, N - 1, B do
        for bi = 0, N - 1, B do
          local cells, bx2, by2, bz2 = {}, 0, 0, 0
          for j = bj, math.min(N - 1, bj + B - 1) do
            for i = bi, math.min(N - 1, bi + B - 1) do
              if state[key(i, j)] == 1 then
                local dx, dy, dz = dir(i, j)
                cells[#cells + 1] = { dx, dy, dz }
                bx2, by2, bz2 = bx2 + dx, by2 + dy, bz2 + dz
              end
            end
          end
          slice(b)
          if #cells > 0 then
            local lb = len(bx2, by2, bz2)
            local ux2, uy2, uz2 = bx2 / lb, by2 / lb, bz2 / lb
            local fb = 0
            for _, c in ipairs(cells) do fb = math.max(fb, ang(c[1], c[2], c[3], ux2, uy2, uz2) * Rv) end
            disc(ux2, uy2, uz2, fb + s * 0.75)
          end
        end
      end
    end
  end
  local lake = { mesh = name, node = nil, level = L.level, vspec = vols, vx = ux * Rl, vy = uy * Rl, vz = uz * Rl, shore = shore,
    vr = L.reach * 1.2 + 10, Rl = Rl, ux = ux, uy = uy, uz = uz,
    t1 = { t1x, t1y, t1z }, t2 = { t2x, t2y, t2z }, s = s, N = N, off = off, state = state,
    cx = b.x + ux * Rl, cy = b.y + uy * Rl, cz = b.z + uz * Rl, reach = L.reach, wet = nwet,
    provisional = unknown > 0 or (terrain.busy and terrain.busy()) or false, built_t = water.t_total or 0 }
  -- Local (0,0,0) under the body: the mesh is in the planet's own frame.
  -- (A child's position is a LOCAL offset: set to the body's own position,
  -- every lake stood a body-position away from its world.)
  spawn("WaterSheet", vec3(0, 0, 0), function(n)
    n.name = "Lake"
    -- (spawn's pos is a WORLD point; a child's x/y/z are its LOCAL offset)
    n.x, n.y, n.z = 0, 0, 0
    n.model = name
    n.tags = { "genbody", "lake" }
    dress(n, w, "lake", ux, uy, uz)
    lake.undressed = { "lake", ux, uy, uz }
    lake.node = n
  end, b.node or find(water.body))
  return lake
end

-- ── waterfalls ──────────────────────────────────────────────────────────────
-- Where a river's surface drops FALL_DROP m or more between two rows, a SHEET
-- hangs from the lip to the foot (prefabs/FallSheet, shaders/fallsheet.flsl:
-- uv.x across, uv.y metres below the lip), its shape the free fall's (the
-- water leaves the lip level and drops as t²), a mist fired at the foot
-- every few seconds while the eye is near (vfx/FallMist, through vfx.emit so
-- it rides the planet), and a waterfall loop there (ambient_tick).
FALL_DROP = 1.5
local function fall_params(n, w, f)
  local bn = space and space.body and space.body(water.body)
  local g = (bn and bn.mu and w.radius) and (bn.mu / (w.radius * w.radius)) or 9.81
  n:setShaderParam("drop", f.drop)
  n:setShaderParam("gAccel", g)
  n:setShaderParam("flow", math.min(4, 0.15 + f.half * 0.12 + f.drop * 0.05))
  local hr, hg, hb = waterSky(w)
  n:setShaderParam("skyColor", hr, hg, hb, 1)
end
function build_fall_sheets(b, w, river)
  for _, f in ipairs(river.falls or {}) do
    local tl = len(f.tx, f.ty, f.tz)
    local bl = len(f.bx, f.by, f.bz)
    local lx, ly, lz = f.tx / tl, f.ty / tl, f.tz / tl
    -- the foot: carried on past the lower row by a third of the drop (the
    -- water leaves the lip with its speed and lands in the plunge pool, not
    -- at the foot of the step), so the sheet leans into the pool
    local fx, fy, fz = f.bx / bl, f.by / bl, f.bz / bl
    local hx, hy, hz = fx - lx, fy - ly, fz - lz
    local hl = len(hx, hy, hz)
    if hl > 1e-9 then
      local push = (f.drop * 0.33) / bl
      fx, fy, fz = fx + hx / hl * push, fy + hy / hl * push, fz + hz / hl * push
      local fl2 = len(fx, fy, fz)
      fx, fy, fz = fx / fl2, fy / fl2, fz / fl2
    end
    local pos, uvs, idx = {}, {}, {}
    local N = 10
    local half = f.half * 0.9
    for k = 0, N do
      local t = k / N
      local dx, dy, dz = lx * (1 - t) + fx * t, ly * (1 - t) + fy * t, lz * (1 - t) + fz * t
      local dl = len(dx, dy, dz)
      dx, dy, dz = dx / dl, dy / dl, dz / dl
      local r = f.tr + 0.05 - f.drop * t * t
      if k == N then r = f.br + 0.15 end
      for _, side in ipairs({ 1, 0, -1 }) do
        pos[#pos + 1], pos[#pos + 2], pos[#pos + 3] = dx * r + f.nx * half * side, dy * r + f.ny * half * side, dz * r + f.nz * half * side
        uvs[#uvs + 1], uvs[#uvs + 2] = side, f.drop * t * t
      end
    end
    for k = 0, N - 1 do
      local a = 1 + k * 3
      for c = 0, 1 do
        local a0, a1, b0, b1 = a + c, a + c + 1, a + c + 3, a + c + 4
        idx[#idx + 1], idx[#idx + 2], idx[#idx + 3] = a0, b0, b1
        idx[#idx + 1], idx[#idx + 2], idx[#idx + 3] = a0, b1, a1
        idx[#idx + 1], idx[#idx + 2], idx[#idx + 3] = a0, b1, b0
        idx[#idx + 1], idx[#idx + 2], idx[#idx + 3] = a0, a1, b1
      end
    end
    local ok, name = pcall(mesh.build, { positions = pos, indices = idx, uvs = uvs })
    if ok then
      f.mesh = name
      spawn("FallSheet", vec3(0, 0, 0), function(n)
        n.name = "Fall"
        n.x, n.y, n.z = 0, 0, 0
        n.model = name
        n.tags = { "genbody", "river" }
        pcall(function() n.castShadow = false end)
        f.node = n
        f.undressed = true
      end, b.node or find(water.body))
    end
  end
end

-- ── the water's sounds ──────────────────────────────────────────────────────
-- Spatial loops the eye is near, each placed at a BODY-RELATIVE point and
-- moved to its world point every frame (the planet moves on its rails):
-- the nearest river stretch (stream_loop / brook_loop by its width), each
-- waterfall's foot (waterfall_loop / waterfall_soft_loop by its drop), the
-- nearest lake shore (lap_loop / lap_rocks_loop by the lake's size). The
-- sea's own surf is ocean.lua's. Asked for every half second by
-- ambient_tick; a loop nobody asked for in 1.2 s fades out.
local amb = {}
local function amb_set(name, clip, want, rx, ry, rz, minD, maxD)
  local A = amb[name]
  if not A then A = { v = 0 }; amb[name] = A end
  A.want, A.rx, A.ry, A.rz, A.clip, A.minD, A.maxD, A.t = want, rx, ry, rz, clip, minD, maxD, water.t_total or 0
end
local function amb_frame(dt)
  if not (audio and audio.play) then return end
  local b = water.body and space.body(water.body)
  for name, A in pairs(amb) do
    local want = ((water.t_total or 0) - (A.t or 0) < 1.2) and (A.want or 0) or 0
    A.v = A.v + (want - A.v) * math.min(1, dt * 1.5)
    if A.v > 0.02 and b then
      local wx, wy, wz = b.x + A.rx, b.y + A.ry, b.z + A.rz
      if not A.h then
        A.h = audio.play(A.clip, wx, wy, wz, { loop = true, volume = 0, track = "SFX", mode = "Spatial",
          minDistance = A.minD or 8, maxDistance = A.maxD or 90 })
      end
      if A.h then A.h:setVolume(A.v); A.h:setPosition(wx, wy, wz) end
    elseif A.h then
      A.h:stop()
      A.h = nil
      if A.v <= 0.02 then amb[name] = nil end
    end
  end
end
local function amb_stop_all()
  for name, A in pairs(amb) do if A.h then A.h:stop() end end
  amb = {}
end
ambientStats = { stream = nil, fall = nil, lap = nil, near = nil }

-- ── running water you can stand in ──────────────────────────────────────────
-- A river is WATER, not a picture of it: inside a drawn ribbon, under its
-- surface, a point is that deep in the stream (seaDepth answers it, so the
-- crew wades and splashes), and the stream is moving: `flowAt` is its
-- velocity there (m/s, the planet's frame), downstream at the speed the
-- ripples are drawn (the rows' travel time). planet_walker leans a wader
-- and carries a swimmer on it; anything else that floats can ask the same.
-- The rows near the eye are listed twice a second (ambient_tick).
-- → depth (m, nil when the point is in no river), vx, vy, vz
function riverAt(name, x, y, z)
  local rows = water.near_rows
  if not rows or name ~= water.body then return nil end
  local b = space.body(name)
  if not b then return nil end
  local px, py, pz = x - b.x, y - b.y, z - b.z
  local best, bi = 1e9, nil
  for i, row in ipairs(rows) do
    local d = len(px - row[1], py - row[2], pz - row[3])
    if d < best then best, bi = d, i end
  end
  if not bi then return nil end
  local row = rows[bi]
  local r = len(px, py, pz)
  local depth = row[4] - r
  -- across the stream: the distance from the row's point less the height
  local horiz = math.sqrt(math.max(0, best * best - depth * depth))
  if depth <= 0 or depth > 3 or horiz > row[5] + 0.3 then return nil end
  local nxt = row.nxt
  if not nxt then return depth, 0, 0, 0 end
  local fx, fy, fz = nxt[1] - row[1], nxt[2] - row[2], nxt[3] - row[3]
  local ds, dt = len(fx, fy, fz), nxt[6] - row[6]
  if ds < 1e-6 or dt <= 1e-4 then return depth, 0, 0, 0 end
  local v = math.min(3.2, ds / dt)
  -- slower at the banks than midstream
  v = v * (1 - 0.6 * math.min(1, horiz / math.max(row[5], 0.1)) ^ 2)
  return depth, fx / ds * v, fy / ds * v, fz / ds * v
end
-- The water's velocity at a WORLD point (m/s, planet frame): a river's
-- current, zero in still water and in air.
function flowAt(x, y, z)
  local d = space.dominant(x, y, z)
  if not d then return 0, 0, 0 end
  local depth, vx, vy, vz = riverAt(d, x, y, z)
  if not depth then return 0, 0, 0 end
  return vx, vy, vz
end

-- How far the eye is from the nearest standing water it is not in (m): the
-- nearest lake or pool shore, river stretch or sea shore found this tick;
-- nil when none is near. soundscape.lua's rain on water.
function waterNearEye() return water.near_dist end

local function ambient_tick(name, w, b, ex, ey, ez)
  local rx, ry, rz = ex - b.x, ey - b.y, ez - b.z
  local near = nil
  -- the nearest river row (and the rows within 60 m, for riverAt)
  local best, brow, bhalf = 45, nil, nil
  local near_rows = {}
  for _, rv in pairs(water.rivers) do
    if rv and rv.rowinfo and len(rx - rv.vx, ry - rv.vy, rz - rv.vz) < rv.vr + 60 then
      for i, row in ipairs(rv.rowinfo) do
        local d = len(rx - row[1], ry - row[2], rz - row[3]) - row[5]
        if d < best then best, brow, bhalf = d, row, row[5] end
        if d < 60 then
          -- (the next row downstream, when it is the same run: a few metres on)
          local nx = rv.rowinfo[i + 1]
          row.nxt = (nx and len(nx[1] - row[1], nx[2] - row[2], nx[3] - row[3]) < 12) and nx or nil
          near_rows[#near_rows + 1] = row
        end
      end
    end
  end
  water.near_rows = near_rows
  if brow then
    local k = 1 - math.max(0, best) / 45
    amb_set("stream", (bhalf > 2.2) and "audio/water/stream_loop.ogg" or "audio/water/brook_loop.ogg",
      (0.12 + 0.45 * k) * math.min(1, bhalf / 2.5 + 0.4), brow[1], brow[2], brow[3], 6, 60)
    near = math.max(0, best)
  end
  ambientStats.stream = brow and best or nil
  ambientStats.streamRow = brow and { brow[1], brow[2], brow[3], brow[5] } or nil
  -- the falls
  local nf = 0
  for key, rv in pairs(water.rivers) do
    if rv and rv.falls then
      for i, f in ipairs(rv.falls) do
        local d = len(rx - f.bx, ry - f.by, rz - f.bz)
        if d < 150 then
          nf = nf + 1
          amb_set("fall" .. key .. "_" .. i, (f.drop > 4) and "audio/water/waterfall_loop.ogg" or "audio/water/waterfall_soft_loop.ogg",
            math.min(0.9, 0.35 + f.drop * 0.06 + f.half * 0.04), f.bx, f.by, f.bz, 10, 160)
          if d < 120 and (water.t_total or 0) - (f.mist_t or -10) > 4.5 then
            f.mist_t = water.t_total or 0
            local fx = findScript and findScript("vfx")
            if fx and fx.emit then fx.emit("FallMist", b.x + f.bx, b.y + f.by, b.z + f.bz, { intensity = math.min(2, 0.5 + f.drop / 5) }) end
          end
        end
      end
    end
  end
  ambientStats.fall = nf
  -- the nearest lake or pool shore
  local lbest, lpt, lbig = 30, nil, false
  local function shores(list)
    for _, l in pairs(list) do
      if l and l.shore and len(rx - l.vx, ry - l.vy, rz - l.vz) < (l.vr or 0) + 40 then
        for _, sd in ipairs(l.shore) do
          local d = len(rx - sd[1] * l.Rl, ry - sd[2] * l.Rl, rz - sd[3] * l.Rl)
          if d < lbest then lbest, lpt, lbig = d, { sd[1] * l.Rl, sd[2] * l.Rl, sd[3] * l.Rl }, (l.reach or 0) > 60 end
        end
      end
    end
  end
  shores(water.lakes)
  shores(water.plakes)
  if lpt then
    amb_set("lap", lbig and "audio/water/lap_loop.ogg" or "audio/water/lap_rocks_loop.ogg", 0.4 * (1 - lbest / 30), lpt[1], lpt[2], lpt[3], 5, 40)
    near = math.min(near or 1e9, lbest)
  end
  ambientStats.lap = lpt and lbest or nil
  -- the sea's shore (ocean.lua publishes how far the nearest is from the eye)
  for _, o in ipairs(findScripts and findScripts("ocean") or {}) do
    if o.shoreDist and o.shoreDist < 1e8 then near = math.min(near or 1e9, o.shoreDist) end
  end
  water.near_dist = near
  ambientStats.near = near
end

-- Travel time (s) from a river's source to each of its points: the bed's
-- ground height at each point gives the slope, and Manning's formula for a
-- shallow, rough stream (n ≈ 0.06 for a cobbled bed, hydraulic radius ≈
-- 0.15 m: brooks a few metres wide) the speed, v ≈ 4·√S m/s, held between
-- 0.3 and 3.2 m/s. (These worlds' streams fall 10–20% down 60 m hills; at
-- a smooth channel's n every one of them was a torrent of white water.) Built once per river (a march
-- per point), kept for the session.
local tau_cache = setmetatable({}, { __mode = "k" })
function river_tau(b, w, rv, top, bottom)
  if tau_cache[rv] then return tau_cache[rv] end
  local p = rv.points
  local n = math.floor(#p / 3)
  local g = {}
  for i = 1, n do
    local x, y, z = p[i * 3 - 2], p[i * 3 - 1], p[i * 3]
    local l = len(x, y, z)
    g[i] = ground_r(b, x / l, y / l, z / l, top, bottom)
  end
  local tau, speed = { 0 }, {}
  for i = 1, n - 1 do
    local ds = len(p[i * 3 + 1] - p[i * 3 - 2], p[i * 3 + 2] - p[i * 3 - 1], p[i * 3 + 3] - p[i * 3])
    -- Slope over a few points either side (the bed is noisy point to point).
    local a, c = math.max(1, i - 2), math.min(n, i + 3)
    local run = 0
    for k = a, c - 1 do
      run = run + len(p[k * 3 + 1] - p[k * 3 - 2], p[k * 3 + 2] - p[k * 3 - 1], p[k * 3 + 3] - p[k * 3])
    end
    local drop = (g[a] and g[c]) and (g[a] - g[c]) or 0
    local S = math.max(0.0004, drop / math.max(run, 1))
    local v = math.max(0.3, math.min(3.2, 4 * math.sqrt(S)))
    speed[i] = v
    tau[i + 1] = tau[i] + ds / v
  end
  tau_cache[rv] = tau
  return tau
end

-- Is ground at radius g under planet-local direction d already under the sea
-- or one of the world's lakes? A river crosses a basin at the height it fills
-- to (engine 0.117 rc3), so its line runs on through the lake it feeds; the
-- lake's own surface is the water there, and a ribbon laid on the bed showed
-- through it as a pale stripe.
local function under_standing_water(w, h, dx, dy, dz, g)
  if (w.sea or 0) > 0 and g < w.sea - 0.2 then return true end
  for _, L in ipairs(h and h.lakes or {}) do
    local ll = len(L.x, L.y, L.z)
    local c = (dx * L.x + dy * L.y + dz * L.z) / ll
    if c > 0.5 and math.acos(math.min(1, c)) * w.radius <= L.reach + 4 and g < w.radius + L.level - 0.2 then return true end
  end
  return false
end

local function build_river(b, w, rv, i0, i1)
  local p, wd = rv.points, rv.widths
  local R = w.radius
  local pos, idx, uvs = {}, {}, {}
  local top, bottom = R + (w.relief or 30) + 20, R - (w.shape and w.shape.low or 40) - 20
  local function pt(i)
    i = math.max(1, math.min(#p / 3, i))
    return p[i * 3 - 2], p[i * 3 - 1], p[i * 3]
  end
  -- uv: x = across the stream, −1 one bank … +1 the other; y = TRAVEL TIME
  -- in seconds from the river's source (river_tau), so a pattern at
  -- uv.y − time moves at the water's own local speed everywhere and
  -- neighbouring pieces' ripples join.
  local tau = river_tau(b, w, rv, top, bottom)
  local along = 0
  -- The carved bed's points are ~10 m apart: a ribbon straight between them
  -- is a chain of kinked planks. Each span is split in SUB, through a
  -- Catmull-Rom curve, and each sample is set on the real ground.
  local SUB = 3
  local samples = {}
  for i = i0, i1 - 1 do
    local ax, ay, az = pt(i - 1)
    local bx, by, bz = pt(i)
    local cx, cy, cz = pt(i + 1)
    local dx, dy, dz = pt(i + 2)
    local wa, wb = wd[i] or 8, wd[i + 1] or wd[i] or 8
    for k = 0, (i == i1 - 1) and SUB or SUB - 1 do
      local t = k / SUB
      local t2, t3 = t * t, t * t * t
      local function cr(a, b2, c, d)
        return 0.5 * ((2 * b2) + (-a + c) * t + (2 * a - 5 * b2 + 4 * c - d) * t2 + (-a + 3 * b2 - 3 * c + d) * t3)
      end
      samples[#samples + 1] = { cr(ax, bx, cx, dx), cr(ay, by, cy, dy), cr(az, bz, cz, dz), wa + (wb - wa) * t,
        tau = tau[i] + (tau[math.min(#tau, i + 1)] - tau[i]) * t }
    end
  end
  -- The polyline is thinned (system_generator keeps ≤200 points a river), so
  -- between its points the carved channel wanders off the straight or
  -- curved line by metres: a ribbon laid on the line sat on the bank, under
  -- the ground, and showed only where the two crossed. Each sample is moved
  -- across the flow to the lowest ground within a width of it (the channel),
  -- and the moves are smoothed so the ribbon does not zigzag.
  local n_s = #samples
  local shift = {}
  for si, sm in ipairs(samples) do
    local x, y, z = sm[1], sm[2], sm[3]
    local l = len(x, y, z)
    local dx, dy, dz = x / l, y / l, z / l
    local nsm, psm = samples[math.min(n_s, si + 1)], samples[math.max(1, si - 1)]
    local ax, ay, az = nsm[1] - psm[1], nsm[2] - psm[2], nsm[3] - psm[3]
    local nx, ny, nz = dy * az - dz * ay, dz * ax - dx * az, dx * ay - dy * ax
    local nl = len(nx, ny, nz)
    sm.dx, sm.dy, sm.dz = dx, dy, dz
    if nl > 1e-6 then
      nx, ny, nz = nx / nl, ny / nl, nz / nl
      sm.nx, sm.ny, sm.nz = nx, ny, nz
      local reach = math.max(2, sm[4] * 0.5)
      local best, bo = nil, 0
      for _, o in ipairs({ -1, -0.5, 0, 0.5, 1 }) do
        local qx, qy, qz = dx * l + nx * reach * o, dy * l + ny * reach * o, dz * l + nz * reach * o
        local ql = len(qx, qy, qz)
        local g = ground_r(b, qx / ql, qy / ql, qz / ql, top, bottom)
        -- Ties go to the line itself.
        if g and (not best or g < best - 0.15) then best, bo = g, reach * o end
      end
      shift[si] = bo
    else
      shift[si] = 0
    end
  end
  for si, sm in ipairs(samples) do
    local o = 0
    for k = -2, 2 do o = o + shift[math.max(1, math.min(n_s, si + k))] * (3 - math.abs(k)) end
    o = o / 9
    if sm.nx then sm[1], sm[2], sm[3] = sm[1] + sm.nx * o, sm[2] + sm.ny * o, sm[3] + sm.nz * o end
  end
  -- Where the line doubles back on itself within a few samples (a hairpin
  -- tighter than the ribbon is wide), a ribbon would fold over itself: over
  -- six samples the path runs much further than it gets. No ribbon is laid
  -- there. (Before engine 0.117 rc3 this was mostly the tracer walking a
  -- river round and round a basin it could not leave; rc3's rivers never
  -- loop, and this now trims only hairpins and tight wiggles of the thinned
  -- line: 8 of 330 rows on Rymiru, 26 of 156 on Draunol.)
  local knot = {}
  for si = 1, n_s do
    local a0, a1 = math.max(1, si - 3), math.min(n_s, si + 3)
    local path = 0
    for k = a0, a1 - 1 do
      local p0, p1 = samples[k], samples[k + 1]
      path = path + len(p1[1] - p0[1], p1[2] - p0[2], p1[3] - p0[3])
    end
    local c0, c1 = samples[a0], samples[a1]
    local chord = len(c1[1] - c0[1], c1[2] - c0[2], c1[3] - c0[3])
    knot[si] = path > 1e-3 and chord < path * 0.55
  end
  local prev, lx, ly, lz
  local prev_ax, prev_ay, prev_az, last_g
  local rows, runs, rowinfo = 0, {}, {}
  local falls, last_row = {}, nil
  for si, sm in ipairs(samples) do
    local x, y, z = sm[1], sm[2], sm[3]
    local l = len(x, y, z)
    local dx, dy, dz = x / l, y / l, z / l
    along = sm.tau
    lx, ly, lz = x, y, z
    local g = ground_r(b, dx, dy, dz, top, bottom)
    -- Across the flow: up × along.
    local nsm = samples[math.min(#samples, si + 1)]
    local psm = samples[math.max(1, si - 1)]
    local ax, ay, az = nsm[1] - psm[1], nsm[2] - psm[2], nsm[3] - psm[3]
    local nx, ny, nz = dy * az - dz * ay, dz * ax - dx * az, dx * ay - dy * ax
    local nl = len(nx, ny, nz)
    if nl < 1e-6 then
      if prev then nx, ny, nz, nl = prev[1], prev[2], prev[3], 1 else nx, ny, nz, nl = 1, 0, 0, 1 end
    end
    nx, ny, nz = nx / nl, ny / nl, nz / nl
    prev = { nx, ny, nz }
    -- A sharp turn (the tracer doubling back round a basin) or a drop of
    -- metres between two samples (a fall) folds a ribbon over itself: the
    -- ribbon is broken there instead.
    local fold = false
    if prev_ax then
      local d = (ax * prev_ax + ay * prev_ay + az * prev_az) / math.max(len(ax, ay, az) * len(prev_ax, prev_ay, prev_az), 1e-9)
      fold = d < 0.2
      if fold then water.stats.turn = water.stats.turn + 1 end
    end
    prev_ax, prev_ay, prev_az = ax, ay, az
    -- (A steep stretch is rapids, drawn down its slope: engine 0.117 rc3's
    -- rivers run from the highest ground, and breaking the ribbon at every
    -- 3.5 m step left alpine rivers as dashes. Only a real fall breaks it.)
    if g and last_g and math.abs(g - last_g) > 8 then fold = true; water.stats.drop = water.stats.drop + 1 end
    last_g = g
    if knot[si] then g = nil; water.stats.knot = water.stats.knot + 1 end
    if not g then water.stats.nog = water.stats.nog + 1 end
    if g and under_standing_water(w, water.hydro, dx, dy, dz, g) then g = nil; water.stats.under = water.stats.under + 1 end
    water.stats.rows = water.stats.rows + 1
    if not g or fold then
      -- No ground answer here (a cold chunk), or a fold: end this run of
      -- ribbon and start a new one after it, rather than dropping the piece.
      rows = 0
      if not g then last_row = nil end
    end
    if g then
      local half = sm[4] * 0.35
      -- The water stands at the LOWER bank's height, a little under it, and
      -- never below the bed: a channel narrower than a voxel or two is drawn
      -- shallower than the field's true bed (the mesh chords across it), so
      -- water laid just over the bed was under the drawn ground — the river
      -- showed in blobs. The banks rise through the ribbon's edges, where the
      -- shader fades it out.
      local function bank(sd)
        local qx, qy, qz = dx * g + nx * half * sd, dy * g + ny * half * sd, dz * g + nz * half * sd
        local ql = len(qx, qy, qz)
        return ground_r(b, qx / ql, qy / ql, qz / ql, g + 25, bottom) or g
      end
      local r = math.max(g + 0.5, math.min(bank(1.4), bank(-1.4)) - 0.2)
      -- Three vertices across: bank, centre, bank.
      for _, side in ipairs({ 1, 0, -1 }) do
        pos[#pos + 1], pos[#pos + 2], pos[#pos + 3] = dx * r + nx * half * side, dy * r + ny * half * side, dz * r + nz * half * side
        uvs[#uvs + 1], uvs[#uvs + 2] = side, along
      end
      rowinfo[#rowinfo + 1] = { dx * r, dy * r, dz * r, r, half, along }
      -- A FALL: the water's surface drops more than FALL_DROP from the last
      -- row to this one within a few metres (the ribbon breaks there, `fold`):
      -- kept for the sheet, the mist and the sound (build_fall_sheets).
      if last_row and last_row.r - r > FALL_DROP
          and len(dx * r - last_row.x, dy * r - last_row.y, dz * r - last_row.z) < 14 then
        falls[#falls + 1] = { tx = last_row.x, ty = last_row.y, tz = last_row.z, tr = last_row.r,
          bx = dx * r, by = dy * r, bz = dz * r, br = r, half = math.max(half, last_row.half),
          nx = nx, ny = ny, nz = nz, drop = last_row.r - r }
      end
      last_row = { x = dx * r, y = dy * r, z = dz * r, r = r, half = half }
      rows = rows + 1
      if rows == 1 then runs[#runs + 1] = { first = #pos / 3 - 2, n = 0, row0 = #rowinfo } end
      runs[#runs].n = rows
    end
  end
  -- Triangles for every run long enough to read as a stretch of river (a
  -- run of two or three rows between folds is a stray plank).
  for _, run in ipairs(runs) do
    if run.n < 5 then water.stats.short = water.stats.short + run.n end
    if run.n >= 5 then
      for rr = 0, run.n - 2 do
        local a = run.first + rr * 3   -- this row's left vertex (1-based)
        for c = 0, 1 do
          local a0, a1, b0, b1 = a + c, a + c + 1, a + c + 3, a + c + 4
          idx[#idx + 1], idx[#idx + 2], idx[#idx + 3] = a0, b0, b1
          idx[#idx + 1], idx[#idx + 2], idx[#idx + 3] = a0, b1, a1
          -- Both faces: a ribbon may be seen from either side as it bends.
          idx[#idx + 1], idx[#idx + 2], idx[#idx + 3] = a0, b1, b0
          idx[#idx + 1], idx[#idx + 2], idx[#idx + 3] = a0, a1, b1
        end
      end
    end
  end
  if #idx == 0 then return nil end
  -- A run's ends fade out over three rows (vertexColor.a, river.flsl): a
  -- ribbon that stopped at a fold, a cold chunk or standing water ended in
  -- a straight cut across the water (Ty: "water ending abruptly at edges").
  local cols = {}
  for v = 1, #pos / 3 do cols[#cols + 1], cols[#cols + 2], cols[#cols + 3], cols[#cols + 4] = 1, 1, 1, 1 end
  for _, run in ipairs(runs) do
    if run.n >= 5 then
      for rr = 0, run.n - 1 do
        local fade = math.min(1, math.min(rr, run.n - 1 - rr) / 3)
        for c = 0, 2 do cols[(run.first + rr * 3 + c) * 4] = fade end
      end
    end
  end
  local ok, name = pcall(mesh.build, { positions = pos, indices = idx, uvs = uvs, colors = cols })
  if not ok then return nil end
  -- The engine's water for it: a disc on the water's own sphere at every
  -- row, as wide as the ribbon (and reaching the next row), carrying the
  -- current — downstream, at the speed the ripples are drawn moving (uv.y is
  -- travel time, so speed = metres between rows over seconds between them).
  local vols = {}
  if VOLUMES and engine_water and engine_water.addVolume then
    for _, run in ipairs(runs) do
      if run.n >= 5 then
        -- every second row, each disc reaching the next one's
        for rr = 0, run.n - 1, 2 do
          local k = run.row0 + rr
          local a, c = rowinfo[k], rowinfo[math.min(run.row0 + run.n - 1, k + 1)]
          local p0 = rowinfo[math.max(run.row0, k - 1)]
          local fx, fy, fz = c[1] - p0[1], c[2] - p0[2], c[3] - p0[3]
          local ds, dt = len(fx, fy, fz), c[6] - p0[6]
          local ux, uy, uz = a[1] / a[4], a[2] / a[4], a[3] / a[4]
          local fu = fx * ux + fy * uy + fz * uz
          fx, fy, fz = fx - ux * fu, fy - uy * fu, fz - uz * fu
          local fl = len(fx, fy, fz)
          local v = (dt > 1e-4) and math.min(3.2, ds / dt) or 0
          local cur = fl > 1e-6 and vec3(fx / fl * v, fy / fl * v, fz / fl * v) or vec3(0, 0, 0)
          local c2 = rowinfo[math.min(run.row0 + run.n - 1, k + 2)]
          local step = len(c2[1] - a[1], c2[2] - a[2], c2[3] - a[3])
          vols[#vols + 1] = { shape = "lake", parent = water.body,
            center = vec3(a[1], a[2], a[3]), radius = a[4], reach = math.max(a[5] * 1.05, step * 0.6), current = cur }
        end
      end
    end
  end
  local mx, my, mz = 0, 0, 0
  for _, a in ipairs(rowinfo) do mx, my, mz = mx + a[1], my + a[2], mz + a[3] end
  mx, my, mz = mx / #rowinfo, my / #rowinfo, mz / #rowinfo
  local vr = 0
  for _, a in ipairs(rowinfo) do vr = math.max(vr, len(a[1] - mx, a[2] - my, a[3] - mz)) end
  local river = { mesh = name, vspec = vols, vx = mx, vy = my, vz = mz, vr = vr + 5, rowinfo = rowinfo, falls = falls }
  build_fall_sheets(b, w, river)
  spawn("RiverSheet", vec3(0, 0, 0), function(n)
    n.name = "River"
    n.x, n.y, n.z = 0, 0, 0
    n.model = name
    n.tags = { "genbody", "river" }
    dress(n, w, "river")
    river.undressed = { "river" }
    river.node = n
  end, b.node or find(water.body))
  return river
end

-- A lake's or river stretch's engine water is declared only while the eye
-- is within VOL_NEAR of it (and taken back past VOL_FAR): every declared
-- volume costs every body in the world a test each physics step (measured
-- 139 discs: physics 0.03 → 2.55 ms a frame), and nothing out of sight is
-- floating in it.
local VOL_NEAR, VOL_FAR = 250, 350
local function vols_on(t)
  if t.vols or not t.vspec or not (engine_water and engine_water.addVolume) then return end
  t.vols = {}
  for _, o in ipairs(t.vspec) do
    local ok, id = pcall(engine_water.addVolume, o)
    if ok and id then t.vols[#t.vols + 1] = id end
  end
end
local function vols_off(t)
  if not t.vols then return end
  if engine_water and engine_water.removeVolume then
    for _, id in ipairs(t.vols) do pcall(engine_water.removeVolume, id) end
  end
  t.vols = nil
end

local function free(t)
  vols_off(t)
  if t.node and t.node.valid then t.node:destroy() end
  if t.mesh then pcall(mesh.free, t.mesh) end
  for _, f in ipairs(t.falls or {}) do
    if f.node and f.node.valid then f.node:destroy() end
    if f.mesh then pcall(mesh.free, f.mesh) end
  end
end

local function clear_water()
  build_co, water.job = nil, nil
  amb_stop_all()
  for _, l in pairs(water.lakes) do if l then free(l) end end
  for _, r in pairs(water.rivers) do if r then free(r) end end
  for _, p in pairs(water.plakes or {}) do if p then free(p) end end
  water.lakes, water.rivers, water.hydro, water.body = {}, {}, nil, nil
  water.plakes, water.pools, water.levels, water.targets, water.breach, water.rim = {}, {}, {}, {}, {}, {}
  water.edit_serial, water.pools_loaded, water.rebuilt = nil, false, {}
end

-- Metres below a lake's (or a pool's) surface at a WORLD point on body `name`,
-- or nil when the point is in no lake or pool standing near the eye.
local function lake_depth_in(list, b, x, y, z)
  for _, l in pairs(list) do
    if l and l.state then
      local px, py, pz = x - b.x, y - b.y, z - b.z
      local r = len(px, py, pz)
      local dx, dy, dz = px / r, py / r, pz / r
      local cosu = dx * l.ux + dy * l.uy + dz * l.uz
      if cosu > 0.5 then
        local a = (dx * l.t1[1] + dy * l.t1[2] + dz * l.t1[3]) / cosu * l.Rl
        local c = (dx * l.t2[1] + dy * l.t2[2] + dz * l.t2[3]) / cosu * l.Rl
        local i, j = math.floor(a / l.s + l.off + 0.5), math.floor(c / l.s + l.off + 0.5)
        if i >= 0 and j >= 0 and i < l.N and j < l.N and l.state[j * l.N + i] == 1 then
          local d = l.Rl - r
          -- Under rock (a cave below the lake's bed or beside it) is not in
          -- the lake: the column up to its surface has to be open.
          if d > 0 and columnOpen(b.x, b.y, b.z, px, py, pz, l.Rl) == false then d = -2.5 end
          if d > -2 then return d end
        end
      end
    end
  end
  return nil
end
function lakeDepth(name, x, y, z)
  if name ~= water.body then return nil end
  local b = space.body(name)
  if not b then return nil end
  local d = lake_depth_in(water.lakes, b, x, y, z)
  if d == nil and water.plakes then d = lake_depth_in(water.plakes, b, x, y, z) end
  return d
end

-- The lakes and river water standing near the eye right now (for the HUD and
-- the probes): { lakes = n, rivers = n, pools = n, volumes = n, body = name }
-- — volumes is how many engine water discs they declared.
function waterNear()
  local nl, nr, nv, np = 0, 0, 0, 0
  for _, l in pairs(water.lakes) do if l then nl = nl + 1; nv = nv + #(l.vols or {}) end end
  for _, r in pairs(water.rivers) do if r then nr = nr + 1; nv = nv + #(r.vols or {}) end end
  for _, p in pairs(water.plakes or {}) do if p then np = np + 1; nv = nv + #(p.vols or {}) end end
  -- the falls of the built rivers (body-relative feet) and a sample of their
  -- rows (every 6th), for the probes
  local falls, rows = {}, {}
  for k, r in pairs(water.rivers) do
    for _, f in ipairs(r and r.falls or {}) do falls[#falls + 1] = { x = f.bx, y = f.by, z = f.bz, drop = f.drop, half = f.half, built = f.node ~= nil, piece = k } end
    for i, row in ipairs(r and r.rowinfo or {}) do
      if i % 6 == 1 then rows[#rows + 1] = { x = row[1], y = row[2], z = row[3], half = row[5], piece = k } end
    end
  end
  return { lakes = nl, rivers = nr, pools = np, volumes = nv, body = water.body, stats = water.stats,
           levels = water.levels, targets = water.targets, poolSpecs = water.pools, reach = reachStats,
           falls = falls, rows = rows, ambient = ambientStats }
end

-- ── live levels and pools ───────────────────────────────────────────────────
-- Water COMES FROM THE TERRAIN and follows it when the terrain changes:
--
--   * a LAKE has a live level. A dig that cuts its rim below the water
--     (rim_check, asked where the edit feed says ground moved near a built
--     lake's shore) is a breach: the lake drains toward the breach's height,
--     LEVEL_DRAIN m/s, and rises back (its rivers refill it) once the breach
--     is filled in. Levels that differ from the generator's are kept in
--     `lakeLevel.<body>`.
--   * a POOL is a small basin found on the real ground: a PIT the laser dug
--     within PIT_SOURCE m of water standing higher than its floor (the sea, a
--     lake, a river, another pool) seeps full over 20–90 s, to the lower of
--     the source's level and its own rim; a pit on dry high ground stays dry.
--     A SUMP is the lowest floor of a wet cave kind (SUMP_KINDS) that holds
--     water: found as the eye moves through caves (sump_search), the highest
--     level up to 2.4 m above the floor that stays closed within SUMP_BOUND.
--     Pools are kept in `pools.<body>` and built, read (lakeDepth), floated
--     and swum exactly like lakes (build_lake with a pool's spec).
--
-- The edit feed is terrain.editsSince (engine 0.118): what landed, where, in
-- the body's own frame, so nothing here keeps a world point.
local LEVEL_DRAIN = 0.06
local LEVEL_FILL = 0.015
local LEVEL_REBUILD = 0.2
local POOL_MAX = 64
-- A pit seeps only BESIDE water the player can see (Ty, 11-12b: "digging a
-- hole still leads to water" — a 6 m pit by the base fence got a puddle from
-- a source 60 m off: the generator's lake record, whose `reach` is its
-- farthest shore, or a sea 60 m away over a rise). Now: open, reachable sea
-- within PIT_SOURCE m; the SHORE of a lake that is built and drawn within
-- PIT_SOURCE m (never the hydro record's reach); a drawn river's water within
-- PIT_SOURCE_RIVER m; a settled pool within PIT_SOURCE_POOL m of its edge.
-- Anywhere else a pit is a dry pit, however deep.
local PIT_SOURCE = 18
local PIT_SOURCE_RIVER = 10
local PIT_SOURCE_POOL = 5
-- Pool records carry POOL_V; a save's pit pools from before the rule above
-- are dropped on load (cave sumps are kept: their rule has not changed).
local POOL_V = 2
local PIT_MIN_R = 0.8
local SUMP_EVERY = 6.0
local SUMP_MOVE = 8.0
local SUMP_KINDS = { karst = true, ice = true, chasm = true, collapse = true }
local SUMP_BOUND = 24.0
local SUMP_CELL = 1.0
water.plakes, water.pools, water.levels, water.targets, water.breach, water.rim = {}, {}, {}, {}, {}, {}
water.pool_next, water.pools_dirty, water.pools_dirty_t, water.rebuilt = 1, false, 0, {}
water.sump_t, water.sump_u = -100, nil
poolStats = { pits = 0, sumps = 0, dry = 0, rebuilt = 0, breaches = 0, searches = 0 }

local function clampc(c) return math.max(-1, math.min(1, c)) end

-- Whether this world's standing water is liquid (frozen seas and dry worlds
-- have no pools; a methane world's pools are methane, which is fine).
local function liquid_world(w)
  if not w then return false end
  if w.water and w.water.state == "ice" then return false end
  return (w.sea or 0) > 0 or w.hydro == true or ((w.atmo or 0) > 0.3 and (w.climMoist or 0) > 0.35)
end

-- Levels and pools kept in the save (lists, so the keys survive the trip).
local function levels_load(name)
  water.levels = {}
  local l = save.get("lakeLevel." .. name)
  if type(l) == "table" then
    for _, e in ipairs(l) do if e.i and e.level then water.levels[e.i] = e.level; water.targets[e.i] = e.level end end
  end
end
local function levels_save(name)
  local out = {}
  for i, lv in pairs(water.levels) do out[#out + 1] = { i = i, level = lv } end
  save.set("lakeLevel." .. name, out)
end
local function pools_load(name)
  water.pools, water.pool_next = {}, 1
  local l = save.get("pools." .. name)
  if type(l) == "table" then
    for _, p in ipairs(l) do
      if p.kind == "pit" and p.v ~= POOL_V then
        poolStats.stale = (poolStats.stale or 0) + 1
        water.pools_dirty = true
      elseif p.id and p.x and p.level then
        water.pools[p.id] = p
        water.pool_next = math.max(water.pool_next, p.id + 1)
      end
    end
  end
  water.pools_loaded = true
end
local function pools_save(name)
  local out = {}
  for _, p in pairs(water.pools) do out[#out + 1] = p end
  save.set("pools." .. name, out)
  water.pools_dirty = false
end

-- The spec a lake is built from: the generator's, or the same basin at its
-- live level (the centre lifted to it, the depth what is left under it).
local function lake_level(i, L) return water.levels[i] or L.level end
local function lake_spec(R, i, L)
  local lv = lake_level(i, L)
  if lv == L.level then return L end
  local Rl = R + lv
  local ll = len(L.x, L.y, L.z)
  return { x = L.x / ll * Rl, y = L.y / ll * Rl, z = L.z / ll * Rl, level = lv, reach = L.reach,
           depth = math.max(0.5, (L.depth or 4) - (L.level - lv)), area = L.area }
end

-- Arc distance (m, at radius R) between two body-relative directions/points.
local function arc_between(ax, ay, az, bx, by, bz, R)
  local al, bl = len(ax, ay, az), len(bx, by, bz)
  if al < 1e-9 or bl < 1e-9 then return 1e9 end
  return math.acos(clampc((ax * bx + ay * by + az * bz) / (al * bl))) * R
end

local function pool_add(w, p)
  local n = 0
  local oldest, oldest_t = nil, 1e18
  for id, q in pairs(water.pools) do
    n = n + 1
    if (q.t or 0) < oldest_t then oldest, oldest_t = id, q.t or 0 end
  end
  if n >= POOL_MAX and oldest then
    local have = water.plakes[oldest]
    if have then free(have) end
    water.plakes[oldest], water.pools[oldest] = nil, nil
  end
  p.id = water.pool_next
  p.v = POOL_V
  p.t = water.t_total or 0
  water.pool_next = water.pool_next + 1
  water.pools[p.id] = p
  water.pools_dirty = true
  return p
end

-- A dig landed at body-relative (e.x,e.y,e.z), radius e.r: is there a pit
-- here that water nearby would seep into? Run as a build job.
local function pit_check(b, w, h, e)
  local R = w.radius
  local el = len(e.x, e.y, e.z)
  if el < 1 then return end
  local ux, uy, uz = e.x / el, e.y / el, e.z / el
  local er = math.max(e.r or 1, PIT_MIN_R)
  local gf = ground_r(b, ux, uy, uz, el + er + 3, el - er - 8)
  if not gf then return end
  -- Water already standing here: a pool deepened or widened is built again.
  for id, p in pairs(water.pools) do
    if arc_between(ux, uy, uz, p.x, p.y, p.z, R) <= p.reach + er + 2 then
      local have = water.plakes[id]
      if have then free(have) end
      water.plakes[id] = nil
      p.depth = math.max(p.depth or 1, R + p.level - gf)
      water.pools_dirty = true
      poolStats.rebuilt = poolStats.rebuilt + 1
      return
    end
  end
  if (w.sea or 0) > gf then
    local so, state = reach_query(water.body, b, w.sea, ux, uy, uz)
    if so == true or state == "pending" then return end
  end
  if lakeDepth(water.body, b.x + ux * (gf + 0.3), b.y + uy * (gf + 0.3), b.z + uz * (gf + 0.3)) then return end
  -- A source: the sea, a lake, a pool or a river standing higher than the
  -- floor, and how far away it is.
  local src_level, src_d = nil, nil
  local function offer(level, d)
    if level <= gf + 0.3 then return end
    d = math.max(d, 2)
    if not src_d or d < src_d then src_level, src_d = level, d end
  end
  local t1x, t1y, t1z, t2x, t2y, t2z = tangent_basis(ux, uy, uz)
  if (w.sea or 0) > gf + 0.3 then
    local S = w.sea
    for k = 0, 11 do
      local a = k * math.pi / 6
      local ca, sa = math.cos(a), math.sin(a)
      for dist = 6, PIT_SOURCE, 6 do
        slice(b)
        local dx = ux + (t1x * ca + t2x * sa) * dist / R
        local dy = uy + (t1y * ca + t2y * sa) * dist / R
        local dz = uz + (t1z * ca + t2z * sa) * dist / R
        local l = len(dx, dy, dz)
        dx, dy, dz = dx / l, dy / l, dz / l
        -- (open at the sea's radius and a hand's depth under it: a shelf a
        -- few decimetres deep is sea too, and the reach rule says whether
        -- it is the sea's; a 1.5 m test here missed a whole shallow beach)
        local q = terrain.query(b.x + dx * S, b.y + dy * S, b.z + dz * S)
        if q and q > 0.05 then
          local qd = terrain.query(b.x + dx * (S - 0.3), b.y + dy * (S - 0.3), b.z + dz * (S - 0.3))
          if qd and qd > 0 and reach_query(water.body, b, S, dx, dy, dz) == true then offer(S, dist) break end
        end
      end
    end
  end
  -- a BUILT lake's shore (its lattice's shore ring, kept at build time)
  for i, l in pairs(water.lakes) do
    if l and l.shore and l.Rl then
      local best = nil
      for _, sd in ipairs(l.shore) do
        local d = arc_between(ux, uy, uz, sd[1], sd[2], sd[3], R)
        if not best or d < best then best = d end
      end
      if best and best <= PIT_SOURCE then offer(l.Rl, best) end
    end
  end
  -- a settled pool right beside the pit (not a pool still filling: pits
  -- would feed pits across a whole yard)
  for _, p in pairs(water.pools) do
    local d = arc_between(ux, uy, uz, p.x, p.y, p.z, R) - p.reach
    if d <= PIT_SOURCE_POOL and math.abs((p.target or p.level) - p.level) < 0.02 then offer(R + p.level, d) end
  end
  -- a drawn river's water (the built ribbon's rows)
  for _, rv in pairs(water.rivers) do
    for _, row in ipairs(rv and rv.rowinfo or {}) do
      local d = arc_between(ux, uy, uz, row[1], row[2], row[3], R) - row[5]
      if d <= PIT_SOURCE_RIVER then offer(row[4], d) end
    end
  end
  if not src_level then poolStats.dry = poolStats.dry + 1 return end
  -- The pit's rim: the lowest pass out of it (twelve rays, the highest ground
  -- along each); the pool can stand no higher.
  local rim = nil
  for k = 0, 11 do
    local a = k * math.pi / 6
    local ca, sa = math.cos(a), math.sin(a)
    local hi = nil
    local rho = er * 0.6
    while rho <= er * 1.8 + 2.5 do
      slice(b)
      local dx = ux + (t1x * ca + t2x * sa) * rho / R
      local dy = uy + (t1y * ca + t2y * sa) * rho / R
      local dz = uz + (t1z * ca + t2z * sa) * rho / R
      local l = len(dx, dy, dz)
      local g = ground_r(b, dx / l, dy / l, dz / l, gf + 40, gf - 6)
      if g and (not hi or g > hi) then hi = g end
      rho = rho + 1.5
    end
    if hi and (not rim or hi < rim) then rim = hi end
  end
  if not rim then return end
  local target = math.min(src_level, rim - 0.15)
  if target < gf + 0.3 then poolStats.dry = poolStats.dry + 1 return end
  local seconds = 20 + src_d * 1.2
  local start = gf + 0.25
  local Rs = start
  poolStats.pits = poolStats.pits + 1
  return pool_add(w, { x = ux * Rs, y = uy * Rs, z = uz * Rs, level = Rs - R, target = target - R,
    rate = (target - start) / seconds, reach = er * 1.3 + 1.5, depth = Rs - gf + 0.5, floor = gf - R, kind = "pit" })
end

-- From the eye at body-relative (px,py,pz), inside a wet cave kind: walk the
-- floor downhill to its lowest point near, and find the highest level up to
-- 2.4 m over it that stays closed. Run as a build job; nil = no sump here.
local function sump_search(b, w, px, py, pz)
  local R = w.radius
  local r = len(px, py, pz)
  if r < 1 then return nil end
  local ux, uy, uz = px / r, py / r, pz / r
  local g = ground_r(b, ux, uy, uz, r + 0.5, r - 14)
  if not g then return nil end
  for _ = 1, 14 do
    slice(b)
    local t1x, t1y, t1z, t2x, t2y, t2z = tangent_basis(ux, uy, uz)
    local best, bx, by, bz = g, nil, nil, nil
    for k = 0, 5 do
      local a = k * math.pi / 3
      local ca, sa = math.cos(a), math.sin(a)
      local dx, dy, dz = ux + (t1x * ca + t2x * sa) * 2 / g, uy + (t1y * ca + t2y * sa) * 2 / g, uz + (t1z * ca + t2z * sa) * 2 / g
      local l = len(dx, dy, dz)
      dx, dy, dz = dx / l, dy / l, dz / l
      local gg = ground_r(b, dx, dy, dz, g + 3, g - 5)
      if gg and gg < best - 0.08 then best, bx, by, bz = gg, dx, dy, dz end
    end
    if not bx then break end
    ux, uy, uz, g = bx, by, bz, best
  end
  -- Not under the open sky: a sump is a cave's.
  if columnOpen(b.x, b.y, b.z, ux * (g + 0.3), uy * (g + 0.3), uz * (g + 0.3), R + (w.relief or 30) + 30) ~= false then return nil end
  for _, p in pairs(water.pools) do
    if arc_between(ux, uy, uz, p.x, p.y, p.z, R) <= p.reach + 3 and math.abs(R + p.level - g) < 6 then return nil end
  end
  local t1x, t1y, t1z, t2x, t2y, t2z = tangent_basis(ux, uy, uz)
  local bound2 = SUMP_BOUND * SUMP_BOUND
  for _, h in ipairs({ 2.4, 1.6, 0.9 }) do
    local Rl = g + h
    local queue, seen, head = { { 0, 0 } }, { [0] = true }, 1
    local n, leak, far2 = 0, false, 0
    while head <= #queue do
      local c = queue[head]
      head = head + 1
      local a, cc = c[1] * SUMP_CELL, c[2] * SUMP_CELL
      if a * a + cc * cc >= bound2 then leak = true break end
      slice(b)
      local dx, dy, dz = ux + (t1x * a + t2x * cc) / Rl, uy + (t1y * a + t2y * cc) / Rl, uz + (t1z * a + t2z * cc) / Rl
      local l = len(dx, dy, dz)
      local q = terrain.query(b.x + dx / l * Rl, b.y + dy / l * Rl, b.z + dz / l * Rl)
      if q == nil then leak = true break end
      if q > 0.1 then
        n = n + 1
        if a * a + cc * cc > far2 then far2 = a * a + cc * cc end
        for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
          local k = (c[1] + d[1]) * 100000 + (c[2] + d[2])
          if not seen[k] then seen[k] = true; queue[#queue + 1] = { c[1] + d[1], c[2] + d[2] } end
        end
        if n > 1500 then leak = true break end
      end
    end
    if not leak and n >= 6 then
      poolStats.sumps = poolStats.sumps + 1
      local reach = math.sqrt(far2) + SUMP_CELL
      return pool_add(w, { x = ux * Rl, y = uy * Rl, z = uz * Rl, level = Rl - R, target = Rl - R, rate = 0,
        reach = reach, depth = h + 0.5, floor = g - R, kind = "cave" })
    end
  end
  return nil
end

-- A built lake's shore ring where edits landed: ring cells whose ground is
-- now below the water and leads on downhill are a breach. Updates
-- water.breach[i] (cell key → the breach's ground radius). A build job.
local function rim_check(b, w, lake, L, i, edits)
  local Rl = lake.Rl
  local N, s, off = lake.N, lake.s, lake.off
  local br = water.breach[i] or {}
  water.breach[i] = br
  local function dir(ii, jj)
    local a, c = (ii - off) * s / Rl, (jj - off) * s / Rl
    local x = lake.ux + lake.t1[1] * a + lake.t2[1] * c
    local y = lake.uy + lake.t1[2] * a + lake.t2[2] * c
    local z = lake.uz + lake.t1[3] * a + lake.t2[3] * c
    local l = len(x, y, z)
    return x / l, y / l, z / l
  end
  local bottom = Rl - (L.depth or 4) - 12
  for k, st in pairs(lake.state) do
    if st == 2 then
      local ii, jj = k % N, math.floor(k / N)
      local dx, dy, dz = dir(ii, jj)
      local near = false
      for _, e in ipairs(edits) do
        if arc_between(dx, dy, dz, e.x, e.y, e.z, Rl) <= (e.r or 1) + s + 2 then near = true break end
      end
      if near then
        slice(b)
        local g = ground_r(b, dx, dy, dz, Rl + 6, bottom)
        local hit = nil
        if g and g < Rl - 0.3 then
          local a, c = ii - off, jj - off
          local l2 = math.max(1, math.sqrt(a * a + c * c))
          local ox, oy, oz = dir(ii + a / l2 * 1.5, jj + c / l2 * 1.5)
          local g2 = ground_r(b, ox, oy, oz, Rl + 6, bottom)
          if g2 and g2 <= g + 0.3 then hit = g end
        end
        if hit then
          if not br[k] then poolStats.breaches = poolStats.breaches + 1 end
          br[k] = hit
        else
          br[k] = nil
        end
      end
    end
  end
  local spill = nil
  for _, g in pairs(br) do if not spill or g < spill then spill = g end end
  local R = w.radius
  water.targets[i] = spill and math.max(spill - R, L.level - (L.depth or 4) + 0.3) or L.level
end

-- Every half second: levels and pools move toward their targets; a built
-- sheet that lags its level by LEVEL_REBUILD is built again.
local function levels_tick(name, w, h, step)
  local changed = false
  for i, L in ipairs(h.lakes or {}) do
    local tgt = water.targets[i]
    if tgt then
      local lv = lake_level(i, L)
      if math.abs(tgt - lv) > 1e-3 then
        local rate = (tgt < lv) and LEVEL_DRAIN or LEVEL_FILL
        local nl = lv + math.max(-rate * step, math.min(rate * step, tgt - lv))
        if math.abs(nl - L.level) < 1e-3 then nl = L.level end
        water.levels[i] = (nl ~= L.level) and nl or nil
        changed = true
        local have = water.lakes[i]
        if have and have.level and math.abs(have.level - nl) > LEVEL_REBUILD then free(have); water.lakes[i] = nil end
      elseif tgt == L.level then
        water.targets[i] = nil
      end
    end
  end
  if changed then levels_save(name) end
  for id, p in pairs(water.pools) do
    if p.target and math.abs(p.target - p.level) > 1e-3 and (p.rate or 0) > 0 then
      local nl = p.level + math.max(-p.rate * step, math.min(p.rate * step, p.target - p.level))
      local R = w.radius
      local ll = len(p.x, p.y, p.z)
      local Rl = R + nl
      p.x, p.y, p.z, p.level = p.x / ll * Rl, p.y / ll * Rl, p.z / ll * Rl, nl
      p.depth = nl - (p.floor or (nl - 1))
      local have = water.plakes[id]
      if have and have.level and math.abs(have.level - nl) > LEVEL_REBUILD then free(have); water.plakes[id] = nil end
      if math.abs(p.target - p.level) <= 1e-3 then water.pools_dirty = true end
    end
  end
  if water.pools_dirty and (water.t_total or 0) - (water.pools_dirty_t or 0) > 3 then
    water.pools_dirty_t = water.t_total or 0
    pools_save(name)
  end
end

-- What landed in the ground since last asked (the body's own frame), paint
-- left out; "all" when the feed ran ahead of us (everything looks again).
local function read_edits(name)
  if not (terrain.editSerial and terrain.editsSince) then return nil end
  local s = terrain.editSerial()
  if water.edit_serial == nil then water.edit_serial = s return nil end
  if s == water.edit_serial then return nil end
  local recs = terrain.editsSince(water.edit_serial, { body = name })
  water.edit_serial = s
  if recs == nil then return "all" end
  local out = {}
  for _, r in ipairs(recs) do
    if r.kind ~= "paint" and r.x then out[#out + 1] = { x = r.x, y = r.y, z = r.z, r = r.r or 1, kind = r.kind } end
  end
  return out
end

-- Resume the lake/river build job for this frame's BUILD_MS.
local function run_build()
  local j = water.job
  if not j then return end
  build_co, build_t0 = j.co, wall()
  local ok, res = coroutine.resume(j.co)
  if not ok then
    print("climate: building " .. j.what .. " failed: " .. tostring(res))
    j.put(false)
    water.job, build_co = nil, nil
  elseif coroutine.status(j.co) == "dead" then
    j.put(res or false)
    water.job, build_co = nil, nil
  end
end
local function start_build(what, fn, put)
  water.job = { what = what, co = coroutine.create(fn), put = put }
  run_build()
end

-- ── the water's screen pass (shaders/waterfx.flsl) ──────────────────────────
-- Under water: fog in the water's colour; near it: caustics on the lit bed
-- and the wet band over the waterline. Driven here every frame in
-- lateUpdate, the pose the frame is drawn with: the water sphere's centre is
-- sent RELATIVE TO THE CAMERA (a 32-bit uniform cannot hold a point 60 km
-- from the origin, and the planet moves metres a tick), with the radius of
-- the water the eye is in or nearest to (the sea, or a lake / pool the eye
-- stands by), how deep the camera is under it, the chemistry and the sun.
-- Off when nothing is near (more than WATERFX_FAR over the water, no lake).
local WATERFX_FAR = 60.0
local wfx = { node = nil, on = false, t = -10 }
waterFx = { on = false, depth = 0, R = 0 }   -- published, for the probes

local star_name, star_t = nil, -10
local function star_body()
  if time - star_t > 1.0 or not star_name then
    star_t = time
    local best, bmu = nil, -1
    for _, b in ipairs(space.bodies and space.bodies() or {}) do
      local key = ((b.soi or 0) < 0 and 1e30 or 0) + (b.mu or 0)
      if key > bmu then best, bmu = b.name, key end
    end
    star_name = best
  end
  return star_name and space.body(star_name)
end

function lateUpdate(node, dt)
  if not (wfx.node and wfx.node.valid) then
    if time - wfx.t < 1.0 then return end
    wfx.t = time
    wfx.node = find and find("Post Processing") or nil
    if not wfx.node then return end
  end
  local post = wfx.node
  local pc = findScript and findScript("planet_camera")
  local cx, cy, cz
  if pc and (pc.cam_x ~= 0 or pc.cam_y ~= 0 or pc.cam_z ~= 0) then cx, cy, cz = pc.cam_x, pc.cam_y, pc.cam_z end
  local name = cx and space.dominant(cx, cy, cz)
  local w = name and worldOf(name)
  local bn = name and find and find(name)
  local R, Rsea = 0, (w and w.sea) or 0
  local depth = -1e9
  if bn and w then
    local dx, dy, dz = cx - bn.x, cy - bn.y, cz - bn.z
    local dc = len(dx, dy, dz)
    -- the water the eye is in or beside: the sea where it reaches (seaDepth's
    -- rule), else the nearest built lake or pool whose sphere the eye is near
    if Rsea > 0 then
      local sd = seaDepth(cx, cy, cz)
      if sd and sd > 0 then R, depth = Rsea, sd
      elseif sd and sd == -1 then R = 0           -- a dry hollow under the sea's radius: no sea here
      else R, depth = Rsea, Rsea - dc end
    end
    local ld = lakeDepth(name, cx, cy, cz)
    if ld and ld > 0 then
      -- inside a lake or pool: its sphere
      for _, l in pairs(water.lakes) do if l and l.Rl and math.abs(l.Rl - dc - ld) < 0.5 then R = l.Rl end end
      for _, l in pairs(water.plakes) do if l and l.Rl and math.abs(l.Rl - dc - ld) < 0.5 then R = l.Rl end end
      depth = ld
    elseif R == 0 or dc - R > WATERFX_FAR then
      -- above the sea's reach: a lake or pool near the eye lends its sphere
      local best = WATERFX_FAR
      local function near_sheet(list)
        for _, l in pairs(list) do
          if l and l.Rl then
            local d = len(dx - l.vx, dy - l.vy, dz - l.vz) - (l.vr or 0)
            if d < best then best, R, depth = d, l.Rl, l.Rl - dc end
          end
        end
      end
      near_sheet(water.lakes)
      near_sheet(water.plakes)
    end
    local want = R > 0 and depth > -WATERFX_FAR
    if want ~= wfx.on then
      wfx.on = want
      pcall(post.setScreenShader, post, "waterfx", want)
    end
    waterFx.on, waterFx.depth, waterFx.R = want, depth, R
    if want then
      post:setShaderParam("waterfx.w0", bn.x - cx, bn.y - cy, bn.z - cz, R)
      post:setShaderParam("waterfx.eyeDepth", depth)
      local wt = water_look(w)
      local ar, ag, ab = waterAbsorb(wt)
      post:setShaderParam("waterfx.absorb", ar, ag, ab)
      post:setShaderParam("waterfx.deepColor", wt.deep[1], wt.deep[2], wt.deep[3])
      post:setShaderParam("waterfx.shallowColor", wt.shallow[1], wt.shallow[2], wt.shallow[3])
      local st = star_body()
      if st then
        local sx, sy, sz = st.x - cx, st.y - cy, st.z - cz
        local sl = len(sx, sy, sz)
        if sl > 1e-6 then post:setShaderParam("waterfx.sunDir", sx / sl, sy / sl, sz / sl) end
      end
    end
  elseif wfx.on then
    wfx.on = false
    waterFx.on = false
    pcall(post.setScreenShader, post, "waterfx", false)
  end
end

-- The scene goes (a menu round trip, a load): the lake and river meshes with
-- it. The engine keeps a built mesh until mesh.free or Stop, not until the
-- scene ends, so without this every load left the last world's water behind.
function onDestroy()
  pcall(clear_water)
end

function update(node, dt)
  flood.clock = flood.clock + dt
  reach.clock = flood.clock
  if next(flood.jobs) then flood_step(FLOOD_SLICE) end
  reach_tick(REACH_SLICE)
  run_build()
  amb_frame(dt)
  water.t = water.t + dt
  water.t_total = (water.t_total or 0) + dt
  if water.t < 0.5 then return end
  local step = water.t
  water.t = 0
  if not (mesh and mesh.build and terrain and terrain.query) then return end
  local ex, ey, ez = eye()
  if not ex then return end
  local name = space.dominant(ex, ey, ez)
  if name ~= water.body then clear_water(); water.body = name end
  if not name then return end
  local w = worldOf(name)
  if not (w and w.shape) then return end
  local b = space.body(name)
  if not b then return end
  local alt = len(ex - b.x, ey - b.y, ez - b.z) - w.radius
  if alt > w.radius * 1.5 then clear_water(); water.body = name; return end
  -- Only once the ground is here to fit the water to.
  if not terrain.query(b.x, b.y + w.radius, b.z) then return end
  if not water.hydro then
    if w.hydro then
      -- The home world's rivers and lakes are being worked out off the
      -- script thread (system_generator hydroWarm): wait for them rather
      -- than asking the same question again on this one.
      if not (gen_ref and gen_ref.valid) then gen_ref = findScript and findScript("system_generator") end
      if gen_ref and gen_ref.hydroPending and gen_ref.hydroPending(name) then return end
      water.hydro = hydroOf(name) or { lakes = {}, rivers = {} }
    else
      -- A world without rivers and lakes still has pools and a sea's reach.
      water.hydro = { lakes = {}, rivers = {} }
    end
  end
  local h = water.hydro
  b.node = b.node or find(name)
  if not water.pools_loaded then levels_load(name); pools_load(name) end
  local liquid = liquid_world(w)
  local bb = { x = b.x, y = b.y, z = b.z, node = b.node, name = b.name }
  local built = water.job ~= nil
  -- THE EDIT FEED: ground that moved since last asked. Near the sea's radius
  -- the sea's reach is worked out again; a dig is looked at as a pit (one
  -- job each, queued); a dig or fill at a built lake's shore is a rim check.
  local edits = read_edits(name)
  if edits == "all" then
    reach_forget()
    for i, l in pairs(water.lakes) do if l and l.state then water.rim[i] = water.rim[i] or {}; water.rim[i].all = true end end
  elseif edits then
    water.pits = water.pits or {}
    for _, e in ipairs(edits) do
      local el = len(e.x, e.y, e.z)
      if (w.sea or 0) > 0 and math.abs(el - w.sea) < e.r + 10 then reach_forget() end
      if e.kind == "dig" and liquid and e.r >= PIT_MIN_R then
        -- (bites land in bursts: one pit check per spot, the last bite's)
        local merged = false
        for _, q in ipairs(water.pits) do
          if arc_between(q.x, q.y, q.z, e.x, e.y, e.z, w.radius) < q.r + e.r + 1 then
            q.x, q.y, q.z, q.r, q.t = e.x, e.y, e.z, math.max(q.r, e.r), water.t_total
            merged = true
            break
          end
        end
        if not merged and #water.pits < 24 then
          water.pits[#water.pits + 1] = { x = e.x, y = e.y, z = e.z, r = e.r, t = water.t_total }
        end
      end
      for i, l in pairs(water.lakes) do
        if l and l.state and arc_between(e.x, e.y, e.z, l.ux, l.uy, l.uz, w.radius) < (h.lakes[i] and h.lakes[i].reach or 0) * 1.4 + 12 + e.r then
          water.rim[i] = water.rim[i] or {}
          local q = water.rim[i]
          q[#q + 1] = e
        end
      end
      for id, p in pairs(water.pools) do
        -- A pool's ground moved: it is built again (the lattice follows).
        if arc_between(e.x, e.y, e.z, p.x, p.y, p.z, w.radius) < p.reach + e.r + 2 and e.kind ~= "dig" then
          local have = water.plakes[id]
          if have then free(have); water.plakes[id] = nil end
        end
      end
    end
  end
  -- Pit checks, a second after the last bite there (the ground has landed).
  if water.pits and not built then
    for k = #water.pits, 1, -1 do
      local q = water.pits[k]
      if water.t_total - q.t > 1.0 then
        table.remove(water.pits, k)
        start_build("pit", function() return pit_check(bb, w, h, q) end, function() end)
        built = true
        break
      end
    end
  end
  -- Rim checks on built lakes where the ground moved.
  if not built then
    for i, q in pairs(water.rim) do
      local l = water.lakes[i]
      if l and l.state and h.lakes[i] then
        water.rim[i] = nil
        local L = h.lakes[i]
        local list = q
        if q.all then
          -- everything: every ring cell is "near" a pretend edit at the centre
          list = { { x = l.ux, y = l.uy, z = l.uz, r = (L.reach or 10) * 1.4 + 12 } }
        end
        start_build("rim " .. i, function() return rim_check(bb, w, l, L, i, list) end, function() end)
        built = true
        break
      elseif not h.lakes[i] then
        water.rim[i] = nil
      end
    end
  end
  levels_tick(name, w, h, step)
  ambient_tick(name, w, b, ex, ey, ez)
  -- Cave sumps: in a wet cave kind, from where the eye is, every SUMP_EVERY s
  -- and SUMP_MOVE m of movement.
  if liquid and not built and water.t_total - water.sump_t > SUMP_EVERY then
    local ug = findScript and findScript("underground")
    local kind = ug and ug.kindNow
    if kind and SUMP_KINDS[kind] then
      local px, py, pz = ex - b.x, ey - b.y, ez - b.z
      local su = water.sump_u
      if not su or len(px - su[1], py - su[2], pz - su[3]) > SUMP_MOVE then
        water.sump_t, water.sump_u = water.t_total, { px, py, pz }
        poolStats.searches = poolStats.searches + 1
        start_build("sump", function() return sump_search(bb, w, px, py, pz) end, function() end)
        built = true
      end
    end
  end
  -- The wind on the water (weather.lua): lakes are sheltered, so they feel
  -- about two thirds of it.
  local wx = findScript and findScript("weather")
  local wc = wx and wx.current and wx.current()
  if wc and wc.body == name then
    local sp = wc.windNow or wc.wind or 0
    local dx, dy, dz = wc.windX or 0, wc.windY or 0, wc.windZ or 1
    local bn = space.body(name)
    local amp, lam = lake_waves(sp * 0.65, bn and bn.mu and bn.mu / (w.radius * w.radius) or 9.81)
    local calm = (w.water and w.water.state == "methane" or (w.geo and w.geo.type == "titan")) and 0.18 or 1
    local function blow(l)
      if l and l.node and l.node.valid then
        l.node:setShaderParam("windDir", dx, dy, dz)
        l.node:setShaderParam("wind", sp * 0.65)
        l.node:setShaderParam("waveAmp", amp * calm)
        l.node:setShaderParam("waveLen", lam)
      end
    end
    for _, l in pairs(water.lakes) do blow(l) end
    for _, p in pairs(water.plakes) do blow(p) end
  end
  -- Lakes: build what came near, give back what fell far. One build at a
  -- time, as a job (`run_build`): the slot reads `false` until it lands.
  -- Pools are the same, from their own specs (`water.pools`).
  local function tend(list, specs, near, far)
    for i, L in pairs(specs) do
      local lx, ly, lz = b.x + L.x, b.y + L.y, b.z + L.z
      local d = len(ex - lx, ey - ly, ez - lz) - L.reach
      local have = list[i]
      local rk = (list == water.lakes) and i or ("p" .. i)
      -- A lake built while its ground was still streaming in is built again
      -- once the terrain has settled, so its outline follows the real ground
      -- (three times at most: a lake wider than the ground that streams in
      -- round the eye is provisional for ever, and rebuilding it every 4 s
      -- kept the one build slot and starved the pools).
      if have and have.provisional and not built and water.t_total - (have.built_t or 0) > 4
          and not (terrain.busy and terrain.busy()) and (water.rebuilt[rk] or 0) < 3 then
        water.rebuilt[rk] = (water.rebuilt[rk] or 0) + 1
        free(have)
        list[i] = nil
        have = nil
      end
      if have == nil and d < near and not built then
        list[i] = false
        local spec = (list == water.lakes) and lake_spec(w.radius, i, L) or L
        local rb = { k = rk }
        start_build("lake " .. i, function() return build_lake(bb, w, spec) end,
          function(r)
            if r and not r.provisional then water.rebuilt[rb.k] = 0 end
            if list[i] == false then list[i] = r elseif r then free(r) end
          end)
        built = true
      elseif have and d > far then
        free(have)
        list[i] = nil
      end
    end
    -- (a spec that is gone: its sheet with it)
    for i, have in pairs(list) do
      if have and specs[i] == nil then free(have); list[i] = nil end
    end
  end
  -- (pools first: they are small and the player is watching them fill)
  tend(water.plakes, water.pools, 300, 450)
  tend(water.lakes, h.lakes or {}, LAKE_NEAR, LAKE_FAR)
  -- Sheets made since last tick get their shader parameters now (dress_params).
  local function redress(list)
    for _, t in pairs(list) do
      if t and t.undressed and t.node and t.node.valid then
        local u = t.undressed
        t.undressed = nil
        dress_params(t.node, w, u[1], u[2], u[3], u[4])
      end
      for _, f in ipairs(t and t.falls or {}) do
        if f.undressed and f.node and f.node.valid then f.undressed = nil; fall_params(f.node, w, f) end
      end
    end
  end
  redress(water.lakes)
  redress(water.plakes)
  redress(water.rivers)
  -- Engine water for what the eye is near.
  local function near_vols(t)
    if t and t.vspec then
      local d = len(ex - b.x - t.vx, ey - b.y - t.vy, ez - b.z - t.vz) - t.vr
      if d < VOL_NEAR then vols_on(t) elseif d > VOL_FAR then vols_off(t) end
    end
  end
  for _, l in pairs(water.lakes) do near_vols(l) end
  for _, p in pairs(water.plakes) do near_vols(p) end
  for _, r in pairs(water.rivers) do near_vols(r) end
  -- Rivers: the stretch of each river near the eye, in pieces of 24 points.
  for ri, rv in ipairs(h.rivers or {}) do
    if rv.river then
      local n = math.floor(#rv.points / 3)
      for i0 = 1, n - 1, 23 do
        local i1 = math.min(n, i0 + 23)
        local k = ri * 10000 + i0
        local mx, my, mz = rv.points[i0 * 3 - 2], rv.points[i0 * 3 - 1], rv.points[i0 * 3]
        local d = len(ex - b.x - mx, ey - b.y - my, ez - b.z - mz)
        local have = water.rivers[k]
        if have == nil and d < RIVER_NEAR and not built then
          water.rivers[k] = false
          local bb = { x = b.x, y = b.y, z = b.z, node = b.node, name = b.name }
          start_build("river " .. k, function() return build_river(bb, w, rv, i0, i1) end,
            function(r) if water.rivers[k] == false then water.rivers[k] = r elseif r then free(r) end end)
          built = true
        elseif have and d > RIVER_NEAR * 1.6 then
          free(have)
          water.rivers[k] = nil
        end
      end
    end
  end
end

-- ════════════════════════════════════════════════════════════════════════════
-- RARE NICHES — where a world's rare plants and ore pockets are.
-- ════════════════════════════════════════════════════════════════════════════
--
-- A rare plant is rare because of WHERE it grows: in the dark under a rock
-- shelf, on the highest ground above the snow line, on the floor of a ravine,
-- at a lake's edge, on a riverbank. This finds those places on the real
-- ground, from the terrain's own distance field (`sdf`, body-relative: a
-- wrapper round terrain.query) and the world's rivers, ravines and lakes
-- (`hydro`), and picks a handful of each. Rare ore pockets are the same pass:
-- a few spots 7–14 m down in solid rock.
--
-- It is its own seeded pass. It reads the generated ground and the world
-- record and rolls its own stream (`rare_rng`, salted off the world seed), so
-- the generator's random streams — and so every world already in a save —
-- are untouched. Pure Lua with the field handed in, so the smoke harness runs
-- it against an analytic planet.
--
--     local sc = cl.rareScan(w, hydro, sdf)    -- sdf(rx, ry, rz) → metres | nil
--     sc.step(2000)   → "running" | "done" | "fail"   (2000 field reads a call)
--     sc.result       → { v, seed, plants = { {niche, x, y, z, s} }, ores = { {x, y, z, d, r} } }
--
-- "fail" means the field did not answer where the world says ground is (not
-- generated yet, or still streaming in): ask again later. The caller keeps the
-- answer (flora_field stores it in the save), so a hole dug later never moves
-- a plant.

RARE_NICHES = { "cave", "peak", "ravine", "lake", "river" }
RARE_SCAN_V = 1

local function rare_rng(seed)
  local s = math.floor(seed or 1) % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function()
    s = (s * 48271) % 2147483647
    return s / 2147483647
  end
end

local function rare_hash(a, b)
  local h = (math.floor(a or 0) % 2147483647) * 16807 + math.floor(b or 0) * 48271 + 11
  return (h % 2147483647) / 2147483647
end

-- Rotate (x,y,z) by yaw a, pitch b (a fixed per-world twist of the grid).
local function rare_rot(x, y, z, ca, sa, cb, sb)
  local x1, z1 = x * ca - z * sa, x * sa + z * ca
  local y2, z2 = y * cb - z1 * sb, y * sb + z1 * cb
  return x1, y2, z2
end

local function tangent_of(ux, uy, uz)
  local ax, ay, az = 0, 1, 0
  if math.abs(uy) > 0.9 then ax, ay, az = 1, 0, 0 end
  local tx, ty, tz = uy * az - uz * ay, uz * ax - ux * az, ux * ay - uy * ax
  local l = len(tx, ty, tz)
  tx, ty, tz = tx / l, ty / l, tz / l
  return tx, ty, tz, uy * tz - uz * ty, uz * tx - ux * tz, ux * ty - uy * tx
end

-- The niche rules as numbers, for the probes and the harness.
RARE_RULES = {
  grid = 38,          -- metres between grid samples
  peakQ = 0.965,      -- a peak is above this share of the world's ground…
  peakRel = 0.6,      -- …and this share of the way from the middle to the top
  peakSlope = 0.9,    -- …and not a cliff (rise over run across 5 m)
  ravineWall = 3.0,   -- a ravine floor has walls at least this high on both sides
  ravineDeep = 5.0,   -- …and this high on one
  shoreMin = 0.15,    -- a lake shore is this far above the water…
  shoreMax = 2.5,     -- …and no further
  bankMin = 0.4,      -- a riverbank stands this far above the bed…
  bankMax = 6.0,
  voidMin = 2.0,      -- an overhang shelters a void at least this tall…
  voidDepth = 16,     -- …whose floor is no deeper than this under the ground above
  openReach = 10,     -- a shelter open to the side within this reach is preferred
  sep = { cave = 110, peak = 160, ravine = 140, lake = 120, river = 140 },
  keep = { cave = 3, peak = 3, ravine = 3, lake = 3, river = 3 },
  ores = 6, oreSep = 160, oreR = 2.5,
}

-- ── THE HOME WORLD'S GUARANTEE ──────────────────────────────────────────────
--
-- The programme's Rare Finds are campaign goals, so the HOME world (the save's
-- first planet) must have every niche: at least RARE_HOME_KEEP plants in each
-- and RARE_HOME_ORES geode pockets. After the home world's scan, a second pass
-- (`rareScan` with the relaxed rules below, `have` = what the first found,
-- `fallback` = true) tops each niche up:
--
--   1. the same niches, judged less strictly (RARE_RELAXED);
--   2. FORCED placements in the best place the world has for that niche: a
--      grotto dug into a ravine wall or a cliff foot for a cave plant (only
--      where terrain edits are allowed, `dig`: a new save's world), else the
--      foot of the highest wall; the highest dry ground for a peak; the lowest
--      cut between walls for a ravine; a lake shore, else the sea's, else a
--      riverbank, else the lowest dry ground for a lake or river plant;
--   3. pockets anywhere 7–20 m down in rock for the geodes.
--
-- Nothing already placed moves: the pass only appends, so an old save's
-- plants keep their keys (a cut plant stays cut) and its terrain is only
-- edited when `dig` is given. The answer is marked `home = RARE_HOME_V`.
RARE_HOME_V = 1
RARE_HOME_KEEP = 3
RARE_HOME_ORES = 3
RARE_RELAXED = {
  peakQ = 0.93, peakRel = 0.45, peakSlope = 1.3,
  ravineWall = 1.6, ravineDeep = 2.5,
  shoreMin = 0.05, shoreMax = 4.5,
  bankMin = 0.15, bankMax = 10,
  voidMin = 1.3, voidDepth = 24,
  sep = { cave = 70, peak = 90, ravine = 80, lake = 70, river = 80 },
  keep = { cave = RARE_HOME_KEEP, peak = RARE_HOME_KEEP, ravine = RARE_HOME_KEEP,
           lake = RARE_HOME_KEEP, river = RARE_HOME_KEEP },
  ores = RARE_HOME_ORES + 3, oreSep = 100, oreWet = true,
}

-- The save's home world: its own system's first planet (the generator's
-- roster), else the base's world.
function homeWorldName()
  local h = save and save.get and save.get("system.home")
  local b1 = type(h) == "table" and type(h.bodies) == "table" and h.bodies[1]
  if type(b1) == "table" and type(b1.name) == "string" then return b1.name end
  local b = save and save.get and save.get("base.body")
  if type(b) == "string" then return b end
  return nil
end

function rareScan(w, hydro, sdf, opts)
  opts = opts or {}
  local RR = RARE_RULES
  if opts.rules then
    RR = {}
    for k, v in pairs(RARE_RULES) do RR[k] = v end
    for k, v in pairs(opts.rules) do RR[k] = v end
  end
  -- A zone nothing is placed in (the base: { x, y, z body-relative, r }).
  local avoid = opts.avoid
  local function avoided(x, y, z)
    if not avoid then return false end
    return len(x - avoid.x, y - avoid.y, z - avoid.z) < (avoid.r or 200)
  end
  local R = w.radius or 100
  local shape = w.shape or {}
  local top = R + (shape.peak or (w.relief or R * 0.06) * 3) + 12
  local bottom = R - (shape.low or (w.relief or R * 0.06) * 2) - 30
  local sea = w.sea or 0
  local seed = math.floor(w.seed or 1)
  local budget, used = 0, 0
  local co
  local sc = { result = nil, reads = 0, status = "running" }

  -- Every field read goes through here, and the coroutine yields once the
  -- call's budget is spent.
  local function q(x, y, z)
    used = used + 1
    sc.reads = sc.reads + 1
    if used >= budget and co then coroutine.yield("running") end
    return sdf(x, y, z)
  end

  -- Ground radius along unit (ux,uy,uz), marched down from `from`. The first
  -- surface met from above: on an overhang that is its roof.
  local function ground(ux, uy, uz, from)
    local r = from or top
    for _ = 1, 160 do
      local d = q(ux * r, uy * r, uz * r)
      if not d then return nil, "cold" end
      if d < 0.12 then
        if d < -0.5 and r >= top - 0.01 then return nil, "buried" end
        return r - math.max(d, 0)
      end
      r = r - math.max(d * 0.9, 0.08)
      if r < bottom then return nil, "deep" end
    end
    return nil, "slow"
  end
  -- Starting close above a known nearby height, falling back to the top.
  local function ground_near(ux, uy, uz, near)
    if near then
      local from = near + 14
      local d = q(ux * from, uy * from, uz * from)
      if d and d > 0.12 then return ground(ux, uy, uz, from) end
    end
    return ground(ux, uy, uz, top)
  end

  local lakes = (hydro and hydro.lakes) or {}
  local function in_water(ux, uy, uz, g)
    if sea > 0 and g < sea + 0.3 then return true end
    for _, L in ipairs(lakes) do
      local ll = len(L.x, L.y, L.z)
      local c = (L.x * ux + L.y * uy + L.z * uz) / ll
      local d = math.acos(math.max(-1, math.min(1, c))) * R
      if d < L.reach * 1.1 and g < R + L.level + 0.1 then return true end
    end
    return false
  end

  -- How steep the ground is round a grid point: rise over run, 5 m out.
  local function slope_at(ux, uy, uz, g)
    local t1x, t1y, t1z, t2x, t2y, t2z = tangent_of(ux, uy, uz)
    local worst = 0
    for k = 1, 2 do
      local tx, ty, tz = (k == 1) and t1x or t2x, (k == 1) and t1y or t2y, (k == 1) and t1z or t2z
      local px, py, pz = ux * g + tx * 5, uy * g + ty * 5, uz * g + tz * 5
      local pl = len(px, py, pz)
      local g2 = ground_near(px / pl, py / pl, pz / pl, g)
      if not g2 then return nil end
      worst = math.max(worst, math.abs(g2 - g) / 5)
    end
    return worst
  end

  -- A void under the surface met from above: the floor of an overhang's
  -- shelter or a cave mouth. → floor radius, void height
  local function void_under(ux, uy, uz, g)
    local r = g - 0.9
    local inrock, top_of_void = true, nil
    for _ = 1, math.floor(RR.voidDepth / 0.9) do
      local d = q(ux * r, uy * r, uz * r)
      if not d then return nil end
      if inrock and d > 0.15 then
        inrock, top_of_void = false, r
      elseif not inrock and d < 0.1 then
        -- Back up onto the floor itself: the step went a little into it.
        for _ = 1, 6 do
          if d < -0.05 then r = r - d
          elseif d > 0.12 then r = r - d * 0.9
          else break end
          d = q(ux * r, uy * r, uz * r)
          if not d then return nil end
        end
        local h = top_of_void - r
        if h >= RR.voidMin then return r - math.max(d, 0), h, g - top_of_void end
        inrock, top_of_void = true, nil
      end
      r = r - 0.9
    end
    return nil
  end

  -- From the middle of a void, can you walk out sideways? Six directions,
  -- air all the way out to `openReach`.
  local function shelter_open(ux, uy, uz, fl, h)
    local t1x, t1y, t1z, t2x, t2y, t2z = tangent_of(ux, uy, uz)
    local rm = fl + math.min(h * 0.5, 1.2)
    for k = 0, 5 do
      local a = k * math.pi / 3
      local dx = t1x * math.cos(a) + t2x * math.sin(a)
      local dy = t1y * math.cos(a) + t2y * math.sin(a)
      local dz = t1z * math.cos(a) + t2z * math.sin(a)
      local clear = true
      for st = 1, 4 do
        local f = RR.openReach * st / 4
        local d = q(ux * rm + dx * f, uy * rm + dy * f, uz * rm + dz * f)
        if not d or d < 0.2 then clear = false break end
      end
      if clear then return true end
    end
    return false
  end

  local cands = { cave = {}, peak = {}, ravine = {}, lake = {}, river = {} }
  -- Everything the channel and lake passes looked at, kept for the forced
  -- placements (`fallback`): ravine floors, riverbank and lake-shore samples.
  local floors, banks, shores = {}, {}, {}
  local function add(niche, ux, uy, uz, g, score, extra)
    if avoided(ux * g, uy * g, uz * g) then return end
    local c = { niche = niche, x = ux * g, y = uy * g, z = uz * g, s = score }
    if extra then for k, v in pairs(extra) do c[k] = v end end
    cands[niche][#cands[niche] + 1] = c
  end

  local function run()
    -- 1. THE GRID: a Fibonacci sphere, twisted per world.
    local rnd = rare_rng(seed * 7 + 90917)
    local a, b = rnd() * math.pi * 2, rnd() * math.pi
    local ca, sa, cb, sb = math.cos(a), math.sin(a), math.cos(b), math.sin(b)
    local N = math.floor(4 * math.pi * R * R / (RR.grid * RR.grid))
    N = math.max(400, math.min(opts.maxGrid or 9000, N))
    local grid = {}
    local ga = math.pi * (3 - math.sqrt(5))
    local hasOver = (not w.shape) or (shape.layers and shape.layers.overhangs) or opts.caves
    for i = 0, N - 1 do
      local y = 1 - (i + 0.5) / N * 2
      local rr = math.sqrt(math.max(0, 1 - y * y))
      local th = ga * i
      local ux, uy, uz = rare_rot(math.cos(th) * rr, y, math.sin(th) * rr, ca, sa, cb, sb)
      local g, why = ground(ux, uy, uz, top)
      if not g then
        -- A world's ground has to be everywhere: a hole in it is a field
        -- that is not all here yet.
        sc.why = why
        return "fail"
      end
      grid[#grid + 1] = { ux, uy, uz, g }
      if hasOver then
        -- Shelters are small: the grid point and two more round it, so the
        -- search is about twice as fine as the grid.
        local t1x, t1y, t1z, t2x, t2y, t2z = tangent_of(ux, uy, uz)
        local off = RR.grid * 0.34
        for k = 0, 2 do
          local vx, vy, vz = ux, uy, uz
          if k > 0 then
            local a = (k == 1) and 0.5 or 3.6
            local px = ux * g + (t1x * math.cos(a) + t2x * math.sin(a)) * off
            local py = uy * g + (t1y * math.cos(a) + t2y * math.sin(a)) * off
            local pz = uz * g + (t1z * math.cos(a) + t2z * math.sin(a)) * off
            vx, vy, vz = px / len(px, py, pz), py / len(px, py, pz), pz / len(px, py, pz)
          end
          local gk = (k == 0) and g or ground_near(vx, vy, vz, g)
          local fl, h, roof = nil, nil, nil
          if gk then fl, h, roof = void_under(vx, vy, vz, gk) end
          if fl and not in_water(vx, vy, vz, fl) then
            -- Open to the side (a shelter you can walk into) beats a sealed
            -- hollow you have to dig to; a thin roof beats a thick one.
            local open = shelter_open(vx, vy, vz, fl, h)
            add("cave", vx, vy, vz, fl, (open and 20 or 0) + h - roof * 0.3 + rare_hash(seed, i * 3 + k) * 0.01,
                { h = h, open = open })
          end
        end
      end
    end
    sc.grid = #grid

    -- 2. PEAKS: the highest ground, above the snow line where the world has
    -- one, and not a cliff face.
    local hs = {}
    for i, p in ipairs(grid) do hs[i] = p[4] end
    table.sort(hs)
    -- The altitude line: the top few percent of the ground, and high above
    -- the world's middle — on a world of rolling hills and one range, only
    -- the range.
    local line = hs[math.max(1, math.floor(#hs * RR.peakQ))]
    local mid = hs[math.max(1, math.floor(#hs * 0.5))]
    line = math.max(line, mid + (hs[#hs] - mid) * RR.peakRel)
    if shape.snowline and R + shape.snowline > line and R + shape.snowline < hs[#hs] - 2 then
      line = R + shape.snowline
    end
    sc.peakLine = line - R
    for i, p in ipairs(grid) do
      if p[4] >= line and not in_water(p[1], p[2], p[3], p[4]) then
        local sl = slope_at(p[1], p[2], p[3], p[4])
        if sl and sl <= RR.peakSlope then
          add("peak", p[1], p[2], p[3], p[4], (p[4] - line) + rare_hash(seed, i + 7) * 0.01, { slope = sl })
        end
      end
    end

    -- 3. CHANNELS: ravine floors and riverbanks, along the carved channels.
    for ci, ch in ipairs((hydro and hydro.rivers) or {}) do
      local pts, wid = ch.points or {}, ch.widths or {}
      local n = math.floor(#pts / 3)
      local acc, last = 0, nil
      for i = 1, n - 1 do
        local ax, ay, az = pts[i * 3 - 2], pts[i * 3 - 1], pts[i * 3]
        local bx, by, bz = pts[i * 3 + 1], pts[i * 3 + 2], pts[i * 3 + 3]
        local seg = len(bx - ax, by - ay, bz - az)
        acc = acc + seg
        if not last or acc - last >= (ch.river and 22 or 16) then
          last = acc
          local al = len(ax, ay, az)
          local ux, uy, uz = ax / al, ay / al, az / al
          -- Across the channel: the segment's direction × up.
          local dx, dy, dz = bx - ax, by - ay, bz - az
          local px, py, pz = dy * uz - dz * uy, dz * ux - dx * uz, dx * uy - dy * ux
          local pl = len(px, py, pz)
          if pl > 1e-6 then
            px, py, pz = px / pl, py / pl, pz / pl
            local half = (wid[i] or 10) * 0.5
            local gc = ground(ux, uy, uz, top)
            if gc then
              local function side(k, off)
                local sx, sy, sz = ux * gc + px * off * k, uy * gc + py * off * k, uz * gc + pz * off * k
                local sl = len(sx, sy, sz)
                local g = ground_near(sx / sl, sy / sl, sz / sl, gc + 30)
                return g, sx / sl, sy / sl, sz / sl
              end
              if not ch.river then
                local gl = side(1, half + 8)
                local gr = side(-1, half + 8)
                if gl and gr and not in_water(ux, uy, uz, gc) then
                  local lo, hi = math.min(gl, gr) - gc, math.max(gl, gr) - gc
                  floors[#floors + 1] = { ux = ux, uy = uy, uz = uz, g = gc, px = px, py = py, pz = pz,
                    half = half, lo = lo, hi = hi, k = (gl >= gr) and 1 or -1, ch = ci, i = i }
                  if lo >= RR.ravineWall and hi >= RR.ravineDeep then
                    add("ravine", ux, uy, uz, gc, lo + rare_hash(ci * 1000 + i, seed) * 0.01,
                        { depth = lo, ch = ci })
                  end
                end
              else
                for _, k in ipairs({ 1, -1 }) do
                  local gb, bx_, by_, bz_ = side(k, half + 2.5)
                  if gb then
                    local rise = gb - gc
                    local go = side(k, half + 6.5)
                    if not in_water(bx_, by_, bz_, gb) then
                      banks[#banks + 1] = { ux = bx_, uy = by_, uz = bz_, g = gb, rise = rise,
                        flat = go and math.abs(go - gb) or 99, ch = ci, i = i, k = k }
                    end
                    if rise >= RR.bankMin and rise <= RR.bankMax and go and math.abs(go - gb) < 3
                       and not in_water(bx_, by_, bz_, gb) then
                      add("river", bx_, by_, bz_, gb, 3 - math.abs(rise - 1.2) + rare_hash(ci * 1000 + i, seed + k) * 0.01,
                          { rise = rise, ch = ci })
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    -- 4. LAKE SHORES: round each lake, just above its water.
    for li, L in ipairs(lakes) do
      local ll = len(L.x, L.y, L.z)
      local ux, uy, uz = L.x / ll, L.y / ll, L.z / ll
      local t1x, t1y, t1z, t2x, t2y, t2z = tangent_of(ux, uy, uz)
      local level = R + L.level
      for k = 0, 23 do
        local ang = k * math.pi / 12
        local found = false
        for _, f in ipairs({ 0.85, 1.0, 1.15, 1.3, 1.5 }) do
          if found then break end
          local d = L.reach * f
          local cx = ux * R + (t1x * math.cos(ang) + t2x * math.sin(ang)) * d
          local cy = uy * R + (t1y * math.cos(ang) + t2y * math.sin(ang)) * d
          local cz = uz * R + (t1z * math.cos(ang) + t2z * math.sin(ang)) * d
          local cl_ = len(cx, cy, cz)
          local vx, vy, vz = cx / cl_, cy / cl_, cz / cl_
          local g = ground_near(vx, vy, vz, level)
          if g then
            local above = g - level
            if above >= -0.05 and above <= 8 and not (sea > 0 and g < sea + 0.3) then
              shores[#shores + 1] = { ux = vx, uy = vy, uz = vz, g = g, above = above, lake = li, k = k }
            end
            if above >= RR.shoreMin and above <= RR.shoreMax and not (sea > 0 and g < sea + 0.3) then
              found = true
              add("lake", vx, vy, vz, g, 3 - math.abs(above - 0.6) + rare_hash(li * 100 + k, seed) * 0.01,
                  { above = above, lake = li })
            end
          end
        end
      end
    end

    -- 5. PICK a handful of each, spread out. A top-up pass (`have`) counts
    -- what is already placed and keeps clear of it; only new ones are added.
    local have = opts.have or {}
    local plants = {}
    local kept_by = {}
    local function far_from(list, x, y, z, sep)
      for _, k in ipairs(list) do
        if len(x - k.x, y - k.y, z - k.z) < sep then return false end
      end
      return true
    end
    for _, niche in ipairs(RARE_NICHES) do
      local list = cands[niche]
      table.sort(list, function(p, q2)
        if p.s ~= q2.s then return p.s > q2.s end
        return (p.x + p.y * 3 + p.z * 7) < (q2.x + q2.y * 3 + q2.z * 7)
      end)
      local kept = {}
      for _, p in ipairs(have.plants or {}) do
        if p.niche == niche then kept[#kept + 1] = { x = p.x, y = p.y, z = p.z, old = true } end
      end
      local sep = RR.sep[niche]
      for _, c in ipairs(list) do
        if #kept >= RR.keep[niche] then break end
        if far_from(kept, c.x, c.y, c.z, sep) then kept[#kept + 1] = c end
      end
      sc[niche] = #list
      kept_by[niche] = kept
      for _, c in ipairs(kept) do
        if not c.old then plants[#plants + 1] = { niche = niche, x = c.x, y = c.y, z = c.z, s = c.s } end
      end
    end

    -- 5b. FORCED placements (`fallback`): what a niche still lacks, in the
    -- best place this world has for it. See RARE_HOME_V.
    if opts.fallback then
      sc.forced = {}
      local function dry_ok(ux, uy, uz, g)
        return g and not in_water(ux, uy, uz, g) and not avoided(ux * g, uy * g, uz * g)
      end
      local function force(niche, list, sep, how)
        local kept = kept_by[niche]
        for _, c in ipairs(list) do
          if #kept >= RR.keep[niche] then break end
          local x, y, z = c.ux * c.g, c.uy * c.g, c.uz * c.g
          -- Apart from its own niche's plants, and from every other plant
          -- too (two forced niches can fall back to the same ground).
          if dry_ok(c.ux, c.uy, c.uz, c.g) and far_from(kept, x, y, z, sep)
             and far_from(plants, x, y, z, 30) and far_from(have.plants or {}, x, y, z, 30) then
            local pl = { niche = niche, x = x, y = y, z = z, s = c.s or 0, forced = c.how or how }
            kept[#kept + 1] = pl
            plants[#plants + 1] = pl
            sc.forced[#sc.forced + 1] = niche .. ":" .. (c.how or how)
          end
        end
      end
      local function by(list, key, desc)
        table.sort(list, function(a, b)
          local x, y = a[key] or 0, b[key] or 0
          if x ~= y then if desc then return x > y end return x < y end
          return (a.ux + a.uy * 3 + a.uz * 7) < (b.ux + b.uy * 3 + b.uz * 7)
        end)
        return list
      end
      local function short(niche) return #kept_by[niche] < RR.keep[niche] end
      -- The grid as fallback candidates: highest, lowest, nearest the sea.
      local function grid_list(score)
        local out = {}
        for i, p in ipairs(grid) do
          local s = score(p, i)
          if s then out[#out + 1] = { ux = p[1], uy = p[2], uz = p[3], g = p[4], s = s } end
        end
        return by(out, "s", true)
      end
      -- (the whole grid sorted with a Lua comparator: ~7,000 points, 10-15 ms
      -- a time, and the niches below asked for it up to four times in one
      -- resume — a 36 ms frame on the home world's first load. Sorted once.)
      local lowest_list = nil
      local function lowest()
        if not lowest_list then lowest_list = grid_list(function(p) return -p[4] end) end
        return lowest_list
      end
      -- Between the forced niches, give the frame back (the scan is a
      -- coroutine; a yield here is the same as one at a field read).
      local function breathe() if co then coroutine.yield("running") end end
      local function coast()
        if sea <= 0 then return {} end
        return grid_list(function(p)
          local a = p[4] - sea
          if a > 0.2 and a < 6 then return -a end
        end)
      end
      local function shore_list()
        local out = {}
        for _, c in ipairs(shores) do
          out[#out + 1] = { ux = c.ux, uy = c.uy, uz = c.uz, g = c.g, s = -math.abs(c.above - 0.6) }
        end
        return by(out, "s", true)
      end
      local function bank_list()
        local out = {}
        for _, c in ipairs(banks) do
          if c.rise > -0.2 and c.rise < 14 then
            out[#out + 1] = { ux = c.ux, uy = c.uy, uz = c.uz, g = c.g, s = -math.abs(c.rise - 1.2) - c.flat * 0.2 }
          end
        end
        return by(out, "s", true)
      end
      -- Walk across a ravine floor at knee height to its wall: the wall's
      -- face, the direction into it, and how high the rock stands over it.
      local function wall_of(f)
        local k = f.k
        local hr = f.g + 2.0
        local bx, by_, bz = f.ux * hr, f.uy * hr, f.uz * hr
        local ax, ay, az = f.px * k, f.py * k, f.pz * k
        for st = 0, math.ceil(f.half + 14) do
          local d = q(bx + ax * st, by_ + ay * st, bz + az * st)
          if not d then return nil end
          if d < 0.15 then
            local wx, wy, wz = bx + ax * st, by_ + ay * st, bz + az * st
            local wl = len(wx, wy, wz)
            local tg = ground(wx / wl, wy / wl, wz / wl, top)
            return wx, wy, wz, ax, ay, az, tg and (tg - f.g) or 0, st
          end
        end
        return nil
      end
      -- CAVES. Dig a grotto into a wall where edits are allowed; else the
      -- foot of the highest wall.
      if short("cave") then
        local walls = {}
        local fl = by(floors, "hi", true)
        for n = 1, math.min(#fl, 80) do
          local f = fl[n]
          if f.hi >= 4 and dry_ok(f.ux, f.uy, f.uz, f.g) then
            -- Both walls: the higher first.
            for _, side in ipairs({ f.k, -f.k }) do
              local fs = { ux = f.ux, uy = f.uy, uz = f.uz, g = f.g, px = f.px, py = f.py, pz = f.pz,
                           half = f.half, hi = f.hi, k = side }
              local wx, wy, wz, ax, ay, az, over, st = wall_of(fs)
              if wx and over >= 6 then
                walls[#walls + 1] = { f = fs, wx = wx, wy = wy, wz = wz, ax = ax, ay = ay, az = az, over = over, st = st }
              end
            end
          end
        end
        -- Steep ground off the grid (cliffs), when there are few ravines.
        if #walls < 12 then
          local tried = 0
          for _, i in ipairs(grid_list(function(p) return rare_hash(seed + 17, math.floor(p[4] * 10)) end)) do
            if tried > 220 or #walls >= 12 then break end
            tried = tried + 1
            if dry_ok(i.ux, i.uy, i.uz, i.g) then
              local t1x, t1y, t1z, t2x, t2y, t2z = tangent_of(i.ux, i.uy, i.uz)
              local lowg, lowd = i.g, nil
              for kk = 0, 5 do
                local a = kk * math.pi / 3
                local dx = t1x * math.cos(a) + t2x * math.sin(a)
                local dy = t1y * math.cos(a) + t2y * math.sin(a)
                local dz = t1z * math.cos(a) + t2z * math.sin(a)
                local px_, py_, pz_ = i.ux * i.g + dx * 8, i.uy * i.g + dy * 8, i.uz * i.g + dz * 8
                local pl = len(px_, py_, pz_)
                local g2 = ground_near(px_ / pl, py_ / pl, pz_ / pl, i.g)
                if g2 and g2 < lowg - 5 then lowg, lowd = g2, { px_ / pl, py_ / pl, pz_ / pl, -dx, -dy, -dz } end
              end
              if lowd then
                -- A foot 8 m downhill, the wall back toward the grid point.
                local f = { ux = lowd[1], uy = lowd[2], uz = lowd[3], g = lowg, px = lowd[4], py = lowd[5], pz = lowd[6],
                            k = 1, half = 0, hi = i.g - lowg }
                local wx, wy, wz, ax, ay, az, over, st = wall_of(f)
                if wx and over >= 6 and dry_ok(f.ux, f.uy, f.uz, f.g) then
                  walls[#walls + 1] = { f = f, wx = wx, wy = wy, wz = wz, ax = ax, ay = ay, az = az, over = over, st = st }
                end
              end
            end
          end
        end
        table.sort(walls, function(a, b)
          if a.over ~= b.over then return a.over > b.over end
          return a.f.ux < b.f.ux
        end)
        local kept = kept_by.cave
        for _, wl in ipairs(walls) do
          if #kept >= RR.keep.cave then break end
          local f = wl.f
          local fx, fy, fz = f.ux * f.g, f.uy * f.g, f.uz * f.g
          if far_from(kept, wl.wx, wl.wy, wl.wz, RR.sep.cave) and far_from(plants, wl.wx, wl.wy, wl.wz, 30)
             and far_from(have.plants or {}, wl.wx, wl.wy, wl.wz, 30) then
            if opts.dig then
              -- The grotto: two bites into the wall at knee-to-head height,
              -- the inner one bigger, so a shelter opens off the floor with
              -- rock over it.
              local function at(d) return wl.wx + wl.ax * d, wl.wy + wl.ay * d, wl.wz + wl.az * d end
              local x1, y1, z1 = at(0.8)
              local x2, y2, z2 = at(3.2)
              opts.dig(x1, y1, z1, 2.2)
              opts.dig(x2, y2, z2, 2.6)
              -- Let the edits land (a few frames when the caller says what
              -- time it is) before reading the field again.
              sc.hold = opts.now and (opts.now() + 0.2) or nil
              coroutine.yield("running")
              -- The floor under the inner bite, and the roof over it.
              local cl_ = len(x2, y2, z2)
              local ux, uy, uz = x2 / cl_, y2 / cl_, z2 / cl_
              local r = cl_
              local floor_r = nil
              for _ = 1, 40 do
                local d = q(ux * r, uy * r, uz * r)
                if not d then break end
                if d < 0.12 then floor_r = r - math.max(d, 0) break end
                r = r - math.max(d * 0.9, 0.08)
              end
              local roof = q(ux * (cl_ + 3.5), uy * (cl_ + 3.5), uz * (cl_ + 3.5))
              if floor_r and roof and roof < 0.2 then
                local pl = { niche = "cave", x = ux * floor_r, y = uy * floor_r, z = uz * floor_r, s = wl.over,
                             forced = "grotto" }
                kept[#kept + 1] = pl
                plants[#plants + 1] = pl
                sc.forced[#sc.forced + 1] = "cave:grotto"
                sc.dug = (sc.dug or 0) + 1
              end
            else
              -- No edits: the foot of the wall, a step out from it.
              local px_, py_, pz_ = wl.wx - wl.ax * 1.3, wl.wy - wl.ay * 1.3, wl.wz - wl.az * 1.3
              local pl_ = len(px_, py_, pz_)
              local g = ground_near(px_ / pl_, py_ / pl_, pz_ / pl_, f.g)
              if g and dry_ok(px_ / pl_, py_ / pl_, pz_ / pl_, g) then
                local pl = { niche = "cave", x = px_ / pl_ * g, y = py_ / pl_ * g, z = pz_ / pl_ * g, s = wl.over,
                             forced = "wallfoot" }
                kept[#kept + 1] = pl
                plants[#plants + 1] = pl
                sc.forced[#sc.forced + 1] = "cave:wallfoot"
              end
            end
          end
        end
        -- A world with no wall anywhere: its lowest dry ground.
        if short("cave") then force("cave", lowest(), RR.sep.cave, "lowland") end
      end
      if short("peak") then force("peak", grid_list(function(p) return p[4] end), RR.sep.peak, "highest"); breathe() end
      if short("ravine") then
        local fl = {}
        for _, f in ipairs(floors) do
          if f.lo >= 0.8 then fl[#fl + 1] = { ux = f.ux, uy = f.uy, uz = f.uz, g = f.g, s = f.lo, how = "shallow" } end
        end
        force("ravine", by(fl, "s", true), RR.sep.ravine, "shallow")
        if short("ravine") then
          -- Gullies: the grid's lowest points with ground standing up round
          -- them.
          local gl = {}
          local low = lowest()
          for n = 1, math.min(#low, 300) do
            local c = low[n]
            if dry_ok(c.ux, c.uy, c.uz, c.g) then
              local t1x, t1y, t1z, t2x, t2y, t2z = tangent_of(c.ux, c.uy, c.uz)
              local rim = 0
              for kk = 0, 3 do
                local a = kk * math.pi / 2
                local px_ = c.ux * c.g + (t1x * math.cos(a) + t2x * math.sin(a)) * 15
                local py_ = c.uy * c.g + (t1y * math.cos(a) + t2y * math.sin(a)) * 15
                local pz_ = c.uz * c.g + (t1z * math.cos(a) + t2z * math.sin(a)) * 15
                local pl = len(px_, py_, pz_)
                local g2 = ground_near(px_ / pl, py_ / pl, pz_ / pl, c.g)
                rim = rim + ((g2 or c.g) - c.g) / 4
              end
              if rim > 0.5 then gl[#gl + 1] = { ux = c.ux, uy = c.uy, uz = c.uz, g = c.g, s = rim, how = "gully" } end
            end
          end
          force("ravine", by(gl, "s", true), RR.sep.ravine, "gully")
          breathe()
        end
        if short("ravine") then force("ravine", lowest(), RR.sep.ravine, "lowland") end
        breathe()
      end
      for _, niche in ipairs({ "lake", "river" }) do
        if short(niche) then
          local order = (niche == "lake") and { shore_list, coast, bank_list } or { bank_list, shore_list, coast }
          local names = (niche == "lake") and { "shore", "coast", "bank" } or { "bank", "shore", "coast" }
          for n, fn in ipairs(order) do
            if short(niche) then
              local l = fn()
              for _, c in ipairs(l) do c.how = names[n] end
              force(niche, l, RR.sep[niche] * 0.6, names[n])
              breathe()
            end
          end
          if short(niche) then force(niche, lowest(), RR.sep[niche] * 0.6, "lowland") end
          breathe()
        end
      end
    end

    -- 6. ORE POCKETS: grid points in a seeded order, a pocket some metres
    -- under each, wholly inside rock.
    local order = {}
    for i = 1, #grid do order[i] = i end
    local orng = rare_rng(seed * 13 + 4441)
    for i = #order, 2, -1 do
      local j = math.floor(orng() * i) + 1
      order[i], order[j] = order[j], order[i]
    end
    local ores = {}
    local olds = {}
    for _, o in ipairs(have.ores or {}) do olds[#olds + 1] = { x = o.x, y = o.y, z = o.z } end
    local want = RR.ores
    local function pocket_try(i, depth, wet_ok, sep)
      local p = grid[i]
      local rc = p[4] - depth
      local cx, cy, cz = p[1] * rc, p[2] * rc, p[3] * rc
      local ok = (wet_ok or not in_water(p[1], p[2], p[3], p[4])) and not avoided(p[1] * p[4], p[2] * p[4], p[3] * p[4])
      for _, o in ipairs(ores) do
        if ok and len(cx - o.x, cy - o.y, cz - o.z) < sep then ok = false end
      end
      for _, o in ipairs(olds) do
        if ok and len(cx - o.x, cy - o.y, cz - o.z) < sep then ok = false end
      end
      if ok then
        local d0 = q(cx, cy, cz)
        ok = d0 ~= nil and d0 <= -1.0
        local r = RR.oreR
        local offs = { { r, 0, 0 }, { -r, 0, 0 }, { 0, r, 0 }, { 0, -r, 0 }, { 0, 0, r }, { 0, 0, -r } }
        for _, o in ipairs(offs) do
          if ok then
            local d = q(cx + o[1], cy + o[2], cz + o[3])
            ok = d ~= nil and d <= -0.3
          end
        end
      end
      if ok then ores[#ores + 1] = { x = cx, y = cy, z = cz, d = depth, r = RR.oreR } end
    end
    for _, i in ipairs(order) do
      if #ores + #olds >= want then break end
      pocket_try(i, 7 + rare_hash(seed + 3, i) * 7, RR.oreWet, RR.oreSep)
    end
    -- Forced: deeper, closer together, under water too.
    if opts.fallback then
      local need = math.max(RARE_HOME_ORES, opts.ores or 0)
      for _, i in ipairs(order) do
        if #ores + #olds >= need then break end
        pocket_try(i, 9 + rare_hash(seed + 5, i) * 11, true, RR.oreSep * 0.5)
      end
    end

    local function round(v) return math.floor(v * 100 + 0.5) / 100 end
    for _, p in ipairs(plants) do p.x, p.y, p.z, p.s = round(p.x), round(p.y), round(p.z), round(p.s) end
    for _, o in ipairs(ores) do o.x, o.y, o.z, o.d = round(o.x), round(o.y), round(o.z), round(o.d) end
    sc.result = { v = RARE_SCAN_V, seed = seed, plants = plants, ores = ores }
    return "done"
  end

  co = coroutine.create(run)
  function sc.step(n)
    if sc.status ~= "running" then return sc.status end
    if sc.hold and opts.now and opts.now() < sc.hold then return "running" end
    sc.hold = nil
    budget, used = math.max(50, n or 2000), 0
    local ok, st = coroutine.resume(co)
    if not ok then
      sc.status, sc.why = "fail", tostring(st)
    elseif coroutine.status(co) == "dead" then
      sc.status = st or "done"
    end
    return sc.status
  end
  return sc
end

-- What each niche is called on a card and in a hint.
RARE_NICHE_TEXT = {
  cave = { where = "under an overhang", short = "overhang" },
  peak = { where = "on a high peak", short = "peak" },
  ravine = { where = "on a ravine floor", short = "ravine" },
  lake = { where = "on a lake shore", short = "lake shore" },
  river = { where = "on a riverbank", short = "riverbank" },
}
