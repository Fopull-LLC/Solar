-- SYSTEM GENERATOR — game-side procgen tooling (NOT an engine feature).
-- Attach to an empty "System Generator" node; the Inspector shows a
-- ▶ Generate button (the --@editorButton below). Clicking it REPLACES the
-- generated bodies in the OPEN scene with a freshly rolled star system:
-- star class, planets (canyon/dune/ice/lava/crystal), moons, orbits,
-- atmospheres, caves, molten cores, names — then queues the heavy terrain
-- fills on the engine's background generator (watch the Console; save the
-- scene once they're in).
--
-- Every knob is a tweakable param below. seed 0 = a new system every click
-- (the rolled seed prints to the Console — put it in the seed param to
-- reproduce). Everything generated lives under ONE "<Star> System" group node
-- (tagged "gensystem"; bodies inside also tagged "genbody"), so regenerating
-- destroys the old system as a single subtree and never touches the rest of
-- the scene — and you can hand-delete a whole system the same way.
--
--@editorButton Generate generate

defaults = {
  seed = 0,          -- 0 = random every click; any number reproduces that system
  planets = 0,       -- 0 = random 2..4
  minOrbit = 60000,  -- first planet's orbit radius
  spacing = 2.2,     -- orbit ratio between neighbours (jittered ±15%)
  radiusMin = 600,   -- planet terrain radius range
  radiusMax = 950,
  gravityMin = 3.5,  -- surface gravity range (µ = g·r²)
  gravityMax = 8.5,
  moonChance = 0.6,  -- chance a planet gets each of up to 2 moons
  atmoChance = 0.8,  -- chance a planet has an atmosphere
  caveScale = 1.0,   -- multiplies cave-zone depth on every body
  starScale = 1.0,   -- multiplies the star's brightness
  scale = 3,         -- WORLD SCALE version (see SCALES); a save keeps its own
}

-- ── WORLD SCALE ─────────────────────────────────────────────────────────────
--
-- Every number that says how BIG this universe is, by version. A save is
-- generated at one version and keeps it for life (save key `g_scale`, read by
-- game_manager; a save from before versions existed has none and is version
-- 1), exactly the way `parts.rating` freezes the catalogue: a world the player
-- has dug, built a colony on and parked craft around must regenerate as the
-- SAME world, so nothing here may ever change for an existing version. A new
-- scale is a new entry.
--
-- 1  the original worlds: planets 100–230 m, orbits from 5 km. Orbital speed
--    ~30 m/s, burns of a few seconds.
-- 2  (2026-10-13) bigger, more realistic worlds: planets 240–380 m across the
--    radius, Mars-to-Earth gravity, orbits from 24 km round a heavier star.
--    Orbital speed ~45 m/s, burns ~1.5× longer. Bodies are the ARCHETYPES of
--    scale 1 at the bigger sizes — the player's slot1 (seed 1187844297) was
--    made at exactly this recipe and regenerates from it. (For a few days the
--    geology roll was switched on for scale 2 too, which re-rolled that save
--    into a different system; it now lives in scale 3 only.)
--
--    HOW BIG WAS CAPPED BY THE TERRAIN GENERATOR (engine 0.116): a fill cost
--    the planet's VOLUME in voxels, so scale 2 sizes each body's VOXEL to its
--    radius so no fill spans more than 175 voxels from centre to peak, and caps
--    the cave zone at 80 m. A body under ~255 m keeps the 1.5 m voxel.
-- 3  (2026-10-20, engine 0.117) WHOLE WORLDS: planets 600–950 m, rolled as a
--    GEOLOGY (rollGeology) and shaped with the engine's relief layers
--    (mountain ranges, warp, plateaus, terraces, overhangs, ravines, rivers
--    and climate biomes — geoOpts3). Everything else is scale 2 × 2.5 in
--    length at the same surface gravity: orbits from 60 km, µ × 6.25, moons
--    150–300 m, the galaxy sector × 2.5, so speeds are × 1.58 and every time
--    (an ascent, an orbit, a year) is √2.5 = 1.58× longer.
--
--    WHY 600–950 m, measured on 0.117.0-rc2 (16 cores, shared with other
--    work; `world117` bench, full relief layers, deferCaves):
--      r   voxel  first fill  RAM (gen / in play)  dug save   orbit-view frame
--      300 1.5    8.5 s       0.3 / –  GB          66 MB      22 ms
--      600 1.5    16 s        1.4 / 2.5 GB         280 MB     16 ms
--      1000 1.5   29 s        3.4 / –  GB          –          –
--      1000 2.0   24 s        1.6 / 3.4 GB         474 MB     24 ms
--      1500 1.5   56 s        9.0 / –  GB          –          –
--      2000 2.0   60 s        8.9 / –  GB          –          –
--    The fill is now cheap (only the shell is evaluated) but the FIELD is
--    not: 256 KB per surface chunk, all resident, so memory and the size of a
--    dug save go as (radius / voxel)². 1.5 km fits the 60 s load but not a
--    player's RAM (engine card 0414: far chunks are not evicted yet), and a
--    ~20 km world (1–3 minute ascents) needs streamed generation. So the
--    voxel follows the radius at `voxelSpan` voxels across the radius (r 700
--    keeps 1.5 m, r 950 gets 2.0 m) and the biggest home world costs what
--    r 1000 at 2 m measured: ~25 s, ~3.4 GB in play, ~0.5 GB once dug.
SCALES = {
  [1] = {
    minOrbit = 5000, spacing = 2.2, radiusMin = 100, radiusMax = 230,
    gravityMin = 4.5, gravityMax = 10,
    starMu = { 4e7, 1.1e8 }, starR = { 650, 1000 },
    moonR = { 26, 58 }, moonG = { 2, 5 }, moonA = { 5, 7 }, moonNext = { 1.8, 2.4 },
    soiFloor = 12, caveMax = nil, voxelHalf = nil,
    sector = 1.0,      -- galaxy sector multiplier (galaxy.lua)
    speed = 1.0,       -- the world's speed scale: heating, aero, tapes
    alt = 1.0,         -- the world's altitude scale: tapes
  },
  [2] = {
    minOrbit = 24000, spacing = 2.2, radiusMin = 240, radiusMax = 380,
    gravityMin = 3.5, gravityMax = 8.5,
    starMu = { 6e8, 1.5e9 }, starR = { 2600, 4000 },
    moonR = { 60, 120 }, moonG = { 1.5, 4 }, moonA = { 4.2, 5.4 }, moonNext = { 1.3, 1.5 },
    soiFloor = 12, caveMax = 80, voxelHalf = 175,
    sector = 5.0,
    speed = 1.4,
    alt = 2.0,
  },
  [3] = {
    minOrbit = 60000, spacing = 2.2, radiusMin = 600, radiusMax = 950,
    gravityMin = 3.5, gravityMax = 8.5,
    starMu = { 3.75e9, 9.375e9 }, starR = { 6500, 10000 },
    moonR = { 150, 300 }, moonG = { 1.5, 4 }, moonA = { 4.2, 5.4 }, moonNext = { 1.3, 1.5 },
    soiFloor = 12, caveMax = 100,
    voxelSpan = 470,   -- radius / voxel: r ≤ 705 m keeps 1.5 m, r 950 gets 2.0 m
    voxelMax = 2.4,    -- the coarsest a slider-dragged giant may get
    geology = true,    -- bodies are rolled as GEOLOGY (rollGeology), not archetype()
    layers = true,     -- …and shaped with the 0.117 relief layers (geoOpts3)
    sector = 12.5,
    speed = 2.2,
    alt = 5.0,
  },
}
CURRENT_SCALE = 3

-- The scale table for version `v` (nil or unknown = 1, the pre-version worlds).
function scaleOf(v)
  return SCALES[tonumber(v) or 1] or SCALES[1]
end

-- Published by every roll: the version and table the resident system was built
-- at, so other scripts (galaxy, HUD, vessel) can size themselves to it.
scaleVersion = 1
scale = SCALES[1]

-- ---------------------------------------------------------------------------
-- helpers

local function hsv(h, s, v)
  h = (h % 1) * 6
  local i = math.floor(h)
  local f = h - i
  local p, q, t = v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
  if i == 0 then return { v, t, p } end
  if i == 1 then return { q, v, p } end
  if i == 2 then return { p, v, t } end
  if i == 3 then return { p, q, v } end
  if i == 4 then return { t, p, v } end
  return { v, p, q }
end

local SYL_A = { "Ka", "Ve", "Zor", "Ath", "Or", "Ta", "Dra", "Pel", "Na", "Gol", "Bry", "Um", "Sol", "Ry" }
local SYL_B = { "ru", "il", "un", "mi", "quo", "os", "ver", "eth", "and", "ol", "ia", "ex" }

local function rollName(r, taken)
  while true do
    local n = r:pick(SYL_A) .. r:pick(SYL_B)
    if r:next() < 0.5 then n = n .. r:pick(SYL_B) end
    if not taken[n] then
      taken[n] = true
      return n
    end
  end
end

-- Archetypes: each returns the generatePlanet opts + an atmosphere hue.
-- Thresholds are tuned so caves read as LIT rock with glowing veins/pockets,
-- not fullbright walls (glow slots bypass lighting by design — use sparingly).
local function archetype(r, kind, radius, caveScale, sc)
  local j = r:range(-0.03, 0.03)
  local caveK = ({ canyon = 0.35, dune = 0.25, ice = 0.3, lava = 0.35, crystal = 0.4,
    barren = 0.25, frost = 0.25 })[kind]
  local cave = radius * caveK
  if sc and sc.caveMax then cave = math.min(cave, sc.caveMax) end
  local o = {
    radius = radius,
    relief = radius * r:range(0.05, 0.08),
    bumpFreq = r:range(3.8, 5.2),
    caveDepth = cave * caveScale,
    coreR = math.max(radius * 0.07, 5),
    corePaint = { slot = 6, color = { 0.98, 0.82, 0.6 } },
  }
  local atmoHue
  if kind == "canyon" then
    local warm, cool = r:range(0.01, 0.09) + j, r:range(0.68, 0.85) + j
    o.surfaceA = { slot = 1, color = hsv(warm, r:range(0.25, 0.45), r:range(0.6, 0.75)) }
    o.surfaceB = { slot = 2, color = hsv(cool, r:range(0.15, 0.3), r:range(0.55, 0.7)) }
    o.subsoil = { slot = 3, color = hsv(cool, 0.18, 0.62) }
    o.strata = { slot = 4, color = hsv(warm, 0.25, 0.75) }
    o.deep = { slot = 5, color = hsv(warm, 0.3, 0.68) }
    o.pockets = { slot = 7, color = hsv(r:range(0.7, 0.82), 0.28, 0.82), threshold = r:range(0.44, 0.5), minDepth = 8 }
    o.seam = { slot = 6, color = hsv(warm, 0.25, 0.9), minDepth = o.caveDepth * 0.5, center = 0.32, width = 0.045 }
    atmoHue = r:range(0.02, 0.1)
  elseif kind == "dune" then
    local gold = r:range(0.08, 0.15) + j
    o.bumpFreq = r:range(6.5, 8.5)
    o.relief = radius * r:range(0.06, 0.1)
    o.surfaceA = { slot = 2, color = hsv(gold, r:range(0.4, 0.55), r:range(0.85, 0.98)) }
    o.surfaceB = { slot = 1, color = hsv(gold - 0.03, r:range(0.4, 0.55), r:range(0.65, 0.8)) }
    o.patchBias = 0.6
    o.patchThr = -0.05
    o.subsoil = { slot = 4, color = hsv(gold - 0.02, 0.5, 0.85) }
    o.strata = { slot = 5, color = hsv(gold - 0.04, 0.5, 0.7) }
    o.deep = { slot = 5, color = hsv(gold - 0.05, 0.45, 0.62) }
    o.pockets = { slot = 6, color = hsv(gold, 0.4, 0.95), threshold = r:range(0.46, 0.52), minDepth = 10 }
    o.seam = { slot = 6, color = hsv(gold, 0.4, 1.0), minDepth = o.caveDepth * 0.6, center = 0.3, width = 0.04 }
    atmoHue = r:range(0.08, 0.13)
  elseif kind == "ice" then
    local blue = r:range(0.5, 0.62) + j
    o.bumpFreq = r:range(2.6, 3.6)
    o.relief = radius * r:range(0.04, 0.07)
    o.surfaceA = { slot = 12, color = hsv(blue, r:range(0.1, 0.25), r:range(0.85, 0.98)) }
    o.surfaceB = { slot = 9, color = hsv(blue, r:range(0.15, 0.3), r:range(0.7, 0.82)) }
    o.patchBias = 0.2
    o.patchThr = 0.25
    o.subsoil = { slot = 9, color = hsv(blue, 0.2, 0.72) }
    o.strata = { slot = 3, color = hsv(blue + 0.04, 0.25, 0.6) }
    o.deep = { slot = 9, color = hsv(blue, 0.25, 0.55) }
    o.pockets = { slot = 8, color = hsv(blue + r:range(-0.05, 0.05), 0.3, 0.9), threshold = r:range(0.4, 0.48), minDepth = 6 }
    o.iceCaps = { lat = 0.75, slot = 12, color = { 0.85, 0.92, 0.98 } }
    o.corePaint = { slot = 8, color = hsv(blue, 0.3, 0.9) }
    atmoHue = r:range(0.5, 0.6)
  elseif kind == "lava" then
    local ash = r:range(0.0, 0.06) + j
    o.bumpFreq = r:range(4.0, 5.5)
    o.surfaceA = { slot = 1, color = hsv(ash, r:range(0.15, 0.3), r:range(0.28, 0.4)) }
    o.surfaceB = { slot = 4, color = hsv(ash, r:range(0.2, 0.35), r:range(0.4, 0.52)) }
    o.patchBias = 0.4
    o.patchThr = 0.05
    o.subsoil = { slot = 4, color = hsv(ash, 0.25, 0.35) }
    o.strata = { slot = 5, color = hsv(ash, 0.3, 0.45) }
    o.deep = { slot = 5, color = hsv(ash, 0.3, 0.5) }
    o.pockets = { slot = 6, color = hsv(ash + 0.02, 0.5, 1.0), threshold = r:range(0.38, 0.44), minDepth = 6 }
    -- Surface cracks: shallow THIN seams — filaments of glow, not floods.
    o.seam = { slot = 6, color = hsv(ash + 0.02, 0.5, 1.0), minDepth = 6, center = 0.3, width = 0.05 }
    atmoHue = r:range(0.0, 0.04)
  elseif kind == "crystal" then
    local vio = (r:next() < 0.5 and r:range(0.68, 0.8) or r:range(0.45, 0.55)) + j
    o.surfaceA = { slot = 2, color = hsv(vio, r:range(0.2, 0.35), r:range(0.55, 0.7)) }
    o.surfaceB = { slot = 3, color = hsv(vio + 0.06, r:range(0.15, 0.3), r:range(0.45, 0.6)) }
    o.patchBias = 0.35
    o.patchThr = 0.0
    o.subsoil = { slot = 3, color = hsv(vio, 0.2, 0.55) }
    o.strata = { slot = 4, color = hsv(vio, 0.25, 0.5) }
    o.deep = { slot = 5, color = hsv(vio, 0.28, 0.6) }
    local slot = vio > 0.6 and 7 or 8
    o.pockets = { slot = slot, color = hsv(vio, 0.32, 0.95), threshold = r:range(0.32, 0.38), minDepth = 5 }
    o.corePaint = { slot = slot, color = hsv(vio, 0.32, 0.95) }
    atmoHue = r:range(0.55, 0.8)
  elseif kind == "frost" then
    local blue = r:range(0.5, 0.6) + j
    o.bumpFreq = r:range(2.6, 3.6)
    o.surfaceA = { slot = 12, color = hsv(blue, 0.12, 0.92) }
    o.surfaceB = { slot = 10, color = hsv(blue, 0.08, 0.72) }
    o.subsoil = { slot = 9, color = hsv(blue, 0.15, 0.7) }
    o.strata = { slot = 9, color = hsv(blue, 0.18, 0.6) }
    o.deep = { slot = 9, color = hsv(blue, 0.2, 0.55) }
    o.pockets = { slot = 8, color = hsv(blue, 0.3, 0.9), threshold = r:range(0.44, 0.5), minDepth = 4 }
    o.iceCaps = { lat = 0.6, slot = 12, color = { 0.8, 0.9, 0.95 } }
    o.craters = 8 + r:int(0, 9)
    o.corePaint = { slot = 8, color = hsv(blue, 0.3, 0.9) }
  else -- barren
    local g = r:range(0.5, 0.75)
    o.surfaceA = { slot = 10, color = hsv(r:next(), 0.04, g) }
    o.surfaceB = { slot = 11, color = hsv(0.1, 0.08, g + 0.1) }
    o.patchThr = -0.42
    o.subsoil = { slot = 9, color = { 0.6, 0.62, 0.68 } }
    o.strata = { slot = 9, color = { 0.55, 0.56, 0.6 } }
    o.deep = { slot = 9, color = { 0.5, 0.5, 0.55 } }
    o.pockets = { slot = 8, color = hsv(r:range(0.5, 0.8), 0.3, 0.9), threshold = r:range(0.46, 0.54), minDepth = 3 }
    o.craters = 8 + r:int(0, 9)
    o.corePaint = { slot = 8, color = { 0.55, 0.8, 1.0 } }
  end
  -- The voxel follows the body (scale 2+): the fill walks a cube of
  -- (2·(radius + relief) / voxel)³ voxels, so a body may span at most
  -- `voxelHalf` voxels from its centre to its tallest peak. Small worlds keep
  -- the engine's 1.5 m; nothing goes finer.
  if sc and sc.voxelHalf then
    o.voxel = math.max(1.5, (radius + o.relief + 2) / sc.voxelHalf)
  end
  return o, atmoHue
end

-- ── GEOLOGY (world scale 2+) ────────────────────────────────────────────────
--
-- Scale 1 keeps `archetype` above, untouched: its worlds must regenerate draw
-- for draw. From scale 2 a body is rolled as a GEOLOGY: a planet TYPE chosen
-- by its physics (how much starlight it gets, whether it holds air, so how warm
-- it is), then a descriptor of what it is made of and how it is shaped, then
-- that descriptor is mapped onto terrain.generatePlanet opts by `geoOpts`.
--
-- The descriptor is the stable layer. The engine's generator today has one
-- fbm relief field, spherical crater dents, two surface paints split by one
-- patch noise (plus an ice/patch paint and a crater-floor paint) and depth
-- layers (crates/floptle-field/src/procgen.rs `PlanetFill`). What a world
-- WANTS beyond that — ridged ranges, domain warp, overhangs, ravines, rivers,
-- slope/biome material rules (engine card 0416) — is already written down in
-- `geo.future`; when the engine grows an opt, `geoOpts` maps it and every
-- world rolled from then on uses it, with no new roll to invent.
--
-- `geo.family` is the legacy archetype (canyon/dune/ice/frost/lava/crystal/
-- barren) that mining (materials.lua BANDS), climate and missions key on, so
-- twenty planet types still pay out and read through the systems that know
-- seven.

