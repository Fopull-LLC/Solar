-- PARTS_BASE — the BASE section: the parts an Engineer places in the world
-- with the Build Kit (deep-space addendum K3; docs/base-building.md).
--
-- A pure data script on the Build Kit node (scenes/system.ron), beside
-- field_builder.lua; it loads from disk in a luajit test. Its records have
-- the parts registry's shape (parts_registry.lua REG: prefab, label, h, rx,
-- rz, mass in TONNES, cost) plus what a placed part needs:
--
--   fieldOnly  true: a world part. The VAB never lists it (the builder does
--              not extend its registry with this script; the flag is what a
--              shared catalogue would filter on).
--   seat       how far the prefab's origin sits above the ground it stands
--              on (the engine centres a model on its box; tools/gen_base_parts.py
--              prints it).
--   half       the footprint's half-extents { x, y, z } (m), for the overlap
--              test and the ghost (placement.overlapObb).
--   slope      the steepest ground it stands on: the cosine between the
--              ground's normal and up (relaxed to the flag's 0.6 in step 5:
--              `grade` and the footing judge the ground now).
--   hull       how the module's walls become a body in the engine's
--              interiors Stage 1 (EN1): "subShape" (flat walls: its "Wall N"
--              boxes) or "shell" (a curved hull: its "Shell" child mesh);
--              nil for a slab. Nothing reads it yet; it says what the prefab
--              was built for.
--
-- Step 5 (K5–K7) adds what snapping and foundations read:
--   deck       a part others may stand on: its top is `deck` m over its
--              ground point (the Pad Plate's 0.20 m proud slab).
--   tile       a part that tiles edge to edge with others of the same `tile`
--              (m between centres): plates beside plates, square to them.
--   onDeck     may stand on a deck (sheds and habs on plates).
--   grade      the most the ground may fall across the footprint (m) before
--              the part refuses it; up to that the ground under it is
--              levelled (terrain.sculpt "flatten") and a footing is cast
--              where it falls more than FOOTING_FROM.
--   footPad    how far the footing reaches past the footprint (m).
--   skirt      how deep the part's own footing already goes (the slab's
--              0.40 m): no cast footing is needed for a fall shallower.
--
-- Numbers are the real things' (tools/gen_base_parts.py has the sources):
--   Pad Plate       4 x 4 m precast slab, 0.30 m: 11.5 t of concrete
--   Equipment Shed  3.0 x 2.4 x 2.6 m steel shelter on skids: 1.6 t fitted
--   Surface Hab     a 4 m x 6 m pressure can on saddles: 7.5 t dry
--   Build Stand     a 0.9 m steel deck on a telescoping column, 0.5-4.0 m: 0.4 t
--   Station Tower   a 12 m self-supporting lattice and a 3 m dish: 1.5 t of steel
--   Solar Array     two 1.2 x 2.0 m modules on a single-axis tracker: 0.18 t
--   Isotope Skid    four MMRTG-class cells (45 kg each) in a caged rack: 0.3 t
--
-- Step 6 (L1) adds, for parts with behaviour:
--   script     the scene script that owns the part's state (craft_stand for
--              the stand): structures.lua calls its `spawned(rec, part, node)`
--              and `gone(sid, uid)`; field_builder asks its `canRemove(rec,
--              part)` before the part comes down.
--   fields     per-part bp fields a placement starts with (the stand's `h`).
--   stand      the stand's numbers: the deck's settable height (min..max,
--              step), how low it goes to let a wheeled craft down (`low`),
--              the deck's half-width, and `deckOff` = the deck's top over the
--              Deck child's origin (tools/gen_base_parts.py prints it).
-- Prices sit with the ground tier (parts_registry.lua): a base is something
-- you can afford to start, and shipping (base_economy.lua, N1) rides on top.

SECTION = "BASE"

PARTS = {
  padPlate = { prefab = "BasePadPlate", label = "Pad Plate", h = 0.60, rx = 2.0, rz = 2.0, mass = 11.5, cost = 900,
               kind = "structural", fieldOnly = true, seat = -0.0475, half = { x = 2.0, y = 0.30, z = 2.0 },
               slope = 0.6, deck = 0.20, tile = 4.0, grade = 2.0, footPad = 0.15, skirt = 0.40,
               desc = "4 x 4 m precast slab · 11.5 t · a level deck to build on" },
  shed     = { prefab = "BaseShed", label = "Equipment Shed", h = 2.60, rx = 1.6, rz = 1.32, mass = 1.6, cost = 1400,
               kind = "structural", fieldOnly = true, seat = 1.30, half = { x = 1.55, y = 1.30, z = 1.25 },
               slope = 0.6, onDeck = true, grade = 1.6, footPad = 0.20, hull = "subShape",
               desc = "3.0 x 2.4 m steel shelter · 1.6 t · racks and a bench inside" },
  hab      = { prefab = "BaseHab", label = "Surface Hab", h = 4.36, rx = 3.5, rz = 2.2, mass = 7.5, cost = 6500,
               kind = "structural", fieldOnly = true, seat = 2.104, half = { x = 3.45, y = 2.18, z = 2.05 },
               slope = 0.6, onDeck = true, grade = 2.0, footPad = 0.25, hull = "shell",
               desc = "4 x 6 m pressure can on saddles · 7.5 t · a home for four, one day" },
  -- Step 6 (L1): a craft stand. Its deck's height is the part's own `h`
  -- (a bp field, copied from `fields` at placement); its behaviour is
  -- craft_stand.lua's (`script`).
  -- (the addendum asked for a 1.2 m deck; a small rover's tyres stand 0.5 m
  -- either side of its centre line and would sit on that deck's corners, so
  -- the deck is 0.9 m: it fits between them)
  stand    = { prefab = "BaseStand", label = "Build Stand", h = 1.0, rx = 0.45, rz = 0.45, mass = 0.4, cost = 650,
               kind = "structural", fieldOnly = true, seat = -0.2200, half = { x = 0.45, y = 0.30, z = 0.45 },
               slope = 0.6, onDeck = true, grade = 1.0, footPad = 0.15, script = "craft_stand",
               fields = { h = 1.0 },
               stand = { min = 0.5, max = 4.0, step = 0.1, low = 0.28, deck = 0.45, deckOff = 2.0385 },
               desc = "0.9 m deck on a telescoping column · 0.5–4.0 m · 0.4 t · build a craft on it" },
  -- Step 7 (M1): the Base Station Tower founds a base (scripts/bases.lua) and
  -- is a ground relay (scripts/base_tower.lua, comms.lua). `tower`: its
  -- antenna's height over the ground point (`mast`), what it draws to be a
  -- ground station (`draw`, EC/s), and the spacing and base radius the
  -- addendum sets (1 km between towers; every structure within 150 m belongs
  -- to its base). Unpowered it is a mast: a beacon-class relay.
  tower    = { prefab = "BaseTower", label = "Base Station Tower", h = 13.51, rx = 1.3, rz = 1.3, mass = 1.5, cost = 4000,
               kind = "structural", fieldOnly = true, seat = 6.7540, half = { x = 1.30, y = 6.6, z = 1.30 },
               slope = 0.6, onDeck = true, grade = 1.5, footPad = 0.25, script = "base_tower",
               tower = { mast = 11.6, draw = 2.0, spacing = 1000, radius = 150 },
               desc = "12 m lattice mast, 3 m dish · 1.5 t · founds a base; powered (2 EC/s) it is a ground station" },
  -- Step 7: the tower's power. Until the base grid (M6, step 8) its sources
  -- are the ones on its own STRUCTURE (the same pads). `power`: kind "solar"
  -- = gen EC/s in home-orbit sunlight, the cells tracking about the part's +X
  -- (electronics.solarOutput: nothing in a planet's shadow); kind "rtg" =
  -- gen EC/s day and night.
  solarArray = { prefab = "BaseSolar", label = "Solar Array", h = 1.92, rx = 1.3, rz = 0.92, mass = 0.18, cost = 1800,
               kind = "structural", fieldOnly = true, seat = 0.9576, half = { x = 1.30, y = 0.96, z = 0.92 },
               slope = 0.6, onDeck = true, grade = 1.2, footPad = 0.15,
               power = { kind = "solar", gen = 3.0, lift = 1.35 },
               desc = "4.8 m² single-axis tracker · 0.18 t · 3 EC/s in full sun, nothing at night" },
  -- (behind the Isotope Cell's research: research.lua ALIAS, isotopeSkid is rtg)
  isotopeSkid = { prefab = "BaseIsotope", label = "Isotope Skid", h = 1.09, rx = 0.85, rz = 0.6, mass = 0.30, cost = 10000,
               kind = "structural", fieldOnly = true, seat = 0.5460, half = { x = 0.85, y = 0.55, z = 0.60 },
               slope = 0.6, onDeck = true, grade = 1.0, footPad = 0.15,
               power = { kind = "rtg", gen = 2.0 },
               desc = "four Isotope Cells in a caged rack · 0.3 t · 2 EC/s day and night" },
}

ORDER = { "padPlate", "shed", "hab", "stand", "tower", "solarArray", "isotopeSkid" }

-- The panel's sections: { { title, ids } } (catalog_panel's host shape).
function catalogue()
  local ids = {}
  for _, id in ipairs(ORDER) do if PARTS[id] then ids[#ids + 1] = id end end
  return { { title = SECTION, ids = ids } }
end

function partInfo(id) return PARTS[id] end

-- parts_registry.extend's hook, for a shared catalogue one day: adds the
-- BASE section (every entry flagged fieldOnly). Nothing calls it today.
function register(REG, CATALOGUE)
  local n = 0
  for _, id in ipairs(ORDER) do
    if REG[id] == nil then REG[id] = PARTS[id]; n = n + 1 end
  end
  CATALOGUE[#CATALOGUE + 1] = { SECTION, ORDER }
  return n
end
