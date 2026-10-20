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

function worldOf(name)
  if not name then return nil end
  local w = save.get("world." .. name)
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
-- One rule, used by the swimmer, the splashdown check and the flora scatter:
-- you are underwater when you are inside the sea sphere of the body you're at.

-- How deep below the surface of the sea, in metres. Negative = above it; nil
-- when this body has no sea (or there's no body).
function seaDepth(x, y, z)
  local d = space.dominant(x, y, z)
  if not d then return nil end
  local sea = seaRadius(d)
  local b = space.body(d)
  if not b then return nil end
  local depth = (sea > 0) and (sea - len(x - b.x, y - b.y, z - b.z)) or nil
  -- The sea is a sphere, so a pit dug below sea level from dry land is
  -- "under" it too, and the crew swam in a dry hole. Water only stands where
  -- the sea can reach: ask the ring of the sea's surface 8 m round the point —
  -- open sea is open there, a hole in the land is ringed with rock.
  if depth and depth > 0 and terrain and terrain.query then
    local px, py, pz = x - b.x, y - b.y, z - b.z
    local r = len(px, py, pz)
    local ux, uy, uz = px / r, py / r, pz / r
    local ax, ay, az = 0, 1, 0
    if math.abs(uy) > 0.9 then ax, ay, az = 1, 0, 0 end
    local t1x, t1y, t1z = uy * az - uz * ay, uz * ax - ux * az, ux * ay - uy * ax
    local l = len(t1x, t1y, t1z)
    t1x, t1y, t1z = t1x / l, t1y / l, t1z / l
    local t2x, t2y, t2z = uy * t1z - uz * t1y, uz * t1x - ux * t1z, ux * t1y - uy * t1x
    local open, n = 0, 0
    for k = 0, 7 do
      local a = k * math.pi / 4
      local ox, oy, oz = (t1x * math.cos(a) + t2x * math.sin(a)) * 8, (t1y * math.cos(a) + t2y * math.sin(a)) * 8,
        (t1z * math.cos(a) + t2z * math.sin(a)) * 8
      local q = terrain.query(b.x + ux * sea + ox, b.y + uy * sea + oy, b.z + uz * sea + oz)
      if q then
        n = n + 1
        if q > 0 then open = open + 1 end
      end
    end
    if n > 0 and open * 2 < n then depth = -1 end
  end
  -- A lake (scale 3) is water too, wherever one is standing near you.
  if not depth or depth <= 0 then
    local ld = lakeDepth(d, x, y, z)
    if ld then return ld end
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

local function dress(n, w, kind)
  local river = kind == "river"
  n:setMaterial { color = { 1, 1, 1 }, alpha = 0.999 }
  -- The shader goes on through the material HANDLE (node:material()). This
  -- was `getcomponent("Material")`, which is not a component the engine
  -- exposes: it answered nil, the shader was never set, and every lake and
  -- river drew in the plain white default material — lit by a warm star, a
  -- flat beige or pink sheet (the world-117 contact sheet's s1 and s6).
  local ok, m = pcall(n.material, n)
  if ok and m then m.shader = river and "shaders/river.flsl" or "shaders/ocean.flsl" end
  pcall(function() n.castShadow = false end)
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
  end
end

-- The ground radius under planet-local unit direction d, marched down the
-- distance field from above the peaks (as game_manager's spawn search does: a
-- true distance never steps through ground, and never stops on a cave roof).
-- nil when the field is cold.
local function ground_r(b, dx, dy, dz, top, bottom)
  local r = top
  for _ = 1, 200 do
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
    local p = table.remove(stack)
    nwet = nwet + 1
    for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
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
      for i = 1, N - 2 do
        local k = key(i, j)
        if state[k] ~= 1 then
          local qa = open_qa[k]
          if qa == nil or qa > 0 then
            local wn = 0
            for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
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
      for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
        local kk = key(i + d[1], j + d[2])
        if not state[kk] then state[kk] = 2 end
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
  if VOLUMES and engine_water and engine_water.addVolume then
    local Rv = Rl - 0.12
    local function disc(cx, cy, cz, reach)
      vols[#vols + 1] = { shape = "lake", parent = water.body,
        center = vec3(cx * Rv, cy * Rv, cz * Rv), radius = Rv, reach = reach }
    end
    local function ang(ax, ay, az, bx, by, bz)
      return math.acos(math.max(-1, math.min(1, ax * bx + ay * by + az * bz)))
    end
    -- The whole lake: centred on its water, out to its farthest water cell.
    local sx, sy, sz, nw = 0, 0, 0, 0
    for k, st in pairs(state) do
      if st == 1 then
        local dx, dy, dz = dir(k % N, math.floor(k / N))
        sx, sy, sz, nw = sx + dx, sy + dy, sz + dz, nw + 1
      end
    end
    local l = len(sx, sy, sz)
    local cx, cy, cz = sx / l, sy / l, sz / l
    local far = 0
    for k, st in pairs(state) do
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
      for i = 0, N - 1 do
        if not leak and state[key(i, j)] ~= 1 then
          local dx, dy, dz = dir(i, j)
          if ang(dx, dy, dz, cx, cy, cz) * Rv <= reach then
            local qa = open_qa[key(i, j)]
            if qa == nil then qa = terrain.query(b.x + dx * Rv, b.y + dy * Rv, b.z + dz * Rv) end
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
  local lake = { mesh = name, node = nil, level = L.level, vspec = vols, vx = ux * Rl, vy = uy * Rl, vz = uz * Rl,
    vr = L.reach * 1.2 + 10, Rl = Rl, ux = ux, uy = uy, uz = uz,
    t1 = { t1x, t1y, t1z }, t2 = { t2x, t2y, t2z }, s = s, N = N, off = off, state = state,
    cx = b.x + ux * Rl, cy = b.y + uy * Rl, cz = b.z + uz * Rl, reach = L.reach, wet = nwet,
    provisional = unknown > 0 or (terrain.busy and terrain.busy()) or false, built_t = water.t_total or 0 }
  createNode("Lake", b.node or find(water.body), function(n)
    -- Local (0,0,0) under the body: the mesh is in the planet's own frame.
    -- (This was `n.x, n.y, n.z = b.x, b.y, b.z`, which a child takes as a
    -- LOCAL offset: every lake and river stood a body-position away from its
    -- world — kilometres off, out of sight, or a sheet hanging in the air.)
    n.model = name
    n.tags = { "genbody", "lake" }
    dress(n, w, "lake")
    lake.node = n
  end)
  return lake
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
  local ok, name = pcall(mesh.build, { positions = pos, indices = idx, uvs = uvs })
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
  local river = { mesh = name, vspec = vols, vx = mx, vy = my, vz = mz, vr = vr + 5 }
  createNode("River", b.node or find(water.body), function(n)
    -- Local (0,0,0) under the body: the mesh is in the planet's own frame.
    -- (This was `n.x, n.y, n.z = b.x, b.y, b.z`, which a child takes as a
    -- LOCAL offset: every lake and river stood a body-position away from its
    -- world — kilometres off, out of sight, or a sheet hanging in the air.)
    n.model = name
    n.tags = { "genbody", "river" }
    dress(n, w, "river")
    river.node = n
  end)
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
end

local function clear_water()
  for _, l in pairs(water.lakes) do if l then free(l) end end
  for _, r in pairs(water.rivers) do if r then free(r) end end
  water.lakes, water.rivers, water.hydro, water.body = {}, {}, nil, nil
end

-- Metres below a lake's surface at a WORLD point on body `name`, or nil when
-- the point is in no lake that is standing near the eye.
function lakeDepth(name, x, y, z)
  if name ~= water.body then return nil end
  local b = space.body(name)
  if not b then return nil end
  for _, l in pairs(water.lakes) do
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
          if d > -2 then return d end
        end
      end
    end
  end
  return nil
end

-- The lakes and river water standing near the eye right now (for the HUD and
-- the probes): { lakes = n, rivers = n, volumes = n, body = name } — volumes
-- is how many engine water discs they declared.
function waterNear()
  local nl, nr, nv = 0, 0, 0
  for _, l in pairs(water.lakes) do if l then nl = nl + 1; nv = nv + #(l.vols or {}) end end
  for _, r in pairs(water.rivers) do if r then nr = nr + 1; nv = nv + #(r.vols or {}) end end
  return { lakes = nl, rivers = nr, volumes = nv, body = water.body, stats = water.stats }
end

function update(node, dt)
  water.t = water.t + dt
  water.t_total = (water.t_total or 0) + dt
  if water.t < 0.5 then return end
  water.t = 0
  if not (mesh and mesh.build and terrain and terrain.query) then return end
  local ex, ey, ez = eye()
  if not ex then return end
  local name = space.dominant(ex, ey, ez)
  if name ~= water.body then clear_water(); water.body = name end
  if not name then return end
  local w = worldOf(name)
  if not (w and w.hydro and w.shape) then return end
  local b = space.body(name)
  if not b then return end
  local alt = len(ex - b.x, ey - b.y, ez - b.z) - w.radius
  if alt > w.radius * 1.5 then clear_water(); water.body = name; return end
  -- Only once the ground is here to fit the water to.
  if not terrain.query(b.x, b.y + w.radius, b.z) then return end
  if not water.hydro then
    -- The home world's rivers and lakes are being worked out off the script
    -- thread (system_generator hydroWarm): wait for them rather than asking
    -- the same question again on this one.
    if not (gen_ref and gen_ref.valid) then gen_ref = findScript and findScript("system_generator") end
    if gen_ref and gen_ref.hydroPending and gen_ref.hydroPending(name) then return end
    water.hydro = hydroOf(name) or { lakes = {}, rivers = {} }
  end
  local h = water.hydro
  b.node = b.node or find(name)
  -- The wind on the water (weather.lua): lakes are sheltered, so they feel
  -- about two thirds of it.
  local wx = findScript and findScript("weather")
  local wc = wx and wx.current and wx.current()
  if wc and wc.body == name then
    local sp = wc.windNow or wc.wind or 0
    local dx, dy, dz = wc.windX or 0, wc.windY or 0, wc.windZ or 1
    for _, l in pairs(water.lakes) do
      if l and l.node and l.node.valid then
        l.node:setShaderParam("windDir", dx, dy, dz)
        l.node:setShaderParam("wind", sp * 0.65)
      end
    end
  end
  -- Lakes: build what came near, give back what fell far. One build a tick.
  local built = false
  for i, L in ipairs(h.lakes or {}) do
    local lx, ly, lz = b.x + L.x, b.y + L.y, b.z + L.z
    local d = len(ex - lx, ey - ly, ez - lz) - L.reach
    local have = water.lakes[i]
    -- A lake built while its ground was still streaming in is built again
    -- once the terrain has settled, so its outline follows the real ground.
    if have and have.provisional and not built and water.t_total - (have.built_t or 0) > 4
        and not (terrain.busy and terrain.busy()) then
      free(have)
      water.lakes[i] = nil
      have = nil
    end
    if have == nil and d < LAKE_NEAR and not built then
      water.lakes[i] = build_lake(b, w, L) or false
      built = true
    elseif have and d > LAKE_FAR then
      free(have)
      water.lakes[i] = nil
    end
  end
  -- Engine water for what the eye is near.
  local function near_vols(t)
    if t and t.vspec then
      local d = len(ex - b.x - t.vx, ey - b.y - t.vy, ez - b.z - t.vz) - t.vr
      if d < VOL_NEAR then vols_on(t) elseif d > VOL_FAR then vols_off(t) end
    end
  end
  for _, l in pairs(water.lakes) do near_vols(l) end
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
          water.rivers[k] = build_river(b, w, rv, i0, i1) or false
          built = true
        elseif have and d > RIVER_NEAR * 1.6 then
          free(have)
          water.rivers[k] = nil
        end
      end
    end
  end
end
