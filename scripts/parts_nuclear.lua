-- PARTS_NUCLEAR — the heat and nuclear parts (deep-space addendum step 3):
-- the Isotope Cell (B1), three radiators (B3), the Shadow Shield (A4) and the
-- Ember reactor, the smallest core, pulled forward from B4 so the fuel rods
-- (B5), the radiation cone (A4) and the scram and restart (A6) have a part
-- to fly on. The Furnace and the Station Core are rulebook data only
-- (scripts/thermal.lua CORES) until step 11.
--
-- A data script on the Electronics node (scenes/system.ron, beside
-- electronics.lua and thermal.lua), like parts_aero on the AeroLib node: the
-- builder reaches it with findScript("parts_nuclear") and joins it once
-- through parts_registry.extend, as the NUCLEAR section of the catalogue.
--
-- Everything a part does thermally is in its MODULES (electronics `mods`),
-- so the blueprint carries it to the flight with no new record keys:
--   rtg       gen (EC/s new), heat, sink (its fins), cap, half (s)
--   radiator  sink (hu at 100 %), draw (its pump, EC/s; 0 = passive), cap
--   reactor   core (a thermal.CORES key) and any of ec, heat, sink, cap,
--             rack, life, rad that differ from it
--   shield    k (the share of radiation it lets through)
-- A deployable radiator also has the solar panel's deploy module (anim
-- "solar": it folds about its SolarWingPivot like a panel, on the Deploy
-- group, U).
--
-- FRAMES (tools/gen_nuclear_parts.py writes the meshes; keep them in step):
--   radial parts (cell, radiators): +X out of the face they mount on, +Y up
--   the stack, the radiator's surfaces facing ±Z.
--   stack parts (shield, Ember): Y up, the Ember's cone opens along its +Y.
--
-- MASSES AND FIGURES, from the real things, compressed like the rest:
--   Isotope Cell  45 kg — an MMRTG (45 kg, ~110 W, ~2 kW of heat through
--                 its eight fins). 0.5 EC/s new, halving in 400 game hours.
--   Radiator Fin  50 kg, passive: a corrugated aluminium panel, 1 hu.
--   Radiator Panel 300 kg: an ammonia-loop panel that folds out, 5 hu.
--   Truss Radiator 1.0 t: an ISS-style accordion of six panels, 20 hu.
--   Shadow Shield 0.8 t: a 1 m disc of tungsten and lithium hydride.
--   Ember         1.8 t, 1 m stack: a Kilopower-class fission core with its
--                 Stirling converters, 6 EC/s, 6 hu at full output, one rod.

PARTS = {
  rtg = { prefab = "PartRTG", label = "Isotope Cell", h = 0.64, rx = 0.36, rz = 0.32, mass = 0.045, cost = 2400,
          top = false, bottom = false, kind = "structural", radial_orient = true, strength = 120,
          mods = { { type = "rtg", gen = 0.5, heat = 0.25, sink = 0.6, cap = 30, half = 1440000 } } },
  radFin = { prefab = "PartRadFin", label = "Radiator Fin", h = 0.90, rx = 0.32, rz = 0.04, mass = 0.05, cost = 300,
             top = false, bottom = false, kind = "structural", radial_orient = true, strength = 140,
             mods = { { type = "radiator", sink = 1, cap = 10 } } },
  radPanel = { prefab = "PartRadPanel", label = "Radiator Panel", h = 0.92, rx = 0.62, rz = 0.06, mass = 0.3, cost = 1200,
               top = false, bottom = false, kind = "structural", radial_orient = true, strength = 160,
               mods = { { type = "radiator", sink = 5, draw = 0.05, cap = 40 }, { type = "deploy", anim = "solar" } } },
  radTruss = { prefab = "PartRadTruss", label = "Truss Radiator", h = 1.60, rx = 1.40, rz = 0.10, mass = 1.0, cost = 3500,
               top = false, bottom = false, kind = "structural", radial_orient = true, strength = 260,
               mods = { { type = "radiator", sink = 20, draw = 0.2, cap = 120 }, { type = "deploy", anim = "solar" } } },
  shadowShield = { prefab = "PartShadowShield", label = "Shadow Shield", h = 0.18, rx = 0.50, rz = 0.50, mass = 0.8,
                   cost = 1800, top = true, bottom = true, kind = "structural", side = true, strength = 900,
                   mods = { { type = "shield", k = 0.02 } } },
  ember = { prefab = "PartEmber", label = "Ember Reactor", h = 1.40, rx = 0.50, rz = 0.50, mass = 1.8, cost = 9000,
            top = true, bottom = true, kind = "structural", side = true, strength = 900,
            mods = { { type = "reactor", core = "ember", ec = 6, heat = 6, rack = 1, rad = 0.5 },
                     { type = "battery", ec = 20 } } },
}

ORDER = { "rtg", "radFin", "radPanel", "radTruss", "shadowShield", "ember" }
SECTION = "NUCLEAR"

DESC = {
  rtg = "isotope cell · 0.5 EC/s day and night, for years · warm fins",
  radFin = "radiator fin · sheds 1 heat · passive, nothing to deploy",
  radPanel = "radiator panel · sheds 5 heat deployed · its pump draws 0.05 EC/s",
  radTruss = "truss radiator · sheds 20 heat deployed · folds for launch",
  shadowShield = "shadow shield · stops 98% of a reactor's radiation behind it",
  ember = "fission reactor · 6 EC/s · 6 heat · one fuel rod · radiation cone up its stack",
}
for id, d in pairs(DESC) do if PARTS[id] then PARTS[id].desc = d end end

function register(REG, CATALOGUE)
  local n = 0
  for _, id in ipairs(ORDER) do
    if not REG[id] then REG[id] = PARTS[id]; n = n + 1 end
  end
  local placed = false
  for _, sec in ipairs(CATALOGUE) do
    if sec[1] == SECTION then
      local have = {}
      for _, id in ipairs(sec[2]) do have[id] = true end
      for _, id in ipairs(ORDER) do if not have[id] then sec[2][#sec[2] + 1] = id end end
      placed = true
    end
  end
  if not placed then CATALOGUE[#CATALOGUE + 1] = { SECTION, ORDER } end
  return n
end