-- Terrain palette slots (terrain/system.palette). 1–12 are the original set
-- (6–8 glow); 13–32 come from tools/gen_terrain_textures.py. A texture carries
-- its own colour at natural brightness; the tint (×1.6 in the shader) is kept
-- near-neutral and pushed toward the world's chemistry.
GEO_SLOT = {
  rust = 1, purpledirt = 2, purpleslate = 3, onyx = 4, veinstone = 5,
  magma = 6, amethyst = 7, bluecrystal = 8, slate = 9, oldregolith = 10, dust = 11, tealice = 12,
  basalt = 13, granite = 14, sandstone = 15, sand = 16, regolith = 17, salt = 18,
  mudcrack = 19, moss = 20, ash = 21, snow = 22, glacier = 23, scree = 24,
  limestone = 25, sulfur = 26, hematite = 27, tundra = 28, pahoehoe = 29, shale = 30,
  peat = 31, litter = 32,
}

-- The steepest fbm ground (relief · bumpFreq / radius) a world may roll; see geoOpts.
GEO_MAX_SLOPE = 0.45

local function clamp01(x) return math.max(0, math.min(1, x)) end

-- One paint: a material + a tint. `h` is the hue the tint leans to, `s` how
-- far (0 = the texture's own colour), `v` the brightness (0.62 ≈ as authored).
local function M(r, mat, h, s, v)
  return { slot = GEO_SLOT[mat], color = hsv(h + r:range(-0.015, 0.015),
    clamp01(s + r:range(-0.03, 0.03)), math.max(0.2, v + r:range(-0.04, 0.04))) }
end

-- Water by chemistry: what the sea's shader is fed (scripts/ocean.lua).
local WATERS = {
  ocean   = { deep = { 0.02, 0.12, 0.25 }, shallow = { 0.09, 0.50, 0.55 }, clarity = 4.0 },
  algal   = { deep = { 0.02, 0.15, 0.13 }, shallow = { 0.20, 0.45, 0.28 }, clarity = 2.4 },
  tannin  = { deep = { 0.06, 0.05, 0.03 }, shallow = { 0.36, 0.25, 0.12 }, clarity = 1.6 },
  glacial = { deep = { 0.05, 0.25, 0.33 }, shallow = { 0.35, 0.70, 0.72 }, clarity = 2.0 },
  iron    = { deep = { 0.12, 0.05, 0.04 }, shallow = { 0.55, 0.28, 0.16 }, clarity = 1.4 },
  tropic  = { deep = { 0.01, 0.10, 0.30 }, shallow = { 0.10, 0.70, 0.68 }, clarity = 7.0 },
  methane = { deep = { 0.05, 0.03, 0.01 }, shallow = { 0.30, 0.20, 0.08 }, clarity = 9.0 },
}

-- Plant pigment by the star's light (Kiang 2007: photosynthesis tunes to the
-- photons that arrive — bluer stars favour yellow/orange-reflecting leaves,
-- Sun-like green, cooler stars red, red dwarfs near-black). A hint for flora.
local FOLIAGE = {
  { 0.62, 0.62, 0.30 }, -- blue-white: yellow-olive
  { 0.40, 0.55, 0.25 }, -- white: yellow-green
  { 0.25, 0.48, 0.18 }, -- yellow: green
  { 0.52, 0.30, 0.18 }, -- orange: rust-red
  { 0.16, 0.10, 0.12 }, -- red dwarf: near-black purple
}

-- The catalogue. `air` true = needs an atmosphere, false = needs none, nil =
-- either. `T` = the equilibrium temperature range (K) it forms in. `w` weight.
-- `spawn` = a colony can start here. `family` = the legacy archetype.
GEO_TYPES = {
  archipelago = { label = "Oceanic archipelago", family = "canyon", air = true,  T = { 262, 330 }, w = 4, spawn = true },
  verdant     = { label = "Verdant wetland",     family = "canyon", air = true,  T = { 272, 335 }, w = 3, spawn = true },
  alpine      = { label = "Alpine highlands",    family = "canyon", air = true,  T = { 235, 310 }, w = 2.5, spawn = true },
  canyon      = { label = "Ochre canyonlands",   family = "canyon", air = nil,   T = { 215, 345 }, w = 2.5, spawn = true },
  steppe      = { label = "Grass steppe",        family = "canyon", air = true,  T = { 248, 325 }, w = 2, spawn = true },
  dune        = { label = "Dune sea",            family = "dune",   air = true,  T = { 270, 420 }, w = 2.5, spawn = true },
  saltflat    = { label = "Salt-pan desert",     family = "dune",   air = nil,   T = { 250, 420 }, w = 2, spawn = true },
  ironred     = { label = "Iron-red desert",     family = "canyon", air = nil,   T = { 180, 335 }, w = 2.5, spawn = true },
  tundra      = { label = "Permafrost tundra",   family = "ice",    air = true,  T = { 205, 268 }, w = 3, spawn = true },
  glacial     = { label = "Glacial world",       family = "ice",    air = nil,   T = { 60, 255 },  w = 2, spawn = true },
  volcanic    = { label = "Basaltic volcanic",   family = "lava",   air = nil,   T = { 0, 999 },   w = 1, hot = 3 },
  sulfur      = { label = "Sulfur plains",       family = "lava",   air = nil,   T = { 0, 999 },   w = 0.6, hot = 2 },
  greenhouse  = { label = "Greenhouse inferno",  family = "lava",   air = true,  T = { 335, 999 }, w = 3 },
  crystal     = { label = "Crystal badlands",    family = "crystal", air = nil,  T = { 0, 999 },   w = 0.9 },
  titan       = { label = "Hydrocarbon world",   family = "ice",    air = true,  T = { 0, 175 },   w = 3 },
  frost       = { label = "Cratered ice",        family = "frost",  air = false, T = { 0, 230 },   w = 3 },
  regolith    = { label = "Cratered regolith",   family = "barren", air = false, T = { 0, 999 },   w = 3 },
  maria       = { label = "Basalt maria",        family = "barren", air = false, T = { 0, 999 },   w = 2 },
}
GEO_ORDER = { "archipelago", "verdant", "alpine", "canyon", "steppe", "dune", "saltflat", "ironred",
  "tundra", "glacial", "volcanic", "sulfur", "greenhouse", "crystal", "titan", "frost", "regolith", "maria" }

