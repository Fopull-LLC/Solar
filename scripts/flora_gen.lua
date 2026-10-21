-- FLORA GENERATOR — the procedural brain behind every planet's plants.
--
-- Nothing here is authored. A world's environment (how warm it is, how wet,
-- what its sky and its star look like, how hard it pulls) decides WHICH kinds
-- of plant could grow there; the world's seed then casts the actual species —
-- their shape, their size, their colours, whether they glow, what you get for
-- cutting one down — so two planets never share a flora look.
--
-- THE SPLIT. The plants themselves are a LIBRARY of procedurally generated
-- meshes (tools/gen_flora.py + tools/gen_flora_tex.py: branching broadleaf
-- trees, conifer whorls, palms, tree ferns, bushes, shrubs, grass tussocks,
-- ferns, reeds, horsetails, succulents, cacti, mushrooms, shelf fungi, spires,
-- tube sponges, crystal growths, coral trees, kelp — 51 shapes, up to three
-- LODs, all painted from noise and parametric outlines in ONE neutral grey
-- ramp). This script is what makes them a WORLD: it reads the environment,
-- scores every shape against it, picks the cast, sizes it for the gravity,
-- picks the colours for the light, and hands `flora_field` a list of species
-- to scatter.
--
--     local fg = findScript("flora_gen")
--     local list = fg.speciesFor("Golil")       -- deterministic per world
--     fg.envOf("Golil")                         -- the inputs, as one table
--     fg.assetFor(sp, lod)                      -- "models/flora/oak_l0.gltf"
--     fg.assetFor(sp, lod, "bark")              -- a tree's trunk (sp.twin)
--
-- COLOUR IS A TINT. Since engine 0.117 a scatter source takes `tint`,
-- `emissive` and `emissiveStrength`, and its props keep their model's maps. So
-- every picture exists once, neutral, and a species' colour is a multiply:
-- `sp.tint` = the palette's mid colour over the neutral mid (and `sp.barkTint`
-- the same for a tree's trunk, drawn from a twin source because a tint
-- colours every part of a prop). Palettes are now a starting point rather
-- than a menu: a published pigment pulls the colour toward itself, and each
-- species is shaded a little off its palette, so two worlds that pick the same
-- palette still differ. The scatter's own per-instance roll shades
-- individuals ±15 %.
--
-- GLOW stays subtle on purpose: a glowing species' source sets `emissive` to
-- its glow colour at `sp.glow` (0.35–0.7), and the model's emissive map limits
-- it to the parts that glow — gills, crystal, tube pores. Nothing is ever
-- turned into a bright blob; `flora_field` adds a few small motes around
-- glowing plants near you.

