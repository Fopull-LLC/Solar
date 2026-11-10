-- PARTS_WEAPONS — the craft-mounted laser (expansion X9; scripts/laser_turret.lua
-- runs it; docs/base-building.md §27.7).
--
-- A data script on the Electronics node (scenes/system.ron and builder.ron,
-- beside parts_survey), joined once by the builder through
-- parts_registry.extend as the DEFENCE section of the catalogue.
--
--   Laser Turret   a self-contained turret for a craft: a 0.5 MJ capacitor
--                  charged from the craft's batteries at up to 10 kW, a
--                  diode-pumped emitter at 30 %, a 0.3 m mirror on a two-axis
--                  gimbal (40°/s). Armed, it tracks the TARGET (the targeting
--                  feature) by itself; it fires from its menu, or AUTO when it
--                  is on target and charged (a pod's sentry, a jet's gun).
--                  A RADIAL part: +X out of the face it mounts on, so it
--                  turns about the hull's normal; mount it on a jet's spine
--                  or a lander's side.
--
-- The numbers from the real things: a 0.3 m fast-steering director with its
-- gimbal is ~60 kg; the capacitor (0.5 MJ of film capacitors at ~2 kJ/kg)
-- ~250 kg; the slab head and its cooling ~80 kg.

PARTS = {
  laserTurret = { prefab = "PartLaserTurret", label = "Laser Turret", h = 0.70, rx = 0.42, rz = 0.36, mass = 0.40, cost = 26000,
                  top = false, bottom = false, kind = "structural", radial_orient = true, strength = 160 },
}
ORDER = { "laserTurret" }
SECTION = "DEFENCE"
DESC = {
  laserTurret = "laser turret · 0.5 MJ capacitor from the craft's batteries (10 kW), 0.3 m mirror · armed, it tracks the TARGET and fires from its menu or AUTO on target · radial",
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
