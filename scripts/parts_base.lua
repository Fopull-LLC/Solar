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
--              ground's normal and up (step 5's foundations relax it).
--   hull       how the module's walls become a body in the engine's
--              interiors Stage 1 (EN1): "subShape" (flat walls: its "Wall N"
--              boxes) or "shell" (a curved hull: its "Shell" child mesh);
--              nil for a slab. Nothing reads it yet; it says what the prefab
--              was built for.
--
-- Numbers are the real things' (tools/gen_base_parts.py has the sources):
--   Pad Plate       4 x 4 m precast slab, 0.30 m: 11.5 t of concrete
--   Equipment Shed  3.0 x 2.4 x 2.6 m steel shelter on skids: 1.6 t fitted
--   Surface Hab     a 4 m x 6 m pressure can on saddles: 7.5 t dry
-- Prices sit with the ground tier (parts_registry.lua): a base is something
-- you can afford to start, and shipping (base_economy.lua, N1) rides on top.

SECTION = "BASE"

PARTS = {
  padPlate = { prefab = "BasePadPlate", label = "Pad Plate", h = 0.60, rx = 2.0, rz = 2.0, mass = 11.5, cost = 900,
               kind = "structural", fieldOnly = true, seat = -0.0475, half = { x = 2.0, y = 0.30, z = 2.0 },
               slope = 0.95, desc = "4 x 4 m precast slab · 11.5 t · a level deck to build on" },
  shed     = { prefab = "BaseShed", label = "Equipment Shed", h = 2.60, rx = 1.6, rz = 1.32, mass = 1.6, cost = 1400,
               kind = "structural", fieldOnly = true, seat = 1.30, half = { x = 1.55, y = 1.30, z = 1.25 },
               slope = 0.96, hull = "subShape",
               desc = "3.0 x 2.4 m steel shelter · 1.6 t · racks and a bench inside" },
  hab      = { prefab = "BaseHab", label = "Surface Hab", h = 4.36, rx = 3.5, rz = 2.2, mass = 7.5, cost = 6500,
               kind = "structural", fieldOnly = true, seat = 2.104, half = { x = 3.45, y = 2.18, z = 2.05 },
               slope = 0.97, hull = "shell",
               desc = "4 x 6 m pressure can on saddles · 7.5 t · a home for four, one day" },
}

ORDER = { "padPlate", "shed", "hab" }

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