defaults = {}

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- ── naming ──────────────────────────────────────────────────────────────────
-- Species names are rolled from syllables so a planet's flora sounds like it
-- comes from one place, with a form noun you can act on ("cut the ashen
-- spires") rather than a catalogue number.

local SYL = { "vel", "quor", "ash", "mira", "tesk", "olun", "brae", "sith", "yuma",
              "kelv", "duno", "arri", "phos", "ulm", "cren", "sova", "thal", "ixi",
              "orr", "zeph", "lumi", "kath", "nym", "drel" }
local NOUN = {
  broadleaf = { "Oak", "Bole", "Crown", "Wood", "Elm" },
  conifer   = { "Pine", "Spruce", "Fir", "Spar", "Larch" },
  palm      = { "Palm", "Frondtree", "Plume" },
  bush      = { "Bush", "Thicket", "Bramble" },
  shrub     = { "Scrub", "Heath", "Brush", "Thorn" },
  grass     = { "Grass", "Sedge", "Tuft", "Blade" },
  fern      = { "Fern", "Frond", "Bracken" },
  reed      = { "Reed", "Rush", "Cane" },
  moss      = { "Moss", "Cushion", "Lichen" },
  succulent = { "Agave", "Bulb", "Pad", "Rosette" },
  cactus    = { "Cactus", "Barrel", "Column" },
  fungus    = { "Cap", "Shroom", "Bracket", "Morel" },
  spire     = { "Spire", "Horn", "Needle" },
  tubes     = { "Tubes", "Sponge", "Flute" },
  crystal   = { "Shard", "Prism", "Geode" },
  coral     = { "Coral", "Antler", "Branchwork" },
  bulb      = { "Podtree", "Bulb", "Lantern" },
  kelp      = { "Kelp", "Weed", "Ribbon" },
}

local function rollName(r, kind)
  local n = r:pick(SYL)
  if r:next() < 0.6 then n = n .. r:pick(SYL) end
  n = n:sub(1, 1):upper() .. n:sub(2)
  return n .. " " .. r:pick(NOUN[kind] or NOUN.shrub)
end

-- ── what each form is made of ───────────────────────────────────────────────
-- Yields are per plant, in inventory units. A tree is worth walking to; a tuft
-- of grass is worth the two seconds it costs. Bioluminescent variants add glow
-- sap, which is where the money in xenobotany actually is.

local FORM = {
  tree      = { work = 3.4, yields = { { "timber", 3, 6 }, { "fiber", 1, 2 } } },
  shrub     = { work = 1.6, yields = { { "fiber", 2, 4 }, { "biomass", 1, 2 } } },
  grass     = { work = 0.6, yields = { { "fiber", 1, 2 } } },
  fungus    = { work = 1.2, yields = { { "biomass", 2, 3 }, { "spores", 1, 2 } } },
  spire     = { work = 2.6, yields = { { "crystal", 1, 2 }, { "silica", 1, 3 } } },
  succulent = { work = 1.4, yields = { { "water", 2, 3 }, { "biomass", 1, 1 } } },
  kelp      = { work = 1.5, yields = { { "kelp", 2, 4 }, { "biomass", 1, 2 } } },
  vine      = { work = 1.8, yields = { { "fiber", 3, 5 }, { "resin", 1, 2 } } },
}

-- Which biomes a KIND of plant claims, and how strongly. The climate model's
-- biome is the per-place answer; this is the plant's side of it.
local KIND_BIOMES = {
  broadleaf = { forest = 1.0, jungle = 1.0, wetland = 0.5, grass = 0.18, shore = 0.15 },
  conifer   = { forest = 1.0, tundra = 0.45, highland = 0.6, steppe = 0.12, snow = 0.08 },
  palm      = { jungle = 1.0, shore = 0.8, wetland = 0.4, desert = 0.06, grass = 0.1 },
  bush      = { forest = 0.6, jungle = 0.8, wetland = 0.6, grass = 0.5, shore = 0.4, steppe = 0.2 },
  shrub     = { steppe = 0.8, tundra = 0.8, highland = 0.8, grass = 0.4, desert = 0.25, snow = 0.15 },
  grass     = { grass = 1.0, steppe = 0.8, wetland = 0.8, forest = 0.45, shore = 0.6, tundra = 0.5, highland = 0.45, jungle = 0.35 },
  fern      = { forest = 0.8, jungle = 1.0, wetland = 0.8 },
  reed      = { wetland = 1.0, shore = 0.8 },
  moss      = { tundra = 1.0, snow = 0.4, highland = 0.6, forest = 0.3, wetland = 0.3 },
  succulent = { desert = 1.0, steppe = 0.5, shore = 0.2, highland = 0.2 },
  cactus    = { desert = 1.0, steppe = 0.3 },
  fungus    = { forest = 0.7, wetland = 0.8, jungle = 0.6, tundra = 0.3, ash = 0.4 },
  spire     = { crystal = 1.0, highland = 0.5, desert = 0.4, ash = 0.6, snow = 0.3, steppe = 0.3 },
  tubes     = { jungle = 0.6, wetland = 0.8, shore = 0.5, crystal = 0.4, ash = 0.4 },
  crystal   = { crystal = 1.0, snow = 0.5, highland = 0.6, desert = 0.4, ash = 0.5 },
  coral     = { jungle = 0.6, wetland = 0.6, shore = 0.6, grass = 0.3 },
  bulb      = { desert = 0.6, steppe = 0.6, grass = 0.4, ash = 0.4 },
  kelp      = { reef = 1.0, ocean = 0.7 },
}

-- Placement density and reach per kind. `chunk`/`per` are the scatter's own
-- knobs (props per chunk at full density), `far` is how far the kind is drawn
-- (and so, through `scatter.cost`, what it costs), `lod` the LOD hand-off
-- distances as fractions of `far`.
local KIND_PLACE = {
  -- Engine 0.117 (card 0424) settles arriving props a few at a time inside
  -- 1 ms a frame and walks a resident prop for ~0.1–0.2 µs, so chunk size no
  -- longer sets the size of a hitch, and reach costs little. These were cut to
  -- the bone on 0.116.1 (grass to 18 m) to stop settle hitches; they are back
  -- toward the look: grass to 26 m, the understorey to ~50–75 m, trees 150 m.
  -- What a reach costs is still `scatter.cost` — per patch source, (far/chunk)².
  grass     = { chunk = 5.0,  per = 4,  far = 26,  lod = { 1.0 } },
  moss      = { chunk = 10.0, per = 3,  far = 45,  lod = { 0.45, 1.0 } },
  fern      = { chunk = 10.0, per = 3,  far = 50,  lod = { 0.45, 1.0 } },
  reed      = { chunk = 10.0, per = 3,  far = 50,  lod = { 0.45, 1.0 } },
  succulent = { chunk = 12.0, per = 3,  far = 55,  lod = { 0.45, 1.0 } },
  cactus    = { chunk = 18.0, per = 2,  far = 110, lod = { 0.25, 0.6, 1.0 } },
  bush      = { chunk = 14.0, per = 3,  far = 75,  lod = { 0.35, 1.0 } },
  shrub     = { chunk = 14.0, per = 3,  far = 70,  lod = { 0.35, 1.0 } },
  fungus    = { chunk = 16.0, per = 3,  far = 80,  lod = { 0.3, 0.65, 1.0 } },
  tubes     = { chunk = 16.0, per = 2,  far = 80,  lod = { 0.35, 1.0 } },
  crystal   = { chunk = 16.0, per = 2,  far = 90,  lod = { 0.3, 0.65, 1.0 } },
  spire     = { chunk = 20.0, per = 2,  far = 145, lod = { 0.2, 0.5, 1.0 } },
  coral     = { chunk = 20.0, per = 2,  far = 135, lod = { 0.2, 0.5, 1.0 } },
  bulb      = { chunk = 20.0, per = 2,  far = 135, lod = { 0.2, 0.5, 1.0 } },
  broadleaf = { chunk = 18.0, per = 2,  far = 150, lod = { 0.22, 0.55, 1.0 } },
  conifer   = { chunk = 18.0, per = 2,  far = 150, lod = { 0.22, 0.55, 1.0 } },
  palm      = { chunk = 20.0, per = 2,  far = 135, lod = { 0.22, 0.6, 1.0 } },
  kelp      = { chunk = 12.0, per = 3,  far = 55,  lod = { 0.4, 0.8, 1.0 } },
}

function placeOf(kind) return KIND_PLACE[kind] or KIND_PLACE.shrub end

-- Palette families, by name (the palettes themselves are generated, below).
local FAMILY = {
  green  = { verdant = 1.0, spring = 1.0, emerald = 1.0, sage = 0.8, chartreuse = 0.7, teal = 0.6 },
  warm   = { amber = 1.0, ochre = 1.0, rust = 1.0, straw = 0.9, crimson = 0.6, chartreuse = 0.3 },
  cool   = { frost = 1.0, azure = 1.0, teal = 1.0, ivory = 0.7, indigo = 0.5, sage = 0.4 },
  dark   = { umbra = 1.0, aubergine = 1.0, indigo = 0.8, violet = 0.7, crimson = 0.6, emerald = 0.3 },
  exotic = { rose = 1.0, violet = 1.0, azure = 0.8, crimson = 0.8, chartreuse = 0.6, ivory = 0.5 },
  dry    = { straw = 1.0, ochre = 1.0, sage = 0.7, rust = 0.6, amber = 0.4 },
}

local function paletteByName(name)
  for _, p in ipairs(PALETTES or {}) do if p.name == name then return p end end
  return nil
end

-- ── the environment adapter ─────────────────────────────────────────────────
-- Everything the brain reads, as one table, from whatever the world record
-- offers. The generator publishes kind/radius/relief/sea/atmo/insol/ground and
-- the air colour today; anything richer it adds later (a per-planet biome
-- table, the star's colour, gravity, soil colour) is picked up here by name
-- without the rest of this file changing.

local cache = {}   -- world name → species list (deterministic; rolled once)
local envs = {}

-- A stable integer from a string (a star's name) — for rolls that must agree
-- across every planet of one system.
local function strhash(s)
  local h = 5381
  for i = 1, #(s or "") do h = (h * 33 + s:byte(i)) % 2147483647 end
  return h
end

-- Star classes as the system generator rolls them (color, heat). Used only
-- when the world record does not carry the star's colour itself.
local STAR = {
  { 0.72, 0.82, 1.0 },  -- blue-white
  { 1.0, 0.97, 0.9 },   -- white
  { 1.0, 0.92, 0.6 },   -- yellow
  { 1.0, 0.72, 0.42 },  -- orange
  { 1.0, 0.5, 0.34 },   -- red dwarf
}

function envOf(worldName, w)
  local cl = findScript("climate")
  w = w or (cl and cl.worldOf(worldName))
  if not w then return nil end
  local e = {}
  e.name = worldName
  e.seed = w.seed or 1
  e.kind = w.kind or "barren"
  e.radius = w.radius or 100
  e.relief = w.relief or (e.radius * 0.06)
  e.sea = w.sea or 0
  e.atmo = w.atmo or 0
  e.insol = w.insol or 1.0
  local base = (cl and cl.kindOf and cl.kindOf(e.kind)) or { temp = 0.5, moist = 0.3 }
  e.temp = w.temp or clamp(base.temp * (0.55 + 0.45 * e.insol), 0, 1)
  e.moist = w.moist or clamp(base.moist * (0.5 + 0.5 * e.atmo) + (e.sea > 0 and 0.25 or 0), 0, 1)
  -- The per-planet biome the terrain side publishes on world scale 2:
  --   w.bio = { type, temp, moist, fertility, soil, sea, palette = { foliage, … } }
  --   w.geo = { type, family }    w.climTemp / w.climMoist (climate's anchors)
  -- Older saves have none of it and fall back to the archetype above.
  e.temp = w.climTemp or e.temp
  e.moist = w.climMoist or e.moist
  local bio = w.bio
  if type(bio) == "table" then
    e.temp = bio.temp or e.temp
    e.moist = bio.moist or e.moist
    e.fertility = bio.fertility
    e.soil = bio.soil
    e.seaState = bio.sea
    e.bioType = bio.type
    local pal = bio.palette
    if type(pal) == "table" and type(pal.foliage) == "table" then
      e.pigment = { pal.foliage[1] or pal.foliage.r, pal.foliage[2] or pal.foliage.g, pal.foliage[3] or pal.foliage.b }
    end
  end
  if type(w.geo) == "table" then e.geoType = w.geo.type end
  -- Fertility: published, or what the water and warmth suggest.
  e.fertility = e.fertility or clamp(e.moist * 1.2 * (1 - math.abs(e.temp - 0.55) * 1.4), 0, 1)
  -- Gravity: published, or µ/r² from the rails.
  local b = space and space.body and space.body(worldName)
  e.gravity = w.gravity or w.g or ((b and b.mu and b.radius and b.radius > 0) and b.mu / (b.radius * b.radius)) or 6.0
  -- Lower gravity grows taller and thinner (and higher grows squat).
  e.gf = clamp((7.0 / math.max(1.0, e.gravity)) ^ 0.4, 0.8, 1.45)
  -- The star's light. Published colour if there is one; otherwise the class
  -- rolled from the star's name, so every planet of a system agrees.
  if type(w.starColor) == "table" then
    e.star = { w.starColor[1] or 1, w.starColor[2] or 1, w.starColor[3] or 1 }
  else
    local home = save and save.get and save.get("system.home")
    local sname = (w.star) or (home and home.star) or worldName
    local r = rng(strhash(sname) + 77)
    e.star = STAR[1 + r:int(0, #STAR - 1)]
  end
  e.ground = w.ground
  e.air = (w.atmoR and { w.atmoR, w.atmoG, w.atmoB }) or nil
  -- How ALIEN this world's life is: crystal and lava worlds and extremes push
  -- it, the seed decides the rest. 0 = familiar Earth-like, 1 = nothing here
  -- looks like a tree.
  local ar = rng((e.seed % 1000003) + 4242)
  local alien = ar:range(0.0, 0.75)
  if e.kind == "crystal" then alien = alien + 0.45 end
  if e.kind == "lava" or e.kind == "dune" then alien = alien + 0.15 end
  if e.star[3] > 0.95 or e.star[2] < 0.6 then alien = alien + 0.15 end
  e.alien = clamp(alien, 0, 1)
  envs[worldName] = e
  return e
end

-- ── palette choice ──────────────────────────────────────────────────────────
-- Plants evolve to the light they get. Under a dim red star leaves go dark —
-- black, aubergine, deep crimson — to drink every photon; under a hot blue-white
-- star they go pale and cool to shed it; under a yellow sun, green. Cold pushes
-- toward frost and teal, hot dry toward ochre and straw, alien worlds toward
-- the exotic end. The world rolls ONE primary palette and each species leans
-- toward it, so a planet reads as one place.

local function family_weights(e)
  local wts = { green = 1.0, warm = 0.25, cool = 0.25, dark = 0.15, exotic = 0.15, dry = 0.2 }
  local s = e.star
  local redness = clamp((s[1] - s[3]) * 1.6, 0, 1)        -- red dwarf ≈ 1
  local blueness = clamp((s[3] - s[1] + 0.3) * 2.0, 0, 1)  -- blue-white ≈ 1
  wts.dark = wts.dark + 3.0 * redness ^ 2 + 1.2 * clamp(0.6 - e.insol, 0, 1)
  wts.warm = wts.warm + 1.2 * redness
  wts.green = wts.green * (1.0 - 0.7 * redness) * (1.0 - 0.4 * blueness)
  wts.cool = wts.cool + 1.6 * blueness
  if e.temp < 0.3 then wts.cool = wts.cool + 1.5; wts.green = wts.green * 0.6 end
  if e.temp > 0.68 then wts.warm = wts.warm + 1.0 end
  if e.moist < 0.3 then wts.dry = wts.dry + 1.6; wts.green = wts.green * 0.5 end
  if e.moist > 0.6 then wts.green = wts.green + 0.8 end
  wts.exotic = wts.exotic + 2.2 * e.alien
  wts.dark = wts.dark + 0.6 * e.alien
  return wts
end

local function weighted(r, tbl)
  local keys = {}
  for k in pairs(tbl) do keys[#keys + 1] = k end
  table.sort(keys)
  local tot = 0
  for _, k in ipairs(keys) do tot = tot + math.max(0, tbl[k]) end
  if tot <= 0 then return keys[1] end
  local x = r:next() * tot
  for _, k in ipairs(keys) do
    x = x - math.max(0, tbl[k])
    if x <= 0 then return k end
  end
  return keys[#keys]
end

local function pickPalette(r, fam)
  local name = weighted(r, FAMILY[fam] or FAMILY.green)
  return paletteByName(name) or (PALETTES and PALETTES[1])
end

-- The palette nearest a published pigment hint (the terrain side's
-- `bio.palette.foliage`, chosen by star class), with a little seeded slack so
-- two species of one world don't all land on the same picture.
local function nearestPalette(r, rgb, slack)
  local best, bd = nil, 1e9
  for _, p in ipairs(PALETTES or {}) do
    local m = p.mid
    local d = (m[1] - rgb[1]) ^ 2 * 0.3 + (m[2] - rgb[2]) ^ 2 * 0.59 + (m[3] - rgb[3]) ^ 2 * 0.11
    -- compare hue too, not just brightness
    local s1, s2 = m[1] + m[2] + m[3] + 1e-3, rgb[1] + rgb[2] + rgb[3] + 1e-3
    d = d + ((m[1] / s1 - rgb[1] / s2) ^ 2 + (m[2] / s1 - rgb[2] / s2) ^ 2 + (m[3] / s1 - rgb[3] / s2) ^ 2) * 2.0
    d = d * r:range(1.0, 1.0 + (slack or 0.6))
    if d < bd then best, bd = p, d end
  end
  return best
end

-- ── the species roll ────────────────────────────────────────────────────────

local function has(tags, t) return (" " .. tags .. " "):find(" " .. t .. " ", 1, true) ~= nil end

-- How well a library shape suits this environment, 0..∞.
local function suitability(lib, e)
  local tags = lib.tags
  local temperate = 1 - math.abs(e.temp - 0.5) * 2
  -- Every affinity is a FACTOR, not a vote: a palm needs warmth AND water, so
  -- a frozen world with a sea does not get palms because half its needs are
  -- met. Each factor keeps a small floor so the seed can still surprise.
  local v = 1.0
  if has(tags, "wet") then v = v * (0.08 + 0.92 * clamp(e.moist * 1.4, 0, 1)) end
  if has(tags, "dry") then v = v * (0.15 + 0.85 * clamp((1 - e.moist) * 1.3, 0, 1)) end
  if has(tags, "hot") then v = v * (0.04 + 0.96 * clamp((e.temp - 0.4) * 2.2, 0, 1)) end
  if has(tags, "cold") then v = v * (0.10 + 0.90 * clamp((0.62 - e.temp) * 2.2, 0, 1)) end
  if has(tags, "temperate") and not (has(tags, "hot") or has(tags, "cold")) then
    v = v * (0.06 + 0.94 * clamp(temperate * 1.4, 0, 1))
  end
  if has(tags, "alien") then v = v * (0.25 + 1.5 * e.alien) else v = v * (1.15 - 0.6 * e.alien) end
  -- Hard limits: frozen or barren ground grows no trees, palms, ferns or
  -- cacti, whatever the seed says — lichen cushions, heath, crystal, fungus.
  local fert = e.fertility or 0.5
  if e.temp < 0.12 or fert < 0.08 then
    local hardy = { moss = 1, crystal = 1, spire = 1, fungus = 0.6, shrub = 0.5, tubes = 0.4, kelp = 1, grass = 0.3 }
    v = v * (hardy[lib.kind] or 0.0)
  end
  if e.temp > 0.9 and e.moist < 0.2 then
    local desert = { cactus = 1, succulent = 1, spire = 1, crystal = 1, shrub = 0.5, bulb = 0.8, grass = 0.3 }
    v = v * (desert[lib.kind] or 0.05)
  end
  -- Soil and fertility: rich loam and peat carry forests, poor ground carries
  -- succulents, lichen cushions and crystal, salt flats only the hardy.
  local fert = e.fertility or 0.5
  local soil = e.soil
  if lib.form == "tree" and not has(tags, "alien") then v = v * (0.25 + 1.2 * fert) end
  if lib.kind == "moss" or lib.kind == "succulent" or lib.kind == "cactus" or lib.kind == "crystal" then
    v = v * (1.4 - 0.8 * fert)
  end
  if soil == "peat" and (lib.kind == "reed" or lib.kind == "moss" or lib.kind == "fern") then v = v * 2.0 end
  if soil == "saline" and (lib.kind == "succulent" or lib.kind == "shrub") then v = v * 2.0 end
  if (soil == "sand" or soil == "sandy" or soil == "oxide") and (lib.kind == "cactus" or lib.kind == "succulent") then v = v * 1.8 end
  if (soil == "permafrost" or soil == "ice") and (lib.kind == "moss" or lib.kind == "conifer" or lib.kind == "shrub") then v = v * 1.8 end
  if (soil == "ash" or soil == "sulfur" or soil == "basalt" or soil == "silicate") and has(tags, "alien") then v = v * 1.8 end
  if soil == "loam" or soil == "loess" then if lib.kind == "grass" or lib.kind == "broadleaf" then v = v * 1.5 end end
  -- Gravity: tall slim shapes for light worlds, squat ones for heavy worlds.
  if has(tags, "tall") then v = v * clamp(0.6 + (e.gf - 0.8) * 1.4, 0.5, 1.5) end
  return v
end

-- The cast: which roles a world fills, in order. Each role names the kinds it
-- may be filled from.
local ROLES = {
  { role = "carpet",  kinds = { grass = 1 },                          need = "grassy" },
  { role = "tree",    kinds = { broadleaf = 1, conifer = 1, palm = 0.7, coral = 0.6, bulb = 0.5 } },
  { role = "under",   kinds = { bush = 1, shrub = 1, fern = 0.8, cactus = 0.6 } },
  { role = "ground",  kinds = { fern = 1, moss = 1, succulent = 1, reed = 0.8, grass = 0.5 } },
  { role = "tree2",   kinds = { broadleaf = 1, conifer = 1, palm = 0.6, fungus = 0.5, spire = 0.4 }, chance = 0.7 },
  { role = "oddity",  kinds = { fungus = 1, spire = 1, tubes = 1, crystal = 1, coral = 0.6, bulb = 0.6 }, alien = true },
  { role = "under2",  kinds = { bush = 1, shrub = 1, succulent = 0.7, fungus = 0.6 }, chance = 0.55 },
  { role = "oddity2", kinds = { fungus = 1, spire = 1, tubes = 1, crystal = 1 }, alien = true, chance = 0.5 },
  { role = "sea",     kinds = { kelp = 1 },                            need = "sea" },
  { role = "sea2",    kinds = { kelp = 1 },                            need = "sea", chance = 0.6 },
}

local function rollSpecies(r, lib, e, primary, role, used)
  local sp = { shape = lib.id, form = lib.form, kind = lib.kind, lods = lib.lods, role = role }
  sp.name = rollName(r, lib.kind)
  -- Size. The library mesh is drawn at a nominal height; the species scales it
  -- (and the scatter jitters each individual inside the range). Gravity pulls
  -- it down; a giant-tree world rolls big.
  local big = r:range(0.75, 1.3)
  if lib.form == "tree" then big = big * r:range(0.9, 1.25) end
  local s = big * ((lib.form == "grass") and math.sqrt(e.gf) or e.gf)
  sp.scaleMin = s * r:range(0.72, 0.9)
  sp.scaleMax = s * r:range(1.08, 1.35)
  sp.height = lib.h * s
  -- Colour: mostly the world's primary family, sometimes a contrast.
  local fam = primary
  local roll = r:next()
  if roll < 0.25 + 0.3 * e.alien then fam = weighted(r, family_weights(e)) end
  if lib.kind == "grass" and e.moist < 0.35 and r:next() < 0.6 then fam = "dry" end
  local pal = pickPalette(r, fam)
  -- A published pigment hint wins most of the time: it is the terrain side's
  -- answer to "what colour is life under this star", and the ground was
  -- painted to match it.
  local pigmented = false
  if e.pigment and fam == primary and r:next() < 0.75 then
    pal = nearestPalette(r, e.pigment, 0.8)
    pigmented = true
  end
  -- Two species of the same kind never share a palette.
  for _ = 1, 4 do
    if not used[lib.kind .. ":" .. pal.id] then break end
    pal = pickPalette(r, weighted(r, family_weights(e)))
  end
  used[lib.kind .. ":" .. pal.id] = true
  sp.palette = pal.id
  sp.paletteName = pal.name
  sp.pigmented = pigmented
  sp.twin = lib.twin == true
  -- Tall things grow toward the sky, not out of the slope: they stand on the
  -- patch's up (≈ the radial); small ones lie with the ground they cover.
  sp.upright = (lib.h or 0) >= 1.5 and lib.kind ~= "grass"
  sp.leafColor = pal.mid
  sp.glowColor = pal.glow
  -- Glow: rare on a sunlit world, common in the dark, and only on shapes that
  -- have something to glow WITH (gills, pods, tube mouths, crystal).
  local glowChance = 0
  if has(lib.tags, "glow") then
    glowChance = (e.insol < 0.6) and 0.5 or 0.16
    glowChance = glowChance + 0.25 * e.alien
  end
  sp.glow = (r:next() < glowChance) and r:range(0.35, 0.7) or 0
  -- What it's made of.
  local f = FORM[lib.form] or FORM.shrub
  sp.work = f.work * (lib.form == "tree" and clamp(s, 0.7, 1.6) or 1.0)
  sp.yields = {}
  for _, y in ipairs(f.yields) do
    sp.yields[#sp.yields + 1] = { mat = y[1], min = y[2], max = y[3] }
  end
  if sp.glow > 0 then sp.yields[#sp.yields + 1] = { mat = "glowsap", min = 1, max = 2 } end
  if e.temp > 0.65 and lib.form ~= "spire" and r:next() < 0.4 then
    sp.yields[#sp.yields + 1] = { mat = "resin", min = 1, max = 2 }
  end
  -- Where it grows, and how thickly.
  sp.biomes = {}
  for biome, wt in pairs(KIND_BIOMES[lib.kind] or {}) do
    sp.biomes[biome] = wt * r:range(0.7, 1.3)
  end
  sp.aquatic = (lib.form == "kelp")
  -- Riverbanks favour the wet-loving (densityAt): +1 wet, −1 dry country.
  sp.wet = has(lib.tags, "wet") and 1 or (has(lib.tags, "dry") and -1 or 0)
  local pl = placeOf(lib.kind)
  sp.chunk = pl.chunk
  sp.per = math.max(1, math.floor(pl.per * r:range(0.75, 1.35) + 0.5))
  if role == "carpet" then sp.per = math.max(sp.per, math.floor(pl.per * (0.9 + e.moist * 0.6) + 0.5)) end
  sp.far = math.min(pl.far * clamp(math.sqrt(s), 0.85, 1.15), 165)
  sp.lodAt = pl.lod
  -- Clumping: how patchy it is (forests with clearings vs even scrub) and the
  -- noise offset that puts this species' patches somewhere of its own.
  sp.clump = (role == "carpet") and r:range(0.1, 0.4) or r:range(0.2, 0.75)
  sp.clumpScale = r:range(2.5, 7.0)
  sp.clumpOff = r:range(0, 1000)
  return sp
end

-- The species' colours as multiplies of the neutral library. A stream of its
-- own (seeded by world and species), so colour never shifts the cast's rolls.
local function mixc(a, b, t) return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t } end
local function colour(sp, e)
  local pal = paletteByName(sp.paletteName) or (PALETTES and PALETTES[1])
  local N = NEUTRAL or { leaf = 0.45, bark = 0.5 }
  local r = rng(((e.seed or 1) % 1000003) * 131 + sp.id * 7 + 5)
  local mid = { pal.mid[1], pal.mid[2], pal.mid[3] }
  -- A published pigment pulls the colour partway toward itself: the ground
  -- was painted to match it.
  if e.pigment and sp.pigmented then mid = mixc(mid, e.pigment, 0.45) end
  -- Shaded a little off the palette, per channel: a world's own green.
  local k = r:range(0.88, 1.12)
  for i = 1, 3 do mid[i] = mid[i] * k * r:range(0.93, 1.07) end
  -- Never near-black: a plant tinted below this reads as a flat silhouette
  -- with no texture left in it (the "umbra"/"aubergine" palettes did, on worlds
  -- that are not even dim). Lift it, keeping the hue; dim worlds keep it darker.
  local floor_ = (e.insol or 1) < 0.6 and 0.10 or 0.15
  local lum = mid[1] * 0.3 + mid[2] * 0.59 + mid[3] * 0.11
  if lum < floor_ then
    local f = floor_ / math.max(lum, 0.02)
    for i = 1, 3 do mid[i] = math.min(1.0, mid[i] * f + (floor_ - lum) * 0.25) end
  end
  sp.leafColor = mid
  sp.tint = { mid[1] / N.leaf, mid[2] / N.leaf, mid[3] / N.leaf }
  local bk = BARKS and BARKS[(pal.bark or 0) + 1]
  local bm = bk and bk.mid or { 0.3, 0.21, 0.14 }
  sp.barkTint = { bm[1] / N.bark, bm[2] / N.bark, bm[3] / N.bark }
  -- Glow: the palette's glow colour, through the model's emissive map.
  if (sp.glow or 0) > 0 then
    sp.emissive = { pal.glow[1], pal.glow[2], pal.glow[3] }
    sp.emissiveStrength = sp.glow
  end
end

-- Every species a world grows, rolled once and cached. Deterministic: the same
-- world record always produces the same flora, which is what lets the scatter
-- field grow the same forest on every visit.
function speciesFor(worldName, w)
  if cache[worldName] then return cache[worldName] end
  local e = envOf(worldName, w)
  if not e then return {} end
  local list = {}
  if (e.atmo > 0.15 or e.sea > 0) and LIBRARY then
    local r = rng((e.seed or 1) * 7919 % 2147483647 + 13)
    local fw = family_weights(e)
    local primary = weighted(r, fw)
    e.primary = primary
    local grassy = e.atmo > 0.15 and e.moist > 0.22 and e.temp > 0.1 and e.temp < 0.92
      and (e.fertility or 0.5) > 0.15
    local land = e.atmo > 0.15
    local used_shape, used_pal = {}, {}
    for _, R in ipairs(ROLES) do
      local ok = true
      if R.need == "grassy" and not grassy then ok = false end
      if R.need == "sea" and not (e.sea > 0) then ok = false end
      if R.need ~= "sea" and not land then ok = false end
      if R.chance and r:next() > R.chance then ok = false end
      if R.alien and r:next() > 0.25 + 0.85 * e.alien then ok = false end
      if ok then
        -- Score every library shape this role may use.
        local cand, tot = {}, 0
        for _, lib in ipairs(LIBRARY) do
          local kw = R.kinds[lib.kind]
          if kw and not used_shape[lib.id] then
            if (lib.form == "kelp") == (R.need == "sea") then
              local sc = kw * suitability(lib, e) * r:range(0.4, 1.6)
              if sc > 0.02 then
                tot = tot + sc
                cand[#cand + 1] = { lib = lib, acc = tot }
              end
            end
          end
        end
        if tot > 0 then
          local x = r:next() * tot
          local pick = cand[#cand].lib
          for _, c in ipairs(cand) do if x <= c.acc then pick = c.lib; break end end
          used_shape[pick.id] = true
          local sp = rollSpecies(r, pick, e, primary, R.role, used_pal)
          sp.id = #list + 1
          colour(sp, e)
          list[#list + 1] = sp
        end
      end
    end
  end
  -- ⚠ ONLY CACHE AN ANSWER, NEVER AN ABSENCE.
  --
  -- `climate.worldOf` answers for a world it has no record of with an honest
  -- fallback — "barren, airless, no sea". That fallback is CORRECT as a default
  -- and FATAL as a cache key: ask one frame before `system_generator` has
  -- written `world.<name>` to the save and this function would memoise "nothing
  -- grows here" for the rest of the session. An empty list costs nothing to
  -- recompute, so a genuinely airless world re-rolls nothing at all.
  if #list > 0 then cache[worldName] = list end
  return list
end

-- Forget a world's roll (the world record changed under us).
function forget(worldName)
  cache[worldName] = nil
  envs[worldName] = nil
end

-- Which species suit a biome, with weights. An empty answer means nothing
-- grows here, which is a real answer.
function speciesIn(worldName, biome)
  local out = {}
  for _, sp in ipairs(speciesFor(worldName)) do
    local w = sp.biomes[biome]
    if w and w > 0 then out[#out + 1] = { sp = sp, w = w } end
  end
  return out
end

function formsFor(biome)
  local out = {}
  for kind, b in pairs(KIND_BIOMES) do
    if b[biome] then out[kind] = b[biome] end
  end
  return out
end

-- How thickly a species grows at one climate sample, 0..1 — the number the
-- scatter's density grid is made of. `x,y,z` is the body-relative point (for
-- the species' own clumping noise).
function densityAt(sp, s, x, y, z, radius)
  if not s then return 0 end
  local under = (s.sea or 0) > 0 and (s.elev or 0) < -0.3
  if sp.aquatic ~= under then return 0 end
  if not sp.aquatic and (s.elev or 0) < 0.4 and (s.sea or 0) > 0 then return 0 end
  if s.inLake and not sp.aquatic then return 0 end
  local bw = sp.biomes[s.biome] or 0
  -- A riverbank or lake shore (flora_field: climate.wetness) is wet ground
  -- whatever the biome round it: the wet-loving species grow there as they
  -- would in a wetland, lusher, and the dry-country ones thin out.
  local rip = s.riparian or 0
  local dens = s.density or 0
  if rip > 0 then
    if (sp.wet or 0) > 0 then
      bw = math.max(bw, (sp.biomes.wetland or sp.biomes.shore or sp.biomes.forest or 0.5) * rip)
      dens = math.max(dens, 1.3 * rip)
    elseif (sp.wet or 0) < 0 then
      bw = bw * (1 - 0.75 * rip)
    end
  end
  if bw <= 0 then return 0 end
  -- Grass carpets the ground wherever it grows at all; everything else
  -- follows how lush the biome is.
  local lush = (sp.kind == "grass") and clamp(dens / 0.8, 0, 1.2)
    or clamp(dens / 1.45, 0, 1.25)
  local d = bw * lush
  -- Patches: the species' own noise field, so forests have clearings and the
  -- grass has bare spots, each species somewhere different.
  local k = sp.clumpScale / math.max(1, radius or 100)
  local n = math.noise((x + sp.clumpOff) * k, y * k, (z - sp.clumpOff) * k, 7)
  d = d * clamp(1 - sp.clump + sp.clump * (n * 1.6 + 0.5), 0, 1.4)
  return clamp(d, 0, 1)
end

-- The mesh file for a species at an LOD; `part` = "bark" for a tree's trunk.
-- A plant that moves in the wind is drawn from its prefab (prefabs/flora,
-- tools/gen_flora_prefabs.py): the same model wearing a Material with sway
-- and backlight, which a scattered prefab carries (engine 0.117.0-rc6, card
-- 0466). The wind is weather.lua's (weather.addWind). Stiff plants, sea
-- plants and two-material models have no prefab and draw the model as it is.
local swaying = {}
local function prefab_or(model)
  local hit = swaying[model]
  if hit == nil then
    local p = "prefabs/flora/" .. model .. ".prefab.ron"
    hit = (assets and assets.getFile and assets.getFile(p)) and p or false
    swaying[model] = hit
  end
  return hit or ("models/flora/" .. model .. ".gltf")
end

local function model_name(sp, lod, part)
  return string.format(part == "bark" and "%s_bark_l%d" or "%s_l%d", sp.shape, lod or 0)
end

-- What a scatter field draws: the prefab when there is one.
function assetFor(sp, lod, part)
  return prefab_or(model_name(sp, lod, part))
end

-- The model file itself: for a node's `model` and for assets.preload, which
-- take a mesh, not a prefab.
function modelFor(sp, lod, part)
  return "models/flora/" .. model_name(sp, lod, part) .. ".gltf"
end

-- What cutting one down gives you, rolled per individual so a stand of trees
-- isn't six identical hauls.
function harvestYield(sp, seedn)
  local r = rng((seedn or 1) % 2147483647 + 4919)
  local out = {}
  for _, y in ipairs(sp.yields or {}) do
    local n = y.min + r:int(0, math.max(0, y.max - y.min))
    if n > 0 then out[#out + 1] = { mat = y.mat, n = n } end
  end
  return out
end

-- The pocket-guide line a survey / the harvest prompt shows.
function describe(sp)
  local mats = findScript("materials")
  local parts = {}
  for _, y in ipairs(sp.yields or {}) do
    parts[#parts + 1] = (mats and mats.label(y.mat)) or y.mat
  end
  return string.format("%s — %s%s", sp.name, sp.kind or sp.form,
    #parts > 0 and ("  ·  " .. table.concat(parts, ", ")) or "")
end

-- ── rare species ────────────────────────────────────────────────────────────
--
-- A few plants per world that grow in ONE kind of place each (climate's rare
-- niches: under an overhang, on a high peak, on a ravine floor, at a lake's
-- edge, on a riverbank). They are not part of the scatter cast: there are a
-- handful of each, placed one by one (flora_field), so each is a find.
--
-- Each niche keeps one look on every world, so a player who has found one
-- knows the next — a colour, a glow and a family of shapes — and the world's
-- seed rolls the rest: which of the shapes, its name, its exact shade. Rolled
-- on a stream of its own (the world seed, salted), so asking for these never
-- moves a single roll of `speciesFor`.
--
--     fg.rareFor("Golil")   → { cave = sp, peak = sp, … }   sp.mat = "rare_<niche>"

local RARE_LOOK = {
  cave   = { shapes = { "tubes", "crystal_big" }, h = 1.6, noun = { "Gloamcap", "Duskcap" },
             tint = { 0.34, 0.20, 0.62 }, glow = { 0.55, 0.62, 1.00 }, strength = 1.6, work = 2.2 },
  peak   = { shapes = { "crystals", "crystal_big" }, h = 1.7, noun = { "Frostbloom", "Snowstar" },
             tint = { 0.86, 0.92, 1.00 }, glow = { 0.72, 0.90, 1.00 }, strength = 1.3, work = 2.2 },
  ravine = { shapes = { "coral_tree", "tubes" }, h = 2.4, noun = { "Emberflute", "Gorge Lantern" },
             tint = { 0.80, 0.30, 0.12 }, glow = { 1.00, 0.58, 0.20 }, strength = 1.5, work = 2.6 },
  lake   = { shapes = { "spire", "coral_tree" }, h = 2.6, noun = { "Pearlcap", "Shorelamp" },
             tint = { 0.12, 0.55, 0.52 }, glow = { 0.40, 1.00, 0.85 }, strength = 1.4, work = 2.4 },
  river  = { shapes = { "spire_ringed", "spire" }, h = 2.8, noun = { "Silkspire", "Rillhorn" },
             tint = { 0.86, 0.72, 0.22 }, glow = { 0.92, 1.00, 0.45 }, strength = 1.3, work = 2.6 },
}
RARE_LOOK_OF = RARE_LOOK

local rare_cache = {}

local function rare_lcg(seed)
  local s = math.floor(seed) % 2147483647
  if s <= 0 then s = s + 2147483646 end
  local r = {}
  function r:next() s = (s * 48271) % 2147483647; return s / 2147483647 end
  function r:range(a, b) return a + (b - a) * self:next() end
  function r:pick(t) return t[math.floor(self:next() * #t) + 1] end
  return r
end

function rareFor(worldName, w)
  if rare_cache[worldName] then return rare_cache[worldName] end
  if not w then
    local cl = findScript and findScript("climate")
    w = cl and cl.worldOf(worldName)
  end
  if not w then return {} end
  local out = {}
  local order = { "cave", "peak", "ravine", "lake", "river" }
  for i, niche in ipairs(order) do
    local L = RARE_LOOK[niche]
    local r = rare_lcg(((w.seed or 1) % 1000003) * 977 + i * 104729 + 31)
    local shape = r:pick(L.shapes)
    local lib
    for _, l in ipairs(LIBRARY or {}) do if l.id == shape then lib = l end end
    local sy = r:pick(SYL)
    local name = (sy:sub(1, 1):upper() .. sy:sub(2)) .. " " .. r:pick(L.noun)
    local k = r:range(0.9, 1.1)
    local tint = { L.tint[1] * k * r:range(0.94, 1.06), L.tint[2] * k * r:range(0.94, 1.06),
                   L.tint[3] * k * r:range(0.94, 1.06) }
    local h = L.h * r:range(0.9, 1.15)
    out[niche] = {
      id = "rare_" .. niche, niche = niche, rare = true, name = name,
      shape = shape, form = lib and lib.form or "fungus", kind = lib and lib.kind or "fungus",
      lods = lib and lib.lods or 1, height = h, scale = h / ((lib and lib.h) or 1.0),
      stalk = lib ~= nil and lib.bark == "stalk",
      tint = tint, leafColor = tint, glowColor = L.glow, glow = L.strength,
      emissive = L.glow, emissiveStrength = L.strength,
      work = L.work, mat = "rare_" .. niche,
      yields = { { mat = "rare_" .. niche, min = 1, max = 1 }, { mat = "glowsap", min = 1, max = 2 } },
    }
  end
  rare_cache[worldName] = out
  return out
end

-- BEGIN FLORA LIBRARY (generated by tools/gen_flora.py — do not edit by hand)
LIBRARY = {
  { id = "grass_tuft", form = "grass", kind = "grass", h = 0.55, bark = nil, twin = false, lods = 1, tags = "temperate wet cold dense", tris = { 146 } },
  { id = "grass_tall", form = "grass", kind = "grass", h = 1.10, bark = nil, twin = false, lods = 1, tags = "temperate wet hot dense", tris = { 146 } },
  { id = "grass_seed", form = "grass", kind = "grass", h = 0.85, bark = nil, twin = false, lods = 1, tags = "temperate dry hot dense", tris = { 146 } },
  { id = "grass_low", form = "grass", kind = "grass", h = 0.30, bark = nil, twin = false, lods = 1, tags = "cold dry temperate dense", tris = { 130 } },
  { id = "meadow", form = "grass", kind = "grass", h = 0.50, bark = nil, twin = false, lods = 1, tags = "temperate wet dense", tris = { 162 } },
  { id = "fern_a", form = "shrub", kind = "fern", h = 0.90, bark = nil, twin = false, lods = 2, tags = "wet temperate hot", tris = { 218, 98 } },
  { id = "fern_tall", form = "shrub", kind = "fern", h = 1.60, bark = nil, twin = false, lods = 2, tags = "wet hot", tris = { 170, 82 } },
  { id = "reeds", form = "grass", kind = "reed", h = 2.00, bark = "stalk", twin = false, lods = 2, tags = "wet temperate", tris = { 459, 149 } },
  { id = "horsetail", form = "grass", kind = "reed", h = 1.30, bark = "stalk", twin = false, lods = 2, tags = "wet cold alien", tris = { 1410, 674 } },
  { id = "cushion", form = "shrub", kind = "moss", h = 0.35, bark = nil, twin = false, lods = 2, tags = "cold wet dry", tris = { 502, 74 } },
  { id = "cushion_bloom", form = "shrub", kind = "moss", h = 0.40, bark = nil, twin = false, lods = 2, tags = "cold temperate", tris = { 566, 138 } },
  { id = "rosette", form = "succulent", kind = "succulent", h = 0.80, bark = nil, twin = false, lods = 2, tags = "dry hot", tris = { 514, 162 } },
  { id = "rosette_big", form = "succulent", kind = "succulent", h = 1.30, bark = nil, twin = false, lods = 2, tags = "dry hot", tris = { 706, 226 } },
  { id = "pads", form = "succulent", kind = "succulent", h = 1.40, bark = nil, twin = false, lods = 2, tags = "dry hot", tris = { 842, 194 } },
  { id = "cactus_col", form = "succulent", kind = "cactus", h = 3.40, bark = nil, twin = false, lods = 3, tags = "dry hot tall", tris = { 390, 180, 152 } },
  { id = "cactus_barrel", form = "succulent", kind = "cactus", h = 0.80, bark = nil, twin = false, lods = 2, tags = "dry hot", tris = { 194, 122 } },
  { id = "bush_round", form = "shrub", kind = "bush", h = 1.40, bark = "rough", twin = false, lods = 2, tags = "temperate wet", tris = { 594, 186 } },
  { id = "bush_bloom", form = "shrub", kind = "bush", h = 1.60, bark = "rough", twin = false, lods = 2, tags = "temperate wet hot", tris = { 594, 186 } },
  { id = "bush_broad", form = "shrub", kind = "bush", h = 2.20, bark = "rough", twin = false, lods = 2, tags = "wet hot temperate", tris = { 418, 142 } },
  { id = "shrub_twig", form = "shrub", kind = "shrub", h = 1.30, bark = "rough", twin = false, lods = 2, tags = "dry cold temperate", tris = { 1322, 296 } },
  { id = "shrub_heath", form = "shrub", kind = "shrub", h = 0.60, bark = "rough", twin = false, lods = 2, tags = "cold dry", tris = { 306, 126 } },
  { id = "shrub_needle", form = "shrub", kind = "shrub", h = 1.10, bark = "rough", twin = false, lods = 2, tags = "cold dry", tris = { 386, 134 } },
  { id = "oak", form = "tree", kind = "broadleaf", h = 10.00, bark = "rough", twin = true, lods = 3, tags = "temperate wet", tris = { 2898, 600, 184 } },
  { id = "oak_wide", form = "tree", kind = "broadleaf", h = 8.00, bark = "rough", twin = true, lods = 3, tags = "temperate dry", tris = { 2898, 596, 180 } },
  { id = "birch", form = "tree", kind = "broadleaf", h = 11.00, bark = "smooth", twin = true, lods = 3, tags = "temperate cold wet tall", tris = { 3374, 656, 240 } },
  { id = "willow", form = "tree", kind = "broadleaf", h = 8.50, bark = "rough", twin = true, lods = 3, tags = "wet temperate", tris = { 2322, 512, 172 } },
  { id = "acacia", form = "tree", kind = "broadleaf", h = 7.00, bark = "rough", twin = true, lods = 3, tags = "dry hot", tris = { 3488, 796, 340 } },
  { id = "sapling", form = "tree", kind = "broadleaf", h = 4.00, bark = "smooth", twin = true, lods = 3, tags = "temperate wet hot", tris = { 1122, 228, 76 } },
  { id = "jungle_giant", form = "tree", kind = "broadleaf", h = 16.00, bark = "smooth", twin = true, lods = 3, tags = "wet hot tall", tris = { 2898, 600, 192 } },
  { id = "spruce", form = "tree", kind = "conifer", h = 13.00, bark = "rough", twin = true, lods = 3, tags = "cold temperate tall", tris = { 3616, 1240, 180 } },
  { id = "fir_slim", form = "tree", kind = "conifer", h = 15.00, bark = "rough", twin = true, lods = 3, tags = "cold tall", tris = { 4346, 1522, 196 } },
  { id = "pine", form = "tree", kind = "conifer", h = 12.00, bark = "rough", twin = true, lods = 3, tags = "dry temperate cold tall", tris = { 3432, 1152, 148 } },
  { id = "dwarf_pine", form = "tree", kind = "conifer", h = 4.00, bark = "rough", twin = true, lods = 3, tags = "cold dry", tris = { 2600, 876, 148 } },
  { id = "palm", form = "tree", kind = "palm", h = 8.00, bark = "palm", twin = true, lods = 3, tags = "hot wet", tris = { 788, 416, 140 } },
  { id = "palm_short", form = "tree", kind = "palm", h = 4.50, bark = "palm", twin = true, lods = 3, tags = "hot wet dry", tris = { 692, 304, 140 } },
  { id = "tree_fern", form = "tree", kind = "palm", h = 4.00, bark = "palm", twin = true, lods = 3, tags = "wet temperate hot alien", tris = { 548, 192, 140 } },
  { id = "toadstool", form = "fungus", kind = "fungus", h = 1.00, bark = "stalk", twin = false, lods = 2, tags = "wet cold temperate glow", tris = { 194, 118 } },
  { id = "parasol", form = "fungus", kind = "fungus", h = 2.50, bark = "stalk", twin = false, lods = 3, tags = "wet temperate alien glow", tris = { 170, 102, 70 } },
  { id = "shroom_cluster", form = "fungus", kind = "fungus", h = 0.70, bark = "stalk", twin = false, lods = 2, tags = "wet cold glow", tris = { 1038, 814 } },
  { id = "giant_cap", form = "fungus", kind = "fungus", h = 7.50, bark = "stalk", twin = false, lods = 3, tags = "wet alien tall glow", tris = { 194, 118, 70 } },
  { id = "shelf_tower", form = "fungus", kind = "fungus", h = 4.00, bark = "stalk", twin = false, lods = 3, tags = "wet cold alien glow", tris = { 552, 219, 127 } },
  { id = "spire", form = "spire", kind = "spire", h = 6.00, bark = nil, twin = false, lods = 3, tags = "alien dry cold tall glow", tris = { 242, 86, 62 } },
  { id = "spire_ringed", form = "spire", kind = "spire", h = 8.00, bark = nil, twin = false, lods = 3, tags = "alien hot tall glow", tris = { 1202, 590, 182 } },
  { id = "tubes", form = "fungus", kind = "tubes", h = 2.20, bark = nil, twin = false, lods = 2, tags = "alien wet hot glow", tris = { 722, 338 } },
  { id = "crystals", form = "spire", kind = "crystal", h = 2.20, bark = nil, twin = false, lods = 2, tags = "alien cold dry glow", tris = { 128, 74 } },
  { id = "crystal_big", form = "spire", kind = "crystal", h = 4.50, bark = nil, twin = false, lods = 3, tags = "alien cold dry tall glow", tris = { 164, 110, 56 } },
  { id = "coral_tree", form = "tree", kind = "coral", h = 3.50, bark = nil, twin = false, lods = 3, tags = "alien wet hot glow", tris = { 850, 212, 124 } },
  { id = "bulb_tree", form = "tree", kind = "bulb", h = 4.50, bark = "smooth", twin = true, lods = 3, tags = "alien hot dry glow", tris = { 1396, 472, 220 } },
  { id = "kelp", form = "kelp", kind = "kelp", h = 5.00, bark = nil, twin = false, lods = 3, tags = "aquatic", tris = { 450, 162, 122 } },
  { id = "kelp_short", form = "kelp", kind = "kelp", h = 2.20, bark = nil, twin = false, lods = 2, tags = "aquatic", tris = { 514, 202 } },
  { id = "sea_tubes", form = "kelp", kind = "tubes", h = 1.20, bark = nil, twin = false, lods = 2, tags = "aquatic alien glow", tris = { 962, 450 } },
}
NEUTRAL = { leaf = 0.45, bark = 0.50 }
PALETTES = {
  { id = 0, name = "verdant", dark = { 0.06, 0.16, 0.05 }, mid = { 0.17, 0.36, 0.10 }, light = { 0.38, 0.58, 0.20 }, accent = { 0.92, 0.86, 0.95 }, glow = { 0.60, 1.00, 0.55 }, bark = 0 },
  { id = 1, name = "spring", dark = { 0.14, 0.30, 0.06 }, mid = { 0.34, 0.58, 0.14 }, light = { 0.62, 0.82, 0.30 }, accent = { 1.00, 0.92, 0.35 }, glow = { 0.80, 1.00, 0.40 }, bark = 3 },
  { id = 2, name = "sage", dark = { 0.18, 0.22, 0.14 }, mid = { 0.38, 0.44, 0.30 }, light = { 0.60, 0.66, 0.50 }, accent = { 0.80, 0.70, 0.90 }, glow = { 0.70, 1.00, 0.80 }, bark = 2 },
  { id = 3, name = "chartreuse", dark = { 0.22, 0.28, 0.02 }, mid = { 0.52, 0.60, 0.08 }, light = { 0.78, 0.84, 0.26 }, accent = { 0.95, 0.45, 0.20 }, glow = { 0.90, 1.00, 0.30 }, bark = 4 },
  { id = 4, name = "teal", dark = { 0.02, 0.16, 0.15 }, mid = { 0.08, 0.38, 0.34 }, light = { 0.28, 0.62, 0.55 }, accent = { 0.98, 0.80, 0.40 }, glow = { 0.40, 1.00, 0.90 }, bark = 2 },
  { id = 5, name = "emerald", dark = { 0.01, 0.14, 0.06 }, mid = { 0.04, 0.34, 0.16 }, light = { 0.18, 0.56, 0.30 }, accent = { 0.95, 0.30, 0.35 }, glow = { 0.30, 1.00, 0.60 }, bark = 1 },
  { id = 6, name = "amber", dark = { 0.30, 0.10, 0.02 }, mid = { 0.70, 0.36, 0.07 }, light = { 0.94, 0.64, 0.22 }, accent = { 0.98, 0.90, 0.55 }, glow = { 1.00, 0.70, 0.30 }, bark = 1 },
  { id = 7, name = "crimson", dark = { 0.20, 0.02, 0.04 }, mid = { 0.52, 0.06, 0.08 }, light = { 0.80, 0.22, 0.18 }, accent = { 1.00, 0.80, 0.40 }, glow = { 1.00, 0.35, 0.30 }, bark = 5 },
  { id = 8, name = "ochre", dark = { 0.30, 0.22, 0.06 }, mid = { 0.64, 0.52, 0.20 }, light = { 0.86, 0.76, 0.42 }, accent = { 0.85, 0.30, 0.15 }, glow = { 1.00, 0.85, 0.40 }, bark = 8 },
  { id = 9, name = "rust", dark = { 0.18, 0.06, 0.03 }, mid = { 0.42, 0.18, 0.08 }, light = { 0.66, 0.36, 0.18 }, accent = { 0.95, 0.85, 0.40 }, glow = { 1.00, 0.55, 0.25 }, bark = 1 },
  { id = 10, name = "frost", dark = { 0.22, 0.34, 0.34 }, mid = { 0.50, 0.66, 0.64 }, light = { 0.78, 0.90, 0.88 }, accent = { 0.70, 0.80, 1.00 }, glow = { 0.70, 1.00, 1.00 }, bark = 3 },
  { id = 11, name = "azure", dark = { 0.02, 0.12, 0.24 }, mid = { 0.10, 0.38, 0.58 }, light = { 0.36, 0.66, 0.82 }, accent = { 1.00, 0.95, 0.60 }, glow = { 0.45, 0.85, 1.00 }, bark = 2 },
  { id = 12, name = "indigo", dark = { 0.04, 0.04, 0.16 }, mid = { 0.16, 0.14, 0.42 }, light = { 0.36, 0.34, 0.70 }, accent = { 0.95, 0.75, 0.40 }, glow = { 0.55, 0.55, 1.00 }, bark = 7 },
  { id = 13, name = "violet", dark = { 0.14, 0.04, 0.18 }, mid = { 0.40, 0.16, 0.48 }, light = { 0.66, 0.40, 0.74 }, accent = { 0.98, 0.90, 0.50 }, glow = { 0.85, 0.50, 1.00 }, bark = 7 },
  { id = 14, name = "aubergine", dark = { 0.06, 0.01, 0.06 }, mid = { 0.20, 0.05, 0.17 }, light = { 0.40, 0.16, 0.32 }, accent = { 0.90, 0.50, 0.60 }, glow = { 1.00, 0.40, 0.70 }, bark = 5 },
  { id = 15, name = "umbra", dark = { 0.02, 0.02, 0.03 }, mid = { 0.07, 0.06, 0.08 }, light = { 0.20, 0.15, 0.20 }, accent = { 0.75, 0.20, 0.25 }, glow = { 0.90, 0.30, 0.40 }, bark = 5 },
  { id = 16, name = "rose", dark = { 0.30, 0.06, 0.18 }, mid = { 0.70, 0.28, 0.48 }, light = { 0.94, 0.60, 0.74 }, accent = { 1.00, 0.95, 0.80 }, glow = { 1.00, 0.60, 0.85 }, bark = 4 },
  { id = 17, name = "ivory", dark = { 0.46, 0.46, 0.42 }, mid = { 0.74, 0.74, 0.68 }, light = { 0.94, 0.94, 0.90 }, accent = { 0.60, 0.80, 0.95 }, glow = { 0.90, 1.00, 1.00 }, bark = 3 },
  { id = 18, name = "straw", dark = { 0.34, 0.26, 0.12 }, mid = { 0.62, 0.52, 0.32 }, light = { 0.86, 0.78, 0.56 }, accent = { 0.75, 0.35, 0.55 }, glow = { 1.00, 0.90, 0.55 }, bark = 8 },
}
BARKS = {
  { id = 0, name = "brown", mid = { 0.30, 0.21, 0.14 } },
  { id = 1, name = "dark", mid = { 0.17, 0.12, 0.09 } },
  { id = 2, name = "grey", mid = { 0.40, 0.39, 0.37 } },
  { id = 3, name = "pale", mid = { 0.80, 0.78, 0.73 } },
  { id = 4, name = "red", mid = { 0.42, 0.19, 0.12 } },
  { id = 5, name = "black", mid = { 0.08, 0.07, 0.07 } },
  { id = 6, name = "green", mid = { 0.26, 0.34, 0.17 } },
  { id = 7, name = "violet", mid = { 0.30, 0.24, 0.34 } },
  { id = 8, name = "ochre", mid = { 0.50, 0.40, 0.24 } },
}
-- END FLORA LIBRARY