-- Which type a body becomes: weighted by how well its temperature and air fit
-- each type, softly (a type 30 K outside its range is still possible, rarely).
local function pickGeoType(r, Tk, air, opts)
  local total, cands = 0, {}
  for _, id in ipairs(GEO_ORDER) do
    local t = GEO_TYPES[id]
    local ok = true
    if t.air == true and not air then ok = false end
    if t.air == false and air then ok = false end
    if opts.spawn and not t.spawn then ok = false end
    if opts.moon and t.air == true then ok = false end
    if id == opts.avoid then ok = false end
    if ok then
      local w = t.w
      if Tk < t.T[1] then w = (Tk > t.T[1] - 30) and w * 0.1 or 0
      elseif Tk > t.T[2] then w = (Tk < t.T[2] + 30) and w * 0.1 or 0 end
      if t.hot and Tk > 330 then w = w + t.hot end
      if opts.tidal and (id == "volcanic" or id == "sulfur") then w = w + 2.5 end
      if w > 0 then total = total + w; cands[#cands + 1] = { id, w } end
    end
  end
  if total <= 0 then return (opts.spawn and (air and "canyon" or "ironred")) or "regolith" end
  local x = r:next() * total
  for _, c in ipairs(cands) do
    x = x - c[2]
    if x <= 0 then return c[1] end
  end
  return cands[#cands][1]
end

-- Temperature on the climate's 0..1 scale (climate.lua prints −40 + t·90 °C).
local function tempNorm(Tk) return clamp01((Tk - 233) / 90) end

-- THE TYPES. Each fills a descriptor from the roll. Shared knobs:
--   relief, bumpFreq     fractions/frequency of the one fbm relief field
--   band = {alt, bias}   an ELEVATION boundary between `low` and `high` paint
--                        (alt in units of relief; bias how sharply height wins
--                        over the patch noise) — beaches, snowlines, treelines
--   thr, bias            otherwise: patch noise picks between them
--   patch                a third paint where the patch noise is lowest
--   cap / capLat         polar caps (lat = |dir.y| above which)
--   craters = {n, k1, k2} k = crater radius over the rim height (the dent's
--                        centre sits 0.3·relief up), so 1.2 is a shallow pan
--                        and 3 a deep bowl
--   sea = {alt, water}   sea level in units of relief; nil = dry
local BUILD = {}

-- Rock that a world's mountains and dig walls are made of.
local ROCKS = { "granite", "basalt", "shale", "limestone", "sandstone", "slate" }
local function rock(r, list) return r:pick(list or ROCKS) end
-- `slate` is the old silver slate slot; same idea, different grain.
GEO_SLOT.slate = 9

BUILD.archipelago = function(r, g)
  local h = r:range(0.05, 0.14)
  g.relief = r:range(0.06, 0.11)
  g.bumpFreq = r:range(2.2, 4.5)
  local veg = r:pick({ "moss", "moss", "litter", "tundra" })
  g.high = M(r, veg, h + 0.15, r:range(0.0, 0.15), r:range(0.58, 0.7))
  g.low = M(r, r:pick({ "sand", "sand", "basalt", "limestone" }), h, r:range(0.0, 0.12), r:range(0.62, 0.75))
  g.patch = M(r, rock(r, { "granite", "basalt", "limestone", "scree" }), h, 0.05, 0.62)
  g.band = { alt = r:range(0.02, 0.1), bias = r:range(2.5, 4) }
  g.sea = { alt = r:range(0.12, 0.32), water = r:pick({ "ocean", "tropic", "tropic", "algal" }) }
  g.dust = M(r, "sand", h, 0.05, 0.7)
  g.craters = { r:int(0, 3), 1.3, 2.2 }
  g.soil, g.moist, g.fertility = "loam", 0.75, 0.8
  g.air = { hue = r:range(0.55, 0.6), sat = 0.45, clouds = r:range(0.3, 0.75) }
  g.future = { ridged = 0.2, warp = 0.5, rivers = 0.4, coastErosion = true }
end

BUILD.verdant = function(r, g)
  local h = r:range(0.08, 0.2)
  g.relief = r:range(0.035, 0.07)
  g.bumpFreq = r:range(3.0, 5.5)
  g.high = M(r, r:pick({ "litter", "moss", "litter" }), h + 0.1, r:range(0, 0.12), r:range(0.6, 0.72))
  g.low = M(r, r:pick({ "peat", "peat", "mudcrack", "moss" }), h, r:range(0, 0.1), r:range(0.62, 0.74))
  g.patch = M(r, "moss", h + 0.12, 0.1, 0.64)
  g.band = { alt = r:range(-0.05, 0.12), bias = r:range(1.2, 2.5) }
  g.sea = { alt = r:range(-0.08, 0.14), water = r:pick({ "algal", "tannin", "ocean" }) }
  g.dust = M(r, "peat", h, 0.05, 0.66)
  g.craters = { r:int(0, 4), 1.2, 1.8 }
  g.soil, g.moist, g.fertility = "peat", 0.9, 1.0
  g.air = { hue = r:range(0.5, 0.6), sat = 0.35, clouds = r:range(0.45, 0.85) }
  g.future = { rivers = 0.8, meanders = true, warp = 0.3 }
end

BUILD.alpine = function(r, g)
  local h = r:range(0.0, 0.15)
  g.relief = r:range(0.11, 0.16)
  g.bumpFreq = r:range(2.6, 4.4)
  local rk = rock(r, { "granite", "granite", "shale", "limestone", "basalt" })
  g.high = M(r, "snow", 0.58, r:range(0.0, 0.06), r:range(0.66, 0.74))
  g.low = M(r, r:pick({ "tundra", "moss", "scree" }), h + 0.1, r:range(0, 0.12), r:range(0.6, 0.7))
  g.patch = M(r, rk, h, 0.08, 0.62)
  g.band = { alt = r:range(0.18, 0.42), bias = r:range(2.5, 4.5) }
  g.sea = r:next() < 0.6 and { alt = r:range(-0.5, -0.2), water = "glacial" } or nil
  g.cap, g.capLat = M(r, "glacier", 0.55, 0.05, 0.66), r:range(0.82, 0.92)
  g.dust = M(r, "scree", h, 0.05, 0.62)
  g.craters = { r:int(0, 2), 1.3, 2.0 }
  g.subsoilMat = rk
  g.soil, g.moist, g.fertility = "rocky", 0.55, 0.45
  g.air = { hue = r:range(0.56, 0.62), sat = 0.5, clouds = r:range(0.25, 0.7) }
  g.future = { ridged = 0.9, warp = 0.4, glacialValleys = true, overhangs = 0.2 }
end

BUILD.canyon = function(r, g)
  local warm = r:range(0.02, 0.09)
  g.relief = r:range(0.07, 0.12)
  g.bumpFreq = r:range(3.2, 6.0)
  g.high = M(r, r:pick({ "sandstone", "sandstone", "limestone", "rust" }), warm, r:range(0.05, 0.25), r:range(0.6, 0.7))
  g.low = M(r, r:pick({ "hematite", "mudcrack", "sand", "scree" }), warm, r:range(0.05, 0.2), r:range(0.58, 0.68))
  g.patch = M(r, "scree", warm, 0.1, 0.6)
  g.bias, g.thr = r:range(0.5, 1.2), r:range(-0.1, 0.15)
  g.sea = r:next() < 0.45 and { alt = r:range(-0.55, -0.25), water = r:pick({ "iron", "ocean", "tannin" }) } or nil
  g.dust = M(r, r:pick({ "mudcrack", "salt" }), warm, 0.08, 0.7)
  g.craters = { r:int(1, 6), 1.3, 2.4 }
  g.soil, g.moist, g.fertility = "sandy", 0.3, 0.35
  g.air = { hue = r:range(0.04, 0.1), sat = 0.4, clouds = r:range(0.0, 0.35) }
  g.future = { ravines = 0.9, terraces = true, mesas = 0.6 }
end

BUILD.steppe = function(r, g)
  local h = r:range(0.08, 0.16)
  g.relief = r:range(0.03, 0.06)
  g.bumpFreq = r:range(2.0, 4.0)
  g.high = M(r, r:pick({ "tundra", "moss" }), h, r:range(0.1, 0.25), r:range(0.62, 0.72))
  g.low = M(r, r:pick({ "mudcrack", "sand", "hematite" }), h - 0.03, r:range(0.05, 0.15), r:range(0.62, 0.72))
  g.patch = M(r, r:pick({ "scree", "limestone", "granite" }), h, 0.05, 0.62)
  g.bias, g.thr = r:range(0.4, 1.0), r:range(-0.15, 0.1)
  g.sea = r:next() < 0.5 and { alt = r:range(-0.5, -0.2), water = r:pick({ "ocean", "algal" }) } or nil
  g.dust = M(r, "salt", h, 0.05, 0.72)
  g.craters = { r:int(0, 4), 1.2, 1.8 }
  g.soil, g.moist, g.fertility = "loess", 0.35, 0.6
  g.air = { hue = r:range(0.55, 0.62), sat = 0.4, clouds = r:range(0.1, 0.5) }
  g.future = { rivers = 0.5, warp = 0.3 }
end

BUILD.dune = function(r, g)
  local gold = r:range(0.06, 0.13)
  g.relief = r:range(0.03, 0.065)
  g.bumpFreq = r:range(6.0, 9.5)
  g.high = M(r, "sand", gold, r:range(0.1, 0.3), r:range(0.66, 0.78))
  g.low = M(r, r:pick({ "sand", "mudcrack", "hematite" }), gold - 0.02, r:range(0.1, 0.3), r:range(0.58, 0.68))
  g.patch = M(r, r:pick({ "sandstone", "salt", "basalt" }), gold, 0.1, 0.62)
  g.bias, g.thr = r:range(0.5, 1.0), r:range(-0.15, 0.05)
  g.sea = r:next() < 0.15 and { alt = r:range(-0.6, -0.4), water = "tropic" } or nil
  g.dust = M(r, "salt", gold, 0.08, 0.72)
  g.craters = { r:int(0, 3), 1.2, 2.0 }
  g.subsoilMat = "sandstone"
  g.soil, g.moist, g.fertility = "sand", 0.08, 0.1
  g.air = { hue = r:range(0.07, 0.12), sat = 0.45, clouds = r:range(0.0, 0.2) }
  g.future = { dunes = "barchan", warp = 0.6, windDir = r:range(0, 6.28) }
end

BUILD.saltflat = function(r, g)
  local h = r:range(0.05, 0.12)
  g.relief = r:range(0.02, 0.04)
  g.bumpFreq = r:range(1.8, 3.5)
  g.high = M(r, r:pick({ "mudcrack", "hematite", "sand", "scree" }), h, r:range(0.05, 0.2), r:range(0.6, 0.7))
  g.low = M(r, "salt", h, r:range(0.0, 0.08), r:range(0.68, 0.78))
  g.patch = M(r, r:pick({ "basalt", "sandstone", "limestone" }), h, 0.05, 0.6)
  g.band = { alt = r:range(-0.2, 0.1), bias = r:range(2, 4) }
  g.dust = M(r, "salt", h, 0.0, 0.76)
  g.craters = { r:int(1, 5), 1.15, 1.6 }
  g.subsoilMat = "mudcrack"
  g.soil, g.moist, g.fertility = "saline", 0.1, 0.05
  g.air = { hue = r:range(0.08, 0.14), sat = 0.3, clouds = r:range(0.0, 0.2) }
  g.future = { evaporiteBasins = true }
end

BUILD.ironred = function(r, g)
  local rust = r:range(0.0, 0.05)
  g.relief = r:range(0.07, 0.14)
  g.bumpFreq = r:range(2.8, 5.5)
  g.high = M(r, r:pick({ "hematite", "rust", "basalt" }), rust, r:range(0.15, 0.35), r:range(0.58, 0.68))
  g.low = M(r, r:pick({ "hematite", "sand", "regolith" }), rust + 0.02, r:range(0.2, 0.4), r:range(0.6, 0.7))
  -- No polar caps: the engine's cap paint also frosts low patch-noise spots at
  -- any latitude (procgen.rs paint(), `patch < -0.42`), which on a dry
  -- iron-red desert reads as snow on the equator. Dark rock outcrops instead.
  g.patch = M(r, r:pick({ "basalt", "scree", "rust" }), rust, 0.15, 0.55)
  g.bias, g.thr = r:range(0.3, 1.0), r:range(-0.1, 0.15)
  g.dust = M(r, r:pick({ "regolith", "basalt" }), rust, 0.15, 0.6)
  g.craters = { r:int(3, 10), 1.25, 2.6 }
  g.soil, g.moist, g.fertility = "oxide", 0.12, 0.08
  g.air = { hue = r:range(0.03, 0.08), sat = 0.5, clouds = r:range(0.0, 0.2) }
  g.future = { ravines = 0.7, shieldVolcano = 0.4, outflowChannels = true }
end

BUILD.tundra = function(r, g)
  local h = r:range(0.1, 0.2)
  g.relief = r:range(0.03, 0.065)
  g.bumpFreq = r:range(2.8, 5.0)
  g.high = M(r, "tundra", h, r:range(0.0, 0.12), r:range(0.6, 0.7))
  g.low = M(r, r:pick({ "peat", "moss", "scree" }), h, r:range(0, 0.1), r:range(0.6, 0.7))
  g.patch = M(r, "snow", 0.58, 0.04, 0.72)
  g.bias, g.thr = r:range(0.3, 1.0), r:range(-0.1, 0.1)
  g.cap, g.capLat = M(r, "snow", 0.58, 0.04, 0.74), r:range(0.6, 0.8)
  g.sea = r:next() < 0.6 and { alt = r:range(-0.35, 0.0), water = "glacial" } or nil
  g.dust = M(r, "glacier", 0.55, 0.04, 0.66)
  g.craters = { r:int(0, 3), 1.2, 1.8 }
  g.soil, g.moist, g.fertility = "permafrost", 0.5, 0.3
  g.air = { hue = r:range(0.55, 0.62), sat = 0.35, clouds = r:range(0.3, 0.7) }
  g.future = { patternedGround = true, pingos = 0.3 }
end

BUILD.glacial = function(r, g)
  local blue = r:range(0.52, 0.6)
  g.relief = r:range(0.04, 0.09)
  g.bumpFreq = r:range(1.8, 3.6)
  g.high = M(r, "snow", blue, r:range(0.0, 0.08), r:range(0.68, 0.76))
  g.low = M(r, "glacier", blue, r:range(0.0, 0.12), r:range(0.6, 0.7))
  g.patch = M(r, rock(r, { "granite", "basalt", "shale", "slate" }), blue, 0.05, 0.58)
  g.bias, g.thr = r:range(0.5, 1.5), r:range(-0.05, 0.25)
  g.cap, g.capLat = M(r, "snow", blue, 0.02, 0.76), r:range(0.55, 0.75)
  g.sea = r:next() < 0.5 and { alt = r:range(-0.25, 0.1), water = "glacial" } or nil
  g.dust = M(r, "glacier", blue, 0.1, 0.62)
  g.craters = { r:int(0, 5), 1.2, 2.0 }
  g.soil, g.moist, g.fertility = "ice", 0.4, 0.02
  g.air = { hue = r:range(0.52, 0.6), sat = 0.3, clouds = r:range(0.1, 0.6) }
  g.future = { crevasses = 0.6, iceShelves = true, ridged = 0.3 }
end

BUILD.volcanic = function(r, g)
  local ash = r:range(0.0, 0.07)
  g.relief = r:range(0.08, 0.14)
  g.bumpFreq = r:range(2.8, 5.0)
  g.high = M(r, r:pick({ "ash", "basalt", "ash" }), ash, r:range(0.0, 0.15), r:range(0.62, 0.72))
  g.low = M(r, r:pick({ "pahoehoe", "basalt" }), ash, r:range(0.0, 0.12), r:range(0.62, 0.74))
  g.patch = M(r, r:pick({ "hematite", "sulfur", "ash" }), ash, 0.1, 0.6)
  g.bias, g.thr = r:range(0.6, 1.4), r:range(-0.1, 0.1)
  g.dust = M(r, "pahoehoe", ash, 0.0, 0.66)
  g.craters = { r:int(2, 7), 1.6, 3.0 }   -- calderas: deep and steep
  g.hot = true
  g.soil, g.moist, g.fertility = "ash", 0.15, 0.25
  g.air = { hue = r:range(0.0, 0.06), sat = 0.35, clouds = r:range(0.1, 0.5) }
  g.future = { shieldVolcano = 0.9, lavaChannels = true, lavaTubes = 0.5 }
end

BUILD.sulfur = function(r, g)
  local y = r:range(0.1, 0.15)
  g.relief = r:range(0.03, 0.07)
  g.bumpFreq = r:range(2.5, 5.0)
  g.high = M(r, "sulfur", y, r:range(0.0, 0.15), r:range(0.62, 0.72))
  g.low = M(r, r:pick({ "salt", "sulfur", "ash" }), y - 0.04, r:range(0.1, 0.25), r:range(0.62, 0.72))
  g.patch = M(r, r:pick({ "basalt", "pahoehoe" }), 0.02, 0.1, 0.6)
  g.bias, g.thr = r:range(0.3, 0.9), r:range(-0.1, 0.1)
  g.dust = M(r, "pahoehoe", 0.03, 0.1, 0.62)
  g.craters = { r:int(2, 6), 1.4, 2.6 }
  g.hot = true
  g.soil, g.moist, g.fertility = "sulfur", 0.05, 0.0
  g.air = { hue = r:range(0.11, 0.15), sat = 0.5, clouds = r:range(0.0, 0.3) }
  g.future = { plumes = true, lavaLakes = 0.4 }
end

BUILD.greenhouse = function(r, g)
  local h = r:range(0.05, 0.1)
  g.relief = r:range(0.05, 0.09)
  g.bumpFreq = r:range(2.0, 4.0)
  g.high = M(r, r:pick({ "basalt", "shale" }), h, r:range(0.1, 0.3), r:range(0.6, 0.72))
  g.low = M(r, r:pick({ "pahoehoe", "ash" }), h, r:range(0.1, 0.3), r:range(0.62, 0.72))
  g.patch = M(r, "sulfur", h + 0.03, 0.2, 0.6)
  g.bias, g.thr = r:range(0.4, 1.0), r:range(-0.1, 0.15)
  g.dust = M(r, "basalt", h, 0.1, 0.6)
  g.craters = { r:int(1, 4), 1.3, 2.2 }
  g.hot = true
  g.soil, g.moist, g.fertility = "basalt", 0.0, 0.0
  g.air = { hue = r:range(0.09, 0.13), sat = 0.55, clouds = r:range(0.6, 0.9) }
  g.future = { tesserae = 0.6, coronae = 0.4, lavaChannels = true }
end

BUILD.crystal = function(r, g)
  local vio = (r:next() < 0.5) and r:range(0.7, 0.8) or r:range(0.45, 0.55)
  g.relief = r:range(0.06, 0.1)
  g.bumpFreq = r:range(3.5, 5.5)
  g.high = M(r, r:pick({ "purpleslate", "slate", "shale" }), vio, r:range(0.1, 0.25), r:range(0.6, 0.7))
  g.low = M(r, r:pick({ "purpledirt", "regolith", "limestone" }), vio + 0.05, r:range(0.1, 0.2), r:range(0.6, 0.7))
  g.patch = M(r, "salt", vio, 0.1, 0.66)
  g.bias, g.thr = r:range(0.3, 0.6), r:range(-0.05, 0.1)
  g.glow = vio > 0.6 and "amethyst" or "bluecrystal"
  g.glowHue = vio
  g.dust = M(r, "regolith", vio, 0.1, 0.62)
  g.craters = { r:int(0, 5), 1.3, 2.2 }
  g.soil, g.moist, g.fertility = "silicate", 0.2, 0.25
  g.air = { hue = r:range(0.6, 0.8), sat = 0.4, clouds = r:range(0.0, 0.4) }
  g.future = { spires = 0.8, overhangs = 0.5 }
end

BUILD.titan = function(r, g)
  local h = r:range(0.06, 0.1)
  g.relief = r:range(0.03, 0.06)
  g.bumpFreq = r:range(3.0, 7.0)
  g.high = M(r, r:pick({ "glacier", "snow" }), h, r:range(0.2, 0.35), r:range(0.5, 0.6))
  g.low = M(r, r:pick({ "sand", "ash" }), h, r:range(0.3, 0.5), r:range(0.4, 0.5))   -- tholin dunes
  g.patch = M(r, "peat", h, 0.2, 0.55)
  g.band = { alt = r:range(-0.05, 0.15), bias = r:range(1.5, 3) }
  g.sea = { alt = r:range(-0.35, -0.05), water = "methane", state = "methane" }
  g.dust = M(r, "ash", h, 0.3, 0.45)
  g.craters = { r:int(0, 3), 1.2, 1.8 }
  g.soil, g.moist, g.fertility = "tholin", 0.6, 0.0
  g.air = { hue = r:range(0.07, 0.1), sat = 0.65, clouds = r:range(0.3, 0.7) }
  g.future = { rivers = 0.7, dunes = "linear" }
end

BUILD.frost = function(r, g)
  local blue = r:range(0.5, 0.6)
  g.relief = r:range(0.04, 0.07)
  g.bumpFreq = r:range(2.5, 4.0)
  g.high = M(r, r:pick({ "snow", "tealice" }), blue, r:range(0.0, 0.1), r:range(0.66, 0.74))
  g.low = M(r, r:pick({ "glacier", "oldregolith" }), blue, r:range(0.0, 0.12), r:range(0.58, 0.68))
  g.patch = M(r, "regolith", blue, 0.05, 0.6)
  g.bias, g.thr = r:range(0.3, 0.8), r:range(-0.1, 0.1)
  g.cap, g.capLat = M(r, "snow", blue, 0.0, 0.78), r:range(0.6, 0.8)
  g.dust = M(r, "dust", blue, 0.05, 0.66)
  g.craters = { r:int(8, 22), 1.3, 3.0 }
  g.soil, g.moist, g.fertility = "ice", 0.3, 0.0
  g.future = { chaosTerrain = 0.4, cryovolcano = 0.3 }
end

BUILD.regolith = function(r, g)
  local h = r:next()
  g.relief = r:range(0.04, 0.08)
  g.bumpFreq = r:range(2.5, 5.0)
  g.high = M(r, r:pick({ "regolith", "oldregolith" }), h, r:range(0.0, 0.06), r:range(0.58, 0.72))
  g.low = M(r, r:pick({ "regolith", "dust" }), h, r:range(0.0, 0.06), r:range(0.56, 0.68))
  g.patch = M(r, r:pick({ "scree", "granite", "basalt" }), h, 0.03, 0.6)
  g.bias, g.thr = r:range(0.2, 0.6), r:range(-0.2, 0.1)
  g.dust = M(r, r:pick({ "dust", "regolith" }), h, 0.03, 0.74)
  g.craters = { r:int(14, 30), 1.3, 3.2 }
  g.soil, g.moist, g.fertility = "regolith", 0.0, 0.0
  g.future = { rayedCraters = true, secondaryCraters = true }
end

BUILD.maria = function(r, g)
  local h = r:range(0.05, 0.12)
  g.relief = r:range(0.04, 0.07)
  g.bumpFreq = r:range(2.0, 4.0)
  g.high = M(r, r:pick({ "regolith", "dust", "granite" }), h, r:range(0.0, 0.08), r:range(0.66, 0.76))
  g.low = M(r, "basalt", h, r:range(0.0, 0.08), r:range(0.62, 0.72))
  g.patch = M(r, "scree", h, 0.03, 0.62)
  g.band = { alt = r:range(-0.15, 0.1), bias = r:range(1.5, 3) }
  g.dust = M(r, "basalt", h, 0.05, 0.6)   -- flooded basins: dark mare floors
  g.craters = { r:int(10, 24), 1.25, 2.6 }
  g.soil, g.moist, g.fertility = "regolith", 0.0, 0.0
  g.future = { rilles = 0.6, wrinkleRidges = true }
end

-- Roll a body's geology. `ctx`: radius, Tk (equilibrium K), air (bool),
-- moon (bool), spawn (bool), avoid (a type not to repeat), tidal (bool).
function rollGeology(r, ctx)
  local id = ctx.type or pickGeoType(r, ctx.Tk, ctx.air, ctx)
  local t = GEO_TYPES[id]
  local g = { type = id, label = t.label, family = t.family, Tk = ctx.Tk }
  BUILD[id](r, g)
  -- Every world gets its own character on top of its type: a mountainous or
  -- a worn-down one, a busier or a calmer relief, a deeper or a shallower crust.
  local mood = r:next()
  if mood < 0.2 then g.relief = g.relief * 1.35; g.bumpFreq = g.bumpFreq * 0.8      -- young, high
  elseif mood > 0.85 then g.relief = g.relief * 0.7 end                              -- old, eroded
  g.cave = r:range(0.22, 0.4)
  g.pocketThr = r:range(0.36, 0.52)
  -- Depth layers: soil, then the sedimentary record, then basement rock.
  g.subsoil = M(r, g.subsoilMat or r:pick({ "mudcrack", "scree", "regolith", "sand" }), r:next(), r:range(0, 0.1), 0.58)
  g.strata = M(r, r:pick({ "sandstone", "shale", "limestone", "onyx" }), r:next(), r:range(0, 0.12), 0.6)
  g.deep = M(r, r:pick({ "granite", "basalt", "slate", "veinstone" }), r:next(), r:range(0, 0.1), 0.56)
  g.subsoilDepth = r:range(1.5, 4.0)
  g.strataDepth = r:range(6.0, 14.0)
  -- The world's seas: liquid water between freezing and boiling (under some
  -- air), sea ice below, nothing above; a hydrocarbon world's are methane.
  if g.sea and not ctx.air then g.sea = nil end
  if g.sea then
    if g.sea.state == "methane" then
      if ctx.Tk > 200 then g.sea = nil end
    elseif ctx.Tk > 375 then g.sea = nil
    else g.sea.state = (ctx.Tk < 268) and "ice" or "liquid" end
  end
  if g.sea then g.sea.waterTable = WATERS[g.sea.water] or WATERS.ocean end
  return g
end

-- The geology as terrain.generatePlanet opts. Today's opts only: see the
-- header for what `geo.future` is waiting on (engine card 0416).
function geoOpts(g, radius, caveScale, sc)
  -- Mountains are capped twice: at 16% of the radius (a world, not a
  -- hedgehog), and where the body's voxel would pass 2.5 m (sc.voxelHalf
  -- voxels from centre to peak; a coarser voxel stops being walkable).
  local relief = radius * math.min(g.relief, 0.16)
  if sc and sc.voxelHalf then relief = math.min(relief, sc.voxelHalf * 2.5 - 2 - radius) end
  -- …and by STEEPNESS: relief × bumpFreq / radius is the typical slope of the
  -- fbm ground. Past ~0.45 the engine's coarse terrain LOD draws the slopes as
  -- huge flat-faced pyramids and spikes standing metres off the real ground
  -- (render only — collision and the field are right; measured 2026-10-14 on
  -- seed 6's moon Draandru, r 99, relief 14.5, bumpFreq 4.24: slope 0.62).
  relief = math.min(relief, GEO_MAX_SLOPE * radius / math.max(g.bumpFreq, 0.5))
  local cave = radius * g.cave
  if sc and sc.caveMax then cave = math.min(cave, sc.caveMax) end
  local o = {
    radius = radius,
    relief = relief,
    bumpFreq = g.bumpFreq,
    caveDepth = cave * (caveScale or 1),
    coreR = math.max(radius * 0.07, 5),
    surfaceA = g.high,
    surfaceB = g.low,
    subsoil = g.subsoil, subsoilDepth = g.subsoilDepth,
    strata = g.strata, strataDepth = g.strataDepth,
    deep = g.deep,
    craterDust = g.dust,
  }
  -- Height or patches: an elevation band makes the patch noise only jitter the
  -- boundary (procgen.rs paint(): patch + alt·patch_bias > patch_thr → A).
  if g.band then
    o.patchBias = g.band.bias
    o.patchThr = g.band.bias * g.band.alt
  else
    o.patchBias = g.bias or 0.45
    o.patchThr = g.thr or 0.08
  end
  -- A third surface paint: the ice-cap slot doubles as "where the patch noise
  -- is lowest" (procgen.rs: patch < −0.42), so a world with no polar caps
  -- (lat > 1 never matches) still gets scree fields, salt pans or lava flows.
  local third = g.cap or g.patch
  if third then
    o.iceCaps = { lat = g.cap and g.capLat or 1.01, slot = third.slot, color = third.color }
  end
  -- Craters, sized against the rim height (see BUILD's header).
  local n = g.craters and g.craters[1] or 0
  if n > 0 then
    local rim = math.max(relief * 0.3, 1.0)
    o.craters = n
    o.craterMin = rim * g.craters[2] / radius
    o.craterMax = rim * g.craters[3] / radius
  end
  -- Underground: ore pockets and seams, glowing where the world is hot or
  -- crystalline; a molten core on the hot ones.
  local glow = g.glow or (g.hot and "magma") or nil
  if glow == "magma" then
    o.corePaint = { slot = 6, color = { 0.98, 0.82, 0.6 } }
    o.pockets = { slot = 6, color = hsv(0.04, 0.5, 1.0), threshold = g.pocketThr - 0.04, minDepth = 6 }
    o.seam = { slot = 6, color = hsv(0.05, 0.5, 1.0), minDepth = 6, center = 0.3, width = 0.045 }
  elseif glow then
    local s = GEO_SLOT[glow]
    o.corePaint = { slot = s, color = hsv(g.glowHue or 0.75, 0.32, 0.95) }
    o.pockets = { slot = s, color = hsv(g.glowHue or 0.75, 0.32, 0.95), threshold = g.pocketThr - 0.1, minDepth = 5 }
  else
    o.corePaint = { slot = 6, color = { 0.98, 0.82, 0.6 } }
    local cold = g.family == "ice" or g.family == "frost"
    o.pockets = { slot = cold and 8 or 7, color = hsv(cold and 0.55 or 0.75, 0.3, 0.9),
      threshold = g.pocketThr, minDepth = 8 }
    o.seam = { slot = 5, color = hsv(0.08, 0.3, 0.8), minDepth = o.caveDepth * 0.5, center = 0.32, width = 0.04 }
  end
  if sc and sc.voxelHalf then
    o.voxel = math.max(1.5, (radius + relief + 2) / sc.voxelHalf)
    -- Keep the subsoil out of the SURFACE's texture. The engine (0.116) does
    -- not take a fragment's texture slot from the voxel under it: it blends the
    -- slots of the 8 nearest cells of the body's shadow atlas, which is at most
    -- 192 cells across the whole body (terrain_edit.rs TERRAIN_SHADOW_MAX_DIM,
    -- raster.wgsl terrain_splat), so ~4.4 m cells on a 340 m world. Corners up
    -- to a cell below the ground read the subsoil, so a subsoil 1.9 m down
    -- showed through the surface in lattice-shaped blobs (27% of the texture
    -- weight, the dominant texture at 13% of ground points; measured offline,
    -- seed 6). 1.5 cells down it is gone (0 points). The tint, from the vertex,
    -- was right all along: hence "two terrains fighting". Remove once the
    -- engine splats from the voxel (engine card, terrain fidelity 2026-10-14).
    local v = o.voxel
    local cell = (2 * (radius + relief) + 64 * v + 20 * v) / 192
    o.subsoilDepth = math.max(o.subsoilDepth or 0, cell * 1.5)
    o.strataDepth = math.max(o.strataDepth or 0, o.subsoilDepth + 4)
  end
  return o
end

-- ── WHOLE WORLDS (world scale 3, engine 0.117) ──────────────────────────────
--
-- The same geology, shaped with the engine's relief layers (engine card 0416,
-- docs/planet-generator.md): ridged mountain RANGES, domain WARP that folds
-- and bends the ground, PLATEAUS and TERRACES (mesas, sinter steps), real
-- OVERHANGS and arches, RAVINES, RIVERS that run downhill in valleys they
-- carve, and BIOMES that paint the surface by altitude, slope, latitude,
-- moisture and nearness to a river. `geo.future` (above) was the wish list;
-- this is where each type's wishes are granted.
--
-- Every layer's numbers come from a SECOND rng seeded from the body's own
-- terrain seed, so the main roll (which bodies, where, what type) is the one
-- scale 2's geology rolled, and two worlds of one type still part ways in
-- every layer: how tall and how sharp the ranges, how folded, how many rivers,
-- where the snowline sits.
--
-- The fbm relief is now the rolling base, not the drama: mountains carry the
-- height. Its steepness cap (GEO_MAX_SLOPE, 0.45 on scale 2) is softened to
-- GEO_MAX_SLOPE3: engine 0.117 draws everything within 64 m at full detail,
-- nothing coarser than stride 2 within 120 m (0426), and settles coarse ground
-- on slopes up to 60° (0389), so the flat-faced "pyramids" that cap fought are
-- a far-field effect now (stride 8 is still ≤ 3 m off at p95). Steeper than
-- this the fbm alone reads as noise, not landform, so the cap stays as taste.
GEO_MAX_SLOPE3 = 0.7

-- How much of its fbm relief each type keeps once mountains carry the height:
-- the ranged worlds less, the worlds whose relief IS the landform (mesas,
-- dunes, pans, crater fields) more.
RELIEF3 = {
  archipelago = 1.0, verdant = 1.2, alpine = 0.6, canyon = 2.0, steppe = 1.5, dune = 1.8,
  saltflat = 2.5, ironred = 1.3, tundra = 1.4, glacial = 0.6, volcanic = 0.8, sulfur = 2.0,
  greenhouse = 1.0, crystal = 0.8, titan = 1.4, frost = 1.6, regolith = 1.5, maria = 1.6,
}

-- One biome rule: a paint plus its ranges.
local function rule(p, t)
  t.slot, t.color = p.slot, p.color
  return t
end

-- What each type does with the layers. `q` is the layer rng, `R` the radius,
-- `o` the opts so far (relief, bumpFreq set), `w` = { seaAlt, rock, ... } the
-- shared facts. Each returns its biome rules (first match wins, so the order
-- is the geology: under the sea, then the shore, then the cliffs, then the
-- heights, then the wet ground; what nothing matches falls back to the
-- surface A/B paints).
local LAYERS3 = {}

local function mountains(q, R, h, sharp, cover, scale)
  return { height = R * h, scale = scale, sharpness = sharp, coverage = cover, octaves = 5 }
end

-- Shared rule makers.
local function seabedRules(g, w, rules)
  if w.seaAlt then
    rules[#rules + 1] = rule(w.rockP, { altitude = { -9999, w.seaAlt - 2.5 } })
    rules[#rules + 1] = rule(w.beachP, { altitude = { w.seaAlt - 2.5, w.seaAlt + w.beach } })
  end
end

LAYERS3.archipelago = function(q, g, R, o, w)
  o.mountains = mountains(q, R, q:range(0.04, 0.075), q:range(1.4, 2.2), q:range(0.35, 0.55), q:range(5, 9))
  o.warp = { strength = q:range(0.06, 0.16), scale = q:range(2, 4) }
  if q:next() < 0.5 then o.overhangs = { depth = 10, scale = q:range(0.05, 0.09), strength = q:range(2, 3.5) } end
  o.rivers = { count = q:int(3, 6), width = q:range(8, 14), depth = q:range(4, 7), meander = q:range(0.6, 1.4) }
  local rules = {}
  seabedRules(g, w, rules)
  rules[#rules + 1] = rule(w.rockP, { slope = { q:range(36, 44), 90 } })
  rules[#rules + 1] = rule(g.high, { nearRiver = q:range(14, 30) })
  rules[#rules + 1] = rule(g.high, { moisture = { q:range(-0.4, 0.0), 1 } })
  return rules
end

LAYERS3.verdant = function(q, g, R, o, w)
  o.mountains = mountains(q, R, q:range(0.02, 0.045), q:range(1.2, 1.8), q:range(0.2, 0.4), q:range(4, 8))
  o.warp = { strength = q:range(0.1, 0.22), scale = q:range(2, 4) }
  o.rivers = { count = q:int(5, 8), width = q:range(10, 18), depth = q:range(4, 6), meander = q:range(1.2, 2.2) }
  local rules = {}
  seabedRules(g, w, rules)
  rules[#rules + 1] = rule(w.rockP, { slope = { 40, 90 } })
  rules[#rules + 1] = rule(g.low, { nearRiver = q:range(25, 50) })
  rules[#rules + 1] = rule(g.patch, { moisture = { q:range(0.25, 0.45), 1 } })
  return rules
end

LAYERS3.alpine = function(q, g, R, o, w)
  o.mountains = mountains(q, R, q:range(0.09, 0.14), q:range(2.4, 3.6), q:range(0.45, 0.65), q:range(4, 7.5))
  o.warp = { strength = q:range(0.06, 0.14), scale = q:range(2.5, 4) }
  o.overhangs = { depth = q:range(12, 18), scale = q:range(0.04, 0.07), strength = q:range(3, 5) }
  o.rivers = { count = q:int(4, 7), width = q:range(7, 11), depth = q:range(5, 8), meander = q:range(0.5, 1.0) }
  if q:next() < 0.35 then o.ravines = { count = q:int(1, 3), depth = q:range(20, 35), width = q:range(10, 16), length = R * q:range(0.5, 1.0), meander = 1.2 } end
  local snow = o.mountains.height * q:range(0.35, 0.6)
  w.snowline = snow
  local rules = {}
  seabedRules(g, w, rules)
  rules[#rules + 1] = rule(w.rockP, { slope = { q:range(34, 40), 90 } })
  rules[#rules + 1] = rule(g.high, { altitude = { snow, 9999 } })
  rules[#rules + 1] = rule(w.screeP, { altitude = { snow * 0.7, snow } })
  rules[#rules + 1] = rule(w.meadowP, { nearRiver = q:range(18, 35) })
  return rules
end

LAYERS3.canyon = function(q, g, R, o, w)
  o.warp = { strength = q:range(0.12, 0.26), scale = q:range(2, 3.5) }
  o.plateau = { height = o.relief * q:range(0.35, 0.7), smooth = q:range(1, 3) }
  o.terrace = { step = q:range(3.5, 7), sharpness = q:range(0.7, 0.92) }
  o.ravines = { count = q:int(5, 9), depth = q:range(22, 42), width = q:range(14, 28), length = R * q:range(0.8, 2.0), meander = q:range(0.8, 1.8) }
  if q:next() < 0.6 then o.overhangs = { depth = 10, scale = q:range(0.05, 0.08), strength = q:range(2, 3) } end
  if w.seaAlt or q:next() < 0.4 then
    o.rivers = { count = q:int(1, 3), width = q:range(8, 12), depth = q:range(5, 9), meander = 1.4 }
  end
  local rules = {}
  seabedRules(g, w, rules)
  rules[#rules + 1] = rule(w.bandP, { slope = { q:range(30, 38), 90 } })
  rules[#rules + 1] = rule(g.low, { altitude = { -9999, -o.relief * q:range(0.1, 0.3) } })
  return rules
end

LAYERS3.steppe = function(q, g, R, o, w)
  if q:next() < 0.5 then o.mountains = mountains(q, R, q:range(0.02, 0.04), q:range(1.0, 1.6), q:range(0.1, 0.25), q:range(3, 6)) end
  o.warp = { strength = q:range(0.15, 0.3), scale = q:range(1.5, 3) }
  o.rivers = { count = q:int(3, 6), width = q:range(9, 14), depth = q:range(3, 5), meander = q:range(1.5, 2.5) }
  local rules = {}
  seabedRules(g, w, rules)
  rules[#rules + 1] = rule(w.rockP, { slope = { 32, 90 } })
  rules[#rules + 1] = rule(w.meadowP, { nearRiver = q:range(20, 40) })
  rules[#rules + 1] = rule(g.high, { moisture = { q:range(-0.2, 0.2), 1 } })
  return rules
end

LAYERS3.dune = function(q, g, R, o, w)
  o.warp = { strength = q:range(0.2, 0.4), scale = q:range(3, 6) }
  if q:next() < 0.5 then
    o.mountains = mountains(q, R, q:range(0.02, 0.04), q:range(3, 5), q:range(0.08, 0.2), q:range(6, 10))
  end
  if q:next() < 0.3 then o.ravines = { count = q:int(1, 3), depth = q:range(10, 20), width = q:range(14, 24), length = R * 0.8, meander = 1.5 } end
  local rules = {}
  seabedRules(g, w, rules)
  rules[#rules + 1] = rule(w.bandP, { slope = { 30, 90 } })
  return rules
end

LAYERS3.saltflat = function(q, g, R, o, w)
  o.plateau = { height = o.relief * q:range(0.1, 0.5), smooth = q:range(2, 5) }
  o.terrace = { step = q:range(2, 4), sharpness = q:range(0.5, 0.8) }
  o.warp = { strength = q:range(0.05, 0.15), scale = 2.5 }
  if q:next() < 0.4 then o.ravines = { count = q:int(1, 4), depth = q:range(8, 16), width = q:range(10, 18), length = R * 0.7, meander = 1.0 } end
  local rules = {}
  rules[#rules + 1] = rule(g.low, { altitude = { -9999, -o.relief * q:range(0.05, 0.25) } })
  rules[#rules + 1] = rule(w.rockP, { slope = { 22, 90 } })
  return rules
end

LAYERS3.ironred = function(q, g, R, o, w)
  if q:next() < 0.55 then
    -- A shield volcano province: broad, soft-crested ranges.
    o.mountains = mountains(q, R, q:range(0.05, 0.1), q:range(0.8, 1.3), q:range(0.2, 0.35), q:range(2, 4))
  end
  o.warp = { strength = q:range(0.08, 0.2), scale = 2.5 }
  o.ravines = { count = q:int(3, 7), depth = q:range(18, 40), width = q:range(18, 34), length = R * q:range(1.0, 2.2), meander = q:range(0.4, 1.0) }
  if not o.mountains and q:next() < 0.6 then
    -- …or mesa country (exclusive: a plateau would plane the shields flat).
    o.plateau = { height = o.relief * 0.5, smooth = 2 }; o.terrace = { step = q:range(4, 8), sharpness = 0.8 }
  end
  local rules = {}
  rules[#rules + 1] = rule(w.rockP, { slope = { 33, 90 } })
  rules[#rules + 1] = rule(g.dust, { altitude = { -9999, -o.relief * 0.35 } })
  return rules
end

LAYERS3.tundra = function(q, g, R, o, w)
  if q:next() < 0.5 then o.mountains = mountains(q, R, q:range(0.025, 0.05), q:range(1.5, 2.5), q:range(0.15, 0.3), q:range(4, 7)) end
  o.warp = { strength = q:range(0.05, 0.15), scale = 3 }
  o.rivers = { count = q:int(5, 8), width = q:range(7, 12), depth = q:range(3, 5), meander = q:range(1.6, 2.6) }
  local rules = {}
  seabedRules(g, w, rules)
  rules[#rules + 1] = rule(w.rockP, { slope = { 34, 90 } })
  rules[#rules + 1] = rule(g.patch, { latitude = { q:range(55, 70), 90 } })
  rules[#rules + 1] = rule(g.low, { nearRiver = q:range(15, 30) })
  return rules
end

LAYERS3.glacial = function(q, g, R, o, w)
  -- A smooth ice sheet with nunataks standing through it and crevasse
  -- fields. (No plateau: the engine planes AFTER the ranges, so a plateau
  -- would shave the nunataks off with the sheet.)
  o.mountains = mountains(q, R, q:range(0.05, 0.1), q:range(2.5, 4), q:range(0.15, 0.3), q:range(5, 9))
  o.ravines = { count = q:int(4, 9), depth = q:range(14, 26), width = q:range(5, 9), length = R * q:range(0.4, 0.9), meander = q:range(0.3, 0.9) }
  if q:next() < 0.5 then o.overhangs = { depth = 12, scale = q:range(0.06, 0.1), strength = q:range(2.5, 4) } end
  local rules = {}
  seabedRules(g, w, rules)
  rules[#rules + 1] = rule(w.rockP, { slope = { 36, 90 } })
  rules[#rules + 1] = rule(g.high, { altitude = { o.relief * 0.3, 9999 } })
  return rules
end

LAYERS3.volcanic = function(q, g, R, o, w)
  o.mountains = mountains(q, R, q:range(0.07, 0.12), q:range(0.9, 1.6), q:range(0.3, 0.5), q:range(2.5, 5))
  o.warp = { strength = q:range(0.05, 0.12), scale = 3 }
  o.ravines = { count = q:int(2, 5), depth = q:range(10, 22), width = q:range(8, 14), length = R * q:range(0.6, 1.4), meander = 1.6 }
  o.overhangs = { depth = q:range(8, 12), scale = q:range(0.06, 0.1), strength = q:range(2, 3.5) }
  local rules = {}
  rules[#rules + 1] = rule(w.rockP, { slope = { 32, 90 } })
  rules[#rules + 1] = rule(g.high, { altitude = { o.mountains.height * q:range(0.25, 0.45), 9999 } })
  return rules
end

LAYERS3.sulfur = function(q, g, R, o, w)
  o.terrace = { step = q:range(1.5, 3), sharpness = q:range(0.6, 0.9) }
  o.plateau = { height = o.relief * q:range(0.3, 0.6), smooth = 2 }
  o.warp = { strength = q:range(0.1, 0.2), scale = 3 }
  local rules = {}
  rules[#rules + 1] = rule(w.rockP, { slope = { 30, 90 } })
  rules[#rules + 1] = rule(g.low, { moisture = { q:range(0.0, 0.35), 1 } })
  return rules
end

LAYERS3.greenhouse = function(q, g, R, o, w)
  -- Tesserae: folded, ridged, terraced crust.
  o.mountains = mountains(q, R, q:range(0.04, 0.07), q:range(2.5, 3.5), q:range(0.4, 0.6), q:range(6, 10))
  o.warp = { strength = q:range(0.2, 0.35), scale = q:range(3, 5) }
  o.terrace = { step = q:range(4, 8), sharpness = q:range(0.4, 0.7) }
  o.ravines = { count = q:int(2, 5), depth = q:range(12, 24), width = q:range(10, 18), length = R * 1.2, meander = 1.6 }
  local rules = {}
  rules[#rules + 1] = rule(w.rockP, { slope = { 30, 90 } })
  return rules
end

LAYERS3.crystal = function(q, g, R, o, w)
  -- Spires and arches.
  o.mountains = mountains(q, R, q:range(0.07, 0.12), q:range(4, 6), q:range(0.35, 0.6), q:range(8, 14))
  o.overhangs = { depth = q:range(14, 20), scale = q:range(0.05, 0.08), strength = q:range(5, 8) }
  o.warp = { strength = q:range(0.05, 0.15), scale = 3 }
  local rules = {}
  rules[#rules + 1] = rule(g.high, { slope = { 34, 90 } })
  rules[#rules + 1] = rule(g.patch, { moisture = { q:range(0.3, 0.5), 1 } })
  return rules
end

LAYERS3.titan = function(q, g, R, o, w)
  o.warp = { strength = q:range(0.2, 0.35), scale = q:range(4, 7) }
  if q:next() < 0.5 then o.mountains = mountains(q, R, q:range(0.025, 0.05), 1.6, q:range(0.15, 0.3), 5) end
  o.rivers = { count = q:int(5, 8), width = q:range(8, 14), depth = q:range(4, 6), meander = q:range(1.0, 2.0) }
  local rules = {}
  seabedRules(g, w, rules)
  rules[#rules + 1] = rule(g.high, { slope = { 30, 90 } })
  rules[#rules + 1] = rule(g.patch, { nearRiver = q:range(12, 24) })
  return rules
end

LAYERS3.frost = function(q, g, R, o, w)
  o.ravines = { count = q:int(4, 9), depth = q:range(12, 26), width = q:range(8, 16), length = R * q:range(0.8, 2.0), meander = q:range(0.2, 0.6) }
  if q:next() < 0.5 then o.plateau = { height = o.relief * 0.5, smooth = 2 } end
  if q:next() < 0.4 then o.warp = { strength = q:range(0.1, 0.25), scale = 4 } end   -- chaos terrain
  local rules = {}
  rules[#rules + 1] = rule(w.rockP, { slope = { 34, 90 } })
  return rules
end

LAYERS3.regolith = function(q, g, R, o, w)
  if q:next() < 0.5 then o.mountains = mountains(q, R, q:range(0.03, 0.06), q:range(1.0, 1.6), q:range(0.1, 0.25), q:range(4, 8)) end
  if q:next() < 0.3 then o.ravines = { count = q:int(1, 3), depth = q:range(8, 14), width = q:range(8, 14), length = R * 0.8, meander = 1.8 } end
  local rules = {}
  rules[#rules + 1] = rule(w.rockP, { slope = { 30, 90 } })
  return rules
end

LAYERS3.maria = function(q, g, R, o, w)
  -- Flooded basins planed flat, wrinkle ridges, sinuous rilles.
  o.plateau = { height = o.relief * q:range(-0.2, 0.2), smooth = q:range(3, 6) }
  o.ravines = { count = q:int(2, 5), depth = q:range(6, 12), width = q:range(8, 14), length = R * q:range(0.6, 1.4), meander = q:range(1.6, 2.6) }
  local rules = {}
  rules[#rules + 1] = rule(w.rockP, { slope = { 28, 90 } })
  rules[#rules + 1] = rule(g.low, { altitude = { -9999, o.plateau.height - 1 } })
  return rules
end

-- The planet's sea level (metres above the radius) for a geology on scale 3,
-- or nil when dry. Read by geoOpts3 and by buildSystem, so the water and the
-- shoreline the terrain paints are one number.
local function seaAlt3(g, relief)
  return g.sea and (relief * g.sea.alt) or nil
end

-- The geology as terrain.generatePlanet opts, with the 0.117 relief layers.
-- Returns the opts and a `shape` table the rest of the generator reads: the
-- sea's altitude, the highest and lowest ground the layers can make, and
-- whether the world has rivers (so lakes and rivers are worth asking for).
function geoOpts3(g, radius, caveScale, sc, seed)
  local q = rng(((seed or 1) * 7 + 911) % 4294967291 + 1)
  -- The fbm base: the world's relief fraction (16% cap as on scale 2), then
  -- each world's own share of it — the ranges are the mountains' job now.
  local relief = radius * math.min(g.relief, 0.16) * q:range(0.35, 0.6) * (RELIEF3[g.type] or 1)
  relief = math.min(relief, radius * 0.16, GEO_MAX_SLOPE3 * radius / math.max(g.bumpFreq * math.sqrt(radius / 310), 0.5))
  local cave = math.min(radius * g.cave, sc.caveMax or 1e9)
  local o = {
    radius = radius,
    relief = relief,
    -- A big world wants more, smaller hills than a small one: the base
    -- frequency is "bumps across the sphere".
    bumpFreq = g.bumpFreq * math.sqrt(radius / 310),
    caveDepth = cave * (caveScale or 1),
    deferCaves = true,
    coreR = math.max(radius * 0.07, 5),
    surfaceA = g.high,
    surfaceB = g.low,
    subsoil = g.subsoil, subsoilDepth = g.subsoilDepth,
    strata = g.strata, strataDepth = g.strataDepth,
    deep = g.deep,
    craterDust = g.dust,
    moistureScale = q:range(2, 7),
  }
  if g.band then
    o.patchBias = g.band.bias
    o.patchThr = g.band.bias * g.band.alt
  else
    o.patchBias = g.bias or 0.45
    o.patchThr = g.thr or 0.08
  end
  local third = g.cap or g.patch
  if third then
    o.iceCaps = { lat = g.cap and g.capLat or 1.01, slot = third.slot, color = third.color }
  end
  -- The shared paints the rules reach for: the world's rock (its strata, which
  -- is what a cliff cuts through), a beach, scree, a meadow by the rivers and
  -- a banded cliff for the canyon country.
  local seaA = seaAlt3(g, relief)
  local w = {
    seaAlt = seaA,
    beach = q:range(1.5, 3.5),
    rockP = g.strata,
    beachP = M(q, (g.family == "ice") and "scree" or q:pick({ "sand", "sand", "scree", "basalt" }), 0.1, 0.05, 0.7),
    screeP = M(q, "scree", 0.08, 0.04, 0.62),
    meadowP = M(q, q:pick({ "moss", "litter", "tundra" }), 0.2, 0.08, 0.64),
    bandP = M(q, q:pick({ "sandstone", "onyx", "limestone", "shale" }), q:range(0.02, 0.09), q:range(0.1, 0.3), 0.66),
  }
  local rules = LAYERS3[g.type] and LAYERS3[g.type](q, g, radius, o, w) or {}
  -- Every world, whatever its type, gets a little more of its own: a fold to
  -- its ground, sometimes an undercut cliff or a terraced slope.
  if not o.warp then o.warp = { strength = q:range(0.03, 0.1), scale = q:range(2, 4) } end
  if not o.overhangs and q:next() < 0.2 then
    o.overhangs = { depth = 10, scale = q:range(0.05, 0.09), strength = q:range(1.5, 3) }
  end
  if not o.terrace and (o.mountains or o.plateau) and q:next() < 0.15 then
    o.terrace = { step = q:range(3, 6), sharpness = q:range(0.3, 0.7) }
  end
  if o.rivers then o.rivers.seaLevel = seaA or -relief * q:range(0.3, 0.6) end
  if #rules > 0 then o.biomes = rules end
  -- Craters as on scale 2, sized against the rim height.
  local n = g.craters and g.craters[1] or 0
  if n > 0 then
    local rim = math.max(relief * 0.3, 1.0)
    o.craters = n
    o.craterMin = rim * g.craters[2] / radius
    o.craterMax = rim * g.craters[3] / radius
  end
  -- Underground, as on scale 2.
  local glow = g.glow or (g.hot and "magma") or nil
  if glow == "magma" then
    o.corePaint = { slot = 6, color = { 0.98, 0.82, 0.6 } }
    o.pockets = { slot = 6, color = hsv(0.04, 0.5, 1.0), threshold = g.pocketThr - 0.04, minDepth = 6 }
    o.seam = { slot = 6, color = hsv(0.05, 0.5, 1.0), minDepth = 6, center = 0.3, width = 0.045 }
  elseif glow then
    local s = GEO_SLOT[glow]
    o.corePaint = { slot = s, color = hsv(g.glowHue or 0.75, 0.32, 0.95) }
    o.pockets = { slot = s, color = hsv(g.glowHue or 0.75, 0.32, 0.95), threshold = g.pocketThr - 0.1, minDepth = 5 }
  else
    o.corePaint = { slot = 6, color = { 0.98, 0.82, 0.6 } }
    local cold = g.family == "ice" or g.family == "frost"
    o.pockets = { slot = cold and 8 or 7, color = hsv(cold and 0.55 or 0.75, 0.3, 0.9),
      threshold = g.pocketThr, minDepth = 8 }
    o.seam = { slot = 5, color = hsv(0.08, 0.3, 0.8), minDepth = o.caveDepth * 0.5, center = 0.32, width = 0.04 }
  end
  -- The voxel follows the radius: memory and a dug save go as (radius/voxel)²
  -- (see SCALES[3]).
  o.voxel = math.max(1.5, math.min(sc.voxelMax or 2.4, radius / (sc.voxelSpan or 470)))
  -- The subsoil is painted by depth under the UNDISTURBED ground (procgen.rs
  -- paint(): radius + relief-grid height − r), but the overhang layer moves the
  -- real surface by up to its strength either way, so a subsoil shallower than
  -- that shows on undug ground wherever the overhang noise dips (measured: a
  -- red test subsoil 1.5 m down blotched a whole world with overhangs 6 m
  -- strong, and none without). Keep it a voxel past the overhangs' reach.
  -- (The 0.116 shadow-atlas bleed scale 2 dodged with a subsoil 1.5 atlas
  -- cells down — 14 m on an 800 m world — is fixed, engine card 0425: undug
  -- ground takes its slot from a quarter voxel inside the surface.)
  -- Two voxels down the splat shows it at 0.5% of undug ground (offline
  -- emulation of the 0.117 splat on Golun, terrain-fidelity agent: 1.6% at
  -- one voxel, 0.06% at 3.4).
  -- A cell of the atlas (7.6–8.8 m here) is past the field's ±4-voxel band,
  -- and on 0.117.0-rc3 the subsoil showed through undug ground as a lattice
  -- of 9–15 m blotches, so the subsoil was held 1.5 atlas cells down. Since
  -- 0.117.0-rc6 (card 0425) a triangle whose corners carry one slot draws
  -- from that slot alone: with no atlas floor the red-subsoil test world
  -- shows 0.19% red from 250 m (rc3: 11.4%), and the floor goes.
  local lean = o.overhangs and o.overhangs.strength or 0
  o.subsoilDepth = math.max(o.subsoilDepth or 0, 2 * o.voxel, lean + o.voxel)
  o.strataDepth = math.max(o.strataDepth or 0, o.subsoilDepth + 4)
  -- What the layers can do to the height, for the spawn, the occluder and the
  -- published relief: peaks stand up to the fbm plus the ranges (a plateau
  -- planes them off), the cuts go down by the deepest channel.
  local hi = relief + (o.mountains and o.mountains.height or 0)
  if o.plateau then hi = math.min(hi, math.max(o.plateau.height, 0) + relief * 0.25 + 2) end
  hi = hi + lean
  local cut = math.max(o.ravines and o.ravines.depth or 0, o.rivers and o.rivers.depth or 0)
  local shape = { seaAlt = seaA, peak = hi, low = relief + cut + lean, rivers = o.rivers ~= nil,
    snowline = w.snowline }
  return o, shape
end

-- ── THE HOME WORLD (homeGen 2, scale 3) ─────────────────────────────────────
--
-- The save's first planet is where the campaign happens: the programme sends
-- you after rare plants on ravine floors, high peaks, under overhangs, at lake
-- shores and on riverbanks, and after Star Geodes underground. A rolled world
-- can be airless, or dry, or have no ravines (seed 1815586866 rolled an
-- airless regolith ball), so from homeGen 2 the home world is BUILT, not
-- rolled:
--
--   * habitable: air, a temperate climate, a sea, rivers and lakes
--   * mountainous north and south polar caps, peaks above a snow line
--   * several long ravines and overhangs (shelters, undercut cliffs)
--   * elsewhere rolling lowland, and a flat equatorial plain for the base,
--     published as `lastBaseDir` (the base agent's siting contract)
--
-- THE VERSION. A save keeps the home recipe it was made with (`g_homeGen`):
-- a save from before has none and is 1 — its home is the rolled world, which
-- must regenerate exactly (tests/smoke_world_scale.lua). A new save is
-- HOME_GEN. Scale 1 and 2 saves are never anything but 1.
--
-- THE STREAMS. The home world's numbers come from its own rng (seeded off the
-- terrain seed the main roll drew for it), and the main roll draws exactly what
-- it drew before, so every other body in the system is the world it always
-- was for that seed: only home changes.
--
-- WHY A SEARCH. Engine 0.117 has no latitude mask on any relief layer: the
-- mountain ranges stand "where a slow mask is high" (relief.rs Layers::height:
-- smoothstep of a 3-octave fbm at 0.3 × the range scale), and every other
-- layer is laid without regard to latitude. Lua's math.noise / math.fbm are
-- the generator's own noise, bit for bit, so the mask can be evaluated here
-- before anything generates: the home roll tries a few thousand (terrain seed,
-- range scale) pairs, keeps the one whose mask stands highest over both poles
-- and lowest over the equator, and sets the coverage threshold between them.
-- ~20k math.fbm calls (~6 ms). Without the engine's noise (the offline
-- harness) the first candidate is taken.
HOME_GEN = 2

-- The home recipe a roll runs: explicit (`p.homeGen`), else the save's
-- `g_homeGen`, else 1 for a save that has already been played and HOME_GEN for
-- a fresh one (written back so it never changes). Only scale 3+ has one.
function homeGenFor(p)
  local sc = scaleOf(p.scale)
  if not sc.layers then return 1 end
  if p.homeGen then return tonumber(p.homeGen) or 1 end
  if not (save and save.get) then return 1 end
  local v = save.get("g_homeGen")
  if v ~= nil then return tonumber(v) or 1 end
  local old = save.get("g_played") ~= nil or save.get("base.body") ~= nil
    or save.get("system.home") ~= nil or save.get("parts.rating") ~= nil
    or save.get("fleet.next") ~= nil
  v = old and 1 or HOME_GEN
  if save.set then save.set("g_homeGen", v) end
  return v
end

-- The home world's latitude targets (degrees).
HOME_POLAR = 62       -- the caps: ranges wanted above this
HOME_EQUATOR = 32     -- the lowland: no ranges wanted below this
HOME_SEARCH = 3000    -- (seed, scale) pairs the mask search tries
HOME_SITE_R = 250     -- the flat zone kept round the base site (arc metres)
HOME_RELIEF = { 0.010, 0.0135 }   -- the rolling lowland's fbm relief, × radius
HOME_BUMP = { 1.4, 2.0 }          -- …and its frequency (× √(radius / 310))

local function hrot(x, y, z)
  return 0.36 * x - 0.80 * y + 0.48 * z, 0.80 * x + 0.52 * y + 0.30 * z, -0.48 * x + 0.30 * y + 0.82 * z
end

-- The engine's ridged noise from math.noise (floptle-core noise.rs `ridged`).
local function ridged(x, y, z, oct, sharp, seed)
  local amp, sum, norm = 1, 0, 0
  for i = 0, oct - 1 do
    local o = i * 19.19
    local n = math.min(1, math.abs(math.noise(x + o, y + o, z + o, seed)))
    sum = sum + (1 - n) ^ sharp * amp
    norm = norm + amp
    amp = amp * 0.5
    x, y, z = hrot(x, y, z)
    x, y, z = x * 2.03, y * 2.03, z * 2.03
  end
  return sum / math.max(norm, 1e-6)
end

local function sstep(a, b, x)
  local t = math.max(0, math.min(1, (x - a) / math.max(b - a, 1e-6)))
  return t * t * (3 - 2 * t)
end

-- Can this Lua see the generator's noise?
local function has_noise() return math.fbm ~= nil and math.noise ~= nil end

-- The raw range-mask field (before its threshold) in unit direction d.
local function mask_raw(seed, scale, dx, dy, dz)
  local s = scale * 0.3
  return 0.5 + 0.5 * math.fbm(dx * s + 241, dy * s + 241, dz * s + 241, 3, seed)
end

-- The ground's height above the radius in unit direction d, as relief.rs
-- Layers::height works it out for the home opts (no warp, plateau or terrace),
-- before the channels are carved; with `lean`, moved by the overhang layer as
-- procgen.rs ground_with does at the surface (body + strength · fbm).
function homeHeight(o, dx, dy, dz, lean)
  if not has_noise() then return 0 end
  local seed = o.seed or 1
  local h = math.fbm(dx * o.bumpFreq, dy * o.bumpFreq, dz * o.bumpFreq, 5, seed) * o.relief
  local m = o.mountains
  if m then
    local edge = 1 - math.max(0, math.min(1, m.coverage))
    local mask = sstep(edge - 0.12, edge + 0.12, mask_raw(seed, m.scale, dx, dy, dz))
    if mask > 0 then
      h = h + m.height * mask * ridged(dx * m.scale + 57, dy * m.scale + 57, dz * m.scale + 57,
        math.max(1, math.min(8, m.octaves or 5)), math.max(0.1, m.sharpness), seed)
    end
  end
  local oh = o.overhangs
  if lean and oh and oh.strength ~= 0 then
    local r, sc_ = o.radius + h, oh.scale
    h = h - oh.strength * math.fbm(dx * r * sc_ + 431, dy * r * sc_ + 431, dz * r * sc_ + 431, 3, seed)
  end
  return h
end

-- Fibonacci directions, optionally only those inside a latitude test.
local function fib_dirs(n, keep)
  local out, ga = {}, math.pi * (3 - math.sqrt(5))
  for i = 0, n - 1 do
    local y = 1 - (i + 0.5) / n * 2
    local rr = math.sqrt(math.max(0, 1 - y * y))
    local lat = math.deg(math.asin(y))
    if not keep or keep(lat) then out[#out + 1] = { math.cos(ga * i) * rr, y, math.sin(ga * i) * rr, lat = lat } end
  end
  return out
end

local function quant(t, f)
  table.sort(t)
  return t[math.max(1, math.min(#t, math.floor(#t * f + 0.5)))]
end

-- Score a (seed, scale): the polar caps' median mask field against the
-- equator band's 90th percentile. → gap, the threshold between them.
local function mask_gap(seed, scale, dirs)
  local pn, ps, pe = {}, {}, {}
  for _, d in ipairs(dirs) do
    local f = mask_raw(seed, scale, d[1], d[2], d[3])
    if d.lat > HOME_POLAR then pn[#pn + 1] = f
    elseif d.lat < -HOME_POLAR then ps[#ps + 1] = f
    else pe[#pe + 1] = f end
  end
  if #pn == 0 or #ps == 0 or #pe == 0 then return -1, 0.5 end
  local lo = math.min(quant(pn, 0.5), quant(ps, 0.5))
  local hi = quant(pe, 0.9)
  return lo - hi, (lo + hi) * 0.5
end

-- The mountain ranges for the home world: the best of HOME_SEARCH (seed,
-- scale) pairs. Returns seed, scale, coverage, and the stats it was picked by.
local function home_ranges(q)
  local cands = {}
  for k = 1, HOME_SEARCH do cands[k] = { seed = q:int(1, 1e9), scale = q:range(3.2, 6.0) } end
  if not has_noise() then
    local c = cands[1]
    return c.seed, c.scale, 0.5, { gap = 0, searched = 0 }
  end
  -- A coarse look at everything (both caps and the equator band, 30 points),
  -- then a fine one at the best few.
  local coarse = fib_dirs(160, function(lat) return math.abs(lat) > HOME_POLAR or math.abs(lat) < HOME_EQUATOR end)
  local pre = {}
  for _, d in ipairs(coarse) do
    if math.abs(d.lat) > HOME_POLAR or (#pre < 40 and math.abs(d.lat) < HOME_EQUATOR) then pre[#pre + 1] = d end
  end
  for _, c in ipairs(cands) do c.g = mask_gap(c.seed, c.scale, pre) end
  table.sort(cands, function(a, b) if a.g ~= b.g then return a.g > b.g end return a.seed < b.seed end)
  local fine = fib_dirs(1200, function(lat) return math.abs(lat) > HOME_POLAR or math.abs(lat) < HOME_EQUATOR end)
  local best, bestS = nil, -1e9
  for i = 1, math.min(48, #cands) do
    local c = cands[i]
    local g, thr = mask_gap(c.seed, c.scale, fine)
    -- The mask the threshold makes: wanted high over the caps, low elsewhere.
    local edge = thr
    local cap, eq, nc, ne, eqHigh = { 0, 0 }, 0, { 0, 0 }, 0, 0
    for _, d in ipairs(fine) do
      local m = sstep(edge - 0.12, edge + 0.12, mask_raw(c.seed, c.scale, d[1], d[2], d[3]))
      if d.lat > HOME_POLAR then cap[1] = cap[1] + m; nc[1] = nc[1] + 1
      elseif d.lat < -HOME_POLAR then cap[2] = cap[2] + m; nc[2] = nc[2] + 1
      else
        eq = eq + m; ne = ne + 1
        if m > 0.5 then eqHigh = eqHigh + 1 end
      end
    end
    local cn, cs, ce = cap[1] / math.max(nc[1], 1), cap[2] / math.max(nc[2], 1), eq / math.max(ne, 1)
    eqHigh = eqHigh / math.max(ne, 1)
    -- Both caps high (the weaker one counts), the lowland low, and as few
    -- ranges standing in it as possible.
    local s = math.min(cn, cs) * 2 - ce * 4 - eqHigh * 6 + g
    if s > bestS then
      bestS = s
      best = { seed = c.seed, scale = c.scale, cov = 1 - edge, gap = g, capN = cn, capS = cs, eq = ce, eqHigh = eqHigh }
    end
  end
  best.searched = #cands
  return best.seed, best.scale, best.cov, best
end

-- The home world's terrain opts and shape. `g` its geology (rolled from the
-- home stream), `q` the home stream.
function homeOpts3(g, radius, caveScale, sc, q)
  local relief = radius * q:range(HOME_RELIEF[1], HOME_RELIEF[2])
  local seaFrac = q:range(0.32, 0.5)
  local mH = radius * q:range(0.11, 0.135)
  local sharp = q:range(2.2, 2.9)
  local seed, mscale, cov, stats = home_ranges(q)
  local o = {
    seed = seed,
    radius = radius,
    relief = relief,
    -- Broad rolling lowland: a few big swells across the sphere.
    bumpFreq = q:range(HOME_BUMP[1], HOME_BUMP[2]) * math.sqrt(radius / 310),
    caveDepth = math.min(radius * g.cave, sc.caveMax or 1e9) * (caveScale or 1),
    deferCaves = true,
    coreR = math.max(radius * 0.07, 5),
    surfaceA = g.high, surfaceB = g.low,
    subsoil = g.subsoil, subsoilDepth = g.subsoilDepth,
    strata = g.strata, strataDepth = g.strataDepth,
    deep = g.deep,
    craterDust = g.dust,
    moistureScale = q:range(2.5, 5),
    patchBias = g.band and g.band.bias or (g.bias or 0.45),
    patchThr = g.band and (g.band.bias * g.band.alt) or (g.thr or 0.08),
    mountains = { height = mH, scale = mscale, sharpness = sharp, coverage = cov, octaves = 5 },
    -- Several long ravines, wherever they fall (the base site avoids them).
    ravines = { count = q:int(5, 7), depth = q:range(20, 30), width = q:range(12, 18),
      length = radius * q:range(1.1, 1.7), meander = q:range(0.8, 1.4) },
    -- Undercut cliffs and shelters on every steep face: the cave niche.
    overhangs = { depth = q:range(12, 16), scale = q:range(0.05, 0.07), strength = q:range(3.0, 3.8) },
  }
  local seaAlt = -relief * seaFrac
  o.rivers = { count = q:int(5, 7), width = q:range(9, 13), depth = q:range(4, 6),
    meander = q:range(1.0, 1.8), seaLevel = seaAlt }
  -- The snow line: well up the ranges, so their crests stand white over
  -- bare rock and scree.
  local snow = relief * 0.5 + mH * q:range(0.3, 0.4)
  local rock = g.strata
  local beach = M(q, q:pick({ "sand", "sand", "scree" }), 0.1, 0.05, 0.7)
  local scree = M(q, "scree", 0.08, 0.04, 0.62)
  local snowP = M(q, "snow", 0.58, 0.03, 0.74)
  local glacier = M(q, "glacier", 0.55, 0.05, 0.68)
  local tundra = M(q, "tundra", 0.15, 0.06, 0.64)
  local meadow = M(q, q:pick({ "moss", "litter" }), 0.2, 0.08, 0.64)
  local polar = q:range(70, 76)
  o.biomes = {
    rule(rock, { altitude = { -9999, seaAlt - 2.5 } }),
    rule(beach, { altitude = { seaAlt - 2.5, seaAlt + q:range(1.5, 3) } }),
    rule(rock, { slope = { q:range(36, 42), 90 } }),
    rule(snowP, { altitude = { snow, 9999 } }),
    rule(glacier, { latitude = { polar, 90 } }),
    rule(scree, { altitude = { snow * 0.72, snow } }),
    rule(tundra, { latitude = { polar - 12, polar } }),
    rule(meadow, { nearRiver = q:range(18, 32) }),
    rule(g.high, { moisture = { q:range(-0.3, 0.1), 1 } }),
  }
  -- No ice-cap paint: it also frosts low patch-noise spots at any latitude.
  if g.patch then o.iceCaps = { lat = 1.01, slot = g.patch.slot, color = g.patch.color } end
  o.corePaint = { slot = 6, color = { 0.98, 0.82, 0.6 } }
  o.pockets = { slot = 7, color = hsv(0.75, 0.3, 0.9), threshold = g.pocketThr, minDepth = 8 }
  o.seam = { slot = 5, color = hsv(0.08, 0.3, 0.8), minDepth = o.caveDepth * 0.5, center = 0.32, width = 0.04 }
  o.voxel = math.max(1.5, math.min(sc.voxelMax or 2.4, radius / (sc.voxelSpan or 470)))
  -- The subsoil under the overhangs' reach (geoOpts3).
  local lean = o.overhangs.strength
  o.subsoilDepth = math.max(o.subsoilDepth or 0, 2 * o.voxel, lean + o.voxel)
  o.strataDepth = math.max(o.strataDepth or 0, o.subsoilDepth + 4)
  local hi = relief + mH + lean
  local cut = math.max(o.ravines.depth, o.rivers.depth)
  local shape = { seaAlt = seaAlt, peak = hi, low = relief + cut + lean, rivers = true, snowline = snow,
    home = { gen = HOME_GEN, mask = stats } }
  return o, shape
end

-- Turn the rolled first planet into the home world. `spec` is what the main
-- roll built (its numbers stay drawn); returns it rewritten.
local function homeWorld(spec, p, sc, radius)
  local q = rng(((spec.opts.seed or 1) * 31 + 70001) % 4294967291 + 1)
  local Tk = q:range(281, 297)
  local density = q:range(0.62, 0.85)
  local types = { "verdant", "steppe", "archipelago", "alpine" }
  local geo = rollGeology(q, { type = q:pick(types), Tk = Tk, air = true, spawn = true })
  -- The home climate is mild and wet whatever its type: rivers, lakes, life.
  geo.moist = math.max(geo.moist or 0.5, 0.6)
  geo.fertility = math.max(geo.fertility or 0.5, 0.65)
  if not geo.sea then geo.sea = { alt = -0.4, water = "ocean", state = "liquid" } end
  geo.sea.state = "liquid"
  geo.sea.waterTable = WATERS[geo.sea.water] or WATERS.ocean
  local opts, shape = homeOpts3(geo, radius, p.caveScale, sc, q)
  geo.sea.alt = shape.seaAlt / math.max(opts.relief, 1e-6)
  geo.home = true
  local cel = spec.cel
  local ga = geo.air or { hue = 0.58, sat = 0.4, clouds = 0.4 }
  cel.atmoColor = hsv(ga.hue, ga.sat, 0.85)
  cel.atmoHeight = radius * q:range(0.28, 0.4)
  cel.atmoDensity = density
  cel.clouds = math.max(0.3, ga.clouds or 0.3)
  cel.occluderRadius = math.max((radius - shape.low - opts.caveDepth) * 0.95, 0)
  spec.geo, spec.opts, spec.shape = geo, opts, shape
  spec.kind = geo.family
  spec.sea = radius + shape.seaAlt
  spec.temp = tempNorm(Tk)
  print(string.format("    HOME (homeGen %d): %s, %.0f K, ranges seed %d scale %.2f coverage %.2f (mask gap %.2f, caps %.2f/%.2f, equator %.2f, %d tried)",
    HOME_GEN, geo.label, Tk, opts.seed, opts.mountains.scale, opts.mountains.coverage, shape.home.mask.gap or 0,
    shape.home.mask.capN or 0, shape.home.mask.capS or 0, shape.home.mask.eq or 0, shape.home.mask.searched or 0))
  return spec
end

-- Arc distance (metres on radius R) from unit u to the nearest point of a
-- channel's polyline, minus its half-width.
local function channel_gap(ux, uy, uz, chs, R)
  local best = math.huge
  local near = math.cos(math.min(math.pi, 1200 / R))
  for _, ch in ipairs(chs or {}) do
    local pts, wid = ch.points or {}, ch.widths or {}
    local l = R
    for i = 1, math.floor(#pts / 3) do
      local x, y, z = pts[i * 3 - 2], pts[i * 3 - 1], pts[i * 3]
      local c = (x * ux + y * uy + z * uz) / (l or math.sqrt(x * x + y * y + z * z))
      -- Only the points within reach are worth an acos.
      if c > near then
        local d = math.acos(math.min(1, c)) * R - (wid[i] or 10) * 0.5
        if d < best then best = d end
      end
    end
  end
  return best
end

-- THE BASE SITE: the flattest dry spot of the equatorial lowland with no
-- range, river, ravine or lake within the flat zone. Planet-local unit vector
-- + what it was picked by. Reads the world's channels and lakes (hydroOf,
-- which keeps them in the save), so it is worked out once per save and kept
-- in `home.site`.
function homeSite(name, o, shape, hyd)
  local cached = save.get("home.site")
  if type(cached) == "table" and cached.seed == o.seed and cached.v == HOME_GEN then return cached end
  local c0 = os and os.clock and os.clock()
  local R = o.radius
  -- Channel points lie on the sphere of the radius: one length for all.
  local chs = hyd and hyd.rivers or {}
  local lakes = hyd and hyd.lakes or {}
  local sea = shape.seaAlt or -1e9
  local best, bestS = nil, -1e9
  local function tangent(ux, uy, uz)
    local ax, ay, az = 0, 1, 0
    if math.abs(uy) > 0.9 then ax, ay, az = 1, 0, 0 end
    local tx, ty, tz = uy * az - uz * ay, uz * ax - ux * az, ux * ay - uy * ax
    local l = math.sqrt(tx * tx + ty * ty + tz * tz)
    tx, ty, tz = tx / l, ty / l, tz / l
    return tx, ty, tz, uy * tz - uz * ty, uz * tx - ux * tz, ux * ty - uy * tx
  end
  for _, lat in ipairs({ 0, 4, -4, 8, -8, 12, -12 }) do
    for k = 0, 89 do
      if home_site_yield then home_site_yield() end
      local lon = k * math.pi / 45
      local cy = math.sin(math.rad(lat))
      local cr = math.cos(math.rad(lat))
      local ux, uy, uz = math.cos(lon) * cr, cy, math.sin(lon) * cr
      local h0 = homeHeight(o, ux, uy, uz, true)
      local gap = channel_gap(ux, uy, uz, chs, R)
      local wet = false
      for _, L in ipairs(lakes) do
        local ll = math.sqrt(L.x * L.x + L.y * L.y + L.z * L.z)
        local c = (L.x * ux + L.y * uy + L.z * uz) / ll
        if math.acos(math.max(-1, math.min(1, c))) * R < (L.reach or 0) + HOME_SITE_R then wet = true end
      end
      if h0 > sea + 4 and gap > HOME_SITE_R - 20 and not wet then
        -- Flatness: the ground over the zone (the overhangs' lean included:
        -- they move flat ground by up to their strength), ring by ring.
        local t1x, t1y, t1z, t2x, t2y, t2z = tangent(ux, uy, uz)
        local dev, lo = 0, h0
        for _, rr in ipairs({ 45, 90, 135, 180, HOME_SITE_R }) do
          local a = rr / R
          for j = 0, 11 do
            local th = j * math.pi / 6
            local px = ux * math.cos(a) + (t1x * math.cos(th) + t2x * math.sin(th)) * math.sin(a)
            local py = uy * math.cos(a) + (t1y * math.cos(th) + t2y * math.sin(th)) * math.sin(a)
            local pz = uz * math.cos(a) + (t1z * math.cos(th) + t2z * math.sin(th)) * math.sin(a)
            local h = homeHeight(o, px, py, pz, true)
            if rr <= 180 then dev = math.max(dev, math.abs(h - h0)) end
            if dev > 12 then break end
            lo = math.min(lo, h)
          end
        end
        local s = -dev * 2 - math.abs(lat) * 0.15 + math.min(gap, 600) * 0.004
          + math.min(lo - sea, 10) * 0.3
        if lo < sea + 1 then s = s - 20 end
        if s > bestS then
          bestS = s
          best = { x = ux, y = uy, z = uz, lat = lat, h = h0, dev = dev, gap = gap, score = s }
        end
      end
    end
  end
  if not best then
    best = { x = 1, y = 0, z = 0, lat = 0, h = 0, dev = -1, gap = -1, score = -1e9 }
  end
  best.seed, best.v, best.r = o.seed, HOME_GEN, HOME_SITE_R
  save.set("home.site", best)
  print(string.format("    HOME base site: lat %+.0f, ground %+.1f m, ±%.1f m over 180 m, nearest channel %.0f m (%.0f ms)",
    best.lat, best.h, best.dev, best.gap, c0 and (os.clock() - c0) * 1000 or -1))
  return best
end

-- The site waits for the world's rivers and lakes, which hydroWarm asks for
-- OFF the script thread while the terrain fills (asking here, on the loading
-- screen's own call, ran past the engine's 2 s script watchdog on a big
-- world). `update` publishes it the frame they land — seconds before the
-- terrain does, so long before the crew is set down.
local site_wait = nil
homeSitePending = false

local function site_publish(site)
  lastBaseDir = { site.x, site.y, site.z }
  lastHomeSite = site
  homeSitePending = false
end

local function site_try()
  local w = site_wait
  if not w then return end
  local cached = save.get("home.site")
  local hyd = save.get("hydro." .. w.name)
  local ready = type(cached) == "table" and cached.seed == w.o.seed and cached.v == HOME_GEN
  if not ready and not (hyd and (type(hyd) == "table" and hyd.seed == w.o.seed and hyd.v == HYDRO_V)) and not (terrain and terrain.planetRivers) then
    hyd = {}   -- no engine to ask (the offline harness): the site from the ground alone
  elseif not ready and not (hyd and (type(hyd) == "table" and hyd.seed == w.o.seed and hyd.v == HYDRO_V)) then
    return
  end
  if ready or not (coroutine and os and os.clock) or not w.async then
    site_wait = nil
    site_publish(homeSite(w.name, w.o, w.shape, hyd))
    return
  end
  -- A few milliseconds a frame: the search reads the ground ~40k times.
  w.co = w.co or coroutine.create(function() return homeSite(w.name, w.o, w.shape, hyd) end)
  local t0 = os.clock()
  home_site_yield = function() if os.clock() - t0 > 0.004 then coroutine.yield() end end
  local ok, site = coroutine.resume(w.co)
  home_site_yield = nil
  if not ok then
    print("system_generator: base site search failed: " .. tostring(site))
    site_wait, homeSitePending = nil, false
  elseif coroutine.status(w.co) == "dead" then
    site_wait = nil
    site_publish(site)
  end
end

function update(node, dt)
  if site_wait then site_try() end
end

-- What the flora, climate and FX read about a world's ground and life: the
-- `bio` table on its world record (see publishWorld).
local function bioOf(g, starClass)
  local t = tempNorm(g.Tk)
  local function col(p) return p and { p.color[1], p.color[2], p.color[3] } or nil end
  local f = FOLIAGE[starClass or 3] or FOLIAGE[3]
  return {
    type = g.type, label = g.label,
    tempK = math.floor(g.Tk + 0.5),
    temp = t,
    moist = g.moist or 0.3,
    fertility = g.fertility or 0,
    soil = g.soil or "regolith",
    sea = g.sea and g.sea.state or "none",
    palette = {
      high = col(g.high), low = col(g.low), patch = col(g.cap or g.patch),
      rock = col(g.strata), foliage = { f[1], f[2], f[3] },
      water = g.sea and g.sea.waterTable.shallow or nil,
    },
    mats = {
      high = g.high and g.high.slot, low = g.low and g.low.slot,
      patch = (g.cap or g.patch) and (g.cap or g.patch).slot,
    },
  }
end

-- The WORLD RECORD every game system downstream reads: what archetype this body
-- is (mining yields), how much sun it gets and whether it has air (climate),
-- and where its sea sits (water, shorelines, what grows). Rolled once here —
-- the generator is the only thing that knows these facts — and published to
-- `save.world.<name>`, which survives the scene hop and rides the save slot.
local function publishWorld(b, kind, insol, sea)
  save.set("world." .. b.name, {
    name = b.name,
    kind = kind,
    seed = b.opts.seed or 1,
    radius = b.opts.radius or 100,
    -- Scale 3: how high the ground goes (the fbm plus the mountain ranges),
    -- which is what every reader of `relief` means by it — a lapse rate, a
    -- low orbit above the peaks, a spawn height.
    relief = (b.shape and b.shape.peak) or b.opts.relief or 6,
    sea = sea or 0,
    atmo = (b.cel.atmoDensity or 0),
    -- The look of the air, not just how much there is. The sky shader already
    -- has these; publishing them is what lets the FOG on the ground be the
    -- same air as the halo seen from orbit, instead of a grey the artist
    -- picked separately and that stops matching the moment a seed changes.
    atmoHeight = (b.cel.atmoHeight or 0),
    atmoR = b.cel.atmoColor and b.cel.atmoColor[1] or nil,
    atmoG = b.cel.atmoColor and b.cel.atmoColor[2] or nil,
    atmoB = b.cel.atmoColor and b.cel.atmoColor[3] or nil,
    insol = insol or 1.0,
    -- The ground's own colour, so dust kicked off it matches (vfx.lua).
    ground = b.opts.surfaceA and b.opts.surfaceA.color or nil,
    -- Scale 2+: the planet TYPE and what lives on it (see bioOf), the sea's
    -- chemistry (ocean.lua) and the climate's anchors (climate.lua). nil on a
    -- scale-1 world, whose readers fall back to `kind`.
    geo = b.geo and { type = b.geo.type, label = b.geo.label, family = b.geo.family,
      future = b.geo.future, home = b.geo.home } or nil,
    bio = b.geo and bioOf(b.geo, b.starClass) or nil,
    water = (b.geo and b.geo.sea) and { state = b.geo.sea.state,
      deep = b.geo.sea.waterTable.deep, shallow = b.geo.sea.waterTable.shallow,
      clarity = b.geo.sea.waterTable.clarity } or nil,
    climTemp = b.geo and tempNorm(b.geo.Tk) or nil,
    climMoist = b.geo and b.geo.moist or nil,
    -- Scale 3: the shape the relief layers gave it, and whether it has rivers
    -- and lakes to ask for (the polylines and basins themselves are in
    -- `hydro.<name>`, see hydroOf — too big to rewrite on every roll).
    shape = b.shape and { peak = b.shape.peak, low = b.shape.low, seaAlt = b.shape.seaAlt,
      snowline = b.shape.snowline, voxel = b.opts.voxel,
      -- The built home world (homeGen): its recipe version, else nil.
      home = b.shape.home and b.shape.home.gen or nil,
      layers = { mountains = b.opts.mountains ~= nil, warp = b.opts.warp ~= nil,
        plateau = b.opts.plateau ~= nil, terrace = b.opts.terrace ~= nil,
        overhangs = b.opts.overhangs ~= nil, ravines = b.opts.ravines ~= nil,
        rivers = b.opts.rivers ~= nil, biomes = b.opts.biomes and #b.opts.biomes or 0 } } or nil,
    hydro = b.shape and (b.opts.rivers ~= nil or (GENSPEC[b.name] ~= nil and GENSPEC[b.name].wet)) or nil,
  })
end

-- ── RIVERS AND LAKES (scale 3) ──────────────────────────────────────────────
--
-- Where a world's water runs and stands, from the engine's own answers for the
-- genspec (terrain.planetRivers / planetLakes, engine cards 0416/0417): the
-- river polylines the generator carved valleys along, and every basin filled
-- to the height it spills at. Deterministic in the opts, so it is worked out
-- once per world per save and kept in `hydro.<name>`:
--
--   { seed, v, rivers = { {river = true|false, depth, length, points = {x,y,z,…},
--       widths = {…}}, … },
--     lakes = { {level, x, y, z, reach, area, depth}, … } }
--
-- Points and lake centres are planet-local (add the body's position); a lake's
-- `level` is metres above the radius, its centre on its surface. A river runs
-- from its spring the way water drains, across any basin on its way at the
-- height the basin fills to, to the sea, the world's lowest ground or another
-- river (engine 0.117 rc3: it never runs round in circles any more, so the
-- old split of a river into the parts the tracer had not lapped, and the
-- "ran to the step cap, so it ends in a lake" guess, are gone). Each is
-- thinned to at most HYDRO_POINTS points; a ravine is a channel with
-- river = false. Read it through hydroOf (or climate.hydroOf) — flora,
-- missions, the HUD and the lake surfaces do.
--
-- COST: the river tracer is quick now (~0.4 s at r 630), but planetLakes
-- rebuilds the planet's relief grid, which at the genspec's own voxel is
-- seconds; asked on a coarse grid it is ~0.5 s. Both run OFF the script
-- thread when given a callback (rc3): `hydroWarm` asks that way while the
-- home world's terrain fills, so the loading screen never stops for it.
-- `hydroOf` still answers at once — from the save, or, if nobody warmed it
-- (or the warm-up has not landed yet), by asking on this thread.
GENSPEC = {}
-- 2: rivers traced by engine 0.117 rc3 (a save made earlier kept rc2's rivers,
-- which no longer match the valleys the generator carves).
HYDRO_V = 2
local HYDRO_POINTS = 200
local MAX_LAKES = 24
local hydro_wait = {}

local function hydro_valid(cached, o)
  return type(cached) == "table" and cached.seed == o.seed and cached.v == HYDRO_V
end

-- What planetLakes is asked: the coarse grid and the sea it drains to.
local function lake_query(gs)
  local o = gs.opts
  local R = o.radius
  local q = { cell = math.max(4, R / 110), minDepth = 1.0 }
  if gs.seaAlt then q.seaLevel = gs.seaAlt elseif o.rivers then q.seaLevel = o.rivers.seaLevel end
  -- The lake finder rebuilds the relief grid at the genspec's voxel (up to
  -- 1024² a face: seconds). At ~2R/112 a cell — 14 m on an 800 m world —
  -- the same lakes come back to a few decimetres (measured r 800: biggest
  -- six identical in level, reach within 2 m) in a fifteenth of the time.
  local o2 = {}
  for k, v in pairs(o) do o2[k] = v end
  o2.voxel = math.max(o.voxel or 1.5, 2 * R / 112)
  return o2, q
end

-- The hydro record from the engine's answers.
local function hydro_assemble(o, chs, lakes, q)
  local out = { seed = o.seed, v = HYDRO_V, rivers = {}, lakes = {} }
  for _, ch in ipairs(chs or {}) do
    local pts, wid = ch.points, ch.widths
    local m = math.floor(#pts / 3)
    if m >= 2 then
      local step = math.max(1, math.ceil(m / HYDRO_POINTS))
      local p2, w2, len = {}, {}, 0
      local px, py, pz
      for i = 1, m, step do
        local x, y, z = pts[i * 3 - 2], pts[i * 3 - 1], pts[i * 3]
        if px then len = len + math.sqrt((x - px) ^ 2 + (y - py) ^ 2 + (z - pz) ^ 2) end
        px, py, pz = x, y, z
        p2[#p2 + 1], p2[#p2 + 2], p2[#p2 + 3] = x, y, z
        w2[#w2 + 1] = wid[i] or wid[#wid]
      end
      out.rivers[#out.rivers + 1] = { river = ch.river, depth = ch.depth, length = len, points = p2, widths = w2 }
    end
  end
  if lakes then
    local minArea = q.cell * q.cell * 6
    for _, l in ipairs(lakes) do
      if #out.lakes >= MAX_LAKES then break end
      if l.area >= minArea then
        local c = l.center
        out.lakes[#out.lakes + 1] = { level = l.level, x = c.x, y = c.y, z = c.z,
          reach = l.reach, area = l.area, depth = l.depth }
      end
    end
  end
  return out
end

function hydroOf(name)
  if not name then return nil end
  local cached = save.get("hydro." .. name)
  local gs = GENSPEC[name]
  if not gs then return cached end
  local o = gs.opts
  if hydro_valid(cached, o) then return cached end
  if not (terrain and terrain.planetLakes and terrain.planetRivers) then return nil end
  local chs = (o.rivers or o.ravines) and terrain.planetRivers(o) or {}
  local lakes, q
  if gs.wet then
    local o2
    o2, q = lake_query(gs)
    local ok, l = pcall(terrain.planetLakes, o2, q)
    lakes = ok and l or nil
  end
  local out = hydro_assemble(o, chs, lakes, q)
  save.set("hydro." .. name, out)
  return out
end

-- Is a warm-up of this world's rivers and lakes still out? (climate waits
-- for it rather than asking the same question on its own thread.)
function hydroPending(name)
  return name ~= nil and hydro_wait[name] ~= nil
end

-- Ask for a world's rivers and lakes OFF the script thread (engine 0.117 rc3
-- callbacks); the answer lands in the save a few frames later. Does nothing
-- when the save already has them, or a warm-up is already out.
function hydroWarm(name)
  local gs = name and GENSPEC[name]
  if not gs or hydro_wait[name] then return end
  local o = gs.opts
  if hydro_valid(save.get("hydro." .. name), o) then return end
  if not (terrain and terrain.planetLakes and terrain.planetRivers) then return end
  local job = { gs = gs, slot = save.slot and save.slot() or nil }
  hydro_wait[name] = job
  local o2, q = lake_query(gs)
  local function done()
    if job.rivers == nil or job.lakes == nil or job.finished then return end
    job.finished = true
    if hydro_wait[name] == job then hydro_wait[name] = nil end
    -- A galaxy rolled again, or another save loaded, while it was out.
    if GENSPEC[name] ~= gs or (save.slot and save.slot() ~= job.slot) then return end
    if hydro_valid(save.get("hydro." .. name), o) then return end
    save.set("hydro." .. name, hydro_assemble(o, job.rivers, job.lakes ~= false and job.lakes or nil, q))
  end
  local function ask(fn, args, field)
    args[#args + 1] = function(v) job[field] = v or {}; done() end
    local ok = pcall(fn, (table.unpack or unpack)(args))
    if not ok then job[field] = (field == "lakes") and false or {}; done() end
  end
  if o.rivers or o.ravines then ask(terrain.planetRivers, { o }, "rivers") else job.rivers = {} end
  if gs.wet then ask(terrain.planetLakes, { o2, q }, "lakes") else job.lakes = false end
  done()
end

-- The sea: a sphere of water at a fixed radius, with the terrain poking through
-- it wherever the ground is higher. That IS an ocean — basins fill, ridges
-- become coastline, and the shoreline moves as the relief does, for free.
--
-- It is the `Sea` prefab (or `SeaIce` on a frozen world): a finely tessellated
-- surface wearing shaders/ocean.flsl — waves, depth colour, surf that breaks on
-- the shore — driven by scripts/ocean.lua (sun, sky, spray, surf sound), over a
-- hidden engine Water Volume of the same radius, which floats what lands in it
-- and turns the view murky underneath. `climate.seaDepth` answers from the same
-- radius, so the swimmer, the scatter and the physics agree on where water is.
local function makeSea(parent, b, sea, kind, temp)
  local frozen = (kind == "ice" or kind == "frost" or (temp or 0.5) < 0.2)
  -- Scale 2+: the geology says what state the sea is in (a methane sea is a
  -- liquid one, however cold).
  if b.geo and b.geo.sea then frozen = b.geo.sea.state == "ice" end
  spawn(frozen and "SeaIce" or "Sea", vec3(b.pos[1], b.pos[2], b.pos[3]), function(w)
    -- The mesh and the volume are both radius 1: the scale is the sea.
    w.scale = sea
  end, parent)
end

-- One body under the system group: node + celestial + core kernel. The body
-- carries its GENSPEC (setTerrainGen) instead of a pre-generated field: the
-- engine generates its terrain in the background the first time you approach
-- (deterministic per seed — G2 streaming), so a freshly rolled system is
-- playable in seconds no matter how many worlds it has, and unvisited worlds
-- cost nothing but a scene node. Only the SPAWN planet pre-generates (you're
-- standing on it — see generate()).
local function makeBody(sys, b)
  createNode(b.name, sys, function(n)
    n:setTerrain(b.id)
    n:setTerrainGen(b.opts)
    n:setCelestial(b.cel)
    n.x, n.y, n.z = b.pos[1], b.pos[2], b.pos[3]
    n.tags = { "genbody" }
    local hot = (b.opts.corePaint and b.opts.corePaint.slot == 6)
    local cc = hot and { 1.0, 0.55, 0.25 } or { 0.55, 0.8, 1.0 }
    local ce = hot and { 1.0, 0.45, 0.15 } or { 0.4, 0.7, 1.0 }
    createNode(b.name .. " Core", n, function(core)
      core:setPrimitive("Sphere", cc)
      core:setMaterial { color = cc, emissive = ce, emissiveStrength = 2.5, unlit = true }
      core.scale = math.max(b.opts.coreR * 0.8, 4)
      core.tags = { "genbody" }
    end)
    if (b.sea or 0) > 0 then makeSea(n, b, b.sea, b.kind, b.temp) end
  end)
end

-- ---------------------------------------------------------------------------

-- Published after every roll (game_manager reads these to place the player and
-- gate its loading screen on the spawn planet's terrain).
lastSeed, lastSpawnBody, lastSpawnRadius = 0, nil, 0
lastSpawnX, lastSpawnY, lastSpawnZ = 0, 0, 0
-- homeGen 2: the base site on the home world's equatorial plain, as a
-- planet-local unit vector { x, y, z } (nil for an older save, whose base is
-- sited by game_manager's own search), and the record it was picked by
-- ({ x, y, z, lat, h, dev, gap, r }; `r` the flat zone's radius in metres).
lastBaseDir, lastHomeSite = nil, nil
-- The home recipe the last roll ran (see homeGenFor).
lastHomeGen = 1

-- The rails ROOT and the galaxy-wide name set, published so `galaxy.lua` can
-- hang its systems off the right star and never repeat a name. Both are set by
-- `roll` — until home exists there is nothing for a neighbour to orbit.
homeStar = nil
homeTaken = {}

-- Build ONE star system from the rolled `r`. `cfg` says WHICH system it is, and
-- everything that differs between the save's own system and one of the galaxy's
-- neighbours is in there rather than in a second copy of this function:
--
--   home       this is the save's own system. Its star is the rails ROOT — the
--              one parentless body, which `frames.rs` gives an infinite SOI —
--              and its first planet is the spawn world. Exactly one system in a
--              galaxy is home; every other star hangs off this one.
--   idBase     the first terrain id this system may use. Terrain ids are
--              SCENE-wide and they name the `.cfield` on disk, so two systems
--              that both counted from 1 would stream each other's ground into
--              each other's planets. `galaxy.lua` hands out a disjoint block.
--   taken      the GALAXY-wide name set. Rails resolve `parent` BY NAME, so one
--              repeated name across two systems cross-wires their orbits.
--   starA / starM0 / starSoi / parentStar
--              a NEIGHBOUR star's circular orbit about the home star, and the
--              influence it holds. Absent for home.
--   tag        an extra tag on the group node, so a streamer can find its own
--              systems without touching the home one.
--
-- Returns the star's name.
-- Where the rails will put a body at sim time `t`: the engine's Kepler solve
-- (frames.rs) for lan = argPe = 0 — M = m0 + n·t, E − e·sin E = M, and the
-- orbit plane tipped by `i` about X. Relative to the parent.
local function kepler(a, e, i, m0, mu, t)
  local M = m0 + math.sqrt(mu / (a * a * a)) * t
  local E = M
  for _ = 1, 8 do E = E - (E - e * math.sin(E) - M) / (1 - e * math.cos(E)) end
  local xp = a * (math.cos(E) - e)
  local yp = a * math.sqrt(1 - e * e) * math.sin(E)
  return xp, math.sin(i) * yp, math.cos(i) * yp
end

-- The home star's µ, kept for placing neighbour stars on their orbit about it.
local homeMu = nil

local function buildSystem(r, p, cfg)
  local taken = cfg.taken
  local sc = scaleOf(p.scale)

  -- The star: class → color + brightness; µ sets the year lengths.
  local classes = {
    { { 0.72, 0.82, 1.0 }, 90, 1 }, -- blue-white
    { { 1.0, 0.97, 0.9 }, 55, 2 },  -- white
    { { 1.0, 0.92, 0.6 }, 40, 3 },  -- yellow
    { { 1.0, 0.72, 0.42 }, 26, 4 }, -- orange
    { { 1.0, 0.5, 0.34 }, 15, 5 },  -- red dwarf
  }
  local cls = r:pick(classes)
  local starName = rollName(r, taken)
  local starMu = r:range(sc.starMu[1], sc.starMu[2])
  -- Brightness is set for ~1x irradiance AT THE FIRST PLANET (irradiance =
  -- lum*1e6/d^2; overbright washes the whole sky white through bloom). The
  -- class nudges it: blue-white runs hot, red dwarfs dim.
  local a1 = p.minOrbit * r:range(0.9, 1.3)
  local classHeat = ({ 1.25, 1.1, 1.0, 0.85, 0.7 })[cls[3]]
  local starLum = (a1 * a1 / 1e6) * r:range(0.95, 1.25) * classHeat * p.starScale
  local starR = r:range(sc.starR[1], sc.starR[2])
  -- Bodies are ROLLED first (pure data, deterministic per seed) and BUILT after,
  -- all under one "<Star> System" group node — so the scene stays organized and
  -- the next generation removes the entire old system in one subtree destroy.
  local specs = {}

  local planetKinds = { "canyon", "dune", "ice", "lava", "crystal" }
  local moonKinds = { "barren", "frost", "crystal", "ice" }
  -- Cap 8: with residency streaming + on-demand genspec generation
  -- (docs/galaxy-streaming-proposal.md) only the bodies near the camera hold
  -- RAM/GPU, and only the spawn planet generates up front — the cap is now
  -- just orbital real estate.
  -- A neighbour is capped tighter than home: every planet it rolls is a scene
  -- node and a genspec that lives for as long as the system is resident, and a
  -- galaxy holds several systems at once. Home is the one you actually live in.
  local nPlanets = (p.planets > 0) and math.min(p.planets, 8) or (2 + r:int(0, 2))
  if not cfg.home then nPlanets = math.min(nPlanets, 5) end
  local a = a1
  local id = cfg.idBase
  local firstPos, firstR, firstRelief, firstName = nil, 0, 0, nil
  local lastKind = nil
  print(string.format("star %s: lum %.0f — %d planet(s)", starName, starLum, nPlanets))

  for pi = 1, nPlanets do
    local kind, radius, g, mu, name, m0, pos, opts, cel, insol, sea, temp, spec
    if not sc.geology then
      repeat
        kind = (pi == 1) and r:pick({ "canyon", "dune", "ice" }) or r:pick(planetKinds)
      until kind ~= lastKind
      lastKind = kind
      radius = r:range(p.radiusMin, p.radiusMax)
      g = r:range(p.gravityMin, p.gravityMax)
      mu = g * radius * radius
      name = rollName(r, taken)
      m0 = r:range(0, 6.2831853)
      pos = { a * math.cos(m0), 0, a * math.sin(m0) }
      local atmoHue
      opts, atmoHue = archetype(r, kind, radius, p.caveScale, sc)
      opts.seed = r:int(1, 1e9)
      local bodyR = radius + math.max(radius * 0.035, 4)
      local laplace = a * (mu / starMu) ^ 0.4
      cel = {
        mu = mu, bodyRadius = bodyR,
        soi = math.min(math.max(laplace, bodyR * sc.soiFloor), a * 0.3),
        -- Renderer occlusion: the ball below the deepest cave is guaranteed
        -- solid, so chunks fully behind it skip their draw calls (the far side
        -- of a planet costs nothing). Conservative: relief + caves subtracted.
        occluderRadius = math.max((radius - opts.relief - opts.caveDepth) * 0.95, 0),
        parent = starName,
        a = a,
        -- The SPAWN planet flies a flat circle: the authored crew positions are
        -- computed from a circular t=0 orbit, and any e/i offset snaps the
        -- planet away from them on the first rails tick.
        e = (pi == 1) and 0 or r:range(0, 0.06),
        i = (pi == 1) and 0 or r:range(0, 0.14),
        m0 = m0,
      }
      if atmoHue and r:next() < p.atmoChance then
        cel.atmoColor = hsv(atmoHue, 0.5, 0.85)
        cel.atmoHeight = radius * r:range(0.25, 0.45)
        cel.atmoDensity = r:range(0.5, 0.85)
        cel.clouds = math.max(0, r:range(-0.25, 0.65))
      end
      -- Sunlight at this orbit, normalised so the innermost planet sits near 1
      -- (the star's luminosity was picked for that) and falling off as 1/r². The
      -- climate model reads it as the world's basic warmth.
      insol = (starLum * 1e6) / (a * a)
      -- SEAS. A world needs air to hold liquid water, and the archetype decides
      -- how likely it is to have any; sea level sits inside the relief band, so
      -- basins flood and ridges stay dry — how much of the world is ocean is part
      -- of the roll, not a constant. An ice world's sea is a frozen one.
      sea = 0
      local seaChance = ({ canyon = 0.75, crystal = 0.5, ice = 0.45, dune = 0.25, lava = 0 })[kind] or 0
      if cel.atmoDensity and r:next() < seaChance then
        sea = radius + opts.relief * r:range(-0.55, 0.10)
      end
      local baseT = ({ canyon = 0.55, dune = 0.78, ice = 0.16, frost = 0.12,
                       lava = 0.95, crystal = 0.45 })[kind] or 0.4
      temp = baseT * (0.55 + 0.45 * insol)
      spec = { name = name, id = id, pos = pos, cel = cel, opts = opts,
                     kind = kind, sea = sea, temp = temp }
    else
      -- Scale 2+: the body's physics first, then what it is made of.
      radius = r:range(p.radiusMin, p.radiusMax)
      g = r:range(p.gravityMin, p.gravityMax)
      mu = g * radius * radius
      name = rollName(r, taken)
      m0 = r:range(0, 6.2831853)
      pos = { a * math.cos(m0), 0, a * math.sin(m0) }
      insol = (starLum * 1e6) / (a * a)
      -- Air: the save's atmosphere chance, less on a light world (a low escape
      -- velocity loses its gas). Its greenhouse warms the ground.
      local air = r:next() < p.atmoChance * ((g < 4.5) and 0.75 or 1.0)
      local density = air and r:range(0.45, 0.9) or 0
      local greenhouse = r:range(0.04, 0.32)
      -- Equilibrium temperature: 255 K at Earth's sunlight (insol 1), as the
      -- fourth root of the light, raised by the greenhouse.
      local Tk = 255 * (insol ^ 0.25) * (1 + density * greenhouse)
      local geo = rollGeology(r, { Tk = Tk, air = air, spawn = (pi == 1 and cfg.home), avoid = lastKind })
      lastKind = geo.type
      kind = geo.family
      local shape
      if sc.layers then
        local seed = r:int(1, 1e9)
        opts, shape = geoOpts3(geo, radius, p.caveScale, sc, seed)
        opts.seed = seed
      else
        opts = geoOpts(geo, radius, p.caveScale, sc)
        opts.seed = r:int(1, 1e9)
      end
      local bodyR = radius + math.max(radius * 0.035, 4)
      local laplace = a * (mu / starMu) ^ 0.4
      cel = {
        mu = mu, bodyRadius = bodyR,
        soi = math.min(math.max(laplace, bodyR * sc.soiFloor), a * 0.3),
        occluderRadius = math.max((radius - (shape and shape.low or opts.relief) - opts.caveDepth) * 0.95, 0),
        parent = starName,
        a = a,
        e = (pi == 1) and 0 or r:range(0, 0.06),
        i = (pi == 1) and 0 or r:range(0, 0.14),
        m0 = m0,
      }
      if air then
        local ga = geo.air or { hue = 0.58, sat = 0.4, clouds = 0.3 }
        cel.atmoColor = hsv(ga.hue, ga.sat, 0.85)
        cel.atmoHeight = radius * r:range(0.25, 0.45)
        cel.atmoDensity = density
        cel.clouds = ga.clouds
      end
      sea = geo.sea and (radius + opts.relief * geo.sea.alt) or 0
      if shape then sea = shape.seaAlt and (radius + shape.seaAlt) or 0 end
      temp = tempNorm(Tk)
      spec = { name = name, id = id, pos = pos, cel = cel, opts = opts,
               kind = kind, sea = sea, temp = temp, geo = geo, starClass = cls[3], shape = shape }
      print(string.format("    %s: %.0f K, %s", geo.label, Tk, air and "air" or "airless"))
      -- homeGen 2: the first planet of a new save is the built home world
      -- (everything above is still drawn, so the rest of the system is the
      -- same as the save would have rolled).
      if pi == 1 and cfg.home and sc.layers and (p.homeGen or 1) >= 2 then
        spec = homeWorld(spec, p, sc, radius)
        kind, sea, temp, opts, cel = spec.kind, spec.sea, spec.temp, spec.opts, spec.cel
      end
    end
    specs[#specs + 1] = spec
    if spec.shape then
      -- Water stands where there is air to hold it (a methane world's too).
      -- Lakes stand where there is air to hold them, liquid (a methane world's
      -- too) and rain to fill them: rivers, a sea, or a wet climate — not in
      -- every basin of a dry desert.
      local gg = spec.geo
      local liquid = (gg.Tk >= 255 and gg.Tk < 375) or (gg.type == "titan" and gg.Tk < 200)
      GENSPEC[name] = { opts = opts, seaAlt = spec.shape.seaAlt,
        wet = (cel.atmoDensity or 0) > 0 and liquid
          and (opts.rivers ~= nil or spec.shape.seaAlt ~= nil or (gg.moist or 0) >= 0.3) }
    end
    publishWorld(spec, kind, insol, sea)
    if sea > 0 then
      print(string.format("    sea at r %.0f (%s)", sea, temp < 0.2 and "frozen" or "liquid"))
    end
    -- Only the SPAWN planet generates up front, and it generates ALONE: while
    -- its fill runs, the engine starts no other generation (the batch owns the
    -- queue), so the player's world is always the FIRST one finished. Every
    -- other body streams from its genspec on approach. A RESUMED save skips
    -- even this (pregen=false): the spawn planet streams back from the slot's
    -- saved field instead, so the player's digs survive the reload.
    -- …and only HOME has one. A neighbour that pre-generated would spend four
    -- to ten seconds of the background generator on a world nobody has arrived
    -- at, while the world somebody is standing on waits behind it in the queue.
    if pi == 1 and cfg.home and p.pregen ~= false then
      terrain.generatePlanet(id, opts)
    end
    -- Where the home world's rivers and lakes are, asked off the script thread
    -- while its terrain fills or streams back (see hydroWarm): a resumed save
    -- made before engine 0.117 rc3 needs them asked again too (HYDRO_V).
    if pi == 1 and cfg.home and spec.shape then
      -- The built home world picks its base site now (it reads the rivers,
      -- ravines and lakes, which hydroOf asks for here and keeps in the save,
      -- so the warm-up below finds them already there).
      hydroWarm(name)
      if spec.shape.home then
        site_wait = { name = name, o = opts, shape = spec.shape, async = terrain and terrain.planetRivers ~= nil }
        homeSitePending = true
        site_try()
      end
    end
    print(string.format("  %s — %s, r %.0f, g %.1f, orbit %.0f", name, kind, radius, g, a))
    if pi == 1 then
      firstPos, firstR, firstName = pos, radius, name
      firstRelief = spec.shape and spec.shape.peak or opts.relief
    end
    id = id + 1

    -- Moons: up to two, orbits inside half the planet's SOI.
    local soi = cel.soi
    local ma = radius * r:range(sc.moonA[1], sc.moonA[2])
    for _ = 1, 2 do
      if r:next() < p.moonChance and ma < soi * 0.45 then
        local mr = math.min(r:range(sc.moonR[1], sc.moonR[2]), radius * 0.35)
        local mmu = r:range(sc.moonG[1], sc.moonG[2]) * mr * mr
        while ma * (mmu / mu) ^ 0.4 < mr * 2.5 do mmu = mmu * 1.6 end
        local mname = rollName(r, taken)
        local mkind, mm0, mpos, mopts, mgeo, mshape
        if not sc.geology then
          mkind = r:pick(moonKinds)
          mm0 = r:range(0, 6.2831853)
          mpos = { pos[1] + ma * math.cos(mm0), 0, pos[3] + ma * math.sin(mm0) }
          mopts = archetype(r, mkind, mr, p.caveScale, sc)
        else
          mm0 = r:range(0, 6.2831853)
          mpos = { pos[1] + ma * math.cos(mm0), 0, pos[3] + ma * math.sin(mm0) }
          -- An airless moon at its planet's distance from the star. Close in
          -- to a heavy planet, tides knead it hot (Io): volcanism is likelier.
          local Tk = 255 * (((starLum * 1e6) / (a * a)) ^ 0.25)
          local tidal = (ma < radius * 4.6) and (mu > 6 * radius * radius)
          mgeo = rollGeology(r, { Tk = Tk, air = false, moon = true, tidal = tidal })
          mkind = mgeo.family
          if sc.layers then
            local mseed = r:int(1, 1e9)
            mopts, mshape = geoOpts3(mgeo, mr, p.caveScale, sc, mseed)
            mopts.seed = mseed
          else
            mopts = geoOpts(mgeo, mr, p.caveScale, sc)
          end
        end
        if not mshape then mopts.seed = r:int(1, 1e9) end
        local mspec = { name = mname, id = id, pos = mpos, cel = {
          mu = mmu, bodyRadius = mr + math.max(mr * 0.035, 4), soi = 0,
          occluderRadius = math.max((mr - (mshape and mshape.low or mopts.relief) - mopts.caveDepth) * 0.95, 0),
          parent = name, a = ma, e = r:range(0, 0.04), i = r:range(0, 0.25), m0 = mm0,
        }, opts = mopts, kind = mkind, sea = 0, parentMu = mu, geo = mgeo, starClass = cls[3], shape = mshape } -- moons stream from their genspec too
        specs[#specs + 1] = mspec
        if mshape then GENSPEC[mname] = { opts = mopts, seaAlt = nil, wet = false } end
        -- Moons are airless in this generator: no sea, nothing grows — but the
        -- record still publishes, because MINING reads the archetype from it.
        publishWorld(mspec, mkind, (starLum * 1e6) / (a * a), 0)
        print(string.format("    moon %s — %s, r %.0f, orbit %.0f", mname, mgeo and mgeo.label or mkind, mr, ma))
        id = id + 1
        ma = ma * r:range(sc.moonNext[1], sc.moonNext[2])
      end
    end

    a = a * p.spacing * r:range(0.85, 1.15)
  end

  -- The HOME SYSTEM'S ROSTER: every world the save can send you to, with what
  -- its orbit is around. The contract generator (missions.lua) plans trips from
  -- it — Δv, distance and landing gravity — and names only bodies on it, so a
  -- contract can never ask for somewhere that isn't in this system. Neighbour
  -- systems are not on it; they stream in and out.
  if cfg.home then
    local roster = {}
    for _, b in ipairs(specs) do
      roster[#roster + 1] = { name = b.name, kind = b.kind, parent = b.cel.parent,
        a = b.cel.a, radius = b.opts.radius, relief = (b.shape and b.shape.peak) or b.opts.relief, mu = b.cel.mu,
        atmo = b.cel.atmoDensity or 0, sea = b.sea or 0 }
    end
    save.set("system.home", { star = starName, mu = starMu, bodies = roster, scale = p.scale or 1 })
  end

  -- A NEIGHBOUR appears mid-play, so every body is authored where the rails
  -- will put it on its first tick. The engine carries free bodies (the crew, a
  -- vessel) by how far their dominant body moved since last tick, and for a
  -- body created this frame "last tick" is its authored position. Authored
  -- about the ORIGIN, as this used to do, a neighbour's planets sat on top of
  -- the home system for one tick: one of them caught the crew inside its SOI
  -- and carried them 3.5 Mm across the galaxy, a minute and a half into play.
  local starPos = { 0, 0, 0 }
  if not cfg.home and homeMu then
    local t = (space.time and space.time()) or 0
    local sx, sy, sz = kepler(cfg.starA, 0, 0, cfg.starM0, homeMu, t)
    starPos = { sx, sy, sz }
    local placed = {}
    for _, b in ipairs(specs) do
      local c = b.cel
      local par = (c.parent == starName) and starPos or placed[c.parent]
      local pmu = (c.parent == starName) and starMu or (b.parentMu or starMu)
      if par then
        local x, y, z = kepler(c.a, c.e or 0, c.i or 0, c.m0 or 0, pmu, t)
        b.pos = { par[1] + x, par[2] + y, par[3] + z }
        placed[b.name] = b.pos
      end
    end
  end
  if cfg.home then homeMu = starMu end

  -- Build the hierarchy: ONE group node holds the star and every body, so the
  -- Hierarchy panel reads as a single tidy system and regeneration (or a hand
  -- delete of the group) cleans up everything at once. The group sits at the
  -- origin with no rotation/scale — bodies' positions stay world numbers.
  local tags = { "gensystem" }
  if cfg.tag then tags[#tags + 1] = cfg.tag end
  createNode(starName .. " System", function(sys)
    sys.x, sys.y, sys.z = 0, 0, 0
    sys.tags = tags
    createNode(starName, sys, function(star)
      star:setPrimitive("Sphere", cls[1])
      star:setMaterial { color = cls[1], emissive = cls[1], emissiveStrength = 2.0, unlit = true }
      -- HOME is the rails ROOT: parentless, `soi = 0`, which `frames.rs` reads
      -- as infinite. Everything in the galaxy hangs off it, including the other
      -- stars — a SECOND parentless body would be invisible to patched conics,
      -- because `dominant` starts at the one root it found and only ever walks
      -- down through children.
      --
      -- A NEIGHBOUR is a child of home on a flat circular orbit, and its SOI is
      -- finite so that flying into it hands you over. It drifts (it is really
      -- orbiting home), but at `sqrt(µ/a)` that is a few units a second against
      -- a home planet's ~99 — slower than anything else in the sky.
      local cel = {
        mu = starMu, bodyRadius = starR * 0.85, soi = 0,
        luminosity = starLum, starColor = cls[1],
      }
      if not cfg.home then
        cel.parent = cfg.parentStar
        cel.a, cel.m0 = cfg.starA, cfg.starM0
        cel.e, cel.i, cel.lan, cel.argPe = 0, 0, 0, 0
        cel.soi = cfg.starSoi
      end
      star:setCelestial(cel)
      star.x = starPos[1]
      star.y = 0
      star.z = starPos[3]
      star.scale = starR
      star.tags = { "genbody" }
    end)
    for _, b in ipairs(specs) do makeBody(sys, b) end
  end)

  -- Publish the spawn world (game_manager places the player + gates its
  -- loading screen on this planet's terrain). Only home has one.
  if firstPos and cfg.home then
    lastSpawnBody, lastSpawnRadius = firstName, firstR + firstRelief
    lastSpawnX, lastSpawnY, lastSpawnZ = firstPos[1], firstPos[2], firstPos[3]

    -- Move the crew to the first planet's north pole.
    local sy = firstPos[2] + firstR + firstRelief
    local who = { { "Astronaut", 0, 6, 0 }, { "Camera 1", 0, 11, 8 } }
    for _, w in ipairs(who) do
      local n = find(w[1])
      if n then
        n.x = firstPos[1] + w[2]
        n.y = sy + w[3]
        n.z = firstPos[3] + w[4]
      end
    end
  end
  return starName, id
end

-- The knobs a roll runs with: the stock defaults, then the size of the world
-- from scale version `v`, then whatever the caller overrides (non-nil only).
-- The scale table is what makes an old save's unset sliders mean what they
-- meant when it was made.
homeScale = nil
function resolve(v, opts)
  local p = {}
  for k, x in pairs(defaults) do p[k] = x end
  local sc = scaleOf(v)
  for _, k in ipairs({ "minOrbit", "spacing", "radiusMin", "radiusMax", "gravityMin", "gravityMax" }) do
    p[k] = sc[k]
  end
  if opts then
    for k, x in pairs(opts) do
      if x ~= nil then p[k] = x end
    end
  end
  p.scale = SCALES[tonumber(v) or 1] and (tonumber(v) or 1) or 1
  return p
end

-- Roll the save's OWN system: clear whatever stood here and build home.
local function roll(p)
  local r = (p.seed > 0) and rng(p.seed) or rng()
  lastSeed = r.seed
  print(string.format("SYSTEM GENERATOR — seed %d (set the seed param to reproduce)", r.seed))

  -- Clear our previous work: the whole system GROUP goes in one subtree
  -- destroy (that's the point of generating into a clean hierarchy), plus any
  -- stray top-level "genbody" nodes from the old flat format.
  for _, n in ipairs(findTagged("gensystem")) do n:destroy() end
  for _, n in ipairs(findTagged("genbody")) do n:destroy() end

  homeStar, homeTaken = nil, {}
  GENSPEC = {}
  lastBaseDir, lastHomeSite = nil, nil
  site_wait, homeSitePending = nil, false
  lastHomeGen = tonumber(p.homeGen) or 1
  homeScale = tonumber(p.scale) or 1
  scaleVersion, scale = homeScale, scaleOf(homeScale)
  homeStar = buildSystem(r, p, { home = true, idBase = 1, taken = homeTaken })
  print("bodies placed — the spawn planet is generating in the background (Console shows progress); every other world streams in from its genspec when you first approach it. Save the scene once the spawn planet lands.")
end

-- Build ONE of the galaxy's other systems, in place, without disturbing home.
-- `galaxy.lua` owns the decision of WHICH — this only knows how to build one.
--
--   seed    the sector's own seed (deterministic: the same sector always rolls
--           the same system, on any machine, forever)
--   a, m0   where its star sits, as a circular orbit about home (the galaxy is
--           a disc in XZ, so `x = a·cos(m0)`, `z = a·sin(m0)` — the same
--           relation every planet in this file already uses)
--   soi     the influence it holds; `galaxy.lua` keeps these from overlapping
--   idBase  its private block of terrain ids
--   tag     so the streamer can evict exactly its own systems
--
-- Returns the star's name, or nil if home has not been rolled yet (a neighbour
-- with nothing to orbit would be placed at the origin, on top of home).
function buildNeighbour(seed, a, m0, soi, idBase, tag, opts)
  if not homeStar then return nil end
  -- A neighbour is built at HOME's world scale (a galaxy is one universe),
  -- from the generator's stock knobs rather than the save's sliders.
  local p = resolve(homeScale or 1, opts)
  p.planets = 0 -- a neighbour rolls its own count; the save's home setting is home's
  local r = rng(seed)
  return (buildSystem(r, p, {
    home = false, idBase = idBase, taken = homeTaken or {},
    starA = a, starM0 = m0, starSoi = soi, parentStar = homeStar, tag = tag,
  }))
end

-- ▶ Generate (the Inspector button): roll with the node's tuned params.
function generate(node)
  roll(params)
end

-- Runtime entry for the GAME's save-slot flow (game_manager calls this through
-- a script handle at the loading screen): regenerate the whole system from a
-- specific galaxy seed. `opts` overrides any generator knob per save — the
-- new-save panel's planets / moonChance / atmoChance / caveScale land here.
-- Deterministic — the same seed + opts always rebuild the same galaxy.
--
-- `opts.scale` is the save's WORLD SCALE version (see SCALES). Absent means 1:
-- a save that predates versions was generated at the original scale and must
-- keep regenerating as the world it is.
function regenerate(seed, opts)
  local p = resolve((opts and opts.scale) or 1, opts)
  p.seed = (seed and seed > 0) and seed or 0
  p.homeGen = homeGenFor(p)
  roll(p)
end
